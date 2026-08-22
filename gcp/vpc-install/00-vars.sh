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
# ⚠️  EU-RESIDENCY EXCEPTION — INFERENCE ONLY (owner decision, re-affirmed 2026-08-18)
#
# VERTEX_REGION is `global`, which is NOT region-pinned. This is a deliberate,
# owner-approved relaxation of the "European regional endpoint only" rule, taken to
# run the two latest Gemini flash models. Everything else — VM, subnet, GCS
# bucket, backups, SearXNG, Honcho, embeddings — stays in europe-west2, so DATA AT
# REST REMAINS IN A EUROPEAN REGION. Only the inference endpoint is non-region-pinned.
#
# Why it is unavoidable for gemini-3.7-flash. Re-probed 2026-08-18
# (`:generateContent` POST, HTTP status):
#
#   MODEL                    | eu-w1 | eu-w2 | eu-w3 | eu-w4 | eu-n1 | global
#   gemini-3.7-flash         |  404  |  404  |  404  |  404  |  404  |  200
#   gemini-3.6-flash         |  404  |  404  |  404  |  404  |  404  |  200
#   gemini-3.5-flash         |  404  |  200  |  200  |  404  |  404  |  200
#   gemini-3.5-flash-lite    |  404  |  404  |  404  |  404  |  404  |  200
#   gemini-2.5-flash         |  200  |  200  |  200  |  200  |  200  |  200
#
# No European regional endpoint serves 3.7-flash. gemini-3.5-flash is the newest
# flash on a regional EU endpoint — and it has GAINED europe-west3 since the
# 2026-07-28 probe (was 404 there), so the regional fallback is widening.
#
# TO REVERT to strict regional-EU inference:
#   VERTEX_REGION="europe-west2"  +  HERMES_MODELS="google/gemini-3.5-flash google/gemini-2.5-flash"
#   HERMES_MODEL="google/gemini-3.5-flash"
# and re-probe — flip back to a regional endpoint the moment 3.7-flash lands in a
# European region. 03-verify.sh prints a residency warning whenever `global` is in use.
export VERTEX_REGION="global"

# The two flash models this install offers. The FIRST entry is the default; both are
# selectable via `/model` and the desktop dropdown.
# Only list models that actually answer at VERTEX_REGION — a dead model shows up as
# a selectable-but-broken row in the picker. Re-probe after any change.
#
# 3.5-flash-lite was dropped 2026-08-18: with 3.7-flash as the flagship and
# 3.5-flash as the strict-EU-capable fallback, a third flash tier earned nothing.
# It still works @ global if you want it back — just re-add it to HERMES_MODELS.
export HERMES_MODEL="google/gemini-3.7-flash"        # default (newest)
export HERMES_MODELS="google/gemini-3.7-flash google/gemini-3.5-flash"

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
#               Honcho has no Vertex transport of its own, but MEMORY_LLM_BACKEND
#               below routes it to Vertex through a local shim, so with the default
#               (=vertex) it needs NO external API keys and bills to this GCP
#               project. Only MEMORY_LLM_BACKEND=gemini needs an outside key.
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
#
# 🛑 DO NOT SET THIS TO A GEMINI 3.x MODEL. Tested on the live install 2026-08-18:
# `gemini-3.5-flash` makes Honcho's dialectic fail, every time, with
#
#   openai.BadRequestError: 400 - vertex returned 400:
#     "Function call is missing a thought_signature..."
#
# WHY. Gemini 3.x are thinking models: when they emit a function call they attach an
# opaque `thought_signature`, and Vertex REQUIRES it to be echoed back on the following
# turn. It rides in the OpenAI-compat response as
# `choices[0].message.extra_content.google.thought_signature` — a Google extension the
# OpenAI wire format has no concept of. Honcho's OpenAI client drops unknown fields when
# it re-serialises the assistant message for the next tool iteration, so from iteration
# two onward Vertex rejects the whole conversation. The shim cannot fix this: it is a
# pass-through and cannot invent a signature Honcho has already discarded.
#
# `gemini-2.5-flash` never issues a thought_signature, so nothing can be lost and the
# multi-iteration tool loop works. Verified 2026-08-18 by A/B on the live box (same
# install, only this value changed):
#
#   HONCHO_MODEL              dialectic result
#   google/gemini-3.5-flash   HTTP 400 on all 3 retries, no answer
#   google/gemini-2.5-flash   HTTP 200, recalled the seeded facts correctly
#
# This is why 03-verify.sh test 11 is NOT sufficient on its own: a single-shot chat
# completion through the shim SUCCEEDS with 3.5-flash (no tool loop, so no signature to
# lose). Only a real multi-iteration dialectic exposes it — see OPS-NOTES.md
# "Prove Honcho really remembers" and re-run it if you ever change this value.
#
# Hermes' OWN chat is unaffected and correctly runs gemini-3.7-flash: it does not use
# this shim, and its Vertex provider round-trips thought signatures properly (proved
# 2026-08-18 with a real tool-using agent turn that wrote a file on the VM).
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

# ---------------------------------------------------------------------------
# Weekly unattended backend updates
# ---------------------------------------------------------------------------
# Runs `hermes update` from a systemd TIMER, not from a `hermes cron` job and not
# from the desktop app. That distinction is load-bearing, not stylistic:
# `hermes update` restarts hermes-gateway.service, and the gateway unit uses
# KillMode=mixed + an ExecStopPost cgroup cleanup — so an updater launched from
# inside the gateway (a hermes cron job, or a dashboard/desktop-app action) is
# reaped mid-run when the gateway goes down. A timer unit has its own cgroup and
# is unaffected. See scripts/hermes-autoupdate.sh for the full reasoning.
export AUTOUPDATE_ENABLE="true"
# "apply" = install updates. "check" = only report that one is available
# (writes ~/.hermes/autoupdate/pending, changes nothing). Use "check" if you
# want a human in the loop for a production agent.
export AUTOUPDATE_MODE="apply"
# systemd OnCalendar expression. `systemd-analyze calendar '<expr>'` validates it
# and prints the next elapse. A 30m randomised delay is added by the timer.
export AUTOUPDATE_SCHEDULE="Sun *-*-* 04:00:00 UTC"

# NOTE: this updates the BACKEND ON THIS VM only. The desktop app on your PC is
# built from its own checkout and has no auto-update feed — updating it is a
# two-command job on the Mac. See OPS-NOTES.md §11.
