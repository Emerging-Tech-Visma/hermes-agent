# Which memory backend for a business deployment?

**Decision (2026-10-13): keep self-hosted Honcho (`MEMORY_PROVIDER="honcho"`,
`MEMORY_LLM_BACKEND="vertex"`).** Conditional on §5.

Written because "should we use Hermes' standard memory or a third party?" is asked
roughly every time someone new looks at this install, and the question hides a false
choice.

## 1. There are three options, not two

Third-party *software* and third-party *hosting* are separate decisions.

| | What it is | Where data lives |
|---|---|---|
| **A — built-in** | `MEMORY_PROVIDER=""` → `MEMORY.md` + `USER.md` under `~/.hermes` (this repo's own claim in `00-vars.sh`; upstream Hermes source is not vendored here, so treat as unverified) | the VM |
| **B — self-hosted Honcho** *(live today)* | third-party software, first-party hosting. Docker FastAPI + Postgres/pgvector, `127.0.0.1:8000` | the VM, inside the private VPC, `europe-west2` |
| **C — hosted memory SaaS** | Honcho Cloud (`HONCHO_API_KEY`), Mem0, Zep, Letta… | a vendor's cloud |

Most people mean **C** when they say "third party". C is the one to rule out.

## 2. What actually decides it: multi-user Slack

Employees reach Hermes **only** through the Slack bot, which is open to every workspace
member. That makes memory a multi-tenant problem:

- **Built-in** memory is two flat files per profile. With N employees you get either one
  shared blob — one employee's facts bleeding into another's context, a privacy problem
  rather than a tidiness one — or N profiles to provision and maintain
  (`../PROFILES-ISOLATION.md`).
- **Honcho** models each Slack user as its own peer (`runtimePeerPrefix`, see
  `../SUPPORT-BOT-SETUP.md`). Per-employee memory separation is the feature that makes the
  all-employee bot workable at all.

For a single-admin agent this constraint disappears and built-in is genuinely fine. It is
the *business* case — many users — that forces Honcho.

## 3. Why not hosted SaaS (option C)

Ruled out on constraints verifiable from this repo, not on a feature comparison we could
not keep current anyway:

- **EU residency.** The standing rule is that data at rest stays in `europe-west2`
  (`00-vars.sh`). Per-employee behavioural models are the most personal data in the stack;
  a hosted vendor puts exactly that outside the VPC.
- **No external keys.** Since v0.12.0 the whole stack, Honcho included, reaches Vertex
  through the local shim on the VM's attached service account. `AGENTS.md` states it
  plainly: there are no external API keys anywhere in this install. Adopting a memory SaaS
  re-introduces the vendor surface that release deliberately removed.
- **Subprocessor cost.** A hosted memory vendor is a new subprocessor — DPA, registration,
  ongoing monitoring. Recurring compliance work for a component we already run ourselves.

Honcho Cloud is the same software as option B without any of these advantages. There is no
reason to move to it from a working self-hosted instance.

## 4. Cost

Honcho's background reasoning (extraction / summary / dialectic / dream on
`gemini-2.5-flash`) is a second inference stream, but it bills to the same GCP project and
service account as chat. Built-in costs nothing extra. Not a deciding factor at this scale.

## 5. The condition: Honcho's Postgres is still not automatically backed up

`scripts/memory-backup.sh` rsyncs `~/.hermes` hourly to GCS. Honcho's Postgres lives in a
**Docker volume**, outside that path — the script says so in its own header, and
`OPS-NOTES.md` §6 repeats it.

So the asset that justifies choosing Honcho is the one asset the hourly job misses, while
built-in memory is fully covered by it.

`OPS-NOTES.md` §6 documents both fixes — a `pg_dumpall` into the bucket, and a whole-disk
snapshot — but **neither is on a timer**. The section says a snapshot is "worth putting on
a schedule"; nothing schedules one.

**Until one of those is actually scheduled, per-employee memory is not a system of record.**
That is the open condition on this decision, not a footnote.

> Related: v0.18.1 found that the memory backups had never run at all. Treat "a backup is
> configured" as unproven until `journalctl --user -u memory-backup` shows it running.

## 6. Verdict

| Situation | Choice |
|---|---|
| Multi-user business deployment (this install) | **Honcho, self-hosted, Vertex backend** — per-employee separation is the requirement, nothing leaves the VPC, no external keys |
| Single admin, or a throwaway pilot | **built-in** — fewer moving parts, no Docker, fully covered by the existing backup |
| Hosted memory SaaS | **no**, for any variant of this install |
