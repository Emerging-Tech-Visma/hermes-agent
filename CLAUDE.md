# CLAUDE.md

This is a **learning / reference project**: how to install a Hermes agent on GCP
(Google Cloud) and reproduce it on a new installation. Document everything.

The full replication runbook — architecture, canonical facts (project/VM/SA/models),
install order, and the gotchas learned along the way — lives in **[AGENTS.md](AGENTS.md)**
(kept there so both Claude Code and Codex read it).

**Read AGENTS.md before running or debugging an install.**

## Where things are

- **[README.md](README.md)** — the front door: what gets built, quick start, repo map.
- **[CHANGELOG.md](CHANGELOG.md)** — version history. Currently **0.10.0**.
  **Add an entry here for any change to the installable configuration** (new service,
  changed default model/region/OS, new variant, re-probed facts). Keep the
  MAJOR/MINOR/PATCH rules stated at the top of that file.
- **[`gcp/vpc-install/`](gcp/vpc-install/)** — **the current install** (v0.10.0):
  private VPC, no external IP, IAP-only ingress, Ubuntu 26.04, Chrome + Playwright,
  self-hosted SearXNG, Honcho, `gemini-3.5-flash` @ `europe-west2`. Self-contained and
  cloneable — `00-vars.sh` is the only file to edit. Guides: `README.md`, `INSTALL.md`,
  `OPS-NOTES.md` (day-2 SSH ops).
- **[`gcp/`](gcp/)** — the earlier public-IP install, now superseded, but still the best
  reference for Slack bots, profiles/isolation, knowledge datastores and MCP patterns:
  `SLACK-TEAM-SETUP.md`, `SUPPORT-BOT-SETUP.md`, `PROFILES-ISOLATION.md`,
  `KNOWLEDGE-DATASTORE.md`, `EXTERNAL-KG-MCP.md`, `REFERENCE.md`.

## Working rules

- **Verify, don't trust the docs in here.** Facts carry dates because model
  availability, GCP image families and pricing all move. Re-probe before relying on a
  claim, and update the date when you do. `AGENTS.md` once described a VM that had been
  deleted — don't let that happen again.
- **AI Studio ≠ Vertex.** Never infer Vertex model availability from `ai.google.dev`.
  Probe the regional Vertex endpoint with a real `:generateContent` POST.
- **Never commit secrets.** Templates use `__PLACEHOLDER__` tokens filled at install
  time; passwords come from the environment or are set on the VM.
- Keep `AGENTS.md`, `README.md`, `CHANGELOG.md` and the install package in sync —
  faithful replication is the entire point of this repo.
