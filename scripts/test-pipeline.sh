#!/usr/bin/env bash
# test-pipeline.sh — Verify the full MCP ecosystem pipeline + authorization matrix
#
# Tests the end-to-end flow across all phases:
#   Phase 1: Catalog API lists available servers
#   Phase 2: Operator-created resources (Deployment, Service, pods) for both servers
#   Phase 3: Gateway integration (HTTPRoute, MCPServerRegistration) for both servers
#   Phase 4: Keycloak authentication (token issuance, unauthenticated rejection)
#   Phase 5: Gateway tool access (session init, tool federation, tool calls)
#   Phase 6: Authorization matrix (3 users × 5 tools = 15 allow/deny cases)
#
# Usage: ./scripts/test-pipeline.sh

set -uo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak.127-0-0-1.sslip.io:8002}"
GATEWAY_URL="${GATEWAY_URL:-http://mcp.127-0-0-1.sslip.io:8001}"
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
    printf "  %-50s %s\n" "$name" "PASS"
    ((PASS++))
  else
    printf "  %-50s %s\n" "$name" "FAIL"
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
    # Denied: expect 403 or 500 (known: full server deny returns 500)
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
echo "  MCP Ecosystem Pipeline Test"
echo "================================================"
echo ""

########################################
# Phase 1: Catalog API
########################################
echo "--- Phase 1: Catalog API ---"

kubectl port-forward svc/mcp-catalog -n catalog-system 18080:8080 &>/dev/null &
PF_PID=$!
sleep 2
cleanup() { kill $PF_PID 2>/dev/null || true; }
trap cleanup EXIT

CATALOG_RESPONSE=$(curl -s http://localhost:18080/api/mcp_catalog/v1alpha1/mcp_servers 2>/dev/null)
SERVER_COUNT=$(echo "$CATALOG_RESPONSE" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('items',[])))" 2>/dev/null || echo "0")
check "Catalog API responds" "$([ "$SERVER_COUNT" -gt 0 ] && echo true || echo false)" "got $SERVER_COUNT servers"

HAS_SERVER1=$(echo "$CATALOG_RESPONSE" | python3 -c "
import sys,json
items = json.load(sys.stdin).get('items',[])
print('true' if any('test-server1' in i.get('name','') for i in items) else 'false')
" 2>/dev/null || echo "false")
check "Catalog lists test-server1" "$HAS_SERVER1"

CATALOG_IMAGE=$(echo "$CATALOG_RESPONSE" | python3 -c "
import sys,json
items = json.load(sys.stdin).get('items',[])
for i in items:
    if 'test-server1' in i.get('name',''):
        arts = i.get('artifacts',[])
        if arts:
            print(arts[0].get('uri',''))
            break
" 2>/dev/null || echo "")
check "Catalog has OCI artifact URI" "$([ -n "$CATALOG_IMAGE" ] && echo true || echo false)" "$CATALOG_IMAGE"

########################################
# Phase 2: Operator-created resources
########################################
echo ""
echo "--- Phase 2: Operator-created resources ---"

for SERVER in test-server1 test-server2; do
  MCPSERVER_EXISTS=$(kubectl get mcpserver "$SERVER" -n mcp-test -o name 2>/dev/null)
  check "${SERVER}: MCPServer CR exists" "$([ -n "$MCPSERVER_EXISTS" ] && echo true || echo false)"

  DEPLOY_EXISTS=$(kubectl get deployment "$SERVER" -n mcp-test -o name 2>/dev/null)
  check "${SERVER}: Deployment created" "$([ -n "$DEPLOY_EXISTS" ] && echo true || echo false)"

  SVC_EXISTS=$(kubectl get service "$SERVER" -n mcp-test -o name 2>/dev/null)
  check "${SERVER}: Service created" "$([ -n "$SVC_EXISTS" ] && echo true || echo false)"

  POD_READY=$(kubectl get pods -n mcp-test -l mcp-server="$SERVER" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
  check "${SERVER}: Pod is Running" "$([ "$POD_READY" = "Running" ] && echo true || echo false)" "status: $POD_READY"
done

########################################
# Phase 3: Gateway integration
########################################
echo ""
echo "--- Phase 3: Gateway integration ---"

for SERVER in test-server1 test-server2; do
  HR_EXISTS=$(kubectl get httproute "$SERVER" -n mcp-test -o name 2>/dev/null)
  check "${SERVER}: HTTPRoute created" "$([ -n "$HR_EXISTS" ] && echo true || echo false)"

  REG_EXISTS=$(kubectl get mcpserverregistration "$SERVER" -n mcp-test -o name 2>/dev/null)
  check "${SERVER}: MCPServerRegistration created" "$([ -n "$REG_EXISTS" ] && echo true || echo false)"

  TOOL_PREFIX=$(kubectl get mcpserverregistration "$SERVER" -n mcp-test -o jsonpath='{.spec.toolPrefix}' 2>/dev/null)
  check "${SERVER}: Has toolPrefix" "$([ -n "$TOOL_PREFIX" ] && echo true || echo false)" "prefix: $TOOL_PREFIX"
done

# AuthPolicies
for POLICY in mcp-auth-policy server1-auth-policy server2-auth-policy; do
  NS="mcp-test"
  [ "$POLICY" = "mcp-auth-policy" ] && NS="gateway-system"
  AP_EXISTS=$(kubectl get authpolicy "$POLICY" -n "$NS" -o name 2>/dev/null)
  check "AuthPolicy ${POLICY} exists" "$([ -n "$AP_EXISTS" ] && echo true || echo false)"
done

########################################
# Phase 4: Authentication (Keycloak)
########################################
echo ""
echo "--- Phase 4: Authentication ---"

# Keycloak accessible
KC_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${KEYCLOAK_URL}/realms/${REALM}/.well-known/openid-configuration" 2>/dev/null)
check "Keycloak OIDC discovery responds" "$([ "$KC_CODE" = "200" ] && echo true || echo false)" "got HTTP $KC_CODE"

# Token issuance for all users
ALICE_TOKEN=$(get_token alice alice)
check "Keycloak issues token for alice" "$([ -n "$ALICE_TOKEN" ] && echo true || echo false)"

BOB_TOKEN=$(get_token bob bob)
check "Keycloak issues token for bob" "$([ -n "$BOB_TOKEN" ] && echo true || echo false)"

CAROL_TOKEN=$(get_token carol carol)
check "Keycloak issues token for carol" "$([ -n "$CAROL_TOKEN" ] && echo true || echo false)"

# Unauthenticated rejection
UNAUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  "${GATEWAY_URL}/mcp" 2>/dev/null)
check "Unauthenticated request rejected (401)" "$([ "$UNAUTH_CODE" = "401" ] && echo true || echo false)" "got HTTP $UNAUTH_CODE"

########################################
# Phase 5: Gateway tool access
########################################
echo ""
echo "--- Phase 5: Gateway tool access ---"

# Initialize sessions for all users
ALICE_SESSION=$(init_session "$ALICE_TOKEN")
check "alice: MCP session initialized" "$([ -n "$ALICE_SESSION" ] && echo true || echo false)"

BOB_SESSION=$(init_session "$BOB_TOKEN")
check "bob: MCP session initialized" "$([ -n "$BOB_SESSION" ] && echo true || echo false)"

CAROL_SESSION=$(init_session "$CAROL_TOKEN")
check "carol: MCP session initialized" "$([ -n "$CAROL_SESSION" ] && echo true || echo false)"

# List tools (use alice's session)
TOOLS_JSON=$(rpc_call "$ALICE_TOKEN" "$ALICE_SESSION" "tools/list")
TOOL_NAMES=$(echo "$TOOLS_JSON" | python3 -c "
import sys,json
data = json.load(sys.stdin)
tools = data.get('result',{}).get('tools',[])
for t in tools:
    print(t['name'])
" 2>/dev/null || echo "")

TOOL_COUNT=$(echo "$TOOL_NAMES" | grep -c . 2>/dev/null || echo "0")
check "Gateway returns federated tools" "$([ "${TOOL_COUNT:-0}" -gt 0 ] 2>/dev/null && echo true || echo false)" "found ${TOOL_COUNT} tools"

# Verify tools from both servers are present
HAS_S1_GREET=$(echo "$TOOL_NAMES" | grep -q "test_server1_greet" && echo true || echo false)
check "Tools include test_server1_greet" "$HAS_S1_GREET"

HAS_S2_HELLO=$(echo "$TOOL_NAMES" | grep -q "test_server2_hello_world" && echo true || echo false)
check "Tools include test_server2_hello_world" "$HAS_S2_HELLO"

# Call a tool to verify results (use alice who has greet access)
CALL_JSON=$(rpc_call "$ALICE_TOKEN" "$ALICE_SESSION" "tools/call" '{"name":"test_server1_greet","arguments":{"name":"pipeline-test"}}')
CALL_TEXT=$(echo "$CALL_JSON" | python3 -c "
import sys,json
data = json.load(sys.stdin)
content = data.get('result',{}).get('content',[])
print(content[0].get('text','') if content else '')
" 2>/dev/null || echo "")
check "Tool call returns result" "$(echo "$CALL_TEXT" | grep -qi "pipeline-test" && echo true || echo false)" "got: $CALL_TEXT"

########################################
# Phase 6: Authorization matrix
########################################
echo ""
echo "--- Phase 6: Authorization matrix ---"
echo ""
echo "  Policies: developers → server1:[greet], server2:[set_time]"
echo "            ops        → server1:[add_tool], server2:[auth1234, set_time]"
echo ""
printf "  %-8s %-30s %-6s %s\n" "USER" "TOOL" "EXPECT" "RESULT"
printf "  %-8s %-30s %-6s %s\n" "--------" "------------------------------" "------" "----------"

# Server1: greet (dev-only)
assert_tool "alice" "test_server1_greet" "allow" "$ALICE_TOKEN" "$ALICE_SESSION" '{"name":"test"}'
assert_tool "bob"   "test_server1_greet" "deny"  "$BOB_TOKEN"   "$BOB_SESSION"   '{"name":"test"}'
assert_tool "carol" "test_server1_greet" "allow" "$CAROL_TOKEN" "$CAROL_SESSION" '{"name":"test"}'

# Server1: add_tool (ops-only)
assert_tool "alice" "test_server1_add_tool" "deny"  "$ALICE_TOKEN" "$ALICE_SESSION" '{"name":"x","description":"x"}'
assert_tool "bob"   "test_server1_add_tool" "allow" "$BOB_TOKEN"   "$BOB_SESSION"   '{"name":"x","description":"x"}'
assert_tool "carol" "test_server1_add_tool" "allow" "$CAROL_TOKEN" "$CAROL_SESSION" '{"name":"x","description":"x"}'

# Server2: hello_world (no group has access)
assert_tool "alice" "test_server2_hello_world" "deny" "$ALICE_TOKEN" "$ALICE_SESSION"
assert_tool "bob"   "test_server2_hello_world" "deny" "$BOB_TOKEN"   "$BOB_SESSION"
assert_tool "carol" "test_server2_hello_world" "deny" "$CAROL_TOKEN" "$CAROL_SESSION"

# Server2: auth1234 (ops-only)
assert_tool "alice" "test_server2_auth1234" "deny"  "$ALICE_TOKEN" "$ALICE_SESSION"
assert_tool "bob"   "test_server2_auth1234" "allow" "$BOB_TOKEN"   "$BOB_SESSION"
assert_tool "carol" "test_server2_auth1234" "allow" "$CAROL_TOKEN" "$CAROL_SESSION"

# Server2: set_time (shared)
assert_tool "alice" "test_server2_set_time" "allow" "$ALICE_TOKEN" "$ALICE_SESSION" '{"time":"12:00"}'
assert_tool "bob"   "test_server2_set_time" "allow" "$BOB_TOKEN"   "$BOB_SESSION"   '{"time":"12:00"}'
assert_tool "carol" "test_server2_set_time" "allow" "$CAROL_TOKEN" "$CAROL_SESSION" '{"time":"12:00"}'

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
