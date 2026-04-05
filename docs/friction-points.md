# MCP Ecosystem Friction Points

Upstream limitations discovered during the MCP ecosystem experimentation (Phases 1-17) that required workarounds, custom code, or manual intervention. Each entry identifies the upstream project, the specific limitation, the workaround applied, and whether the workaround is temporary or permanent.

Excludes Kind-specific infrastructure issues (MetalLB, CoreDNS, NodePort mappings) that do not apply to OpenShift AI deployments. Excludes helper/toy projects (mcp-launcher, mini-oidc) that were experiment scaffolding.

---

## Custom Forks

These required forking upstream code and building custom images.

| # | Project | Limitation | Workaround | Image / Branch | Durability |
|---|---------|-----------|-----------|----------------|------------|
| 1 | mcp-lifecycle-operator | **Reconciler overwrites entire MCPServerRegistration spec** — `reconcileMCPServerRegistration` uses `CreateOrUpdate` with a flat map literal, dropping any externally-added fields including `credentialRef`. Servers requiring auth for broker tool discovery (e.g., GitHub) become unhealthy. | Added annotation support: `mcp.x-k8s.io/gateway-credential-ref` and `mcp.x-k8s.io/gateway-credential-key`. Operator reads annotations from MCPServer CR and propagates to MCPServerRegistration spec. | `quay.io/jrao/mcp-lifecycle-operator:gateway-credential-ref` (branch: `gateway-credential-ref`) | Permanent until upstreamed |
| 2 | mcp-lifecycle-operator | **No automated gateway registration** — operator creates Deployment + Service but nothing creates the HTTPRoute + MCPServerRegistration needed to make the server routable through the gateway. | Added `MCPServerGatewayReconciler` — a separate controller watching for `mcp.x-k8s.io/gateway-ref` annotation on MCPServer CRs. Creates HTTPRoute + MCPServerRegistration automatically. | Same image/branch as above | Permanent until upstreamed |

---

## mcp-gateway

| # | Limitation | Workaround | Severity | Durability |
|---|-----------|-----------|----------|------------|
| 3 | **VirtualMCPServer controller writes to hardcoded `mcp-system` namespace** — ignores the MCPGatewayExtension's actual namespace. In multi-tenant (gateway-per-namespace) deployments, VirtualMCPServer CRs have no effect. | Manually patch the target namespace's `mcp-gateway-config` Secret with `virtualServers` entries via `kubectl`, then restart the broker pod. Must be repeated on every VirtualMCPServer change. | Critical | Temporary — controller needs namespace discovery |
| 4 | **ext_proc EnvoyFilter only generated for HTTP listener (port 8080), not HTTPS (port 8443)** — mcp-controller creates the EnvoyFilter for HTTP only. HTTPS MCP traffic bypasses the Router entirely. | Clone existing EnvoyFilter via `kubectl get`, sed-replace the port number from 8080 to 8443, strip metadata, and apply. | Critical | Temporary — controller should generate for all listeners |
| 5 | **Router unconditionally rewrites `:authority` header on ALL port 8080 traffic** — `internal/mcp-router/request_handlers.go:198` rewrites to `MCPGatewayExternalHostname` regardless of whether the request is MCP traffic. Non-MCP services sharing the gateway get misrouted. | Expose non-MCP services (Keycloak, etc.) on separate ports/services to avoid the Router's ext_proc processing. | Significant | Semi-permanent — architectural, not a bug |
| 6 | **Credential secret label is `mcp.kuadrant.io/secret=true`**, not `mcp.kuadrant.io/credential=true` as documented in the project's own CLAUDE.md. MCPServerRegistration silently fails validation. | Use the correct undocumented label. Discovered through trial and error. | Minor | Permanent — documentation needs correction |
| 7 | **`X-Mcp-Virtualserver` header requires namespaced format** (`namespace/name`, e.g., `team-a/team-a-dev-tools`), not the bare resource name. Not documented — broker logs "virtual server not found" with no hint about the expected format. | Use fully-qualified `namespace/name` in AuthPolicy response rules and client headers. Discovered through broker log debugging. | Minor | Permanent — needs documentation |
| 8 | **Broker returns 500 instead of 403 when entire server is denied** — when a user has no authorized tools on a server, the broker wraps the 403 from Authorino as "failed to create session" and returns 500. Per-tool denials correctly return 403. | Accepted limitation. Not worked around — documented as a presentation issue. | Moderate | Until broker distinguishes auth errors from transport errors |
| 9 | **`tools/list` returns all tools regardless of permissions** — the broker aggregates tools from all servers and returns the full list. The gateway cannot selectively filter items within a JSON-RPC response body. Users see tools they'll get 403 on when calling. | Accepted limitation. Not a security issue (calls are denied), but confusing UX. Requires broker-side filtering based on JWT claims. | Moderate | Until broker implements identity-aware filtering (Auth Phase 2) |

---

## mcp-lifecycle-operator (upstream, pre-fork)

| # | Limitation | Workaround | Severity | Durability |
|---|-----------|-----------|----------|------------|
| 10 | **No awareness of catalog API** — the operator has no integration with the model-registry catalog. The bridge between "what's available" and "deploy it" must be built externally. | Accepted gap. Currently bridged by Gen AI Studio (or launcher toy project in experiment). | Architectural | Until operator or UI provides catalog integration |

---

## model-registry / Catalog Schema

| # | Limitation | Workaround | Severity | Durability |
|---|-----------|-----------|----------|------------|
| 11 | **No field for container command/entrypoint** — `runtimeMetadata` has `defaultPort` and `mcpPath` but nothing for the container binary or arguments. Each MCP server image differs in ENTRYPOINT/CMD conventions. | User must know the image's startup convention out-of-band and manually configure deployment YAML. | Architectural | Until catalog schema adds operational metadata |
| 12 | **No field for security context requirements** — the operator defaults to restricted PSS (`runAsNonRoot: true`). The catalog has no field indicating whether an image requires root or specific UIDs. | User manually adds security context overrides during deployment. | Architectural | Until catalog schema adds security context fields |
| 13 | **No standardized arguments field** — the catalog has no equivalent of the operator's `config.arguments`. Some images need specific flags but this isn't captured in metadata. | User must know per-image flag conventions out-of-band. | Architectural | Until catalog schema or image contract is defined |

These three are symptoms of a deeper issue: **OCI images are opaque, and catalog metadata doesn't carry enough operational context to deploy them reliably.** A complete catalog-to-operator handoff needs: container command/entrypoint, required arguments, security context, and potentially resource requirements. See `docs/changes-tracker.md` "OCI image opacity" section for full analysis.

---

## Kuadrant

| # | Limitation | Workaround | Severity | Durability |
|---|-----------|-----------|----------|------------|
| 14 | **TLSPolicy reconciliation is flaky on first apply** — occasionally fails to enforce after initial creation. | Retry loop (12 iterations x 5s) + Kuadrant operator restart + annotation trigger to force re-reconciliation. Implemented in `scripts/setup.sh`. | Moderate | Temporary — likely fixed in newer Kuadrant versions |
| 15 | **Per-tool CEL predicates don't scale** — inline `patternMatching` with tool name lists in AuthPolicy becomes unmanageable with many tools and groups. Works for experimentation, not for production. | Accepted limitation. Auth Phase 2 design (Keycloak `resource_access` + Authorino wristband JWTs) eliminates per-tool predicates, but isn't available yet. | Architectural | Until Auth Phase 2 is implemented |

---

## Keycloak

| # | Limitation | Workaround | Severity | Durability |
|---|-----------|-----------|----------|------------|
| 16 | **Realm import silently drops `defaultClientScopes` on clients** — the `--import-realm` flag defines scopes correctly but doesn't apply them to the specified client. Vault JWT auth failed because `aud: mcp-gateway` was missing from tokens. | Post-deploy verification via admin API: `GET /admin/realms/mcp/clients/{id}/default-client-scopes`, then `DELETE` from optional scopes and `PUT` as default. Order matters — adding as default without removing from optional is a no-op. | Significant | Semi-permanent — Keycloak behavior |
| 17 | **Keycloak 26 requires firstName/lastName even when "optional"** — password grant returns "Account is not fully set up" without these fields, despite the user profile configuration marking them as optional. | Explicitly set firstName and lastName on all users in realm-import JSON. | Moderate | Permanent — Keycloak 26 behavior |
| 18 | **Realm import is one-shot** — `--import-realm` only works on first Keycloak startup. Subsequent changes require the admin API or UI. | Phases 13+ use Keycloak admin REST API for all group/user/scope modifications. | Moderate | Permanent — Keycloak design |

---

## Env-Var Credential Servers (Cross-Cutting)

| # | Limitation | Workaround | Severity | Durability |
|---|-----------|-----------|----------|------------|
| 19 | **MCP servers that read credentials only from environment variables cannot use per-user gateway credential injection** — the Vault token exchange flow injects credentials via HTTP headers (`Authorization: Bearer`). Servers like the Slack MCP server that only read from `SLACK_TOKEN` env var require a 1:1 deployment-per-user model. The GitHub server avoids this by also accepting headers in HTTP mode. | Accepted architectural limitation. Servers must support HTTP header-based credentials to participate in gateway-level per-user credential exchange. | Architectural | Until MCP server authors adopt header-based credential acceptance |

---

## Summary

| Category | Count | Notes |
|----------|-------|-------|
| **Custom fork required** | 2 | Both in mcp-lifecycle-operator, single branch |
| **Critical upstream gaps** | 2 | mcp-gateway: VirtualMCPServer namespace, EnvoyFilter HTTPS |
| **Architectural gaps** | 6 | Catalog schema (3), CEL scaling, env-var credentials, operator-catalog integration |
| **Accepted limitations** | 3 | `tools/list` filtering, 500 vs 403, env-var servers |
| **Operational gotchas** | 6 | Keycloak (3), TLSPolicy, credential label, VirtualMCPServer header format |

**Single custom image carried**: `quay.io/jrao/mcp-lifecycle-operator:gateway-credential-ref` — addresses both forked items (#1 and #2). This is the only image that would need upstreaming or maintaining for an OpenShift AI migration.

**Deepest architectural gaps**: The catalog schema limitations (#11-13) and the OCI image opacity problem they reflect. These cannot be solved by patches — they require design decisions about where operational metadata lives (in images, in catalog schema, or in a deployment profile layer).
