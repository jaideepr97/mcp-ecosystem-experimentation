#!/bin/bash
# Setup script for the MCP ecosystem experimentation environment.
# Deploys a multi-tenant MCP gateway ecosystem on a Kind cluster.
#
# Architecture: shared control plane (mcp-system, keycloak, kuadrant, vault)
# with per-team namespaces (team-a) each containing their own Gateway,
# MCPGatewayExtension (broker/router), MCP servers, and auth policies.
#
# Prerequisites:
#   - docker (or podman)
#   - kind
#   - kubectl
#   - helm
#   - jq
#   - python3
#
# Usage:
#   ./scripts/setup.sh                # Full setup from scratch
#   ./scripts/setup.sh --skip-cluster # Skip Kind cluster creation (reuse existing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KIND_CLUSTER_NAME="mcp-ecosystem"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-docker}"

# Auto-detect podman: check if docker is missing or if docker is actually podman
if ! command -v docker &>/dev/null && command -v podman &>/dev/null; then
  export KIND_EXPERIMENTAL_PROVIDER=podman
  CONTAINER_ENGINE="podman"
elif command -v podman &>/dev/null && docker --version 2>/dev/null | grep -qi podman; then
  export KIND_EXPERIMENTAL_PROVIDER=podman
  CONTAINER_ENGINE="podman"
fi

# Versions
GATEWAY_API_VERSION="v1.4.1"
SAIL_VERSION="1.27.0"
METALLB_VERSION="v0.15.2"
CERT_MANAGER_VERSION="v1.17.2"

# URLs
KEYCLOAK_EXTERNAL="http://keycloak.127-0-0-1.sslip.io:8002"
KEYCLOAK_ADMIN_URL=""  # Set after Keycloak is ready

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
wait_for() { echo -e "${YELLOW}[WAIT]${NC} $*"; }

# Parse args
SKIP_CLUSTER=false
for arg in "$@"; do
  case $arg in
    --skip-cluster) SKIP_CLUSTER=true ;;
  esac
done

########################################
# Phase 1: Kind cluster
########################################
if [ "$SKIP_CLUSTER" = false ]; then
  if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
    warn "Kind cluster '${KIND_CLUSTER_NAME}' already exists. Delete it first with: kind delete cluster --name ${KIND_CLUSTER_NAME}"
    warn "Or run with --skip-cluster to reuse it."
    exit 1
  fi
  info "Phase 1: Creating Kind cluster '${KIND_CLUSTER_NAME}'..."
  kind create cluster --name "${KIND_CLUSTER_NAME}" --config "${REPO_DIR}/infrastructure/kind/cluster.yaml"
else
  info "Phase 1: Skipping Kind cluster creation (--skip-cluster)"
fi

# Ensure we're using the right context
kubectl config use-context "kind-${KIND_CLUSTER_NAME}"

########################################
# Phase 2: Gateway API CRDs
########################################
info "Phase 2: Installing Gateway API CRDs (${GATEWAY_API_VERSION})..."
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
kubectl wait --for=condition=Established --timeout=60s crd/gateways.gateway.networking.k8s.io

########################################
# Phase 3: Istio (Sail operator)
########################################
info "Phase 3: Installing Istio via Sail operator (${SAIL_VERSION})..."
helm upgrade --install sail-operator \
  --create-namespace \
  --namespace istio-system \
  --wait \
  --timeout=300s \
  "https://github.com/istio-ecosystem/sail-operator/releases/download/${SAIL_VERSION}/sail-operator-${SAIL_VERSION}.tgz"

kubectl apply -f "${REPO_DIR}/infrastructure/kind/istio/istio.yaml"
wait_for "Istio to become ready..."
kubectl -n istio-system wait --for=condition=Ready istio/default --timeout=300s

########################################
# Phase 4: MetalLB
########################################
info "Phase 4: Installing MetalLB (${METALLB_VERSION})..."
kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"
wait_for "MetalLB controller..."
kubectl -n metallb-system wait --for=condition=Available deployments controller --timeout=300s
kubectl -n metallb-system wait --for=condition=ready pod --selector=app=metallb --timeout=120s

info "Configuring MetalLB IP pool..."
"${REPO_DIR}/infrastructure/kind/metallb/ipaddresspool.sh" kind | kubectl apply -n metallb-system -f -

########################################
# Phase 5: cert-manager
########################################
info "Phase 5: Installing cert-manager (${CERT_MANAGER_VERSION})..."
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --create-namespace \
  --namespace cert-manager \
  --set crds.enabled=true \
  --wait \
  --timeout=300s

wait_for "cert-manager to be ready..."
kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=120s
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=120s

info "Creating CA issuer chain..."
kubectl apply -f "${REPO_DIR}/infrastructure/kind/cert-manager/issuers.yaml"
wait_for "CA certificate to be ready..."
kubectl wait --for=condition=Ready certificate/mcp-ca-cert -n cert-manager --timeout=60s

########################################
# Phase 6: mcp-gateway CRDs + controller
########################################
info "Phase 6: Installing mcp-gateway CRDs and controller..."
kubectl apply -f "${REPO_DIR}/infrastructure/kind/mcp-gateway/mcp.kuadrant.io_mcpserverregistrations.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/kind/mcp-gateway/mcp.kuadrant.io_mcpvirtualservers.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/kind/mcp-gateway/mcp.kuadrant.io_mcpgatewayextensions.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/kind/mcp-gateway/deploy.yaml"
wait_for "mcp-controller to be ready..."
kubectl wait --for=condition=Available deployment/mcp-controller -n mcp-system --timeout=120s

########################################
# Phase 7: mcp-lifecycle-operator
########################################
info "Phase 7: Deploying mcp-lifecycle-operator..."
OPERATOR_IMAGE="quay.io/jrao/mcp-lifecycle-operator:gateway-credential-ref"
${CONTAINER_ENGINE} pull "${OPERATOR_IMAGE}" 2>/dev/null || true
TMP_TAR="/tmp/operator-image-$$.tar"
${CONTAINER_ENGINE} save "${OPERATOR_IMAGE}" -o "${TMP_TAR}"
kind load image-archive "${TMP_TAR}" --name "${KIND_CLUSTER_NAME}"
rm -f "${TMP_TAR}"

kubectl apply -f "${REPO_DIR}/infrastructure/kind/lifecycle-operator/deploy.yaml"
wait_for "Lifecycle operator to be ready..."
kubectl wait --for=condition=Available deployment/mcp-lifecycle-operator-controller-manager \
  -n mcp-lifecycle-operator-system --timeout=120s

info "Applying operator-gateway RBAC..."
kubectl apply -f "${REPO_DIR}/infrastructure/kind/operator-gateway/gateway-role.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/kind/operator-gateway/gateway-role-binding.yaml"

########################################
# Phase 8: Catalog
########################################
info "Phase 8: Deploying catalog system and launcher..."
kubectl create namespace catalog-system --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${REPO_DIR}/infrastructure/kind/catalog/postgres.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/kind/catalog/catalog-sources.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/kind/catalog/catalog.yaml"
wait_for "Catalog pods..."
kubectl wait --for=condition=Ready pod -l app=mcp-catalog-postgres -n catalog-system --timeout=120s
kubectl wait --for=condition=Ready pod -l app=mcp-catalog -n catalog-system --timeout=120s

info "Deploying MCP Launcher..."
kubectl apply -f "${REPO_DIR}/infrastructure/kind/launcher/rbac.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/kind/launcher/deployment.yaml"
wait_for "Launcher to be ready..."
kubectl wait --for=condition=Ready pod -l app=mcp-launcher -n catalog-system --timeout=120s 2>/dev/null || \
  warn "Launcher not ready yet — continuing"

########################################
# Phase 9: Keycloak (direct, no shared gateway)
########################################
info "Phase 9: Deploying Keycloak..."
kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${REPO_DIR}/infrastructure/kind/keycloak/realm-import.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/kind/keycloak/deployment.yaml"

# Keycloak-auth service (port 8002 → 8080) for in-cluster access
kubectl apply -f "${REPO_DIR}/infrastructure/kind/keycloak/keycloak-auth-service.yaml"

# NodePort for external access (30089 → 8002 → 8080, mapped to host port 8002)
kubectl apply -f "${REPO_DIR}/infrastructure/kind/keycloak/nodeport.yaml"

wait_for "Keycloak to be ready..."
kubectl wait --for=condition=Ready pod -l app=keycloak -n keycloak --timeout=180s

KEYCLOAK_ADMIN_URL="${KEYCLOAK_EXTERNAL}/admin/realms/mcp"

########################################
# Phase 10: Kuadrant + CoreDNS
########################################
info "Phase 10: Installing Kuadrant operator..."
helm repo add kuadrant https://kuadrant.io/helm-charts 2>/dev/null || true
helm repo update
helm upgrade --install kuadrant-operator kuadrant/kuadrant-operator \
  --create-namespace \
  --wait \
  --timeout=600s \
  --namespace kuadrant-system

info "Creating Kuadrant instance..."
kubectl apply -f "${REPO_DIR}/infrastructure/kind/kuadrant/kuadrant.yaml"
wait_for "Authorino to be ready..."
kubectl wait --for=condition=Ready pod -l app=authorino -n kuadrant-system --timeout=120s 2>/dev/null || \
  kubectl wait --for=condition=Ready pod -l authorino-resource -n kuadrant-system --timeout=120s 2>/dev/null || \
  warn "Could not verify Authorino readiness — continuing"

# Patch CoreDNS so Authorino can reach Keycloak via keycloak-auth service
info "Patching CoreDNS for Keycloak resolution..."
KEYCLOAK_AUTH_IP=$(kubectl get svc keycloak-auth -n keycloak -o jsonpath='{.spec.clusterIP}')
if [ -n "${KEYCLOAK_AUTH_IP}" ]; then
  kubectl get configmap coredns -n kube-system -o yaml | \
    sed "s/ready/hosts {\n          ${KEYCLOAK_AUTH_IP} keycloak.127-0-0-1.sslip.io\n          fallthrough\n        }\n        ready/" | \
    kubectl apply -f -
  kubectl rollout restart deployment coredns -n kube-system
  info "CoreDNS patched with keycloak-auth ClusterIP ${KEYCLOAK_AUTH_IP}"
else
  warn "Could not determine keycloak-auth ClusterIP — CoreDNS patch skipped"
fi

########################################
# Phase 11: Vault
########################################
info "Phase 11: Deploying Vault..."
kubectl apply -f "${REPO_DIR}/infrastructure/kind/vault/namespace.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/kind/vault/deployment.yaml"
wait_for "Vault to be ready..."
kubectl wait --for=condition=Ready pod -l app=vault -n vault --timeout=120s

info "Configuring Vault JWT auth..."
"${REPO_DIR}/infrastructure/kind/vault/configure.sh"

########################################
# Phase 12: team-a namespace
########################################
info "Phase 12: Deploying team-a namespace..."
kubectl apply -f "${REPO_DIR}/infrastructure/kind/team-a/namespace.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/kind/team-a/gateway.yaml"
wait_for "team-a Gateway to be programmed..."
kubectl wait --for=condition=Programmed gateway/team-a-gateway -n team-a --timeout=300s

info "Deploying MCPGatewayExtension (creates broker/router)..."
kubectl apply -f "${REPO_DIR}/infrastructure/kind/team-a/mcpgatewayextension.yaml"
wait_for "MCPGatewayExtension to be ready..."
kubectl wait --for=condition=Ready mcpgatewayextension/team-a-gateway-extension -n team-a --timeout=120s

info "Deploying NodePort for team-a gateway..."
kubectl apply -f "${REPO_DIR}/infrastructure/kind/team-a/nodeport.yaml"

info "Deploying MCP servers in team-a..."
kubectl apply -f "${REPO_DIR}/infrastructure/kind/team-a/test-server-a1.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/kind/team-a/test-server-a2.yaml"

wait_for "MCP servers to be ready..."
kubectl wait --for=condition=Ready mcpserver/test-server-a1 -n team-a --timeout=120s 2>/dev/null || \
  warn "test-server-a1 MCPServer not ready yet"
kubectl wait --for=condition=Ready mcpserver/test-server-a2 -n team-a --timeout=120s 2>/dev/null || \
  warn "test-server-a2 MCPServer not ready yet"

# Wait for broker to pick up server registrations
wait_for "Broker to discover servers..."
sleep 5

########################################
# Phase 13: Keycloak groups + users for team-a
########################################
info "Phase 13: Creating Keycloak groups and users for team-a..."

# Get admin token
get_admin_token() {
  curl -s -X POST "${KEYCLOAK_EXTERNAL}/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" \
    -d "username=admin" \
    -d "password=admin" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

ADMIN_TOKEN=$(get_admin_token)

# Create team-a groups
for GROUP in team-a-developers team-a-ops team-a-leads; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${KEYCLOAK_ADMIN_URL}/groups" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${GROUP}\"}")
  if [ "$HTTP_CODE" = "201" ]; then
    info "  Created group: ${GROUP}"
  elif [ "$HTTP_CODE" = "409" ]; then
    info "  Group already exists: ${GROUP}"
  else
    warn "  Failed to create group ${GROUP} (HTTP ${HTTP_CODE})"
  fi
done

# Refresh token (may have expired during group creation)
ADMIN_TOKEN=$(get_admin_token)

# Get group IDs
get_group_id() {
  curl -s "${KEYCLOAK_ADMIN_URL}/groups?search=$1" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" | \
    python3 -c "import sys,json; groups=[g for g in json.load(sys.stdin) if g['name']=='$1']; print(groups[0]['id'] if groups else '')"
}

DEV_GROUP_ID=$(get_group_id "team-a-developers")
OPS_GROUP_ID=$(get_group_id "team-a-ops")
LEADS_GROUP_ID=$(get_group_id "team-a-leads")

# Create team-a users and assign to groups
# dev1, dev2 → team-a-developers
# ops1, ops2 → team-a-ops
# lead1 → team-a-leads
create_user_with_group() {
  local username="$1"
  local group_id="$2"
  local group_name="$3"

  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${KEYCLOAK_ADMIN_URL}/users" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"username\": \"${username}\",
      \"firstName\": \"${username}\",
      \"lastName\": \"User\",
      \"email\": \"${username}@example.com\",
      \"emailVerified\": true,
      \"enabled\": true,
      \"credentials\": [{\"type\": \"password\", \"value\": \"${username}\", \"temporary\": false}]
    }")

  if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "409" ]; then
    # Get user ID
    local user_id
    user_id=$(curl -s "${KEYCLOAK_ADMIN_URL}/users?username=${username}&exact=true" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" | \
      python3 -c "import sys,json; users=json.load(sys.stdin); print(users[0]['id'] if users else '')")

    if [ -n "$user_id" ]; then
      # Assign to group
      curl -s -o /dev/null -X PUT \
        "${KEYCLOAK_ADMIN_URL}/users/${user_id}/groups/${group_id}" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        -H "Content-Type: application/json"
      info "  User ${username} → ${group_name}"
    fi
  else
    warn "  Failed to create user ${username} (HTTP ${HTTP_CODE})"
  fi
}

ADMIN_TOKEN=$(get_admin_token)
create_user_with_group "dev1" "$DEV_GROUP_ID" "team-a-developers"
create_user_with_group "dev2" "$DEV_GROUP_ID" "team-a-developers"

ADMIN_TOKEN=$(get_admin_token)
create_user_with_group "ops1" "$OPS_GROUP_ID" "team-a-ops"
create_user_with_group "ops2" "$OPS_GROUP_ID" "team-a-ops"

ADMIN_TOKEN=$(get_admin_token)
create_user_with_group "lead1" "$LEADS_GROUP_ID" "team-a-leads"

########################################
# Phase 18: Vault credential storage
# Store team-level and per-user secrets in Vault for credential injection.
# AuthPolicy metadata evaluators exchange JWT for Vault token, then read secrets.
########################################
info "Phase 18: Storing Vault credentials for team-a..."

VAULT_NS="vault"
VAULT_CMD="VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root"

# Team-level secrets (shared by group)
info "  Storing team-level secrets..."
kubectl exec -n "$VAULT_NS" deploy/vault -- sh -c \
  "${VAULT_CMD} vault kv put secret/mcp-gateway/teams/team-a-developers api_key=team-dev-shared-key-001"
kubectl exec -n "$VAULT_NS" deploy/vault -- sh -c \
  "${VAULT_CMD} vault kv put secret/mcp-gateway/teams/team-a-ops api_key=team-ops-shared-key-002"
kubectl exec -n "$VAULT_NS" deploy/vault -- sh -c \
  "${VAULT_CMD} vault kv put secret/mcp-gateway/teams/team-a-leads api_key=team-leads-shared-key-003"

# Per-user secrets (keyed by Keycloak sub claim)
info "  Storing per-user secrets..."
ADMIN_TOKEN=$(get_admin_token)
for username in dev1 dev2 ops1 ops2 lead1; do
  USER_SUB=$(curl -s "${KEYCLOAK_ADMIN_URL}/users?username=${username}&exact=true" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" | \
    python3 -c "import sys,json; users=json.load(sys.stdin); print(users[0]['id'] if users else '')")
  if [ -n "$USER_SUB" ]; then
    kubectl exec -n "$VAULT_NS" deploy/vault -- sh -c \
      "${VAULT_CMD} vault kv put secret/mcp-gateway/users/${USER_SUB} api_key=${username}-personal-key"
    info "  User ${username} (${USER_SUB}) → personal key stored"
  fi
done

########################################
# Phase 14: VirtualMCPServers + AuthPolicies
########################################
info "Phase 14: Applying VirtualMCPServers and AuthPolicies..."

# VirtualMCPServer CRs (filtering only — see Finding 48 workaround in Phase 15)
kubectl apply -f "${REPO_DIR}/infrastructure/kind/team-a/virtualserver-dev.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/kind/team-a/virtualserver-ops.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/kind/team-a/virtualserver-leads.yaml"

# Gateway-level AuthPolicy (JWT auth + x-mcp-virtualserver header injection)
kubectl apply -f "${REPO_DIR}/infrastructure/kind/team-a/gateway-auth-policy.yaml"
sleep 5  # Allow gateway-level policy to settle

# Per-HTTPRoute AuthPolicies (tool-level authorization)
kubectl apply -f "${REPO_DIR}/infrastructure/kind/team-a/authpolicy-server-a1.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/kind/team-a/authpolicy-server-a2.yaml"

########################################
# Phase 15: Config Secret patch
# Workaround for Finding 48: MCPVirtualServer controller writes to
# mcp-system/mcp-gateway-config (hardcoded), not the team namespace.
# We manually patch team-a's config Secret with virtualServers entries.
########################################
info "Phase 15: Patching team-a config Secret with VirtualMCPServer definitions..."

wait_for "Config Secret to exist in team-a..."
for i in $(seq 1 12); do
  kubectl get secret mcp-gateway-config -n team-a &>/dev/null && break
  sleep 5
done

# Read current config
CURRENT_CONFIG=$(kubectl get secret mcp-gateway-config -n team-a -o jsonpath='{.data.config\.yaml}' | base64 -d)

# Check if virtualServers already patched
if echo "$CURRENT_CONFIG" | grep -q "virtualServers:"; then
  info "  Config Secret already contains virtualServers — skipping patch"
else
  # Append virtualServers section
  PATCHED_CONFIG="${CURRENT_CONFIG}
virtualServers:
  - name: team-a/team-a-dev-tools
    description: Developer tools for team-a
    tools:
      - test_server_a1_greet
      - test_server_a1_time
      - test_server_a1_headers
      - test_server_a2_hello_world
      - test_server_a2_time
      - test_server_a2_headers
  - name: team-a/team-a-ops-tools
    description: Operations tools for team-a
    tools:
      - test_server_a1_add_tool
      - test_server_a1_slow
      - test_server_a2_auth1234
      - test_server_a2_set_time
      - test_server_a2_slow
      - test_server_a2_pour_chocolate_into_mold
  - name: team-a/team-a-lead-tools
    description: Full tool access for team-a leads
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
      - test_server_a2_time"

  kubectl create secret generic mcp-gateway-config -n team-a \
    --from-literal="config.yaml=${PATCHED_CONFIG}" \
    --dry-run=client -o yaml | kubectl apply -f -
  info "  Config Secret patched with 3 VirtualMCPServer definitions"

  # Restart broker to pick up the new config
  info "  Restarting broker to load VirtualMCPServer config..."
  BROKER_DEPLOY=$(kubectl get deploy -n team-a -l app=mcp-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -n "$BROKER_DEPLOY" ]; then
    kubectl rollout restart deployment "${BROKER_DEPLOY}" -n team-a
    kubectl rollout status deployment "${BROKER_DEPLOY}" -n team-a --timeout=60s
  fi
fi

########################################
# Phase 16: TLS (HTTPS termination on team-a gateway)
########################################
info "Phase 16: Configuring TLS for team-a gateway..."

# TLSPolicy references the mcp-ca-issuer ClusterIssuer from Phase 5
kubectl apply -f "${REPO_DIR}/infrastructure/kind/team-a/tls-policy.yaml"

# HTTPS NodePort (30443 → 8443, mapped to host port 8443)
kubectl apply -f "${REPO_DIR}/infrastructure/kind/team-a/nodeport-tls.yaml"

wait_for "TLSPolicy to be enforced..."
for i in $(seq 1 12); do
  STATUS=$(kubectl get tlspolicy team-a-gateway-tls -n team-a -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null)
  [ "$STATUS" = "True" ] && break
  sleep 5
done
if [ "$STATUS" != "True" ]; then
  warn "TLSPolicy not enforced yet — restarting Kuadrant operator..."
  kubectl rollout restart deployment kuadrant-operator-controller-manager -n kuadrant-system
  kubectl rollout status deployment kuadrant-operator-controller-manager -n kuadrant-system --timeout=60s
  kubectl annotate tlspolicy team-a-gateway-tls -n team-a reconcile-trigger="$(date +%s)" --overwrite
  sleep 10
fi

wait_for "HTTPS certificate to be ready..."
kubectl wait --for=condition=Ready certificate/team-a-gateway-mcp-https-tls -n team-a --timeout=120s 2>/dev/null || \
  warn "HTTPS certificate not ready yet"

wait_for "Gateway to be programmed with HTTPS listener..."
kubectl wait --for=condition=Programmed gateway/team-a-gateway -n team-a --timeout=120s

# Clone the controller-created EnvoyFilter for the HTTPS listener (port 8443)
# The mcp-controller creates ext_proc for port 8080; HTTPS needs the same on 8443
info "Creating ext_proc EnvoyFilter for HTTPS listener..."
EXISTING_EF=$(kubectl get envoyfilter -n team-a -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
              kubectl get envoyfilter -n istio-system -l gateway.io/name=team-a-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$EXISTING_EF" ]; then
  # Determine which namespace the EnvoyFilter is in
  EF_NS="team-a"
  kubectl get envoyfilter "$EXISTING_EF" -n team-a &>/dev/null || EF_NS="istio-system"

  # Check if TLS EnvoyFilter already exists
  TLS_EF_EXISTS=$(kubectl get envoyfilter "${EXISTING_EF}-tls" -n "$EF_NS" -o name 2>/dev/null)
  if [ -z "$TLS_EF_EXISTS" ]; then
    kubectl get envoyfilter "$EXISTING_EF" -n "$EF_NS" -o yaml | \
      sed "s/name: ${EXISTING_EF}/name: ${EXISTING_EF}-tls/" | \
      sed 's/portNumber: 8080/portNumber: 8443/' | \
      grep -v "resourceVersion:" | \
      grep -v "uid:" | \
      grep -v "creationTimestamp:" | \
      kubectl apply -f -
    info "  Created ${EXISTING_EF}-tls EnvoyFilter for port 8443"
  else
    info "  TLS EnvoyFilter already exists — skipping"
  fi
else
  warn "Could not find controller-created EnvoyFilter — HTTPS ext_proc may not work"
fi

# Extract CA cert for client use
info "Extracting CA certificate for client verification..."
kubectl get secret mcp-ca-secret -n cert-manager -o jsonpath='{.data.ca\.crt}' | \
  base64 -d > /tmp/mcp-ca.crt 2>/dev/null || \
  kubectl get secret mcp-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' | \
  base64 -d > /tmp/mcp-ca.crt 2>/dev/null || \
  warn "Could not extract CA cert"
if [ -f /tmp/mcp-ca.crt ]; then
  info "CA certificate saved to /tmp/mcp-ca.crt (use with curl --cacert)"
fi

########################################
# Done
########################################
echo ""
info "========================================="
info "  MCP Ecosystem setup complete!"
info "========================================="
echo ""
info "Architecture: Multi-tenant model"
info "  Shared:  mcp-system (controller), keycloak, kuadrant, vault, catalog, launcher"
info "  team-a:  Gateway + broker/router + 2 MCP servers + 3 VirtualMCPServers + 3 AuthPolicies + TLS"
echo ""
info "Endpoints (HTTP):"
info "  team-a MCP Gateway: http://team-a.mcp.127-0-0-1.sslip.io:8001/mcp"
info "  Keycloak:           ${KEYCLOAK_EXTERNAL} (admin/admin)"
info "  Launcher:           http://localhost:8004"
echo ""
info "Endpoints (HTTPS — self-signed CA):"
info "  team-a MCP Gateway: https://team-a.mcp.127-0-0-1.sslip.io:8443/mcp"
info "  CA cert:            /tmp/mcp-ca.crt"
echo ""
info "Vault:"
info "  Internal:  http://vault.vault.svc.cluster.local:8200 (root token: root)"
echo ""
info "team-a users (password = username):"
info "  dev1, dev2  (team-a-developers) — 6 tools (utility/inspection)"
info "  ops1, ops2  (team-a-ops)        — 6 tools (admin/management)"
info "  lead1       (team-a-leads)      — 12 tools (all)"
echo ""
info "Quick test:"
info "  ./scripts/mcp-client.sh"
echo ""
info "Run tests:"
info "  ./scripts/test-pipeline.sh"
