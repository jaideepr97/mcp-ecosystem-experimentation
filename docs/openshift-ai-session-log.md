# OpenShift AI Session Log

**Date**: 2026-04-15
**Cluster**: `agentic-mcp.jolf.p3.openshiftapps.com` (ROSA, OpenShift 4.21.6)
**RHOAI**: 3.4.0-ea.2
**Goal**: End-to-end Gen AI Playground → Llama Stack → MCP Gateway → MCP Servers

---

## Actions Taken

### 1. Repo reorganization

- Committed outstanding housekeeping changes from last session (friction-points, test-pipeline, guided-setup)
- Created `advanced` branch from current HEAD and pushed to remote — preserves all Kind/Phase 18 work
- Moved all Kind cluster infrastructure from `infrastructure/` to `infrastructure/kind/`
- Created `infrastructure/openshift-ai/` for new OpenShift AI work
- Updated all path references in scripts and docs

### 2. Cluster assessment

Identified what's already deployed:
- **RHOAI 3.4-ea.2** with Llama Stack Operator, KServe, Dashboard, MLflow all `Managed`
- **Gen AI Studio** enabled (`genAiStudio: true` in dashboard config)
- **Gateway API CRDs** installed (via Service Mesh 3), `data-science-gateway-class` available
- **vLLM 20B + 120B** serving in `gpt-oss` namespace via KServe `RawDeployment`
- **Llama Stack v6** (20B + 120B) running in `gpt-oss`, image `distribution-starter:0.6.1`
- **3 GPU nodes**: g6e.12xlarge (4x L40S), g6e.4xlarge (1x L40S), g6.4xlarge (1x L4) — all GPUs in use

Identified what's missing for end-to-end flow:
1. vLLM tool-calling args
2. MCP Gateway controller + CRDs
3. MCP server(s)
4. `gen-ai-aa-mcp-servers` ConfigMap for Playground UI
5. Llama Stack MCP tool_runtime provider
6. Playground instance

### 3. Documented baseline prerequisites

Created `docs/openshift-ai-prerequisites.md` and 7 YAMLs in `infrastructure/openshift-ai/`:
- `01-rhoai-catalogsource.yaml` — EA catalog source
- `02-rhoai-subscription.yaml` — RHOAI operator subscription
- `03-datasciencecluster.yaml` — DSC with required components
- `04-vllm-servingruntime.yaml` — vLLM runtime with tool-calling
- `05-inferenceservice.yaml` — Model deployment
- `06-llamastack-config.yaml` — Llama Stack config ConfigMap
- `07-llamastack-distribution.yaml` — Llama Stack CR

### 4. Enabled vLLM tool calling

**Problem**: gpt-oss-20b model understood tools conceptually but returned tool args in `content` field instead of `tool_calls` array.

**Investigation**:
- Model architecture: `GptOssForCausalLM` (custom), no built-in chat template, only 3 special tokens
- Tested calling the `/v1/chat/completions` endpoint with `tools` param — model reasoned about tools but didn't produce structured output
- Found `openai_tool_parser.py` in the vLLM image (v0.16.0+rhaiv.9) — registered as `openai`
- Model's vLLM config shows `reasoning_parser='openai_gptoss'` — confirming it's designed for the openai parser

**Fix**:
- Patched `vllm-cuda129-20b-runtime` ServingRuntime: added `--enable-auto-tool-choice --tool-call-parser openai`
- ServingRuntime patch didn't propagate to pod — KServe `RawDeployment` mode doesn't re-reconcile
- Patched `vllm-20b-predictor` Deployment directly
- Had to scale down/up (replicas 0→1) due to GPU deadlock with RollingUpdate strategy

**Result**: Tool calling works — `tool_calls` array properly populated, `finish_reason: "tool_calls"`

### 5. Deployed Llama Stack in test-jd namespace

**ConfigMap** (`llama-stack-mcp-config`):
- `remote::vllm` provider pointing at `https://vllm-20b-gpt-oss.apps.rosa...` 
- `inline::rag-runtime` tool_runtime (still required as agents dependency in 0.6.1, even though API is deprecated)
- faiss vector_io, localfs files, pypdf file_processors, meta-reference agents

**LlamaStackDistribution** (`llama-stack-mcp`):
- Image: `docker.io/llamastack/distribution-starter:0.6.1`
- 5Gi storage, route exposed

**Issues hit**:
- First deploy crashed: `KeyError: <Api.tool_runtime: 'tool_runtime'>` — agents provider requires tool_runtime as dependency even if not in APIs list. Added it back.
- Operator didn't auto-create route despite `exposeRoute: true`. Created edge route manually.

**Result**: Pod running (1/1), Responses API verified with tool calling end-to-end.
- Route: `https://llama-stack-mcp-test-jd.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com`

### 6. Enabled Playground UI access

**Problem**: Playground page showed "No available model deployments" for gpt-oss project.

**Investigation**:
- Docs say models must be marked as "AI asset endpoints"
- Searched dashboard frontend JS bundles for the annotation/label
- Found it: `opendatahub.io/genai-asset: "true"` label on InferenceService

**Problem 2**: KServe validating webhook rejected ALL updates to the InferenceService — even label-only patches — with error "deploymentMode cannot be changed from 'RawDeployment' to 'Standard'". This is a bug in the EA build.

**Fix**: Exported the InferenceService JSON, added the label, deleted and recreated the CR. vLLM pod restarted but model reloads in ~3-4 minutes.

**Result**: "Create playground" button now appears in the UI.

### 7. Fixed Playground model name mismatch

**Problem**: Playground created its own Llama Stack pod (`lsd-genai-playground`) but messages sent in the UI got no response. Logs showed:
```
Provider SDK error: Error code: 404 - {'error': {'message': 'The model `vllm-20b` does not exist.'}}
```

**Root cause**: Playground UI derives model name from InferenceService name (`vllm-20b`), but vLLM's `--served-model-name` was `gpt-oss-20b`. Llama Stack auto-discovers from vLLM and registered it as `vllm-inference-1/gpt-oss-20b`.

**Attempted fixes that didn't work**:
- Added `provider_model_id: gpt-oss-20b` to `llama-stack-config` ConfigMap `registered_resources` — operator reverted it on reconciliation
- Registered model alias via Llama Stack API (`POST /v1/models`) — Llama Stack has no alias mechanism, `model_id` is ignored in favor of `{provider_id}/{provider_model_id}`
- Deleted and re-registered models via API — `vllm-20b` still didn't resolve as a lookup name

**Fix**: Changed vLLM's `--served-model-name` from `gpt-oss-20b` to `vllm-20b`:
- Patched ServingRuntime `vllm-cuda129-20b-runtime` (source of truth — deployment-only patches get reverted by the controller)
- Scaled 0→1 to force controller reconciliation with new ServingRuntime args
- Llama Stack auto-discovery now registers model as `vllm-inference-1/vllm-20b` which resolves when UI sends `model: vllm-20b`

**Result**: Playground UI working end-to-end — messages get responses from vLLM through Llama Stack.

---

## Current State

| Component | Namespace | Status |
|-----------|-----------|--------|
| vLLM 20B (with tool calling) | gpt-oss | Running, `--served-model-name vllm-20b`, `openai` tool parser |
| vLLM 120B | gpt-oss | Running (no tool calling yet) |
| Llama Stack v6-20b | gpt-oss | Running (original, no MCP) |
| Llama Stack v6-120b | gpt-oss | Running (original, no MCP) |
| Llama Stack MCP (test) | test-jd | Running, Responses API verified |
| **Playground** | **gpt-oss** | **Working — UI → Llama Stack → vLLM end-to-end** |
| MCP Gateway controller | test-jd | Running (chart 0.5.1) |
| MCP Gateway broker/router | test-jd | Running |
| MCP Gateway (Envoy) | test-jd | Running, Programmed, AWS ELB assigned |
| MCPGatewayExtension | test-jd | Ready |

## Friction Points Discovered

1. **KServe webhook bug** — Rejects any InferenceService update (even label patches) with "deploymentMode cannot be changed" error. Workaround: delete and recreate the CR.
2. **ServingRuntime changes don't propagate** — In KServe RawDeployment mode, patching the ServingRuntime doesn't update the Deployment. Must patch the Deployment directly.
3. **GPU deadlock on rollout** — RollingUpdate strategy + single GPU = new pod can't schedule. Must scale to 0 first, then back to 1.
4. **tool_runtime still required** — Llama Stack 0.6.1 agents provider has a hard dependency on tool_runtime even though the API is deprecated. Must include `inline::rag-runtime` provider.
5. **LlamaStackDistribution route not created** — `exposeRoute: true` didn't create a route in test-jd. Had to create manually via `oc create route edge`.
6. **genai-asset label undocumented** — The `opendatahub.io/genai-asset: "true"` label required for Playground visibility is not mentioned in docs. Found by grepping dashboard frontend JS.
7. **Playground model name mismatch — no alias support in Llama Stack** — The Playground UI derives the model name from the InferenceService name (`vllm-20b`), but vLLM's `--served-model-name` is `gpt-oss-20b`. These must match or inference fails with `The model 'vllm-20b' does not exist`.

   **Why this is hard to fix from the Llama Stack side:**
   - The `llama-stack-config` ConfigMap is owned by the LlamaStackDistribution operator. Adding `provider_model_id: gpt-oss-20b` to `registered_resources` works initially, but the operator reverts it on reconciliation.
   - Llama Stack auto-discovery calls `list_provider_model_ids()` on the vLLM provider, which returns `gpt-oss-20b`, and registers it as `vllm-inference-1/gpt-oss-20b` (format: `{provider_id}/{served_model_name}`).
   - The static `registered_resources` entry with `model_id: vllm-20b` creates a separate model `vllm-inference-1/vllm-20b` with `provider_resource_id: vllm-20b` — the `provider_model_id` field is ignored.
   - Llama Stack has no model alias mechanism — identifiers are always `{provider_id}/{provider_resource_id}`.
   - Registering via the runtime API (`POST /v1/models`) with `model_id: vllm-20b` and `provider_model_id: gpt-oss-20b` creates `vllm-inference-1/gpt-oss-20b` (ignoring `model_id`), not `vllm-20b`.
   - Attempting to look up `vllm-20b` via `/v1/chat/completions` returns `Model 'vllm-20b' not found`.

   **Workaround**: Change vLLM's `--served-model-name` to match the InferenceService name. This aligns auto-discovery so Llama Stack registers the model as `vllm-inference-1/vllm-20b`, which resolves when the UI sends `model: vllm-20b`.

### 8. Deployed MCP Gateway in test-jd (raw manifests)

**Prerequisites already in place**: Gateway API CRDs (via Service Mesh 3), Istio (`openshift-gateway` revision), `data-science-gateway-class` GatewayClass. Red Hat Connectivity Link operator installed (Authorino + Limitador + Kuadrant operators) — provides AuthPolicy/RateLimitPolicy for later.

**First attempt: Helm chart** (`oci://ghcr.io/kuadrant/charts/mcp-gateway`, v0.5.1). Hit a service selector bug — the Helm chart gives both controller and broker pods the same `app.kubernetes.io/name: mcp-gateway` label. The `mcp-gateway` Service uses that label as its selector, so it load-balances between both pods. The controller doesn't listen on gRPC :50051, causing intermittent `ext_proc_error_gRPC_error_14` (Connection refused) through Envoy. The EnvoyFilter and Service are both reconciled by the MCPGatewayExtension controller, so patching them on-cluster gets reverted immediately.

**Fix: Redeployed with raw manifests.** Uninstalled Helm, created manifests modeled after the Kind cluster setup. Key change: controller Deployment uses labels `app: mcp-controller` (NOT `app.kubernetes.io/name: mcp-gateway`), so the controller-created Service only targets the broker pod.

Raw manifests (`infrastructure/openshift-ai/`):
- `10-mcp-controller-rbac.yaml` — ServiceAccount, ClusterRole, ClusterRoleBinding
- `11-mcp-controller-deployment.yaml` — Controller with `app: mcp-controller` labels
- `12-mcp-gateway.yaml` — Gateway with `data-science-gateway-class`
- `13-mcp-gateway-extension.yaml` — MCPGatewayExtension with `privateHost` override

**Second issue: `privateHost` default assumes Istio gateway class.** The MCPGatewayExtension's `privateHost` defaults to `<gateway>-istio.<ns>.svc.cluster.local:<port>`. On OpenShift with `data-science-gateway-class`, the actual Envoy service is `mcp-gateway-data-science-gateway-class`. The broker's `--mcp-gateway-private-host` flag got the wrong value, causing `tools/call` to fail with `no such host`. Fix: set `privateHost: mcp-gateway-data-science-gateway-class.test-jd.svc.cluster.local:8080` in MCPGatewayExtension spec.

**Third issue: Hair-pin routing fails with shared hostnames.** Backend MCP server HTTPRoute initially used the same hostname as the public gateway listener (`mcp-test-jd.apps.rosa...`). When the ext_proc router hair-pins a `tools/call` through Envoy, the ext_proc processes the request again, sees the un-prefixed tool name (e.g., `greet` instead of `test_greet`), fails to match any server, and forwards to the broker — which returns `tool not found`. Fix: backend HTTPRoutes must use the `*.mcp.local` hostname (via the `mcps` gateway listener) so the ext_proc can distinguish hair-pinned requests from client requests.

**Result**: All three MCP operations work end-to-end through Envoy:
- `initialize` → session established with Kagenti MCP Broker
- `tools/list` → 5 tools with `test_` prefix
- `tools/call test_greet` → `"Hi OpenShift"`
- `tools/call test_time` → returns current UTC timestamp

### 9. Deployed test MCP server

Deployed `ghcr.io/kuadrant/mcp-gateway/test-server1:latest` in test-jd namespace:
- Deployment + Service (port 9090)
- HTTPRoute with hostname `test-mcp-server.mcp.local` (mcps listener)
- MCPServerRegistration with `toolPrefix: test_`
- Broker discovers 5 tools: `test_add_tool`, `test_greet`, `test_headers`, `test_slow`, `test_time`

All manifests in `infrastructure/openshift-ai/14-test-mcp-server.yaml`.

## Current State

| Component | Namespace | Status |
|-----------|-----------|--------|
| vLLM 20B (with tool calling) | gpt-oss | Running, `--served-model-name vllm-20b`, `openai` tool parser |
| vLLM 120B | gpt-oss | Running (no tool calling yet) |
| Llama Stack v6-20b | gpt-oss | Running (original, no MCP) |
| Llama Stack v6-120b | gpt-oss | Running (original, no MCP) |
| Llama Stack MCP (test) | test-jd | Running, Responses API verified |
| **Playground** | **gpt-oss** | **Working — UI → Llama Stack → vLLM end-to-end** |
| MCP Gateway controller | test-jd | Running (raw manifests, v0.5.1) |
| MCP Gateway broker/router | test-jd | Running, 1 healthy server |
| MCP Gateway (Envoy) | test-jd | Running, Programmed, AWS ELB assigned |
| MCPGatewayExtension | test-jd | Ready, privateHost override set |
| Test MCP server | test-jd | Running, 5 tools registered |

## Friction Points Discovered

1. **KServe webhook bug** — Rejects any InferenceService update (even label patches) with "deploymentMode cannot be changed" error. Workaround: delete and recreate the CR.
2. **ServingRuntime changes don't propagate** — In KServe RawDeployment mode, patching the ServingRuntime doesn't update the Deployment. Must patch the Deployment directly.
3. **GPU deadlock on rollout** — RollingUpdate strategy + single GPU = new pod can't schedule. Must scale to 0 first, then back to 1.
4. **tool_runtime still required** — Llama Stack 0.6.1 agents provider has a hard dependency on tool_runtime even though the API is deprecated. Must include `inline::rag-runtime` provider.
5. **LlamaStackDistribution route not created** — `exposeRoute: true` didn't create a route in test-jd. Had to create manually via `oc create route edge`.
6. **genai-asset label undocumented** — The `opendatahub.io/genai-asset: "true"` label required for Playground visibility is not mentioned in docs. Found by grepping dashboard frontend JS.
7. **Playground model name mismatch — no alias support in Llama Stack** — The Playground UI derives the model name from the InferenceService name (`vllm-20b`), but vLLM's `--served-model-name` is `gpt-oss-20b`. These must match or inference fails with `The model 'vllm-20b' does not exist`.

   **Why this is hard to fix from the Llama Stack side:**
   - The `llama-stack-config` ConfigMap is owned by the LlamaStackDistribution operator. Adding `provider_model_id: gpt-oss-20b` to `registered_resources` works initially, but the operator reverts it on reconciliation.
   - Llama Stack auto-discovery calls `list_provider_model_ids()` on the vLLM provider, which returns `gpt-oss-20b`, and registers it as `vllm-inference-1/gpt-oss-20b` (format: `{provider_id}/{served_model_name}`).
   - The static `registered_resources` entry with `model_id: vllm-20b` creates a separate model `vllm-inference-1/vllm-20b` with `provider_resource_id: vllm-20b` — the `provider_model_id` field is ignored.
   - Llama Stack has no model alias mechanism — identifiers are always `{provider_id}/{provider_resource_id}`.
   - Registering via the runtime API (`POST /v1/models`) with `model_id: vllm-20b` and `provider_model_id: gpt-oss-20b` creates `vllm-inference-1/gpt-oss-20b` (ignoring `model_id`), not `vllm-20b`.
   - Attempting to look up `vllm-20b` via `/v1/chat/completions` returns `Model 'vllm-20b' not found`.

   **Workaround**: Change vLLM's `--served-model-name` to match the InferenceService name. This aligns auto-discovery so Llama Stack registers the model as `vllm-inference-1/vllm-20b`, which resolves when the UI sends `model: vllm-20b`.

8. **Helm chart service selector bug** — MCP Gateway Helm chart gives both controller and broker pods `app.kubernetes.io/name: mcp-gateway`. The `mcp-gateway` Service selector matches both. Controller doesn't listen on gRPC :50051 → intermittent ext_proc connection refused errors through Envoy. Both Service and EnvoyFilter are reconciled by the MCPGatewayExtension controller, so on-cluster patches get reverted. **Workaround**: Deploy via raw manifests with controller labels `app: mcp-controller` (not `app.kubernetes.io/name: mcp-gateway`).

9. **`privateHost` default assumes Istio gateway class** — MCPGatewayExtension defaults `privateHost` to `<gateway>-istio.<ns>.svc.cluster.local:<port>`. Non-Istio gateway classes (e.g., `data-science-gateway-class`) create services with different names. **Fix**: Set `privateHost` explicitly in the MCPGatewayExtension spec.

10. **Backend HTTPRoutes must use separate hostnames for hair-pin routing** — If a backend's HTTPRoute uses the same hostname as the public gateway listener, the ext_proc processes hair-pinned `tools/call` requests twice. On the second pass, the un-prefixed tool name has no match, so the request falls through to the broker, which returns `tool not found`. **Fix**: Backend HTTPRoutes must use `*.mcp.local` hostnames (via the `mcps` listener), not the public hostname.

---

## Session 2 — 2026-04-17

**Goal**: Migrate MCP Gateway from manual v0.5.1 deployment to upstream OpenShift install path (v0.6.0 via OLM + Helm).

### 10. Investigated OpenShift routing gap

The v0.5.1 MCP Gateway in test-jd was only reachable via a raw AWS ELB — no OpenShift Route existed. Investigated why:

- The Gateway used `data-science-gateway-class`, which is Istio-backed. Istio defaults to creating a **LoadBalancer** service.
- The platform's `data-science-gateway` in `openshift-ingress` avoids this via an `infrastructure.parametersRef` pointing to a ConfigMap that forces `spec.type: ClusterIP`. This ConfigMap is created by the RHOAI `GatewayConfig` CR — a **singleton, platform-level resource** owned by `DSCInitialization`. It only manages the one platform gateway, not user-created gateways.
- The `GatewayConfig` has `ingressMode: OcpRoute`, which wires up OpenShift Routes automatically — but only for the platform gateway.

**Conclusion**: Per-team gateways using `data-science-gateway-class` will always get a LoadBalancer unless you manually replicate the ConfigMap pattern. This is undocumented.

### 11. Found upstream OpenShift install path

Discovered `github.com/Kuadrant/mcp-gateway/config/openshift/` which contains:
- `deploy_openshift.sh` — Full automated deployment script
- `charts/mcp-gateway-ingress/` — Helm chart that creates an OpenShift Route
- `kustomize/ocp-ingress/base/` — Creates `openshift-default` GatewayClass

Key design decisions in the upstream path:
- Uses `gatewayClassName: openshift-default` (not `data-science-gateway-class` or `istio`)
- `openshift-default` uses the same `openshift.io/gateway-controller/v1` controller — on clusters with Service Mesh, it's still handled by Istio (creates Envoy), so EnvoyFilter/ext_proc works
- The `mcp-gateway-ingress` Helm chart creates the OpenShift Route pointing to the gateway service
- Gateway still gets a LoadBalancer service (not ClusterIP), but the Route provides the proper `*.apps.rosa...` HTTPS endpoint

### 12. Installed MCP Gateway v0.6.0 via OLM

Upgraded from manual v0.5.1 to OLM-managed v0.6.0:

1. Deleted old v0.5.1 CRs (`MCPServerRegistration`, `MCPGatewayExtension`) and controller deployment from test-jd
2. Deleted old CRDs (`mcp.kagenti.com` → replaced by `mcp.kuadrant.io`)
3. Created `mcp-system` namespace
4. Installed CatalogSource (`ghcr.io/kuadrant/mcp-controller-catalog:v0.6.0`) in `openshift-marketplace`
5. Installed OperatorGroup + Subscription in `mcp-system` (patched `sourceNamespace` to `openshift-marketplace`)
6. Controller CSV succeeded, 3 new CRDs registered: `mcpgatewayextensions.mcp.kuadrant.io`, `mcpserverregistrations.mcp.kuadrant.io`, `mcpvirtualservers.mcp.kuadrant.io`

### 13. Deployed MCP Gateway in `mcp-upstream-test` (upstream path)

Created `openshift-default` GatewayClass, then deployed using upstream Helm charts:

```bash
# Gateway instance
helm upgrade -i mcp-gateway oci://ghcr.io/kuadrant/charts/mcp-gateway \
  --version 0.6.0 --namespace mcp-upstream-test --skip-crds \
  --set controller.enabled=false \
  --set gateway.create=true --set gateway.name=mcp-gateway \
  --set gateway.namespace=mcp-upstream-test \
  --set gateway.publicHost="mcp-upstream.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com" \
  --set gateway.internalHostPattern="*.mcp.local" \
  --set gateway.gatewayClassName="openshift-default" \
  --set mcpGatewayExtension.create=true \
  --set mcpGatewayExtension.gatewayRef.name=mcp-gateway \
  --set mcpGatewayExtension.gatewayRef.namespace=mcp-upstream-test \
  --set mcpGatewayExtension.gatewayRef.sectionName=mcp

# OpenShift Route (from cloned repo chart)
helm upgrade -i mcp-gateway-ingress config/openshift/charts/mcp-gateway-ingress \
  --namespace mcp-upstream-test \
  --set mcpGateway.host="mcp-upstream.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com" \
  --set mcpGateway.namespace=mcp-upstream-test \
  --set gateway.name=mcp-gateway --set gateway.class="openshift-default" \
  --set route.create=true
```

Helm chart creates: Gateway, MCPGatewayExtension. Controller creates: broker Deployment + Service, EnvoyFilter, HTTPRoute. Ingress chart creates: OpenShift Route (edge TLS).

### 14. Deployed test MCP server in `mcp-upstream-test`

```yaml
# Deployment (must specify --http flag, server defaults to stdio)
command: ["/mcp-test-server"]
args: ["--http", "0.0.0.0:9090"]
# HTTPRoute on *.mcp.local (mcps listener)
# MCPServerRegistration with toolPrefix: "test_"
```

Registration initially failed because server pod was crash-looping (missing `--http` flag). After patching, controller discovered 5 tools within one ping interval (60s).

### 15. Verified end-to-end via OpenShift Route

All three MCP operations work via `https://mcp-upstream.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com/mcp`:
- `initialize` → session ID (JWT), server `Kuadrant MCP Gateway v0.0.1`
- `tools/list` → 5 tools: `test_greet`, `test_time`, `test_headers`, `test_slow`, `test_add_tool`
- `tools/call test_greet {"name":"OpenShift"}` → `"Hi OpenShift"`

### 16. Deleted `test-jd` namespace

Attempted to redeploy v0.6.0 in test-jd but controller failed to reconcile (stale `mcp-gateway-config` Secret from v0.5.1, then controller restart didn't recover). Since `mcp-upstream-test` was fully functional, deleted `test-jd` entirely.

Also deleted the `LlamaStackDistribution` from test-jd earlier in the session (no longer needed — Llama Stack will be redeployed when we wire it to the MCP Gateway).

### 17. Connected Playground to MCP Gateway

Created `gen-ai-aa-mcp-servers` ConfigMap in `redhat-ods-applications`:

```yaml
kind: ConfigMap
apiVersion: v1
metadata:
  name: gen-ai-aa-mcp-servers
  namespace: redhat-ods-applications
data:
  MCP-Gateway-Test: |
    {
      "url": "https://mcp-upstream.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com/mcp",
      "description": "MCP Gateway with test tools (greet, time, headers, slow, add_tool)"
    }
```

The Playground UI immediately showed `MCP-Gateway-Test` as an available MCP server. The playground's Llama Stack instance (`lsd-genai-playground`, v0.6.0.1+rhai0) already had `remote::model-context-protocol` registered as a `tool_runtime` provider — the dashboard wires the ConfigMap URL to Llama Stack automatically. No Llama Stack config changes needed.

**End-to-end verified**: Playground UI → Llama Stack → MCP Gateway → Test MCP Server. Tool calling works (e.g., "what time is it?" invokes `test_time` through the gateway).

---

## Current State — as of 2026-04-17

| Component | Namespace | Status |
|-----------|-----------|--------|
| vLLM 20B (with tool calling) | gpt-oss | Running, `--served-model-name vllm-20b`, `openai` tool parser |
| vLLM 120B | gpt-oss | Running (no tool calling yet) |
| Llama Stack v6-20b | gpt-oss | Running (original, no MCP) |
| Llama Stack v6-120b | gpt-oss | Running (original, no MCP) |
| Playground (lsd-genai-playground) | gpt-oss | Running — full end-to-end with MCP Gateway |
| `gen-ai-aa-mcp-servers` ConfigMap | redhat-ods-applications | MCP-Gateway-Test → mcp-upstream gateway |
| MCP Gateway Controller (v0.6.0, OLM) | mcp-system | Running, cluster-scoped |
| MCP Gateway Broker (v0.6.0) | mcp-upstream-test | Running, with EnvoyFilter ext_proc |
| MCP Gateway Envoy (`openshift-default`) | mcp-upstream-test | Running, LoadBalancer + OpenShift Route |
| MCPGatewayExtension | mcp-upstream-test | Ready |
| MCPServerRegistration (test-mcp-server) | mcp-upstream-test | Ready, prefix `test_`, 5 tools |
| Test MCP Server | mcp-upstream-test | Running (kuadrant test-server1) |
| GatewayClass `openshift-default` | cluster-scoped | Accepted, handled by Istio controller |

## Friction Points Discovered (continued)

11. **No OpenShift Route for user-created Gateways** — The RHOAI `GatewayConfig` CR only manages the platform `data-science-gateway` in `openshift-ingress`. User-created Gateways (any namespace, any GatewayClass) don't get Routes or ClusterIP services automatically. The upstream MCP Gateway project solves this with the `mcp-gateway-ingress` Helm chart, but it's not published to an OCI registry — must be installed from the git repo.

12. **`openshift-default` GatewayClass not pre-created** — Despite the controllerName `openshift.io/gateway-controller/v1` being available, the `openshift-default` GatewayClass doesn't exist by default on RHOAI clusters. Must be created manually. Behavior depends on whether Service Mesh is installed: with SM it uses Istio/Envoy (EnvoyFilter works), without SM it would use HAProxy (EnvoyFilter would not work).

13. **Test MCP server defaults to stdio** — `ghcr.io/kuadrant/mcp-gateway/test-server1:latest` defaults to stdio transport. Must explicitly pass `--http 0.0.0.0:9090` to run in HTTP mode. No error message — just exits silently.

14. **Stale secrets block controller reconciliation** — When upgrading from v0.5.1 to v0.6.0, a leftover `mcp-gateway-config` Secret with the old format prevented the controller from creating a new one. Controller logged `Secret "mcp-gateway-config" not found` even though it existed (wrong format/ownership). Required manual deletion.

## Next Steps

1. ~~Create Playground instance via UI~~ ✓
2. ~~Fix Playground model name mismatch~~ ✓
3. ~~Deploy MCP Gateway controller + CRDs on the cluster~~ ✓ (v0.6.0 via OLM)
4. ~~Deploy MCP server behind the gateway~~ ✓ (mcp-upstream-test)
5. ~~Test tools/call end-to-end through Envoy~~ ✓ (via OpenShift Route)
6. ~~Wire Llama Stack → MCP Gateway~~ ✓ (automatic — dashboard wires ConfigMap to Llama Stack's `remote::model-context-protocol` provider)
7. ~~Create `gen-ai-aa-mcp-servers` ConfigMap to expose MCP servers in Playground UI~~ ✓
8. ~~Test end-to-end: Playground → Llama Stack → MCP Gateway → MCP Server → tool response~~ ✓

---

## Session 3 — 2026-04-17 (continued)

**Goal**: Set up authentication and authorization for the MCP Gateway, deploy the OpenShift MCP server behind it, and test role-based access through the Playground.

### 18. Deployed Keycloak (RHBK) via operator

Installed Red Hat Build of Keycloak (RHBK) operator v26.4.11 via OLM in `keycloak` namespace. Deployed a production-style setup:

- **Postgres database**: StatefulSet with `gp3-csi` PVC (not emptyDir)
- **Keycloak instance**: `k8s.keycloak.org/v2alpha1 Keycloak` CR with `hostname: keycloak.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com`, OpenShift Route (edge TLS), `proxy.headers: xforwarded`
- **Admin credentials**: `temp-admin` / `4c4dabaa2423433fbc04ade91bd0bf87` (stored in `keycloak-initial-admin` Secret)

### 19. Created Keycloak realm for MCP Gateway

Used `KeycloakRealmImport` CR to create `mcp-gateway` realm:

- **Clients**:
  - `mcp-gateway` — confidential client (secret: `mcp-gateway-client-secret`), for service-to-service auth
  - `mcp-playground` — public client, for user-facing auth (Playground UI)
- **Roles**: `mcp-user`, `mcp-admin`
- **Users**:
  - `mcp-user1` / `user1pass` — role: `mcp-user`
  - `mcp-admin1` / `admin1pass` — roles: `mcp-user` + `mcp-admin`

OIDC discovery verified at `https://keycloak.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com/realms/mcp-gateway/.well-known/openid-configuration`. Token acquisition tested — JWT claims include `realm_access.roles` array with correct role assignments.

### 20. Installed Kuadrant (Connectivity Link)

Created `Kuadrant` CR in `openshift-operators` namespace. Connectivity Link operator (already installed) reconciled and deployed:
- **Authorino** — JWT validation and authorization engine
- **Limitador** — rate limiting engine (available for future use)

### 21. Created gateway-level AuthPolicy (JWT validation)

Applied `AuthPolicy` targeting the Gateway's `mcp` listener:

```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: mcp-gateway-auth
  namespace: mcp-upstream-test
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: mcp-gateway
    sectionName: mcp
  rules:
    authentication:
      keycloak-jwt:
        jwt:
          issuerUrl: https://keycloak.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com/realms/mcp-gateway
```

**Result**: All requests through the gateway's public endpoint now require a valid JWT from the `mcp-gateway` Keycloak realm. Unauthenticated requests get 401. Authenticated requests (with `Authorization: Bearer <token>`) succeed. Verified with both `mcp-user1` and `mcp-admin1` tokens.

### 22. Deployed OpenShift MCP server

Deployed `quay.io/redhat-user-workloads/crt-nshift-lightspeed-tenant/openshift-mcp-server:latest` (upstream: `github.com/openshift/openshift-mcp-server`, fork of `github.com/containers/kubernetes-mcp-server`) in `mcp-upstream-test`:

- **ServiceAccount** (`openshift-mcp-server`) with `view` ClusterRole binding — read-only access to the Kubernetes API
- **ConfigMap** (`openshift-mcp-server-config`) with `config.toml`:
  - `read_only = true`, `stateless = true` (recommended for container deployments)
  - `cluster_provider_strategy = "in-cluster"`
  - `toolsets = ["core", "config"]`
  - Denied resources: `Secret`, `ServiceAccount`, `rbac.authorization.k8s.io/*`
- **Deployment** with health checks (`/healthz`), security context (non-root, drop all capabilities)
- **Service** on port 8080
- **HTTPRoute** on `openshift-mcp-server.mcp.local` (internal `mcps` listener)
- **MCPServerRegistration** with `toolPrefix: "openshift_"`

Server detected OpenShift (108 API groups), registered 14 tools with the gateway:
`openshift_configuration_view`, `openshift_events_list`, `openshift_namespaces_list`, `openshift_nodes_log`, `openshift_nodes_stats_summary`, `openshift_nodes_top`, `openshift_pods_get`, `openshift_pods_list`, `openshift_pods_list_in_namespace`, `openshift_pods_log`, `openshift_pods_top`, `openshift_projects_list`, `openshift_resources_get`, `openshift_resources_list`

Gateway now serves 19 tools total (14 openshift + 5 test).

### 23. Created per-server AuthPolicy (admin-only authorization)

Applied a second `AuthPolicy` targeting the OpenShift MCP server's HTTPRoute — restricts access to users with the `mcp-admin` role:

```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: openshift-mcp-admin-only
  namespace: mcp-upstream-test
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: openshift-mcp-server
  rules:
    authentication:
      keycloak-jwt:
        jwt:
          issuerUrl: https://keycloak.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com/realms/mcp-gateway
    authorization:
      admin-only:
        patternMatching:
          patterns:
            - selector: auth.identity.realm_access.roles
              operator: incl
              value: mcp-admin
```

**Verified via curl**:

| User | Role | Test tools | OpenShift tools |
|------|------|-----------|-----------------|
| `mcp-user1` | `mcp-user` | Allowed | **Blocked** (403 from Authorino) |
| `mcp-admin1` | `mcp-user` + `mcp-admin` | Allowed | **Allowed** |

### 24. Tested end-to-end through Playground UI

The Playground UI has an auth icon that accepts an access token for MCP server authentication. Tokens acquired from Keycloak via:

```bash
curl -s -X POST \
  https://keycloak.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com/realms/mcp-gateway/protocol/openid-connect/token \
  -d "grant_type=password&client_id=mcp-playground&username=<user>&password=<pass>" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
```

**With `mcp-admin1` token**: Full end-to-end working — Playground UI → Llama Stack → MCP Gateway (JWT validated) → OpenShift MCP Server → Kubernetes API. Successfully queried pod list in `mcp-upstream-test` namespace through the Playground.

**With `mcp-user1` token**: `tools/list` returns all 19 tools (see friction point 16), but `tools/call` for OpenShift tools fails with a network error in the Playground (see friction point 17).

---

## Current State — as of 2026-04-17 (end of Session 3)

| Component | Namespace | Status |
|-----------|-----------|--------|
| vLLM 20B (with tool calling) | gpt-oss | Running, `--served-model-name vllm-20b`, `openai` tool parser |
| vLLM 120B | gpt-oss | Running (no tool calling yet) |
| Llama Stack v6-20b | gpt-oss | Running (original, no MCP) |
| Llama Stack v6-120b | gpt-oss | Running (original, no MCP) |
| Playground (lsd-genai-playground) | gpt-oss | Running — full end-to-end with MCP Gateway + auth |
| `gen-ai-aa-mcp-servers` ConfigMap | redhat-ods-applications | MCP-Gateway-Test → mcp-upstream gateway |
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
| AuthPolicy (openshift-mcp-admin-only) | mcp-upstream-test | Enforced — `mcp-admin` role required for OpenShift tools |
| Keycloak (RHBK v26.4.11) | keycloak | Running, with Postgres PVC |
| Keycloak realm `mcp-gateway` | keycloak | 2 clients, 2 roles, 2 users |
| Kuadrant CR | openshift-operators | Authorino + Limitador running |

## Friction Points Discovered (continued)

15. **Keycloak token lifetime too short for testing** — Default access token lifetime is 5 minutes (300 seconds). Tokens expire quickly during manual Playground testing, requiring frequent re-acquisition. Consider increasing for dev/test environments.

16. **`tools/list` ignores authorization — shows all tools regardless of user role** — The gateway broker serves `tools/list` from its internal cache (aggregated during startup). It does not evaluate per-HTTPRoute AuthPolicies when building the tool list. Result: `mcp-user1` (who can only access test tools) sees all 19 tools including the 14 OpenShift tools they cannot call. Tool visibility should be filtered by the user's identity/roles.

17. **Per-server authorization failures return "network error" instead of proper MCP error** — When the HTTPRoute-level AuthPolicy blocks a `tools/call` (Authorino returns 403), the gateway broker misinterprets the 403 as a transport error: `"failed to create client: transport error: server returned 4xx for initialize POST, likely a legacy SSE server"`. The broker returns EOF to Envoy, Llama Stack gets a broken stream, and the Playground shows a generic "network error." The broker should catch 4xx responses from backend connections and return a JSON-RPC error with a meaningful message (e.g., "access denied").

18. **`mcpCatalog` feature flag not in RHOAI 3.4.0-ea.2** — The `mcpCatalog` dashboard config flag (for MCP server catalog browsing UI) is not recognized by the OdhDashboardConfig CRD schema in this RHOAI version. Patching with `{"spec": {"dashboardConfig": {"mcpCatalog": "true"}}}` produces `Warning: unknown field` and has no effect. Requires a newer RHOAI build.

19. **Broker logs "unable to check conflict, tool id is missing" for OpenShift MCP server** — The OpenShift MCP server's tools don't include `_meta.id` fields in their tool definitions. The gateway broker logs repeated warnings during conflict detection. Does not block tool registration (14 tools registered successfully) but produces noisy logs.

## Next Steps

1. ~~Set up Keycloak (RHBK) for OIDC~~ ✓
2. ~~Create AuthPolicy on gateway (JWT validation)~~ ✓
3. ~~Deploy OpenShift MCP server behind the gateway~~ ✓
4. ~~Create per-server authorization (admin-only for OpenShift tools)~~ ✓
5. ~~Test auth flow end-to-end through Playground~~ ✓
6. Explore MCPVirtualServer for identity-based tool filtering (solves friction point 16)
7. Investigate Playground auth token passthrough mechanism — how does the UI pass the Bearer token to Llama Stack?
8. Increase Keycloak token lifetime for dev/test usability
9. Upgrade RHOAI to a build that supports `mcpCatalog` feature flag
10. Update documentation YAMLs in `infrastructure/openshift-ai/` with auth and OpenShift MCP server manifests
