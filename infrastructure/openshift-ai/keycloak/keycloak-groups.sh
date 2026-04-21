#!/usr/bin/env bash
# Create Keycloak groups and assign users for VirtualMCPServer routing.
#
# The realm import (keycloak.yaml) creates users and roles.
# This script adds groups that the gateway AuthPolicy uses to route
# to the correct VirtualMCPServer (via x-mcp-virtualserver header).
#
# Groups created:
#   mcp-admins  — routes to team-a/admin-tools (all OpenShift + test tools)
#   mcp-github  — routes to team-a/github-tools (GitHub tools)
#   mcp-users   — routes to team-a/user-tools (test tools only)
#
# Prerequisites:
#   - Keycloak running with mcp-gateway realm imported
#   - Requires: KEYCLOAK_ADMIN_PASSWORD or reads from keycloak-initial-admin secret
#
# Usage: ./keycloak-groups.sh

set -euo pipefail

KEYCLOAK_HOST="${KEYCLOAK_HOST:-keycloak.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-mcp-gateway}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-temp-admin}"

if [ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]; then
  KEYCLOAK_ADMIN_PASSWORD=$(oc get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d)
fi

KC_BASE="https://${KEYCLOAK_HOST}"

echo "=== Get admin token ==="
KC_TOKEN=$(curl -sk -X POST "${KC_BASE}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=${KEYCLOAK_ADMIN}&password=${KEYCLOAK_ADMIN_PASSWORD}" \
  | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['access_token'])")

create_group() {
  local name=$1
  echo "Creating group: $name"
  curl -sk -X POST -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
    "${KC_BASE}/admin/realms/${KEYCLOAK_REALM}/groups" \
    -d "{\"name\": \"$name\"}" -w " HTTP %{http_code}\n" -o /dev/null
}

get_group_id() {
  local name=$1
  curl -sk -H "Authorization: Bearer $KC_TOKEN" \
    "${KC_BASE}/admin/realms/${KEYCLOAK_REALM}/groups?search=$name" \
    | python3 -c "import sys,json; groups=json.loads(sys.stdin.read()); print(next(g['id'] for g in groups if g['name']=='$name'))"
}

get_user_id() {
  local username=$1
  curl -sk -H "Authorization: Bearer $KC_TOKEN" \
    "${KC_BASE}/admin/realms/${KEYCLOAK_REALM}/users?username=$username&exact=true" \
    | python3 -c "import sys,json; print(json.loads(sys.stdin.read())[0]['id'])"
}

add_user_to_group() {
  local username=$1
  local group_name=$2
  local user_id group_id
  user_id=$(get_user_id "$username")
  group_id=$(get_group_id "$group_name")
  echo "  Adding $username to $group_name"
  curl -sk -X PUT -H "Authorization: Bearer $KC_TOKEN" \
    "${KC_BASE}/admin/realms/${KEYCLOAK_REALM}/users/${user_id}/groups/${group_id}" \
    -w " HTTP %{http_code}\n" -o /dev/null
}

echo "=== Create groups ==="
create_group "mcp-admins"
create_group "mcp-github"
create_group "mcp-users"

echo "=== Assign users ==="
add_user_to_group "mcp-admin1" "mcp-admins"
add_user_to_group "mcp-admin1" "mcp-github"
add_user_to_group "mcp-user1" "mcp-users"

echo "=== Add groups client scope ==="
# Ensure the groups claim is included in tokens
CLIENT_ID=$(curl -sk -H "Authorization: Bearer $KC_TOKEN" \
  "${KC_BASE}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=mcp-playground" \
  | python3 -c "import sys,json; print(json.loads(sys.stdin.read())[0]['id'])")

MAPPERS_URL="${KC_BASE}/admin/realms/${KEYCLOAK_REALM}/clients/${CLIENT_ID}/protocol-mappers/models"

curl -sk -X POST -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
  "$MAPPERS_URL" -d '{
    "name": "groups",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-group-membership-mapper",
    "config": {
      "full.path": "false",
      "id.token.claim": "true",
      "access.token.claim": "true",
      "claim.name": "groups",
      "userinfo.token.claim": "true"
    }
  }' -w " HTTP %{http_code}\n" -o /dev/null

echo ""
echo "=== Done ==="
echo "Test: get a token for mcp-admin1 and decode it — should have groups: [mcp-admins, mcp-github]"
