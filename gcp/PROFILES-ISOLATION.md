# Multiple Isolated Agents on One VM — Hermes Profiles

**Goal:** one Hermes installation on the `hermes-agent` GCP VM (as built by `01`→`02`→`03`),
serving **several independent agents**, each entered through its own **Slack** chat app, each
**isolated from the others** — separate persona, memory, knowledge, tools, and credentials.

This generalises the single `support` profile in [SUPPORT-BOT-SETUP.md](SUPPORT-BOT-SETUP.md)
to N profiles. Source of truth for the feature:
<https://hermes-agent.nousresearch.com/docs/user-guide/profiles>.

## What a profile is (and what it does / doesn't isolate)

A **profile is a separate Hermes home directory** (`HERMES_HOME=~/.hermes/profiles/<name>`).
Each profile gets its own `config.yaml`, `.env`, `SOUL.md`, memories, sessions, skills, cron
jobs, state DB, **gateway process**, and **MCP connections**.

| Component | Isolated per profile? | Note |
|---|---|---|
| `config.yaml`, `.env`, `SOUL.md` | ✅ | independent settings, tokens, persona |
| Sessions, memory, state DB | ✅ | one agent's chat/memory never reaches another |
| Skills, cron jobs | ✅ | profile-scoped |
| MCP servers (e.g. an ETAP KG) | ✅ | each profile connects its own |
| Bot token / Slack app | ✅ | **each profile needs its OWN Slack app** (see §2) |
| Gateway process + systemd service | ✅ | `hermes-gateway-<profile>` per profile |
| **OS user `HOME` + filesystem** | ❌ **by default** | tool subprocesses share your real `~` — **the isolation gap, closed in §4** |
| GCP identity → Vertex billing | ❌ | all profiles bill via the **VM service account (ADC)** — shared (see §6) |

> **Profiles are config/state/process isolation, NOT a security sandbox.** With filesystem tools
> enabled and default `HOME`, one profile's agent could read another profile's `HERMES_HOME`
> (which holds its `.env` tokens + memory). §4 hardens this; §7 covers *strict* (untrusted)
> isolation via separate OS users.

## The design (1 VM, N isolated Slack agents)

```
Slack app A  ─(Socket Mode)→  gateway  profile "teamA"     ~/.hermes/profiles/teamA
Slack app B  ─(Socket Mode)→  gateway  profile "teamB"     ~/.hermes/profiles/teamB
Slack app C  ─(Socket Mode)→  gateway  profile "support"   ~/.hermes/profiles/support
        (all on one VM · each its own persona/memory/knowledge/tools · all 24/7)
```

Each profile = **one Slack app + one gateway service + one HERMES_HOME**. Input is always
Slack (Socket Mode — no open ports). Do this once per agent.

> **Chat platform:** Hermes' documented connectors are **Slack, Telegram, Discord, WhatsApp,
> Signal** — configured the same per-profile way (own token in the profile `.env`). **Google
> Chat is not a listed Hermes connector**, so "chat via Google" here means Slack in the Visma
> Google/Slack org, not a native Google Chat bot. Flag if you actually need Google Chat — it'd
> need a custom bridge, not a profile setting.

## 1. Create the profile

```bash
# on the VM (kennetkusk@hermes-agent)
hermes profile create teamA --clone   # copy config/skills/SOUL as a starting point (no sessions)
# blank instead: hermes profile create teamA
hermes profile list                   # confirm; note its HERMES_HOME path
```

`--clone` copies config/skills/SOUL only; `--clone-all` also copies memory/state (usually NOT
what you want for a fresh, isolated agent). Each profile gets an **alias command** = its name,
e.g. `teamA chat`, `teamA gateway start`. Explicit form: `hermes -p teamA <cmd>`.

## 2. A dedicated Slack app per profile (required)

Two profiles **cannot share a bot token** — the second gateway is blocked with a
"conflicting profile" error. So create **one Slack app per profile** (all can live in the same
Visma workspace; each is a distinct bot user). For each, follow the token steps in
[SLACK-TEAM-SETUP.md](SLACK-TEAM-SETUP.md) §1:

- **Socket Mode** on → app-level token (`xapp-…`, scope `connections:write`).
- **Bot scopes** + **Event Subscriptions** (the `*history` scopes + `message.*`/`app_mention`).
- **Install** → bot token (`xoxb-…`).
- App-Home **Messages tab ON** if the agent should take DMs.

## 3. Configure the profile (`.env` + `config.yaml`)

Edit the profile's own files (NOT `~/.hermes/...` — the *profile's* home):

```bash
nano ~/.hermes/profiles/teamA/.env
```
```bash
SLACK_BOT_TOKEN=xoxb-...            # teamA's app
SLACK_APP_TOKEN=xapp-...
# access: allowlist OR open (see SUPPORT-BOT-SETUP.md §6)
SLACK_ALLOWED_USERS=U0...,U0...     # or  SLACK_ALLOW_ALL_USERS=true  (leave allowed blank)
```

In `~/.hermes/profiles/teamA/config.yaml`: set this agent's persona (`SOUL.md`), its **own MCP
servers** (e.g. only teamA's knowledge — an [ETAP KG](EXTERNAL-KG-MCP.md) or a Vertex AI Search
app), its Vertex chat model (EU region — [KNOWLEDGE-DATASTORE.md](KNOWLEDGE-DATASTORE.md)), and
`agent.disabled_toolsets` to restrict capability. Because MCP/memory/SOUL are all per-`HERMES_HOME`,
teamA can never query teamB's knowledge or memory.

## 4. Harden the isolation gap (filesystem/HOME)

By default all profiles' tool subprocesses share your OS `HOME` and can see the whole disk —
including sibling profiles' `HERMES_HOME`. Close it **per profile** in `config.yaml`:

```yaml
terminal:
  home_mode: profile        # tool subprocesses use HOME={HERMES_HOME}/home, not your ~
  cwd: "{HERMES_HOME}/home" # keep the working dir inside the profile too
```

Two complementary levers:
- **Best isolation-by-removal:** if an agent only needs to search knowledge (the support-bot
  shape), set `agent.disabled_toolsets` to strip shell/file/web entirely — then there is no tool
  that can read another profile's files, and `home_mode` is belt-and-suspenders.
- **For agents that DO need file/shell tools,** `home_mode: profile` is mandatory, and consider
  §7 (separate OS user) for real trust boundaries.

## 5. Run each profile 24/7 as its own service

Per the always-on rule (production runs 24/7 — never stop the VM), install a **per-profile**
gateway service; linger is already enabled by `02-vm-install.sh`:

```bash
teamA gateway install     # creates + enables hermes-gateway-teamA (survives reboot/logout)
teamA gateway start
teamA gateway status      # → Slack connected
```

Repeat per profile. Each is an independent systemd user unit; one crashing doesn't touch the others.

## 6. What stays SHARED across profiles (accept or mitigate)

- **Vertex AI billing + identity.** All profiles infer via the VM's **attached service account
  (ADC)** — one GCP bill, one identity, all in `test-disco-cm`. Profiles don't split cost or
  quota. To bill/segregate a profile separately you'd need a different key/project, which the
  VM-SA/ADC model doesn't provide out of the box.
- **The VM, OS, and Honcho instance** (if used). Point each profile at its own Honcho *peer
  namespace* if you want per-profile memory backends; otherwise memory is already isolated by
  `HERMES_HOME` for the built-in provider.
- **EU residency still applies to every profile** — each profile's Vertex region must be
  `europe-*` and any added datastore EU-pinned ([AGENTS.md](../AGENTS.md) "EU data residency").

## 7. Strict isolation (untrusted separation)

If profiles must not trust each other at the OS level (e.g. different orgs' data), Hermes
profiles alone are not enough — run each gateway under a **separate Linux user** (own home, own
systemd user instance) or in **separate containers/VMs**. Profiles give you clean logical
separation; the OS user/container is the security boundary.

## 8. Verify isolation

```bash
hermes profile list                       # all profiles + gateway status
teamA gateway status && teamB gateway status
```
- [ ] Each Slack app answers only on its own profile (distinct bot users).
- [ ] Ask teamA about something only in teamB's knowledge/memory → not known.
- [ ] With `home_mode: profile`: from teamA (if it has file tools) try to read
      `~/.hermes/profiles/teamB/.env` → denied / not visible.
- [ ] Reusing one Slack token in two profiles → second `gateway start` errors naming the conflict.
- [ ] Reboot the VM → every `hermes-gateway-<profile>` comes back (linger + enabled).

## Cost note

One VM hosts all profiles (no per-profile VM cost), but **chat tokens are additive** — N busy
agents ≈ N× the Vertex token spend of one. Keep Flash as default; the VM stays up 24/7 for a
production/support deployment.
