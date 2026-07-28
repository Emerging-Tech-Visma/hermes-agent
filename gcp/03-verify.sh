#!/usr/bin/env bash
# Run ON THE VM after 02-vm-install.sh. End-to-end health check.
set -uo pipefail
source "$(dirname "$0")/00-vars.sh"
export PATH="${HOME}/.local/bin:${PATH}"

pass=0; fail=0
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  OK    ${name}"; pass=$((pass+1))
  else
    echo "  FAIL  ${name}"; fail=$((fail+1))
  fi
}

echo "== Services =="
check "memory-backup.timer active"        systemctl --user is-active memory-backup.timer
if [ "${INSTALL_OPENVIKING:-false}" = "true" ]; then
  check "openviking.service active"        systemctl --user is-active openviking.service
  check "vertex-token-refresh.timer active" systemctl --user is-active vertex-token-refresh.timer
  check "OpenViking answers on :1933"       curl -sf http://localhost:1933/
fi
if [ "${MEMORY_PROVIDER:-}" = "honcho" ]; then
  check "Honcho containers running"  bash -c "sudo docker compose -f ${HOME}/honcho/docker-compose.yml ps --status running | grep -q honcho"
  check "Honcho answers on :8000"    curl -sf http://localhost:8000/
fi
if [ "${DASHBOARD_ENABLE:-false}" = "true" ]; then
  check "hermes-dashboard.service active" systemctl --user is-active hermes-dashboard.service
  check "dashboard auth gate on"          bash -c "curl -s http://localhost:${DASHBOARD_PORT:-9119}/api/status | grep -q '\"auth_required\":true'"
fi

echo "== GCP access (via attached service account) =="
check "metadata server token"  curl -sf -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"
check "GCS bucket writable"    bash -c "echo ok | gcloud storage cp - ${MEMORY_BUCKET}/.verify && gcloud storage rm ${MEMORY_BUCKET}/.verify"

echo "== Vertex AI (EU regional endpoint) =="
VMODEL="${HERMES_MODEL#google/}"          # strip provider prefix for the REST path
VHOST="${VERTEX_REGION}-aiplatform.googleapis.com"
[ "${VERTEX_REGION}" = "global" ] && VHOST="aiplatform.googleapis.com"
check "Vertex inference (${VMODEL} @ ${VERTEX_REGION})" bash -c '
  TOKEN=$(curl -sf -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)[\"access_token\"])")
  curl -sf -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    "https://'"${VHOST}"'/v1/projects/'"${PROJECT_ID}"'/locations/'"${VERTEX_REGION}"'/publishers/google/models/'"${VMODEL}"':generateContent" \
    -d "{\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"hi\"}]}]}" | grep -q candidates'
# EU-residency guard. Strict setup uses a regional European endpoint. The current
# install accepts `global` as an explicit owner exception (needed for gemini-3.6-flash /
# gemini-3.5-flash-lite, which are global-only on Vertex — see 00-vars.sh / AGENTS.md).
# Pass on europe-* OR the accepted `global`; loudly warn (don't silently pass) on global.
if [ "${VERTEX_REGION}" = "global" ]; then
  echo "  ⚠️  VERTEX_REGION=global — EU-residency relaxed (accepted exception; data not region-pinned)"
fi
check "Vertex region is European or accepted-global" bash -c '[[ "'"${VERTEX_REGION}"'" == europe-* || "'"${VERTEX_REGION}"'" == global ]]'

echo "== Hermes =="
check "hermes binary on PATH"  command -v hermes
echo
echo "Interactive checks (run these yourself):"
echo "  hermes doctor          # Vertex credentials + model"
echo "  hermes memory status   # provider: openviking"
echo "  hermes chat            # tell it a fact, restart session, ask it back"
echo
echo "Result: ${pass} passed, ${fail} failed"
exit "$((fail > 0 ? 1 : 0))"
