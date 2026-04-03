#!/usr/bin/env bash
# test-pipeline.sh — Verify the full MCP ecosystem pipeline
#
# Tests the end-to-end flow:
#   1. Catalog API lists available servers
#   2. Deploy a server via MCPServer CR (simulating what the launcher does)
#   3. Lifecycle operator creates Deployment + Service + HTTPRoute + MCPServerRegistration
#   4. Gateway discovers the server and federates its tools
#   5. Authenticated tool calls succeed through the gateway
#
# Usage: ./scripts/test-pipeline.sh
#        Run from the repo root directory after ./scripts/setup.sh has completed.
#
# By default, test-server1 is already deployed by setup.sh. This script verifies
# the resources exist and tests gateway access. Pass --deploy to skip setup.sh's
# server deployment and test the full deploy-from-scratch pipeline instead.

set -uo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://mcp.127-0-0-1.sslip.io:8001}"
OIDC_URL="${OIDC_URL:-http://localhost:8003}"

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

########################################
# 1. Catalog API
########################################
echo "================================================"
echo "  MCP Ecosystem Pipeline Test"
echo "================================================"
echo ""
echo "--- Phase 1: Catalog API ---"

# Port-forward to catalog and mini-oidc in background
kubectl port-forward svc/mcp-catalog -n catalog-system 18080:8080 &>/dev/null &
PF_CATALOG_PID=$!
kubectl port-forward svc/mini-oidc -n mcp-test 18003:9090 &>/dev/null &
PF_OIDC_PID=$!
sleep 2

# Cleanup port-forwards on exit
cleanup() {
  kill $PF_CATALOG_PID 2>/dev/null || true
  kill $PF_OIDC_PID 2>/dev/null || true
}
trap cleanup EXIT

CATALOG_RESPONSE=$(curl -s http://localhost:18080/api/mcp_catalog/v1alpha1/mcp_servers 2>/dev/null)
SERVER_COUNT=$(echo "$CATALOG_RESPONSE" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('items',[])))" 2>/dev/null || echo "0")
check "Catalog API responds" "$([ "$SERVER_COUNT" -gt 0 ] && echo true || echo false)" "got $SERVER_COUNT servers"

HAS_TEST_SERVER=$(echo "$CATALOG_RESPONSE" | python3 -c "
import sys,json
items = json.load(sys.stdin).get('items',[])
print('true' if any('test-server1' in (i.get('name','')) for i in items) else 'false')
" 2>/dev/null || echo "false")
check "Catalog lists test-server1" "$HAS_TEST_SERVER"

# Get image URI from catalog
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

# catalog port-forward no longer needed for remaining phases
# (cleanup trap handles both port-forwards on exit)

########################################
# 2. Operator resources
########################################
echo ""
echo "--- Phase 2: Operator-created resources ---"

# Check that the MCPServer CR exists
MCPSERVER_EXISTS=$(kubectl get mcpserver test-server1 -n mcp-test -o name 2>/dev/null)
check "MCPServer CR exists" "$([ -n "$MCPSERVER_EXISTS" ] && echo true || echo false)"

# Check Deployment
DEPLOY_EXISTS=$(kubectl get deployment test-server1 -n mcp-test -o name 2>/dev/null)
check "Operator created Deployment" "$([ -n "$DEPLOY_EXISTS" ] && echo true || echo false)"

# Check Service
SVC_EXISTS=$(kubectl get service test-server1 -n mcp-test -o name 2>/dev/null)
check "Operator created Service" "$([ -n "$SVC_EXISTS" ] && echo true || echo false)"

# Check pod is running
POD_READY=$(kubectl get pods -n mcp-test -l mcp-server=test-server1 -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
check "Server pod is Running" "$([ "$POD_READY" = "Running" ] && echo true || echo false)" "status: $POD_READY"

########################################
# 3. Gateway integration (operator gateway controller)
########################################
echo ""
echo "--- Phase 3: Gateway integration ---"

# Check HTTPRoute
HR_EXISTS=$(kubectl get httproute test-server1 -n mcp-test -o name 2>/dev/null)
check "Operator created HTTPRoute" "$([ -n "$HR_EXISTS" ] && echo true || echo false)"

# Check MCPServerRegistration
REG_EXISTS=$(kubectl get mcpserverregistration test-server1 -n mcp-test -o name 2>/dev/null)
check "Operator created MCPServerRegistration" "$([ -n "$REG_EXISTS" ] && echo true || echo false)"

# Check toolPrefix
TOOL_PREFIX=$(kubectl get mcpserverregistration test-server1 -n mcp-test -o jsonpath='{.spec.toolPrefix}' 2>/dev/null)
check "MCPServerRegistration has toolPrefix" "$([ -n "$TOOL_PREFIX" ] && echo true || echo false)" "prefix: $TOOL_PREFIX"

########################################
# 4. Authentication
########################################
echo ""
echo "--- Phase 4: Authentication ---"

# Get token from mini-oidc (POST required, use port-forwarded endpoint)
TOKEN=$(curl -s -X POST "http://localhost:18003/token" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
check "Mini-OIDC issues token" "$([ -n "$TOKEN" ] && echo true || echo false)"

# Verify unauthenticated request is rejected (Istio returns 403; see Key Findings in README)
UNAUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  "${GATEWAY_URL}/mcp" 2>/dev/null)
check "Unauthenticated request rejected (401/403)" "$([ "$UNAUTH_CODE" = "401" ] || [ "$UNAUTH_CODE" = "403" ] && echo true || echo false)" "got HTTP $UNAUTH_CODE"

########################################
# 5. Gateway tool access
########################################
echo ""
echo "--- Phase 5: Gateway tool access ---"

# Initialize MCP session
INIT_RESPONSE=$(curl -si -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test-pipeline","version":"1.0"}}}' \
  "${GATEWAY_URL}/mcp" 2>&1)
SESSION_ID=$(echo "$INIT_RESPONSE" | grep -i mcp-session-id | awk '{print $2}' | tr -d '\r')
check "MCP session initialized" "$([ -n "$SESSION_ID" ] && echo true || echo false)"

# List tools
TOOLS_RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  "${GATEWAY_URL}/mcp" 2>/dev/null)

# Parse response (may be plain JSON or SSE depending on gateway version)
TOOLS_JSON=$(echo "$TOOLS_RESPONSE" | grep "^data:" | sed 's/^data: //')
if [ -z "$TOOLS_JSON" ]; then
  TOOLS_JSON="$TOOLS_RESPONSE"
fi
TOOL_NAMES=$(echo "$TOOLS_JSON" | python3 -c "
import sys,json
data = json.load(sys.stdin)
tools = data.get('result',{}).get('tools',[])
for t in tools:
    print(t['name'])
" 2>/dev/null || echo "")

TOOL_COUNT=$(echo "$TOOL_NAMES" | grep -c . 2>/dev/null || echo "0")
check "Gateway returns federated tools" "$([ "${TOOL_COUNT:-0}" -gt 0 ] 2>/dev/null && echo true || echo false)" "found ${TOOL_COUNT} tools"

HAS_GREET=$(echo "$TOOL_NAMES" | grep -q "test_server1_greet" && echo true || echo false)
check "Tools include test_server1_greet" "$HAS_GREET"

HAS_TIME=$(echo "$TOOL_NAMES" | grep -q "test_server1_time" && echo true || echo false)
check "Tools include test_server1_time" "$HAS_TIME"

# Call a tool
CALL_RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"test_server1_greet","arguments":{"name":"pipeline-test"}}}' \
  "${GATEWAY_URL}/mcp" 2>/dev/null)

CALL_JSON=$(echo "$CALL_RESPONSE" | grep "^data:" | sed 's/^data: //')
if [ -z "$CALL_JSON" ]; then
  CALL_JSON="$CALL_RESPONSE"
fi
CALL_TEXT=$(echo "$CALL_JSON" | python3 -c "
import sys,json
data = json.load(sys.stdin)
content = data.get('result',{}).get('content',[])
print(content[0].get('text','') if content else '')
" 2>/dev/null || echo "")
check "Tool call returns result" "$(echo "$CALL_TEXT" | grep -qi "pipeline-test" && echo true || echo false)" "got: $CALL_TEXT"

# Call time tool (no args)
TIME_RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"test_server1_time","arguments":{}}}' \
  "${GATEWAY_URL}/mcp" 2>/dev/null)

TIME_JSON=$(echo "$TIME_RESPONSE" | grep "^data:" | sed 's/^data: //')
if [ -z "$TIME_JSON" ]; then
  TIME_JSON="$TIME_RESPONSE"
fi
TIME_TEXT=$(echo "$TIME_JSON" | python3 -c "
import sys,json
data = json.load(sys.stdin)
content = data.get('result',{}).get('content',[])
print(content[0].get('text','') if content else '')
" 2>/dev/null || echo "")
check "Time tool returns timestamp" "$([ -n "$TIME_TEXT" ] && echo true || echo false)" "got: $TIME_TEXT"

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
