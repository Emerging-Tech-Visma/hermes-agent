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

LOG="${HOME}/Library/Logs/hermes-gateway-tunnel.log"

if [ "${1:-}" = "--status" ]; then
  CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 \
    "http://localhost:${PORT}/" 2>/dev/null || true)"
  CODE="${CODE:-000}"
  case "${CODE}" in
    200|302|401)
      # 302 -> /login is the normal unauthenticated answer.
      echo "Gateway UP on localhost:${PORT} (HTTP ${CODE})"
      exit 0 ;;
  esac

  echo "Gateway DOWN on localhost:${PORT} (HTTP ${CODE})"

  # DISTINGUISH the two failures — they look identical from the app, which just says
  # "could not reach the remote Hermes gateway", but the fixes are completely different.
  #
  # (a) nothing listening        -> the tunnel is not running at all.
  # (b) listening but HTTP 000   -> the tunnel process is alive and BOUND, and simply
  #     cannot forward. Overwhelmingly this is EXPIRED gcloud CREDENTIALS. This is the
  #     dangerous one: `launchctl list` reports the agent as status 0 and the port is
  #     held, so every "is it up?" check based on process or port liveness says HEALTHY
  #     while nothing works. Only an actual HTTP request reveals it. (Hit 2026-08-19.)
  if lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    echo
    echo "  A process IS listening on :${PORT} but the tunnel is not forwarding."
    if grep -qiE "TokenRefreshError|Reauthentication failed|gcloud auth login" "${LOG}" 2>/dev/null; then
      echo "  CAUSE: expired gcloud credentials (found in ${LOG})."
      echo "  FIX:"
      echo "    gcloud auth login"
      echo "    launchctl kickstart -k gui/\$(id -u)/com.hermes.gateway-tunnel"
    else
      echo "  Check the log for the reason: tail -30 ${LOG}"
      echo "  Expired credentials are the usual cause: gcloud auth login"
    fi
  else
    echo
    echo "  Nothing is listening on :${PORT} — the tunnel is not running."
    echo "  Start it permanently:  bash scripts/install-gateway-launchagent.sh"
  fi
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
