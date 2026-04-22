#!/usr/bin/env bash
# =============================================================================
# MCP Ecosystem — Cleanup
# =============================================================================
# Deletes resources created by setup.sh and usage.sh, in reverse order.
# Accepts a script name (setup/usage) and phase/step to clean selectively.
#
# Usage:
#   ./cleanup.sh                        # clean everything (usage 3→1, setup 6→1)
#   ./cleanup.sh usage                  # clean all usage phases (3→1)
#   ./cleanup.sh setup                  # clean all setup phases (6→1)
#   ./cleanup.sh usage 2               # clean only usage phase 2
#   ./cleanup.sh usage 1.3             # clean only usage step 1.3
#   ./cleanup.sh setup 5              # clean only setup phase 5
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="${SCRIPT_DIR}/../infrastructure/openshift-ai"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com}"
KEYCLOAK_HOST="keycloak.${CLUSTER_DOMAIN}"

TARGET="${1:-all}"
SCOPE="${2:-all}"

header() { echo ""; echo "══════════════════════════════════════════════════════════════"; echo "  $1"; echo "══════════════════════════════════════════════════════════════"; }
step()   { echo ""; echo "── $1"; }
ok()     { echo "   ✓ $1"; }
skip()   { echo "   - $1 (not found)"; }

del() {
  local resource="$1"
  if oc get $resource &>/dev/null; then
    oc delete $resource --timeout=30s 2>/dev/null && ok "Deleted $resource" || echo "   ⚠ Failed to delete $resource"
  else
    skip "$resource"
  fi
}

del_ns() {
  local ns="$1"
  if oc get namespace "$ns" &>/dev/null; then
    oc delete namespace "$ns" --timeout=60s 2>/dev/null && ok "Deleted namespace $ns" || echo "   ⚠ Namespace $ns stuck — check for finalizers"
  else
    skip "namespace $ns"
  fi
}

remove_finalizers() {
  local kind="$1" ns="$2"
  for name in $(oc get "$kind" -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    oc patch "$kind" "$name" -n "$ns" --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  done
}

should_clean() {
  local phase="$1"
  [[ "$SCOPE" == "all" ]] || [[ "$SCOPE" == "$phase" ]] || [[ "$SCOPE" == "$phase."* ]]
}

should_clean_step() {
  local step="$1"
  [[ "$SCOPE" == "all" ]] || [[ "$SCOPE" == "${step%.*}" ]] || [[ "$SCOPE" == "$step" ]]
}

# --- Keycloak admin token ---
kc_admin_token() {
  if [ -z "${KC_TOKEN:-}" ]; then
    local kc_admin="${KEYCLOAK_ADMIN:-temp-admin}"
    local kc_pass="${KEYCLOAK_ADMIN_PASSWORD:-}"
    if [ -z "$kc_pass" ]; then
      kc_pass=$(oc get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
    fi
    if [ -n "$kc_pass" ]; then
      KC_TOKEN=$(curl -sk -X POST "https://${KEYCLOAK_HOST}/realms/master/protocol/openid-connect/token" \
        -d "grant_type=password&client_id=admin-cli&username=${kc_admin}&password=${kc_pass}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)
    fi
  fi
  echo "${KC_TOKEN:-}"
}

kc_delete_client() {
  local client_id="$1" token
  token=$(kc_admin_token)
  [ -z "$token" ] && return
  local encoded
  encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$client_id', safe=''))")
  local uuid
  uuid=$(curl -sk -H "Authorization: Bearer $token" \
    "https://${KEYCLOAK_HOST}/admin/realms/mcp-gateway/clients?clientId=${encoded}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null || true)
  if [ -n "$uuid" ]; then
    curl -sk -X DELETE -H "Authorization: Bearer $token" \
      "https://${KEYCLOAK_HOST}/admin/realms/mcp-gateway/clients/${uuid}" -o /dev/null
    ok "Deleted Keycloak client $client_id"
  else
    skip "Keycloak client $client_id"
  fi
}

kc_delete_user() {
  local username="$1" token
  token=$(kc_admin_token)
  [ -z "$token" ] && return
  local uid
  uid=$(curl -sk -H "Authorization: Bearer $token" \
    "https://${KEYCLOAK_HOST}/admin/realms/mcp-gateway/users?username=$username&exact=true" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null || true)
  if [ -n "$uid" ]; then
    curl -sk -X DELETE -H "Authorization: Bearer $token" \
      "https://${KEYCLOAK_HOST}/admin/realms/mcp-gateway/users/${uid}" -o /dev/null
    ok "Deleted Keycloak user $username"
  else
    skip "Keycloak user $username"
  fi
}

# =============================================================================
# Usage Phase 3: GitHub MCP Server
# =============================================================================
clean_usage_3() {
  header "Clean Usage Phase 3: GitHub MCP Server"

  if should_clean_step "3.6"; then
    step "3.6 Vault secrets"
    echo "   Vault secrets are internal — re-run vault-configure.sh to reset"
  fi

  if should_clean_step "3.4"; then
    step "3.4 Auth + Curation"
    del "authpolicy github-mcp-vault-auth -n team-a"
    del "mcpvirtualserver github-tools -n team-a"
    kc_delete_client "team-a/github-mcp-server"
  fi

  if should_clean_step "3.3"; then
    step "3.3 Registration"
    del "mcpserverregistration github-mcp-server -n team-a"
    del "httproute github-mcp-server -n team-a"
  fi

  if should_clean_step "3.2"; then
    step "3.2 Deploy"
    del "mcpserver github-mcp-server -n team-a"
    del "secret github-mcp-credential -n team-a"
  fi

  if should_clean_step "3.1"; then
    step "3.1 Catalog entry"
    echo "   Removing github-mcp-server from catalog ConfigMap..."
    if oc get configmap mcp-catalog-sources -n odh-model-registries &>/dev/null; then
      CURRENT=$(oc get configmap mcp-catalog-sources -n odh-model-registries -o jsonpath='{.data.custom-mcp-servers\.yaml}')
      if echo "$CURRENT" | grep -q "github-mcp-server"; then
        CLEANED=$(echo "$CURRENT" | python3 -c "
import sys, yaml
content = sys.stdin.read()
try:
    data = yaml.safe_load(content)
    if data and 'mcp_servers' in data:
        data['mcp_servers'] = [s for s in data['mcp_servers'] if s.get('name') != 'github-mcp-server']
        print(yaml.dump(data, default_flow_style=False, sort_keys=False))
    else:
        print(content)
except yaml.YAMLError:
    lines = content.split('\n')
    cut = next((i for i, l in enumerate(lines) if '- name: github-mcp-server' in l.strip()), None)
    print('\n'.join(lines[:cut]).rstrip() if cut else content)
")
        oc patch configmap mcp-catalog-sources -n odh-model-registries --type merge \
          -p "{\"data\":{\"custom-mcp-servers.yaml\":$(echo "$CLEANED" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")}}"
        ok "github-mcp-server removed from catalog"
      else
        skip "github-mcp-server not in catalog"
      fi
    fi
  fi
}

# =============================================================================
# Usage Phase 2: Test Servers
# =============================================================================
clean_usage_2() {
  header "Clean Usage Phase 2: Test Servers"

  if should_clean_step "2.4"; then
    step "2.4 Curation"
    del "mcpvirtualserver user-tools -n team-a"
    kc_delete_client "team-a/test-mcp-server"
    kc_delete_client "team-a/test-mcp-server2"
    echo "   Reverting admin-tools to Phase 1 state (OpenShift tools only)..."
    if oc get mcpvirtualserver admin-tools -n team-a &>/dev/null; then
      oc apply -f - <<'EOF'
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPVirtualServer
metadata:
  name: admin-tools
  namespace: team-a
spec:
  description: OpenShift tools for mcp-admins group
  tools:
    - openshift_configuration_view
    - openshift_events_list
    - openshift_namespaces_list
    - openshift_nodes_log
    - openshift_nodes_stats_summary
    - openshift_nodes_top
    - openshift_pods_get
    - openshift_pods_list
    - openshift_pods_list_in_namespace
    - openshift_pods_log
    - openshift_pods_top
    - openshift_projects_list
    - openshift_resources_get
    - openshift_resources_list
EOF
      ok "admin-tools reverted to OpenShift-only"
    fi
  fi

  if should_clean_step "2.3"; then
    step "2.3 Registrations"
    del "mcpserverregistration test-mcp-server -n team-a"
    del "mcpserverregistration test-mcp-server2 -n team-a"
    del "httproute test-mcp-server -n team-a"
    del "httproute test-mcp-server2 -n team-a"
  fi

  if should_clean_step "2.2"; then
    step "2.2 Deploy"
    del "mcpserver test-mcp-server -n team-a"
    del "mcpserver test-mcp-server2 -n team-a"
  fi

  if should_clean_step "2.1"; then
    step "2.1 Catalog"
    del "configmap mcp-catalog-sources -n odh-model-registries"
  fi
}

# =============================================================================
# Usage Phase 1: OpenShift MCP Server
# =============================================================================
clean_usage_1() {
  header "Clean Usage Phase 1: OpenShift MCP Server"

  if should_clean_step "1.5"; then
    step "1.5 Auth + Curation"
    del "authpolicy team-a-gateway-auth -n team-a"
    del "authpolicy openshift-mcp-admin-only -n team-a"
    del "mcpvirtualserver admin-tools -n team-a"
    kc_delete_client "team-a/openshift-mcp-server"
  fi

  if should_clean_step "1.4"; then
    step "1.4 Registration"
    del "mcpserverregistration openshift-mcp-server -n team-a"
    del "httproute openshift-mcp-server -n team-a"
  fi

  if should_clean_step "1.3"; then
    step "1.3 Deploy"
    del "mcpserver openshift-mcp-server -n team-a"
  fi

  if should_clean_step "1.1"; then
    step "1.1 Prerequisites"
    del "clusterrolebinding team-a-ocp-mcp-view"
    del "serviceaccount mcp-viewer -n team-a"
    del "configmap openshift-mcp-server-config -n team-a"
  fi
}

# =============================================================================
# Setup Phase 6: Playground
# =============================================================================
clean_setup_6() {
  header "Clean Setup Phase 6: Playground"
  echo "   LlamaStack Playground was created via UI — delete it from RHOAI Dashboard"
  echo "   or delete the LlamaStackDistribution CR manually:"
  LLAMA_NS=$(oc get llamastackdistribution --all-namespaces -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
  LLAMA_NAME=$(oc get llamastackdistribution --all-namespaces -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$LLAMA_NS" ] && [ -n "$LLAMA_NAME" ]; then
    echo "   Found: $LLAMA_NAME in $LLAMA_NS"
    echo "   Run: oc delete llamastackdistribution $LLAMA_NAME -n $LLAMA_NS"
  else
    skip "No LlamaStackDistribution found"
  fi
}

# =============================================================================
# Setup Phase 5: MCP Gateway Instance (team-a)
# =============================================================================
clean_setup_5() {
  header "Clean Setup Phase 5: MCP Gateway + Kuadrant"

  if should_clean_step "5.8"; then
    step "5.8 RHOAI ConfigMap"
    del "configmap gen-ai-aa-mcp-servers -n redhat-ods-applications"
  fi

  if should_clean_step "5.6" || should_clean_step "5.5"; then
    step "5.5–5.6 Wristband keys + MCPGatewayExtension patch"
    del "secret trusted-headers-public-key -n team-a"
    del "secret trusted-headers-private-key -n openshift-operators"
  fi

  if should_clean_step "5.4" || should_clean_step "5.3"; then
    step "5.3–5.4 Gateway Helm releases"
    helm uninstall team-a-gateway-ingress -n team-a 2>/dev/null && ok "Uninstalled team-a-gateway-ingress" || skip "team-a-gateway-ingress Helm release"
    helm uninstall team-a-gateway -n team-a 2>/dev/null && ok "Uninstalled team-a-gateway" || skip "team-a-gateway Helm release"

    echo "   Removing finalizers from MCP Gateway resources..."
    for kind in mcpgatewayextension mcpserverregistration mcpvirtualserver; do
      remove_finalizers "$kind" team-a
    done
  fi

  if should_clean_step "5.2"; then
    step "5.2 Kuadrant CR"
    del "kuadrant kuadrant -n openshift-operators"
  fi

  if should_clean_step "5.1"; then
    step "5.1 team-a namespace"
    del_ns "team-a"
  fi
}

# =============================================================================
# Setup Phase 4: Vault
# =============================================================================
clean_setup_4() {
  header "Clean Setup Phase 4: Vault"
  helm uninstall vault -n openshift-operators 2>/dev/null && ok "Uninstalled Vault Helm release" || skip "Vault Helm release"
  del "pvc data-vault-0 -n openshift-operators"
}

# =============================================================================
# Setup Phase 3: MCP Lifecycle Operator
# =============================================================================
clean_setup_3() {
  header "Clean Setup Phase 3: MCP Lifecycle Operator"
  oc delete -f "${INFRA_DIR}/lifecycle operator/lifecycle-operator.yaml" --ignore-not-found 2>/dev/null && ok "Lifecycle operator resources deleted" || skip "Lifecycle operator"
  del_ns "mcp-lifecycle-operator-system"
}

# =============================================================================
# Setup Phase 2: Keycloak
# =============================================================================
clean_setup_2() {
  header "Clean Setup Phase 2: Keycloak"
  oc delete -f "${INFRA_DIR}/keycloak/keycloak.yaml" --ignore-not-found 2>/dev/null && ok "Keycloak resources deleted" || skip "Keycloak resources"
}

# =============================================================================
# Setup Phase 1: Operator Subscriptions
# =============================================================================
clean_setup_1() {
  header "Clean Setup Phase 1: Operator Subscriptions"

  if should_clean_step "1.3"; then
    step "1.3 RHBK Operator"
    del "subscription rhbk-operator -n keycloak"
    del "operatorgroup rhbk -n keycloak"
    oc delete csv -n keycloak -l operators.coreos.com/rhbk-operator.keycloak --ignore-not-found 2>/dev/null || true
    del_ns "keycloak"
  fi

  if should_clean_step "1.2"; then
    step "1.2 MCP Gateway Operator"
    del "subscription mcp-gateway-operator -n mcp-system"
    del "operatorgroup mcp-gateway -n mcp-system"
    oc delete csv -n mcp-system -l operators.coreos.com/mcp-gateway-operator.mcp-system --ignore-not-found 2>/dev/null || true
    del_ns "mcp-system"
  fi

  if should_clean_step "1.1"; then
    step "1.1 CatalogSource"
    del "catalogsource mcp-gateway-catalog -n openshift-marketplace"
  fi
}

# =============================================================================
# Main
# =============================================================================
echo "MCP Ecosystem Cleanup"
echo "  Target: $TARGET"
echo "  Scope:  $SCOPE"

if [[ "$TARGET" == "all" ]] || [[ "$TARGET" == "usage" ]]; then
  if should_clean 3; then clean_usage_3; fi
  if should_clean 2; then clean_usage_2; fi
  if should_clean 1; then clean_usage_1; fi
fi

if [[ "$TARGET" == "all" ]] || [[ "$TARGET" == "setup" ]]; then
  if should_clean 6; then clean_setup_6; fi
  if should_clean 5; then clean_setup_5; fi
  if should_clean 4; then clean_setup_4; fi
  if should_clean 3; then clean_setup_3; fi
  if should_clean 2; then clean_setup_2; fi
  if should_clean 1; then clean_setup_1; fi
fi

header "Cleanup Complete"
