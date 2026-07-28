# Changelog

All notable changes to this Hermes-on-GCP runbook are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning is **date-anchored semantic-ish**: this repo ships *runbooks*, not a
library, so the version tracks the **installable configuration** it describes.

- **MAJOR** — a new architecture you cannot reach by editing `00-vars.sh`
  (different network model, different host, different client topology).
- **MINOR** — a new install variant, a new service in the stack, or a changed
  default (model, region, provider).
- **PATCH** — corrections, re-probed facts, doc fixes, script robustness.

> **Verify, don't trust.** Every version here records facts that were true when
> probed. Model availability, image families and pricing all move. Each entry
> carries the date it was verified — re-probe before relying on it.

---

## [Unreleased]

- **Exercise a full agent turn** through the desktop app and confirm files/folders
  land on the VM (`INSTALL.md` §8). The CLI TUI cannot be driven by piped stdin, so
  this was not verifiable from a script.
- Replace the plaintext dashboard password with a scrypt
  `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH`.
- Optional: `serpapi-mcp` as an *additional* MCP tool for true Google SERP data,
  alongside SearXNG rather than replacing it.

---

## [0.12.0] — 2026-07-29

**Honcho now runs entirely on Vertex AI — zero external API keys.** Honcho's reasoning
bills to the same GCP project and service account as Hermes chat.

### Added

- **`scripts/vertex-openai-proxy.py`** — an OpenAI-compatible shim in front of Vertex,
  run as `vertex-openai-proxy.service` on `127.0.0.1:8900`. Python **stdlib only**, no
  dependencies. It exists because two things block pointing Honcho at Vertex directly:
  1. **Vertex OAuth tokens expire hourly**, but Honcho wants a *static* `api_key`. The
     shim mints a fresh token from the metadata server per request (cached, refreshed
     5 min before expiry) — no 45-minute container-restart loop.
  2. **Vertex's OpenAI-compat `/embeddings` endpoint is broken.** Verified 2026-07-28:
     HTTP 500 "Internal error" for *every* model name (`gemini-embedding-001`,
     `text-embedding-004/005`, with and without the `google/` prefix) in **both**
     `global` and `europe-west2`. The native `:predict` API works fine on the same
     models. The shim translates `/v1/embeddings` → `:predict` and converts back.
  Chat is a transparent pass-through including **SSE streaming**; only auth is added.
- **`configs/honcho-vertex.env`** — points all ten Honcho module transports at the shim.
- **`configs/honcho-gemini-only.env`** — single-AI-Studio-key alternative.
- **`MEMORY_LLM_BACKEND`** in `00-vars.sh`: `vertex` (default) | `gemini` | `manual`.
- **`OPS-NOTES.md` §8 — stop / start / reboot semantics**, with a per-component table of
  what returns automatically, and the fact that **Cloud NAT keeps billing while the VM is
  stopped**.
- **`OPS-NOTES.md` §9 — scenario cookbook**: shell in, update Hermes, restart the
  gateway, kill a wedged gateway, restart everything, re-apply managed config, inspect
  the shim, free disk, rotate the password, audit who can reach the box.

### Changed

- `HONCHO_MODEL` defaults to `google/gemini-2.5-flash`, **not** 3.6-flash: 3.6-flash
  spends output budget on reasoning tokens (observed `max_tokens=20` consumed entirely
  by 16 reasoning tokens, empty content), which is wasteful for short structured
  extractions.
- Embeddings pinned to `europe-west2` via the native API — **EU-resident even though
  chat uses `global`**. Dimensionality forced to **1536** to match Honcho's pgvector
  column; `gemini-embedding-001` returns 3072 by default, which would fail every insert.

### Fixed

- **A stray manually-started proxy masked a failing systemd unit.** During testing a
  `nohup` process held port 8900, so the real unit was in a restart loop
  (`Result=exit-code`) while everything *appeared* healthy — the install would have
  survived a reboot by luck, not design. Killed the stray; the unit now owns the port.
  *Lesson: verify which PID owns the port, not just that the port answers.*

### Verified live (2026-07-29)

End-to-end memory extraction through Vertex, with **no external keys configured**:

| Step | Result |
|---|---|
| Shim health / chat / **streaming** | 200 / 200 / real SSE deltas |
| Shim embeddings | 200, **1536 dims** (batch of 2 → 2 × 1536) |
| Reachable from Honcho container | ✅ via compose gateway `172.19.0.1` |
| Message ingest (`POST /v3/.../messages`) | **201** |
| Deriver extraction errors | **0** |
| Dialectic recall | *"Kennet works at Visma in Denmark and strongly prefers Bun over npm for TypeScript projects."* — exactly the inserted fact |
| **Falsification: shim stopped** | dialectic → **HTTP 500** |
| **Falsification: shim started** | dialectic → **HTTP 200**, fresh answer |
| `03-verify.sh` | **9/9** |

The falsification pair is the real proof: Honcho's LLM calls demonstrably depend on the
shim, so they are demonstrably going to Vertex.

Reboot-survival audited: Honcho's shipped compose already has `restart: unless-stopped`
on all four services, Docker is `enabled` at boot, and all four user units are `enabled`
under linger. Internal IP `10.10.0.2` persists across stop/start. **Only the client-side
IAP tunnel needs re-opening.**

### Known limits

- Vertex may not support OpenAI `json_schema` structured output over the compat
  endpoint; if Honcho's extraction ever returns malformed JSON, set
  `DERIVER_MODEL_CONFIG__STRUCTURED_OUTPUT_MODE=json_object`.
- The shim has **no authentication** — it hands Vertex access to anything that can reach
  it. Safe only because this VM has no external IP and the firewall admits only Google's
  IAP range. Never expose port 8900.
- Reading the shim's access log needs `systemd-journal` group membership
  (`sudo usermod -aG systemd-journal $USER`, then re-login).

---

## [0.11.1] — 2026-07-28

### Fixed

- **Re-running the installer silently logged out every client.**
  `dashboard-setup.sh` regenerated `HERMES_DASHBOARD_BASIC_AUTH_SECRET` on every run.
  That secret signs dashboard session tokens, so a routine re-run of
  `02-vm-install.sh` — e.g. to change the model list in 0.11.0 — invalidated all live
  sessions. The desktop app then reported **"Remote gateway session has expired /
  Lost connection to the gateway"**, which reads like a broken tunnel or a dead VM
  rather than an intended logout, sending you diagnosing the wrong layer entirely.
  The secret is now **preserved** when one already exists; rotate deliberately with
  `ROTATE_DASHBOARD_SECRET=1 dashboard-setup.sh …` (do that if a password may have
  leaked). Verified on the live VM: re-running leaves the secret byte-identical, keeps
  exactly 4 auth lines, and an existing session stays valid.

  *Diagnostic note for the future:* the desktop log line
  `Cached remote Hermes backend failed liveness probe` alongside a tunnel that answers
  `HTTP 302` and credentials that return `{"ok":true}` means the transport is fine and
  the **session** is stale — click "Sign out & sign in", don't touch the tunnel.

---

## [0.11.0] — 2026-07-28

Switches chat to **the three latest Gemini flash models**, which requires moving
inference to the Vertex `global` endpoint. Owner-approved; **infrastructure stays in
`europe-west2`**.

### Changed

- **Model catalog is now the three newest flash models**, replacing the 3.5/2.5 pair:
  | | |
  |---|---|
  | `google/gemini-3.6-flash` | **default** |
  | `google/gemini-3.5-flash` | switchable |
  | `google/gemini-3.5-flash-lite` | switchable |

  Removed: `gemini-2.5-flash`, `gemini-2.5-pro`.
- **`VERTEX_REGION` → `global`.** ⚠️ **EU-residency exception, inference only**
  (owner decision, re-affirmed 2026-07-28). `global` is not region-pinned.
  **Everything else stays in `europe-west2`** — VM, subnet, GCS bucket, backups,
  SearXNG, Honcho — so **data at rest remains in a European region**. Only the
  inference endpoint is unpinned. This restores the same posture as v0.9.0 and
  reverses 0.10.0's move to a strict regional endpoint.
- **`HERMES_MODEL_ALT` replaced by `HERMES_MODELS`**, a space-separated list.
  `02-vm-install.sh` generates the `providers.vertex.models` YAML block from it, so
  adding or removing a model is a one-line edit in `00-vars.sh` instead of a
  template change. The installer now also **fails fast** if `HERMES_MODELS` is empty
  or if `HERMES_MODEL` is not present in it (which would show a picker that excludes
  the running model).

### Why `global` is unavoidable for these models

Re-probed 2026-07-28 (`:generateContent` POST, HTTP status):

| Model | eu-w1 | eu-w2 | eu-w3 | eu-w4 | eu-n1 | global |
|---|---|---|---|---|---|---|
| `gemini-3.6-flash` | 404 | 404 | 404 | 404 | 404 | **200** |
| `gemini-3.5-flash` | 404 | **200** | — | 404 | — | **200** |
| `gemini-3.5-flash-lite` | 404 | 404 | — | — | — | **200** |

No European regional endpoint serves 3.6-flash or 3.5-flash-lite. **To revert:**
`VERTEX_REGION="europe-west2"` + `HERMES_MODELS="google/gemini-3.5-flash google/gemini-2.5-flash"`,
and re-probe — flip back the moment the newer models land in a European region.
`03-verify.sh` prints a residency warning whenever `global` is in use.

### Fixed

- **`awk -v` with a multi-line value is not portable.** The first implementation of
  the model-list substitution used `awk -v repl="$MULTILINE"`, which works with GNU
  awk (the Ubuntu VM) but fails on BSD/macOS awk with `awk: newline in string`. It
  would therefore have worked on the VM and broken for anyone cloning the repo on a
  Mac. Now uses `python3`, which is guaranteed on both.
- **Model list built with `printf` + an explicit array** instead of `$'\n'`
  concatenation and unquoted word-splitting. `for m in ${HERMES_MODELS}` does **not**
  split in zsh (the macOS default shell), which silently yields a single malformed
  model name; `read -r -a` splits the same way everywhere.

### Verified live after the change (2026-07-28)

`02-vm-install.sh` re-run on the existing VM, exit 0. All three models probed from
the VM's own service account at `global`: **200 / 200 / 200**. `config.yaml` shows
`model: google/gemini-3.6-flash`, `region: global`, exactly three catalog entries, no
2.5 models. `03-verify.sh`: **8/9** with the expected residency warning; gateway and
dashboard restarted and active; gateway unit correctly preserved
(`keeping the Hermes installer's own unit`); Honcho still correctly reported as
missing its keys.

---

## [0.10.1] — 2026-07-28

Fixes found by **actually running 0.10.0 end-to-end** against `test-disco-cm`.
Both were real defects that static validation could not have caught.

### Fixed

- **`03-verify.sh` reported a false PASS for Honcho.** The check used
  `curl -o /dev/null -w '%{http_code}' … || echo 000`. On a connection failure curl
  *already* prints `000` **and** exits non-zero, so `|| echo 000` concatenated into
  `000000`, which compared unequal to `"000"` and passed. The first live run reported
  a confident **9/9 including `Honcho listening (/health -> HTTP 000000)`** while
  nothing was listening on `:8000` at all. Now captures plainly, defaults only when
  empty, and matches with a `case` — the same run then correctly reported **8/9**
  with Honcho failing. *Lesson: a health check that cannot fail is worse than no
  health check.*
- **`02-vm-install.sh` clobbered the Hermes installer's gateway unit.** The official
  installer generates its own `hermes-gateway.service` at the same path, and it is
  strictly better than our template — it encodes Hermes' restart semantics
  (`RestartForceExitStatus=75`, `RestartPreventExitStatus=78`), `KillMode=mixed`, a
  SIGUSR1 `ExecReload`, an `ExecStopPost` cgroup cleanup, and the venv
  `PATH`/`VIRTUAL_ENV`. The installer now **detects and preserves** an existing unit,
  prefers `hermes gateway install` when none exists, and treats
  `systemd/hermes-gateway.service` as a documented fallback only.

- **`MEMORY_PROVIDER=builtin` would have written an invalid config.** There is no
  Hermes memory provider named `builtin`. Source of truth (`hermes_cli/config.py`
  memory defaults): `"provider": ""` with the comment *"External memory provider
  plugin (empty = built-in only)"* — built-in is selected by an **empty string**, and
  the registered plugins are `honcho, openviking, mem0, hindsight, holographic,
  retaindb, byterover, supermemory`. `00-vars.sh` advertised `builtin` as a value and
  the template rendered it straight through, naming a plugin that does not exist.
  `02-vm-install.sh` now translates `builtin|none|off|""` → `""`, verified to render
  `memory.provider: ''` while `honcho` still renders `'honcho'`.
- **Placeholder API keys read as "configured".** `~/honcho/.env.template` ships
  *non-empty* dummy values (e.g. `LLM_OPENAI_API_KEY=your-openai-key`), so a
  `grep -qE '^KEY=.+'` test reports the key as set and Honcho then fails to start
  with a confusing downstream error. `02-vm-install.sh` now validates **both** keys
  against empty, known placeholder patterns, and a minimum length. Same root cause as
  the false-PASS above: **non-empty is not the same as valid.**

### Added

- **`RestartPreventExitStatus=78` is now documented as an ops fact:** a Hermes config
  error exits `78` and deliberately does *not* restart-loop. A gateway that is
  `inactive (dead)` immediately after a config change is usually this — read the
  journal instead of forcing restarts (`OPS-NOTES.md` §2).

### Verified live on `test-disco-cm` (2026-07-28)

Provisioning and install both exited 0. Independently audited afterwards:

| Check | Result |
|---|---|
| VM external IP | **none** (internal `10.10.0.2`) |
| Firewall ALLOW rules | only `35.235.240.0/20` → `tcp:22`, `tcp:9119`, target-tagged |
| `0.0.0.0/0` rules | **only the DENY** at priority 65000 |
| Cloud NAT / Private Google Access | `hermes-nat` up / `True` |
| Hermes | v0.19.0 (2026.7.20) |
| Chrome | 150.0.7871.186 |
| Playwright | `chromium-1234` + `chromium_headless_shell-1234` |
| Vertex `gemini-3.5-flash` @ `europe-west2` | **HTTP 200** |
| SearXNG JSON API | **HTTP 200, 20–32 results** |
| Dashboard | `hermes-dashboard.service` active, `:9119` on `0.0.0.0` |
| Dashboard auth gate | `401` without credentials — auth is **ON** |
| Dashboard login | `POST /auth/password-login` → **200 `{"ok":true}`** |
| Gateway | active (installer's unit) |
| linger | `Linger=yes` |
| Honcho | **not running** — needs its own LLM keys (expected) |
| Overall | **8/9**, the one failure being Honcho by design |

Also learned: the dashboard login payload requires a `provider` field —
`{"provider":"basic","username":…,"password":…}` — and `/api/auth/providers`
advertises `{"name":"basic","supports_password":true}`. Raw HTTP Basic (`curl -u`)
does **not** authenticate; the flow mints a session token. Ubuntu 26.04 ships glibc
2.43 and Playwright installed without needing the platform override.

---

## [0.10.0] — 2026-07-28

First versioned release. Adds a **private-network install** that supersedes the
original public-IP setup, and corrects the repo's stale "current install" claims.

### Added

- **`gcp/vpc-install/` — a complete, cloneable install package.** Self-contained
  alternative to the original `gcp/` scripts, not an add-on. 19 files:
  - `00-vars.sh` — single source of truth; the only file you edit when cloning.
  - `01-gcp-setup.sh` — custom VPC + subnet (Private Google Access), Cloud Router
    + Cloud NAT, IAP-only firewall, service account, GCS bucket, VM, operator IAM.
  - `02-vm-install.sh` — Hermes, Chrome + Playwright, SearXNG, Honcho, systemd
    services, hourly GCS backup. Idempotent.
  - `03-verify.sh` — 9-point health check including a real Vertex
    `:generateContent` call.
  - `README.md` / `INSTALL.md` / `OPS-NOTES.md`.
- **Private-network architecture.** VM has **no external IP**. The only firewall
  ingress is Google's IAP range (`35.235.240.0/20`) on `tcp:22` and `tcp:9119`,
  backed by an explicit deny-all at priority 65000. No `0.0.0.0/0` allow exists.
  Access requires `roles/iap.tunnelResourceAccessor`, so it is IAM-gated,
  auditable and revocable with one command.
- **Secure gateway via IAP tunnel.** `gcloud compute start-iap-tunnel` replaces the
  plain SSH tunnel for both the desktop app and the browser. macOS LaunchAgent
  (`configs/com.hermes.gateway-tunnel.plist`) keeps it alive across sleep/reboot.
- **Self-hosted SearXNG** as the web-search backend — Docker, `127.0.0.1:8080`,
  JSON API enabled, generated `secret_key`.
- **Chrome + Playwright Chromium** on the VM, headless, with an automatic
  `PLAYWRIGHT_HOST_PLATFORM_OVERRIDE` fallback for unrecognised Ubuntu releases.
- **`hermes-gateway.service`** for cron/routines, plus a **gateway watchdog**
  recipe (`OPS-NOTES.md` §2c) — `Restart=always` cannot detect a gateway that is
  alive but wedged, so a timer probes `hermes gateway status` and restarts on failure.
- **`OPS-NOTES.md`** — SSH operations runbook: idle/wedged gateway recovery,
  in-place backend upgrades and post-upgrade config checks, per-service updates,
  the setup the desktop app cannot do, backup/restore (including Honcho's Postgres
  volume, which the GCS rsync does not cover), tunnel troubleshooting, and a
  symptom → cause table.
- **Top-level `README.md`** and this `CHANGELOG.md`.

### Changed

- **Default model → `google/gemini-3.5-flash`** on the **regional** European
  endpoint `europe-west2`, dropping the previous `global`-endpoint EU-residency
  exception. Switchable alternate is `gemini-2.5-flash`.
- **Region → `europe-west2`** (VM, subnet, bucket, Vertex) — the only European
  regional Vertex endpoint serving `gemini-3.5-flash`. The **UK-adequacy caveat**
  is documented, with two EU-member fallback paths.
- **OS → Ubuntu 26.04 LTS** (`ubuntu-2604-lts-amd64`), up from 24.04 LTS.
- **VM → `e2-standard-4` / 100 GB**, up from `e2-standard-2` / 50 GB. Chrome +
  Playwright + Postgres/pgvector + SearXNG + Valkey + Hermes do not fit in 8 GB.
- **Shielded VM** (Secure Boot, vTPM, integrity monitoring) and **OS Login** enabled.
- `AGENTS.md` "Canonical facts" — retitled to make clear it is **historical**, with
  the verification date and a pointer to the new variant.
- `gcp/README.md` — banner directing new installs to `vpc-install/`.

### Fixed

- **`AGENTS.md` claimed a running install that does not exist.** Verified
  2026-07-28: `gcloud compute instances list --project=test-disco-cm` returns
  **0 items**. The documented `hermes-agent` VM was gone, so every row of the
  canonical-facts table was stale. A rebuild is a fresh install, not a modification.
- VM creation in `01-gcp-setup.sh` now uses check-then-create instead of
  `|| echo "already exists"`, which was swallowing real failures (quota, bad image
  family, capacity) and then stalling in the SSH wait loop.

### Verified this release (re-probe before trusting)

Vertex `:generateContent` POST, **2026-07-28**:

| Model | europe-west2 | europe-west1 | europe-west4 | global |
|---|---|---|---|---|
| `gemini-3.5-flash` | **200** | 404 | 404 | 200 |
| `gemini-2.5-flash` | **200** | 200 | — | — |
| `gemini-2.5-pro` | 404 | 200 | — | — |
| `gemini-3.6-flash` | 404 | 404 | 404 | 200 |
| `gemini-3.5-flash-lite` | 404 | 404 | 404 | 200 |

Against the installed **Hermes Agent v0.19.0** source:

- Web-search backends are exactly
  `{parallel, firecrawl, tavily, exa, searxng, brave-free, ddgs, xai}`.
  **SerpApi is not among them.**
- `terminal.backend` accepts `local | docker | ssh | modal | daytona | singularity`.
- Honcho self-hosting uses `HONCHO_BASE_URL`; `HONCHO_API_KEY` is cloud-only.
- `hermes update` exists as an in-place upgrade path.
- `browser.cdp_url` / `BROWSER_CDP_URL` can point Hermes at a remote Chrome.

GCP image families available: `ubuntu-2204-lts`, `ubuntu-2404-lts-amd64`,
`ubuntu-2604-lts-amd64` (+ arm64 variants).

### Known gaps

- **Honcho needs its own keys.** It has no Vertex support, so it requires an AI
  Studio Gemini key + an OpenAI embeddings key in `~/honcho/.env`. Until those are
  filled, Honcho does not start and `03-verify.sh` check 7 fails by design. This is
  the only component not billed through the GCP project.
- **Dashboard password is plaintext** in `~/.hermes/.env` (mode 600). Fine for a
  pilot; use the scrypt hash beyond that.
- **SearXNG and Honcho have no authentication of their own** — hence the
  `127.0.0.1` binds. Never publish those ports.
- **The GCS backup excludes Honcho's Postgres volume.** Use `pg_dumpall` or a disk
  snapshot for full coverage (`OPS-NOTES.md` §6).

---

## [0.9.0] — 2026-07-22 *(retroactive — pre-changelog state)*

The original public-IP install, reconstructed here for continuity. Not a tagged
release; recorded so 0.10.0's changes have a baseline.

- All-GCP install on the `default` network, VM with an external IP, dashboard
  reached over a plain SSH tunnel.
- `europe-west1` / `europe-west1-b`, `e2-standard-2`, Ubuntu 24.04 LTS, 50 GB.
- Chat model `gemini-3.6-flash` on the Vertex **`global`** endpoint — a documented,
  owner-approved **EU-residency exception**, because 3.6-flash and
  `gemini-3.5-flash-lite` are global-only on Vertex.
- Knowledge via Vertex AI Search (Drive connector + verified URLs) over MCP, and an
  alternative reusing an existing ETAP knowledge graph over MCP + bearer token.
- Slack team/support bot with per-channel personas and profile isolation.
- Self-hosted Honcho memory; hourly GCS backup.
- Guides: `DESKTOP-SETUP.md`, `SLACK-TEAM-SETUP.md`, `KNOWLEDGE-DATASTORE.md`,
  `SUPPORT-BOT-SETUP.md`, `PROFILES-ISOLATION.md`, `EXTERNAL-KG-MCP.md`,
  `REFERENCE.md`, `SUBPROCESSOR-MONITOR-PLAN.md`.

---

[Unreleased]: https://github.com/
[0.10.0]: https://github.com/
[0.9.0]: https://github.com/
