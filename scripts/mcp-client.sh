#!/usr/bin/env bash
# mcp-client.sh — Interactive MCP client with OAuth device authorization flow
#
# Usage: ./scripts/mcp-client.sh
#
# Authenticates via Keycloak device flow (opens browser for login),
# then provides an interactive session to call MCP tools through the gateway.

set -uo pipefail
# Note: not using set -e — the interactive loop needs to survive individual command failures

KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak.127-0-0-1.sslip.io:8002}"
GATEWAY_URL="${GATEWAY_URL:-http://team-a.mcp.127-0-0-1.sslip.io:8001}"
CLIENT_ID="${CLIENT_ID:-mcp-cli}"
REALM="${REALM:-mcp}"
SCOPE="${SCOPE:-openid groups}"

TOKEN_ENDPOINT="${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token"
DEVICE_ENDPOINT="${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/auth/device"
LOGOUT_ENDPOINT="${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/logout"

ACCESS_TOKEN=""
SESSION_ID=""
IDENTITY=""
ID_TOKEN=""
REFRESH_TOKEN=""

# --- Authentication ---

do_login() {
  # If switching users, log out the existing Keycloak browser session first
  if [ "${1:-}" = "--switch" ]; then
    echo ""
    echo "Logging out current session..."

    # Back-channel: revoke the refresh token to kill the server-side session
    if [ -n "$REFRESH_TOKEN" ]; then
      curl -s -X POST "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/revoke" \
        -d "client_id=${CLIENT_ID}" \
        -d "token=${REFRESH_TOKEN}" \
        -d "token_type_hint=refresh_token" >/dev/null 2>&1
    fi

    # Front-channel: open logout URL in browser to clear the session cookie
    # id_token_hint lets Keycloak skip the "are you sure?" confirmation
    local logout_url="${LOGOUT_ENDPOINT}?client_id=${CLIENT_ID}"
    if [ -n "$ID_TOKEN" ]; then
      logout_url="${logout_url}&id_token_hint=${ID_TOKEN}"
    fi
    if command -v open &>/dev/null; then
      open "$logout_url" 2>/dev/null || true
    fi

    echo "Browser logout opened. Press Enter when you've been logged out..."
    read -r
  fi

  echo "Requesting device code..."
  local device_response
  device_response=$(curl -s -X POST "$DEVICE_ENDPOINT" \
    -d "client_id=${CLIENT_ID}" \
    -d "scope=${SCOPE}")

  local device_code user_code verification_url poll_interval
  device_code=$(echo "$device_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['device_code'])")
  user_code=$(echo "$device_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['user_code'])")
  verification_url=$(echo "$device_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['verification_uri_complete'])")
  poll_interval=$(echo "$device_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('interval', 5))")

  echo ""
  echo "=========================================="
  echo "  Open this URL in your browser:"
  echo ""
  echo "  ${verification_url}"
  echo ""
  echo "  Or go to: ${KEYCLOAK_URL}/realms/${REALM}/device"
  echo "  and enter code: ${user_code}"
  echo "=========================================="
  echo ""

  if command -v open &>/dev/null; then
    open "$verification_url" 2>/dev/null || true
  fi

  echo "Waiting for you to log in..."

  # Poll for token
  while true; do
    sleep "$poll_interval"

    local token_response error
    token_response=$(curl -s -X POST "$TOKEN_ENDPOINT" \
      -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
      -d "client_id=${CLIENT_ID}" \
      -d "device_code=${device_code}")

    error=$(echo "$token_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error', ''))" 2>/dev/null || echo "parse_error")

    if [ "$error" = "authorization_pending" ]; then
      printf "."
      continue
    elif [ "$error" = "slow_down" ]; then
      poll_interval=$((poll_interval + 1))
      continue
    elif [ "$error" = "" ]; then
      echo ""
      ACCESS_TOKEN=$(echo "$token_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
      ID_TOKEN=$(echo "$token_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id_token', ''))" 2>/dev/null || echo "")
      REFRESH_TOKEN=$(echo "$token_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('refresh_token', ''))" 2>/dev/null || echo "")
      break
    else
      echo ""
      echo "Error: $error"
      echo "$token_response" | python3 -m json.tool 2>/dev/null || echo "$token_response"
      return 1
    fi
  done

  # Show who we authenticated as
  IDENTITY=$(echo "$ACCESS_TOKEN" | python3 -c "
import sys,json,base64
parts = sys.stdin.read().strip().split('.')
payload = parts[1] + '=' * (4 - len(parts[1]) % 4)
d = json.loads(base64.urlsafe_b64decode(payload))
user = d.get('preferred_username', d.get('sub', 'unknown'))
groups = d.get('groups', [])
print(f'{user} (groups: {\", \".join(groups) if groups else \"none\"})')
")
  echo "Authenticated as: ${IDENTITY}"

  # Initialize MCP session
  echo ""
  echo "Initializing MCP session..."

  local init_response
  init_response=$(curl -si -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"mcp-cli","version":"1.0"}}}' \
    "${GATEWAY_URL}/mcp" 2>&1)

  SESSION_ID=$(echo "$init_response" | grep -i mcp-session-id | awk '{print $2}' | tr -d '\r')

  if [ -z "$SESSION_ID" ]; then
    echo "Failed to initialize session:"
    echo "$init_response"
    return 1
  fi

  echo "Session established."
  echo ""
}

# --- MCP call helper ---

mcp_call() {
  local method="$1"
  local params="${2:-"{}"}"
  local id=$((RANDOM % 10000 + 2))

  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({
    'jsonrpc': '2.0',
    'id': ${id},
    'method': sys.argv[1],
    'params': json.loads(sys.argv[2])
}))" "$method" "$params")

  local response
  response=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Mcp-Session-Id: $SESSION_ID" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d "$payload" \
    "${GATEWAY_URL}/mcp")

  # Handle both plain JSON and SSE (event: message\ndata: {...}) response formats
  printf '%s\n' "$response" | python3 -c "
import sys, json
raw = sys.stdin.read().strip()
# Try plain JSON first
try:
    print(json.dumps(json.loads(raw), indent=2))
except json.JSONDecodeError:
    # Parse SSE format: extract 'data:' lines
    for line in raw.splitlines():
        if line.startswith('data: '):
            try:
                print(json.dumps(json.loads(line[6:]), indent=2))
            except json.JSONDecodeError:
                print(line)
        elif line and not line.startswith('event:'):
            print(line)
" 2>/dev/null || printf '%s\n' "$response"
}

# --- Print tools ---

print_tools() {
  local tools_raw
  tools_raw=$(mcp_call "tools/list")
  printf '%s\n' "$tools_raw" | python3 -c "
import sys, json
raw = sys.stdin.read().strip()
# Handle both plain JSON and SSE format
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    # Parse SSE: find 'data:' line
    data = None
    for line in raw.splitlines():
        if line.startswith('data: '):
            try:
                data = json.loads(line[6:])
                break
            except json.JSONDecodeError:
                pass
    if data is None:
        print(raw)
        sys.exit(0)
for t in data.get('result', {}).get('tools', []):
    params = list(t.get('inputSchema', {}).get('properties', {}).keys())
    param_str = f'({\", \".join(params)})' if params else '()'
    print(f'  {t[\"name\"]}{param_str} — {t.get(\"description\", \"\")}')
" 2>/dev/null || printf '%s\n' "$tools_raw"
}

# --- Initial login ---

do_login || exit 1

echo "Available tools:"
echo "----------------"
print_tools

# --- Interactive loop ---

echo ""
echo "Enter tool calls as: tool_name {\"param\": \"value\"}"
echo "  or with key=value:  tool_name name=luffy"
echo "Commands: /login (switch user), /tools, /whoami, /raw METHOD {params}, /quit"
echo ""

while true; do
  printf "\033[1mmcp>\033[0m "
  read -r INPUT || break

  [ -z "$INPUT" ] && continue

  case "$INPUT" in
    /quit|/exit|/q)
      echo "Goodbye."
      break
      ;;
    /login)
      do_login --switch
      echo "Available tools:"
      echo "----------------"
      print_tools
      echo ""
      ;;
    /tools)
      print_tools
      ;;
    /whoami)
      echo "$IDENTITY"
      ;;
    /raw\ *)
      METHOD=$(echo "$INPUT" | awk '{print $2}')
      PARAMS=$(echo "$INPUT" | cut -d' ' -f3-)
      [ -z "$PARAMS" ] && PARAMS="{}"
      mcp_call "$METHOD" "$PARAMS"
      ;;
    *)
      TOOL_NAME=$(echo "$INPUT" | awk '{print $1}')
      TOOL_ARGS=$(echo "$INPUT" | cut -d' ' -f2-)
      if [ "$TOOL_ARGS" = "$TOOL_NAME" ]; then
        TOOL_ARGS="{}"
      fi
      # Build params JSON safely via python (handles both JSON and key=value input)
      CALL_PARAMS=$(python3 -c "
import json, sys
name = sys.argv[1]
args_str = sys.argv[2]
try:
    args = json.loads(args_str)
except json.JSONDecodeError:
    # Try key=value format: name=luffy age=19
    args = {}
    for pair in args_str.split():
        if '=' in pair:
            k, v = pair.split('=', 1)
            try:
                v = json.loads(v)
            except (json.JSONDecodeError, ValueError):
                pass
            args[k] = v
print(json.dumps({'name': name, 'arguments': args}))
" "$TOOL_NAME" "$TOOL_ARGS")
      mcp_call "tools/call" "$CALL_PARAMS"
      ;;
  esac
done
