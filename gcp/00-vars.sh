#!/usr/bin/env bash
# Shared settings for the Hermes-on-GCP installation.
# Source this from the other scripts: source "$(dirname "$0")/00-vars.sh"

export PROJECT_ID="test-disco-cm"
export PROJECT_NUMBER="881765721010"
export REGION="europe-west1"
export ZONE="europe-west1-b"

export VM_NAME="hermes-agent"
export MACHINE_TYPE="e2-standard-2"
export BOOT_DISK_SIZE="50GB"

export SA_NAME="hermes-agent"
export SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

export MEMORY_BUCKET="gs://${PROJECT_ID}-hermes-memory"

# Vertex AI models.
#
# CURRENT CHOICE: the latest Gemini 3.x flash models — but they are served on Vertex
# ONLY via the `global` endpoint right now (probed 2026-07-22: gemini-3.6-flash and
# gemini-3.5-flash-lite both 200 @ global, 404 in ALL 12 European regional endpoints).
# gemini-3.5-flash remains the only 3.x flash on a regional EU endpoint (200 @ europe-west2).
#
# ⚠️  EU-RESIDENCY EXCEPTION (explicit owner decision, 2026-07-22): to run the newest
# models we use `global`, which is NOT region-pinned — this relaxes the "regional European
# endpoint only" rule. Revert to VERTEX_REGION=europe-west2 + gemini-3.5-flash for strict
# EU residency, or flip back the moment 3.6-flash/flash-lite land in an EU region (re-probe).
export VERTEX_REGION="global"
export HERMES_MODEL="google/gemini-3.6-flash"           # flagship chat model (default)
export HERMES_MODEL_LITE="google/gemini-3.5-flash-lite" # cheap/fast option, switch via `/model`
export EMBEDDING_MODEL="gemini-embedding-2-preview"   # OpenViking only; keep in-region if enabled

# Memory provider: "honcho" (self-hosted, per-user modeling — final choice),
# "openviking" (v1 stack), or "builtin" (no external provider).
# Knowledge is separate: Vertex AI Search (see KNOWLEDGE-DATASTORE.md).
export MEMORY_PROVIDER="honcho"
if [ "${MEMORY_PROVIDER}" = "openviking" ]; then
  export INSTALL_OPENVIKING="true"
else
  export INSTALL_OPENVIKING="false"
fi

# Web dashboard (remote backend for the desktop app / browser).
# Reached via SSH tunnel — the port is NEVER opened in the GCP firewall.
export DASHBOARD_ENABLE="true"
export DASHBOARD_PORT="9119"
export DASHBOARD_USERNAME="kennet"
# Password is NOT stored in this repo. Export it in your shell before running
# 02-vm-install.sh (or set it later with scripts/dashboard-setup.sh):
#   export HERMES_DASHBOARD_PASSWORD='choose-a-strong-password'
