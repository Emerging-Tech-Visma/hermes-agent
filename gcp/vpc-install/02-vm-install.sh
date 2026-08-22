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
# SELF-REPAIR before the first apt-get update. `gpg --dearmor -o` writes keyrings mode
# 0600; apt fetches as the unprivileged `_apt` user, so an 0600 keyring makes apt treat
# its repo as UNSIGNED and `apt-get update` exits 100. The nasty part is the ordering:
# whoever wrote the keyring also wrote /etc/apt/sources.list.d/*.list, so from then on
# EVERY run of this script dies here at step 1 — long before the step-4 code that
# created the mess can fix it. That makes a single failed Chrome install unrecoverable
# by re-running, which defeats this script's idempotency guarantee.
# Keyrings hold PUBLIC keys; 0644 is the correct, standard mode.
# (Observed on a from-scratch Ubuntu 26.04 install, 2026-08-18.)
for _k in /usr/share/keyrings/*.gpg; do
  [ -e "${_k}" ] || continue
  if ! sudo -u _apt /usr/bin/test -r "${_k}" 2>/dev/null; then
    echo "    repairing apt keyring unreadable by _apt: ${_k}"
    sudo chmod 0644 "${_k}"
  fi
done
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
      | sudo gpg --dearmor --yes -o /usr/share/keyrings/google-chrome.gpg
    # `--yes` because a bare `gpg --dearmor -o` on an ALREADY-EXISTING file blocks on an
    # interactive "Overwrite? (y/N)" prompt, which fails outright over a non-tty SSH
    # --command and breaks this script's idempotency on the second run.
    #
    # GOTCHA (hit on a from-scratch Ubuntu 26.04 install, 2026-08-18): `gpg --dearmor -o`
    # creates the file mode 0600 — gpg does this itself, it is NOT the umask (root's
    # umask is 0022 here). apt fetches as the unprivileged `_apt` user, which then
    # cannot read the keyring, so apt IGNORES the key and fails the repo with
    #   "The key(s) ... are ignored as the file is not readable by user '_apt'"
    #   "E: The repository ... is not signed."
    # and the whole install dies at step 4. The chmod is mandatory, not cosmetic.
    sudo chmod 0644 /usr/share/keyrings/google-chrome.gpg
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
    # `|| true`: same errexit trap as dashboard-setup.sh:43. Currently harmless because
    # this function is only ever called as an `if` condition (bash suspends errexit
    # there), but one direct call would make a missing key abort the install.
    v="$(grep -E "^${1}=" "${HOME}/honcho/.env" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    [ -n "${v}" ] || return 1
    case "${v}" in
      your-*|YOUR-*|your_*|changeme*|sk-xxx*|\<*\>|*placeholder*|*example*) return 1 ;;
    esac
    [ "${#v}" -ge 20 ] || return 1
    return 0
  }
  # --- Point Honcho at an LLM backend -------------------------------------
  # Managed block, stripped and rewritten each run so re-running is idempotent.
  apply_honcho_block() {
    python3 - "$1" <<'PY'
import pathlib, sys
env = pathlib.Path.home() / "honcho" / ".env"
block = pathlib.Path(sys.argv[1]).read_text()
lines, out, skip = env.read_text().splitlines(keepends=True), [], False
for l in lines:
    if "BEGIN hermes-managed" in l:
        skip = True
    if not skip:
        out.append(l)
    if "END hermes-managed" in l:
        skip = False
text = "".join(out).rstrip("\n") + "\n"
body = "\n".join(l for l in block.splitlines() if l.strip() and not l.lstrip().startswith("#"))
env.write_text(text + "\n# ===== BEGIN hermes-managed =====\n" + body + "\n# ===== END hermes-managed =====\n")
PY
    chmod 600 "${HOME}/honcho/.env"
  }

  if [ "${MEMORY_LLM_BACKEND}" = "vertex" ]; then
    echo "==> Honcho -> Vertex AI via local shim (no external API keys)"
    install -m 0755 "${INSTALL_DIR}/scripts/vertex-openai-proxy.py" \
      "${HOME}/.local/bin/vertex-openai-proxy.py"
    sed -e "s|__HOME__|${HOME}|g" \
        -e "s|__PROJECT_ID__|${PROJECT_ID}|g" \
        -e "s|__VERTEX_REGION__|${VERTEX_REGION}|g" \
        -e "s|__VERTEX_EMBED_LOCATION__|${VERTEX_EMBED_LOCATION}|g" \
        -e "s|__VERTEX_EMBED_DIMENSIONS__|${VERTEX_EMBED_DIMENSIONS}|g" \
        -e "s|__PROXY_PORT__|${VERTEX_PROXY_PORT}|g" \
        "${INSTALL_DIR}/systemd/vertex-openai-proxy.service" \
        > "${HOME}/.config/systemd/user/vertex-openai-proxy.service" 2>/dev/null \
      || { mkdir -p "${HOME}/.config/systemd/user"; sed -e "s|__HOME__|${HOME}|g" \
            -e "s|__PROJECT_ID__|${PROJECT_ID}|g" -e "s|__VERTEX_REGION__|${VERTEX_REGION}|g" \
            -e "s|__VERTEX_EMBED_LOCATION__|${VERTEX_EMBED_LOCATION}|g" \
            -e "s|__VERTEX_EMBED_DIMENSIONS__|${VERTEX_EMBED_DIMENSIONS}|g" \
            -e "s|__PROXY_PORT__|${VERTEX_PROXY_PORT}|g" \
            "${INSTALL_DIR}/systemd/vertex-openai-proxy.service" \
            > "${HOME}/.config/systemd/user/vertex-openai-proxy.service"; }
    systemctl --user daemon-reload
    systemctl --user enable --now vertex-openai-proxy.service
    systemctl --user restart vertex-openai-proxy.service
    sleep 3
    curl -sf -o /dev/null "http://127.0.0.1:${VERTEX_PROXY_PORT}/health" \
      && echo "    shim healthy on :${VERTEX_PROXY_PORT}" \
      || echo "    WARNING: shim not responding — journalctl --user -u vertex-openai-proxy -n 30"

    # Honcho runs in Docker and cannot reach the host's localhost. Detect the
    # compose bridge gateway; if the network doesn't exist yet, create it by
    # bringing the stack up once first.
    ${DOCKER} compose -f "${HOME}/honcho/docker-compose.yml" up -d --no-start >/dev/null 2>&1 || true
    GW="$(${DOCKER} network inspect honcho_default \
          --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)"
    [ -n "${GW}" ] || GW="172.17.0.1"   # default-bridge fallback
    echo "    containers will reach the shim at ${GW}:${VERTEX_PROXY_PORT}"
    TMP_BLOCK="$(mktemp)"
    sed -e "s|__PROXY_URL__|http://${GW}:${VERTEX_PROXY_PORT}/v1|g" \
        -e "s|__HONCHO_MODEL__|${HONCHO_MODEL}|g" \
        -e "s|__HONCHO_EMBED_MODEL__|${HONCHO_EMBED_MODEL}|g" \
        -e "s|__VERTEX_EMBED_DIMENSIONS__|${VERTEX_EMBED_DIMENSIONS}|g" \
        "${INSTALL_DIR}/configs/honcho-vertex.env" > "${TMP_BLOCK}"
    apply_honcho_block "${TMP_BLOCK}"
    rm -f "${TMP_BLOCK}"
    ( cd "${HOME}/honcho" && ${DOCKER} compose up -d )

  elif [ "${MEMORY_LLM_BACKEND}" = "gemini" ]; then
    echo "==> Honcho -> AI Studio Gemini (one key required)"
    apply_honcho_block "${INSTALL_DIR}/configs/honcho-gemini-only.env"
    if honcho_key_real LLM_GEMINI_API_KEY; then
      ( cd "${HOME}/honcho" && ${DOCKER} compose up -d )
    else
      echo "    ACTION REQUIRED: set LLM_GEMINI_API_KEY in ~/honcho/.env"
      echo "      (AI Studio key from https://aistudio.google.com/apikey)"
      echo "    then: cd ~/honcho && sudo docker compose up -d"
    fi

  elif honcho_key_real LLM_GEMINI_API_KEY && honcho_key_real LLM_OPENAI_API_KEY; then
    ( cd "${HOME}/honcho" && ${DOCKER} compose up -d )
  else
    cat <<'HONCHO'
    ACTION REQUIRED — Honcho has no LLM backend configured and cannot start.

    You reached this branch because MEMORY_LLM_BACKEND is neither "vertex" nor
    "gemini" (i.e. "manual"), so nothing pointed Honcho at a provider. Honcho has no
    Vertex transport of its own; set MEMORY_LLM_BACKEND=vertex in 00-vars.sh to route
    it through the local shim with NO external keys, or supply keys by hand below.

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
for s in dashboard-setup.sh memory-backup.sh hermes-autoupdate.sh; do
  install -m 0755 "${INSTALL_DIR}/scripts/${s}" "${HOME}/.local/bin/${s}"
done

mkdir -p "${HOME}/.config/systemd/user"
UNITS="memory-backup.service memory-backup.timer"
[ "${DASHBOARD_ENABLE}" = "true" ] && UNITS="${UNITS} hermes-dashboard.service"
[ "${AUTOUPDATE_ENABLE:-false}" = "true" ] && \
  UNITS="${UNITS} hermes-autoupdate.service hermes-autoupdate.timer"

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
      -e "s|__AUTOUPDATE_MODE__|${AUTOUPDATE_MODE:-apply}|g" \
      -e "s|__AUTOUPDATE_SCHEDULE__|${AUTOUPDATE_SCHEDULE:-Sun *-*-* 04:00:00 UTC}|g" \
      "${INSTALL_DIR}/systemd/${u}" > "${HOME}/.config/systemd/user/${u}"
done

# CRITICAL for a 24/7 service: without linger, user systemd units are killed
# when your SSH session ends. This is what keeps Hermes running after you log out.
sudo loginctl enable-linger "${USER}"
systemctl --user daemon-reload
systemctl --user enable --now memory-backup.timer

if [ "${AUTOUPDATE_ENABLE:-false}" = "true" ]; then
  # Validate the OnCalendar expression before enabling: a malformed one makes the
  # timer load but never fire, which looks identical to "updates are working".
  if systemd-analyze calendar "${AUTOUPDATE_SCHEDULE}" >/dev/null 2>&1; then
    systemctl --user enable --now hermes-autoupdate.timer
    NEXT="$(systemctl --user list-timers hermes-autoupdate.timer --no-pager 2>/dev/null | sed -n '2p')"
    echo "    weekly backend autoupdate: ${AUTOUPDATE_MODE:-apply} mode, next run:"
    echo "      ${NEXT:-（run: systemctl --user list-timers hermes-autoupdate.timer）}"
  else
    echo "    WARNING: AUTOUPDATE_SCHEDULE='${AUTOUPDATE_SCHEDULE}' is not a valid"
    echo "    systemd OnCalendar expression — timer NOT enabled. Check it with:"
    echo "      systemd-analyze calendar '${AUTOUPDATE_SCHEDULE}'"
  fi
else
  systemctl --user disable --now hermes-autoupdate.timer 2>/dev/null || true
fi

if [ "${DASHBOARD_ENABLE}" = "true" ]; then
  # If the operator didn't export a password, GENERATE one rather than leaving the
  # dashboard with auth unconfigured. Before this, forgetting the export produced an
  # install that finished "successfully" with no way to sign in — the failure only showed
  # up later, at the desktop app. (Added 2026-08-18.)
  #
  # PRESERVE an existing file. Regenerating on every run would silently rotate the
  # password and lock out the desktop app on each re-run — the same trap dashboard-setup.sh
  # already avoids for the session-signing secret.
  #
  # Charset is deliberately ALPHANUMERIC, not `openssl rand -base64`. Base64 emits `+`,
  # `/` and `=`; `+` is decoded as a SPACE by form/urlencoded parsers, so a base64
  # password can work in one client and fail in another. `tr -dc A-Za-z0-9` sidesteps that
  # whole class of problem at no real cost in entropy (32 alnum chars ≈ 190 bits).
  DASH_PW_FILE="${HOME}/.hermes-dashboard-password"
  if [ -z "${HERMES_DASHBOARD_PASSWORD:-}" ]; then
    if [ -s "${DASH_PW_FILE}" ]; then
      HERMES_DASHBOARD_PASSWORD="$(cat "${DASH_PW_FILE}")"
      echo "    reusing the existing dashboard password from ${DASH_PW_FILE}"
    else
      HERMES_DASHBOARD_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
      ( umask 077; printf '%s' "${HERMES_DASHBOARD_PASSWORD}" > "${DASH_PW_FILE}" )
      chmod 600 "${DASH_PW_FILE}"
      echo "    generated a dashboard password -> ${DASH_PW_FILE} (mode 600)"
      echo "    read it with: cat ${DASH_PW_FILE}"
    fi
    export HERMES_DASHBOARD_PASSWORD
  fi

  if [ -n "${HERMES_DASHBOARD_PASSWORD:-}" ]; then
    # Report the failure instead of dying mutely. stdout goes to /dev/null to keep the
    # install log readable, which means a non-zero exit here used to end the whole
    # install with no explanation at all (see dashboard-setup.sh:43).
    if ! DASHBOARD_USERNAME="${DASHBOARD_USERNAME}" DASHBOARD_PORT="${DASHBOARD_PORT}" \
      "${HOME}/.local/bin/dashboard-setup.sh" "${DASHBOARD_USERNAME}" "${DASHBOARD_PORT}" >/dev/null; then
      echo "ERROR: dashboard-setup.sh failed. Re-run it WITHOUT >/dev/null to see why:" >&2
      echo "  HERMES_DASHBOARD_PASSWORD='...' ~/.local/bin/dashboard-setup.sh ${DASHBOARD_USERNAME} ${DASHBOARD_PORT}" >&2
      exit 1
    fi
    systemctl --user enable --now hermes-dashboard.service
    # POLL, don't `sleep 6`. On a cold VM the dashboard needs ~30-60s before it accepts
    # connections (it starts a Python venv and warms up), so a fixed 6s wait printed
    # "WARNING: dashboard not responding" on every from-scratch install even though the
    # service came up fine seconds later — a false alarm that sends you journal-diving
    # for nothing. Measured 2026-08-18: listening but not yet answering at 6s, HTTP 302
    # by ~50s. Same retry shape as the SearXNG probe above.
    DASH_OK="no"
    for i in $(seq 1 30); do
      if curl -sf -o /dev/null --max-time 5 "http://localhost:${DASHBOARD_PORT}/"; then
        DASH_OK="yes"; break
      fi
      sleep 3
    done
    if [ "${DASH_OK}" = "yes" ]; then
      echo "    Dashboard up on :${DASHBOARD_PORT}"
    else
      echo "    WARNING: dashboard still not responding after 90s — journalctl --user -u hermes-dashboard -n 50"
      echo "    (note: user-unit logs need group systemd-journal; otherwise use"
      echo "     sudo journalctl _SYSTEMD_USER_UNIT=hermes-dashboard)"
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
    Password:   cat ~/.hermes-dashboard-password   (on the VM, mode 600)

  NOTE: an unauthenticated GET returns HTTP 302 -> /login. That is the auth gate
  working, not an error. The tunnel belongs to the shell that started it — when that
  shell exits, localhost:${DASHBOARD_PORT} stops answering until you start it again.
  Or open http://localhost:${DASHBOARD_PORT} in a browser.

Everything the agent does — shell, files, browser, search, memory — runs HERE
on the VM. Ask it to create a folder and the folder appears on this machine.
============================================================================
EOF
