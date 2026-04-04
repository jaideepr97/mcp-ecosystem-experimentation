# Session Handoff — Current State

**Date**: 2026-04-03
**Last action**: Phase 15 complete — mcp-client.sh fixed, test pipeline expanded to 63 checks, docs updated

---

## Current State Summary

Phase 15 is complete. The full Vault token exchange flow works end-to-end: user authenticates with Keycloak → gateway exchanges JWT for stored credential via Vault → upstream MCP server receives the credential. The GitHub MCP server is deployed and callable through the gateway with 23 tools registered.

The `mcp-client.sh` JSONDecode error has been fixed (two bugs: broken default params `\{\}` → `"{}"`, and `echo` → `printf '%s\n'` for zsh compatibility). The test pipeline now has 63 checks across 8 phases, including Vault JWT login verification and credential round-trip testing with a dummy token.

### What was completed in this session

1. **mcp-client.sh JSONDecode fix** — Root cause was two bugs:
   - Default params in `mcp_call` was `\{\}` (literal backslash-brace, not valid JSON). When `mcp_call "tools/list"` was called without a second arg, the payload python script crashed on `json.loads('\{}')`, producing an empty curl request. Fixed to `"{}"`.
   - `echo "$var"` in zsh interprets `\n` as newlines, corrupting JSON strings from GitHub tool descriptions (16 occurrences of `\n` in tool descriptions). Fixed all `echo` calls to `printf '%s\n'` for portability.

2. **Router hairpin auth issue resolved** — The `tools/call` 4xx via curl that was observed in the previous session no longer reproduces. Was likely a transient timing issue.

3. **Test pipeline Phase 8** — Added 8 new checks for Vault credential exchange:
   - Vault pod running, JWT auth method enabled
   - Vault JWT login with Keycloak token (via `vault write auth/jwt/login`)
   - Vault secret round-trip: stores a dummy PAT, reads it back with the JWT-derived client token, verifies match
   - GitHub MCPServerRegistration ready with 23 tools
   - GitHub AuthPolicy and credential secret with correct label

4. **Documentation updated** — README.md (pipeline description, key findings, repo structure, custom images, services table), changes-tracker.md (operator credential-ref, Vault observations, mcp-client.sh fix), progress.md.

### Cluster State

- Everything from Phase 14 still active
- Vault running in `vault` namespace (dev mode, root token: `root`)
- Vault JWT auth method enabled, backed by Keycloak JWKS
- Vault policy `authorino`: read `secret/data/mcp-gateway/*`
- Vault role `authorino`: bound to `aud: mcp-gateway`, user_claim: `sub`
- GitHub MCP server pod running in `mcp-test` (HTTP mode, port 8082)
- MCPServerRegistration `github` — READY: True, 23 tools, credentials: `github-broker-credential`
- AuthPolicy `github-auth-policy` applied (Vault token exchange flow) — working
- Broker credential (`github-broker-credential`): valid, scopes: `public_repo, read:org, read:packages, read:project, read:public_key, read:ssh_signing_key`
- Operator running `quay.io/jrao/mcp-lifecycle-operator:gateway-credential-ref`
- Keycloak `mcp-gateway` client has default scopes: basic, roles, groups, mcp-gateway-audience
- Test pipeline: 63/63 passing (8 phases)

---

## Known Issues (ongoing)

1. **`tools/list` not filtered** — all users see all tools regardless of permissions. Requires broker-side changes.
2. **500 vs 403 on full server deny** — broker returns 500 instead of 403. Presentation issue, not security.
3. **Env-var-only MCP servers can't use per-user Vault credentials** — servers that read tokens only from environment variables (e.g., Slack MCP server) force a 1:1 deployment-per-user model. The GitHub server avoids this by also accepting `Authorization: Bearer` headers in HTTP mode.
4. **GitHub search API restrictions** — `github_search_issues` returns 422 on some orgs (e.g., `meta-llama`) due to org-level search visibility restrictions. Not a gateway issue — same behavior with `gh` CLI.
5. **VirtualMCPServer is filtering-only, not enforcement** — `tools/list` is filtered but `tools/call` is not blocked. Users who know a tool name can still call it even if it's not in their virtual server. AuthPolicy remains the only security boundary.
6. **VirtualMCPServer has no discovery mechanism** — no gateway API to list available virtual servers. Users must discover them via `kubectl get mcpvirtualservers` (requires K8s access), out-of-band communication, or Gen AI Studio UI. Friction point for direct API/CLI consumers.
7. **VirtualMCPServer ↔ AuthPolicy alignment is manual** — VirtualMCPServers are not group/identity-aware. If both are used, the platform engineer must manually keep the tool lists in sync with authorization predicates, or users see tools they can't call (403).
8. **Per-tool CEL predicates don't scale** — inline `patternMatching` in AuthPolicy works for experimentation but becomes unmanageable at scale (many tools × many groups). Production would need external policy engines (OPA) or coarser authorization at the namespace/gateway level.
9. **VirtualMCPServer selection requires custom HTTP headers** — standard MCP clients (Claude Desktop, Cursor, etc.) cannot inject the `X-Mcp-Virtualserver` header. Only Gen AI Studio or custom clients can select a virtual server. Per-virtual-server URL paths (e.g., `/mcp/dev-tools`) would work with any client but the broker only exposes a single `/mcp` endpoint today.
10. **VirtualMCPServer-to-group binding requires manual coordination across two CRD systems** — the correct pattern is platform-driven (AuthPolicy injects the header based on JWT groups, client is unaware), but this means maintaining VirtualMCPServer CRs (mcp-gateway) and AuthPolicy response rules (Kuadrant/Authorino) independently with no automatic bridging between them.

---

## Next Steps — Narrowed by RHAISTRAT-1149

Scope is now driven by [RHAISTRAT-1149](https://redhat.atlassian.net/browse/RHAISTRAT-1149) — "Document Best Practices for Deploying MCP Servers with OpenShift AI". The ticket frames everything around two personas (Platform Engineer vs AI Engineer) and the full lifecycle: Catalog → Deployment → Gateway Registration → VirtualMCPServer → Gen AI Studio consumption.

Chris Hambridge's comment (Jan 26) from RHAISTRAT-1084 feature refinement identified the key gaps. The next phases should demonstrate these concrete scenarios:

### Phase 16: Namespace-Isolated Gateways
- Create a second namespace (e.g., `team-b`) with its own MCP Gateway
- Register different MCP servers per namespace
- Show that teams cannot see each other's registered servers
- Validates: "How can a Platform Engineer create an MCP Gateway per namespace in order to isolate registered MCP servers"

### Phase 17: VirtualMCPServer Tool Curation (analysis in progress)

Investigation through code review and architecture discussion has surfaced key findings:

**How VirtualMCPServers work:**
- CRD is minimal: just `spec.tools` (list of tool names) + `spec.description`
- Client selects via `X-Mcp-Virtualserver: namespace/name` header
- Broker filters `tools/list` response — filtering only, does NOT block `tools/call`
- Can span tools across multiple registered MCP servers (tool names are already prefixed)

**Alignment with AuthPolicy:**
- VirtualMCPServer is not per-user/group — it's selected by header
- AuthPolicy (per-tool CEL predicates) is the actual security enforcement
- If both are used, they must be kept in sync manually — VirtualMCPServer should only list tools the intended audience is authorized to call, otherwise users see tools they get 403 on
- Inline CEL predicates don't scale: 50 tools × 8 groups = unmanageable
- Better pattern: use namespace isolation + VirtualMCPServer for curation, keep AuthPolicy coarse (group can access this namespace's gateway), avoid per-tool predicates

**Discovery gap:**
- No gateway API to list available VirtualMCPServers — broker stores them internally, lookup by header only
- Users must discover virtual servers via: `kubectl get mcpvirtualservers` (requires K8s access), out-of-band communication, or Gen AI Studio UI (not yet implemented)
- For direct API/CLI consumers this is a friction point; for Summit MVP it gets papered over by Gen AI Studio UI

**Remaining Phase 17 work:**
- Deploy sample VirtualMCPServer CRs to validate the filtering behavior end-to-end
- Test tool delisting (remove a tool from virtual server, confirm it disappears from `tools/list` but remains callable via `tools/call`)
- Document the recommended pattern and tradeoffs

### Phase 18: MCP Server/Tool Revocation Workflow
- End-to-end removal: delist from catalog → identify deployed instances → scale down / delete → unregister from gateway (CR deletion)
- Document the recommended order of operations
- Validates: "MCP Server or Tool Revocation Process"

### Phase 19: Rate Limiting (RateLimitPolicy)
- Configure per-user and/or per-tool rate limits using Limitador (already deployed)
- Falls under "security, observability, and compliance considerations" from the ticket

### Deferred (out of scope for RHAISTRAT-1149)
- Multi-cluster / ACM / DNSPolicy
- OPA Rego / SpiceDB advanced authorization
- Redis session store for broker HA
- Registry and advanced aggregation (explicitly deferred in ticket)

### Other
- **Commit and push** both repos (experimentation + operator)
- **Coordinate with Gordon Sim** on best practice recommendations

---

## Key Files

| File | Description |
|------|-------------|
| `scripts/setup.sh` | Full cluster setup (16 phases, Vault + GitHub gated on GITHUB_PAT) |
| `scripts/test-pipeline.sh` | Full pipeline + auth matrix + TLS + Vault (63 checks) |
| `scripts/mcp-client.sh` | Interactive MCP client (device auth flow) |
| `scripts/store-github-pat.sh` | Store a GitHub PAT in Vault for a Keycloak user |
| `infrastructure/vault/deployment.yaml` | Vault deployment + service (dev mode) |
| `infrastructure/vault/configure.sh` | Vault JWT auth + policy + role setup |
| `infrastructure/auth/authpolicy-github.yaml` | Vault token exchange AuthPolicy for GitHub server |
| `infrastructure/test-servers/github-server.yaml` | MCPServer CR for GitHub MCP server (with credential-ref annotation) |
| `infrastructure/keycloak/realm-import.yaml` | Keycloak realm (groups + mcp-gateway-audience as default scopes) |
| `infrastructure/catalog/catalog-sources.yaml` | Catalog with GitHub server entry (local deployment) |

## Key Ports (host → Kind NodePort → gateway)

| Host Port | NodePort | Gateway Port | Service |
|-----------|----------|--------------|---------|
| 8001 | 30080 | 8080 | MCP (HTTP) |
| 8002 | 30089 | 8002 | Keycloak (HTTP) |
| 8443 | 30443 | 8443 | MCP (HTTPS) |
| 8445 | 30445 | 8445 | Keycloak (HTTPS) |
