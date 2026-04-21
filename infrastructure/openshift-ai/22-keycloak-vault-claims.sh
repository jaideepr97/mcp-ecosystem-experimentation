#!/usr/bin/env bash
# Add sub + preferred_username claims to a Keycloak client.
#
# The mcp-playground client's JWTs need these claims for Vault:
#   - sub: user UUID, used as Vault entity alias name
#   - preferred_username: used in Vault policy path templating
#
# Usage:
#   ./22-keycloak-vault-claims.sh
#
# Requires: KEYCLOAK_ADMIN_PASSWORD or reads from keycloak-initial-admin secret

set -euo pipefail

KEYCLOAK_HOST="${KEYCLOAK_HOST:-keycloak.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-mcp-gateway}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-temp-admin}"
KEYCLOAK_CLIENT_NAME="${KEYCLOAK_CLIENT_NAME:-mcp-playground}"

if [ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]; then
  KEYCLOAK_ADMIN_PASSWORD=$(oc get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d)
fi

KC_BASE="https://${KEYCLOAK_HOST}"

echo "=== Get admin token ==="
KC_TOKEN=$(curl -sk -X POST "${KC_BASE}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=${KEYCLOAK_ADMIN}&password=${KEYCLOAK_ADMIN_PASSWORD}" \
  | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['access_token'])")

echo "=== Find client UUID ==="
CLIENT_ID=$(curl -sk -H "Authorization: Bearer $KC_TOKEN" \
  "${KC_BASE}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${KEYCLOAK_CLIENT_NAME}" \
  | python3 -c "import sys,json; print(json.loads(sys.stdin.read())[0]['id'])")
echo "Client UUID: $CLIENT_ID"

MAPPERS_URL="${KC_BASE}/admin/realms/${KEYCLOAK_REALM}/clients/${CLIENT_ID}/protocol-mappers/models"

echo "=== Add sub mapper ==="
curl -sk -X POST -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
  "$MAPPERS_URL" -d '{
    "name": "sub",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-sub-mapper",
    "config": {
      "id.token.claim": "true",
      "access.token.claim": "true",
      "introspection.token.claim": "true"
    }
  }' -w "\nHTTP %{http_code}\n" -o /dev/null

echo "=== Add preferred_username mapper ==="
curl -sk -X POST -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
  "$MAPPERS_URL" -d '{
    "name": "preferred_username",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-usermodel-attribute-mapper",
    "config": {
      "user.attribute": "username",
      "claim.name": "preferred_username",
      "jsonType.label": "String",
      "id.token.claim": "true",
      "access.token.claim": "true",
      "introspection.token.claim": "true"
    }
  }' -w "\nHTTP %{http_code}\n" -o /dev/null

echo "=== Add audience mapper ==="
curl -sk -X POST -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
  "$MAPPERS_URL" -d '{
    "name": "mcp-playground-audience",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-audience-mapper",
    "config": {
      "id.token.claim": "false",
      "access.token.claim": "true",
      "introspection.token.claim": "true",
      "included.custom.audience": "mcp-playground",
      "userinfo.token.claim": "false"
    }
  }' -w "\nHTTP %{http_code}\n" -o /dev/null

echo ""
echo "=== Verify ==="
TOKEN=$(curl -sk -X POST "${KC_BASE}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=${KEYCLOAK_CLIENT_NAME}&username=mcp-admin1&password=admin1pass&scope=openid" \
  | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['access_token'])")

echo "$TOKEN" | cut -d. -f2 | python3 -c "
import sys, base64, json
payload = sys.stdin.read().strip()
payload += '=' * (4 - len(payload) % 4)
decoded = json.loads(base64.urlsafe_b64decode(payload))
for k in ['sub', 'preferred_username', 'aud', 'realm_access']:
    print(f'  {k}: {decoded.get(k, \"MISSING\")}')
"
