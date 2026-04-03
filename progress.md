# Session Handoff — Current State

**Date**: 2026-04-03
**Last action**: Phase 14 — TLS termination at gateway via cert-manager + Kuadrant TLSPolicy

---

## Current State Summary

Fully automated MCP ecosystem with per-user, per-tool authorization and TLS termination. Setup script deploys everything from scratch; test pipeline verifies all 55 checks across 7 phases.

### What changed since Phase 13

1. **cert-manager installed** (v1.17.2) — CA issuer chain: self-signed → CA certificate → CA ClusterIssuer
2. **TLSPolicy** — targets Gateway, auto-creates Certificate CRs for HTTPS listeners
3. **HTTPS listeners** — MCP on port 8443, Keycloak on port 8445, TLS terminated at Envoy
4. **Kind cluster** — added port mappings for HTTPS (8443→30443, 8445→30445)
5. **NodePort service** — added HTTPS entries (30443→8443, 30445→8445)
6. **Keycloak HTTPS** — gateway patch + HTTPRoute for port 8445 with OAuth discovery rewrite
7. **Test pipeline** — extended with Phase 7 (TLS): 8 new checks, total 55/55 passing
8. **Diagrams updated** — tls-architecture.mermaid (new), request-flow.mermaid, component-architecture.mermaid

### Cluster State

- cert-manager running in `cert-manager` namespace (CA issuer chain active)
- Kuadrant operator running in `kuadrant-system` (Authorino, Limitador, TLSPolicy controller)
- TLSPolicy `mcp-gateway-tls` enforced in `gateway-system`
- 4 Gateway listeners: mcp (8080), keycloak (8002), mcp-https (8443), keycloak-https (8445)
- 2 auto-created certificates: `mcp-gateway-mcp-https`, `mcp-gateway-keycloak-https`
- 3 AuthPolicies: gateway-level, per-server (server1, server2)
- 2 test servers with different images and different tools
- CoreDNS patched with hosts plugin for Keycloak resolution

### Authorization Matrix (unchanged from Phase 13)

| User | Group | greet | add_tool | hello_world | auth1234 | set_time |
|------|-------|-------|----------|-------------|----------|----------|
| Alice | developers | allow | deny | deny | deny | allow |
| Bob | ops | deny | allow | deny | allow | allow |
| Carol | both | allow | allow | deny | allow | allow |

### Known Issues

1. **`tools/list` not filtered** — all users see all tools regardless of permissions. Requires broker-side changes.
2. **500 vs 403 on full server deny** — when a user has no allowed tools on a server, the broker returns 500 ("failed to create session") instead of 403. Presentation issue, not security.

---

## Next Steps (user mentioned previously)

1. **Token exchange** — wire up token exchange for real servers like GitHub (Phase 15).
2. **Rate limiting** — Limitador is running but no RateLimitPolicy configured yet.
3. **Multi-tenancy / concurrency** — cut a new branch to explore multiple replicas, concurrent users, serious multi-tenancy.

---

## Key Files

| File | Description |
|------|-------------|
| `scripts/setup.sh` | Full cluster setup from scratch (14 phases) |
| `scripts/test-pipeline.sh` | Full pipeline + auth matrix + TLS verification (55 checks) |
| `scripts/mcp-client.sh` | Interactive MCP client (device auth flow) |
| `infrastructure/cert-manager/issuers.yaml` | CA issuer chain (self-signed → CA cert → CA issuer) |
| `infrastructure/cert-manager/tls-policy.yaml` | TLSPolicy targeting Gateway |
| `infrastructure/auth/authpolicy.yaml` | Gateway-level JWT auth + 401 response |
| `infrastructure/auth/authpolicy-server1.yaml` | Per-server: developers→greet, ops→add_tool |
| `infrastructure/auth/authpolicy-server2.yaml` | Per-server: developers→set_time, ops→auth1234+set_time |
| `infrastructure/keycloak/realm-import.yaml` | Keycloak realm with users, groups, clients |
| `infrastructure/gateway/gateway.yaml` | Gateway with HTTP + HTTPS listeners |
| `docs/diagrams/tls-architecture.mermaid` | TLS certificate chain and termination flow |
