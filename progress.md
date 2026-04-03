# Session Handoff — Current State

**Date**: 2026-04-03
**Last action**: Reorganized repo, updated test-server2 to distinct image, added automated auth test matrix

---

## Current State Summary

Fully automated MCP ecosystem with per-user, per-tool authorization. Setup script deploys everything from scratch; test matrix verifies all authorization rules pass (15/15).

### What changed since Phase 13

1. **test-server2 now uses a different image** — `ghcr.io/kuadrant/mcp-gateway/test-server2:latest` (was using test-server1 image). Different tools: hello_world, time, headers, auth1234, slow, set_time.
2. **AuthPolicies updated for unique tools** — only unique tools per server are used in policies to avoid confusion.
3. **Direct access grant enabled** on `mcp-cli` Keycloak client — allows non-interactive token acquisition for automated tests.
4. **Automated test matrix script** — `scripts/test-auth-matrix.sh` authenticates as all 3 users via password grant, runs 15 tool calls, asserts allow/deny.
5. **Repo reorganized** — all manifests under `infrastructure/`, all scripts under `scripts/`.

### Cluster State

- Kuadrant operator running in `kuadrant-system` (Authorino, Limitador, operators)
- 3 AuthPolicies: gateway-level (`mcp-auth-policy`), per-server (`server1-auth-policy`, `server2-auth-policy`)
- 2 test servers with different images and different tools
- CoreDNS patched with hosts plugin for Keycloak resolution

### Authorization Matrix (current)

Policies use only the unique tools from each server:

Server1 (test-server1 image — tools: greet, time, slow, headers, add_tool):
- developers: greet
- ops: add_tool

Server2 (test-server2 image — tools: hello_world, time, headers, auth1234, slow, set_time):
- developers: set_time
- ops: auth1234, set_time

hello_world: not in any policy (denied for everyone — tests "existence != access")

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

1. **TLS** — cert-manager + Kuadrant TLSPolicy.
2. **Token exchange** — wire up token exchange for real servers like GitHub.
3. **Rate limiting** — Limitador is running but no RateLimitPolicy configured yet.

---

## Key Files

| File | Description |
|------|-------------|
| `scripts/setup.sh` | Full cluster setup from scratch |
| `scripts/test-auth-matrix.sh` | Automated 15-case auth verification |
| `scripts/mcp-client.sh` | Interactive MCP client (device auth flow) |
| `infrastructure/auth/authpolicy.yaml` | Gateway-level JWT auth + 401 response |
| `infrastructure/auth/authpolicy-server1.yaml` | Per-server: developers→greet, ops→add_tool |
| `infrastructure/auth/authpolicy-server2.yaml` | Per-server: developers→set_time, ops→auth1234+set_time |
| `infrastructure/keycloak/realm-import.yaml` | Keycloak realm with users, groups, clients |
| `infrastructure/test-servers/test-server1.yaml` | MCPServer CR (test-server1 image) |
| `infrastructure/test-servers/test-server2.yaml` | MCPServer CR (test-server2 image) |
