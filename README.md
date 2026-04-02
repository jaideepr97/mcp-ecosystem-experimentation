# MCP Ecosystem Experimentation

A reproducible experiment exploring how five MCP ecosystem projects work together end-to-end: **discovery** (model-registry catalog), **deployment** (lifecycle operator), **routing** (mcp-gateway), **authentication** (Keycloak + Kuadrant/Authorino), and **per-tool authorization** (AuthPolicy with CEL predicates).

## Acknowledgements

- [@matzew](https://github.com/matzew) for [mcp-launcher](https://github.com/matzew/mcp-launcher) — the catalog UI and deployment frontend used in this experiment (forked with catalog API integration)
- [@Cali0707](https://github.com/Cali0707) for the [mcp-gateway integration PR](https://github.com/openshift/mcp-lifecycle-operator/pull/3) on the lifecycle operator — the gateway controller that automates HTTPRoute and MCPServerRegistration creation was adapted from this work

## Overview

The result is a fully automated pipeline:

```
Catalog API          — "what's available"
  ↓ REST API
MCP Launcher         — "browse, configure, deploy"
  ↓ creates MCPServer CR (with gateway-ref annotation)
Lifecycle Operator   — "make it run AND make it routable"
  ↓ creates Deployment + Service + HTTPRoute + MCPServerRegistration
Kuadrant AuthPolicy  — "who can call which tools on which servers"
  ↓ per-HTTPRoute policies with CEL predicates
MCP Gateway          — "route requests securely to the server"
```

## Documentation

- [docs/experimentation.md](docs/experimentation.md) — Full chronological narrative of the experiment, from initial project analysis through deployment, request tracing, authentication, catalog integration, gateway automation, and per-tool authorization
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

### Step 4: Keycloak (OIDC provider)

```bash
kubectl create namespace keycloak
kubectl apply -f keycloak/realm-import.yaml
kubectl apply -f keycloak/deployment.yaml
kubectl patch gateway mcp-gateway -n gateway-system --type json -p "$(cat keycloak/gateway-patch.json)"
kubectl apply -f keycloak/httproute.yaml

# Wait for Keycloak to be ready (can take 30-60s)
kubectl wait --for=condition=Ready pod -l app=keycloak -n keycloak --timeout=120s
```

### Step 5: Kuadrant operator (auth enforcement)

```bash
helm repo add kuadrant https://kuadrant.io/helm-charts/
helm install kuadrant-operator kuadrant/kuadrant-operator -n kuadrant-system --create-namespace

# Create the Kuadrant CR (from mcp-gateway's config)
kubectl apply -f /path/to/mcp-gateway/config/kuadrant/kuadrant.yaml

# Wait for Authorino to be ready
kubectl wait --for=condition=Ready pod -l app=authorino -n kuadrant-system --timeout=120s

# Patch CoreDNS so Authorino can reach Keycloak via the gateway
# (sslip.io resolves to 127.0.0.1 inside pods — need to map to gateway LB IP)
GATEWAY_IP=$(kubectl get svc -n gateway-system -l gateway.networking.k8s.io/gateway-name=mcp-gateway -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
kubectl get configmap coredns -n kube-system -o yaml | \
  sed "s/ready/hosts {\n          $GATEWAY_IP keycloak.127-0-0-1.sslip.io\n          fallthrough\n        }\n        ready/" | \
  kubectl apply -f -
kubectl rollout restart deployment coredns -n kube-system
```

Apply the gateway-level AuthPolicy (JWT auth + 401 response):

```bash
kubectl apply -f auth/authpolicy.yaml
```

### Step 6: MCP Launcher

```bash
kubectl apply -f launcher/rbac.yaml
kubectl apply -f launcher/deployment.yaml
```

### Step 7: Deploy servers and apply per-server AuthPolicies

Deploy MCP servers (via launcher UI at http://localhost:8004 or directly):

```bash
kubectl apply -f examples/test-server1.yaml
kubectl apply -f examples/test-server2.yaml

# Wait for the operator to create Deployments, Services, HTTPRoutes, and MCPServerRegistrations
kubectl wait --for=condition=Ready mcpserver/test-server1 -n mcp-test --timeout=120s
kubectl wait --for=condition=Ready mcpserver/test-server2 -n mcp-test --timeout=120s

# Restart mcp-gateway to pick up new registrations (if needed)
kubectl rollout restart deployment mcp-gateway -n mcp-system
```

Apply per-server AuthPolicies for tool-level authorization:

```bash
kubectl apply -f auth/authpolicy-server1.yaml
kubectl apply -f auth/authpolicy-server2.yaml
```

These policies enforce per-group, per-tool access control:
- **server1**: `developers` can call greet+time, `ops` can call time+headers
- **server2**: `developers` can call slow, `ops` can call headers+add_tool
- Users in both groups (carol) get the union of permissions

## Accessing services

| Service | URL | Description |
|---------|-----|-------------|
| MCP Gateway | http://mcp.127-0-0-1.sslip.io:8001/mcp | Envoy gateway (authenticated) |
| MCP Launcher | http://localhost:8004 | Catalog UI + deployment |
| Keycloak | http://keycloak.127-0-0-1.sslip.io:8002 | OIDC provider (admin: admin/admin) |
| Keycloak OIDC Discovery | http://keycloak.127-0-0-1.sslip.io:8002/realms/mcp/.well-known/openid-configuration | Realm endpoints |

### Interactive client (recommended)

```bash
# Authenticates via browser-based device flow, then drops into a tool-calling REPL
./scripts/mcp-client.sh
```

Log in as any user (alice/alice, bob/bob, carol/carol). Use `/login` to switch users, `/tools` to list tools, `/whoami` to check identity.

### Quick test (curl)

```bash
# Get a token from Keycloak
TOKEN=$(curl -s -X POST http://keycloak.127-0-0-1.sslip.io:8002/realms/mcp/protocol/openid-connect/token \
  -d 'grant_type=client_credentials&client_id=mcp-gateway&client_secret=secret' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Initialize an MCP session
SESSION=$(curl -si -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  http://mcp.127-0-0-1.sslip.io:8001/mcp | grep -i mcp-session-id | awk '{print $2}' | tr -d '\r')

# List tools through the gateway
curl -s -H "Authorization: Bearer $TOKEN" \
  -H "Mcp-Session-Id: $SESSION" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  http://mcp.127-0-0-1.sslip.io:8001/mcp
```

## Repository structure

```
├── docs/
│   ├── experimentation.md         # Full experiment narrative (Phases 1-12)
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
├── keycloak/                      # keycloak namespace
│   ├── realm-import.yaml              # Minimal realm (mcp-gateway client + scopes)
│   ├── deployment.yaml                # Keycloak 26.3 dev mode + Service
│   ├── gateway-patch.json             # HTTP listener on port 8002
│   └── httproute.yaml                 # Routes with OAuth discovery path rewrite
├── auth/                          # Kuadrant AuthPolicies
│   ├── authpolicy.yaml                # Gateway-level JWT auth + 401 response
│   ├── authpolicy-server1.yaml        # Per-server: developers + tool ACLs
│   └── authpolicy-server2.yaml        # Per-server: ops + tool ACLs
├── launcher/                      # mcp-test namespace
│   ├── rbac.yaml
│   └── deployment.yaml
├── operator-gateway/              # Operator RBAC additions
│   ├── gateway-role.yaml
│   └── gateway-role-binding.yaml
├── scripts/
│   └── mcp-client.sh              # Interactive MCP client (device auth flow)
└── examples/
    ├── test-server1.yaml          # MCPServer CR with gateway annotation
    └── test-server2.yaml          # Second test server (same image, different name)
```

## Custom images

Pre-built images are available on quay.io:

| Image | Source |
|-------|--------|
| `quay.io/jrao/mcp-launcher:catalog-api` | [mcp-launcher](https://github.com/matzew/mcp-launcher) fork, branch `catalog-api-integration` — adds catalog REST API backend |
| `quay.io/jrao/mcp-lifecycle-operator:gateway-integration` | [mcp-lifecycle-operator](https://github.com/kubernetes-sigs/mcp-lifecycle-operator) fork, branch `gateway-integration` — adds gateway controller for automatic HTTPRoute/MCPServerRegistration creation |
| `quay.io/keycloak/keycloak:26.3` | Upstream Keycloak OIDC provider (no custom build) |

## Key findings

The experiment surfaced several integration friction points documented in detail in [docs/changes-tracker.md](docs/changes-tracker.md). The most significant:

1. **Per-tool authorization works at the gateway with no code changes** — Kuadrant AuthPolicy + CEL predicates enable per-group, per-tool, cross-server authorization. The Router sets `x-mcp-toolname` and `:authority` headers before the auth check runs, giving Authorino full visibility into tool and server identity.

2. **Envoy filter chain order is critical** — ext_proc (Router) runs before the Kuadrant Wasm plugin (auth). This was initially assumed to be the opposite, which would have made per-tool authorization impossible at the gateway. Always verify filter chain order via the Envoy config dump.

3. **`tools/list` is the authorization blind spot** — `tools/call` is fully enforced at the gateway, but `tools/list` returns all tools to all users. The broker aggregates without identity-based filtering, requiring application-level changes for consistent UX.

4. **Catalog metadata is insufficient for deployment** — `runtimeMetadata` covers port and path but not container command, arguments, or security context. Each MCP server image is potentially a snowflake.

5. **The annotation-based gateway integration pattern works well** — using `mcp.x-k8s.io/gateway-ref` annotations on MCPServer CRs avoids upstream spec changes while enabling automatic gateway registration.

See [docs/experimentation.md](docs/experimentation.md) for the full narrative including the auth layer investigation (Istio 403 vs OAuth 401), the OIDC/PKCE flow, the Keycloak migration, and the per-tool authorization evolution.
