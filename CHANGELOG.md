# Changelog

All notable changes to this Hermes-on-GCP runbook are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning is **date-anchored semantic-ish**: this repo ships *runbooks*, not a
library, so the version tracks the **installable configuration** it describes.

- **MAJOR** — a new architecture you cannot reach by editing `00-vars.sh`
  (different network model, different host, different client topology).
- **MINOR** — a new install variant, a new service in the stack, or a changed
  default (model, region, provider).
- **PATCH** — corrections, re-probed facts, doc fixes, script robustness, and
  changes to how this repo itself is run (CI, contribution rules).

**Every pull request claims a new version here**, and the entry becomes the notes of
the matching [GitHub release](https://github.com/Emerging-Tech-Visma/hermes-agent/releases)
— published automatically when the PR merges. A change that alters nothing installable
is still a PATCH; a change that documents nothing at all carries the `skip-changelog`
label instead and ships no release. This file is the single source of truth for the
version: [CONTRIBUTING.md](CONTRIBUTING.md) has the mechanics.

> **Verify, don't trust.** Every version here records facts that were true when
> probed. Model availability, image families and pricing all move. Each entry
> carries the date it was verified — re-probe before relying on it.

---

## [Unreleased]

- **Pin the Honcho clone.** `02-vm-install.sh` does `git clone --depth 1` of `main`,
  which pins nothing — every install gets a different Honcho.
- Replace the plaintext dashboard password with a scrypt
  `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH`.
- Optional: `serpapi-mcp` as an *additional* MCP tool for true Google SERP data,
  alongside SearXNG rather than replacing it.

---

## [0.15.0] — 2026-08-22

Adds **automated weekly backend updates** via a systemd timer, and documents the
update path for the desktop app — which is a separate, manual job.

### Added

- **`scripts/hermes-autoupdate.sh` + `hermes-autoupdate.{service,timer}`** — weekly
  unattended `hermes update` on the VM, Sunday 04:00 UTC with a 30-minute randomised
  delay. Each run: `--check` (exits quietly when there is nothing to do) → `hermes
  update --yes` (keeping Hermes' own pre-update backup) → **restart the dashboard** →
  `03-verify.sh`, failing loudly if the new code does not pass. State markers in
  `~/.hermes/autoupdate/`.
- **`AUTOUPDATE_ENABLE` / `AUTOUPDATE_MODE` / `AUTOUPDATE_SCHEDULE`** in `00-vars.sh`.
  `AUTOUPDATE_MODE=check` reports without installing, for a human-in-the-loop
  production agent.
- **`03-verify.sh` check 14** — asserts the timer is not just *enabled* but has a real
  `NextElapse`, because a timer with a malformed `OnCalendar` loads happily and then
  never fires, which is indistinguishable from "updates are working". Also fails if
  `~/.hermes/autoupdate/last-failure` exists, so a broken update cannot rot silently.
  **Verification target is now 14/14.**
- **`OPS-NOTES.md` §11** — the full update story: automated backend, why a timer rather
  than `hermes cron`, the manual desktop-app path, how to make it check-only or turn it
  off, and recovery when an unattended update breaks the install.

### Why a systemd timer and not `hermes cron`

Established by reading v0.20.5 on the live VM, not inferred:

- `hermes update --plan` reports exactly one service to restart —
  `gateway [default] … systemd`, `restart: systemctl restart`.
- A `hermes cron` job executes **inside that gateway process**, and the gateway unit sets
  `KillMode=mixed` plus an `ExecStopPost` cgroup cleanup. So an update scheduled as a
  cron job is reaped by the restart it triggers — it destroys its own runtime mid-run.
- The same trap catches updates launched from the **desktop app or dashboard**: the
  spawned updater is a child of the gateway. This is the real cause of in-app updates
  reporting failure.
- A timer unit has its own cgroup and is unaffected. No Hermes code change and no
  `systemd-run --scope` wrapper needed — the isolation is free once the updater is not
  launched from the service being restarted.

### Fixed

- **INSTALL-BLOCKING: `02-vm-install.sh` died at step 3 on every current Hermes.** It
  called `hermes version`, which was **removed as a subcommand** — v0.20.5 answers
  `hermes: error: argument command: invalid choice: 'version'` and only accepts
  `--version`. Because that call is guarded by `|| { …; exit 1; }`, the installer aborted
  with "ERROR: hermes not on PATH after install" on a perfectly good install, and no
  amount of re-running helped. Found by applying this release to the live VM — a fresh
  clone today would have hit it immediately. Now tries `--version` first and falls back to
  the old subcommand for older pinned installs. `03-verify.sh` check 1 and the
  `OPS-NOTES.md` snippets had the same stale form and are fixed too.
- **`hermes update` leaves the dashboard on pre-update code.** `--plan` restarts only the
  gateway; this install also runs `hermes-dashboard.service`, the endpoint the desktop app
  and browser actually connect to, which the updater knows nothing about. The autoupdate
  script now restarts it explicitly, and the manual path in §3 says to do the same. Symptom
  this removes: "I updated Hermes but the UI is unchanged."

### Corrected — three claims that do not survive checking

Recorded because they are plausible, circulate as advice, and are wrong:

| Claim | Reality (v0.20.5 source) |
|---|---|
| "The gateway drain defaults to 1800s, so set `agent.restart_drain_timeout: 5` to speed restarts up." | `restart_drain_timeout` **defaults to 0 — no drain at all**; a restart interrupts in-flight agents immediately. Setting `5` *increases* the wait. The 1800 figure is `HERMES_AGENT_TIMEOUT`, the **idle-agent** timeout, unrelated to restart drain. The only real drain is `cron_drain_timeout` (default 30s). **No config change applied.** |
| "`hermes cron create --schedule '0 4 * * 1' --prompt '…'`" | `hermes cron create` takes **positional** `schedule [prompt]`; there are no `--schedule` / `--prompt` flags. The command as written fails. (And see above for why cron is the wrong mechanism regardless.) |
| "`_spawn_hermes_action` lives in `hermes_cli/web_server.py`." | It lives in `hermes_cli/web_routers/{profiles,tools}.py`. The underlying cgroup diagnosis is sound; the file reference is not. |

The upstream `systemd-run --user --scope` code fix remains a reasonable idea for the
in-app path, but this install does not need it — the timer sidesteps the problem.

### Verified

**The whole path was exercised on the live VM, not just installed.** `02-vm-install.sh`
re-run to exit 0; timer armed for `Sun 2026-08-23 04:25:21 UTC`; then
`systemctl --user start hermes-autoupdate.service` — the same unit the timer fires — was
run against a VM that was genuinely 3 commits behind:

| | |
|---|---|
| Unit result | `Result=success`, `ExecMainStatus=0` |
| Version moved | `upstream 209e2ebd (+1 carried commit)` → `upstream 8e475ed2` |
| Markers | `last-success` only — no `last-failure` |
| Restart order | gateway `09:42:35` → dashboard `09:42:42` |
| `03-verify.sh` | **14/14**, including the new check 14 |

That restart order is the proof the design works: the updater restarted the gateway,
**survived it** (a cron- or dashboard-launched updater would have been reaped there), and
then restarted the dashboard.

`hermes update --plan` and `--check` were also run read-only beforehand. Desktop side: `/Applications/Hermes.app` carries **no
`app-update.yml`**, so there is no electron auto-update feed; `hermes desktop` is
documented as *"Build and launch the native desktop app"*, confirming the app is built
from its own checkout and cannot be updated by a VM-side timer.

---

## [0.14.4] — 2026-08-19

**Re-probed the live install and corrected the front page.** The repo had been claiming
Hermes v0.19.0 since 2026-07-28; the box has been on **v0.20.4** since the 2026-08-18
rebuild. No change to what gets installed — this is the "verify, don't trust" rule
applied to our own shop window.

### Fixed

- **Hermes version — `v0.19.0` → `v0.20.4` (`2026.8.18`)** in the README badge, and in
  the "Verified against" lines of `gcp/vpc-install/README.md` and `INSTALL.md`. Those
  lines now also say out loud that `02-vm-install.sh` installs Hermes **unpinned** from
  upstream `install.sh`, so a fresh run gets whatever is current — re-probe
  `hermes --version` rather than trusting the line. (`hermes` is not on the PATH of a
  non-interactive SSH shell; it lives at `~/.local/bin/hermes`.)
- **Model badge — `gemini-3.6-flash` → `gemini-3.7-flash`**, which has been the default
  since 0.13.0. The live `~/.hermes/config.yaml` lists `gemini-3.7-flash` then
  `gemini-3.5-flash` on `providers.vertex` @ `global`.
- **Quick start said `03-verify.sh` "targets 9/9"** — it has been 13/13 since 0.13.0.
- **`OPS-NOTES.md` still listed the internal IP as `10.10.0.2`** in the stop/start and
  cost tables; the current VM is `10.10.0.3`, and the tables now say the address is
  per-VM-creation rather than fixed.
- **GitHub repo About** — description rewritten to the current stack and "verified
  13/13", homepage set to the upstream Hermes project, topics extended with
  `private-vpc`, `eu-data-residency`, `playwright`. It had advertised "9/9".

### Added

- **`Hermes Agent version` row in the `AGENTS.md` canonical-facts table.** There was a
  Honcho version row but none for Hermes itself, which is exactly why the v0.19.0 claim
  went unchallenged for three weeks. Same unpinned-install warning as Honcho carries.
- Live probe stamped into the facts table (2026-08-19): **Chrome 151.0.7922.169**,
  SearXNG (`searxng` + `searxng-valkey`) and Honcho (4 containers) up, `hermes-gateway`,
  `hermes-dashboard` and `vertex-openai-proxy` all `active`, Ubuntu 26.04 LTS,
  17 GB of 96 GB disk used.

---

## [0.14.3] — 2026-08-19

**Every PR now claims a version, and every version becomes a release automatically.**
Governance only — no change to what gets installed.

### Added

- **`.github/workflows/release.yml`** — on every push to `main`, reads the top entry of
  `CHANGELOG.md`, and if that version has no release yet, tags the merge commit and
  publishes a GitHub release whose notes *are* that entry. If the release already exists,
  its notes are refreshed from the changelog, so correcting an entry corrects the release.
  Idempotent, so a re-run or a `skip-changelog` merge is a no-op.
- **`.github/scripts/changelog.py`** — the parser both workflows share (`top`, `versions`,
  `notes <x.y.z>`, `newer <a> <b>`). Runnable by hand to preview release notes:
  `python3 .github/scripts/changelog.py notes 0.14.3`.
- **Version-bump enforcement in the `changelog` check.** A PR must now (a) touch
  `CHANGELOG.md`, (b) declare a version strictly above the one on `main` and not already
  tagged, and (c) keep the version badge in `README.md` and the "Currently" line in
  `CLAUDE.md` in step with it. If a concurrent PR lands your version first, the check
  tells you which version `main` is now at so you can renumber.
- **Releases backfilled** for `v0.13.0`, `v0.14.0`, `v0.14.1` and `v0.14.2` — those
  versions had changelog entries but no tags and no releases, which also left every
  compare link in this file pointing at a tag that did not exist.

### Changed

- The `skip-changelog` label now waives the version bump too — a labelled PR ships no
  release, which is the point of it.

---

## [0.14.2] — 2026-08-19

**`main` is protected, and every update must document itself.** Governance only — no
change to what gets installed.

### Added

- **Repository ruleset `main-protected`** on `main`: pull request required (0 approvals,
  so a solo maintainer can still merge), stale approvals dismissed on push, review
  threads must be resolved, linear history, no force-push, no branch deletion. Direct
  `git push origin main` is rejected — **including for repo admins**, whose bypass is
  scoped to pull requests (`bypass_mode: pull_request`): an admin may force-merge a PR
  that fails a required check, and that is logged, but nobody pushes to `main`.
  Repo merge settings now allow **squash and rebase only**, and delete the head branch
  on merge.
- **`.github/workflows/changelog.yml`** — the `changelog` status check, required by the
  ruleset. It fails any PR into `main` whose file list does not contain `CHANGELOG.md`.
  Escape hatch: the **`skip-changelog`** label waives it for changes that document
  nothing (CI plumbing, typos).
- **`.github/pull_request_template.md`** — changelog / version-bump / docs-in-sync and
  "facts were re-probed and dated" checklists.
- **`CONTRIBUTING.md`** — the branch → PR → changelog → tag/release workflow, and the
  exact rules the ruleset enforces.

### Fixed

- The changelog's link block pointed every version at a bare `https://github.com/`.
  It now carries real compare and tag URLs.

---

## [0.14.1] — 2026-08-19

Process change, plus the tooling that makes it followable. No change to what gets installed.

### Added

- **RULE: validate from a virgin installation** — stated at the top of `AGENTS.md`, repeated
  in its agent-conventions section, and pointed to from `CLAUDE.md`, `INSTALL.md` and the
  install README. Never sign off an install change because a re-run over an existing VM
  exited 0.

  The evidence, tabulated in `AGENTS.md`: the 2026-08-18 from-scratch rebuild found **five
  defects an incremental re-run passes straight over** — an apt keyring written 0600, the
  poisoned `sources.list.d` that made every later re-run fail at step 1, a `gpg --dearmor`
  overwrite prompt, an `errexit` trap that killed `dashboard-setup.sh` silently, and a
  `sleep 6` too short for a cold dashboard. **Four were install-blocking**, and all five sat
  latent across three releases that had been re-run and declared working. A re-run proves
  the installer is *idempotent*; it says nothing about whether it *installs*.
- **`scripts/teardown.sh`** — one command back to virgin, because a rule nobody can follow
  cheaply is a rule nobody follows. Deletes the VM, firewall rules, Cloud NAT, router,
  subnet, VPC and service account, in dependency order. Requires typing the VM name to
  confirm; nothing is deleted before that.
  - **Keeps the memory bucket by default** (`--with-bucket` to destroy the backups too),
    since that is the only irreplaceable state.
  - `--vm-only` for a quick VM rebuild, with a warning that **Cloud NAT keeps billing with
    no VM attached**, so full teardown is the cheaper default.
  - Also removes the local gateway LaunchAgent: left pointing at a deleted VM it fails
    forever and squats port 9119 — precisely the stale-agent mess found on the operator's
    Mac from the previous install.

### Changed

- **`INSTALL.md` now warns that 13/13 on an existing VM is not evidence a fresh install
  works.** The checks confirm a *running* system is healthy; they are structurally unable to
  see fresh-state defects.

---

## [0.14.0] — 2026-08-18

**The secure gateway is now permanent by default, and the installer no longer lets you
finish without dashboard credentials.** Both came out of actually connecting a desktop
client to the v0.13.0 install.

### Added

- **`scripts/install-gateway-launchagent.sh`** — one command to make the IAP tunnel
  survive sleep, reboot and network changes. It renders the plist from `00-vars.sh` and
  `which gcloud`, boots out stale agents, `plutil -lint`s the result, and **polls until the
  gateway actually answers** before claiming success. `--uninstall` removes it. Verified
  2026-08-18: killing the tunnel process, it was serving again in **~8s**.
- **`configs/com.hermes.gateway-tunnel.plist` is now a template** with placeholders instead
  of values to hand-edit. Hand-editing had two reliable failure modes: a bare `gcloud`
  (launchd reads no shell profile) and a literal `<you>` left in `HOME`, which fails with a
  credentials error that looks like an IAM problem.
- **Gateway troubleshooting runbook** (`OPS-NOTES.md`) for *"Remote gateway sign-in
  required"*, which is almost always a dead tunnel rather than bad credentials.

### Changed

- **The LaunchAgent is the documented default** in `INSTALL.md` §8 and the README quick
  start (now four commands, not three); the manual `start-iap-tunnel` is demoted to a
  one-off check. Rationale stated in the docs: a hand-started tunnel belongs to the shell
  that launched it and dies with it — the app then reports a sign-in problem that is really
  a transport problem.
- **`02-vm-install.sh` generates a dashboard password when `HERMES_DASHBOARD_PASSWORD` is
  unset**, into `~/.hermes-dashboard-password` (mode 600), and prints the path — never the
  value. Previously, forgetting the export produced an install that finished "successfully"
  with no way to sign in, and you only discovered it later at the desktop app. **Re-runs
  reuse an existing file**, so a routine re-run cannot silently rotate the password and lock
  out connected clients.
  - The generated charset is deliberately **alphanumeric**, not `openssl rand -base64`:
    base64 emits `+`, `/` and `=`, and `+` is decoded as a **space** by form/urlencoded
    parsers, so a base64 password can work in one client and fail in another. 32
    alphanumeric characters ≈ 190 bits, so nothing is given up.
- **Docs now state that an unauthenticated `GET /` returns HTTP 302 → `/login`** and that
  this is the auth gate working. It had been described as `401` in one place, which sends
  people chasing a non-existent fault.

### Fixed

- **Stale `com.hermes.tunnel` LaunchAgent from the pre-VPC install** — an SSH `-L` tunnel to
  a VM in `europe-west1-b` that no longer exists. Found still loaded and failing (exit 1) on
  the operator's Mac, competing for port 9119 with the real gateway. The installer script
  now boots it out and archives its plist to `.superseded`.
- **Bootout needed verification and retry.** A single `launchctl bootout` reported success
  while the job was still listed with a fresh PID moments later, because KeepAlive had
  already relaunched it. The script now re-checks and retries up to 5 times, and says what
  to do by hand if the job still will not unload.
- **The new install script hit the same errexit trap as v0.13.0's #4** — worth recording,
  because it is clearly an easy mistake to repeat. `CODE="$(curl …)"` under `set -e`: curl
  exits **7** on every probe before the tunnel is listening, so the first failed attempt
  killed the script and the retry loop never ran. It exited 7 silently while the agent came
  up fine a second later. Fixed with `|| true`; the comment now marks it load-bearing.

---

## [0.13.0] — 2026-08-18

**`gemini-3.7-flash` is the default chat model.** The install was also **torn down and
rebuilt from an empty project**, which surfaced **four install-blocking defects** that no
incremental re-run on an existing VM could ever hit. `03-verify.sh` grew 9 → 13 checks and
passes 13/13. Still **zero external API keys**.

**Honcho stays on `gemini-2.5-flash`** — moving it to `gemini-3.5-flash` was attempted and
**reverted**: it breaks every dialectic query. Details under *Fixed*.

### Changed

- **Default chat model → `google/gemini-3.7-flash`** (was `gemini-3.6-flash`). Proven with
  a real tool-using agent turn, not just an HTTP 200 — see *Added*.
- **Model catalog → `{gemini-3.7-flash, gemini-3.5-flash}`.** `gemini-3.5-flash-lite`
  **dropped**: with 3.7-flash as flagship and 3.5-flash as the strict-EU-capable fallback,
  a third flash tier earned nothing. It still answers 200 @ `global` — re-add it to
  `HERMES_MODELS` if you want it.
- **`VERTEX_REGION` stays `global`.** Re-probed 2026-08-18 (`:generateContent` POST):

  | Model | eu-w1 | eu-w2 | eu-w3 | eu-w4 | eu-n1 | global |
  |---|---|---|---|---|---|---|
  | `gemini-3.7-flash` | 404 | 404 | 404 | 404 | 404 | **200** |
  | `gemini-3.6-flash` | 404 | 404 | 404 | 404 | 404 | **200** |
  | `gemini-3.5-flash` | 404 | **200** | **200** | 404 | 404 | **200** |
  | `gemini-3.5-flash-lite` | 404 | 404 | 404 | 404 | 404 | **200** |
  | `gemini-2.5-flash` | **200** | **200** | **200** | **200** | **200** | **200** |

  No European regional endpoint serves 3.7-flash, so the EU-residency exception (**chat
  inference only** — all storage, and Honcho's embeddings, stay in `europe-west2`) still
  stands. **`gemini-3.5-flash` gained `europe-west3`** since 2026-07-28 — an EU-*member*
  region — so the strict-EU fallback is widening. This is why the tables carry dates.
- **VM internal IP is now `10.10.0.3`** (was `10.10.0.2`). It is DHCP-assigned per VM
  creation; `AGENTS.md` now says not to treat it as a fixed fact.

### Fixed — four defects that only a from-scratch install reveals

1. **Chrome's apt keyring was written mode 0600, killing the install at step 4.**
   `gpg --dearmor -o` sets 0600 itself (not a umask effect — root's umask is 0022), and
   apt fetches as the unprivileged `_apt` user, so apt ignored the key and rejected the
   repo: `E: The repository '…/chrome/deb stable InRelease' is not signed.` Now
   `chmod 0644` immediately after the dearmor.
2. **Worse: that failure was unrecoverable by re-running.** The `sources.list.d` entry is
   written next to the bad keyring, so every *later* `apt-get update` — including the one
   at **step 1** — failed with exit 100, long before the step-4 code that could repair it.
   One failed Chrome install permanently broke the documented "idempotent, safe to
   re-run" guarantee. **Step 1 now self-repairs** any keyring `_apt` cannot read before
   calling `apt-get update`.

   *Evidence, stated precisely:* the exit-100 failure was observed on the original
   from-scratch run. A later regression run restored the 0600 keyring and the emptied auth
   block and confirmed the **self-repair fires and the install completes clean** (8/8,
   exit 0) — it did **not** re-observe the exit 100, because `apt-get update` reused
   still-valid cached `InRelease` data instead of re-verifying the signature. So: the
   blocker is real and recorded from the run that hit it; the regression run proves the
   repair path works, not that the failure recurs without it.
3. **`gpg --dearmor -o` blocked on an interactive overwrite prompt** when the keyring
   already existed, which fails outright over a non-tty `ssh --command`. Added `--yes`.
4. **`dashboard-setup.sh` died on its first real line on any fresh install.**
   `EXISTING_SECRET="$(grep … | head -1 | cut …)"` under `set -euo pipefail`: on a new
   `.env` the grep matches nothing and exits 1, `pipefail` propagates it, and `set -e`
   killed the script — **silently**, because "no match" prints nothing and
   `02-vm-install.sh` sent its stdout to `/dev/null`. The whole install ended at step 8
   with no error message at all. Added `|| true`, hardened the same pattern in
   `02-vm-install.sh`'s `honcho_key_real()`, and made the caller report the failure with
   the command to re-run instead of dying mutely.

### Fixed — other

- **`HONCHO_MODEL` reverted to `google/gemini-2.5-flash`; do NOT use Gemini 3.x.**
  `gemini-3.5-flash` fails every dialectic query with
  `400 … "Function call is missing a thought_signature"`. Gemini 3.x are thinking models:
  a function call they emit carries an opaque `thought_signature` that Vertex **requires**
  echoed back, delivered as `message.extra_content.google.thought_signature` — a Google
  extension the OpenAI wire format has no field for. Honcho's OpenAI client drops it when
  re-serialising for the next tool iteration, so Vertex rejects the conversation from
  iteration two on. **The shim cannot fix it**: it is a pass-through and cannot recreate a
  signature the client already discarded. A/B on the live box, only this value changed:
  3.5-flash → HTTP 400 on all 3 retries, no answer; 2.5-flash → 200, facts recalled.
  **Hermes' own chat is unaffected on 3.7-flash** — different code path, and its provider
  round-trips signatures correctly.
- **False "dashboard not responding" warning on every from-scratch install.** The script
  waited a fixed `sleep 6`, but on a cold VM the dashboard is listening yet not answering
  at 6s and returns 302 by ~50s. Both `02-vm-install.sh` and `03-verify.sh` now poll
  instead of probing once. `03-verify.sh` also stops calling 302 a failure — a redirect
  to `/login` *is* the engaged auth gate.
- **Stale claim removed: "Honcho has NO Vertex support and needs its OWN keys."** Still
  in `00-vars.sh` and `02-vm-install.sh`'s fallback message, contradicting
  `MEMORY_LLM_BACKEND=vertex` (the default since 0.12.0) a few lines below. Also corrected
  in `AGENTS.md`.
- **Narrowed an overstated v0.12.0 claim.** `gcp/vpc-install/README.md` said a fact pushed
  into Honcho was "extracted and correctly recalled". *Recall* is what was demonstrated;
  extraction into derived conclusions was not, and on Honcho `2163ab1` it does not happen
  for API-inserted messages at all.

### Added

- **`03-verify.sh`: 9 → 13 checks.** All four new checks cover failures the old suite
  reported as **PASS**:
  - **Test 13 — Honcho end-to-end dialectic.** Seeds a fact, asks for it back, asserts it
    comes out. **The only check that catches a bad `HONCHO_MODEL`** — confirmed to FAIL on
    3.5-flash and PASS on 2.5-flash. Asserts on the dialectic answer only, deliberately
    not on the representation (see the deriver known issue).
  - **Gateway liveness** — `hermes-gateway.service` is a separate unit from the dashboard
    and nothing in the client UI reveals a dead one, but cron, routines and any messaging
    bot need it.
  - **Shim chat returns non-empty content for `HONCHO_MODEL`** — proves the shim's auth
    injection works. Its comment now records that it **cannot** catch the
    thought_signature failure, because a single-shot completion has no tool loop.
  - **Shim embeddings return exactly `VERTEX_EMBED_DIMENSIONS` values** — this path works
    around a genuinely broken upstream (Vertex's OpenAI-compat `/embeddings` 500s), and a
    width mismatch fails every pgvector insert while staying invisible to liveness checks.
- **A scripted agent turn — the long-standing `[Unreleased]` item, now done.**
  `hermes -z '<prompt>'` runs one turn non-interactively; it is the **TUI** that cannot be
  piped, not the CLI. Asked to create a directory and file, `gemini-3.7-flash` used its
  tools and the file landed on the VM. Recorded as an OPS-NOTES recipe.
- **Remote gateway verified from the client side** — `gcloud compute start-iap-tunnel`
  plus `curl` from the operator's Mac returns `302 → /login` through the tunnel.
- **OPS-NOTES recipes**: "Run one agent turn non-interactively" and "Prove Honcho really
  remembers" (with the thought_signature symptom called out).
- **Honcho commit SHA recorded** (`2163ab1`, 2026-08-18) in `AGENTS.md`, plus a warning
  that `git clone --depth 1` of `main` **pins nothing** — so Honcho-specific facts can go
  stale with no change to this repo.
- **Documented Honcho's hardcoded 250-token ceiling on the `minimal` dialectic tier**
  (every other tier gets 8192). Gemini reasoning models spend that budget on reasoning:
  measured on an 80-token prompt, 3.5-flash used 237 reasoning / 9 content and 2.5-flash
  236–240 / 6–10 — both truncate, so this is an upstream default to know about, not a
  reason to pick either model.

### Documented — Honcho memory extraction verified, and two traps that mimic a failure

**Memory extraction works** (Honcho `2163ab1`): nine seeded facts were each extracted
correctly, and Hermes' own agent turn produced a conclusion in the `hermes` workspace. Two
behaviours made a healthy install look broken — both now written up in `AGENTS.md`:

- **The deriver batches on purpose, for up to 30 minutes.** It claims a representation
  work unit only once `DERIVER_REPRESENTATION_BATCH_WORK_UNIT_TARGET_TOKENS` (**512**) is
  reached or `DERIVER_REPRESENTATION_BATCH_MAX_AGE_SECONDS` (**1800**) expires. A handful
  of short test messages trips neither, so `queue/status` sits at N pending / 0
  in-progress and nothing is wrong. Polling backoff is not the cause (30s max interval).
  Setting the token target to 0 drains the queue in ~40s — useful for verification, but
  restore it, since 0 means one LLM call per message.
- **`POST …/peers/{peer}/representation` needs `{"session_id": …}`.** With an empty body it
  returns `{"representation":""}` — indistinguishable from "nothing was extracted". This
  is what made the batching look like a hard failure. `…/peers/{peer}/search` needs no
  session; `conclusions/query` needs `observer`/`observed` inside `filters`.

This is why `03-verify.sh` test 13 asserts on the dialectic answer (immediate) rather than
the representation (up to 30 min late on a fresh install).

---

## [0.12.0] — 2026-07-29

**Honcho now runs entirely on Vertex AI — zero external API keys.** Honcho's reasoning
bills to the same GCP project and service account as Hermes chat.

### Added

- **`scripts/vertex-openai-proxy.py`** — an OpenAI-compatible shim in front of Vertex,
  run as `vertex-openai-proxy.service` on `127.0.0.1:8900`. Python **stdlib only**, no
  dependencies. It exists because two things block pointing Honcho at Vertex directly:
  1. **Vertex OAuth tokens expire hourly**, but Honcho wants a *static* `api_key`. The
     shim mints a fresh token from the metadata server per request (cached, refreshed
     5 min before expiry) — no 45-minute container-restart loop.
  2. **Vertex's OpenAI-compat `/embeddings` endpoint is broken.** Verified 2026-07-28:
     HTTP 500 "Internal error" for *every* model name (`gemini-embedding-001`,
     `text-embedding-004/005`, with and without the `google/` prefix) in **both**
     `global` and `europe-west2`. The native `:predict` API works fine on the same
     models. The shim translates `/v1/embeddings` → `:predict` and converts back.
  Chat is a transparent pass-through including **SSE streaming**; only auth is added.
- **`configs/honcho-vertex.env`** — points all ten Honcho module transports at the shim.
- **`configs/honcho-gemini-only.env`** — single-AI-Studio-key alternative.
- **`MEMORY_LLM_BACKEND`** in `00-vars.sh`: `vertex` (default) | `gemini` | `manual`.
- **`OPS-NOTES.md` §8 — stop / start / reboot semantics**, with a per-component table of
  what returns automatically, and the fact that **Cloud NAT keeps billing while the VM is
  stopped**.
- **`OPS-NOTES.md` §9 — scenario cookbook**: shell in, update Hermes, restart the
  gateway, kill a wedged gateway, restart everything, re-apply managed config, inspect
  the shim, free disk, rotate the password, audit who can reach the box.

### Changed

- `HONCHO_MODEL` defaults to `google/gemini-2.5-flash`, **not** 3.6-flash: 3.6-flash
  spends output budget on reasoning tokens (observed `max_tokens=20` consumed entirely
  by 16 reasoning tokens, empty content), which is wasteful for short structured
  extractions.
- Embeddings pinned to `europe-west2` via the native API — **EU-resident even though
  chat uses `global`**. Dimensionality forced to **1536** to match Honcho's pgvector
  column; `gemini-embedding-001` returns 3072 by default, which would fail every insert.

### Fixed

- **A stray manually-started proxy masked a failing systemd unit.** During testing a
  `nohup` process held port 8900, so the real unit was in a restart loop
  (`Result=exit-code`) while everything *appeared* healthy — the install would have
  survived a reboot by luck, not design. Killed the stray; the unit now owns the port.
  *Lesson: verify which PID owns the port, not just that the port answers.*

### Verified live (2026-07-29)

End-to-end memory extraction through Vertex, with **no external keys configured**:

| Step | Result |
|---|---|
| Shim health / chat / **streaming** | 200 / 200 / real SSE deltas |
| Shim embeddings | 200, **1536 dims** (batch of 2 → 2 × 1536) |
| Reachable from Honcho container | ✅ via compose gateway `172.19.0.1` |
| Message ingest (`POST /v3/.../messages`) | **201** |
| Deriver extraction errors | **0** |
| Dialectic recall | *"Kennet works at Visma in Denmark and strongly prefers Bun over npm for TypeScript projects."* — exactly the inserted fact |
| **Falsification: shim stopped** | dialectic → **HTTP 500** |
| **Falsification: shim started** | dialectic → **HTTP 200**, fresh answer |
| `03-verify.sh` | **9/9** |

The falsification pair is the real proof: Honcho's LLM calls demonstrably depend on the
shim, so they are demonstrably going to Vertex.

Reboot-survival audited: Honcho's shipped compose already has `restart: unless-stopped`
on all four services, Docker is `enabled` at boot, and all four user units are `enabled`
under linger. Internal IP `10.10.0.2` persists across stop/start. **Only the client-side
IAP tunnel needs re-opening.**

### Known limits

- Vertex may not support OpenAI `json_schema` structured output over the compat
  endpoint; if Honcho's extraction ever returns malformed JSON, set
  `DERIVER_MODEL_CONFIG__STRUCTURED_OUTPUT_MODE=json_object`.
- The shim has **no authentication** — it hands Vertex access to anything that can reach
  it. Safe only because this VM has no external IP and the firewall admits only Google's
  IAP range. Never expose port 8900.
- Reading the shim's access log needs `systemd-journal` group membership
  (`sudo usermod -aG systemd-journal $USER`, then re-login).

---

## [0.11.1] — 2026-07-28

### Fixed

- **Re-running the installer silently logged out every client.**
  `dashboard-setup.sh` regenerated `HERMES_DASHBOARD_BASIC_AUTH_SECRET` on every run.
  That secret signs dashboard session tokens, so a routine re-run of
  `02-vm-install.sh` — e.g. to change the model list in 0.11.0 — invalidated all live
  sessions. The desktop app then reported **"Remote gateway session has expired /
  Lost connection to the gateway"**, which reads like a broken tunnel or a dead VM
  rather than an intended logout, sending you diagnosing the wrong layer entirely.
  The secret is now **preserved** when one already exists; rotate deliberately with
  `ROTATE_DASHBOARD_SECRET=1 dashboard-setup.sh …` (do that if a password may have
  leaked). Verified on the live VM: re-running leaves the secret byte-identical, keeps
  exactly 4 auth lines, and an existing session stays valid.

  *Diagnostic note for the future:* the desktop log line
  `Cached remote Hermes backend failed liveness probe` alongside a tunnel that answers
  `HTTP 302` and credentials that return `{"ok":true}` means the transport is fine and
  the **session** is stale — click "Sign out & sign in", don't touch the tunnel.

---

## [0.11.0] — 2026-07-28

Switches chat to **the three latest Gemini flash models**, which requires moving
inference to the Vertex `global` endpoint. Owner-approved; **infrastructure stays in
`europe-west2`**.

### Changed

- **Model catalog is now the three newest flash models**, replacing the 3.5/2.5 pair:
  | | |
  |---|---|
  | `google/gemini-3.6-flash` | **default** |
  | `google/gemini-3.5-flash` | switchable |
  | `google/gemini-3.5-flash-lite` | switchable |

  Removed: `gemini-2.5-flash`, `gemini-2.5-pro`.
- **`VERTEX_REGION` → `global`.** ⚠️ **EU-residency exception, inference only**
  (owner decision, re-affirmed 2026-07-28). `global` is not region-pinned.
  **Everything else stays in `europe-west2`** — VM, subnet, GCS bucket, backups,
  SearXNG, Honcho — so **data at rest remains in a European region**. Only the
  inference endpoint is unpinned. This restores the same posture as v0.9.0 and
  reverses 0.10.0's move to a strict regional endpoint.
- **`HERMES_MODEL_ALT` replaced by `HERMES_MODELS`**, a space-separated list.
  `02-vm-install.sh` generates the `providers.vertex.models` YAML block from it, so
  adding or removing a model is a one-line edit in `00-vars.sh` instead of a
  template change. The installer now also **fails fast** if `HERMES_MODELS` is empty
  or if `HERMES_MODEL` is not present in it (which would show a picker that excludes
  the running model).

### Why `global` is unavoidable for these models

Re-probed 2026-07-28 (`:generateContent` POST, HTTP status):

| Model | eu-w1 | eu-w2 | eu-w3 | eu-w4 | eu-n1 | global |
|---|---|---|---|---|---|---|
| `gemini-3.6-flash` | 404 | 404 | 404 | 404 | 404 | **200** |
| `gemini-3.5-flash` | 404 | **200** | — | 404 | — | **200** |
| `gemini-3.5-flash-lite` | 404 | 404 | — | — | — | **200** |

No European regional endpoint serves 3.6-flash or 3.5-flash-lite. **To revert:**
`VERTEX_REGION="europe-west2"` + `HERMES_MODELS="google/gemini-3.5-flash google/gemini-2.5-flash"`,
and re-probe — flip back the moment the newer models land in a European region.
`03-verify.sh` prints a residency warning whenever `global` is in use.

### Fixed

- **`awk -v` with a multi-line value is not portable.** The first implementation of
  the model-list substitution used `awk -v repl="$MULTILINE"`, which works with GNU
  awk (the Ubuntu VM) but fails on BSD/macOS awk with `awk: newline in string`. It
  would therefore have worked on the VM and broken for anyone cloning the repo on a
  Mac. Now uses `python3`, which is guaranteed on both.
- **Model list built with `printf` + an explicit array** instead of `$'\n'`
  concatenation and unquoted word-splitting. `for m in ${HERMES_MODELS}` does **not**
  split in zsh (the macOS default shell), which silently yields a single malformed
  model name; `read -r -a` splits the same way everywhere.

### Verified live after the change (2026-07-28)

`02-vm-install.sh` re-run on the existing VM, exit 0. All three models probed from
the VM's own service account at `global`: **200 / 200 / 200**. `config.yaml` shows
`model: google/gemini-3.6-flash`, `region: global`, exactly three catalog entries, no
2.5 models. `03-verify.sh`: **8/9** with the expected residency warning; gateway and
dashboard restarted and active; gateway unit correctly preserved
(`keeping the Hermes installer's own unit`); Honcho still correctly reported as
missing its keys.

---

## [0.10.1] — 2026-07-28

Fixes found by **actually running 0.10.0 end-to-end** against `test-disco-cm`.
Both were real defects that static validation could not have caught.

### Fixed

- **`03-verify.sh` reported a false PASS for Honcho.** The check used
  `curl -o /dev/null -w '%{http_code}' … || echo 000`. On a connection failure curl
  *already* prints `000` **and** exits non-zero, so `|| echo 000` concatenated into
  `000000`, which compared unequal to `"000"` and passed. The first live run reported
  a confident **9/9 including `Honcho listening (/health -> HTTP 000000)`** while
  nothing was listening on `:8000` at all. Now captures plainly, defaults only when
  empty, and matches with a `case` — the same run then correctly reported **8/9**
  with Honcho failing. *Lesson: a health check that cannot fail is worse than no
  health check.*
- **`02-vm-install.sh` clobbered the Hermes installer's gateway unit.** The official
  installer generates its own `hermes-gateway.service` at the same path, and it is
  strictly better than our template — it encodes Hermes' restart semantics
  (`RestartForceExitStatus=75`, `RestartPreventExitStatus=78`), `KillMode=mixed`, a
  SIGUSR1 `ExecReload`, an `ExecStopPost` cgroup cleanup, and the venv
  `PATH`/`VIRTUAL_ENV`. The installer now **detects and preserves** an existing unit,
  prefers `hermes gateway install` when none exists, and treats
  `systemd/hermes-gateway.service` as a documented fallback only.

- **`MEMORY_PROVIDER=builtin` would have written an invalid config.** There is no
  Hermes memory provider named `builtin`. Source of truth (`hermes_cli/config.py`
  memory defaults): `"provider": ""` with the comment *"External memory provider
  plugin (empty = built-in only)"* — built-in is selected by an **empty string**, and
  the registered plugins are `honcho, openviking, mem0, hindsight, holographic,
  retaindb, byterover, supermemory`. `00-vars.sh` advertised `builtin` as a value and
  the template rendered it straight through, naming a plugin that does not exist.
  `02-vm-install.sh` now translates `builtin|none|off|""` → `""`, verified to render
  `memory.provider: ''` while `honcho` still renders `'honcho'`.
- **Placeholder API keys read as "configured".** `~/honcho/.env.template` ships
  *non-empty* dummy values (e.g. `LLM_OPENAI_API_KEY=your-openai-key`), so a
  `grep -qE '^KEY=.+'` test reports the key as set and Honcho then fails to start
  with a confusing downstream error. `02-vm-install.sh` now validates **both** keys
  against empty, known placeholder patterns, and a minimum length. Same root cause as
  the false-PASS above: **non-empty is not the same as valid.**

### Added

- **`RestartPreventExitStatus=78` is now documented as an ops fact:** a Hermes config
  error exits `78` and deliberately does *not* restart-loop. A gateway that is
  `inactive (dead)` immediately after a config change is usually this — read the
  journal instead of forcing restarts (`OPS-NOTES.md` §2).

### Verified live on `test-disco-cm` (2026-07-28)

Provisioning and install both exited 0. Independently audited afterwards:

| Check | Result |
|---|---|
| VM external IP | **none** (internal `10.10.0.2`) |
| Firewall ALLOW rules | only `35.235.240.0/20` → `tcp:22`, `tcp:9119`, target-tagged |
| `0.0.0.0/0` rules | **only the DENY** at priority 65000 |
| Cloud NAT / Private Google Access | `hermes-nat` up / `True` |
| Hermes | v0.19.0 (2026.7.20) |
| Chrome | 150.0.7871.186 |
| Playwright | `chromium-1234` + `chromium_headless_shell-1234` |
| Vertex `gemini-3.5-flash` @ `europe-west2` | **HTTP 200** |
| SearXNG JSON API | **HTTP 200, 20–32 results** |
| Dashboard | `hermes-dashboard.service` active, `:9119` on `0.0.0.0` |
| Dashboard auth gate | `401` without credentials — auth is **ON** |
| Dashboard login | `POST /auth/password-login` → **200 `{"ok":true}`** |
| Gateway | active (installer's unit) |
| linger | `Linger=yes` |
| Honcho | **not running** — needs its own LLM keys (expected) |
| Overall | **8/9**, the one failure being Honcho by design |

Also learned: the dashboard login payload requires a `provider` field —
`{"provider":"basic","username":…,"password":…}` — and `/api/auth/providers`
advertises `{"name":"basic","supports_password":true}`. Raw HTTP Basic (`curl -u`)
does **not** authenticate; the flow mints a session token. Ubuntu 26.04 ships glibc
2.43 and Playwright installed without needing the platform override.

---

## [0.10.0] — 2026-07-28

First versioned release. Adds a **private-network install** that supersedes the
original public-IP setup, and corrects the repo's stale "current install" claims.

### Added

- **`gcp/vpc-install/` — a complete, cloneable install package.** Self-contained
  alternative to the original `gcp/` scripts, not an add-on. 19 files:
  - `00-vars.sh` — single source of truth; the only file you edit when cloning.
  - `01-gcp-setup.sh` — custom VPC + subnet (Private Google Access), Cloud Router
    + Cloud NAT, IAP-only firewall, service account, GCS bucket, VM, operator IAM.
  - `02-vm-install.sh` — Hermes, Chrome + Playwright, SearXNG, Honcho, systemd
    services, hourly GCS backup. Idempotent.
  - `03-verify.sh` — 9-point health check including a real Vertex
    `:generateContent` call.
  - `README.md` / `INSTALL.md` / `OPS-NOTES.md`.
- **Private-network architecture.** VM has **no external IP**. The only firewall
  ingress is Google's IAP range (`35.235.240.0/20`) on `tcp:22` and `tcp:9119`,
  backed by an explicit deny-all at priority 65000. No `0.0.0.0/0` allow exists.
  Access requires `roles/iap.tunnelResourceAccessor`, so it is IAM-gated,
  auditable and revocable with one command.
- **Secure gateway via IAP tunnel.** `gcloud compute start-iap-tunnel` replaces the
  plain SSH tunnel for both the desktop app and the browser. macOS LaunchAgent
  (`configs/com.hermes.gateway-tunnel.plist`) keeps it alive across sleep/reboot.
- **Self-hosted SearXNG** as the web-search backend — Docker, `127.0.0.1:8080`,
  JSON API enabled, generated `secret_key`.
- **Chrome + Playwright Chromium** on the VM, headless, with an automatic
  `PLAYWRIGHT_HOST_PLATFORM_OVERRIDE` fallback for unrecognised Ubuntu releases.
- **`hermes-gateway.service`** for cron/routines, plus a **gateway watchdog**
  recipe (`OPS-NOTES.md` §2c) — `Restart=always` cannot detect a gateway that is
  alive but wedged, so a timer probes `hermes gateway status` and restarts on failure.
- **`OPS-NOTES.md`** — SSH operations runbook: idle/wedged gateway recovery,
  in-place backend upgrades and post-upgrade config checks, per-service updates,
  the setup the desktop app cannot do, backup/restore (including Honcho's Postgres
  volume, which the GCS rsync does not cover), tunnel troubleshooting, and a
  symptom → cause table.
- **Top-level `README.md`** and this `CHANGELOG.md`.

### Changed

- **Default model → `google/gemini-3.5-flash`** on the **regional** European
  endpoint `europe-west2`, dropping the previous `global`-endpoint EU-residency
  exception. Switchable alternate is `gemini-2.5-flash`.
- **Region → `europe-west2`** (VM, subnet, bucket, Vertex) — the only European
  regional Vertex endpoint serving `gemini-3.5-flash`. The **UK-adequacy caveat**
  is documented, with two EU-member fallback paths.
- **OS → Ubuntu 26.04 LTS** (`ubuntu-2604-lts-amd64`), up from 24.04 LTS.
- **VM → `e2-standard-4` / 100 GB**, up from `e2-standard-2` / 50 GB. Chrome +
  Playwright + Postgres/pgvector + SearXNG + Valkey + Hermes do not fit in 8 GB.
- **Shielded VM** (Secure Boot, vTPM, integrity monitoring) and **OS Login** enabled.
- `AGENTS.md` "Canonical facts" — retitled to make clear it is **historical**, with
  the verification date and a pointer to the new variant.
- `gcp/README.md` — banner directing new installs to `vpc-install/`.

### Fixed

- **`AGENTS.md` claimed a running install that does not exist.** Verified
  2026-07-28: `gcloud compute instances list --project=test-disco-cm` returns
  **0 items**. The documented `hermes-agent` VM was gone, so every row of the
  canonical-facts table was stale. A rebuild is a fresh install, not a modification.
- VM creation in `01-gcp-setup.sh` now uses check-then-create instead of
  `|| echo "already exists"`, which was swallowing real failures (quota, bad image
  family, capacity) and then stalling in the SSH wait loop.

### Verified this release (re-probe before trusting)

Vertex `:generateContent` POST, **2026-07-28**:

| Model | europe-west2 | europe-west1 | europe-west4 | global |
|---|---|---|---|---|
| `gemini-3.5-flash` | **200** | 404 | 404 | 200 |
| `gemini-2.5-flash` | **200** | 200 | — | — |
| `gemini-2.5-pro` | 404 | 200 | — | — |
| `gemini-3.6-flash` | 404 | 404 | 404 | 200 |
| `gemini-3.5-flash-lite` | 404 | 404 | 404 | 200 |

Against the installed **Hermes Agent v0.19.0** source:

- Web-search backends are exactly
  `{parallel, firecrawl, tavily, exa, searxng, brave-free, ddgs, xai}`.
  **SerpApi is not among them.**
- `terminal.backend` accepts `local | docker | ssh | modal | daytona | singularity`.
- Honcho self-hosting uses `HONCHO_BASE_URL`; `HONCHO_API_KEY` is cloud-only.
- `hermes update` exists as an in-place upgrade path.
- `browser.cdp_url` / `BROWSER_CDP_URL` can point Hermes at a remote Chrome.

GCP image families available: `ubuntu-2204-lts`, `ubuntu-2404-lts-amd64`,
`ubuntu-2604-lts-amd64` (+ arm64 variants).

### Known gaps

- **Honcho needs its own keys.** It has no Vertex support, so it requires an AI
  Studio Gemini key + an OpenAI embeddings key in `~/honcho/.env`. Until those are
  filled, Honcho does not start and `03-verify.sh` check 7 fails by design. This is
  the only component not billed through the GCP project.
- **Dashboard password is plaintext** in `~/.hermes/.env` (mode 600). Fine for a
  pilot; use the scrypt hash beyond that.
- **SearXNG and Honcho have no authentication of their own** — hence the
  `127.0.0.1` binds. Never publish those ports.
- **The GCS backup excludes Honcho's Postgres volume.** Use `pg_dumpall` or a disk
  snapshot for full coverage (`OPS-NOTES.md` §6).

---

## [0.9.0] — 2026-07-22 *(retroactive — pre-changelog state)*

The original public-IP install, reconstructed here for continuity. Not a tagged
release; recorded so 0.10.0's changes have a baseline.

- All-GCP install on the `default` network, VM with an external IP, dashboard
  reached over a plain SSH tunnel.
- `europe-west1` / `europe-west1-b`, `e2-standard-2`, Ubuntu 24.04 LTS, 50 GB.
- Chat model `gemini-3.6-flash` on the Vertex **`global`** endpoint — a documented,
  owner-approved **EU-residency exception**, because 3.6-flash and
  `gemini-3.5-flash-lite` are global-only on Vertex.
- Knowledge via Vertex AI Search (Drive connector + verified URLs) over MCP, and an
  alternative reusing an existing ETAP knowledge graph over MCP + bearer token.
- Slack team/support bot with per-channel personas and profile isolation.
- Self-hosted Honcho memory; hourly GCS backup.
- Guides: `DESKTOP-SETUP.md`, `SLACK-TEAM-SETUP.md`, `KNOWLEDGE-DATASTORE.md`,
  `SUPPORT-BOT-SETUP.md`, `PROFILES-ISOLATION.md`, `EXTERNAL-KG-MCP.md`,
  `REFERENCE.md`, `SUBPROCESSOR-MONITOR-PLAN.md`.

---

[Unreleased]: https://github.com/Emerging-Tech-Visma/hermes-agent/compare/v0.14.4...HEAD
[0.14.4]: https://github.com/Emerging-Tech-Visma/hermes-agent/compare/v0.14.3...v0.14.4
[0.14.3]: https://github.com/Emerging-Tech-Visma/hermes-agent/compare/v0.14.2...v0.14.3
[0.14.2]: https://github.com/Emerging-Tech-Visma/hermes-agent/compare/v0.14.1...v0.14.2
[0.14.1]: https://github.com/Emerging-Tech-Visma/hermes-agent/compare/v0.14.0...v0.14.1
[0.14.0]: https://github.com/Emerging-Tech-Visma/hermes-agent/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/Emerging-Tech-Visma/hermes-agent/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/Emerging-Tech-Visma/hermes-agent/releases/tag/v0.12.0
[0.11.1]: https://github.com/Emerging-Tech-Visma/hermes-agent/releases/tag/v0.11.1
