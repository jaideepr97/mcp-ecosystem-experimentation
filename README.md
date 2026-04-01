# MCP Ecosystem Experimentation

A reproducible experiment exploring how four MCP ecosystem projects work together end-to-end: **discovery** (model-registry catalog), **deployment** (lifecycle operator), **routing** (mcp-gateway), and **authentication** (Istio + custom OIDC provider).

The result is a fully automated pipeline:

```
Catalog API          — "what's available"
  ↓ REST API
MCP Launcher         — "browse, configure, deploy"
  ↓ creates MCPServer CR (with gateway-ref annotation)
Lifecycle Operator   — "make it run AND make it routable"
  ↓ creates Deployment + Service + HTTPRoute + MCPServerRegistration
MCP Gateway          — "route requests securely to the server"
```

## Documentation

- [docs/experimentation.md](docs/experimentation.md) — Full chronological narrative of the experiment, from initial project analysis through deployment, request tracing, authentication, catalog integration, and gateway automation
- [docs/changes-tracker.md](docs/changes-tracker.md) — Structured changelog of every code modification and integration friction point discovered
- [docs/diagrams/](docs/diagrams/) — Mermaid diagrams of the architecture, request flow, pipeline, and operator reconciliation logic

## Prerequisites

- [Kind](https://kind.sigs.k8s.io/) (tested with v0.27+)
- [Podman](https://podman.io/) or Docker
- kubectl
- Go 1.25+ (only if building from source)
- The following project repos cloned locally:
  - [mcp-gateway](https://github.com/kuadrant/mcp-gateway)
  - [mcp-lifecycle-operator](https://github.com/kubernetes-sigs/mcp-lifecycle-operator) (upstream)

## Setup

### Step 1: Kind cluster + Gateway infrastructure

From the **mcp-gateway** repo:

```bash
cd /path/to/mcp-gateway
export CONTAINER_ENGINE=podman

make tools
make kind-create-cluster    # Creates "mcp-gateway" Kind cluster with port mappings
make gateway-api-install
make istio-install
make metallb-install
make build-and-load-image
make deploy-gateway
make deploy                 # CRDs + controller
```

This sets up: Kind cluster, Istio (as Gateway API controller), MetalLB, Envoy gateway, and the mcp-gateway broker/router/controller.

### Step 2: Lifecycle operator

From the **mcp-lifecycle-operator** repo (upstream):

```bash
cd /path/to/mcp-lifecycle-operator
make install    # Apply MCPServer CRD
make deploy     # Deploy operator
```

Then apply the gateway integration RBAC so the operator can manage HTTPRoutes and MCPServerRegistrations:

```bash
kubectl apply -f operator-gateway/gateway-role.yaml
kubectl apply -f operator-gateway/gateway-role-binding.yaml
```

To use the pre-built operator image with gateway integration (recommended):

```bash
# Load the image with gateway controller support
podman pull quay.io/jrao/mcp-lifecycle-operator:gateway-integration
podman save quay.io/jrao/mcp-lifecycle-operator:gateway-integration -o /tmp/operator.tar
kind load image-archive /tmp/operator.tar --name mcp-gateway

# Update the operator deployment to use it
kubectl set image deployment/mcp-lifecycle-operator-controller-manager \
  -n mcp-lifecycle-operator-system \
  manager=quay.io/jrao/mcp-lifecycle-operator:gateway-integration

kubectl rollout restart deployment/mcp-lifecycle-operator-controller-manager \
  -n mcp-lifecycle-operator-system
```

> **Note**: If the operator pod hangs on "Attempting to acquire leader lease", delete the stale lease:
> ```bash
> kubectl delete lease bed7462b.x-k8s.io -n mcp-lifecycle-operator-system
> ```

### Step 3: Catalog service

```bash
kubectl create namespace catalog-system
kubectl apply -f catalog/postgres.yaml
kubectl apply -f catalog/catalog-sources.yaml
kubectl apply -f catalog/catalog.yaml

# Wait for pods to be ready
kubectl wait --for=condition=Ready pod -l app=mcp-catalog-postgres -n catalog-system --timeout=120s
kubectl wait --for=condition=Ready pod -l app=mcp-catalog -n catalog-system --timeout=120s
```

Verify the catalog API:
```bash
kubectl port-forward svc/mcp-catalog -n catalog-system 8080:8080 &
curl -s http://localhost:8080/api/mcp_catalog/v1alpha1/mcp_servers | python3 -m json.tool
kill %1
```

### Step 4: Authentication layer

Deploy the OIDC provider and Istio auth resources:

```bash
kubectl apply -f mini-oidc/mini-oidc.yaml
kubectl apply -f auth/request-authentication.yaml
kubectl apply -f auth/authorization-policy.yaml
kubectl apply -f auth/envoyfilter-401.yaml
```

### Step 5: MCP Launcher

```bash
kubectl apply -f launcher/rbac.yaml
kubectl apply -f launcher/deployment.yaml
```

### Step 6: Deploy a server from the catalog

Open the launcher UI at http://localhost:8004, browse the catalog, click "Edit YAML" on the configure page, and paste the example YAML:

```bash
kubectl apply -f examples/test-server1.yaml
```

Or use the launcher's YAML editor to deploy interactively.

## Accessing services

| Service | URL | Description |
|---------|-----|-------------|
| MCP Gateway | http://mcp.127-0-0-1.sslip.io:8001/mcp | Envoy gateway (authenticated) |
| MCP Launcher | http://localhost:8004 | Catalog UI + deployment |
| Mini-OIDC | http://localhost:8003 | OIDC provider (token issuance) |

### Quick test

```bash
# Get a token from mini-oidc
TOKEN=$(curl -s http://localhost:8003/token | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# List tools through the gateway
curl -s -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  http://mcp.127-0-0-1.sslip.io:8001/mcp
```

## Repository structure

```
├── docs/
│   ├── experimentation.md         # Full experiment narrative (Phases 1-11)
│   ├── changes-tracker.md         # Code changes + friction points
│   └── diagrams/
│       ├── component-architecture.mermaid  # Cluster component map
│       ├── request-flow.mermaid            # Authenticated MCP request sequence
│       ├── catalog-to-gateway-pipeline.mermaid  # End-to-end pipeline flow
│       └── operator-reconciliation.mermaid      # Operator reconciler logic
├── catalog/                       # catalog-system namespace
│   ├── postgres.yaml              # PostgreSQL backend
│   ├── catalog-sources.yaml       # MCP server definitions
│   └── catalog.yaml               # Catalog API deployment
├── auth/                          # gateway-system namespace
│   ├── request-authentication.yaml
│   ├── authorization-policy.yaml
│   └── envoyfilter-401.yaml
├── mini-oidc/                     # mcp-test namespace
│   └── mini-oidc.yaml
├── launcher/                      # mcp-test namespace
│   ├── rbac.yaml
│   └── deployment.yaml
├── operator-gateway/              # Operator RBAC additions
│   ├── gateway-role.yaml
│   └── gateway-role-binding.yaml
└── examples/
    └── test-server1.yaml          # MCPServer CR with gateway annotation
```

## Custom images

Pre-built images are available on quay.io:

| Image | Source |
|-------|--------|
| `quay.io/jrao/mcp-launcher:catalog-api` | [mcp-launcher](https://github.com/matzew/mcp-launcher) fork, branch `catalog-api-integration` — adds catalog REST API backend |
| `quay.io/jrao/mcp-lifecycle-operator:gateway-integration` | [mcp-lifecycle-operator](https://github.com/kubernetes-sigs/mcp-lifecycle-operator) fork, branch `gateway-integration` — adds gateway controller for automatic HTTPRoute/MCPServerRegistration creation |
| `quay.io/jrao/mini-oidc:latest` | Custom lightweight OIDC provider with OAuth 2.1 + PKCE support |

## Key findings

The experiment surfaced several integration friction points documented in detail in [docs/changes-tracker.md](docs/changes-tracker.md). The most significant:

1. **Catalog metadata is insufficient for deployment** — `runtimeMetadata` covers port and path but not container command, arguments, or security context. Each MCP server image is potentially a snowflake.

2. **OCI images are opaque to orchestrators** — without a standardized contract for MCP server images, every new server added to the catalog is a potential deployment failure requiring human debugging.

3. **The annotation-based gateway integration pattern works well** — using `mcp.x-k8s.io/gateway-ref` annotations on MCPServer CRs avoids upstream spec changes while enabling automatic gateway registration.

See [docs/experimentation.md](docs/experimentation.md) for the full narrative including the auth layer investigation (Istio 403 vs OAuth 401), the OIDC/PKCE flow, and the architectural evolution.
