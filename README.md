# MCP Ecosystem Experimentation

A reproducible experiment exploring how MCP ecosystem projects work together end-to-end: **discovery** (model-registry catalog), **deployment** (lifecycle operator), **routing** (mcp-gateway), **authentication** (Keycloak + Kuadrant/Authorino), **per-tool authorization** (AuthPolicy with CEL predicates), **TLS** (cert-manager + Kuadrant TLSPolicy), and **per-user credential exchange** (Vault token exchange for upstream API tokens).

Powered heavily by Claude Code 

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
```

## Documentation

- [docs/experimentation.md](docs/experimentation.md) — Full chronological narrative of the experiment (Phases 1-15), from initial project analysis through deployment, request tracing, authentication, catalog integration, gateway automation, per-tool authorization, TLS, and Vault credential exchange
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

This takes approximately 10 minutes and sets up: Kind cluster, Istio (as Gateway API controller), MetalLB, cert-manager, Envoy gateway, mcp-gateway (broker/router/controller), lifecycle operator, catalog system, Keycloak, Kuadrant (Authorino), two test MCP servers, per-tool AuthPolicies, TLS termination, Vault, and optionally a GitHub MCP server.

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

This verifies the full pipeline end-to-end across 8 phases (63 checks):
1. **Catalog API** — lists available servers with OCI artifact URIs
2. **Operator resources** — MCPServer CRs triggered Deployment + Service creation for both servers
3. **Gateway integration** — operator created HTTPRoute + MCPServerRegistration + AuthPolicies
4. **Authentication** — Keycloak issues tokens for all users, unauthenticated requests are rejected with 401
5. **Gateway tool access** — MCP sessions initialize, tools from both servers are federated, tool calls return results
6. **Authorization matrix** — 15 allow/deny cases across 3 users × 5 tools (see matrix below)
7. **TLS** — cert-manager, TLSPolicy, HTTPS endpoints for MCP gateway and Keycloak
8. **Vault credential exchange** — Vault JWT login with Keycloak token, per-user secret read via JWT-derived policy, GitHub MCPServerRegistration + AuthPolicy

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

Authenticates against Keycloak via browser-based device flow, then drops into a tool-calling REPL. Log in as any user (alice/alice, bob/bob, carol/carol). Use `/login` to switch users, `/tools` to list tools, `/whoami` to check identity.

```bash
╰─ ./scripts/mcp-client.sh                                                           ─╯
Requesting device code...

==========================================
  Open this URL in your browser:

  http://keycloak.127-0-0-1.sslip.io:8002/realms/mcp/device?user_code=VTVY-ZGVW

  Or go to: http://keycloak.127-0-0-1.sslip.io:8002/realms/mcp/device
  and enter code: VTVY-ZGVW
==========================================

Waiting for you to log in...

Authenticated as: 0e8ae6e5-1e7c-491a-b1d2-81bb26668110 (groups: developers)

Initializing MCP session...
Session established.

Available tools:
----------------
  github_get_commit(include_diff, owner, page, perPage, repo, sha) — Get details for a commit from a GitHub repository
  github_get_file_contents(owner, path, ref, repo, sha) — Get the contents of a file or directory from a GitHub repository
  github_get_label(name, owner, repo) — Get a specific label from a repository.
  github_get_latest_release(owner, repo) — Get the latest release in a GitHub repository
  github_get_me() — Get details of the authenticated GitHub user. Use this when a request is about the user's own profile for GitHub. Or when information is missing to build other tool calls.
  github_get_release_by_tag(owner, repo, tag) — Get a specific release by its tag name in a GitHub repository
  github_get_tag(owner, repo, tag) — Get details about a specific git tag in a GitHub repository
  github_get_team_members(org, team_slug) — Get member usernames of a specific team in an organization. Limited to organizations accessible with current credentials
  github_get_teams(user) — Get details of the teams the user is a member of. Limited to organizations accessible with current credentials
  github_issue_read(issue_number, method, owner, page, perPage, repo) — Get information about a specific issue in a GitHub repository.
  github_list_branches(owner, page, perPage, repo) — List branches in a GitHub repository
  github_list_commits(author, owner, page, perPage, repo, sha) — Get list of commits of a branch in a GitHub repository. Returns at least 30 results per page by default, but can return more if specified using the perPage parameter (up to 100).
  github_list_issue_types(owner) — List supported issue types for repository owner (organization).
  github_list_issues(after, direction, labels, orderBy, owner, perPage, repo, since, state) — List issues in a GitHub repository. For pagination, use the 'endCursor' from the previous response's 'pageInfo' in the 'after' parameter.
  github_list_pull_requests(base, direction, head, owner, page, perPage, repo, sort, state) — List pull requests in a GitHub repository. If the user specifies an author, then DO NOT use this tool and use the search_pull_requests tool instead.
  github_list_releases(owner, page, perPage, repo) — List releases in a GitHub repository
  github_list_tags(owner, page, perPage, repo) — List git tags in a GitHub repository
  github_pull_request_read(method, owner, page, perPage, pullNumber, repo) — Get information on a specific pull request in GitHub repository.
  github_search_code(order, page, perPage, query, sort) — Fast and precise code search across ALL GitHub repositories using GitHub's native search engine. Best for finding exact symbols, functions, classes, or specific code patterns.
  github_search_issues(order, owner, page, perPage, query, repo, sort) — Search for issues in GitHub repositories using issues search syntax already scoped to is:issue
  github_search_pull_requests(order, owner, page, perPage, query, repo, sort) — Search for pull requests in GitHub repositories using issues search syntax already scoped to is:pr
  github_search_repositories(minimal_output, order, page, perPage, query, sort) — Find GitHub repositories by name, description, readme, topics, or other metadata. Perfect for discovering projects, finding examples, or locating specific repositories across GitHub.
  github_search_users(order, page, perPage, query, sort) — Find GitHub users by username, real name, or other profile information. Useful for locating developers, contributors, or team members.
  test_server1_add_tool(description, name) — dynamically add a new tool (triggers notifications/tools/list_changed)
  test_server1_greet(name) — say hi
  test_server1_headers() — get headers
  test_server1_slow(seconds) — delay N seconds
  test_server1_time() — get current time
  test_server2_auth1234() — check authorization header
  test_server2_headers() — get HTTP headers
  test_server2_hello_world(name) — Say hello to someone
  test_server2_pour_chocolate_into_mold(quantity) — Pour chocolate into mold
  test_server2_set_time(time) — Set the clock
  test_server2_slow(seconds) — Delay for N seconds
  test_server2_time() — Get the current time

Enter tool calls as: tool_name {"param": "value"}
  or with key=value:  tool_name name=luffy
Commands: /login (switch user), /tools, /whoami, /raw METHOD {params}, /quit
```

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
| MCP Gateway (HTTP) | http://mcp.127-0-0-1.sslip.io:8001/mcp | Envoy gateway (authenticated) |
| MCP Gateway (HTTPS) | https://mcp.127-0-0-1.sslip.io:8443/mcp | TLS-terminated (use `--cacert /tmp/mcp-ca.crt`) |
| Keycloak (HTTP) | http://keycloak.127-0-0-1.sslip.io:8002 | OIDC provider (admin: admin/admin) |
| Keycloak (HTTPS) | https://keycloak.127-0-0-1.sslip.io:8445 | TLS-terminated (use `--cacert /tmp/mcp-ca.crt`) |
| MCP Launcher | http://localhost:8004 | Catalog UI + deployment |
| Keycloak OIDC Discovery | http://keycloak.127-0-0-1.sslip.io:8002/realms/mcp/.well-known/openid-configuration | Realm endpoints |
| Vault | ClusterIP only (`vault.vault.svc:8200`) | Dev mode, root token: `root` |

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
│   ├── experimentation.md                      # Full experiment narrative (Phases 1-14)
│   ├── changes-tracker.md                      # Code changes + friction points
│   └── diagrams/
│       ├── component-architecture.mermaid      # Cluster component map
│       ├── request-flow.mermaid                # Authenticated MCP request sequence (HTTP + HTTPS)
│       ├── tls-architecture.mermaid            # TLS certificate chain + termination flow
│       ├── catalog-to-gateway-pipeline.mermaid # End-to-end pipeline flow
│       └── operator-reconciliation.mermaid     # Operator reconciler logic
├── infrastructure/
│   ├── kind/                                   # Kind cluster config (HTTP + HTTPS ports)
│   ├── istio/                                  # Istio (Sail operator) config
│   ├── gateway/                                # Gateway namespace, resource, nodeport
│   ├── metallb/                                # MetalLB IP pool script
│   ├── cert-manager/                           # CA issuers + TLSPolicy
│   ├── mcp-gateway/                            # CRDs + controller/broker deployment
│   ├── lifecycle-operator/                     # Operator deployment manifest
│   ├── kuadrant/                               # Kuadrant CR
│   ├── catalog/                                # Catalog API + PostgreSQL
│   ├── keycloak/                               # Keycloak deployment + realm import + TLS
│   ├── launcher/                               # MCP Launcher deployment + RBAC
│   ├── operator-gateway/                       # Operator gateway RBAC additions
│   ├── vault/                                  # Vault deployment + configuration script
│   ├── auth/                                   # Kuadrant AuthPolicies (gateway + per-server + Vault exchange)
│   └── test-servers/                           # MCPServer CRs for test-server1, test-server2, and GitHub
├── scripts/
│   ├── guided-setup.sh                         # Interactive guided setup with gum TUI
│   ├── setup.sh                                # Non-interactive full cluster setup (16 phases)
│   ├── test-pipeline.sh                        # Full pipeline + auth matrix + TLS + Vault (63 checks)
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

## Key Findings

The experiment surfaced several integration friction points documented in detail in [docs/changes-tracker.md](docs/changes-tracker.md). The most significant:

1. **Per-tool authorization works at the gateway with no code changes** — Kuadrant AuthPolicy + CEL predicates enable per-group, per-tool, cross-server authorization. The Router sets `x-mcp-toolname` and `:authority` headers before the auth check runs, giving Authorino full visibility into tool and server identity.

2. **Envoy filter chain order is critical** — ext_proc (Router) runs before the Kuadrant Wasm plugin (auth). This was initially assumed to be the opposite, which would have made per-tool authorization impossible at the gateway. Always verify filter chain order via the Envoy config dump.

3. **`tools/list` is the authorization blind spot** — `tools/call` is fully enforced at the gateway, but `tools/list` returns all tools to all users. The broker aggregates without identity-based filtering, requiring application-level changes for consistent UX.

4. **Catalog metadata is insufficient for deployment** — `runtimeMetadata` covers port and path but not container command, arguments, or security context. Each MCP server image is potentially a snowflake.

5. **The annotation-based gateway integration pattern works well** — using `mcp.x-k8s.io/gateway-ref` annotations on MCPServer CRs avoids upstream spec changes while enabling automatic gateway registration.

6. **TLS termination is transparent to the MCP protocol** — Kuadrant TLSPolicy + cert-manager adds HTTPS with zero application changes. TLS terminates at Envoy; backends stay plain HTTP. The only client-side change is URL scheme and CA certificate trust. cert-manager must be installed before Kuadrant — the TLSPolicy controller checks for it at startup and never re-checks.

7. **Per-user credential exchange works entirely at the gateway** — Vault token exchange (Keycloak JWT → Vault JWT login → per-user secret read → inject upstream credential) is implemented purely in AuthPolicy metadata evaluators. No application code changes, no sidecars, no per-user MCP server deployments. The gateway swaps the user's JWT for their stored API token before forwarding to the upstream MCP server.

8. **MCP servers that only read credentials from environment variables force per-user deployments** — the GitHub MCP server accepts `Authorization: Bearer` headers in HTTP mode, making per-user Vault credential injection possible. Servers that only read tokens from env vars (e.g., Slack MCP server) require a separate deployment per user — the gateway can't inject credentials into environment variables at request time.

See [docs/experimentation.md](docs/experimentation.md) for the full narrative including the auth layer investigation (Istio 403 vs OAuth 401), the OIDC/PKCE flow, the Keycloak migration, the per-tool authorization evolution, and the Vault credential exchange flow.
