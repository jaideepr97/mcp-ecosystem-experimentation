# MCP Ecosystem Experimentation

A reproducible experiment exploring how MCP ecosystem projects work together end-to-end: **discovery** (model-registry catalog), **deployment** (lifecycle operator), **routing** (mcp-gateway with namespace-isolated gateways), **authentication** (Keycloak + Kuadrant/Authorino), **per-tool authorization** (AuthPolicy with CEL predicates), **TLS** (cert-manager + Kuadrant TLSPolicy), **per-user credential exchange** (Vault token exchange for upstream API tokens), and **multi-tenancy** (gateway-per-namespace isolation).

Powered heavily by Claude Code 

## Branches

This repo has three branches at increasing levels of complexity:

| Branch | Phases | What it covers |
|--------|--------|----------------|
| [`basic`](../../tree/basic) | 1-10 | Core pipeline: Kind + Istio + mcp-gateway + lifecycle operator + catalog + mini-oidc authentication |
| [`intermediate`](../../tree/intermediate) | 1-16 | Adds Keycloak, Kuadrant/Authorino, per-tool authorization, TLS, Vault credential exchange, GitHub MCP server |
| [`main`](../../tree/main) | 1-18+ | Active development — multi-tenancy, VirtualMCPServers, AuthPolicies, Vault credential injection |

Start with `basic` to understand the fundamentals, then move to `intermediate` for the full auth and security stack.

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
Vault Token Exchange — "swap user JWT for upstream API credentials"
  | Keycloak JWT → Vault JWT login → per-user secret read
MCP Gateway          — "route requests securely to the server"
  (one gateway per team namespace for isolation)
```

## Current State (Phase 18)

The experiment has progressed through namespace-isolated multi-tenancy (Phase 16), per-group VirtualMCPServers and AuthPolicies (Phase 17), and Vault credential injection patterns (Phase 18):

- `team-a` has its own Gateway, MCP gateway extension, 2 test servers (12 tools total), and 3 VirtualMCPServers
- 5 Keycloak users across 3 groups (`team-a-developers`, `team-a-ops`, `team-a-leads`)
- Gateway AuthPolicy injects `X-Mcp-Virtualserver` header based on group — clients never select their virtual server
- Per-HTTPRoute AuthPolicies enforce tool-level authorization via CEL predicates and inject Vault credentials:
  - **Server-a1**: team-level credential (`X-Team-Credential`) keyed by group membership
  - **Server-a2**: per-user credential (`X-User-Credential`) keyed by JWT `sub` claim
- Each team namespace is fully isolated: its own Gateway, its own MCP servers, its own routes

See [docs/experimentation.md](docs/experimentation.md) for the full chronological narrative.

## Documentation

- [docs/experimentation.md](docs/experimentation.md) — Full chronological narrative of the experiment (Phases 1-18), from initial project analysis through deployment, request tracing, authentication, catalog integration, gateway automation, per-tool authorization, TLS, Vault credential exchange, multi-tenancy, VirtualMCPServers, and credential injection patterns
- [docs/persona-flows.md](docs/persona-flows.md) — End-to-end walkthrough of the two RHAISTRAT-1149 personas: Platform Engineer (infrastructure provisioning) and AI Engineer (tool discovery and usage)
- [docs/friction-points.md](docs/friction-points.md) — Upstream limitations requiring workarounds, organized by project with severity and durability assessment
- [docs/changes-tracker.md](docs/changes-tracker.md) — Structured changelog of every code modification and deployment artifact
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

**NOTE:** This setup deploys the GitHub MCP server, which requires a PAT to be set to work as expected. Set your GitHub PAT by running `export GITHUB_PAT=<pat>` beforehand.

```bash
./scripts/guided-setup.sh
```

![Guided Setup](docs/images/guided-setup.gif)

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

This takes approximately 10 minutes and sets up: Kind cluster, Istio (as Gateway API controller), MetalLB, cert-manager, Envoy gateway, mcp-gateway (broker/router/controller), lifecycle operator, catalog system, Keycloak, Kuadrant (Authorino), Vault, team-a namespace with gateway + servers + VirtualMCPServers + AuthPolicies + Vault credential injection.

To reuse an existing Kind cluster:

```bash
./scripts/setup.sh --skip-cluster
```

### Tear down

```bash
kind delete cluster --name mcp-ecosystem
```

## Verifying the Setup

Run the automated pipeline test:

```bash
./scripts/test-pipeline.sh
```

This verifies the full pipeline end-to-end across 10 phases:
1. **Shared infrastructure** — namespaces, controllers, operators running
2. **Catalog API** — lists available servers with OCI artifact URIs
3. **team-a namespace** — gateway, broker, servers deployed and ready
4. **Authentication** — Keycloak issues tokens for all users, unauthenticated requests rejected with 401
5. **VirtualMCPServer filtering** — per-group tool visibility (dev1 sees 6, ops1 sees 6, lead1 sees 12)
6. **Authorization matrix** — per-group tool access enforcement across both servers
7. **TLS** — cert-manager, TLSPolicy, HTTPS endpoints
8. **Launcher** — catalog UI accessible
9. **Tool delisting** — VirtualMCPServer filtering-only behavior (removed tool hidden but still callable)
10. **Vault credential injection** — team-level and per-user credentials injected via AuthPolicy metadata evaluators

### Authorization Matrix (team-a — Phases 17-18)

Per-tool, per-group access control across two servers with Vault credential injection:

**test-server-a1** (5 tools, team-level credential via `X-Team-Credential`):

| | greet | time | headers | add_tool | slow |
|---|---|---|---|---|---|
| developers (dev1, dev2) | allow | allow | allow | deny | deny |
| ops (ops1, ops2) | deny | deny | deny | allow | allow |
| leads (lead1) | allow | allow | allow | allow | allow |

**test-server-a2** (7 tools, per-user credential via `X-User-Credential`):

| | hello_world | time | headers | auth1234 | set_time | slow | pour_chocolate_into_mold |
|---|---|---|---|---|---|---|---|
| developers | allow | allow | allow | deny | deny | deny | deny |
| ops | deny | deny | deny | allow | allow | allow | allow |
| leads | allow | allow | allow | allow | allow | allow | allow |

### Interactive Client

```bash
./scripts/mcp-client.sh
```

Authenticates against Keycloak via browser-based device flow, then drops into a tool-calling REPL. Log in as any team-a user (dev1/dev1, ops1/ops1, lead1/lead1). Use `/login` to switch users, `/tools` to list tools, `/whoami` to check identity.

### Quick Test (curl)

```bash
# Get a token (direct access grant — scope=openid groups is required)
TOKEN=$(curl -s http://keycloak.127-0-0-1.sslip.io:8002/realms/mcp/protocol/openid-connect/token \
  -d 'grant_type=password&client_id=mcp-cli&username=dev1&password=dev1&scope=openid groups' \
  | jq -r .access_token)

# Initialize an MCP session
SESSION=$(curl -si -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  http://team-a.mcp.127-0-0-1.sslip.io:8001/mcp | grep -i mcp-session-id | awk '{print $2}' | tr -d '\r')

# List tools (dev1 sees 6 tools filtered by VirtualMCPServer)
curl -s -H "Authorization: Bearer $TOKEN" \
  -H "Mcp-Session-Id: $SESSION" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  http://team-a.mcp.127-0-0-1.sslip.io:8001/mcp

# Call a tool (Vault credential injected transparently)
curl -s -H "Authorization: Bearer $TOKEN" \
  -H "Mcp-Session-Id: $SESSION" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"test_server_a1_headers","arguments":{}}}' \
  http://team-a.mcp.127-0-0-1.sslip.io:8001/mcp
```

## Accessing Services

| Service | URL | Description |
|---------|-----|-------------|
| Keycloak (HTTP) | http://keycloak.127-0-0-1.sslip.io:8002 | OIDC provider (admin: admin/admin) |
| Keycloak (HTTPS) | https://keycloak.127-0-0-1.sslip.io:8445 | TLS-terminated (use `--cacert /tmp/mcp-ca.crt`) |
| Keycloak OIDC Discovery | http://keycloak.127-0-0-1.sslip.io:8002/realms/mcp/.well-known/openid-configuration | Realm endpoints |
| Vault | ClusterIP only (`vault.vault.svc:8200`) | Dev mode, root token: `root` |
| team-a MCP Gateway | `kubectl port-forward -n team-a svc/<gateway-svc> 8080:80` | Per-namespace gateway (port-forward) |

## Test Users

All passwords match the username.

### team-a namespace (Phases 16-18)

| User | Password | Group | VirtualMCPServer | Tools visible |
|------|----------|-------|-----------------|---------------|
| dev1 | dev1 | team-a-developers | team-a-dev-tools | 6 |
| dev2 | dev2 | team-a-developers | team-a-dev-tools | 6 |
| ops1 | ops1 | team-a-ops | team-a-ops-tools | 6 |
| ops2 | ops2 | team-a-ops | team-a-ops-tools | 6 |
| lead1 | lead1 | team-a-leads | team-a-lead-tools | 12 |

## Repository Structure

```
├── docs/
│   ├── experimentation.md                      # Full experiment narrative (Phases 1-18)
│   ├── persona-flows.md                        # Platform Engineer + AI Engineer end-to-end flows
│   ├── friction-points.md                      # Upstream limitations + workarounds
│   ├── changes-tracker.md                      # Code changes + deployment artifacts
│   └── diagrams/
│       ├── component-architecture.mermaid      # Cluster component map
│       ├── multi-tenancy-architecture.mermaid  # Namespace isolation + control plane
│       ├── request-flow.mermaid                # Authenticated MCP request sequence
│       ├── team-a-request-flow.mermaid         # team-a request flow with credential injection
│       ├── tls-architecture.mermaid            # TLS certificate chain + termination flow
│       ├── catalog-to-gateway-pipeline.mermaid # End-to-end pipeline flow
│       └── operator-reconciliation.mermaid     # Operator reconciler logic
├── infrastructure/kind/
│   ├── kind/                                   # Kind cluster config (HTTP + HTTPS ports)
│   ├── istio/                                  # Istio (Sail operator) config
│   ├── metallb/                                # MetalLB IP pool script
│   ├── cert-manager/                           # CA issuers + TLSPolicy
│   ├── mcp-gateway/                            # CRDs + controller/broker deployment
│   ├── lifecycle-operator/                     # Operator deployment manifest
│   ├── kuadrant/                               # Kuadrant CR
│   ├── catalog/                                # Catalog API + PostgreSQL
│   ├── keycloak/                               # Keycloak deployment + realm import + TLS
│   ├── operator-gateway/                       # Operator gateway RBAC additions
│   ├── vault/                                  # Vault deployment + configuration script
│   └── team-a/                                 # Team-A namespace: gateway, MCP extension, test servers
├── scripts/
│   ├── guided-setup.sh                         # Interactive guided setup with gum TUI
│   ├── setup.sh                                # Non-interactive full cluster setup
│   ├── test-pipeline.sh                        # Full pipeline + auth matrix + TLS + Vault tests
│   ├── test-auth-matrix.sh                     # Auth matrix only (subset of test-pipeline)
│   ├── mcp-client.sh                           # Interactive MCP client (device auth flow)
│   └── store-github-pat.sh                     # Store a GitHub PAT in Vault for a Keycloak user
├── progress.md                                 # Session handoff / current state
└── README.md
```

## Custom Images

Pre-built images are available on quay.io:

| Image | Source |
|-------|--------|
| `quay.io/jrao/mcp-launcher:catalog-api` | [mcp-launcher](https://github.com/matzew/mcp-launcher) fork, branch `catalog-api-integration` — adds catalog REST API backend |
| `quay.io/jrao/mcp-lifecycle-operator:gateway-integration` | [mcp-lifecycle-operator](https://github.com/kubernetes-sigs/mcp-lifecycle-operator) fork, branch `gateway-integration` — adds gateway controller for automatic HTTPRoute/MCPServerRegistration creation |
| `quay.io/jrao/mcp-lifecycle-operator:gateway-credential-ref` | Same fork, branch `gateway-credential-ref` — adds `credentialRef` annotation support for per-server credential secrets |
| `quay.io/keycloak/keycloak:26.3` | Upstream Keycloak OIDC provider (no custom build) |

Key findings and friction points are documented in [docs/friction-points.md](docs/friction-points.md). For the full experiment narrative, see [docs/experimentation.md](docs/experimentation.md). For end-to-end Platform Engineer and AI Engineer workflows, see [docs/persona-flows.md](docs/persona-flows.md).
