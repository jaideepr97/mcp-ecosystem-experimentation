# MCP Ecosystem Experimentation

A chronological record of an incremental, AI-assisted experiment that starts from a completely empty Kind cluster and builds up a production-adjacent MCP ecosystem — from initial project analysis through deployment, request tracing, authentication, OAuth integration, catalog-driven discovery, automated gateway registration, and production-grade per-tool authorization with Kuadrant.

This document captures both the technical outcomes and the learning process: what the user asked at each step, how they scoped and directed the exploration, where they pushed back or changed direction, and how AI-assisted iteration allowed them to build deep understanding of complex distributed systems without prior expertise in every component.

## Table of Contents

- [Phase 1: Project Analysis](#phase-1-project-analysis)
  - [What came back](#what-came-back)
- [Phase 2: Bare-Minimum Deployment on Kind](#phase-2-bare-minimum-deployment-on-kind)
  - [Infrastructure setup](#infrastructure-setup)
  - [Issues encountered along the way](#issues-encountered-along-the-way)
  - [Deploying the operator and MCP server](#deploying-the-operator-and-mcp-server)
  - [Result](#result)
- [Phase 3: Understanding the Request Flow](#phase-3-understanding-the-request-flow)
  - [Follow-up questions](#follow-up-questions)
  - [Resources involved](#resources-involved)
  - [Request path for tools/call op_greet](#request-path-for-toolscall-op_greet)
- [Phase 4: Adding Authentication (JWT/OIDC)](#phase-4-adding-authentication-jwtoidc)
  - [Scope decision: Rejecting the production auth stack](#scope-decision-rejecting-the-production-auth-stack)
  - [Custom OIDC provider: mini-oidc](#custom-oidc-provider-mini-oidc)
  - [Istio-native JWT validation](#istio-native-jwt-validation)
  - [Result](#result-1)
  - [Issue discovered: JWKS caching](#issue-discovered-jwks-caching)
- [Phase 5: MCP Inspector Integration (OAuth 2.1 + PKCE)](#phase-5-mcp-inspector-integration-oauth-21--pkce)
  - [Extended mini-oidc](#extended-mini-oidc)
  - [Exposing mini-oidc externally](#exposing-mini-oidc-externally)
  - [Broker configuration](#broker-configuration)
- [Phase 6: The 401 vs 403 Problem](#phase-6-the-401-vs-403-problem)
  - [Problem chain](#problem-chain)
  - [User question: Is this a limitation of our custom setup?](#user-question-is-this-a-limitation-of-our-custom-setup)
  - [User follow-up: Is this an intentional design decision?](#user-follow-up-is-this-an-intentional-design-decision)
  - [User follow-up: How is this solved in production?](#user-follow-up-how-is-this-solved-in-production-should-this-be-raised)
  - [User direction on the fix](#user-direction-on-the-fix)
  - [Result](#result-2)
- [Phase 7: End-to-End OAuth Flow via MCP Inspector](#phase-7-end-to-end-oauth-flow-via-mcp-inspector)
  - [Token exchange discussion](#token-exchange-discussion)
- [Architecture Summary (as of Phase 7)](#architecture-summary-as-of-phase-7)
  - [Components on the cluster](#components-on-the-cluster)
  - [External access](#external-access)
- [Phase 8: Introducing the Catalog (Model Registry)](#phase-8-introducing-the-catalog-model-registry)
  - [Deploying the catalog](#deploying-the-catalog)
  - [Catalog API exploration](#catalog-api-exploration)
- [Phase 9: Wiring Discovery to Deployment (mcp-launcher)](#phase-9-wiring-discovery-to-deployment-mcp-launcher)
  - [Changes to mcp-launcher](#changes-to-mcp-launcher-branch-catalog-api-integration)
  - [Deploying the launcher](#deploying-the-launcher)
- [Phase 10: Catalog to Operator Deployment Flow](#phase-10-catalog--operator-deployment-flow)
  - [First deployment attempt](#first-deployment-attempt)
  - [Second deployment attempt](#second-deployment-attempt)
  - [Successful deployment](#successful-deployment)
- [Phase 11: Closing the Operator to Gateway Gap](#phase-11-closing-the-operator--gateway-gap)
  - [The PR's approach](#the-prs-approach)
  - [What needed adapting](#what-needed-adapting)
  - [Integration](#integration)
  - [Deployment and verification](#deployment-and-verification)
  - [Result](#result-3)
  - [Why the annotation-based approach works well](#why-the-annotation-based-approach-works-well)
- [Integration Friction Points](#integration-friction-points)
  - [1. Catalog runtimeMetadata insufficient for deployment](#1-catalog-runtimemetadata-insufficient-for-deployment)
  - [2. OCI image opacity — the systemic problem](#2-oci-image-opacity--the-systemic-problem)
  - [3. Operator to Gateway registration gap](#3-operator--gateway-registration-gap-resolved-in-phase-11)
  - [4. Semantic gap in arguments](#4-semantic-gap-in-arguments)
  - [5. Catalog API N+1 queries for tools](#5-catalog-api-n1-queries-for-tools)
  - [6. Operator gateway controller overwrites MCPServerRegistration spec](#6-operator-gateway-controller-overwrites-mcpserverregistration-spec)
  - [Temporary workarounds implemented](#temporary-workarounds-implemented)
- [Phase 12: Replacing mini-oidc with Keycloak](#phase-12-replacing-mini-oidc-with-keycloak)
  - [Motivation](#motivation)
  - [Evaluating mcp-gateway's existing Keycloak setup](#evaluating-mcp-gateways-existing-keycloak-setup)
  - [Decision: minimal Keycloak, no TLS](#decision-minimal-keycloak-no-tls)
  - [Integration issues encountered](#integration-issues-encountered)
  - [Resources created](#resources-created)
  - [Resources removed](#resources-removed)
  - [Resources modified](#resources-modified)
  - [Verification (client_credentials)](#verification-client_credentials)
  - [Adding users, groups, and identity-based access](#adding-users-groups-and-identity-based-access)
  - [Verification (user tokens with group claims)](#verification-user-tokens-with-group-claims)
  - [MCP Inspector (browser-based OAuth)](#mcp-inspector-browser-based-oauth)
  - [Interactive MCP client with device authorization grant](#interactive-mcp-client-with-device-authorization-grant)
- [Phase 13: Kuadrant AuthPolicy — From Binary Auth to Per-Tool Authorization](#phase-13-kuadrant-authpolicy--from-binary-auth-to-per-tool-authorization)
  - [Installing Kuadrant](#installing-kuadrant)
  - [AuthPolicy replaces three Istio workarounds](#authpolicy-replaces-three-istio-workarounds)
  - [CoreDNS fix for in-cluster Keycloak resolution](#coredns-fix-for-in-cluster-keycloak-resolution)
  - [Discovering the filter chain order](#discovering-the-filter-chain-order)
  - [Server-level authorization](#server-level-authorization)
  - [Tool-level authorization](#tool-level-authorization)
  - [Cross-server per-group per-tool authorization](#cross-server-per-group-per-tool-authorization)
  - [Remaining gap: tools/list filtering](#remaining-gap-toolslist-filtering)
  - [What Istio still handles vs what Kuadrant now handles](#what-istio-still-handles-vs-what-kuadrant-now-handles)
- [Phase 14: TLS Termination at the Gateway](#phase-14-tls-termination-at-the-gateway)
  - [cert-manager installation order matters](#cert-manager-installation-order-matters)
  - [Certificate chain](#certificate-chain)
  - [TLSPolicy auto-creates certificates](#tlspolicy-auto-creates-certificates)
  - [Gateway HTTPS listeners](#gateway-https-listeners)
  - [Kind cluster and NodePort updates](#kind-cluster-and-nodeport-updates)
  - [CA certificate extraction](#ca-certificate-extraction)
  - [User experience](#user-experience)
  - [Test coverage](#test-coverage)
- [Phase 15: Per-User Credential Exchange via Vault](#phase-15-per-user-credential-exchange-via-vault)
  - [The credential exchange flow](#the-credential-exchange-flow)
  - [Vault setup](#vault-setup)
  - [GitHub MCP server deployment](#github-mcp-server-deployment)
  - [Operator credential-ref support](#operator-credential-ref-support)
  - [Keycloak scope issues](#keycloak-scope-issues)
  - [Credential secret label mismatch](#credential-secret-label-mismatch)
  - [mcp-client.sh fix](#mcp-clientsh-fix)
  - [Test coverage](#test-coverage-1)
  - [Env-var credential limitation](#env-var-credential-limitation)
- [Architecture Summary (as of Phase 15)](#architecture-summary-as-of-phase-15)
  - [Components on the cluster](#components-on-the-cluster-1)
  - [External access](#external-access-1)
  - [The catalog to deploy to authorize to exchange to route pipeline](#the-catalog--deploy--authorize--exchange--route-pipeline-complete)
- [Phase 16-20: Design Scoping — From Single-User Experiment to Multi-Tenant Production](#phase-16-20-design-scoping--from-single-user-experiment-to-multi-tenant-production)
  - [Starting from the ticket: RHAISTRAT-1149](#starting-from-the-ticket-rhaistrat-1149)
  - [Questioning VirtualMCPServers](#questioning-virtualmcpservers)
  - [The alignment problem and Auth Phase 2](#the-alignment-problem-and-auth-phase-2)
  - [Ecosystem deployment topology](#ecosystem-deployment-topology)
  - [Credential patterns at scale](#credential-patterns-at-scale)
  - [The concrete plan](#the-concrete-plan)
- [Key Learnings](#key-learnings)
- [Reflection: How AI Was Used in This Experiment](#reflection-how-ai-was-used-in-this-experiment)
  - [Pattern of interaction](#pattern-of-interaction)
  - [What worked well](#what-worked-well)
  - [What this approach is good for](#what-this-approach-is-good-for)
  - [Author's personal insights and learnings](#authors-personal-insights-and-learnings)

---

## Phase 1: Project Analysis

> **User instruction**: *"Are you able to look at the mcp-lifecycle-operator and the mcp-gateway projects in this directory? Do a cursory scan of both and talk about how they might be able to work together."*

This was deliberately open-ended. The user had both project repositories locally and wanted a high-level read on how they related before investing time in either. No specific files or focus areas were specified — the intent was to see what an AI could extract from a cold scan and whether it would identify the integration points the user suspected existed.

### What came back

**mcp-lifecycle-operator**: A Kubebuilder-based Kubernetes operator that manages MCP server lifecycle via an `MCPServer` CRD (`mcp.x-k8s.io/v1alpha1`). For each MCPServer CR, the operator reconciles a Deployment and Service. Key file: `internal/controller/mcpserver_controller.go`.

**mcp-gateway**: An Envoy-based gateway for Model Context Protocol servers. Single binary (`mcp-broker-router`) with three components:

- **Router** — Envoy external processor (ext_proc gRPC on :50051). Parses MCP JSON-RPC requests, strips tool prefixes, rewrites `:authority` headers to steer Envoy routing.
- **Broker** — HTTP service (:8080 /mcp). Handles `initialize` and `tools/list` by aggregating tools from multiple upstream MCP servers. Not touched during `tools/call`.
- **Controller** — Watches `MCPServerRegistration` CRDs, discovers backends via HTTPRoutes, writes config.

Custom CRDs: `MCPServerRegistration`, `MCPVirtualServer`, `MCPGatewayExtension` (all `mcp.kuadrant.io/v1alpha1`).

**Integration point**: The lifecycle operator deploys MCP server pods. The gateway federates and routes to them. The bridge between the two is an HTTPRoute (pointing to the operator-created Service) and an MCPServerRegistration (registering the server with the gateway's broker/router). This confirmed the user's hypothesis — the two projects have a clean boundary with Gateway API resources as the glue.

---

## Phase 2: Bare-Minimum Deployment on Kind

> **User instruction**: *"Can you spin up a kind cluster, and then deploy the operator on it along with a very simple mcp server? Also deploy the required gateway resources in the simplest deployment pattern possible such that the mcp server is accessible via the gateway. Ignore any non-basic features for either project, I am only interested in getting something absolutely bare minimum running."*

The user was explicit about minimalism. Both projects have extensive feature sets (auth, virtual servers, Redis, scaling), but the user wanted the absolute simplest path to a working setup before layering complexity. This turned out to be important — even the "bare minimum" involved a significant number of moving parts, and each one surfaced a learning opportunity.

### Infrastructure setup

Used mcp-gateway's Makefile targets with `CONTAINER_ENGINE=podman`:

1. `make tools` — installed helm, kind, kustomize, yq, istioctl, controller-gen to `./bin/`
2. `make kind-create-cluster` — created "mcp-gateway" Kind cluster with port mappings (hostPort 8001 -> nodePort 30080, etc.)
3. `make gateway-api-install` — Gateway API CRDs
4. `make istio-install` — Istio via Sail operator (only istiod — NOT a service mesh, just a Gateway API provider)
5. `make metallb-install` — MetalLB for LoadBalancer IPs in Kind
6. `make build-and-load-image` — built and loaded mcp-gateway + mcp-controller images
7. `make deploy-gateway` — deployed Istio Gateway + NodePort service
8. `make deploy` — deployed CRDs + controller

### Issues encountered along the way

These were unplanned but highly educational. Each failure forced a deeper understanding of the underlying system.

- **Podman machine not running**: `Cannot connect to Podman` — fixed with `podman machine start`. Trivial, but a reminder that podman's machine-based architecture differs from Docker's daemon model.
- **Insufficient memory (2GB)**: istiod stuck in Pending with `Insufficient memory` — fixed by stopping podman machine, setting `--memory 8192`, restarting, and recreating the Kind cluster. Revealed that Istio's control plane has non-trivial resource requirements even in dev.
- **Operator image name**: `localhost/controller:latest` failed to pull inside Kind node (localhost treated as a registry URL) — retagged to `docker.io/mcp-lifecycle/controller:latest` and loaded via `podman save` + `kind load image-archive`. Revealed that "localhost" means something different inside a Kind node's container runtime vs on the host.
- **ImagePullPolicy Always for `:latest` tags**: Both operator and MCP server images — Kubernetes defaults to `Always` for `:latest`. Fixed by patching deployments with `imagePullPolicy: IfNotPresent`. A subtle Kubernetes convention that bites everyone working with pre-loaded images in Kind.
- **MCP server container args**: `args: ["--http", "0.0.0.0:9090"]` overrode the Dockerfile's CMD entirely because Kubernetes `args` replaces Docker CMD, not appends to it. Error: `exec: "--http": executable file not found in $PATH`. Fixed by including the binary: `args: ["/mcp-test-server", "--http", "0.0.0.0:9090"]`. The distinction between Docker's CMD/ENTRYPOINT and Kubernetes' command/args was a concrete learning.

### Deploying the operator and MCP server

Applied an MCPServer CR using mcp-gateway's test-server1 image, then wired it into the gateway with an HTTPRoute and MCPServerRegistration:

```yaml
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPServerRegistration
metadata:
  name: operator-server
  namespace: mcp-test
spec:
  toolPrefix: op_
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: operator-server-route
```

### Result

Successfully accessed the MCP server through the gateway at `http://mcp.127-0-0-1.sslip.io:8001/mcp`. Tools appeared with `op_` prefix (e.g., `op_hi`, `op_time`). At this point the user had a working end-to-end setup but no understanding of how the request actually moved through all these components.

---

## Phase 3: Understanding the Request Flow

> **User instruction**: *"Now walk me through every resource that didn't exist on the cluster before you applied it for the gateway to work. We can then walk through how a client request touches all of them before ending up at the mcp server service."*

This was the pivotal learning phase. The user had a working system but wanted to understand every component and its role. The request was structured as a two-part ask: first inventory everything, then trace the request path.

### Follow-up questions

After the initial walkthrough, the user asked a series of targeted follow-up questions. Each one peeled back a layer:

> *"http://mcp.127-0-0-1.sslip.io:8001/mcp — what does this endpoint point to?"*

The user wanted to understand the full chain from the URL to the actual pod. This revealed the Kind port mapping -> NodePort -> Envoy -> Broker chain.

> *"What exactly is Envoy and what is its relationship to the Gateway and Istio?"*

The user realized they were conflating three things (the Gateway resource, Envoy the proxy, and Istio the controller) and needed them disentangled. The answer clarified that Gateway is declarative config, Envoy is the runtime data plane, and Istio is the control plane that translates one into the other.

> *"Can you create a diagram that shows the request path going through all these components? Make sure that component relationships are also appropriately highlighted in the process."*

The user wanted a visual. A Mermaid diagram was created (`mcp-gateway-request-flow.html`).

> *"Can you update your diagram such that every box where the request physically touches is highlighted in some sense? So I can be clear on which components fall directly into the path of the request and which components exist to enable/manage these line of sight components."*

A refinement — the user realized the first diagram didn't distinguish between components the request bytes flow through (data path) and components that configure/manage those components (control plane). The updated diagram used:
- **Pink with thick borders** for data path components
- **Gray** for control plane components
- **Numbered solid arrows (1-6)** for the tools/call request path
- **Dashed arrows** for control plane relationships

> *"For the initialize path, presumably the flow is the same until it gets to the broker instead of router, then the broker speaks directly with the mcp server to get its tool list? And then how does it return this information?"*

Testing a mental model. This revealed the key architectural insight: for `tools/call`, the Router rewrites `:authority` and Envoy routes directly to the upstream (Broker is never touched). For `initialize`/`tools/list`, the Router leaves `:authority` unchanged and Envoy routes to the Broker, which aggregates responses.

> *"Is it safe to say that the number of HTTPRoutes in the system depend on the number of listeners in the gateway?"*

Checking a generalization. The answer corrected the user — HTTPRoutes depend on the number of backends, not listeners. Multiple HTTPRoutes can attach to the same listener, distinguished by hostname.

> *"How does the router know to pick the correct one?"*

Understanding the routing decision. The Router reads the tool name prefix, looks up the corresponding MCPServerRegistration config, and sets `:authority` to that upstream's HTTPRoute hostname.

> *"And what is the role of ReferenceGrant and MCPGatewayExtension here?"*

Filling in the gaps — understanding cross-namespace permissions (ReferenceGrant) and how the controller knows which Gateway to attach to (MCPGatewayExtension).

> *"Is this a very simplistic arrangement of these things? How close is this to a production setup on say an OpenShift AI cluster?"*

Zooming out for perspective. The answer covered what production adds: TLS, auth (Kuadrant + Keycloak), multiple MCP server registrations, Redis for session caching, horizontal scaling, and monitoring.

> *"What is MetalLB?"*

Asked separately when it came up in conversation. MetalLB is needed specifically in bare-metal/Kind environments to assign IPs to LoadBalancer Services — without it, the Gateway stays in Pending and never reaches `Programmed: True`.

### Resources involved

| Resource | Namespace | Role |
|----------|-----------|------|
| Gateway `mcp-gateway` | gateway-system | Declares listeners (mcp, mcps). Istio reads this to program Envoy. |
| Service `mcp-gateway-np` (NodePort) | gateway-system | Receives external traffic: hostPort 8001 -> nodePort 30080 -> port 8080 |
| Envoy pod `mcp-gateway-istio` | gateway-system | L7 proxy. Programmed by Istio via xDS. Runs ext_proc filter. |
| EnvoyFilter | gateway-system | Tells Istio to inject ext_proc filter into Envoy's chain |
| ReferenceGrant | gateway-system | Permits cross-namespace Gateway reference from MCPGatewayExtension |
| istiod | istio-system | Watches Gateway/HTTPRoute resources, programs Envoy |
| MCPGatewayExtension | mcp-system | Declares: attach broker/router to Gateway's mcp listener |
| HTTPRoute `mcp-gateway-route` | mcp-system | Routes `mcp.127-0-0-1.sslip.io` -> mcp-gateway:8080 (broker) |
| Service `mcp-gateway` | mcp-system | Exposes broker (:8080) and router (:50051) |
| Secret `mcp-gateway-config` | mcp-system | Upstream server list. Controller writes, broker reads. |
| mcp-controller | mcp-system | Watches MCPServerRegistration, writes config |
| MCPServerRegistration | mcp-test | Registers upstream with prefix, references HTTPRoute |
| HTTPRoute `operator-server-route` | mcp-test | Routes `operator-server.mcp.local` -> operator-server:9090 |
| Service `operator-server` | mcp-test | ClusterIP :9090 (created by lifecycle operator) |
| MCP server pod | mcp-test | test-server1 container, handles tools/call |
| MetalLB | metallb-system | Assigns LoadBalancer IP so Gateway reaches Programmed: True |

### Request path for `tools/call op_greet`

```
Client (localhost:8001)
  -> Kind nodePort 30080
  -> NodePort Service -> Envoy pod (:8080)
  -> ext_proc filter calls Router (gRPC :50051)
  -> Router: parses JSON-RPC, strips "op_" prefix, sets :authority = operator-server.mcp.local
  -> Returns to Envoy with modified headers
  -> Envoy route matches on new :authority -> operator-server:9090
  -> MCP server pod handles "greet" (prefix stripped)
```

---

## Phase 4: Adding Authentication (JWT/OIDC)

> **User instruction**: *"Let's step this up a bit and try to bring authn/authz into the fold. What is the simplest modification we can make to this current setup to simulate a functional OIDC/OAuth2 based auth workflow? Maybe update the fake MCP server to require an OIDC/OAuth token and set up a barebones OIDC provider? We can leave token exchange out for now."*

This was a deliberate scope escalation — the user had understood the basic flow and wanted to add the next layer of real-world complexity. The instruction was explicit about leaving token exchange out; the user wanted to learn one thing at a time.

### Scope decision: Rejecting the production auth stack

The initial AI proposal was to install cert-manager, Kuadrant operator (Authorino), and Keycloak — the mcp-gateway's production auth stack. The user pushed back:

> *"Before we jump to setting up full-blown Keycloak — can we not just set up a lightweight OIDC provider of our own? I simply want to understand the flow for now."*

This was a key scoping decision. The user didn't want to learn "how to deploy Keycloak" — they wanted to understand "what does an OIDC provider actually do in this flow." Building one from scratch (even a minimal one) would teach far more than deploying a black box. This turned out to be one of the most valuable decisions in the experiment.

### Custom OIDC provider: mini-oidc

Built a lightweight OIDC provider in Go (`/Users/jrao/projects/mini-oidc/main.go`):

- Generates RSA 2048-bit key pair at startup
- Serves OIDC discovery at `/.well-known/openid-configuration`
- Serves JWKS at `/jwks`
- Issues RS256 JWTs with configurable issuer/audience
- Simple `/token` endpoint for quick token issuance
- Two env vars: `ISSUER` (internal URL for JWT `iss` claim) and `EXTERNAL_URL` (browser-reachable URL for discovery endpoints)

### Istio-native JWT validation

Used Istio's built-in resources (no Kuadrant needed):

**RequestAuthentication** — tells Envoy how to validate JWTs:

```yaml
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: mcp-jwt-auth
  namespace: gateway-system
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: mcp-gateway
  jwtRules:
  - issuer: "http://mini-oidc.mcp-test.svc.cluster.local:9090"
    jwksUri: "http://mini-oidc.mcp-test.svc.cluster.local:9090/jwks"
    forwardOriginalToken: true
```

**AuthorizationPolicy** — requires a valid JWT principal, exempts `.well-known` endpoints:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: mcp-require-jwt
  namespace: gateway-system
spec:
  action: ALLOW
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: mcp-gateway
  rules:
  - from:
    - source:
        requestPrincipals: ["*"]
  - to:
    - operation:
        paths: ["/.well-known/*"]
```

### Result

- 403 without token (RBAC: access denied)
- 401 with bad/expired token
- 200 with valid JWT from mini-oidc

### Issue discovered: JWKS caching

When mini-oidc restarts (regenerating RSA keys), Envoy continues using cached JWKS. Debugging revealed that Istio fetches JWKS once and bakes it as `local_jwks` inline in the Envoy config — it doesn't refetch dynamically. Fix: restart istiod + Envoy pod to force JWKS refresh. This is a known operational consideration — in production, OIDC providers persist their keys across restarts.

---

## Phase 5: MCP Inspector Integration (OAuth 2.1 + PKCE)

> **User instruction**: *"How do I test this flow via the MCP Inspector as client?"*

This question exposed a significant gap. MCP Inspector implements the full MCP auth spec (OAuth 2.1 with authorization code + PKCE), but mini-oidc only had a simple token endpoint. When asked whether to extend mini-oidc to support the full flow, the user confirmed:

> *"Yes."*

### Extended mini-oidc

Added the following to support the full MCP auth spec:

- **Authorization endpoint** (`/authorize`): GET shows HTML approve page, POST generates auth code and redirects with `?code=...&state=...`
- **PKCE support**: S256 code challenge validation on token exchange
- **Dynamic Client Registration** (`/register`): RFC 7591 — accepts client metadata, returns `client_id`. MCP Inspector uses this to register itself before starting the auth flow.
- **OAuth AS metadata** (`/.well-known/oauth-authorization-server`): Same as OIDC discovery, needed by some OAuth clients.
- **CORS middleware**: All endpoints wrapped with `Access-Control-Allow-Origin: *` for browser-based clients.

Building these from scratch (rather than deploying Keycloak) meant each endpoint's purpose was understood concretely. PKCE in particular became tangible — it's not an abstract spec when you're writing the SHA256 verification yourself.

### Exposing mini-oidc externally

#### Failed approach: Through the gateway

Attempted to route mini-oidc traffic through Envoy by adding an `oidc` listener to the Gateway and an HTTPRoute for `oidc.127-0-0-1.sslip.io`. This resulted in 404s.

**Root cause**: The ext_proc (Router) unconditionally rewrites the `:authority` header on ALL requests arriving on port 8080 to the MCP gateway hostname — this happens in `HandleRequestHeaders()` before Envoy does route matching. Non-MCP traffic gets its host rewritten and 404s.

```go
// internal/mcp-router/request_handlers.go:198
func (s *ExtProcServer) HandleRequestHeaders(_ *eppb.HttpHeaders) ([]*eppb.ProcessingResponse, error) {
    requestHeaders := NewHeaders()
    requestHeaders.WithAuthority(s.RoutingConfig.MCPGatewayExternalHostname)  // always rewrites
    return response.WithRequestHeadersReponse(requestHeaders.Build()).Build(), nil
}
```

This was a valuable debugging exercise — it required reading the Envoy config dump, comparing virtual host domains, and tracing through the ext_proc code to find the root cause. The insight was architectural: ext_proc operates on the entire port, not per-listener. Anything sharing that port gets processed by the Router.

#### Working approach: Separate NodePort

Exposed mini-oidc directly via a NodePort service (port 30471 -> host port 8003), bypassing Envoy entirely. mini-oidc accessible at `http://localhost:8003`.

### Broker configuration

Set `OAUTH_AUTHORIZATION_SERVERS=http://localhost:8003` on the broker so it serves OAuth protected resource metadata at `/.well-known/oauth-protected-resource`.

---

## Phase 6: The 401 vs 403 Problem

When MCP Inspector was first tested, it returned error `-32001` (request timeout) before any OAuth flow started. This led to one of the most interesting discoveries in the experiment.

### Problem chain

1. MCP Inspector POSTs to `/mcp` without a token
2. Istio's AuthorizationPolicy returns **403** with body "RBAC: access denied"
3. MCP Inspector doesn't recognize 403 as an auth challenge — it expects **401** with a `WWW-Authenticate` header per RFC 6750
4. Inspector retries until timeout (-32001)

### User question: Is this a limitation of our custom setup?

> *"Is this a limitation of using our custom OIDC provider/auth setup?"*

The answer: no. This is a limitation of **Istio's AuthorizationPolicy** — it would be the same with Keycloak or any OIDC provider. The issue is at the gateway enforcement layer, not the identity provider.

### User follow-up: Is this an intentional design decision?

> *"Can you look through Envoy/Istio code/docs to see if this is an intentional design decision?"*

The user wanted to know if this was a bug, a configuration gap, or a deliberate choice — because the answer determines whether to file an issue, work around it, or accept it.

**Finding**: Confirmed as intentional by Istio maintainer Yangmin Zhu in [istio/istio#26559](https://github.com/istio/istio/issues/26559), closed as "working as designed":

- **RequestAuthentication** validates JWTs but **allows requests with no token** (no token = nothing to validate). Returns 401 only for *invalid* tokens.
- **AuthorizationPolicy** checks for principals. When no token was provided, no principal is set, so the ALLOW rule doesn't match. The RBAC filter **always returns 403** — this is hardcoded in Envoy with no configuration to change it.

This is a strict authn/authz separation: authentication asks "is the token valid?" while authorization asks "is the principal allowed?" Semantically correct for RBAC, but incompatible with OAuth's expectation of 401 for "not yet authenticated."

### User follow-up: How is this solved in production? Should this be raised?

> *"How would this issue need to be solved in production? Is this something that should be raised?"*

This question was about whether a real gap had been found worth reporting. It turned out the mcp-gateway team already solved this — they use **Kuadrant's AuthPolicy** (backed by Authorino), which acts as an external authorization server via Envoy's `ext_authz` protocol. AuthPolicy gives full control over the denial response, including custom status codes and headers. No issue needed — just a gap in the minimal setup caused by skipping Kuadrant.

### User direction on the fix

> *"Yeah, proceed with the light one for now."*

The user accepted the Lua EnvoyFilter approach as a lightweight substitute for Kuadrant. The filter checks for Bearer tokens and returns a proper 401 with `WWW-Authenticate` header:

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: mcp-auth-401
  namespace: gateway-system
spec:
  workloadSelector:
    labels:
      gateway.networking.k8s.io/gateway-name: mcp-gateway
  configPatches:
  - applyTo: HTTP_FILTER
    match:
      context: GATEWAY
      listener:
        portNumber: 8080
        filterChain:
          filter:
            name: envoy.filters.network.http_connection_manager
            subFilter:
              name: envoy.filters.http.router
    patch:
      operation: INSERT_BEFORE
      value:
        name: envoy.filters.http.lua
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua
          inline_code: |
            function envoy_on_request(request_handle)
              local path = request_handle:headers():get(":path")
              local auth = request_handle:headers():get("authorization")
              if path and path:find("^/.well%-known") then return end
              local method = request_handle:headers():get(":method")
              if method == "OPTIONS" then return end
              if path and path:find("^/mcp") and (not auth or not auth:find("^Bearer ")) then
                request_handle:respond(
                  {
                    [":status"] = "401",
                    ["WWW-Authenticate"] = 'Bearer resource_metadata="http://mcp.127-0-0-1.sslip.io:8001/.well-known/oauth-protected-resource"',
                    ["content-type"] = "application/json",
                    ["access-control-allow-origin"] = "*",
                    ["access-control-allow-headers"] = "Content-Type, Authorization",
                    ["access-control-allow-methods"] = "GET, POST, OPTIONS"
                  },
                  '{"error":"Unauthorized","message":"Authentication required."}'
                )
              end
            end
```

### Result

All three scenarios work:
- No token -> 401 Unauthorized with `WWW-Authenticate` header
- `.well-known` endpoints -> 200 (no auth required)
- Valid token -> 200 with MCP response

---

## Phase 7: End-to-End OAuth Flow via MCP Inspector

MCP Inspector was pointed at `http://mcp.127-0-0-1.sslip.io:8001/mcp`. The complete flow worked:

1. Inspector hits `/mcp` -> gets **401** with `WWW-Authenticate: Bearer resource_metadata="..."`
2. Discovers auth server at `http://localhost:8003` via `/.well-known/oauth-protected-resource`
3. Fetches `http://localhost:8003/.well-known/oauth-authorization-server` -> discovers endpoints
4. Calls `/register` (RFC 7591 Dynamic Client Registration) -> gets `client_id`
5. Redirects browser to `/authorize` with PKCE challenge
6. User sees mini-oidc approve page, clicks "Approve"
7. mini-oidc generates auth code, redirects back with `?code=...&state=...`
8. Inspector exchanges auth code for JWT at `/token` with PKCE code_verifier
9. mini-oidc validates PKCE, issues RS256 JWT
10. Inspector sends authenticated requests -> Envoy validates JWT -> tools list returned

> *User confirmation*: *"No other error, after redirection I could click on list tools."*

### Token exchange discussion

> **User question**: *"What if the MCP server required a special token? I assume this would be the token exchange case?"*

This was a forward-looking question — having understood the basic auth flow, the user wanted to understand the next tier of complexity. Three tiers were identified:

1. **Static API key swap**: MCPServerRegistration `credentialRef` points to a Secret. Router sets `x-mcp-api-key` header. Already built into mcp-gateway.
2. **OAuth Token Exchange (RFC 8693)**: Kuadrant AuthPolicy pipeline — validate client token, try Vault for stored credentials, fall back to OAuth token exchange with Keycloak (swap broad-scope client token for server-scoped token with `audience` set to the target server). The gateway handles the exchange transparently; the client never needs to know about upstream auth requirements.
3. **Cross-IDP federation**: Out of scope for mcp-gateway's phase 1.

---

## Architecture Summary (as of Phase 7)

This snapshot captures the cluster state after Phase 7 — basic gateway routing with mini-oidc authentication and the Lua EnvoyFilter workaround for 401 responses. Catalog, Keycloak, and Kuadrant were not yet introduced.

### Components on the cluster

```
Kind Node (mcp-gateway)
|
+-- gateway-system namespace
|   +-- Envoy pod (mcp-gateway-istio) — L7 proxy, data path
|   +-- NodePort Service (30080 -> 8080) — external ingress
|   +-- Gateway resource — declarative listener config
|   +-- ReferenceGrant — cross-namespace permissions
|   +-- RequestAuthentication — JWT validation rules
|   +-- EnvoyFilter (ext_proc) — injects Router into Envoy
|   +-- EnvoyFilter (Lua) — 401 auth challenge for unauthenticated requests
|
+-- istio-system namespace
|   +-- istiod — programs Envoy via xDS
|
+-- mcp-system namespace
|   +-- mcp-gateway pod (broker + router + controller)
|   +-- MCPGatewayExtension — attaches to Gateway
|   +-- HTTPRoute (mcp-gateway-route) — routes to broker
|   +-- Secret (config) — upstream server list
|
+-- mcp-test namespace
|   +-- operator-server pod (test MCP server, created by lifecycle operator)
|   +-- operator-server Service (created by lifecycle operator)
|   +-- MCPServer CR (lifecycle operator input)
|   +-- MCPServerRegistration (gateway registration)
|   +-- HTTPRoute (operator-server-route)
|   +-- mini-oidc pod (custom OIDC provider)
|   +-- mini-oidc Services (ClusterIP + NodePort 30471)
|
+-- mcp-lifecycle-operator-system namespace
|   +-- lifecycle operator pod
|
+-- metallb-system namespace
    +-- MetalLB (LoadBalancer IP assignment)
```

### External access

| Port | Maps to | Service |
|------|---------|---------|
| localhost:8001 | nodePort 30080 -> Envoy :8080 | MCP Gateway |
| localhost:8003 | nodePort 30471 -> mini-oidc :9090 | OIDC Provider |

---

## Phase 8: Introducing the Catalog (Model Registry)

> **User instruction**: *"Can you move the catalog components to their own namespace, or will that cause operational issues? I would like to leave mcp-test as a deployment space for the actual servers and the lifecycle operator to use and manage."*

With the gateway, operator, auth, and OAuth flows working, the user turned to the missing piece: **discovery**. How does a user find out what MCP servers are available to deploy? The user wanted to introduce the [model-registry](https://github.com/kubeflow/model-registry) catalog service — a metadata store that indexes MCP servers, their tools, artifacts, and runtime requirements.

### Deploying the catalog

The catalog service requires PostgreSQL as a metadata backend. Deployed into a dedicated `catalog-system` namespace to keep it separate from the MCP server deployment space (`mcp-test`):

- **PostgreSQL**: StatefulSet + PVC + Secret + Service
- **Catalog ConfigMap** (`mcp-catalog-sources`): Contains `sources.yaml` (pointing to a local YAML source) and `mcp-servers.yaml` (server definitions including test-server1 with OCI artifact, runtime metadata, tools, and prerequisites)
- **Catalog Service**: Deployment + ClusterIP Service exposing the REST API on port 8080

### Catalog API exploration

The catalog API provides:

- `GET /api/mcp_catalog/v1alpha1/mcp_servers` — lists all registered MCP servers with metadata (name, description, version, artifacts, runtimeMetadata, toolCount)
- `GET /api/mcp_catalog/v1alpha1/mcp_servers/{id}/tools` — returns tools for a specific server
- `GET /api/mcp_catalog/v1alpha1/filter_options` — returns available filter facets (returned empty for our YAML-based catalog)

**Observation**: The list endpoint returns `toolCount` but not the tools themselves. A consumer building a UI must make N+1 API calls (one for the list, then one per server for tools). An `include=tools` query parameter or embedding tools in the list response would reduce round trips.

---

## Phase 9: Wiring Discovery to Deployment (mcp-launcher)

> **User instruction**: *"How would we go about wiring the discovery in? We may need to expose the catalog service publicly and have some kind of UI to see what's available."*

The user needed a bridge between "here's what the catalog says is available" and "deploy it on the cluster." The [mcp-launcher](https://github.com/matzew/mcp-launcher) project already had a web UI for browsing a catalog and deploying MCP servers — but it was hardcoded to read from Kubernetes ConfigMaps.

> **User instruction**: *"Take a quick look at https://github.com/matzew/mcp-launcher/tree/main. I think this has done a lot of this already. I wonder if it is hardcoded for a set of servers already or if it can be repurposed for our needs."*

After analyzing the launcher codebase, the approach was clear: fork it, extract a `Store` interface from the concrete `ConfigMapStore`, and add an `APIStore` backend that reads from the catalog REST API. This lets the launcher work with either backend depending on environment configuration.

### Changes to mcp-launcher (branch: `catalog-api-integration`)

1. **Extracted `Store` interface** from the concrete `ConfigMapStore` type in `catalog/catalog.go` — `List(ctx) ([]ServerEntry, error)` and `Get(ctx, name) (*ServerEntry, error)`

2. **Added `APIStore` backend** (`catalog/api_store.go`):
   - Reads from catalog REST API at `CATALOG_API_URL`
   - Maps catalog API response schema to launcher's internal types: `artifacts` → `packages`, `runtimeMetadata` → `kubernetesExtensions`, `prerequisites` → environment variables / secret mounts
   - Fetches tools per-server from the `/tools` endpoint
   - Strips `oci://` prefix from artifact URIs

3. **Added `Tool` type** to `ServerEntry` and updated `catalog.html` template to render tools as badges with hover descriptions

4. **Removed all gateway awareness** — the launcher originally created HTTPRoutes and MCPServerRegistrations when deploying servers. The user explicitly directed this removal:

   > *"The mcp launcher should not be aware of this detail."*
   > *"Get rid of any code in the launcher that makes it aware of gateway resources."*

   Removed: `GatewayConfig` struct, `createHTTPRoute()`, `createMCPServerRegistration()`, `toolPrefix()`, gateway resource creation from `Run`/`QuickDeploy`/`Delete` handlers, and gateway RBAC from the ClusterRole. The launcher now only bridges catalog → operator (MCPServer CR creation). Gateway routing registration is a separate concern for a future iteration.

5. **Added editable YAML mode** to the configure page — an "Edit YAML" toggle that swaps the read-only preview for an editable textarea, with a `POST /apply` endpoint that accepts raw YAML and creates the MCPServer CR directly. This was added as a workaround for the catalog metadata gaps (see integration friction below) — when the generated YAML is missing required fields like container arguments, the user can manually edit it before deploying.

### Deploying the launcher

Deployed to `mcp-test` namespace with:
- ServiceAccount + ClusterRole + ClusterRoleBinding (permissions for MCPServer CRs, Secrets, ConfigMaps, ServiceAccounts, Namespaces)
- Deployment with `CATALOG_API_URL` pointing to the catalog service's ClusterIP
- Service + NodePort (30472 → host port 8004)

---

## Phase 10: Catalog → Operator Deployment Flow

### First deployment attempt

Deploying test-server1 through the launcher UI failed immediately:

```
MCPServer.mcp.x-k8s.io "test-server1" is invalid: [spec.image: Required value, spec.port: Required value]
```

**Root cause**: The MCPServer CRD on the cluster was stale. When the operator was first deployed (Phase 2), the CRD used a flat schema (`spec.image`, `spec.port`). The operator repo had since been updated to a nested schema (`spec.source.containerImage.ref`, `spec.config.port`), but the CRD on the cluster was never updated. The launcher was generating the correct nested spec, but the CRD's validation rejected it.

**Fix**: Re-ran `make install` from the operator repo to apply the updated CRD, then rebuilt and redeployed the operator binary to match the new types. Also had to delete a stale leader lease (`kubectl delete lease bed7462b.x-k8s.io`) because the new operator pod couldn't acquire the lease held by the old pod identity.

### Second deployment attempt

The MCPServer CR was accepted, and the operator created a Deployment + Service. But the pod was in `CrashLoopBackOff`:

```
2026/04/01 17:41:56 MCP handler use stdio
```

The container started, defaulted to stdio transport mode, and immediately exited. The pod had no `args` — the catalog metadata provided the image and port but nothing about how to start the server in HTTP mode.

**Root cause**: This is friction point #1 — the catalog's `runtimeMetadata` has `defaultPort` and `mcpPath` but no field for container command or arguments. The image's default CMD (`["/mcp-test-server"]`) runs in stdio mode. It needs `["/mcp-test-server", "--http", "0.0.0.0:9090"]` to run as an HTTP server.

Additionally, the operator defaults to restricted Pod Security Standards (`runAsNonRoot: true`), but the test-server1 image runs as root. The catalog has no field indicating this requirement.

### Successful deployment

With the editable YAML feature, the user manually added the missing fields:

```yaml
spec:
  source:
    type: ContainerImage
    containerImage:
      ref: ghcr.io/kuadrant/mcp-gateway/test-server1:latest
  config:
    port: 9090
    path: /mcp
    arguments:
      - /mcp-test-server
      - --http
      - 0.0.0.0:9090
  runtime:
    security:
      securityContext:
        runAsNonRoot: false
```

The server deployed successfully, confirming the end-to-end flow: catalog API → launcher UI → MCPServer CR → operator → Deployment + Service → running pod.

---

## Phase 11: Closing the Operator → Gateway Gap

> **User instruction**: *"From what I can tell the only remaining gap in the end to end flow between discovering a server and accessing it securely behind the gateway is the server registration piece. Is that accurate?"*

The user identified the last missing piece: once the lifecycle operator deploys an MCP server (Deployment + Service), nothing automatically creates the HTTPRoute and MCPServerRegistration needed to make it routable through the gateway. In earlier phases this was done manually.

> **User instruction**: *"There is a downstream version of the lifecycle operator project in the projects directory. Take a look at this PR https://github.com/openshift/mcp-lifecycle-operator/pull/3. It adds some changes to the operator to make it aware of gateway integration resources but it is probably very out of sync with the latest state of the project. I would like you to understand the changes it is trying to introduce, and integrate them in a new branch of the downstream operator."*

### The PR's approach

[openshift/mcp-lifecycle-operator#3](https://github.com/openshift/mcp-lifecycle-operator/pull/3) introduced a well-designed gateway integration pattern:

- **Separate controller** (`MCPServerGatewayReconciler`) — avoids conflicts with the main reconciler by operating independently and using status patches only
- **Annotation-driven** — no spec changes required, avoiding merge conflicts with upstream. Three annotations:
  - `mcp.x-k8s.io/gateway-ref: namespace/name` (required — triggers gateway resource creation)
  - `mcp.x-k8s.io/gateway-hostname: custom.example.com` (optional — defaults to `<name>.mcp.local`)
  - `mcp.x-k8s.io/gateway-tool-prefix: kube_` (optional — defaults to `<name_underscored>_`)
- **Creates two resources** with owner references for automatic garbage collection:
  - **HTTPRoute** — routes traffic from the gateway to the server's Service
  - **MCPServerRegistration** — registers the server with the gateway's broker for tool aggregation
- **GatewayReady status condition** on the MCPServer CR — reports whether gateway resources are configured
- **Graceful degradation** — if Gateway API or MCPServerRegistration CRDs aren't installed, sets `GatewayReady=False` with `CRDNotInstalled` reason instead of crashing
- **Handles toolPrefix immutability** — MCPServerRegistration's `toolPrefix` is immutable in the CRD, so the controller deletes and recreates if the annotation changes

### What needed adapting

The PR was written against an older version of the operator with a flat spec schema. Three things needed updating:

1. **Nested spec access**: `mcpServer.Spec.Port` → `mcpServer.Spec.Config.Port`, `mcpServer.Spec.Path` → `mcpServer.Spec.Config.Path`
2. **MCPServerRegistration API group**: `mcp.kagenti.com` → `mcp.kuadrant.io` (matches what's deployed on the cluster — the CRD group appears to have changed at some point)
3. **Test MCPServer construction**: flat `Image`/`Port` fields → nested `Source.ContainerImage` (pointer) / `Config.Port`

### Integration

Created branch `gateway-integration` on the downstream operator (`/Users/jrao/projects/mcp-lifecycle-operator`). Files added/modified:

- `internal/controller/mcpserver_gateway_controller.go` — the gateway reconciler, adapted for nested spec
- `internal/controller/mcpserver_gateway_controller_test.go` — comprehensive tests (no annotation, valid ref, defaults, custom values, malformed ref, annotation changes, annotation removal)
- `config/crd/test/gateway/httproute-crd.yaml` — minimal HTTPRoute CRD for envtest
- `config/crd/test/gateway/mcpserverregistration-crd.yaml` — minimal MCPServerRegistration CRD for envtest (using `mcp.kuadrant.io`)
- `config/rbac/gateway_role.yaml` — ClusterRole for HTTPRoute and MCPServerRegistration CRUD
- `config/rbac/gateway_role_binding.yaml` — ClusterRoleBinding for the operator's ServiceAccount
- `config/rbac/kustomization.yaml` — updated to include gateway RBAC
- `internal/controller/suite_test.go` — updated to load gateway test CRDs
- `cmd/main.go` — registers the `MCPServerGatewayReconciler` alongside the main reconciler

All tests pass (`make test`).

### Deployment and verification

Built and deployed the updated operator to the cluster. Then deployed test-server1 from the catalog via the launcher's YAML editor with the gateway annotation included:

```yaml
apiVersion: mcp.x-k8s.io/v1alpha1
kind: MCPServer
metadata:
  name: test-server1
  namespace: mcp-test
  annotations:
    mcp.x-k8s.io/gateway-ref: gateway-system/mcp-gateway
spec:
  source:
    type: ContainerImage
    containerImage:
      ref: ghcr.io/kuadrant/mcp-gateway/test-server1:latest
  config:
    port: 9090
    path: /mcp
    arguments:
      - /mcp-test-server
      - --http
      - 0.0.0.0:9090
  runtime:
    security:
      securityContext:
        runAsNonRoot: false
```

### Result

The operator automatically created all resources:

- **Deployment + Service** (main reconciler, as before)
- **HTTPRoute** with hostname `test-server1.mcp.local` pointing to the gateway (gateway controller)
- **MCPServerRegistration** with tool prefix `test_server1_` (gateway controller)

Status conditions on the MCPServer CR:
- `Ready: True` — "Deployment is available and ready"
- `GatewayReady: True` — "HTTPRoute and MCPServerRegistration are configured"

The gateway picked up the registration immediately — 5 tools visible, status `Ready`. The full pipeline is now automated:

```
Catalog API (catalog-system)          — "what's available"
  ↓ REST API
MCP Launcher (mcp-test)               — "browse, configure, deploy"
  ↓ creates MCPServer CR (with gateway-ref annotation)
Lifecycle Operator (operator-system)  — "make it run AND make it routable"
  ↓ creates Deployment + Service + HTTPRoute + MCPServerRegistration
Gateway (gateway-system)              — "route requests to the server"
```

### Why the annotation-based approach works well

The decision to use annotations rather than spec fields was deliberate in the original PR and proved to be the right call:

1. **No upstream spec changes** — the gateway integration is a downstream concern. Using annotations means the MCPServer CRD doesn't need to change, avoiding merge conflicts when syncing with upstream.
2. **Opt-in per server** — servers without the annotation work exactly as before. Gateway integration is additive.
3. **Separate controller** — the gateway reconciler can't interfere with the main reconciler's work. Status updates use patches to avoid write conflicts.
4. **Clean lifecycle** — owner references mean deleting the MCPServer CR automatically cleans up the HTTPRoute and MCPServerRegistration. Removing the annotation also triggers cleanup.

---

## Integration Friction Points

These are the significant integration gaps discovered during the catalog integration phases. They represent real contract mismatches between the catalog, operator, and gateway — not bugs in any individual project, but gaps in the interfaces between them.

### 1. Catalog `runtimeMetadata` insufficient for deployment

The catalog schema has `artifacts[].uri` (OCI image) and `runtimeMetadata.defaultPort`/`mcpPath`, but is missing:

- **Container command/entrypoint**: No field for the binary path or entrypoint. The operator's `config.arguments` maps to Kubernetes `container.args` which *replaces* CMD for images without ENTRYPOINT. Without knowing the binary (e.g., `/mcp-test-server`), a deployer can't construct correct arguments.
- **Container arguments**: No equivalent of the operator's `config.arguments`. Some images need specific flags (e.g., `--http 0.0.0.0:9090`), but this isn't captured in catalog metadata.
- **Security context requirements**: The operator defaults to `runAsNonRoot: true`. The catalog has no field indicating whether an image requires root. A deployer reading only catalog metadata has no way to know deployment will fail.

**Impact**: The catalog metadata alone is insufficient to deploy — you need out-of-band knowledge about each image.

### 2. OCI image opacity — the systemic problem

The friction points above are symptoms of a deeper structural issue: **OCI images are opaque, and catalog metadata doesn't carry enough operational context to deploy them reliably.** Each MCP server image can differ across multiple dimensions simultaneously:

- **Entrypoint/CMD conventions**: Some use ENTRYPOINT (args append), some use CMD (args replace), some use both. Kubernetes `container.args` replaces CMD — destructive if the deployer gets it wrong.
- **Transport selection**: Servers default to different transports (stdio, HTTP/SSE, streamable-HTTP). The flag to switch varies per image.
- **Bind address conventions**: Some listen on `0.0.0.0`, some on `127.0.0.1`. Some accept `host:port`, others take separate `--port`/`--host` flags.
- **Security context**: Root vs non-root, specific UID requirements, filesystem write needs.

In the worst case, every MCP server image is a snowflake. The catalog becomes a registry of names without enough operational metadata to deploy anything. This is the most significant integration gap observed — it's not a single missing field but a **missing contract between image authors, catalog curators, and the deployment operator**.

Possible solutions:
1. **OCI image convention** — standardized ENTRYPOINT contract for MCP servers
2. **Richer catalog metadata** — extend `runtimeMetadata` to cover command, args, security context
3. **Deployment profiles** — a separate layer encoding per-image operational knowledge
4. **Convention over configuration** — define an "MCP server image contract" (must use ENTRYPOINT, must accept `--port $PORT`, must run as non-root)

No upstream issue exists yet for this — [kubeflow/model-registry#1139](https://github.com/kubeflow/model-registry/issues/1139) is the overarching MCP catalog feature request but doesn't discuss `runtimeMetadata` schema gaps.

### 3. Operator → Gateway registration gap (resolved in Phase 11)

Once the operator deploys an MCP server (Deployment + Service), there was no automated path to register it with the gateway (HTTPRoute + MCPServerRegistration). This was resolved by integrating the gateway controller from [openshift/mcp-lifecycle-operator#3](https://github.com/openshift/mcp-lifecycle-operator/pull/3) into the downstream operator. The annotation `mcp.x-k8s.io/gateway-ref` on the MCPServer CR triggers automatic creation of both gateway resources.

### 4. Semantic gap in `arguments`

mcp-launcher's `PackageArguments` are meant to be appended to the container command. The operator's `config.arguments` replaces CMD entirely. These are fundamentally different semantics — an integrator bridging the two must understand both conventions.

### 5. Catalog API N+1 queries for tools

The list endpoint returns `toolCount` but not the tools themselves. Tools require a separate per-server call. A consumer building a UI must make N+1 API calls.

### 6. Operator gateway controller overwrites MCPServerRegistration spec

The gateway controller's `reconcileMCPServerRegistration` (`mcpserver_gateway_controller.go:208`) replaces the entire `spec` map on every reconciliation:

```go
reg.Object["spec"] = map[string]any{
    "toolPrefix": toolPrefix,
    "targetRef":  map[string]any{...},
}
```

This overwrites any fields added out-of-band — including `credentialRef`, which the broker needs to authenticate to backends that require credentials for tool discovery (`tools/list`). The GitHub MCP server, for example, requires a PAT for all requests including tool listing. Without `credentialRef`, the broker gets a 401 and marks the server unhealthy.

**Why this matters**: The gateway's auth architecture has an intentional separation between broker-level credentials (static, for tool discovery) and per-user credentials (dynamic, via Vault/AuthPolicy for tool calls). The broker connects directly to backends — it doesn't go through Envoy, so AuthPolicy/Vault token exchange never fires. The broker's only credential mechanism is `credentialRef` pointing to a Kubernetes Secret. The operator's gateway controller doesn't support setting this, and actively prevents it by overwriting the spec.

**Root cause**: The controller uses `CreateOrUpdate` with a mutate function that sets `spec` as a flat map literal. Any fields not explicitly included are dropped. The fix would be to either preserve existing fields during reconciliation, or support a `credentialRef` annotation on the MCPServer CR (similar to `mcp.x-k8s.io/gateway-tool-prefix`).

### Temporary workarounds implemented

| Friction point | Workaround |
|----------------|------------|
| Missing command/args in catalog metadata | Added editable YAML mode to launcher UI — user manually adds `config.arguments` before deploying |
| Missing security context in catalog metadata | User manually adds `runtime.security.securityContext.runAsNonRoot: false` in YAML editor |
| Stale CRD on cluster (flat → nested schema) | Re-ran `make install` from operator repo; rebuilt and redeployed operator binary |
| Stale leader lease after operator restart | Manually deleted lease: `kubectl delete lease bed7462b.x-k8s.io` |
| N+1 API calls for tools | Launcher makes per-server `/tools` call in a loop during `List()` |
| Gateway code in launcher | Removed entirely — launcher only bridges catalog → operator; gateway registration handled by operator's gateway controller via annotation |
| Operator overwrites `credentialRef` | setup.sh patches MCPServerRegistration after creation, but operator reconciler reverts it. Must scale down operator or patch repeatedly. Proper fix requires operator change. |

---

## Phase 12: Replacing mini-oidc with Keycloak

> **Goal**: Replace the custom mini-oidc provider with Keycloak as the sole OIDC identity provider, establishing a production-grade auth foundation while keeping the deployment minimal.

### Motivation

mini-oidc was built from scratch to learn how OIDC works — an explicitly educational decision that paid off (Phase 4). But for the next stage of the experiment (multi-tenancy, role-based tool access, token exchange), a real identity provider with user management, groups, client roles, and standards-compliant flows is needed. Keycloak is the upstream choice for the mcp-gateway project.

### Evaluating mcp-gateway's existing Keycloak setup

> **User instruction**: *"Wait before you fly through the keycloak installation. I would like to better understand what's getting applied for keycloak."*

The mcp-gateway repo already has `make keycloak-install` with full automation. Before using it, we examined every resource it creates:

1. **Realm import** — a ConfigMap containing a Keycloak realm JSON with pre-configured clients (one per test server), per-tool roles, user groups, and a test user. This was too broad — it bundled test infrastructure we don't need.

2. **Deployment** — Keycloak 26.3 in dev mode with `--import-realm` to auto-load the realm on startup.

3. **Gateway patch** — adds an HTTPS listener on port 8002 with TLS termination via cert-manager.

4. **HTTPRoute** — routes traffic with an OAuth discovery path rewrite. Keycloak uses `/realms/mcp/.well-known/oauth-authorization-server` but the OAuth spec expects `/.well-known/oauth-authorization-server/realms/mcp`. The HTTPRoute rewrites the path. This is a Keycloak-specific quirk — its multi-realm URL structure predates RFC 8414 standardization.

5. **TLSPolicy + ClusterIssuer** — Kuadrant TLSPolicy with a self-signed cert-manager ClusterIssuer.

6. **Post-install steps** — extracts the TLS CA cert, bind-mounts it into the Kind node, configures the Kubernetes API server to trust Keycloak as an OIDC issuer, and restarts the API server. This was specific to the kubernetes-mcp-server use case.

### Decision: minimal Keycloak, no TLS

> **User question**: *"These make targets are all likely too broad for our use case right now. Is the Kuadrant CRD all that is needed to get Keycloak up?"*

This led to the realization that TLS (via TLSPolicy) required both the full Kuadrant operator *and* cert-manager — a significant dependency chain just for HTTPS on a Kind cluster.

> **User instruction**: *"Let's do that [skip TLS]. Though I do plan to ramp up to have TLS soon."*

Rather than using `make keycloak-install` wholesale, we stripped it down:

- **Skipped TLS entirely** — the TLSPolicy requires Kuadrant operator + cert-manager, neither of which were installed yet. For a Kind experiment, HTTP is sufficient. TLS will be layered in when Kuadrant is introduced for AuthPolicy.
- **Stripped the realm** to bare minimum. The pre-built realm included 5 clients (one per test server), per-tool roles, groups, and a test user. The user questioned this:

> *"Those 5 clients you mentioned earlier — are they just examples or do they really get created out of the box? I imagine we would only want to create clients as and when required."*

> *"Let's not even create any users yet. So what is the final list of resources to be created?"*

The final realm contains only the `mcp-gateway` confidential client (with `serviceAccountsEnabled` for client_credentials grant), plus the `groups` and `roles` client scopes. No users, no server-specific clients, no roles, no groups. These will be added as needed.
- **Skipped API server OIDC config** — not needed for gateway authentication, only for the kubernetes-mcp-server integration.
- **Used HTTP gateway listener** on port 8002 instead of HTTPS, avoiding the cert-manager dependency chain.

### Integration issues encountered

#### 1. AuthorizationPolicy blocks Keycloak traffic

> **User question**: *"Why does Keycloak need a dedicated gateway listener but mini-oidc didn't need one?"*

Because mini-oidc bypassed the gateway entirely via a direct NodePort, while Keycloak routes through the gateway for TLS termination (later) and the OAuth discovery path rewrite. This meant the existing Istio `AuthorizationPolicy` — an ALLOW rule requiring a valid JWT on all gateway traffic — now blocked Keycloak on port 8002. You can't require a token to reach the service that issues tokens.

**Fix**: Changed from ALLOW to DENY semantics:

```yaml
# Before (ALLOW): only allow requests WITH a JWT — blocks everything else
action: ALLOW
rules:
  - from:
      - source:
          requestPrincipals: ["*"]

# After (DENY): deny requests WITHOUT a JWT, but only on port 8080
action: DENY
rules:
  - from:
      - source:
          notRequestPrincipals: ["*"]
    to:
      - operation:
          ports: ["8080"]
```

The ALLOW approach is a whitelist — anything not explicitly allowed is denied, including new listeners. The DENY approach is a blacklist — only unauthenticated MCP traffic (port 8080) is blocked, leaving other listeners (port 8002 for Keycloak) open by default. The net effect on MCP traffic is identical.

**Learning**: When adding new gateway listeners, existing auth policies may need restructuring. An ALLOW policy that was fine for a single-listener gateway becomes a trap when you add a second listener. This is the kind of issue that would also surface in production when adding any new service behind the gateway.

#### 2. Keycloak client_credentials grant requires serviceAccountsEnabled

The initial realm had `directAccessGrantsEnabled: true` on the `mcp-gateway` client, which enables username/password token requests. But `client_credentials` grant (no user, just the client itself) requires `serviceAccountsEnabled: true` — a separate Keycloak setting. The token endpoint returned `"unauthorized_client"` until this was added.

**Fix**: Added `"serviceAccountsEnabled": true` to the client config and redeployed Keycloak (realm is imported on startup, so a pod restart was needed).

#### 3. Istio RequestAuthentication issuer mismatch

Keycloak tokens use issuer `http://keycloak.127-0-0-1.sslip.io:8002/realms/mcp`. The existing `RequestAuthentication` pointed to mini-oidc's issuer. Istio rejected Keycloak tokens with "Jwt issuer is not configured."

**Fix**: Updated the `jwtRules` to point to Keycloak's issuer and JWKS endpoint (using the in-cluster URL for JWKS: `http://keycloak.keycloak.svc.cluster.local/realms/mcp/protocol/openid-connect/certs`).

### Resources created

| Resource | Namespace | Purpose |
|----------|-----------|---------|
| Namespace `keycloak` | — | Isolation for Keycloak resources |
| ConfigMap `realm-import` | keycloak | Minimal realm JSON (mcp-gateway client + scopes) |
| Deployment `keycloak` | keycloak | Keycloak 26.3 dev mode, HTTP only |
| Service `keycloak` | keycloak | ClusterIP :80 → :8080 |
| Gateway patch | gateway-system | HTTP listener on port 8002 for `keycloak.127-0-0-1.sslip.io` |
| HTTPRoute `keycloak-route` | keycloak | Routes to Keycloak with OAuth discovery path rewrite |

### Resources removed

> **User instruction**: *"Let's take down mini-oidc and whatever resources are associated with it. We don't need to run multiple OIDC providers."*

| Resource | Reason |
|----------|--------|
| mini-oidc Deployment + Services | Replaced by Keycloak |
| mini-oidc YAML from experiment repo | No longer part of the setup |

### Resources modified

| Resource | Change |
|----------|--------|
| `RequestAuthentication` | Removed mini-oidc issuer, added Keycloak issuer + JWKS |
| `AuthorizationPolicy` | Changed from ALLOW to DENY, scoped to port 8080 only |

### Verification (client_credentials)

```bash
# Get token from Keycloak
KC_TOKEN=$(curl -s -X POST http://keycloak.127-0-0-1.sslip.io:8002/realms/mcp/protocol/openid-connect/token \
  -d 'grant_type=client_credentials&client_id=mcp-gateway&client_secret=secret' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Initialize MCP session
SESSION=$(curl -si -H "Authorization: Bearer $KC_TOKEN" ... initialize ... | grep mcp-session-id)

# List tools — returns all 5 test-server1 tools
curl -H "Authorization: Bearer $KC_TOKEN" -H "Mcp-Session-Id: $SESSION" ... tools/list
# → test_server1_add_tool, test_server1_greet, test_server1_headers, test_server1_slow, test_server1_time

# Unauthenticated request — denied
curl http://mcp.127-0-0-1.sslip.io:8001/mcp
# → RBAC: access denied
```

### Adding users, groups, and identity-based access

> **User instruction**: *"Let's add a couple users and groups now. I want to get to a place where I have tested everything I can with just Keycloak."*

The realm was updated with:

- **Users**: alice (developers), bob (ops), carol (developers + ops). Each with password = username, `emailVerified: true`, `firstName`/`lastName` set (Keycloak 26 requires these even when profile says optional — without them, the password grant returns "Account is not fully set up").
- **Groups**: `developers` and `ops` — these map to the group claims in access tokens when the `groups` scope is requested.
- **`basic` client scope** with `sub` mapper — this was missing from the stripped realm and turned out to be critical. Without the `sub` claim, Istio cannot construct a request principal (`iss/sub`), and the DENY AuthorizationPolicy fires because `notRequestPrincipals: ["*"]` matches when there's no principal.
- **`mcp-inspector` public client** — a separate OAuth client for browser-based tools, configured with `standardFlowEnabled: true`, PKCE (S256), and redirect URIs for localhost:6274. Deliberately kept separate from the `mcp-gateway` confidential client to maintain proper OAuth client separation (public clients for browser flows, confidential clients for server-to-server).

> **User instruction**: *"One thing we need to be cognizant of is what changes are we making just to get stuff working right now vs which ones are taking us closer to our goal of getting a robust system in place."*

This prompted an explicit assessment of each change's durability. The Keycloak configuration (realm, clients, users, groups, scopes) is all durable — Kuadrant consumes Keycloak as an OIDC provider and doesn't replace it. The Istio auth resources (RequestAuthentication, EnvoyFilter, AuthorizationPolicy) are temporary workarounds that will be replaced by Kuadrant AuthPolicy.

#### AuthorizationPolicy removal

The DENY AuthorizationPolicy was deleted from the cluster. Istio's RBAC filter runs *before* the Lua EnvoyFilter in the filter chain, so unauthenticated requests got a bare `403` from RBAC before the Lua filter could return a proper `401 + WWW-Authenticate` header. Since the `401` response is needed for OAuth-compliant clients to discover the authorization flow, the AuthorizationPolicy was removed, leaving enforcement to the Lua filter + RequestAuthentication. The file remains in the repo for reference but is not applied.

This is acknowledged as a temporary workaround — in production, Kuadrant's AuthPolicy handles both enforcement and proper 401 responses.

#### JWKS caching issue (istiod)

After restarting the Keycloak pod (to pick up realm changes), all authenticated requests failed with "Jwks doesn't have key to match kid or alg from Jwt." Investigation revealed that **istiod converts JWKS URIs to inline `local_jwks`** — it fetches the JWKS once, embeds the keys directly in the Envoy config, and does not refresh when the upstream keys change. The gateway pod had the old kid baked into its config even after a pod restart, because istiod was still serving the cached keys.

**Fix**: Restart istiod, then restart the gateway pod. The new istiod fetches fresh JWKS from Keycloak, embeds the updated keys, and pushes them to the gateway's Envoy.

**Learning**: In production, OIDC providers persist signing keys across restarts (Keycloak does this with a persistent database). In dev mode with ephemeral storage, every pod restart generates new keys. This is a dev-mode-only issue, but it's worth knowing that istiod's JWKS caching is aggressive and doesn't honor the `jwksUri` for periodic refresh — it's a one-shot fetch that becomes `local_jwks`.

#### Protected resource metadata (`OAUTH_AUTHORIZATION_SERVERS`)

The `mcp-gateway` broker serves `/.well-known/oauth-protected-resource` with the `authorization_servers` field populated from the `OAUTH_AUTHORIZATION_SERVERS` env var. This was set on the `mcp-gateway` deployment in `mcp-system` namespace. Initially the value was set to the `.well-known` URL (`http://keycloak.127-0-0-1.sslip.io:8002/.well-known/oauth-authorization-server/realms/mcp`) but per RFC 9728, it should be the **issuer identifier** (`http://keycloak.127-0-0-1.sslip.io:8002/realms/mcp`). OAuth clients construct the metadata URL from the issuer themselves.

### Verification (user tokens with group claims)

```bash
# Alice authenticates — token carries groups: ["developers"]
TOKEN=$(curl -s -X POST http://keycloak.127-0-0-1.sslip.io:8002/realms/mcp/protocol/openid-connect/token \
  -d 'grant_type=password&client_id=mcp-gateway&client_secret=secret&username=alice&password=alice&scope=openid groups' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Full MCP flow: initialize → tools/list
curl -H "Authorization: Bearer $TOKEN" ... initialize ...  # → 200, Mcp-Session-Id returned
curl -H "Authorization: Bearer $TOKEN" -H "Mcp-Session-Id: $SESSION" ... tools/list
# → all 5 test_server1 tools returned
```

### MCP Inspector (browser-based OAuth)

> **User question**: *"Can I verify what we have now through the MCP Inspector?"*

MCP Inspector runs a browser-based OAuth 2.1 authorization code + PKCE flow. The setup was correct (protected resource metadata pointing to Keycloak, `mcp-inspector` public client with PKCE, redirect URIs configured), but Inspector's browser-side OAuth discovery failed: it fetched the `authorization_servers` issuer from the protected resource metadata, then tried to discover Keycloak's OAuth AS metadata, but the metadata fetch failed silently. Inspector fell back to constructing `/authorize` on the MCP gateway host, which returned 404.

> **User question**: *"Is this an issue that is worth spending time on? Or is it something very specific to the inspector that wouldn't really matter when the client is something else?"*

This is Inspector-specific. The auth setup is fully functional — verified end-to-end with both client_credentials and user password grants via curl. Production MCP clients do OAuth discovery server-side where browser CORS restrictions don't apply. The Inspector's browser-based implementation has limitations with complex auth setups involving path-based OAuth issuers (Keycloak's `/realms/mcp` structure).

### Interactive MCP client with device authorization grant

> **User instruction**: *"I am open to switching to a better MCP client. But I do want to retain the ability to test things out myself one way or another."*

Rather than debugging the Inspector's browser OAuth, we built an interactive shell script (`scripts/mcp-client.sh`) using the OAuth 2.0 Device Authorization Grant (RFC 8628) — the same flow used by `gh auth login`, `gcloud auth login`, and `az login`. This is the production-standard pattern for CLI tools that need user authentication.

> **User instruction**: *"If there are cheap opportunities to make something closer to production without much extra effort let's take it."*

A new `mcp-cli` public Keycloak client was added with `oauth2.device.authorization.grant.enabled: true`. The script:

1. Requests a device code from Keycloak
2. Opens the verification URL in the browser — user logs in as alice/bob/carol
3. Polls the token endpoint until login completes
4. Shows the authenticated identity and group memberships
5. Initializes an MCP session through the gateway
6. Drops into a REPL for tool calls

```
$ ./scripts/mcp-client.sh
==========================================
  Open this URL in your browser:
  http://keycloak.../realms/mcp/device?user_code=ABCD-EFGH
==========================================
Waiting for you to log in...
Authenticated as: alice (groups: developers)
Session established.

Available tools:
----------------
  test_server1_greet(name) — say hi
  test_server1_time() — get current time
  ...

mcp> test_server1_greet name=luffy
mcp> /login          # switch to a different user
mcp> /whoami         # show current identity
mcp> /tools          # list available tools
```

The `/login` command performs a proper Keycloak logout (back-channel token revocation + front-channel browser cookie clearing via `id_token_hint`) before starting a fresh device flow, allowing mid-session user switching.

This validates the complete production-grade auth flow: device authorization grant → Keycloak login → JWT with group claims → authenticated MCP tool calls through the gateway. The only non-production element is HTTP instead of TLS.

---

## Phase 13: Kuadrant AuthPolicy — From Binary Auth to Per-Tool Authorization

> **Goal**: Replace the three Istio auth workarounds (RequestAuthentication + AuthorizationPolicy + Lua EnvoyFilter) with Kuadrant's AuthPolicy, then push authorization granularity as far as possible.

### Installing Kuadrant

> **User instruction**: *"Stick to the minimum as always!"*

Installed via Helm into `kuadrant-system` namespace, then created the Kuadrant CR from mcp-gateway's config. This brought up Authorino (auth engine), its operator, Limitador (rate limiting — not yet used), and a DNS operator.

### AuthPolicy replaces three Istio workarounds

A single AuthPolicy replaced RequestAuthentication + AuthorizationPolicy + Lua EnvoyFilter:

```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: mcp-auth-policy
  namespace: gateway-system
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: mcp-gateway
    sectionName: mcp
  defaults:
    when:
      - predicate: "!request.path.contains('/.well-known')"
    rules:
      authentication:
        "keycloak":
          jwt:
            issuerUrl: http://keycloak.127-0-0-1.sslip.io:8002/realms/mcp
    response:
      unauthenticated:
        headers:
          "WWW-Authenticate":
            value: >-
              Bearer resource_metadata="http://mcp.127-0-0-1.sslip.io:8001/.well-known/oauth-protected-resource"
        body:
          value: |
            {"error":"Unauthorized","message":"Authentication required."}
```

Key points:
- `sectionName: mcp` targets only the MCP listener, leaving Keycloak's port 8002 unaffected
- `defaults.when` excludes `.well-known` paths from auth entirely (must be at `defaults` level, not inside `rules`)
- Custom `unauthenticated` response returns proper 401 + `WWW-Authenticate` — no more Lua hacks

### CoreDNS fix for in-cluster Keycloak resolution

Authorino couldn't reach Keycloak because `keycloak.127-0-0-1.sslip.io` resolved to `127.0.0.1` inside pods. Fixed by patching CoreDNS with a hosts plugin mapping to the gateway's LoadBalancer IP (`10.89.0.0`). This is cleaner than mcp-gateway's `/etc/hosts` node patching approach — works cluster-wide for all pods.

### Discovering the filter chain order

The initial assumption was that Authorino's auth check ran before the Router's body parsing, which would make per-server and per-tool authorization impossible at the gateway layer (all requests would look identical to Authorino). This turned out to be wrong.

> **User (from a separate session)**: *"ext_proc is set to run BEFORE ext_authz, so the request body parsing will already be done by the router/broker and a header set before it gets to authorino"*

The Envoy config dump confirmed this:

```
1. envoy.filters.http.ext_proc                               ← Router runs FIRST
2. extensions.istio.io/wasmplugin/kuadrant-mcp-gateway        ← Kuadrant Wasm auth runs SECOND
3. ... other filters ...
9. envoy.filters.http.router                                  ← routing decision
```

By the time the auth check happens, the Router has already parsed the JSON-RPC body and set headers visible to Authorino:

| Header | Value | Example |
|--------|-------|---------|
| `:authority` | Server hostname (rewritten) | `test-server1.mcp.local` |
| `x-mcp-toolname` | Tool name (prefix stripped) | `greet` |
| `x-mcp-servername` | Server namespace/name | `mcp-test/test-server1` |
| `x-mcp-method` | JSON-RPC method | `tools/call` |

**Note**: Kuadrant implements auth via a Wasm plugin, not a raw ext_authz HTTP filter. This is why the Kuadrant EnvoyFilter only adds a cluster definition — the Wasm plugin was not visible in EnvoyFilter resources, only in the Envoy config dump.

### Server-level authorization

With the filter chain order confirmed, per-HTTPRoute AuthPolicies work. A second test server was deployed (same image, different name), and per-server AuthPolicies were created:

```yaml
# server1-auth-policy targets HTTPRoute test-server1
authorization:
  "require-developers":
    patternMatching:
      patterns:
        - predicate: "auth.identity.groups.exists(g, g == 'developers')"
```

Results: Alice (developers) could call server1 tools, Bob (ops) could call server2 tools, Carol (both groups) could call both. Denied requests returned 403 from Authorino.

### Tool-level authorization

The `x-mcp-toolname` header enables per-tool restrictions. Adding a tool check to the authorization rules:

```yaml
authorization:
  "allowed-tools":
    patternMatching:
      patterns:
        - predicate: "request.headers['x-mcp-toolname'] in ['greet', 'time', 'add_tool']"
```

**Note**: The header name is `x-mcp-toolname` (no hyphens between words), not `x-mcp-tool-name`. This was discovered via Authorino debug logs — the initial assumption about the header name caused "no such key" errors.

### Cross-server per-group per-tool authorization

> **User instruction**: *"Can you also cover the case where Alice has access to tool-a, tool-b from server1 and tool-c from server2 and Bob has access to tool-b from server1 and tool-d from server2?"*

This required combining group and tool checks in a single CEL predicate using OR logic:

```yaml
authorization:
  "group-tool-access":
    patternMatching:
      patterns:
        - predicate: >-
            (auth.identity.groups.exists(g, g == 'developers') && request.headers['x-mcp-toolname'] in ['greet', 'time'])
            || (auth.identity.groups.exists(g, g == 'ops') && request.headers['x-mcp-toolname'] in ['time', 'headers'])
```

Full test matrix — 30 test cases, all passing:

| User | Group | Server1 allowed | Server1 denied | Server2 allowed | Server2 denied |
|------|-------|----------------|----------------|-----------------|----------------|
| Alice | developers | greet, time | headers, slow, add_tool | slow | greet, headers, add_tool |
| Bob | ops | time, headers | greet, slow, add_tool | headers, add_tool | greet, time, slow |
| Carol | both | greet, time, headers | slow, add_tool | slow, headers, add_tool | greet, time |

This is production-grade per-user authorization at the gateway level with:
- **No code changes to mcp-gateway** — purely declarative AuthPolicy CRs
- **No duplicated JSON-RPC parsing** — the Router sets headers, Authorino reads them
- **CEL predicates** combining group membership with tool identity

### Remaining gap: `tools/list` filtering

For `tools/call`, authorization is fully enforced at the gateway. But `tools/list` returns all tools to all users regardless of permissions. The broker aggregates tools from all servers and returns the full list — the gateway cannot selectively filter items within a JSON-RPC response body.

This means Alice sees all 10 tools in `tools/list` even though she can only call 3 of them. Unauthorized calls are denied with 403, so it's not a security issue, but it's a confusing UX. Fixing this requires application-level changes to the broker to filter the tool list based on JWT claims.

### What Istio still handles vs what Kuadrant now handles

- **Istio**: Gateway API controller (istiod programs Envoy via xDS), traffic routing (HTTPRoutes → Envoy virtual hosts), ext_proc injection (Router filter)
- **Kuadrant**: Authentication (JWT validation via Authorino), authorization (per-group per-tool ACLs), custom 401/403 responses, `.well-known` path exclusions

---

## Phase 14: TLS Termination at the Gateway

> **User instruction**: *"i think we can do TLS in phase 14, token exchange in phase 15 and then probably cut another branch."*

> **User instruction**: *"keep HTTP for now, and separate ports"*

The goal was to add TLS termination at the Envoy gateway using cert-manager and Kuadrant's TLSPolicy, while keeping existing HTTP endpoints intact. HTTPS runs on separate ports (8443 for MCP, 8445 for Keycloak) so nothing breaks for existing workflows.

### cert-manager installation order matters

The first attempt installed Kuadrant before cert-manager. TLSPolicy was created but sat in `MissingDependency` status:

```
message: "[Cert Manager] is not installed"
```

Kuadrant's TLSPolicy controller checks for cert-manager at startup. If cert-manager isn't present, the controller never initializes — even if cert-manager is installed later. The fix was to install cert-manager as Phase 5 in setup.sh (before Kuadrant in Phase 11), and add a fallback that restarts the Kuadrant operator if TLSPolicy isn't enforced within 30 seconds.

### Certificate chain

Three resources create the CA chain:

1. **ClusterIssuer `selfsigned-issuer`** — self-signed issuer (bootstrap)
2. **Certificate `mcp-ca-cert`** — CA certificate (`isCA: true`), signed by the self-signed issuer, stored in `mcp-ca-secret`
3. **ClusterIssuer `mcp-ca-issuer`** — references `mcp-ca-secret`, signs all downstream certificates

This is a standard cert-manager pattern: bootstrap a self-signed CA, then use it to sign everything else.

### TLSPolicy auto-creates certificates

A single TLSPolicy targeting the Gateway:

```yaml
apiVersion: kuadrant.io/v1
kind: TLSPolicy
metadata:
  name: mcp-gateway-tls
  namespace: gateway-system
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: mcp-gateway
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: mcp-ca-issuer
```

Kuadrant scans the Gateway for HTTPS listeners and auto-creates a Certificate CR for each one. The naming convention is deterministic: `{gateway-name}-{listener-name}` for the Certificate, `{gateway-name}-{listener-name}-tls` for the Secret. The Gateway's `certificateRefs` must match these auto-generated secret names.

### Gateway HTTPS listeners

Two HTTPS listeners were added to the Gateway:

- `mcp-https` on port 8443 — TLS-terminated MCP gateway
- `keycloak-https` on port 8445 — TLS-terminated Keycloak

Both use `tls.mode: Terminate` — TLS is terminated at Envoy, and traffic continues as plain HTTP to backends. No backend changes needed.

The Keycloak HTTPS listener was added via a JSON patch (`gateway-patch-tls.json`) applied by setup.sh, keeping the base gateway.yaml clean. A separate HTTPRoute (`httproute-tls.yaml`) routes HTTPS Keycloak traffic, including the OAuth discovery path rewrite.

### Kind cluster and NodePort updates

Kind cluster config gained two new port mappings:
- `hostPort: 8443` → `containerPort: 30443` (MCP HTTPS)
- `hostPort: 8445` → `containerPort: 30445` (Keycloak HTTPS)

The NodePort service added corresponding entries routing 30443→8443 and 30445→8445.

### CA certificate extraction

Setup.sh extracts the CA certificate from the `mcp-ca-secret` for client use:

```bash
kubectl get secret mcp-ca-secret -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/mcp-ca.crt
```

Clients use this with `curl --cacert /tmp/mcp-ca.crt` to verify the self-signed certificate chain.

### User experience

> **User instruction**: *"so from a user experience perspective there is no difference other than the fact that you are hitting an https endpoint instead of http?"*

Correct. From the client's perspective, the only change is:
- Use `https://` URLs with port 8443/8445 instead of `http://` with port 8001/8002
- Pass `--cacert /tmp/mcp-ca.crt` to curl (or equivalent CA trust in other clients)

All JSON-RPC payloads, headers, session management, and authorization behavior are identical. TLS is transparent to the MCP protocol layer.

### Test coverage

The test pipeline was extended with Phase 7 (TLS), adding 8 checks:
1. cert-manager is running
2. CA certificate is Ready
3. TLSPolicy exists
4. Gateway has HTTPS listener
5. CA cert extracted to `/tmp/mcp-ca.crt`
6. Keycloak HTTPS token issuance
7. MCP session via HTTPS
8. Tools listed via HTTPS

Total: 55/55 tests passing on a clean cluster (setup.sh → test-pipeline.sh).

---

## Phase 15: Per-User Credential Exchange via Vault

> **User instruction**: *"i think we can do TLS in phase 14, token exchange in phase 15 and then probably cut another branch."*

The goal was to enable per-user credential injection at the gateway: when a user calls a tool on a credentialed MCP server (e.g., GitHub), the gateway swaps their Keycloak JWT for their personal API token stored in Vault, then forwards the request with the upstream credential. No application code changes, no per-user server deployments.

### The credential exchange flow

The AuthPolicy implements a three-step metadata evaluator chain:

1. **Vault JWT login** (priority 0) — takes the user's Keycloak JWT from the `Authorization` header, sends it to `http://vault:8200/v1/auth/jwt/login` with `role: authorino`. Vault validates the JWT against Keycloak's JWKS, checks the `aud: mcp-gateway` claim, and returns a Vault client token scoped to the `authorino` policy.

2. **Vault secret read** (priority 1, conditional) — uses the Vault client token from step 1 to read `secret/data/mcp-gateway/{sub}`, where `{sub}` is the user's Keycloak subject ID. Returns the stored credential (e.g., `github_pat`).

3. **Response injection** — sets `Authorization: Bearer {github_pat}` and `x-mcp-api-key: {github_pat}` headers on the request before it reaches the MCP server.

An authorization rule (`found-vault-secret`) verifies that the Vault secret was successfully retrieved and contains the expected field. If the secret doesn't exist (user hasn't stored a PAT), the request is denied with a 403 explaining how to store one.

### Vault setup

Vault runs in dev mode (single-pod, in-memory storage, root token: `root`):

- **JWT auth method** — backed by Keycloak's JWKS endpoint (`http://keycloak.keycloak.svc.cluster.local/realms/mcp/protocol/openid-connect/certs`)
- **Role `authorino`** — bound audience: `mcp-gateway`, user claim: `sub`, token TTL: 1h
- **Policy `authorino`** — read access to `secret/data/mcp-gateway/*`
- **Secret path convention** — `secret/mcp-gateway/{keycloak-sub}` with field `github_pat`

Vault login responses are cached by Authorino (TTL: 300s, key: `auth.identity.sub`), so the JWT login doesn't happen on every request.

### GitHub MCP server deployment

The GitHub MCP server (`ghcr.io/github/github-mcp-server:latest`) runs in HTTP mode on port 8082 with toolsets: `repos,issues,pull_requests,users` (23 tools). Unlike many MCP servers that only read credentials from environment variables, the GitHub server accepts `Authorization: Bearer` headers in HTTP mode — this is what makes per-user credential injection possible at the gateway.

The MCPServer CR uses the `mcp.x-k8s.io/gateway-credential-ref` annotation to specify the broker credential secret. This required adding annotation support to the operator's gateway controller, because the reconciler previously replaced the entire MCPServerRegistration `spec` map, dropping any externally-added fields including `credentialRef`.

### Operator credential-ref support

The operator's gateway controller was updated (branch: `gateway-credential-ref`, image: `quay.io/jrao/mcp-lifecycle-operator:gateway-credential-ref`) to propagate credential references from annotations:

```yaml
metadata:
  annotations:
    mcp.x-k8s.io/gateway-ref: gateway-system/mcp-gateway
    mcp.x-k8s.io/gateway-credential-ref: github-broker-credential
    mcp.x-k8s.io/gateway-credential-key: token
```

The broker uses this static credential (`github-broker-credential` Secret) for tool discovery at startup. Per-user credentials flow through the AuthPolicy Vault exchange at request time. This is an intentional split: the broker connects directly to backends (not through Envoy), so AuthPolicy never fires for discovery. The router hairpins through Envoy, triggering the per-user credential exchange.

### Keycloak scope issues

Two Keycloak configuration issues surfaced:

1. **`mcp-gateway-audience` scope not applied to client** — the realm-import defined the scope and listed it in `defaultClientScopes`, but Keycloak's `--import-realm` didn't apply it to the `mcp-gateway` client. Vault JWT auth requires `aud: mcp-gateway`, so tokens were rejected. Fixed via admin API.

2. **Moving a scope from optional to default requires two API calls** — calling `PUT .../default-client-scopes/{id}` doesn't remove the scope from optional. Must `DELETE .../optional-client-scopes/{id}` first, then `PUT .../default-client-scopes/{id}`. This was also updated in the realm-import.yaml to prevent recurrence on fresh clusters.

### Credential secret label mismatch

The credential secret initially used `mcp.kuadrant.io/credential: "true"` but the mcp-gateway controller validates `mcp.kuadrant.io/secret: "true"`. The label name is unintuitive and even the project's own CLAUDE.md documents it incorrectly. Without it, MCPServerRegistration status reports a clear error but the secret appears correct — only the label is missing.

### mcp-client.sh fix

The interactive client had a JSONDecode error that was traced to two bugs:

1. **Broken default params** — `mcp_call`'s default params was `\{\}` (literal backslash-brace, invalid JSON) instead of `{}`. When called without a second argument (e.g., `tools/list`), the payload python script crashed, producing an empty curl request.

2. **`echo` vs `printf` for zsh** — zsh's builtin `echo` interprets `\n` as newlines by default. The GitHub tool descriptions contain 16 occurrences of `\n` in JSON strings. After `mcp_call` pretty-printed the response, `echo "$tools_raw"` in zsh converted these to actual newlines, producing invalid JSON. Fixed all `echo "$var"` calls to `printf '%s\n' "$var"` for cross-shell portability.

### Test coverage

The test pipeline was extended with Phase 8 (Vault credential exchange), adding 8 checks:
1. Vault pod is Running
2. Vault JWT auth method enabled
3. Vault JWT login with Keycloak token succeeds
4. Vault returns stored credential via JWT-derived token (round-trip with dummy PAT)
5. GitHub MCPServerRegistration is Ready
6. GitHub server has tools registered (23 tools)
7. AuthPolicy `github-auth-policy` exists
8. Credential secret has correct label

Total: 63/63 tests passing.

### Env-var credential limitation

> **Observation:** MCP servers that only read credentials from environment variables (e.g., Slack MCP server) cannot use gateway-level credential injection. The gateway can inject credentials into HTTP headers at request time, but it cannot modify a running container's environment variables per-request. These servers require a per-user deployment model — one pod per user, each with its own credentials in env vars. The GitHub server avoids this by accepting `Authorization: Bearer` headers in HTTP mode, making it compatible with the Vault token exchange pattern.

---

## Architecture Summary (as of Phase 15)

This snapshot captures the cluster state after Phase 15 — the full pipeline from catalog discovery through deployment, gateway registration, per-tool authorization with Kuadrant, TLS termination, and per-user credential exchange via Vault.

### Components on the cluster

```
Kind Node (mcp-gateway)
|
+-- cert-manager namespace
|   +-- cert-manager (certificate lifecycle management)
|   +-- ClusterIssuer selfsigned-issuer (bootstrap)
|   +-- Certificate mcp-ca-cert (isCA: true) → Secret mcp-ca-secret
|   +-- ClusterIssuer mcp-ca-issuer (signs downstream certs)
|
+-- catalog-system namespace
|   +-- PostgreSQL StatefulSet + PVC + Secret + Service (catalog metadata backend)
|   +-- Catalog ConfigMap (mcp-catalog-sources: sources.yaml + mcp-servers.yaml)
|   +-- Catalog Deployment + ClusterIP Service (REST API on :8080)
|
+-- gateway-system namespace
|   +-- Envoy pod (mcp-gateway-istio) — L7 proxy, data path
|   +-- NodePort Service (30080→8080, 30089→8002, 30443→8443, 30445→8445)
|   +-- Gateway resource — 4 listeners (mcp, keycloak, mcp-https, keycloak-https)
|   +-- TLSPolicy mcp-gateway-tls — targets Gateway, references mcp-ca-issuer
|   +-- Certificate mcp-gateway-mcp-https → Secret mcp-gateway-mcp-https-tls
|   +-- Certificate mcp-gateway-keycloak-https → Secret mcp-gateway-keycloak-https-tls
|   +-- ReferenceGrant — cross-namespace permissions
|   +-- EnvoyFilter (ext_proc) — injects Router into Envoy
|   +-- EnvoyFilter (kuadrant-auth) — created by Kuadrant (ext_authz cluster)
|   +-- WasmPlugin (kuadrant-mcp-gateway) — created by Kuadrant (auth enforcement)
|   +-- AuthPolicy (mcp-auth-policy) — gateway-level JWT auth + 401 response
|
+-- kuadrant-system namespace
|   +-- Authorino (auth engine, ext_authz gRPC server)
|   +-- Authorino operator
|   +-- Kuadrant operator (translates AuthPolicy/TLSPolicy → Authorino config + certs)
|   +-- Limitador + operator (rate limiting, not yet used)
|   +-- DNS operator (not yet used)
|
+-- keycloak namespace
|   +-- Keycloak 26.3 (OIDC provider, dev mode)
|   +-- ConfigMap (realm-import) — mcp realm with clients, users, groups
|   +-- Service + HTTPRoutes (HTTP + HTTPS, OAuth discovery path rewrite)
|
+-- istio-system namespace
|   +-- istiod — programs Envoy via xDS
|
+-- mcp-system namespace
|   +-- mcp-gateway pod (broker + router + controller)
|   +-- MCPGatewayExtension — attaches to Gateway
|   +-- HTTPRoute (mcp-gateway-route) — routes to broker
|   +-- Secret (config) — upstream server list
|
+-- vault namespace
|   +-- Vault pod (dev mode, in-memory storage, root token: root)
|   +-- JWT auth method (Keycloak JWKS-backed)
|   +-- Role authorino (aud: mcp-gateway, user_claim: sub)
|   +-- Policy authorino (read secret/data/mcp-gateway/*)
|   +-- Per-user secrets at secret/mcp-gateway/{keycloak-sub}
|
+-- mcp-test namespace
|   +-- mcp-launcher pod (catalog UI + deployer)
|   +-- mcp-launcher Service + NodePort (30472 -> host port 8004)
|   +-- mcp-launcher RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding)
|   +-- test-server1 pod + Service + HTTPRoute + MCPServerRegistration
|   +-- test-server2 pod + Service + HTTPRoute + MCPServerRegistration
|   +-- github pod + Service + HTTPRoute + MCPServerRegistration (23 tools)
|   +-- Secret github-broker-credential (broker discovery credential)
|   +-- AuthPolicy (server1-auth-policy) — developers group + tool ACLs
|   +-- AuthPolicy (server2-auth-policy) — ops group + tool ACLs
|   +-- AuthPolicy (github-auth-policy) — Vault token exchange flow
|   +-- MCPServer CRs (with gateway-ref + credential-ref annotations)
|
+-- mcp-lifecycle-operator-system namespace
|   +-- lifecycle operator pod (main reconciler + gateway reconciler)
|
+-- metallb-system namespace
    +-- MetalLB (LoadBalancer IP assignment)
```

### External access

| Port | Maps to | Service |
|------|---------|---------|
| localhost:8001 | nodePort 30080 → Envoy :8080 | MCP Gateway (HTTP) |
| localhost:8002 | nodePort 30089 → Envoy :8002 → Keycloak | OIDC Provider (HTTP) |
| localhost:8443 | nodePort 30443 → Envoy :8443 | MCP Gateway (HTTPS) |
| localhost:8445 | nodePort 30445 → Envoy :8445 → Keycloak | OIDC Provider (HTTPS) |
| localhost:8004 | nodePort 30472 → mcp-launcher :8080 | MCP Launcher UI |

### The catalog → deploy → authorize → exchange → route pipeline (complete)

```
Catalog API (catalog-system)          — "what's available"
  ↓ REST API
MCP Launcher (mcp-test)               — "browse, configure, deploy"
  ↓ creates MCPServer CR (with gateway-ref + credential-ref annotations)
Lifecycle Operator (operator-system)  — "make it run AND make it routable"
  ↓ creates Deployment + Service + HTTPRoute + MCPServerRegistration
Kuadrant AuthPolicy (per-HTTPRoute)   — "who can call which tools"
  ↓ CEL predicates: group membership + tool name
Vault Token Exchange (AuthPolicy)     — "swap user JWT for upstream API credential"
  ↓ Keycloak JWT → Vault JWT login → per-user secret read → header injection
Gateway (gateway-system)              — "route authorized requests to the server"
```

The end-to-end pipeline is now fully automated with per-tool authorization and per-user credential exchange. A user browses the catalog, deploys a server, and the operator handles deployment + gateway registration. AuthPolicies on the auto-created HTTPRoutes enforce per-group, per-tool access control. For credentialed upstream servers, the AuthPolicy's metadata evaluators exchange the user's JWT for their personal API token stored in Vault.

---

## Phase 16-20: Design Scoping — From Single-User Experiment to Multi-Tenant Production

> **User instruction**: *"The motivation behind this entire experiment has been this ticket RHAISTRAT-1149. Read the description and comments carefully to understand the scope of the problem. That should help us narrow down the various cases/scenarios we should explore."*

With Phase 15 complete, the experiment had proven the full pipeline end-to-end for a single gateway, single namespace setup. The next challenge was making it production-representative: multiple teams, namespace isolation, intra-team access control, and credential management at scale. Rather than jumping straight to implementation, this phase was a design discussion that started from the motivating Jira ticket and progressively narrowed scope through architecture analysis and code review.

### Starting from the ticket: RHAISTRAT-1149

[RHAISTRAT-1149](https://redhat.atlassian.net/browse/RHAISTRAT-1149) — "Document Best Practices for Deploying MCP Servers with OpenShift AI" — frames the MCP ecosystem around two personas: **Platform Engineers** who deploy, register, and manage MCP servers, and **AI Engineers** who consume tools via Gen AI Studio without needing Kubernetes expertise. The documentation scope covers the full lifecycle: Catalog → Deployment → Gateway Registration → VirtualMCPServer → Gen AI Studio consumption.

Chris Hambridge's comment (Jan 26, from RHAISTRAT-1084 feature refinement) identified four specific gaps that needed to be addressed:

1. **MCP Gateway Registration flow** — how a platform engineer registers a server and gets the endpoint + header for AI engineers
2. **Creating an MCP Gateway per namespace** — namespace-level isolation of registered MCP servers
3. **VirtualMCPServers as best practice** — 1:1 mapping with tool sets for tool delisting
4. **MCP Server/Tool Revocation** — removing from catalog, identifying deployed versions, scaling down, unregistering from gateway

This narrowed the earlier open-ended multi-tenancy brainstorm (which included multi-cluster, ACM, OPA/Rego, SpiceDB, Redis session stores) to a focused set of scenarios directly tied to the ticket's deliverables.

### Questioning VirtualMCPServers

> **User question**: *"How are VirtualMCPServers set up in the gateway, and is it different from the test-auth-matrix thing we have?"*

Code review of the mcp-gateway broker revealed that VirtualMCPServers operate at a fundamentally different layer than expected. The CRD is minimal — just a list of tool names and an optional description. The broker filters `tools/list` responses when the `X-Mcp-Virtualserver` header is present, but critically, **does not enforce anything on `tools/call`**. Anyone who knows a tool name can call it regardless of virtual server membership. AuthPolicy remains the only security boundary.

This led to a series of questions that progressively uncovered the operational complexity:

> **User**: *"How did we add the per tool auth? Sounds like if we are doing both, we would have to make sure they line up."*

Our existing per-tool AuthPolicy uses CEL predicates on the `x-mcp-toolname` header — a whitelist approach where tools not listed get denied. If VirtualMCPServers show tools that the user's group can't call (or hide tools they can), the UX breaks. The platform engineer must manually keep tool names synchronized across VirtualMCPServer CRs and AuthPolicy predicates.

> **User**: *"Can VirtualMCPServers be tied to groups?"*

No — the CRD has no concept of identity. It's selected by client header, not JWT claims. The correct pattern would be platform-driven: AuthPolicy injects the header based on group membership, so the client is unaware of virtual servers entirely. But this means maintaining two independent CRD systems (mcp-gateway VirtualMCPServer CRs and Kuadrant AuthPolicy response rules) with no automatic bridging.

> **User**: *"How would VirtualMCPServers be discovered by users?"*

No gateway API exists to list available virtual servers. The broker stores them internally with lookup by header only. Users must discover them via `kubectl get mcpvirtualservers` (requires K8s access), out-of-band communication, or Gen AI Studio UI.

> **User**: *"Even assuming VirtualMCPServers are present and the user knows which one they want, how are they currently meant to express that?"*

Via the `X-Mcp-Virtualserver` HTTP header — but standard MCP clients (Claude Desktop, Cursor) cannot inject custom headers. Only Gen AI Studio or custom clients can set it. This means VirtualMCPServer selection is inherently tied to the client implementation.

> **User**: *"So something has to know which VirtualMCPServer a client should be pointing to and add that header then basically, right? Clients choosing VirtualMCPServers while possessing awareness of them makes no sense."*

This reframed VirtualMCPServers entirely: they are a **platform concept, not a client concept**. The client should be completely unaware. The platform injects the header via AuthPolicy response rules based on the user's identity.

### The alignment problem and Auth Phase 2

> **User**: *"Would it be necessary to create a VirtualMCPServer for each actual MCPServer? Seems a bit redundant if the idea of the VirtualMCPServer is to make logical groupings across actual servers."*

This questioned Chris Hambridge's 1:1 recommendation. If the value of VirtualMCPServers is cross-server tool curation for specific roles, then 1:1 just duplicates the registered tool list. The 1:1 pattern only buys tool delisting — and even then, delisting just hides from `tools/list` without blocking `tools/call`.

> **User**: *"Are AuthPolicies typically used in production? I imagine using predicates won't be very sustainable at scale."*

Inline CEL predicates (hardcoding tool names and groups) become unmanageable at scale — 50 tools × 8 groups is unwieldy. This prompted a check: is there already a better solution?

> **User**: *"Could be a good suggestion, but that would require a new controller. Are we 100% sure this isn't an already solved problem?"*

This led to discovering the mcp-gateway project's **Auth Phase 2 design** (`docs/design/auth-phase-2.md`), which already addresses most of the identified gaps:

- Tool permissions move to Keycloak as client roles on resource server clients
- A single generic AuthPolicy uses OPA/Rego + Authorino's wristband feature to sign the user's allowed tools into an `x-authorized-tools` JWT
- The broker validates the signature and filters `tools/list` — no per-tool CEL predicates
- `tools/call` authorization also reads `resource_access` from the JWT
- A future `KeycloakToolRoleMappingPolicy` CRD (described in `VISION.md`) would further abstract the configuration

This was a case where the experimentation process — building with Phase 1 primitives, hitting scalability walls, and reasoning about what a better architecture would look like — independently identified the same problems the gateway team had already designed solutions for.

> **User**: *"What role will VirtualMCPServers play in Phase 2 if Keycloak handles the mapping at a tool level and not at a server level?"*

Almost none. With identity-based filtering via `x-authorized-tools`, VirtualMCPServers become redundant for access control. Their only remaining use case is workflow-specific tool scoping for LLM ergonomics — reducing the tool set an AI agent sees to minimize context confusion. This is a significant finding for RHAISTRAT-1149 documentation: VirtualMCPServers are a key best practice in Phase 1, but their importance diminishes substantially once Phase 2 is adopted.

### Ecosystem deployment topology

> **User**: *"How should the various ecosystem components be deployed on the cluster? Gateway per namespace seems fine. Maybe catalog per namespace too?"*

The discussion settled on a clear topology:

- **Catalog** — 1 per cluster. Discovery should be broad; teams should browse all available servers even if they can't deploy everything. Per-namespace catalogs fragment discovery.
- **Lifecycle Operator** — 1 per cluster. It's a K8s controller watching MCPServer CRs across namespaces. RBAC scoping handles per-namespace access.
- **MCP Gateway** — 1 per namespace (team). This is the isolation boundary.
- **Keycloak + Vault** — shared cluster services.
- **MCP Servers** — deployed in team namespaces. The `mcp.x-k8s.io/gateway-ref` annotation (currently `gateway-system/mcp-gateway`) would point to that namespace's gateway.

### Credential patterns at scale

> **User**: *"How would token exchange work at this scale? Do we just store team-level PATs in secrets and everyone in a specific team/group gets to use those credentials?"*

Three credential patterns emerged:

1. **Shared team credential** — one PAT per service per team in Vault, keyed off group claim. For shared services (GitHub org account, internal APIs).
2. **Per-user Vault credential** — individual PATs keyed off `sub` claim. For identity-bound services (Jira, where permissions are per-user).
3. **OAuth2 token exchange** (Phase 2) — RFC 8693 exchange at the gateway, no stored credentials. For services that trust the same Keycloak realm.

> **User**: *"I'm just wondering in a team setup when would an individual developer's personal token ever be needed? Seems like an anti pattern."*

For most team tooling, team-level credentials are correct. Per-user credentials only make sense for services where permissions are inherently identity-bound (e.g., Jira, where a shared service account would lose attribution and either over- or under-privilege).

> **User**: *"If everything is in Vault do we still need to create Kube secrets for anything?"*

Yes — for broker tool discovery. The broker connects directly to backends (not through Envoy), so AuthPolicy/Vault never fires for `tools/list`. The broker's only credential mechanism is `credentialRef` → K8s Secret. For servers that require auth even for tool discovery, a Secret with a minimal read-only service account credential is still needed alongside Vault.

### The concrete plan

> **User**: *"I have a rough idea for an end state of the cluster over the next couple of phases. We should have 3 namespaces with a gateway in each, single operator, single catalog and Keycloak etc. 2 servers and 3 groups in each namespace. Maybe 15 dummy users distributed arbitrarily."*

This produced a concrete namespace layout: per namespace, 13 CRs (1 MCPGatewayExtension, 2 MCPServerRegistrations, 2 MCPServers, 3 VirtualMCPServers, 3 AuthPolicies, 2 K8s Secrets) plus Vault secrets for team-level and per-user credentials. The full cluster would have 27+ namespace CRs plus shared infrastructure.

> **User**: *"I want to split up Phase 17 to tackle VirtualMCPServers and AuthPolicies first since that is a new concept for this phase."*

The implementation was structured into phases that separate new concepts from full integration:

- **Phase 16**: Namespace-isolated gateways — create `team-a` with its own gateway, deploy 2 servers, verify isolation
- **Phase 17**: VirtualMCPServers + AuthPolicies — 3 groups, 5 users, 3 VirtualMCPServers, per-server AuthPolicies, gateway virtual server header injection, test matrix
- **Phase 18**: Vault credential patterns — team-level and per-user credentials, K8s Secrets for broker discovery, AuthPolicy Vault metadata evaluators
- **Phase 19**: Multi-namespace expansion — replicate to `team-b` and `team-c`, cross-namespace users, single operator + catalog serving all
- **Phase 20**: Rate limiting — RateLimitPolicy with Limitador

---

## Key Learnings

1. **Istio is not a service mesh here** — only istiod is used, purely as a Gateway API controller that programs Envoy. No sidecars, no ambient mode.

2. **ext_proc runs before route matching** — this is what makes the Router powerful (it can steer Envoy's routing decisions) but also means it affects ALL traffic on the port, including non-MCP traffic.

3. **JWKS caching is aggressive** — Istio fetches JWKS once and bakes it inline in Envoy config as `local_jwks`. If the OIDC provider's keys change, istiod and Envoy must be restarted. Production OIDC providers persist keys across restarts.

4. **Istio's 403 vs OAuth's 401** — an intentional design decision (istio/istio#26559). AuthorizationPolicy always returns 403 via Envoy's hardcoded RBAC filter. OAuth clients need 401 + WWW-Authenticate. The mcp-gateway project solves this with Kuadrant's AuthPolicy (ext_authz), which has full response control.

5. **Kubernetes `:latest` tag semantics** — defaults to `imagePullPolicy: Always`, which fails in Kind where images are pre-loaded. Either use specific tags or patch to `IfNotPresent`.

6. **Kubernetes `args` replaces Docker CMD entirely** — not appended. If the Dockerfile has `CMD ["/binary"]`, setting `args: ["--flag"]` in the pod spec means `--flag` is executed as the entrypoint. Must include the binary path in args.

7. **Token exchange is a gateway concern** — the client authenticates to the gateway with one token; the gateway can swap it for a server-specific credential (API key from Vault or scoped token via RFC 8693) before forwarding. The upstream MCP server never sees the client's original token.

8. **Catalog metadata is necessary but not sufficient for deployment** — the model-registry catalog provides discovery (what exists, what tools it has, what port it uses), but lacks the operational metadata needed to actually run an image (command, arguments, security context). This creates a manual gap between "I found a server in the catalog" and "I deployed it successfully."

9. **OCI images are opaque to orchestrators** — without a standardized contract for MCP server images (entrypoint conventions, transport selection, bind address), every new server added to the catalog is a potential deployment failure. The catalog tells you *what exists*, the operator does *what it's told*, but nothing in between encodes *how to run it*.

10. **CRD schema evolution breaks silently** — the operator's MCPServer CRD changed from flat (`spec.image`) to nested (`spec.source.containerImage.ref`) between deployments. The stale CRD on the cluster rejected valid specs with unhelpful validation errors. CRD versioning and migration deserves explicit tooling/process in multi-component ecosystems.

11. **Separation of concerns matters at integration seams** — the user explicitly directed removing gateway awareness from the launcher, keeping each component focused: catalog = discovery, launcher = UI + CR creation, operator = deployment, gateway = routing. The temptation to bundle everything in one tool creates coupling that makes the system harder to reason about and evolve.

12. **Annotations are a clean extension mechanism for downstream features** — the gateway integration uses annotations (`mcp.x-k8s.io/gateway-ref`) rather than spec fields, avoiding upstream schema changes and merge conflicts. Combined with a separate controller, this pattern lets downstream forks add capabilities without touching the core reconciliation logic. The trade-off is discoverability — annotations are less visible than spec fields — but for optional, downstream-specific integrations, it's the right call.

13. **Existing PRs may be out of sync but architecturally sound** — the gateway integration PR was written against an old flat spec schema but its design (separate controller, annotation-driven, status patches, owner references) was solid. Adapting it to the current nested spec was mechanical — the architecture translated directly. This suggests that reviewing PRs for design quality is more valuable than checking whether they apply cleanly.

14. **ALLOW auth policies don't compose well with multiple gateway listeners** — an ALLOW-based AuthorizationPolicy that requires JWT on all traffic works for a single-listener gateway. Adding a second listener (Keycloak) breaks it because the new listener is implicitly denied. Switching to DENY semantics scoped to specific ports avoids this. In production, Kuadrant AuthPolicy handles this at a per-route level rather than a per-gateway level.

15. **Strip upstream make targets down to what you need** — mcp-gateway's `make keycloak-install` bundles TLS, API server OIDC config, per-server clients, test users, and host patching. Most of this is irrelevant at the foundation stage. Understanding each resource before applying it prevents unnecessary dependencies (cert-manager, Kuadrant) from being pulled in prematurely.

16. **Keycloak's realm import is a one-shot operation** — the `--import-realm` flag loads the realm JSON on first startup. Changes to the ConfigMap require a pod restart. This is fine for development but means realm evolution (adding users, clients, roles) should be done via the Keycloak admin API or UI once the instance is running, not by editing the ConfigMap.

17. **Istio auth resources are all Envoy filters under the hood** — RequestAuthentication becomes a JWT authn filter, AuthorizationPolicy becomes an RBAC filter, EnvoyFilter injects Lua directly. They all end up as configuration in the same Envoy proxy, executed in order. Understanding this makes debugging auth issues much clearer — you're always debugging Envoy filter chain behavior, not three separate systems.

18. **Envoy filter chain ordering constrains auth architecture** — RBAC filters (from AuthorizationPolicy) run before Lua filters (from EnvoyFilter). This means you can't use AuthorizationPolicy to deny unauthenticated requests AND use a Lua filter to return proper 401 + WWW-Authenticate — the RBAC 403 fires first. In production, Kuadrant's ext_authz-based AuthPolicy runs at a different point in the filter chain and has full response control.

19. **istiod caches JWKS inline, not by reference** — istiod fetches JWKS from the configured URI once, converts it to `local_jwks` (inline keys in Envoy config), and pushes it to proxies. If the OIDC provider's keys rotate (e.g., Keycloak pod restart in dev mode), istiod does not re-fetch. Both istiod and the gateway pod must be restarted to pick up new keys. Production OIDC providers persist keys across restarts, making this a dev-mode-specific issue.

20. **RFC 9728 `authorization_servers` must contain issuer identifiers, not `.well-known` URLs** — OAuth clients construct the metadata discovery URL from the issuer. Setting the full `.well-known` URL in protected resource metadata breaks client discovery. This is a subtle but important distinction in the OAuth protected resource metadata spec.

21. **Separate OAuth clients for different grant flows** — browser-based tools (Inspector, SPAs) need public clients with authorization code + PKCE. Server-to-server integrations need confidential clients with client_credentials. Mixing these in a single client weakens the security model. Keycloak makes this easy with multiple clients per realm.

22. **Keycloak 26 requires firstName/lastName even when optional** — user profile fields marked as optional in Keycloak's profile configuration are still required for the password grant flow. Without them, the token endpoint returns "Account is not fully set up." This is a Keycloak-specific behavior, not an OIDC standard requirement.

23. **Device authorization grant is the right pattern for CLI MCP clients** — unlike password grant (client handles credentials directly) or authorization code + PKCE (requires browser redirect URI handling), the device flow lets a CLI tool authenticate users through the browser without embedding credentials or handling callbacks. Keycloak supports it out of the box with a single client attribute (`oauth2.device.authorization.grant.enabled`). The flow is identical to `gh auth login` and `gcloud auth login`.

24. **Envoy filter chain order enables gateway-level tool authorization** — ext_proc (Router) runs before the Kuadrant Wasm plugin (auth) in Envoy's HTTP filter chain. By the time auth runs, the Router has already parsed the JSON-RPC body and set headers (`x-mcp-toolname`, `x-mcp-servername`, `:authority`). This means Authorino can authorize based on tool name and server identity without duplicating body parsing. The initial assumption that auth ran before routing was wrong — verified via `curl localhost:15000/config_dump` on the Envoy pod.

25. **Kuadrant uses a Wasm plugin, not raw ext_authz** — the Kuadrant operator's EnvoyFilter only adds a cluster definition for Authorino. The actual HTTP filter is a Wasm plugin (`extensions.istio.io/wasmplugin/kuadrant-mcp-gateway`) that the operator manages via a WasmPlugin resource. This is not visible in EnvoyFilter resources — only in the Envoy config dump or `kubectl get wasmplugin`. Understanding this is critical for debugging auth issues.

26. **CEL predicates in AuthPolicy combine group and tool checks** — a single `patternMatching` predicate can express "developers can call tools A and B, ops can call tools B and C" using OR logic. Multiple authorization rules are AND'd, but within a predicate you can use `||`. This gives production-grade per-group per-tool authorization with no code changes to the gateway.

27. **Header names from the Router don't match intuition** — the Router sets `x-mcp-toolname` (no hyphens between words), not `x-mcp-tool-name`. This caused "no such key" errors in Authorino that were only visible in Authorino's debug logs. Always verify actual header names from the Envoy config dump or Authorino logs rather than assuming.

28. **`tools/list` is the authorization blind spot** — gateway-level AuthPolicy can enforce `tools/call` authorization because the Router identifies the tool and sets headers. But `tools/list` goes to the broker (no `:authority` rewrite, no tool-specific headers), and the broker returns all tools to all users. Filtering `tools/list` by user identity requires broker code changes — the gateway cannot selectively filter items within a JSON-RPC response body.

29. **TLS termination at the gateway is transparent to the MCP protocol** — adding HTTPS listeners with `tls.mode: Terminate` means TLS is handled entirely at Envoy. Backends (broker, MCP servers, Keycloak) continue to receive plain HTTP. No application-level changes are needed. The only client-side change is the URL scheme and CA certificate trust.

30. **cert-manager must be installed before Kuadrant** — Kuadrant's TLSPolicy controller checks for cert-manager at startup. If cert-manager isn't present, the controller reports `MissingDependency` and never initializes — even if cert-manager is installed later. The fix is installation order, plus a fallback that restarts the Kuadrant operator if TLSPolicy isn't enforced within a timeout window.

31. **TLSPolicy auto-creates certificates with deterministic naming** — a single TLSPolicy targeting a Gateway scans for HTTPS listeners and creates Certificate CRs named `{gateway}-{listener}`, with secrets named `{gateway}-{listener}-tls`. The Gateway's `certificateRefs` must match these auto-generated names. This convention is undocumented but reliable — knowing it avoids trial-and-error.

32. **Denied server access returns 500, denied tool access returns 403** — when a user is blocked from an entire server, the broker can't establish a session and wraps the 403 as a generic "failed to create session" 500 error. When a user can reach the server but is denied a specific tool, the 403 from Authorino passes through cleanly. The 500 is a presentation issue in the broker — it doesn't distinguish "server is down" from "you're not authorized."

33. **Keycloak realm import silently drops `defaultClientScopes` on clients** — when a realm export defines both a client scope and a client that references it in `defaultClientScopes`, Keycloak's `--import-realm` may not apply the scope to the client. The scope is created, but the client doesn't get it. Tokens are then missing expected claims (in our case, `aud: mcp-gateway` required by Vault JWT auth). This is not an experiment-specific issue — any production setup using Keycloak realm imports with custom audience mappers would hit it. The fix is to verify scopes are applied after import via the admin API (`GET /admin/realms/{realm}/clients/{id}/default-client-scopes`) and add them if missing (`PUT .../default-client-scopes/{scope-id}`).

34. **Broker credential secret label is `mcp.kuadrant.io/secret`, not `mcp.kuadrant.io/credential`** — the mcp-gateway controller validates that secrets referenced by `credentialRef` have the label `mcp.kuadrant.io/secret=true`. The label name is not intuitive and is easy to get wrong. Without it, the MCPServerRegistration status reports a clear error message, but the secret appears to exist and have correct data — only the label is missing. The mcp-gateway CLAUDE.md documents this as `mcp.kuadrant.io/credential`, which is also incorrect.

35. **Gateway auth architecture has an intentional broker/router split for credentials** — the broker uses static K8s Secret credentials (`credentialRef`) for tool discovery at startup. Per-user credentials flow through the Envoy AuthPolicy layer (Vault token exchange) at request time. The broker connects directly to backends (not through Envoy), so AuthPolicy never fires for discovery. The router, however, hairpins through Envoy for session initialization, which triggers AuthPolicy. This means the broker and router have fundamentally different credential paths for the same backend — static for discovery, dynamic for user requests. Understanding this split is essential for debugging auth issues with authenticated backends.

36. **Per-user credential exchange works entirely in AuthPolicy metadata evaluators** — the Vault token exchange (JWT login + secret read + header injection) is implemented purely in Kuadrant AuthPolicy metadata and response rules. No application code changes, no sidecars, no webhook interceptors. Authorino's metadata evaluators execute HTTP calls in a priority-ordered chain, and the response rules inject the retrieved credential into upstream request headers. This demonstrates that Kuadrant's auth architecture is general enough to handle credential brokering, not just access control.

37. **MCP servers must accept credentials via HTTP headers for gateway-level credential injection** — the GitHub MCP server accepts `Authorization: Bearer` headers in HTTP mode, making it compatible with the Vault exchange pattern. Servers that only read credentials from environment variables (e.g., Slack MCP server) force a per-user deployment model. This is a fundamental design consideration for MCP server authors: supporting HTTP header-based credentials enables multi-tenant gateway architectures.

38. **Operator reconcilers must merge, not replace, spec maps for extensibility** — the gateway controller's `reconcileMCPServerRegistration` initially replaced the entire `spec` map, dropping any externally-added fields including `credentialRef`. The fix was annotation-driven propagation of `credentialRef`. The general lesson: reconcilers that own a resource should merge their fields into the existing spec rather than replacing it wholesale, or risk overwriting fields set by other controllers or manual configuration.

39. **VirtualMCPServer filters `tools/list` but does not enforce `tools/call`** — the broker filters the tool list response when the `X-Mcp-Virtualserver` header is present, but does not block `tools/call` for tools not in the virtual server. Any user who knows a tool name can call it regardless of virtual server membership. VirtualMCPServer is a curation/visibility mechanism, not a security boundary. AuthPolicy remains the only enforcement layer.

40. **VirtualMCPServer is not identity-aware** — the CRD has no concept of users or groups. It's selected by client header (`X-Mcp-Virtualserver: namespace/name`), not by JWT claims. If both VirtualMCPServer and per-tool AuthPolicy are used, the platform engineer must manually keep them aligned — the virtual server should only list tools the intended audience is authorized to call, otherwise users see tools they get 403 on.

41. **No gateway API for VirtualMCPServer discovery** — the broker stores virtual servers in an internal map with lookup by header value only. There is no endpoint to list available virtual servers. Users must discover them via `kubectl get mcpvirtualservers` (requires K8s access), out-of-band communication (docs, Slack), or a UI like Gen AI Studio that reads the CRs directly. For CLI/API consumers without K8s access, this is a significant friction point.

42. **Per-tool CEL predicates in AuthPolicy don't scale** — the inline `patternMatching` approach (hardcoding tool names and group memberships in CEL predicates per AuthPolicy) works for experimentation but becomes unmanageable at scale. A production deployment with many tools and groups would need external policy engines (OPA/Rego) or a coarser authorization model. The more practical pattern is: namespace isolation for team-level separation + VirtualMCPServer for tool curation + coarse AuthPolicy at the gateway level (group can access this namespace), avoiding per-tool predicates entirely.

43. **VirtualMCPServers can span tools from multiple registered servers** — since registered servers use `toolPrefix` to namespace their tools (e.g., `test_server1_greet`, `github_list_repos`), a VirtualMCPServer can cherry-pick tools across any number of upstream servers in a single curated list. The broker matches tool names from the aggregated pool regardless of origin. This enables cross-server tool composition for team-specific use cases.

44. **VirtualMCPServer-to-group binding requires manual coordination across two independent CRD systems** — the correct pattern for VirtualMCPServer is platform-driven: AuthPolicy injects the `X-Mcp-Virtualserver` header based on JWT group claims, so the client is unaware of virtual servers entirely. But this means the platform engineer must manually maintain two independent resources: a VirtualMCPServer CR (mcp-gateway controller) defining the tool list, and an AuthPolicy response rule (Kuadrant/Authorino) mapping groups to virtual server names. Nothing connects these automatically — the mcp-controller doesn't generate AuthPolicy rules, and Authorino doesn't read VirtualMCPServer CRs. A higher-level abstraction that declares "this virtual server is for this group" and generates both would close the gap, but doesn't exist today.

45. **VirtualMCPServer selection requires custom HTTP headers that standard MCP clients can't set** — the broker selects a virtual server based on the `X-Mcp-Virtualserver` HTTP header on each request. The MCP protocol has no concept of virtual server selection — clients just connect to a URL and send JSON-RPC. Off-the-shelf MCP clients (Claude Desktop, Cursor, etc.) cannot inject custom headers, so VirtualMCPServer selection only works for clients that explicitly support it: Gen AI Studio (which can add the header behind the scenes) or custom-built clients. An alternative that would work with any MCP client would be per-virtual-server URL paths (e.g., `/mcp/dev-tools`), but the gateway's broker exposes a single `/mcp` endpoint today.

46. **The gateway's Auth Phase 2 design already addresses the manual coordination gap we identified** — Findings 39-45 documented a series of operational pain points with VirtualMCPServers and per-tool AuthPolicy: manual CEL predicates don't scale (42), VirtualMCPServer-to-group binding requires coordinating two independent CRD systems (44), and clients can't discover or select virtual servers natively (41, 45). After identifying these gaps through architecture analysis, we discovered that the mcp-gateway project's Auth Phase 2 design (`docs/design/auth-phase-2.md`) already solves most of them through a fundamentally different approach:

    - **Tool permissions move to Keycloak**, not AuthPolicy — each MCP server is a Keycloak "resource server" client, each tool is a client role, and users are assigned tools via group-to-role mappings. The JWT's `resource_access` claim carries the full tool permission set.
    - **A single generic AuthPolicy** uses OPA/Rego to extract `resource_access` from the JWT and Authorino's **wristband** feature to sign it into an `x-authorized-tools` JWT header. The broker validates the signature and filters `tools/list`. No per-tool CEL predicates, no manual tool name lists in the policy.
    - **`tools/call` authorization** also reads `resource_access` from the JWT and checks that the requested tool (via `x-mcp-toolname` header) is in the user's roles for that server. Combined with Vault API key lookup (priority 0) and OAuth2 token exchange (priority 1, RFC 8693) for upstream credential injection.
    - **VirtualMCPServers become optional** — identity-based filtering via `x-authorized-tools` handles per-user tool visibility. VirtualMCPServers remain available as an additional curation layer but are no longer the primary mechanism for controlling who sees what.
    - A future `KeycloakToolRoleMappingPolicy` CRD is envisioned in `VISION.md` to further abstract the AuthPolicy configuration, but even without it, the Phase 2 design eliminates the need for per-tool predicates and multi-CRD coordination.

    Notably, Phase 2 also diminishes the role of VirtualMCPServers significantly. When Keycloak's `resource_access` claim defines per-user tool permissions at the individual tool level (not server level), and the `x-authorized-tools` wristband JWT handles `tools/list` filtering, VirtualMCPServers become redundant for access control. Their only remaining use case is workflow-specific tool scoping — an AI agent wanting a focused subset of its authorized tools to reduce LLM context — which is a client-side UX concern, not a platform concern. This matters for RHAISTRAT-1149 documentation: VirtualMCPServers are a key best practice in Phase 1 (the only tool visibility mechanism), but their importance drops substantially once Phase 2 is adopted. The documentation should be clear about which auth phase the deployment is targeting.

    This is a case where the experimentation process — building with Phase 1 primitives, hitting scalability walls, and reasoning about what a better architecture would look like — led us to independently identify the same problems the gateway team had already designed solutions for. The findings remain valid as documentation of Phase 1 limitations and as motivation for why Phase 2 is necessary. Example sample AuthPolicies for both patterns are available at `config/samples/oauth-token-exchange/tools-list-auth.yaml` and `tools-call-auth.yaml` in the mcp-gateway repo.

---

## Reflection: How AI Was Used in This Experiment

### Pattern of interaction

The experiment followed a consistent pattern that proved effective for learning complex systems:

1. **Start with a broad, open-ended question** ("scan these projects, how do they work together") to get oriented
2. **Request a minimal working deployment** ("bare minimum, ignore non-basic features") to have something concrete to poke at
3. **Ask for a deep walkthrough** ("walk me through every resource") to build understanding from the running system
4. **Ask clarifying questions** to test and correct mental models ("is it safe to say X?", "how does Y know to pick the right one?")
5. **Request visualizations** to solidify understanding, then refine them ("highlight the data path vs control plane")
6. **Scope up incrementally** ("let's add auth") with explicit boundaries ("leave token exchange out for now")
7. **Push back on over-engineering** ("can we not just build our own lightweight OIDC provider?") to keep focus on understanding vs deployment
8. **Investigate failures deeply** ("is this a limitation?" -> "is this intentional?" -> "how is it solved in production?") rather than just working around them

As the experiment progressed beyond the initial learning phases, the interaction pattern evolved. The following patterns emerged in the later phases (11-13) as the focus shifted from understanding individual components to integrating them into a cohesive system:

9. **Evaluate and adapt existing work rather than starting from scratch** — for the gateway integration (Phase 11), the user directed AI to read an existing PR ([openshift/mcp-lifecycle-operator#3](https://github.com/openshift/mcp-lifecycle-operator/pull/3)), assess its architectural soundness despite being out-of-sync with the current codebase, and reintegrate its design into a new branch. This is a different mode from the earlier "build from scratch to learn" pattern — it's closer to how experienced engineers actually work: find prior art, evaluate the design, adapt to current state. The AI was used to bridge the gap between the PR's outdated assumptions and the current nested spec schema, while preserving the PR's sound architectural decisions (separate controller, annotation-driven, status patches, owner references).

10. **Decompose upstream automation before using it** — when it came time to deploy Keycloak (Phase 12), the user stopped the AI from running `make keycloak-install` wholesale: *"Wait before you fly through the keycloak installation. I would like to better understand what's getting applied for keycloak."* Each resource was examined individually, and only the relevant subset was applied. This turned out to prevent unnecessary dependencies (cert-manager, API server OIDC config, per-server test clients) from being pulled in. The pattern: don't run opaque automation; break it open, understand each piece, take only what you need.

11. **Assess the durability of each change** — the user introduced an explicit filter: *"One thing we need to be cognizant of is what changes are we making just to get stuff working right now vs which ones are taking us closer to our goal of getting a robust system in place."* This prompted a review of every change's longevity — Keycloak config was durable (Kuadrant consumes it as-is), while Istio auth resources were temporary (replaced by AuthPolicy). This meta-awareness prevented accumulating technical debt disguised as progress, and is a pattern that's easy to skip when moving fast with AI assistance.

12. **Pivot to production-grade alternatives when the cost is low** — when MCP Inspector's browser OAuth failed with Keycloak (Phase 12), instead of debugging Inspector internals, the user pivoted to building a device authorization grant CLI: *"If there are cheap opportunities to make something closer to production without much extra effort let's take it."* The resulting `mcp-client.sh` uses the same flow as `gh auth login` — more production-representative than fixing a dev tool's browser quirks. This is a judgment call the user made that the AI wouldn't have: when to stop debugging a tool and build something better.

13. **Direct architectural separation through the AI** — the user used AI not just to build, but to enforce design boundaries: *"The mcp launcher should not be aware of this detail"* and *"Get rid of any code in the launcher that makes it aware of gateway resources."* The AI was directed to remove working code that violated separation of concerns — gateway resource creation was moved to the operator's gateway controller where it belongs. This is a pattern where the user's architectural judgment overrides the AI's tendency to keep things working in the most direct way possible.

14. **Run parallel investigations across sessions** — the filter chain order insight (Phase 13) came from a separate session where the user independently investigated Envoy's config dump. The finding — that ext_proc runs before the Kuadrant Wasm plugin — was brought back as a premise for the current session's work. This shows a multi-threaded investigation pattern where the user maintains multiple AI conversations as parallel workstreams, synthesizing findings across them.

15. **Validate with exhaustive test matrices** — the 30-case authorization test matrix (Phase 13) marked a shift from "does it work" to "prove the full authorization matrix is correct." Three users × two servers × five tools per server, testing both allowed and denied combinations. The AI was used to systematically execute every test case and present results in a table. This is a verification pattern that builds confidence in the system's correctness before moving to the next layer.

As the experiment shifted from building the system to packaging it for reproducibility (guided setup, branch management, documentation), a new set of patterns emerged:

16. **Test live on a running cluster and report in real time** — the user consistently tested changes immediately after they were made, reporting issues as they encountered them: *"the github tools aren't showing"*, *"i got an invalid session id"*, *"the mcp-client.sh script is breaking on main."* Rather than reviewing diffs or reading logs, the user ran the system and let failures surface organically. This created a tight feedback loop where the AI could diagnose from the user's exact error context rather than speculating about what might go wrong. It also exposed integration issues that code review alone wouldn't catch — like the operator image (`gateway-integration` vs `gateway-credential-ref`) silently dropping credential references from MCPServerRegistrations.

17. **Treat READMEs as user-owned artifacts** — the user frequently edited README content directly between AI commits: adding usage examples, tweaking wording, inserting attribution lines, adding PAT setup notes. The AI's role was to make targeted, structural changes (adding a branch table, updating a tear-down command) rather than wholesale rewrites. This is a division of labor where the user controls voice and presentation while the AI handles cross-file consistency and mechanical updates.

18. **Demand full visibility into operational state** — when the guided setup initially summarized each phase with a brief completion message, the user pushed back: *"I would like the output to be more explicit about the full list of resources that were deployed/created during that phase."* This led to the `show_resources` helper that lists every Deployment, Pod, Service, CRD, HTTPRoute, and AuthPolicy created by each phase. The preference was clear: show everything, let the user decide what to skip — don't pre-filter on their behalf.

19. **Enforce cross-file consistency as a first-class concern** — two bugs in this phase (operator image tag and Kind cluster name) both had the same root cause: a value defined in multiple files was updated in some but not all of them. The operator image was `gateway-integration` in `deploy.yaml`, `setup.sh`, and `guided-setup.sh`, but Phase 16 required `gateway-credential-ref`. The Kind cluster name was `mcp-gateway` in scripts, README, and guided-setup descriptions. The fix in both cases was a grep across the repo for every occurrence before committing. This is a pattern the AI should internalize: when changing any named value, search for all occurrences first.

20. **Branch strategically to create a complexity ladder** — the user created three branches (`basic`, `intermediate`, `main`) that serve different audiences. `basic` (10 phases) covers the core pipeline with mini-oidc. `intermediate` (16 phases) adds Keycloak, Kuadrant, per-tool auth, TLS, and Vault. `main` evolves toward production deployment patterns. Each branch has a self-describing README that explains what it covers and links to the others. This isn't just version control — it's a pedagogical structure where each branch is a complete, self-contained experiment at a specific complexity level.

### What worked well

- **Building mini-oidc instead of deploying Keycloak** was the single best decision. Writing PKCE verification code taught more about OAuth 2.1 than any documentation could.
- **Letting failures drive learning** — every error (image pull failures, OOM, JWKS caching, 403 vs 401) became a concrete lesson about the underlying systems.
- **Testing mental models explicitly** — asking "is it safe to say X?" repeatedly caught incorrect generalizations early.
- **Asking "why" after finding a limitation** — the 401 vs 403 investigation went from "it's broken" to "it's an intentional design decision" to "here's how production solves it" to "no issue needed." That chain of inquiry built real architectural understanding.
- **Decomposing upstream automation** — examining `make keycloak-install` resource by resource prevented pulling in cert-manager, API server OIDC config, and test fixtures that weren't needed. The habit of understanding before applying paid off repeatedly.
- **Adapting existing PRs rather than reimplementing** — the gateway integration PR's design was architecturally sound despite being out-of-sync. Evaluating design quality separately from code currency saved significant effort and preserved decisions (annotation-driven activation, separate controller, owner references) that would have been easy to get wrong from scratch.
- **Enforcing separation of concerns through explicit direction** — removing gateway awareness from the launcher was uncomfortable (it broke a working shortcut) but resulted in a cleaner system where each component has a single responsibility. The AI wouldn't have made this refactoring choice unprompted.
- **Pivoting to production patterns when debugging dev tools** — the device authorization grant CLI replaced Inspector debugging and ended up being more valuable: it validated a real OAuth flow, could be used for the full authorization test matrix, and demonstrated the production auth pattern for CLI MCP clients.
- **Grepping for all occurrences before changing a named value** — the operator image and cluster name bugs both came from partial updates across multiple files. The fix was mechanical but the lesson was structural: in a multi-file infrastructure repo, every named constant is a potential consistency bug.
- **Packaging the experiment as a complexity ladder** — three branches at three levels means a reader can start with the 10-phase `basic` branch and build understanding incrementally, rather than being dropped into a 16-phase system with Vault and TLS from the start.

### What this approach is good for

This AI-assisted incremental exploration works well when the goal is to understand **how multiple complex systems interact** without deep prior expertise in all of them. The AI handles the boilerplate (deploying infrastructure, writing YAML, debugging container issues) while the user directs the learning — choosing what to explore next, when to go deeper, when to simplify, and what questions will build the most useful mental models.

As the experiment matured, the AI's role shifted from "teach me how this works" to "help me integrate these systems correctly." The user's increasing familiarity with the components meant they could make architectural judgment calls (separation of concerns, durability of changes, when to pivot) while delegating the mechanical work (adapting PR code to new schemas, running 30-test authorization matrices, tracing Envoy filter chains) to the AI. The most productive interactions were ones where the user brought a clear design intent and the AI handled the implementation details — not because the user couldn't do the implementation, but because the AI's ability to hold the full context of multiple systems (Envoy config dumps, Authorino debug logs, Keycloak realm JSON, Kubernetes CRD schemas) simultaneously made it faster and less error-prone.

In the latest phases, the AI's role shifted again — from integration to packaging and reproducibility. Building the guided setup script, maintaining cross-branch consistency, diagnosing live cluster issues from user-reported symptoms, and ensuring every file referencing a shared value stays in sync. This is closer to a maintenance and DevEx role than the earlier exploration and integration work, and it requires a different kind of attention: less architectural creativity, more systematic cross-referencing.

### Author's personal insights and learnings

- As human beings we have to know what we want and put ourselves in the driver's seat. That is the best way to get the most out of these AI systems. You should have a clear vision for what you are trying to achieve and adjust scope aggressively. AI should only provide options/inputs if requested and execute. Relying on/delegating to AI for direction and design decisions could be suboptimal towards achieving both, the task objective as well as personal growth and fullfilment from that task (Until such a time as 100% automated AI systems exist and behave reliably)
- Critical thinking isn't going away, but it is changing shape. While a lot of mechanical thinking and execution may be getting abstracted away from us, humans must remain curious and skeptical. When decision points emerge out of AI system outputs, it is still crucial for humans to poke and prod and ask "why" or "why not" every so often. This ensures AI decision making rationale is surfaced and scrutinized, allows human critical thinking muscle to be exercised and can often lead to learning opportunites on both sides.
- Trust vs control is a sliding boundary. As we build confidence in AI systems to take on bigger and more complex tasks, we should set ourselves up to always be in a position to take the wheel if needed. This can look like having AI build in manual entry points alongside the vast and powerful automations. For example, having AI set up the large, multi-phase setup scripts and testing pipelines while also buidling the `mcp-client` CLI for manual testing. Human perspective is still capable of catching drifts from the intended spirit of the operation at any point.
- Simply generating and shipping code is boring. These AI systems can be much more fun and interesting when used as a learning parter and brainstorming tool. When faced with a problem statement, assuming a collaborative posture as opposed to a delegatory posture could be the differenece in how enriching the interaction is to you and how good you feel about the outcome. Rather than throwing our hands up in the air and saying "this is AI's problem now", we should acknowledge that it is still our problem, we just have something to work through it with 24x7 now.
- Thiking out loud seemed to help enrich context with intention as compared to always trying to come up with crisp and polished commands. The flexible interaction format allows human stream of consciousness to be received and engaged with immediately. Taking advantage of that seemed to allow for more seemless convergence with the AI on shared direction as compared to abstracting away my thought process. There have been occassions where AI is able to identify and articulate things that were in my mind but I couldn't quite place my finger on, presumbly due to the context clues it picked up.
- A fork in the road, a mirror, and a double edged sword, AI is all of them. It is a significant force multiplier with no inherent direction of its own. It is a unique tool that allows your pwn personal traits and chocies to determine your direction of progress but amplies by the effect by orders of magnitude. Depending on how you choose to view and use it, it can either upskill or downskill you very quickly. If you are someone who is curious, motivated and goal driven, it can accelerate your progress. If you are unmotivated and indifferent, it can wipe your skills out in the long run. It is crucial for any humans spending extended amounts of time working with these systems to self assess and see where they fall from time to time.
