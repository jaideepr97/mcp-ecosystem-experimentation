#!/usr/bin/env bash
# test-pipeline.sh — Verify the multi-tenant MCP ecosystem
#
# Tests the end-to-end flow:
#   Phase 1: Shared infrastructure (namespaces, controllers, operators)
#   Phase 2: Catalog API
#   Phase 3: team-a namespace (gateway, broker, servers)
#   Phase 4: Authentication (Keycloak token issuance, unauthenticated rejection)
#   Phase 5: VirtualMCPServer filtering (per-group tool visibility)
#   Phase 6: Authorization matrix (per-group tool access enforcement)
#   Phase 7: TLS (HTTPS termination, cert-manager, TLSPolicy)
#   Phase 8: Launcher (catalog UI accessible via NodePort)
#   Phase 9: Tool delisting (VirtualMCPServer config change)
#
# Usage: ./scripts/test-pipeline.sh

set -uo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak.127-0-0-1.sslip.io:8002}"
GATEWAY_URL="${GATEWAY_URL:-http://team-a.mcp.127-0-0-1.sslip.io:8001}"
GATEWAY_TLS_URL="${GATEWAY_TLS_URL:-https://team-a.mcp.127-0-0-1.sslip.io:8443}"
CA_CERT="${CA_CERT:-/tmp/mcp-ca.crt}"
CLIENT_ID="${CLIENT_ID:-mcp-cli}"
REALM="${REALM:-mcp}"
SCOPE="${SCOPE:-openid groups}"

TOKEN_ENDPOINT="${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token"

PASS=0
FAIL=0
ERRORS=""

# --- Helpers ---

check() {
  local name="$1"
  local result="$2"  # "true" or "false"
  local detail="${3:-}"

  if [ "$result" = "true" ]; then
    printf "  %-55s %s\n" "$name" "PASS"
    ((PASS++))
  else
    printf "  %-55s %s\n" "$name" "FAIL"
    ((FAIL++))
    if [ -n "$detail" ]; then
      ERRORS="${ERRORS}\n  ${name}: ${detail}"
    fi
  fi
}

get_token() {
  local username="$1"
  local password="$2"
  curl -s -X POST "$TOKEN_ENDPOINT" \
    -d "grant_type=password" \
    -d "client_id=${CLIENT_ID}" \
    -d "username=${username}" \
    -d "password=${password}" \
    -d "scope=${SCOPE}" | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null
}

init_session() {
  local token="$1"
  curl -si -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test-pipeline","version":"1.0"}}}' \
    "${GATEWAY_URL}/mcp" 2>&1 | grep -i mcp-session-id | awk '{print $2}' | tr -d '\r'
}

rpc_call() {
  local token="$1"
  local session_id="$2"
  local method="$3"
  local params="${4:-"{}"}"

  local response
  response=$(curl -s -H "Authorization: Bearer $token" \
    -H "Mcp-Session-Id: $session_id" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"${method}\",\"params\":${params}}" \
    "${GATEWAY_URL}/mcp" 2>/dev/null)

  # Handle SSE or plain JSON
  local json
  json=$(echo "$response" | grep "^data:" | sed 's/^data: //')
  if [ -n "$json" ]; then
    echo "$json"
  else
    echo "$response"
  fi
}

get_tool_names() {
  local token="$1"
  local session_id="$2"
  rpc_call "$token" "$session_id" "tools/list" | python3 -c "
import sys,json
data = json.load(sys.stdin)
tools = data.get('result',{}).get('tools',[])
for t in tools:
    print(t['name'])
" 2>/dev/null
}

get_tool_count() {
  local token="$1"
  local session_id="$2"
  rpc_call "$token" "$session_id" "tools/list" | python3 -c "
import sys,json
data = json.load(sys.stdin)
print(len(data.get('result',{}).get('tools',[])))
" 2>/dev/null
}

call_tool_http_code() {
  local token="$1"
  local session_id="$2"
  local tool_name="$3"
  local tool_args="${4:-"{}"}"

  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({
    'jsonrpc': '2.0',
    'id': 99,
    'method': 'tools/call',
    'params': {'name': sys.argv[1], 'arguments': json.loads(sys.argv[2])}
}))" "$tool_name" "$tool_args")

  curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $token" \
    -H "Mcp-Session-Id: $session_id" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${GATEWAY_URL}/mcp"
}

assert_tool() {
  local user="$1"
  local tool="$2"
  local expected="$3"  # "allow" or "deny"
  local token="$4"
  local session_id="$5"
  local tool_args="${6:-"{}"}"

  local http_code
  http_code=$(call_tool_http_code "$token" "$session_id" "$tool" "$tool_args")

  local result
  if [ "$expected" = "allow" ]; then
    if [ "$http_code" = "200" ]; then
      result="true"
    else
      result="false"
    fi
  else
    # Denied: expect 403 or 500 (known: broker wraps 403 as 500)
    if [ "$http_code" = "403" ] || [ "$http_code" = "500" ]; then
      result="true"
    else
      result="false"
    fi
  fi

  check "${user} → ${tool} (${expected})" "$result" "got HTTP ${http_code}"
}

########################################
# Header
########################################
echo "================================================"
echo "  MCP Ecosystem Pipeline Test (Multi-Tenant)"
echo "================================================"
echo ""

########################################
# Phase 1: Shared infrastructure
########################################
echo "--- Phase 1: Shared infrastructure ---"

# Namespaces
for NS in mcp-system keycloak kuadrant-system vault catalog-system mcp-lifecycle-operator-system; do
  NS_EXISTS=$(kubectl get namespace "$NS" -o name 2>/dev/null)
  check "Namespace ${NS} exists" "$([ -n "$NS_EXISTS" ] && echo true || echo false)"
done

# Controllers and operators
check "mcp-controller running" \
  "$([ "$(kubectl get deploy mcp-controller -n mcp-system -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" -gt 0 ] 2>/dev/null && echo true || echo false)"

check "lifecycle-operator running" \
  "$([ "$(kubectl get deploy mcp-lifecycle-operator-controller-manager -n mcp-lifecycle-operator-system -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" -gt 0 ] 2>/dev/null && echo true || echo false)"

check "Authorino running" \
  "$(kubectl get pod -l app=authorino -n kuadrant-system -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running && echo true || echo false)"

# Keycloak
KC_PHASE=$(kubectl get pod -l app=keycloak -n keycloak -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
check "Keycloak pod running" "$([ "$KC_PHASE" = "Running" ] && echo true || echo false)" "status: $KC_PHASE"

# Vault
VAULT_PHASE=$(kubectl get pod -l app=vault -n vault -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
check "Vault pod running" "$([ "$VAULT_PHASE" = "Running" ] && echo true || echo false)" "status: $VAULT_PHASE"

########################################
# Phase 2: Catalog API
########################################
echo ""
echo "--- Phase 2: Catalog API ---"

kubectl port-forward svc/mcp-catalog -n catalog-system 18080:8080 &>/dev/null &
PF_PID=$!
sleep 2
cleanup() { kill $PF_PID 2>/dev/null || true; }
trap cleanup EXIT

CATALOG_RESPONSE=$(curl -s http://localhost:18080/api/mcp_catalog/v1alpha1/mcp_servers 2>/dev/null)
SERVER_COUNT=$(echo "$CATALOG_RESPONSE" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('items',[])))" 2>/dev/null || echo "0")
check "Catalog API responds" "$([ "$SERVER_COUNT" -gt 0 ] && echo true || echo false)" "got $SERVER_COUNT servers"

# Clean up port-forward early
kill $PF_PID 2>/dev/null || true
trap - EXIT

########################################
# Phase 3: team-a namespace
########################################
echo ""
echo "--- Phase 3: team-a namespace ---"

NS_EXISTS=$(kubectl get namespace team-a -o name 2>/dev/null)
check "Namespace team-a exists" "$([ -n "$NS_EXISTS" ] && echo true || echo false)"

# Gateway
GW_PROGRAMMED=$(kubectl get gateway team-a-gateway -n team-a -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
check "team-a Gateway is Programmed" "$([ "$GW_PROGRAMMED" = "True" ] && echo true || echo false)"

# MCPGatewayExtension
EXT_READY=$(kubectl get mcpgatewayextension team-a-gateway-extension -n team-a -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
check "MCPGatewayExtension is Ready" "$([ "$EXT_READY" = "True" ] && echo true || echo false)"

# Broker/router pod
BROKER_PHASE=$(kubectl get pod -l app=mcp-gateway -n team-a -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
check "Broker/router pod running" "$([ "$BROKER_PHASE" = "Running" ] && echo true || echo false)" "status: $BROKER_PHASE"

# MCP servers
for SERVER in test-server-a1 test-server-a2; do
  MCPSERVER_READY=$(kubectl get mcpserver "$SERVER" -n team-a -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  check "${SERVER}: MCPServer Ready" "$([ "$MCPSERVER_READY" = "True" ] && echo true || echo false)"

  POD_PHASE=$(kubectl get pod -l mcp-server="$SERVER" -n team-a -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
  check "${SERVER}: Pod Running" "$([ "$POD_PHASE" = "Running" ] && echo true || echo false)" "status: $POD_PHASE"

  HR_EXISTS=$(kubectl get httproute "$SERVER" -n team-a -o name 2>/dev/null)
  check "${SERVER}: HTTPRoute created" "$([ -n "$HR_EXISTS" ] && echo true || echo false)"

  REG_EXISTS=$(kubectl get mcpserverregistration "$SERVER" -n team-a -o name 2>/dev/null)
  check "${SERVER}: MCPServerRegistration created" "$([ -n "$REG_EXISTS" ] && echo true || echo false)"
done

# AuthPolicies
for POLICY in team-a-gateway-auth team-a-auth-server-a1 team-a-auth-server-a2; do
  AP_EXISTS=$(kubectl get authpolicy "$POLICY" -n team-a -o name 2>/dev/null)
  check "AuthPolicy ${POLICY} exists" "$([ -n "$AP_EXISTS" ] && echo true || echo false)"
done

# VirtualMCPServer CRs
for VS in team-a-dev-tools team-a-ops-tools team-a-lead-tools; do
  VS_EXISTS=$(kubectl get mcpvirtualserver "$VS" -n team-a -o name 2>/dev/null)
  check "VirtualMCPServer ${VS} exists" "$([ -n "$VS_EXISTS" ] && echo true || echo false)"
done

# NodePort
NP_EXISTS=$(kubectl get svc team-a-gateway-np -n team-a -o name 2>/dev/null)
check "NodePort service exists" "$([ -n "$NP_EXISTS" ] && echo true || echo false)"

########################################
# Phase 4: Authentication
########################################
echo ""
echo "--- Phase 4: Authentication ---"

# Keycloak OIDC discovery
KC_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${KEYCLOAK_URL}/realms/${REALM}/.well-known/openid-configuration" 2>/dev/null)
check "Keycloak OIDC discovery responds" "$([ "$KC_CODE" = "200" ] && echo true || echo false)" "got HTTP $KC_CODE"

# Token issuance for team-a users
DEV1_TOKEN=$(get_token dev1 dev1)
check "Token issued for dev1 (developers)" "$([ -n "$DEV1_TOKEN" ] && echo true || echo false)"

OPS1_TOKEN=$(get_token ops1 ops1)
check "Token issued for ops1 (ops)" "$([ -n "$OPS1_TOKEN" ] && echo true || echo false)"

LEAD1_TOKEN=$(get_token lead1 lead1)
check "Token issued for lead1 (leads)" "$([ -n "$LEAD1_TOKEN" ] && echo true || echo false)"

# Verify group claims in tokens
DEV1_GROUPS=$(echo "$DEV1_TOKEN" | python3 -c "
import sys,json,base64
t = sys.stdin.read().strip()
parts = t.split('.')
payload = parts[1] + '=' * (4 - len(parts[1]) % 4)
groups = json.loads(base64.urlsafe_b64decode(payload)).get('groups',[])
print(','.join(groups))
" 2>/dev/null)
check "dev1 has team-a-developers group" "$(echo "$DEV1_GROUPS" | grep -q 'team-a-developers' && echo true || echo false)" "groups: $DEV1_GROUPS"

LEAD1_GROUPS=$(echo "$LEAD1_TOKEN" | python3 -c "
import sys,json,base64
t = sys.stdin.read().strip()
parts = t.split('.')
payload = parts[1] + '=' * (4 - len(parts[1]) % 4)
groups = json.loads(base64.urlsafe_b64decode(payload)).get('groups',[])
print(','.join(groups))
" 2>/dev/null)
check "lead1 has team-a-leads group" "$(echo "$LEAD1_GROUPS" | grep -q 'team-a-leads' && echo true || echo false)" "groups: $LEAD1_GROUPS"

# Unauthenticated rejection
UNAUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  "${GATEWAY_URL}/mcp" 2>/dev/null)
check "Unauthenticated request rejected (401)" "$([ "$UNAUTH_CODE" = "401" ] && echo true || echo false)" "got HTTP $UNAUTH_CODE"

########################################
# Phase 5: VirtualMCPServer filtering
########################################
echo ""
echo "--- Phase 5: VirtualMCPServer filtering (tools/list per group) ---"

# Initialize sessions
DEV1_SESSION=$(init_session "$DEV1_TOKEN")
check "dev1: MCP session initialized" "$([ -n "$DEV1_SESSION" ] && echo true || echo false)"

OPS1_SESSION=$(init_session "$OPS1_TOKEN")
check "ops1: MCP session initialized" "$([ -n "$OPS1_SESSION" ] && echo true || echo false)"

LEAD1_SESSION=$(init_session "$LEAD1_TOKEN")
check "lead1: MCP session initialized" "$([ -n "$LEAD1_SESSION" ] && echo true || echo false)"

# Tool counts per group
DEV1_COUNT=$(get_tool_count "$DEV1_TOKEN" "$DEV1_SESSION")
check "dev1 sees 6 tools (developers)" "$([ "${DEV1_COUNT:-0}" = "6" ] && echo true || echo false)" "got ${DEV1_COUNT}"

OPS1_COUNT=$(get_tool_count "$OPS1_TOKEN" "$OPS1_SESSION")
check "ops1 sees 6 tools (ops)" "$([ "${OPS1_COUNT:-0}" = "6" ] && echo true || echo false)" "got ${OPS1_COUNT}"

LEAD1_COUNT=$(get_tool_count "$LEAD1_TOKEN" "$LEAD1_SESSION")
check "lead1 sees 12 tools (leads)" "$([ "${LEAD1_COUNT:-0}" = "12" ] && echo true || echo false)" "got ${LEAD1_COUNT}"

# Verify specific tools visible/hidden
DEV1_TOOLS=$(get_tool_names "$DEV1_TOKEN" "$DEV1_SESSION")
check "dev1 sees test_server_a1_greet" "$(echo "$DEV1_TOOLS" | grep -q 'test_server_a1_greet' && echo true || echo false)"
check "dev1 does NOT see test_server_a1_add_tool" "$(echo "$DEV1_TOOLS" | grep -q 'test_server_a1_add_tool' && echo false || echo true)"

OPS1_TOOLS=$(get_tool_names "$OPS1_TOKEN" "$OPS1_SESSION")
check "ops1 sees test_server_a1_add_tool" "$(echo "$OPS1_TOOLS" | grep -q 'test_server_a1_add_tool' && echo true || echo false)"
check "ops1 does NOT see test_server_a1_greet" "$(echo "$OPS1_TOOLS" | grep -q 'test_server_a1_greet' && echo false || echo true)"

########################################
# Phase 6: Authorization matrix
########################################
echo ""
echo "--- Phase 6: Authorization matrix (tools/call enforcement) ---"
echo ""
echo "  Groups:"
echo "    team-a-developers → greet, time, headers (server-a1) + hello_world, time, headers (server-a2)"
echo "    team-a-ops        → add_tool, slow (server-a1) + auth1234, set_time, slow, pour_chocolate_into_mold (server-a2)"
echo "    team-a-leads      → all tools from both servers"
echo ""
printf "  %-8s %-40s %-6s %s\n" "USER" "TOOL" "EXPECT" "RESULT"
printf "  %-8s %-40s %-6s %s\n" "--------" "----------------------------------------" "------" "----------"

# dev1 (team-a-developers): allowed greet, time, headers; denied add_tool, slow
assert_tool "dev1" "test_server_a1_greet" "allow" "$DEV1_TOKEN" "$DEV1_SESSION" '{"name":"test"}'
assert_tool "dev1" "test_server_a1_time" "allow" "$DEV1_TOKEN" "$DEV1_SESSION"
assert_tool "dev1" "test_server_a1_add_tool" "deny" "$DEV1_TOKEN" "$DEV1_SESSION" '{"name":"x","description":"x"}'

# ops1 (team-a-ops): allowed add_tool, slow; denied greet, time
assert_tool "ops1" "test_server_a1_add_tool" "allow" "$OPS1_TOKEN" "$OPS1_SESSION" '{"name":"x","description":"x"}'
assert_tool "ops1" "test_server_a1_slow" "allow" "$OPS1_TOKEN" "$OPS1_SESSION"
assert_tool "ops1" "test_server_a1_greet" "deny" "$OPS1_TOKEN" "$OPS1_SESSION" '{"name":"test"}'

# lead1 (team-a-leads): allowed all
assert_tool "lead1" "test_server_a1_greet" "allow" "$LEAD1_TOKEN" "$LEAD1_SESSION" '{"name":"test"}'
assert_tool "lead1" "test_server_a1_add_tool" "allow" "$LEAD1_TOKEN" "$LEAD1_SESSION" '{"name":"x","description":"x"}'

# Server a2 tools
assert_tool "dev1" "test_server_a2_hello_world" "allow" "$DEV1_TOKEN" "$DEV1_SESSION"
assert_tool "dev1" "test_server_a2_auth1234" "deny" "$DEV1_TOKEN" "$DEV1_SESSION"

assert_tool "ops1" "test_server_a2_auth1234" "allow" "$OPS1_TOKEN" "$OPS1_SESSION"
assert_tool "ops1" "test_server_a2_hello_world" "deny" "$OPS1_TOKEN" "$OPS1_SESSION"

assert_tool "lead1" "test_server_a2_auth1234" "allow" "$LEAD1_TOKEN" "$LEAD1_SESSION"
assert_tool "lead1" "test_server_a2_hello_world" "allow" "$LEAD1_TOKEN" "$LEAD1_SESSION"

########################################
# Phase 7: TLS
########################################
echo ""
echo "--- Phase 7: TLS ---"

# cert-manager running
CM_READY=$(kubectl get deployment cert-manager -n cert-manager -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
check "cert-manager is running" "$([ "${CM_READY:-0}" -gt 0 ] && echo true || echo false)"

# CA certificate issued
CA_CERT_READY=$(kubectl get certificate mcp-ca-cert -n cert-manager -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
check "CA certificate is Ready" "$([ "$CA_CERT_READY" = "True" ] && echo true || echo false)"

# TLSPolicy exists and enforced
TLS_POLICY_STATUS=$(kubectl get tlspolicy team-a-gateway-tls -n team-a -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null)
check "TLSPolicy enforced" "$([ "$TLS_POLICY_STATUS" = "True" ] && echo true || echo false)"

# Gateway has HTTPS listener
HTTPS_LISTENER=$(kubectl get gateway team-a-gateway -n team-a -o jsonpath='{.spec.listeners[?(@.name=="mcp-https")].protocol}' 2>/dev/null)
check "Gateway has HTTPS listener" "$([ "$HTTPS_LISTENER" = "HTTPS" ] && echo true || echo false)"

# HTTPS NodePort
TLS_NP_EXISTS=$(kubectl get svc team-a-gateway-tls-np -n team-a -o name 2>/dev/null)
check "HTTPS NodePort service exists" "$([ -n "$TLS_NP_EXISTS" ] && echo true || echo false)"

# CA cert file exists
check "CA cert extracted to ${CA_CERT}" "$([ -f "$CA_CERT" ] && echo true || echo false)"

# HTTPS endpoint responds
if [ -f "$CA_CERT" ]; then
  TLS_TOKEN=$(get_token dev1 dev1)
  TLS_INIT=$(curl -si --cacert "$CA_CERT" \
    -H "Authorization: Bearer $TLS_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"tls-test","version":"1.0"}}}' \
    "${GATEWAY_TLS_URL}/mcp" 2>&1)
  TLS_SESSION=$(echo "$TLS_INIT" | grep -i mcp-session-id | awk '{print $2}' | tr -d '\r')
  check "MCP session via HTTPS" "$([ -n "$TLS_SESSION" ] && echo true || echo false)"

  if [ -n "$TLS_SESSION" ]; then
    TLS_TOOLS_RAW=$(curl -s --cacert "$CA_CERT" \
      -H "Authorization: Bearer $TLS_TOKEN" \
      -H "Mcp-Session-Id: $TLS_SESSION" \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
      "${GATEWAY_TLS_URL}/mcp" 2>/dev/null)
    TLS_TOOLS_JSON=$(echo "$TLS_TOOLS_RAW" | grep "^data:" | sed 's/^data: //')
    [ -z "$TLS_TOOLS_JSON" ] && TLS_TOOLS_JSON="$TLS_TOOLS_RAW"
    TLS_TOOL_COUNT=$(echo "$TLS_TOOLS_JSON" | python3 -c "
import sys,json
data = json.load(sys.stdin)
print(len(data.get('result',{}).get('tools',[])))
" 2>/dev/null || echo "0")
    check "Tools listed via HTTPS" "$([ "${TLS_TOOL_COUNT:-0}" -gt 0 ] 2>/dev/null && echo true || echo false)" "found ${TLS_TOOL_COUNT} tools"
  else
    check "Tools listed via HTTPS" "false" "skipped (no session)"
  fi
else
  check "MCP session via HTTPS" "false" "skipped (no CA cert)"
  check "Tools listed via HTTPS" "false" "skipped (no CA cert)"
fi

########################################
# Phase 8: Launcher
########################################
echo ""
echo "--- Phase 8: Launcher ---"

LAUNCHER_PHASE=$(kubectl get pod -l app=mcp-launcher -n catalog-system -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
check "Launcher pod running" "$([ "$LAUNCHER_PHASE" = "Running" ] && echo true || echo false)" "status: $LAUNCHER_PHASE"

LAUNCHER_NP=$(kubectl get svc mcp-launcher-external -n catalog-system -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
check "Launcher NodePort configured" "$([ "$LAUNCHER_NP" = "30472" ] && echo true || echo false)" "nodePort: $LAUNCHER_NP"

LAUNCHER_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8004 2>/dev/null)
check "Launcher UI accessible at localhost:8004" "$([ "$LAUNCHER_CODE" = "200" ] && echo true || echo false)" "got HTTP $LAUNCHER_CODE"

########################################
# Phase 9: Tool delisting (VirtualMCPServer filtering-only behavior)
########################################
echo ""
echo "--- Phase 9: Tool delisting (filtering vs enforcement) ---"

# Remove greet from dev-tools VirtualMCPServer config and verify it disappears from tools/list
# but remains callable via tools/call (proving filtering-only, not enforcement)
info "  Patching config Secret to remove test_server_a1_greet from dev-tools..."
CURRENT_CONFIG=$(kubectl get secret mcp-gateway-config -n team-a -o jsonpath='{.data.config\.yaml}' | base64 -d)

# Remove test_server_a1_greet from the dev-tools virtualServer
DELISTED_CONFIG=$(echo "$CURRENT_CONFIG" | python3 -c "
import sys
config = sys.stdin.read()
# Remove the specific tool line from team-a/team-a-dev-tools section
lines = config.split('\n')
in_dev_section = False
result = []
for line in lines:
    if 'team-a/team-a-dev-tools' in line:
        in_dev_section = True
    elif in_dev_section and '- name:' in line:
        in_dev_section = False
    if in_dev_section and line.strip() == '- test_server_a1_greet':
        continue
    result.append(line)
print('\n'.join(result))
")

kubectl create secret generic mcp-gateway-config -n team-a \
  --from-literal="config.yaml=${DELISTED_CONFIG}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart broker to pick up config change
BROKER_DEPLOY=$(kubectl get deploy -n team-a -l app=mcp-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$BROKER_DEPLOY" ]; then
  kubectl rollout restart deployment "${BROKER_DEPLOY}" -n team-a
  kubectl rollout status deployment "${BROKER_DEPLOY}" -n team-a --timeout=60s
fi

# Need a new session after broker restart
sleep 3
DEV1_TOKEN=$(get_token dev1 dev1)
DEV1_SESSION=$(init_session "$DEV1_TOKEN")

# Verify greet is no longer in tools/list
DEV1_DELISTED_COUNT=$(get_tool_count "$DEV1_TOKEN" "$DEV1_SESSION")
check "dev1 sees 5 tools after delisting greet" "$([ "${DEV1_DELISTED_COUNT:-0}" = "5" ] && echo true || echo false)" "got ${DEV1_DELISTED_COUNT}"

DEV1_DELISTED_TOOLS=$(get_tool_names "$DEV1_TOKEN" "$DEV1_SESSION")
check "test_server_a1_greet NOT in tools/list" "$(echo "$DEV1_DELISTED_TOOLS" | grep -q 'test_server_a1_greet' && echo false || echo true)"

# Verify greet is still callable (filtering-only, not enforcement)
GREET_CODE=$(call_tool_http_code "$DEV1_TOKEN" "$DEV1_SESSION" "test_server_a1_greet" '{"name":"delist-test"}')
check "test_server_a1_greet still callable (200)" "$([ "$GREET_CODE" = "200" ] && echo true || echo false)" "got HTTP $GREET_CODE"

# Restore the config
info "  Restoring config Secret..."
kubectl create secret generic mcp-gateway-config -n team-a \
  --from-literal="config.yaml=${CURRENT_CONFIG}" \
  --dry-run=client -o yaml | kubectl apply -f -

if [ -n "$BROKER_DEPLOY" ]; then
  kubectl rollout restart deployment "${BROKER_DEPLOY}" -n team-a
  kubectl rollout status deployment "${BROKER_DEPLOY}" -n team-a --timeout=60s
fi

########################################
# Summary
########################################
echo ""
echo "================================================"
TOTAL=$((PASS + FAIL))
echo "  Results: ${PASS}/${TOTAL} passed"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "  Failures:"
  echo -e "$ERRORS"
  echo ""
  echo "================================================"
  exit 1
else
  echo "  All tests passed."
  echo "================================================"
  exit 0
fi
