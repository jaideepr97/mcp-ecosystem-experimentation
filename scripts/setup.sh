#!/usr/bin/env bash
# =============================================================================
# MCP Ecosystem — Setup
# =============================================================================
# Installs all shared infrastructure on an OpenShift cluster:
#   Phase 1: Operator subscriptions (MCP Gateway, RHBK)
#   Phase 2: Keycloak (DB, realm, users, groups, claims)
#   Phase 3: MCP Lifecycle Operator
#   Phase 4: Vault (Helm, init, JWT auth, per-user policy)
#   Phase 5: Kuadrant CR + MCP Gateway instance in team-a (Helm + Route + config Secret + RHOAI registration)
#   Phase 6: Playground (RHOAI Gen AI Studio + LlamaStack)
#
# The script runs continuously, pausing between phases for the user to
# review progress. Prerequisites are shown at the start.
#
# Usage:
#   ./setup.sh                   # guided run through all phases
#   ./setup.sh --phase 3         # start from phase 3 onward
#   ./setup.sh --phase 2 --only  # run only phase 2
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="${SCRIPT_DIR}/../infrastructure/openshift-ai"
START_PHASE="${START_PHASE:-1}"
ONLY_PHASE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --phase) START_PHASE="$2"; shift 2 ;;
    --only)  ONLY_PHASE=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Cluster-specific values (edit for your environment) ---
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com}"
KEYCLOAK_HOST="keycloak.${CLUSTER_DOMAIN}"
GATEWAY_HOST="team-a-mcp.${CLUSTER_DOMAIN}"

header()  { echo ""; echo "══════════════════════════════════════════════════════════════"; echo "  $1"; echo "══════════════════════════════════════════════════════════════"; }
step()    { echo ""; echo "── $1"; }
ok()      { echo "   ✓ $1"; }
pause()   { echo ""; read -rp "   ⏎ Press Enter to continue... " < /dev/tty; }
wait_for() {
  local what="$1" cmd="$2" timeout="${3:-120}"
  echo -n "   Waiting for $what..."
  local i=0
  while ! eval "$cmd" &>/dev/null; do
    sleep 5; i=$((i+5))
    if [ $i -ge $timeout ]; then echo " TIMEOUT"; return 1; fi
    echo -n "."
  done
  echo " ready"
}
show() {
  echo "   \$ $1"
  eval "$1" 2>/dev/null | sed 's/^/   /' || true
}
inspect() {
  echo "   Inspect:"
  for cmd in "$@"; do
    echo "     $cmd"
  done
}

should_run() { local phase=$1; [[ $phase -ge $START_PHASE ]] && { $ONLY_PHASE && [[ $phase -ne $START_PHASE ]] && return 1; return 0; }; }

# =============================================================================
# Prerequisites
# =============================================================================
header "Prerequisites"
echo ""
echo "  Verify the following are in place before proceeding:"
echo ""
echo "  Cluster: OpenShift 4.19+ (tested on ROSA 4.21.6)"
echo ""
echo "  CLI tools:"
echo "    1. oc / kubectl — logged in with cluster-admin"
echo "    2. helm v3"
echo "    3. python3"
echo ""
echo "  Operators (install via OperatorHub):"
echo "    4. NVIDIA GPU Operator (channel: v25.10, certified-operators catalog)"
echo "    5. Node Feature Discovery (channel: stable) — required by GPU operator"
echo "    6. OpenShift Service Mesh 2 (channel: stable) — Istio proxy for Gateway API"
echo "    7. OpenShift Service Mesh 3 (channel: stable) — Gateway API CRDs + openshift-default GatewayClass"
echo "    8. OpenShift Serverless (channel: stable) — required by KServe"
echo "    9. cert-manager Operator (channel: stable-v1)"
echo "   10. Red Hat Connectivity Link (channel: stable) — includes Kuadrant, Authorino, Limitador"
echo "   11. RHOAI 3.4 (channel: beta) with Gen AI Studio + MCP Catalog enabled:"
echo "       oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type merge \\"
echo "         -p '{\"spec\":{\"dashboardConfig\":{\"genAiStudio\":true,\"mcpCatalog\":true}}}'"
echo ""
echo "  Model serving:"
echo "   12. A vLLM ServingRuntime + InferenceService deployed and running:"
echo "       --served-model-name matching the InferenceService name"
echo "       --enable-auto-tool-choice --tool-call-parser openai"
echo "       label opendatahub.io/genai-asset=true on the InferenceService"
echo ""
echo "  Target: ${CLUSTER_DOMAIN}"
pause

# =============================================================================
# Phase 1: Operator Subscriptions
# =============================================================================
if should_run 1; then
  header "Phase 1: Operator Subscriptions"
  echo ""
  echo "  What: Install the MCP Gateway and RHBK (Keycloak) operators via OLM"
  echo "        subscriptions. These are cluster-scoped operators that watch"
  echo "        for their respective CRs and manage workload lifecycle."
  echo ""
  echo "  Why:  The MCP Gateway operator manages MCPGatewayExtension CRs — when"
  echo "        you create one in a namespace, it deploys a broker/router pod"
  echo "        that aggregates multiple MCP servers behind a single endpoint."
  echo "        RHBK provides Keycloak as the OIDC identity provider for JWT-based"
  echo "        authentication and group-based authorization across the ecosystem."
  echo ""
  echo "  Creates:"
  echo "    - CatalogSource/mcp-gateway-catalog (openshift-marketplace)"
  echo "    - Subscription + CSV for mcp-gateway-operator (mcp-system)"
  echo "    - Subscription + CSV for rhbk-operator (keycloak)"
  echo ""

  step "1.1 MCP Gateway CatalogSource"
  oc apply -f "${INFRA_DIR}/operator subscriptions/mcp-gateway-catalogsource.yaml"
  ok "CatalogSource applied"
  show "oc get catalogsource mcp-gateway-catalog -n openshift-marketplace -o custom-columns='NAME:.metadata.name,STATUS:.status.connectionState.lastObservedState'"
  inspect \
    "oc get catalogsource mcp-gateway-catalog -n openshift-marketplace" \
    "oc get catalogsource mcp-gateway-catalog -n openshift-marketplace -o yaml"

  step "1.2 MCP Gateway Operator (mcp-system namespace)"
  oc create namespace mcp-system --dry-run=client -o yaml | oc apply -f -
  oc apply -f "${INFRA_DIR}/operator subscriptions/mcp-gateway-operator.yaml"
  wait_for "MCP Gateway CSV" "oc get csv -n mcp-system -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Succeeded" 300
  ok "MCP Gateway operator installed"
  show "oc get csv -n mcp-system -o custom-columns='NAME:.metadata.name,VERSION:.spec.version,PHASE:.status.phase'"
  inspect \
    "oc get csv -n mcp-system" \
    "oc get csv -n mcp-system -o yaml"

  step "1.3 RHBK Operator (keycloak namespace)"
  oc create namespace keycloak --dry-run=client -o yaml | oc apply -f -
  oc apply -f "${INFRA_DIR}/operator subscriptions/rhbk-operator.yaml"
  wait_for "RHBK CSV" "oc get csv -n keycloak -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Succeeded" 300
  ok "RHBK operator installed"
  show "oc get csv -n keycloak -l operators.coreos.com/rhbk-operator.keycloak -o custom-columns='NAME:.metadata.name,VERSION:.spec.version,PHASE:.status.phase'"
  inspect \
    "oc get csv -n keycloak -l operators.coreos.com/rhbk-operator.keycloak" \
    "oc get csv -n keycloak -l operators.coreos.com/rhbk-operator.keycloak -o yaml"

  ok "Phase 1 complete"
  pause
fi

# =============================================================================
# Phase 2: Keycloak
# =============================================================================
if should_run 2; then
  header "Phase 2: Keycloak"
  echo ""
  echo "  What: Deploy Keycloak with a PostgreSQL database, import the"
  echo "        mcp-gateway realm (clients, users, roles), create groups"
  echo "        for VirtualMCPServer routing, and add Vault-required claims."
  echo ""
  echo "  Why:  Keycloak is the central identity provider. The realm defines:"
  echo "        - Clients: mcp-gateway (broker auth), mcp-playground (user tokens)"
  echo "        - Users: mcp-admin1, mcp-user1, mcp-github1 (with passwords for demo)"
  echo "        - Groups: mcp-admins, mcp-github, mcp-users — the gateway-level"
  echo "          AuthPolicy reads the JWT groups claim to route each user to"
  echo "          the correct VirtualMCPServer (tool subset)."
  echo "        - Claims: sub + preferred_username are required by Vault's JWT"
  echo "          auth for identity-based secret access (per-user GitHub PATs)."
  echo ""
  echo "  Creates:"
  echo "    - Deployment/keycloak-db + Keycloak CR (keycloak namespace)"
  echo "    - KeycloakRealmImport/mcp-gateway-realm"
  echo "    - Route for external access (https://${KEYCLOAK_HOST})"
  echo "    - Keycloak groups: mcp-admins, mcp-github, mcp-users"
  echo "    - Protocol mappers: sub, preferred_username, audience on mcp-playground client"
  echo ""

  step "2.1 Deploy PostgreSQL + Keycloak CR + realm import"
  oc apply -f "${INFRA_DIR}/keycloak/keycloak.yaml"
  wait_for "Keycloak DB" "oc get deployment keycloak-db -n keycloak -o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -q 1" 120
  ok "PostgreSQL DB running"
  wait_for "Keycloak pod" "oc get keycloak keycloak -n keycloak -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True" 300
  ok "Keycloak running at https://${KEYCLOAK_HOST}"
  show "oc get keycloak -n keycloak -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type==\"Ready\")].status'"
  show "oc get deployment keycloak-db -n keycloak -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas'"
  show "oc get route -n keycloak -o custom-columns='NAME:.metadata.name,HOST:.spec.host'"
  inspect \
    "oc get keycloak keycloak -n keycloak -o yaml" \
    "oc get deployment keycloak-db -n keycloak -o yaml" \
    "oc get route -n keycloak -o yaml"

  step "2.2 Wait for realm import"
  wait_for "realm import" "oc get keycloakrealmimport mcp-gateway-realm -n keycloak -o jsonpath='{.status.conditions[?(@.type==\"Done\")].status}' 2>/dev/null | grep -q True" 120
  ok "mcp-gateway realm imported (clients: mcp-gateway, mcp-playground; users: mcp-admin1, mcp-user1, mcp-github1)"
  show "oc get keycloakrealmimport -n keycloak -o custom-columns='NAME:.metadata.name,DONE:.status.conditions[?(@.type==\"Done\")].status'"
  inspect \
    "oc get keycloakrealmimport mcp-gateway-realm -n keycloak -o yaml"

  step "2.3 Create Keycloak groups and assign users"
  KEYCLOAK_HOST="$KEYCLOAK_HOST" bash "${INFRA_DIR}/keycloak/keycloak-groups.sh"
  ok "Groups created: mcp-admins, mcp-github, mcp-users"

  step "2.4 Add Vault-required claims to mcp-playground client"
  KEYCLOAK_HOST="$KEYCLOAK_HOST" bash "${INFRA_DIR}/vault/keycloak-vault-claims.sh"
  ok "Claims added: sub, preferred_username, mcp-playground audience"

  ok "Phase 2 complete"
  pause
fi

# =============================================================================
# Phase 3: MCP Lifecycle Operator
# =============================================================================
if should_run 3; then
  header "Phase 3: MCP Lifecycle Operator"
  echo ""
  echo "  What: Deploy the MCP Lifecycle Operator, which watches for MCPServer"
  echo "        CRs and automatically creates the Deployment, Service, HTTPRoute,"
  echo "        and MCPServerRegistration for each MCP server."
  echo ""
  echo "  Why:  Without this operator, deploying an MCP server requires manually"
  echo "        creating 4 resources. The lifecycle operator reduces this to a"
  echo "        single MCPServer CR — you specify the container image, port, and"
  echo "        arguments, and the operator handles the rest. It also integrates"
  echo "        with the RHOAI MCP Catalog for discover-and-deploy workflows."
  echo ""
  echo "  Creates:"
  echo "    - Deployment/mcp-lifecycle-operator-controller-manager (mcp-lifecycle-operator-system)"
  echo "    - CRD: mcpservers.mcp.x-k8s.io"
  echo ""

  step "3.1 Deploy operator"
  oc apply -f "${INFRA_DIR}/lifecycle operator/lifecycle-operator.yaml"
  wait_for "lifecycle operator" "oc get deployment mcp-lifecycle-operator-controller-manager -n mcp-lifecycle-operator-system -o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -q 1" 120
  ok "Lifecycle operator running (manages MCPServer CRs)"
  show "oc get deployment -n mcp-lifecycle-operator-system -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image'"
  show "oc get crd mcpservers.mcp.x-k8s.io -o custom-columns='NAME:.metadata.name,CREATED:.metadata.creationTimestamp'"
  inspect \
    "oc get deployment mcp-lifecycle-operator-controller-manager -n mcp-lifecycle-operator-system -o yaml" \
    "oc get crd mcpservers.mcp.x-k8s.io -o yaml"

  ok "Phase 3 complete"
  pause
fi

# =============================================================================
# Phase 4: Vault
# =============================================================================
if should_run 4; then
  header "Phase 4: Vault"
  echo ""
  echo "  What: Install HashiCorp Vault via Helm, then initialize it with KV v2"
  echo "        secrets engine, JWT auth backed by Keycloak, and a templated"
  echo "        policy for per-user secret access."
  echo ""
  echo "  Why:  Vault provides credential exchange — a user's Keycloak JWT is"
  echo "        exchanged for a short-lived Vault token, which reads the user's"
  echo "        personal secrets (e.g., GitHub PAT). This happens transparently"
  echo "        in the AuthPolicy metadata evaluator chain:"
  echo "        1. User JWT arrives at the gateway"
  echo "        2. Authorino sends JWT to Vault's /auth/jwt/login endpoint"
  echo "        3. Vault returns a client token scoped to that user's policy"
  echo "        4. Authorino reads the user's secret from Vault"
  echo "        5. The secret value is injected as a header to the upstream server"
  echo "        The MCP server never sees the user's JWT or Vault token."
  echo ""
  echo "  Creates:"
  echo "    - Pod/vault-0 (openshift-operators) via Helm chart"
  echo "    - Vault KV v2 engine at mcp/"
  echo "    - Vault JWT auth method with Keycloak JWKS"
  echo "    - Vault policy: mcp-user-secrets (per-user path templating)"
  echo "    - Vault role: mcp-user (JWT login role)"
  echo ""

  step "4.1 Install Vault via Helm"
  helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
  helm repo update hashicorp
  helm upgrade -i vault hashicorp/vault \
    -n openshift-operators \
    -f "${INFRA_DIR}/vault/vault-helm-values.yaml"
  wait_for "Vault pod" "oc get pod vault-0 -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running" 120
  ok "Vault pod running"
  show "oc get pod vault-0 -n openshift-operators -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,IMAGE:.spec.containers[0].image'"
  show "helm list -n openshift-operators --filter vault"
  inspect \
    "oc get pod vault-0 -n openshift-operators -o yaml" \
    "helm get values vault -n openshift-operators"

  step "4.2 Initialize and configure Vault"
  KEYCLOAK_HOST="$KEYCLOAK_HOST" bash "${INFRA_DIR}/vault/vault-configure.sh"
  ok "Vault configured: KV v2 at mcp/, JWT auth with Keycloak JWKS, per-user policy"

  ok "Phase 4 complete"
  pause
fi

# =============================================================================
# Phase 5: MCP Gateway Instance (team-a)
# =============================================================================
if should_run 5; then
  header "Phase 5: MCP Gateway Instance (team-a)"
  echo ""
  echo "  What: Create the team-a namespace with its own Gateway, Route,"
  echo "        MCPGatewayExtension (broker/router), wristband signing keys,"
  echo "        and RHOAI Dashboard registration."
  echo ""
  echo "  Why:  This is where the multi-tenancy model takes shape. Each team gets:"
  echo "        - Gateway: an Envoy proxy scoped to the team's namespace. The"
  echo "          hostname (team-a-mcp.${CLUSTER_DOMAIN}) routes traffic"
  echo "          exclusively to this team's MCP servers."
  echo "        - MCPGatewayExtension: tells the mcp-gateway controller to deploy"
  echo "          a broker/router pod in team-a. The broker aggregates all registered"
  echo "          MCP servers and handles tools/list filtering via VirtualMCPServers."
  echo "        - Wristband keys: ECDSA key pair for signing the x-authorized-tools"
  echo "          JWT header. The AuthPolicy signs it (private key in Authorino's"
  echo "          namespace), the broker verifies it (public key in team-a)."
  echo "        - RHOAI registration: a ConfigMap that tells Gen AI Studio about"
  echo "          this gateway, enabling Playground integration."
  echo ""
  echo "  Creates:"
  echo "    - Namespace/team-a"
  echo "    - Kuadrant CR (enables Authorino + Limitador)"
  echo "    - Gateway/team-a-gateway + Route (Helm charts)"
  echo "    - MCPGatewayExtension -> broker/router pod + config Secret"
  echo "    - Secrets: trusted-headers-private-key, trusted-headers-public-key"
  echo "    - ConfigMap/gen-ai-aa-mcp-servers (redhat-ods-applications)"
  echo ""

  step "5.1 Create team-a namespace"
  oc create namespace team-a --dry-run=client -o yaml | oc apply -f -
  ok "team-a namespace ready"
  show "oc get namespace team-a -o custom-columns='NAME:.metadata.name,STATUS:.status.phase'"
  inspect \
    "oc get namespace team-a -o yaml"

  step "5.2 Kuadrant CR"
  oc apply -f "${INFRA_DIR}/operator subscriptions/kuadrant.yaml"
  wait_for "Kuadrant ready" "oc get kuadrant kuadrant -n openshift-operators -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True" 180
  ok "Kuadrant ready (Authorino + Limitador deployed)"
  show "oc get kuadrant kuadrant -n openshift-operators -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type==\"Ready\")].status'"
  inspect \
    "oc get kuadrant kuadrant -n openshift-operators -o yaml"

  step "5.3 Install gateway via Helm"
  helm upgrade -i team-a-gateway oci://ghcr.io/kuadrant/charts/mcp-gateway \
    --version 0.6.0 --namespace team-a --skip-crds \
    -f "${INFRA_DIR}/gateway/gateway-helm-values.yaml"
  wait_for "Gateway programmed" "oc get gateway team-a-gateway -n team-a -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}' 2>/dev/null | grep -q True" 120
  ok "Gateway programmed"
  show "oc get gateway team-a-gateway -n team-a -o custom-columns='NAME:.metadata.name,CLASS:.spec.gatewayClassName,PROGRAMMED:.status.conditions[?(@.type==\"Programmed\")].status'"
  inspect \
    "oc get gateway team-a-gateway -n team-a" \
    "oc get gateway team-a-gateway -n team-a -o yaml"

  step "5.4 Create OpenShift Route"
  # The ingress chart is not in the OCI registry — install from local mcp-gateway repo clone if available
  MCP_GATEWAY_REPO="${MCP_GATEWAY_REPO:-/Users/jrao/projects/mcp-gateway}"
  if [ -d "$MCP_GATEWAY_REPO/config/openshift/charts/mcp-gateway-ingress" ]; then
    helm upgrade -i team-a-gateway-ingress \
      "$MCP_GATEWAY_REPO/config/openshift/charts/mcp-gateway-ingress" \
      --namespace team-a \
      -f "${INFRA_DIR}/gateway/gateway-ingress-helm-values.yaml"
  else
    echo "   ⚠ mcp-gateway repo not found at $MCP_GATEWAY_REPO"
    echo "     Set MCP_GATEWAY_REPO env var or install the ingress chart manually:"
    echo "     helm upgrade -i team-a-gateway-ingress <path-to>/mcp-gateway-ingress -n team-a -f gateway/gateway-ingress-helm-values.yaml"
  fi

  wait_for "Route" "oc get route team-a-gateway -n team-a -o jsonpath='{.status.ingress[0].conditions[0].status}' 2>/dev/null | grep -q True" 60
  ok "Route: https://${GATEWAY_HOST}"
  show "oc get route team-a-gateway -n team-a -o custom-columns='NAME:.metadata.name,HOST:.spec.host'"
  inspect \
    "oc get route team-a-gateway -n team-a -o yaml"

  step "5.5 Generate ECDSA keys for wristband tool filtering"
  bash "${INFRA_DIR}/gateway/wristband-keys.sh"
  ok "ECDSA key pair created (private in openshift-operators, public in team-a)"
  show "oc get secret trusted-headers-private-key -n openshift-operators -o custom-columns='NAME:.metadata.name,CREATED:.metadata.creationTimestamp'"
  show "oc get secret trusted-headers-public-key -n team-a -o custom-columns='NAME:.metadata.name,CREATED:.metadata.creationTimestamp'"
  inspect \
    "oc get secret trusted-headers-private-key -n openshift-operators -o yaml" \
    "oc get secret trusted-headers-public-key -n team-a -o yaml"

  step "5.6 Patch MCPGatewayExtension with trustedHeadersKey"
  MCPGW_EXT_NAME=$(oc get mcpgatewayextension -n team-a -o jsonpath='{.items[0].metadata.name}')
  oc patch mcpgatewayextension "$MCPGW_EXT_NAME" -n team-a --type merge \
    -p '{"spec":{"trustedHeadersKey":{"generate":"Disabled","secretName":"trusted-headers-public-key"}}}'
  wait_for "MCPGatewayExtension ready" "oc get mcpgatewayextension $MCPGW_EXT_NAME -n team-a -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True" 60
  ok "MCPGatewayExtension ready (broker deployed, wristband verification configured)"
  show "oc get mcpgatewayextension -n team-a -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type==\"Ready\")].status'"
  inspect \
    "oc get mcpgatewayextension -n team-a -o yaml"

  step "5.7 Wait for config Secret"
  wait_for "mcp-gateway-config" "oc get secret mcp-gateway-config -n team-a" 60
  ok "Config Secret exists in team-a (patched with VirtualMCPServers during usage)"
  show "oc get secret mcp-gateway-config -n team-a -o custom-columns='NAME:.metadata.name,CREATED:.metadata.creationTimestamp'"
  inspect \
    "oc get secret mcp-gateway-config -n team-a -o yaml"

  step "5.8 Register gateway in RHOAI Dashboard"
  oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: gen-ai-aa-mcp-servers
  namespace: redhat-ods-applications
data:
  Team-A-MCP-Gateway: |
    {
      "url": "https://${GATEWAY_HOST}/mcp",
      "description": "Team-A MCP Gateway — OpenShift + test tools"
    }
EOF
  ok "gen-ai-aa-mcp-servers ConfigMap applied"
  show "oc get configmap gen-ai-aa-mcp-servers -n redhat-ods-applications -o custom-columns='NAME:.metadata.name,KEYS:.data'"
  inspect \
    "oc get configmap gen-ai-aa-mcp-servers -n redhat-ods-applications -o yaml"

  ok "Phase 5 complete"
  pause
fi

# =============================================================================
# Phase 6: Playground (RHOAI Gen AI Studio + LlamaStack)
# =============================================================================
if should_run 6; then
  header "Phase 6: Playground (RHOAI Gen AI Studio + LlamaStack)"
  echo ""
  echo "  What: Create a Playground in RHOAI Gen AI Studio that connects a"
  echo "        vLLM model with the MCP Gateway for agentic tool use."
  echo ""
  echo "  Why:  The Playground is the end-user experience. RHOAI's Gen AI Studio"
  echo "        creates a LlamaStackDistribution CR that wires together:"
  echo "        - vLLM inference (tool-calling enabled model)"
  echo "        - MCP tool_runtime (remote::model-context-protocol) pointing"
  echo "          at the Team-A MCP Gateway registered in Phase 5"
  echo "        - SQLite storage for agent conversation state"
  echo "        Users chat with the model, which discovers available tools via"
  echo "        the gateway and calls them as needed. Tool visibility is governed"
  echo "        by the token the user provides (VirtualMCPServer + wristband)."
  echo ""
  echo "  Creates (via RHOAI Dashboard UI):"
  echo "    - LlamaStackDistribution CR + ConfigMap + Route"
  echo ""

  step "6.1 Create Playground via RHOAI Dashboard"
  echo ""
  echo "  ┌─────────────────────────────────────────────────────────────────────────────────────────┐"
  printf "  │  %-86s │\n" "UI Steps"
  printf "  │  %-86s │\n" ""
  printf "  │  %-86s │\n" "1. Open the RHOAI Dashboard → Gen AI Studio"
  printf "  │  %-86s │\n" "2. Click 'Create Playground'"
  printf "  │  %-86s │\n" "3. Select the vLLM model endpoint (AI asset endpoint)"
  printf "  │  %-86s │\n" "4. Under MCP tools, add the Team-A MCP Gateway"
  printf "  │  %-86s │\n" "5. Click Create — this creates a LlamaStackDistribution"
  printf "  │  %-86s │\n" "   CR, ConfigMap, and Route automatically"
  echo "  └─────────────────────────────────────────────────────────────────────────────────────────┘"
  echo ""
  echo "  The LlamaStack distribution connects:"
  echo "    - vLLM inference (tool-calling enabled model)"
  echo "    - MCP tool_runtime (remote::model-context-protocol)"
  echo "    - SQLite storage for agent state"
  echo ""

  pause

  step "6.2 Validate LlamaStack"
  echo "  Checking for LlamaStackDistribution CRs across the cluster..."
  LLAMA_NS=$(oc get llamastackdistribution --all-namespaces -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
  LLAMA_NAME=$(oc get llamastackdistribution --all-namespaces -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$LLAMA_NS" ] && [ -n "$LLAMA_NAME" ]; then
    ok "Found: $LLAMA_NAME in namespace $LLAMA_NS"
    wait_for "LlamaStack pod" "oc get pod -n $LLAMA_NS -l app.kubernetes.io/instance=$LLAMA_NAME -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running" 180
    ok "LlamaStack pod running"

    LLAMA_ROUTE=$(oc get route -n "$LLAMA_NS" -l app.kubernetes.io/instance=$LLAMA_NAME -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
    if [ -n "$LLAMA_ROUTE" ]; then
      ok "LlamaStack route: https://${LLAMA_ROUTE}"
    else
      echo "   ⚠ No LlamaStack route found — check the LlamaStackDistribution spec.network.exposeRoute"
    fi
    show "oc get llamastackdistribution $LLAMA_NAME -n $LLAMA_NS -o custom-columns='NAME:.metadata.name,NAMESPACE:.metadata.namespace'"
    show "oc get pod -n $LLAMA_NS -l app.kubernetes.io/instance=$LLAMA_NAME -o custom-columns='NAME:.metadata.name,STATUS:.status.phase'"
    inspect \
      "oc get llamastackdistribution $LLAMA_NAME -n $LLAMA_NS -o yaml" \
      "oc get pod -n $LLAMA_NS -l app.kubernetes.io/instance=$LLAMA_NAME -o yaml"
  else
    echo "   ⚠ No LlamaStackDistribution found. Create one via the RHOAI Dashboard."
  fi
fi

# =============================================================================
# Summary (only when running all phases or the last phase)
# =============================================================================
if ! $ONLY_PHASE || [[ $START_PHASE -eq 6 ]]; then
header "Setup Complete"
echo ""
echo "  Operators (installed by this script):"
echo "    MCP Gateway Controller  → mcp-system"
echo "    RHBK (Keycloak)         → keycloak"
echo "    MCP Lifecycle Operator  → mcp-lifecycle-operator-system"
echo ""
echo "  Prerequisites (installed before running this script):"
echo "    Connectivity Link       → openshift-operators (includes Kuadrant/Authorino/Limitador)"
echo "    RHOAI 3.4               → mcpCatalog + Gen AI Studio enabled"
echo "    vLLM model              → ServingRuntime + InferenceService running"
echo ""
echo "  Infrastructure:"
echo "    Keycloak    → https://${KEYCLOAK_HOST}"
echo "    Vault       → vault.openshift-operators.svc.cluster.local:8200"
echo "    Gateway     → https://${GATEWAY_HOST}"
echo "    Wristband   → ECDSA keys + trustedHeadersKey configured"
echo "    Config      → mcp-gateway-config Secret in team-a (ready for VirtualMCPServer patching)"
echo "    RHOAI       → gen-ai-aa-mcp-servers ConfigMap registered"
echo "    Playground  → RHOAI Gen AI Studio (LlamaStack + vLLM)"
echo ""
echo "  Keycloak users:"
echo "    mcp-admin1 / admin1pass  (groups: mcp-admins, mcp-github)"
echo "    mcp-user1  / user1pass   (groups: mcp-users)"
echo ""
echo "  Next: run ./usage.sh to walk through the demo phases"
echo ""
fi
