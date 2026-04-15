#!/bin/bash
# Configure Vault for MCP Gateway token exchange.
# Enables JWT auth backed by Keycloak, creates policy and role for Authorino.
#
# Prerequisites: Vault pod running in vault namespace, Keycloak accessible.
# Usage: called by setup.sh after Vault deployment

set -euo pipefail

VAULT_NS="vault"
VAULT_CMD="VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root"

echo "  Enabling KV v2 secrets engine..."
kubectl exec -n "$VAULT_NS" deploy/vault -- sh -c \
  "${VAULT_CMD} vault secrets enable -version=2 -path=secret kv" 2>/dev/null || true

echo "  Enabling JWT auth method..."
kubectl exec -n "$VAULT_NS" deploy/vault -- sh -c \
  "${VAULT_CMD} vault auth enable jwt" 2>/dev/null || true

echo "  Configuring JWT auth with Keycloak JWKS..."
kubectl exec -n "$VAULT_NS" deploy/vault -- sh -c \
  "${VAULT_CMD} vault write auth/jwt/config \
    jwks_url=\"http://keycloak.keycloak.svc.cluster.local/realms/mcp/protocol/openid-connect/certs\" \
    default_role=\"authorino\""

echo "  Creating Vault policy (read secret/data/mcp-gateway/*)..."
printf 'path "secret/data/mcp-gateway/*" {\n  capabilities = ["read"]\n}\n' | \
  kubectl exec -i -n "$VAULT_NS" deploy/vault -- sh -c \
    "${VAULT_CMD} vault policy write authorino -"

echo "  Creating JWT role (bound to audience mcp-gateway)..."
printf '{"role_type":"jwt","bound_audiences":["mcp-gateway"],"user_claim":"sub","policies":["authorino"],"ttl":"1h"}\n' | \
  kubectl exec -i -n "$VAULT_NS" deploy/vault -- sh -c \
    "${VAULT_CMD} vault write auth/jwt/role/authorino -"

echo "  Vault configuration complete."
