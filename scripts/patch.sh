#!/usr/bin/env bash
# patch.sh — Re-apply virtualServers config to the broker config secret.
#
# Workaround for https://github.com/Kuadrant/mcp-gateway/issues/722
# The MCPVirtualServer controller writes to the hardcoded mcp-system namespace
# instead of the per-namespace config secret. Additionally, MCPServerRegistration
# reconciliations overwrite the virtualServers section.
#
# Run this after any event that triggers MCPServerRegistration reconciliation
# (e.g., deploying a new server from the catalog).

set -euo pipefail

NAMESPACE="${1:-team-a}"

echo "Reading current config secret from ${NAMESPACE}..."
CONFIG=$(kubectl get secret mcp-gateway-config -n "$NAMESPACE" -o jsonpath='{.data.config\.yaml}' | base64 -d)

# Strip existing virtualServers section if present (to avoid duplication)
CONFIG=$(echo "$CONFIG" | sed '/^virtualServers:/,$d')

PATCHED="${CONFIG}
virtualServers:
  - name: ${NAMESPACE}/team-a-dev-tools
    tools:
      - test_server_a1_greet
      - test_server_a1_time
      - test_server_a1_headers
      - test_server_a2_hello_world
      - test_server_a2_time
      - test_server_a2_headers
  - name: ${NAMESPACE}/team-a-ops-tools
    tools:
      - test_server_a1_add_tool
      - test_server_a1_slow
      - test_server_a2_auth1234
      - test_server_a2_set_time
      - test_server_a2_slow
      - test_server_a2_pour_chocolate_into_mold
  - name: ${NAMESPACE}/team-a-lead-tools
    tools:
      - test_server_a1_add_tool
      - test_server_a1_greet
      - test_server_a1_headers
      - test_server_a1_slow
      - test_server_a1_time
      - test_server_a2_auth1234
      - test_server_a2_headers
      - test_server_a2_hello_world
      - test_server_a2_pour_chocolate_into_mold
      - test_server_a2_set_time
      - test_server_a2_slow
      - test_server_a2_time
      - test_server1_greet
      - test_server1_time
      - test_server1_headers"

echo "Patching config secret..."
kubectl create secret generic mcp-gateway-config -n "$NAMESPACE" \
  --from-literal="config.yaml=${PATCHED}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Restarting broker..."
kubectl rollout restart deploy/mcp-gateway -n "$NAMESPACE"
kubectl rollout status deploy/mcp-gateway -n "$NAMESPACE" --timeout=60s

echo "Done. VirtualMCPServer filtering restored."
