#!/usr/bin/env bash
# Set / reset the Hermes dashboard basic-auth credentials. Run ON THE VM.
#
#   HERMES_DASHBOARD_PASSWORD='new-pw' dashboard-setup.sh [username] [port]
#
# Idempotent by design. GOTCHA this exists to prevent: appending auth lines twice
# (or leaving a <placeholder> password) leaves MULTIPLE
# HERMES_DASHBOARD_BASIC_AUTH_* sets in .env and the wrong one wins — sign-in
# then fails with no useful error. This script strips ALL existing lines first,
# then writes exactly one clean set.
#
# Note the file is ~/.hermes/.env — NOT ~/.env.
set -euo pipefail

USERNAME="${1:-${DASHBOARD_USERNAME:-hermes}}"
PORT="${2:-${DASHBOARD_PORT:-9119}}"
ENV_FILE="${HERMES_HOME:-${HOME}/.hermes}/.env"

if [ -z "${HERMES_DASHBOARD_PASSWORD:-}" ]; then
  echo "ERROR: export HERMES_DASHBOARD_PASSWORD first." >&2
  exit 1
fi
case "${HERMES_DASHBOARD_PASSWORD}" in
  *'<'*|*'>'*|"changeme"|"password")
    echo "ERROR: that looks like a placeholder, not a real password." >&2
    exit 1 ;;
esac

mkdir -p "$(dirname "${ENV_FILE}")"
touch "${ENV_FILE}"
chmod 600 "${ENV_FILE}"

# HMAC key that signs dashboard session tokens.
#
# PRESERVE it by default. Rotating this secret invalidates every live session, so a
# routine re-run of 02-vm-install.sh (e.g. to change the model list) would silently
# log out the desktop app with "Remote gateway session has expired / Lost connection
# to the gateway" — a confusing failure that looks like a broken gateway rather than
# an intended logout. Learned the hard way 2026-07-28.
#
# Rotate deliberately with:  ROTATE_DASHBOARD_SECRET=1 dashboard-setup.sh ...
# (do that when a password may have leaked — it forces every client to re-auth).
# `|| true` is LOAD-BEARING under `set -euo pipefail`. On a FRESH install .env has no
# secret yet, so grep exits 1; `pipefail` propagates that through the pipeline, the
# command substitution inherits it, and `set -e` kills this script on its first real
# line — with NO error message, because grep's "no match" is silent. 02-vm-install.sh
# calls this with stdout on /dev/null, so the whole install died at step 8 showing
# nothing at all. Found on a from-scratch install 2026-08-18; it could not reproduce on
# an existing box, where .env already contained the line and grep succeeded.
EXISTING_SECRET="$(grep '^HERMES_DASHBOARD_BASIC_AUTH_SECRET=' "${ENV_FILE}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
if [ "${ROTATE_DASHBOARD_SECRET:-0}" = "1" ] || [ -z "${EXISTING_SECRET}" ]; then
  SECRET="$(openssl rand -base64 32)"
  if [ -n "${EXISTING_SECRET}" ]; then
    echo "Rotating session-signing secret — ALL existing sessions are now invalid."
    echo "Every client (desktop app, browser) must sign in again."
  fi
else
  SECRET="${EXISTING_SECRET}"
  echo "Preserving existing session-signing secret (live sessions stay valid)."
fi

# Strip every existing basic-auth line (the whole point of this script).
TMP="$(mktemp)"
grep -v '^HERMES_DASHBOARD_BASIC_AUTH_' "${ENV_FILE}" > "${TMP}" || true
mv "${TMP}" "${ENV_FILE}"
chmod 600 "${ENV_FILE}"

cat >> "${ENV_FILE}" <<EOF
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=${USERNAME}
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${HERMES_DASHBOARD_PASSWORD}
HERMES_DASHBOARD_BASIC_AUTH_SECRET=${SECRET}
HERMES_DASHBOARD_BASIC_AUTH_TTL_SECONDS=43200
EOF

echo "Wrote dashboard auth for user '${USERNAME}' to ${ENV_FILE}"
echo "Sessions last 12h (TTL 43200s) — periodic re-login is expected, not a fault."
echo "Note: changing the PASSWORD always requires clients to sign in again, even"
echo "though the signing secret was preserved."
echo
echo "For anything past a pilot, replace the plaintext password with a scrypt hash:"
echo "  HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=<scrypt hash>"
echo "  (then delete the HERMES_DASHBOARD_BASIC_AUTH_PASSWORD line)"

if systemctl --user is-enabled hermes-dashboard.service >/dev/null 2>&1; then
  echo
  echo "Restarting dashboard to pick up the new credentials..."
  systemctl --user restart hermes-dashboard.service
  sleep 4
  systemctl --user --no-pager status hermes-dashboard.service | head -5
fi
