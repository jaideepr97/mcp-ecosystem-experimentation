# Component Versions

Tracks all deployed component versions, sources, and custom builds on the `agentic-mcp` cluster.

**Cluster**: `agentic-mcp.jolf.p3.openshiftapps.com` (ROSA)
**OpenShift**: 4.21.6
**Last updated**: 2026-04-21

---

## Platform

| Component | Version | Source |
|-----------|---------|--------|
| OpenShift | 4.21.6 | ROSA |
| RHOAI | 3.4.0 | CatalogSource: `rhoai-340-catalog` (`quay.io/rhoai/rhoai-fbc-fragment@sha256:33562d...`) |
| Service Mesh 3 | 3.3.2 | OLM |
| Service Mesh 2 | 2.6.14 | OLM |
| Connectivity Link (Kuadrant) | 1.3.2 | OLM (`rhcl-operator`) |
| Authorino Operator | 1.3.0 | OLM (deployed by Kuadrant) |
| Limitador Operator | 1.3.0 | OLM (deployed by Kuadrant) |

## MCP Gateway

| Component | Version | Image / Source | Namespace |
|-----------|---------|----------------|-----------|
| MCP Gateway Controller | v0.6.0 (CSV: 0.0.0) | CatalogSource: `mcp-gateway-catalog` (`ghcr.io/kuadrant/mcp-controller-catalog:v0.6.0`) | mcp-system |
| MCP Gateway Broker | v0.6.0 | `ghcr.io/kuadrant/mcp-gateway:v0.6.0` | team-a |
| MCP Gateway Envoy | Istio proxy | `registry.redhat.io/openshift-service-mesh/istio-proxyv2-rhel9@sha256:7d15ce...` | team-a |
| Helm chart (mcp-gateway) | v0.6.0 | `oci://ghcr.io/kuadrant/charts/mcp-gateway` | team-a |
| Helm chart (mcp-gateway-ingress) | v0.1.0 | Local chart from `mcp-gateway` repo | team-a |
| GatewayClass | `openshift-default` | Controller: `openshift.io/gateway-controller/v1` (Istio) | cluster-scoped |

## MCP Lifecycle Operator

| Component | Version | Image / Source | Namespace |
|-----------|---------|----------------|-----------|
| Controller | release-0.1 | **Custom build**: `quay.io/jrao/mcp-lifecycle-operator:release-0.1` | mcp-lifecycle-operator-system |
| CRD (`mcpservers.mcp.x-k8s.io`) | release-0.1 | PR #16 `dist/install.yaml` (`openshift/mcp-lifecycle-operator`, branch `release-0.1`) | cluster-scoped |

**Note**: CRD was patched post-install to add `.status.observedGeneration` (missing from generated schema). Custom image built from `openshift/release-0.1` branch because PR #16 shipped with a `main` branch image that was incompatible with the `release-0.1` CRD (see friction point #29).

## MCP Servers

| Component | Image | Config | Namespace |
|-----------|-------|--------|-----------|
| OpenShift MCP Server | `registry.redhat.io/openshift-mcp-beta/openshift-mcp-server-rhel9:0.2` | `stateless=true`, `cluster_provider_strategy=in-cluster`, toolsets: `core`+`config`, SA: `mcp-viewer` (view ClusterRole) | team-a |
| Test MCP Server | `ghcr.io/kuadrant/mcp-gateway/test-server1:latest` | 5 tools (greet, headers, time, slow, add_tool) | team-a |
| Test MCP Server 2 | `ghcr.io/kuadrant/mcp-gateway/test-server2:latest` | 7 tools (hello_world, headers, time, auth1234, slow, set_time, pour_chocolate_into_mold) | team-a |
| GitHub MCP Server | `ghcr.io/github/github-mcp-server:latest` | `--toolsets all --read-only`, PAT via env var (broker discovery) + Vault (per-user injection) | team-a |

## Auth

| Component | Version | Image / Source | Namespace |
|-----------|---------|----------------|-----------|
| Keycloak (RHBK) | 26.4.11-opr.1 | `registry.redhat.io/rhbk/keycloak-rhel9@sha256:a8ec9c...` | keycloak |
| Keycloak realm | `mcp-gateway` | 6 clients, 3 groups, 3 users (see below) | keycloak |
| Vault | 1.21.2 | `registry.connect.redhat.com/hashicorp/vault:1.21.2-ubi` (Helm chart 0.32.0) | openshift-operators |
| AuthPolicy (gateway) | `team-a-gateway-auth` | JWT + OPA wristband on `mcp` listener; group → VirtualMCPServer routing | team-a |
| AuthPolicy (per-server) | `openshift-mcp-admin-only` | `mcp-admin` role required for OpenShift MCP server HTTPRoute | team-a |
| AuthPolicy (Vault) | `github-mcp-vault-auth` | JWT → Vault login → per-user PAT injection for GitHub MCP server | team-a |

**Keycloak realm details:**

| Type | Names |
|------|-------|
| Clients | `mcp-gateway`, `mcp-playground`, `team-a/openshift-mcp-server`, `team-a/test-mcp-server`, `team-a/test-mcp-server2`, `team-a/github-mcp-server` |
| Groups | `mcp-admins`, `mcp-users`, `mcp-github` |
| Users | `mcp-admin1` (mcp-admins), `mcp-user1` (mcp-users), `mcp-github1` (mcp-github) |

## AI Stack

| Component | Version | Image | Namespace |
|-----------|---------|-------|-----------|
| Llama Stack (Playground) | 0.6.0.1+rhai0 | `quay.io/rhoai/odh-llama-stack-core-rhel9@sha256:14b97a...` | gpt-oss |
| vLLM 20B | — | `registry.redhat.io/rhaii-early-access/vllm-cuda-rhel9@sha256:abf0fd...` | gpt-oss |
| vLLM 120B | — | `registry.redhat.io/rhaii-early-access/vllm-cuda-rhel9@sha256:abf0fd...` | gpt-oss |
| `gen-ai-aa-mcp-servers` ConfigMap | — | Points to `https://team-a-mcp.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com/mcp` | redhat-ods-applications |

## Custom Builds

| Image | Built from | Reason |
|-------|-----------|--------|
| `quay.io/jrao/mcp-lifecycle-operator:release-0.1` | `openshift/mcp-lifecycle-operator` branch `release-0.1` | PR #16 shipped `main` image incompatible with `release-0.1` CRD (no `.status.phase`, crash-loop on `.status.observedGeneration`) |

## Workarounds Applied

| Target | Workaround | Reason |
|--------|-----------|--------|
| CRD `mcpservers.mcp.x-k8s.io` | Patched to add `.status.observedGeneration` | Missing from generated schema, caused SSA crash-loop |
| HTTPRoute `openshift-mcp-server` | `RequestHeaderModifier` filter removes `Authorization` header | Envoy forwards user's Keycloak JWT to backend; MCP server uses it as K8s credentials instead of SA token |
| Keycloak realm `mcp-gateway` | Access token TTL increased to 1800s (30 min) | Default 300s TTL caused frequent 401s during Playground testing |
