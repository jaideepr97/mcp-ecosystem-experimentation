#!/usr/bin/env bash
# guided-setup.sh — Interactive guided setup for the MCP ecosystem experiment.
#
# Walks you through each deployment phase with context and explanations,
# using gum (https://github.com/charmbracelet/gum) for a rich terminal experience.
#
# Architecture: Multi-tenant model with shared control plane + per-team namespaces.
#
# Phases:
#   1. Shared Infrastructure (Kind, Gateway API, Istio, MetalLB, cert-manager,
#      mcp-gateway controller, lifecycle operator, catalog, Keycloak, Kuadrant, Vault)
#   2. team-a Namespace (Gateway, MCPGatewayExtension, NodePort, MCP servers)
#   3. Keycloak Groups + Users (team-a-developers, team-a-ops, team-a-leads)
#   4. VirtualMCPServers + AuthPolicies (per-group tool filtering + authorization)
#   5. Config Secret Patch (Finding 48 workaround for VirtualMCPServer)
#
# Usage:
#   ./scripts/guided-setup.sh              # Start from the beginning
#   ./scripts/guided-setup.sh --resume     # Resume from where you left off
#   ./scripts/guided-setup.sh --phase 3    # Start from a specific phase
#   ./scripts/guided-setup.sh --batch      # Run all phases without prompts (like setup.sh)
#
# Prerequisites: kind, kubectl, helm, docker/podman, jq, python3, gum
#   brew install gum    # macOS
#   go install github.com/charmbracelet/gum@latest  # or from source

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_FILE="${REPO_DIR}/.setup-state"
KIND_CLUSTER_NAME="mcp-ecosystem"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-docker}"
BATCH_MODE=false
START_PHASE=1

# Versions
GATEWAY_API_VERSION="v1.4.1"
SAIL_VERSION="1.27.0"
METALLB_VERSION="v0.15.2"
CERT_MANAGER_VERSION="v1.17.2"

# URLs
KEYCLOAK_EXTERNAL="http://keycloak.127-0-0-1.sslip.io:8002"

TOTAL_PHASES=5

# --- Argument parsing ---

for arg in "$@"; do
  case $arg in
    --resume)
      if [ -f "$STATE_FILE" ]; then
        START_PHASE=$(( $(cat "$STATE_FILE") + 1 ))
      fi
      ;;
    --phase)
      shift_next=true
      ;;
    --batch)
      BATCH_MODE=true
      ;;
    *)
      if [ "${shift_next:-false}" = true ]; then
        START_PHASE="$arg"
        shift_next=false
      fi
      ;;
  esac
done

# --- Auto-detect container engine ---

if ! command -v docker &>/dev/null && command -v podman &>/dev/null; then
  export KIND_EXPERIMENTAL_PROVIDER=podman
  CONTAINER_ENGINE="podman"
elif command -v podman &>/dev/null && docker --version 2>/dev/null | grep -qi podman; then
  export KIND_EXPERIMENTAL_PROVIDER=podman
  CONTAINER_ENGINE="podman"
fi

# --- Check for gum ---

if ! command -v gum &>/dev/null; then
  echo "gum is required for the guided setup."
  echo ""
  echo "Install it with:"
  echo "  brew install gum        # macOS"
  echo "  go install github.com/charmbracelet/gum@latest"
  echo ""
  echo "Or use ./scripts/setup.sh for non-interactive setup."
  exit 1
fi

# --- Helpers ---

save_state() {
  echo "$1" > "$STATE_FILE"
}

run_cmd() {
  local title="$1"
  shift
  if [ "$BATCH_MODE" = true ]; then
    echo "  $title"
    "$@" 2>&1 | tail -3
  else
    gum spin --spinner dot --title "$title" -- "$@"
  fi
}

show_phase() {
  local num="$1"
  local title="$2"
  local description="$3"

  echo ""
  if [ "$BATCH_MODE" = true ]; then
    echo "=== Phase ${num}/${TOTAL_PHASES}: ${title} ==="
    return 0
  fi

  gum style --border rounded --border-foreground 212 --padding "1 2" --margin "1 0" \
    "Phase ${num}/${TOTAL_PHASES}: ${title}"

  gum format <<< "$description"
  echo ""
}

confirm_phase() {
  local num="$1"
  if [ "$BATCH_MODE" = true ]; then
    return 0
  fi

  if ! gum confirm "Deploy phase ${num}?"; then
    gum style --foreground 214 "Skipped."
    return 1
  fi
  return 0
}

phase_done() {
  local num="$1"
  save_state "$num"
  if [ "$BATCH_MODE" = true ]; then
    echo "  Done."
  else
    gum style --foreground 82 --bold "Phase ${num} complete."
  fi
}

show_resources() {
  local output=""
  for entry in "$@"; do
    local label="${entry%%:*}"
    local cmd="${entry#*: }"
    local items
    items=$(eval "kubectl get $cmd --no-headers 2>/dev/null")
    if [ -n "$items" ]; then
      output="${output}${label}:\n${items}\n\n"
    fi
  done

  if [ -z "$output" ]; then
    return
  fi

  echo ""
  if [ "$BATCH_MODE" = true ]; then
    echo "  Resources created:"
    printf '%b' "$output" | sed 's/^/    /'
  else
    printf '%b' "$output" | gum style --border rounded --border-foreground 240 --padding "0 2" --margin "0 2"
  fi
}

# --- Welcome ---

if [ "$BATCH_MODE" = false ]; then
  gum style --border double --border-foreground 99 --padding "1 3" --margin "1 0" --align center \
    "MCP Ecosystem — Guided Setup" \
    "" \
    "Build a multi-tenant MCP ecosystem on a local Kind cluster." \
    "Shared control plane + per-team namespaces with isolated gateways." \
    "" \
    "${TOTAL_PHASES} phases | ~10 minutes total"

  if [ "$START_PHASE" -gt 1 ]; then
    gum style --foreground 214 "Resuming from phase ${START_PHASE}."
    echo ""
  fi
fi

########################################
# Phase 1: Shared Infrastructure
########################################

if [ "$START_PHASE" -le 1 ]; then

show_phase 1 "Shared Infrastructure" "
## What this does

Deploys all shared control plane components that every team namespace depends on.
This is a one-time setup that doesn't change as you add more teams.

## Components (in order)

1. **Kind cluster** — Kubernetes in Docker with NodePort mappings (8001→MCP, 8002→Keycloak)
2. **Gateway API CRDs** — Kubernetes-native L7 networking (Gateway, HTTPRoute)
3. **Istio via Sail** — Gateway API controller only (no service mesh/sidecars)
4. **MetalLB** — Bare-metal LoadBalancer for Kind (assigns IPs to Gateway services)
5. **cert-manager** — TLS certificate automation + self-signed CA chain
6. **mcp-gateway controller** — Watches MCPGatewayExtension CRs, deploys broker/router per namespace
7. **Lifecycle operator** — Watches MCPServer CRs, creates Deployment/Service/HTTPRoute/Registration
8. **Catalog + Launcher** — REST API for MCP server discovery + web UI for browsing/deploying
9. **Keycloak** — OIDC provider with realm import (users, clients, group mappers)
10. **Kuadrant (Authorino)** — Envoy-native authorization engine for AuthPolicy CRs
11. **Vault** — Credential exchange via JWT auth (Keycloak JWT → per-user secrets)

## Why all in one phase?

These are infrastructure dependencies — they must exist before any team namespace
can function. Splitting them across phases adds no value for a guided walkthrough
since they're always deployed together. The interesting architectural decisions
happen in Phases 2-5 where the multi-tenancy model takes shape.

## What gets created

- Kind cluster node with 5 port mappings
- ~10 namespaces (istio-system, metallb-system, cert-manager, mcp-system, etc.)
- ~25 pods across shared infrastructure
- MCP CRDs, Gateway API CRDs, Kuadrant CRDs
- CoreDNS patch for in-cluster Keycloak resolution
"

if confirm_phase 1; then
  # --- Kind ---
  if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
    kubectl config use-context "kind-${KIND_CLUSTER_NAME}" >/dev/null 2>&1
    if kubectl get nodes --request-timeout=5s &>/dev/null; then
      if [ "$BATCH_MODE" = false ]; then
        gum style --foreground 214 "Cluster '${KIND_CLUSTER_NAME}' already exists and is healthy — reusing it."
      else
        echo "  Cluster already exists — reusing."
      fi
    else
      run_cmd "Deleting stale cluster..." \
        kind delete cluster --name "${KIND_CLUSTER_NAME}"
      run_cmd "Creating Kind cluster..." \
        kind create cluster --name "${KIND_CLUSTER_NAME}" --config "${REPO_DIR}/infrastructure/kind/cluster.yaml"
    fi
  else
    run_cmd "Creating Kind cluster..." \
      kind create cluster --name "${KIND_CLUSTER_NAME}" --config "${REPO_DIR}/infrastructure/kind/cluster.yaml"
  fi
  kubectl config use-context "kind-${KIND_CLUSTER_NAME}" >/dev/null 2>&1

  # --- Gateway API CRDs ---
  run_cmd "Installing Gateway API CRDs (${GATEWAY_API_VERSION})..." \
    kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
  kubectl wait --for=condition=Established --timeout=60s crd/gateways.gateway.networking.k8s.io >/dev/null 2>&1

  # --- Istio ---
  run_cmd "Installing Istio via Sail operator (${SAIL_VERSION})..." \
    helm upgrade --install sail-operator \
      --create-namespace \
      --namespace istio-system \
      --wait \
      --timeout=300s \
      "https://github.com/istio-ecosystem/sail-operator/releases/download/${SAIL_VERSION}/sail-operator-${SAIL_VERSION}.tgz"
  kubectl apply -f "${REPO_DIR}/infrastructure/istio/istio.yaml" >/dev/null 2>&1
  run_cmd "Waiting for Istio..." \
    kubectl -n istio-system wait --for=condition=Ready istio/default --timeout=300s

  # --- MetalLB ---
  run_cmd "Installing MetalLB (${METALLB_VERSION})..." \
    kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"
  run_cmd "Waiting for MetalLB controller..." \
    kubectl -n metallb-system wait --for=condition=Available deployments controller --timeout=300s
  run_cmd "Waiting for MetalLB pods..." \
    kubectl -n metallb-system wait --for=condition=ready pod --selector=app=metallb --timeout=120s
  run_cmd "Configuring IP pool..." \
    bash -c "'${REPO_DIR}/infrastructure/metallb/ipaddresspool.sh' kind | kubectl apply -n metallb-system -f -"

  # --- cert-manager ---
  run_cmd "Adding Helm repos..." \
    bash -c "helm repo add jetstack https://charts.jetstack.io 2>/dev/null; helm repo update"
  run_cmd "Installing cert-manager (${CERT_MANAGER_VERSION})..." \
    helm upgrade --install cert-manager jetstack/cert-manager \
      --create-namespace \
      --namespace cert-manager \
      --set crds.enabled=true \
      --wait \
      --timeout=300s
  run_cmd "Waiting for cert-manager..." \
    bash -c "kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=120s && \
             kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=120s"
  run_cmd "Creating CA issuer chain..." \
    kubectl apply -f "${REPO_DIR}/infrastructure/cert-manager/issuers.yaml"
  run_cmd "Waiting for CA certificate..." \
    kubectl wait --for=condition=Ready certificate/mcp-ca-cert -n cert-manager --timeout=60s

  # --- mcp-gateway CRDs + controller ---
  run_cmd "Installing MCP CRDs..." \
    bash -c "kubectl apply -f '${REPO_DIR}/infrastructure/mcp-gateway/mcp.kuadrant.io_mcpserverregistrations.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/mcp-gateway/mcp.kuadrant.io_mcpvirtualservers.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/mcp-gateway/mcp.kuadrant.io_mcpgatewayextensions.yaml'"
  run_cmd "Deploying mcp-gateway controller..." \
    kubectl apply -f "${REPO_DIR}/infrastructure/mcp-gateway/deploy.yaml"
  run_cmd "Waiting for mcp-controller..." \
    kubectl wait --for=condition=Available deployment/mcp-controller -n mcp-system --timeout=120s

  # --- Lifecycle operator ---
  OPERATOR_IMAGE="quay.io/jrao/mcp-lifecycle-operator:gateway-credential-ref"
  run_cmd "Pulling operator image..." \
    ${CONTAINER_ENGINE} pull "${OPERATOR_IMAGE}"
  TMP_TAR="/tmp/operator-image-$$.tar"
  run_cmd "Loading image into Kind..." \
    bash -c "${CONTAINER_ENGINE} save '${OPERATOR_IMAGE}' -o '${TMP_TAR}' && kind load image-archive '${TMP_TAR}' --name '${KIND_CLUSTER_NAME}' && rm -f '${TMP_TAR}'"
  run_cmd "Deploying lifecycle operator..." \
    kubectl apply -f "${REPO_DIR}/infrastructure/lifecycle-operator/deploy.yaml"
  run_cmd "Waiting for operator..." \
    kubectl wait --for=condition=Available deployment/mcp-lifecycle-operator-controller-manager \
      -n mcp-lifecycle-operator-system --timeout=120s
  run_cmd "Applying gateway RBAC..." \
    bash -c "kubectl apply -f '${REPO_DIR}/infrastructure/operator-gateway/gateway-role.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/operator-gateway/gateway-role-binding.yaml'"

  # --- Catalog ---
  kubectl create namespace catalog-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  run_cmd "Deploying catalog system..." \
    bash -c "kubectl apply -f '${REPO_DIR}/infrastructure/catalog/postgres.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/catalog/catalog-sources.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/catalog/catalog.yaml'"
  run_cmd "Waiting for catalog pods..." \
    bash -c "kubectl wait --for=condition=Ready pod -l app=mcp-catalog-postgres -n catalog-system --timeout=120s && \
             kubectl wait --for=condition=Ready pod -l app=mcp-catalog -n catalog-system --timeout=120s"

  # --- Launcher ---
  run_cmd "Deploying MCP Launcher..." \
    bash -c "kubectl apply -f '${REPO_DIR}/infrastructure/launcher/rbac.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/launcher/deployment.yaml'"
  run_cmd "Waiting for Launcher..." \
    bash -c "kubectl wait --for=condition=Ready pod -l app=mcp-launcher -n catalog-system --timeout=120s 2>/dev/null || true"

  # --- Keycloak ---
  kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  run_cmd "Deploying Keycloak..." \
    bash -c "kubectl apply -f '${REPO_DIR}/infrastructure/keycloak/realm-import.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/keycloak/deployment.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/keycloak/keycloak-auth-service.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/keycloak/nodeport.yaml'"
  run_cmd "Waiting for Keycloak..." \
    kubectl wait --for=condition=Ready pod -l app=keycloak -n keycloak --timeout=180s

  # --- Kuadrant ---
  run_cmd "Adding Kuadrant Helm repo..." \
    bash -c "helm repo add kuadrant https://kuadrant.io/helm-charts 2>/dev/null; helm repo update"
  run_cmd "Installing Kuadrant operator (this may take a few minutes)..." \
    helm upgrade --install kuadrant-operator kuadrant/kuadrant-operator \
      --create-namespace \
      --wait \
      --timeout=600s \
      --namespace kuadrant-system
  run_cmd "Creating Kuadrant instance..." \
    kubectl apply -f "${REPO_DIR}/infrastructure/kuadrant/kuadrant.yaml"
  run_cmd "Waiting for Authorino..." \
    bash -c "kubectl wait --for=condition=Ready pod -l app=authorino -n kuadrant-system --timeout=120s 2>/dev/null || \
             kubectl wait --for=condition=Ready pod -l authorino-resource -n kuadrant-system --timeout=120s 2>/dev/null || true"

  # Patch CoreDNS for in-cluster Keycloak resolution
  KEYCLOAK_AUTH_IP=$(kubectl get svc keycloak-auth -n keycloak -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
  if [ -n "${KEYCLOAK_AUTH_IP}" ]; then
    run_cmd "Patching CoreDNS for Keycloak resolution..." \
      bash -c "kubectl get configmap coredns -n kube-system -o yaml | \
        sed 's/ready/hosts {\n          ${KEYCLOAK_AUTH_IP} keycloak.127-0-0-1.sslip.io\n          fallthrough\n        }\n        ready/' | \
        kubectl apply -f - && \
        kubectl rollout restart deployment coredns -n kube-system"
  fi

  # --- Vault ---
  run_cmd "Deploying Vault..." \
    bash -c "kubectl apply -f '${REPO_DIR}/infrastructure/vault/namespace.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/vault/deployment.yaml'"
  run_cmd "Waiting for Vault..." \
    kubectl wait --for=condition=Ready pod -l app=vault -n vault --timeout=120s
  run_cmd "Configuring Vault JWT auth..." \
    "${REPO_DIR}/infrastructure/vault/configure.sh"

  phase_done 1
  show_resources \
    "Nodes: nodes" \
    "Namespaces: namespaces" \
    "MCP Controller: deployments -n mcp-system" \
    "Keycloak: pods -n keycloak" \
    "Vault: pods -n vault" \
    "Catalog: pods -n catalog-system"
fi

fi # phase 1

########################################
# Phase 2: team-a Namespace
########################################

if [ "$START_PHASE" -le 2 ]; then

show_phase 2 "team-a Namespace" "
## What this does

Creates the **team-a** namespace with its own isolated Gateway, MCPGatewayExtension,
NodePort service, and two MCP test servers.

## Why

This is where the multi-tenancy model comes alive. Each team gets:

1. **Gateway** — An Istio-managed Envoy proxy scoped to the team's namespace.
   The hostname \`team-a.mcp.127-0-0-1.sslip.io\` routes traffic exclusively
   to this team's servers. Complete traffic isolation from other teams.

2. **MCPGatewayExtension** — When applied, the mcp-controller automatically
   deploys a **broker/router pod** in the team namespace and creates a
   **config Secret** (\`mcp-gateway-config\`) scoped to this namespace. Server
   registrations are namespace-scoped — team-a's broker only sees team-a's servers.

3. **NodePorts** — Maps Kind's port 30080 (host port 8001) for HTTP and
   30443 (host port 8443) for HTTPS to the team gateway.

4. **MCP Servers** — Two test servers (\`test-server-a1\` with 5 tools,
   \`test-server-a2\` with 7 tools) deployed via MCPServer CRs. The lifecycle
   operator creates Deployment, Service, HTTPRoute, and MCPServerRegistration
   for each.

5. **TLS** — TLSPolicy references the CA issuer from Phase 1. cert-manager
   automatically issues a certificate for the HTTPS listener. An EnvoyFilter
   clone ensures the ext_proc (MCP router) runs on the HTTPS port too.

## What gets created

- \`team-a\` namespace
- Gateway (\`team-a-gateway\`) with HTTP + HTTPS listeners
- MCPGatewayExtension → broker/router pod + config Secret
- NodePort services (HTTP 30080, HTTPS 30443)
- TLSPolicy + auto-provisioned certificate
- 2 MCPServer CRs → 2 Deployments, 2 Services, 2 HTTPRoutes, 2 MCPServerRegistrations
"

if confirm_phase 2; then
  kubectl apply -f "${REPO_DIR}/infrastructure/team-a/namespace.yaml" >/dev/null 2>&1
  run_cmd "Deploying team-a Gateway..." \
    kubectl apply -f "${REPO_DIR}/infrastructure/team-a/gateway.yaml"
  run_cmd "Waiting for Gateway to be programmed..." \
    kubectl wait --for=condition=Programmed gateway/team-a-gateway -n team-a --timeout=300s

  run_cmd "Deploying MCPGatewayExtension (creates broker/router)..." \
    kubectl apply -f "${REPO_DIR}/infrastructure/team-a/mcpgatewayextension.yaml"
  run_cmd "Waiting for MCPGatewayExtension..." \
    kubectl wait --for=condition=Ready mcpgatewayextension/team-a-gateway-extension -n team-a --timeout=120s

  run_cmd "Deploying NodePort service..." \
    kubectl apply -f "${REPO_DIR}/infrastructure/team-a/nodeport.yaml"

  run_cmd "Deploying MCP servers..." \
    bash -c "kubectl apply -f '${REPO_DIR}/infrastructure/team-a/test-server-a1.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/team-a/test-server-a2.yaml'"
  run_cmd "Waiting for MCP servers..." \
    bash -c "kubectl wait --for=condition=Ready mcpserver/test-server-a1 -n team-a --timeout=120s 2>/dev/null; \
             kubectl wait --for=condition=Ready mcpserver/test-server-a2 -n team-a --timeout=120s 2>/dev/null || true"

  # Wait for broker to discover servers
  sleep 5

  # --- TLS ---
  run_cmd "Applying TLSPolicy..." \
    kubectl apply -f "${REPO_DIR}/infrastructure/team-a/tls-policy.yaml"
  run_cmd "Deploying HTTPS NodePort..." \
    kubectl apply -f "${REPO_DIR}/infrastructure/team-a/nodeport-tls.yaml"

  run_cmd "Waiting for TLSPolicy to be enforced..." \
    bash -c "for i in \$(seq 1 12); do \
      STATUS=\$(kubectl get tlspolicy team-a-gateway-tls -n team-a -o jsonpath='{.status.conditions[?(@.type==\"Enforced\")].status}' 2>/dev/null); \
      [ \"\$STATUS\" = 'True' ] && exit 0; sleep 5; \
    done; \
    kubectl rollout restart deployment kuadrant-operator-controller-manager -n kuadrant-system 2>/dev/null; \
    kubectl rollout status deployment kuadrant-operator-controller-manager -n kuadrant-system --timeout=60s 2>/dev/null; \
    kubectl annotate tlspolicy team-a-gateway-tls -n team-a reconcile-trigger=\"\$(date +%s)\" --overwrite 2>/dev/null; \
    sleep 10"
  run_cmd "Waiting for HTTPS certificate..." \
    bash -c "kubectl wait --for=condition=Ready certificate/team-a-gateway-mcp-https-tls -n team-a --timeout=120s 2>/dev/null || true"

  # Clone EnvoyFilter for HTTPS port
  EXISTING_EF=$(kubectl get envoyfilter -n team-a -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
                kubectl get envoyfilter -n istio-system -l gateway.io/name=team-a-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -n "$EXISTING_EF" ]; then
    EF_NS="team-a"
    kubectl get envoyfilter "$EXISTING_EF" -n team-a &>/dev/null || EF_NS="istio-system"
    TLS_EF_EXISTS=$(kubectl get envoyfilter "${EXISTING_EF}-tls" -n "$EF_NS" -o name 2>/dev/null)
    if [ -z "$TLS_EF_EXISTS" ]; then
      run_cmd "Creating ext_proc EnvoyFilter for HTTPS..." \
        bash -c "kubectl get envoyfilter '${EXISTING_EF}' -n '${EF_NS}' -o yaml | \
          sed 's/name: ${EXISTING_EF}/name: ${EXISTING_EF}-tls/' | \
          sed 's/portNumber: 8080/portNumber: 8443/' | \
          grep -v 'resourceVersion:' | grep -v 'uid:' | grep -v 'creationTimestamp:' | \
          kubectl apply -f -"
    fi
  fi

  # Extract CA cert
  bash -c "kubectl get secret mcp-ca-secret -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/mcp-ca.crt 2>/dev/null || \
           kubectl get secret mcp-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/mcp-ca.crt 2>/dev/null || true"

  phase_done 2
  show_resources \
    "Gateway: gateway -n team-a" \
    "MCPGatewayExtension: mcpgatewayextension -n team-a" \
    "MCPServers: mcpserver -n team-a" \
    "Pods: pods -n team-a" \
    "Services: services -n team-a" \
    "HTTPRoutes: httproute -n team-a" \
    "MCPServerRegistrations: mcpserverregistration -n team-a" \
    "TLSPolicy: tlspolicy -n team-a" \
    "Certificates: certificate -n team-a"
fi

fi # phase 2

########################################
# Phase 3: Keycloak Groups + Users
########################################

if [ "$START_PHASE" -le 3 ]; then

show_phase 3 "Keycloak Groups + Users" "
## What this does

Creates **team-a groups** and **users** in Keycloak via the admin REST API.

## Why

The realm import (Phase 1) only creates the base realm with generic groups
(\`developers\`, \`ops\`). For the multi-tenancy model, each team needs its own
groups so AuthPolicies can scope tool access per team:

- **team-a-developers** — utility and inspection tools (greet, time, headers)
- **team-a-ops** — admin and management tools (add_tool, slow, auth1234, set_time)
- **team-a-leads** — all tools across both servers

Users:
- **dev1, dev2** → team-a-developers (password = username)
- **ops1, ops2** → team-a-ops
- **lead1** → team-a-leads

Groups appear in the JWT \`groups\` claim via Keycloak's group membership mapper.
The gateway-level AuthPolicy reads this claim to inject the \`X-Mcp-Virtualserver\`
header (Phase 4), and per-HTTPRoute AuthPolicies use it for tool-level authorization.

## What gets created

- 3 Keycloak groups (team-a-developers, team-a-ops, team-a-leads)
- 5 Keycloak users with group assignments
"

if confirm_phase 3; then
  KEYCLOAK_ADMIN_URL="${KEYCLOAK_EXTERNAL}/admin/realms/mcp"

  get_admin_token() {
    curl -s -X POST "${KEYCLOAK_EXTERNAL}/realms/master/protocol/openid-connect/token" \
      -d "grant_type=password" \
      -d "client_id=admin-cli" \
      -d "username=admin" \
      -d "password=admin" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
  }

  ADMIN_TOKEN=$(get_admin_token)

  # Create groups
  for GROUP in team-a-developers team-a-ops team-a-leads; do
    run_cmd "Creating group: ${GROUP}..." \
      bash -c "curl -s -o /dev/null -w '%{http_code}' \
        -X POST '${KEYCLOAK_ADMIN_URL}/groups' \
        -H 'Authorization: Bearer ${ADMIN_TOKEN}' \
        -H 'Content-Type: application/json' \
        -d '{\"name\": \"${GROUP}\"}' | grep -qE '201|409'"
  done

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

  create_user_with_group() {
    local username="$1"
    local group_id="$2"
    local group_name="$3"

    curl -s -o /dev/null \
      -X POST "${KEYCLOAK_ADMIN_URL}/users" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"username\": \"${username}\",
        \"email\": \"${username}@example.com\",
        \"emailVerified\": true,
        \"enabled\": true,
        \"credentials\": [{\"type\": \"password\", \"value\": \"${username}\", \"temporary\": false}]
      }"

    local user_id
    user_id=$(curl -s "${KEYCLOAK_ADMIN_URL}/users?username=${username}&exact=true" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" | \
      python3 -c "import sys,json; users=json.load(sys.stdin); print(users[0]['id'] if users else '')")

    if [ -n "$user_id" ]; then
      curl -s -o /dev/null -X PUT \
        "${KEYCLOAK_ADMIN_URL}/users/${user_id}/groups/${group_id}" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        -H "Content-Type: application/json"
    fi
  }

  ADMIN_TOKEN=$(get_admin_token)
  run_cmd "Creating user dev1 → team-a-developers..." \
    bash -c "$(declare -f create_user_with_group); KEYCLOAK_ADMIN_URL='${KEYCLOAK_ADMIN_URL}'; ADMIN_TOKEN='${ADMIN_TOKEN}'; create_user_with_group dev1 '${DEV_GROUP_ID}' team-a-developers"
  run_cmd "Creating user dev2 → team-a-developers..." \
    bash -c "$(declare -f create_user_with_group); KEYCLOAK_ADMIN_URL='${KEYCLOAK_ADMIN_URL}'; ADMIN_TOKEN='${ADMIN_TOKEN}'; create_user_with_group dev2 '${DEV_GROUP_ID}' team-a-developers"

  ADMIN_TOKEN=$(get_admin_token)
  run_cmd "Creating user ops1 → team-a-ops..." \
    bash -c "$(declare -f create_user_with_group); KEYCLOAK_ADMIN_URL='${KEYCLOAK_ADMIN_URL}'; ADMIN_TOKEN='${ADMIN_TOKEN}'; create_user_with_group ops1 '${OPS_GROUP_ID}' team-a-ops"
  run_cmd "Creating user ops2 → team-a-ops..." \
    bash -c "$(declare -f create_user_with_group); KEYCLOAK_ADMIN_URL='${KEYCLOAK_ADMIN_URL}'; ADMIN_TOKEN='${ADMIN_TOKEN}'; create_user_with_group ops2 '${OPS_GROUP_ID}' team-a-ops"

  ADMIN_TOKEN=$(get_admin_token)
  run_cmd "Creating user lead1 → team-a-leads..." \
    bash -c "$(declare -f create_user_with_group); KEYCLOAK_ADMIN_URL='${KEYCLOAK_ADMIN_URL}'; ADMIN_TOKEN='${ADMIN_TOKEN}'; create_user_with_group lead1 '${LEADS_GROUP_ID}' team-a-leads"

  phase_done 3
fi

fi # phase 3

########################################
# Phase 4: VirtualMCPServers + AuthPolicies
########################################

if [ "$START_PHASE" -le 4 ]; then

show_phase 4 "VirtualMCPServers + AuthPolicies" "
## What this does

Applies **VirtualMCPServer** CRs for per-group tool filtering and **AuthPolicy** CRs
for authentication + tool-level authorization.

## How it works — two layers

### Layer 1: Tool filtering (VirtualMCPServer)

VirtualMCPServer CRs define named subsets of the full tool list:
- **team-a-dev-tools** → 6 tools (greet, time, headers from both servers)
- **team-a-ops-tools** → 6 tools (add_tool, slow, auth1234, set_time, etc.)
- **team-a-lead-tools** → all 12 tools

The gateway-level AuthPolicy injects an \`X-Mcp-Virtualserver\` header based on the
user's group claim (via CEL expression). The broker reads this header and filters
the \`tools/list\` response — users only *see* their group's tools.

**Important**: This is filtering-only. The broker does NOT enforce it on \`tools/call\`.
A user could call a tool they don't see in the list. Enforcement is Layer 2.

### Layer 2: Tool authorization (per-HTTPRoute AuthPolicy)

Per-HTTPRoute AuthPolicies define CEL predicates that check:
- Which group the user belongs to (from JWT \`groups\` claim)
- Which tool they're calling (from \`x-mcp-toolname\` header, set by the router)

If the predicate doesn't match, Authorino returns 403.

**Friction point (Finding 50)**: Kuadrant supports only one AuthPolicy per HTTPRoute.
This means all group→tool mappings for a server must be combined in a single CR.
Adding a new group requires editing the existing AuthPolicy, not applying a new one.

## What gets created

- 3 VirtualMCPServer CRs (dev-tools, ops-tools, lead-tools)
- 1 Gateway-level AuthPolicy (JWT auth + VirtualMCPServer header injection)
- 2 Per-HTTPRoute AuthPolicies (tool-level authorization for server-a1 and server-a2)
"

if confirm_phase 4; then
  run_cmd "Applying VirtualMCPServer CRs..." \
    bash -c "kubectl apply -f '${REPO_DIR}/infrastructure/team-a/virtualserver-dev.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/team-a/virtualserver-ops.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/team-a/virtualserver-leads.yaml'"

  run_cmd "Applying gateway-level AuthPolicy..." \
    kubectl apply -f "${REPO_DIR}/infrastructure/team-a/gateway-auth-policy.yaml"
  sleep 5  # Allow gateway-level policy to settle

  run_cmd "Applying per-HTTPRoute AuthPolicies..." \
    bash -c "kubectl apply -f '${REPO_DIR}/infrastructure/team-a/authpolicy-server-a1.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/team-a/authpolicy-server-a2.yaml'"

  phase_done 4
  show_resources \
    "VirtualMCPServers: mcpvirtualserver -n team-a" \
    "AuthPolicies: authpolicy -n team-a"
fi

fi # phase 4

########################################
# Phase 5: Config Secret Patch
########################################

if [ "$START_PHASE" -le 5 ]; then

show_phase 5 "Config Secret Patch" "
## What this does

Patches team-a's **config Secret** with VirtualMCPServer definitions so the broker
can filter \`tools/list\` responses per group.

## Why this is needed (Finding 48)

The MCPVirtualServer controller has a bug: it writes VirtualMCPServer data to a
hardcoded location (\`mcp-system/mcp-gateway-config\`) instead of the team namespace's
config Secret. This is because \`config.DefaultNamespaceName\` in the controller source
is hardcoded to \`mcp-system\`.

In our multi-tenancy model, each team has its own config Secret (created by the
MCPGatewayExtension controller). The VirtualMCPServer controller doesn't know about
these per-namespace secrets.

## Workaround

We manually read team-a's config Secret, append the \`virtualServers:\` section with
all three VirtualMCPServer definitions, and apply the updated Secret. Then we restart
the broker to pick up the new config.

This is a temporary workaround — the upstream fix would be to make the controller
namespace-aware and write VirtualMCPServer data to the same namespace as the
MCPGatewayExtension that owns it.

## What gets modified

- Secret \`mcp-gateway-config\` in team-a (patched with virtualServers section)
- Broker pod restarted to load new config
"

if confirm_phase 5; then
  run_cmd "Waiting for config Secret..." \
    bash -c "for i in \$(seq 1 12); do kubectl get secret mcp-gateway-config -n team-a &>/dev/null && break; sleep 5; done"

  CURRENT_CONFIG=$(kubectl get secret mcp-gateway-config -n team-a -o jsonpath='{.data.config\.yaml}' | base64 -d)

  if echo "$CURRENT_CONFIG" | grep -q "virtualServers:"; then
    if [ "$BATCH_MODE" = false ]; then
      gum style --foreground 214 "Config Secret already contains virtualServers — skipping patch."
    else
      echo "  Config Secret already patched — skipping."
    fi
  else
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

    run_cmd "Patching config Secret with VirtualMCPServer definitions..." \
      bash -c "kubectl create secret generic mcp-gateway-config -n team-a \
        --from-literal='config.yaml=${PATCHED_CONFIG}' \
        --dry-run=client -o yaml | kubectl apply -f -"

    BROKER_DEPLOY=$(kubectl get deploy -n team-a -l app=mcp-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$BROKER_DEPLOY" ]; then
      run_cmd "Restarting broker to load new config..." \
        bash -c "kubectl rollout restart deployment '${BROKER_DEPLOY}' -n team-a && \
                 kubectl rollout status deployment '${BROKER_DEPLOY}' -n team-a --timeout=60s"
    fi
  fi

  phase_done 5
fi

fi # phase 5

########################################
# Complete
########################################

echo ""
if [ "$BATCH_MODE" = true ]; then
  echo "=== Setup complete! ==="
else
  gum style --border double --border-foreground 82 --padding "1 3" --margin "1 0" --align center \
    "Setup Complete!" \
    "" \
    "Multi-tenant MCP ecosystem deployed successfully." \
    "" \
    "Shared control plane + team-a namespace with isolated" \
    "gateway (HTTP+HTTPS), 2 servers, 3 groups, per-tool auth."
fi

echo ""

if [ "$BATCH_MODE" = false ]; then
  gum format << 'EOF'
## Architecture

```
Shared Control Plane          team-a Namespace
─────────────────────         ──────────────────────
mcp-system (controller)       Gateway (HTTP+HTTPS)
keycloak (OIDC)               MCPGatewayExtension (broker/router)
kuadrant (Authorino)          test-server-a1 (5 tools)
vault (credentials)           test-server-a2 (7 tools)
catalog + launcher            3 VirtualMCPServers + TLSPolicy
cert-manager (TLS)            3 AuthPolicies
```

## Endpoints

| Service | URL |
|---------|-----|
| team-a Gateway (HTTP) | http://team-a.mcp.127-0-0-1.sslip.io:8001/mcp |
| team-a Gateway (HTTPS) | https://team-a.mcp.127-0-0-1.sslip.io:8443/mcp |
| Keycloak | http://keycloak.127-0-0-1.sslip.io:8002 (admin/admin) |
| Launcher | http://localhost:8004 |
| CA cert | /tmp/mcp-ca.crt (use with \`curl --cacert\`) |

## team-a Users (password = username)

| User | Group | Tools Visible | Tools Allowed |
|------|-------|---------------|---------------|
| dev1, dev2 | team-a-developers | 6 (utility) | greet, time, headers |
| ops1, ops2 | team-a-ops | 6 (admin) | add_tool, slow, auth1234, set_time |
| lead1 | team-a-leads | 12 (all) | all tools |

## Try it

```bash
# Interactive CLI client
GATEWAY_URL=http://team-a.mcp.127-0-0-1.sslip.io:8001 ./scripts/mcp-client.sh

# Run the full test pipeline
./scripts/test-pipeline.sh
```
EOF
else
  echo "Endpoints:"
  echo "  team-a Gateway (HTTP):  http://team-a.mcp.127-0-0-1.sslip.io:8001/mcp"
  echo "  team-a Gateway (HTTPS): https://team-a.mcp.127-0-0-1.sslip.io:8443/mcp"
  echo "  Keycloak:               http://keycloak.127-0-0-1.sslip.io:8002 (admin/admin)"
  echo "  Launcher:               http://localhost:8004"
  echo "  CA cert:                /tmp/mcp-ca.crt"
  echo ""
  echo "team-a users (password = username):"
  echo "  dev1, dev2  (team-a-developers) — 6 tools"
  echo "  ops1, ops2  (team-a-ops)        — 6 tools"
  echo "  lead1       (team-a-leads)      — 12 tools"
  echo ""
  echo "Quick test:"
  echo "  ./scripts/mcp-client.sh"
  echo "  ./scripts/test-pipeline.sh"
fi

# Clean up state file on successful completion
rm -f "$STATE_FILE"
