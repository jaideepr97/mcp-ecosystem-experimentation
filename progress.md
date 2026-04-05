# Session Handoff — Current State

**Date**: 2026-04-04
**Last action**: Phase 17 complete — VirtualMCPServers + AuthPolicies + per-group tool filtering in team-a

---

## Current State Summary

Phase 17 is complete. The `team-a` namespace now has full per-group authorization: 3 Keycloak groups with 5 users, 3 VirtualMCPServers for tool filtering, a gateway-level AuthPolicy injecting `X-Mcp-Virtualserver` headers based on group membership, and 2 per-HTTPRoute AuthPolicies enforcing `tools/call` authorization via CEL predicates. The full authorization matrix (14/14 checks) is verified, and tool delisting from VirtualMCPServers correctly removes tools from `tools/list` while they remain callable (confirming VirtualMCPServer is filtering-only, not enforcement). All prior infrastructure (Phases 1-16) remains active.

### What was completed in this session

1. **Keycloak groups and users** — Created 3 groups (`team-a-developers`, `team-a-ops`, `team-a-leads`) and 5 users distributed across them in Keycloak. Groups are included in JWT tokens via the `groups` claim.

2. **Gateway AuthPolicy** — Applied a gateway-level AuthPolicy that authenticates via Keycloak JWT and injects the `X-Mcp-Virtualserver` header based on the user's group membership, so clients never choose their virtual server directly.

3. **3 VirtualMCPServers** — Created `virtualserver-dev`, `virtualserver-ops`, and `virtualserver-leads`, each composing a different subset of tools from `test-server-a1` and `test-server-a2` to give each group a tailored tool view.

4. **2 per-HTTPRoute AuthPolicies** — Applied `authpolicy-server-a1` and `authpolicy-server-a2` with CEL predicates matching Keycloak groups, enforcing which groups can call tools on each server.

5. **Authorization matrix verified (14/14)** — Every user tested against every tool category: correct tools visible via `tools/list`, correct `tools/call` allowed/denied per group. Full matrix passed.

6. **Tool delisting test passed** — Removing a tool from a VirtualMCPServer correctly hides it from `tools/list` but the tool remains callable via `tools/call`, confirming VirtualMCPServer is filtering-only (Known Issue #5).

### Cluster State

- Everything from Phase 15 still active
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
- **team-a namespace (Phases 16-17)**:
  - `team-a-gateway` — Programmed, Envoy gateway in `team-a` namespace
  - `team-a-gateway-extension` — Ready, MCPGatewayExtension in `team-a`
  - `test-server-a1` — 5 tools, registered with `team-a` gateway
  - `test-server-a2` — 7 tools, registered with `team-a` gateway
  - 4 pods running in `team-a` namespace (gateway, broker, router, plus server pods)
  - Isolation confirmed: 12 tools visible via `team-a` gateway, 35 via `mcp-test` gateway
  - `gateway-auth-policy` — Gateway-level AuthPolicy (JWT auth + `X-Mcp-Virtualserver` injection by group)
  - `authpolicy-server-a1` — Per-HTTPRoute AuthPolicy for test-server-a1 (CEL group predicates)
  - `authpolicy-server-a2` — Per-HTTPRoute AuthPolicy for test-server-a2 (CEL group predicates)
  - `virtualserver-dev` — VirtualMCPServer for developers group
  - `virtualserver-ops` — VirtualMCPServer for ops group
  - `virtualserver-leads` — VirtualMCPServer for leads group
  - 5 Keycloak users across 3 groups (`team-a-developers`, `team-a-ops`, `team-a-leads`)
  - `keycloak-auth` service — Keycloak authentication backing for AuthPolicies
  - Authorization matrix: 14/14 checks passing

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
11. **VirtualMCPServers become largely redundant under Auth Phase 2** — when Keycloak `resource_access` defines per-user tool permissions and the `x-authorized-tools` wristband JWT handles `tools/list` filtering, VirtualMCPServers no longer serve an access control function. They reduce to an optional LLM ergonomics layer for workflow-specific tool scoping. RHAISTRAT-1149 documentation should clarify their role relative to which auth phase is deployed.
12. **VirtualMCPServer controller writes to hardcoded mcp-system namespace, not MCPGatewayExtension's namespace** — the controller always writes virtual server config to `mcp-system` regardless of which namespace the MCPGatewayExtension lives in. Workaround: manually add `virtualServers` entries to the config Secret in the target namespace.

---

## Next Steps — Narrowed by RHAISTRAT-1149

Scope is now driven by [RHAISTRAT-1149](https://redhat.atlassian.net/browse/RHAISTRAT-1149) — "Document Best Practices for Deploying MCP Servers with OpenShift AI". The ticket frames everything around two personas (Platform Engineer vs AI Engineer) and the full lifecycle: Catalog → Deployment → Gateway Registration → VirtualMCPServer → Gen AI Studio consumption.

Chris Hambridge's comment (Jan 26) from RHAISTRAT-1084 feature refinement identified the key gaps. The next phases should demonstrate these concrete scenarios:

### Design Scoping (completed)

A design discussion driven by RHAISTRAT-1149 narrowed scope and uncovered key findings about VirtualMCPServers, AuthPolicy alignment, credential patterns, and ecosystem deployment topology. The full narrative is documented in `docs/experimentation.md` under "Phase 16-20: Design Scoping." Key conclusions:

- VirtualMCPServers are filtering-only (not enforcement), not identity-aware, and have no discovery API
- Per-tool CEL predicates don't scale; Auth Phase 2 design (wristband JWTs + Keycloak resource_access) solves this but isn't available yet
- VirtualMCPServers become largely redundant once Phase 2 is adopted
- Clients should never choose virtual servers — platform injects via AuthPolicy response rules
- Deployment topology: 1 catalog + 1 operator per cluster, 1 gateway per namespace, shared Keycloak + Vault
- Three credential patterns: team-level Vault, per-user Vault (identity-bound services like Jira), OAuth2 token exchange (Phase 2)
- K8s Secrets still needed for broker tool discovery even with Vault

### Phase 16: Namespace-Isolated Gateway (completed)
- Created `team-a` namespace with its own Gateway + MCPGatewayExtension
- Deployed 2 test servers (`test-server-a1` with 5 tools, `test-server-a2` with 7 tools), registered with `team-a`'s gateway via `gateway-ref` annotation
- Isolation verified — `team-a`'s gateway sees 12 tools, `mcp-test` sees 35 tools, zero cross-namespace leakage
- Tool call routing works through `team-a`'s Envoy gateway

### Phase 17: VirtualMCPServers + AuthPolicies (completed)
- 3 namespace-scoped Keycloak groups (`team-a-developers`, `team-a-ops`, `team-a-leads`) with 5 users
- 3 VirtualMCPServers (one per group's tool view, cross-server tool composition)
- 2 per-HTTPRoute AuthPolicies for `tools/call` (CEL predicates by group)
- Gateway AuthPolicy response rule injecting `X-Mcp-Virtualserver` header based on group
- Authorization matrix verified: 14/14 checks passing
- Tool delisting test passed: VirtualMCPServer filtering confirmed as presentation-only (Known Issue #5)

### Phase 18: Vault Credential Patterns
- Server 1: team-level Vault credential (keyed off group claim) — shared service account
- Server 2: per-user Vault credentials (keyed off `sub` claim) — Jira stand-in for identity-bound services
- K8s Secrets for broker discovery on both servers (read-only service account credentials)
- AuthPolicies updated with Vault metadata evaluators (team-level vs per-user URL expressions)
- Test: verify correct credential reaches upstream per user/team

### Phase 19: Multi-Namespace Expansion
- Replicate `team-a` pattern to `team-b` and `team-c`
- Vary group-to-tool mappings across namespaces
- 2-3 cross-namespace users (e.g., a lead with access to two teams)
- Single operator + catalog serving all 3 namespaces
- 15 total users distributed across namespaces

### Phase 20: Rate Limiting
- RateLimitPolicy on at least one namespace using Limitador (already deployed)
- Falls under "security, observability, and compliance considerations" from RHAISTRAT-1149

### Deferred (out of scope for RHAISTRAT-1149)
- Multi-cluster / ACM / DNSPolicy
- Auth Phase 2 (Keycloak resource_access + wristband JWTs) — designed but not available for this experiment
- `KeycloakToolRoleMappingPolicy` higher-level abstraction
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
| `infrastructure/team-a/namespace.yaml` | team-a namespace definition |
| `infrastructure/team-a/gateway.yaml` | team-a Gateway + HTTPRoute |
| `infrastructure/team-a/mcpgatewayextension.yaml` | team-a MCPGatewayExtension |
| `infrastructure/team-a/test-server-a1.yaml` | Test server A1 (5 tools) for team-a |
| `infrastructure/team-a/test-server-a2.yaml` | Test server A2 (7 tools) for team-a |
| `infrastructure/team-a/gateway-auth-policy.yaml` | Gateway-level AuthPolicy (JWT auth + X-Mcp-Virtualserver injection by group) |
| `infrastructure/team-a/authpolicy-server-a1.yaml` | Per-HTTPRoute AuthPolicy for test-server-a1 (CEL group predicates) |
| `infrastructure/team-a/authpolicy-server-a2.yaml` | Per-HTTPRoute AuthPolicy for test-server-a2 (CEL group predicates) |
| `infrastructure/team-a/virtualserver-dev.yaml` | VirtualMCPServer for team-a-developers group |
| `infrastructure/team-a/virtualserver-ops.yaml` | VirtualMCPServer for team-a-ops group |
| `infrastructure/team-a/virtualserver-leads.yaml` | VirtualMCPServer for team-a-leads group |

## Key Ports (host → Kind NodePort → gateway)

| Host Port | NodePort | Gateway Port | Service |
|-----------|----------|--------------|---------|
| 8001 | 30080 | 8080 | MCP (HTTP) |
| 8002 | 30089 | 8002 | Keycloak (HTTP) |
| 8443 | 30443 | 8443 | MCP (HTTPS) |
| 8445 | 30445 | 8445 | Keycloak (HTTPS) |
