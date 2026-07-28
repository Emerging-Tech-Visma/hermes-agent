# Plan — Subprocessor Monitor as a Hermes Profile (on GCP)

**What this is.** A build plan for running the legal team's **subprocessor-monitoring**
workflow as a new, isolated **Hermes profile** on the existing GCP VM — instead of on ETAP.
Derived from the "Subprocessor Monitor on ETAP — platform fit" assessment (2026-07-08); this
doc re-targets that design at Hermes and fills in the GCP pieces.

**Scope decisions (chosen 2026-07-20):** learning-grade prototype · register built **fresh in
GCP** · human approval captured **in Slack via Hermes** · **web search included** (GCP) for page
rediscovery / new-vendor discovery.

> Learning-grade = prove the shape end-to-end; approvals capture who/when and evidence is
> versioned, but this is **not** yet an audit-hardened, legally-signed deployment. A real GDPR
> subprocessor monitor needs the production upgrades called out in §8 before go-live.

---

## 0. The one big reason to do this on Hermes: EU inference

The ETAP assessment's #1 blocker was **EU data residency of the model** — ETAP runs Anthropic
Managed Agents on **US-hosted** inference. The assessment itself names the escape hatch:

> *"If EU-region inference for the orchestration step is a hard requirement, that specific step
> points to the Bedrock/Vertex route … not ETAP's managed-agent runtime."*

**Running the orchestrating agent on Hermes IS that Vertex route** — Hermes already infers via
Vertex in an EU region ([AGENTS.md](../AGENTS.md) "EU data residency"). So Hermes doesn't merely
"fit"; it closes the assessment's headline gap. Two honest caveats:

1. **The model becomes Gemini, not Claude.** Extraction/reasoning behaviour differs — validate
   extraction quality on saved page fixtures (P1) against Gemini, not assume Claude's numbers.
2. **EU residency now applies to every GCP service you add** — Cloud Run, GCS, Cloud SQL, and the
   search API must all be EU-pinned (`europe-west*`), same rule as the rest of this repo.

---

## 1. Don't collapse the three planes

The whole thesis of the source design: the **agent is the small, late, reversible piece**. The
crawler, diff engine, evidence archive, approval record, and compliance register live **outside**
the agent and **must exist first**. "Implement it in Hermes" = mount the thin agent *on top of* a
GCP core that you build first. Keep the planes separate:

```
┌── Deterministic core (GCP, outside the agent) ──────────────┐   built FIRST (P0–P2)
│  crawl → render → extract → diff → evidence archive          │
│  exposed to the agent as a READ/PROPOSE MCP tool server      │
└──────────────────────────────────────────────────────────────┘
              │ references only (evidence_ref, diff_ref)
┌── Agent plane (Hermes profile "legal-subproc") ─────────────┐   mounted LAST (P4)
│  cron-fired run · calls tools · drafts findings/notices      │
│  PROPOSE-ONLY — no loader tool, no DB write, no shell         │
└──────────────────────────────────────────────────────────────┘
              │ human approves in Slack  →  signed approval row
┌── Authority lane (GCP, outside the agent) ──────────────────┐   built FIRST (P3)
│  approval record → idempotent LOADER → compliance register   │
│  the agent can NEVER reach the loader or the register        │
└──────────────────────────────────────────────────────────────┘
```

---

## 2. The propose-only boundary — the crux (and why Hermes needs extra care)

On ETAP the boundary is enforced by a limited-egress environment + vault-delivered creds + a tool
list that omits the loader. **Hermes profiles are config/state isolation, not a security sandbox**
([PROFILES-ISOLATION.md](PROFILES-ISOLATION.md)), so we reconstruct the boundary deliberately:

- **Agent gets only read/propose MCP tools** (fetch, search, extract, diff, get-evidence, draft,
  post-proposal). See §4.
- **`agent.disabled_toolsets`** strips shell / file / browser / everything else — the agent has
  *no* general-purpose capability, only the tool server.
- **The loader is a separate GCP service the agent cannot address** — never an MCP tool, on its
  own host, triggered only by a signed approval. This is non-negotiable.
- **Tools pass references, not blobs** (`evidence_ref`, `diff_ref`) — raw HTML/screenshots stay in
  GCS; the agent reasons over pointers + a compact structured diff. Keeps regulated content out of
  the model and shrinks cost/latency.
- **Limited egress + `terminal.home_mode: profile`** so the profile can't read siblings' state and
  (belt-and-suspenders) can't reach arbitrary hosts.

---

## 3. GCP services (all EU-pinned, `europe-west*`)

| Plane | Piece | GCP service | Notes |
|---|---|---|---|
| Core | Crawl + render vendor pages | **Cloud Run job** + headless Chromium (Playwright) | scheduled; renders JS pages |
| Core | Extract structured subprocessor list | same job, **Vertex AI (Gemini, EU)** | LLM extraction lives in the core, not the agent |
| Core | Diff vs last approved snapshot | same job (deterministic) | added/removed/purpose/location/transfer-mechanism |
| Core | Page rediscovery / new-vendor search | **Custom Search JSON API** (Programmable Search Engine) | see §4 `search_subprocessor_page`; queries only, no regulated data |
| Core | **Tool server (MCP)** | **Cloud Run** service, bearer auth | the read/propose surface Hermes attaches to (§4) |
| Store | Evidence archive (raw HTML, screenshots, hashes) | **GCS bucket** (EU), versioned | immutable/object-lock is a P-prod upgrade (§8) |
| Store | **Compliance register** (source of truth) | **Cloud SQL Postgres** (EU) | normalized vendor/subprocessor schema (§5) |
| Store | Snapshots + proposals + **signed approvals** | same Postgres, separate tables | the authority lane's state |
| Authority | **Loader** (writes approved diffs) | **separate Cloud Run** service | approval-triggered; agent cannot reach it |
| Schedule | Fire the monitoring run | **Hermes per-profile cron** (pick one owner) | Cloud Scheduler is the alternative; don't run both |
| Agent | Orchestrator + drafting | **Hermes profile** on the VM, Vertex-EU | §6 |

> **Search & EU:** the search API only ever receives *queries* (e.g. `"OpenAI sub-processors"`),
> never regulated content, so it's the lowest-residency-risk piece; still keep it in the core, not
> as an agent capability that could wander.

---

## 4. The MCP tool server — the agent's entire capability

One Cloud Run service, bearer-auth, attached to Hermes via the **ADD MCP SERVER** flow documented
in [EXTERNAL-KG-MCP.md](EXTERNAL-KG-MCP.md) (same transport + token pattern). Every tool is
**read or propose** — none writes the register:

| Tool | Kind | Does |
|---|---|---|
| `list_watched_vendors` | read | the configured vendor + URL list |
| `search_subprocessor_page` | read | Custom Search → candidate URLs when a page moved / new vendor (human/agent confirms) |
| `fetch_page(url)` | read | trigger crawl+render; returns an **`evidence_ref`** (GCS), not the HTML |
| `extract_subprocessors(evidence_ref)` | read | structured list from the archived page (core does the LLM extraction) |
| `diff_against_last_approved(vendor)` | read | compact diff vs last approved snapshot → **`diff_ref`** + change summary |
| `get_change(diff_ref)` | read | the structured change set for reasoning (added/removed/changed) |
| `create_proposal(diff_ref, rationale)` | propose | writes a **proposal** row (status=pending) — NOT the register |
| `draft_customer_notice(diff_ref)` | propose | drafts notice text; **sending is separate + human-approved** |

**Deliberately absent:** any `load`, `write_register`, `approve`, or `send` tool. Approval and
loading are the authority lane's job (§7).

---

## 5. Compliance register (fresh Cloud SQL Postgres, EU) — schema sketch

Normalized (not a RAG/KG store). Minimal shape for the prototype:

```
vendors(id, name, dpa_url, subprocessor_url, active)
subprocessors(id, vendor_id→vendors, name, purpose, location, transfer_mechanism,
              status, first_seen, last_confirmed)          -- current approved state
snapshots(id, vendor_id, evidence_ref, extracted_json, taken_at)   -- what a run saw
proposals(id, vendor_id, diff_ref, change_json, status[pending|approved|rejected],
          created_by_run, created_at)                      -- agent output (propose-only)
approvals(id, proposal_id→proposals, approver_slack_id, method, decided_at,
          diff_hash, evidence_refs, scope, expires_at)      -- the signed approval event
register_log(id, subprocessor_id, change, approval_id, loaded_at)  -- soft-delete audit
```

The **agent** may read `vendors`/`subprocessors` (via tools) and write `proposals`; it can touch
**nothing** in `approvals`/`subprocessors`-writes/`register_log` — those are the loader's, on a DB
role the agent's tool server does not hold (mirror the two-tier role idea, DB-enforced).

---

## 6. The Hermes profile — files & config (this is the last ~20%)

Create per [PROFILES-ISOLATION.md](PROFILES-ISOLATION.md): `hermes profile create legal-subproc`.
Its own Slack app (own `xoxb`/`xapp`), own gateway service.

**`SOUL.md`** (identity slot #1) — the propose-only persona:

```
You are the Subprocessor Monitor for the Legal & Compliance team.
Your ONLY job each run: for every watched vendor, fetch the current sub-processor page,
extract the list, diff it against the last approved snapshot, and — for every real change —
create a proposal with a clear rationale citing the evidence reference. You may draft a
customer notice. You NEVER approve, NEVER write the compliance register, and NEVER send
anything. You reason over references (evidence_ref/diff_ref), not raw page content. If an
extraction is low-confidence or noisy, say so and do not create a proposal. Cite evidence for
every claim. When done, post a concise summary of proposals to the review channel for a human.
```

**`config.yaml`** (profile) — key blocks:

```yaml
# Vertex chat model, EU region (same discipline as the base install)
provider: vertex
model: google/gemini-3.5-pro        # -pro for extraction/diff reasoning; confirm on fixtures (P1)
vertex:
  region: europe-west2              # EU; must be europe-* (AGENTS.md EU rule)

terminal:
  home_mode: profile                # filesystem isolation from other profiles
  cwd: "{HERMES_HOME}/home"

agent:
  disabled_toolsets: [shell, files, web, browser, memory-write]   # tool server is the ONLY capability

mcp_servers:
  subproc-tools:
    url: "https://<tool-server>.europe-west1.run.app/mcp"   # Cloud Run, EU
    headers: { Authorization: "Bearer ${SUBPROC_TOOLS_TOKEN}" }   # value in .env
    enabled: true
    timeout: 120

# Scheduled unattended run (pick Hermes cron OR Cloud Scheduler — not both)
cron:
  - name: daily-subproc-scan
    schedule: "0 6 * * *"           # 06:00 daily
    prompt: "Run the subprocessor scan for all watched vendors and post proposals."

platforms:
  slack:
    reply_in_thread: true
slack:
  allowed_channels: ["C0LEGAL_REVIEW"]   # post proposals here; DMs still gated below
```

**`.env`** (profile) — Slack + tool-server token:

```bash
SLACK_BOT_TOKEN=xoxb-...            # the legal-subproc app
SLACK_APP_TOKEN=xapp-...
SUBPROC_TOOLS_TOKEN=...             # bearer for the MCP tool server
# ACCESS: allowlist the compliance team — do NOT use allow-all here.
SLACK_ALLOWED_USERS=U0COMPLIANCE1,U0COMPLIANCE2,U0LEGALOPS
```

> **Access control is the OPPOSITE of the support bot.** The support bot uses
> `SLACK_ALLOW_ALL_USERS=true` (all employees). This monitor is restricted to the **compliance
> team allowlist** — approvals are attributable, so only named approvers may interact.

---

## 7. The approval → loader handoff (Slack-captured, GCP-loaded)

1. The run posts each proposal to the **legal review channel** in Slack (agent, propose-only).
2. A named compliance approver responds to approve/reject **in Slack**. A tiny **authority-lane
   webhook** (Cloud Run, listening to Slack interactions — *not* the Hermes agent) writes the
   **`approvals`** row: approver Slack id, timestamp, `diff_hash`, `evidence_refs`, scope.
3. That approval row firing is the trigger for the **loader** (separate Cloud Run) to write the
   approved diff into `subprocessors` + `register_log` (idempotent, soft-delete only).
4. Sending any customer notice stays a **separate, explicitly human-approved** step.

The Hermes agent participates in step 1 only. Steps 2–4 are the authority lane — the agent has no
tool for them. (Slack captures *who/when*; upgrading to a full legally-signed event is §8.)

---

## 8. Build order & what "production-grade" would add

**Build order (foundation before roof):**

| Phase | Build | Where |
|---|---|---|
| P0 | Schemas + column contract + seed vendor/URL list (OpenAI, Anthropic, AWS, Google, HubSpot) | none |
| P1 | Prove **Gemini** extraction quality on saved page fixtures | Vertex-EU |
| P2 | Deterministic core: crawl→render→extract→diff→evidence; wrap as the MCP tool server | Cloud Run + GCS |
| P3 | Authority lane: register DB + Slack-approval webhook + idempotent loader | Cloud SQL + Cloud Run |
| **P4** | **Mount the Hermes `legal-subproc` profile** over the tool server (§6) | **Hermes VM** |
| P5 | Notice drafting + notification workflow; polish | Hermes + core |

**Learning-grade → production-compliance upgrades (before real GDPR use):**
- **Immutable evidence** — GCS object-lock/retention on the evidence bucket (tamper-evident).
- **Legally-sufficient signed approval** — extend the `approvals` capture to a full signed event
  (identity method, single-action scope, expiry, non-repudiation), possibly out of Slack.
- **Extraction regression gate** — enforce "no new extractor/prompt/model ships without passing
  fixture tests" as a CI gate on the core.
- **DB-enforced role split** — the tool server's DB role is read/propose only; only the loader's
  role writes the register (two-tier roles, like the KG platform's model).
- **Retention & DSAR** posture on snapshots/evidence.

---

## 9. Deliverables checklist (what you asked for)

- **md files:** `SOUL.md` (§6 persona), profile `config.yaml` + `.env` (§6).
- **Agent:** one Hermes profile `legal-subproc`, propose-only, Vertex-EU, own Slack app + cron.
- **MCP:** one Cloud Run tool server with the 8 read/propose tools (§4), attached via bearer token.
- **Tools the agent must NOT have:** loader / register-write / approve / send (§2, §7).
- **GCP services:** Cloud Run (core job, tool server, approval webhook, loader), GCS (evidence),
  Cloud SQL Postgres (register + authority state), Custom Search JSON API (search) — all EU (§3).
- **Search:** `search_subprocessor_page` for page rediscovery / new-vendor discovery (§4).
- **Database:** fresh Cloud SQL Postgres register with the §5 schema.
