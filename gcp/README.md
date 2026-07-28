# Hermes Agent on GCP — `test-disco-cm`

> ⚠️ **The VM described below no longer exists** (`gcloud compute instances list`
> returned 0 items on 2026-07-28). Treat this page as the *last known* v1 install.
>
> **For a new install, use [`vpc-install/`](vpc-install/) instead** — a self-contained,
> cloneable rebuild with a private VPC, **no external IP**, IAP-only ingress, Ubuntu
> 26.04, Chrome + Playwright, self-hosted SearXNG search, Honcho memory, and
> `gemini-3.5-flash` on the strict-EU `europe-west2` endpoint (no `global`
> exception). Start at [`vpc-install/README.md`](vpc-install/README.md); ops
> runbook at [`vpc-install/OPS-NOTES.md`](vpc-install/OPS-NOTES.md).

All-GCP installation of the [Hermes agent](https://hermes-agent.nousresearch.com) with:

- **Models:** Vertex AI, `google/gemini-3.6-flash` (default) + `google/gemini-3.5-flash-lite` (switchable via `/model`), region `global` — ⚠️ EU-residency exception, these models are global-only on Vertex; see AGENTS.md
- **Knowledge (v2):** Vertex AI Search datastore — Google Drive connector + verified
  webpage URLs, via MCP — see [KNOWLEDGE-DATASTORE.md](KNOWLEDGE-DATASTORE.md)
- **Slack team bot:** gateway + per-channel personas — see [SLACK-TEAM-SETUP.md](SLACK-TEAM-SETUP.md)
- **Desktop app / browser UI:** dashboard service on the VM (`:9119`, basic-auth,
  reached over an SSH tunnel) — see [DESKTOP-SETUP.md](DESKTOP-SETUP.md)
- **Memory:** self-hosted [Honcho](https://github.com/plastic-labs/honcho) on the VM
  (Docker, Postgres/pgvector, :8000) — per-user memory modeling for the team bot.
  `MEMORY_PROVIDER` in `00-vars.sh` switches to `builtin` or `openviking` (v1).
  Note: Honcho's background reasoning needs its own AI Studio Gemini key +
  OpenAI embeddings key in `~/honcho/.env` — the one non-GCP-billed piece.
- **Storage:** hourly rsync to GCS (`~/.hermes`; Honcho state lives in its
  Postgres Docker volume — snapshot the VM disk for full coverage)
- **Auth:** one service account attached to the VM — no key files anywhere

| | |
|---|---|
| Project | `test-disco-cm` (881765721010) |
| VM | `hermes-agent`, e2-standard-2, Ubuntu 24.04, europe-west1-b |
| Service account | `hermes-agent@test-disco-cm.iam.gserviceaccount.com` |
| Backup bucket | `gs://test-disco-cm-hermes-memory` |

## Install

```bash
# 1. From your workstation (needs gcloud, project owner/editor):
bash gcp/01-gcp-setup.sh          # APIs, SA, bucket, VM; copies files to VM

# 2. On the VM:
gcloud compute ssh hermes-agent --zone=europe-west1-b
bash ~/hermes-install/02-vm-install.sh

# 3. Verify:
bash ~/hermes-install/03-verify.sh
hermes doctor && hermes memory status
hermes chat
```

Settings (project, zone, machine type, models) live in `00-vars.sh`.
To enable the desktop/browser UI during install, export a dashboard password first:
`export HERMES_DASHBOARD_PASSWORD='...'` before running `02-vm-install.sh`.

## Layout

```
00-vars.sh                     shared settings (incl. dashboard user/port)
01-gcp-setup.sh                run locally: provision GCP
02-vm-install.sh               run on VM: install + configure everything
03-verify.sh                   run on VM: health checks
configs/
  hermes-config.yaml           -> ~/.hermes/config.yaml (Vertex + memory provider)
  hermes.env                   -> appended to ~/.hermes/.env
  honcho.json.template         -> ~/.hermes/honcho.json (self-hosted Honcho)
  ov.conf.template             -> ~/.openviking/ov.conf (only if openviking)
scripts/
  dashboard-setup.sh           idempotent dashboard basic-auth + restart
  vertex-token-refresh.sh      metadata-server token -> ov.conf vlm.api_key
  memory-backup.sh             backup dir -> GCS rsync
systemd/ (user units)
  hermes-dashboard.service     dashboard on :9119 (basic-auth, tunnel-only)
  memory-backup.*              hourly GCS backup
  openviking.service           OpenViking server on :1933 (only if openviking)
  vertex-token-refresh.*       every 45 min, Vertex OAuth (only if openviking)
```

Docs: [DESKTOP-SETUP.md](DESKTOP-SETUP.md) · [SLACK-TEAM-SETUP.md](SLACK-TEAM-SETUP.md) · [KNOWLEDGE-DATASTORE.md](KNOWLEDGE-DATASTORE.md)

## How the Vertex-only auth works

- **Hermes → Vertex:** the VM's attached service account provides Application
  Default Credentials; Hermes mints OAuth tokens itself. No config beyond
  `provider: vertex` + project/region.
- **OpenViking embeddings → Vertex:** `google-genai` runs in Vertex mode via
  `GOOGLE_GENAI_USE_VERTEXAI=true` in `openviking.service`, using the same ADC.
- **OpenViking VLM → Vertex:** the OpenAI-compatible endpoint needs a bearer
  token in `api_key`. Vertex tokens expire after ~1h, so
  `vertex-token-refresh.timer` rewrites `ov.conf` and restarts OpenViking every
  45 min. If a restart every 45 min bothers you, alternatives: a Vertex
  Express-mode API key, or a local auth-injecting proxy.

## Known caveats

- EU data residency is a hard requirement: all services run in a European region.
  Vertex currently uses `global` (EU-residency exception) for gemini-3.6-flash / gemini-3.5-flash-lite,
  which are global-only on Vertex. Strict-EU fallback: `europe-west2` + `gemini-3.5-flash`.
  See AGENTS.md "EU data residency" for the model-availability matrix and UK caveat.
- If OpenViking's gemini embedding provider ignores the `GOOGLE_GENAI_USE_VERTEXAI`
  env vars, fallback is a plain Gemini API key (AI Studio) — still Google, but
  billed outside the GCP project. Test with `03-verify.sh` + a real chat session.
- OpenViking has no auth by default; it binds to localhost only. Don't open
  port 1933 in the firewall.
- Restore from backup: `gcloud storage rsync --recursive gs://test-disco-cm-hermes-memory/workspace ~/openviking_workspace`

## Running costs (approx.)

~$54/mo infra (VM + disk) + ~$45–100/mo Vertex tokens at moderate daily use
+ ~$2–8/mo embeddings/VLM + <$1 GCS ≈ **$100–160/month**.
Stop the VM when idle (`gcloud compute instances stop hermes-agent --zone=europe-west1-b`)
to drop infra to ~$5/mo.
