#!/usr/bin/env bash
# Shared settings for the Hermes-on-GCP "private VPC + IAP gateway" installation.
# Source this from the other scripts: source "$(dirname "$0")/00-vars.sh"
#
# THIS IS THE ONLY FILE YOU EDIT when cloning the setup for a new team/company.

# ---------------------------------------------------------------------------
# GCP project
# ---------------------------------------------------------------------------
export PROJECT_ID="test-disco-cm"
export PROJECT_NUMBER="881765721010"

# Region for INFRASTRUCTURE — VM, subnet, GCS bucket, backups.
# Stays europe-west2 (London) so all DATA AT REST remains in a European region.
# Note west2 = UK, not an EU member state (covered by UK adequacy).
export REGION="europe-west2"
export ZONE="europe-west2-b"

# ---------------------------------------------------------------------------
# Network (private VPC — no public IP anywhere)
# ---------------------------------------------------------------------------
export VPC_NAME="hermes-vpc"
export SUBNET_NAME="hermes-subnet"
export SUBNET_RANGE="10.10.0.0/24"
export ROUTER_NAME="hermes-router"
export NAT_NAME="hermes-nat"
export NET_TAG="hermes-agent"          # firewall target tag

# Google's IAP TCP-forwarding source range. This is the ONLY ingress source
# allowed by the firewall rules. It is NOT the public internet — it is Google's
# IAP frontend, and who may use it is gated by IAM (roles/iap.tunnelResourceAccessor).
export IAP_RANGE="35.235.240.0/20"

# ---------------------------------------------------------------------------
# VM
# ---------------------------------------------------------------------------
export VM_NAME="hermes-agent"
# 4 vCPU / 16 GB: Hermes + Chrome/Playwright + Postgres/pgvector (Honcho)
# + SearXNG + Valkey all run on this one box. e2-standard-2 is not enough.
export MACHINE_TYPE="e2-standard-4"
export BOOT_DISK_SIZE="100GB"
# Ubuntu 26.04 LTS — the latest LTS image family in GCP (verified 2026-07-28).
# Playwright may not recognise 26.04; 02-vm-install.sh falls back to
# PLAYWRIGHT_HOST_PLATFORM_OVERRIDE automatically.
export IMAGE_FAMILY="ubuntu-2604-lts-amd64"
export IMAGE_PROJECT="ubuntu-os-cloud"

# ---------------------------------------------------------------------------
# Service account (no key files — the VM uses its attached SA via ADC)
# ---------------------------------------------------------------------------
export SA_NAME="hermes-agent"
export SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

export MEMORY_BUCKET="gs://${PROJECT_ID}-hermes-memory"

# ---------------------------------------------------------------------------
# Vertex AI models
# ---------------------------------------------------------------------------
# ⚠️  EU-RESIDENCY EXCEPTION — INFERENCE ONLY (owner decision, re-affirmed 2026-07-28)
#
# VERTEX_REGION is `global`, which is NOT region-pinned. This is a deliberate,
# owner-approved relaxation of the "European regional endpoint only" rule, taken to
# run the three latest Gemini flash models. Everything else — VM, subnet, GCS
# bucket, backups, SearXNG, Honcho — stays in europe-west2, so DATA AT REST
# REMAINS IN A EUROPEAN REGION. Only the inference endpoint is non-region-pinned.
#
# Why it is unavoidable for these models. Re-probed 2026-07-28
# (`:generateContent` POST, HTTP status):
#
#   MODEL                    | eu-w1 | eu-w2 | eu-w3 | eu-w4 | eu-n1 | global
#   gemini-3.6-flash         |  404  |  404  |  404  |  404  |  404  |  200
#   gemini-3.5-flash         |  404  |  200  |   -   |  404  |   -   |  200
#   gemini-3.5-flash-lite    |  404  |  404  |   -   |   -   |   -   |  200
#
# No European regional endpoint serves 3.6-flash or 3.5-flash-lite. Only
# gemini-3.5-flash is available regionally, at europe-west2.
#
# TO REVERT to strict regional-EU inference:
#   VERTEX_REGION="europe-west2"  +  HERMES_MODELS="google/gemini-3.5-flash google/gemini-2.5-flash"
# and re-probe — flip back to a regional endpoint the moment 3.6-flash and
# flash-lite land in a European region. 03-verify.sh prints a residency warning
# whenever `global` is in use.
export VERTEX_REGION="global"

# The three latest Gemini flash models. The FIRST entry is the default; all are
# selectable via `/model` and the desktop dropdown.
# Only list models that actually answer at VERTEX_REGION — a dead model shows up as
# a selectable-but-broken row in the picker. Re-probe after any change.
export HERMES_MODEL="google/gemini-3.6-flash"        # default (newest)
export HERMES_MODELS="google/gemini-3.6-flash google/gemini-3.5-flash google/gemini-3.5-flash-lite"

# ---------------------------------------------------------------------------
# Tooling on the VM
# ---------------------------------------------------------------------------
export INSTALL_CHROME="true"          # google-chrome-stable + Playwright Chromium
export INSTALL_SEARXNG="true"         # self-hosted metasearch, localhost:8080
export SEARXNG_PORT="8080"
export WEB_BACKEND="searxng"          # Hermes web.backend

# Memory provider. Two supported values here:
#
#   "honcho"  — self-hosted Honcho (Docker, Postgres/pgvector) on this VM.
#               ⚠️  Honcho has NO Vertex support and needs its OWN keys: an
#               AI Studio Gemini key + an OpenAI embeddings key in ~/honcho/.env.
#               That is the only component NOT billed through your GCP project.
#
#   "builtin" — Hermes' built-in memory only (MEMORY.md + USER.md). No Docker, no
#               extra keys, no second billing surface, nothing leaves the VM.
#               Loses Honcho's cross-session user modelling.
#
# NOTE: Hermes' real config value for built-in is an EMPTY string
# (config.py default: `"provider": ""` — "empty = built-in only"). There is no
# provider literally named "builtin", so 02-vm-install.sh translates
# builtin/none/"" to an empty string. Do not put "builtin" in config.yaml.
export MEMORY_PROVIDER="honcho"       # honcho | builtin
export HONCHO_PORT="8000"

# Which LLM backend Honcho itself uses. Honcho has NO Vertex transport
# (src/config.py: ModelTransport = Literal["anthropic","openai","gemini"]), so:
#
#   "vertex"  — RECOMMENDED. Honcho's `openai` transport is pointed at a local
#               shim (scripts/vertex-openai-proxy.py) that forwards to Vertex and
#               injects a fresh service-account token per request. Result: ZERO
#               external API keys, Honcho's reasoning billed to this GCP project,
#               same service account as Hermes chat. The shim also works around
#               Vertex's broken OpenAI-compat /embeddings endpoint (HTTP 500 for
#               every model, verified 2026-07-28) by translating to :predict.
#
#   "gemini"  — direct AI Studio. Needs ONE key (LLM_GEMINI_API_KEY) pasted into
#               ~/honcho/.env. Simpler, but billed outside GCP.
#
#   "manual"  — touch nothing; you configure ~/honcho/.env yourself.
export MEMORY_LLM_BACKEND="vertex"

# Model Honcho uses for extraction / summary / dialectic / dream.
# Default is 2.5-flash, not 3.6-flash, on purpose: 3.6-flash spends part of its
# output budget on reasoning tokens (observed: max_tokens=20 consumed entirely by
# 16 reasoning tokens, empty content), which is wasteful for Honcho's short
# structured extractions. 3.6-flash does work if you want it.
export HONCHO_MODEL="google/gemini-2.5-flash"
export HONCHO_EMBED_MODEL="gemini-embedding-001"

# Local Vertex shim. Bound to 0.0.0.0 so Honcho's containers reach it over the
# compose bridge; safe ONLY because this VM has no external IP and the firewall
# admits nothing but Google's IAP range. NEVER open this port.
export VERTEX_PROXY_PORT="8900"
# Embeddings need a REGIONAL endpoint (the native :predict route). europe-west2
# keeps them EU-resident even while chat uses `global`.
export VERTEX_EMBED_LOCATION="europe-west2"
# MUST match Honcho's pgvector column width (EMBEDDING_VECTOR_DIMENSIONS).
# gemini-embedding-001 returns 3072 unless outputDimensionality is requested.
export VERTEX_EMBED_DIMENSIONS="1536"

# ---------------------------------------------------------------------------
# Dashboard (the "secure gateway" endpoint the desktop app + browser connect to)
# ---------------------------------------------------------------------------
# Bound to 0.0.0.0 on purpose: Hermes only engages its auth provider on a
# NON-loopback bind (a 127.0.0.1 bind runs with auth OFF and the desktop app
# cannot sign in). Safe here because the VM has no external IP and the only
# firewall ingress is Google's IAP range.
export DASHBOARD_ENABLE="true"
export DASHBOARD_PORT="9119"
export DASHBOARD_USERNAME="kennet"
# Password is NEVER stored in this repo. Export it before running 02-vm-install.sh:
#   export HERMES_DASHBOARD_PASSWORD='choose-a-strong-password'

# Gateway service (cron / routines / messaging platforms). The desktop app talks
# to the dashboard, not the gateway — but cron jobs and any future Slack/Telegram
# bot need this running. See OPS-NOTES.md §2 for idle-gateway recovery.
export GATEWAY_ENABLE="true"
export HERMES_AGENT_TIMEOUT="1800"    # gateway idle timeout, seconds (Hermes default)
