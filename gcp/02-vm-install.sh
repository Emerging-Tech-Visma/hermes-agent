#!/usr/bin/env bash
# Run ON THE VM (as your normal user, not root) after 01-gcp-setup.sh.
# Installs Hermes + OpenViking, writes configs, and sets up systemd services.
set -euo pipefail
source "$(dirname "$0")/00-vars.sh"

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="${HOME}/openviking_workspace"

echo "==> Installing OS packages"
sudo apt-get update -qq
sudo apt-get install -y -qq git curl xz-utils build-essential python3-pip python3-venv

echo "==> Installing Hermes (installer provisions Python 3.11 via uv, Node 22, ripgrep, ffmpeg)"
if ! command -v hermes >/dev/null 2>&1 && [ ! -x "${HOME}/.local/bin/hermes" ]; then
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
fi
export PATH="${HOME}/.local/bin:${PATH}"

if [ "${INSTALL_OPENVIKING}" = "true" ]; then
  echo "==> Installing OpenViking in its own venv"
  python3 -m venv "${HOME}/.openviking-venv"
  "${HOME}/.openviking-venv/bin/pip" install --quiet --upgrade openviking "google-genai>=1.0.0"
fi

echo "==> Writing Hermes config"
mkdir -p "${HOME}/.hermes"
sed -e "s|__PROJECT_ID__|${PROJECT_ID}|g" \
    -e "s|__VERTEX_REGION__|${VERTEX_REGION}|g" \
    -e "s|__HERMES_MODEL_LITE__|${HERMES_MODEL_LITE}|g" \
    -e "s|__HERMES_MODEL__|${HERMES_MODEL}|g" \
    "${INSTALL_DIR}/configs/hermes-config.yaml" > "${HOME}/.hermes/config.yaml"
grep -q OPENVIKING_ENDPOINT "${HOME}/.hermes/.env" 2>/dev/null || \
  cat "${INSTALL_DIR}/configs/hermes.env" >> "${HOME}/.hermes/.env"

# Without OpenViking, the hourly GCS backup covers Hermes' built-in memory instead.
BACKUP_DIR="${WORKSPACE}"
[ "${INSTALL_OPENVIKING}" = "true" ] || BACKUP_DIR="${HOME}/.hermes"

if [ "${INSTALL_OPENVIKING}" = "true" ]; then
  echo "==> Writing OpenViking config"
  mkdir -p "${HOME}/.openviking" "${WORKSPACE}"
  sed -e "s|__WORKSPACE__|${WORKSPACE}|g" \
      -e "s|__PROJECT_ID__|${PROJECT_ID}|g" \
      -e "s|__EMBEDDING_MODEL__|${EMBEDDING_MODEL}|g" \
      -e "s|__HERMES_MODEL__|${HERMES_MODEL}|g" \
      "${INSTALL_DIR}/configs/ov.conf.template" > "${HOME}/.openviking/ov.conf"
fi

if [ "${MEMORY_PROVIDER}" = "honcho" ]; then
  echo "==> Installing self-hosted Honcho (Docker: FastAPI + Postgres/pgvector on :8000)"
  sudo apt-get install -y -qq docker.io docker-compose-v2
  sudo usermod -aG docker "${USER}"
  if [ ! -d "${HOME}/honcho" ]; then
    git clone --depth 1 https://github.com/plastic-labs/honcho.git "${HOME}/honcho"
    cd "${HOME}/honcho"
    cp docker-compose.yml.example docker-compose.yml
    cp .env.template .env
    echo ""
    echo "  ACTION REQUIRED: edit ~/honcho/.env and set Honcho's LLM keys"
    echo "    LLM_GEMINI_API_KEY=...   (AI Studio key — Honcho has no Vertex support)"
    echo "    LLM_OPENAI_API_KEY=...   (embeddings)"
    echo "  then run: cd ~/honcho && sudo docker compose up -d"
    cd - >/dev/null
  fi
  sed -i "s|provider: openviking|provider: honcho|" "${HOME}/.hermes/config.yaml"
  sed -e "s|__PEER_NAME__|${USER}|g" \
      "${INSTALL_DIR}/configs/honcho.json.template" > "${HOME}/.hermes/honcho.json"
  pip3 install --user --quiet --break-system-packages honcho-ai || pip3 install --user --quiet honcho-ai
elif [ "${MEMORY_PROVIDER}" = "builtin" ]; then
  echo "==> Using Hermes built-in memory (no external provider)"
  sed -i 's|provider: openviking|# provider:  # built-in memory|' "${HOME}/.hermes/config.yaml"
fi

echo "==> Installing helper scripts"
mkdir -p "${HOME}/.local/bin" "${HOME}/.hermes/logs"
for s in vertex-token-refresh.sh memory-backup.sh dashboard-setup.sh; do
  install -m 0755 "${INSTALL_DIR}/scripts/${s}" "${HOME}/.local/bin/${s}"
done

echo "==> Installing systemd units (user services)"
mkdir -p "${HOME}/.config/systemd/user"
UNITS="memory-backup.service memory-backup.timer"
[ "${DASHBOARD_ENABLE}" = "true" ] && UNITS="${UNITS} hermes-dashboard.service"
[ "${INSTALL_OPENVIKING}" = "true" ] && \
  UNITS="${UNITS} openviking.service vertex-token-refresh.service vertex-token-refresh.timer"
for u in ${UNITS}; do
  sed -e "s|__HOME__|${HOME}|g" \
      -e "s|__BUCKET__|${MEMORY_BUCKET}|g" \
      -e "s|__WORKSPACE__|${BACKUP_DIR}|g" \
      -e "s|__PORT__|${DASHBOARD_PORT}|g" \
      "${INSTALL_DIR}/systemd/${u}" > "${HOME}/.config/systemd/user/${u}"
done
sudo loginctl enable-linger "${USER}"   # keep user services running after logout
systemctl --user daemon-reload

echo "==> Starting services"
systemctl --user enable --now memory-backup.timer

if [ "${DASHBOARD_ENABLE}" = "true" ]; then
  if [ -n "${HERMES_DASHBOARD_PASSWORD:-}" ]; then
    echo "==> Configuring dashboard basic-auth (user: ${DASHBOARD_USERNAME})"
    # Idempotent: strips any old lines, writes one clean set + fresh secret.
    DASHBOARD_USERNAME="${DASHBOARD_USERNAME}" DASHBOARD_PORT="${DASHBOARD_PORT}" \
      "${HOME}/.local/bin/dashboard-setup.sh" >/dev/null || true
    systemctl --user enable --now hermes-dashboard.service
    sleep 6
    curl -sf -o /dev/null "http://localhost:${DASHBOARD_PORT}/" \
      && echo "Dashboard up on :${DASHBOARD_PORT} (reach via SSH tunnel; sign in as ${DASHBOARD_USERNAME})" \
      || echo "WARNING: dashboard not responding — check: journalctl --user -u hermes-dashboard"
  else
    echo "==> Dashboard: skipping auth setup (HERMES_DASHBOARD_PASSWORD not set)"
    echo "    Set it later on the VM with:"
    echo "      HERMES_DASHBOARD_PASSWORD='pw' dashboard-setup.sh ${DASHBOARD_USERNAME} ${DASHBOARD_PORT}"
    echo "      systemctl --user enable --now hermes-dashboard.service"
  fi
fi
if [ "${INSTALL_OPENVIKING}" = "true" ]; then
  echo "==> Priming Vertex access token for OpenViking's VLM endpoint"
  "${HOME}/.local/bin/vertex-token-refresh.sh" --no-restart
  systemctl --user enable --now openviking.service
  systemctl --user enable --now vertex-token-refresh.timer
  sleep 3
  systemctl --user --no-pager status openviking.service | head -5
  curl -sf http://localhost:1933/ >/dev/null && echo "OpenViking responding on :1933" \
    || echo "WARNING: OpenViking not responding yet — check: journalctl --user -u openviking"
fi

cat <<EOF

Install complete. Finish up interactively:
  hermes doctor            # verify Vertex credentials/model
  hermes memory status     # openviking if enabled, otherwise built-in
  hermes chat              # first conversation

For the desktop app / browser UI, open an SSH tunnel FROM YOUR MAC:
  gcloud compute ssh ${VM_NAME} --zone=${ZONE} -- -L ${DASHBOARD_PORT}:localhost:${DASHBOARD_PORT} -N -f
then sign in at http://localhost:${DASHBOARD_PORT} (user: ${DASHBOARD_USERNAME}).
See DESKTOP-SETUP.md for the full flow.

Then follow SLACK-TEAM-SETUP.md (Slack bot) and KNOWLEDGE-DATASTORE.md
(Vertex AI Search knowledge layer). Run 03-verify.sh for an end-to-end check.
EOF
