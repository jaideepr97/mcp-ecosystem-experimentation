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

should_run() { local phase=$1; [[ $phase -ge $START_PHASE ]] && { $ONLY_PHASE && [[ $phase -ne $START_PHASE ]] && return 1; return 0; }; }

# =============================================================================
# Prerequisites
# =============================================================================
header "Prerequisites"
echo ""
echo "  Verify the following are in place before proceeding:"
echo ""
echo "  1. oc / kubectl logged into the target cluster"
echo "  2. helm v3 installed"
echo "  3. python3 available"
echo "  4. Red Hat Connectivity Link operator installed"
echo "     (includes Kuadrant / Authorino / Limitador)"
echo "  5. RHOAI 3.4 installed with mcpCatalog + Gen AI Studio enabled"
echo "  6. A vLLM ServingRuntime + InferenceService deployed and running:"
echo "     --served-model-name matching the InferenceService name"
echo "     --enable-auto-tool-choice --tool-call-parser openai"
echo "     label opendatahub.io/genai-asset=true on the InferenceService"
echo ""
echo "  Cluster: ${CLUSTER_DOMAIN}"
pause

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

  ok "Phase 1 complete"
  pause
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

  ok "Phase 2 complete"
  pause
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

  ok "Phase 3 complete"
  pause
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

  ok "Phase 4 complete"
  pause
fi

# =============================================================================
# Phase 5: MCP Gateway Instance (team-a)
# =============================================================================
if should_run 5; then
  header "Phase 5: MCP Gateway Instance (team-a)"

  step "5.1 Create team-a namespace"
  oc create namespace team-a --dry-run=client -o yaml | oc apply -f -
  ok "team-a namespace ready"

  step "5.2 Kuadrant CR"
  oc apply -f "${SCRIPT_DIR}/operator subscriptions/kuadrant.yaml"
  wait_for "Kuadrant ready" "oc get kuadrant kuadrant -n openshift-operators -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True" 180
  ok "Kuadrant ready (Authorino + Limitador deployed)"

  step "5.3 Install gateway via Helm"
  helm upgrade -i team-a-gateway oci://ghcr.io/kuadrant/charts/mcp-gateway \
    --version 0.6.0 --namespace team-a --skip-crds \
    -f "${SCRIPT_DIR}/gateway/gateway-helm-values.yaml"
  wait_for "Gateway programmed" "oc get gateway team-a-gateway -n team-a -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}' 2>/dev/null | grep -q True" 120
  ok "Gateway programmed"

  step "5.4 Create OpenShift Route"
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

  step "5.5 Generate ECDSA keys for wristband tool filtering"
  bash "${SCRIPT_DIR}/gateway/wristband-keys.sh"
  ok "ECDSA key pair created (private in openshift-operators, public in team-a)"

  step "5.6 Patch MCPGatewayExtension with trustedHeadersKey"
  MCPGW_EXT_NAME=$(oc get mcpgatewayextension -n team-a -o jsonpath='{.items[0].metadata.name}')
  oc patch mcpgatewayextension "$MCPGW_EXT_NAME" -n team-a --type merge \
    -p '{"spec":{"trustedHeadersKey":{"generate":"Disabled","secretName":"trusted-headers-public-key"}}}'
  wait_for "MCPGatewayExtension ready" "oc get mcpgatewayextension $MCPGW_EXT_NAME -n team-a -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True" 60
  ok "MCPGatewayExtension ready (broker deployed, wristband verification configured)"

  step "5.7 Wait for config Secret"
  wait_for "mcp-gateway-config" "oc get secret mcp-gateway-config -n team-a" 60
  ok "Config Secret exists in team-a (patched with VirtualMCPServers during usage)"

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

  ok "Phase 5 complete"
  pause
fi

# =============================================================================
# Phase 6: Playground (RHOAI Gen AI Studio + LlamaStack)
# =============================================================================
if should_run 6; then
  header "Phase 6: Playground (RHOAI Gen AI Studio + LlamaStack)"

  step "6.1 Create Playground via RHOAI Dashboard"
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
