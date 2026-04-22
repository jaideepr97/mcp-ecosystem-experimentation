#!/usr/bin/env bash
# Generate ECDSA key pair for wristband JWT signing/verification.
#
# Creates two secrets:
#   trusted-headers-private-key (in Authorino's namespace) — signs the wristband
#   trusted-headers-public-key  (in the gateway namespace)  — broker verifies it
#
# The AuthPolicy wristband response uses the private key to sign an ES256 JWT
# containing the allowed-tools claim. The broker uses the public key to validate
# the x-authorized-tools header before filtering tools/list.
#
# Usage: ./wristband-keys.sh
#   GATEWAY_NS   — namespace where the gateway is deployed (default: team-a)
#   AUTHORINO_NS — namespace where Authorino runs (default: openshift-operators)

set -euo pipefail

GATEWAY_NS="${GATEWAY_NS:-team-a}"
AUTHORINO_NS="${AUTHORINO_NS:-openshift-operators}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "=== Generate ECDSA P-256 key pair ==="
openssl ecparam -name prime256v1 -genkey -noout -out "$TMPDIR/private.pem"
openssl ec -in "$TMPDIR/private.pem" -pubout -out "$TMPDIR/public.pem"
echo "  Key pair generated"

echo "=== Create private key secret in ${AUTHORINO_NS} (for Authorino signing) ==="
oc create secret generic trusted-headers-private-key \
  -n "$AUTHORINO_NS" \
  --from-file=key.pem="$TMPDIR/private.pem" \
  --dry-run=client -o yaml | oc apply -f -

echo "=== Create public key secret in ${GATEWAY_NS} (for broker verification) ==="
oc create secret generic trusted-headers-public-key \
  -n "$GATEWAY_NS" \
  --from-file=key="$TMPDIR/public.pem" \
  --dry-run=client -o yaml | oc apply -f -

echo ""
echo "=== Done ==="
echo "  Private key: trusted-headers-private-key in ${AUTHORINO_NS}"
echo "  Public key:  trusted-headers-public-key in ${GATEWAY_NS}"
echo ""
echo "  Next: patch MCPGatewayExtension to reference the public key:"
echo "    oc patch mcpgatewayextension <name> -n ${GATEWAY_NS} --type merge \\"
echo "      -p '{\"spec\":{\"trustedHeadersKey\":{\"generate\":\"Disabled\",\"secretName\":\"trusted-headers-public-key\"}}}'"
