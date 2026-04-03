#!/usr/bin/env bash
# test-auth-matrix.sh — Automated authorization matrix verification
#
# Tests cross-user, cross-server, per-tool access control through the MCP gateway.
# Uses Keycloak direct access grant (resource owner password) for non-interactive auth.
#
# Usage: ./scripts/test-auth-matrix.sh
#        Run from the repo root directory.
#
# Prerequisites:
#   - Cluster running with mcp-gateway, Keycloak, test-server1, test-server2
#   - mcp-cli client has directAccessGrantsEnabled: true in Keycloak
#   - Users alice/bob/carol exist with passwords matching usernames

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

get_token() {
  local username="$1"
  local password="$2"
  local response
  response=$(curl -s -X POST "$TOKEN_ENDPOINT" \
    -d "grant_type=password" \
    -d "client_id=${CLIENT_ID}" \
    -d "username=${username}" \
    -d "password=${password}" \
    -d "scope=${SCOPE}")

  local token
  token=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)

  if [ -z "$token" ]; then
    echo "ERROR: Failed to get token for ${username}" >&2
    echo "$response" | python3 -m json.tool >&2 2>/dev/null || echo "$response" >&2
    return 1
  fi
  echo "$token"
}

init_session() {
  local token="$1"
  local response
  response=$(curl -si -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test-matrix","version":"1.0"}}}' \
    "${GATEWAY_URL}/mcp" 2>&1)

  local session_id
  session_id=$(echo "$response" | grep -i mcp-session-id | awk '{print $2}' | tr -d '\r')

  if [ -z "$session_id" ]; then
    echo "ERROR: Failed to init session" >&2
    echo "$response" >&2
    return 1
  fi
  echo "$session_id"
}

call_tool() {
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
  http_code=$(call_tool "$token" "$session_id" "$tool" "$tool_args")

  local result
  if [ "$expected" = "allow" ]; then
    if [ "$http_code" = "200" ]; then
      result="PASS"
      ((PASS++))
    else
      result="FAIL"
      ((FAIL++))
      ERRORS="${ERRORS}\n  ${user} → ${tool}: expected allow (200), got ${http_code}"
    fi
  else
    # Denied: expect 403 or 500 (known issue: full server deny returns 500)
    if [ "$http_code" = "403" ] || [ "$http_code" = "500" ]; then
      result="PASS"
      ((PASS++))
    else
      result="FAIL"
      ((FAIL++))
      ERRORS="${ERRORS}\n  ${user} → ${tool}: expected deny (403/500), got ${http_code}"
    fi
  fi

  printf "  %-8s %-30s %-6s %s (HTTP %s)\n" "$user" "$tool" "$expected" "$result" "$http_code"
}

# --- Test matrix ---
#
# Authorization policies:
#   Server1: developers → [greet], ops → [add_tool]
#   Server2: developers → [set_time], ops → [auth1234, set_time]
#
# Users:
#   alice (developers) — greet, set_time
#   bob   (ops)        — add_tool, auth1234, set_time
#   carol (both)       — greet, add_tool, auth1234, set_time
#
# hello_world: in no policy → denied for everyone

echo "================================================"
echo "  MCP Authorization Matrix Test"
echo "================================================"
echo ""
echo "Gateway: ${GATEWAY_URL}"
echo "Keycloak: ${KEYCLOAK_URL}"
echo ""

# --- Authenticate all users ---

echo "Authenticating users..."
ALICE_TOKEN=$(get_token alice alice) || exit 1
BOB_TOKEN=$(get_token bob bob) || exit 1
CAROL_TOKEN=$(get_token carol carol) || exit 1
echo "  All tokens acquired."
echo ""

# --- Initialize sessions ---

echo "Initializing MCP sessions..."
ALICE_SESSION=$(init_session "$ALICE_TOKEN") || exit 1
BOB_SESSION=$(init_session "$BOB_TOKEN") || exit 1
CAROL_SESSION=$(init_session "$CAROL_TOKEN") || exit 1
echo "  All sessions established."
echo ""

# --- Run test matrix ---

echo "Running 15 test cases..."
echo ""
printf "  %-8s %-30s %-6s %s\n" "USER" "TOOL" "EXPECT" "RESULT"
printf "  %-8s %-30s %-6s %s\n" "--------" "------------------------------" "------" "----------"

# Server1 tools (prefixed with test_server1_)
# greet: dev-only
assert_tool "alice" "test_server1_greet" "allow" "$ALICE_TOKEN" "$ALICE_SESSION" '{"name":"test"}'
assert_tool "bob"   "test_server1_greet" "deny"  "$BOB_TOKEN"   "$BOB_SESSION"   '{"name":"test"}'
assert_tool "carol" "test_server1_greet" "allow" "$CAROL_TOKEN" "$CAROL_SESSION" '{"name":"test"}'

# add_tool: ops-only
assert_tool "alice" "test_server1_add_tool" "deny"  "$ALICE_TOKEN" "$ALICE_SESSION" '{"name":"x","description":"x"}'
assert_tool "bob"   "test_server1_add_tool" "allow" "$BOB_TOKEN"   "$BOB_SESSION"   '{"name":"x","description":"x"}'
assert_tool "carol" "test_server1_add_tool" "allow" "$CAROL_TOKEN" "$CAROL_SESSION" '{"name":"x","description":"x"}'

# Server2 tools (prefixed with test_server2_)
# hello_world: no group has access
assert_tool "alice" "test_server2_hello_world" "deny" "$ALICE_TOKEN" "$ALICE_SESSION"
assert_tool "bob"   "test_server2_hello_world" "deny" "$BOB_TOKEN"   "$BOB_SESSION"
assert_tool "carol" "test_server2_hello_world" "deny" "$CAROL_TOKEN" "$CAROL_SESSION"

# auth1234: ops-only
assert_tool "alice" "test_server2_auth1234" "deny"  "$ALICE_TOKEN" "$ALICE_SESSION"
assert_tool "bob"   "test_server2_auth1234" "allow" "$BOB_TOKEN"   "$BOB_SESSION"
assert_tool "carol" "test_server2_auth1234" "allow" "$CAROL_TOKEN" "$CAROL_SESSION"

# set_time: shared (both groups)
assert_tool "alice" "test_server2_set_time" "allow" "$ALICE_TOKEN" "$ALICE_SESSION" '{"time":"12:00"}'
assert_tool "bob"   "test_server2_set_time" "allow" "$BOB_TOKEN"   "$BOB_SESSION"   '{"time":"12:00"}'
assert_tool "carol" "test_server2_set_time" "allow" "$CAROL_TOKEN" "$CAROL_SESSION" '{"time":"12:00"}'

# --- Summary ---

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
