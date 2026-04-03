#!/usr/bin/env bash
# mcp-client.sh — Interactive MCP client for the basic branch
#
# Authenticates via mini-oidc, initializes a gateway session,
# and provides an interactive loop to list and call tools.
#
# Usage: ./scripts/mcp-client.sh

set -uo pipefail
# Note: not using set -e — the interactive loop needs to survive individual command failures

GATEWAY_URL="${GATEWAY_URL:-http://mcp.127-0-0-1.sslip.io:8001}"
OIDC_PORT="${OIDC_PORT:-18003}"

# --- Setup port-forward for mini-oidc ---
cleanup() {
  kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

kubectl port-forward svc/mini-oidc -n mcp-test "${OIDC_PORT}:9090" &>/dev/null &
PF_PID=$!
sleep 2

# --- Get token ---
echo "Authenticating with mini-oidc..."
TOKEN=$(curl -s -X POST "http://localhost:${OIDC_PORT}/token" 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)

if [ -z "$TOKEN" ]; then
  echo "ERROR: Failed to get token from mini-oidc"
  exit 1
fi

IDENTITY=$(printf '%s' "$TOKEN" | python3 -c "
import sys,json,base64
parts = sys.stdin.read().strip().split('.')
payload = parts[1] + '=' * (4 - len(parts[1]) % 4)
d = json.loads(base64.urlsafe_b64decode(payload))
user = d.get('preferred_username', d.get('sub', 'unknown'))
print(user)
" 2>/dev/null || echo "mcp-user")
echo "Authenticated as ${IDENTITY}"

# --- Initialize session ---
echo ""
echo "Connecting to gateway at ${GATEWAY_URL}/mcp ..."
INIT_RESPONSE=$(curl -si -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"mcp-client","version":"1.0"}}}' \
  "${GATEWAY_URL}/mcp" 2>&1)

SESSION_ID=$(printf '%s' "$INIT_RESPONSE" | grep -i mcp-session-id | awk '{print $2}' | tr -d '\r')
if [ -z "$SESSION_ID" ]; then
  echo "ERROR: Failed to initialize MCP session"
  printf '%s\n' "$INIT_RESPONSE"
  exit 1
fi
echo "Session established."
echo ""

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
  response=$(curl -s -H "Authorization: Bearer $TOKEN" \
    -H "Mcp-Session-Id: $SESSION_ID" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d "$payload" \
    "${GATEWAY_URL}/mcp")

  # Handle both plain JSON and SSE (event: message\ndata: {...}) response formats
  # Use printf instead of echo to avoid zsh interpreting \n in JSON strings
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
try:
    data = json.loads(raw)
except json.JSONDecodeError:
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

# --- Initial tool listing ---

echo "Available tools:"
echo "----------------"
print_tools

# --- Interactive loop ---

echo ""
echo "Enter tool calls as: tool_name {\"param\": \"value\"}"
echo "  or with key=value:  tool_name name=World"
echo "Commands: /tools, /whoami, /raw METHOD {params}, /quit"
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
      # Build params JSON safely via python3 (handles both JSON and key=value input)
      CALL_PARAMS=$(python3 -c "
import json, sys
name = sys.argv[1]
args_str = sys.argv[2]
try:
    args = json.loads(args_str)
except json.JSONDecodeError:
    # Try key=value format: name=World greeting=Hello
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
