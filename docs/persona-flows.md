# Persona Flows: Platform Engineer and AI Engineer

This document describes the two end-to-end flows validated in the experiment, mapped to the two personas defined by RHAISTRAT-1149. Everything below reflects the current state of the `team-a` namespace after Phase 18.

For a visual overview of the request path, see [docs/diagrams/team-a-request-flow.mermaid](diagrams/team-a-request-flow.mermaid).

---

## Flow 1: Platform Engineer

The platform engineer provisions infrastructure so that AI engineers can discover and call MCP tools without touching Kubernetes, credentials, or authorization config. The entire flow is declarative — no application code.

### Step 1: Create the team's namespace and gateway

```bash
kubectl apply -f infrastructure/team-a/namespace.yaml
kubectl apply -f infrastructure/team-a/gateway.yaml
kubectl apply -f infrastructure/team-a/mcpgatewayextension.yaml
```

- `namespace.yaml` — isolation boundary. Each team gets its own namespace.
- `gateway.yaml` — Gateway CR with an HTTP listener on port 8080. Istio creates an Envoy proxy pod for this gateway in the `team-a` namespace.
- `mcpgatewayextension.yaml` — tells the mcp-controller to deploy a broker/router pod in this namespace, attached to this gateway. The broker aggregates `tools/list` from all registered servers; the router (ext_proc) rewrites `tools/call` requests to the correct upstream.

After this, `team-a` has its own Envoy proxy and MCP broker, completely isolated from other namespaces.

### Step 2: Deploy MCP servers

```bash
kubectl apply -f infrastructure/team-a/test-server-a1.yaml
kubectl apply -f infrastructure/team-a/test-server-a2.yaml
```

Each is an MCPServer CR with a `gateway-ref` annotation pointing to `team-a/team-a-gateway`. The lifecycle operator automatically creates:
- Deployment + Service (runs the MCP server pod)
- HTTPRoute (routes traffic from the gateway)
- MCPServerRegistration (registers the server with the broker)

The mcp-controller sees the registrations and updates the broker's config Secret. The platform engineer doesn't manage any of these downstream resources.

**Current servers:**
- `test-server-a1` — 5 tools: `add_tool`, `greet`, `headers`, `slow`, `time`
- `test-server-a2` — 7 tools: `auth1234`, `headers`, `hello_world`, `pour_chocolate_into_mold`, `set_time`, `slow`, `time`

### Step 3: Set up identity (Keycloak)

Create groups and users via the Keycloak admin API. Groups determine what each user can see and do.

**Groups:**
| Group | Members | Role |
|-------|---------|------|
| `team-a-developers` | dev1, dev2 | Utility and inspection tools |
| `team-a-ops` | ops1, ops2 | Admin and management tools |
| `team-a-leads` | lead1 | Full access to all tools |

**Requirements:**
- Users must have `firstName`, `lastName`, and `email` set (Keycloak 26 profile enforcement)
- The `mcp-cli` client must have the `groups` scope available (so tokens include the `groups` claim)
- Token requests must include `scope=openid groups` — without this, the `groups` claim is absent and AuthPolicy CEL predicates fail

### Step 4: Store credentials in Vault

Two patterns, one per server:

**Team-level credentials** (server-a1 pattern — shared by group):
```bash
vault kv put secret/mcp-gateway/teams/team-a-developers api_key=team-dev-shared-key-001
vault kv put secret/mcp-gateway/teams/team-a-ops        api_key=team-ops-shared-key-002
vault kv put secret/mcp-gateway/teams/team-a-leads       api_key=team-leads-shared-key-003
```

**Per-user credentials** (server-a2 pattern — keyed by Keycloak `sub` claim):
```bash
vault kv put secret/mcp-gateway/users/{dev1-sub}  api_key=dev1-personal-key
vault kv put secret/mcp-gateway/users/{dev2-sub}  api_key=dev2-personal-key
vault kv put secret/mcp-gateway/users/{ops1-sub}  api_key=ops1-personal-key
vault kv put secret/mcp-gateway/users/{ops2-sub}  api_key=ops2-personal-key
vault kv put secret/mcp-gateway/users/{lead1-sub} api_key=lead1-personal-key
```

The `sub` claim is the Keycloak user ID (UUID). In practice, the platform engineer retrieves it from the Keycloak admin API when creating users. The `setup.sh` script automates this.

**Vault prerequisites** (already configured in the shared control plane):
- KV v2 secrets engine at `secret/`
- JWT auth method backed by Keycloak's JWKS endpoint
- Policy `authorino`: allows `read` on `secret/data/mcp-gateway/*`
- Role `authorino`: bound to audience `mcp-gateway`, user claim `sub`

### Step 5: Define what each group sees (VirtualMCPServers)

```bash
kubectl apply -f infrastructure/team-a/virtualserver-dev.yaml
kubectl apply -f infrastructure/team-a/virtualserver-ops.yaml
kubectl apply -f infrastructure/team-a/virtualserver-leads.yaml
```

Each VirtualMCPServer lists tool names (prefixed with server name) that should be visible to a group:

| VirtualMCPServer | Tools | Description |
|-----------------|-------|-------------|
| `team-a-dev-tools` | 6 tools from both servers | Utility and inspection |
| `team-a-ops-tools` | 6 tools from both servers | Admin and management |
| `team-a-lead-tools` | All 12 tools | Full access |

**Important:** VirtualMCPServers control `tools/list` filtering only — they do not enforce authorization. A user who knows a tool name can still call it unless an AuthPolicy blocks it. See Step 6.

### Step 6: Wire up authorization and credential injection (AuthPolicies)

Three AuthPolicies, layered from gateway to route:

#### Gateway-level AuthPolicy

```bash
kubectl apply -f infrastructure/team-a/gateway-auth-policy.yaml
```

Targets the Gateway CR with `defaults` strategy:
- **Authentication**: validates JWT via Keycloak JWKS
- **Response rule**: injects `X-Mcp-Virtualserver` header based on group membership using a CEL ternary:
  - `team-a-leads` → `team-a/team-a-lead-tools`
  - `team-a-ops` → `team-a/team-a-ops-tools`
  - `team-a-developers` → `team-a/team-a-dev-tools`

The client never selects a VirtualMCPServer — the gateway does it based on JWT claims.

#### Per-HTTPRoute AuthPolicies

```bash
kubectl apply -f infrastructure/team-a/authpolicy-server-a1.yaml
kubectl apply -f infrastructure/team-a/authpolicy-server-a2.yaml
```

Each targets an HTTPRoute and has four layers:

1. **Authentication** — JWT validation (same Keycloak issuer)
2. **Metadata evaluators** — two-stage Vault credential exchange:
   - Stage 1 (priority 0): exchange JWT for Vault client token via `POST /v1/auth/jwt/login`
   - Stage 2 (priority 1): read the secret using the Vault token
     - Server-a1: `GET /v1/secret/data/mcp-gateway/teams/{group}` (CEL ternary selects group path)
     - Server-a2: `GET /v1/secret/data/mcp-gateway/users/{sub}` (JWT `sub` claim selects user path)
3. **Authorization** — CEL predicate checks `group ∈ allowed tools`:
   ```
   (auth.identity.groups.exists(g, g == 'team-a-developers')
    && request.headers['x-mcp-toolname'] in ['greet', 'time', 'headers'])
   || (auth.identity.groups.exists(g, g == 'team-a-ops')
    && request.headers['x-mcp-toolname'] in ['add_tool', 'slow'])
   || ...
   ```
4. **Response** — inject the Vault secret as a header:
   - Server-a1: `X-Team-Credential` → `auth.metadata.vault_team_secret.data.data.api_key`
   - Server-a2: `X-User-Credential` → `auth.metadata.vault_user_secret.data.data.api_key`

### Summary: what the platform engineer creates

| Layer | Resource | Count | Purpose |
|-------|----------|-------|---------|
| Namespace | Namespace | 1 | Isolation boundary |
| Gateway | Gateway + MCPGatewayExtension + NodePort | 3 | Ingress + broker/router |
| Servers | MCPServer CRs | 2 | MCP server deployments |
| Identity | Keycloak groups + users | 3 groups, 5 users | Who can access what |
| Credentials | Vault secrets | 3 team + 5 user | Downstream API keys |
| Presentation | VirtualMCPServer CRs | 3 | Tool filtering per group |
| Authorization | AuthPolicy CRs | 3 (1 gateway + 2 route) | JWT auth + tool ACLs + credential injection |

Total: ~20 Kubernetes resources + Keycloak/Vault API calls. No application code.

---

## Flow 2: AI Engineer

The AI engineer knows a gateway URL, a username, and a password. They don't know about VirtualMCPServers, AuthPolicies, Vault, Kubernetes, or which MCP servers exist.

### Step 1: Authenticate

```bash
TOKEN=$(curl -s http://keycloak.127-0-0-1.sslip.io:8002/realms/mcp/protocol/openid-connect/token \
  -d "grant_type=password&client_id=mcp-cli&username=dev1&password=dev1&scope=openid groups" \
  | jq -r .access_token)
```

In production, this would be a device authorization grant (the `mcp-client.sh` script implements this) or a browser-based OIDC flow. The direct grant above is for testing.

### Step 2: Initialize a session

```bash
SESSION_ID=$(curl -si http://team-a.mcp.127-0-0-1.sslip.io:8001/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
    "protocolVersion":"2025-03-26",
    "capabilities":{},
    "clientInfo":{"name":"my-client","version":"1.0"}
  }}' | grep -i mcp-session-id | awk '{print $2}' | tr -d '\r')
```

The gateway returns an `Mcp-Session-Id` header. All subsequent requests must include it.

### Step 3: Discover available tools

```bash
curl -s http://team-a.mcp.127-0-0-1.sslip.io:8001/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
```

**What the AI engineer sees** depends on their group:

| User | Group | Tools visible | Tools hidden |
|------|-------|--------------|--------------|
| dev1 | team-a-developers | 6 (greet, time, headers from both servers) | 6 (add_tool, slow, auth1234, set_time, pour_chocolate_into_mold) |
| ops1 | team-a-ops | 6 (add_tool, slow, auth1234, set_time, slow, pour_chocolate_into_mold) | 6 (greet, time, headers, hello_world) |
| lead1 | team-a-leads | All 12 | None |

The AI engineer doesn't know that 12 tools exist on the cluster. They see only what their group's VirtualMCPServer includes.

### Step 4: Call a tool

```bash
curl -s http://team-a.mcp.127-0-0-1.sslip.io:8001/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{
    "name":"test_server_a1_headers",
    "arguments":{}
  }}'
```

The AI engineer sends a simple JSON-RPC call. Here's what happens behind the scenes:

#### What the AI engineer doesn't see

1. **Router (ext_proc)** parses the tool name `test_server_a1_headers`, strips the server prefix, and rewrites the request:
   - `:authority` → `test-server-a1.mcp.local` (routes to server-a1's HTTPRoute)
   - `x-mcp-toolname` → `headers`
   - `x-mcp-servername` → `team-a/test-server-a1`

2. **Gateway AuthPolicy** validates the JWT (already happened at gateway level)

3. **Server-a1 AuthPolicy** runs:
   - Validates JWT again (per-route)
   - CEL predicate: dev1 ∈ `team-a-developers`, `headers` ∈ `['greet', 'time', 'headers']` → **authorized**
   - Metadata evaluator stage 1: sends JWT to Vault → gets Vault client token
   - Metadata evaluator stage 2: reads `secret/mcp-gateway/teams/team-a-developers` → gets `team-dev-shared-key-001`
   - Response: injects `X-Team-Credential: team-dev-shared-key-001` header

4. **MCP server** receives the request with the credential header and returns the tool result

The AI engineer gets the tool response. The MCP server got the right credential. No one handled credentials manually.

#### What happens when denied

If dev1 tries to call `test_server_a1_add_tool` (an ops-only tool):

```bash
curl -s ... -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{
  "name":"test_server_a1_add_tool","arguments":{"name":"x","description":"y"}
}}'
```

Response:
```json
{"error":"Forbidden","message":"You do not have access to this tool."}
```

The CEL predicate fails (`add_tool` is not in the developers' allowed list), and the request is rejected before it reaches the MCP server or Vault.

### Summary: what the AI engineer experiences

| Step | Action | What they provide | What they get |
|------|--------|-------------------|---------------|
| 1 | Authenticate | Username + password | JWT token |
| 2 | Initialize | Token + gateway URL | Session ID |
| 3 | List tools | Token + session ID | Filtered tool list (group-appropriate) |
| 4 | Call tool | Token + session ID + tool name + args | Tool result (credential injection invisible) |

The AI engineer interacts with **standard MCP protocol only**. No Kubernetes, no Vault, no VirtualMCPServer headers, no credential management.

---

## How the two flows connect

The platform engineer's declarative configuration creates a self-service experience for the AI engineer:

| Platform Engineer configures... | AI Engineer experiences... |
|--------------------------------|--------------------------|
| Keycloak groups + users | "I log in and get a token" |
| VirtualMCPServers + gateway AuthPolicy | "I see the tools relevant to my role" |
| Per-HTTPRoute AuthPolicy CEL predicates | "I can call my tools; unauthorized ones are blocked" |
| Vault secrets + metadata evaluators | "Tools just work — I don't manage API keys" |
| Namespace + Gateway + MCPGatewayExtension | "I have one URL to connect to" |

The platform engineer's work is entirely in Kubernetes manifests and API calls. The AI engineer's experience is entirely MCP protocol. The gateway layer bridges the two.
