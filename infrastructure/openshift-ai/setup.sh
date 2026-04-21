#!/usr/bin/env bash
# =============================================================================
# MCP Ecosystem — Setup
# =============================================================================
# Installs all shared infrastructure on an OpenShift cluster:
#   Phase 1: Operator subscriptions (MCP Gateway, RHBK, Kuadrant)
#   Phase 2: Keycloak (DB, realm, users, groups, claims)
#   Phase 3: MCP Lifecycle Operator
#   Phase 4: Vault (Helm, init, JWT auth, per-user policy)
#   Phase 5: MCP Gateway instance in team-a (Helm + Route)
#   Phase 6: Playground (RHOAI Gen AI Studio + LlamaStack)
#
# Prerequisites:
#   - oc / kubectl logged into the target cluster
#   - helm v3 installed
#   - RHOAI 3.4 installed with mcpCatalog + Gen AI Studio enabled
#   - python3 available (for JSON parsing)
#
# Usage:
#   ./setup.sh                   # run all phases
#   ./setup.sh --phase 3         # run from phase 3 onward
#   ./setup.sh --phase 2 --only  # run only phase 2
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

header() { echo ""; echo "══════════════════════════════════════════════════════════════"; echo "  $1"; echo "══════════════════════════════════════════════════════════════"; }
step()   { echo ""; echo "── $1"; }
ok()     { echo "   ✓ $1"; }
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

should_run() { local phase=$1; [[ $phase -ge $START_PHASE ]] && { $ONLY_PHASE && [[ $phase -ne $START_PHASE ]] && return 1; return 0; }; }

# =============================================================================
# Phase 1: Operator Subscriptions
# =============================================================================
if should_run 1; then
  header "Phase 1: Operator Subscriptions"

  step "1.1 MCP Gateway CatalogSource"
  oc apply -f "${SCRIPT_DIR}/operator subscriptions/mcp-gateway-catalogsource.yaml"
  ok "CatalogSource applied"

  step "1.2 MCP Gateway Operator (mcp-system namespace)"
  oc create namespace mcp-system --dry-run=client -o yaml | oc apply -f -
  oc apply -f "${SCRIPT_DIR}/operator subscriptions/mcp-gateway-operator.yaml"
  wait_for "MCP Gateway CSV" "oc get csv -n mcp-system -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Succeeded" 300
  ok "MCP Gateway operator installed"

  step "1.3 RHBK Operator (keycloak namespace)"
  oc create namespace keycloak --dry-run=client -o yaml | oc apply -f -
  oc apply -f "${SCRIPT_DIR}/operator subscriptions/rhbk-operator.yaml"
  wait_for "RHBK CSV" "oc get csv -n keycloak -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Succeeded" 300
  ok "RHBK operator installed"

  step "1.4 Red Hat Connectivity Link operator"
  oc apply -f "${SCRIPT_DIR}/operator subscriptions/connectivity-link.yaml"
  echo "   Waiting for install plan..."
  sleep 10
  INSTALL_PLAN=""
  for i in $(seq 1 30); do
    INSTALL_PLAN=$(oc get installplan -n openshift-operators -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}' 2>/dev/null || true)
    [ -n "$INSTALL_PLAN" ] && break
    sleep 5
  done
  if [ -n "$INSTALL_PLAN" ]; then
    echo "   Approving install plan: $INSTALL_PLAN"
    oc patch installplan "$INSTALL_PLAN" -n openshift-operators --type merge -p '{"spec":{"approved":true}}'
    wait_for "Connectivity Link CSV" "oc get csv -n openshift-operators -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | grep -q rhcl-operator" 300
    ok "Connectivity Link operator installed"
  else
    echo "   ⚠ No pending install plan found — operator may already be installed"
  fi

  step "1.5 Kuadrant CR"
  oc apply -f "${SCRIPT_DIR}/operator subscriptions/kuadrant.yaml"
  wait_for "Kuadrant ready" "oc get kuadrant kuadrant -n openshift-operators -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True" 180
  ok "Kuadrant ready (Authorino + Limitador deployed)"
fi

# =============================================================================
# Phase 2: Keycloak
# =============================================================================
if should_run 2; then
  header "Phase 2: Keycloak"

  step "2.1 Deploy PostgreSQL + Keycloak CR + realm import"
  oc apply -f "${SCRIPT_DIR}/keycloak/keycloak.yaml"
  wait_for "Keycloak DB" "oc get deployment keycloak-db -n keycloak -o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -q 1" 120
  ok "PostgreSQL DB running"
  wait_for "Keycloak pod" "oc get keycloak keycloak -n keycloak -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True" 300
  ok "Keycloak running at https://${KEYCLOAK_HOST}"

  step "2.2 Wait for realm import"
  wait_for "realm import" "oc get keycloakrealmimport mcp-gateway-realm -n keycloak -o jsonpath='{.status.conditions[?(@.type==\"Done\")].status}' 2>/dev/null | grep -q True" 120
  ok "mcp-gateway realm imported (clients: mcp-gateway, mcp-playground; users: mcp-admin1, mcp-user1)"

  step "2.3 Create Keycloak groups and assign users"
  KEYCLOAK_HOST="$KEYCLOAK_HOST" bash "${SCRIPT_DIR}/keycloak/keycloak-groups.sh"
  ok "Groups created: mcp-admins, mcp-github, mcp-users"

  step "2.4 Add Vault-required claims to mcp-playground client"
  KEYCLOAK_HOST="$KEYCLOAK_HOST" bash "${SCRIPT_DIR}/vault/keycloak-vault-claims.sh"
  ok "Claims added: sub, preferred_username, mcp-playground audience"
fi

# =============================================================================
# Phase 3: MCP Lifecycle Operator
# =============================================================================
if should_run 3; then
  header "Phase 3: MCP Lifecycle Operator"

  step "3.1 Deploy operator"
  oc apply -f "${SCRIPT_DIR}/lifecycle operator/lifecycle-operator.yaml"
  wait_for "lifecycle operator" "oc get deployment mcp-lifecycle-operator-controller-manager -n mcp-lifecycle-operator-system -o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -q 1" 120
  ok "Lifecycle operator running (manages MCPServer CRs)"
fi

# =============================================================================
# Phase 4: Vault
# =============================================================================
if should_run 4; then
  header "Phase 4: Vault"

  step "4.1 Install Vault via Helm"
  helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
  helm repo update hashicorp
  helm upgrade -i vault hashicorp/vault \
    -n openshift-operators \
    -f "${SCRIPT_DIR}/vault/vault-helm-values.yaml"
  wait_for "Vault pod" "oc get pod vault-0 -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running" 120
  ok "Vault pod running"

  step "4.2 Initialize and configure Vault"
  KEYCLOAK_HOST="$KEYCLOAK_HOST" bash "${SCRIPT_DIR}/vault/vault-configure.sh"
  ok "Vault configured: KV v2 at mcp/, JWT auth with Keycloak JWKS, per-user policy"
fi

# =============================================================================
# Phase 5: MCP Gateway Instance (team-a)
# =============================================================================
if should_run 5; then
  header "Phase 5: MCP Gateway Instance (team-a)"

  step "5.1 Create team-a namespace"
  oc create namespace team-a --dry-run=client -o yaml | oc apply -f -
  ok "team-a namespace ready"

  step "5.2 Install gateway via Helm"
  helm upgrade -i team-a-gateway oci://ghcr.io/kuadrant/charts/mcp-gateway \
    --version 0.6.0 --namespace team-a --skip-crds \
    -f "${SCRIPT_DIR}/gateway/gateway-helm-values.yaml"
  wait_for "Gateway programmed" "oc get gateway team-a-gateway -n team-a -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}' 2>/dev/null | grep -q True" 120
  ok "Gateway programmed"

  step "5.3 Create OpenShift Route"
  # The ingress chart is not in the OCI registry — install from local mcp-gateway repo clone if available
  MCP_GATEWAY_REPO="${MCP_GATEWAY_REPO:-/Users/jrao/projects/mcp-gateway}"
  if [ -d "$MCP_GATEWAY_REPO/config/openshift/charts/mcp-gateway-ingress" ]; then
    helm upgrade -i team-a-gateway-ingress \
      "$MCP_GATEWAY_REPO/config/openshift/charts/mcp-gateway-ingress" \
      --namespace team-a \
      -f "${SCRIPT_DIR}/gateway/gateway-ingress-helm-values.yaml"
  else
    echo "   ⚠ mcp-gateway repo not found at $MCP_GATEWAY_REPO"
    echo "     Set MCP_GATEWAY_REPO env var or install the ingress chart manually:"
    echo "     helm upgrade -i team-a-gateway-ingress <path-to>/mcp-gateway-ingress -n team-a -f gateway/gateway-ingress-helm-values.yaml"
  fi

  wait_for "Route" "oc get route team-a-gateway -n team-a -o jsonpath='{.status.ingress[0].conditions[0].status}' 2>/dev/null | grep -q True" 60
  ok "Route: https://${GATEWAY_HOST}"

  step "5.4 Verify MCPGatewayExtension"
  wait_for "MCPGatewayExtension ready" "oc get mcpgatewayextension -n team-a -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True" 60
  ok "MCPGatewayExtension ready (broker deployed)"

  step "5.5 Generate ECDSA keys for wristband tool filtering"
  bash "${SCRIPT_DIR}/gateway/wristband-keys.sh"
  ok "ECDSA key pair created (private in openshift-operators, public in team-a)"

  step "5.6 Patch MCPGatewayExtension with trustedHeadersKey"
  MCPGW_EXT_NAME=$(oc get mcpgatewayextension -n team-a -o jsonpath='{.items[0].metadata.name}')
  oc patch mcpgatewayextension "$MCPGW_EXT_NAME" -n team-a --type merge \
    -p '{"spec":{"trustedHeadersKey":{"generate":"Disabled","secretName":"trusted-headers-public-key"}}}'
  wait_for "MCPGatewayExtension reconcile" "oc get mcpgatewayextension $MCPGW_EXT_NAME -n team-a -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True" 60
  ok "Broker configured to validate x-authorized-tools wristband JWTs"
fi

# =============================================================================
# Phase 6: Playground (RHOAI Gen AI Studio + LlamaStack)
# =============================================================================
if should_run 6; then
  header "Phase 6: Playground (RHOAI Gen AI Studio + LlamaStack)"

  echo ""
  echo "  This phase requires manual steps in the RHOAI Dashboard."
  echo "  Prerequisites:"
  echo "    - RHOAI 3.4 installed with mcpCatalog + Gen AI Studio enabled"
  echo "    - The LlamaStack operator installed"
  echo "    - A vLLM model deployed in a Data Science Project namespace"
  echo "    - The InferenceService labeled with opendatahub.io/genai-asset=true"
  echo "      so it appears as an AI asset endpoint in Gen AI Studio"
  echo ""

  step "6.1 Ensure ServingRuntime has correct --served-model-name and tool-calling args"
  echo "  The Playground registers models by InferenceService name, but vLLM uses"
  echo "  --served-model-name. These MUST match or inference will fail with 404."
  echo "  The ServingRuntime also needs --enable-auto-tool-choice --tool-call-parser openai."
  echo ""
  read -p "  Enter the namespace where vLLM is deployed [gpt-oss]: " VLLM_NS
  VLLM_NS="${VLLM_NS:-gpt-oss}"
  echo ""
  echo "  Available ServingRuntimes in ${VLLM_NS}:"
  oc get servingruntime -n "$VLLM_NS" -o custom-columns=NAME:.metadata.name,SERVED_MODEL_NAME:'.spec.containers[0].args' --no-headers 2>/dev/null | while read -r name args; do
    served_name=$(echo "$args" | python3 -c "import sys,ast; a=ast.literal_eval(sys.stdin.read()); i=a.index('--served-model-name'); print(a[i+1])" 2>/dev/null || echo "NOT SET")
    has_tool_choice=$(echo "$args" | grep -q 'enable-auto-tool-choice' && echo "yes" || echo "NO")
    echo "    ${name}  →  served-model-name: ${served_name}, tool-calling: ${has_tool_choice}"
  done
  echo ""
  echo "  Available InferenceServices in ${VLLM_NS}:"
  oc get inferenceservice -n "$VLLM_NS" -o custom-columns=NAME:.metadata.name,RUNTIME:.spec.predictor.model.runtime,GENAI_ASSET:.metadata.labels.opendatahub\\.io/genai-asset --no-headers 2>/dev/null
  echo ""
  echo "  For each ServingRuntime, ensure:"
  echo "    1. --served-model-name matches the InferenceService name"
  echo "    2. --enable-auto-tool-choice and --tool-call-parser openai are present"
  echo "    3. The InferenceService has label opendatahub.io/genai-asset=true"
  echo ""
  echo "  Example patch:"
  echo "    oc patch servingruntime <runtime-name> -n ${VLLM_NS} --type json -p '[{\"op\":\"replace\",\"path\":\"/spec/containers/0/args\",\"value\":[...]}]'"
  echo ""
  read -p "  Press Enter once ServingRuntimes are configured (vLLM pods will restart)..."

  step "6.2 Register MCP Gateway in RHOAI Dashboard"
  oc apply -f "${SCRIPT_DIR}/playground/gen-ai-aa-mcp-servers.yaml"
  ok "gen-ai-aa-mcp-servers ConfigMap applied to redhat-ods-applications"

  step "6.3 Create Playground via RHOAI Dashboard"
  echo ""
  echo "  ┌─────────────────────────────────────────────────────────────┐"
  echo "  │  UI Steps                                                  │"
  echo "  │                                                            │"
  echo "  │  1. Open the RHOAI Dashboard → Gen AI Studio               │"
  echo "  │  2. Click 'Create Playground'                              │"
  echo "  │  3. Select the vLLM model endpoint (AI asset endpoint)     │"
  echo "  │  4. Under MCP tools, add the Team-A MCP Gateway           │"
  echo "  │  5. Click Create — this creates a LlamaStackDistribution  │"
  echo "  │     CR, ConfigMap, and Route automatically                 │"
  echo "  └─────────────────────────────────────────────────────────────┘"
  echo ""
  echo "  The LlamaStack distribution connects:"
  echo "    - vLLM inference (tool-calling enabled model)"
  echo "    - MCP tool_runtime (remote::model-context-protocol)"
  echo "    - SQLite storage for agent state"
  echo ""

  read -p "  Press Enter after creating the Playground in the UI..."

  step "6.4 Validate LlamaStack"
  echo "  Checking for LlamaStackDistribution CRs across the cluster..."
  LLAMA_NS=$(oc get llamastackdistribution --all-namespaces -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
  LLAMA_NAME=$(oc get llamastackdistribution --all-namespaces -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$LLAMA_NS" ] && [ -n "$LLAMA_NAME" ]; then
    ok "Found: $LLAMA_NAME in namespace $LLAMA_NS"
    wait_for "LlamaStack pod" "oc get pod -n $LLAMA_NS -l app.kubernetes.io/part-of=llama-stack -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running" 180
    ok "LlamaStack pod running"

    LLAMA_ROUTE=$(oc get route -n "$LLAMA_NS" -l app.kubernetes.io/part-of=llama-stack -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
    if [ -n "$LLAMA_ROUTE" ]; then
      ok "LlamaStack route: https://${LLAMA_ROUTE}"
    else
      echo "   ⚠ No LlamaStack route found — check the LlamaStackDistribution spec.network.exposeRoute"
    fi
  else
    echo "   ⚠ No LlamaStackDistribution found. Create one via the RHOAI Dashboard."
  fi
fi

# =============================================================================
# Summary
# =============================================================================
header "Setup Complete"
echo ""
echo "  Operators:"
echo "    MCP Gateway Controller  → mcp-system"
echo "    RHBK (Keycloak)         → keycloak"
echo "    Kuadrant + Authorino    → openshift-operators"
echo "    MCP Lifecycle Operator  → mcp-lifecycle-operator-system"
echo ""
echo "  Infrastructure:"
echo "    Keycloak    → https://${KEYCLOAK_HOST}"
echo "    Vault       → vault.openshift-operators.svc.cluster.local:8200"
echo "    Gateway     → https://${GATEWAY_HOST}"
echo "    Wristband   → ECDSA keys + trustedHeadersKey configured"
echo "    Playground  → RHOAI Gen AI Studio (LlamaStack + vLLM)"
echo ""
echo "  Keycloak users:"
echo "    mcp-admin1 / admin1pass  (groups: mcp-admins, mcp-github)"
echo "    mcp-user1  / user1pass   (groups: mcp-users)"
echo ""
echo "  Next: run ./usage.sh to walk through the demo phases"
echo ""
