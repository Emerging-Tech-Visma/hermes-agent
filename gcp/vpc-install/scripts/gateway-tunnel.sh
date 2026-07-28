#!/usr/bin/env bash
# Run on YOUR PC (not the VM). Opens the secure gateway to the Hermes dashboard.
#
#   ./gateway-tunnel.sh            # foreground, Ctrl-C to stop
#   ./gateway-tunnel.sh --status   # is it up?
#
# This is an IAP TCP-forwarding tunnel. The VM has no external IP and the
# firewall admits nothing but Google's IAP range, so this tunnel — authorised by
# your Google identity via roles/iap.tunnelResourceAccessor — is the ONLY way in.
# Nothing is ever published to the internet.
#
# Once up:  desktop app -> Settings -> Gateway -> Remote gateway
#             URL http://localhost:9119, sign in with your dashboard user/password
#           or just open http://localhost:9119 in a browser.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-test-disco-cm}"
VM_NAME="${VM_NAME:-hermes-agent}"
ZONE="${ZONE:-europe-west2-b}"
PORT="${DASHBOARD_PORT:-9119}"

if [ "${1:-}" = "--status" ]; then
  if curl -sS -o /dev/null -w '%{http_code}' "http://localhost:${PORT}/" 2>/dev/null | grep -qE '^(200|302|401)$'; then
    echo "Gateway UP on localhost:${PORT}"
    exit 0
  fi
  echo "Gateway DOWN on localhost:${PORT}"
  exit 1
fi

echo "Opening IAP tunnel to ${VM_NAME} (${ZONE}) :${PORT} ..."
echo "Then open http://localhost:${PORT}"
echo

# --local-host-port binds only on loopback of THIS machine.
exec gcloud compute start-iap-tunnel "${VM_NAME}" "${PORT}" \
  --local-host-port="localhost:${PORT}" \
  --zone="${ZONE}" \
  --project="${PROJECT_ID}"
