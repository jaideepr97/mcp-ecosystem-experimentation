# MCP Ecosystem Friction Points

Upstream limitations discovered during the MCP ecosystem experimentation (Phases 1-18) that required workarounds, custom code, or manual intervention. Each entry identifies the upstream project, the specific limitation, the workaround applied, and whether the workaround is temporary or permanent.

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
| 8 | **MCPGatewayExtension only creates HTTPRoute for the targeted listener** — `spec.targetRef.sectionName` targets a single listener, and the controller creates one HTTPRoute for it. When a Gateway has both HTTP and HTTPS listeners on the same hostname, TLS traffic has no route to the broker. Cannot create a second MCPGatewayExtension (one per namespace enforced) and cannot target multiple listeners (field is a single string). [#725](https://github.com/Kuadrant/mcp-gateway/issues/725) | Manually create a second HTTPRoute (`mcp-gateway-route-tls`) targeting the HTTPS listener with the same backend. The auto-managed HTTPRoute reverts if patched directly (ownerReference reconciliation). | Critical | Temporary — controller should create HTTPRoutes for all matching listeners |
| 9 | **MCPServerRegistration controller race condition on initial setup** — when MCPGatewayExtension and MCPServerRegistration controllers reconcile simultaneously during first deploy, the config secret can remain empty despite controller logs showing successful writes. The `resourceVersion` never changes, suggesting writes are silently lost. | Conditional controller restart in `guided-setup.sh`: check if config secret contains `url:` entries, restart `mcp-controller` if empty, then poll until populated (up to 120s). | Significant | Temporary — likely a controller-runtime cache or timing issue |
| 10 | **Helm chart service selector bug** — gives both controller and broker pods `app.kubernetes.io/name: mcp-gateway`. The `mcp-gateway` Service selector matches both pods. Controller doesn't listen on gRPC :50051, causing intermittent ext_proc Connection refused errors through Envoy. Both Service and EnvoyFilter are reconciled by the MCPGatewayExtension controller, reverting on-cluster patches. | Deploy via raw manifests with controller labels `app: mcp-controller` instead of `app.kubernetes.io/name: mcp-gateway`. | Critical | Until Helm chart is fixed |
| 11 | **`privateHost` default assumes Istio gateway class** — MCPGatewayExtension defaults `privateHost` to `<gateway>-istio.<ns>.svc.cluster.local:<port>`. Non-Istio gateway classes (e.g., `data-science-gateway-class`) create services with different naming patterns, causing `no such host` errors on `tools/call`. | Set `privateHost` explicitly in MCPGatewayExtension spec. | Significant | Until controller derives service name from Gateway status |
| 12 | **Backend HTTPRoutes must use separate hostnames for hair-pin routing** — if a backend's HTTPRoute uses the same hostname as the public gateway listener, the ext_proc processes hair-pinned `tools/call` requests twice. On the second pass, the un-prefixed tool name has no match, and the request falls through to the broker which returns `tool not found`. | Backend HTTPRoutes must use `*.mcp.local` hostnames (via a separate gateway listener), not the public hostname. | Significant | Until ext_proc distinguishes hair-pinned requests |
| 13a | **Broker returns 500 instead of 403 when entire server is denied** — when a user has no authorized tools on a server, the broker wraps the 403 from Authorino as "failed to create session" and returns 500. Per-tool denials correctly return 403. | Accepted limitation. Not worked around — documented as a presentation issue. | Moderate | Until broker distinguishes auth errors from transport errors |
| 13b | **`tools/list` returns all tools regardless of permissions** — the broker aggregates tools from all servers and returns the full list. The gateway cannot selectively filter items within a JSON-RPC response body. Users see tools they'll get 403 on when calling. | VirtualMCPServers provide static role-based filtering (role → fixed tool list). Not a security issue (calls are still denied), but confusing UX when not using VirtualMCPServers. | Moderate | Partially addressed by VirtualMCPServers |
| 13c | **No dynamic per-user tool filtering** — VirtualMCPServers are static: a role maps to a fixed tool list via a CEL expression in AuthPolicy. There is no way to dynamically compose a tool list based on per-user state (e.g., whether a user has a GitHub PAT in Vault). A user with credentials for an additional server sees the same tools as users without those credentials, unless a separate VirtualMCPServer and role are pre-created for every combination. This doesn't scale — N servers produce 2^N possible VirtualMCPServer combinations. | No workaround. Would require the broker to query a credential store (Vault) at `tools/list` time and dynamically filter based on which servers the authenticated user has credentials for. Alternatively, the VirtualMCPServer selection logic could be extended to support metadata evaluators (e.g., Authorino queries Vault, injects available-server list into headers, broker uses that instead of a static VirtualMCPServer). | Architectural | Until broker supports credential-aware dynamic tool filtering |

---

## mcp-lifecycle-operator (upstream, pre-fork)

| # | Limitation | Workaround | Severity | Durability |
|---|-----------|-----------|----------|------------|
| 15 | **No awareness of catalog API** — the operator has no integration with the model-registry catalog. The bridge between "what's available" and "deploy it" must be built externally. | Accepted gap. Currently bridged by Gen AI Studio (or launcher toy project in experiment). | Architectural | Until operator or UI provides catalog integration |

---

## model-registry / Catalog Schema

| # | Limitation | Workaround | Severity | Durability |
|---|-----------|-----------|----------|------------|
| 16 | **No field for container command/entrypoint** — `runtimeMetadata` has `defaultPort` and `mcpPath` but nothing for the container binary or arguments. Each MCP server image differs in ENTRYPOINT/CMD conventions. | User must know the image's startup convention out-of-band and manually configure deployment YAML. | Architectural | Until catalog schema adds operational metadata |
| 17 | **No field for security context requirements** — the operator defaults to restricted PSS (`runAsNonRoot: true`). The catalog has no field indicating whether an image requires root or specific UIDs. | User manually adds security context overrides during deployment. | Architectural | Until catalog schema adds security context fields |
| 18 | **No standardized arguments field** — the catalog has no equivalent of the operator's `config.arguments`. Some images need specific flags but this isn't captured in metadata. | User must know per-image flag conventions out-of-band. | Architectural | Until catalog schema or image contract is defined |

These three are symptoms of a deeper issue: **OCI images are opaque, and catalog metadata doesn't carry enough operational context to deploy them reliably.** A complete catalog-to-operator handoff needs: container command/entrypoint, required arguments, security context, and potentially resource requirements. See `docs/changes-tracker.md` "OCI image opacity" section for full analysis.

---

## Kuadrant

| # | Limitation | Workaround | Severity | Durability |
|---|-----------|-----------|----------|------------|
| 19 | **TLSPolicy reconciliation is flaky on first apply** — occasionally fails to enforce after initial creation. | Retry loop (12 iterations x 5s) + Kuadrant operator restart + annotation trigger to force re-reconciliation. Implemented in `scripts/setup.sh`. | Moderate | Temporary — likely fixed in newer Kuadrant versions |
| 20 | **Per-tool CEL predicates don't scale** — inline `patternMatching` with tool name lists in AuthPolicy becomes unmanageable with many tools and groups. Works for experimentation, not for production. | Accepted limitation. Auth Phase 2 design (Keycloak `resource_access` + Authorino wristband JWTs) eliminates per-tool predicates, but isn't available yet. | Architectural | Until Auth Phase 2 is implemented |

---

## Keycloak

| # | Limitation | Workaround | Severity | Durability |
|---|-----------|-----------|----------|------------|
| 21 | **Realm import silently drops `defaultClientScopes` on clients** — the `--import-realm` flag defines scopes correctly but doesn't apply them to the specified client. Vault JWT auth failed because `aud: mcp-gateway` was missing from tokens. | Post-deploy verification via admin API: `GET /admin/realms/mcp/clients/{id}/default-client-scopes`, then `DELETE` from optional scopes and `PUT` as default. Order matters — adding as default without removing from optional is a no-op. | Significant | Semi-permanent — Keycloak behavior |
| 22 | **Keycloak 26 requires firstName/lastName even when "optional"** — password grant returns "Account is not fully set up" without these fields, despite the user profile configuration marking them as optional. | Explicitly set firstName and lastName on all users in realm-import JSON. | Moderate | Permanent — Keycloak 26 behavior |
| 23 | **Realm import is one-shot** — `--import-realm` only works on first Keycloak startup. Subsequent changes require the admin API or UI. | Phases 13+ use Keycloak admin REST API for all group/user/scope modifications. | Moderate | Permanent — Keycloak design |

---

## Kuadrant / Authorino Metadata Evaluators

| # | Limitation | Workaround | Severity | Durability |
|---|-----------|-----------|----------|------------|
| 25 | **`auth.identity.jwt` does not exist in CEL context** — the identity object contains only decoded JWT claims. There is no built-in way to access the raw JWT token string from within a metadata evaluator's CEL expression. | Use `request.headers.authorization.split(' ')[1]` to extract the raw JWT from the `Authorization: Bearer <token>` header. Two other approaches failed first: gjson `@extract` selector extracted "Bearer" (wrong position), and `auth.identity.jwt` threw a key-not-found error. | Moderate | Until Authorino exposes the raw token in CEL context or documents the correct approach |
| 26 | **Hyphenated metadata key names cause CEL parse errors** — metadata keys like `vault-token` are treated as minus operators when referenced in CEL expressions (`auth.metadata.vault-token` → `vault minus token`). | Use underscored key names (`vault_token`) for all metadata evaluator keys. Applies to any key referenced in subsequent CEL expressions (other metadata evaluators, authorization predicates, response rules). | Minor | Permanent — CEL language design, not a bug |
| 27 | **`urlExpression` and `url` are separate top-level fields, not nested** — attempting `url: { expression: ... }` or `url.expression` fails with CRD validation errors. The two fields serve different purposes: `url` accepts a static string with optional gjson selectors, `urlExpression` accepts a CEL string. | Use the top-level `urlExpression:` field for dynamic URLs. Discovered through CRD validation errors — the CRD schema is correct but the distinction is not obvious from examples. | Minor | Permanent — CRD schema documentation gap |
| 28 | **`groups` claim requires explicit scope in token request** — AuthPolicy CEL predicates referencing `auth.identity.groups` fail silently with "no such key: groups" if the Keycloak token was issued without `scope=openid groups`. The error message gives no hint about the missing scope. | Include `scope=openid groups` in all token requests (password grant, device flow, etc.). Ensure Keycloak's client has `groups` in its default scopes. | Moderate | Permanent — Keycloak/OIDC design; Authorino could improve the error message |

---

## Env-Var Credential Servers (Cross-Cutting)

| # | Limitation | Workaround | Severity | Durability |
|---|-----------|-----------|----------|------------|
| 24 | **MCP servers that read credentials only from environment variables cannot use per-user gateway credential injection** — the Vault token exchange flow injects credentials via HTTP headers (`Authorization: Bearer`). Servers like the Slack MCP server that only read from `SLACK_TOKEN` env var require a 1:1 deployment-per-user model. The GitHub server avoids this by also accepting headers in HTTP mode. | Accepted architectural limitation. Servers must support HTTP header-based credentials to participate in gateway-level per-user credential exchange. | Architectural | Until MCP server authors adopt header-based credential acceptance |

---

## OpenShift AI / MCP Lifecycle Operator (PR #16)

| # | Limitation | Workaround | Severity | Durability |
|---|-----------|-----------|----------|------------|
| 29 | **PR #16 install.yaml ships mismatched image and CRD** — the CRD is generated from `release-0.1` (has `.status.phase`, no `.status.observedGeneration`) but the controller image is `mcp-lifecycle-operator-main:latest` (expects `observedGeneration`, never sets `phase`). This causes two failures: (1) operator crash-loops on SSA status updates because `observedGeneration` isn't in the CRD schema, and (2) `.status.phase` is never set, so the dashboard catalog shows "Pending" permanently. Needs a Konflux build of `release-0.1`. | Built and pushed `quay.io/jrao/mcp-lifecycle-operator:release-0.1` from the `openshift/release-0.1` branch. Patched the CRD to add `observedGeneration` to unblock the `main` image before discovering the root cause. | Critical | Until a Konflux build from `release-0.1` is available |
| 30 | **Dashboard reads `.status.phase` for MCPServer status display** — the BFF extracts `phase` from the MCPServer CR and the frontend maps it to Available/Unavailable/Pending. The upstream operator (`main`) has moved to Kubernetes-style `.status.conditions` (`Accepted`, `Ready`) and dropped `phase`. The dashboard needs to read conditions as well for forward compatibility. | None — currently requires the `release-0.1` operator which still sets `phase`. | Moderate | Until dashboard reads `.status.conditions` alongside or instead of `.status.phase` |

---

## RHOAI Gen AI Studio / LlamaStack

| # | Limitation | Workaround | Severity | Durability |
|---|-----------|-----------|----------|------------|
| 31 | **Playground registers model_id from InferenceService name, not vLLM's `--served-model-name`** — when creating a Playground, RHOAI uses the InferenceService metadata name (e.g., `vllm-120b`) as the LlamaStack `model_id`. If vLLM is configured with a different `--served-model-name` (e.g., `gpt-oss-120b`), inference requests fail because vLLM rejects the unknown model name. The LlamaStack operator owns the ConfigMap (`ownerReferences`) but does not continuously reconcile it — manual edits persist. | Two options: (a) edit the LlamaStack ConfigMap `model_id` to match `--served-model-name` and restart the LlamaStack pod (seconds), or (b) patch the ServingRuntime `--served-model-name` to match the InferenceService name (requires full model reload, ~7 min for 120B). Option (b) also requires adding `--enable-auto-tool-choice --tool-call-parser openai` for tool calling. | Significant | Until RHOAI reads `--served-model-name` from the ServingRuntime args or vLLM's `/v1/models` endpoint |
| 32 | **Default `--max-model-len 8192` too small for MCP tool calling** — the Playground sends all registered MCP tools in every prompt, inflating it to ~20K tokens. With a 8192 context window, LlamaStack computes a negative `max_tokens` and vLLM rejects the request with `max_tokens must be at least 1`. Reasoning models (e.g., gpt-oss-120b) exacerbate this by consuming additional tokens for chain-of-thought. | Increase `--max-model-len` on the ServingRuntime (e.g., 32768). The model must support the larger context (gpt-oss-120b supports 131K). Requires a full vLLM pod restart and model reload. Also increase `VLLM_MAX_TOKENS` env var on the LlamaStackDistribution CR to match. | Significant | Until RHOAI sets appropriate defaults based on model capabilities |

---

## Summary

| Category | Count | Notes |
|----------|-------|-------|
| **Custom fork required** | 2 | Both in mcp-lifecycle-operator, single branch |
| **Critical upstream gaps** | 5 | mcp-gateway: VirtualMCPServer namespace, EnvoyFilter HTTPS, HTTPRoute HTTPS (#725), Helm service selector; lifecycle operator PR #16 image/CRD mismatch |
| **Significant upstream gaps** | 3 | mcp-gateway: MCPServerRegistration race, privateHost default, hair-pin hostname collision |
| **Architectural gaps** | 7 | Catalog schema (3), CEL scaling, env-var credentials, operator-catalog integration, dynamic per-user tool filtering |
| **Accepted limitations** | 3 | `tools/list` static filtering, 500 vs 403, env-var servers |
| **Operational gotchas** | 10 | Keycloak (3), TLSPolicy, credential label, VirtualMCPServer header format, metadata evaluator CEL (4) |
| **OpenShift AI integration** | 4 | Lifecycle operator image/CRD mismatch (#29), dashboard phase vs conditions (#30), Playground model_id mismatch (#31), context window too small for MCP (#32) |

**Custom images carried**: `quay.io/jrao/mcp-lifecycle-operator:gateway-credential-ref` (Kind cluster, addresses #1 and #2) and `quay.io/jrao/mcp-lifecycle-operator:release-0.1` (OpenShift AI, addresses #29).

**Deepest architectural gaps**: The catalog schema limitations (#16-18) and the OCI image opacity problem they reflect. These cannot be solved by patches — they require design decisions about where operational metadata lives (in images, in catalog schema, or in a deployment profile layer).
