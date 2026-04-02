# Session Handoff — Phase 13 Complete

**Date**: 2026-04-02
**Last action**: Phase 13 documentation complete, all files updated

---

## Phase 13 Summary

Kuadrant AuthPolicy replaces all Istio auth workarounds. Per-group, per-tool, cross-server authorization is fully working at the gateway level with no code changes to mcp-gateway.

### What was accomplished

1. **Kuadrant operator installed** — Authorino, Limitador, operators in `kuadrant-system`
2. **Gateway-level AuthPolicy** — replaces RequestAuthentication + AuthorizationPolicy + Lua EnvoyFilter
3. **CoreDNS patch** — Authorino reaches Keycloak via gateway LB IP
4. **Filter chain order verified** — ext_proc (Router) runs BEFORE Kuadrant Wasm plugin (auth)
5. **Server-level auth** — per-HTTPRoute AuthPolicies targeting auto-created HTTPRoutes
6. **Tool-level auth** — CEL predicates checking `x-mcp-toolname` header + group claims
7. **Cross-server per-group per-tool auth** — 30/30 test cases passing
8. **Old Istio auth files deleted** — request-authentication.yaml, authorization-policy.yaml, envoyfilter-401.yaml
9. **Second test server deployed** — test-server2 (same image, different name/prefix)
10. **All documentation updated** — experimentation.md, changes-tracker.md, diagrams, README

### Cluster State

- Kuadrant operator running in `kuadrant-system` (Authorino, Limitador, operators)
- 3 AuthPolicies: gateway-level (`mcp-auth-policy`), per-server (`server1-auth-policy`, `server2-auth-policy`)
- 2 test servers: test-server1 (prefix `test_server1_`), test-server2 (prefix `test_server2_`)
- Old Istio auth resources deleted from cluster and repo
- CoreDNS patched with hosts plugin for Keycloak resolution
- Authorino debug logging enabled (was set during header name debugging)

### Authorization Matrix (current)

Server1 AuthPolicy:
- developers: greet, time
- ops: time, headers

Server2 AuthPolicy:
- developers: slow
- ops: headers, add_tool

| User | Group | Server1 | Server2 |
|------|-------|---------|---------|
| Alice | developers | greet, time | slow |
| Bob | ops | time, headers | headers, add_tool |
| Carol | both | greet, time, headers | slow, headers, add_tool |

### Known Issues

1. **`tools/list` not filtered** — all users see all 10 tools regardless of permissions. Requires broker-side changes.
2. **500 vs 403 on full server deny** — when a user has NO allowed tools on a server, the broker returns 500 ("failed to create session") instead of 403. Presentation issue, not security.
3. **Authorino debug logging still on** — set during header name debugging. Consider reverting: `kubectl set env deployment/authorino -n kuadrant-system LOG_LEVEL=info`

---

## Next Steps (user mentioned)

1. **TLS** — user expressed interest. Requires cert-manager + Kuadrant TLSPolicy.
2. **Token exchange** — user mentioned wanting to wire up token exchange to use "real servers like GitHub."
3. **Rate limiting** — Limitador is running but no RateLimitPolicy configured yet.

---

## Key Files (Phase 13)

| File | Status | Description |
|------|--------|-------------|
| `auth/authpolicy.yaml` | Current | Gateway-level JWT auth + 401 response |
| `auth/authpolicy-server1.yaml` | Current | Per-server: developers + tool ACLs |
| `auth/authpolicy-server2.yaml` | Current | Per-server: ops + tool ACLs |
| `auth/request-authentication.yaml` | DELETED | Replaced by AuthPolicy |
| `auth/authorization-policy.yaml` | DELETED | Replaced by AuthPolicy |
| `auth/envoyfilter-401.yaml` | DELETED | Replaced by AuthPolicy |
| `examples/test-server2.yaml` | NEW | Second test server for multi-server auth |
| `docs/experimentation.md` | Updated | Phase 13 section added |
| `docs/changes-tracker.md` | Updated | Kuadrant + auth findings |
| `docs/diagrams/component-architecture.mermaid` | Updated | kuadrant-system + AuthPolicies |
| `docs/diagrams/request-flow.mermaid` | Updated | Wasm plugin auth flow |
| `README.md` | Updated | Kuadrant step + auth setup |
