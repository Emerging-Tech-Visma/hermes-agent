<div align="center">

# Hermes on GCP

**A reproducible runbook for running a [Hermes Agent](https://hermes-agent.nousresearch.com)
on Google Cloud — privately, EU-resident data, billed through your own project.**

[![version](https://img.shields.io/badge/version-0.14.1-blue)](CHANGELOG.md)
[![Hermes](https://img.shields.io/badge/Hermes-v0.19.0-8A2BE2)](https://hermes-agent.nousresearch.com)
[![data](https://img.shields.io/badge/data-europe--west2-green)](#eu-data-residency)
[![inference](https://img.shields.io/badge/inference-vertex%20global-yellow)](#eu-data-residency)
[![model](https://img.shields.io/badge/model-gemini--3.6--flash-orange)](#eu-data-residency)

</div>

---

This is a **learning and reference repo**. It is documentation, not application code.
Its whole purpose is that a working Hermes install can be **rebuilt from scratch** on
a new project or VM without rediscovering the gotchas — so everything is written
down, including the things that went wrong.

If you are here to build one: **[start with `gcp/vpc-install/`](gcp/vpc-install/README.md)**.

---

## What you end up with

```
YOUR PC                                GOOGLE CLOUD
┌──────────────────────┐               ┌────────────────────────────────────────────┐
│  Hermes Desktop app  │               │  private VPC · no external IP · IAP-only   │
│  or a browser        │               │                                            │
│          │           │               │  ┌──────────────────────────────────────┐  │
│  localhost:9119 ─────┼──IAP tunnel───┼─►│ Hermes dashboard  :9119  (the gateway)│ │
│                      │  identity-    │  │ Hermes gateway    (cron / routines)   │ │
│  (client only —      │  gated,       │  │ Chrome + Playwright Chromium          │ │
│   zero compute)      │  encrypted    │  │ SearXNG           :8080  localhost    │ │
└──────────────────────┘               │  │ Honcho memory :8000 + Vertex shim :8900│ │
                                       │  └──────────────────────────────────────┘  │
                                       │  Vertex AI · gemini-3.7-flash · global ⚠️  │
                                       └────────────────────────────────────────────┘
```

**Everything runs on the VM.** Your PC only runs the client. Ask the agent to create
a file or folder and it is created **on the VM** — the agent, its shell, its browser,
its search and its memory all live there.

**Nothing is exposed to the internet.** The VM has no public IP. The only firewall
ingress is Google's IAP range, and using it requires an IAM role — so access is
centrally granted, audited, and revoked with one command. No SSH keys to distribute,
no service-account key files to leak.

---

## Quick start

Three commands, after editing one file.

```bash
# 0. Edit gcp/vpc-install/00-vars.sh — project, region, VM name, dashboard user.
#    This is the ONLY file you change when cloning for a new team or company.

# 1. On your PC (needs gcloud + project Owner/Editor):
bash gcp/vpc-install/01-gcp-setup.sh

# 2. On the VM:
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap
export HERMES_DASHBOARD_PASSWORD='choose-a-strong-password'
bash ~/hermes-install/02-vm-install.sh

# 3. Verify (on the VM) — targets 9/9:
bash ~/hermes-install/03-verify.sh
```

Then open the secure gateway from your PC and connect:

```bash
gcloud compute start-iap-tunnel hermes-agent 9119 \
  --local-host-port=localhost:9119 \
  --zone=europe-west2-b --project=test-disco-cm
```

Desktop app → **Settings → Gateway → Remote gateway** → `http://localhost:9119`, then
**sign in** with your dashboard username and password. There is no token to paste. Or
just open <http://localhost:9119> in a browser.

Full walkthrough: **[gcp/vpc-install/INSTALL.md](gcp/vpc-install/INSTALL.md)**

---

## The stack

| Layer | Choice | Why |
|---|---|---|
| Host | GCE `e2-standard-4`, Ubuntu 26.04 LTS, 100 GB | Chrome + Postgres + SearXNG + Hermes need the headroom |
| Network | Custom VPC, no external IP, Cloud NAT, IAP-only ingress | nothing to scan; access is IAM |
| Model | Vertex AI `gemini-3.7-flash` (+ `3.5-flash`) @ `global` | newest flash, plus the newest one that also serves from an EU region; ⚠️ `global` is not region-pinned |
| Search | Self-hosted **SearXNG** | native Hermes backend, no API key, no hosted-SaaS query log |
| Browser | Chrome + Playwright Chromium, headless | real browser automation on the VM |
| Memory | Self-hosted **Honcho** (Postgres/pgvector) **on Vertex** | per-user memory modelling; **zero external API keys** via a local OpenAI-compat shim |
| Client | Hermes Desktop app or browser, over IAP | thin client; all compute remote |
| Auth | One attached service account | **no key files anywhere** |

Running cost at moderate daily team use: **~$235–365/month**. Chat tokens dominate —
breakdown and the cheapest levers are in [INSTALL.md §11](gcp/vpc-install/INSTALL.md).

---

## EU data residency

A hard requirement for this project: **all GCP services run in a European region** —
with one deliberate, owner-approved exception for **inference only**.

| Plane | Where | EU-resident? |
|---|---|---|
| **Data at rest** — VM, subnet, GCS bucket, backups, SearXNG, Honcho | `europe-west2` | ✅ yes |
| **Inference** — Vertex chat calls | `global` | ⚠️ **not region-pinned** |

The reason is model availability. Re-probed directly against Vertex on **2026-08-18**
(`:generateContent` POST, HTTP status):

| Model | eu-w1 | eu-w2 | eu-w3 | eu-w4 | eu-n1 | global |
|---|---|---|---|---|---|---|
| `gemini-3.7-flash` | 404 | 404 | 404 | 404 | 404 | **200** |
| `gemini-3.6-flash` | 404 | 404 | 404 | 404 | 404 | **200** |
| `gemini-3.5-flash` | 404 | **200** | **200** | 404 | 404 | **200** |
| `gemini-3.5-flash-lite` | 404 | 404 | 404 | 404 | 404 | **200** |
| `gemini-2.5-flash` | **200** | **200** | **200** | **200** | **200** | **200** |

**No European regional endpoint serves `gemini-3.7-flash`.** Running the newest flash
model therefore requires the `global` endpoint. That trade was made knowingly:
infrastructure and all stored data — including Honcho's embeddings, which use the
regional `europe-west2` endpoint — stay in `europe-west2`, and only the chat inference
call leaves a pinned region.

`gemini-3.5-flash` **gained `europe-west3`** since the 2026-07-28 probe, so the
strict-EU fallback is widening over time. This is exactly why the table carries a date.

**To revert to strict regional-EU inference**, in `gcp/vpc-install/00-vars.sh`:

```bash
VERTEX_REGION="europe-west2"
HERMES_MODELS="google/gemini-3.5-flash google/gemini-2.5-flash"
HERMES_MODEL="google/gemini-3.5-flash"
```

Then re-run `02-vm-install.sh`. Flip back the moment the newer models land in a
European region — and **re-probe** rather than trusting the table above.

> Note `europe-west2` is London — **UK, not an EU member state**. It is covered by the
> EU's UK adequacy decision. For strict EU-*member* residency use `europe-west1`,
> which caps at `gemini-2.5-flash`.

> **AI Studio ≠ Vertex.** The `ai.google.dev` docs list models Vertex regions do not
> serve. Always probe Vertex directly — the one-liner is in
> [INSTALL.md §12](gcp/vpc-install/INSTALL.md), and `03-verify.sh` makes a real
> inference call, so a wrong model/region pairing fails loudly instead of silently.
> It also prints a residency warning whenever `global` is in use.

---

## Repo map

**Start here**

| Document | What it is |
|---|---|
| **[gcp/vpc-install/](gcp/vpc-install/README.md)** | **The current install.** Cloneable package: 3 scripts + 3 guides + configs. |
| [gcp/vpc-install/INSTALL.md](gcp/vpc-install/INSTALL.md) | Full guide — architecture, every command, security model, cost, design rationale. |
| [gcp/vpc-install/OPS-NOTES.md](gcp/vpc-install/OPS-NOTES.md) | **Day-2 ops over SSH** — idle/wedged gateways, backend upgrades, service updates, symptom→cause table. |
| [AGENTS.md](AGENTS.md) | Master runbook: architecture, canonical facts, and **lessons learned** (read before debugging anything). |
| [CHANGELOG.md](CHANGELOG.md) | Version history. Currently **0.14.1**. |

**Variants and deeper topics** (from the earlier public-IP install — still the best
reference for these subjects)

| Document | Topic |
|---|---|
| [gcp/SLACK-TEAM-SETUP.md](gcp/SLACK-TEAM-SETUP.md) | Slack bot, Socket Mode, per-channel personas |
| [gcp/SUPPORT-BOT-SETUP.md](gcp/SUPPORT-BOT-SETUP.md) | Locked-down all-employee support bot |
| [gcp/PROFILES-ISOLATION.md](gcp/PROFILES-ISOLATION.md) | Several isolated agents on one VM via profiles |
| [gcp/KNOWLEDGE-DATASTORE.md](gcp/KNOWLEDGE-DATASTORE.md) | Vertex AI Search knowledge layer (Drive + URLs) |
| [gcp/EXTERNAL-KG-MCP.md](gcp/EXTERNAL-KG-MCP.md) | Reuse an existing knowledge graph over MCP |
| [gcp/DESKTOP-SETUP.md](gcp/DESKTOP-SETUP.md) | Desktop app over a plain SSH tunnel (v1 pattern) |
| [gcp/REFERENCE.md](gcp/REFERENCE.md) | Env vars, MCP config shape, skills, troubleshooting |
| [gcp/SUBPROCESSOR-MONITOR-PLAN.md](gcp/SUBPROCESSOR-MONITOR-PLAN.md) | Worked example: propose-only compliance agent |
| [gcp/](gcp/README.md) | The original v1 install (superseded — see the banner) |

---

## Lessons that cost the most time

The full list lives in [AGENTS.md](AGENTS.md). The ones most likely to bite you:

- **`linger` is not optional.** Without `sudo loginctl enable-linger $USER`, every
  user systemd service dies when your SSH session closes. This is *the* cause of
  "worked during setup, dead the next morning".
- **The dashboard must bind `0.0.0.0`, not `127.0.0.1`.** Hermes only engages its
  auth provider on a non-loopback bind — on loopback it runs with **auth OFF** and
  the desktop app cannot sign in. Safe here only because the VM has no public IP.
- **No external IP ⇒ Cloud NAT is mandatory.** Private Google Access covers *Google*
  APIs only. Without NAT, `apt`, the installer, Docker Hub, Playwright and SearXNG's
  upstream fetches all fail.
- **SerpApi cannot be self-hosted and is not a Hermes backend.** The backends are
  exactly `{parallel, firecrawl, tavily, exa, searxng, brave-free, ddgs, xai}`.
  SearXNG is the local, key-free, EU-resident answer.
- **SearXNG needs `json` in `search.formats` and `limiter: false`.** Miss either and
  every search returns 403 while the service looks perfectly healthy.
- **`Restart=always` cannot detect a wedged gateway.** A gateway hung on a stalled
  tool call stays "active" forever. Use the watchdog timer in OPS-NOTES §2c.
- **The `gemini` provider ≠ the `vertex` provider.** Setting `GOOGLE_API_KEY` in
  `~/.hermes/.env` silently switches Hermes to AI Studio and yields
  `HTTP 400 — no access to model`. Vertex uses ADC and needs no key.
- **Duplicate `.env` credentials break login silently.** Always use
  `dashboard-setup.sh`; it strips all existing lines then writes exactly one set.

---

## Conventions for this repo

- **Secrets are never committed.** Passwords come from the environment
  (`HERMES_DASHBOARD_PASSWORD`) or are set directly on the VM. Config templates use
  `__PLACEHOLDER__` tokens filled at install time.
- **Tooling:** [UV](https://docs.astral.sh/uv/) for Python/CLI,
  [Bun](https://bun.sh/) for TS/web.
- **Agent instructions live in [AGENTS.md](AGENTS.md)**, read by both Claude Code and
  Codex. Keep it and `gcp/` in sync when the install changes — faithful replication
  is the point of this repo.
- **Record what you verify, and when.** Facts here carry dates because model
  availability, image families and pricing all move. Re-probe rather than trust.
