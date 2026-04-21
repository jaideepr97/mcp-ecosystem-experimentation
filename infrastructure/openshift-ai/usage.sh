#!/usr/bin/env bash
# =============================================================================
# MCP Ecosystem — Usage Demo
# =============================================================================
# Three-phase walkthrough demonstrating the MCP ecosystem end-to-end.
# Each phase adds a new MCP server: discover → deploy → register → auth.
# Each server gets dual-layer tool filtering:
#   1. VirtualMCPServer — coarse group-based curation (x-mcp-virtualserver)
#   2. Wristband — fine-grained per-user ACLs via Keycloak resource_access (x-authorized-tools)
# The visible tools are the INTERSECTION of both layers.
#
#   Phase 1: OpenShift MCP Server (mcp-admin1 — admin group)
#            Deploy, register, auth + curation + wristband, Playground
#
#   Phase 2: Test Servers (mcp-user1 — user group)
#            Add to catalog, deploy, register, dual-layer tool filtering
#
#   Phase 3: GitHub MCP Server (mcp-github1 — github group)
#            Deploy with Vault credential injection, per-user PATs, wristband
#
# Prerequisites:
#   - ./setup.sh has been run (all infrastructure in place)
#   - python3 available (for JSON parsing)
#
# Usage:
#   ./usage.sh                   # run all phases
#   ./usage.sh --phase 2         # start from phase 2
#   ./usage.sh --phase 1 --only  # run only phase 1
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
START_PHASE="${START_PHASE:-1}"
ONLY_PHASE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --phase) START_PHASE="$2"; shift 2 ;;
    --only)  ONLY_PHASE=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Cluster-specific values ---
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com}"
KEYCLOAK_HOST="keycloak.${CLUSTER_DOMAIN}"
GATEWAY_HOST="team-a-mcp.${CLUSTER_DOMAIN}"
GATEWAY_URL="https://${GATEWAY_HOST}/mcp"
TOKEN_URL="https://${KEYCLOAK_HOST}/realms/mcp-gateway/protocol/openid-connect/token"

header()   { echo ""; echo "══════════════════════════════════════════════════════════════"; echo "  $1"; echo "══════════════════════════════════════════════════════════════"; }
step()     { echo ""; echo "── $1"; }
ok()       { echo "   ✓ $1"; }
pause()    { echo ""; read -rp "   ⏎ Press Enter to continue... " < /dev/tty; }
ui_step()  { echo "   🖥  UI: $1"; }
should_run() { local phase=$1; [[ $phase -ge $START_PHASE ]] && { $ONLY_PHASE && [[ $phase -ne $START_PHASE ]] && return 1; return 0; }; }
wait_for() {
  local what="$1" cmd="$2" timeout="${3:-120}"
  echo -n "   Waiting for $what..."
  local i=0
  while ! eval "$cmd" &>/dev/null; do
    sleep 5; i=$((i+5))
    if [ $i -ge $timeout ]; then echo " TIMEOUT"; return 1; fi
    echo -n "."
  done
  echo " ready"
}

get_token() {
  local user="$1" pass="$2"
  curl -sk -X POST "$TOKEN_URL" \
    -d "grant_type=password&client_id=mcp-playground&username=${user}&password=${pass}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

mcp_init() {
  local token="$1"
  curl -sk -X POST "$GATEWAY_URL" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
      "protocolVersion":"2025-03-26","capabilities":{},
      "clientInfo":{"name":"demo","version":"1.0"}
    }}' -i 2>/dev/null | grep -i mcp-session-id | awk '{print $2}' | tr -d '\r'
}

mcp_tools_list() {
  local token="$1" session="$2"
  curl -sk -X POST "$GATEWAY_URL" \
    -H "Authorization: Bearer $token" \
    -H "Mcp-Session-Id: $session" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
}

mcp_tool_call() {
  local token="$1" session="$2" tool="$3" args="$4"
  curl -sk -X POST "$GATEWAY_URL" \
    -H "Authorization: Bearer $token" \
    -H "Mcp-Session-Id: $session" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":$args}}"
}

# --- Keycloak helpers for wristband tool filtering ---
# Each MCPServerRegistration gets a matching Keycloak client whose roles
# are the UNPREFIXED tool names. The AuthPolicy OPA extracts resource_access
# from the JWT to build the wristband allowed-tools map.

kc_admin_token() {
  if [ -z "${KC_TOKEN:-}" ]; then
    local kc_admin="${KEYCLOAK_ADMIN:-temp-admin}"
    local kc_pass="${KEYCLOAK_ADMIN_PASSWORD:-}"
    if [ -z "$kc_pass" ]; then
      kc_pass=$(oc get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d)
    fi
    KC_TOKEN=$(curl -sk -X POST "https://${KEYCLOAK_HOST}/realms/master/protocol/openid-connect/token" \
      -d "grant_type=password&client_id=admin-cli&username=${kc_admin}&password=${kc_pass}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
  fi
  echo "$KC_TOKEN"
}

kc_create_client() {
  local client_id="$1" token
  token=$(kc_admin_token)
  curl -sk -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    "https://${KEYCLOAK_HOST}/admin/realms/mcp-gateway/clients" \
    -d "{\"clientId\":\"$client_id\",\"enabled\":true,\"publicClient\":false,\"bearerOnly\":true}" \
    -o /dev/null -w ""
}

kc_get_client_uuid() {
  local client_id="$1" token encoded
  token=$(kc_admin_token)
  encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$client_id', safe=''))")
  curl -sk -H "Authorization: Bearer $token" \
    "https://${KEYCLOAK_HOST}/admin/realms/mcp-gateway/clients?clientId=${encoded}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')"
}

kc_create_role() {
  local client_uuid="$1" role_name="$2" token
  token=$(kc_admin_token)
  curl -sk -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    "https://${KEYCLOAK_HOST}/admin/realms/mcp-gateway/clients/${client_uuid}/roles" \
    -d "{\"name\":\"$role_name\"}" -o /dev/null -w ""
}

kc_get_user_id() {
  local username="$1" token
  token=$(kc_admin_token)
  curl -sk -H "Authorization: Bearer $token" \
    "https://${KEYCLOAK_HOST}/admin/realms/mcp-gateway/users?username=$username&exact=true" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])"
}

kc_assign_roles() {
  local user_id="$1" client_uuid="$2" token
  shift 2
  token=$(kc_admin_token)
  local roles_json="["
  local first=true
  for role_name in "$@"; do
    local encoded role_json
    encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$role_name', safe=''))")
    role_json=$(curl -sk -H "Authorization: Bearer $token" \
      "https://${KEYCLOAK_HOST}/admin/realms/mcp-gateway/clients/${client_uuid}/roles/${encoded}")
    if [ "$first" = true ]; then first=false; else roles_json+=","; fi
    roles_json+="$role_json"
  done
  roles_json+="]"
  curl -sk -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    "https://${KEYCLOAK_HOST}/admin/realms/mcp-gateway/users/${user_id}/role-mappings/clients/${client_uuid}" \
    -d "$roles_json" -o /dev/null -w ""
}

# =============================================================================
# Phase 1: OpenShift MCP Server (mcp-admin1)
# =============================================================================
if should_run 1; then
  header "Phase 1: OpenShift MCP Server"
  echo "  Deploy the OpenShift MCP server, register it with the gateway,"
  echo "  apply auth + tool curation, and use it from the Playground."
  echo "  User: mcp-admin1 (group: mcp-admins)"

  # --- 1.1 Discover ---
  step "1.1 Discover — browse the MCP Catalog"
  ui_step "Open RHOAI Dashboard → MCP Catalog"
  ui_step "Locate the OpenShift MCP Server (pre-populated in RHOAI 3.4)"
  ui_step "View metadata: description, capabilities, container image"
  pause

  # --- 1.2 Deploy ---
  step "1.2 Deploy — RBAC + config + MCPServer CR"

  echo "   Creating ServiceAccount + ClusterRoleBinding (cluster read access)..."
  oc apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: openshift-mcp-server
  namespace: team-a
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: team-a-ocp-mcp-view
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
  - kind: ServiceAccount
    name: openshift-mcp-server
    namespace: team-a
EOF
  ok "RBAC created"

  echo "   Creating config (read-only, core+config toolsets, denied RBAC resources)..."
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
  ok "ConfigMap created"

  echo "   Deploying MCPServer CR (lifecycle operator creates Deployment + Service)..."
  oc apply -f - <<'EOF'
apiVersion: mcp.x-k8s.io/v1alpha1
kind: MCPServer
metadata:
  name: openshift-mcp-server
  namespace: team-a
  annotations:
    mcp.opendatahub.io/catalog-server: openshift-mcp-server
    mcp.opendatahub.io/display-name: openshift-mcp-server
spec:
  source:
    type: ContainerImage
    containerImage:
      ref: registry.redhat.io/openshift-mcp-beta/openshift-mcp-server-rhel9:0.2
  config:
    port: 8080
    path: /mcp
    arguments: ["--config", "/etc/mcp-config/config.toml"]
    storage:
      - path: /etc/mcp-config
        permissions: ReadOnly
        source:
          type: ConfigMap
          configMap:
            name: openshift-mcp-server-config
  runtime:
    security:
      serviceAccountName: openshift-mcp-server
EOF
  wait_for "OpenShift MCP server" "oc get mcpserver openshift-mcp-server -n team-a -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running" 180
  ok "OpenShift MCP server running (14 tools)"

  # --- 1.3 Register ---
  step "1.3 Register — HTTPRoute + MCPServerRegistration"
  oc apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openshift-mcp-server
  namespace: team-a
spec:
  hostnames: ["openshift-mcp-server.mcp.local"]
  parentRefs:
    - name: team-a-gateway
      sectionName: mcps
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
  toolPrefix: openshift_
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: openshift-mcp-server
EOF
  wait_for "registration" "oc get mcpserverregistration openshift-mcp-server -n team-a -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True" 60
  TOOLS=$(oc get mcpserverregistration openshift-mcp-server -n team-a -o jsonpath='{.status.discoveredTools}')
  ok "Registered with gateway — ${TOOLS} tools with openshift_ prefix"

  # --- 1.4 Auth + Curation ---
  step "1.4 Auth + Curation — AuthPolicy + VirtualMCPServer + wristband"

  echo "   Creating admin-tools VirtualMCPServer (all OpenShift tools)..."
  oc apply -f - <<'EOF'
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPVirtualServer
metadata:
  name: admin-tools
  namespace: team-a
spec:
  description: OpenShift tools for mcp-admins group
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
EOF
  ok "admin-tools VirtualMCPServer created (14 tools)"

  echo "   Creating wristband client + roles for openshift-mcp-server..."
  kc_create_client "team-a/openshift-mcp-server"
  OCP_CLIENT_UUID=$(kc_get_client_uuid "team-a/openshift-mcp-server")
  for role in configuration_view events_list namespaces_list nodes_log nodes_stats_summary \
              nodes_top pods_get pods_list pods_list_in_namespace pods_log pods_top \
              projects_list resources_get resources_list; do
    kc_create_role "$OCP_CLIENT_UUID" "$role"
  done
  ok "Keycloak client team-a/openshift-mcp-server with 14 tool roles"

  echo "   Assigning OpenShift tool roles to mcp-admin1..."
  ADMIN1_ID=$(kc_get_user_id "mcp-admin1")
  kc_assign_roles "$ADMIN1_ID" "$OCP_CLIENT_UUID" \
    namespaces_list pods_list pods_list_in_namespace pods_log projects_list
  ok "mcp-admin1: namespaces_list, pods_list, pods_list_in_namespace, pods_log, projects_list"

  echo "   Applying gateway-level AuthPolicy (JWT + wristband + VirtualMCPServer routing)..."
  oc apply -f - <<EOF
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
    strategy: atomic
    rules:
      authentication:
        keycloak-jwt:
          jwt:
            issuerUrl: https://${KEYCLOAK_HOST}/realms/mcp-gateway
      authorization:
        authorized-tools:
          opa:
            allValues: true
            rego: |
              allow = true
              tools = { server: roles |
                server := object.keys(input.auth.identity.resource_access)[_]
                roles := object.get(input.auth.identity.resource_access, server, {}).roles
              }
      response:
        success:
          headers:
            x-authorized-tools:
              wristband:
                issuer: authorino
                signingKeyRefs:
                  - name: trusted-headers-private-key
                    algorithm: ES256
                tokenDuration: 300
                customClaims:
                  allowed-tools:
                    selector: auth.authorization.authorized-tools.tools.@tostr
            x-mcp-virtualserver:
              plain:
                expression: |
                  auth.identity.groups.exists(g, g == 'mcp-admins')
                    ? 'team-a/admin-tools'
                    : 'team-a/admin-tools'
EOF
  ok "Gateway auth applied (wristband + VirtualMCPServer, all users → admin-tools for now)"

  echo "   Applying per-server AuthPolicy (OpenShift tools — admin only)..."
  oc apply -f - <<EOF
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
          issuerUrl: https://${KEYCLOAK_HOST}/realms/mcp-gateway
    authorization:
      admin-only:
        patternMatching:
          patterns:
            - selector: auth.identity.groups
              operator: incl
              value: mcp-admins
    response:
      success:
        headers:
          authorization:
            plain:
              value: ""
EOF
  wait_for "AuthPolicies enforced" "oc get authpolicy team-a-gateway-auth -n team-a -o jsonpath='{.status.conditions[?(@.type==\"Enforced\")].status}' 2>/dev/null | grep -q True" 60
  ok "AuthPolicies enforced"

  # --- 1.5 RHOAI ConfigMap ---
  step "1.5 Add gateway to RHOAI ConfigMap"
  oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: gen-ai-aa-mcp-servers
  namespace: redhat-ods-applications
data:
  Team-A-MCP-Gateway: |
    {
      "url": "https://${GATEWAY_HOST}/mcp",
      "description": "Team-A MCP Gateway — OpenShift + test tools"
    }
EOF
  ok "gen-ai-aa-mcp-servers ConfigMap updated"

  # --- 1.6 Use ---
  step "1.6 Use — verify as mcp-admin1"
  echo "   Getting admin token..."
  ADMIN_TOKEN=$(get_token "mcp-admin1" "admin1pass")
  ADMIN_SESSION=$(mcp_init "$ADMIN_TOKEN")
  echo "   Session: $ADMIN_SESSION"

  echo ""
  echo "   tools/list as mcp-admin1 (intersection of VirtualMCPServer + wristband):"
  TOOLS_JSON=$(mcp_tools_list "$ADMIN_TOKEN" "$ADMIN_SESSION")
  TOOL_COUNT=$(echo "$TOOLS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('result',{}).get('tools',[])))" 2>/dev/null || echo "?")
  echo "   → $TOOL_COUNT tools visible"
  echo "$TOOLS_JSON" | python3 -c "
import sys,json
tools = json.load(sys.stdin).get('result',{}).get('tools',[])
for t in tools[:5]:
    print(f'     - {t[\"name\"]}')
if len(tools) > 5:
    print(f'     ... and {len(tools)-5} more')
" 2>/dev/null || true
  echo "   (VirtualMCPServer has 14 tools, wristband allows 5 → intersection = 5)"

  echo ""
  echo "   tools/call openshift_pods_list_in_namespace(namespace=team-a) as mcp-admin1:"
  CALL_RESULT=$(mcp_tool_call "$ADMIN_TOKEN" "$ADMIN_SESSION" "openshift_pods_list_in_namespace" '{"namespace":"team-a"}')
  echo "$CALL_RESULT" | python3 -c "
import sys,json
r = json.load(sys.stdin)
if 'result' in r:
    print('   → Success — pods returned')
elif 'error' in r:
    print(f'   → Error: {r[\"error\"][\"message\"]}')
" 2>/dev/null || echo "   → (check response manually)"
  ok "Phase 1 complete — OpenShift MCP server accessible to mcp-admin1"

  step "1.7 Use in Playground"
  ui_step "Open Gen AI Studio → Playground"
  ui_step "Select Team-A MCP Gateway as tool source"
  ui_step "Paste an mcp-admin1 token (printed below) into the auth field"
  echo ""
  echo "   Token for mcp-admin1:"
  echo "   $(get_token 'mcp-admin1' 'admin1pass')"
  echo ""
  ui_step "Ask: 'List the pods running in the team-a namespace'"
  ui_step "Observe the model invoke openshift_pods_list_in_namespace"
  pause
fi

# =============================================================================
# Phase 2: Test Servers (mcp-user1)
# =============================================================================
if should_run 2; then
  header "Phase 2: Test Servers"
  echo "  Add test servers to the catalog, deploy them, register with the"
  echo "  gateway, and demonstrate tool filtering for regular users."
  echo "  User: mcp-user1 (group: mcp-users)"

  # --- 2.1 Catalog ---
  step "2.1 Add test-server-2 to the MCP Catalog"
  oc apply -f "${SCRIPT_DIR}/playground/mcp-catalog-sources.yaml"
  ok "Catalog sources updated (test-server-2 + github-mcp-server added)"

  ui_step "Open RHOAI Dashboard → MCP Catalog → see test-server-2"
  pause

  # --- 2.2 Deploy ---
  step "2.2 Deploy test servers via MCPServer CRs"

  echo "   Deploying test-mcp-server (5 tools: add, greet, headers, slow, time)..."
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
    path: /mcp
    arguments: ["/mcp-test-server", "--http", "0.0.0.0:9090"]
  runtime:
    replicas: 1
EOF

  echo "   Deploying test-server-2 (7 tools: hello_world, time, headers, auth1234, slow, set_time, pour_chocolate)..."
  oc apply -f - <<'EOF'
apiVersion: mcp.x-k8s.io/v1alpha1
kind: MCPServer
metadata:
  name: test-server-2
  namespace: team-a
  annotations:
    mcp.opendatahub.io/catalog-server: test-server-2
    mcp.opendatahub.io/display-name: test-server-2
spec:
  source:
    type: ContainerImage
    containerImage:
      ref: ghcr.io/kuadrant/mcp-gateway/test-server2:latest
  config:
    port: 9090
    path: /mcp
    arguments: ["/mcp-test-server"]
    env:
      - name: MCP_TRANSPORT
        value: http
      - name: PORT
        value: "9090"
EOF

  wait_for "test-mcp-server" "oc get mcpserver test-mcp-server -n team-a -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running" 180
  wait_for "test-server-2" "oc get mcpserver test-server-2 -n team-a -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running" 180
  ok "Both test servers running"

  # --- 2.3 Register ---
  step "2.3 Register test servers with gateway"
  oc apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: test-mcp-server
  namespace: team-a
spec:
  hostnames: ["test-mcp-server.mcp.local"]
  parentRefs:
    - name: team-a-gateway
      sectionName: mcps
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
  toolPrefix: test_
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: test-mcp-server
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: test-server-2
  namespace: team-a
spec:
  hostnames: ["test-server-2.mcp.local"]
  parentRefs:
    - name: team-a-gateway
      sectionName: mcps
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
  toolPrefix: test2_
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: test-server-2
EOF
  wait_for "test-mcp-server registration" "oc get mcpserverregistration test-mcp-server -n team-a -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True" 60
  wait_for "test-server-2 registration" "oc get mcpserverregistration test-server-2 -n team-a -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True" 60
  ok "Both registered (test_ prefix: 5 tools, test2_ prefix: 7 tools)"

  # --- 2.4 Curation ---
  step "2.4 Update VirtualMCPServers + wristband clients + auth routing"

  echo "   Creating wristband client + roles for test-mcp-server..."
  kc_create_client "team-a/test-mcp-server"
  TEST1_UUID=$(kc_get_client_uuid "team-a/test-mcp-server")
  for role in greet headers time slow add_tool; do
    kc_create_role "$TEST1_UUID" "$role"
  done
  ok "Keycloak client team-a/test-mcp-server with 5 tool roles"

  echo "   Creating wristband client + roles for test-server-2..."
  kc_create_client "team-a/test-server-2"
  TEST2_UUID=$(kc_get_client_uuid "team-a/test-server-2")
  for role in hello_world time headers auth1234 slow set_time pour_chocolate_into_mold; do
    kc_create_role "$TEST2_UUID" "$role"
  done
  ok "Keycloak client team-a/test-server-2 with 7 tool roles"

  echo "   Assigning test tool roles to mcp-admin1..."
  ADMIN1_ID=$(kc_get_user_id "mcp-admin1")
  kc_assign_roles "$ADMIN1_ID" "$TEST1_UUID" greet headers time
  kc_assign_roles "$ADMIN1_ID" "$TEST2_UUID" hello_world time headers
  ok "mcp-admin1: test server subset (greet, headers, time, hello_world)"

  echo "   Assigning test tool roles to mcp-user1..."
  USER1_ID=$(kc_get_user_id "mcp-user1")
  kc_assign_roles "$USER1_ID" "$TEST1_UUID" greet headers time
  kc_assign_roles "$USER1_ID" "$TEST2_UUID" hello_world time headers slow
  OCP_CLIENT_UUID=$(kc_get_client_uuid "team-a/openshift-mcp-server")
  kc_assign_roles "$USER1_ID" "$OCP_CLIENT_UUID" namespaces_list pods_list
  ok "mcp-user1: test tools + limited openshift (namespaces_list, pods_list)"

  echo "   Updating admin-tools to include test tools..."
  oc apply -f - <<'EOF'
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPVirtualServer
metadata:
  name: admin-tools
  namespace: team-a
spec:
  description: All non-GitHub tools for mcp-admins group
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
EOF
  ok "admin-tools updated (26 tools)"

  echo "   Creating user-tools VirtualMCPServer (test tools only)..."
  oc apply -f - <<'EOF'
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPVirtualServer
metadata:
  name: user-tools
  namespace: team-a
spec:
  description: Test tools only for mcp-users group
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
EOF
  ok "user-tools VirtualMCPServer created (12 tools)"

  echo "   Updating gateway auth to route by group..."
  oc apply -f - <<EOF
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
    strategy: atomic
    rules:
      authentication:
        keycloak-jwt:
          jwt:
            issuerUrl: https://${KEYCLOAK_HOST}/realms/mcp-gateway
      authorization:
        authorized-tools:
          opa:
            allValues: true
            rego: |
              allow = true
              tools = { server: roles |
                server := object.keys(input.auth.identity.resource_access)[_]
                roles := object.get(input.auth.identity.resource_access, server, {}).roles
              }
      response:
        success:
          headers:
            x-authorized-tools:
              wristband:
                issuer: authorino
                signingKeyRefs:
                  - name: trusted-headers-private-key
                    algorithm: ES256
                tokenDuration: 300
                customClaims:
                  allowed-tools:
                    selector: auth.authorization.authorized-tools.tools.@tostr
            x-mcp-virtualserver:
              plain:
                expression: |
                  auth.identity.groups.exists(g, g == 'mcp-admins')
                    ? 'team-a/admin-tools'
                    : auth.identity.groups.exists(g, g == 'mcp-users')
                      ? 'team-a/user-tools'
                      : ''
EOF
  wait_for "AuthPolicy enforced" "oc get authpolicy team-a-gateway-auth -n team-a -o jsonpath='{.status.conditions[?(@.type==\"Enforced\")].status}' 2>/dev/null | grep -q True" 60
  ok "Gateway auth updated (mcp-admins → admin-tools, mcp-users → user-tools)"

  # --- 2.5 Verify ---
  step "2.5 Verify — tool visibility is intersection of VirtualMCPServer + wristband"

  echo "   --- mcp-admin1 (VirtualMCPServer: admin-tools=26, wristband: ocp=5 + test1=3 + test2=3) ---"
  ADMIN_TOKEN=$(get_token "mcp-admin1" "admin1pass")
  ADMIN_SESSION=$(mcp_init "$ADMIN_TOKEN")
  ADMIN_TOOLS=$(mcp_tools_list "$ADMIN_TOKEN" "$ADMIN_SESSION" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('result',{}).get('tools',[])))" 2>/dev/null || echo "?")
  echo "   mcp-admin1: $ADMIN_TOOLS tools visible (intersection)"

  echo "   --- mcp-user1 (VirtualMCPServer: user-tools=12, wristband: test1=3 + test2=4 + ocp=2) ---"
  USER_TOKEN=$(get_token "mcp-user1" "user1pass")
  USER_SESSION=$(mcp_init "$USER_TOKEN")
  USER_TOOLS_JSON=$(mcp_tools_list "$USER_TOKEN" "$USER_SESSION")
  USER_TOOLS=$(echo "$USER_TOOLS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('result',{}).get('tools',[])))" 2>/dev/null || echo "?")
  echo "   mcp-user1:  $USER_TOOLS tools visible (intersection)"

  echo ""
  echo "   mcp-user1 → openshift_pods_list_in_namespace(team-a):"
  BLOCKED=$(mcp_tool_call "$USER_TOKEN" "$USER_SESSION" "openshift_pods_list_in_namespace" '{"namespace":"team-a"}')
  echo "$BLOCKED" | python3 -c "
import sys,json
r = json.load(sys.stdin)
if 'error' in r:
    print('   → Blocked (403) — expected')
else:
    print('   → Unexpected success — check AuthPolicy')
" 2>/dev/null || echo "   → (check response)"

  echo ""
  echo "   mcp-user1 → test_greet(name=team-a):"
  ALLOWED=$(mcp_tool_call "$USER_TOKEN" "$USER_SESSION" "test_greet" '{"name":"team-a"}')
  echo "$ALLOWED" | python3 -c "
import sys,json
r = json.load(sys.stdin)
if 'result' in r:
    print('   → Success — expected')
else:
    print(f'   → Error: {r}')
" 2>/dev/null || echo "   → (check response)"

  echo ""
  echo "   Two layers of filtering:"
  echo "   ┌──────────────┬─────────────────┬─────────────────┬───────────────┐"
  echo "   │ User         │ VirtualMCPServer│ Wristband roles │ Result (∩)    │"
  echo "   ├──────────────┼─────────────────┼─────────────────┼───────────────┤"
  echo "   │ mcp-admin1   │ admin-tools (26)│ ocp:5+test:6    │ ${ADMIN_TOOLS} tools    │"
  echo "   │ mcp-user1    │ user-tools (12) │ test:7+ocp:2    │ ${USER_TOOLS} tools     │"
  echo "   └──────────────┴─────────────────┴─────────────────┴───────────────┘"

  ok "Phase 2 complete — dual-layer tool filtering (VirtualMCPServer ∩ wristband)"
  pause
fi

# =============================================================================
# Phase 3: GitHub MCP Server (mcp-admin1 via mcp-github group)
# =============================================================================
if should_run 3; then
  header "Phase 3: GitHub MCP Server"
  echo "  Deploy the GitHub MCP server with Vault per-user credential injection."
  echo "  Each user's GitHub PAT is stored in Vault and injected at request time."
  echo "  User: mcp-admin1 (group: mcp-github)"

  # --- 3.1 Catalog ---
  step "3.1 Discover — GitHub MCP server in catalog"
  echo "   (Catalog was already updated in Phase 2 with github-mcp-server entry)"
  ui_step "Open RHOAI Dashboard → MCP Catalog → see GitHub MCP Server"
  pause

  # --- 3.2 Deploy ---
  step "3.2 Deploy GitHub MCP server"
  echo ""
  echo "   The GitHub MCP server needs a PAT for broker tool discovery."
  echo "   Enter a GitHub PAT (read-only scope is sufficient), or press Enter to use a placeholder:"
  read -rp "   GitHub PAT: " GITHUB_PAT < /dev/tty
  GITHUB_PAT="${GITHUB_PAT:-ghp_PLACEHOLDER_REPLACE_ME}"

  oc apply -f - <<EOF
apiVersion: mcp.x-k8s.io/v1alpha1
kind: MCPServer
metadata:
  name: github-mcp-server
  namespace: team-a
spec:
  source:
    type: ContainerImage
    containerImage:
      ref: ghcr.io/github/github-mcp-server:latest
  config:
    port: 8080
    arguments: ["http", "--port", "8080", "--toolsets", "all", "--read-only"]
    env:
      - name: GITHUB_PERSONAL_ACCESS_TOKEN
        value: "${GITHUB_PAT}"
  runtime:
    replicas: 1
---
apiVersion: v1
kind: Secret
metadata:
  name: github-mcp-credential
  namespace: team-a
  labels:
    mcp.kuadrant.io/secret: "true"
type: Opaque
stringData:
  token: "Bearer ${GITHUB_PAT}"
EOF
  wait_for "GitHub MCP server" "oc get mcpserver github-mcp-server -n team-a -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running" 180
  ok "GitHub MCP server running"

  # --- 3.3 Register ---
  step "3.3 Register with gateway"
  oc apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: github-mcp-server
  namespace: team-a
spec:
  hostnames: ["github-mcp-server.mcp.local"]
  parentRefs:
    - name: team-a-gateway
      sectionName: mcps
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /mcp
      backendRefs:
        - name: github-mcp-server
          port: 8080
---
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPServerRegistration
metadata:
  name: github-mcp-server
  namespace: team-a
spec:
  toolPrefix: github_
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: github-mcp-server
  credentialRef:
    name: github-mcp-credential
    key: token
EOF
  wait_for "github registration" "oc get mcpserverregistration github-mcp-server -n team-a -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True" 60
  GH_TOOLS=$(oc get mcpserverregistration github-mcp-server -n team-a -o jsonpath='{.status.discoveredTools}')
  ok "Registered — ${GH_TOOLS} tools with github_ prefix"

  # --- 3.4 Auth + Curation ---
  step "3.4 Vault AuthPolicy + VirtualMCPServer + wristband + gateway routing"

  echo "   Creating mcp-github1 user (dedicated GitHub group user)..."
  KC_TKN=$(kc_admin_token)
  curl -sk -X POST -H "Authorization: Bearer $KC_TKN" -H "Content-Type: application/json" \
    "https://${KEYCLOAK_HOST}/admin/realms/mcp-gateway/users" \
    -d '{"username":"mcp-github1","enabled":true,"firstName":"GitHub","lastName":"User","email":"mcp-github1@example.com","credentials":[{"type":"password","value":"github1pass","temporary":false}]}' \
    -o /dev/null -w ""
  GITHUB1_ID=$(kc_get_user_id "mcp-github1")
  GITHUB_GROUP_ID=$(curl -sk -H "Authorization: Bearer $KC_TKN" \
    "https://${KEYCLOAK_HOST}/admin/realms/mcp-gateway/groups?search=mcp-github" \
    | python3 -c "import sys,json; groups=json.load(sys.stdin); print(next(g['id'] for g in groups if g['name']=='mcp-github'))")
  curl -sk -X PUT -H "Authorization: Bearer $KC_TKN" \
    "https://${KEYCLOAK_HOST}/admin/realms/mcp-gateway/users/${GITHUB1_ID}/groups/${GITHUB_GROUP_ID}" \
    -o /dev/null -w ""
  ok "mcp-github1 / github1pass created (group: mcp-github)"

  echo "   Creating github-tools VirtualMCPServer..."
  oc apply -f - <<'EOF'
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPVirtualServer
metadata:
  name: github-tools
  namespace: team-a
spec:
  description: GitHub tools for mcp-github group — repos, PRs, users, context
  tools:
    - github_get_commit
    - github_get_file_contents
    - github_get_latest_release
    - github_get_me
    - github_get_release_by_tag
    - github_get_tag
    - github_get_team_members
    - github_get_teams
    - github_list_branches
    - github_list_commits
    - github_list_pull_requests
    - github_list_releases
    - github_list_tags
    - github_pull_request_read
    - github_search_code
    - github_search_pull_requests
    - github_search_repositories
    - github_search_users
EOF
  ok "github-tools VirtualMCPServer created (18 tools)"

  echo "   Creating wristband client + roles for github-mcp-server..."
  kc_create_client "team-a/github-mcp-server"
  GH_CLIENT_UUID=$(kc_get_client_uuid "team-a/github-mcp-server")
  for role in get_me list_pull_requests search_repositories get_file_contents list_commits \
              get_commit search_pull_requests get_team_members list_releases get_release_by_tag \
              list_tags list_branches search_code search_users get_latest_release pull_request_read \
              get_tag get_teams; do
    kc_create_role "$GH_CLIENT_UUID" "$role"
  done
  ok "Keycloak client team-a/github-mcp-server with 18 tool roles"

  echo "   Assigning GitHub tool roles to mcp-github1..."
  kc_assign_roles "$GITHUB1_ID" "$GH_CLIENT_UUID" \
    get_me list_pull_requests search_repositories get_file_contents list_commits
  ok "mcp-github1: get_me, list_pull_requests, search_repositories, get_file_contents, list_commits"

  echo "   Assigning GitHub tool roles to mcp-admin1..."
  ADMIN1_ID=$(kc_get_user_id "mcp-admin1")
  kc_assign_roles "$ADMIN1_ID" "$GH_CLIENT_UUID" \
    get_me list_pull_requests search_repositories
  ok "mcp-admin1: get_me, list_pull_requests, search_repositories"

  echo "   Assigning limited test tool roles to mcp-github1..."
  TEST1_UUID=$(kc_get_client_uuid "team-a/test-mcp-server")
  TEST2_UUID=$(kc_get_client_uuid "team-a/test-server-2")
  kc_assign_roles "$GITHUB1_ID" "$TEST1_UUID" greet time
  kc_assign_roles "$GITHUB1_ID" "$TEST2_UUID" hello_world
  ok "mcp-github1: limited test tools (greet, time, hello_world)"

  echo "   Applying Vault credential injection AuthPolicy..."
  oc apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: github-mcp-vault-auth
  namespace: team-a
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: github-mcp-server
  rules:
    authentication:
      keycloak-jwt:
        jwt:
          issuerUrl: https://${KEYCLOAK_HOST}/realms/mcp-gateway
    metadata:
      vault_token:
        http:
          url: http://vault.openshift-operators.svc.cluster.local:8200/v1/auth/jwt/login
          method: POST
          body:
            expression: |
              '{"role":"mcp-user","jwt":"' + request.headers.authorization.split(' ')[1] + '"}'
          contentType: application/json
        priority: 0
      vault_user_secret:
        http:
          urlExpression: |
            'http://vault.openshift-operators.svc.cluster.local:8200/v1/mcp/data/users/' + auth.identity.preferred_username + '/github'
          headers:
            X-Vault-Token:
              expression: auth.metadata.vault_token.auth.client_token
        priority: 1
    response:
      success:
        headers:
          authorization:
            plain:
              expression: "'Bearer ' + auth.metadata.vault_user_secret.data.data.token"
EOF
  ok "Vault AuthPolicy applied (Keycloak JWT → Vault token → per-user PAT)"

  echo "   Updating gateway auth to include mcp-github routing..."
  oc apply -f - <<EOF
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
    strategy: atomic
    rules:
      authentication:
        keycloak-jwt:
          jwt:
            issuerUrl: https://${KEYCLOAK_HOST}/realms/mcp-gateway
      authorization:
        authorized-tools:
          opa:
            allValues: true
            rego: |
              allow = true
              tools = { server: roles |
                server := object.keys(input.auth.identity.resource_access)[_]
                roles := object.get(input.auth.identity.resource_access, server, {}).roles
              }
      response:
        success:
          headers:
            x-authorized-tools:
              wristband:
                issuer: authorino
                signingKeyRefs:
                  - name: trusted-headers-private-key
                    algorithm: ES256
                tokenDuration: 300
                customClaims:
                  allowed-tools:
                    selector: auth.authorization.authorized-tools.tools.@tostr
            x-mcp-virtualserver:
              plain:
                expression: |
                  auth.identity.groups.exists(g, g == 'mcp-admins')
                    ? 'team-a/admin-tools'
                    : auth.identity.groups.exists(g, g == 'mcp-github')
                      ? 'team-a/github-tools'
                      : auth.identity.groups.exists(g, g == 'mcp-users')
                        ? 'team-a/user-tools'
                        : ''
EOF
  wait_for "AuthPolicies enforced" "oc get authpolicy team-a-gateway-auth -n team-a -o jsonpath='{.status.conditions[?(@.type==\"Enforced\")].status}' 2>/dev/null | grep -q True" 60
  ok "Gateway auth updated (mcp-admins → admin-tools, mcp-github → github-tools, mcp-users → user-tools)"

  # --- 3.5 Store PATs in Vault ---
  step "3.5 Store per-user GitHub PATs in Vault"

  VAULT_NS="openshift-operators"
  VAULT_POD="vault-0"
  if [ -f "${SCRIPT_DIR}/vault-credentials.json" ]; then
    VAULT_TOKEN=$(python3 -c "import json; print(json.load(open('${SCRIPT_DIR}/vault-credentials.json'))['root_token'])")
  else
    echo "   ⚠ vault-credentials.json not found — enter Vault root token:"
    read -rp "   Vault token: " VAULT_TOKEN < /dev/tty
  fi

  echo "   Storing PAT for mcp-admin1..."
  oc exec -n "$VAULT_NS" "$VAULT_POD" -- sh -c \
    "export VAULT_TOKEN=$VAULT_TOKEN; vault kv put mcp/users/mcp-admin1/github token=${GITHUB_PAT}"
  ok "PAT stored at mcp/users/mcp-admin1/github"

  echo "   Storing PAT for mcp-github1..."
  echo "   Enter a GitHub PAT for mcp-github1 (or press Enter to reuse the same PAT):"
  read -rp "   GitHub PAT for mcp-github1: " GITHUB1_PAT < /dev/tty
  GITHUB1_PAT="${GITHUB1_PAT:-${GITHUB_PAT}}"
  oc exec -n "$VAULT_NS" "$VAULT_POD" -- sh -c \
    "export VAULT_TOKEN=$VAULT_TOKEN; vault kv put mcp/users/mcp-github1/github token=${GITHUB1_PAT}"
  ok "PAT stored at mcp/users/mcp-github1/github"

  # --- 3.6 Verify ---
  step "3.6 Verify — tool visibility across all users"

  echo "   --- mcp-github1 (VirtualMCPServer: github-tools=18, wristband: github:5+test:3) ---"
  GH_TOKEN=$(get_token "mcp-github1" "github1pass")
  GH_SESSION=$(mcp_init "$GH_TOKEN")
  GH_TOOLS=$(mcp_tools_list "$GH_TOKEN" "$GH_SESSION" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('result',{}).get('tools',[])))" 2>/dev/null || echo "?")
  echo "   mcp-github1: $GH_TOOLS tools visible (intersection)"

  echo ""
  echo "   tools/call github_get_me as mcp-github1:"
  GH_RESULT=$(mcp_tool_call "$GH_TOKEN" "$GH_SESSION" "github_get_me" '{}')
  echo "$GH_RESULT" | python3 -c "
import sys,json
r = json.load(sys.stdin)
if 'result' in r:
    content = r['result'].get('content', [{}])
    if content:
        text = content[0].get('text', '')
        if 'login' in text.lower() or len(text) > 10:
            print('   → Success — GitHub user info returned')
        else:
            print(f'   → Response: {text[:100]}')
    else:
        print('   → Success (empty content)')
elif 'error' in r:
    print(f'   → Error: {r[\"error\"].get(\"message\",r[\"error\"])}')
" 2>/dev/null || echo "   → (check response)"

  echo ""
  echo "   --- mcp-admin1 (VirtualMCPServer: admin-tools=26, wristband: ocp:5+test:6+github:3) ---"
  ADMIN_TOKEN=$(get_token "mcp-admin1" "admin1pass")
  ADMIN_SESSION=$(mcp_init "$ADMIN_TOKEN")
  ADMIN_TOOLS=$(mcp_tools_list "$ADMIN_TOKEN" "$ADMIN_SESSION" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('result',{}).get('tools',[])))" 2>/dev/null || echo "?")
  echo "   mcp-admin1: $ADMIN_TOOLS tools visible (intersection — admin-tools has no github tools)"

  echo ""
  echo "   --- mcp-user1 (VirtualMCPServer: user-tools=12, wristband: test:7+ocp:2) ---"
  USER_TOKEN=$(get_token "mcp-user1" "user1pass")
  USER_SESSION=$(mcp_init "$USER_TOKEN")
  USER_TOOLS=$(mcp_tools_list "$USER_TOKEN" "$USER_SESSION" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('result',{}).get('tools',[])))" 2>/dev/null || echo "?")
  echo "   mcp-user1:  $USER_TOOLS tools visible (intersection)"

  echo ""
  echo "   Two layers of tool filtering:"
  echo "   ┌──────────────┬──────────────────┬────────────────────┬───────────────┐"
  echo "   │ User         │ VirtualMCPServer │ Wristband roles    │ Result (∩)    │"
  echo "   ├──────────────┼──────────────────┼────────────────────┼───────────────┤"
  echo "   │ mcp-admin1   │ admin-tools (26) │ ocp:5+test:6+gh:3  │ ${ADMIN_TOOLS} tools    │"
  echo "   │ mcp-github1  │ github-tools (18)│ gh:5+test:3        │ ${GH_TOOLS} tools     │"
  echo "   │ mcp-user1    │ user-tools (12)  │ test:7+ocp:2       │ ${USER_TOOLS} tools     │"
  echo "   └──────────────┴──────────────────┴────────────────────┴───────────────┘"
  echo ""
  echo "   Vault credential injection flow:"
  echo "   User JWT → Authorino → Vault JWT login → Read per-user secret → Inject PAT"

  ok "Phase 3 complete — GitHub MCP with Vault credentials + dual-layer tool filtering"
fi

# =============================================================================
# Summary
# =============================================================================
header "Demo Complete"
echo ""
echo "  Phase 1: OpenShift MCP Server"
echo "    → 14 tools (openshift_*), admin-only access, Playground integration"
echo ""
echo "  Phase 2: Test Servers"
echo "    → 12 additional tools (test_* + test2_*), dual-layer tool filtering"
echo ""
echo "  Phase 3: GitHub MCP Server"
echo "    → 18 tools (github_*), Vault credential injection, wristband ACLs"
echo ""
echo "  Tool filtering (VirtualMCPServer ∩ wristband):"
echo "    mcp-admin1  → admin-tools ∩ resource_access roles"
echo "    mcp-github1 → github-tools ∩ resource_access roles"
echo "    mcp-user1   → user-tools ∩ resource_access roles"
echo ""
echo "  Endpoints:"
echo "    Gateway   → https://${GATEWAY_HOST}/mcp"
echo "    Keycloak  → https://${KEYCLOAK_HOST}"
echo "    Catalog   → https://model-catalog.${CLUSTER_DOMAIN}"
echo ""
echo "  Quick test:"
echo "    TOKEN=\$(curl -sk -X POST 'https://${KEYCLOAK_HOST}/realms/mcp-gateway/protocol/openid-connect/token' \\"
echo "      -d 'grant_type=password&client_id=mcp-playground&username=mcp-admin1&password=admin1pass' \\"
echo "      | python3 -c \"import sys,json; print(json.load(sys.stdin)['access_token'])\")"
echo ""
