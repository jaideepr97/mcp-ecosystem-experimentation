#!/bin/bash
# Store a GitHub PAT in Vault for a Keycloak user.
#
# Usage:
#   export GITHUB_PAT=ghp_YOUR_TOKEN
#   ./scripts/store-github-pat.sh alice
#   ./scripts/store-github-pat.sh alice bob carol   # multiple users, same PAT

set -euo pipefail

if [ -z "${GITHUB_PAT:-}" ]; then
  echo "Error: GITHUB_PAT environment variable not set"
  echo ""
  echo "Get a token at: https://github.com/settings/tokens/new"
  echo "Required scope: read:user (minimum)"
  echo ""
  echo "  export GITHUB_PAT=ghp_YOUR_TOKEN"
  exit 1
fi

if [ $# -eq 0 ]; then
  echo "Usage: $0 <username> [username...]"
  echo "  Stores GITHUB_PAT in Vault for each Keycloak user."
  exit 1
fi

KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak.127-0-0-1.sslip.io:8002}"
TOKEN_ENDPOINT="${KEYCLOAK_URL}/realms/mcp/protocol/openid-connect/token"

for USER in "$@"; do
  echo -n "Storing PAT for ${USER}... "

  # Get the user's sub claim from a token
  USER_SUB=$(curl -s "$TOKEN_ENDPOINT" \
    -d "grant_type=password" -d "client_id=mcp-cli" \
    -d "username=${USER}" -d "password=${USER}" -d "scope=openid" 2>/dev/null | \
    python3 -c "import sys,json,base64; t=json.load(sys.stdin)['access_token']; print(json.loads(base64.urlsafe_b64decode(t.split('.')[1]+'=='))['sub'])" 2>/dev/null)

  if [ -z "$USER_SUB" ]; then
    echo "FAILED (could not get token for ${USER})"
    continue
  fi

  kubectl exec -n vault deploy/vault -- sh -c \
    "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault kv put secret/mcp-gateway/${USER_SUB} github_pat=${GITHUB_PAT}" \
    >/dev/null 2>&1

  echo "OK (sub: ${USER_SUB})"
done
