#!/usr/bin/env bash
# Supervises the IAP tunnel to the Hermes dashboard. Run by the LaunchAgent — you do not
# normally invoke this by hand (use install-gateway-launchagent.sh).
#
# WHY A SUPERVISOR AND NOT JUST KeepAlive
# =======================================
# `gcloud compute start-iap-tunnel` BINDS THE LOCAL PORT FIRST, and if its OAuth token
# later fails to refresh it does NOT exit — it retries internally, forever, while holding
# the listener open. Measured on 2026-09-02: one such process had been alive 1d 9h logging
# ~1.5 "Reauthentication failed" errors per SECOND, having written a 27 MB / 413k-line log.
#
# launchd's KeepAlive only restarts a process that DIES, so it never fired. The result is
# the worst possible failure shape:
#
#   launchctl list          -> status 0     (running)
#   lsof -iTCP:9119 LISTEN  -> bound        (accepts connections)
#   curl localhost:9119     -> HTTP 000     (forwards nothing)
#
# and the desktop app says "Could not reach the remote Hermes gateway while refreshing its
# WebSocket ticket", which reads like a server problem. Worse: **it never self-heals even
# after you run `gcloud auth login`**, because the stuck process never re-reads credentials.
# Only a manual `launchctl kickstart` recovered it. That is why the failure kept recurring.
#
# This supervisor fixes the actual defect: it health-checks the tunnel over HTTP (the only
# check that can tell forwarding from listening) and restarts the child when it stops
# forwarding. A credential lapse then self-heals the moment you re-authenticate.
set -uo pipefail

# Config comes from the environment when installed to ~/.local/bin (the plist sets it),
# and from 00-vars.sh when this script is run straight out of a repo checkout. The
# installed copy has no repo next to it, so sourcing must not be mandatory.
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${VM_NAME:-}" ] || [ -z "${ZONE:-}" ] || [ -z "${PROJECT_ID:-}" ]; then
  if [ -f "${HERE}/../00-vars.sh" ]; then
    # shellcheck disable=SC1091
    source "${HERE}/../00-vars.sh"
  else
    echo "ERROR: VM_NAME/ZONE/PROJECT_ID not set and no 00-vars.sh beside this script" >&2
    exit 78
  fi
fi

PORT="${DASHBOARD_PORT:-9119}"
LOG="${HOME}/Library/Logs/hermes-gateway-tunnel.log"
CHILD_LOG="${HOME}/Library/Logs/hermes-gateway-tunnel.child.log"
CHECK_EVERY="${CHECK_EVERY:-15}"      # seconds between HTTP probes
FAILS_BEFORE_RESTART="${FAILS_BEFORE_RESTART:-3}"   # 3 x 15s = 45s of no forwarding
MAX_LOG_BYTES="${MAX_LOG_BYTES:-2000000}"           # 2 MB, then truncate
NOTIFY_EVERY="${NOTIFY_EVERY:-1800}"                # re-nag about creds at most every 30m

mkdir -p "$(dirname "${LOG}")"
CHILD_PID=""

log() {
  # Cap our own log. The old setup wrote 27 MB because nothing rotated it.
  if [ -f "${LOG}" ] && [ "$(wc -c < "${LOG}" 2>/dev/null || echo 0)" -gt "${MAX_LOG_BYTES}" ]; then
    tail -c 500000 "${LOG}" > "${LOG}.tmp" 2>/dev/null && mv "${LOG}.tmp" "${LOG}"
    printf '%s  [log truncated]\n' "$(date '+%F %T')" >> "${LOG}"
  fi
  printf '%s  %s\n' "$(date '+%F %T')" "$*" >> "${LOG}"
}

notify() {
  # The one thing a human must do. A silent daemon is how this went unnoticed for a day.
  local msg="$1"
  command -v osascript >/dev/null 2>&1 && osascript -e \
    "display notification \"${msg}\" with title \"Hermes gateway\"" >/dev/null 2>&1 || true
}

stop_child() {
  [ -n "${CHILD_PID}" ] || return 0
  kill "${CHILD_PID}" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    kill -0 "${CHILD_PID}" 2>/dev/null || break
    sleep 1
  done
  kill -9 "${CHILD_PID}" 2>/dev/null || true
  CHILD_PID=""
}

trap 'log "supervisor stopping (signal)"; stop_child; exit 0' TERM INT

creds_ok() { gcloud auth print-access-token >/dev/null 2>&1; }

http_code() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://localhost:${PORT}/" 2>/dev/null || true
}

log "supervisor started (port ${PORT}, probe ${CHECK_EVERY}s, restart after ${FAILS_BEFORE_RESTART} failures)"
LAST_NOTIFY=0

while :; do
  # 1. Credentials. A daemon cannot satisfy an interactive reauth prompt, so don't even
  #    start the child — just wait, and tell the human what to run.
  if ! creds_ok; then
    NOW="$(date +%s)"
    log "gcloud credentials are not usable — waiting. Fix: gcloud auth login"
    if [ "$((NOW - LAST_NOTIFY))" -ge "${NOTIFY_EVERY}" ]; then
      notify "Credentials expired. Run: gcloud auth login"
      LAST_NOTIFY="${NOW}"
    fi
    stop_child
    sleep 30
    continue
  fi

  # 2. Start the tunnel if it isn't running.
  if [ -z "${CHILD_PID}" ] || ! kill -0 "${CHILD_PID}" 2>/dev/null; then
    : > "${CHILD_LOG}"
    gcloud compute start-iap-tunnel "${VM_NAME}" "${PORT}" \
      --local-host-port="localhost:${PORT}" \
      --zone="${ZONE}" --project="${PROJECT_ID}" >> "${CHILD_LOG}" 2>&1 &
    CHILD_PID=$!
    log "started tunnel child pid ${CHILD_PID}"
    sleep 8
  fi

  # 3. HEALTH-CHECK OVER HTTP. This is the whole point: a bound port proves nothing.
  FAILS=0
  while :; do
    CODE="$(http_code)"
    case "${CODE}" in
      200|302|401)
        [ "${FAILS}" -gt 0 ] && log "healthy again (HTTP ${CODE})"
        FAILS=0 ;;
      *)
        FAILS=$((FAILS+1))
        log "not forwarding (HTTP ${CODE:-000}) ${FAILS}/${FAILS_BEFORE_RESTART}"
        if [ "${FAILS}" -ge "${FAILS_BEFORE_RESTART}" ]; then
          if grep -qiE "Reauthentication failed|TokenRefreshError" "${CHILD_LOG}" 2>/dev/null; then
            log "child is stuck on expired credentials — killing it (it will not exit on its own)"
          else
            log "restarting the tunnel child"
          fi
          stop_child
          break
        fi ;;
    esac
    kill -0 "${CHILD_PID}" 2>/dev/null || { log "tunnel child exited"; CHILD_PID=""; break; }
    sleep "${CHECK_EVERY}"
  done
done
