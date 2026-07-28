#!/usr/bin/env bash
# Run ON THE VM (as your normal user, NOT root), after 01-gcp-setup.sh.
#
#   export HERMES_DASHBOARD_PASSWORD='choose-a-strong-password'
#   bash ~/hermes-install/02-vm-install.sh
#
# Installs the full stack: Hermes, Chrome + Playwright, SearXNG, Honcho,
# dashboard + gateway systemd services, hourly GCS backup.
# Idempotent — safe to re-run.
set -euo pipefail
source "$(dirname "$0")/00-vars.sh"

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" = "0" ]; then
  echo "ERROR: run as your normal user, not root. Hermes lives in \$HOME." >&2
  exit 1
fi

echo "############################################################"
echo "# 1/8  OS packages"
echo "############################################################"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  git curl wget unzip jq xz-utils build-essential ca-certificates gnupg \
  python3-pip python3-venv python3-dev \
  ripgrep ffmpeg lsof net-tools rsync

echo "############################################################"
echo "# 2/8  Docker (for SearXNG + Honcho)"
echo "############################################################"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io docker-compose-v2
sudo systemctl enable --now docker
sudo usermod -aG docker "${USER}"
# The group change does not apply to this shell. Use `sudo docker` below rather
# than requiring a re-login mid-install.
DOCKER="sudo docker"

echo "############################################################"
echo "# 3/8  Hermes"
echo "############################################################"
if ! command -v hermes >/dev/null 2>&1 && [ ! -x "${HOME}/.local/bin/hermes" ]; then
  # The installer provisions its own Python 3.11 via uv, plus Node.
  # --skip-browser: we install Chrome + Playwright ourselves in step 4.
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-browser
else
  echo "    already installed — skipping (use \`hermes update\` to upgrade)"
fi
export PATH="${HOME}/.local/bin:${PATH}"
hermes version || { echo "ERROR: hermes not on PATH after install" >&2; exit 1; }

echo "############################################################"
echo "# 4/8  Chrome + Playwright"
echo "############################################################"
if [ "${INSTALL_CHROME}" = "true" ]; then
  if ! command -v google-chrome >/dev/null 2>&1; then
    echo "==> Installing google-chrome-stable from Google's apt repo"
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
      | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
      | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq google-chrome-stable
  else
    echo "    google-chrome already present"
  fi
  google-chrome --version || true

  echo "==> Installing Playwright Chromium + OS deps"
  # `--with-deps` lets Playwright resolve the right libasound/libatk package
  # names for this Ubuntu release instead of us hardcoding them (they differ
  # between 22.04/24.04/26.04 — e.g. libasound2 vs libasound2t64).
  #
  # GOTCHA: on a brand-new Ubuntu (26.04) Playwright may refuse with
  # "Unsupported host platform". PLAYWRIGHT_HOST_PLATFORM_OVERRIDE makes it
  # install the 24.04 build, which works. Only used as a fallback.
  if ! npx --yes playwright install --with-deps chromium 2>/dev/null; then
    echo "    Playwright rejected this OS version — retrying with platform override"
    PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64 \
      npx --yes playwright install --with-deps chromium
  fi
fi

echo "############################################################"
echo "# 5/8  SearXNG (self-hosted search, localhost:${SEARXNG_PORT})"
echo "############################################################"
if [ "${INSTALL_SEARXNG}" = "true" ]; then
  mkdir -p "${HOME}/searxng"
  sed -e "s|__SEARXNG_PORT__|${SEARXNG_PORT}|g" \
    "${INSTALL_DIR}/configs/searxng-docker-compose.yml" > "${HOME}/searxng/docker-compose.yml"

  if [ ! -f "${HOME}/searxng/settings.yml" ]; then
    SEARXNG_SECRET="$(openssl rand -hex 32)"
    sed -e "s|__SEARXNG_SECRET__|${SEARXNG_SECRET}|g" \
      "${INSTALL_DIR}/configs/searxng-settings.yml" > "${HOME}/searxng/settings.yml"
    chmod 600 "${HOME}/searxng/settings.yml"
    echo "    generated a fresh secret_key"
  else
    echo "    settings.yml already exists — keeping existing secret_key"
  fi

  ( cd "${HOME}/searxng" && ${DOCKER} compose up -d )
  echo "==> Waiting for SearXNG to answer JSON..."
  SEARX_OK="no"
  for i in $(seq 1 30); do
    if curl -sf "http://localhost:${SEARXNG_PORT}/search?q=test&format=json" >/dev/null 2>&1; then
      SEARX_OK="yes"; break
    fi
    sleep 3
  done
  if [ "${SEARX_OK}" = "yes" ]; then
    echo "    SearXNG JSON API responding on :${SEARXNG_PORT}"
  else
    SCODE="$(curl -s -o /dev/null -w '%{http_code}' \
      "http://localhost:${SEARXNG_PORT}/search?q=test&format=json" 2>/dev/null || echo 000)"
    echo "    WARNING: SearXNG JSON probe returned HTTP ${SCODE}."
    case "${SCODE}" in
      403) echo "    403 = a gate is closed. Check BOTH in ~/searxng/settings.yml:"
           echo "         (a) 'json' listed under search.formats"
           echo "         (b) server.limiter: false" ;;
      429) echo "    429 = rate-limited. Set server.limiter: false in ~/searxng/settings.yml" ;;
      000) echo "    No response at all — the container may still be starting." ;;
      *)   echo "    Unexpected status; inspect the logs." ;;
    esac
    echo "    Logs: ${DOCKER} compose -f ${HOME}/searxng/docker-compose.yml logs searxng"
    echo "    (Not fatal — the rest of the install continues.)"
  fi
fi

echo "############################################################"
echo "# 6/8  Hermes configuration"
echo "############################################################"
mkdir -p "${HOME}/.hermes" "${HOME}/.hermes/logs"

# Translate the memory provider to what Hermes actually accepts. Its config
# default is `provider: ""` and the comment in hermes_cli/config.py reads
# "empty = built-in only" — there is NO provider named "builtin", so writing that
# literal would name a plugin that does not exist.
case "${MEMORY_PROVIDER}" in
  builtin|none|off|"") MEMORY_PROVIDER_CFG='""' ;;
  *)                   MEMORY_PROVIDER_CFG="${MEMORY_PROVIDER}" ;;
esac

# Build the providers.vertex.models YAML list from HERMES_MODELS (space-separated).
# Done as a generated block rather than fixed placeholders so adding/removing a
# model is a one-line change in 00-vars.sh.
# Split explicitly into an array rather than relying on unquoted word-splitting:
# this file is bash, but if anyone sources it from zsh (the default macOS shell)
# `for m in ${VAR}` does NOT split and you silently get one giant model name.
read -r -a HERMES_MODEL_ARR <<< "${HERMES_MODELS}"
if [ "${#HERMES_MODEL_ARR[@]}" -eq 0 ]; then
  echo "ERROR: HERMES_MODELS is empty in 00-vars.sh" >&2; exit 1
fi
# printf, not "$'\n'" concatenation — portable and avoids the literal-\n trap.
MODEL_LIST_YAML="$(printf '      - %s\n' "${HERMES_MODEL_ARR[@]}")"

# Sanity: the default model must appear in the catalog, or the picker shows a list
# that excludes what is actually running.
MODEL_IN_CATALOG="no"
for m in "${HERMES_MODEL_ARR[@]}"; do
  [ "${m}" = "${HERMES_MODEL}" ] && MODEL_IN_CATALOG="yes"
done
if [ "${MODEL_IN_CATALOG}" != "yes" ]; then
  echo "ERROR: HERMES_MODEL (${HERMES_MODEL}) is not listed in HERMES_MODELS" >&2
  exit 1
fi
echo "    models: ${#HERMES_MODEL_ARR[@]} declared, default ${HERMES_MODEL}, region ${VERTEX_REGION}"

# config.yaml — Vertex provider, model catalog, searxng backend, local terminal.
# sed handles the single-line tokens; python3 expands the multi-line model block.
#
# NOTE: do NOT use `awk -v repl="$MULTILINE"` here. BSD/macOS awk rejects embedded
# newlines in -v assignments ("awk: newline in string"), so it works on the Ubuntu
# VM (GNU awk) and breaks for anyone cloning this on a Mac. python3 is guaranteed
# on both and needs no quoting gymnastics.
sed -e "s|__PROJECT_ID__|${PROJECT_ID}|g" \
    -e "s|__VERTEX_REGION__|${VERTEX_REGION}|g" \
    -e "s|__HERMES_MODEL__|${HERMES_MODEL}|g" \
    -e "s|__WEB_BACKEND__|${WEB_BACKEND}|g" \
    -e "s|__MEMORY_PROVIDER__|${MEMORY_PROVIDER_CFG}|g" \
    "${INSTALL_DIR}/configs/hermes-config.yaml" \
  | MODEL_LIST_YAML="${MODEL_LIST_YAML}" python3 -c '
import os, sys
# rstrip+newline: command substitution strips the trailing newline from the block,
# so re-add exactly one to keep the YAML indentation intact.
block = os.environ["MODEL_LIST_YAML"].rstrip("\n") + "\n"
for line in sys.stdin:
    sys.stdout.write(block if "__VERTEX_MODEL_LIST__" in line else line)
' > "${HOME}/.hermes/config.yaml"

# .env — non-secret pointers. Written idempotently: strip our managed keys, re-add.
touch "${HOME}/.hermes/.env"
chmod 600 "${HOME}/.hermes/.env"
TMP_ENV="$(mktemp)"
grep -vE '^(SEARXNG_URL|HONCHO_BASE_URL|GOOGLE_CLOUD_PROJECT|GOOGLE_CLOUD_LOCATION|HERMES_AGENT_TIMEOUT|HERMES_STREAM_READ_TIMEOUT)=' \
  "${HOME}/.hermes/.env" > "${TMP_ENV}" || true
mv "${TMP_ENV}" "${HOME}/.hermes/.env"
sed -e "s|__SEARXNG_PORT__|${SEARXNG_PORT}|g" \
    -e "s|__HONCHO_PORT__|${HONCHO_PORT}|g" \
    -e "s|__PROJECT_ID__|${PROJECT_ID}|g" \
    -e "s|__VERTEX_REGION__|${VERTEX_REGION}|g" \
    -e "s|__HERMES_AGENT_TIMEOUT__|${HERMES_AGENT_TIMEOUT}|g" \
    "${INSTALL_DIR}/configs/hermes.env" >> "${HOME}/.hermes/.env"
chmod 600 "${HOME}/.hermes/.env"

echo "############################################################"
echo "# 7/8  Honcho memory (localhost:${HONCHO_PORT})"
echo "############################################################"
if [ "${MEMORY_PROVIDER}" = "honcho" ]; then
  if [ ! -d "${HOME}/honcho" ]; then
    git clone --depth 1 https://github.com/plastic-labs/honcho.git "${HOME}/honcho"
    ( cd "${HOME}/honcho" && cp docker-compose.yml.example docker-compose.yml && cp .env.template .env )
    chmod 600 "${HOME}/honcho/.env"
  fi
  # restart policy so Honcho survives VM reboots (this is a 24/7 service).
  grep -q 'restart:' "${HOME}/honcho/docker-compose.yml" 2>/dev/null || \
    echo "    NOTE: consider adding 'restart: unless-stopped' to ~/honcho/docker-compose.yml"

  # Both keys must be REAL, not the shipped placeholders. `.env.template` ships
  # non-empty dummy values like `your-openai-key`, so a plain `=.+` test reports a
  # false "configured" and Honcho then fails to start with a confusing error.
  # Treat a value as unset if it is empty, still matches the template, or looks
  # like a placeholder.
  honcho_key_real() {
    local v
    v="$(grep -E "^${1}=" "${HOME}/honcho/.env" 2>/dev/null | head -1 | cut -d= -f2-)"
    [ -n "${v}" ] || return 1
    case "${v}" in
      your-*|YOUR-*|your_*|changeme*|sk-xxx*|\<*\>|*placeholder*|*example*) return 1 ;;
    esac
    [ "${#v}" -ge 20 ] || return 1
    return 0
  }
  if honcho_key_real LLM_GEMINI_API_KEY && honcho_key_real LLM_OPENAI_API_KEY; then
    ( cd "${HOME}/honcho" && ${DOCKER} compose up -d )
  else
    cat <<'HONCHO'
    ACTION REQUIRED — Honcho needs its own LLM keys and cannot start without them.

    Honcho does its background user-modelling with its OWN provider config and has
    NO Vertex support, so it needs an AI Studio Gemini key + an OpenAI embeddings
    key. This is the one piece not billed through your GCP project.

      nano ~/honcho/.env
        LLM_GEMINI_API_KEY=...    # https://aistudio.google.com/apikey
        LLM_OPENAI_API_KEY=...    # embeddings
      cd ~/honcho && sudo docker compose up -d

    Hermes is already pointed at it (HONCHO_BASE_URL in ~/.hermes/.env).
HONCHO
  fi
fi

echo "############################################################"
echo "# 8/8  Services"
echo "############################################################"
mkdir -p "${HOME}/.local/bin"
for s in dashboard-setup.sh memory-backup.sh; do
  install -m 0755 "${INSTALL_DIR}/scripts/${s}" "${HOME}/.local/bin/${s}"
done

mkdir -p "${HOME}/.config/systemd/user"
UNITS="memory-backup.service memory-backup.timer"
[ "${DASHBOARD_ENABLE}" = "true" ] && UNITS="${UNITS} hermes-dashboard.service"

# Gateway unit: PREFER the one the Hermes installer generates. Verified 2026-07-28 —
# the installer's unit is strictly better than our template: it encodes Hermes'
# own restart semantics (RestartForceExitStatus=75, RestartPreventExitStatus=78),
# KillMode=mixed, SIGUSR1 ExecReload, a cgroup-cleanup ExecStopPost, and the venv
# PATH/VIRTUAL_ENV. Ours is only a fallback for when the installer didn't make one.
GATEWAY_UNIT="${HOME}/.config/systemd/user/hermes-gateway.service"
if [ "${GATEWAY_ENABLE}" = "true" ]; then
  if [ -f "${GATEWAY_UNIT}" ] && grep -q 'hermes_cli.main gateway run' "${GATEWAY_UNIT}" 2>/dev/null; then
    echo "    gateway unit: keeping the Hermes installer's own unit (preferred)"
  elif [ -f "${GATEWAY_UNIT}" ]; then
    echo "    gateway unit: existing unit found — leaving it alone"
  else
    echo "    gateway unit: none found, asking Hermes to generate one"
    if ! hermes gateway install >/dev/null 2>&1; then
      echo "    'hermes gateway install' unavailable — falling back to our template"
      UNITS="${UNITS} hermes-gateway.service"
    fi
  fi
fi

for u in ${UNITS}; do
  sed -e "s|__HOME__|${HOME}|g" \
      -e "s|__BUCKET__|${MEMORY_BUCKET}|g" \
      -e "s|__WORKSPACE__|${HOME}/.hermes|g" \
      -e "s|__PORT__|${DASHBOARD_PORT}|g" \
      "${INSTALL_DIR}/systemd/${u}" > "${HOME}/.config/systemd/user/${u}"
done

# CRITICAL for a 24/7 service: without linger, user systemd units are killed
# when your SSH session ends. This is what keeps Hermes running after you log out.
sudo loginctl enable-linger "${USER}"
systemctl --user daemon-reload
systemctl --user enable --now memory-backup.timer

if [ "${DASHBOARD_ENABLE}" = "true" ]; then
  if [ -n "${HERMES_DASHBOARD_PASSWORD:-}" ]; then
    DASHBOARD_USERNAME="${DASHBOARD_USERNAME}" DASHBOARD_PORT="${DASHBOARD_PORT}" \
      "${HOME}/.local/bin/dashboard-setup.sh" "${DASHBOARD_USERNAME}" "${DASHBOARD_PORT}" >/dev/null
    systemctl --user enable --now hermes-dashboard.service
    sleep 6
    if curl -sf -o /dev/null "http://localhost:${DASHBOARD_PORT}/"; then
      echo "    Dashboard up on :${DASHBOARD_PORT}"
    else
      echo "    WARNING: dashboard not responding — journalctl --user -u hermes-dashboard -n 50"
    fi
  else
    echo "    HERMES_DASHBOARD_PASSWORD not set — dashboard auth NOT configured."
    echo "    Set it now with:"
    echo "      HERMES_DASHBOARD_PASSWORD='pw' dashboard-setup.sh ${DASHBOARD_USERNAME} ${DASHBOARD_PORT}"
    echo "      systemctl --user enable --now hermes-dashboard.service"
  fi
fi

if [ "${GATEWAY_ENABLE}" = "true" ]; then
  systemctl --user enable --now hermes-gateway.service
  sleep 3
  systemctl --user --no-pager status hermes-gateway.service | head -5 || true
fi

cat <<EOF

============================================================================
Install complete. Verify:

  bash ~/hermes-install/03-verify.sh

Then, FROM YOUR PC, open the secure gateway and connect the desktop app:

  gcloud compute start-iap-tunnel ${VM_NAME} ${DASHBOARD_PORT} \\
    --local-host-port=localhost:${DASHBOARD_PORT} \\
    --zone=${ZONE} --project=${PROJECT_ID}

  Desktop app -> Settings -> Gateway -> Remote gateway
    URL: http://localhost:${DASHBOARD_PORT}
    Sign in as: ${DASHBOARD_USERNAME}
  Or open http://localhost:${DASHBOARD_PORT} in a browser.

Everything the agent does — shell, files, browser, search, memory — runs HERE
on the VM. Ask it to create a folder and the folder appears on this machine.
============================================================================
EOF
