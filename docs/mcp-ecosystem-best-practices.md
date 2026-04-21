# Best Practices for the MCP Ecosystem on Red Hat OpenShift AI

## Document Overview

This document provides comprehensive guidance for the Model Context Protocol (MCP) Ecosystem on Red Hat OpenShift AI, covering how MCP components work together to enable discovery, deployment, secure access, and consumption of MCP servers through the platform.

It serves as the central reference for understanding and implementing the MCP Ecosystem as delivered in RHOAI, including the roles of the MCP Catalog, MCP server deployment, MCP Gateway integration, and Gen AI Studio consumption.

The guidance in this document is based on hands-on experimentation with a production-representative deployment on OpenShift AI (ROSA, OpenShift 4.21.6, RHOAI 3.4.0) and 18 phases of incremental development in a Kind-based lab environment. Recommendations reflect validated patterns, known constraints, and integration seams discovered through systematic testing.

### Visual References

- [OpenShift AI Component Architecture](diagrams/openshift-ai-architecture.mermaid) — Full cluster topology: namespaces, components, and control/data plane relationships
- [OpenShift AI Request Flow](diagrams/openshift-ai-request-flow.mermaid) — End-to-end sequence: Playground → Llama Stack → vLLM → MCP Gateway → Auth → MCP Server → Kubernetes API
- [OpenShift AI Auth Flow](diagrams/openshift-ai-auth-flow.mermaid) — Layered JWT authentication and role-based authorization with Keycloak + Authorino

---

## Table of Contents

- [MCP Ecosystem Overview](#mcp-ecosystem-overview)
  - [What Is MCP?](#what-is-mcp)
  - [MCP in OpenShift AI](#mcp-in-openshift-ai)
  - [Component Roles](#component-roles)
  - [How MCP Fits Into Agent-Based AI Workflows](#how-mcp-fits-into-agent-based-ai-workflows)
- [Personas and Responsibilities](#personas-and-responsibilities)
  - [Platform Engineer / AI Ops](#platform-engineer--ai-ops)
  - [AI Engineer / Practitioner](#ai-engineer--practitioner)
  - [Responsibility Matrix](#responsibility-matrix)
- [Supported MCP Workflows](#supported-mcp-workflows)
  - [Workflow 1: Deploying MCP Servers](#workflow-1-deploying-mcp-servers)
  - [Workflow 2: Registering MCP Servers with the Gateway](#workflow-2-registering-mcp-servers-with-the-gateway)
  - [Workflow 3: Configuring Authentication and Authorization](#workflow-3-configuring-authentication-and-authorization)
  - [Workflow 4: Creating and Using Virtual MCP Servers](#workflow-4-creating-and-using-virtual-mcp-servers)
  - [Workflow 5: Consuming MCP in Gen AI Studio](#workflow-5-consuming-mcp-in-gen-ai-studio)
- [MCP Gateway Integration](#mcp-gateway-integration)
  - [Purpose of the MCP Gateway](#purpose-of-the-mcp-gateway)
  - [Architecture](#architecture)
  - [Installing the MCP Gateway on OpenShift AI](#installing-the-mcp-gateway-on-openshift-ai)
  - [Registering MCP Servers with the Gateway](#registering-mcp-servers-with-the-gateway)
  - [Virtual MCP Servers](#virtual-mcp-servers)
  - [Policy and Access Control](#policy-and-access-control)
- [Best Practices and Constraints](#best-practices-and-constraints)
  - [MCP Server Requirements](#mcp-server-requirements)
  - [Authentication and Authorization](#authentication-and-authorization)
  - [Namespace Isolation and Multi-Tenancy](#namespace-isolation-and-multi-tenancy)
  - [Deployment Patterns](#deployment-patterns)
  - [Security Considerations](#security-considerations)
  - [Observability](#observability)
  - [Known Limitations (Summit MVP)](#known-limitations-summit-mvp)
- [Future Direction (Non-Normative)](#future-direction-non-normative)
- [Reference: Component Versions](#reference-component-versions)
- [Reference: Deployment Patterns](#reference-deployment-patterns)

---

## MCP Ecosystem Overview

### What Is MCP?

The Model Context Protocol (MCP) is an open standard that provides a uniform interface for AI models to discover and invoke external tools. An MCP server exposes tools — discrete functions that perform actions or retrieve information — over HTTP using the JSON-RPC 2.0 protocol. An MCP client (such as an AI agent runtime) discovers available tools via `tools/list` and calls them via `tools/call`.

MCP decouples tool implementation from AI model integration: a team can build an MCP server that wraps a Kubernetes API, a database, a third-party SaaS, or any internal service, and any MCP-compatible AI system can use it without custom integration code.

### MCP in OpenShift AI

In OpenShift AI, MCP enables a **tool-augmented AI workflow**: AI models running on the platform (via vLLM and Llama Stack) can call external tools through MCP servers, giving them the ability to query live systems, take actions, and access data beyond what's in their training data.

The MCP Ecosystem on OpenShift AI consists of four components that work together:

```
┌─────────────────────────────────────────────────────────────────┐
│                        Gen AI Studio                            │
│  (Playground UI → Llama Stack → MCP Gateway → MCP Servers)      │
└─────────────────────────────────────────────────────────────────┘

     ┌──────────┐    ┌──────────────┐    ┌──────────────────┐
     │  MCP     │    │  MCP         │    │  MCP Servers     │
     │  Catalog │───▶│  Gateway     │───▶│  (OpenShift,     │
     │          │    │  (Kuadrant)  │    │   custom, etc.)  │
     └──────────┘    └──────────────┘    └──────────────────┘
```

1. **MCP Catalog** — Discovery: browse and find available MCP servers
2. **MCP Server Deployment** — Lifecycle: deploy MCP servers as Kubernetes workloads
3. **MCP Gateway** — Routing, aggregation, and policy: federate multiple MCP servers behind a single endpoint with authentication, authorization, and tool filtering
4. **Gen AI Studio** — Consumption: AI practitioners use MCP tools through the Playground UI without touching infrastructure

### Component Roles

| Component | Role | Key Resources |
|-----------|------|---------------|
| **MCP Catalog** | Serves as the registry of available MCP servers, their capabilities, and metadata. Provides a browsable inventory for discovering what tools exist and how to deploy them. | Catalog API, MCP server entries, tool listings |
| **MCP Lifecycle Operator** | Manages the Kubernetes lifecycle of MCP servers. Watches `MCPServer` custom resources and creates the necessary Deployment, Service, and networking resources. | `MCPServer` CR, Deployment, Service |
| **MCP Gateway** | Federates multiple MCP servers behind a single endpoint. The broker aggregates `tools/list` responses; the router (Envoy ext_proc) directs `tools/call` requests to the correct backend server. | `MCPGatewayExtension`, `MCPServerRegistration`, `MCPVirtualServer`, Gateway, HTTPRoute, EnvoyFilter |
| **MCP Gateway Controller** | Cluster-scoped operator that reconciles MCP Gateway CRDs. Deploys broker/router pods, creates config Secrets, and manages EnvoyFilters. | Installed via OLM |
| **Kuadrant (Connectivity Link)** | Provides `AuthPolicy` and `RateLimitPolicy` CRDs for gateway-level and per-route authentication, authorization, and rate limiting. Backed by Authorino (auth) and Limitador (rate limiting). | `AuthPolicy`, `RateLimitPolicy` |
| **Gen AI Studio** | The Playground UI in the RHOAI Dashboard. Orchestrates AI model interactions through Llama Stack, which connects to MCP servers via the gateway. | Playground instance, Llama Stack, `gen-ai-aa-mcp-servers` ConfigMap |

### How MCP Fits Into Agent-Based AI Workflows

MCP enables agent-based AI patterns where AI models can take action on behalf of users:

1. **User asks a question in Gen AI Studio** — e.g., "What pods are running in the production namespace?"
2. **The AI model (vLLM) decides it needs external data** — it generates a tool call request
3. **Llama Stack routes the tool call through the MCP Gateway** — which handles authentication, authorization, and routing to the correct MCP server
4. **The MCP server executes the tool** — e.g., queries the Kubernetes API
5. **The result flows back** — MCP server → MCP Gateway → Llama Stack → vLLM → user sees the answer

The user interacts with a chat interface. The MCP ecosystem handles everything between the model's tool decision and the tool's execution — routing, authentication, authorization, and credential management — transparently.

---

## Personas and Responsibilities

The MCP Ecosystem involves two primary personas with distinct responsibilities and skill sets.

### Platform Engineer / AI Ops

The platform engineer provisions and manages the MCP infrastructure. Their responsibilities include:

- **Infrastructure provisioning**: Creating namespaces, deploying gateways, and installing operators
- **MCP server lifecycle**: Deploying, configuring, and maintaining MCP servers
- **Identity management**: Configuring Keycloak realms, clients, users, groups, and roles
- **Access control**: Defining `AuthPolicy` resources for JWT validation, per-tool authorization, and credential injection
- **Tool curation**: Creating `MCPVirtualServer` resources to control which tools are visible to which groups
- **Monitoring**: Observing gateway health, server registration status, and auth policy enforcement

The platform engineer works primarily with Kubernetes manifests, Keycloak admin APIs, and `oc`/`kubectl` commands. No application code is required.

### AI Engineer / Practitioner

The AI engineer consumes MCP tools through Gen AI Studio or programmatic MCP clients. Their experience is:

- **Authentication**: Log in with credentials (via Keycloak)
- **Tool discovery**: See available tools (filtered by their role/group)
- **Tool invocation**: Call tools through natural language in the Playground, or via the MCP protocol
- **No infrastructure knowledge required**: The AI engineer does not need to know about Kubernetes, Vault, VirtualMCPServers, AuthPolicies, or which MCP servers exist on the cluster

The AI engineer interacts with the standard MCP protocol only. All infrastructure complexity is abstracted by the platform engineer's configuration.

### Responsibility Matrix

| Capability | Platform Engineer | AI Engineer |
|-----------|:-:|:-:|
| Namespace + Gateway + MCPGatewayExtension | Owns | — |
| MCP server deployment (MCPServer CRs or Deployments) | Owns | — |
| Keycloak realm, clients, groups, users, roles | Owns | — |
| Credential management (Vault secrets or equivalent) | Owns | — |
| VirtualMCPServers (tool curation per group) | Owns | — |
| AuthPolicies (JWT auth + tool-level authorization) | Owns | — |
| Gen AI Studio MCP server registration (`gen-ai-aa-mcp-servers` ConfigMap) | Owns | — |
| Authenticate and obtain token | — | Owns |
| Discover tools (`tools/list`) | — | Owns |
| Call tools (`tools/call`) via Playground or MCP client | — | Owns |

---

## Supported MCP Workflows

### Workflow 1: Deploying MCP Servers

MCP servers run as standard Kubernetes workloads on OpenShift AI. There are two deployment approaches:

#### Option A: Direct Deployment (Deployment + Service)

Create a Deployment and Service for the MCP server manually:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-mcp-server
  namespace: mcp-servers
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-mcp-server
  template:
    metadata:
      labels:
        app: my-mcp-server
    spec:
      containers:
        - name: server
          image: <mcp-server-image>
          args: ["--http", "0.0.0.0:8080"]
          ports:
            - containerPort: 8080
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
---
apiVersion: v1
kind: Service
metadata:
  name: my-mcp-server
  namespace: mcp-servers
spec:
  selector:
    app: my-mcp-server
  ports:
    - port: 8080
      targetPort: 8080
```

#### Option B: MCPServer Custom Resource (via Lifecycle Operator)

If the MCP Lifecycle Operator is installed, declare an `MCPServer` CR and the operator creates the Deployment and Service automatically:

```yaml
apiVersion: mcp.x-k8s.io/v1alpha1
kind: MCPServer
metadata:
  name: my-mcp-server
  namespace: mcp-servers
spec:
  transport: http
  config:
    port: 8080
    image: <mcp-server-image>
    arguments: ["--http", "0.0.0.0:8080"]
```

#### MCP Server Requirements

- **HTTP transport only.** MCP servers must expose an HTTP endpoint. Stdio-based servers are not supported — they cannot be routed through the gateway or shared across clients.
- **Listen on `0.0.0.0`.** Servers must bind to all interfaces, not `127.0.0.1`, to be reachable from the gateway.
- **Run as non-root.** Follow OpenShift's restricted security context standards. Servers requiring root access need explicit `SecurityContext` configuration.
- **Expose a health check endpoint.** Use liveness and readiness probes (e.g., `/healthz`) for Kubernetes lifecycle management.

#### Example: OpenShift MCP Server

The OpenShift MCP Server provides read-only access to the Kubernetes API through MCP tools. It authenticates to the Kubernetes API using a dedicated ServiceAccount — this is the [recommended production approach](https://github.com/openshift/openshift-mcp-server/blob/main/docs/getting-started-kubernetes.md). All tool calls execute with the ServiceAccount's RBAC permissions, regardless of which user initiated the request. Per-user authorization is enforced at the gateway layer (AuthPolicy), not at the Kubernetes API layer.

The recommended deployment model is a **two-tier approach** with separate instances for platform engineers and AI engineers:

##### Platform Engineer Instance (cluster-scoped)

A single, centrally managed deployment with cluster-wide visibility for platform operations and triage:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openshift-mcp-server-platform
  namespace: mcp-platform
spec:
  replicas: 1
  selector:
    matchLabels:
      app: openshift-mcp-server-platform
  template:
    metadata:
      labels:
        app: openshift-mcp-server-platform
    spec:
      serviceAccountName: mcp-platform-viewer
      containers:
        - name: server
          image: registry.redhat.io/openshift-mcp-beta/openshift-mcp-server-rhel9:0.2
          args: ["serve", "--config", "/config/config.toml"]
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: config
              mountPath: /config
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
      volumes:
        - name: config
          configMap:
            name: openshift-mcp-server-platform-config
```

```toml
# Platform engineer config — cluster-wide visibility, core + config toolsets
[server]
read_only = true
stateless = true
toolsets = ["core", "config"]

[server.denied_resources]
resources = ["Secret", "ServiceAccount"]
api_groups = ["rbac.authorization.k8s.io"]
```

The ServiceAccount uses a **ClusterRoleBinding** to the `view` ClusterRole, giving it read access across all namespaces:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: mcp-platform-viewer
subjects:
  - kind: ServiceAccount
    name: mcp-platform-viewer
    namespace: mcp-platform
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
```

This instance should be protected by an AuthPolicy requiring the `mcp-admin` role — only platform engineers and SREs should have access to cluster-wide Kubernetes visibility.

##### AI Engineer Instance (namespace-scoped)

A lightweight, per-team deployment with visibility restricted to the team's namespace:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openshift-mcp-server
  namespace: team-a
spec:
  replicas: 1
  selector:
    matchLabels:
      app: openshift-mcp-server
  template:
    metadata:
      labels:
        app: openshift-mcp-server
    spec:
      serviceAccountName: mcp-team-viewer
      containers:
        - name: server
          image: registry.redhat.io/openshift-mcp-beta/openshift-mcp-server-rhel9:0.2
          args: ["serve", "--config", "/config/config.toml"]
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: config
              mountPath: /config
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
      volumes:
        - name: config
          configMap:
            name: openshift-mcp-server-config
```

```toml
# AI engineer config — namespace-scoped, core toolset only
[server]
read_only = true
stateless = true
toolsets = ["core"]

[server.denied_resources]
resources = ["Secret", "ServiceAccount"]
api_groups = ["rbac.authorization.k8s.io"]
```

The ServiceAccount uses a namespace-scoped **RoleBinding** to the `view` Role, restricting visibility to only the team's namespace:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: mcp-team-viewer
  namespace: team-a
subjects:
  - kind: ServiceAccount
    name: mcp-team-viewer
    namespace: team-a
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
```

When an AI engineer calls `openshift_pods_list`, the Kubernetes API only returns pods in `team-a` — the RBAC boundary does the scoping, not the gateway.

##### Two-Tier Comparison

| | Platform Engineer Instance | AI Engineer Instance |
|---|---|---|
| **Scope** | Cluster-wide | Single namespace |
| **ServiceAccount binding** | `view` ClusterRole (ClusterRoleBinding) | `view` ClusterRole (namespace RoleBinding) |
| **Toolsets** | `core` + `config` | `core` only |
| **Denied resources** | Secrets, RBAC | Secrets, RBAC |
| **Gateway AuthPolicy** | Requires `mcp-admin` role | Requires team membership (group claim) |
| **Deployment location** | Shared namespace (e.g., `mcp-platform`) | Team namespace (e.g., `team-a`) |
| **Kubernetes audit identity** | `system:serviceaccount:mcp-platform:mcp-platform-viewer` | `system:serviceaccount:team-a:mcp-team-viewer` |

The `config` toolset (e.g., `openshift_configuration_view`) exposes cluster-level configuration that is not useful or appropriate for AI engineers. Restricting AI engineer instances to `core` only keeps the tool list focused and avoids leaking cluster configuration details. This restriction happens at the server level — the tools are never loaded, so they don't appear in the broker, can't be listed, and can't be called.

##### Kubernetes Authentication Model

The OpenShift MCP Server authenticates to the Kubernetes API using its pod's ServiceAccount token. This means:

- **All tool calls execute with the same Kubernetes identity** — the ServiceAccount, not the individual user. Per-user Kubernetes RBAC is not applied.
- **Per-user authorization is handled at the gateway layer** via AuthPolicies, not at the Kubernetes API layer.
- **Kubernetes audit logs show the ServiceAccount identity** for all MCP tool calls, not individual users. For per-user audit trails, correlate gateway access logs (which contain JWT claims) with Kubernetes audit logs.
- **The Authorization header must be stripped** on the HTTPRoute (`RequestHeaderModifier`) to prevent the user's Keycloak JWT from being forwarded to the server, where it would be used as Kubernetes credentials and fail.

The upstream codebase contains experimental support for per-user token passthrough (`--require-oauth`), but this is not documented or recommended for production use. The ServiceAccount approach is the supported path.

##### Layered Access Control Model

Access to MCP tools is controlled at four independent layers. Each layer serves a distinct purpose:

| Layer | What It Controls | Mechanism | Configured By |
|-------|-----------------|-----------|---------------|
| **Server config** (`toolsets`) | Which tools exist at all | MCP server only loads specified toolsets | Platform Engineer (config.toml) |
| **Kubernetes RBAC** (ServiceAccount binding) | What data the tools can access | Kubernetes API returns only what the SA can see | Platform Engineer (RoleBinding/ClusterRoleBinding) |
| **VirtualMCPServer** | Which loaded tools users see in `tools/list` | Gateway broker filters the list | Platform Engineer (MCPVirtualServer CR) |
| **AuthPolicy** | Which tools users can call | Authorino enforces per-request | Platform Engineer (AuthPolicy CR) |

These layers are independent and composable:

- **Server config** is the coarsest filter — it determines the universe of available tools. An AI engineer instance with `toolsets = ["core"]` will never expose `config` tools regardless of any other layer.
- **Kubernetes RBAC** scopes the data returned by tools. A namespace-scoped RoleBinding means `pods_list` only returns pods in that namespace. The tool exists and can be called, but the results are naturally bounded.
- **VirtualMCPServer** is a UX layer — it controls what users see when they call `tools/list`, reducing noise and confusion. It does not enforce access.
- **AuthPolicy** is the security enforcement layer — it blocks unauthorized `tools/call` requests before they reach the MCP server. This is the only layer that prevents a user from calling a tool they know the name of.

### Workflow 2: Registering MCP Servers with the Gateway

Once an MCP server is running, it must be registered with the MCP Gateway so it can be discovered and invoked through the gateway's unified endpoint.

#### Step 1: Create an HTTPRoute

The HTTPRoute tells the gateway how to reach the MCP server. Backend HTTPRoutes **must** use the internal `*.mcp.local` hostname (via the gateway's `mcps` listener), not the public hostname:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openshift-mcp-server
  namespace: mcp-upstream-test
spec:
  parentRefs:
    - name: mcp-gateway
      namespace: mcp-upstream-test
      sectionName: mcps
  hostnames:
    - openshift-mcp-server.mcp.local
  rules:
    - backendRefs:
        - name: openshift-mcp-server
          port: 8080
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            remove:
              - Authorization
```

The `RequestHeaderModifier` that removes the `Authorization` header is important when the backend MCP server uses a ServiceAccount for Kubernetes API access. Without it, Envoy forwards the user's Keycloak JWT to the backend, and the server may attempt to use it as Kubernetes credentials instead of its ServiceAccount token.

#### Step 2: Create an MCPServerRegistration

The registration tells the broker about the server and how to prefix its tools:

```yaml
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPServerRegistration
metadata:
  name: openshift-mcp-server
  namespace: mcp-upstream-test
spec:
  serverRef:
    hostname: openshift-mcp-server.mcp.local
    port: 8080
  toolPrefix: "openshift_"
```

The `toolPrefix` ensures tool names are unique across servers. A tool named `pods_list` on the OpenShift MCP server becomes `openshift_pods_list` when exposed through the gateway.

After applying the MCPServerRegistration, the gateway controller updates the broker's configuration. The broker discovers the server's tools within its ping interval (default: 60 seconds). Verify registration:

```bash
# Initialize a session
SESSION_ID=$(curl -si https://<gateway-route>/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
    "protocolVersion":"2025-03-26",
    "capabilities":{},
    "clientInfo":{"name":"verify","version":"1.0"}
  }}' | grep -i mcp-session-id | awk '{print $2}' | tr -d '\r')

# List tools
curl -s https://<gateway-route>/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
```

### Workflow 3: Configuring Authentication and Authorization

Authentication and authorization for the MCP Gateway are provided by Kuadrant (Red Hat Connectivity Link) using `AuthPolicy` resources backed by Authorino.

#### Step 1: Deploy Keycloak

Deploy Red Hat Build of Keycloak (RHBK) as the OIDC provider:

1. Install the RHBK operator via OLM
2. Create a Keycloak instance with a Postgres database
3. Create a realm (e.g., `mcp-gateway`) with:
   - A **confidential client** (`mcp-gateway`) for service-to-service auth
   - A **public client** (`mcp-playground`) for user-facing auth (Playground UI)
   - **Roles** that map to access levels (e.g., `mcp-user`, `mcp-admin`)
   - **Users** assigned to roles

Example users and roles:

| User | Password | Roles | Access |
|------|----------|-------|--------|
| mcp-user1 | user1pass | mcp-user | Test tools only |
| mcp-admin1 | admin1pass | mcp-user, mcp-admin | All tools including OpenShift |

#### Step 2: Install Kuadrant

Create a `Kuadrant` CR to deploy Authorino (auth engine) and Limitador (rate limiting):

```yaml
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: openshift-operators
spec: {}
```

#### Step 3: Gateway-level AuthPolicy (JWT validation)

Apply an `AuthPolicy` targeting the Gateway's MCP listener to require valid JWTs on all requests:

```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: mcp-gateway-auth
  namespace: mcp-upstream-test
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: mcp-gateway
    sectionName: mcp
  rules:
    authentication:
      keycloak-jwt:
        jwt:
          issuerUrl: https://<keycloak-route>/realms/mcp-gateway
```

After this, all requests to the gateway require a valid JWT. Unauthenticated requests receive 401.

#### Step 4: Per-server AuthPolicy (role-based authorization)

Apply an `AuthPolicy` targeting an HTTPRoute to restrict access based on JWT claims:

```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: openshift-mcp-admin-only
  namespace: mcp-upstream-test
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: openshift-mcp-server
  rules:
    authentication:
      keycloak-jwt:
        jwt:
          issuerUrl: https://<keycloak-route>/realms/mcp-gateway
    authorization:
      admin-only:
        patternMatching:
          patterns:
            - selector: auth.identity.realm_access.roles
              operator: incl
              value: mcp-admin
```

This restricts OpenShift MCP server access to users with the `mcp-admin` role. Users with only `mcp-user` can still access other registered MCP servers (e.g., test tools) but are blocked from OpenShift tools.

#### Authorization Enforcement

| User | Role | Test tools | OpenShift tools |
|------|------|-----------|-----------------|
| mcp-user1 | mcp-user | Allowed | Blocked (403) |
| mcp-admin1 | mcp-user + mcp-admin | Allowed | Allowed |

### Workflow 4: Creating and Using Virtual MCP Servers

VirtualMCPServers control which tools are visible to users when they call `tools/list`. They filter the broker's aggregated tool list based on the user's identity.

#### Creating a VirtualMCPServer

```yaml
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPVirtualServer
metadata:
  name: admin-tools
  namespace: mcp-upstream-test
spec:
  tools:
    - name: openshift_pods_list
    - name: openshift_pods_get
    - name: openshift_pods_log
    - name: openshift_resources_list
    - name: openshift_resources_get
    - name: test_greet
    - name: test_time
```

#### Selecting a VirtualMCPServer

The VirtualMCPServer is selected via the `X-Mcp-Virtualserver` header. This header must use the **namespaced format**: `namespace/name` (e.g., `mcp-upstream-test/admin-tools`).

For automated selection based on user identity, the gateway-level AuthPolicy can inject this header using a CEL expression based on JWT claims:

```yaml
# In the gateway-level AuthPolicy
spec:
  rules:
    response:
      success:
        headers:
          x-mcp-virtualserver:
            expression: |
              auth.identity.realm_access.roles.exists(r, r == 'mcp-admin')
                ? 'mcp-upstream-test/admin-tools'
                : 'mcp-upstream-test/basic-tools'
```

#### Important: VirtualMCPServers Are Presentation Only

VirtualMCPServers filter `tools/list` responses — they control what users **see**, not what they can **call**. A user who knows a tool name can still attempt to call it directly. Authorization enforcement must be handled separately via `AuthPolicy` resources.

Always pair VirtualMCPServers with AuthPolicies:
- **VirtualMCPServer** → controls tool **visibility** (UX)
- **AuthPolicy** → controls tool **access** (security)

### Workflow 5: Consuming MCP in Gen AI Studio

Gen AI Studio (the Playground UI in RHOAI) provides the primary consumption interface for AI practitioners.

#### Step 1: Register MCP Servers with Gen AI Studio

Create a ConfigMap in the `redhat-ods-applications` namespace to expose MCP servers to the Playground:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gen-ai-aa-mcp-servers
  namespace: redhat-ods-applications
data:
  MCP-Gateway: |
    {
      "url": "https://<mcp-gateway-route>/mcp",
      "description": "MCP Gateway with OpenShift and utility tools"
    }
```

The Playground UI immediately recognizes the ConfigMap and shows the MCP server as available. The dashboard automatically wires the URL to Llama Stack's `remote::model-context-protocol` tool_runtime provider — no Llama Stack configuration changes are needed.

#### Step 2: Configure Authentication (if required)

If the MCP Gateway requires JWT authentication, the Playground UI provides an auth token input field. Users paste an access token acquired from Keycloak:

```bash
TOKEN=$(curl -s -X POST \
  https://<keycloak-route>/realms/mcp-gateway/protocol/openid-connect/token \
  -d "grant_type=password&client_id=mcp-playground&username=<user>&password=<pass>" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
```

In production environments, this would be replaced by an integrated SSO flow.

#### Step 3: Use Tools Through Natural Language

Once configured, users interact through the Playground chat interface. When the AI model determines it needs external data, it automatically invokes the appropriate MCP tool:

**User**: "What pods are running in the mcp-upstream-test namespace?"

**Behind the scenes**:
1. vLLM generates a `tools/call` for `openshift_pods_list_in_namespace`
2. Llama Stack routes the call through the MCP Gateway
3. The gateway validates the JWT, checks authorization, and routes to the OpenShift MCP server
4. The OpenShift MCP server queries the Kubernetes API
5. The result flows back through the chain to the user

The user sees a natural language response with the pod information. The entire MCP routing, auth, and tool execution is invisible.

#### End-to-End Data Flow

```
User (Playground UI)
  → Llama Stack (AI agent runtime)
    → MCP Gateway (Envoy + Broker/Router)
      → AuthPolicy (Authorino — JWT validation + role check)
        → MCP Server (e.g., OpenShift MCP Server)
          → Kubernetes API (via ServiceAccount)
        ← Tool result
      ← Authorized response
    ← Tool response (JSON-RPC)
  ← AI-generated answer
← User sees the result
```

---

## MCP Gateway Integration

### Purpose of the MCP Gateway

The MCP Gateway (from the Kuadrant project) provides a single, policy-enforced entry point for all MCP traffic. It solves three problems:

1. **Aggregation**: Multiple MCP servers appear as one. Clients connect to a single URL and see tools from all registered servers.
2. **Routing**: `tools/call` requests are automatically routed to the correct backend server based on the tool name prefix.
3. **Policy enforcement**: Authentication, authorization, rate limiting, and credential injection are applied at the gateway layer, not in individual MCP servers.

Without the gateway, each MCP server would need its own endpoint, its own auth implementation, and clients would need to know which server hosts which tool.

### Architecture

The MCP Gateway consists of three components deployed together:

| Component | Role | Process |
|-----------|------|---------|
| **Envoy Proxy** | L7 traffic handling, TLS termination, request routing | Created automatically by the Gateway API controller (Istio on OpenShift with Service Mesh) |
| **Router (ext_proc)** | Parses MCP JSON-RPC requests, rewrites headers for tool routing | Runs as an external processing filter in Envoy |
| **Broker** | Aggregates `tools/list` from all registered servers, manages sessions, applies VirtualMCPServer filtering | Runs as the MCP endpoint that Envoy routes to |

The **MCP Gateway Controller** runs cluster-scoped (installed via OLM) and reconciles the gateway CRDs. It watches `MCPGatewayExtension` resources and creates the broker/router deployment, config Secret, Service, and EnvoyFilter in the target namespace.

#### Request Flow

For a `tools/call` request:

1. **Client** sends `{"method":"tools/call","params":{"name":"openshift_pods_list"}}` to the gateway endpoint
2. **Router (ext_proc)** intercepts the request, parses the tool name, strips the prefix (`openshift_` → `pods_list`), and rewrites the `:authority` header to route to the correct backend (`openshift-mcp-server.mcp.local`)
3. **Authorino (via Wasm plugin)** validates the JWT and evaluates authorization rules from the AuthPolicy
4. **Envoy** routes the request to the backend MCP server's HTTPRoute
5. **MCP server** executes the tool and returns the result

For a `tools/list` request:

1. **Client** sends `{"method":"tools/list"}` to the gateway endpoint
2. **Router** identifies this as a list request and forwards to the broker
3. **Broker** returns its cached, aggregated tool list (optionally filtered by VirtualMCPServer)

### Installing the MCP Gateway on OpenShift AI

#### Prerequisites

- OpenShift 4.x with Service Mesh (Istio) installed
- Kuadrant (Connectivity Link) operator installed (provides Authorino + Limitador)
- Gateway API CRDs installed (typically via Service Mesh)

#### Step 1: Install the MCP Gateway Controller via OLM

```yaml
# CatalogSource
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: mcp-gateway-catalog
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ghcr.io/kuadrant/mcp-controller-catalog:v0.6.0

# Namespace
apiVersion: v1
kind: Namespace
metadata:
  name: mcp-system

# OperatorGroup
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: mcp-system
  namespace: mcp-system
spec: {}

# Subscription
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: mcp-gateway
  namespace: mcp-system
spec:
  channel: alpha
  name: mcp-gateway
  source: mcp-gateway-catalog
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

This installs three CRDs: `MCPGatewayExtension`, `MCPServerRegistration`, and `MCPVirtualServer`.

#### Step 2: Create the `openshift-default` GatewayClass

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-default
spec:
  controllerName: openshift.io/gateway-controller/v1
```

On clusters with Service Mesh, this GatewayClass is handled by Istio (creates Envoy proxies), which is required for the ext_proc/EnvoyFilter mechanism. On clusters without Service Mesh, this would use HAProxy, and ext_proc would not work.

#### Step 3: Deploy the Gateway Instance via Helm

```bash
# Deploy gateway + MCPGatewayExtension
helm upgrade -i mcp-gateway oci://ghcr.io/kuadrant/charts/mcp-gateway \
  --version 0.6.0 \
  --namespace mcp-upstream-test --create-namespace \
  --skip-crds \
  --set controller.enabled=false \
  --set gateway.create=true \
  --set gateway.name=mcp-gateway \
  --set gateway.namespace=mcp-upstream-test \
  --set gateway.publicHost="mcp-upstream.apps.<cluster-domain>" \
  --set gateway.internalHostPattern="*.mcp.local" \
  --set gateway.gatewayClassName="openshift-default" \
  --set mcpGatewayExtension.create=true \
  --set mcpGatewayExtension.gatewayRef.name=mcp-gateway \
  --set mcpGatewayExtension.gatewayRef.namespace=mcp-upstream-test \
  --set mcpGatewayExtension.gatewayRef.sectionName=mcp

# Deploy OpenShift Route
helm upgrade -i mcp-gateway-ingress oci://ghcr.io/kuadrant/charts/mcp-gateway-ingress \
  --version 0.6.0 \
  --namespace mcp-upstream-test \
  --set mcpGateway.host="mcp-upstream.apps.<cluster-domain>" \
  --set mcpGateway.namespace=mcp-upstream-test \
  --set gateway.name=mcp-gateway \
  --set gateway.class="openshift-default" \
  --set route.create=true
```

The Helm chart creates the Gateway and MCPGatewayExtension. The controller creates the broker Deployment, Service, EnvoyFilter, and HTTPRoute. The ingress chart creates the OpenShift Route (edge TLS termination).

### Registering MCP Servers with the Gateway

See [Workflow 2: Registering MCP Servers with the Gateway](#workflow-2-registering-mcp-servers-with-the-gateway) for detailed steps.

Key points:
- Backend HTTPRoutes must use `*.mcp.local` hostnames via the `mcps` listener, not the public hostname
- Tool prefixes ensure unique tool names across servers
- The broker discovers tools within its ping interval (default 60s) after registration

### Virtual MCP Servers

See [Workflow 4: Creating and Using Virtual MCP Servers](#workflow-4-creating-and-using-virtual-mcp-servers) for detailed steps.

Key points:
- VirtualMCPServers filter `tools/list` only — they are a UX feature, not a security boundary
- The `X-Mcp-Virtualserver` header must use namespaced format: `namespace/name`
- Selection can be automated via AuthPolicy CEL expressions based on JWT claims

### Policy and Access Control

The MCP Gateway integrates with Kuadrant's policy framework for layered access control:

#### Layer 1: Gateway-level AuthPolicy

Applied to the Gateway resource. All requests through the gateway must satisfy this policy. Typically used for:
- JWT validation (require a valid token from Keycloak)
- VirtualMCPServer header injection based on user identity

#### Layer 2: Per-HTTPRoute AuthPolicy

Applied to individual server HTTPRoutes. Provides per-server or per-tool authorization. Used for:
- Role-based access (e.g., only `mcp-admin` users can access OpenShift tools)
- Group-based tool-level authorization (e.g., developers can call `greet` and `time`, ops can call `add_tool` and `slow`)
- Credential injection via metadata evaluators (e.g., Vault token exchange)

#### Layer 3: RateLimitPolicy (optional)

Applied to the Gateway or per-HTTPRoute for rate limiting. Backed by Limitador.

```yaml
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata:
  name: mcp-rate-limit
  namespace: mcp-upstream-test
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: mcp-gateway
  limits:
    per-user:
      rates:
        - limit: 100
          window: 60s
      counters:
        - expression: auth.identity.sub
```

---

## Best Practices and Constraints

### MCP Server Requirements

1. **HTTP-based transport only.** All MCP servers must use HTTP (Streamable HTTP or HTTP+SSE). Stdio-based MCP servers cannot be routed through the gateway, shared across clients, or secured with AuthPolicies. Do not deploy stdio-based servers.

2. **Explicit transport configuration.** Many MCP server images default to stdio. Always explicitly configure HTTP transport via command-line arguments (e.g., `--http 0.0.0.0:8080`). Servers that default to stdio will exit silently with no error message.

3. **Bind to `0.0.0.0`.** Servers must listen on all interfaces. Servers that bind to `127.0.0.1` are unreachable from the Envoy proxy.

4. **Follow OpenShift restricted SCC.** Run as non-root, drop all capabilities, disallow privilege escalation. This is the default Pod Security Standard on OpenShift.

5. **Include health probes.** Configure liveness and readiness probes on the MCP server's HTTP endpoint for proper Kubernetes lifecycle management.

6. **Accept credentials via HTTP headers.** MCP servers that need downstream credentials (API keys, tokens) should accept them via HTTP headers, not only through environment variables. Header-based credentials enable per-user credential injection through the gateway; environment-variable-only servers require a 1:1 deployment-per-user model.

### Authentication and Authorization

1. **Always enable authentication on the MCP Gateway.** An unauthenticated gateway allows any client to call any tool. At minimum, apply a gateway-level AuthPolicy with JWT validation.

2. **Use Keycloak roles for coarse-grained authorization.** Map access levels to Keycloak realm roles (e.g., `mcp-user`, `mcp-admin`). Use `patternMatching` in AuthPolicy to check `auth.identity.realm_access.roles`.

3. **Use Keycloak groups for fine-grained tool authorization.** When different user groups need access to different subsets of tools, use Keycloak groups and CEL predicates in AuthPolicy. Ensure token requests include the `groups` scope (`scope=openid groups`), otherwise the `groups` claim will be absent from JWTs and CEL predicates will fail silently.

4. **Layer AuthPolicies: gateway-level for authentication, per-route for authorization.** The gateway-level policy handles JWT validation (applies to all requests). Per-HTTPRoute policies handle server-specific or tool-specific authorization rules.

5. **Pair VirtualMCPServers with AuthPolicies.** VirtualMCPServers control visibility; AuthPolicies control access. Without an AuthPolicy, a user who knows a tool name can call it even if it's hidden by a VirtualMCPServer.

6. **Strip the Authorization header for backend servers using ServiceAccount auth.** When the backend MCP server uses a Kubernetes ServiceAccount (e.g., the OpenShift MCP Server), add a `RequestHeaderModifier` to the HTTPRoute to remove the `Authorization` header. Otherwise, Envoy forwards the user's Keycloak JWT, and the server may use it as Kubernetes credentials.

7. **Increase Keycloak token lifetime for development environments.** The default 5-minute access token TTL causes frequent 401 errors during testing. Set the access token lifespan to 30 minutes (1800 seconds) in development/test Keycloak realms.

### Namespace Isolation and Multi-Tenancy

1. **Use one gateway per team namespace for isolation.** Each team gets its own namespace, Gateway, MCPGatewayExtension, and broker. The broker only sees servers registered in its namespace. This provides physical isolation — a misconfigured policy in one namespace cannot expose another team's tools.

2. **Shared control plane, per-team data plane.** The MCP Gateway Controller, Keycloak, Kuadrant, and operators run in shared namespaces. Each team namespace contains its own gateway, broker, MCP servers, VirtualMCPServers, and AuthPolicies.

3. **Consider shared-gateway patterns for small teams.** If namespace isolation is overkill (small organization, low compliance requirements), a single gateway with group-based VirtualMCPServers and AuthPolicies provides logical separation. This trades isolation for simplicity — all servers are visible to the broker, and separation is policy-only.

### Deployment Patterns

Organizations should choose a deployment pattern based on team maturity and compliance requirements:

| Pattern | When to Use | Platform Engineer Owns | AI Engineer Owns |
|---------|------------|----------------------|------------------|
| **Platform-Managed** | Regulated environments, early adoption | Everything | Token + tool calls only |
| **Self-Service Servers** | AI teams build their own MCP servers | Infra, auth, policy | Server deployment |
| **Catalog-Driven** | Many non-technical AI users | Catalog + approved servers | Selects tools from catalog |
| **Namespace Admin** | Autonomous AI/ML platform teams | Shared control plane only | Full namespace ownership |

**Recommended starting point**: Platform-Managed. Evolve toward Self-Service Servers as AI teams mature, then Catalog-Driven when scaling to many non-technical users.

### Security Considerations

1. **Deploy per-namespace OpenShift MCP Server instances for AI engineers.** Use namespace-scoped RoleBindings instead of ClusterRoleBindings to limit Kubernetes API visibility to the team's namespace. Reserve cluster-scoped instances for platform engineers behind an `mcp-admin` AuthPolicy. This limits blast radius — a compromised ServiceAccount token can only see one namespace, not the entire cluster.

2. **Restrict MCP server Kubernetes access.** Use the principle of least privilege for ServiceAccount RBAC. The OpenShift MCP Server should use a `view` ClusterRole (read-only) or a custom role that restricts access to specific resources. Deny access to Secrets, ServiceAccounts, and RBAC resources via `denied_resources` in the server config.

3. **Do not expose the MCP Gateway without authentication.** The gateway aggregates access to backend services. An unauthenticated gateway is equivalent to giving anonymous users access to all registered MCP server tools.

4. **Review MCP server tool capabilities.** Before registering an MCP server with the gateway, review what tools it exposes and what actions they perform. An MCP server with write access to the Kubernetes API could create, modify, or delete resources.

5. **Use read-only mode for the OpenShift MCP Server.** Set `read_only = true` and `stateless = true` in the server configuration to prevent write operations against the Kubernetes API.

6. **Restrict toolsets to the minimum needed.** Use the `toolsets` config option to load only the toolsets appropriate for each persona. AI engineer instances should not load the `config` toolset — it exposes cluster-level configuration data. Tools that are not loaded cannot be called, regardless of gateway-level policies.

7. **Credential injection over credential embedding.** When MCP servers need credentials for downstream APIs, use the gateway's credential injection mechanism (Vault + Authorino metadata evaluators) rather than embedding credentials in environment variables or ConfigMaps. This keeps credentials out of the server's pod spec and enables per-user credential isolation.

8. **Correlate gateway and Kubernetes audit logs for per-user attribution.** Since the OpenShift MCP Server uses a ServiceAccount identity for all Kubernetes API calls, Kubernetes audit logs alone don't show which user initiated a tool call. Correlate MCP Gateway access logs (which contain JWT claims including `sub` and group membership) with Kubernetes audit log timestamps to attribute API calls to specific users.

### Observability

1. **Monitor broker logs for registration failures.** The broker logs server discovery results including tool counts and errors. Watch for "unable to check conflict, tool id is missing" warnings (informational, not blocking) and "failed to create client" errors (indicates server connectivity issues).

2. **Monitor AuthPolicy enforcement.** Authorino logs authorization decisions. Look for `403 Forbidden` responses to identify unauthorized access attempts.

3. **Monitor MCPServerRegistration status.** Check the `.status` field of MCPServerRegistration resources to verify servers are registered and healthy.

### Known Limitations (Summit MVP)

The following limitations apply to the current release and are documented to help users avoid unsupported patterns:

| # | Limitation | Impact | Workaround |
|---|-----------|--------|------------|
| 1 | **`tools/list` does not filter by user identity** | All authenticated users see all tools regardless of their role/group. VirtualMCPServers help but require explicit selection. | Use VirtualMCPServers + AuthPolicies together. Users may see tools they cannot call. |
| 2 | **Per-server auth failures surface as "network error"** | When Authorino blocks a `tools/call` with 403, the broker misinterprets it as a transport error. The Playground shows a generic "network error" instead of "access denied." | Expected behavior in the MVP. Users should check with their admin if tools fail unexpectedly. |
| 3 | **VirtualMCPServer controller namespace behavior** | In multi-tenant deployments, the VirtualMCPServer controller may write to the wrong namespace. | Manual config Secret patching may be required in namespace-isolated setups. |
| 4 | **EnvoyFilter only auto-generated for HTTP listener** | The MCP controller creates the ext_proc EnvoyFilter for port 8080 only. HTTPS listeners require manual EnvoyFilter creation. | Clone and modify the auto-generated EnvoyFilter for HTTPS ports. |
| 5 | **No integrated MCP Catalog UI** | The `mcpCatalog` dashboard feature flag is not yet available in RHOAI 3.4.0. | Use the Catalog API directly or a custom catalog UI. |
| 6 | **Keycloak token lifetime** | Default 5-minute TTL causes frequent token expiry during testing. | Increase token lifetime in Keycloak realm settings for dev/test. |

---

## Future Direction (Non-Normative)

The following capabilities are intentionally deferred from the Summit MVP. They represent the longer-term MCP roadmap on OpenShift AI:

| Capability | Description | Status |
|-----------|-------------|--------|
| **MCP Catalog UI** | Browsable catalog of MCP servers integrated into the RHOAI Dashboard | Pending `mcpCatalog` feature flag in a future RHOAI release |
| **Identity-aware tool filtering** | Broker-side filtering of `tools/list` based on user identity, eliminating the need for VirtualMCPServer selection | Requires gateway Auth Phase 2 |
| **Advanced authorization (OPA/SpiceDB)** | Policy engines beyond CEL pattern matching for complex authorization rules | Out of scope for MVP |
| **Multi-cluster deployment** | ACM-managed MCP Gateway deployments across multiple clusters with DNSPolicy | Out of scope for MVP |
| **Registry and lifecycle management** | Automated MCP server lifecycle: versioning, update policies, health-based deregistration | Out of scope for MVP |
| **Redis session store** | Broker HA with shared session state for multi-replica gateway deployments | Out of scope for MVP |
| **Advanced aggregation** | Cross-server tool composition, tool aliasing, and response transformation | Out of scope for MVP |
| **Per-user Kubernetes token passthrough** | Exchange user JWTs for Kubernetes-compatible tokens so the OpenShift MCP Server operates with per-user RBAC instead of a shared ServiceAccount. Enables per-user Kubernetes audit trails. | Experimental support exists in upstream codebase (`--require-oauth`), not yet recommended for production |
| **Integrated SSO for Playground** | Automatic Keycloak integration for Playground MCP auth (no manual token paste) | Pending RHOAI dashboard integration |

### How the MVP Fits Into the Longer-Term Roadmap

The current MVP establishes the foundational patterns:
- **Gateway-centric architecture** — all MCP traffic flows through a policy-enforced gateway
- **Declarative configuration** — Kubernetes CRDs define the entire MCP topology
- **Layered policy** — authentication, authorization, and rate limiting are composable and independently configurable
- **Persona separation** — platform engineers manage infrastructure; AI engineers consume tools

Future iterations will build on these patterns, not replace them. The CRD-based approach ensures that as capabilities like identity-aware filtering and catalog integration mature, they slot into the existing architecture without requiring re-architecture.

---

## Reference: Component Versions

Validated component versions for the MCP Ecosystem on OpenShift AI:

| Component | Version | Source |
|-----------|---------|--------|
| OpenShift | 4.21.6 | ROSA |
| RHOAI | 3.4.0 | CatalogSource |
| Service Mesh | 3.3.1 | OLM |
| Kuadrant (Connectivity Link) | 1.3.2 | OLM |
| MCP Gateway Controller | v0.6.0 | OLM (CatalogSource) |
| MCP Gateway Broker | v0.6.0 | Helm chart |
| Keycloak (RHBK) | 26.4.11 | OLM |
| Authorino Operator | 1.3.0 | OLM (via Kuadrant) |
| Limitador Operator | 1.3.0 | OLM (via Kuadrant) |
| OpenShift MCP Server | 0.2 | registry.redhat.io |
| Llama Stack | 0.6.0.1+rhai0 | registry.redhat.io |
| GatewayClass | `openshift-default` | `openshift.io/gateway-controller/v1` |

---

## Reference: Deployment Patterns

Detailed deployment pattern descriptions for organizations at different maturity levels.

### Pattern 1: Platform-Managed (Recommended Starting Point)

The platform engineer controls the full blast radius — what servers are deployed, who can see which tools, and how credentials are injected. The AI engineer cannot introduce new tools, escalate access, or misconfigure auth.

**When to use**: Regulated environments (SOC2, HIPAA, FedRAMP), early adoption where AI teams are new to MCP, or any situation requiring centralized control over tool access and credentials.

### Pattern 2: Self-Service Server Registration

The AI team deploys MCP servers within guardrails set by the platform engineer (namespace quotas, network policy, default auth). The platform engineer controls who can call what via AuthPolicies.

**When to use**: Platform team + mature AI/ML teams that build or operate their own MCP servers. Standard OpenShift model — platform provides the cluster, app teams own their workloads.

**Key difference**: The AI engineer creates MCPServer CRs in their namespace. New tools are not accessible until the platform engineer adds them to AuthPolicy and VirtualMCPServer.

### Pattern 3: Catalog-Driven Provisioning

The AI engineer's interface is a catalog (web UI or CLI), not kubectl. The platform engineer curates a menu of approved MCP servers. Deployment is triggered through the catalog UI; VirtualMCPServers and AuthPolicies may be auto-generated.

**When to use**: Large organizations with many casual AI tool users (data scientists, analysts, prompt engineers) who should not need Kubernetes knowledge. Internal marketplace model.

### Pattern 4: AI Engineer as Namespace Admin

Maximum autonomy. The AI team owns the entire namespace — gateway, servers, auth, credentials. The platform engineer provides shared control plane and namespace provisioning.

**When to use**: Large, autonomous AI/ML platform teams with Kubernetes expertise. "Namespace-as-a-service" model.

**Trade-off**: Higher autonomy, higher required expertise. The AI team must understand AuthPolicies, Vault integration, and VirtualMCPServers.
