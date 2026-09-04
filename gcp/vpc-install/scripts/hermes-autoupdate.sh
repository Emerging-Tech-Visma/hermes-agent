#!/usr/bin/env bash
# Weekly unattended update of the Hermes BACKEND on this VM.
# Run by hermes-autoupdate.timer — NOT by hand, and NOT from a hermes cron job.
#
# ---------------------------------------------------------------------------
# WHY A SYSTEMD TIMER AND NOT `hermes cron`
# ---------------------------------------------------------------------------
# `hermes update` restarts hermes-gateway.service. Verified with
# `hermes update --plan` on 2026-08-22:
#
#     Running services to restart (1):
#       • gateway [default] pid ... — systemd @ ...
#         restart: systemctl restart (drain-first SIGUSR1 when supported)
#
# A `hermes cron` job executes INSIDE that gateway process. So scheduling the
# update as a hermes cron job means the job restarts its own runtime mid-run and
# is killed before it finishes — the gateway unit sets `KillMode=mixed` plus an
# `ExecStopPost` cgroup cleanup, which reaps every process in the unit's cgroup.
# The same trap catches updates launched from the desktop app / dashboard: the
# spawned updater lives in the gateway's cgroup and dies with it.
#
# A systemd timer is its own unit with its own cgroup. When the updater restarts
# hermes-gateway.service, THIS script is unaffected. No Hermes code change and no
# `systemd-run --scope` wrapper is needed — the isolation is free once the
# updater is not launched from the thing being restarted.
#
# ---------------------------------------------------------------------------
# WHAT IT DOES NOT DO
# ---------------------------------------------------------------------------
# It cannot update the desktop app on your Mac. That app is built from its own
# checkout (`hermes desktop` = "Build and launch the native desktop app") and has
# no auto-update feed (no app-update.yml in the bundle). See OPS-NOTES.md §11.
set -uo pipefail

export PATH="${HOME}/.local/bin:${PATH}"
export HERMES_HOME="${HERMES_HOME:-${HOME}/.hermes}"

MODE="${AUTOUPDATE_MODE:-apply}"          # apply | check
STAMP_DIR="${HERMES_HOME}/autoupdate"
mkdir -p "${STAMP_DIR}"

log() { echo "[hermes-autoupdate] $*"; }

version_line() { hermes --version 2>/dev/null | head -1; }

BEFORE="$(version_line)"
log "current: ${BEFORE:-unknown}  (mode=${MODE})"

# ---------------------------------------------------------------------------
# 1. Is there anything to do? Skip quietly if not — no restarts, no churn.
# ---------------------------------------------------------------------------
CHECK_OUT="$(hermes update --check 2>&1)"
CHECK_RC=$?
if [ "${CHECK_RC}" -ne 0 ]; then
  log "WARNING: 'hermes update --check' exited ${CHECK_RC}; not updating this run"
  log "${CHECK_OUT}"
  exit 0    # a failed check is not a failed update — try again next week
fi
if ! printf '%s' "${CHECK_OUT}" | grep -qiE 'update available|commits behind'; then
  log "already up to date — nothing to do"
  date -u +%Y-%m-%dT%H:%M:%SZ > "${STAMP_DIR}/last-check"
  exit 0
fi
log "update available:"
printf '%s\n' "${CHECK_OUT}" | sed 's/^/    /'

if [ "${MODE}" = "check" ]; then
  log "AUTOUPDATE_MODE=check — reporting only, not installing"
  printf '%s\n' "${CHECK_OUT}" > "${STAMP_DIR}/pending"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Update. Hermes takes its own pre-update backup by default; don't disable it.
#    --yes so it never waits on a TTY that a timer does not have.
# ---------------------------------------------------------------------------
log "running 'hermes update --yes'"
if ! hermes update --yes 2>&1 | sed 's/^/    /'; then
  log "ERROR: 'hermes update --yes' failed — see the lines above"
  log "the pre-update backup is under ${HERMES_HOME}/backups; recovery: OPS-NOTES.md §3"
  date -u +%Y-%m-%dT%H:%M:%SZ > "${STAMP_DIR}/last-failure"
  exit 1
fi

AFTER="$(version_line)"
log "updated: ${BEFORE:-unknown}  ->  ${AFTER:-unknown}"

# ---------------------------------------------------------------------------
# 3. Restart what the updater does NOT.
#
# `hermes update --plan` lists ONLY the gateway as a service it restarts. Our
# install also runs hermes-dashboard.service — the endpoint the desktop app and
# browser actually connect to — and the updater has no knowledge of it. Without
# this, the dashboard keeps serving the PRE-update code until something else
# restarts it, so the app appears not to have updated at all.
#
# vertex-openai-proxy.service is deliberately NOT restarted: it is our own
# stdlib script, untouched by a Hermes upgrade.
# ---------------------------------------------------------------------------
if systemctl --user list-unit-files hermes-dashboard.service >/dev/null 2>&1; then
  log "restarting hermes-dashboard.service (the updater does not)"
  systemctl --user restart hermes-dashboard.service || log "WARNING: dashboard restart failed"
fi

# ---------------------------------------------------------------------------
# 4. Prove the box still works. An unattended update that silently breaks the
#    install is worse than no update at all.
# ---------------------------------------------------------------------------
VERIFY="${HOME}/hermes-install/03-verify.sh"
if [ -x "${VERIFY}" ] || [ -f "${VERIFY}" ]; then
  log "running post-update verification"
  sleep 15    # let the dashboard and gateway finish coming back
  # Tell 03-verify.sh that WE are running it. Two of its checks assert on the
  # autoupdate's own state (the timer's next elapse, and whether a previous run
  # failed); both are circular from in here — the timer has no next elapse while this
  # service is executing, and our previous outcome is what we are about to overwrite.
  # Asserting them anyway made every successful update report failure, and latched:
  # the marker we write on failure guaranteed the next run failed too. See CHANGELOG
  # 0.18.0.
  if HERMES_VERIFY_FROM_AUTOUPDATE=1 bash "${VERIFY}" 2>&1 | sed 's/^/    /'; then
    log "post-update verification PASSED"
    date -u +%Y-%m-%dT%H:%M:%SZ > "${STAMP_DIR}/last-success"
    rm -f "${STAMP_DIR}/last-failure" "${STAMP_DIR}/pending"
  else
    log "ERROR: post-update verification FAILED after updating to ${AFTER:-unknown}"
    log "the install is running new code that does not pass 03-verify.sh."
    log "triage: OPS-NOTES.md §1, rollback: OPS-NOTES.md §3"
    date -u +%Y-%m-%dT%H:%M:%SZ > "${STAMP_DIR}/last-failure"
    exit 1
  fi
else
  log "WARNING: ${VERIFY} not found — updated without verifying"
  date -u +%Y-%m-%dT%H:%M:%SZ > "${STAMP_DIR}/last-success"
fi

log "done"
