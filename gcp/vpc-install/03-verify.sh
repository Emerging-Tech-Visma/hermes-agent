#!/usr/bin/env bash
# Run ON THE VM. End-to-end health check — targets 14/14 pass.
# When hermes-autoupdate.sh runs this (HERMES_VERIFY_FROM_AUTOUPDATE=1) two checks are
# SKIPPED rather than asserted, because they are about the autoupdate's own state and
# are circular from inside it: 14/0/1-or-2-skipped is a pass there. See CHANGELOG 0.18.0.
set -uo pipefail
source "$(dirname "$0")/00-vars.sh"
export PATH="${HOME}/.local/bin:${PATH}"

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP  $1"; SKIP=$((SKIP+1)); }

# Set by hermes-autoupdate.sh when it runs this script as its post-update check.
# Two checks below are about the AUTOUPDATE's own state, and asserting on them from
# inside the autoupdate is circular — see the comments at each. Standalone runs (a
# human, or `hermesctl`) still make both assertions.
FROM_AUTOUPDATE="${HERMES_VERIFY_FROM_AUTOUPDATE:-0}"

echo "=== Hermes on GCP — verification ==========================="

# 1. Hermes CLI
# `hermes version` is gone in v0.20.5+ ("invalid choice: 'version'"); --version is the
# supported form. Keep the old one as a fallback for older pinned installs.
if hermes --version >/dev/null 2>&1 || hermes version >/dev/null 2>&1; then
  ok "hermes CLI ($( { hermes --version 2>/dev/null || hermes version 2>/dev/null; } | head -1))"
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
    bad "Nothing listening on :${HONCHO_PORT} — check: sudo docker compose -f ~/honcho/docker-compose.yml ps; logs api. With MEMORY_LLM_BACKEND=vertex no API keys are needed, so a failure here is the stack, not credentials."
  fi
else
  ok "Honcho not requested (provider=${MEMORY_PROVIDER})"
fi

# 8. Dashboard service
if [ "${DASHBOARD_ENABLE}" = "true" ]; then
  # Retry rather than probe once: run straight after 02-vm-install.sh the dashboard can
  # be `active` and even LISTENING while still not answering (verified 2026-08-18 — a
  # single probe at ~6s got HTTP 000, the same endpoint returned 302 shortly after).
  # A one-shot check here reports a false FAIL on a perfectly good install.
  DASH_CODE="000"
  for i in $(seq 1 10); do
    DASH_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
      "http://localhost:${DASHBOARD_PORT}/" 2>/dev/null)"
    DASH_CODE="${DASH_CODE:-000}"
    [ "${DASH_CODE}" != "000" ] && break
    sleep 3
  done
  if systemctl --user is-active hermes-dashboard.service >/dev/null 2>&1 \
     && [ "${DASH_CODE}" != "000" ]; then
    # 302 = redirect to the login form, i.e. the auth gate is engaged. That is the
    # expected unauthenticated response, not a fault.
    ok "hermes-dashboard.service active on :${DASHBOARD_PORT} (unauthenticated -> HTTP ${DASH_CODE})"
  else
    bad "hermes-dashboard.service not healthy (HTTP ${DASH_CODE}) — sudo journalctl _SYSTEMD_USER_UNIT=hermes-dashboard -n 50"
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

# 10. Gateway service — separate unit from the dashboard. Cron/routines and any
# messaging bot need it; the desktop app does NOT, so a dead gateway is invisible
# from the UI. See OPS-NOTES.md §2 for idle-gateway recovery.
if [ "${GATEWAY_ENABLE}" = "true" ]; then
  if systemctl --user is-active hermes-gateway.service >/dev/null 2>&1; then
    ok "hermes-gateway.service active"
  else
    bad "hermes-gateway.service not active — journalctl --user -u hermes-gateway -n 50"
  fi
else
  ok "Gateway not requested"
fi

# 11. Vertex shim — CHAT. Not just /health: a 200 on /health only proves the
# process is up. This asserts the shim returns NON-EMPTY content for HONCHO_MODEL.
#
# WHY THIS TEST EXISTS: it proves the shim's auth injection and Vertex plumbing work
# for HONCHO_MODEL, which test 7 (port liveness) cannot tell you.
#
# ⚠️  WHAT IT CANNOT CATCH: this is a SINGLE-SHOT completion, so it passes happily with
# a model that breaks Honcho's multi-iteration tool loop. Verified 2026-08-18:
# gemini-3.5-flash PASSES here and still 400s every real dialectic
# ("Function call is missing a thought_signature"). Test 13 is the one that catches
# that. Keep both.
if [ "${MEMORY_PROVIDER}" = "honcho" ] && [ "${MEMORY_LLM_BACKEND}" = "vertex" ]; then
  SHIM_OUT="$(curl -s --max-time 90 -X POST \
    "http://127.0.0.1:${VERTEX_PROXY_PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${HONCHO_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word OK\"}],\"max_tokens\":512}" 2>/dev/null)"
  SHIM_CONTENT="$(printf '%s' "${SHIM_OUT}" | jq -r '.choices[0].message.content // ""' 2>/dev/null)"
  SHIM_FINISH="$(printf '%s' "${SHIM_OUT}" | jq -r '.choices[0].finish_reason // "?"' 2>/dev/null)"
  if [ -n "${SHIM_CONTENT}" ]; then
    ok "shim chat ${HONCHO_MODEL} -> non-empty content (finish=${SHIM_FINISH})"
  elif [ "${SHIM_FINISH}" = "length" ]; then
    bad "shim chat ${HONCHO_MODEL} returned EMPTY content, finish_reason=length — the model burned its whole budget on reasoning tokens. Honcho extraction will silently produce nothing. Pin HONCHO_MODEL to google/gemini-2.5-flash in 00-vars.sh."
  else
    bad "shim chat ${HONCHO_MODEL} failed: $(printf '%s' "${SHIM_OUT}" | head -c 300)"
  fi
else
  ok "Vertex shim not requested (memory backend=${MEMORY_LLM_BACKEND})"
fi

# 12. Vertex shim — EMBEDDINGS, with a DIMENSION assertion.
# This path is a workaround for a genuinely broken upstream (Vertex's OpenAI-compat
# /embeddings returns HTTP 500 for every model), so it must be tested, not assumed.
# The vector width MUST equal Honcho's pgvector column (EMBEDDING_VECTOR_DIMENSIONS)
# or every insert fails on a dimension mismatch — invisible from any liveness check.
if [ "${MEMORY_PROVIDER}" = "honcho" ] && [ "${MEMORY_LLM_BACKEND}" = "vertex" ]; then
  EMB_LEN="$(curl -s --max-time 60 -X POST \
    "http://127.0.0.1:${VERTEX_PROXY_PORT}/v1/embeddings" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${HONCHO_EMBED_MODEL}\",\"input\":\"hermes dimension probe\"}" 2>/dev/null \
    | jq -r '.data[0].embedding | length' 2>/dev/null)"
  if [ "${EMB_LEN}" = "${VERTEX_EMBED_DIMENSIONS}" ]; then
    ok "shim embeddings ${HONCHO_EMBED_MODEL} -> ${EMB_LEN} dims (matches pgvector column)"
  elif [ -n "${EMB_LEN}" ] && [ "${EMB_LEN}" != "null" ] && [ "${EMB_LEN}" != "0" ]; then
    bad "shim embeddings returned ${EMB_LEN} dims but Honcho's column is ${VERTEX_EMBED_DIMENSIONS} — every pgvector insert will fail. Fix VERTEX_EMBED_DIMENSIONS in 00-vars.sh (must match EMBEDDING_VECTOR_DIMENSIONS in ~/honcho/.env) and re-run 02-vm-install.sh."
  else
    bad "shim embeddings returned no vector — journalctl --user -u vertex-openai-proxy -n 30"
  fi
else
  ok "Embeddings shim not requested"
fi

# 13. Honcho END-TO-END — seed a fact, then ask for it back.
#
# THE MOST IMPORTANT HONCHO CHECK, and the only one that exercises the multi-iteration
# tool loop. Tests 7 and 11 both PASS on a configuration whose dialectic is completely
# dead: gemini-3.5-flash answers a single-shot shim completion fine, then 400s on every
# real query because Gemini 3.x attaches a `thought_signature` to function calls that
# Honcho's OpenAI client drops on the next iteration (verified 2026-08-18). Anyone
# changing HONCHO_MODEL needs this check, or they get a green run and no memory.
#
# Deliberately asserts on the DIALECTIC answer only, not on the derived representation:
# see the deriver known-issue note in AGENTS.md. Uses its own throwaway workspace.
if [ "${MEMORY_PROVIDER}" = "honcho" ]; then
  HV_WS="hermes-verify"
  HV="http://localhost:${HONCHO_PORT}/v3/workspaces"
  HV_JSON='Content-Type: application/json'
  HV_FACT="Gustav"          # distinctive token we look for coming back out
  curl -s --max-time 20 -X POST "${HV}" -H "${HV_JSON}" \
    -d "{\"id\":\"${HV_WS}\"}" >/dev/null 2>&1
  curl -s --max-time 20 -X POST "${HV}/${HV_WS}/peers" -H "${HV_JSON}" \
    -d '{"id":"verify-peer"}' >/dev/null 2>&1
  curl -s --max-time 20 -X POST "${HV}/${HV_WS}/sessions" -H "${HV_JSON}" \
    -d '{"id":"verify-session"}' >/dev/null 2>&1
  curl -s --max-time 30 -X POST "${HV}/${HV_WS}/sessions/verify-session/messages" \
    -H "${HV_JSON}" \
    -d "{\"messages\":[{\"peer_id\":\"verify-peer\",\"content\":\"I keep a pet tortoise called ${HV_FACT} and I always use Bun for TypeScript.\"}]}" \
    >/dev/null 2>&1

  HV_ANS="$(curl -s --max-time 180 -X POST "${HV}/${HV_WS}/peers/verify-peer/chat" \
    -H "${HV_JSON}" -d '{"query":"What pet does this user have, and what is its name?"}' 2>/dev/null)"
  HV_CONTENT="$(printf '%s' "${HV_ANS}" | jq -r '.content // .answer // ""' 2>/dev/null)"

  if printf '%s' "${HV_CONTENT}" | grep -qi "${HV_FACT}"; then
    ok "Honcho end-to-end: dialectic recalled the seeded fact ('${HV_FACT}')"
  elif [ -n "${HV_CONTENT}" ]; then
    bad "Honcho dialectic answered but WITHOUT the seeded fact — retrieval/derivation is not working. Answer: $(printf '%s' "${HV_CONTENT}" | head -c 200)"
  else
    # Surface the upstream error verbatim; the thought_signature 400 is self-describing.
    bad "Honcho dialectic returned NO answer. If the error mentions 'thought_signature', HONCHO_MODEL is a Gemini 3.x model and MUST be changed to google/gemini-2.5-flash (see 00-vars.sh). Raw: $(printf '%s' "${HV_ANS}" | head -c 300)"
  fi
else
  ok "Honcho end-to-end not applicable (provider=${MEMORY_PROVIDER})"
fi

# 14. Weekly autoupdate timer. A timer that loads but never fires is
# indistinguishable from "updates are working", so assert NextElapse exists
# rather than just that the unit is enabled.
if [ "${AUTOUPDATE_ENABLE:-false}" = "true" ]; then
  if systemctl --user is-active hermes-autoupdate.timer >/dev/null 2>&1; then
    NEXT="$(systemctl --user show hermes-autoupdate.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
    if [ -n "${NEXT}" ] && [ "${NEXT}" != "0" ] && [ "${NEXT}" != "n/a" ]; then
      WHEN="$(systemctl --user list-timers hermes-autoupdate.timer --no-pager 2>/dev/null | sed -n '2p' | awk '{print $1, $2, $3}')"
      ok "autoupdate timer armed (${AUTOUPDATE_MODE:-apply} mode, next ${WHEN:-scheduled})"
    else
      # While hermes-autoupdate.service is EXECUTING, its own timer legitimately has
      # no next elapse — so this assertion is guaranteed to fail when the updater runs
      # us, and says nothing about the install. It made every successful update report
      # failure. Assert it only on a standalone run.
      if [ "${FROM_AUTOUPDATE}" = "1" ]; then
        skip "autoupdate timer next-elapse (not assertable from inside the update run)"
      else
        bad "hermes-autoupdate.timer is active but has NO next elapse — check AUTOUPDATE_SCHEDULE with: systemd-analyze calendar '${AUTOUPDATE_SCHEDULE:-}'"
      fi
    fi
  else
    bad "hermes-autoupdate.timer not active — run: systemctl --user enable --now hermes-autoupdate.timer"
  fi
  # Surface a previous failed run rather than letting it rot silently — but NOT when the
  # updater is running us. THE LATCH: the updater writes last-failure when this script
  # fails, so once any run failed, every later run failed on that marker alone, wrote the
  # marker again, and never reached the `rm -f last-failure` that a success performs. One
  # bad Sunday disabled the check permanently while the updates themselves kept working.
  # Note a timestamp comparison does NOT break this — last-failure is always newer than
  # last-success once latched. The updater is about to record this run's own outcome, so
  # its prior outcome is not evidence about the install.
  if [ -f "${HOME}/.hermes/autoupdate/last-failure" ]; then
    if [ "${FROM_AUTOUPDATE}" = "1" ]; then
      skip "previous autoupdate outcome (this run is about to replace it)"
    else
      bad "a previous autoupdate FAILED at $(cat "${HOME}/.hermes/autoupdate/last-failure") — journalctl --user -u hermes-autoupdate"
    fi
  fi
else
  ok "autoupdate not requested (AUTOUPDATE_ENABLE=${AUTOUPDATE_ENABLE:-false})"
fi

echo "==========================================================="
if [ "${SKIP}" -gt 0 ]; then
  echo "  ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
else
  echo "  ${PASS} passed, ${FAIL} failed"
fi
[ "${FAIL}" -eq 0 ] || exit 1
