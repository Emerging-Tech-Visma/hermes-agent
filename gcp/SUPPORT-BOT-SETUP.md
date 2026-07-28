# Hermes as a Locked-Down Employee Support Bot

**A different shape from [SLACK-TEAM-SETUP.md](SLACK-TEAM-SETUP.md).** That guide builds a
*team* assistant: shared channels (marketing / finance), shared memory, full toolset. This
guide builds a **1:1 support desk** for ~100 employees where every employee is isolated:

| Requirement | Mechanism |
|---|---|
| One private conversation per employee, no cross-talk | Slack **DMs** → one session per user (`group_sessions_per_user: true`) + Hermes' built-in cross-session isolation |
| Bot remembers *each* employee's details, kept apart | **Honcho** multi-user peers — each Slack user ID → its own peer (`runtimePeerPrefix`), so memory never bleeds between employees |
| Company identity / behaviour ("its own soul") | **`SOUL.md`** (system-prompt slot #1) on a dedicated **profile** |
| Agent can *only* search the knowledge base — no shell, no file edits, no web | **`agent.disabled_toolsets`** in `config.yaml` — strip everything except the knowledge-search MCP and memory |
| Knowledge store "like a Google Drive" the bot can read | **Vertex AI Search** datastore with the Drive connector (see [KNOWLEDGE-DATASTORE.md](KNOWLEDGE-DATASTORE.md)) |

**Do this after** the base install (`01-gcp-setup.sh` → `02-vm-install.sh` → `03-verify.sh`) is
green and the [Vertex AI Search knowledge layer](KNOWLEDGE-DATASTORE.md) is wired up.

Architecture:

```
Slack DMs (Socket Mode, per-employee session)
  → Hermes gateway  (profile: "support")  on hermes-agent VM
      → chat model:  Vertex AI  gemini-3.6-flash  (global — EU-residency exception)
      → knowledge:   Vertex AI Search  ← Google Drive connector   [ONLY tool the agent has]
      → memory:      self-hosted Honcho  — one peer per Slack user (per-employee segregation)
      persona:       ~/.hermes-support/SOUL.md   (company support identity)
      capability:    disabled_toolsets = everything except {mcp-vertex-ai-search, memory}
```

> **Why verify keys on the VM.** This repo's rule is faithful replication. The toolset names,
> the exact Honcho multi-user key placement, and the full toolset registry below were taken
> from the Hermes docs, not from our own probing. Before trusting them, confirm on the VM with
> `hermes tools` (interactive list) and `hermes config show`. Where something is doc-sourced but
> not yet VM-verified it is flagged **[verify on VM]**.

---

## 1. Dedicated profile — "its own soul and profile"

A Hermes **profile** is a separate `HERMES_HOME` → its own `SOUL.md`, `config.yaml`, memory, and
sessions. Give the support bot its own so its persona, locked-down toolset, and Slack app never
mix with your personal/desktop Hermes.

```bash
# on the VM
hermes profile create support --clone      # clones current config as a starting point
# The support profile's home is a separate dir, e.g. ~/.hermes-support (confirm the path
# it prints). All paths below are relative to THAT home, not ~/.hermes.  [verify on VM]
```

Run every `hermes ...` command for this bot with the profile selected (the CLI prints how —
typically `hermes --profile support ...` or by exporting `HERMES_HOME`). The gateway you install
in §7 must be the one launched under this profile.

## 2. Company persona — `SOUL.md`

`SOUL.md` is loaded verbatim into **slot #1 of the system prompt** (the identity position) and is
read **only** from the profile's `HERMES_HOME` — never the working directory. Write the support
identity there:

```markdown
# ~/.hermes-support/SOUL.md
You are the Visma internal support assistant. You help employees by answering
questions strictly from the company knowledge base.

Rules:
- Answer ONLY from the knowledge-base search tool. If the answer is not in the
  retrieved documents, say so plainly and point the employee to the right human
  team — never guess, never use outside/world knowledge.
- Always cite the document title or URL you drew each answer from.
- You have no other tools: you cannot run commands, browse the web, open files,
  or take actions. If asked, explain that you only answer knowledge questions.
- Be concise, friendly, and neutral. Keep each employee's details private to
  their own conversation.
```

Optional named overlays (per-topic tone) go under `agent.personalities` in `config.yaml` and are
switched in-session with `/personality <name>`; `SOUL.md` stays the baseline. For a single support
role you usually don't need them.

## 3. Per-employee memory — Honcho multi-user peers (the load-bearing change)

The base install's [`honcho.json.template`](configs/honcho.json.template) pins **one static
peer** — fine for a single user, but it would collapse all 100 employees into one shared memory.
For per-employee segregation, run Honcho in **gateway multi-user mode**: each platform user ID
resolves to its **own peer**, so what the bot learns about employee A is never visible in employee
B's conversation.

The three keys that decide the mapping. Per the Hermes docs, `workspace`/`peerName` are
**top-level** in `honcho.json`, while the per-user resolver keys nest **under `hosts.<profile>`**
(the resolver checks `pinUserPeer` → `userPeerAliases` → `runtimePeerPrefix`, in that order):

| Key (placement) | Set to | Effect |
|---|---|---|
| `hosts.hermes.pinUserPeer` | `false` | **Must be false.** `true` collapses every gateway user into the single top-level `peerName` (the thing we're avoiding). |
| `hosts.hermes.runtimePeerPrefix` | e.g. `"slack_"` | Every unmapped Slack user ID becomes its own peer, e.g. `slack_U01ABC2DEF3` → isolated memory per employee, automatically. |
| `hosts.hermes.userPeerAliases` | `{}` (optional) | Only to pin a specific user ID to a friendly peer name, e.g. `{"U01ABC2DEF3": "alice"}`. Leave empty; the prefix handles all 100. |

```jsonc
// ~/.hermes-support/honcho.json   (multi-user support bot)
{
  "baseUrl": "http://localhost:8000",
  "workspace": "hermes-support",        // top-level: shared environment ID
  "peerName": "support-user",           // top-level: fallback identity (used only if pinUserPeer=true)
  "hosts": {
    "hermes": {
      "enabled": true,
      "aiPeer": "hermes",
      "pinUserPeer": false,             // per-user peers ON — do not collapse employees
      "runtimePeerPrefix": "slack_",    // slack_U01ABC2DEF3 → one peer per employee
      "userPeerAliases": {}
    }
  }
}
```

Honcho itself is the same self-hosted Docker stack from the base install (FastAPI + Postgres/
pgvector on `:8000`, localhost-only). It still needs its **AI-Studio Gemini + OpenAI keys** in
`~/honcho/.env` — Honcho has no Vertex support; this is the one documented non-Vertex exception and
is **not** an EU-residency violation (see §8).

> **Honcho ≠ the built-in `memory` toolset.** Honcho is a *memory provider plugin*
> (`plugins/memory/honcho/`), so per-employee memory is injected as context by the provider — it is
> not one of the toolsets §5 disables. The built-in `MEMORY.md` / `USER.md` files (the `memory`
> toolset) are the *agent's own* notes and a *single* user profile; keep that toolset enabled in §5
> for the agent's note-taking/guidance, but the per-employee segregation comes from Honcho's peers.

## 4. Knowledge store — the "Google-Drive-like" datastore

Use **Vertex AI Search** with the **Google Drive connector**, per
[KNOWLEDGE-DATASTORE.md](KNOWLEDGE-DATASTORE.md): a GCP-native managed vector datastore that stays
in sync with a Google Drive (Shared Drive / folders), honours Drive ACLs, and is exposed to Hermes
as an **MCP** tool. Do that whole guide first, then come back here. Net result: the bot has exactly
one capability — query this datastore — which is precisely the restriction §5 enforces.

For a support bot, one datastore + one search app for the whole company is usually right (all
employees see the same support corpus). Split into per-team datastores only if some knowledge must
be invisible to some employees.

## 5. Tool lockdown — "only search the knowledge database"

This is the security core. Restrict capability persistently with **`agent.disabled_toolsets`** in
the profile's `config.yaml`. Unlike the `--toolsets` CLI flag, this key applies to the CLI **and
every gateway platform**, so it survives the systemd gateway.

```yaml
# ~/.hermes-support/config.yaml   (append to the base Vertex config)
agent:
  disabled_toolsets:
    - terminal        # no shell / command execution
    - file            # no reading/writing/patching files   (name is singular: `file`)
    - web             # no web_search / web_extract
    - browser         # no headless browsing
    - vision          # no image input
    - image_gen       # no image generation
    - session_search  # no cross-session history search (reinforces per-employee isolation)
    # KEEP enabled: `mcp-vertex-ai-search` → the knowledge-search tool (the one allowed capability)
    # KEEP enabled: `memory`               → the agent's built-in note-taking + guidance
    #               (Honcho per-employee memory is a provider plugin, not a toolset — §3)
```

**How MCP maps to toolsets (important for the lockdown).** Each registered MCP server becomes its
**own dynamic toolset** named `mcp-<server>` — so the Vertex AI Search server surfaces as
`mcp-vertex-ai-search`. Keeping it enabled equals "knowledge-search only" **only because it is the
sole MCP server registered on this profile.** If you ever register another MCP server on the support
profile, it appears as a *separate* `mcp-<name>` toolset that is enabled by default — add it to
`disabled_toolsets` or it silently widens the agent past the lockdown.

**Verify the real registry on the VM** — run `hermes tools` and disable everything the interactive
list shows *except* `mcp-vertex-ai-search` and `memory`. The names above are doc-sourced (from the
Hermes toolsets reference); treat the live `hermes tools` output as authoritative. **[verify on VM]**

Defence in depth (cheap, worth adding for a bot that shouldn't act at all):

```yaml
approvals:
  mode: manual        # any command that somehow slips through must be human-approved
terminal:
  backend: docker     # if terminal is ever re-enabled, sandbox it (cap-drop ALL, no-new-privileges)
```

`HERMES_WRITE_SAFE_ROOT` and the hardline blocklist stay in force regardless. With `terminal` and
`files` in `disabled_toolsets`, the agent has no path to the shell or filesystem in the first place.

## 6. Slack — the per-employee support desk (from a manifest)

Employees **DM the bot** (and can `@mention` it inside the DM). Each DM is its own session, and §3
gives each its own memory peer. Create the Slack app from the ready-made manifest —
[`configs/slack-app-manifest.yaml`](configs/slack-app-manifest.yaml) — least-privilege for a DM
support desk (no channel-history scopes).

**Step 1 — create the app from the manifest.**
1. Go to <https://api.slack.com/apps> → **Create New App** → **From an app manifest**.
2. Pick your workspace → paste the contents of
   [`configs/slack-app-manifest.yaml`](configs/slack-app-manifest.yaml) (switch the editor to YAML)
   → **Create**.

**Step 2 — app-level token (Socket Mode).** The manifest turns Socket Mode *on* but can't mint the
token. In the app: **Basic Information → App-Level Tokens → Generate Token and Scopes** → name it,
add scope **`connections:write`** → **Generate** → copy the **`xapp-…`** token.

**Step 3 — install + bot token.** **OAuth & Permissions → Install to Workspace** → approve → copy
the **Bot User OAuth Token** (**`xoxb-…`**).

**Step 4 — collect the ~100 Member IDs.** Each employee's ID: profile → **View full profile → ⋮ →
Copy member ID** (format `U01ABC2DEF3`). At 100 users, don't hand-collect — generate the list from
a Slack user group / IDP export (see §"Scaling the allowlist" below).

**Step 5 — hand the tokens to Hermes.** Two equivalent ways:

**This deployment uses the two-profile model** (chosen): the default profile (`~/.hermes`) stays the
admin's full-power assistant behind the dashboard/desktop; the employee bot runs on a separate,
locked-down `support` profile. So configure Slack on the **`support` profile via its `.env`** — **not**
the dashboard screen (that screen manages the *default* profile). Leave the dashboard's Slack
connector unconfigured.

Append to the support profile's `.env` (`~/.hermes-support/.env` — confirm the path from §1):

```bash
SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
# Access — pick ONE (see below):
#   (a) allowlist  — SLACK_ALLOWED_USERS=U01ABC2DEF3,U02...,U03...  (leave ALLOW_ALL unset)
#   (b) open        — SLACK_ALLOW_ALL_USERS=true  and leave SLACK_ALLOWED_USERS BLANK
SLACK_ALLOW_ALL_USERS=true
```

**Access decision — this deployment uses (b) open (chosen 2026-07-20).** The bot is an
all-employee support desk, so gating on a hand-maintained ~100-ID CSV wasn't worth it; the gate
is instead **Slack workspace/org membership** (the app is installed on the Visma org) plus the
per-user session isolation below. `SLACK_ALLOW_ALL_USERS=true` bypasses the allowlist entirely —
leave `SLACK_ALLOWED_USERS` blank when it's set.

> **Trade accepted:** the field is labelled *dev-only* upstream. Open access means every workspace
> member can spend Vertex tokens and it widens the prompt-injection surface — mitigated here by the
> locked-down `agent.disabled_toolsets` (knowledge-search only), per-user isolation, and (optionally)
> restricting `allowed_channels`. If access must be narrowed later, revert to the allowlist (a).
>
> **Slack-side requirement for open access:** the App-Home **Messages tab must be ON** (*"Allow users
> to send Slash commands and messages"*) — the manifest sets this, but confirm it; if it's off, no
> employee can DM the bot regardless of the Hermes setting. Install the app **org-wide** ("installed
> on Visma Group") so all members have it.

**Step 6 — the bot must be reachable by DM.** The manifest enables the App-Home *Messages* tab, so
employees can open a DM from the bot's profile. Tell them: search the bot's name → message it. No
channel invite needed.

In `config.yaml` keep per-user sessions on (this is the default, but make it explicit):

```yaml
platforms:
  slack:
    group_sessions_per_user: true    # each user gets their own isolated session
```

**Scaling the allowlist to 100 employees** (only relevant if you chose allowlist (a) above — the
open (b) path sidesteps this entirely). A hand-maintained 100-ID CSV is brittle. There is no
documented "allow a whole workspace group" key, so generate the list from the source of truth
instead of editing it by hand — e.g. pull the members of a Slack user group / IDP group and render
the `SLACK_ALLOWED_USERS=` line, then restart the gateway. Wire that into a small script (same
systemd-timer pattern as the memory backup) so joiners/leavers stay in sync. **[verify on VM]** —
confirm whether your Hermes build also accepts an allowed-users list in `config.yaml`; the env var
is the guaranteed path.

## 7. Run the gateway (under the support profile)

```bash
# with the support profile selected (HERMES_HOME → ~/.hermes-support)
hermes gateway install      # systemd user service
hermes gateway start
hermes gateway status       # expect: Slack connected
```

The gateway holds a separate session per DM and keeps the Socket-Mode connection alive. If you also
run your personal Hermes gateway, they are different profiles → different services → no collision.

## 7b. 24/7 operation (this is a production service)

The support bot must be **always available** — it runs 24/7 on the GCP VM. This **overrides** the
"stop the VM when idle" cost tip in AGENTS.md (that's for a pilot only). Four things keep it up
unattended; the first is already done by the base install, verify the rest:

1. **Linger — user services survive logout (already enabled).** `02-vm-install.sh` runs
   `sudo loginctl enable-linger`, so systemd *user* services (gateway, dashboard, Honcho-adjacent
   timers) keep running after you close SSH. Confirm:
   ```bash
   loginctl show-user "$USER" | grep Linger        # expect: Linger=yes
   ```
2. **Gateway auto-starts on reboot.** `hermes gateway install` created a user service; make sure it
   is *enabled* (not just started) so it comes back after a VM reboot:
   ```bash
   systemctl --user list-units | grep -i hermes    # find the gateway unit name
   systemctl --user enable --now <hermes-gateway-unit>   # [verify on VM] exact unit name
   systemctl --user is-enabled <hermes-gateway-unit>     # expect: enabled
   ```
3. **Honcho containers restart on boot.** Per-employee memory dies after a reboot if the containers
   don't come back. Ensure a restart policy in `~/honcho/docker-compose.yml`, then re-up:
   ```yaml
   services:
     api:       # and postgres, and any others
       restart: unless-stopped
   ```
   ```bash
   cd ~/honcho && sudo docker compose up -d
   sudo docker compose ps        # all services "running"; reboot-test once if you can
   ```
4. **Never stop the VM; let it self-heal.** Do **not** run `gcloud compute instances stop`. GCE
   `automaticRestart` (default `true`) restarts the VM through host maintenance/crashes — verify:
   ```bash
   gcloud compute instances describe hermes-agent --zone=europe-west1-b \
     --format='value(scheduling.automaticRestart, scheduling.onHostMaintenance)'
   # expect: True   MIGRATE
   ```

**Why the bot stays up even when your Mac is asleep:** the Slack gateway uses **Socket Mode** — an
*outbound* WebSocket from the VM to Slack. It needs no inbound ports and no SSH tunnel. The Mac-side
tunnel (AGENTS.md "tunnel dies on Mac sleep") only serves the *human dashboard UI* — bot availability
is fully independent of it.

Cost note: 24/7 means the full ~$55/mo VM cost with no idle savings; only chat tokens scale with use.

## 8. EU data residency (unchanged hard requirement)

Per [AGENTS.md](../AGENTS.md#eu-data-residency-hard-requirement):

- **Vertex chat** — `gemini-3.6-flash` (default) / `gemini-3.5-flash-lite` on the `global` endpoint.
  ⚠️ This is an **accepted EU-residency exception** (these models are global-only on Vertex, not
  region-pinned). Strict-EU fallback: `gemini-3.5-flash` @ regional `europe-west2`.
- **Vertex AI Search datastore** — create it in an **EU** multi-region (`eu`), not `us`/`global`.
- **Honcho** — self-hosted on the EU VM (data stays in `test-disco-cm`). Its AI-Studio Gemini key
  is the *documented* non-Vertex exception, not a residency breach.
- **VM + buckets** — already `europe-west1`.

## Verification checklist

- [ ] `hermes gateway status` (support profile) → Slack connected
- [ ] Employee A DMs the bot → answers **only** from the knowledge base, cites a document
- [ ] Ask the bot to run a command / open a file / browse a URL → it declines (no such tool)
- [ ] Ask something not in the corpus → it says so and points to a human, does **not** invent
- [ ] Access gate works: with open access (b), any workspace member DMs → answers; with allowlist (a), a non-allowlisted user DMs → ignored
- [ ] Tell the bot a personal detail as employee A; as employee B ask for it → **not** known
      (per-peer memory isolation working)
- [ ] `hermes tools` (support profile) shows only the knowledge-search MCP + memory enabled
- [ ] `hermes config show` → `agent.disabled_toolsets` includes terminal/files/web/session_search
- [ ] Honcho: two employees produce two distinct peers (`slack_U…`) in the Honcho workspace

## Added cost vs. the base install

The bot is idle-cheap on the existing VM. Deltas at ~100 employees, casual support use:

- **Vertex chat tokens** dominate and scale with usage — rough order **+$150–500/mo** depending on
  how chatty the workforce is (Flash keeps it low; `/compress` and short answers help).
- **Vertex AI Search** ≈ $2–4 per 1k queries + small index cost → tens of $/mo at this scale.
- **Honcho** — a bit more Postgres/pgvector storage for 100 peers; negligible compute, small
  AI-Studio token spend for background user-modeling.

Stop the VM when the workforce is offline (nights/weekends) to cut the base cost.

## Open items to confirm on the VM (don't ship as fact until checked)

1. Exact profile home path printed by `hermes profile create support` (used for every path above).
2. Full authoritative toolset list from `hermes tools`, and that disabling all-but-`mcp`/`memory`
   still lets the Vertex AI Search tool run and Honcho memory record.
3. Exact placement of `pinUserPeer` / `runtimePeerPrefix` in the installed `honcho.json` schema
   (top-level vs. under `hosts.hermes`) — our template nests; the docs show some keys top-level.
4. Whether your Hermes build reads a Slack allowed-users list from `config.yaml` as well as the env
   var (env var is the guaranteed path).
