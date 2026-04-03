#!/bin/bash
# Generates MetalLB IPAddressPool for the Kind docker network.
# Usage: ./ipaddresspool.sh | kubectl apply -n metallb-system -f -

set -euo pipefail

NETWORK_NAME="${1:-kind}"

# Get the docker network subnet (IPv4 only)
SUBNET=""
if command -v podman &>/dev/null; then
  SUBNET=$(podman network inspect -f '{{range .Subnets}}{{if eq (len .Subnet.IP) 4}}{{.Subnet}}{{end}}{{end}}' "$NETWORK_NAME" 2>/dev/null) || true
fi
if [[ -z "$SUBNET" ]]; then
  SUBNET=$(docker network inspect "$NETWORK_NAME" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
fi
if [[ -z "$SUBNET" ]]; then
  echo "Error: could not determine subnet for network '$NETWORK_NAME'" >&2
  exit 1
fi

NETWORK=$(echo "$SUBNET" | cut -d/ -f1)
IFS='.' read -r o1 o2 o3 o4 <<< "$NETWORK"

ADDRESS="${o1}.${o2}.${o3}.0/28"
echo "IPAddressPool address: $ADDRESS (from subnet: $SUBNET)" >&2

cat <<EOF
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: mcp-gateway
spec:
  addresses:
  - ${ADDRESS}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: empty
EOF
