#!/usr/bin/env bash
# mcp-cli.sh — Lightweight MCP client for the basic branch
#
# Authenticates via mini-oidc, initializes a gateway session,
# and provides an interactive loop to list and call tools.
#
# Usage: ./scripts/mcp-cli.sh

set -uo pipefail

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
echo "Authenticated as mcp-user (token valid for 1 hour)"

# --- Initialize session ---
echo ""
echo "Connecting to gateway at ${GATEWAY_URL}/mcp ..."
INIT_RESPONSE=$(curl -si -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"mcp-cli","version":"1.0"}}}' \
  "${GATEWAY_URL}/mcp" 2>&1)

SESSION_ID=$(echo "$INIT_RESPONSE" | grep -i mcp-session-id | awk '{print $2}' | tr -d '\r')
if [ -z "$SESSION_ID" ]; then
  echo "ERROR: Failed to initialize MCP session"
  echo "$INIT_RESPONSE"
  exit 1
fi
echo "Session established"

# --- JSON-RPC helper ---
REQUEST_ID=2
rpc_call() {
  local method="$1"
  local params="${2:-"{}"}"
  local response
  response=$(curl -s -H "Authorization: Bearer $TOKEN" \
    -H "Mcp-Session-Id: $SESSION_ID" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":${REQUEST_ID},\"method\":\"${method}\",\"params\":${params}}" \
    "${GATEWAY_URL}/mcp" 2>/dev/null)
  ((REQUEST_ID++))

  # Handle SSE or plain JSON
  local json
  json=$(echo "$response" | grep "^data:" | sed 's/^data: //')
  if [ -n "$json" ]; then
    echo "$json"
  else
    echo "$response"
  fi
}

# --- List tools ---
list_tools() {
  echo ""
  echo "Available tools:"
  echo "─────────────────────────────────────────────"
  rpc_call "tools/list" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tools = data.get('result', {}).get('tools', [])
for i, t in enumerate(tools, 1):
    name = t['name']
    desc = t.get('description', '')
    schema = t.get('inputSchema', {})
    props = schema.get('properties', {})
    required = schema.get('required', [])
    args = []
    for k, v in props.items():
        req = '*' if k in required else ''
        args.append(f'{k}{req}:{v.get(\"type\",\"?\")}')
    arg_str = ', '.join(args) if args else '(no args)'
    print(f'  {i}. {name}')
    print(f'     {desc}')
    print(f'     args: {arg_str}')
    print()
" 2>/dev/null
}

# --- Call tool ---
call_tool() {
  local tool_name="$1"
  local tool_args="$2"

  echo ""
  echo "Calling ${tool_name}..."
  local result
  result=$(rpc_call "tools/call" "{\"name\":\"${tool_name}\",\"arguments\":${tool_args}}")

  echo "$result" | python3 -c "
import sys, json
data = json.load(sys.stdin)
error = data.get('error')
if error:
    print(f'  ERROR: {error.get(\"message\", error)}')
else:
    content = data.get('result', {}).get('content', [])
    for c in content:
        text = c.get('text', '')
        print(f'  {text}')
" 2>/dev/null
}

# --- Interactive loop ---
list_tools

echo "─────────────────────────────────────────────"
echo "Commands:"
echo "  list              — list available tools"
echo "  call <tool> [json] — call a tool (json args optional)"
echo "  quit              — exit"
echo "─────────────────────────────────────────────"
echo ""

while true; do
  printf "mcp> "
  read -r line || break

  case "$line" in
    ""|" ")
      continue
      ;;
    quit|exit|q)
      echo "Bye."
      break
      ;;
    list)
      list_tools
      ;;
    call\ *)
      # Parse: call <tool_name> [json_args]
      parts=($line)
      tool="${parts[1]:-}"
      if [ -z "$tool" ]; then
        echo "  Usage: call <tool_name> [json_args]"
        continue
      fi
      # Everything after the tool name is JSON args
      args="${line#call ${tool}}"
      args="${args# }"  # trim leading space
      if [ -z "$args" ]; then
        args="{}"
      fi
      call_tool "$tool" "$args"
      ;;
    *)
      echo "  Unknown command. Try: list, call <tool> [json], quit"
      ;;
  esac
done
