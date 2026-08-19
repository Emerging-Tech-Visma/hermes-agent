# Hermes Agent on a private GCP VPC — full installation guide

A complete, copy-pasteable install of a [Hermes agent](https://hermes-agent.nousresearch.com)
on Google Cloud, where:

- **Everything runs on the VM** — agent loop, shell, files, browser, search, memory, inference.
- **Your PC is only a client.** The Hermes **desktop app** (or a browser) reaches the VM
  through a **secure IAP gateway tunnel**. Nothing is published to the internet.
- **The VM has no external IP.** The only firewall ingress is Google's IAP range,
  gated by IAM.
- Ask the agent to create a file or folder and **it is created on the VM**, because the
  agent's terminal backend is local *to the VM*.

Verified against **Hermes Agent v0.20.4** (`2026.8.18`), GCP as of **2026-08-19**.
The installer pulls Hermes **unpinned** from upstream `install.sh`, so a fresh run gets
whatever is current — re-probe `hermes --version` rather than trusting this line.

---

## Contents

1. [Architecture](#1-architecture)
2. [Region & model availability](#2-region--model-availability)
3. [Prerequisites](#3-prerequisites)
4. [Step 1 — provision GCP](#4-step-1--provision-gcp-run-on-your-pc)
5. [Step 2 — install on the VM](#5-step-2--install-on-the-vm)
6. [Step 3 — Honcho memory keys](#6-step-3--honcho-memory-keys-on-the-vm)
7. [Step 4 — verify](#7-step-4--verify-on-the-vm)
8. [Step 5 — connect the desktop app](#8-step-5--connect-the-desktop-app-on-your-pc)
9. [What runs where](#9-what-runs-where)
10. [Security model](#10-security-model)
11. [Cost](#11-cost)
12. [Design decisions & rejected alternatives](#12-design-decisions--rejected-alternatives)

---

## 1. Architecture

```
YOUR PC                              GOOGLE CLOUD  (project: test-disco-cm)
┌─────────────────────┐              ┌──────────────────────────────────────────────┐
│ Hermes Desktop app  │              │  VPC hermes-vpc / subnet 10.10.0.0/24        │
│   or a browser      │              │  (europe-west2, Private Google Access)       │
│         │           │              │                                              │
│         ▼           │              │  ┌────────────────────────────────────────┐  │
│  localhost:9119 ────┼──IAP tunnel──┼─►│ VM hermes-agent  (NO external IP)      │  │
│                     │  (identity-  │  │  Ubuntu 26.04 LTS · e2-standard-4      │  │
│  gcloud             │   gated,     │  │                                        │  │
│  start-iap-tunnel   │   encrypted) │  │  hermes-dashboard.service  :9119 ◄──── │  │
└─────────────────────┘              │  │  hermes-gateway.service  (cron)        │  │
                                     │  │  Chrome + Playwright Chromium          │  │
                                     │  │  SearXNG (Docker)        :8080 (local) │  │
                                     │  │  Honcho + Postgres/pgvector :8000 (local)│ │
                                     │  └──────────┬─────────────────────────────┘  │
                                     │             │                                │
                                     │   Private Google Access → Vertex AI          │
                                     │    gemini-3.7-flash @ global  ⚠️ see §2      │
                                     │   Cloud NAT → apt, GitHub, SearXNG upstreams │
                                     │   GCS gs://test-disco-cm-hermes-memory       │
                                     └──────────────────────────────────────────────┘
```

Inference bills to the GCP project through the VM's **attached service account**
(Application Default Credentials — no key files anywhere). The single exception is
Honcho's background reasoning, which needs its own AI Studio + OpenAI keys because
Honcho has no Vertex support.

---

## 2. Region & model availability

This install runs **the three latest Gemini flash models**, and that forces a split
between where data lives and where inference happens.

| Plane | Location | EU-resident? |
|---|---|---|
| VM, subnet, GCS bucket, backups, SearXNG, Honcho | `europe-west2` | ✅ yes |
| Vertex inference | **`global`** | ⚠️ not region-pinned |

**Model catalog** (`HERMES_MODELS` in `00-vars.sh`):

| Model | Role |
|---|---|
| `google/gemini-3.7-flash` | **default** |
| `google/gemini-3.5-flash` | switchable via `/model`; also the **strict-EU-capable** one |

Honcho's own reasoning runs on `google/gemini-3.5-flash` (`HONCHO_MODEL`) through the
Vertex shim — see §7 before changing it.

### Why `global`

Re-probed directly against Vertex on **2026-08-18** (`:generateContent` POST, HTTP status):

| Model | eu-w1 | eu-w2 | eu-w3 | eu-w4 | eu-n1 | global |
|---|---|---|---|---|---|---|
| `gemini-3.7-flash` | 404 | 404 | 404 | 404 | 404 | **200** |
| `gemini-3.6-flash` | 404 | 404 | 404 | 404 | 404 | **200** |
| `gemini-3.5-flash` | 404 | **200** | **200** | 404 | 404 | **200** |
| `gemini-3.5-flash-lite` | 404 | 404 | 404 | 404 | 404 | **200** |
| `gemini-2.5-flash` | **200** | **200** | **200** | **200** | **200** | **200** |

**No European regional endpoint serves `gemini-3.7-flash`**, so running the newest model
requires `global`. `gemini-3.5-flash` is the newest flash on a regional EU endpoint —
and it **gained `europe-west3`** since the 2026-07-28 probe, so re-probe rather than
trusting this table.

> ⚠️ **This is a deliberate EU-residency exception, and it is scoped to inference.**
> `global` is not region-pinned, so chat requests may be served outside Europe.
> Everything that *stores* anything — the VM disk, the GCS bucket, Honcho's Postgres,
> SearXNG — stays in `europe-west2`. If your policy forbids unpinned inference, revert
> as below; the install works identically, just with older models.

### Reverting to strict regional-EU inference

In `00-vars.sh`:

```bash
VERTEX_REGION="europe-west2"
HERMES_MODEL="google/gemini-3.5-flash"
HERMES_MODELS="google/gemini-3.5-flash google/gemini-2.5-flash"
```

Then re-run `02-vm-install.sh` (idempotent). For strict EU-**member** residency use
`europe-west1`, which caps at `gemini-2.5-flash`:

```bash
REGION="europe-west1"; ZONE="europe-west1-b"
VERTEX_REGION="europe-west1"
HERMES_MODEL="google/gemini-2.5-flash"
HERMES_MODELS="google/gemini-2.5-flash google/gemini-2.5-pro"
```

> **`europe-west2` is London — UK, not an EU member state.** It is covered by the EU's
> UK adequacy decision, so it normally satisfies a "European region" policy, but it is
> not EU-*member* residency.
>
> **Re-probe before trusting any of this.** Model availability moves. `03-verify.sh`
> makes a real inference call and prints a residency warning when `global` is in use;
> the probe one-liner is in [§12](#12-design-decisions--rejected-alternatives).

Only models that actually answer at the configured region belong in the catalog — a
404 model still shows as a selectable row and fails only when picked. The installer
fails fast if `HERMES_MODEL` is not one of `HERMES_MODELS`.

---

## 3. Prerequisites

On your PC:

```bash
gcloud --version          # Google Cloud SDK
gcloud auth login
gcloud auth application-default login
```

You need **Owner or Editor** on the GCP project (the script creates a VPC, a service
account, IAM bindings and a VM). Then download the desktop app from
<https://hermes-agent.nousresearch.com/>:

| OS | Download |
|---|---|
| macOS 12+ | <https://hermes-assets.nousresearch.com/Hermes-Setup.dmg> |
| Windows 10/11 | <https://hermes-assets.nousresearch.com/Hermes-Setup.exe> |
| Linux | `curl -fsSL https://hermes-agent.nousresearch.com/install.sh \| bash` |

Finally, **edit `00-vars.sh`** — it is the only file you change when cloning this
setup for a different project, team, or company.

---

## 4. Step 1 — provision GCP (run on your PC)

```bash
bash gcp/vpc-install/01-gcp-setup.sh
```

This is idempotent; re-run it freely. It creates:

| Resource | Name | Why |
|---|---|---|
| VPC | `hermes-vpc` (custom subnet mode) | isolation from the `default` network |
| Subnet | `hermes-subnet` `10.10.0.0/24` | Private Google Access **on** → reach Vertex/GCS with no public IP |
| Cloud Router + NAT | `hermes-router` / `hermes-nat` | **mandatory** outbound egress |
| Firewall | `allow-iap-ssh` tcp:22 | from `35.235.240.0/20` only |
| Firewall | `allow-iap-dashboard` tcp:9119 | from `35.235.240.0/20` only |
| Firewall | `deny-all-ingress` priority 65000 | belt-and-braces |
| Service account | `hermes-agent@…` | `roles/aiplatform.user`, `roles/storage.objectAdmin` |
| Bucket | `gs://test-disco-cm-hermes-memory` | hourly state backup |
| VM | `hermes-agent`, e2-standard-4, Ubuntu 26.04 LTS, **`--no-address`** | the whole stack |
| IAM (you) | `iap.tunnelResourceAccessor`, `compute.osLogin` | permission to open the gateway |

**Why Cloud NAT is not optional.** A VM with no external IP cannot reach the internet
at all without it. Private Google Access only covers *Google* APIs. Without NAT:
`apt` fails, the Hermes installer fails, Docker Hub fails, Playwright and Chrome
downloads fail, and **SearXNG cannot reach the upstream engines it proxies** — so
search returns nothing.

**Why port 9119 has a firewall rule.** IAP TCP forwarding requires an explicit allow
for the port it forwards. The source range is Google's IAP frontend, not the
internet — and who may use it is gated by IAM. Port 9119 is still unreachable
publicly. There is no `0.0.0.0/0` allow rule anywhere.

---

## 5. Step 2 — install on the VM

SSH in over the tunnel (there is no public IP, so `--tunnel-through-iap` is required):

```bash
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap
```

Then, **on the VM**:

```bash
export HERMES_DASHBOARD_PASSWORD='choose-a-strong-password'
bash ~/hermes-install/02-vm-install.sh
```

> Watch your shell prompt. `you@hermes-agent` = the VM. `you@your-machine` = your PC.
> Pasting VM commands into the wrong terminal is the single biggest time sink in this
> whole process. If unsure, wrap it:
> `gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap --command='...'`
> runs on the VM regardless of where your prompt is.

The eight stages:

| # | Stage | Notes |
|---|---|---|
| 1 | OS packages | git, curl, jq, ripgrep, ffmpeg, build-essential, rsync |
| 2 | Docker | for SearXNG + Honcho; uses `sudo docker` so no re-login is needed mid-install |
| 3 | Hermes | official installer with `--skip-browser` (we install browsers ourselves) |
| 4 | Chrome + Playwright | `google-chrome-stable` from Google's apt repo + Playwright Chromium |
| 5 | SearXNG | Docker, `127.0.0.1:8080`, fresh `secret_key`, JSON API enabled |
| 6 | Hermes config | `config.yaml` + `.env` (idempotent — managed keys are stripped and rewritten) |
| 7 | Honcho | cloned + started, or prompts you for its keys |
| 8 | Services | dashboard, gateway, hourly backup, **linger** |

### Two gotchas this step exists to handle

**Playwright on Ubuntu 26.04.** Playwright may refuse a brand-new OS with
"Unsupported host platform". The script retries automatically with
`PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64`, which installs the 24.04 build
and works fine. `--with-deps` is used so Playwright resolves the correct library
package names for this release itself — they differ between Ubuntu versions
(`libasound2` vs `libasound2t64`, etc.).

**`linger`.** Without `sudo loginctl enable-linger $USER`, every user systemd service
is killed the moment your SSH session closes. This is *the* reason a Hermes install
"works during setup then dies overnight". `03-verify.sh` checks it explicitly.

---

## 6. Step 3 — Honcho memory keys (on the VM)

Honcho is the memory layer. It does background user-modelling with its **own**
provider configuration and **has no Vertex support**, so it needs an AI Studio Gemini
key plus an OpenAI embeddings key. This is the one component not billed through your
GCP project.

```bash
nano ~/honcho/.env
#   LLM_GEMINI_API_KEY=...     # from https://aistudio.google.com/apikey
#   LLM_OPENAI_API_KEY=...     # embeddings

cd ~/honcho && sudo docker compose up -d
sudo docker compose ps
```

Hermes is already pointed at it — `HONCHO_BASE_URL=http://localhost:8000` was written
to `~/.hermes/.env` in step 6 of the installer.

> **Do not confuse the `gemini` and `vertex` providers.** Hermes chat uses the
> **`vertex`** provider (config.yaml + ADC, no API key). The **`gemini`** provider
> uses an AI Studio `GOOGLE_API_KEY`. Setting `GOOGLE_API_KEY`/`GEMINI_API_KEY` in
> `~/.hermes/.env` will switch Hermes to the wrong provider and produce
> `HTTP 400 — no access to model`. Honcho's Gemini key lives in `~/honcho/.env`,
> a completely separate file.

---

## 7. Step 4 — verify (on the VM)

```bash
bash ~/hermes-install/03-verify.sh
```

> ⚠️ **13/13 on an existing VM does not mean a fresh install works.** These checks
> confirm a *running* system is healthy; they cannot see fresh-state defects (an apt key
> written with the wrong mode, a script dying on an empty `.env`, a cold service that is
> slower than a fixed `sleep`). Validate install changes from a **virgin** install —
> `bash scripts/teardown.sh`, then 01 → 02 → 03 from zero. See the rule in
> [AGENTS.md](../../AGENTS.md); it exists because five such bugs survived three versions
> of "re-ran it, exit 0".

Targets **13/13**: Hermes CLI, a real Vertex `:generateContent` call, EU residency,
Chrome, Playwright, SearXNG JSON API, Honcho, dashboard service, linger.

> The Vertex check makes a genuine inference POST on purpose. A `GET` on a model
> resource can return 404 even when inference works perfectly — so a GET-based
> health check gives false failures.

Also worth running:

```bash
hermes doctor
hermes status
```

Some `hermes doctor` warnings are expected and fine — it flags optional integrations
you are not using (Discord, Spotify, xAI, OpenRouter, …).

---

## 8. Step 5 — connect the desktop app (on your PC)

**Open the secure gateway — install the LaunchAgent (this is the default).** One command,
and the tunnel then survives sleep, reboot and network changes:

```bash
bash gcp/vpc-install/scripts/install-gateway-launchagent.sh
```

It fills the plist placeholders from `00-vars.sh` and `which gcloud`, boots out any stale
agent, loads the job, and waits until the gateway actually answers before reporting
success. Verified 2026-08-18: killing the tunnel process had it back up in **~8s**.

> **Why the default is the agent, not a manual tunnel.** A hand-started
> `start-iap-tunnel` belongs to the shell that launched it and dies with that shell —
> closing the terminal, sleeping the Mac, or ending the session that started it all take
> the gateway down, and the desktop app then reports *"Remote gateway sign-in required"*
> as if something were wrong with your credentials.

Manual alternatives, for a one-off check:

```bash
bash gcp/vpc-install/scripts/gateway-tunnel.sh          # foreground wrapper, Ctrl-C to stop
bash gcp/vpc-install/scripts/gateway-tunnel.sh --status # is it up?
```

```bash
gcloud compute start-iap-tunnel hermes-agent 9119 \
  --local-host-port=localhost:9119 \
  --zone=europe-west2-b --project=test-disco-cm
```

**Connect the app.** Desktop app → **Settings → Gateway → Remote gateway**:

- Remote URL: `http://localhost:9119`
- **Sign in** — username is `DASHBOARD_USERNAME` from `00-vars.sh` (`kennet`), and if the
  installer generated the password it is on the **VM** at `~/.hermes-dashboard-password`
  (mode 600, never printed to the console):
  ```bash
  gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap \
    --command='cat ~/.hermes-dashboard-password'
  ```
- Reconnect

> An unauthenticated `GET /` returns **HTTP 302 → `/login`**. That is the auth gate
> working, not a failure — don't chase it.

**If the gateway will not come up**, check for a port fight before anything else — launchd
does not surface a failed bind, it just respawns while the log fills with *"Address already
in use"*:

```bash
lsof -nP -iTCP:9119 -sTCP:LISTEN     # who holds the port
launchctl list | grep -i hermes      # stale agents (status ≠ 0 means it is failing)
tail -f /tmp/hermes-gateway-tunnel.log
```

The pre-VPC install shipped a **`com.hermes.tunnel`** agent — an SSH `-L` tunnel to a VM in
`europe-west1-b` that no longer exists. It fails forever and competes for port 9119. The
installer script boots it out and archives its plist; it was found still loaded and
failing on 2026-08-18.

There is **no session token to copy**. Older notes describing a token paste are out
of date — in v0.19.0 the app signs in with username/password and reuses the session
for the chat WebSocket automatically. Make sure Gateway settings are set to
basic-auth, **not** OAuth.

Or just open **<http://localhost:9119>** in a browser — same backend, same login.

### Managing the gateway agent

```bash
launchctl kickstart -k gui/$(id -u)/com.hermes.gateway-tunnel   # force reconnect
bash gcp/vpc-install/scripts/install-gateway-launchagent.sh     # re-apply (idempotent)
bash gcp/vpc-install/scripts/install-gateway-launchagent.sh --uninstall
tail -f /tmp/hermes-gateway-tunnel.log
```

Reconnect after wake takes ~20–40s (launchd `ThrottleInterval` + gcloud cold start), so
give the app a moment before assuming it is broken. Re-running the installer is also how
you apply a changed VM, zone or port — it re-renders the plist from `00-vars.sh`.

> `configs/com.hermes.gateway-tunnel.plist` is a **template** with placeholders; it is not
> a valid plist on its own. Do not copy it into `~/Library/LaunchAgents/` by hand — that
> was the old procedure and it had two reliable failure modes: a bare `gcloud` (launchd
> reads no shell profile) and a literal `<you>` left in `HOME`, which fails with a
> credentials error that looks like an IAM problem. The script substitutes both and
> `plutil -lint`s the result.

### Prove that compute really is remote

In the desktop app, ask the agent:

```text
Create a folder ~/proof-it-runs-on-the-vm and write the output of `hostname` into it.
```

Then, on the VM:

```bash
ls ~/proof-it-runs-on-the-vm && cat ~/proof-it-runs-on-the-vm/*
```

The folder exists **on the VM** and the hostname is `hermes-agent`. Nothing was
created on your PC. That is the whole design: `terminal.backend: local` in the VM's
`config.yaml` means "local *to the machine running the agent*", and that machine is
the VM.

---

## 9. What runs where

| Component | Location | Port | Exposure |
|---|---|---|---|
| Hermes agent loop | VM | — | — |
| Dashboard (the gateway endpoint) | VM | `9119` | IAP range only |
| Gateway (cron / routines) | VM | — | — |
| Chrome + Playwright Chromium | VM | — | headless, no network listener |
| SearXNG | VM (Docker) | `8080` | **`127.0.0.1` only** |
| Honcho + Postgres/pgvector | VM (Docker) | `8000` | **`127.0.0.1` only** |
| Vertex AI inference | Google, `europe-west2` | — | via Private Google Access |
| State backup | `gs://…-hermes-memory` | — | hourly, SA-scoped |
| Desktop app / browser | Your PC | — | client only |

SearXNG and Honcho have **no authentication of their own**. They are bound to
`127.0.0.1` for exactly that reason. Never publish those ports and never add a
firewall rule for them.

---

## 10. Security model

**Layered, and each layer is independently sufficient to keep the box private:**

1. **No external IP.** The VM is unroutable from the internet. There is no address
   to scan or attack.
2. **No public ingress rule.** The only allows are from `35.235.240.0/20` — Google's
   IAP frontend. An explicit `deny-all-ingress` at priority 65000 backs that up.
3. **IAM-gated tunnels.** Reaching the VM requires `roles/iap.tunnelResourceAccessor`.
   Revoking that role cuts off access instantly, centrally, and audibly — no key
   rotation, no `authorized_keys` edits.
4. **Dashboard basic auth.** Bound to `0.0.0.0` *on purpose*: Hermes only engages
   its auth provider on a non-loopback bind. On `127.0.0.1` the dashboard runs with
   **auth OFF**. The `0.0.0.0` bind is safe precisely because of layers 1–2.
5. **Shielded VM** — Secure Boot, vTPM, integrity monitoring.
6. **OS Login** — SSH access follows IAM, not scattered `authorized_keys` files.
7. **No service-account key files.** The VM uses its attached SA. There is no
   credential to leak, commit, or rotate.

**Hardening still worth doing beyond a pilot:**

- Replace the plaintext dashboard password with
  `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH` (scrypt) and delete the plaintext line.
- Restrict `iap.tunnelResourceAccessor` to named users, not a group.
- Add VPC Service Controls if you need to prevent data egress to non-project GCS.
- Enable Cloud Audit Logs for Compute + IAP so tunnel opens are logged.

**Dashboard sessions expire every 12 hours** (`…_TTL_SECONDS=43200`). Re-login is
expected behaviour, not a fault.

---

## 11. Cost

| Item | Approx / month |
|---|---|
| VM `e2-standard-4`, europe-west2, 24/7 | ~$110 |
| 100 GB pd-balanced | ~$11 |
| Cloud NAT (gateway + data processing) | ~$35–45 |
| Vertex `gemini-3.7-flash` tokens, moderate daily team use | ~$75–180 |
| Honcho (AI Studio + OpenAI, outside GCP) | ~$3–20 |
| GCS backup | <$1 |
| **Total** | **~$235–365** |

Chrome, Playwright and SearXNG cost nothing beyond the VM they sit on — that is
the main saving versus a hosted search API.

Cost levers, cheapest first:

- **Switch to `gemini-2.5-flash`** via `/model` for routine work.
- **Use `/compress`** in long sessions; `/usage` shows consumption.
- **Drop to `e2-standard-2`** if you disable Chrome *and* SearXNG (4 GB is not
  enough for Chrome + Postgres + SearXNG together).
- **Stop the VM when genuinely idle** — but see the warning below.

> ⚠️ **If this is a production or team-facing service, do not stop the VM.** Stopping
> it kills the gateway, cron jobs, and any messaging bot. `linger` and
> `Restart=always` keep everything alive across reboots and logouts; they cannot
> help a stopped instance. The "stop when idle" lever is for a solo pilot only.
> Cloud NAT bills whether the VM is up or not — delete the NAT gateway too if you
> are pausing for a long time.

---

## 12. Design decisions & rejected alternatives

**SerpApi → SearXNG.** SerpApi was the original request, but it does not fit:
its GitHub organisation contains client libraries and an MCP wrapper around the
**hosted** API — there is no self-hostable server; it is **not** one of Hermes'
web backends (`exa, firecrawl, parallel, tavily, searxng, brave-free, ddgs, xai`);
and it publishes **no EU data-residency option**, which conflicts with the EU-region
requirement. **SearXNG** is a native Hermes backend, runs entirely on the VM, needs
no API key, and costs nothing. If you later want true Google SERP data, run
`serpapi-mcp` as an *additional* MCP tool rather than replacing the web backend.

**SearXNG's two load-bearing settings.** `search.formats` must include `json` —
SearXNG defaults to HTML only, and Hermes gets HTTP 403 "Forbidden format" without
it. This is the number-one cause of "SearXNG is running but search doesn't work".
And `server.limiter` must be `false`: the limiter is bot detection for public
instances and it blocks programmatic clients. Both are safe because the instance is
loopback-only.

**`terminal.backend: local`, not `ssh`.** Hermes *does* have an `ssh` backend
(`terminal.ssh_host` / `ssh_user` / `ssh_port` / `ssh_key`) that would let a locally
installed Hermes execute tools on a remote box. That is a different architecture —
the agent loop and inference would stay on your PC. Since the requirement is that
everything runs on the VM with the desktop app as a pure client, the agent runs on
the VM with `local`, and the desktop app attaches to the dashboard. Simpler, and
inference bills through the VM's service account.

**Model catalog is generated, and every entry must be probed.** `HERMES_MODELS` in
`00-vars.sh` is a space-separated list; `02-vm-install.sh` renders it into
`providers.vertex.models` and fails fast if the list is empty or if `HERMES_MODEL` is
not in it. Adding a model is a one-line edit — but probe it first, because a 404 model
still appears as a selectable row and fails only when picked.

**Model picker must be declared by hand.** Vertex has no `/models` discovery route
and uses ADC rather than a stored credential, so Hermes' `/model` picker and the
desktop dropdown list **only the currently-configured model** unless you declare a
`providers.vertex.models:` catalog in `config.yaml`. Editing the shipped list in
`hermes_cli/models.py` affects only the CLI flow, not the desktop picker, and is not
upgrade-safe — don't. If you use Hermes **profiles**, each profile's own
`config.yaml` needs the block.

**Probe models, don't trust docs.** The AI Studio docs page (`ai.google.dev`) lists
models that Vertex EU regions do not serve. AI Studio ≠ Vertex. Always probe:

```bash
# on the VM
TOKEN=$(curl -sf -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://REGION-aiplatform.googleapis.com/v1/projects/PROJECT/locations/REGION/publishers/google/models/MODEL:generateContent" \
  -d '{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}'
```

**Backups cover `~/.hermes`, not Honcho's database.** Honcho's Postgres data lives
in a Docker volume. The hourly rsync deliberately excludes `.env` (secrets), caches,
and lock files. For full coverage, snapshot the VM disk — see
[OPS-NOTES.md](OPS-NOTES.md) §6.

---

Day-2 operations — idle gateways, upgrades, service restarts, everything you do
over SSH — are in **[OPS-NOTES.md](OPS-NOTES.md)**.
