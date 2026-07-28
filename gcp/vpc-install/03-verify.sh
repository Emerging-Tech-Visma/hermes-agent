#!/usr/bin/env bash
# Run ON THE VM. End-to-end health check — targets 9/9 pass.
set -uo pipefail
source "$(dirname "$0")/00-vars.sh"
export PATH="${HOME}/.local/bin:${PATH}"

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

echo "=== Hermes on GCP — verification ==========================="

# 1. Hermes CLI
if hermes version >/dev/null 2>&1; then
  ok "hermes CLI ($(hermes version 2>/dev/null | head -1))"
else
  bad "hermes CLI not on PATH"
fi

# 2. Vertex inference — must be a REAL generateContent call.
# GOTCHA: a GET on a model resource can 404 even when inference works fine.
MODEL_ID="${HERMES_MODEL#google/}"
if [ "${VERTEX_REGION}" = "global" ]; then
  VHOST="aiplatform.googleapis.com"
else
  VHOST="${VERTEX_REGION}-aiplatform.googleapis.com"
fi
TOKEN="$(curl -sf -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])' 2>/dev/null)"
if [ -n "${TOKEN}" ]; then
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
    "https://${VHOST}/v1/projects/${PROJECT_ID}/locations/${VERTEX_REGION}/publishers/google/models/${MODEL_ID}:generateContent" \
    -d '{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}')"
  [ "${CODE}" = "200" ] && ok "Vertex ${MODEL_ID} @ ${VERTEX_REGION} (HTTP 200)" \
                        || bad "Vertex ${MODEL_ID} @ ${VERTEX_REGION} returned HTTP ${CODE}"
else
  bad "could not get a token from the metadata server (is the SA attached?)"
fi

# 3. EU residency
case "${VERTEX_REGION}" in
  europe-*) ok "Vertex region is European (${VERTEX_REGION})" ;;
  global)   ok "Vertex region 'global' — WARNING: not region-pinned, EU-residency exception" ;;
  *)        bad "Vertex region ${VERTEX_REGION} is NOT European" ;;
esac

# 4. Chrome
if command -v google-chrome >/dev/null 2>&1; then
  ok "Chrome ($(google-chrome --version 2>/dev/null))"
else
  [ "${INSTALL_CHROME}" = "true" ] && bad "google-chrome missing" || ok "Chrome not requested"
fi

# 5. Playwright Chromium
if ls "${HOME}"/.cache/ms-playwright/chromium*/ >/dev/null 2>&1; then
  ok "Playwright Chromium installed"
else
  [ "${INSTALL_CHROME}" = "true" ] && bad "Playwright Chromium not found in ~/.cache/ms-playwright" \
                                   || ok "Playwright not requested"
fi

# 6. SearXNG JSON API — the format that matters to Hermes
# GET with ?format=json is the documented API shape (docs.searxng.org/dev/search_api.html:
# "/ and /search are supported for both GET and POST"). A 403 means the requested
# format is not enabled — "Requesting an unset format will return a 403 Forbidden error."
if [ "${INSTALL_SEARXNG}" = "true" ]; then
  SCODE="$(curl -s -o /dev/null -w '%{http_code}' \
    "http://localhost:${SEARXNG_PORT}/search?q=hermes+agent&format=json")"
  if [ "${SCODE}" = "200" ]; then
    # 200 only proves the format gate is open; confirm results actually come back.
    RCOUNT="$(curl -s "http://localhost:${SEARXNG_PORT}/search?q=hermes+agent&format=json" \
      | jq -r '.results | length' 2>/dev/null || echo 0)"
    if [ "${RCOUNT}" -gt 0 ] 2>/dev/null; then
      ok "SearXNG JSON API on :${SEARXNG_PORT} (200, ${RCOUNT} results)"
    else
      bad "SearXNG answers 200 but returned 0 results — upstream engines are likely blocking the Cloud NAT egress IP (see OPS-NOTES.md §4)"
    fi
  elif [ "${SCODE}" = "403" ]; then
    # Two independent gates can produce 403. Name both so nobody chases the wrong one.
    bad "SearXNG 403. Check BOTH: (a) 'json' present in search.formats, and (b) server.limiter is false — in ~/searxng/settings.yml, then restart"
  elif [ "${SCODE}" = "429" ]; then
    bad "SearXNG 429 rate-limited — set server.limiter: false in ~/searxng/settings.yml"
  else
    bad "SearXNG JSON API returned HTTP ${SCODE}"
  fi
else
  ok "SearXNG not requested"
fi

# 7. Honcho
# Try several endpoints: Honcho is FastAPI, but /docs can be disabled in production
# mode and / is not guaranteed to be routed. Any HTTP response at all proves the
# service is listening, which is what we actually care about.
if [ "${MEMORY_PROVIDER}" = "honcho" ]; then
  HONCHO_OK="no"; HONCHO_EP=""; HCODE="000"
  for ep in /health /healthz /docs /openapi.json /; do
    # NOTE: `curl -o /dev/null -w '%{http_code}'` already prints 000 on a
    # connection failure AND exits non-zero. Appending `|| echo 000` would
    # concatenate into "000000", which then compares unequal to "000" and
    # produces a FALSE PASS. Capture plainly and default only if empty.
    HCODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
      "http://localhost:${HONCHO_PORT}${ep}" 2>/dev/null)" || true
    HCODE="${HCODE:-000}"
    # Any real HTTP status (even 404) proves something is listening.
    case "${HCODE}" in
      000) ;;
      *)   HONCHO_OK="yes"; HONCHO_EP="${ep}"; break ;;
    esac
  done
  if [ "${HONCHO_OK}" = "yes" ]; then
    ok "Honcho listening on :${HONCHO_PORT} (${HONCHO_EP} -> HTTP ${HCODE})"
  else
    bad "Nothing listening on :${HONCHO_PORT} — Honcho needs its OWN LLM keys (it has no Vertex support). Fill ~/honcho/.env then: cd ~/honcho && sudo docker compose up -d"
  fi
else
  ok "Honcho not requested (provider=${MEMORY_PROVIDER})"
fi

# 8. Dashboard service
if [ "${DASHBOARD_ENABLE}" = "true" ]; then
  if systemctl --user is-active hermes-dashboard.service >/dev/null 2>&1 \
     && curl -sf -o /dev/null "http://localhost:${DASHBOARD_PORT}/"; then
    ok "hermes-dashboard.service active on :${DASHBOARD_PORT}"
  else
    bad "hermes-dashboard.service not healthy — journalctl --user -u hermes-dashboard -n 50"
  fi
else
  ok "Dashboard not requested"
fi

# 9. Linger — without this everything dies when you log out
if loginctl show-user "${USER}" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
  ok "linger enabled (services survive logout)"
else
  bad "linger DISABLED — run: sudo loginctl enable-linger ${USER}"
fi

echo "==========================================================="
echo "  ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ] || exit 1
