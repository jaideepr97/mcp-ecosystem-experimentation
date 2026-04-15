# Session Handoff — Current State

**Date**: 2026-04-05
**Last action**: Phase 18 complete — Vault credential patterns, persona flows doc, all docs/scripts/diagrams updated and pushed

---

## Current State Summary

Phase 18 is complete and all documentation is current. The `team-a` namespace now has the full stack: namespace isolation (Phase 16), per-group VirtualMCPServers + AuthPolicies (Phase 17), and Vault credential injection via AuthPolicy metadata evaluators (Phase 18). Two credential patterns are demonstrated: team-level (group-keyed, `X-Team-Credential`) on server-a1 and per-user (sub-keyed, `X-User-Credential`) on server-a2. All prior infrastructure remains active.

### What was completed in this session

1. **Vault credential injection (Phase 18)** — Added two-stage metadata evaluator chains to both per-HTTPRoute AuthPolicies: JWT→Vault token exchange (stage 1), then Vault secret read (stage 2). Server-a1 uses group-keyed team secrets, server-a2 uses sub-keyed user secrets. Credentials injected as response headers visible to upstream MCP servers.

2. **CRD field discovery** — Resolved three failed approaches for JWT extraction: `auth.identity.jwt` (doesn't exist), gjson `@extract` (wrong token), CEL `request.headers.authorization.split(' ')[1]` (works). Also discovered: hyphenated metadata keys cause CEL parse errors (use underscores), `urlExpression` is a separate top-level field from `url`.

3. **Credential injection verified** — dev1 gets `team-dev-shared-key-001` (team) + `dev1-personal-key` (user). lead1 gets `team-leads-shared-key-003` (team) + `lead1-personal-key` (user).

4. **Persona flows document** — Created `docs/persona-flows.md` with end-to-end Platform Engineer and AI Engineer workflows, concrete commands, and the bridge table showing how platform config maps to AI engineer experience.

5. **Diagrams** — Created `docs/diagrams/team-a-request-flow.mermaid` (flowchart with credential injection paths). Rewrote `docs/diagrams/request-flow.mermaid` (sequence diagram) for team-a with VirtualMCPServer injection + both Vault patterns + deny path.

6. **All docs updated for Phase 18** — README (current state, test users, quick test, repo structure, removed redundant Key Findings section), friction-points.md (4 new CEL/metadata gotchas #20-23), experimentation.md (Phase 18 narrative), changes-tracker.md (Phase 16-18 artifacts).

7. **All scripts updated** — setup.sh (Vault secret storage + user profile fix), guided-setup.sh (new Phase 6 for Vault credentials, user profile fix, bumped to 6 phases), test-pipeline.sh (Phase 10: 6 credential injection checks).

### Cluster State

- **Shared control plane**: mcp-system (controller), keycloak, kuadrant-system (Authorino), vault, catalog-system, cert-manager, istio-system
- Vault running in `vault` namespace (dev mode, root token: `root`)
- Vault JWT auth method enabled, backed by Keycloak JWKS
- Vault policy `authorino`: read `secret/data/mcp-gateway/*`
- Vault role `authorino`: bound to `aud: mcp-gateway`, user_claim: `sub`
- Vault team secrets: `secret/mcp-gateway/teams/{team-a-developers,team-a-ops,team-a-leads}`
- Vault per-user secrets: `secret/mcp-gateway/users/{sub}` for dev1, dev2, ops1, ops2, lead1
- Operator running `quay.io/jrao/mcp-lifecycle-operator:gateway-credential-ref`
- Keycloak `mcp-gateway` client has default scopes: basic, roles, groups, mcp-gateway-audience
- **team-a namespace (Phases 16-18)**:
  - `team-a-gateway` — Programmed, Envoy gateway with HTTP + HTTPS listeners
  - `team-a-gateway-extension` — Ready, MCPGatewayExtension
  - `test-server-a1` — 5 tools, team-level Vault credential (`X-Team-Credential`)
  - `test-server-a2` — 7 tools, per-user Vault credential (`X-User-Credential`)
  - 4 pods running: gateway, broker, test-server-a1, test-server-a2
  - `gateway-auth-policy` — Gateway-level AuthPolicy (JWT auth + `X-Mcp-Virtualserver` injection by group)
  - `authpolicy-server-a1` — Per-HTTPRoute AuthPolicy (CEL group predicates + team-level Vault metadata evaluators)
  - `authpolicy-server-a2` — Per-HTTPRoute AuthPolicy (CEL group predicates + per-user Vault metadata evaluators)
  - 3 VirtualMCPServers: dev (6 tools), ops (6 tools), leads (12 tools)
  - 5 Keycloak users across 3 groups
  - Authorization matrix: 14/14 checks passing
  - Credential injection: verified for dev1 and lead1 on both servers

---

## Known Issues (ongoing)

See [docs/friction-points.md](docs/friction-points.md) for the complete list (23 entries). Key ongoing items:

1. **`tools/list` returns all tools regardless of permissions** — broker aggregates without identity-based filtering. VirtualMCPServers provide group-based filtering but are presentation-only.
2. **500 vs 403 on full server deny** — broker wraps Authorino 403 as transport error, returns 500.
3. **Env-var-only MCP servers can't use gateway credential injection** — servers must accept credentials via HTTP headers.
4. **VirtualMCPServer controller writes to hardcoded mcp-system namespace** — workaround: manual config Secret patch.
5. **Per-tool CEL predicates don't scale** — works for experimentation, not production. Auth Phase 2 (wristband JWTs) solves this but isn't available yet.
6. **VirtualMCPServer ↔ AuthPolicy alignment is manual** — no automatic bridging between the two CRD systems.
7. **`groups` scope must be explicitly requested** — token requests without `scope=openid groups` cause silent AuthPolicy failures.

---

## Next Steps — Narrowed by RHAISTRAT-1149

Scope is driven by [RHAISTRAT-1149](https://redhat.atlassian.net/browse/RHAISTRAT-1149) — "Document Best Practices for Deploying MCP Servers with OpenShift AI".

### Completed Phases

| Phase | Description | Status |
|-------|-------------|--------|
| Design Scoping | VirtualMCPServer/AuthPolicy analysis, credential patterns, topology | Done |
| 16 | Namespace-isolated gateway (`team-a`) | Done |
| 17 | VirtualMCPServers + AuthPolicies (3 groups, 5 users, 14/14 auth matrix) | Done |
| 18 | Vault credential patterns (team-level + per-user injection) | Done |

### Remaining Phases

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
- Auth Phase 2 (Keycloak resource_access + wristband JWTs) — designed but not available
- `KeycloakToolRoleMappingPolicy` higher-level abstraction
- Redis session store for broker HA
- Registry and advanced aggregation (explicitly deferred in ticket)

### Other
- **Coordinate with Gordon Sim** on best practice recommendations

---

## Key Files

| File | Description |
|------|-------------|
| `scripts/setup.sh` | Full cluster setup (Phases 1-18, Vault secrets + Keycloak users) |
| `scripts/guided-setup.sh` | Interactive guided setup (6 phases with gum TUI) |
| `scripts/test-pipeline.sh` | Full pipeline tests (10 phases including credential injection) |
| `scripts/mcp-client.sh` | Interactive MCP client (device auth flow) |
| `docs/persona-flows.md` | Platform Engineer + AI Engineer end-to-end workflows |
| `docs/friction-points.md` | 23 upstream friction points with workarounds |
| `docs/experimentation.md` | Full chronological narrative (Phases 1-18) |
| `docs/changes-tracker.md` | Code changes + deployment artifacts |
| `docs/diagrams/team-a-request-flow.mermaid` | Request flow with credential injection (flowchart) |
| `docs/diagrams/request-flow.mermaid` | Request flow sequence diagram |
| `docs/diagrams/component-architecture.mermaid` | Cluster component map |
| `docs/diagrams/multi-tenancy-architecture.mermaid` | Namespace isolation + control plane |
| `infrastructure/kind/team-a/authpolicy-server-a1.yaml` | Per-HTTPRoute AuthPolicy (team-level Vault credential) |
| `infrastructure/kind/team-a/authpolicy-server-a2.yaml` | Per-HTTPRoute AuthPolicy (per-user Vault credential) |
| `infrastructure/kind/team-a/gateway-auth-policy.yaml` | Gateway AuthPolicy (JWT + VirtualMCPServer injection) |
| `infrastructure/kind/team-a/virtualserver-*.yaml` | 3 VirtualMCPServer CRs (dev, ops, leads) |
| `infrastructure/kind/vault/configure.sh` | Vault JWT auth + policy + role setup |

## Key Ports (host → Kind NodePort → gateway)

| Host Port | NodePort | Gateway Port | Service |
|-----------|----------|--------------|---------|
| 8001 | 30080 | 8080 | team-a MCP (HTTP) |
| 8002 | 30089 | 8002 | Keycloak (HTTP) |
| 8443 | 30443 | 8443 | team-a MCP (HTTPS) |
| 8445 | 30445 | 8445 | Keycloak (HTTPS) |
