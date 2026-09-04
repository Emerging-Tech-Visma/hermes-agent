#!/usr/bin/env bash
# Run on YOUR MAC (not the VM). Makes the secure gateway permanent.
#
#   bash gcp/vpc-install/scripts/install-gateway-launchagent.sh
#   bash gcp/vpc-install/scripts/install-gateway-launchagent.sh --uninstall
#
# Installs a launchd LaunchAgent that keeps the IAP tunnel to the Hermes dashboard up
# across sleep, reboot and network changes. This is the DEFAULT way to connect: a
# hand-started `gcloud compute start-iap-tunnel` dies with the shell that launched it,
# which shows up in the desktop app as "Remote gateway sign-in required".
#
# Nothing is exposed to the internet. The tunnel binds ONLY on this machine's loopback,
# and IAP still authorises every connection against your Google identity.
#
# Idempotent — safe to re-run. It boots out any existing agent with the same label first,
# so re-running is also the way to apply a changed VM/zone/port.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/../00-vars.sh"

LABEL="com.hermes.gateway-tunnel"
TEMPLATE="${HERE}/../configs/${LABEL}.plist"
TARGET="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DOMAIN="gui/$(id -u)"
LOG="${HOME}/Library/Logs/hermes-gateway-tunnel.log"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: launchd is macOS-only. On Linux use a systemd --user unit instead." >&2
  exit 1
fi

boot_out() { launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true; }

if [ "${1:-}" = "--uninstall" ]; then
  boot_out
  rm -f "${TARGET}"
  echo "Removed ${LABEL}. The gateway is no longer kept up automatically."
  exit 0
fi

GCLOUD="$(command -v gcloud || true)"
if [ -z "${GCLOUD}" ]; then
  echo "ERROR: gcloud not on PATH. Install the Google Cloud SDK first." >&2
  exit 1
fi

# --- Clear anything already holding the port ------------------------------------
# Two things commonly do: an older agent (the pre-VPC install shipped
# `com.hermes.tunnel`, an SSH -L tunnel to a VM that no longer exists — it fails
# forever and would fight for this port), and an interactive tunnel in some other
# terminal. launchd will NOT tell you the bind failed; the agent just respawns and the
# log fills with "Address already in use".
# Bootout is not always immediate — VERIFY and retry. Observed 2026-08-18: a single
# bootout of com.hermes.tunnel returned success and the job was still listed (with a
# fresh PID) seconds later, because launchd had already relaunched it under KeepAlive.
for stale in com.hermes.tunnel "${LABEL}"; do
  launchctl list 2>/dev/null | grep -q "${stale}" || continue
  echo "==> Booting out existing agent ${stale}"
  for attempt in 1 2 3 4 5; do
    launchctl bootout "${DOMAIN}/${stale}" 2>/dev/null || true
    sleep 2
    launchctl list 2>/dev/null | grep -q "${stale}" || { echo "    gone"; break; }
    echo "    still listed after attempt ${attempt}; retrying"
  done
  if launchctl list 2>/dev/null | grep -q "${stale}"; then
    echo "    WARNING: ${stale} would not unload. Remove"
    echo "    ~/Library/LaunchAgents/${stale}.plist and log out/in."
  fi
done
if [ -f "${HOME}/Library/LaunchAgents/com.hermes.tunnel.plist" ]; then
  mv "${HOME}/Library/LaunchAgents/com.hermes.tunnel.plist" \
     "${HOME}/Library/LaunchAgents/com.hermes.tunnel.plist.superseded"
  echo "    archived the superseded com.hermes.tunnel.plist (public-IP install)"
fi
if lsof -nP -iTCP:"${DASHBOARD_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "    NOTE: something else is still LISTENING on :${DASHBOARD_PORT}."
  echo "    Close that tunnel, or the agent cannot bind. Holder:"
  lsof -nP -iTCP:"${DASHBOARD_PORT}" -sTCP:LISTEN | tail -n +2 | sed 's/^/      /'
fi

# --- Render the template --------------------------------------------------------
echo "==> Writing ${TARGET}"
mkdir -p "${HOME}/Library/LaunchAgents"
# The LaunchAgent outlives the shell that installed it, so it must NEVER point at
# this checkout: this repo's workflow uses temporary per-agent git worktrees, and
# deleting one would delete the running supervisor out from under launchd. That is
# not hypothetical — it happened on 2026-09-04, and the failure looks exactly like
# the credential fault the supervisor exists to diagnose (agent loaded, nothing
# listening on the port, no log).
#
# So: copy the supervisor to ~/.local/bin and point the plist THERE. The installed
# copy has no 00-vars.sh beside it, which is why the plist carries VM_NAME/ZONE/
# PROJECT_ID/DASHBOARD_PORT in EnvironmentVariables.
SRC_SUPERVISOR="${HERE}/gateway-tunnel-supervisor.sh"
if [ ! -f "${SRC_SUPERVISOR}" ]; then
  echo "ERROR: missing ${SRC_SUPERVISOR}" >&2; exit 1
fi
# --- Tunnel credential -----------------------------------------------------------
# A LaunchAgent cannot answer a reauth prompt, so the tunnel authenticates as a
# service account. See the TUNNEL_USE_SA block in 00-vars.sh for the full reasoning.
SA_KEY_FOR_PLIST=""
if [ "${TUNNEL_USE_SA:-true}" = "true" ]; then
  if [ ! -f "${TUNNEL_SA_KEY}" ]; then
    echo "==> Creating the tunnel service-account key"
    if ! gcloud iam service-accounts describe "${TUNNEL_SA_EMAIL}" \
         --project="${PROJECT_ID}" >/dev/null 2>&1; then
      echo "ERROR: service account ${TUNNEL_SA_EMAIL} does not exist." >&2
      echo "       Run 01-gcp-setup.sh first (it creates and grants it)." >&2
      exit 1
    fi
    mkdir -p "$(dirname "${TUNNEL_SA_KEY}")"
    # umask so the key is never briefly world-readable between create and chmod.
    ( umask 077
      gcloud iam service-accounts keys create "${TUNNEL_SA_KEY}" \
        --iam-account="${TUNNEL_SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null )
    chmod 600 "${TUNNEL_SA_KEY}"
    echo "    wrote ${TUNNEL_SA_KEY} (mode 0600, gitignored — this is a real credential)"
  else
    echo "==> Reusing existing tunnel key ${TUNNEL_SA_KEY}"
    chmod 600 "${TUNNEL_SA_KEY}"
  fi
  # Prove the credential actually works BEFORE handing it to launchd, so a bad key
  # surfaces here instead of as a silently dead gateway hours later.
  # A freshly created key is eventually consistent: the first token request can fail
  # for a few seconds even though the key is valid. Observed 2026-09-04 — the check
  # failed immediately after `keys create`, then succeeded seconds later by hand. Poll
  # rather than declaring a good key bad and telling the operator to delete it.
  TOKEN_OK=""
  for i in $(seq 1 10); do
    if CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="${TUNNEL_SA_KEY}" \
       gcloud auth print-access-token >/dev/null 2>&1; then
      TOKEN_OK="yes"; break
    fi
    sleep 3
  done
  if [ -z "${TOKEN_OK}" ]; then
    echo "ERROR: ${TUNNEL_SA_KEY} did not yield a token after 30s." >&2
    echo "       Check that ${TUNNEL_SA_EMAIL} still has roles/iap.tunnelResourceAccessor," >&2
    echo "       then delete the key file and re-run to mint a new one." >&2
    exit 1
  fi
  echo "    credential verified (minted a token, no reauth prompt)"
  SA_KEY_FOR_PLIST="${TUNNEL_SA_KEY}"
else
  echo "==> TUNNEL_USE_SA=false — using your own gcloud credentials."
  echo "    NOTE: the tunnel will stop at every reauth window until you run 'gcloud auth login'."
fi

SUPERVISOR="${HOME}/.local/bin/hermes-gateway-tunnel-supervisor.sh"
mkdir -p "${HOME}/.local/bin"
install -m 0755 "${SRC_SUPERVISOR}" "${SUPERVISOR}"
echo "    supervisor installed to ${SUPERVISOR}"

sed -e "s|__SUPERVISOR__|${SUPERVISOR}|g" \
    -e "s|__SA_KEY__|${SA_KEY_FOR_PLIST}|g" \
    -e "s|__GCLOUD__|${GCLOUD}|g" \
    -e "s|__GCLOUD_DIR__|$(dirname "${GCLOUD}")|g" \
    -e "s|__HOME__|${HOME}|g" \
    -e "s|__VM_NAME__|${VM_NAME}|g" \
    -e "s|__PORT__|${DASHBOARD_PORT}|g" \
    -e "s|__ZONE__|${ZONE}|g" \
    -e "s|__PROJECT_ID__|${PROJECT_ID}|g" \
    "${TEMPLATE}" > "${TARGET}"

# With TUNNEL_USE_SA=false there is no key, and an EMPTY
# CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE is worse than an absent one — gcloud would
# try to load "" as a credential file. Remove the key outright in that case.
if [ -z "${SA_KEY_FOR_PLIST}" ]; then
  plutil -remove EnvironmentVariables.CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE \
    "${TARGET}" >/dev/null 2>&1 || true
fi

# Fail loudly on a malformed plist rather than leaving launchd to reject it silently.
if ! plutil -lint "${TARGET}" >/dev/null; then
  echo "ERROR: rendered plist is not valid. Inspect ${TARGET}" >&2
  exit 1
fi
if grep -q "__" "${TARGET}"; then
  echo "ERROR: unsubstituted __TOKEN__ left in ${TARGET}" >&2
  grep -n "__" "${TARGET}" >&2
  exit 1
fi
# A plist that references a git checkout is a time bomb: the referenced path can be
# deleted (worktree cleanup, repo move) while launchd still points at it. Refuse to
# install one rather than discover it weeks later as a dead gateway.
if grep -qF "${HERE}" "${TARGET}"; then
  echo "ERROR: ${TARGET} references this checkout (${HERE}) — it must reference" >&2
  echo "       ${HOME}/.local/bin only, or the agent dies when the checkout moves." >&2
  grep -nF "${HERE}" "${TARGET}" >&2
  exit 1
fi

echo "==> Loading the agent"
: > "${LOG}" || true
launchctl bootstrap "${DOMAIN}" "${TARGET}"
launchctl kickstart -k "${DOMAIN}/${LABEL}"

# --- Verify it actually serves ---------------------------------------------------
# Poll: gcloud cold start plus the launchd ThrottleInterval means it is not instant.
echo "==> Waiting for the gateway to answer on localhost:${DASHBOARD_PORT}"
# `|| true` is LOAD-BEARING: this script runs under `set -e`, and curl exits 7
# ("failed to connect") on every attempt before the tunnel is listening. Without it the
# FIRST failed probe kills the script with exit 7 and the retry loop never runs — which is
# exactly what happened when this script was first written (it reported nothing and exited
# 7 while the agent came up fine a second later). Same errexit trap as
# dashboard-setup.sh:43; see CHANGELOG 0.13.0.
CODE="000"
for i in $(seq 1 20); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://localhost:${DASHBOARD_PORT}/" 2>/dev/null || true)"
  [ "${CODE:-000}" != "000" ] && break
  sleep 3
done

echo
if [ "${CODE:-000}" != "000" ]; then
  cat <<DONE
============================================================================
Gateway is UP and will stay up (restarts on sleep/reboot/network change).

  URL       http://localhost:${DASHBOARD_PORT}      (HTTP ${CODE} = auth gate, expected)
  Username  ${DASHBOARD_USERNAME}
  Password  on the VM: cat ~/.hermes-dashboard-password

  Desktop app -> Settings -> Gateway -> Remote gateway -> that URL, basic auth.

  Force reconnect   launchctl kickstart -k ${DOMAIN}/${LABEL}
  Stop + disable    bash $(basename "$0") --uninstall
  Logs              tail -f ${LOG}
============================================================================
DONE
else
  echo "WARNING: no response on :${DASHBOARD_PORT} yet."
  # Name the cause instead of dumping a log and hoping. Expired credentials are the most
  # common one and the most confusing, because the agent stays "running" and the port
  # stays bound — see the note in gateway-tunnel.sh --status.
  if grep -qiE "TokenRefreshError|Reauthentication failed|gcloud auth login" "${LOG}" 2>/dev/null; then
    echo
    echo "  CAUSE: EXPIRED gcloud CREDENTIALS (found in ${LOG})."
    echo "  The agent will keep running and holding the port while failing every"
    echo "  forward, so it looks healthy to launchctl. Fix:"
    echo "     gcloud auth login"
    echo "     launchctl kickstart -k ${DOMAIN}/${LABEL}"
  elif grep -qi "Address already in use" "${LOG}" 2>/dev/null; then
    echo
    echo "  CAUSE: another tunnel already holds :${DASHBOARD_PORT}."
    lsof -nP -iTCP:"${DASHBOARD_PORT}" -sTCP:LISTEN 2>/dev/null | sed 's/^/    /'
  else
    echo "  Reconnect after wake/cold start can take 20-40s — try again shortly."
    echo "  If it stays down, read ${LOG}:"
    tail -20 "${LOG}" 2>/dev/null | sed 's/^/    /'
  fi
  exit 1
fi
