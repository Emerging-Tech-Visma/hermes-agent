# Hermes Agent on a private GCP VPC — cloneable install

A self-contained, reproducible install of a [Hermes agent](https://hermes-agent.nousresearch.com)
on Google Cloud. Copy this directory, change one file, run three scripts.

**Everything runs on the VM.** Your PC only runs the Hermes **desktop app** (or a
browser), which reaches the VM through an identity-gated **IAP gateway tunnel**. The
VM has **no external IP** and nothing is exposed to the internet. Ask the agent to
create a file or folder and it is created **on the VM**.

```
Desktop app / browser  ──IAP tunnel──►  GCE VM (no public IP, private VPC)
  (your PC, client only)                 ├─ Hermes dashboard :9119  ← the gateway endpoint
                                         ├─ Hermes gateway (cron / routines)
                                         ├─ Chrome + Playwright Chromium
                                         ├─ SearXNG      :8080  (localhost only)
                                         ├─ Honcho memory :8000  (localhost only)
                                         ├─ Vertex shim   :8900  (localhost only)
                                         └─ Vertex AI  gemini-3.6-flash @ global ⚠️
```

| | |
|---|---|
| OS | Ubuntu 26.04 LTS |
| VM | `e2-standard-4`, 100 GB pd-balanced, no external IP |
| Network | custom VPC + subnet, Private Google Access, Cloud NAT, IAP-only ingress |
| Data residency | infra + storage `europe-west2`; ⚠️ inference on `global` (not region-pinned) |
| Model | Vertex AI `gemini-3.6-flash` (default) + `gemini-3.5-flash` + `gemini-3.5-flash-lite` |
| Search | self-hosted SearXNG (no API key, nothing leaves the region but the query itself) |
| Memory | self-hosted Honcho (Postgres/pgvector), **backed by Vertex — no external API keys** |
| Browser | Chrome + Playwright Chromium, headless |
| Auth | one attached service account — **no key files anywhere** |
| Cost | ~$235–365/month at moderate daily team use |

Verified against **Hermes Agent v0.19.0**, GCP as of **2026-07-28**.

> **Status: executed end-to-end on `test-disco-cm`, 2026-07-28 — 8/9 verified.**
> Both scripts exited 0. Confirmed live: no external IP, IAP-only firewall (the only
> `0.0.0.0/0` rule is the DENY), Cloud NAT, Hermes v0.19.0, Chrome 150, Playwright
> Chromium, Vertex `gemini-3.6-flash` @ `global` HTTP 200 (all three models probed 200), SearXNG JSON API
> returning results, dashboard auth gate returning 401 unauthenticated and
> `{"ok":true}` on login, gateway active, linger on.
>
> **Honcho now runs on Vertex with zero external API keys** (v0.12.0) via a local
> OpenAI-compat shim. Verified end-to-end: a fact pushed into Honcho was extracted and
> correctly recalled, and stopping the shim makes the dialectic fail with HTTP 500 —
> proving the Vertex dependency. `03-verify.sh` is **9/9**.
>
> A full agent *turn* has not been scripted (the CLI TUI cannot be driven by piped
> stdin) — do that from the desktop app using the proof step in
> [INSTALL.md §8](INSTALL.md). The live run found and fixed two real defects; see
> [CHANGELOG 0.10.1](../../CHANGELOG.md). Model/region moved to the three latest
> flash models on `global` in [0.11.0](../../CHANGELOG.md).

---

## Install in three commands

```bash
# 0. Edit 00-vars.sh — project, region, VM name, dashboard user. This is the
#    ONLY file you change when cloning for a new team or company.

# 1. On your PC (needs gcloud + project Owner/Editor):
bash 01-gcp-setup.sh

# 2. On the VM:
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap
export HERMES_DASHBOARD_PASSWORD='choose-a-strong-password'
bash ~/hermes-install/02-vm-install.sh

# 3. Verify (on the VM) — targets 9/9:
bash ~/hermes-install/03-verify.sh
```

Two manual steps remain, both explained in [INSTALL.md](INSTALL.md):

- **Connect the desktop app** — open the gateway tunnel, then sign in.

Honcho needs no keys: `MEMORY_LLM_BACKEND=vertex` (the default) routes it through the
local Vertex shim, billed to this GCP project. Set `MEMORY_LLM_BACKEND=gemini` if you
would rather use a single AI Studio key.

### Then connect from your PC

```bash
gcloud compute start-iap-tunnel hermes-agent 9119 \
  --local-host-port=localhost:9119 \
  --zone=europe-west2-b --project=test-disco-cm
```

Desktop app → **Settings → Gateway → Remote gateway** → `http://localhost:9119`,
then **sign in** with your dashboard username and password. There is no token to
paste. Or open <http://localhost:9119> in a browser.

---

## Read these

| Document | What's in it |
|---|---|
| **[INSTALL.md](INSTALL.md)** | The full guide: architecture, region/model probe results, every step explained, security model, cost breakdown, and why each design choice was made (including why SearXNG replaced SerpApi). |
| **[OPS-NOTES.md](OPS-NOTES.md)** | Day-2 operations over SSH: **idle/wedged gateway recovery** (plus an automatic watchdog), **updating the Hermes backend**, **updating every other service**, setup the desktop app can't do, backup/restore, tunnel troubleshooting, and a symptom → cause table. |

---

## Files

```
00-vars.sh                    ← EDIT THIS. All settings live here.
01-gcp-setup.sh               run on your PC:  VPC, NAT, firewall, SA, bucket, VM, IAM
02-vm-install.sh              run on the VM:   Hermes, Chrome, Playwright, SearXNG, Honcho, services
03-verify.sh                  run on the VM:   9-point health check

INSTALL.md                    full installation guide
OPS-NOTES.md                  SSH operations / troubleshooting

configs/
  hermes-config.yaml          → ~/.hermes/config.yaml   (Vertex, model catalog, searxng, browser)
  hermes.env                  → ~/.hermes/.env          (non-secret pointers)
  searxng-docker-compose.yml  → ~/searxng/docker-compose.yml
  searxng-settings.yml        → ~/searxng/settings.yml  (JSON API + limiter off)
  honcho-vertex.env           → ~/honcho/.env  (Honcho via Vertex, no external keys)
  honcho-gemini-only.env      → ~/honcho/.env  (single AI Studio key alternative)
  com.hermes.gateway-tunnel.plist   macOS LaunchAgent — keeps the gateway tunnel alive

scripts/
  dashboard-setup.sh          idempotent dashboard basic-auth (run on the VM)
  memory-backup.sh            ~/.hermes → GCS rsync (hourly timer)
  vertex-openai-proxy.py      OpenAI-compat shim in front of Vertex (for Honcho)
  gateway-tunnel.sh           open the secure gateway (run on your PC)

systemd/ (user units, kept alive by linger)
  hermes-dashboard.service    dashboard on :9119 — the gateway endpoint
  hermes-gateway.service      cron / routines / messaging
  memory-backup.service/.timer
  vertex-openai-proxy.service Vertex shim on :8900
```

---

## Cloning this for another team or company

1. Copy this directory into the new repo.
2. Edit **`00-vars.sh`** only:
   - `PROJECT_ID`, `PROJECT_NUMBER`
   - `REGION` / `ZONE` — but see the warning below
   - `VM_NAME`, `MACHINE_TYPE`, `BOOT_DISK_SIZE`
   - `DASHBOARD_USERNAME`
   - `MEMORY_BUCKET` derives from `PROJECT_ID` automatically
3. Run the three commands above.
4. Grant each team member gateway access (see [OPS-NOTES.md](OPS-NOTES.md) §5):
   ```bash
   gcloud projects add-iam-policy-binding <PROJECT> \
     --member="user:person@example.com" \
     --role="roles/iap.tunnelResourceAccessor" --condition=None
   ```

> ⚠️ **Region and model are coupled — changing one can break the other.**
> `VERTEX_REGION` is `global` here because `gemini-3.6-flash` and
> `gemini-3.5-flash-lite` return **404 in every European regional endpoint** tested
> (west1/2/3/4, north1 — probed 2026-07-28). `gemini-3.5-flash` is regional only at
> `europe-west2`; `europe-west1` caps at `gemini-2.5-flash`. `global` is **not
> region-pinned** — the exception is scoped to inference, while VM/bucket/backups stay
> in `europe-west2`. If you change either setting, **re-probe**: the one-liner is in
> [INSTALL.md](INSTALL.md) §12, `03-verify.sh` makes a real inference call so a wrong
> pairing fails loudly, and it prints a residency warning while `global` is in use.
> Revert instructions: [INSTALL.md §2](INSTALL.md).

### Things that are deliberately not automated

- **Secrets.** Nothing in this directory contains a credential. The dashboard
  password comes from `HERMES_DASHBOARD_PASSWORD` in your shell; Honcho's keys are
  pasted into `~/honcho/.env` on the VM. Never commit either.
- **Honcho's keys.** They are third-party API keys that can't be minted from GCP.
- **Who may connect.** Access is IAM, granted per person, on purpose — so revoking
  is one command and needs no key rotation.

---

## Security posture in one paragraph

The VM has no external IP, so there is nothing to scan. The only firewall ingress is
`35.235.240.0/20` (Google's IAP frontend) on ports 22 and 9119, backed by an explicit
deny-all rule; there is no `0.0.0.0/0` allow anywhere. Reaching either port requires
an IAP tunnel, which requires `roles/iap.tunnelResourceAccessor` — so access is IAM,
auditable, and instantly revocable. The dashboard adds basic auth on top with 12-hour
sessions. SearXNG and Honcho have no authentication of their own and are therefore
bound to `127.0.0.1` only. Shielded VM and OS Login are on. Inference uses the VM's
attached service account, so there is no service-account key file to leak. Full
detail and the hardening backlog: [INSTALL.md](INSTALL.md) §10.
