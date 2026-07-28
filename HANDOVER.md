# HANDOVER — Hermes work in progress

**For a fresh session starting cold** (no memory of the prior conversation; tokens likely rotated
/ expired). Date of handover: **2026-07-20**. Working dir: `/Users/kennetkusk/code/hermes` (a
learning/reference **runbook** repo — docs, not app code). Read [AGENTS.md](AGENTS.md) first.

---

## 1. What was done this session (context, all landed in the repo)

| Item | State | Where |
|---|---|---|
| Reuse ETAP "Vismo" knowledge graph from Hermes via MCP + bearer token | **Working** (verified 2026-07-20) | [gcp/EXTERNAL-KG-MCP.md](gcp/EXTERNAL-KG-MCP.md) |
| Slack support bot opened to **all** employees (`SLACK_ALLOW_ALL_USERS=true`) | **Working** | [gcp/SUPPORT-BOT-SETUP.md](gcp/SUPPORT-BOT-SETUP.md) §6, [gcp/REFERENCE.md](gcp/REFERENCE.md) |
| Multiple **isolated agents on one VM** via Hermes profiles | Documented | [gcp/PROFILES-ISOLATION.md](gcp/PROFILES-ISOLATION.md) |
| **Subprocessor Monitor** as a Hermes profile — full build plan | **Plan only, not built** | [gcp/SUBPROCESSOR-MONITOR-PLAN.md](gcp/SUBPROCESSOR-MONITOR-PLAN.md) |

Memories updated (auto-loaded each session): `hermes-access-model`, `hermes-etap-kg-mcp`,
`subproc-monitor-hermes-slack`, plus the existing `hermes-gcp-eu-region` / `hermes-24-7-always-on`.

---

## 2. The active goal

Build the **Subprocessor Monitor** (a GDPR/DPA legal-compliance workflow) as a **Hermes agent**
with **Slack as the main user interface**. It watches vendors' public sub-processor pages, diffs
them against the last approved list, and — for real changes — posts **proposals** to a Slack
review channel; a compliance approver signs off **in Slack**; an external loader writes the
approved change to a compliance register. The agent is **propose-only**.

Read the plan end to end: [gcp/SUBPROCESSOR-MONITOR-PLAN.md](gcp/SUBPROCESSOR-MONITOR-PLAN.md).
It has the three-plane architecture, GCP service mapping, the 8-tool MCP surface, the Postgres
schema sketch, the profile `SOUL.md` + `config.yaml`, and the P0–P5 build order.

---

## 3. Decisions already locked (do not re-litigate)

- **Grade:** learning-grade prototype (not yet audit-hardened; prod upgrades listed in plan §8).
- **Register:** built **fresh** in GCP (Cloud SQL Postgres, EU).
- **Approval:** captured **in Slack via Hermes** (authority-lane webhook writes the approval row).
- **Search:** **included** — a GCP search tool for page rediscovery / new-vendor discovery.
- **Host = Hermes, not ETAP,** specifically because Hermes gives **EU (Vertex) inference** — that
  is the reason, and it resolves the ETAP assessment's #1 blocker. Model becomes **Gemini, not
  Claude** → extraction quality must be re-proven (see §5, P1).

---

## 4. Guardrails — must not be violated

- **Propose-only boundary is the crux.** The agent's ONLY capability is the read/propose MCP tool
  server. `agent.disabled_toolsets` strips shell/file/web/etc. The **loader / register-write is a
  separate GCP service the agent cannot reach** — never a tool. Tools pass **references**
  (`evidence_ref`/`diff_ref`), never raw page blobs.
- **Access = compliance-team allowlist** (`SLACK_ALLOWED_USERS`), NOT allow-all. This is the
  OPPOSITE of the support bot — approvals must be attributable.
- **EU everything.** Every GCP service (Cloud Run, GCS, Cloud SQL, search) pinned to `europe-*`.
  Vertex region `europe-*` (Gemini 3.x is regional only in `europe-west2`; see AGENTS.md).
- **Profiles are NOT a security sandbox.** Set `terminal.home_mode: profile` so the profile can't
  read sibling profiles' state ([gcp/PROFILES-ISOLATION.md](gcp/PROFILES-ISOLATION.md)).
- **24/7 / never stop the VM** for anything production-facing (`hermes-24-7-always-on` memory).

---

## 5. Open gaps & prerequisites — what must be done before/while building

1. **Authoritative source docs are MISSING.** The design cites `subprocessor_monitor.yaml`,
   `subprocessor_monitor_recommended_solution.md`, `subprocessor_monitor_platform_comparison.md` —
   **not in the repo.** They hold the real extraction schema, DB column contract, signed-approval
   fields, tool I/O contracts, change-type taxonomy, seed vendors.
   → **Action:** obtain them, OR consciously author these P0 contracts ourselves (acceptable for a
   learning-grade prototype — but decide, don't drift).
2. **No home for the service code.** This repo is docs-only. The deterministic core (crawl/render/
   extract/diff), the MCP tool server, the approval webhook, and the loader are **new services**
   needing a repo or `services/` subdir. → **Action:** decide the code home.
3. **GCP project + regions** — confirm same project as the VM (`test-disco-cm`) and pick an EU
   region per service.
4. **Seed vendor URLs** — the real sub-processor page URLs for OpenAI, Anthropic, AWS, Google,
   HubSpot.
5. **New Slack app** for the `legal-subproc` profile — not yet created (see §6 tokens).

---

## 6. Credentials & tokens a fresh session needs (assume all rotated/expired)

**None of these are committed — gather/rotate them at the start of the build session.**

| Token / credential | For | How to get it (fresh) |
|---|---|---|
| `gcloud` auth / ADC, project-owner | creating GCP resources | `gcloud auth login` + `gcloud auth application-default login`; confirm project |
| **ETAP KG bearer** (`kgmcp_…`) | the *existing* Vismo KG link (if that agent is touched) | ETAP → Databases → Vismo → **Rotate token** (show-once). Re-paste into Hermes; see EXTERNAL-KG-MCP.md. A burst of MCP 401s = it was rotated. |
| **New Slack app** `xoxb-…` + `xapp-…` | the `legal-subproc` profile's Slack app | Create a Slack app; Socket Mode on → app-level token scope `connections:write` (`xapp`); OAuth install → bot token (`xoxb`). Scopes + events per [gcp/SLACK-TEAM-SETUP.md](gcp/SLACK-TEAM-SETUP.md) §1. App-Home **Messages tab ON**. |
| **Tool-server bearer** (`SUBPROC_TOOLS_TOKEN`) | Hermes → the MCP tool server | Mint when the Cloud Run tool server is built; store in the profile `.env`, reference in `config.yaml`. |
| VM access | running `hermes` commands | `gcloud compute ssh hermes-agent --zone=europe-west1-b` |
| Custom Search JSON API key + CSE id | the search tool | Create a Programmable Search Engine + API key (EU billing/project). |

Reminders: paste bearer tokens **without** a `Bearer ` prefix when the field/auth type already
says "Bearer" (double scheme → 401). Secrets live in the profile `.env`, never in `config.yaml`
or git.

---

## 7. Recommended next steps (in order)

1. **P1 extraction spike first — needs no infra, de-risks the biggest unknown.** Lock a minimal
   extraction schema, save 2–3 real vendor sub-processor pages as fixtures, and prove **Gemini**
   (Vertex-EU) extracts + diffs them reliably. If it fails, learn it before building infra.
2. Settle the two unblockers: **source docs vs. author-our-own contracts**, and the **code home**.
3. P0 contracts → P2 core + MCP tool server → P3 register + approval webhook + loader → **P4 mount
   the Hermes `legal-subproc` profile** → P5 notices. (Plan §8 has the phase table.)

**Fastest safe start:** say "start the extraction spike" and author the P0 extraction schema +
fixture harness — that moves the build forward without waiting on GCP or Slack tokens.

---

## 8. Doc map (everything a builder needs is already written)

- [AGENTS.md](AGENTS.md) — the master runbook + canonical facts + lessons learned (read first).
- [gcp/SUBPROCESSOR-MONITOR-PLAN.md](gcp/SUBPROCESSOR-MONITOR-PLAN.md) — the build plan.
- [gcp/PROFILES-ISOLATION.md](gcp/PROFILES-ISOLATION.md) — how to make the isolated profile.
- [gcp/EXTERNAL-KG-MCP.md](gcp/EXTERNAL-KG-MCP.md) — the MCP-server + bearer-token attach pattern.
- [gcp/SLACK-TEAM-SETUP.md](gcp/SLACK-TEAM-SETUP.md) / [gcp/SUPPORT-BOT-SETUP.md](gcp/SUPPORT-BOT-SETUP.md) — Slack app + profile config patterns.
- [gcp/REFERENCE.md](gcp/REFERENCE.md) — env vars / MCP shape / troubleshooting.
