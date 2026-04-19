# Session Handoff — Current State

**Date**: 2026-04-17
**Last action**: Auth + OpenShift MCP server deployed. Full end-to-end: Playground UI → (Bearer JWT) → Llama Stack → MCP Gateway → (Authorino JWT validation + role-based authorization) → OpenShift MCP Server → Kubernetes API. Role-based access verified: `mcp-admin` can use OpenShift tools, `mcp-user` is restricted to test tools only.

---

## Current State Summary

Kind cluster work (Phases 1-18) is preserved on the `advanced` branch. Main branch is focused on OpenShift AI integration — building the end-to-end flow: **Playground UI → Llama Stack → MCP Gateway → MCP Servers**.

Cluster: `agentic-mcp.jolf.p3.openshiftapps.com` (ROSA, OpenShift 4.21.6, RHOAI 3.4.0-ea.2)

### What was completed (April 15 session)

1. **Repo reorganization** — Committed Phase 18 housekeeping, created `advanced` branch (pushed to remote). Moved Kind infra to `infrastructure/kind/`, created `infrastructure/openshift-ai/` for new work.

2. **Cluster assessment** — Catalogued existing deployments: RHOAI 3.4-ea.2, Gen AI Studio enabled, Gateway API CRDs, vLLM 20B+120B in gpt-oss, Llama Stack v6 instances, 3 GPU nodes (4x L40S, 1x L40S, 1x L4).

3. **Baseline documentation** — Created `docs/openshift-ai-prerequisites.md` and 7 YAMLs in `infrastructure/openshift-ai/` covering the full stack from operator subscription to Llama Stack distribution.

4. **vLLM tool calling enabled** — Discovered model uses `openai` parser (not hermes). Patched ServingRuntime and Deployment directly (ServingRuntime patches don't propagate in RawDeployment mode). Scaled 0→1 to avoid GPU deadlock. Verified: `tool_calls` array populated, `finish_reason: "tool_calls"`.

5. **Llama Stack deployed in test-jd** — ConfigMap with remote::vllm inference + inline::rag-runtime tool_runtime (required by agents despite API being deprecated). Created route manually (`exposeRoute: true` didn't work). Responses API verified end-to-end with tool calling.

6. **Playground UI activated** — Discovered undocumented `opendatahub.io/genai-asset: "true"` label (found by grepping dashboard JS). KServe webhook bug rejected all label patches — had to delete/recreate InferenceService. "Create playground" button now appears.

7. **Playground created but blocked** — Playground creates its own Llama Stack pod. Model name mismatch: playground registers model as `vllm-20b` (InferenceService name) but vLLM serves as `gpt-oss-20b` (`--served-model-name`). `provider_model_id` ConfigMap fix did not resolve it.

### What was completed (April 15-16, between sessions)

8. **MCP Gateway v0.5.1 deployed in test-jd** (superseded) — Manual deployment of kagenti MCP Gateway with `data-science-gateway-class`. Worked but had routing issues (no OpenShift Route, exposed via raw AWS ELB only).

### What was completed (April 17 session)

9. **Investigated OpenShift routing gap** — Discovered `data-science-gateway-class` uses Istio which defaults to LoadBalancer. The platform `data-science-gateway` in `openshift-ingress` uses a ConfigMap (`infrastructure.parametersRef`) to force ClusterIP, managed by the RHOAI `GatewayConfig` CR — a platform-level singleton, not available for user namespaces.

10. **Found upstream OpenShift install path** — `github.com/Kuadrant/mcp-gateway/config/openshift/` contains `deploy_openshift.sh` + Helm charts that handle OpenShift-specific setup: `openshift-default` GatewayClass + `mcp-gateway-ingress` chart for Route creation.

11. **MCP Gateway v0.6.0 installed via OLM** — CatalogSource in `openshift-marketplace`, Subscription in `mcp-system`. Controller runs cluster-wide. CRDs upgraded from `mcp.kagenti.com` (v0.5.1) to `mcp.kuadrant.io` (v0.6.0).

12. **`openshift-default` GatewayClass created** — Same `openshift.io/gateway-controller/v1` controller; on this cluster with Service Mesh, it's handled by Istio (creates Envoy proxy), so EnvoyFilter/ext_proc works. On clusters without Service Mesh, this would use HAProxy and ext_proc would not work.

13. **MCP Gateway instance deployed in `mcp-upstream-test`** — Via `oci://ghcr.io/kuadrant/charts/mcp-gateway` (v0.6.0) Helm chart. OpenShift Route created via `mcp-gateway-ingress` chart. End-to-end verified: initialize → tools/list (5 tools) → tools/call (`"Hi OpenShift"`).

14. **test-jd namespace deleted** — Old v0.5.1 setup replaced by `mcp-upstream-test`.

15. **End-to-end flow completed** — Created `gen-ai-aa-mcp-servers` ConfigMap in `redhat-ods-applications` pointing to the MCP Gateway. Playground UI immediately showed it as available. The dashboard automatically wires the ConfigMap URL to Llama Stack's `remote::model-context-protocol` tool_runtime provider — no Llama Stack config changes needed. Tool calling verified through the full chain: Playground → Llama Stack (0.6.0.1+rhai0) → MCP Gateway (v0.6.0) → Test MCP Server.

16. **Keycloak (RHBK) deployed** — RHBK operator v26.4.11 via OLM in `keycloak` namespace. Postgres with gp3-csi PVC. Keycloak instance at `https://keycloak.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com`. Realm `mcp-gateway` with 2 clients (`mcp-gateway` confidential, `mcp-playground` public), 2 roles (`mcp-user`, `mcp-admin`), 2 users (`mcp-user1`, `mcp-admin1`).

17. **Kuadrant CR deployed** — Created in `openshift-operators`. Authorino (JWT validation) and Limitador (rate limiting) running.

18. **Gateway-level AuthPolicy** — JWT validation on the `mcp` listener. All requests require a valid JWT from the Keycloak `mcp-gateway` realm. Unauthenticated → 401.

19. **OpenShift MCP server deployed** — `openshift-mcp-server` in `mcp-upstream-test`. Read-only, `core` + `config` toolsets, `view` ClusterRole. 14 tools registered with `openshift_` prefix. Gateway now serves 19 tools total (14 openshift + 5 test).

20. **Per-server authorization** — HTTPRoute-level AuthPolicy requires `mcp-admin` role for OpenShift MCP server. `mcp-admin1` gets full access, `mcp-user1` is blocked from OpenShift tools but can use test tools.

21. **Playground auth verified** — Playground UI has a token input field for MCP server auth. With `mcp-admin1` token: full end-to-end working (Playground → Llama Stack → MCP Gateway → OpenShift MCP Server → Kubernetes API). Successfully queried live cluster state through the Playground.

### Cluster State (OpenShift AI) — as of 2026-04-17 (end of session)

| Component | Namespace | Status |
|-----------|-----------|--------|
| vLLM 20B (with tool calling) | gpt-oss | Running, `openai` tool parser, IngressReady |
| vLLM 120B | gpt-oss | Running (no tool calling yet) |
| Llama Stack v6-20b | gpt-oss | Running (original, no MCP) |
| Llama Stack v6-120b | gpt-oss | Running (original, no MCP) |
| Playground (lsd-genai-playground) | gpt-oss | Running — full end-to-end with MCP + auth |
| `gen-ai-aa-mcp-servers` ConfigMap | redhat-ods-applications | MCP-Gateway-Test → gateway |
| MCP Gateway Controller (v0.6.0, OLM) | mcp-system | Running, cluster-scoped |
| MCP Gateway Broker (v0.6.0) | mcp-upstream-test | Running, with EnvoyFilter ext_proc |
| MCP Gateway Envoy (`openshift-default`) | mcp-upstream-test | Running, LoadBalancer + OpenShift Route |
| MCPGatewayExtension | mcp-upstream-test | Ready |
| MCPServerRegistration (test-mcp-server) | mcp-upstream-test | Ready, prefix `test_`, 5 tools |
| MCPServerRegistration (openshift-mcp-server) | mcp-upstream-test | Ready, prefix `openshift_`, 14 tools |
| Test MCP Server | mcp-upstream-test | Running (kuadrant test-server1) |
| OpenShift MCP Server | mcp-upstream-test | Running, read-only, `core` + `config` toolsets |
| GatewayClass `openshift-default` | cluster-scoped | Accepted, handled by Istio controller |
| AuthPolicy (mcp-gateway-auth) | mcp-upstream-test | Enforced — JWT validation on `mcp` listener |
| AuthPolicy (openshift-mcp-admin-only) | mcp-upstream-test | Enforced — `mcp-admin` role required |
| Keycloak (RHBK v26.4.11) | keycloak | Running, Postgres PVC, realm `mcp-gateway` |
| Kuadrant CR | openshift-operators | Authorino + Limitador running |

### Kind Cluster State (preserved on `advanced` branch)

- **Shared control plane**: mcp-system (controller), keycloak, kuadrant-system (Authorino), vault, catalog-system, cert-manager, istio-system
- **team-a namespace (Phases 16-18)**: Full stack with namespace isolation, VirtualMCPServers, AuthPolicies, Vault credential injection
- Authorization matrix: 14/14 checks passing
- Credential injection: verified for dev1 and lead1

---

## Known Issues (ongoing)

### OpenShift AI

1. **Playground model name mismatch** — Playground registers model as `vllm-20b` (InferenceService name) but vLLM serves as `gpt-oss-20b` (`--served-model-name`). `provider_model_id` ConfigMap fix didn't resolve it.
2. **KServe webhook bug** — Rejects any InferenceService update (even label patches) with "deploymentMode cannot be changed" error. Workaround: delete and recreate the CR.
3. **ServingRuntime changes don't propagate** — In KServe RawDeployment mode, patching the ServingRuntime doesn't update the Deployment. Must patch the Deployment directly.
4. **GPU deadlock on rollout** — RollingUpdate strategy + single GPU = new pod can't schedule. Scale to 0 first, then back to 1.
5. **tool_runtime still required** — Llama Stack 0.6.1 agents provider has hard dependency on tool_runtime even though API is deprecated.
6. **LlamaStackDistribution route not created** — `exposeRoute: true` didn't work. Manual `oc create route edge` needed.
7. **genai-asset label undocumented** — `opendatahub.io/genai-asset: "true"` required for Playground visibility, not in docs.

### MCP Gateway Auth

8. **`tools/list` ignores authorization** — Broker serves tool list from cache, does not filter by user identity/roles. All 19 tools visible to all authenticated users regardless of per-server AuthPolicies.
9. **Per-server auth failures return "network error"** — When HTTPRoute-level AuthPolicy blocks a `tools/call` (Authorino 403), broker misinterprets as transport error ("likely a legacy SSE server"), returns EOF. Playground shows generic "network error" instead of "access denied."
10. **`mcpCatalog` feature flag missing** — Not in OdhDashboardConfig CRD schema for RHOAI 3.4.0-ea.2. Requires newer build.
11. **Keycloak token lifetime too short** — Default 5-minute access token TTL makes manual Playground testing cumbersome.
12. **Broker logs noisy "tool id is missing" warnings** — OpenShift MCP server tools lack `_meta.id` fields. Doesn't block registration but produces repeated log noise.

### Kind Cluster (on `advanced` branch)

See [docs/friction-points.md](docs/friction-points.md) for the full list (23 entries).

---

## Next Steps — OpenShift AI End-to-End

Goal: **Playground UI → Llama Stack → MCP Gateway → MCP Servers**

1. ~~**Deploy MCP Gateway controller + CRDs** on the cluster~~ — Done (v0.6.0 via OLM in mcp-system)
2. ~~**Deploy MCP server(s)** behind the gateway~~ — Done (test-mcp-server + openshift-mcp-server in mcp-upstream-test)
3. ~~**Fix playground model name mismatch**~~ — Done (previous session)
4. ~~**Wire Llama Stack → MCP Gateway**~~ — Done (automatic via `gen-ai-aa-mcp-servers` ConfigMap)
5. ~~**Create `gen-ai-aa-mcp-servers` ConfigMap**~~ — Done (in `redhat-ods-applications`)
6. ~~**Test end-to-end flow**~~ — Done (Playground → Llama Stack → MCP Gateway → MCP Server ✓)
7. ~~**Set up Keycloak + auth**~~ — Done (RHBK + realm + AuthPolicies)
8. ~~**Deploy OpenShift MCP server**~~ — Done (14 tools, admin-only access)
9. ~~**Test auth end-to-end through Playground**~~ — Done (admin works, user blocked correctly)
10. **Explore MCPVirtualServer for identity-based tool filtering** — Needed to fix tool visibility issue
11. **Increase Keycloak token lifetime** — For dev/test usability
12. **Upgrade RHOAI** — To a build that supports `mcpCatalog` feature flag

### Kind Cluster Phases (on `advanced` branch, deferred)

| Phase | Description | Status |
|-------|-------------|--------|
| 16 | Namespace-isolated gateway (`team-a`) | Done |
| 17 | VirtualMCPServers + AuthPolicies (3 groups, 5 users, 14/14 auth matrix) | Done |
| 18 | Vault credential patterns (team-level + per-user injection) | Done |
| 19 | Multi-Namespace Expansion | Deferred |
| 20 | Rate Limiting | Deferred |

---

## Key Files

### OpenShift AI
| File | Description |
|------|-------------|
| `docs/openshift-ai-session-log.md` | Session log of all OpenShift AI actions and discoveries |
| `docs/openshift-ai-prerequisites.md` | Baseline setup guide for fresh cluster |
| `infrastructure/openshift-ai/01-rhoai-catalogsource.yaml` | EA catalog source |
| `infrastructure/openshift-ai/02-rhoai-subscription.yaml` | RHOAI operator subscription |
| `infrastructure/openshift-ai/03-datasciencecluster.yaml` | DSC with required components |
| `infrastructure/openshift-ai/04-vllm-servingruntime.yaml` | vLLM runtime with tool-calling |
| `infrastructure/openshift-ai/05-inferenceservice.yaml` | Model deployment |
| `infrastructure/openshift-ai/06-llamastack-config.yaml` | Llama Stack config ConfigMap |
| `infrastructure/openshift-ai/07-llamastack-distribution.yaml` | Llama Stack CR |

### Kind Cluster (on `advanced` branch)
| File | Description |
|------|-------------|
| `scripts/setup.sh` | Full cluster setup (Phases 1-18) |
| `scripts/guided-setup.sh` | Interactive guided setup (6 phases) |
| `scripts/test-pipeline.sh` | Full pipeline tests (10 phases) |
| `docs/friction-points.md` | 23 upstream friction points |
| `docs/experimentation.md` | Full chronological narrative (Phases 1-18) |

## Key Endpoints

| Endpoint | Description |
|----------|-------------|
| `https://vllm-20b-gpt-oss.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com` | vLLM 20B (tool calling) |
| `https://mcp-upstream.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com/mcp` | MCP Gateway (mcp-upstream-test, via OpenShift Route, JWT required) |
| `https://keycloak.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com` | Keycloak admin console + OIDC endpoints (realm: `mcp-gateway`) |
