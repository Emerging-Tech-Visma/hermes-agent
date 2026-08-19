# Hermes Agent on GCP — Replication Runbook

This repo documents how to install a **Hermes agent** ([nousresearch](https://hermes-agent.nousresearch.com))
on **Google Cloud** so it can be rebuilt from scratch on a new project/VM. The
scripted install lives in [`gcp/`](gcp/); this file is the human-readable "why"
and the lessons learned. Read this before running an install or debugging one.

> Purpose: this is a **learning / reference project** — document *everything* so a
> new installation can be reproduced without rediscovering the gotchas.

## What gets built

```
Slack (Socket Mode)  ┐
Desktop app / browser ┼─► Hermes gateway + dashboard on a GCE VM
                      ┘        ├─ chat model:  Vertex AI  gemini-3.7-flash (region: global — EU-residency exception)
                               ├─ knowledge:   Vertex AI Search (Google Drive connector + verified URLs) via MCP
                               └─ memory:      self-hosted Honcho (Docker: FastAPI + Postgres/pgvector, :8000)
```

All inference (chat, embeddings) bills to the GCP project via the VM's **attached
service account** (Application Default Credentials — no key files) — **including
Honcho's background reasoning**. Honcho has no Vertex transport of its own, so since
v0.12.0 its `openai` transport is pointed at a local shim
(`scripts/vertex-openai-proxy.py`) that forwards to Vertex and injects a fresh
service-account token per request. **There are no external API keys anywhere in this
install.**

## Canonical facts

### Current install — v0.13.0, private VPC (rebuilt from scratch 2026-08-18)

The live install is the **[`gcp/vpc-install/`](gcp/vpc-install/)** package. The v1 table
in the next subsection is **historical**.

**Provenance of this table: the whole install was torn down and rebuilt on 2026-08-18**
(`gcloud compute instances list` returned 0 items beforehand), so every row below was
observed on a from-scratch run of `01-gcp-setup.sh` + `02-vm-install.sh`, not carried
over from a previous edit. Note the internal IP changed (`10.10.0.2` → `10.10.0.3`) —
it is DHCP-assigned per VM creation, so **do not treat it as a fixed fact**.

| Thing | Value | Verified |
|---|---|---|
| Project ID / number | `test-disco-cm` / `881765721010` | ✅ |
| Region / zone (**infrastructure / data at rest**) | `europe-west2` / `europe-west2-b` (London, **UK — not EU-member**) | ✅ |
| VPC / subnet | `hermes-vpc` / `hermes-subnet` `10.10.0.0/24`, Private Google Access **on** | ✅ |
| VM | `hermes-agent`, `e2-standard-4`, **Ubuntu 26.04 LTS**, 100 GB pd-balanced, Shielded, OS Login | ✅ |
| VM internal IP / external | `10.10.0.3` / **none** — reassigned on each VM re-create, do not hardcode | ✅ 2026-08-18 |
| Egress | Cloud NAT `hermes-nat` via router `hermes-router` | ✅ |
| Ingress | `35.235.240.0/20` (IAP) → `tcp:22`, `tcp:9119`, target-tag `hermes-agent`; deny-all @ 65000. **No `0.0.0.0/0` allow rule exists.** | ✅ |
| Gateway to client | `gcloud compute start-iap-tunnel … 9119` → desktop app / browser at `localhost:9119` | — |
| Service account | `hermes-agent@test-disco-cm.iam.gserviceaccount.com` (`aiplatform.user`, `storage.objectAdmin`) | ✅ |
| Chat model / Vertex region | `google/gemini-3.7-flash` (default) + `gemini-3.5-flash` / **`global`** — ⚠️ EU-residency exception, **inference only**; VM/bucket stay `europe-west2` | ✅ probed 200/200 on 2026-08-18 |
| Web search | self-hosted **SearXNG**, Docker, `127.0.0.1:8080`, JSON API on | — |
| Browser | Chrome + Playwright Chromium, headless | — |
| Memory | self-hosted Honcho, Docker, `127.0.0.1:8000`, LLM = **`google/gemini-2.5-flash`** via the Vertex shim on `:8900` (NOT a 3.x model — see below); embeddings `gemini-embedding-001` @ `europe-west2`, **1536 dims** | ✅ 2026-08-18 |
| Honcho version | commit **`2163ab1`** (2026-08-18) — ⚠️ `02-vm-install.sh` does `git clone --depth 1` of Honcho `main`, which **pins nothing**. Every install gets whatever `main` is that day, so Honcho-specific facts here can go stale without anyone touching this repo. Record the SHA whenever you re-verify. | ✅ 2026-08-18 |
| Dashboard | `:9119`, bound `0.0.0.0` (required for auth), basic-auth, IAP-tunnel-only | — |
| Backup bucket | `gs://test-disco-cm-hermes-memory` | ✅ |

Operator IAM required to reach it: `roles/iap.tunnelResourceAccessor` + `roles/compute.osLogin`.

#### ⚠️ Honcho memory model: NEVER use a Gemini 3.x model (verified 2026-08-18)

`HONCHO_MODEL` must stay on **`google/gemini-2.5-flash`**. Setting it to
`gemini-3.5-flash` (or any 3.x) makes every Honcho dialectic query fail:

```
openai.BadRequestError: 400 - vertex returned 400:
  "Function call is missing a thought_signature..."
```

Gemini 3.x are thinking models: a function call they emit carries an opaque
`thought_signature` that Vertex **requires** back on the next turn. Over the
OpenAI-compat wire it arrives as `choices[0].message.extra_content.google.thought_signature`
— a Google extension the OpenAI format has no field for — so Honcho's OpenAI client
drops it when re-serialising the assistant message for the next tool iteration, and
Vertex rejects the conversation from iteration two onward. **The shim cannot fix this**;
it is a pass-through and cannot re-create a signature the client already discarded.
`gemini-2.5-flash` never issues one, so nothing is lost.

A/B on the live box, only this value changed: `3.5-flash` → HTTP 400 on all 3 retries,
no answer; `2.5-flash` → HTTP 200, recalled the seeded facts.

**This does NOT affect Hermes' own chat**, which runs `gemini-3.7-flash` happily — it
does not use the shim and its Vertex provider round-trips signatures properly (proved
with a real tool-using agent turn that wrote a file on the VM).

Beware: a single-shot completion through the shim **succeeds** with 3.5-flash, so port
liveness and shim-chat checks both pass on a dead dialectic. `03-verify.sh` **test 13**
is the only check that catches it — it seeds a fact and asserts the dialectic returns it.
Confirmed to fail on 3.5-flash and pass on 2.5-flash.

#### Honcho memory extraction — it works, but it is BATCHED (don't call it broken)

**Verified working 2026-08-18** on Honcho `2163ab1`: nine facts seeded in one session were
each extracted correctly, and Hermes' own agent turn was derived too (a conclusion
`"hermes created a file"` appeared in the `hermes` workspace under the Hermes user peer).

Two things make a healthy install *look* broken. Both cost real debugging time here, so
check them before concluding anything is wrong:

**1. The deriver batches on purpose — expect up to 30 minutes.** `queue/status` sitting at
N pending / **0 in-progress** / 0 completed is normal for a quiet install. The deriver
claims a representation work unit only once either gate opens
(`src/deriver/queue_manager.py::get_and_claim_work_units`):

| Setting | Default | Meaning |
|---|---|---|
| `DERIVER_REPRESENTATION_BATCH_WORK_UNIT_TARGET_TOKENS` | **512** | accumulate this many tokens before claiming |
| `DERIVER_REPRESENTATION_BATCH_MAX_AGE_SECONDS` | **1800** | …or claim anyway once the oldest item is this old |
| `DERIVER_FLUSH_ENABLED` | `false` | `true` bypasses the accumulation gate |

A few short test messages are nowhere near 512 tokens, so nothing happens for **30
minutes**. Polling backoff is *not* the cause (max interval is only 30s). To verify
derivation immediately, open the gate rather than waiting — set
`DERIVER_REPRESENTATION_BATCH_WORK_UNIT_TARGET_TOKENS=0` in `~/honcho/.env`, recreate the
deriver, and the queue drains in ~40s. **Put it back afterwards**: 0 disables batching for
good and means one LLM call per message, which costs real money.

**2. `POST …/peers/{peer}/representation` with `{}` returns `{"representation":""}` even
when memory exists.** You must pass the session:
`-d '{"session_id":"<session>"}'`. An empty body is not an error and looks exactly like
"nothing was extracted" — this is what made the batching above look like a hard failure.
`POST …/peers/{peer}/search` needs no session and is a quicker sanity check;
`conclusions/query` requires `observer`/`observed` inside a `filters` object.

For the same reason, `03-verify.sh` test 13 asserts on the **dialectic answer**, which is
available immediately, and not on the representation — a representation assertion would
fail for 30 minutes after every fresh install.

### v1 install (historical — public IP, `europe-west1`, `global` endpoint)

Kept because the Slack / knowledge / profiles guides still reference it. **The VM
described here no longer exists.**

| Thing | Value |
|---|---|
| Project ID / number | `test-disco-cm` / `881765721010` |
| Region / zone (VM, bucket) | `europe-west1` / `europe-west1-b` (EU-proper, Belgium) |
| VM | `hermes-agent`, `e2-standard-2`, Ubuntu 24.04, 50 GB pd-balanced |
| Service account | `hermes-agent@test-disco-cm.iam.gserviceaccount.com` (`roles/aiplatform.user`, `roles/storage.objectAdmin`, `roles/discoveryengine.viewer`) |
| Memory backup bucket | `gs://test-disco-cm-hermes-memory` |
| Chat model / Vertex region | `google/gemini-3.6-flash` (default); picker also offers `gemini-3.5-flash` + `gemini-3.5-flash-lite` (via `providers.vertex.models`) / `global` — ⚠️ EU-residency exception, see below |
| Embedding model | `gemini-embedding-2-preview` (only if using OpenViking) |
| Dashboard | `:9119`, basic-auth, tunnel-only (never firewalled open) |
| Honcho | `:8000`, localhost-only |

All of these are variables in [`gcp/00-vars.sh`](gcp/00-vars.sh) — change them there
to target a new project/VM.

## EU data residency (hard requirement)

**Rule:** all GCP services should run in a European region. Verified state: VM + bucket in
`europe-west1` (Belgium, EU). **Chat inference is the standing exception (see below).**

⚠️ **EU-residency EXCEPTION for the chat model (explicit owner decision, 2026-07-22,
re-affirmed 2026-08-18).** Hermes chat runs `gemini-3.7-flash` (default) with
`gemini-3.5-flash` as a switchable fallback, on the Vertex **`global`** endpoint, which
is NOT region-pinned. This knowingly relaxes the "regional European endpoint only" rule to get
the newest model. Everything else (VM, bucket, KG, datastore, Honcho, **embeddings**) stays
EU-region-pinned.

The catch, established by direct API probing (do not re-litigate without re-probing):
- **`gemini-3.6-flash` and `gemini-3.5-flash-lite` are Vertex `global`-only right now**
  (probed 2026-07-22: 200 @ `global`; **404 in all 12 European regional endpoints** —
  west1/2/3/4/6/8/9/12, central2, southwest1, north1/2). The AI-Studio docs page
  (`ai.google.dev`) lists them, but AI Studio ≠ Vertex; Vertex EU regions don't serve them yet.
- **`gemini-3.5-flash` is the only 3.x flash on a regional EU endpoint** — 200 @ `europe-west2`
  (London), 404 in every EU-*member* region. It is the **strict-EU fallback**.
- **EU-member regions top out at `gemini-2.5-flash` / `gemini-2.5-pro`** (200 in europe-west1).

**Re-probed 2026-07-28 (still holds):** `gemini-3.5-flash` → **200** @ `europe-west2`,
**404** @ `europe-west1` / `europe-west4`, 200 @ `global`. At `europe-west2`:
`gemini-2.5-flash` 200, but `gemini-2.5-pro` **404** and `gemini-3.6-flash` /
`gemini-3.5-flash-lite` **404**. So a west2 model catalog is exactly
`{gemini-3.5-flash, gemini-2.5-flash}`.

**Re-probed again 2026-07-28 (v0.11.0 decision):** `gemini-3.6-flash` 404 in
europe-west1/2/3/4 and north1, **200 @ `global`**; `gemini-3.5-flash-lite` likewise
`global`-only.

**Re-probed 2026-08-18 (v0.13.0 decision — supersedes the tables above):**

| Model | eu-w1 | eu-w2 | eu-w3 | eu-w4 | eu-n1 | global |
|---|---|---|---|---|---|---|
| `gemini-3.7-flash` | 404 | 404 | 404 | 404 | 404 | **200** |
| `gemini-3.6-flash` | 404 | 404 | 404 | 404 | 404 | **200** |
| `gemini-3.5-flash` | 404 | **200** | **200** | 404 | 404 | **200** |
| `gemini-3.5-flash-lite` | 404 | 404 | 404 | 404 | 404 | **200** |
| `gemini-2.5-flash` | **200** | **200** | **200** | **200** | **200** | **200** |

Two things moved since 2026-07-28 and both matter:
- **`gemini-3.7-flash` exists on Vertex and is `global`-only**, same shape as 3.6.
- **`gemini-3.5-flash` gained `europe-west3`** (was 404 there). The strict-EU fallback
  is widening — which is precisely why these tables carry dates. Re-probe, don't trust.

[`gcp/vpc-install/`](gcp/vpc-install/) therefore runs **`VERTEX_REGION=global`** with the
catalog `{gemini-3.7-flash (default), gemini-3.5-flash}` — the **EU-residency exception
applies to CHAT INFERENCE ONLY**; VM, subnet, bucket, backups, SearXNG, Honcho and
Honcho's **embeddings** (which use the regional `europe-west2` `:predict` endpoint) all
remain in `europe-west2`. Both models probed 200 from the VM's own service account.

`gemini-3.5-flash-lite` was **dropped from the catalog** in v0.13.0 — with 3.7-flash as
flagship and 3.5-flash as the EU-capable fallback, a third flash tier earned nothing. It
still answers 200 @ `global` if you want it back; re-add it to `HERMES_MODELS`.

**Reverting to strict EU residency:** set `VERTEX_REGION=europe-west2` + `HERMES_MODEL=google/gemini-3.5-flash`
(European, regional — UK/adequacy caveat; `europe-west3` = Frankfurt is now also an option
and **is** an EU member state), or `europe-west1` + `gemini-2.5-flash`. **Re-probe on every
revisit** — flip back to a regional endpoint the moment 3.7-flash lands in an EU region.

Probe any model/region before assuming availability:
```bash
# on the VM
TOKEN=$(curl -sf -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://REGION-aiplatform.googleapis.com/v1/projects/test-disco-cm/locations/REGION/publishers/google/models/MODEL:generateContent" \
  -d '{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}'
```
#### Getting the model NAME right — and proving the probe isn't lying to you

Canonical Vertex model IDs used here (validated 2026-08-18): **`gemini-3.7-flash`**,
**`gemini-3.5-flash`**, `gemini-3.5-flash-lite`, `gemini-2.5-flash`. In `00-vars.sh` and
`config.yaml` these carry Hermes' `google/` provider prefix (`google/gemini-3.7-flash`);
the raw Vertex REST path takes the bare id. `03-verify.sh` strips the prefix with
`${HERMES_MODEL#google/}`.

**A 200 alone does not prove the name is right — check the echoed `modelVersion`.** Vertex
rejects unknown ids (`gemini-9.9-flash`, `gemini-totally-fake-model` → *"Publisher model …
was not found"*), and a valid one echoes its own id back:

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://aiplatform.googleapis.com/v1/projects/test-disco-cm/locations/global/publishers/google/models/MODEL:generateContent" \
  -d '{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}' | jq -r '.modelVersion, .error.message'
```

If `modelVersion` comes back equal to the id you asked for, the name is real and served.
That check is what confirmed `gemini-3.7-flash` exists on Vertex even though
`ai.google.dev`'s Gemini 3.5 Flash page does not mention it — **AI Studio ≠ Vertex cuts
both ways**: AI Studio lists models Vertex won't serve, *and* Vertex serves models AI
Studio's pages don't document. That page does confirm `gemini-3.5-flash` as the stable id
(with `gemini-3-flash-preview` as its preview alias), matching what we use.

Also EU-pin anything added later: GCS `--location=europe-west1`, Vertex AI Search
datastore in an EU multi-region/`eu`, and if OpenViking is ever enabled its
`GOOGLE_CLOUD_LOCATION` (hardcoded `global` in `systemd/openviking.service`) must change.

## Install order

1. **Locally** (workstation with `gcloud`, project owner): `bash gcp/01-gcp-setup.sh`
   — enables APIs, creates SA + bucket + VM, copies files to the VM.
2. **On the VM** (`gcloud compute ssh hermes-agent --zone=europe-west1-b`):
   `export HERMES_DASHBOARD_PASSWORD='...'` then `bash ~/hermes-install/02-vm-install.sh`
   — installs Hermes, memory provider, dashboard service, systemd units.
3. **On the VM**: fill `~/honcho/.env` (Gemini + OpenAI keys), `cd ~/honcho && sudo docker compose up -d`.
4. **On the VM**: `bash ~/hermes-install/03-verify.sh` (targets 7/7 pass).
5. Then the manual, credential-bearing pieces:
   [`gcp/DESKTOP-SETUP.md`](gcp/DESKTOP-SETUP.md),
   [`gcp/SLACK-TEAM-SETUP.md`](gcp/SLACK-TEAM-SETUP.md),
   [`gcp/KNOWLEDGE-DATASTORE.md`](gcp/KNOWLEDGE-DATASTORE.md).
   - Variant: [`gcp/SUPPORT-BOT-SETUP.md`](gcp/SUPPORT-BOT-SETUP.md) — a **locked-down
     per-employee support bot** (DM-per-employee session + isolation, per-employee Honcho
     memory, `SOUL.md` persona on its own profile, `agent.disabled_toolsets` so the agent
     can *only* search the knowledge base). Sits on top of the Slack + knowledge guides.
   - Multi-agent variant: [`gcp/PROFILES-ISOLATION.md`](gcp/PROFILES-ISOLATION.md) — run
     **several isolated Slack agents on the one VM** via Hermes **profiles** (own persona /
     memory / knowledge / tools / Slack app per profile). Key facts: each profile needs its
     **own Slack app** (tokens can't be shared), and filesystem/`HOME` is **shared until you
     set `terminal.home_mode: profile`** — profiles are config/state isolation, not an OS sandbox.
   - Knowledge variant: [`gcp/EXTERNAL-KG-MCP.md`](gcp/EXTERNAL-KG-MCP.md) — instead of
     building our own datastore, point Hermes at an **existing knowledge base in the Visma
     Agentic Platform (ETAP)** via that platform's per-graph **MCP server** + bearer token
     (verified working 2026-07-20; reuse vs. build-your-own trade documented there).
   - **Private-network variant (recommended for new installs):**
     [`gcp/vpc-install/`](gcp/vpc-install/) — a **complete alternative to steps 1–4
     above**, not an add-on. Custom VPC + Cloud NAT, VM with **no external IP**,
     ingress only from Google's IAP range, Ubuntu 26.04, Chrome + Playwright,
     self-hosted SearXNG (replaces SerpApi/hosted search), Honcho-on-Vertex, and
     `gemini-3.7-flash` @ `global`. Desktop app + browser connect over
     `gcloud compute start-iap-tunnel` instead of a plain SSH tunnel. Guides:
     [`README.md`](gcp/vpc-install/README.md) ·
     [`INSTALL.md`](gcp/vpc-install/INSTALL.md) ·
     [`OPS-NOTES.md`](gcp/vpc-install/OPS-NOTES.md) (idle-gateway recovery, backend
     upgrades, service updates).
   - Worked example (plan): [`gcp/SUBPROCESSOR-MONITOR-PLAN.md`](gcp/SUBPROCESSOR-MONITOR-PLAN.md)
     — a **propose-only, approval-gated compliance agent** (GDPR subprocessor monitor) as a
     dedicated profile. Shows the three-plane split (GCP deterministic core + authority lane
     built first; thin Hermes agent mounted last), why **Vertex-EU inference** is the reason to
     host it on Hermes vs. ETAP, and how to reconstruct the propose-only boundary on Hermes
     (read/propose MCP tools only + `disabled_toolsets`; loader is an unreachable GCP service).

Distilled env-var / MCP-config / skills / troubleshooting reference (from the official
docs, keyed to our setup): [`gcp/REFERENCE.md`](gcp/REFERENCE.md).

## Lessons learned (the gotchas — DON'T rediscover these)

- **Service account IAM race.** Right after `gcloud iam service-accounts create`, an
  immediate `add-iam-policy-binding` can fail with "does not exist" — the SA hasn't
  propagated. Wait/poll until `gcloud iam service-accounts describe` succeeds, then
  bind. `01-gcp-setup.sh` is idempotent, so re-running it also recovers.
- **`gcloud compute scp --recurse` of a dir into an existing target nests it**
  (`hermes-install/gcp/...`). Re-runs cause this. `01` now `rm -rf`s the remote dir
  first; if you scp by hand, delete the target first.
- **Dashboard auth only engages on a non-loopback bind.** `hermes dashboard` on
  `127.0.0.1` runs with auth OFF; the desktop app then can't sign in. Bind
  `--host 0.0.0.0` (auth ON) and reach it via SSH tunnel — never open :9119 in the
  firewall. This is why `hermes-dashboard.service` uses `0.0.0.0`.
- **There is no session token to copy.** Older notes say "enter a session token" —
  in this version the desktop app just **signs in** with username/password and reuses
  the session automatically. If the app says "Remote gateway incomplete", the backend
  has no auth provider (loopback bind) — fix the bind, not the token.
- **`.env` credential duplication silently breaks login.** Appending auth lines twice
  (or leaving a `<placeholder>` password) leaves multiple
  `HERMES_DASHBOARD_BASIC_AUTH_*` sets; the wrong one wins. Always use
  [`gcp/scripts/dashboard-setup.sh`](gcp/scripts/dashboard-setup.sh) — it strips ALL
  existing lines then writes exactly one clean set. Note the file is `~/.hermes/.env`,
  NOT `~/.env`.
- **Wrong-machine paste is the #1 time sink.** Watch the prompt: `kennetkusk@hermes-agent`
  = VM, `kennetkusk@Mac` = laptop. Config/auth commands must run on the VM. When in
  doubt wrap them: `gcloud compute ssh hermes-agent --zone=europe-west1-b --command='...'`
  runs on the VM regardless of where your prompt is. (macOS `sed -i` also differs from
  Linux — another reason to run edits on the VM.)
- **`gcloud compute ssh` intermittently exits 255** (transient SSH). Just retry; the
  scripts are idempotent.
- **Vertex health check must be a real call.** A GET on a model resource can 404 even
  when inference works; verify with a `:generateContent` POST (see `03-verify.sh`).
- **Vertex model picker shows only the current model unless you declare a catalog.**
  Vertex has no `/models` discovery route and uses ADC (no stored credential), so Hermes'
  `/model` picker (and the desktop dropdown) lists ONLY the currently-configured model — the
  other switchable models never appear. Fix is pure config, not a code edit: add a
  `providers.vertex.models:` list to `config.yaml` (see `configs/hermes-config.yaml`); those
  IDs then show as selectable rows. Editing the shipped curated list (`hermes_cli/models.py`
  `_PROVIDER_MODELS`) only affects the CLI `hermes model` flow, not the desktop picker, and is
  not upgrade-safe — don't. Applies **per profile**: the serving profile's own
  `config.yaml` (e.g. `~/.hermes/profiles/<name>/config.yaml`) needs the block, not just the base.
- **Vertex region ≠ AI-Studio availability.** See "EU data residency" above — the newest
  flash models (`gemini-3.7-flash`, `gemini-3.6-flash`, `gemini-3.5-flash-lite`) are Vertex
  `global`-only; `gemini-3.5-flash` is the newest on a regional EU endpoint (europe-west2 and,
  since 2026-08-18, europe-west3), and EU-member regions otherwise cap at 2.5. The AI-Studio docs page lists models Vertex EU may not serve — always probe Vertex, not
  AI Studio. `03-verify.sh` now passes on `europe-*` OR the accepted `global`, and prints a
  residency warning when `global` is in use.
- **Tunnel dies on VM stop / Mac sleep.** The dashboard is a systemd service and
  self-heals on VM reboot; only the Mac-side tunnel needs rerunning.
- **Dashboard sessions expire every 12h** (`HERMES_DASHBOARD_BASIC_AUTH_TTL_SECONDS`
  default) — re-login is expected, not a fault. For anything past the pilot, replace the
  plaintext password with `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH` (scrypt).
- **External KG-over-MCP: rotate breaks Hermes silently; don't double the Bearer.** Reusing an
  ETAP "Database" (Knowledge Graph) via its MCP server ([`gcp/EXTERNAL-KG-MCP.md`](gcp/EXTERNAL-KG-MCP.md))
  ties Hermes to a **show-once bearer token**. Rotating/Detaching in ETAP invalidates it and does
  **not** notify Hermes — a burst of MCP 401s means "someone rotated in ETAP", re-paste the token.
  And with AUTHENTICATION=`Bearer token` the client adds the scheme itself: paste the raw `kgmcp_…`,
  never `Bearer kgmcp_…` (double scheme → 401).
- **Slack open access needs the App-Home Messages tab, not just the Hermes toggle.**
  `SLACK_ALLOW_ALL_USERS=true` (all-employee support bot) is the *Hermes*-side gate, but employees
  still can't DM the bot unless the Slack app's **App Home → Messages tab is ON**. Also generate an
  **app-level token** (`xapp-…`, scope `connections:write`) for Socket Mode — the manifest can't mint
  it. Signing secret / verification token are NOT used in Socket Mode.
- **SerpApi cannot be self-hosted and is not a Hermes backend.** Established
  2026-07-28 from the installed v0.19.0 source: the web backends are exactly
  `{parallel, firecrawl, tavily, exa, searxng, brave-free, ddgs, xai}`
  (`tools/web_tools.py` `_LEGACY_WEB_BACKENDS`). SerpApi's GitHub org is client
  libraries + an MCP wrapper around the **hosted** API — no self-hostable server —
  and it publishes no EU data-residency option. **SearXNG** is the native, local,
  key-free, EU-resident answer (`SEARXNG_URL`, backend name `searxng`).
- **SearXNG has two settings that silently break Hermes.** `search.formats` must
  include `json` (SearXNG defaults to HTML only → every Hermes search gets HTTP 403
  "Forbidden format" — the #1 "SearXNG is up but search fails" cause), and
  `server.limiter` must be `false` (the limiter is bot detection that blocks
  programmatic clients). Both safe when bound to `127.0.0.1`.
- **IAP TCP forwarding needs a firewall rule for each forwarded port.** A no-external-IP
  VM reached over `gcloud compute start-iap-tunnel` still needs
  `allow ingress 35.235.240.0/20 → tcp:<port>`, including the dashboard's 9119. That
  range is Google's IAP frontend, not the internet, and use is gated by
  `roles/iap.tunnelResourceAccessor` — so this is not a public exposure.
- **No external IP ⇒ Cloud NAT is mandatory, not optional.** Private Google Access
  only covers *Google* APIs (Vertex, GCS). Without a Cloud Router + NAT, `apt`, the
  Hermes installer, Docker Hub, Playwright/Chrome downloads, and **SearXNG's upstream
  engine fetches** all fail. NAT also bills while the VM is stopped.
- **`terminal.backend: ssh` exists** (`terminal.ssh_host` / `ssh_user` / `ssh_port` /
  `ssh_key`; env `TERMINAL_SSH_*`) — a *locally* installed Hermes can execute all
  tools on a remote box while the agent loop and inference stay local. Useful to know,
  but the opposite of the [`gcp/vpc-install/`](gcp/vpc-install/) design, which runs the
  agent **on the VM** (`backend: local`) with the desktop app as a pure client so
  inference bills through the VM's service account. `browser.cdp_url` /
  `BROWSER_CDP_URL` is the matching lever for pointing at a remote Chrome.
- **Playwright may reject a brand-new Ubuntu.** On 26.04 `npx playwright install` can
  fail with "Unsupported host platform"; `PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64`
  installs the 24.04 build and works. Use `--with-deps` so Playwright resolves the
  release-correct library names itself (`libasound2` vs `libasound2t64` differ by release).
- **`gemini` provider ≠ `vertex` provider.** The `gemini` provider uses an AI-Studio
  `GOOGLE_API_KEY`; our chat uses the `vertex` provider (config.yaml + ADC, no key).
  Mixing them up causes HTTP 400 "no access to model". Honcho has no Vertex transport of
  its own, but since v0.12.0 `MEMORY_LLM_BACKEND=vertex` routes it through the local shim,
  so it needs **no** AI-Studio key either — this install has zero external API keys.

## Ops quick reference

```bash
# Start / stop the VM (stop drops cost to ~$5/mo)
gcloud compute instances start hermes-agent --zone=europe-west1-b
gcloud compute instances stop  hermes-agent --zone=europe-west1-b

# SSH tunnel for desktop/browser UI (rerun after any VM stop or Mac reboot)
gcloud compute ssh hermes-agent --zone=europe-west1-b -- -L 9119:localhost:9119 -N -f

# Reset dashboard login (on the VM)
HERMES_DASHBOARD_PASSWORD='new-pw' dashboard-setup.sh kennet 9119

# Health check (on the VM)
bash ~/hermes-install/03-verify.sh
```

## Cost (moderate daily team use)

~$55/mo VM+disk + ~$75–180/mo Vertex chat tokens + ~$5–20/mo Vertex AI Search +
~$3–10/mo Honcho (AI Studio) ≈ **$140–265/month**. Chat tokens dominate; keep Flash
as default and stop the VM when idle.

> **Production / support-bot deployment runs 24/7 — do NOT stop the VM.** The "stop when idle"
> lever above is for a pilot only. For the always-on [support bot](gcp/SUPPORT-BOT-SETUP.md)
> the VM stays up (full ~$55/mo, no idle savings), user services survive logout via linger
> (already set by `02-vm-install.sh`), the gateway service is `enable`d for boot, and Honcho
> containers use `restart: unless-stopped`. Socket Mode means bot uptime is independent of the
> Mac-side dashboard tunnel. See SUPPORT-BOT-SETUP.md §"24/7 operation".

## Conventions for agents working in this repo

- Tooling: **UV** for Python/CLI, **Bun** for TS/web (per user global prefs).
- Secrets/credentials are **never** committed here — passwords come from env
  (`HERMES_DASHBOARD_PASSWORD`) or are set directly on the VM. Templates in
  `gcp/configs/*.template` use `__PLACEHOLDER__` tokens filled at install time.
- Keep this file and `gcp/` in sync when the install changes — this repo's whole
  point is faithful replication.
