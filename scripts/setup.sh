#!/bin/bash
# Setup script for the MCP ecosystem experimentation environment.
# Creates a Kind cluster and deploys all components from this repo.
#
# Prerequisites:
#   - docker (or podman)
#   - kind
#   - kubectl
#   - helm
#
# Usage:
#   ./scripts/setup.sh          # Full setup from scratch
#   ./scripts/setup.sh --skip-cluster  # Skip Kind cluster creation (reuse existing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KIND_CLUSTER_NAME="mcp-gateway"
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
  info "Creating Kind cluster '${KIND_CLUSTER_NAME}'..."
  kind create cluster --name "${KIND_CLUSTER_NAME}" --config "${REPO_DIR}/infrastructure/kind/cluster.yaml"
fi

# Ensure we're using the right context
kubectl config use-context "kind-${KIND_CLUSTER_NAME}"

########################################
# Phase 2: Gateway API CRDs
########################################
info "Installing Gateway API CRDs (${GATEWAY_API_VERSION})..."
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
kubectl wait --for=condition=Established --timeout=60s crd/gateways.gateway.networking.k8s.io

########################################
# Phase 3: Istio (Sail operator)
########################################
info "Installing Istio via Sail operator (${SAIL_VERSION})..."
helm upgrade --install sail-operator \
  --create-namespace \
  --namespace istio-system \
  --wait \
  --timeout=300s \
  "https://github.com/istio-ecosystem/sail-operator/releases/download/${SAIL_VERSION}/sail-operator-${SAIL_VERSION}.tgz"

kubectl apply -f "${REPO_DIR}/infrastructure/istio/istio.yaml"
wait_for "Istio to become ready..."
kubectl -n istio-system wait --for=condition=Ready istio/default --timeout=300s

########################################
# Phase 4: MetalLB
########################################
info "Installing MetalLB (${METALLB_VERSION})..."
kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"
wait_for "MetalLB controller..."
kubectl -n metallb-system wait --for=condition=Available deployments controller --timeout=300s
kubectl -n metallb-system wait --for=condition=ready pod --selector=app=metallb --timeout=120s

info "Configuring MetalLB IP pool..."
"${REPO_DIR}/infrastructure/metallb/ipaddresspool.sh" kind | kubectl apply -n metallb-system -f -

########################################
# Phase 5: Gateway (namespace, gateway, nodeport, referencegrant)
########################################
info "Deploying Istio Gateway..."
kubectl apply -f "${REPO_DIR}/infrastructure/gateway/namespace.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/gateway/gateway.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/gateway/nodeport.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/gateway/referencegrant.yaml"
wait_for "Gateway to be programmed..."
kubectl wait --for=condition=Programmed gateway/mcp-gateway -n gateway-system --timeout=300s

########################################
# Phase 6: mcp-gateway (CRDs + controller)
########################################
info "Installing mcp-gateway CRDs..."
kubectl apply -f "${REPO_DIR}/infrastructure/mcp-gateway/mcp.kuadrant.io_mcpserverregistrations.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/mcp-gateway/mcp.kuadrant.io_mcpvirtualservers.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/mcp-gateway/mcp.kuadrant.io_mcpgatewayextensions.yaml"

info "Deploying mcp-gateway controller and broker..."
kubectl apply -f "${REPO_DIR}/infrastructure/mcp-gateway/deploy.yaml"
wait_for "mcp-controller to be ready..."
kubectl wait --for=condition=Available deployment/mcp-controller -n mcp-system --timeout=120s

# The controller auto-creates the EnvoyFilter for ext_proc when reconciling MCPGatewayExtension
wait_for "MCPGatewayExtension to be ready..."
kubectl wait --for=condition=Ready mcpgatewayextension/mcp-gateway-extension -n mcp-system --timeout=120s

########################################
# Phase 7: mcp-lifecycle-operator
########################################
# Pre-load the image into Kind so it doesn't need to pull from registry
info "Loading lifecycle operator image into Kind..."
OPERATOR_IMAGE="quay.io/jrao/mcp-lifecycle-operator:gateway-integration"
${CONTAINER_ENGINE} pull "${OPERATOR_IMAGE}" 2>/dev/null || true
TMP_TAR="/tmp/operator-image-$$.tar"
${CONTAINER_ENGINE} save "${OPERATOR_IMAGE}" -o "${TMP_TAR}"
kind load image-archive "${TMP_TAR}" --name "${KIND_CLUSTER_NAME}"
rm -f "${TMP_TAR}"

info "Deploying mcp-lifecycle-operator..."
kubectl apply -f "${REPO_DIR}/infrastructure/lifecycle-operator/deploy.yaml"
wait_for "Lifecycle operator to be ready..."
kubectl wait --for=condition=Available deployment/mcp-lifecycle-operator-controller-manager \
  -n mcp-lifecycle-operator-system --timeout=120s

info "Applying operator-gateway RBAC..."
kubectl apply -f "${REPO_DIR}/infrastructure/operator-gateway/gateway-role.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/operator-gateway/gateway-role-binding.yaml"

########################################
# Phase 8: Catalog system
########################################
info "Deploying catalog system..."
kubectl create namespace catalog-system --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${REPO_DIR}/infrastructure/catalog/postgres.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/catalog/catalog-sources.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/catalog/catalog.yaml"
wait_for "Catalog pods..."
kubectl wait --for=condition=Ready pod -l app=mcp-catalog-postgres -n catalog-system --timeout=120s
kubectl wait --for=condition=Ready pod -l app=mcp-catalog -n catalog-system --timeout=120s

########################################
# Phase 9: Keycloak
########################################
info "Deploying Keycloak..."
kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${REPO_DIR}/infrastructure/keycloak/realm-import.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/keycloak/deployment.yaml"
kubectl patch gateway mcp-gateway -n gateway-system --type json \
  -p "$(cat "${REPO_DIR}/infrastructure/keycloak/gateway-patch.json")"
kubectl apply -f "${REPO_DIR}/infrastructure/keycloak/httproute.yaml"
wait_for "Keycloak to be ready..."
kubectl wait --for=condition=Ready pod -l app=keycloak -n keycloak --timeout=180s

########################################
# Phase 10: Kuadrant operator
########################################
info "Installing Kuadrant operator..."
helm repo add kuadrant https://kuadrant.io/helm-charts 2>/dev/null || true
helm repo update
helm upgrade --install kuadrant-operator kuadrant/kuadrant-operator \
  --create-namespace \
  --wait \
  --timeout=600s \
  --namespace kuadrant-system

info "Creating Kuadrant instance..."
kubectl apply -f "${REPO_DIR}/infrastructure/kuadrant/kuadrant.yaml"
wait_for "Authorino to be ready..."
kubectl wait --for=condition=Ready pod -l app=authorino -n kuadrant-system --timeout=120s 2>/dev/null || \
  kubectl wait --for=condition=Ready pod -l authorino-resource -n kuadrant-system --timeout=120s 2>/dev/null || \
  warn "Could not verify Authorino readiness — continuing"

# Fix CoreDNS so Authorino can reach Keycloak through the gateway
info "Patching CoreDNS for Keycloak resolution..."
GATEWAY_IP=$(kubectl get svc -n gateway-system \
  -l gateway.networking.k8s.io/gateway-name=mcp-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
if [ -n "${GATEWAY_IP}" ]; then
  kubectl get configmap coredns -n kube-system -o yaml | \
    sed "s/ready/hosts {\n          ${GATEWAY_IP} keycloak.127-0-0-1.sslip.io\n          fallthrough\n        }\n        ready/" | \
    kubectl apply -f -
  kubectl rollout restart deployment coredns -n kube-system
  info "CoreDNS patched with gateway IP ${GATEWAY_IP}"
else
  warn "Could not determine gateway LB IP — CoreDNS patch skipped"
fi

########################################
# Phase 11: Test servers + Launcher
########################################
info "Deploying test servers..."
kubectl create namespace mcp-test --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${REPO_DIR}/infrastructure/test-servers/test-server1.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/test-servers/test-server2.yaml"

info "Deploying MCP Launcher..."
kubectl apply -f "${REPO_DIR}/infrastructure/launcher/rbac.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/launcher/deployment.yaml"

wait_for "Test servers to be ready..."
kubectl wait --for=condition=Ready mcpserver/test-server1 -n mcp-test --timeout=120s 2>/dev/null || \
  warn "test-server1 MCPServer not ready yet"
kubectl wait --for=condition=Ready mcpserver/test-server2 -n mcp-test --timeout=120s 2>/dev/null || \
  warn "test-server2 MCPServer not ready yet"

# Restart gateway to pick up new registrations
info "Restarting mcp-gateway to pick up server registrations..."
kubectl rollout restart deployment mcp-gateway -n mcp-system 2>/dev/null || true
kubectl rollout status deployment mcp-gateway -n mcp-system --timeout=120s 2>/dev/null || true

########################################
# Phase 12: AuthPolicies
########################################
info "Applying gateway-level AuthPolicy..."
kubectl apply -f "${REPO_DIR}/infrastructure/auth/authpolicy.yaml"
sleep 5 # Allow gateway-level policy to settle before per-server policies
info "Applying per-server AuthPolicies..."
kubectl apply -f "${REPO_DIR}/infrastructure/auth/authpolicy-server1.yaml"
kubectl apply -f "${REPO_DIR}/infrastructure/auth/authpolicy-server2.yaml"

########################################
# Done
########################################
echo ""
info "========================================="
info "  MCP Ecosystem setup complete!"
info "========================================="
echo ""
info "Endpoints:"
info "  MCP Gateway:  http://mcp.127-0-0-1.sslip.io:8001/mcp"
info "  Keycloak:     http://keycloak.127-0-0-1.sslip.io:8002 (admin/admin)"
info "  Launcher:     http://localhost:8004"
echo ""
info "Test users (password = username):"
info "  alice (developers) | bob (ops) | carol (both)"
echo ""
info "Quick test:"
info "  TOKEN=\$(curl -s http://keycloak.127-0-0-1.sslip.io:8002/realms/mcp/protocol/openid-connect/token \\"
info "    -d grant_type=password -d client_id=mcp-cli -d username=alice -d password=alice -d scope=openid \\"
info "    | jq -r .access_token)"
info "  curl http://mcp.127-0-0-1.sslip.io:8001/mcp -H \"Authorization: Bearer \$TOKEN\" \\"
info "    -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"method\":\"tools/list\",\"id\":1}'"
