# Hermes Reference — distilled for this GCP install

Curated from the official reference docs, kept to what matters for our setup.
Sources:
[env vars](https://hermes-agent.nousresearch.com/docs/reference/environment-variables) ·
[MCP config](https://hermes-agent.nousresearch.com/docs/reference/mcp-config-reference) ·
[skills catalog](https://hermes-agent.nousresearch.com/docs/reference/skills-catalog) ·
[FAQ](https://hermes-agent.nousresearch.com/docs/reference/faq)

## Environment variables we use (`~/.hermes/.env`)

**Dashboard auth** (see [DESKTOP-SETUP.md](DESKTOP-SETUP.md))
| Var | Notes |
|---|---|
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | activates the basic provider (with a password) |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | plaintext, hashed in-memory |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH` | **scrypt hash alternative** — prefer this over plaintext for anything beyond a pilot |
| `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | HMAC key (32+ bytes) signing session tokens — we generate with `openssl rand -base64 32` |
| `HERMES_DASHBOARD_BASIC_AUTH_TTL_SECONDS` | access-token lifetime, **default 12h** (re-login cadence) |
| `HERMES_DASHBOARD_OAUTH_CLIENT_ID` | Nous Portal OAuth (only if exposing publicly; we use tunnel + basic instead) |

**Slack** (see [SLACK-TEAM-SETUP.md](SLACK-TEAM-SETUP.md))
`SLACK_BOT_TOKEN` (`xoxb-`), `SLACK_APP_TOKEN` (`xapp-`, Socket Mode),
`SLACK_ALLOWED_USERS` (comma-separated user IDs), `SLACK_HOME_CHANNEL` (cron delivery target).
`SLACK_ALLOW_ALL_USERS=true` (labelled dev-only) opens the bot to any workspace member — used
deliberately for the all-employee support bot (gate = Slack org membership; see
[SUPPORT-BOT-SETUP.md](SUPPORT-BOT-SETUP.md) §6). Leave `SLACK_ALLOWED_USERS` blank when it's set.
Requires the App-Home Messages tab ON so employees can DM. For a narrower audience use the allowlist instead.

**Memory (Honcho)** — for self-hosted, set `HONCHO_BASE_URL` (default is Honcho cloud);
`HONCHO_API_KEY` only for cloud. We also configure `~/.hermes/honcho.json` with `baseUrl`.

**Model / gateway**
`HERMES_MODEL` / `HERMES_INFERENCE_MODEL` (process-level overrides; prefer `config.yaml`),
`HERMES_AGENT_TIMEOUT` (gateway idle timeout, default 1800s),
`HERMES_STREAM_READ_TIMEOUT` (raise to 1800 for very large contexts).

> **EU residency:** strict setup uses a regional European endpoint, never `global`. Current
> install accepts a `global` **exception** to run the latest models: `gemini-3.6-flash` (default)
> and `gemini-3.5-flash-lite` are Vertex `global`-only (probed 2026-07-22: 200 @ global, 404 in
> all 12 European regions). `gemini-3.5-flash` @ `europe-west2` remains the strict-EU fallback;
> EU-member regions cap at `gemini-2.5-flash`. See AGENTS.md "EU data residency".

> **Vertex nuance:** the generic env-var reference is AI-Studio-centric
> (`GOOGLE_API_KEY`/`GEMINI_API_KEY` → the `gemini` provider). Our **Vertex** setup is
> configured in `config.yaml` (`provider: vertex`, `vertex.project_id/region`) per the
> [Vertex guide](https://hermes-agent.nousresearch.com/docs/guides/google-vertex), with
> auth via the VM's attached service account (ADC) — no API key. Don't confuse the
> `gemini` provider (AI Studio key) with the `vertex` provider (GCP/ADC). Honcho, by
> contrast, genuinely needs an AI-Studio `gemini` key since it has no Vertex support.

## MCP config (for the Vertex AI Search knowledge tool)

MCP servers go under `mcp_servers` in `config.yaml`. HTTP server shape:

```yaml
mcp_servers:
  vertex-ai-search:
    url: "https://<vertex-ai-search-mcp-endpoint>"
    headers: {}            # or use auth below
    auth: oauth            # OAuth 2.1 PKCE — handles token persistence + refresh
    enabled: true
    timeout: 120
    connect_timeout: 60
    tools:
      include: []          # whitelist wins over exclude when both set
      exclude: []
```

Stdio servers use `command` + `args` + `env` instead of `url`. TLS/mTLS via
`client_cert` / `client_key` / `ssl_verify`. See [KNOWLEDGE-DATASTORE.md](KNOWLEDGE-DATASTORE.md)
for how this wires to the Drive + verified-URL datastores.

## Skills worth enabling for the team bot

From the catalog — bind per-channel via `slack.channel_skill_bindings` (see SLACK-TEAM-SETUP.md):

- **`google-workspace`** — Gmail, Calendar, **Drive, Docs, Sheets** via gws CLI / Python.
  A direct-access alternative/complement to the Vertex AI Search Drive connector: the
  agent can read/act on Drive live. Trade-off: no managed vector index or ACL-scoped
  retrieval — good for "open this doc", less good for "search across everything".
- **`plan`** — actionable markdown task plans without executing (good default for all channels).
- **`llm-wiki`** — build/query interconnected markdown knowledge bases.
- **`ocr-and-documents`** — extract text from PDFs/scans (pymupdf, marker-pdf).
- **`blogwatcher`** — monitor blogs / RSS-Atom feeds (useful for the marketing channel).

## Operational facts (FAQ)

- **License / cost:** Hermes is free/OSS; you pay only LLM API usage. **No telemetry** —
  conversations, memory, skills stay in `~/.hermes/`.
- **Token levers in-session:** `/compress` summarizes history to cut tokens; `/usage`
  shows consumption. Relevant given Vertex chat tokens dominate our cost.
- **Access control:** allowlist (user IDs), DM pairing (first messager claims access),
  or open. We use allowlist.
- **Dangerous-command blocking:** Hermes refuses destructive commands (e.g. `rm -rf`)
  and asks for approval — expected, not a bug.

## Troubleshooting (FAQ + our experience)

| Symptom | Cause / fix |
|---|---|
| **HTTP 400 on first model call** | model name mismatch or key/SA lacks access. `hermes config show`, re-run `hermes model`. |
| **Gateway won't start** | missing deps (`uv pip install -e ".[messaging]"`), port conflict (`lsof -i :PORT`), bad tokens. Logs: `~/.hermes/logs/gateway.log`. |
| **Node/ffmpeg not found (macOS launchd)** | minimal PATH; re-run `hermes gateway install` to capture shell PATH, restart. |
| **Desktop can't sign in / "remote gateway incomplete"** | dashboard bound to loopback (auth OFF) or duplicate `.env` creds. Bind `0.0.0.0`; run `dashboard-setup.sh`. See AGENTS.md gotchas. |
| **Large-context stream timeouts** | set `HERMES_STREAM_READ_TIMEOUT=1800`. |
| **systemd unreliable (WSL only)** | use `tmux new -s hermes 'hermes gateway run'`. N/A on our Ubuntu VM. |
