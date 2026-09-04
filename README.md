<div align="center">

# Hermes on GCP

**A reproducible runbook for running a [Hermes Agent](https://hermes-agent.nousresearch.com)
on Google Cloud — privately, EU-resident data, billed through your own project.**

Live install probed **2026-08-19**: Hermes **v0.20.4**, Ubuntu 26.04 LTS, Chrome 151,
Vertex **`gemini-3.7-flash`** @ `global` (+ `gemini-3.5-flash`), SearXNG and Honcho up,
no external IP.

> **0.17.0 moves the default model to `gemini-3.8-flash`** (re-probed on Vertex
> 2026-09-04). The live box above still runs 3.7-flash until the install is re-run —
> this line will be updated when it is re-probed.

[![version](https://img.shields.io/badge/version-0.17.3-blue)](CHANGELOG.md)
[![Hermes](https://img.shields.io/badge/Hermes-v0.20.4-8A2BE2)](https://hermes-agent.nousresearch.com)
[![data](https://img.shields.io/badge/data-europe--west2-green)](#eu-data-residency)
[![inference](https://img.shields.io/badge/inference-vertex%20global-yellow)](#eu-data-residency)
[![model](https://img.shields.io/badge/model-gemini--3.7--flash-orange)](#eu-data-residency)
[![verify](https://img.shields.io/badge/03--verify.sh-14%2F14-brightgreen)](gcp/vpc-install/README.md)

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
                                       │  Vertex AI · gemini-3.8-flash · global ⚠️  │
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

# 3. Verify (on the VM) — targets 14/14:
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

## Everyday commands — `hermesctl`

One script wraps every routine operation, so you never have to remember a `gcloud`
incantation. Install it once, on your PC:

```bash
bash gcp/vpc-install/scripts/install-hermesctl.sh
```

Then:

```bash
hermesctl status            # is everything healthy?  (the 14-point check)
hermesctl update-all        # update the server AND the desktop app
hermesctl gateway restart   # the one you'll reach for most
hermesctl help              # everything else
```

### Updating

The server **updates itself every Sunday** (04:00 UTC + a random delay), so normally you
do nothing. These are for when you want to move sooner, or check:

| Command | What it does |
|---|---|
| `hermesctl update-check` | Is a newer version out? Changes nothing. |
| `hermesctl update` | Update the **server** now, without waiting for Sunday. |
| `hermesctl update-desktop` | Update the **desktop app** on your Mac and relaunch it. |
| `hermesctl update-all` | Both, server first. |
| `hermesctl autoupdate` | Show the weekly schedule and the last result. |
| `hermesctl autoupdate off` / `on` | Turn the weekly automatic update off or back on. |

> **The server and the desktop app update separately, and that is not a bug.** The app is
> built from its own checkout and ships **no auto-update feed**, so nothing on the VM can
> update it — `hermesctl update-desktop` is the supported path. It matters far less than
> it sounds: the app is a thin client, and all the compute, tools and memory live on the
> server. Version skew is normally harmless.
>
> `hermesctl update` deliberately runs the **autoupdate unit** rather than `hermes update`
> directly, so it gets the same cgroup isolation, dashboard restart and post-update
> verification as the scheduled run. See [OPS-NOTES.md §11](gcp/vpc-install/OPS-NOTES.md)
> for why that isolation is load-bearing.

### Services, access, machine

| Command | What it does |
|---|---|
| `hermesctl gateway status\|start\|stop\|restart` | The gateway runs cron jobs and messaging. |
| `hermesctl gateway kick` | Force-recover a gateway that is "running" but doing nothing — clears stale locks and starts clean. `restart` alone cannot fix that state. |
| `hermesctl dashboard restart` | Restart the endpoint your app connects to. |
| `hermesctl restart-all` | Restart everything, in the order that works (shim before Honcho). |
| `hermesctl logs gateway\|dashboard\|shim\|autoupdate\|honcho\|searxng` | Recent logs for one component. |
| `hermesctl tunnel` | Open the secure gateway tunnel. |
| `hermesctl open` | Open the dashboard in your browser (tells you if the tunnel is down). |
| `hermesctl ssh` | Shell on the server. |
| `hermesctl vm status\|start\|stop` | `stop` warns first — it halts the agent, cron and the weekly update, and the disk plus Cloud NAT keep billing. |
| `hermesctl disk` | Disk usage, and reclaim space. |

Every server-side command goes over the IAP tunnel (the VM has no public IP) and retries
the transient `exit 255` that `gcloud compute ssh` occasionally throws.

### When you can't connect

Since 0.17.1 the **desktop app and the command line fail independently**, because they
authenticate as different identities: the tunnel runs as the `hermes-tunnel` service
account, while `hermesctl` runs as *you*. So `gcloud auth login` is the fix for one of them
and does nothing for the other. Start here:

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:9119
```

| It says | What it means | What to do |
|---|---|---|
| **302** | The tunnel is healthy — 302 is the auth gate. | If the app still won't connect, the problem is the app or the password, not your login. `gcloud auth login` will not help. |
| **000** | The tunnel is not forwarding. | **Wait ~2 minutes first** — a cold start has taken over two minutes to first answer. Then `launchctl kickstart -k gui/$(id -u)/com.hermes.gateway-tunnel`, and if it is still 000 read the log below, which names the actual fix. |

```bash
tail -20 ~/Library/Logs/hermes-gateway-tunnel.log
```

**`gcloud auth login` is still the fix for `hermesctl`.** Google enforces a periodic
reauthentication on user credentials, so after idle the CLI stops with:

```
Reauthentication failed. cannot prompt during non-interactive execution.
```

The tell-tale is **`hermesctl` failing while the app works fine** — that is this split, not a
broken tunnel. Re-login and the CLI works again; the tunnel is untouched.

| Symptom | Fix |
|---|---|
| App won't connect, `curl` returns 302 | Not an auth problem — check the app and the dashboard password |
| `curl` returns 000 | Wait ~2 min → `launchctl kickstart` → read the tunnel log |
| `hermesctl` says `Reauthentication failed` | `gcloud auth login` |

Why the app no longer needs a periodic re-login: a LaunchAgent can never answer an
interactive reauth prompt, so the tunnel was guaranteed to die after idle while it used a
human credential. Service-account credentials are exempt from reauth. Full reasoning in
[`OPS-NOTES.md`](gcp/vpc-install/OPS-NOTES.md) §7a and the `TUNNEL_USE_SA` block of
[`00-vars.sh`](gcp/vpc-install/00-vars.sh).

---

## The stack

| Layer | Choice | Why |
|---|---|---|
| Host | GCE `e2-standard-4`, Ubuntu 26.04 LTS, 100 GB | Chrome + Postgres + SearXNG + Hermes need the headroom |
| Network | Custom VPC, no external IP, Cloud NAT, IAP-only ingress | nothing to scan; access is IAM |
| Model | Vertex AI `gemini-3.8-flash` (+ `3.5-flash`) @ `global` | newest flash, plus the newest one that also serves from an EU region; ⚠️ `global` is not region-pinned |
| Search | Self-hosted **SearXNG** | native Hermes backend, no API key, no hosted-SaaS query log |
| Browser | Chrome + Playwright Chromium, headless | real browser automation on the VM |
| Memory | Self-hosted **Honcho** (Postgres/pgvector) **on Vertex** | per-user memory modelling; **zero external API keys** via a local OpenAI-compat shim |
| Client | Hermes Desktop app or browser, over IAP | thin client; all compute remote |
| Auth | One attached service account | **no key files anywhere** |

Running cost at moderate daily team use: **~$200–275/month** while `gemini-3.8-flash`
is on introductory pricing (**$0.75 / $3.75** per 1M input / output tokens through
**2026-12-31**, then **$1.50 / $7.50**). On 2027-01-01 the model line roughly doubles
back to ~$75–180, restoring the earlier ~$235–365/month total if the other line items
hold. Chat tokens dominate — breakdown and the cheapest levers are in
[INSTALL.md §11](gcp/vpc-install/INSTALL.md).

---

## EU data residency

A hard requirement for this project: **all GCP services run in a European region** —
with one deliberate, owner-approved exception for **inference only**.

| Plane | Where | EU-resident? |
|---|---|---|
| **Data at rest** — VM, subnet, GCS bucket, backups, SearXNG, Honcho | `europe-west2` | ✅ yes |
| **Inference** — Vertex chat calls | `global` | ⚠️ **not region-pinned** |

The reason is model availability. Re-probed directly against Vertex on **2026-09-04**
(`:generateContent` POST, HTTP status; each 200 additionally confirmed by the echoed
`modelVersion` matching the requested id):

| Model | eu-w1 | eu-w2 | eu-w3 | eu-w4 | eu-n1 | global |
|---|---|---|---|---|---|---|
| `gemini-3.8-flash` | 404 | 404 | 404 | 404 | 404 | **200** |
| `gemini-3.7-flash` | 404 | 404 | 404 | 404 | 404 | **200** |
| `gemini-3.6-flash` | 404 | 404 | 404 | 404 | 404 | **200** |
| `gemini-3.5-flash` | 404 | **200** | **200** | 404 | 404 | **200** |
| `gemini-3.5-flash-lite` | 404 | 404 | 404 | 404 | 404 | **200** |
| `gemini-2.5-flash` | **200** | **200** | **200** | **200** | **200** | **200** |

**No European regional endpoint serves `gemini-3.8-flash`.** Running the newest flash
model therefore requires the `global` endpoint — 3.8 has exactly the same availability
shape as 3.7 and 3.6, so this upgrade does not change the residency posture either way. That trade was made knowingly:
infrastructure and all stored data — including Honcho's embeddings, which use the
regional `europe-west2` endpoint — stay in `europe-west2`, and only the chat inference
call leaves a pinned region.

`gemini-3.5-flash` holds `europe-west2` **and `europe-west3`** (west3 arrived after the
2026-07-28 probe), so the strict-EU fallback is unchanged by this upgrade — and widening
over time. This is exactly why the table carries a date.

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
| [CHANGELOG.md](CHANGELOG.md) | Version history. Currently **0.17.0**. Each entry is the notes of the matching [release](https://github.com/Emerging-Tech-Visma/hermes-agent/releases). |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How changes land: `main` is PR-only; every PR bumps the version and its changelog entry is auto-published as a release. |

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
- **`main` is PR-only; every PR ships a new version.** Direct pushes to `main` are
  rejected by a repository ruleset. The required `changelog` check fails any PR that
  does not touch [CHANGELOG.md](CHANGELOG.md), bump the version above `main`'s, and keep
  the badges in step. On merge, that entry is published as a
  [GitHub release](https://github.com/Emerging-Tech-Visma/hermes-agent/releases)
  automatically — never tag by hand. See [CONTRIBUTING.md](CONTRIBUTING.md).
- **Agent instructions live in [AGENTS.md](AGENTS.md)**, read by both Claude Code and
  Codex. Keep it and `gcp/` in sync when the install changes — faithful replication
  is the point of this repo.
- **Record what you verify, and when.** Facts here carry dates because model
  availability, image families and pricing all move. Re-probe rather than trust.
