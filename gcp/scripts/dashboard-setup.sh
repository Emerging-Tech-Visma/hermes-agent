#!/usr/bin/env bash
# Configure (or reset) the Hermes dashboard basic-auth credentials, idempotently.
# Run ON THE VM. Fixes the two traps we hit by hand:
#   1. duplicate HERMES_DASHBOARD_BASIC_AUTH_* lines (last/first-wins ambiguity)
#   2. a leftover placeholder password silently staying active
# It strips ALL existing basic-auth lines first, then writes exactly one clean set.
#
# Usage:
#   HERMES_DASHBOARD_PASSWORD='your-password' dashboard-setup.sh [username] [port]
# Defaults: username=kennet, port=9119
set -euo pipefail

USERNAME="${1:-${DASHBOARD_USERNAME:-kennet}}"
PORT="${2:-${DASHBOARD_PORT:-9119}}"
ENV_FILE="${HOME}/.hermes/.env"
HERMES="${HOME}/.local/bin/hermes"

if [ -z "${HERMES_DASHBOARD_PASSWORD:-}" ]; then
  echo "ERROR: set HERMES_DASHBOARD_PASSWORD before running, e.g.:" >&2
  echo "  HERMES_DASHBOARD_PASSWORD='choose-a-strong-password' $0 ${USERNAME} ${PORT}" >&2
  exit 1
fi

mkdir -p "${HOME}/.hermes"
touch "${ENV_FILE}"

echo "==> Removing any existing dashboard basic-auth lines (idempotent)"
sed -i '/^HERMES_DASHBOARD_BASIC_AUTH_/d' "${ENV_FILE}"

echo "==> Writing one clean credential set for user '${USERNAME}'"
{
  echo "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=${USERNAME}"
  echo "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${HERMES_DASHBOARD_PASSWORD}"
  echo "HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(openssl rand -base64 32)"
} >> "${ENV_FILE}"

count=$(grep -c '^HERMES_DASHBOARD_BASIC_AUTH_USERNAME=' "${ENV_FILE}")
[ "${count}" = "1" ] || { echo "ERROR: expected 1 username line, found ${count}" >&2; exit 1; }
echo "    OK: exactly one credential set present"

echo "==> Restarting the dashboard"
if systemctl --user list-unit-files hermes-dashboard.service >/dev/null 2>&1 \
   && [ -f "${HOME}/.config/systemd/user/hermes-dashboard.service" ]; then
  systemctl --user restart hermes-dashboard.service
else
  "${HERMES}" dashboard --stop >/dev/null 2>&1 || true
  sleep 2
  setsid "${HERMES}" dashboard --host 0.0.0.0 --port "${PORT}" --no-open --skip-build \
    > "${HOME}/.hermes/logs/dashboard-launch.log" 2>&1 < /dev/null &
fi

sleep 6
code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT}/" || echo 000)
auth=$(curl -s "http://localhost:${PORT}/api/status" | grep -o '"auth_required":[a-z]*' || true)
echo "    dashboard http=${code}  ${auth}"
echo
echo "Sign in from the desktop app / browser (via SSH tunnel to localhost:${PORT}):"
echo "  username: ${USERNAME}"
echo "  password: (the one you just set)"
