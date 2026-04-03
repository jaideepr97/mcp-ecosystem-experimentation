---
name: MCP Ecosystem Experiment - Changes Tracker
description: Tracks all modifications made to projects during the MCP ecosystem experiment, distinguishing fundamental component gaps from helper project changes
type: project
---

# Changes Made During MCP Ecosystem Experiment

## Fundamental Components (gaps/enhancements worth tracking)

### model-registry catalog
- **No code changes made.** Deployed as-is from `ghcr.io/kubeflow/model-registry/server:latest`.
- Catalog API works well for MCP server discovery out of the box.
- **Observation:** The list endpoint (`/api/mcp_catalog/v1alpha1/mcp_servers`) returns `toolCount` but not the tools themselves. Tools require a separate per-server call (`/mcp_servers/{id}/tools`). A consumer building a UI or automation layer must make N+1 API calls to show tools alongside server listings. An `include=tools` query parameter or embedding tools in the list response would reduce round trips.
- **Observation:** `filter_options` returned empty `{"filters": {}}` for our YAML-based catalog. Filtering may only be meaningful with larger catalogs or specific provider types.

### mcp-gateway
- **No code changes made.** Deployed using existing make targets.
- **Observation (from earlier phases):** The ext_proc Router unconditionally rewrites `:authority` header on ALL port 8080 traffic (`internal/mcp-router/request_handlers.go:198`), which prevents non-MCP services from being exposed through the same Envoy gateway. Mini-oidc had to be exposed via a separate NodePort to avoid this.
- **Observation:** MCPServerRegistration API group is `mcp.kuadrant.io` but mcp-launcher hardcoded `mcp.kagenti.com`. This was fixed in our launcher fork. The group name difference suggests the CRD API group may have changed at some point — consumers need to track the correct group.

### mcp-lifecycle-operator
- **No code changes to upstream.** CRD and operator binary were redeployed from latest source (schema had changed from flat to nested since initial deployment).
- Works as expected: MCPServer CR creates Deployment + Service, deleting CR cleans up resources.
- **Observation:** No built-in integration with the catalog. The operator has no awareness of the catalog API — the bridge between "what's available" (catalog) and "deploy it" (operator) must be built externally (which is what mcp-launcher does).

### mcp-lifecycle-operator (downstream fork)
- Branch: `gateway-integration` on `/Users/jrao/projects/mcp-lifecycle-operator`
- **Changes:** Integrated gateway controller from [openshift/mcp-lifecycle-operator#3](https://github.com/openshift/mcp-lifecycle-operator/pull/3), adapted for current nested spec schema and correct API group (`mcp.kuadrant.io`).
- Added `MCPServerGatewayReconciler` — a separate controller that watches MCPServer CRs and creates HTTPRoute + MCPServerRegistration when `mcp.x-k8s.io/gateway-ref` annotation is present.
- This closes the operator → gateway registration gap. The full pipeline (catalog → launcher → operator → gateway) is now automated.

### Catalog → Operator handoff friction (cross-project integration gap)
These are the most significant findings — gaps in the **contract between catalog metadata and operator deployment**:

1. **`runtimeMetadata` missing container command/entrypoint.** The catalog schema has `artifacts[].uri` (OCI image) and `runtimeMetadata.defaultPort`, but no field for the container binary or entrypoint. The operator's `config.arguments` maps to Kubernetes `container.args` which *replaces* CMD for images without ENTRYPOINT. Without knowing the binary path (e.g. `/mcp-test-server`), a deployer cannot construct correct arguments. The catalog metadata alone is insufficient to deploy — you need out-of-band knowledge about the image's ENTRYPOINT/CMD.

2. **`runtimeMetadata` missing security context requirements.** The operator defaults to restricted Pod Security Standards (`runAsNonRoot: true`). The catalog has no field indicating whether an image requires root. mcp-launcher has a `runAsRoot` extension field, but the catalog API schema doesn't expose this. A deployer reading only catalog metadata has no way to know this will fail.

3. **No standardized "arguments" field in catalog metadata.** The catalog has no equivalent of the operator's `config.arguments`. Some images need specific flags (e.g. `--http 0.0.0.0:9090`), but this isn't captured in the catalog. The `runtimeMetadata` section covers port and path but not how to start the server.

4. **Semantic gap in `arguments` between launcher and operator.** mcp-launcher's `PackageArguments` are meant to be appended to the container command. The operator's `config.arguments` replaces CMD entirely. These are fundamentally different semantics. An integrator bridging the two must understand both conventions.

**Summary:** The `runtimeMetadata` contract is necessary but not sufficient for automated deployment. It covers *what* to expose (port, path) but not *how* to run (command, args, security context). A complete catalog-to-operator handoff would need: container command/entrypoint, required arguments, security context requirements (root/non-root), and potentially resource requirements.

5. **Operator → Gateway registration gap.** Once the operator deploys an MCP server (Deployment + Service), there is no automated path to register it with the gateway (HTTPRoute + MCPServerRegistration). The handoff from "server is running" to "server is routable via gateway" is a distinct integration seam. The user has something in mind for a future iteration to address this.

### OCI image opacity — the systemic catalog→operator problem

The friction points above (1–4) are symptoms of a deeper structural issue: **OCI images are opaque, and the catalog metadata doesn't carry enough operational context to deploy them reliably.** Each MCP server image can differ across multiple dimensions simultaneously:

- **Entrypoint/CMD conventions**: Some images use ENTRYPOINT (args append), some use CMD (args replace), some use both. The operator's `config.arguments` maps to Kubernetes `container.args`, which *replaces* CMD — destructive if the deployer gets it wrong. Example: test-server1 has `CMD ["/mcp-test-server"]` with no ENTRYPOINT, so `config.arguments: ["--http", "0.0.0.0:9090"]` replaced the binary entirely and the container crashed.
- **Transport selection**: Servers default to different transports (stdio, HTTP/SSE, streamable-HTTP). The flag to switch varies per image (`--http`, `--transport http`, `--mode sse`, env var `MCP_TRANSPORT`, etc.). test-server1 defaulted to stdio and exited immediately because no HTTP flag was passed.
- **Bind address conventions**: Some listen on `0.0.0.0`, some on `127.0.0.1` by default. Some accept `host:port` combined, others take `--port` and `--host` separately.
- **Security context requirements**: Root vs non-root, specific UID, filesystem write needs. The operator defaults to restricted PSS (`runAsNonRoot: true`), but the catalog has no field indicating what an image requires.
- **Runtime dependencies**: Writable temp dirs, volume mounts, DNS resolution for external services, etc.

**In the worst case, every MCP server image is a snowflake.** The catalog becomes a registry of names without enough operational metadata to actually deploy anything — it tells you *what exists* but not *how to make it run*. The operator just does what it's told, so there's no intelligence in between.

**Where should this knowledge live?** Options include:
1. **In the image itself** — OCI labels or a standardized ENTRYPOINT contract. Requires all MCP server authors to follow a convention.
2. **In the catalog metadata** — Richer `runtimeMetadata` covering command, args, security context, bind address. Requires the catalog schema to grow.
3. **In a separate "deployment profile"** — A layer between catalog and operator encoding per-image operational knowledge.
4. **Convention over configuration** — Define an "MCP server image contract" (e.g., MUST use ENTRYPOINT, MUST accept `--port $PORT` and listen on `0.0.0.0`, MUST run as non-root) so the operator can make safe assumptions without per-image metadata.

Without at least one of these, every new MCP server added to the catalog is a potential deployment failure requiring human debugging. This is the most significant integration gap observed in the experiment — it's not a single missing field but a missing contract between image authors, catalog curators, and the deployment operator.

### mini-oidc (custom OIDC provider)
- **Code changes made** (this is our own test project, not an upstream component):
  - Added `/.well-known/oauth-authorization-server` endpoint (OAuth AS metadata, same as OIDC discovery)
  - Added CORS middleware for browser-based clients (MCP Inspector)
  - Added `/register` endpoint (RFC 7591 Dynamic Client Registration)
  - Added `/authorize` endpoint with authorization code + PKCE flow
  - These were needed because MCP Inspector expects a full OAuth 2.1 flow

### cert-manager (Phase 14)
- **No code changes to upstream.** Deployed via Helm chart `jetstack/cert-manager` (v1.17.2).
- Created a CA issuer chain: ClusterIssuer `selfsigned-issuer` → Certificate `mcp-ca-cert` (isCA) → ClusterIssuer `mcp-ca-issuer`.
- **Observation:** Must be installed before Kuadrant operator. Kuadrant's TLSPolicy controller checks for cert-manager at startup and reports `MissingDependency` if not found — it does not re-check later. Setup.sh installs cert-manager as Phase 5 (before Kuadrant in Phase 11) with a fallback that restarts the Kuadrant operator if TLSPolicy isn't enforced.

### Kuadrant TLSPolicy (Phase 14)
- **TLSPolicy `mcp-gateway-tls`** in `gateway-system` — targets the Gateway, references `mcp-ca-issuer`.
- Auto-creates Certificate CRs for each HTTPS listener: `mcp-gateway-mcp-https` and `mcp-gateway-keycloak-https`.
- Naming convention is deterministic: `{gateway}-{listener}` for Certificate, `{gateway}-{listener}-tls` for Secret.
- **Observation:** TLSPolicy reconciliation can be flaky after initial creation. Setup.sh includes a retry loop and a fallback that restarts the Kuadrant operator and annotates the TLSPolicy to trigger re-reconciliation.

### Gateway HTTPS listeners (Phase 14)
- **Two HTTPS listeners added** to the Gateway: `mcp-https` (port 8443) and `keycloak-https` (port 8445).
- Both use `tls.mode: Terminate` — TLS terminated at Envoy, backends receive plain HTTP.
- Keycloak HTTPS listener added via JSON patch (`gateway-patch-tls.json`) + separate HTTPRoute (`httproute-tls.yaml`) with OAuth discovery path rewrite.
- **NodePort service** updated with two new entries: 30443→8443, 30445→8445.
- **Kind cluster config** updated with corresponding host port mappings: 8443→30443, 8445→30445.

### Istio/Envoy (auth layer)
- **EnvoyFilter `mcp-auth-401` created** in `gateway-system` — Lua filter that returns proper 401 + `WWW-Authenticate: Bearer` header instead of Istio's default 403 from AuthorizationPolicy. This was needed because Istio's AuthorizationPolicy hardcodes 403 responses (istio/istio#26559), but OAuth clients (MCP Inspector) expect 401 to trigger the authorization flow. In production, Kuadrant AuthPolicy (Authorino) handles this properly.

## Helper Projects (experiment scaffolding)

### mcp-launcher (forked from matzew/mcp-launcher)
- Branch: `catalog-api-integration`
- **Changes:**
  - Extracted `Store` interface from concrete `ConfigMapStore` type
  - Added `APIStore` backend that reads from model-registry catalog REST API (`CATALOG_API_URL` env var)
  - Maps catalog API response schema to launcher's `ServerEntry` schema (artifacts → packages, runtimeMetadata → kubernetesExtensions, etc.)
  - Added `Tool` type to `ServerEntry` and fetches tools from per-server endpoint
  - Updated catalog.html template to render tools as badges
  - Fixed MCPServerRegistration GVR from `mcp.kagenti.com` to `mcp.kuadrant.io` (in RBAC; handler code still has old value — potential issue when deploying via launcher)
- **Why:** Needed a UI to demonstrate the catalog → deploy flow. The launcher's ConfigMap-based catalog backend doesn't integrate with the model-registry catalog API.

### Keycloak (replacing mini-oidc)
- **No changes to upstream Keycloak image.** Deployed `quay.io/keycloak/keycloak:26.3` as-is in dev mode.
- Created a stripped-down realm (`mcp`) with:
  - `mcp-gateway` confidential client (`serviceAccountsEnabled`, `directAccessGrantsEnabled`) for server-to-server and password grant flows
  - `mcp-inspector` public client (`standardFlowEnabled`, PKCE S256) for browser-based OAuth flows
  - `basic` client scope with `sub` mapper (required for Istio to construct request principals from `iss/sub`)
  - `groups` client scope with group membership mapper
  - `roles` client scope with realm/client role mappers
  - Users: alice (developers), bob (ops), carol (developers + ops)
  - Groups: `developers`, `ops`
- Exposed via HTTP (port 8002) and HTTPS (port 8445) through the gateway. TLS terminated at Envoy — Keycloak receives plain HTTP.
- **Observation:** Keycloak's multi-realm URL structure (`/realms/mcp/.well-known/...`) predates RFC 8414, requiring an HTTPRoute path rewrite. This is a Keycloak-specific quirk, not a general OIDC issue.
- **Observation:** Keycloak 26 requires `firstName`/`lastName` on user profiles for password grant even when these fields are marked optional in the user profile configuration. Without them, the token endpoint returns "Account is not fully set up."
- **Observation:** istiod caches JWKS as inline `local_jwks` in Envoy config. When Keycloak's dev mode regenerates signing keys on pod restart, istiod does not re-fetch. Both istiod and gateway pods must be restarted. Production Keycloak with persistent storage would not have this issue.

### Istio auth resources (removed in Phase 13)
- **All three Istio auth resources** (RequestAuthentication, AuthorizationPolicy, Lua EnvoyFilter) have been **deleted from the cluster and removed from the repo**. They were replaced by Kuadrant AuthPolicy which handles authentication, authorization, and custom response formatting in a single CR.
- **Historical observations** (from Phases 6-12, now resolved by Kuadrant):
  - ALLOW-based auth policies don't compose well with multiple gateway listeners
  - Envoy filter chain ordering (RBAC before Lua) prevented combining AuthorizationPolicy enforcement with custom 401 responses
  - These constraints are specific to Istio's auth model and do not apply to Kuadrant's Wasm-based approach

### mcp-gateway (runtime configuration)
- **`OAUTH_AUTHORIZATION_SERVERS` env var** set on `mcp-gateway` deployment in `mcp-system` — populates `authorization_servers` in `/.well-known/oauth-protected-resource`. Value must be the Keycloak issuer identifier (`http://keycloak.127-0-0-1.sslip.io:8002/realms/mcp`), not the `.well-known` URL, per RFC 9728.
- **Observation:** MCP Inspector's browser-based OAuth discovery fails with Keycloak's path-based issuer (`/realms/mcp`). The Inspector fetches authorization server metadata from the browser, which fails silently due to CORS/header issues, and falls back to constructing `/authorize` on the MCP gateway host (404). This is Inspector-specific — curl-based verification works correctly for all grant types.

### mcp-client script (new)
- **`scripts/mcp-client.sh`** — interactive MCP client using OAuth 2.0 Device Authorization Grant (RFC 8628).
- Uses the `mcp-cli` public Keycloak client with `oauth2.device.authorization.grant.enabled`.
- Authenticates via browser-based device flow (same pattern as `gh auth login`), initializes an MCP session, and provides a REPL for tool calls.
- Supports `/login` command for mid-session user switching with proper Keycloak logout (back-channel token revocation + front-channel `id_token_hint` logout).
- Accepts both JSON (`{"name": "value"}`) and key=value (`name=value`) input formats for tool arguments.
- **Why:** MCP Inspector's browser-based OAuth discovery fails with Keycloak's path-based issuer. Rather than debugging an Inspector-specific issue, the device flow provides a production-grade alternative that also serves as a reusable test client.

### Kuadrant operator (Phase 13)
- **Installed via Helm** into `kuadrant-system` namespace. Kuadrant CR created from mcp-gateway's config.
- Components running: Authorino (auth engine), Authorino operator, Kuadrant operator, Limitador + operator (rate limiting, not yet used), DNS operator (not yet used).
- **AuthPolicy** (`auth/authpolicy.yaml`) replaces three Istio auth workarounds (RequestAuthentication, AuthorizationPolicy, Lua EnvoyFilter) with a single CR. Uses Authorino as `ext_authz` in Envoy's filter chain, giving full control over denial responses (proper 401 + `WWW-Authenticate`).
- **CoreDNS patch** applied to `kube-system` — maps `keycloak.127-0-0-1.sslip.io → 10.89.0.0` (gateway LB IP) so Authorino can reach Keycloak from inside the cluster. Cleaner than mcp-gateway's `/etc/hosts` node patching approach.
- Old Istio auth resources (`RequestAuthentication`, `EnvoyFilter/mcp-auth-401`) deleted from cluster. `AuthorizationPolicy` was already deleted in Phase 12.

### 6. Per-user tool-level authorization at the gateway — working (Phase 13)

Per-group, per-tool, cross-server authorization is fully working at the gateway level using Kuadrant AuthPolicy. No code changes to mcp-gateway were required.

#### How it works

The Envoy filter chain order is key: ext_proc (Router) runs **before** the Kuadrant Wasm auth plugin. By the time auth runs, the Router has already parsed the JSON-RPC body and set headers:
- `x-mcp-toolname` — the tool name (prefix stripped)
- `x-mcp-servername` — the server namespace/name
- `:authority` — rewritten to the server's HTTPRoute hostname

Per-HTTPRoute AuthPolicies target individual server HTTPRoutes (created automatically by the operator's gateway controller). CEL predicates combine group membership with tool name:

```yaml
authorization:
  "group-tool-access":
    patternMatching:
      patterns:
        - predicate: >-
            (auth.identity.groups.exists(g, g == 'developers') && request.headers['x-mcp-toolname'] in ['greet', 'time'])
            || (auth.identity.groups.exists(g, g == 'ops') && request.headers['x-mcp-toolname'] in ['time', 'headers'])
```

#### Test results (30/30 passing)

| User | Group | Server1 allowed | Server2 allowed |
|------|-------|----------------|-----------------|
| Alice | developers | greet, time | slow |
| Bob | ops | time, headers | headers, add_tool |
| Carol | both | greet, time, headers | slow, headers, add_tool |

#### Remaining gap: `tools/list` filtering

`tools/call` authorization is fully enforced. But `tools/list` returns all tools to all users because the broker aggregates without filtering. A user denied access to a tool via AuthPolicy would still see it in the tool list but get 403 when calling it. Fixing this requires broker-side changes to filter tools based on JWT claims — the gateway cannot selectively filter items within a JSON-RPC response.

#### Response code inconsistency

- Tool denied on an accessible server → clean **403** from Authorino
- Entire server denied (no allowed tools) → **500** from broker ("failed to create session") because it wraps the 403 as a transport error

The 500 is a presentation issue in the broker — it doesn't distinguish "server is down" from "you're not authorized."

### mini-oidc (removed)
- **Removed from cluster and experiment repo.** Replaced entirely by Keycloak.
- mini-oidc served its purpose as an educational tool for understanding OIDC flows (Phase 4). For multi-tenancy and role-based access control, Keycloak provides the necessary user/group/role management.

## Deployment Artifacts Created (in experiment repo)
- PostgreSQL StatefulSet + PVC + Secret + Service in `catalog-system`
- Catalog ConfigMap (`mcp-catalog-sources`) with sources.yaml + mcp-servers.yaml
- Catalog Deployment + Service in `catalog-system`
- Launcher RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding)
- Launcher Deployment + Service + NodePort in `mcp-test`
- Keycloak namespace + ConfigMap (realm-import) + Deployment + Service in `keycloak`
- Gateway patch (HTTP listener on port 8002) + HTTPRoute for Keycloak
- Gateway patch (HTTPS listener on port 8445) + HTTPRoute for Keycloak HTTPS
- AuthPolicy `mcp-auth-policy` in `gateway-system` (gateway-level JWT auth + 401 response)
- AuthPolicy `server1-auth-policy` in `mcp-test` (per-HTTPRoute, developers group + tool ACLs)
- AuthPolicy `server2-auth-policy` in `mcp-test` (per-HTTPRoute, ops group + tool ACLs)
- MCPServer `test-server2` in `mcp-test` (second test server for multi-server auth testing)
- cert-manager CA issuer chain (ClusterIssuers + CA Certificate) in `cert-manager`
- TLSPolicy `mcp-gateway-tls` in `gateway-system` (auto-creates HTTPS certificates)
- Gateway HTTPS listener `mcp-https` on port 8443 (in base gateway.yaml)
- NodePort entries for HTTPS (30443→8443, 30445→8445)
