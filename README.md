# MCP Ecosystem Experimentation (Basic)

A reproducible experiment exploring how four MCP ecosystem projects work together end-to-end: **discovery** (model-registry catalog), **deployment** (lifecycle operator), **routing** (mcp-gateway), and **authentication** (Istio + custom OIDC provider).

> **Note**: This is the `basic` branch — it covers Phases 1-11 of the experiment, using mini-oidc for authentication and Istio for JWT validation. The `main` branch extends this with Keycloak, Kuadrant/Authorino, and per-tool authorization.

## Acknowledgements

- [@matzew](https://github.com/matzew) for [mcp-launcher](https://github.com/matzew/mcp-launcher) — the catalog UI and deployment frontend used in this experiment (forked with catalog API integration)
- [@Cali0707](https://github.com/Cali0707) for the [mcp-gateway integration PR](https://github.com/openshift/mcp-lifecycle-operator/pull/3) on the lifecycle operator — the gateway controller that automates HTTPRoute and MCPServerRegistration creation was adapted from this work

## Overview

The result is a fully automated pipeline:

```
Catalog API          — "what's available"
  | REST API
MCP Launcher         — "browse, configure, deploy"
  | creates MCPServer CR (with gateway-ref annotation)
Lifecycle Operator   — "make it run AND make it routable"
  | creates Deployment + Service + HTTPRoute + MCPServerRegistration
MCP Gateway          — "route requests securely to the server"
```

## Documentation

- [docs/experimentation.md](docs/experimentation.md) — Full chronological narrative of the experiment (Phases 1-11), from initial project analysis through deployment, request tracing, authentication, catalog integration, and gateway automation
- [docs/changes-tracker.md](docs/changes-tracker.md) — Structured changelog of every code modification and integration friction point discovered
- [docs/diagrams/](docs/diagrams/) — Mermaid diagrams of the architecture, request flow, pipeline, and operator reconciliation logic

## Prerequisites

- [Kind](https://kind.sigs.k8s.io/) (tested with v0.27+)
- [Podman](https://podman.io/) or Docker
- kubectl
- [Helm](https://helm.sh/)
- [gum](https://github.com/charmbracelet/gum) (for guided setup — `brew install gum`)

## Quick Start

### Guided setup (recommended)

Walk through each phase interactively with explanations of what each component does and why:

```bash
./scripts/guided-setup.sh
```

Features:
- Rich TUI powered by [gum](https://github.com/charmbracelet/gum)
- Each phase explains what it deploys and why before prompting you to continue
- Shows all resources created after each phase completes
- Resume from where you left off with `--resume`
- Jump to a specific phase with `--phase N`
- Run non-interactively with `--batch`

### One-shot setup

For a non-interactive setup that runs all phases without prompts:

```bash
./scripts/setup.sh
```

This takes approximately 5 minutes and sets up: Kind cluster, Istio (as Gateway API controller), MetalLB, Envoy gateway, mcp-gateway (broker/router/controller), lifecycle operator, catalog system, mini-oidc OIDC provider, Istio JWT auth, a test MCP server, and the launcher UI.

To reuse an existing Kind cluster:

```bash
./scripts/setup.sh --skip-cluster
```

### Tear down

```bash
kind delete cluster --name mcp-gateway
```

## Verifying the Setup

Run the automated pipeline test:

```bash
./scripts/test-pipeline.sh
```

This verifies the full pipeline end-to-end (15 checks):
1. **Catalog API** — lists available servers with OCI artifact URIs
2. **Operator resources** — MCPServer CR triggered Deployment + Service creation
3. **Gateway integration** — operator created HTTPRoute + MCPServerRegistration
4. **Authentication** — mini-oidc issues tokens, unauthenticated requests are rejected with 401
5. **Gateway tool access** — MCP session initializes, tools are federated with prefixes, tool calls return results

### Quick test (curl)

```bash
# Get a token from mini-oidc
TOKEN=$(curl -s -X POST http://localhost:8003/token | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

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

## Accessing Services

| Service | URL | Description |
|---------|-----|-------------|
| MCP Gateway | http://mcp.127-0-0-1.sslip.io:8001/mcp | Envoy gateway (authenticated) |
| MCP Launcher | http://localhost:8004 | Catalog UI + deployment |
| Mini-OIDC | http://localhost:8003 | OIDC provider (token issuance) |

### Authentication

This branch uses a custom mini-oidc provider for JWT authentication. Tokens are issued via a POST request:

```bash
curl -X POST http://localhost:8003/token
```

Istio validates the JWT at the gateway level using RequestAuthentication + AuthorizationPolicy. A Lua EnvoyFilter attempts to return proper 401 responses with `WWW-Authenticate` headers, but Istio's RBAC filter runs first and returns 403 for missing tokens (see Key Findings).

## Repository Structure

```
├── docs/
│   ├── experimentation.md                      # Full experiment narrative (Phases 1-11)
│   ├── changes-tracker.md                      # Code changes + friction points
│   └── diagrams/
│       ├── component-architecture.mermaid      # Cluster component map
│       ├── request-flow.mermaid                # Authenticated MCP request sequence
│       ├── catalog-to-gateway-pipeline.mermaid # End-to-end pipeline flow
│       └── operator-reconciliation.mermaid     # Operator reconciler logic
├── infrastructure/
│   ├── kind/                                   # Kind cluster config
│   ├── istio/                                  # Istio (Sail operator) config
│   ├── gateway/                                # Gateway namespace, resource, nodeport
│   ├── metallb/                                # MetalLB IP pool script
│   ├── mcp-gateway/                            # CRDs + controller/broker deployment
│   ├── lifecycle-operator/                     # Operator deployment manifest
│   ├── catalog/                                # Catalog API + PostgreSQL
│   ├── mini-oidc/                              # Custom OIDC provider
│   ├── auth/                                   # Istio auth (RequestAuthentication,
│   │                                           #   AuthorizationPolicy, EnvoyFilter)
│   ├── launcher/                               # MCP Launcher deployment + RBAC
│   ├── operator-gateway/                       # Operator gateway RBAC additions
│   └── test-servers/                           # MCPServer CR for test-server1
├── scripts/
│   ├── guided-setup.sh                         # Interactive guided setup with gum TUI
│   ├── setup.sh                                # Non-interactive full cluster setup
│   └── test-pipeline.sh                        # Automated 15-check pipeline verification
└── README.md
```

## Custom Images

Pre-built images are available on quay.io:

| Image | Source |
|-------|--------|
| `quay.io/jrao/mini-oidc:latest` | Custom OIDC provider built during the experiment |
| `quay.io/jrao/mcp-launcher:catalog-api` | [mcp-launcher](https://github.com/matzew/mcp-launcher) fork, branch `catalog-api-integration` — adds catalog REST API backend |
| `quay.io/jrao/mcp-lifecycle-operator:gateway-integration` | [mcp-lifecycle-operator](https://github.com/kubernetes-sigs/mcp-lifecycle-operator) fork, branch `gateway-integration` — adds gateway controller for automatic HTTPRoute/MCPServerRegistration creation |

## Key Findings

The experiment surfaced several integration friction points documented in detail in [docs/changes-tracker.md](docs/changes-tracker.md). The most significant:

1. **Catalog metadata is insufficient for deployment** — `runtimeMetadata` covers port and path but not container command, arguments, or security context. Each MCP server image is potentially a snowflake.

2. **OCI image opacity is the systemic problem** — images differ across entrypoint conventions, transport selection, bind addresses, security context requirements, and runtime dependencies. The catalog tells you *what exists* but not *how to make it run*.

3. **The annotation-based gateway integration pattern works well** — using `mcp.x-k8s.io/gateway-ref` annotations on MCPServer CRs avoids upstream spec changes while enabling automatic gateway registration.

4. **Istio's 403 vs OAuth 401 gap** — Istio returns 403 for missing tokens instead of the 401 required by OAuth 2.1. A Lua EnvoyFilter workaround provides correct responses, but production deployments should use Kuadrant/Authorino (see `main` branch).

5. **ext_proc rewrites `:authority` on all port 8080 traffic** — the Router doesn't distinguish MCP from non-MCP requests, which prevents exposing other services through the same gateway port.

See [docs/experimentation.md](docs/experimentation.md) for the full narrative.
