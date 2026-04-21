#!/usr/bin/env bash
# Vault post-install configuration for MCP Gateway credential injection.
#
# Prerequisites:
#   helm install vault hashicorp/vault -n openshift-operators -f vault-helm-values.yaml
#   oc wait pod/vault-0 -n openshift-operators --for=condition=Ready --timeout=120s
#
# Usage:
#   ./vault-configure.sh
#
# This script:
#   1. Initializes Vault (1 key share, threshold 1) — saves credentials to vault-credentials.json
#   2. Unseals Vault
#   3. Enables KV v2 secrets engine at mcp/
#   4. Enables JWT auth with Keycloak JWKS
#   5. Creates a templated policy for per-user secret access
#   6. Creates a JWT login role with claim mappings
#   7. Stores an example secret for mcp-admin1

set -euo pipefail

VAULT_NS="${VAULT_NS:-openshift-operators}"
VAULT_POD="${VAULT_POD:-vault-0}"
KEYCLOAK_HOST="${KEYCLOAK_HOST:-keycloak.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-mcp-gateway}"
CREDS_FILE="vault-credentials.json"

vault_exec() {
  oc exec -n "$VAULT_NS" "$VAULT_POD" -- sh -c "export VAULT_TOKEN=$VAULT_TOKEN; $1"
}

echo "=== Step 1: Initialize Vault ==="
if oc exec -n "$VAULT_NS" "$VAULT_POD" -- vault status 2>&1 | grep -q "Initialized.*true"; then
  echo "Already initialized. Reading credentials from $CREDS_FILE"
  UNSEAL_KEY=$(python3 -c "import json; print(json.load(open('$CREDS_FILE'))['unseal_keys_b64'][0])")
  VAULT_TOKEN=$(python3 -c "import json; print(json.load(open('$CREDS_FILE'))['root_token'])")
else
  oc exec -n "$VAULT_NS" "$VAULT_POD" -- vault operator init \
    -key-shares=1 -key-threshold=1 -format=json > "$CREDS_FILE"
  UNSEAL_KEY=$(python3 -c "import json; print(json.load(open('$CREDS_FILE'))['unseal_keys_b64'][0])")
  VAULT_TOKEN=$(python3 -c "import json; print(json.load(open('$CREDS_FILE'))['root_token'])")
  echo "Credentials saved to $CREDS_FILE"
fi

echo "=== Step 2: Unseal Vault ==="
if oc exec -n "$VAULT_NS" "$VAULT_POD" -- vault status 2>&1 | grep -q "Sealed.*true"; then
  oc exec -n "$VAULT_NS" "$VAULT_POD" -- vault operator unseal "$UNSEAL_KEY"
  echo "Unsealed"
else
  echo "Already unsealed"
fi

echo "=== Step 3: Enable KV v2 at mcp/ ==="
vault_exec "vault secrets enable -path=mcp kv-v2 2>/dev/null || echo 'Already enabled'"

echo "=== Step 4: Enable JWT auth with Keycloak JWKS ==="
vault_exec "vault auth enable jwt 2>/dev/null || echo 'Already enabled'"

JWKS_URL="https://${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/certs"
vault_exec "vault write auth/jwt/config jwks_url='$JWKS_URL'"
echo "JWKS URL: $JWKS_URL"

echo "=== Step 5: Get JWT auth mount accessor ==="
JWT_ACCESSOR=$(vault_exec "vault auth list -format=json" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['jwt/']['accessor'])")
echo "JWT accessor: $JWT_ACCESSOR"

echo "=== Step 6: Create per-user secrets policy ==="
vault_exec "vault policy write mcp-user-secrets - <<'POLICY'
path \"mcp/data/users/{{identity.entity.aliases.${JWT_ACCESSOR}.metadata.preferred_username}}/*\" {
  capabilities = [\"read\"]
}
POLICY"

echo "=== Step 7: Create JWT login role ==="
vault_exec "vault write auth/jwt/role/mcp-user \
  role_type=jwt \
  bound_audiences=mcp-gateway,mcp-playground \
  user_claim=sub \
  claim_mappings=sub=sub \
  claim_mappings=preferred_username=preferred_username \
  policies=mcp-user-secrets \
  ttl=1h"

echo "=== Step 8: Store example secret ==="
vault_exec "vault kv put mcp/users/mcp-admin1/github token=ghp_PLACEHOLDER_REPLACE_WITH_REAL_PAT"

echo ""
echo "=== Done ==="
echo "Vault root token: $VAULT_TOKEN"
echo "Unseal key:       $UNSEAL_KEY"
echo "JWT accessor:     $JWT_ACCESSOR"
echo ""
echo "Test: vault write auth/jwt/login role=mcp-user jwt=<keycloak-jwt>"
echo "Then: vault read mcp/data/users/mcp-admin1/github"
