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
KIND_CLUSTER_NAME="mcp-gateway"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-docker}"
BATCH_MODE=false
START_PHASE=1

# Versions
GATEWAY_API_VERSION="v1.4.1"
SAIL_VERSION="1.27.0"
METALLB_VERSION="v0.15.2"

TOTAL_PHASES=10

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

phase_inspect() {
  local namespace="$1"
  if [ "$BATCH_MODE" = true ]; then
    return
  fi
  if gum confirm --default=no "Inspect resources in ${namespace}?"; then
    kubectl get all -n "$namespace" 2>/dev/null | gum pager
  fi
}

# --- Welcome ---

if [ "$BATCH_MODE" = false ]; then
  gum style --border double --border-foreground 99 --padding "1 3" --margin "1 0" --align center \
    "MCP Ecosystem — Guided Setup" \
    "" \
    "Build a production-adjacent MCP ecosystem on a local Kind cluster." \
    "Each phase deploys one layer and explains what it does and why." \
    "" \
    "10 phases | ~5 minutes total"

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

Creates a **Kind** (Kubernetes in Docker) cluster named \`mcp-gateway\` with custom
port mappings so you can reach services from your host machine.

## Why

Kind runs a full Kubernetes cluster inside a Docker container. The port mappings
in the cluster config expose specific NodePorts to your host:

- **8001** -> MCP Gateway (HTTP)
- **8003** -> Mini-OIDC (token issuance)
- **8004** -> MCP Launcher UI

Without these mappings, services inside the cluster would be unreachable from
your browser and curl.

## What gets created

- A Kind cluster node (Docker container running Kubernetes)
- kubectl context set to \`kind-mcp-gateway\`
"

if confirm_phase 1; then
  if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
    gum style --foreground 214 "Cluster '${KIND_CLUSTER_NAME}' already exists — reusing it."
  else
    run_cmd "Creating Kind cluster..." \
      kind create cluster --name "${KIND_CLUSTER_NAME}" --config "${REPO_DIR}/infrastructure/kind/cluster.yaml"
  fi
  kubectl config use-context "kind-${KIND_CLUSTER_NAME}" >/dev/null 2>&1
  phase_done 1
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
  phase_inspect "istio-system"
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
fi

fi # phase 4

########################################
# Phase 5: Gateway
########################################

if [ "$START_PHASE" -le 5 ]; then

show_phase 5 "Envoy Gateway" "
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

if confirm_phase 5; then
  kubectl apply -f "${REPO_DIR}/infrastructure/gateway/namespace.yaml" >/dev/null 2>&1
  kubectl apply -f "${REPO_DIR}/infrastructure/gateway/gateway.yaml" >/dev/null 2>&1
  kubectl apply -f "${REPO_DIR}/infrastructure/gateway/nodeport.yaml" >/dev/null 2>&1
  kubectl apply -f "${REPO_DIR}/infrastructure/gateway/referencegrant.yaml" >/dev/null 2>&1
  run_cmd "Waiting for Gateway to be programmed..." \
    kubectl wait --for=condition=Programmed gateway/mcp-gateway -n gateway-system --timeout=300s
  phase_done 5
  phase_inspect "gateway-system"
fi

fi # phase 5

########################################
# Phase 6: mcp-gateway
########################################

if [ "$START_PHASE" -le 6 ]; then

show_phase 6 "MCP Gateway (Broker + Router)" "
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

if confirm_phase 6; then
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
  phase_done 6
  phase_inspect "mcp-system"
fi

fi # phase 6

########################################
# Phase 7: Lifecycle Operator
########################################

if [ "$START_PHASE" -le 7 ]; then

show_phase 7 "MCP Lifecycle Operator" "
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

- Lifecycle operator deployment in \`mcp-lifecycle-operator-system\`
- RBAC for the gateway reconciler (needs permissions for HTTPRoute, MCPServerRegistration)
"

if confirm_phase 7; then
  OPERATOR_IMAGE="quay.io/jrao/mcp-lifecycle-operator:gateway-integration"
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
  phase_done 7
  phase_inspect "mcp-lifecycle-operator-system"
fi

fi # phase 7

########################################
# Phase 8: Catalog System
########################################

if [ "$START_PHASE" -le 8 ]; then

show_phase 8 "Catalog System" "
## What this does

Deploys the **model-registry catalog** — a REST API that provides MCP server discovery.

## Why

The catalog answers the question: *\"What MCP servers are available?\"*

It serves a REST API at \`/api/mcp_catalog/v1alpha1/mcp_servers\` that returns server
metadata: name, description, OCI image URI, tools, port, and runtime requirements.

The catalog is backed by **PostgreSQL** for metadata storage and a **ConfigMap** for
the server definitions (YAML). In this experiment, the catalog has one entry:
\`test-server1\`.

The MCP Launcher (Phase 10) reads from this API to present a browsable UI.

## What gets created

- \`catalog-system\` namespace
- PostgreSQL StatefulSet + PVC + Secret + Service
- Catalog ConfigMap (server definitions in YAML)
- Catalog Deployment + ClusterIP Service
"

if confirm_phase 8; then
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
  phase_done 8
  phase_inspect "catalog-system"
fi

fi # phase 8

########################################
# Phase 9: Mini-OIDC + Istio Auth
########################################

if [ "$START_PHASE" -le 9 ]; then

show_phase 9 "Authentication (Mini-OIDC + Istio)" "
## What this does

Deploys **mini-oidc** (a lightweight OIDC provider) and configures Istio to validate
JWTs at the gateway.

## Why

MCP servers behind the gateway need authentication — you don't want anonymous users
calling tools. The auth layer has two parts:

1. **mini-oidc** — a minimal OIDC provider that issues JWTs. It exposes a \`POST /token\`
   endpoint and OIDC discovery at \`/.well-known/openid-configuration\`. Tokens are
   signed with RSA keys and contain standard JWT claims.

2. **Istio auth resources**:
   - **RequestAuthentication** — tells Envoy to validate JWT signatures using
     mini-oidc's JWKS endpoint
   - **AuthorizationPolicy** — requires a valid JWT on all requests to port 8080
   - **EnvoyFilter (Lua)** — attempts to return proper 401 + \`WWW-Authenticate\`
     headers (Istio's default is 403, which confuses OAuth clients)

This is the *basic* auth approach. The \`main\` branch replaces mini-oidc with
Keycloak and Istio auth with Kuadrant AuthPolicy for production-grade per-tool
authorization.

## What gets created

- \`mcp-test\` namespace
- mini-oidc Deployment + Service + NodePort (accessible at localhost:8003)
- RequestAuthentication in \`gateway-system\`
- AuthorizationPolicy in \`gateway-system\`
- EnvoyFilter (Lua 401 response) in \`gateway-system\`
"

if confirm_phase 9; then
  kubectl create namespace mcp-test --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  run_cmd "Deploying mini-oidc..." \
    kubectl apply -f "${REPO_DIR}/infrastructure/mini-oidc/mini-oidc.yaml"
  run_cmd "Waiting for mini-oidc..." \
    kubectl wait --for=condition=Ready pod -l app=mini-oidc -n mcp-test --timeout=120s
  run_cmd "Applying Istio auth resources..." \
    bash -c "kubectl apply -f '${REPO_DIR}/infrastructure/auth/request-authentication.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/auth/authorization-policy.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/auth/envoyfilter-401.yaml'"
  phase_done 9
fi

fi # phase 9

########################################
# Phase 10: Test Server + Launcher
########################################

if [ "$START_PHASE" -le 10 ]; then

show_phase 10 "Test Server + MCP Launcher" "
## What this does

Deploys a **test MCP server** and the **MCP Launcher** UI.

## Why

This is where the full pipeline comes together:

1. The **MCPServer CR** (\`test-server1\`) is applied with a \`gateway-ref\` annotation
2. The **lifecycle operator** sees it and creates: Deployment, Service, HTTPRoute,
   and MCPServerRegistration
3. The **mcp-gateway broker** discovers the new server's tools
4. The **mcp-gateway router** can now route \`tools/call\` requests to it

The **MCP Launcher** is a web UI that reads from the catalog API and lets you
browse available servers. It's at \`http://localhost:8004\`.

After this phase, you can:
\`\`\`bash
# Get a token
TOKEN=\$(curl -s -X POST http://localhost:8003/token | python3 -c \"import sys,json; print(json.load(sys.stdin)['access_token'])\")

# List tools through the gateway
curl -s http://mcp.127-0-0-1.sslip.io:8001/mcp \\
  -H \"Authorization: Bearer \$TOKEN\" \\
  -H 'Content-Type: application/json' \\
  -d '{\"jsonrpc\":\"2.0\",\"method\":\"tools/list\",\"id\":1}'
\`\`\`

## What gets created

- MCPServer CR \`test-server1\` (triggers operator reconciliation)
- test-server1 Deployment + Service + HTTPRoute + MCPServerRegistration (by operator)
- MCP Launcher Deployment + Service + NodePort
- Launcher RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding)
"

if confirm_phase 10; then
  run_cmd "Deploying test server..." \
    kubectl apply -f "${REPO_DIR}/infrastructure/test-servers/test-server1.yaml"
  run_cmd "Deploying MCP Launcher..." \
    bash -c "kubectl apply -f '${REPO_DIR}/infrastructure/launcher/rbac.yaml' && \
             kubectl apply -f '${REPO_DIR}/infrastructure/launcher/deployment.yaml'"
  run_cmd "Waiting for test server..." \
    bash -c "kubectl wait --for=condition=Ready mcpserver/test-server1 -n mcp-test --timeout=120s 2>/dev/null || true"

  run_cmd "Restarting mcp-gateway to pick up registrations..." \
    bash -c "kubectl rollout restart deployment mcp-gateway -n mcp-system 2>/dev/null && \
             kubectl rollout status deployment mcp-gateway -n mcp-system --timeout=120s 2>/dev/null || true"
  phase_done 10
  phase_inspect "mcp-test"
fi

fi # phase 10

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
    "All 10 phases deployed successfully."
fi

echo ""

if [ "$BATCH_MODE" = false ]; then
  gum format << 'EOF'
## Endpoints

| Service | URL |
|---------|-----|
| MCP Gateway | http://mcp.127-0-0-1.sslip.io:8001/mcp |
| Mini-OIDC | http://localhost:8003 |
| MCP Launcher | http://localhost:8004 |

## Try it

```bash
# Get a token
TOKEN=$(curl -s -X POST http://localhost:8003/token | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# List tools through the gateway
curl -s http://mcp.127-0-0-1.sslip.io:8001/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'

# Run the test pipeline
./scripts/test-pipeline.sh
```

## Next steps

The `main` branch extends this with:
- **Keycloak** (production OIDC with users, groups, roles)
- **Kuadrant AuthPolicy** (per-tool authorization with CEL predicates)
- **TLS** (cert-manager + TLSPolicy)
- **Vault** (per-user credential exchange)
EOF
else
  echo "Endpoints:"
  echo "  MCP Gateway:  http://mcp.127-0-0-1.sslip.io:8001/mcp"
  echo "  Mini-OIDC:    http://localhost:8003"
  echo "  Launcher:     http://localhost:8004"
fi

# Clean up state file on successful completion
rm -f "$STATE_FILE"
