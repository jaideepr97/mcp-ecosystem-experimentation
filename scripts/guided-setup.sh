#!/usr/bin/env bash
# guided-setup.sh — Interactive guided setup for the MCP ecosystem experiment.
#
# Walks you through each deployment phase with context and explanations,
# using gum (https://github.com/charmbracelet/gum) for a rich terminal experience.
#
# Usage:
#   ./scripts/guided-setup.sh              # Start from the beginning
#   ./scripts/guided-setup.sh --resume     # Resume from where you left off
#   ./scripts/guided-setup.sh --phase 5    # Start from a specific phase
#   ./scripts/guided-setup.sh --batch      # Run all phases without prompts (like setup.sh)
#
# Prerequisites: kind, kubectl, helm, docker/podman, gum
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

TOTAL_PHASES=16

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
  # Run a command with a gum spinner in batch mode, or interactively
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
  # Show the actual resources created during a phase by running kubectl commands.
  # Usage: show_resources "label: kubectl args" "label: kubectl args" ...
  # Each argument is "LABEL: kubectl get args..." — the label is shown as a header.

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
    "Build a production-grade MCP ecosystem on a local Kind cluster." \
    "Each phase deploys one layer and explains what it does and why." \
    "" \
    "16 phases | ~10 minutes total"

  if [ "$START_PHASE" -gt 1 ]; then
    gum style --foreground 214 "Resuming from phase ${START_PHASE}."
    echo ""
  fi
fi

########################################
# Phase 1: Kind cluster
########################################

if [ "$START_PHASE" -le 1 ]; then

show_phase 1 "Kind Cluster" "
## What this does

Creates a **Kind** (Kubernetes in Docker) cluster named \`mcp-ecosystem\` with custom
port mappings so you can reach services from your host machine.

## Why

Kind runs a full Kubernetes cluster inside a Docker container. The port mappings
in the cluster config expose specific NodePorts to your host:

- **8001** -> MCP Gateway (HTTP)
- **8002** -> Keycloak (OIDC provider)
- **8004** -> MCP Launcher UI
- **8443** -> MCP Gateway (HTTPS)
- **8445** -> Keycloak (HTTPS)

Without these mappings, services inside the cluster would be unreachable from
your browser and curl.

## What gets created

- A Kind cluster node (Docker container running Kubernetes)
- kubectl context set to \`kind-mcp-ecosystem\`
"

if confirm_phase 1; then
  if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
    # Cluster exists — check if it's actually healthy
    kubectl config use-context "kind-${KIND_CLUSTER_NAME}" >/dev/null 2>&1
    if kubectl get nodes --request-timeout=5s &>/dev/null; then
      gum style --foreground 214 "Cluster '${KIND_CLUSTER_NAME}' already exists and is healthy — reusing it."
    else
      gum style --foreground 214 "Cluster '${KIND_CLUSTER_NAME}' exists but is not responding — recreating it."
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
  phase_done 1
  show_resources "Nodes: nodes"
fi

fi # phase 1

########################################
# Phase 2: Gateway API CRDs
########################################

if [ "$START_PHASE" -le 2 ]; then

show_phase 2 "Gateway API CRDs" "
## What this does

Installs the **Gateway API** Custom Resource Definitions (CRDs) — the Kubernetes-native
way to define L7 networking: Gateways, HTTPRoutes, and related resources.

## Why

Gateway API is the successor to Ingress. It separates infrastructure concerns (Gateway)
from application concerns (HTTPRoute). The MCP gateway uses these to:

- Define an Envoy listener (Gateway resource)
- Route traffic to specific MCP servers (HTTPRoute resources)

The CRDs must exist before anything that references them (Istio, the gateway, HTTPRoutes).

## What gets created

- Gateway API CRDs (\`gateways.gateway.networking.k8s.io\`, \`httproutes\`, etc.)
"

if confirm_phase 2; then
  run_cmd "Installing Gateway API CRDs (${GATEWAY_API_VERSION})..." \
    kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
  kubectl wait --for=condition=Established --timeout=60s crd/gateways.gateway.networking.k8s.io >/dev/null 2>&1
  phase_done 2
  show_resources "Gateway API CRDs: crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io referencegrants.gateway.networking.k8s.io gatewayclasses.gateway.networking.k8s.io grpcroutes.gateway.networking.k8s.io"
fi

fi # phase 2

########################################
# Phase 3: Istio (Sail operator)
########################################

if [ "$START_PHASE" -le 3 ]; then

show_phase 3 "Istio via Sail Operator" "
## What this does

Installs **Istio** using the Sail operator — but *not* as a service mesh.

## Why

A common misconception: Istio here is used **only as a Gateway API controller**.
No sidecars, no mTLS, no ambient mode. The only component is **istiod**, which
reads Gateway and HTTPRoute resources and programs an Envoy proxy to implement them.

Think of it as: \"I need a programmable Envoy that responds to Gateway API resources.\"
Istio via Sail is the easiest way to get that on a Kind cluster.

## What gets created

- Sail operator (Helm chart in \`istio-system\`)
- istiod deployment (the control plane that programs Envoy)
- Istio resource (\`istio/default\`) — tells Sail what to configure
"

if confirm_phase 3; then
  run_cmd "Installing Sail operator..." \
    helm upgrade --install sail-operator \
      --create-namespace \
      --namespace istio-system \
      --wait \
      --timeout=300s \
      "https://github.com/istio-ecosystem/sail-operator/releases/download/${SAIL_VERSION}/sail-operator-${SAIL_VERSION}.tgz"

  kubectl apply -f "${REPO_DIR}/infrastructure/istio/istio.yaml" >/dev/null 2>&1
  run_cmd "Waiting for Istio to become ready..." \
    kubectl -n istio-system wait --for=condition=Ready istio/default --timeout=300s
  phase_done 3
  show_resources \
    "Deployments: deployments -n istio-system" \
    "Pods: pods -n istio-system" \
    "Istio: istio -n istio-system"
fi

fi # phase 3

########################################
# Phase 4: MetalLB
########################################

if [ "$START_PHASE" -le 4 ]; then

show_phase 4 "MetalLB" "
## What this does

Installs **MetalLB**, a bare-metal LoadBalancer implementation for Kubernetes.

## Why

In cloud environments, \`Service type: LoadBalancer\` gets an external IP from the
cloud provider. In Kind, there is no cloud provider — LoadBalancer services sit in
\`Pending\` forever.

MetalLB solves this by assigning IPs from a configured pool (derived from the Docker
network range). This is what makes the Envoy gateway reachable.

## What gets created

- MetalLB controller + speaker pods in \`metallb-system\`
- IPAddressPool configured for the Docker/podman network range
- L2Advertisement (ARP-based IP assignment)
"

if confirm_phase 4; then
  run_cmd "Installing MetalLB..." \
    kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"
  run_cmd "Waiting for MetalLB controller..." \
    kubectl -n metallb-system wait --for=condition=Available deployments controller --timeout=300s
  run_cmd "Waiting for MetalLB pods..." \
    kubectl -n metallb-system wait --for=condition=ready pod --selector=app=metallb --timeout=120s
  run_cmd "Configuring IP pool..." \
    bash -c "'${REPO_DIR}/infrastructure/metallb/ipaddresspool.sh' kind | kubectl apply -n metallb-system -f -"
  phase_done 4
  show_resources \
    "Deployments: deployments -n metallb-system" \
    "Pods: pods -n metallb-system" \
    "IPAddressPools: ipaddresspool -n metallb-system" \
    "L2Advertisements: l2advertisement -n metallb-system"
fi

fi # phase 4

########################################
# Phase 5: cert-manager
########################################

if [ "$START_PHASE" -le 5 ]; then

show_phase 5 "cert-manager" "
## What this does

Installs **cert-manager** and creates a self-signed CA certificate chain for TLS.

## Why

cert-manager automates certificate lifecycle in Kubernetes. We install it *before*
Kuadrant (Phase 11) because Kuadrant detects cert-manager at install time and enables
TLSPolicy support only if cert-manager is already present.

The CA chain works like this:

1. **SelfSigned ClusterIssuer** — bootstraps a root CA
2. **mcp-ca-cert Certificate** — a CA certificate signed by the self-signed issuer
3. **mcp-ca ClusterIssuer** — uses mcp-ca-cert to sign leaf certificates

Later, TLSPolicy (Phase 14) references mcp-ca to issue certificates for the gateway's
HTTPS listeners automatically.

## What gets created

- cert-manager deployment in \`cert-manager\` namespace (via Helm)
- SelfSigned ClusterIssuer (bootstrap)
- mcp-ca-cert Certificate (CA certificate)
- mcp-ca ClusterIssuer (signs leaf certs for gateway TLS)
"

if confirm_phase 5; then
  run_cmd "Adding Helm repo..." \
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
  phase_done 5
  show_resources \
    "Deployments: deployments -n cert-manager" \
    "Pods: pods -n cert-manager" \
    "ClusterIssuers: clusterissuer" \
    "Certificates: certificate -n cert-manager"
fi

fi # phase 5

########################################
# Phase 6: Gateway
########################################

if [ "$START_PHASE" -le 6 ]; then

show_phase 6 "Envoy Gateway" "
## What this does

Creates the **Gateway** resource and its supporting infrastructure. istiod sees this
and deploys an Envoy proxy pod to serve as the data plane.

## Why

The Gateway resource is the declarative way to say: \"I want an L7 proxy listening
on port 8080.\" istiod reads this, deploys an Envoy pod (\`mcp-gateway-istio\`),
and programs it with the listener config.

A **NodePort** service maps the Kind cluster's ports to the Envoy proxy, making it
reachable from your host at \`http://mcp.127-0-0-1.sslip.io:8001\`.

The **ReferenceGrant** allows HTTPRoutes in other namespaces (like \`mcp-test\`)
to reference this Gateway — without it, cross-namespace routing is denied.

## What gets created

- \`gateway-system\` namespace
- Gateway resource (listener on port 8080)
- NodePort service (30080 -> 8080, mapped to host port 8001)
- ReferenceGrant (cross-namespace permissions)
- Envoy proxy pod (\`mcp-gateway-istio\`, deployed by istiod)
"

if confirm_phase 6; then
  kubectl apply -f "${REPO_DIR}/infrastructure/gateway/namespace.yaml" >/dev/null 2>&1
  kubectl apply -f "${REPO_DIR}/infrastructure/gateway/gateway.yaml" >/dev/null 2>&1
  kubectl apply -f "${REPO_DIR}/infrastructure/gateway/nodeport.yaml" >/dev/null 2>&1
  kubectl apply -f "${REPO_DIR}/infrastructure/gateway/referencegrant.yaml" >/dev/null 2>&1
  run_cmd "Waiting for Gateway to be programmed..." \
    kubectl wait --for=condition=Programmed gateway/mcp-gateway -n gateway-system --timeout=300s
  phase_done 6
  show_resources \
    "Gateways: gateway -n gateway-system" \
    "Services: services -n gateway-system" \
    "Pods: pods -n gateway-system" \
    "ReferenceGrants: referencegrant -n gateway-system"
fi

fi # phase 6

########################################
# Phase 7: mcp-gateway
########################################

if [ "$START_PHASE" -le 7 ]; then

show_phase 7 "MCP Gateway (Broker + Router)" "
## What this does

Installs the **mcp-gateway** — the MCP-specific layer that sits on top of Envoy.

## Why

Envoy is a generic L7 proxy. It doesn't understand MCP (JSON-RPC over HTTP).
The mcp-gateway adds three components:

1. **Broker** — aggregates tools from all registered MCP servers. When a client
   calls \`tools/list\`, the broker fans out to every upstream server, collects
   their tools, prefixes each tool name with the server name, and returns the
   merged list.

2. **Router** (ext_proc) — an Envoy external processor that intercepts every
   request. For \`tools/call\`, it parses the JSON-RPC body, extracts the tool
   name, strips the prefix, looks up which server owns it, and rewrites the
   \`:authority\` header so Envoy routes to the correct backend.

3. **Controller** — watches MCPServerRegistration resources and updates the
   broker's server list.

The Router runs as an **ext_proc filter** in Envoy's filter chain. This means
it sees every request *before* routing decisions are made — it's what allows
the gateway to steer traffic based on tool names inside the JSON-RPC body.

## What gets created

- MCP CRDs (MCPServerRegistration, MCPVirtualServer, MCPGatewayExtension)
- mcp-gateway deployment in \`mcp-system\` (broker + router + controller)
- MCPGatewayExtension (attaches to the Gateway)
- EnvoyFilter (injects ext_proc into Envoy's filter chain)
"

if confirm_phase 7; then
  run_cmd "Installing MCP CRDs..." \
    bash -c "kubectl apply -f '${REPO_DIR}/infrastructure/mcp-gateway/mcp.kuadrant.io_mcpserverregistrations.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/mcp-gateway/mcp.kuadrant.io_mcpvirtualservers.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/mcp-gateway/mcp.kuadrant.io_mcpgatewayextensions.yaml'"

  run_cmd "Deploying mcp-gateway..." \
    kubectl apply -f "${REPO_DIR}/infrastructure/mcp-gateway/deploy.yaml"
  run_cmd "Waiting for mcp-controller..." \
    kubectl wait --for=condition=Available deployment/mcp-controller -n mcp-system --timeout=120s
  run_cmd "Waiting for MCPGatewayExtension..." \
    kubectl wait --for=condition=Ready mcpgatewayextension/mcp-gateway-extension -n mcp-system --timeout=120s
  phase_done 7
  show_resources \
    "MCP CRDs: crd mcpserverregistrations.mcp.kuadrant.io mcpvirtualservers.mcp.kuadrant.io mcpgatewayextensions.mcp.kuadrant.io" \
    "Deployments: deployments -n mcp-system" \
    "Services: services -n mcp-system" \
    "Pods: pods -n mcp-system" \
    "MCPGatewayExtensions: mcpgatewayextension -n mcp-system"
fi

fi # phase 7

########################################
# Phase 8: Lifecycle Operator
########################################

if [ "$START_PHASE" -le 8 ]; then

show_phase 8 "MCP Lifecycle Operator" "
## What this does

Deploys the **mcp-lifecycle-operator** — a Kubernetes operator that manages MCP
server lifecycle via the \`MCPServer\` CRD.

## Why

Without the operator, deploying an MCP server means manually creating a Deployment,
Service, HTTPRoute, and MCPServerRegistration. The operator automates this:

1. **Main reconciler** — watches MCPServer CRs, creates Deployment + Service
2. **Gateway reconciler** — if the MCPServer has a \`mcp.x-k8s.io/gateway-ref\`
   annotation, it also creates an HTTPRoute + MCPServerRegistration

This means a single MCPServer CR is enough to go from \"I want this server\" to
\"it's deployed, has a Service, is routed through the gateway, and its tools are
discoverable.\"

The operator image is pre-built and loaded into Kind from a container registry.

## What gets created

- MCPServer CRD (\`mcpservers.mcp.x-k8s.io\`)
- Lifecycle operator deployment in \`mcp-lifecycle-operator-system\`
- RBAC for the gateway reconciler (needs permissions for HTTPRoute, MCPServerRegistration)
"

if confirm_phase 8; then
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
  phase_done 8
  show_resources \
    "Deployments: deployments -n mcp-lifecycle-operator-system" \
    "Pods: pods -n mcp-lifecycle-operator-system" \
    "Operator CRDs: crd mcpservers.mcp.x-k8s.io"
fi

fi # phase 8

########################################
# Phase 9: Catalog System
########################################

if [ "$START_PHASE" -le 9 ]; then

show_phase 9 "Catalog System" "
## What this does

Deploys the **model-registry catalog** — a REST API that provides MCP server discovery.

## Why

The catalog answers the question: *\"What MCP servers are available?\"*

It serves a REST API at \`/api/mcp_catalog/v1alpha1/mcp_servers\` that returns server
metadata: name, description, OCI image URI, tools, port, and runtime requirements.

The catalog is backed by **PostgreSQL** for metadata storage and a **ConfigMap** for
the server definitions (YAML). The MCP Launcher (Phase 12) reads from this API to
present a browsable UI.

## What gets created

- \`catalog-system\` namespace
- PostgreSQL StatefulSet + PVC + Secret + Service
- Catalog ConfigMap (server definitions in YAML)
- Catalog Deployment + ClusterIP Service
"

if confirm_phase 9; then
  kubectl create namespace catalog-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  run_cmd "Deploying PostgreSQL..." \
    kubectl apply -f "${REPO_DIR}/infrastructure/catalog/postgres.yaml"
  run_cmd "Deploying catalog sources..." \
    kubectl apply -f "${REPO_DIR}/infrastructure/catalog/catalog-sources.yaml"
  run_cmd "Deploying catalog API..." \
    kubectl apply -f "${REPO_DIR}/infrastructure/catalog/catalog.yaml"
  run_cmd "Waiting for PostgreSQL..." \
    kubectl wait --for=condition=Ready pod -l app=mcp-catalog-postgres -n catalog-system --timeout=120s
  run_cmd "Waiting for catalog API..." \
    kubectl wait --for=condition=Ready pod -l app=mcp-catalog -n catalog-system --timeout=120s
  phase_done 9
  show_resources \
    "Deployments: deployments -n catalog-system" \
    "Pods: pods -n catalog-system" \
    "Services: services -n catalog-system" \
    "ConfigMaps: configmaps -n catalog-system" \
    "PVCs: pvc -n catalog-system"
fi

fi # phase 9

########################################
# Phase 10: Keycloak
########################################

if [ "$START_PHASE" -le 10 ]; then

show_phase 10 "Keycloak (OIDC Provider)" "
## What this does

Deploys **Keycloak** — a production-grade OIDC provider with pre-configured users,
groups, and OAuth clients.

## Why

Authentication in the MCP ecosystem requires an OIDC provider that issues JWTs
with group claims. Keycloak provides:

- **Users**: alice (developers), bob (ops), carol (both) — passwords match usernames
- **Groups**: \`developers\`, \`ops\` — mapped to JWT \`groups\` claim via mapper
- **OAuth clients**:
  - \`mcp-gateway\` (confidential) — for gateway-to-Keycloak token exchange
  - \`mcp-cli\` (public) — for device auth flow from the CLI client

Keycloak is imported from a **realm JSON** that pre-configures all of the above.
It's also exposed through the gateway with its own HTTPRoute so that in-cluster
services (like Authorino) can reach it via the same hostname as external clients.

## What gets created

- \`keycloak\` namespace
- Keycloak Deployment + Service
- Realm import ConfigMap (users, groups, clients, mappers)
- Gateway listener patch (adds port 8082 for Keycloak)
- HTTPRoute for Keycloak through the gateway
"

if confirm_phase 10; then
  kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  run_cmd "Deploying Keycloak..." \
    bash -c "kubectl apply -f '${REPO_DIR}/infrastructure/keycloak/realm-import.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/keycloak/deployment.yaml'"
  run_cmd "Patching Gateway for Keycloak..." \
    bash -c "kubectl patch gateway mcp-gateway -n gateway-system --type json \
      -p \"\$(cat '${REPO_DIR}/infrastructure/keycloak/gateway-patch.json')\" && \
      kubectl apply -f '${REPO_DIR}/infrastructure/keycloak/httproute.yaml'"
  run_cmd "Waiting for Keycloak..." \
    kubectl wait --for=condition=Ready pod -l app=keycloak -n keycloak --timeout=180s
  phase_done 10
  show_resources \
    "Deployments: deployments -n keycloak" \
    "Pods: pods -n keycloak" \
    "Services: services -n keycloak" \
    "HTTPRoutes: httproute -n keycloak"
fi

fi # phase 10

########################################
# Phase 11: Kuadrant operator
########################################

if [ "$START_PHASE" -le 11 ]; then

show_phase 11 "Kuadrant (Authorino)" "
## What this does

Installs the **Kuadrant operator** which deploys **Authorino** — an Envoy-native
authorization service that evaluates AuthPolicy resources.

## Why

Istio's built-in auth (RequestAuthentication + AuthorizationPolicy) only supports
coarse-grained JWT validation — it can check if a token is valid, but it can't
inspect the JSON-RPC body to authorize individual tool calls.

Kuadrant's **AuthPolicy** replaces Istio auth with fine-grained, per-HTTPRoute
authorization:

- **JWT validation** with Keycloak JWKS
- **CEL predicates** that evaluate JWT claims (e.g., \`'developers' in auth.identity.groups\`)
- **Metadata evaluators** that call external services (e.g., Vault for credential exchange)

Authorino runs as a sidecar-like service in the Kuadrant namespace and is invoked
by Envoy via ext_authz for every request matching an AuthPolicy.

This phase also patches **CoreDNS** so that Authorino (running inside the cluster)
can resolve \`keycloak.127-0-0-1.sslip.io\` to the gateway's LoadBalancer IP.

## What gets created

- Kuadrant operator in \`kuadrant-system\` (via Helm)
- Authorino deployment (the authorization engine)
- Kuadrant resource (operator configuration)
- CoreDNS patch (Keycloak hostname → gateway IP)
"

if confirm_phase 11; then
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

  # Patch CoreDNS
  GATEWAY_IP=$(kubectl get svc -n gateway-system \
    -l gateway.networking.k8s.io/gateway-name=mcp-gateway \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  if [ -n "${GATEWAY_IP}" ]; then
    run_cmd "Patching CoreDNS for Keycloak resolution..." \
      bash -c "kubectl get configmap coredns -n kube-system -o yaml | \
        sed 's/ready/hosts {\n          ${GATEWAY_IP} keycloak.127-0-0-1.sslip.io\n          fallthrough\n        }\n        ready/' | \
        kubectl apply -f - && \
        kubectl rollout restart deployment coredns -n kube-system"
  fi
  phase_done 11
  show_resources \
    "Deployments: deployments -n kuadrant-system" \
    "Pods: pods -n kuadrant-system" \
    "Kuadrant: kuadrant -n kuadrant-system"
fi

fi # phase 11

########################################
# Phase 12: Test Servers + Launcher
########################################

if [ "$START_PHASE" -le 12 ]; then

show_phase 12 "Test Servers + MCP Launcher" "
## What this does

Deploys **two test MCP servers** and the **MCP Launcher** UI.

## Why

This is where the full pipeline comes together:

1. The **MCPServer CRs** (\`test-server1\`, \`test-server2\`) are applied with
   \`gateway-ref\` annotations
2. The **lifecycle operator** sees them and creates: Deployment, Service, HTTPRoute,
   and MCPServerRegistration for each
3. The **mcp-gateway broker** discovers both servers' tools
4. The **mcp-gateway router** can now route \`tools/call\` requests to either server

**test-server1** provides: greet, time, slow, headers, add_tool
**test-server2** provides: hello_world, time, headers, auth1234, slow, set_time

The **MCP Launcher** is a web UI that reads from the catalog API and lets you
browse available servers. It's at \`http://localhost:8004\`.

## What gets created

- MCPServer CRs (test-server1, test-server2)
- 2x Deployment + Service + HTTPRoute + MCPServerRegistration (by operator)
- MCP Launcher Deployment + Service + NodePort
- Launcher RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding)
"

if confirm_phase 12; then
  kubectl create namespace mcp-test --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  run_cmd "Deploying test servers..." \
    bash -c "kubectl apply -f '${REPO_DIR}/infrastructure/test-servers/test-server1.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/test-servers/test-server2.yaml'"
  run_cmd "Deploying MCP Launcher..." \
    bash -c "kubectl apply -f '${REPO_DIR}/infrastructure/launcher/rbac.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/launcher/deployment.yaml'"
  run_cmd "Waiting for test servers..." \
    bash -c "kubectl wait --for=condition=Ready mcpserver/test-server1 -n mcp-test --timeout=120s 2>/dev/null; \
             kubectl wait --for=condition=Ready mcpserver/test-server2 -n mcp-test --timeout=120s 2>/dev/null || true"

  run_cmd "Restarting mcp-gateway to pick up registrations..." \
    bash -c "kubectl rollout restart deployment mcp-gateway -n mcp-system 2>/dev/null && \
             kubectl rollout status deployment mcp-gateway -n mcp-system --timeout=120s 2>/dev/null || true"
  phase_done 12
  show_resources \
    "MCPServers: mcpserver -n mcp-test" \
    "Deployments: deployments -n mcp-test" \
    "Services: services -n mcp-test" \
    "Pods: pods -n mcp-test" \
    "HTTPRoutes: httproute -n mcp-test" \
    "MCPServerRegistrations: mcpserverregistration -n mcp-test"
fi

fi # phase 12

########################################
# Phase 13: AuthPolicies
########################################

if [ "$START_PHASE" -le 13 ]; then

show_phase 13 "AuthPolicies (Per-Tool Authorization)" "
## What this does

Applies **AuthPolicy** resources — Kuadrant's way of defining who can call which
tools on which servers.

## Why

Authentication (Phase 10-11) proves *who* you are. Authorization decides *what*
you can do. AuthPolicies attach to HTTPRoutes and define:

1. **Gateway-level policy** — requires a valid JWT on all requests (replaces
   Istio's RequestAuthentication + AuthorizationPolicy)
2. **Per-server policies** — use CEL predicates to check group membership:
   - server1: \`developers\` can call \`greet\`, \`ops\` can call \`add_tool\`
   - server2: \`ops\` can call \`auth1234\` + \`set_time\`, \`developers\` can call \`set_time\`

The per-server policies use **\`overrides\`** (not \`defaults\`) to override the
gateway-level policy. Each rule includes a **\`when\`** condition with a CEL predicate
that extracts the tool name from the JSON-RPC request body and checks the caller's
groups claim.

A 5-second delay between gateway and per-server policies avoids a race condition
where Authorino might evaluate the per-server policy before the gateway policy
is fully reconciled.

## What gets created

- Gateway-level AuthPolicy on \`mcp-gateway\` (JWT validation with Keycloak JWKS)
- Per-server AuthPolicy on test-server1's HTTPRoute (tool-level CEL rules)
- Per-server AuthPolicy on test-server2's HTTPRoute (tool-level CEL rules)
"

if confirm_phase 13; then
  run_cmd "Applying gateway-level AuthPolicy..." \
    kubectl apply -f "${REPO_DIR}/infrastructure/auth/authpolicy.yaml"
  sleep 5
  run_cmd "Applying per-server AuthPolicies..." \
    bash -c "kubectl apply -f '${REPO_DIR}/infrastructure/auth/authpolicy-server1.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/auth/authpolicy-server2.yaml'"
  phase_done 13
  show_resources \
    "AuthPolicies (gateway): authpolicy -n gateway-system" \
    "AuthPolicies (servers): authpolicy -n mcp-test"
fi

fi # phase 13

########################################
# Phase 14: TLS
########################################

if [ "$START_PHASE" -le 14 ]; then

show_phase 14 "TLS (HTTPS Termination)" "
## What this does

Enables **HTTPS** on the gateway using Kuadrant's **TLSPolicy** and cert-manager's
CA issuer from Phase 5.

## Why

TLSPolicy automates TLS certificate provisioning for Gateway listeners. When you
add an HTTPS listener to the Gateway, TLSPolicy tells cert-manager to issue a
certificate using the \`mcp-ca\` ClusterIssuer.

This phase adds two HTTPS listeners:

- **mcp-https** (port 8443) — TLS-terminated MCP gateway endpoint
- **keycloak-https** (port 8445) — TLS-terminated Keycloak endpoint

Both use certificates signed by the self-signed CA from Phase 5. Clients need
\`--cacert /tmp/mcp-ca.crt\` to trust them.

## What gets created

- TLSPolicy on \`mcp-gateway\` (references mcp-ca ClusterIssuer)
- HTTPS listener on Gateway (port 8443 for MCP, 8445 for Keycloak)
- HTTPRoute for Keycloak HTTPS
- Certificate resources (auto-created by cert-manager)
- CA cert extracted to \`/tmp/mcp-ca.crt\` for client use
"

if confirm_phase 14; then
  run_cmd "Applying TLSPolicy..." \
    kubectl apply -f "${REPO_DIR}/infrastructure/cert-manager/tls-policy.yaml"
  run_cmd "Adding Keycloak HTTPS listener..." \
    bash -c "kubectl patch gateway mcp-gateway -n gateway-system --type json \
      -p \"\$(cat '${REPO_DIR}/infrastructure/keycloak/gateway-patch-tls.json')\" && \
      kubectl apply -f '${REPO_DIR}/infrastructure/keycloak/httproute-tls.yaml'"

  run_cmd "Waiting for TLSPolicy to be enforced..." \
    bash -c "for i in \$(seq 1 6); do \
      STATUS=\$(kubectl get tlspolicy mcp-gateway-tls -n gateway-system -o jsonpath='{.status.conditions[?(@.type==\"Enforced\")].status}' 2>/dev/null); \
      [ \"\$STATUS\" = 'True' ] && exit 0; sleep 5; \
    done; \
    kubectl rollout restart deployment kuadrant-operator-controller-manager -n kuadrant-system 2>/dev/null; \
    kubectl rollout status deployment kuadrant-operator-controller-manager -n kuadrant-system --timeout=60s 2>/dev/null; \
    kubectl annotate tlspolicy mcp-gateway-tls -n gateway-system reconcile-trigger=\"\$(date +%s)\" --overwrite 2>/dev/null; \
    sleep 10"

  run_cmd "Waiting for HTTPS certificates..." \
    bash -c "kubectl wait --for=condition=Ready certificate/mcp-gateway-mcp-https -n gateway-system --timeout=120s 2>/dev/null; \
             kubectl wait --for=condition=Ready certificate/mcp-gateway-keycloak-https -n gateway-system --timeout=120s 2>/dev/null || true"
  run_cmd "Waiting for Gateway to be programmed with HTTPS..." \
    kubectl wait --for=condition=Programmed gateway/mcp-gateway -n gateway-system --timeout=120s

  # Extract CA cert
  bash -c "kubectl get secret mcp-ca-secret -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/mcp-ca.crt 2>/dev/null || \
           kubectl get secret mcp-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/mcp-ca.crt 2>/dev/null || true"

  phase_done 14
  show_resources \
    "TLSPolicy: tlspolicy -n gateway-system" \
    "Certificates: certificate -n gateway-system" \
    "Gateway listeners: gateway -n gateway-system"
fi

fi # phase 14

########################################
# Phase 15: Vault
########################################

if [ "$START_PHASE" -le 15 ]; then

show_phase 15 "Vault (Credential Exchange)" "
## What this does

Deploys **HashiCorp Vault** in dev mode and configures JWT-based authentication
so users can exchange their Keycloak JWT for upstream API credentials.

## Why

Some MCP servers (like GitHub) need per-user API credentials. You don't want to
bake a single shared token into the server — each user should have their own.

The credential exchange flow works like this:

1. User authenticates with Keycloak and gets a JWT
2. Authorino (via AuthPolicy metadata evaluator) calls Vault's JWT auth endpoint
3. Vault validates the JWT against Keycloak's JWKS
4. Vault maps the JWT's \`sub\` claim to a policy that allows reading only that
   user's secrets at \`secret/mcp-gateway/<sub>\`
5. Authorino reads the secret and injects it as an HTTP header (e.g., \`Authorization\`)

This means each user's API token is stored in Vault under their Keycloak subject ID,
and only they can access it — enforced by Vault policy, not application code.

## What gets created

- \`vault\` namespace
- Vault Deployment + Service (dev mode, root token: \`root\`)
- JWT auth backend (validates Keycloak JWTs)
- Vault role \`mcp-user\` (binds JWT sub claim to policy)
- Vault policy \`mcp-user-secrets\` (per-user secret read access)
"

if confirm_phase 15; then
  run_cmd "Deploying Vault..." \
    bash -c "kubectl apply -f '${REPO_DIR}/infrastructure/vault/namespace.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/vault/deployment.yaml'"
  run_cmd "Waiting for Vault..." \
    kubectl wait --for=condition=Ready pod -l app=vault -n vault --timeout=120s
  run_cmd "Configuring Vault JWT auth..." \
    "${REPO_DIR}/infrastructure/vault/configure.sh"

  # Store GitHub PATs if GITHUB_PAT is set
  if [ -n "${GITHUB_PAT:-}" ]; then
    run_cmd "Storing GitHub PATs in Vault..." \
      bash -c "KEYCLOAK_INTERNAL='http://keycloak.127-0-0-1.sslip.io:8002'; \
        for USER in alice bob carol; do \
          USER_SUB=\$(curl -s \"\${KEYCLOAK_INTERNAL}/realms/mcp/protocol/openid-connect/token\" \
            -d 'grant_type=password' -d 'client_id=mcp-cli' \
            -d \"username=\${USER}\" -d \"password=\${USER}\" -d 'scope=openid' 2>/dev/null | \
            python3 -c \"import sys,json,base64; t=json.load(sys.stdin)['access_token']; print(json.loads(base64.urlsafe_b64decode(t.split('.')[1]+'=='))['sub'])\" 2>/dev/null); \
          if [ -n \"\$USER_SUB\" ]; then \
            kubectl exec -n vault deploy/vault -- sh -c \"VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault kv put secret/mcp-gateway/\${USER_SUB} github_pat=\${GITHUB_PAT}\"; \
          fi; \
        done"
  else
    if [ "$BATCH_MODE" = false ]; then
      gum style --foreground 214 "GITHUB_PAT not set — skipping Vault PAT storage."
      gum style --foreground 214 "To store PATs later: export GITHUB_PAT=ghp_... && ./scripts/store-github-pat.sh <user>"
    else
      echo "  GITHUB_PAT not set — skipping Vault PAT storage."
    fi
  fi

  phase_done 15
  show_resources \
    "Deployments: deployments -n vault" \
    "Pods: pods -n vault" \
    "Services: services -n vault"
fi

fi # phase 15

########################################
# Phase 16: GitHub MCP Server
########################################

if [ "$START_PHASE" -le 16 ]; then

show_phase 16 "GitHub MCP Server (Optional)" "
## What this does

Deploys the **GitHub MCP server** — a real-world MCP server that exposes GitHub API
operations as tools (search repos, list issues, create PRs, etc.).

## Why

This demonstrates the full credential exchange pipeline end-to-end:

1. User calls a GitHub tool through the gateway
2. Authorino's AuthPolicy triggers a **metadata evaluator** that:
   - Logs into Vault with the user's Keycloak JWT
   - Reads the user's GitHub PAT from \`secret/mcp-gateway/<sub>\`
3. Authorino injects the PAT as \`Authorization: Bearer <pat>\` header
4. The GitHub MCP server receives the request with the PAT and calls GitHub's API

The operator's **credential-ref** annotation (\`mcp.x-k8s.io/gateway-credential-ref\`)
tells the operator to set a \`credentialRef\` on the MCPServerRegistration so the
broker can authenticate when discovering the server's tools.

**Requires \`GITHUB_PAT\` environment variable** — skipped if not set.

## What gets created

- MCPServer CR \`github\` (with gateway-ref + credential-ref annotations)
- GitHub Deployment + Service + HTTPRoute + MCPServerRegistration (by operator)
- Broker credential Secret (for tool discovery)
- AuthPolicy with Vault metadata evaluator (for per-user credential injection)
"

if confirm_phase 16; then
  if [ -z "${GITHUB_PAT:-}" ]; then
    if [ "$BATCH_MODE" = false ]; then
      gum style --foreground 214 "GITHUB_PAT not set — skipping GitHub MCP server."
      gum style --foreground 214 "Set GITHUB_PAT and re-run with --phase 16 to deploy it later."
    else
      echo "  GITHUB_PAT not set — skipping GitHub MCP server."
    fi
    phase_done 16
  else
    GITHUB_IMAGE="ghcr.io/github/github-mcp-server:latest"
    run_cmd "Pulling GitHub MCP server image..." \
      ${CONTAINER_ENGINE} pull "${GITHUB_IMAGE}"
    TMP_TAR="/tmp/github-mcp-server-$$.tar"
    run_cmd "Loading image into Kind..." \
      bash -c "${CONTAINER_ENGINE} save '${GITHUB_IMAGE}' -o '${TMP_TAR}' && kind load image-archive '${TMP_TAR}' --name '${KIND_CLUSTER_NAME}' && rm -f '${TMP_TAR}'"

    run_cmd "Creating broker credential secret..." \
      kubectl apply -f - <<CRED_EOF
apiVersion: v1
kind: Secret
metadata:
  name: github-broker-credential
  namespace: mcp-test
  labels:
    mcp.kuadrant.io/secret: "true"
type: Opaque
stringData:
  token: "${GITHUB_PAT}"
CRED_EOF

    run_cmd "Deploying GitHub MCP server..." \
      kubectl apply -f "${REPO_DIR}/infrastructure/test-servers/github-server.yaml"
    run_cmd "Waiting for GitHub deployment..." \
      bash -c "kubectl wait --for=condition=Available deployment/github -n mcp-test --timeout=120s 2>/dev/null || true"

    run_cmd "Waiting for MCPServerRegistration..." \
      bash -c "for i in \$(seq 1 12); do kubectl get mcpserverregistration github -n mcp-test &>/dev/null && break; sleep 5; done"

    run_cmd "Restarting mcp-gateway to pick up GitHub registration..." \
      bash -c "kubectl rollout restart deployment mcp-gateway -n mcp-system 2>/dev/null && \
               kubectl rollout status deployment mcp-gateway -n mcp-system --timeout=120s 2>/dev/null || true"

    run_cmd "Applying GitHub AuthPolicy (Vault token exchange)..." \
      bash -c "sleep 5 && kubectl apply -f '${REPO_DIR}/infrastructure/auth/authpolicy-github.yaml'"

    phase_done 16
    show_resources \
      "MCPServers: mcpserver github -n mcp-test" \
      "Deployments: deployments -n mcp-test -l mcp-server=github" \
      "MCPServerRegistrations: mcpserverregistration github -n mcp-test" \
      "AuthPolicies: authpolicy -n mcp-test" \
      "Secrets: secrets -n mcp-test -l mcp.kuadrant.io/secret=true"
  fi
fi

fi # phase 16

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
    "All 16 phases deployed successfully."
fi

echo ""

if [ "$BATCH_MODE" = false ]; then
  gum format << 'EOF'
## Endpoints (HTTP)

| Service | URL |
|---------|-----|
| MCP Gateway | http://mcp.127-0-0-1.sslip.io:8001/mcp |
| Keycloak | http://keycloak.127-0-0-1.sslip.io:8002 (admin/admin) |
| MCP Launcher | http://localhost:8004 |

## Endpoints (HTTPS — self-signed CA)

| Service | URL |
|---------|-----|
| MCP Gateway | https://mcp.127-0-0-1.sslip.io:8443/mcp |
| Keycloak | https://keycloak.127-0-0-1.sslip.io:8445 |
| CA cert | /tmp/mcp-ca.crt (use with `curl --cacert`) |

## Test users (password = username)

| User | Groups | Server1 | Server2 |
|------|--------|---------|---------|
| alice | developers | greet | set_time |
| bob | ops | add_tool | auth1234, set_time |
| carol | both | greet, add_tool | auth1234, set_time |

## Try it

```bash
# Get a token
TOKEN=$(curl -s http://keycloak.127-0-0-1.sslip.io:8002/realms/mcp/protocol/openid-connect/token \
  -d grant_type=password -d client_id=mcp-cli -d username=alice -d password=alice -d scope=openid \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Initialize an MCP session
SESSION=$(curl -si -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  http://mcp.127-0-0-1.sslip.io:8001/mcp | grep -i mcp-session-id | awk '{print $2}' | tr -d '\r')

# List tools through the gateway
curl -s http://mcp.127-0-0-1.sslip.io:8001/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Mcp-Session-Id: $SESSION" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# Interactive CLI client
./scripts/mcp-client.sh

# Run the full test pipeline (63 checks)
./scripts/test-pipeline.sh
```
EOF
else
  echo "Endpoints (HTTP):"
  echo "  MCP Gateway:  http://mcp.127-0-0-1.sslip.io:8001/mcp"
  echo "  Keycloak:     http://keycloak.127-0-0-1.sslip.io:8002 (admin/admin)"
  echo "  Launcher:     http://localhost:8004"
  echo ""
  echo "Endpoints (HTTPS):"
  echo "  MCP Gateway:  https://mcp.127-0-0-1.sslip.io:8443/mcp"
  echo "  Keycloak:     https://keycloak.127-0-0-1.sslip.io:8445"
  echo "  CA cert:      /tmp/mcp-ca.crt"
fi

# Clean up state file on successful completion
rm -f "$STATE_FILE"
