# MCP Ecosystem Experimentation

A reproducible experiment exploring how five MCP ecosystem projects work together end-to-end: **discovery** (model-registry catalog), **deployment** (lifecycle operator), **routing** (mcp-gateway), **authentication** (Keycloak + Kuadrant/Authorino), and **per-tool authorization** (AuthPolicy with CEL predicates).

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
Kuadrant AuthPolicy  — "who can call which tools on which servers"
  | per-HTTPRoute policies with CEL predicates
MCP Gateway          — "route requests securely to the server"
```

## Documentation

- [docs/experimentation.md](docs/experimentation.md) — Full chronological narrative of the experiment (Phases 1-13), from initial project analysis through deployment, request tracing, authentication, catalog integration, gateway automation, and per-tool authorization
- [docs/changes-tracker.md](docs/changes-tracker.md) — Structured changelog of every code modification and integration friction point discovered
- [docs/diagrams/](docs/diagrams/) — Mermaid diagrams of the architecture, request flow, pipeline, and operator reconciliation logic

## Prerequisites

- [Kind](https://kind.sigs.k8s.io/) (tested with v0.27+)
- [Podman](https://podman.io/) or Docker
- kubectl
- [Helm](https://helm.sh/)

## Quick Start

The setup script creates a Kind cluster and deploys all components:

```bash
./scripts/setup.sh
```

This takes approximately 5 minutes and sets up: Kind cluster, Istio (as Gateway API controller), MetalLB, Envoy gateway, mcp-gateway (broker/router/controller), lifecycle operator, catalog system, Keycloak, Kuadrant (Authorino), two test MCP servers, and per-tool AuthPolicies.

To reuse an existing Kind cluster:

```bash
./scripts/setup.sh --skip-cluster
```

To tear down:

```bash
kind delete cluster --name mcp-gateway
```

## Verifying the Setup

Run the automated authorization test matrix:

```bash
./scripts/test-auth-matrix.sh
```

This authenticates as all three test users via Keycloak's direct access grant, calls every tool on both servers, and verifies the correct allow/deny outcome for each combination (15 test cases).

### Authorization Matrix

Two test servers with distinct tools, five access control patterns:

| | greet | add_tool | hello_world | auth1234 | set_time |
|---|---|---|---|---|---|
| **Policy** | dev-only | ops-only | *no group* | ops-only | shared |
| Alice (developers) | allow | deny | deny | deny | allow |
| Bob (ops) | deny | allow | deny | allow | allow |
| Carol (both) | allow | allow | deny | allow | allow |

- **server1** (greet, time, slow, headers, add_tool): `developers` can call greet, `ops` can call add_tool
- **server2** (hello_world, time, headers, auth1234, slow, set_time): `developers` can call set_time, `ops` can call auth1234 + set_time
- **hello_world** is not in any policy — tests that tool existence does not imply access

### Interactive Client

```bash
./scripts/mcp-client.sh
```

Authenticates via browser-based device flow, then drops into a tool-calling REPL. Log in as any user (alice/alice, bob/bob, carol/carol). Use `/login` to switch users, `/tools` to list tools, `/whoami` to check identity.

### Quick Test (curl)

```bash
# Get a token (direct access grant)
TOKEN=$(curl -s -X POST http://keycloak.127-0-0-1.sslip.io:8002/realms/mcp/protocol/openid-connect/token \
  -d 'grant_type=password&client_id=mcp-cli&username=alice&password=alice&scope=openid groups' \
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

## Accessing Services

| Service | URL | Description |
|---------|-----|-------------|
| MCP Gateway | http://mcp.127-0-0-1.sslip.io:8001/mcp | Envoy gateway (authenticated) |
| MCP Launcher | http://localhost:8004 | Catalog UI + deployment |
| Keycloak | http://keycloak.127-0-0-1.sslip.io:8002 | OIDC provider (admin: admin/admin) |
| Keycloak OIDC Discovery | http://keycloak.127-0-0-1.sslip.io:8002/realms/mcp/.well-known/openid-configuration | Realm endpoints |

## Test Users

All passwords match the username.

| User | Password | Groups | Server1 access | Server2 access |
|------|----------|--------|----------------|----------------|
| alice | alice | developers | greet | set_time |
| bob | bob | ops | add_tool | auth1234, set_time |
| carol | carol | developers, ops | greet, add_tool | auth1234, set_time |

## Repository Structure

```
├── docs/
│   ├── experimentation.md                      # Full experiment narrative (Phases 1-13)
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
│   ├── kuadrant/                               # Kuadrant CR
│   ├── catalog/                                # Catalog API + PostgreSQL
│   ├── keycloak/                               # Keycloak deployment + realm import
│   ├── launcher/                               # MCP Launcher deployment + RBAC
│   ├── operator-gateway/                       # Operator gateway RBAC additions
│   ├── auth/                                   # Kuadrant AuthPolicies (gateway + per-server)
│   └── test-servers/                           # MCPServer CRs for test-server1 and test-server2
├── scripts/
│   ├── setup.sh                                # Full cluster setup from scratch
│   ├── test-auth-matrix.sh                     # Automated 15-case auth verification
│   └── mcp-client.sh                           # Interactive MCP client (device auth flow)
├── progress.md                                 # Session handoff / current state
└── README.md
```

## Custom Images

Pre-built images are available on quay.io:

| Image | Source |
|-------|--------|
| `quay.io/jrao/mcp-launcher:catalog-api` | [mcp-launcher](https://github.com/matzew/mcp-launcher) fork, branch `catalog-api-integration` — adds catalog REST API backend |
| `quay.io/jrao/mcp-lifecycle-operator:gateway-integration` | [mcp-lifecycle-operator](https://github.com/kubernetes-sigs/mcp-lifecycle-operator) fork, branch `gateway-integration` — adds gateway controller for automatic HTTPRoute/MCPServerRegistration creation |
| `quay.io/keycloak/keycloak:26.3` | Upstream Keycloak OIDC provider (no custom build) |

## Key Findings

The experiment surfaced several integration friction points documented in detail in [docs/changes-tracker.md](docs/changes-tracker.md). The most significant:

1. **Per-tool authorization works at the gateway with no code changes** — Kuadrant AuthPolicy + CEL predicates enable per-group, per-tool, cross-server authorization. The Router sets `x-mcp-toolname` and `:authority` headers before the auth check runs, giving Authorino full visibility into tool and server identity.

2. **Envoy filter chain order is critical** — ext_proc (Router) runs before the Kuadrant Wasm plugin (auth). This was initially assumed to be the opposite, which would have made per-tool authorization impossible at the gateway. Always verify filter chain order via the Envoy config dump.

3. **`tools/list` is the authorization blind spot** — `tools/call` is fully enforced at the gateway, but `tools/list` returns all tools to all users. The broker aggregates without identity-based filtering, requiring application-level changes for consistent UX.

4. **Catalog metadata is insufficient for deployment** — `runtimeMetadata` covers port and path but not container command, arguments, or security context. Each MCP server image is potentially a snowflake.

5. **The annotation-based gateway integration pattern works well** — using `mcp.x-k8s.io/gateway-ref` annotations on MCPServer CRs avoids upstream spec changes while enabling automatic gateway registration.

See [docs/experimentation.md](docs/experimentation.md) for the full narrative including the auth layer investigation (Istio 403 vs OAuth 401), the OIDC/PKCE flow, the Keycloak migration, and the per-tool authorization evolution.
