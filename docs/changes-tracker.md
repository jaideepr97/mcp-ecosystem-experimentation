---
name: MCP Ecosystem Experiment - Changes Tracker
description: Tracks all modifications made to projects during the MCP ecosystem experiment, distinguishing fundamental component gaps from helper project changes
type: project
---

# Changes Made During MCP Ecosystem Experiment

## Fundamental Components (gaps/enhancements worth tracking)

### model-registry catalog
- **No code changes made.** Deployed as-is from `ghcr.io/kubeflow/model-registry/server:latest`.
- Catalog API works well for MCP server discovery out of the box.
- **Observation:** The list endpoint (`/api/mcp_catalog/v1alpha1/mcp_servers`) returns `toolCount` but not the tools themselves. Tools require a separate per-server call (`/mcp_servers/{id}/tools`). A consumer building a UI or automation layer must make N+1 API calls to show tools alongside server listings. An `include=tools` query parameter or embedding tools in the list response would reduce round trips.
- **Observation:** `filter_options` returned empty `{"filters": {}}` for our YAML-based catalog. Filtering may only be meaningful with larger catalogs or specific provider types.

### mcp-gateway
- **No code changes made.** Deployed using existing make targets.
- **Observation (from earlier phases):** The ext_proc Router unconditionally rewrites `:authority` header on ALL port 8080 traffic (`internal/mcp-router/request_handlers.go:198`), which prevents non-MCP services from being exposed through the same Envoy gateway. Mini-oidc had to be exposed via a separate NodePort to avoid this.
- **Observation:** MCPServerRegistration API group is `mcp.kuadrant.io` but mcp-launcher hardcoded `mcp.kagenti.com`. This was fixed in our launcher fork. The group name difference suggests the CRD API group may have changed at some point — consumers need to track the correct group.

### mcp-lifecycle-operator
- **No code changes to upstream.** CRD and operator binary were redeployed from latest source (schema had changed from flat to nested since initial deployment).
- Works as expected: MCPServer CR creates Deployment + Service, deleting CR cleans up resources.
- **Observation:** No built-in integration with the catalog. The operator has no awareness of the catalog API — the bridge between "what's available" (catalog) and "deploy it" (operator) must be built externally (which is what mcp-launcher does).

### mcp-lifecycle-operator (downstream fork)
- Branch: `gateway-integration` on `/Users/jrao/projects/mcp-lifecycle-operator`
- **Changes:** Integrated gateway controller from [openshift/mcp-lifecycle-operator#3](https://github.com/openshift/mcp-lifecycle-operator/pull/3), adapted for current nested spec schema and correct API group (`mcp.kuadrant.io`).
- Added `MCPServerGatewayReconciler` — a separate controller that watches MCPServer CRs and creates HTTPRoute + MCPServerRegistration when `mcp.x-k8s.io/gateway-ref` annotation is present.
- This closes the operator → gateway registration gap. The full pipeline (catalog → launcher → operator → gateway) is now automated.

### Catalog → Operator handoff friction (cross-project integration gap)
These are the most significant findings — gaps in the **contract between catalog metadata and operator deployment**:

1. **`runtimeMetadata` missing container command/entrypoint.** The catalog schema has `artifacts[].uri` (OCI image) and `runtimeMetadata.defaultPort`, but no field for the container binary or entrypoint. The operator's `config.arguments` maps to Kubernetes `container.args` which *replaces* CMD for images without ENTRYPOINT. Without knowing the binary path (e.g. `/mcp-test-server`), a deployer cannot construct correct arguments. The catalog metadata alone is insufficient to deploy — you need out-of-band knowledge about the image's ENTRYPOINT/CMD.

2. **`runtimeMetadata` missing security context requirements.** The operator defaults to restricted Pod Security Standards (`runAsNonRoot: true`). The catalog has no field indicating whether an image requires root. mcp-launcher has a `runAsRoot` extension field, but the catalog API schema doesn't expose this. A deployer reading only catalog metadata has no way to know this will fail.

3. **No standardized "arguments" field in catalog metadata.** The catalog has no equivalent of the operator's `config.arguments`. Some images need specific flags (e.g. `--http 0.0.0.0:9090`), but this isn't captured in the catalog. The `runtimeMetadata` section covers port and path but not how to start the server.

4. **Semantic gap in `arguments` between launcher and operator.** mcp-launcher's `PackageArguments` are meant to be appended to the container command. The operator's `config.arguments` replaces CMD entirely. These are fundamentally different semantics. An integrator bridging the two must understand both conventions.

**Summary:** The `runtimeMetadata` contract is necessary but not sufficient for automated deployment. It covers *what* to expose (port, path) but not *how* to run (command, args, security context). A complete catalog-to-operator handoff would need: container command/entrypoint, required arguments, security context requirements (root/non-root), and potentially resource requirements.

5. **Operator → Gateway registration gap.** Once the operator deploys an MCP server (Deployment + Service), there is no automated path to register it with the gateway (HTTPRoute + MCPServerRegistration). The handoff from "server is running" to "server is routable via gateway" is a distinct integration seam. The user has something in mind for a future iteration to address this.

### OCI image opacity — the systemic catalog→operator problem

The friction points above (1–4) are symptoms of a deeper structural issue: **OCI images are opaque, and the catalog metadata doesn't carry enough operational context to deploy them reliably.** Each MCP server image can differ across multiple dimensions simultaneously:

- **Entrypoint/CMD conventions**: Some images use ENTRYPOINT (args append), some use CMD (args replace), some use both. The operator's `config.arguments` maps to Kubernetes `container.args`, which *replaces* CMD — destructive if the deployer gets it wrong. Example: test-server1 has `CMD ["/mcp-test-server"]` with no ENTRYPOINT, so `config.arguments: ["--http", "0.0.0.0:9090"]` replaced the binary entirely and the container crashed.
- **Transport selection**: Servers default to different transports (stdio, HTTP/SSE, streamable-HTTP). The flag to switch varies per image (`--http`, `--transport http`, `--mode sse`, env var `MCP_TRANSPORT`, etc.). test-server1 defaulted to stdio and exited immediately because no HTTP flag was passed.
- **Bind address conventions**: Some listen on `0.0.0.0`, some on `127.0.0.1` by default. Some accept `host:port` combined, others take `--port` and `--host` separately.
- **Security context requirements**: Root vs non-root, specific UID, filesystem write needs. The operator defaults to restricted PSS (`runAsNonRoot: true`), but the catalog has no field indicating what an image requires.
- **Runtime dependencies**: Writable temp dirs, volume mounts, DNS resolution for external services, etc.

**In the worst case, every MCP server image is a snowflake.** The catalog becomes a registry of names without enough operational metadata to actually deploy anything — it tells you *what exists* but not *how to make it run*. The operator just does what it's told, so there's no intelligence in between.

**Where should this knowledge live?** Options include:
1. **In the image itself** — OCI labels or a standardized ENTRYPOINT contract. Requires all MCP server authors to follow a convention.
2. **In the catalog metadata** — Richer `runtimeMetadata` covering command, args, security context, bind address. Requires the catalog schema to grow.
3. **In a separate "deployment profile"** — A layer between catalog and operator encoding per-image operational knowledge.
4. **Convention over configuration** — Define an "MCP server image contract" (e.g., MUST use ENTRYPOINT, MUST accept `--port $PORT` and listen on `0.0.0.0`, MUST run as non-root) so the operator can make safe assumptions without per-image metadata.

Without at least one of these, every new MCP server added to the catalog is a potential deployment failure requiring human debugging. This is the most significant integration gap observed in the experiment — it's not a single missing field but a missing contract between image authors, catalog curators, and the deployment operator.

### mini-oidc (custom OIDC provider)
- **Code changes made** (this is our own test project, not an upstream component):
  - Added `/.well-known/oauth-authorization-server` endpoint (OAuth AS metadata, same as OIDC discovery)
  - Added CORS middleware for browser-based clients (MCP Inspector)
  - Added `/register` endpoint (RFC 7591 Dynamic Client Registration)
  - Added `/authorize` endpoint with authorization code + PKCE flow
  - These were needed because MCP Inspector expects a full OAuth 2.1 flow

### Istio/Envoy (auth layer)
- **EnvoyFilter `mcp-auth-401` created** in `gateway-system` — Lua filter that returns proper 401 + `WWW-Authenticate: Bearer` header instead of Istio's default 403 from AuthorizationPolicy. This was needed because Istio's AuthorizationPolicy hardcodes 403 responses (istio/istio#26559), but OAuth clients (MCP Inspector) expect 401 to trigger the authorization flow. In production, Kuadrant AuthPolicy (Authorino) handles this properly.

## Helper Projects (experiment scaffolding)

### mcp-launcher (forked from matzew/mcp-launcher)
- Branch: `catalog-api-integration`
- **Changes:**
  - Extracted `Store` interface from concrete `ConfigMapStore` type
  - Added `APIStore` backend that reads from model-registry catalog REST API (`CATALOG_API_URL` env var)
  - Maps catalog API response schema to launcher's `ServerEntry` schema (artifacts → packages, runtimeMetadata → kubernetesExtensions, etc.)
  - Added `Tool` type to `ServerEntry` and fetches tools from per-server endpoint
  - Updated catalog.html template to render tools as badges
  - Fixed MCPServerRegistration GVR from `mcp.kagenti.com` to `mcp.kuadrant.io` (in RBAC; handler code still has old value — potential issue when deploying via launcher)
- **Why:** Needed a UI to demonstrate the catalog → deploy flow. The launcher's ConfigMap-based catalog backend doesn't integrate with the model-registry catalog API.

## Deployment Artifacts Created (not in any repo)
- PostgreSQL StatefulSet + PVC + Secret + Service in `catalog-system`
- Catalog ConfigMap (`mcp-catalog-sources`) with sources.yaml + mcp-servers.yaml
- Catalog Deployment + Service in `catalog-system`
- Launcher RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding)
- Launcher Deployment + Service + NodePort in `mcp-test`
- Mini-oidc Deployment + Services in `mcp-test`
- EnvoyFilter `mcp-auth-401` in `gateway-system`
- RequestAuthentication `mcp-jwt-auth` in `gateway-system`
