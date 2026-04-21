# OpenShift AI MCP Ecosystem Demo Script

**Goal**: Demonstrate the minimum viable MCP ecosystem working end-to-end using the OpenShift MCP server as the tool provider.

**Flow**: Catalog → Deploy → Gateway Registration → Auth + Curation → RHOAI ConfigMap → Gen AI Studio → Tool Execution

**Cluster**: `agentic-mcp.jolf.p3.openshiftapps.com` (ROSA, OpenShift 4.21.6, RHOAI 3.4)
**Demo namespace**: `team-a`

---

## Prerequisites

These are in place before the demo starts — shared platform infrastructure:

| Component | Location | Notes |
|-----------|----------|-------|
| RHOAI 3.4 | redhat-ods-operator | mcpCatalog enabled, Gen AI Studio enabled |
| vLLM 20B | gpt-oss | `--enable-auto-tool-choice --tool-call-parser openai`, `--served-model-name vllm-20b` |
| MCP Gateway Controller | mcp-system (OLM) | v0.6.0, cluster-scoped |
| GatewayClass `openshift-default` | cluster-scoped | Istio-backed (`openshift.io/gateway-controller/v1`) |
| Keycloak (RHBK v26.4.11) | keycloak | Realm `mcp-gateway`, clients `mcp-gateway` + `mcp-playground` |
| Keycloak users | keycloak | `mcp-admin1` (roles: mcp-user + mcp-admin), `mcp-user1` (role: mcp-user) |
| Kuadrant CR | openshift-operators | Authorino (JWT validation) + Limitador (rate limiting) |
| MCP Lifecycle Operator | — | Manages MCPServer CRs |

---

## Step 1: Browse the MCP Catalog

**What**: Discover the OpenShift MCP Server in the RHOAI catalog.

**Actions (UI)**:
1. Open RHOAI Dashboard
2. Navigate to MCP Catalog
3. Locate the OpenShift MCP Server (pre-populated in 3.4)
4. View metadata: description, capabilities, container image

**Resources created**: None

**Status**: [x] Done

---

## Step 2: Deploy the MCP Servers

### 2.1 Create the namespace

```bash
oc create namespace team-a
```

**Status**: [x] Done

### 2.2 OpenShift MCP Server — RBAC

The OpenShift MCP server needs read access to the Kubernetes API. The lifecycle operator does not create this.

```bash
oc create serviceaccount openshift-mcp-server -n team-a

oc create clusterrolebinding team-a-ocp-mcp-view \
  --clusterrole=view \
  --serviceaccount=team-a:openshift-mcp-server
```

**Status**: [x] Done

### 2.3 OpenShift MCP Server — config

> **Note**: The `port` field is required — without it, the server starts in stdio mode and exits immediately.
> The `denied_resources` field uses inline table array syntax: `[{group="", version="v1", kind="Secret"}, ...]`.
> Using TOML section syntax (`[denied_resources]`) causes a type mismatch error.

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: openshift-mcp-server-config
  namespace: team-a
data:
  config.toml: |
    port = "8080"
    read_only = true
    stateless = true
    cluster_provider_strategy = "in-cluster"
    toolsets = ["core", "config"]

    denied_resources = [
        {group = "", version = "v1", kind = "Secret"},
        {group = "", version = "v1", kind = "ServiceAccount"},
        {group = "rbac.authorization.k8s.io", version = "v1", kind = "Role"},
        {group = "rbac.authorization.k8s.io", version = "v1", kind = "ClusterRole"},
        {group = "rbac.authorization.k8s.io", version = "v1", kind = "RoleBinding"},
        {group = "rbac.authorization.k8s.io", version = "v1", kind = "ClusterRoleBinding"}
    ]
EOF
```

**Status**: [x] Done

### 2.4 OpenShift MCP Server — deploy via catalog

**Actions (UI)**:
1. In MCP Catalog, click Deploy on the OpenShift MCP Server
2. Select namespace `team-a`
3. Configure: set ServiceAccount to `openshift-mcp-server`, mount ConfigMap `openshift-mcp-server-config` at `/etc/mcp-config`, set args `--config /etc/mcp-config/config.toml`
4. The lifecycle operator creates Deployment + Service

**Image used**: `registry.redhat.io/openshift-mcp-beta/openshift-mcp-server-rhel9:0.2`

**Verify:**

```bash
oc get pods -n team-a -l app.kubernetes.io/name=openshift-mcp-server
oc get svc openshift-mcp-server -n team-a
oc logs -l app.kubernetes.io/name=openshift-mcp-server -n team-a
# Should show: "HTTP server starting on port 8080"
```

**Status**: [x] Done

### 2.5 Test MCP Server — deploy via lifecycle operator

> **Note**: The `arguments` field maps to the container `command` field (not `args`), so the binary path must be included as the first element.

```bash
oc apply -f - <<'EOF'
apiVersion: mcp.x-k8s.io/v1alpha1
kind: MCPServer
metadata:
  name: test-mcp-server
  namespace: team-a
spec:
  source:
    type: ContainerImage
    containerImage:
      ref: ghcr.io/kuadrant/mcp-gateway/test-server1:latest
  config:
    port: 9090
    arguments: ["/mcp-test-server", "--http", "0.0.0.0:9090"]
  runtime:
    replicas: 1
EOF
```

**Verify:**

```bash
oc get mcpserver -n team-a
oc get pods -n team-a
```

**Status**: [x] Done

### 2.6 Add test-server-2 to the MCP Catalog

> **Note**: The `mcp-catalog-sources` ConfigMap needs `type: yaml` with a `yamlCatalogPath` — inline entries are not supported.
> Use a multi-key ConfigMap: `sources.yaml` for the index, and a second key for the actual catalog data.

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: mcp-catalog-sources
  namespace: odh-model-registries
data:
  sources.yaml: |
    mcp_catalogs:
      - name: Custom MCP Servers
        id: custom_mcp_servers
        type: yaml
        enabled: true
        properties:
          yamlCatalogPath: /data/user-mcp-sources/custom-mcp-servers.yaml
        labels:
          - Custom
    labels:
      - name: Custom
        assetType: mcp_servers
        displayName: Custom MCP servers
        description: Team-curated MCP servers for demo and testing.
  custom-mcp-servers.yaml: |
    source: Custom MCP
    mcp_servers:
      - name: test-server-2
        provider: Kuadrant
        license: apache-2.0
        license_link: https://www.apache.org/licenses/LICENSE-2.0
        description: A test MCP server with miscellaneous tools including greeting, time, authorization checking, and chocolate molding.
        version: latest
        transports:
          - http
        repositoryUrl: https://github.com/Kuadrant/mcp-gateway
        tools:
          - name: hello_world
            description: Say hello to someone
            parameters:
              - name: name
                type: string
                description: Name to greet
                required: true
          - name: time
            description: Get the current time
            parameters: []
          - name: headers
            description: Get HTTP headers
            parameters: []
          - name: auth1234
            description: Check authorization header
            parameters: []
          - name: slow
            description: Delay for N seconds
            parameters:
              - name: seconds
                type: integer
                description: Number of seconds to delay
                required: true
          - name: set_time
            description: Set the clock
            parameters:
              - name: time
                type: string
                description: Time to set
                required: true
          - name: pour_chocolate_into_mold
            description: Pour chocolate into mold
            parameters:
              - name: quantity
                type: string
                description: Quantity in milliliters
                required: true
        artifacts:
          - uri: oci://ghcr.io/kuadrant/mcp-gateway/test-server2:latest
        runtimeMetadata:
          defaultPort: 9090
          mcpPath: /mcp
EOF
```

**Status**: [x] Done

### 2.7 Test Server 2 — deploy via catalog

> **Note**: test-server2 uses `MCP_TRANSPORT` and `PORT` env vars (not CLI flags) to configure transport mode.
> Without `MCP_TRANSPORT=http`, it defaults to stdio and exits immediately.

If deploying from the catalog UI, set the env vars in the deployment config. Or apply the MCPServer CR directly:

```bash
oc apply -f - <<'EOF'
apiVersion: mcp.x-k8s.io/v1alpha1
kind: MCPServer
metadata:
  name: test-server-2
  namespace: team-a
spec:
  source:
    type: ContainerImage
    containerImage:
      ref: ghcr.io/kuadrant/mcp-gateway/test-server2:latest
  config:
    port: 9090
    arguments: ["/mcp-test-server"]
    env:
      - name: MCP_TRANSPORT
        value: "http"
      - name: PORT
        value: "9090"
  runtime:
    replicas: 1
EOF
```

**Verify:**

```bash
oc logs deployment/test-server-2 -n team-a --tail=3
# Should show: "Serving HTTPStreamable on http://localhost:9090/mcp"
```

**Status**: [x] Done

---

## Step 3: MCP Gateway + Registration + Auth + Curation

### 3.1 Deploy MCP Gateway instance

> The controller is already installed cluster-wide via OLM in `mcp-system`.
> We only deploy the gateway instance (Gateway + MCPGatewayExtension + broker) via Helm.

```bash
helm upgrade -i team-a-gateway oci://ghcr.io/kuadrant/charts/mcp-gateway \
  --version 0.6.0 --namespace team-a --skip-crds \
  --set controller.enabled=false \
  --set gateway.create=true \
  --set gateway.name=team-a-gateway \
  --set gateway.namespace=team-a \
  --set gateway.publicHost="team-a-mcp.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com" \
  --set gateway.internalHostPattern="*.mcp.local" \
  --set gateway.gatewayClassName="openshift-default" \
  --set mcpGatewayExtension.create=true \
  --set mcpGatewayExtension.gatewayRef.name=team-a-gateway \
  --set mcpGatewayExtension.gatewayRef.namespace=team-a \
  --set mcpGatewayExtension.gatewayRef.sectionName=mcp
```

**Status**: [x] Done

### 3.2 Create OpenShift Route

> The `mcp-gateway-ingress` chart is not published to an OCI registry — must be installed from the mcp-gateway git repo clone.

```bash
helm upgrade -i team-a-gateway-ingress \
  /path/to/mcp-gateway/config/openshift/charts/mcp-gateway-ingress \
  --namespace team-a \
  --set mcpGateway.host="team-a-mcp.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com" \
  --set mcpGateway.namespace=team-a \
  --set gateway.name=team-a-gateway \
  --set gateway.class="openshift-default" \
  --set route.create=true
```

**Verify:**

```bash
oc get gateway -n team-a
# Should show: team-a-gateway, Programmed=True

oc get mcpgatewayextension -n team-a
# Should show: Ready=True

oc get route -n team-a
# Should show: team-a-mcp.apps.rosa...

oc get pods -n team-a
# Should see: mcp-gateway pod (broker), team-a-gateway-openshift-default pod (Envoy)
```

**Status**: [x] Done

### 3.3 Register OpenShift MCP Server with gateway

```bash
oc apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openshift-mcp-server
  namespace: team-a
spec:
  parentRefs:
    - name: team-a-gateway
      sectionName: mcps
  hostnames:
    - "openshift-mcp-server.mcp.local"
  rules:
    - backendRefs:
        - name: openshift-mcp-server
          port: 8080
---
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPServerRegistration
metadata:
  name: openshift-mcp-server
  namespace: team-a
spec:
  toolPrefix: "openshift_"
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: openshift-mcp-server
EOF
```

**Status**: [x] Done — 14 tools registered with `openshift_` prefix

### 3.4 Register Test MCP Server with gateway

```bash
oc apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: test-mcp-server
  namespace: team-a
spec:
  parentRefs:
    - name: team-a-gateway
      sectionName: mcps
  hostnames:
    - "test-mcp-server.mcp.local"
  rules:
    - backendRefs:
        - name: test-mcp-server
          port: 9090
---
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPServerRegistration
metadata:
  name: test-mcp-server
  namespace: team-a
spec:
  toolPrefix: "test_"
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: test-mcp-server
EOF
```

**Verify (before auth is applied):**

```bash
GATEWAY_URL="https://team-a-mcp.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com/mcp"

# Initialize — capture session ID
SESSION_ID=$(curl -si -X POST "$GATEWAY_URL" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
    "protocolVersion":"2025-03-26",
    "capabilities":{},
    "clientInfo":{"name":"demo","version":"1.0"}
  }}' | grep -i mcp-session-id | awk '{print $2}' | tr -d '\r')

echo "Session: $SESSION_ID"

# tools/list — should show openshift_* + test_* tools
curl -s -X POST "$GATEWAY_URL" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | python3 -m json.tool
```

**Status**: [x] Done — 5 tools registered with `test_` prefix

### 3.4.1 Register Test Server 2 with gateway

```bash
oc apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: test-server-2
  namespace: team-a
spec:
  parentRefs:
    - name: team-a-gateway
      sectionName: mcps
  hostnames:
    - "test-server-2.mcp.local"
  rules:
    - backendRefs:
        - name: test-server-2
          port: 9090
---
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPServerRegistration
metadata:
  name: test-server-2
  namespace: team-a
spec:
  toolPrefix: "test2_"
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: test-server-2
EOF
```

**Status**: [x] Done — 7 tools registered with `test2_` prefix

### 3.5 Gateway-level AuthPolicy (JWT validation + VirtualMCPServer selection)

> **Note**: Use `expression` (not `value`) for the VirtualMCPServer header — `value` sends the CEL as a literal string instead of evaluating it.

```bash
oc apply -f - <<'EOF'
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: team-a-gateway-auth
  namespace: team-a
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: team-a-gateway
    sectionName: mcp
  defaults:
    rules:
      authentication:
        keycloak-jwt:
          jwt:
            issuerUrl: https://keycloak.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com/realms/mcp-gateway
      response:
        success:
          headers:
            x-mcp-virtualserver:
              plain:
                expression: |
                  auth.identity.realm_access.roles.exists(r, r == 'mcp-admin')
                    ? 'team-a/admin-tools'
                    : 'team-a/user-tools'
EOF
```

**Verify:**

```bash
oc get authpolicy -n team-a
# Should show: team-a-gateway-auth, Accepted=True Enforced=True
```

**Status**: [x] Done

### 3.6 VirtualMCPServers (tool visibility per role)

> **Note**: The CRD kind is `MCPVirtualServer` (not `VirtualMCPServer`). The spec only has `tools` and `description` — no `gatewayRef`.

```bash
oc apply -f - <<'EOF'
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPVirtualServer
metadata:
  name: admin-tools
  namespace: team-a
spec:
  description: "Full access — OpenShift + all test tools"
  tools:
    # OpenShift tools (14)
    - openshift_configuration_view
    - openshift_events_list
    - openshift_namespaces_list
    - openshift_nodes_log
    - openshift_nodes_stats_summary
    - openshift_nodes_top
    - openshift_pods_get
    - openshift_pods_list
    - openshift_pods_list_in_namespace
    - openshift_pods_log
    - openshift_pods_top
    - openshift_projects_list
    - openshift_resources_get
    - openshift_resources_list
    # Test server 1 tools (5)
    - test_add_tool
    - test_greet
    - test_headers
    - test_slow
    - test_time
    # Test server 2 tools (7)
    - test2_hello_world
    - test2_time
    - test2_headers
    - test2_auth1234
    - test2_slow
    - test2_set_time
    - test2_pour_chocolate_into_mold
---
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPVirtualServer
metadata:
  name: user-tools
  namespace: team-a
spec:
  description: "Test tools only — no OpenShift access"
  tools:
    # Test server 1 tools (5)
    - test_add_tool
    - test_greet
    - test_headers
    - test_slow
    - test_time
    # Test server 2 tools (7)
    - test2_hello_world
    - test2_time
    - test2_headers
    - test2_auth1234
    - test2_slow
    - test2_set_time
    - test2_pour_chocolate_into_mold
EOF
```

**Verify:**

```bash
oc get mcpvirtualserver -n team-a
```

**Status**: [x] Done

### 3.6.1 Workaround: VirtualMCPServer namespace bug

> **Known issue**: The MCPVirtualServer controller writes virtualServers config to the `mcp-system/mcp-gateway-config` Secret (hardcoded `DefaultNamespaceName`) instead of per-gateway namespace Secrets. Per-namespace gateway brokers read from their own namespace and never see the VirtualMCPServer config. There is an open upstream issue for this.

**Workaround**: Manually merge virtualServers into the team-a broker config Secret.

```bash
# Export current config
oc get secret mcp-gateway-config -n team-a -o jsonpath='{.data.config\.yaml}' | base64 -d > /tmp/broker-config.yaml

# Append virtualServers section
cat >> /tmp/broker-config.yaml <<'VSEOF'
virtualServers:
  - name: admin-tools
    namespace: team-a
    tools:
      - openshift_configuration_view
      - openshift_events_list
      - openshift_namespaces_list
      - openshift_nodes_log
      - openshift_nodes_stats_summary
      - openshift_nodes_top
      - openshift_pods_get
      - openshift_pods_list
      - openshift_pods_list_in_namespace
      - openshift_pods_log
      - openshift_pods_top
      - openshift_projects_list
      - openshift_resources_get
      - openshift_resources_list
      - test_add_tool
      - test_greet
      - test_headers
      - test_slow
      - test_time
      - test2_hello_world
      - test2_time
      - test2_headers
      - test2_auth1234
      - test2_slow
      - test2_set_time
      - test2_pour_chocolate_into_mold
  - name: user-tools
    namespace: team-a
    tools:
      - test_add_tool
      - test_greet
      - test_headers
      - test_slow
      - test_time
      - test2_hello_world
      - test2_time
      - test2_headers
      - test2_auth1234
      - test2_slow
      - test2_set_time
      - test2_pour_chocolate_into_mold
VSEOF

# Replace the Secret
oc create secret generic mcp-gateway-config -n team-a \
  --from-file=config.yaml=/tmp/broker-config.yaml \
  --dry-run=client -o yaml | oc apply -f -

# Restart broker to pick up new config
oc rollout restart deployment/mcp-gateway -n team-a
oc rollout status deployment/mcp-gateway -n team-a
```

**Status**: [x] Done

### 3.7 Per-server AuthPolicy (OpenShift tools — admin only, with header stripping)

> **Note**: The `response.success.headers.authorization` section strips the JWT Authorization header after validation, before the request is forwarded to the upstream MCP server. Without this, Llama Stack's JWT gets passed through to the OpenShift MCP server, which doesn't expect it and causes the model to refuse tool calls ("cluster requires authentication").

```bash
oc apply -f - <<'EOF'
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: openshift-mcp-admin-only
  namespace: team-a
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: openshift-mcp-server
  rules:
    authentication:
      keycloak-jwt:
        jwt:
          issuerUrl: https://keycloak.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com/realms/mcp-gateway
    authorization:
      admin-only:
        patternMatching:
          patterns:
            - selector: auth.identity.realm_access.roles
              operator: incl
              value: mcp-admin
    response:
      success:
        headers:
          authorization:
            plain:
              value: ""
EOF
```

**Verify:**

```bash
oc get authpolicy -n team-a
# Should show both: team-a-gateway-auth and openshift-mcp-admin-only, both Enforced=True
```

**Status**: [x] Done

### 3.8 Verify auth + tool filtering

```bash
GATEWAY_URL="https://team-a-mcp.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com/mcp"
KEYCLOAK_URL="https://keycloak.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com/realms/mcp-gateway/protocol/openid-connect/token"

# --- Get tokens ---
ADMIN_TOKEN=$(curl -s -X POST "$KEYCLOAK_URL" \
  -d "grant_type=password&client_id=mcp-playground&username=mcp-admin1&password=admin1pass" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

USER_TOKEN=$(curl -s -X POST "$KEYCLOAK_URL" \
  -d "grant_type=password&client_id=mcp-playground&username=mcp-user1&password=user1pass" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# --- Admin flow ---
ADMIN_SESSION=$(curl -si -X POST "$GATEWAY_URL" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
    "protocolVersion":"2025-03-26","capabilities":{},
    "clientInfo":{"name":"demo","version":"1.0"}
  }}' | grep -i mcp-session-id | awk '{print $2}' | tr -d '\r')

# Admin: tools/list — expect ALL tools (openshift_* + test_*)
curl -s -X POST "$GATEWAY_URL" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Mcp-Session-Id: $ADMIN_SESSION" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | python3 -m json.tool

# Admin: tools/call openshift tool — expect SUCCESS
curl -s -X POST "$GATEWAY_URL" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Mcp-Session-Id: $ADMIN_SESSION" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{
    "name":"openshift_pods_list_in_namespace",
    "arguments":{"namespace":"team-a"}
  }}' | python3 -m json.tool

# --- User flow ---
USER_SESSION=$(curl -si -X POST "$GATEWAY_URL" \
  -H "Authorization: Bearer $USER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
    "protocolVersion":"2025-03-26","capabilities":{},
    "clientInfo":{"name":"demo","version":"1.0"}
  }}' | grep -i mcp-session-id | awk '{print $2}' | tr -d '\r')

# User: tools/list — expect ONLY test_* tools
curl -s -X POST "$GATEWAY_URL" \
  -H "Authorization: Bearer $USER_TOKEN" \
  -H "Mcp-Session-Id: $USER_SESSION" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | python3 -m json.tool

# User: tools/call openshift tool — expect BLOCKED (403)
curl -s -X POST "$GATEWAY_URL" \
  -H "Authorization: Bearer $USER_TOKEN" \
  -H "Mcp-Session-Id: $USER_SESSION" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{
    "name":"openshift_pods_list_in_namespace",
    "arguments":{"namespace":"team-a"}
  }}' | python3 -m json.tool

# User: tools/call test tool — expect SUCCESS
curl -s -X POST "$GATEWAY_URL" \
  -H "Authorization: Bearer $USER_TOKEN" \
  -H "Mcp-Session-Id: $USER_SESSION" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{
    "name":"test_greet",
    "arguments":{"name":"team-a"}
  }}' | python3 -m json.tool
```

**Expected results:**

| User | tools/list | openshift_* call | test_* call |
|------|-----------|-----------------|-------------|
| mcp-admin1 | All 26 tools | Allowed | Allowed |
| mcp-user1 | Only 12 test tools | Blocked (403) | Allowed |

**Status**: [x] Done — all checks pass (admin: 26 tools, user: 12 tools, RBAC enforced)

---

## Step 4: Add Gateway Endpoint to RHOAI ConfigMap

> **Note**: This overwrites the existing ConfigMap. If other entries need to be preserved, merge them into the `data` section.

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: gen-ai-aa-mcp-servers
  namespace: redhat-ods-applications
data:
  Team-A-MCP-Gateway: |
    {
      "url": "https://team-a-mcp.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com/mcp",
      "description": "Team-A MCP Gateway — OpenShift + test tools"
    }
EOF
```

**Verify:**

```bash
oc get configmap gen-ai-aa-mcp-servers -n redhat-ods-applications -o yaml
```

**Status**: [x] Done

---

## Step 5: View and Select in Gen AI Studio

**Actions (UI)**:
1. Open Gen AI Studio in RHOAI Dashboard
2. Navigate to AI Asset Endpoints — confirm Team-A MCP Gateway is visible
3. Open the Playground
4. Select the MCP server as a tool source
5. Click the auth icon and paste an `mcp-admin1` token:

```bash
curl -s -X POST \
  "https://keycloak.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com/realms/mcp-gateway/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=mcp-playground&username=mcp-admin1&password=admin1pass" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
```

**Resources created**: None

**Status**: [x] Done

---

## Step 6: Execute a Tool Call

**Actions (UI)**:
1. In the Playground, type: **"List the pods running in the team-a namespace"**
2. Observe the model invoke `openshift_pods_list_in_namespace` through the MCP Gateway
3. See real cluster data returned in the Playground

**Full request chain:**
```
Playground UI
  → (Bearer JWT from Keycloak)
Llama Stack (v0.6.0.1+rhai0)
  → MCP Gateway (team-a-gateway, v0.6.0)
  → Authorino (JWT validation + role check)
  → OpenShift MCP Server
  → Kubernetes API
  → Results back to Playground
```

**Resources created**: None

**Status**: [x] Done — admin: OpenShift tool calls succeed through Playground; user: restricted to test tools only

---

## Cleanup

To tear down the demo and start fresh:

```bash
# Helm releases
helm uninstall team-a-gateway -n team-a
helm uninstall team-a-gateway-ingress -n team-a

# Delete team-a namespace (removes all namespaced resources)
oc delete namespace team-a

# Delete cluster-scoped resources
oc delete clusterrolebinding team-a-ocp-mcp-view

# Remove from RHOAI ConfigMap
oc delete configmap gen-ai-aa-mcp-servers -n redhat-ods-applications
```

---

## Future Additions

- **Vault credential injection** — per-user or per-team secrets injected via AuthPolicy metadata evaluators into MCP server requests
- **GitHub MCP Server** — add to catalog, deploy via lifecycle operator, register with same team-a gateway (demonstrates multi-server catalog + deployment)

---

## Lessons Learned

1. **config.toml needs `port`** — Without `port = "8080"`, the server starts in stdio mode, reads EOF, and exits immediately.
2. **`denied_resources` uses inline table array syntax** — Must be `denied_resources = [{group="", version="v1", kind="Secret"}, ...]`. TOML section syntax (`[denied_resources]`) causes a type mismatch error (`map[string]any` vs `slice`).
3. **Lifecycle operator does not create RBAC** — ServiceAccount + ClusterRoleBinding for cluster read access must be created before deploying the MCPServer CR.
4. **Lifecycle operator does not create gateway resources** — HTTPRoute + MCPServerRegistration are separate from the MCPServer lifecycle. The operator manages Deployment + Service only.
5. **MCPServer `arguments` maps to container `args`** — The lifecycle operator puts `config.arguments` into the container's `args` field. If the image has no ENTRYPOINT, this becomes the command. Include the binary path as the first element (e.g., `["/mcp-test-server", "--http", "0.0.0.0:9090"]`). If the image has an ENTRYPOINT, the binary will be doubled — use env vars instead.
6. **MCPVirtualServer controller namespace bug** — The controller writes virtualServers config to `mcp-system/mcp-gateway-config` (hardcoded) instead of per-gateway namespace Secrets. Per-namespace brokers never see the config. Workaround: manually merge virtualServers into the per-namespace broker config Secret.
7. **AuthPolicy `expression` vs `value`** — Use `plain.expression` for CEL expressions that should be evaluated at runtime. `plain.value` sends the CEL text as a literal string header.
8. **CRD kind is `MCPVirtualServer`** — Not `VirtualMCPServer`. The spec only has `tools` and `description` — no `gatewayRef`.
9. **Strip Authorization header on per-server AuthPolicy** — When Llama Stack forwards tool calls through the MCP Gateway, the user's JWT rides along as the Authorization header. If the upstream MCP server (e.g., OpenShift MCP) receives this JWT, it can't use it and the model refuses to call tools. Fix: add `response.success.headers.authorization` with `plain.value: ""` to strip the header after Authorino validates it.
10. **Adding custom MCP servers to the RHOAI catalog** — Edit the `mcp-catalog-sources` ConfigMap in `odh-model-registries`. The ConfigMap needs two keys: `sources.yaml` (catalog index with `type: yaml` pointing to a `yamlCatalogPath`) and the actual catalog YAML file. Using `type: inline` with `mcp_servers` nested under the catalog entry does NOT work — the loader rejects unknown fields. The catalog file format must match the built-in catalogs: `source`, `mcp_servers` list with `name`, `provider`, `description`, `tools`, `artifacts` (OCI URI), and `runtimeMetadata` (`defaultPort`, `mcpPath`, `defaultArgs`). Example:

  ```yaml
    # ConfigMap keys:
    #   sources.yaml — references /data/user-mcp-sources/custom-mcp-servers.yaml
    #   custom-mcp-servers.yaml — actual catalog entries (same format as redhat-mcp-servers-catalog.yaml)
  ```
11. **MCP servers may use env vars, not CLI flags** — test-server2 uses `MCP_TRANSPORT` and `PORT` env vars (not `--http` flag). Without `MCP_TRANSPORT=http`, it defaults to stdio and exits. Use `config.env` in the MCPServer CR to set these.

---

## Resource Inventory

| Step | Resource | Kind | Scope | Count |
|------|----------|------|-------|-------|
| 2.1 | team-a | Namespace | cluster | 1 |
| 2.2 | openshift-mcp-server | ServiceAccount | team-a | 1 |
| 2.2 | team-a-ocp-mcp-view | ClusterRoleBinding | cluster | 1 |
| 2.3 | openshift-mcp-server-config | ConfigMap | team-a | 1 |
| 2.4 | openshift-mcp-server | MCPServer | team-a | 1 |
| 2.5 | test-mcp-server | MCPServer | team-a | 1 |
| 2.6 | mcp-catalog-sources | ConfigMap | odh-model-registries | 1 |
| 2.7 | test-server-2 | MCPServer | team-a | 1 |
| 3.1 | team-a-gateway | Gateway | team-a | 1 |
| 3.1 | team-a-gateway | MCPGatewayExtension | team-a | 1 |
| 3.2 | team-a-mcp | Route | team-a | 1 |
| 3.3 | openshift-mcp-server | HTTPRoute | team-a | 1 |
| 3.3 | openshift-mcp-server | MCPServerRegistration | team-a | 1 |
| 3.4 | test-mcp-server | HTTPRoute | team-a | 1 |
| 3.4 | test-mcp-server | MCPServerRegistration | team-a | 1 |
| 3.4.1 | test-server-2 | HTTPRoute | team-a | 1 |
| 3.4.1 | test-server-2 | MCPServerRegistration | team-a | 1 |
| 3.5 | team-a-gateway-auth | AuthPolicy | team-a | 1 |
| 3.6 | admin-tools | MCPVirtualServer | team-a | 1 |
| 3.6 | user-tools | MCPVirtualServer | team-a | 1 |
| 3.7 | openshift-mcp-admin-only | AuthPolicy | team-a | 1 |
| 4 | gen-ai-aa-mcp-servers | ConfigMap | redhat-ods-applications | 1 |
| **Total** | | | | **22** |
