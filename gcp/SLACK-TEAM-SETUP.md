# Hermes as a Team Slack Bot with Google Drive Knowledge

**Do this after the base install (`01-gcp-setup.sh` → `02-vm-install.sh` → `03-verify.sh`) is up and running.**

Goal (the ["company brain"](https://youmind.com/landing/x-viral-articles/hermes-agent-box-company-brain) pattern, with Google Drive instead of Box):

| Channel | Audience | Behavior |
|---|---|---|
| `#marketing-ai` | Marketing team | Marketing assistant, reads the Marketing Drive folder |
| `#finance-ai` (private) | Finance group | Finance assistant, reads the Finance Drive folder |
| `#kennet-ai` (private) or DM | Only you | Full personal assistant, all tools |

Architecture: the **Hermes gateway** runs as a service on the `hermes-agent` VM and connects to Slack over **Socket Mode** (WebSockets — no public URL, the VM needs no open inbound ports). Google Drive folders are mirrored to the VM with **rclone** using the VM's service account, so the agent reads knowledge with its normal file tools.

> **Different goal? See [SUPPORT-BOT-SETUP.md](SUPPORT-BOT-SETUP.md).** This guide builds a
> *team* assistant (shared channels, shared memory, full toolset). For a **1:1 employee
> support desk** — one isolated DM session *and* separate memory per employee, a company
> `SOUL.md` persona on its own profile, and the agent restricted to knowledge-base search
> only — use that guide instead; it reuses Parts 1–4 here.

---

## Part 1 — Slack app

Create one app at <https://api.slack.com/apps> → "From scratch", in your workspace.

1. **Socket Mode** → enable → create an **app-level token** with scope `connections:write` → save the `xapp-...` token.
2. **OAuth & Permissions** → Bot Token Scopes:
   `chat:write`, `app_mentions:read`, `channels:history`, `groups:history`, `im:history`, `mpim:history`, `files:read`
   (`groups:history` is what lets it see **private** channels — needed for finance and personal.)
3. **Event Subscriptions** → enable, subscribe to bot events:
   `message.channels`, `message.groups`, `message.im`, `message.mpim`, `app_mention`
   > Docs warning: without `channels:history`/`groups:history` the bot **will not receive channel messages** — the most commonly missed step.
4. **Install to workspace** → save the `xoxb-...` bot token.
5. In Slack: create `#marketing-ai` (public), `#finance-ai` (private), `#kennet-ai` (private); invite the bot to each (`/invite @Hermes`). Copy each channel ID (channel details → bottom of the About tab).

## Part 2 — Hermes gateway config on the VM

Append to `~/.hermes/.env`:

```bash
SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
# Slack *user* IDs allowed to talk to the bot (profile → three dots → Copy member ID).
# You + marketing + finance members:
SLACK_ALLOWED_USERS=U0KENNET,U0MKT1,U0MKT2,U0FIN1,U0FIN2
```

Add to `~/.hermes/config.yaml` (replace the `C0...` IDs with yours):

```yaml
platforms:
  slack:
    reply_to_mode: "first"
    extra:
      reply_in_thread: true

slack:
  # Bot ignores every channel not listed here (1:1 DMs stay exempt —
  # but DM access is still gated by SLACK_ALLOWED_USERS).
  allowed_channels:
    - "C0MARKETING"
    - "C0FINANCE"
    - "C0KENNET"

  # Persona per channel — reinjected every turn.
  channel_prompts:
    "C0MARKETING": |
      You are the marketing team's assistant. Knowledge base:
      /data/gdrive/marketing (read-only mirror of the team's Google Drive
      folder). Ground answers in those documents and cite file names.
      Campaigns, copy, brand voice, competitor notes. Never discuss
      finance topics or other teams' documents here.
    "C0FINANCE": |
      You are the finance group's assistant. Knowledge base:
      /data/gdrive/finance. Ground every figure in a document and cite the
      file name; if a number is not in the documents, say so — never
      estimate financial figures. Confidential: never reference these
      documents or discussions outside this channel.
    "C0KENNET": |
      Personal assistant for Kennet. Full access: /data/gdrive (all
      mirrored folders) and all tools.

  # Optional: bind skills per channel (loaded at session start)
  # channel_skill_bindings:
  #   - id: "C0MARKETING"
  #     skills: [writing-plans]
```

Behavior to tell the teams: in channels the bot answers when **@mentioned** and continues in the thread without further mentions; DMs need no mention.

## Part 3 — Google Drive as the knowledge store

> **⚠️ Superseded:** for the team build we've since chosen **Vertex AI Search** (managed
> Drive connector + verified-webpage data store, via MCP) instead of the rclone mirror
> below — see [KNOWLEDGE-DATASTORE.md](KNOWLEDGE-DATASTORE.md). The rclone approach below
> remains a valid low-cost fallback.

Hermes has no native Google Drive tool, so mirror Drive to the VM with **rclone** — same idea as the article's Box CLI, including the service-identity security model: *Hermes gets its own Drive identity, and you share only the folders it needs.*

**One decision first — Shared Drive vs My Drive:** service accounts work cleanly with **Google Workspace Shared Drives** (add the SA as a member). Sharing personal "My Drive" folders with an SA works for reading but is second-class; since you're on Workspace (visma.com), put the knowledge folders in a Shared Drive.

On the VM:

```bash
sudo apt-get install -y rclone
mkdir -p /data/gdrive/{marketing,finance,personal}   # sudo mkdir + chown to your user

# The VM's attached service account can't be used by rclone directly for Drive;
# create a key for it (Drive API needs the key file):
gcloud iam service-accounts keys create ~/.config/rclone/hermes-drive-sa.json \
  --iam-account=hermes-agent@test-disco-cm.iam.gserviceaccount.com
```

Enable the **Google Drive API** in `test-disco-cm` (`gcloud services enable drive.googleapis.com`), then in Google Drive add `hermes-agent@test-disco-cm.iam.gserviceaccount.com` as a **Viewer/Content manager member of the Shared Drive** (or of the specific folders).

`~/.config/rclone/rclone.conf`:

```ini
[gdrive]
type = drive
scope = drive.readonly
service_account_file = /home/YOU/.config/rclone/hermes-drive-sa.json
team_drive = <SHARED_DRIVE_ID>        # from the Shared Drive URL
```

Sync script + timer (mirrors the memory-backup pattern already installed):

```bash
# ~/.local/bin/gdrive-sync.sh
#!/usr/bin/env bash
set -euo pipefail
rclone sync "gdrive:Marketing" /data/gdrive/marketing --drive-export-formats md,csv
rclone sync "gdrive:Finance"   /data/gdrive/finance   --drive-export-formats md,csv
rclone sync "gdrive:Kennet"    /data/gdrive/personal  --drive-export-formats md,csv
```

`--drive-export-formats md,csv` converts Google Docs/Sheets to Markdown/CSV so the agent can actually read them. Run it every 15 min with a systemd user timer (copy `memory-backup.{service,timer}` from `gcp/systemd/`, point `ExecStart` at this script, `OnUnitActiveSec=15min`).

> **Alternative:** a Google Drive **MCP server** (Hermes supports MCP: `/docs/guides/use-mcp-with-hermes`) gives live search/read without mirroring, but adds an OAuth dependency and per-query latency. The rclone mirror is simpler, faster for the agent, and read-only by construction. Start with rclone.

**Drive vs GCS, to answer the earlier question:** keep both, for different jobs. Google Drive = the *knowledge* store (humans edit docs there; rclone mirrors them in). GCS = the *memory* backup (OpenViking's machine-generated state). Don't move OpenViking's workspace to Drive — it isn't a filesystem, and the agent's memory isn't something the team should edit.

## Part 4 — Run the gateway as a service

```bash
hermes gateway install     # creates a systemd user service on Linux
hermes gateway start
hermes gateway status
```

The gateway keeps the Slack Socket-Mode connection alive, holds a **separate session per channel/DM**, and runs cron jobs. Manage adapters live with `/platform` in any authorized chat; sessions reset with `/reset` or on idle/daily schedules if configured.

## Part 5 — Isolation caveat, and when to split profiles

One bot = one Hermes profile = **one shared memory and one OpenViking store** across all three channels. Per-channel *sessions* are separate, but long-term memory is not — something learned in `#finance-ai` could in principle surface in `#marketing-ai`. The channel prompts instruct against it, but that's soft isolation.

If finance confidentiality needs to be *hard*, use Hermes **profiles** ("Running Many Gateways at Once" is a documented capability):

```bash
hermes profile create finance --clone
# Separate HERMES_HOME → own config, memory, sessions, OpenViking peer.
# Give the finance profile its own Slack app/tokens (or a second workspace token),
# only C0FINANCE in allowed_channels, and only /data/gdrive/finance mirrored.
```

Recommended rollout: **start with the single bot + per-channel prompts** (one service, one bill, simplest ops). Split finance into its own profile once the team actually puts confidential material through it.

## Verification checklist

- [ ] `hermes gateway status` shows Slack connected
- [ ] DM the bot → replies (you're in `SLACK_ALLOWED_USERS`)
- [ ] Non-allowlisted user DMs the bot → ignored
- [ ] `@Hermes` in `#marketing-ai` → answers in thread, marketing persona, cites a Drive file
- [ ] `@Hermes` in `#finance-ai` → finance persona; ask about a marketing doc → declines
- [ ] Message in a random channel the bot was invited to but isn't allowlisted → ignored
- [ ] Edit a doc in the Drive Marketing folder → within 15 min the bot sees the change
- [ ] `systemctl --user list-timers` shows gdrive-sync + memory-backup firing

## Added cost

Marginal: the gateway is idle-cheap on the existing VM; rclone sync is free; the real delta is more Vertex tokens from more users. Rough guess for a small marketing + finance team at casual use: **+$30–80/month** on `gemini-3.6-flash`, on top of the ~$100–160 base estimate.
