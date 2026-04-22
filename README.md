# MCP Ecosystem Experimentation

A reproducible experiment exploring how MCP ecosystem projects work together end-to-end on OpenShift: **discovery** (RHOAI model-registry catalog), **deployment** (lifecycle operator), **routing** (MCP Gateway with Kuadrant), **authentication** (Keycloak + Authorino), **tool curation** (VirtualMCPServers + wristband per-user filtering), **per-user credential injection** (Vault token exchange), and **AI playground** (RHOAI Gen AI Studio + LlamaStack + vLLM).

Powered heavily by Claude Code

## Overview

```
RHOAI Model Registry    — "what MCP servers are available"
  | catalog API
RHOAI Dashboard         — "browse, configure, deploy"
  | creates MCPServer CR
Lifecycle Operator      — "make it run"
  | creates Deployment + Service
MCP Gateway             — "route, authenticate, filter, inject"
  | HTTPRoute + MCPServerRegistration + AuthPolicy + VirtualMCPServer
Keycloak + Authorino    — "who are you, what group, what tools"
  | JWT validation, group→VirtualMCPServer routing, wristband per-user roles
Vault                   — "swap user JWT for upstream API credentials"
  | Keycloak JWT → Vault JWT login → per-user secret → header injection
RHOAI Gen AI Studio     — "AI playground with MCP tool calling"
  | LlamaStack + vLLM (tool-calling model)
```

## Cluster

**Platform**: ROSA (Red Hat OpenShift on AWS)
**Cluster**: `agentic-mcp.jolf.p3.openshiftapps.com`

See [docs/component-versions.md](docs/component-versions.md) for all deployed component versions and images.

## Scripts

The demo is driven by three scripts in `scripts/`:

| Script | Description |
|--------|-------------|
| `scripts/setup.sh` | Guided interactive setup — installs operators, Keycloak, Vault, MCP Gateway, RHOAI registration |
| `scripts/usage.sh` | Three-phase demo — deploys MCP servers, configures auth, demonstrates tool filtering |
| `scripts/cleanup.sh` | Selective teardown — by script (setup/usage), phase, or individual step |

### Setup

Installs all shared infrastructure across 6 phases:

```bash
./scripts/setup.sh                   # guided run through all phases
./scripts/setup.sh --phase 3         # start from phase 3 onward
./scripts/setup.sh --phase 2 --only  # run only phase 2
```

**Phases**: (1) Operator subscriptions, (2) Keycloak, (3) Lifecycle Operator, (4) Vault, (5) MCP Gateway instance in team-a, (6) Playground

**Prerequisites**: See [docs/openshift-ai-prerequisites.md](docs/openshift-ai-prerequisites.md)

### Usage (Demo)

Walks through three phases demonstrating MCP server deployment, auth, and tool curation:

```bash
./scripts/usage.sh                   # guided run through all phases
./scripts/usage.sh --phase 2         # start from phase 2
./scripts/usage.sh --phase 1 --only  # run only phase 1
```

| Phase | What it deploys |
|-------|----------------|
| **1. OpenShift MCP Server** | Deploy, register with gateway, admin-only AuthPolicy, VirtualMCPServer for mcp-admins |
| **2. Test Servers** | Two test servers, catalog integration, user-tools + admin-tools VirtualMCPServers, wristband per-user filtering |
| **3. GitHub MCP Server** | GitHub server with Vault credential injection, per-user PATs, mcp-github group + roles |

### Cleanup

```bash
./scripts/cleanup.sh                  # clean everything (usage 3→1, setup 6→1)
./scripts/cleanup.sh usage            # clean all usage phases
./scripts/cleanup.sh usage 2          # clean only usage phase 2
./scripts/cleanup.sh usage 1.3        # clean only usage step 1.3
./scripts/cleanup.sh setup 5          # clean only setup phase 5
```

## Architecture

### Tool Filtering (Two Layers)

1. **VirtualMCPServer** (group-level): Keycloak group → VirtualMCPServer mapping via `x-mcp-virtualserver` header. Each virtual server defines which tools are visible.
2. **Wristband** (per-user): Keycloak client roles per MCP server determine which tools each user can see within their VirtualMCPServer. The intersection of both layers is what the user sees.

### Credential Injection (GitHub MCP Server)

The broker uses a shared PAT (`credentialRef` Secret) for tool discovery. At request time, the Vault AuthPolicy swaps the user's Keycloak JWT for their personal PAT stored in Vault, so each user's tool calls use their own GitHub credentials.

### Users

| User | Password | Group | VirtualMCPServer | Description |
|------|----------|-------|-----------------|-------------|
| mcp-admin1 | admin1pass | mcp-admins | admin-tools | OpenShift + test tools |
| mcp-user1 | user1pass | mcp-users | user-tools | Test tools only |
| mcp-github1 | github1pass | mcp-github | github-tools | GitHub + limited test tools |

## Documentation

- [docs/component-versions.md](docs/component-versions.md) — All deployed component versions, images, and custom builds
- [docs/openshift-ai-prerequisites.md](docs/openshift-ai-prerequisites.md) — Prerequisites for the OpenShift AI deployment
- [docs/experimentation.md](docs/experimentation.md) — Full chronological narrative of the experiment
- [docs/friction-points.md](docs/friction-points.md) — Upstream limitations requiring workarounds
- [docs/changes-tracker.md](docs/changes-tracker.md) — Structured changelog of every modification
- [docs/persona-flows.md](docs/persona-flows.md) — Platform Engineer + AI Engineer end-to-end flows
- [docs/mcp-ecosystem-best-practices.md](docs/mcp-ecosystem-best-practices.md) — Best practices for MCP ecosystem deployments
- [scripts/openshift-ai-demo-script.md](scripts/openshift-ai-demo-script.md) — Demo script / talking points

## Repository Structure

```
├── docs/
│   ├── component-versions.md              # Deployed versions and images
│   ├── openshift-ai-prerequisites.md      # Cluster prerequisites
│   ├── experimentation.md                 # Full experiment narrative
│   ├── friction-points.md                 # Upstream limitations + workarounds
│   ├── changes-tracker.md                 # Code changes + deployment artifacts
│   ├── persona-flows.md                   # Platform Engineer + AI Engineer flows
│   ├── mcp-ecosystem-best-practices.md    # Best practices
│   └── diagrams/
│       ├── openshift-ai-architecture.mermaid
│       ├── openshift-ai-auth-flow.mermaid
│       ├── openshift-ai-request-flow.mermaid
│       ├── team-a-request-flow.mermaid
│       ├── operator-reconciliation.mermaid
│       └── tls-architecture.mermaid
├── infrastructure/openshift-ai/
│   ├── gateway/                           # Gateway Helm values, auth, wristband keys
│   ├── github server/                     # GitHub MCP server manifest
│   ├── keycloak/                          # Keycloak CR, realm import, groups script
│   ├── lifecycle operator/                # Lifecycle operator deployment
│   ├── ocp server/                        # OpenShift MCP server manifest
│   ├── operator subscriptions/            # OLM subscriptions (MCP Gateway, RHBK)
│   ├── playground/                        # RHOAI ConfigMaps (gateway registration, catalog sources)
│   ├── test-servers/                      # Test MCP server manifests
│   └── vault/                             # Vault Helm values, configuration, Keycloak claims
├── scripts/
│   ├── setup.sh                           # Guided infrastructure setup (6 phases)
│   ├── usage.sh                           # Demo walkthrough (3 phases)
│   ├── cleanup.sh                         # Selective teardown
│   └── openshift-ai-demo-script.md        # Demo script / talking points
└── README.md
```
