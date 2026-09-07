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

- **Exercise the virgin-install rule at least once.** v0.14.1 added the rule and
  `scripts/teardown.sh`, but it has **not yet been run**: the installer was validated by
  restoring broken preconditions on a live VM, not by installing onto a virgin OS. Strongly
  evidenced, not proven, for a from-zero install. Do a teardown → 01 → 02 → 03 pass and
  record the date, Hermes version and Honcho SHA in `AGENTS.md`.
- **Pin the Honcho clone.** `02-vm-install.sh` does `git clone --depth 1` of `main`,
  which pins nothing — every install gets a different Honcho.
- Replace the plaintext dashboard password with a scrypt
  `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH`.
- Optional: `serpapi-mcp` as an *additional* MCP tool for true Google SERP data,
  alongside SearXNG rather than replacing it.
- **Proposed: a VM-side dashboard watchdog.** Nothing on the VM notices when the agent
  stops answering on 9119 (see 0.18.1) — the only watchdog we have runs on the operator's
  Mac and can only see, and only fix, the tunnel. A `hermes-dashboard-watchdog.timer` that
  probes `localhost:9119` and restarts `hermes-dashboard.service` after N consecutive
  failures would close that gap. **Deliberately not shipped here:** auto-restarting the
  agent on a 24/7 production install is a new failure mode of its own (it would kill live
  agent turns, and a probe that is wrong restarts a healthy agent in a loop). Wants its own
  PR, a virgin-install validation, and a decision on whether killing in-flight turns is
  acceptable.

## [0.18.1] — 2026-09-06

### Fixed — memory backups had never run under systemd

`memory-backup.service` exited **127 on every firing**: its `Environment=PATH` omitted
`/snap/bin`, and on the Ubuntu GCP image `gcloud` is a snap living **only** at
`/snap/bin/gcloud` (there is no `/usr/bin/gcloud` — verified 2026-09-06). `memory-backup.sh`
calls `gcloud storage rsync`, so every timer firing failed and the state backups silently
did not happen. `/snap/bin` appeared **nowhere** in the install package.

What kept it hidden: **running the script by hand works.** An interactive login shell has
`/snap/bin` on `PATH`; systemd's does not. Every manual verification of this script has
therefore always passed, while the scheduled path never once succeeded.

Fixed in `systemd/memory-backup.service` and applied to the live VM; the unit now exits
`0/SUCCESS` under systemd and the failed-unit list is empty. It is the only **packaged
script** affected — `memory-backup.sh` is the only one in the install that calls `gcloud`.

> Not fixed here, but worth knowing: `hermes-dashboard.service` omits `/snap/bin` too, and it
> hosts the agent runtime. Commands the agent shells out to inherit that `PATH`, so an agent
> turn doing GCP work would not find `gcloud` on `PATH` either. Left alone deliberately —
> widening the runtime's `PATH` is a behaviour change on a 24/7 install, not a bug fix, and
> nothing has reported it. Noted so the next person recognises the same shape.

> How long backups had been failing is **undetermined**: the diagnostic run that found this
> also rsynced the tree, overwriting the bucket timestamps that would have dated it. Known
> good: failing at the 20:01:35 UTC firing, succeeding under systemd afterwards.

### Documented — the gateway failure that is not the gateway's fault, and not credentials

Hit live **2026-09-06**, on Hermes **v0.21.0**, and initially read as the 0.16.2 credential
lapse because *every local signal is identical*. It is not. The tunnel, the credentials, the
service account, the firewall and the VM were all healthy throughout. **The agent itself had
stopped answering**, and no Mac-side action could have fixed it.

Ruled out with evidence, not assumption: the tunnel hangs identically under **user creds and
service-account creds**; a probe **from inside the VM** also returns `000`; there was no OOM
kill and 12.9–13.7 GB of 16 GB stayed free throughout (**it was not memory**); and
`hermes-autoupdate` last ran 13 hours earlier.

**The signature:** `curl localhost:9119` **on the VM** returns `000` while `ss -ltn` still
shows `LISTEN` — and the `Recv-Q` column on that LISTEN row climbs (19 → 44, live) because
those are completed TCP handshakes the application never `accept()`ed.

**Root cause — catastrophic regex backtracking (ReDoS) in the agent's approval guard.** The
launchd gateway-lifecycle pattern at `tools/approval_detection.py:337` is unanchored and
*both* of its branches are lookaheads starting with `[\s\S]*`, so `re.search` retries at all
N start positions and rescans to end each time: **O(N²)**. When the command contains no
`launchctl` — the normal case — nothing short-circuits and the full quadratic cost is paid on
**every ordinary command**. Python holds the GIL inside `re`, so one thread starves the whole
process, uvicorn's accept loop included. Captured with `py-spy`: one thread `active+gil` in
`detect_dangerous_command`, **47 threads parked in `futex_do_wait`**, 13m34s of CPU in a
single `search()`.

Measured against the exact pattern — the last row is the **largest input the guard allows**:

| command size | one pattern, one variant |
|---|---|
| 22 KB | 1.2 s |
| 44 KB | 4.9 s |
| 89 KB | 19.7 s |
| **127 KB** | **39.6 s** |

The existing size guard (`128_000` chars / `4_096` separator-free / `25_000` separators) does
not help: a `python3 - <<'EOF'` heredoc that writes an HTML page is ~10–127 KB with a few
thousand newlines and passes all three. That is exactly how it was triggered — twice,
reproducibly, by an agent turn generating a 90 KB HTML page.

> **Upstream defect, not an install fault.** The pattern is in upstream `6b2d4faf` at the
> same line; the install's single carried commit is unrelated. Do **not** hand-patch the VM —
> `hermes-autoupdate` overwrites it. Report upstream.

**Operational fallout this exposes:** the 0.16.2 tunnel supervisor does its job correctly and
still misleads, because **its HTTP probe cannot distinguish a broken tunnel from a wedged
agent** — both are `HTTP 000` at `localhost:9119`. It restarted a healthy tunnel every ~65s
for hours. And `OPS-NOTES.md` opened this symptom with *"Check credentials first"*, which is
right for one cause and a dead end for the other.

- **`OPS-NOTES.md`** gains *"The gateway wedges with the port still open (remote side)"* —
  the VM-side probe that separates the two causes, the `Recv-Q` tell, a table of which
  checks lie, the measured numbers, the `py-spy` recipe for capturing the specimen before a
  restart destroys it, and the avoidance rule (**write large files with a file-writing tool,
  not a giant heredoc**; the exposure window is ~4 KB–128 KB with a newline).
- The existing credential section now **starts** by splitting local from remote, instead of
  sending you to `gcloud auth login` for a fault that has nothing to do with credentials.
  The split is read in **three** branches, not two: the diagnostic `gcloud compute ssh`
  authenticates with your *user* credentials, so **whether the SSH succeeds at all** is the
  first signal — a genuine credential lapse makes that command fail outright rather than
  return a discriminating `302`. (And since 0.17.1 the tunnel authenticates as a service
  account, so your user credentials expiring does not imply the tunnel is down.)
- Recovery is `systemctl --user restart hermes-dashboard.service` — the **dashboard** unit
  owns 9119 (`hermes-gateway.service` is a different process; restarting it does nothing).
  The Mac needs no action: the supervisor reconnects itself in ~35s.

### Not yet validated

- ⚠️ **The `memory-backup.service` PATH fix has not been rebuilt from a virgin install.** It
  was verified on the live 24/7 VM (unit patched, `daemon-reload`, run under systemd, exit
  `0/SUCCESS`, failed-unit list empty) — which is exactly the "re-run over a live VM" the
  from-scratch rule in `AGENTS.md` says not to sign off on. The change is a one-token PATH
  append, but per that rule it wants a teardown → 01 → 02 → 03 pass before it counts as
  proven. The ReDoS half of this entry is a diagnosis and doc change; it installs nothing.

---



## [0.18.0] — 2026-09-04

### Fixed — the weekly update reported failure every week while succeeding every week

`hermes-autoupdate.service` sat in `failed` for five days. The updates themselves were
**working**: the 2026-08-30 run installed Hermes v0.20.6, restarted the gateway and the
dashboard, and passed 13 checks including shim chat, embeddings and Honcho end-to-end
recall. It then exited 1 on two checks — **both of which assert on the autoupdate's own
state, and are circular when the autoupdate is what is running them.** Both were
introduced by check 14 in 0.15.0.

**1. The latch.** `03-verify.sh` failed if `~/.hermes/autoupdate/last-failure` exists — and
the updater *writes that marker when verification fails*. So the first bad Sunday
(2026-08-23) guaranteed every later Sunday failed on the marker alone, wrote the marker
again, and never reached the `rm -f last-failure` that a success performs. Self-sustaining,
and invisible: the box kept updating.

Note a **timestamp comparison does not fix this** — once latched, `last-failure` is always
newer than `last-success`. The updater is about to record this run's outcome, so its
previous outcome is not evidence about the install. It is now skipped when the updater is
the caller, and still a hard FAIL for a human or `hermesctl`, which is who that warning is
for.

**2. The timer check could not pass.** The check failed when `hermes-autoupdate.timer` has
no next elapse — but while `hermes-autoupdate.service` is *executing*, its own timer
legitimately has none. Guaranteed to fail from inside the update, and says nothing about
the install.

`hermes-autoupdate.sh` now passes `HERMES_VERIFY_FROM_AUTOUPDATE=1`, and `03-verify.sh`
gained a `skip()` state so the count stays honest instead of quietly passing. Deliberately
an env marker rather than "is the service active" — a standalone run during a concurrent
update would wrongly skip a check that should pass.

### Added — `teardown.sh` refuses to destroy a RUNNING install

The typed confirmation was never a barrier to an automated caller: it reads stdin, so
`echo "${VM_NAME}" | teardown.sh` sails through it. That is how destructive code gets
"tested" against a live project.

**What it cost, on 2026-09-04:** the VM's service account was deleted at 12:31:11 UTC and
recreated 21 seconds later while teardown changes were being validated. The recreated
account has the **same email but a new unique id**, and a GCE instance is bound to the
*id* — so the metadata server returned `401 "Service account is deleted or disabled."`
indefinitely, `agent.vertex_adapter` could not resolve credentials, and **every turn failed
with "agent init failed"** while the desktop app blamed Vertex. The VM never stopped; the
identity that made it useful was gone.

`teardown.sh` now refuses when the target instance is `RUNNING` and requires
`--yes-destroy-live`, naming the safe alternatives (a throwaway `PROJECT_ID`/`VM_NAME`, or
stopping the VM first). Verified both directions: the exact `echo hermes-agent |
teardown.sh` invocation is refused with exit 1 (also with `--vm-only`), and an absent or
non-running target reaches the confirmation prompt exactly as before.

**Recovery, for the record:** `gcloud iam service-accounts undelete <ORIGINAL_UNIQUE_ID>`
restores the identity the instance is still bound to, so the metadata server works again
**with no stop/start** — the email must be freed first by deleting the replacement.
`gcloud compute instances set-service-account` is the alternative and needs a stopped VM.

### Verified — re-probed live, 2026-09-04

| Check | Result |
|---|---|
| `03-verify.sh` standalone | **14 passed, 0 failed** |
| `03-verify.sh` as the updater runs it, against the real latched marker | **14 passed, 0 failed, 1 skipped** (was: 1 failed, forever) |
| Vertex `:generateContent` @ `global` | `gemini-3.8-flash`, `3.7-flash`, `3.5-flash` — all **HTTP 200** |
| Hermes on the box | **v0.21.0** (`2026.8.31`) — badge and CLAUDE.md said v0.20.4/v0.20.5 |
| Gateway through the tunnel | **HTTP 302** |

The 2026-08-18 from-scratch rebuild block in `gcp/vpc-install/README.md` is a dated
historical record and was left as written; only the re-probe lines were updated. Same
discipline the 0.16.1 entry had to correct after a blanket find/replace rewrote history.
## [0.17.3] — 2026-09-04

### Added — README: what to do when you can't connect

0.17.1 split the two credentials — the tunnel moved to the `hermes-tunnel` service account
while `hermesctl` kept running as the operator — and 0.17.2 explained the split in
`OPS-NOTES.md` §7a. But the README, which is the front door and the only page most people
read, still implied a single answer. The practical consequence: `gcloud auth login` is now
the fix for **one** of the two and does **nothing** for the other, and there was no
front-page guidance on telling them apart.

New **"When you can't connect"** section under *Everyday commands*, built around the one
check that distinguishes the cases — `curl localhost:9119`, because a bound-but-not-
forwarding tunnel looks alive to every process- and port-based check:

- **302** — tunnel healthy; if the app still fails it is the app or the password, and
  `gcloud auth login` will not help.
- **000** — tunnel not forwarding; wait, then `launchctl kickstart`, then read the log.
- **`Reauthentication failed` from `hermesctl` while the app works** — that is the split,
  not a broken tunnel.

### Corrected

- Documented that a **cold tunnel start has taken over two minutes** to first answer.
  Observed repeatedly on 2026-09-04 while verifying 0.17.1. This matters because the
  obvious reaction to a slow start is to conclude the tunnel is dead and start
  re-installing — the README now says to wait first. The supervisor's 45s threshold applies
  to a *running* tunnel that stops forwarding, not to first connect.
## [0.17.2] — 2026-09-04

### Fixed — teardown left the tunnel service account behind

0.17.1 added the `hermes-tunnel` service account and a local key, but **`teardown.sh` was
never taught about either**. A teardown-then-rebuild — this repo's own mandated validation
path — therefore left:

- an **orphan service account still holding `roles/iap.tunnelResourceAccessor`** on the
  project, invisible in `gcloud compute instances list`, so the "confirm it really is virgin"
  check passed while it was still there; and
- a **stale key file** on the Mac, which the installer's "Reusing existing tunnel key" branch
  would have handed straight to launchd — a key whose service account no longer exists.

Teardown now deletes the tunnel SA alongside the VM's, removes `${TUNNEL_SA_KEY}` locally,
and lists both in the typed-confirmation preview so nothing is destroyed unannounced. Found
by review immediately after 0.17.1 shipped, not by a rebuild — the virgin-install rule exists
because this is exactly the class of defect that hides from incremental re-runs.

### Fixed — `gcloud auth login` guidance contradicted itself

0.17.1's new §7a says `gcloud auth login` is *not* the fix for a dead tunnel; 0.16.2's entry
says an expired credential breaks *all* of `hermesctl` and to run exactly that. Both are
true — the tunnel moved to a service account, **`hermesctl` did not** — but side by side they
read as a contradiction. §7a now states the split explicitly: the desktop app and the CLI
now fail **independently**, and `Reauthentication failed` from `hermesctl` while
`curl localhost:9119` returns 302 is that split, not a broken tunnel.

### Corrected

- `teardown.sh` still told the operator the rebuild "must be 13/13". The suite grew to
  **14** checks in 0.15.0. Same stale-count class as the 0.16.1 README defect.

### Verified

- `constraints/iam.serviceAccountKeyExpiryHours` on `test-disco-cm` is **`allowAll`** — no
  key-expiry limit is enforced, so 0.17.1's "survives a week of idle" has no hidden shelf
  life from org policy. Probed 2026-09-04 via the Org Policy API.

## [0.17.1] — 2026-09-04

### Fixed — the gateway tunnel now authenticates as a service account, so idle no longer kills it

Two faults, hit together on 2026-09-04. The desktop app showed the same *"Could not reach
this gateway yet"* that 0.16.2 is about, from two causes that 0.16.2 did not fix.

#### 1. The installer wrote a LaunchAgent pointing into a git worktree

0.16.2's supervisor, its plist and **two commit messages** were all written for a stable
`~/.local/bin` install. The **one line in `install-gateway-launchagent.sh` that chooses the
path was never changed** — it still passed `${HERE}`, the checkout it was run from. So the
installed plist referenced
`.claude/worktrees/hermes-flash-upgrade-test-44506f/…/gateway-tunnel-supervisor.sh`; that
worktree was reset to `main`, the script vanished, and launchd could no longer exec it:

| Check | Says | Reality |
|---|---|---|
| `launchctl list \| grep hermes` | listed | agent is loaded |
| last exit status | **-15** | never actually ran |
| `lsof -iTCP:9119` | **nothing** | no listener at all |
| `~/Library/Logs/…tunnel.log` | stops at 14:07 | died when the file disappeared |

- The installer now `install -m 0755`s the supervisor to
  `~/.local/bin/hermes-gateway-tunnel-supervisor.sh` and points the plist there.
- It also **refuses to write a plist that contains its own checkout path** (`grep -qF
  "${HERE}"`), the same shape as the existing unsubstituted-`__TOKEN__` guard, so this
  cannot regress silently.
- **Verified the way it actually failed**, not from the source tree: copied the package to a
  foreign directory, installed from *there*, **deleted that directory**, restarted the agent
  — gateway still served **HTTP 302**. The original failure is now unreachable.
- The 0.16.2 entry claimed this was "caught before it could bite". That claim has been
  corrected in place. **A commit message is not verification**, and — for the second time
  after the 0.16.1 `hermesctl` PATH defect — **exercising a script from its own checkout
  does not test how it is installed.**

#### 2. THE REAL ONE: a LaunchAgent can never satisfy a reauth prompt

Underneath the missing script, the log showed the tunnel had been refusing to start for
hours, once every 30 seconds:

```
Reauthentication failed. cannot prompt during non-interactive execution.
```

That is Google Cloud's periodic **reauthentication** requirement on *user* credentials.
`01-gcp-setup.sh` grants `roles/iap.tunnelResourceAccessor` to the **human operator**, and
the tunnel then runs unattended as that human. **No supervisor, timeout, retry or
`KeepAlive` can fix this** — reauth is interactive by definition, and a daemon has no one to
prompt. 0.16.2's supervisor diagnosed it correctly and could do nothing about it. The
requirement — *"it needs to work after a week of idle"* — was **structurally unmeetable**.

**Fix: the tunnel gets its own service account.** Service-account credentials are exempt
from reauth.

- **`TUNNEL_SA_NAME` / `TUNNEL_SA_EMAIL` / `TUNNEL_SA_KEY` / `TUNNEL_USE_SA` in
  `00-vars.sh`.** `01-gcp-setup.sh` creates `hermes-tunnel` and grants it
  **`roles/iap.tunnelResourceAccessor` and nothing else** — no `osLogin`, no Vertex, no
  storage. It is deliberately **not** the VM's `hermes-agent` SA, whose roles would be
  wildly over-granted for a laptop.
- **The key is minted on the Mac** by `install-gateway-launchagent.sh` under `umask 077`
  (never briefly world-readable), `chmod 600`, and the plist passes it as
  `CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE`. It is `.gitignore`d (`*-sa.json`) and never
  committed. This is the **one key file in an install that otherwise deliberately has none**
  — the reasoning is written out in `00-vars.sh` next to the variables.
- **The installer verifies the credential before handing it to launchd**, so a bad key fails
  loudly at install time instead of becoming a dead gateway hours later.
- **The supervisor no longer prints the wrong advice.** Under a service account there is
  nothing for a human to log into, so a credential failure now names the real causes (key
  missing, revoked, or lost its IAM binding) instead of suggesting `gcloud auth login`.
- `TUNNEL_USE_SA="false"` restores the old operator-credential behaviour, and the installer
  says plainly that the tunnel will then stop at every reauth window.

**Verified that it no longer depends on the human login at all** — the only test that
actually proves the week-idle claim. With `CLOUDSDK_CONFIG` pointed at an **empty**
directory, so `gcloud auth list` reports no credentialed accounts whatsoever:

| Test | Result |
|---|---|
| `gcloud auth print-access-token` with only the SA key | **token minted** |
| full `start-iap-tunnel` → `curl localhost:9219` | **HTTP 302** |
| live agent's plist env | `CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE` set |
| live gateway on :9119 | **HTTP 302** |

#### Corrected while verifying

- A freshly created SA key is **eventually consistent**. The first version of the installer's
  own verification failed immediately after `keys create` and told the operator to delete a
  perfectly good key; by hand, seconds later, it minted a token fine. It now polls for up to
  30s — the same trap `01-gcp-setup.sh` already documents for SA *creation*.
- With `TUNNEL_USE_SA=false` the plist would have carried an **empty**
  `CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE`, which is worse than an absent one (gcloud would
  try to load `""`). The installer now removes the key outright in that case.

## [0.17.0] — 2026-09-04

### Changed

- **Default chat model is now `gemini-3.8-flash`** (was `gemini-3.7-flash`). The catalog
  is `{google/gemini-3.8-flash (default), google/gemini-3.5-flash}`; `gemini-3.5-flash`
  remains the switchable, **strict-EU-capable** fallback. Only `HERMES_MODEL` /
  `HERMES_MODELS` in `00-vars.sh` change — `config.yaml` is templated from them, and
  `03-verify.sh` derives the probe target from `$HERMES_MODEL`, so nothing else moved.

- **`VERTEX_REGION` stays `global`, and the EU-residency exception is unchanged.**
  `gemini-3.8-flash` has exactly the same availability shape as 3.7 and 3.6: 404 at
  every European regional endpoint, 200 only at `global`. This upgrade neither widens
  nor narrows the residency posture. Re-probed 2026-09-04 (`:generateContent` POST):

  | Model | eu-w1 | eu-w2 | eu-w3 | eu-w4 | eu-n1 | global |
  |---|---|---|---|---|---|---|
  | `gemini-3.8-flash` | 404 | 404 | 404 | 404 | 404 | **200** |
  | `gemini-3.7-flash` | 404 | 404 | 404 | 404 | 404 | **200** |
  | `gemini-3.6-flash` | 404 | 404 | 404 | 404 | 404 | **200** |
  | `gemini-3.5-flash` | 404 | **200** | **200** | 404 | 404 | **200** |
  | `gemini-3.5-flash-lite` | 404 | 404 | 404 | 404 | 404 | **200** |
  | `gemini-2.5-flash` | **200** | **200** | **200** | **200** | **200** | **200** |

  Every row other than 3.8 is byte-identical to the 2026-08-18 probe — the run reproduced
  the known-good result, which is what makes the new row trustworthy.

- **Cost estimate revised down while introductory pricing lasts.** `gemini-3.8-flash` is
  **$0.75 / $3.75** per 1M input / output tokens at `global` through **2026-12-31**, then
  **$1.50 / $7.50** from **2027-01-01** — the latter being exactly what 3.7-flash costs
  today. The token line moves ~$75–180 → **~$40–90**, taking the line-item sum from
  $234–367 to **$199–277** (tabled as ~$200–275, matching how the previous estimate
  rounded). On 2027-01-01 the model line doubles back with no action required.
  Non-`global` endpoints carry a ~10% premium. Source: the
  [Vertex AI pricing page](https://cloud.google.com/vertex-ai/generative-ai/pricing),
  read 2026-09-04.

### Verified

- **The model id is real, proved the strong way.** The `global` 200 echoed
  `"modelVersion": "gemini-3.8-flash"`, matching the requested id — a 200 alone would not
  have settled it. Negative control run alongside: `gemini-3.9-flash`,
  `gemini-3.8-flash-lite` and `gemini-3.8-pro` **all 404 at `global`**, so 3.8 currently
  ships as a flash tier only, with no `-lite` or `-pro` sibling on Vertex.

### Fixed

- **The repo-map row in `README.md` still read "Currently **0.14.3**"** while the version
  badge four lines up read 0.16.1 — stale since 0.14.4. Now tracks the badge.

- **`INSTALL.md` §2 and `gcp/vpc-install/README.md` both stated Honcho runs on
  `gemini-3.5-flash`.** It does not, and must not — `00-vars.sh` sets
  `HONCHO_MODEL=google/gemini-2.5-flash`, and §7 of the same document explains at length
  why any Gemini 3.x model 400s every dialectic query (dropped `thought_signature`). The
  summary tables contradicted the source of truth they were summarising. Both corrected.

### Not yet validated

- ⚠️ **This has not been rebuilt from a virgin install.** The 3.8 evidence is an API fact,
  not an install fact: as of 2026-09-04 the live box still runs 3.7-flash, and neither
  `03-verify.sh` nor the live tool-calling turn has been re-run on 3.8. A
  `:generateContent` 200 proves the model answers — it does **not** exercise the
  thought-signature round-trip that tool-calling depends on, which is the failure mode
  that already bit `HONCHO_MODEL`. Per the from-scratch rule in `AGENTS.md`, run
  `teardown.sh` → full install → `03-verify.sh` → the OPS-NOTES tool-call check before
  treating 3.8 as validated. `HONCHO_MODEL` is untouched and stays on `gemini-2.5-flash`.
## [0.16.2] — 2026-09-01

### Fixed — the gateway failure that reports itself as healthy

Hit live on 2026-08-19, and **initially misattributed to an unrelated upgrade**. The desktop
app showed *"Could not reach the remote Hermes gateway while refreshing its WebSocket
ticket"* and **gateway offline**; Settings → Connection mode said *"Could not reach this
gateway yet. Check the URL — the auth method will appear once it responds."*

Cause: **expired gcloud credentials.** The tunnel process stays alive and keeps port 9119
bound; it simply cannot forward, because `gcloud` can no longer mint a token. That makes it
pathologically misleading:

| Check | Says | Reality |
|---|---|---|
| `launchctl list \| grep hermes` | status **0** | process is running |
| `lsof -iTCP:9119 -sTCP:LISTEN` | **bound** | accepts local connections |
| `curl localhost:9119` | **HTTP 000** | ← the only honest check |

The app connects at TCP level, then fails refreshing its WebSocket ticket — exactly what the
message says. **Every process- or port-based liveness check reports HEALTHY.** Same lesson as
`03-verify.sh` test 13: *liveness is not correctness.*

#### The real defect: the tunnel could never recover, even after you re-authenticated

`gcloud compute start-iap-tunnel` **binds the local port first**, and when its token later
fails to refresh it **does not exit** — it retries internally, forever, holding the listener
open. Caught in the act 2026-09-02: one process alive **1d 9h**, emitting **~1.5 auth errors
per second**, having written a **27 MB / 413,000-line** log.

`KeepAlive` only restarts a process that **dies**, so it never fired. And because the stuck
process never re-reads credentials, **`gcloud auth login` did not fix it** — only a manual
`launchctl kickstart` did. That is why the failure kept coming back and why it was
repeatedly misattributed to whatever had changed most recently.

- **`scripts/gateway-tunnel-supervisor.sh` (new)** — the LaunchAgent now runs this instead
  of `gcloud` directly. It probes the tunnel **over HTTP** (the only check that separates
  *forwarding* from *listening*) and kills and restarts the child after 45s of no
  forwarding. When credentials have genuinely expired it stops the child, waits, and posts a
  macOS notification naming the one command a human must run — then reconnects on its own
  once you do. **Verified** by `SIGSTOP`ing the child to reproduce the exact zombie shape
  (port bound, HTTP 000): detected and recovered in **~35s** with a new child.
- **Logs moved out of `/tmp` to `~/Library/Logs/` and are rotated** (2 MB cap). The previous
  setup pointed gcloud's raw stderr at a file nothing rotated, which is how it reached 27 MB.
- **THE ACTUAL DEFECT: the tunnel could never recover, and `KeepAlive` could not help.**
  `gcloud compute start-iap-tunnel` **binds the local port first**, and when its token later
  fails to refresh it **does not exit** — it retries internally, forever, holding the
  listener open. Measured 2026-09-02: one such process had been alive **1d 9h** logging ~1.5
  `Reauthentication failed` errors per **second**, having written a **27 MB / 413k-line**
  log. launchd's `KeepAlive` only restarts a process that *dies*, so it never fired — and
  since the stuck process never re-read credentials, **`gcloud auth login` did not fix it
  either.** Only a manual `launchctl kickstart` did. That is why this failure kept recurring
  and kept looking like something else had broken.

  **Fix: `scripts/gateway-tunnel-supervisor.sh`**, which the LaunchAgent now runs instead of
  `gcloud` directly. It probes the tunnel **over HTTP** — the only check that distinguishes
  forwarding from listening — and kills and restarts the child after 45s of not forwarding.
  A credential lapse now self-heals the moment you re-authenticate, and while it is waiting
  it sends a macOS notification naming the one command a human must run. It also rotates its
  own log, and logs moved from `/tmp` to `~/Library/Logs/`.

  Verified by `SIGSTOP`-ing the child to reproduce the exact zombie shape (port bound,
  HTTP 000): detected and recovered in **~35s** with a new child.
- **The supervisor is installed to `~/.local/bin/`, not referenced in the checkout.** The
  first version pointed launchd at the script inside the repo working tree — and this repo's
  own workflow uses **temporary per-agent git worktrees**, so cleaning one up deletes the
  running supervisor and kills the gateway, failing in a way that looks exactly like the
  credential fault it exists to fix. The installer now `install -m 0755`s it to
  `~/.local/bin/hermes-gateway-tunnel-supervisor.sh` and passes `VM_NAME` / `ZONE` /
  `PROJECT_ID` / `DASHBOARD_PORT` through the plist's `EnvironmentVariables`, because the
  installed copy has no `00-vars.sh` beside it to source.

  **It bit before this was true.** An earlier revision of this entry claimed the move was
  "caught before it could bite, on 2026-09-02". It was not: the supervisor, the plist and
  two commit messages were all written for `~/.local/bin`, but the **one line in
  `install-gateway-launchagent.sh` that chooses the path was never changed** — it still
  passed `${HERE}`. So the installed plist pointed at
  `.claude/worktrees/hermes-flash-upgrade-test-44506f/…`, that worktree was reset to `main`
  on **2026-09-04**, the script vanished, and launchd could no longer exec it: agent loaded,
  `exit -15`, nothing listening on 9119, no log. The desktop app reported the same
  *"Could not reach this gateway yet"* this entry is about — from a completely different
  cause.

  Two lessons, both already in this repo's rules and both ignored here: **a commit message
  is not verification** (three artifacts described the fix; the code did one thing), and
  **exercising a script from its own checkout does not test how it is installed** — the same
  shape as the 0.16.1 `hermesctl` PATH defect. The installer now also **refuses to write a
  plist that references its own checkout**, so this cannot regress silently.
- **`hermesctl` now fails fast with the real fix.** Every VM-side command goes over the IAP
  tunnel, so an expired credential breaks *all* of it — and breaks it confusingly, because
  `gcloud compute ssh` returns **255**, which `vm()`'s retry loop treats as transient and
  retries 3× before giving up on something no retry can fix. A `require_creds` preflight now
  runs once per invocation and prints the two-command fix.
- **`gateway-tunnel.sh --status` diagnoses instead of reporting up/down.** It separates
  "nothing listening" (tunnel not running) from "listening but HTTP 000" (running, not
  forwarding), greps the log for `TokenRefreshError`, and names the fix. Verified against the
  real broken state — it identified the cause correctly.
- **`install-gateway-launchagent.sh`** names the cause (credentials vs. port conflict)
  instead of dumping 20 log lines.
- Documented in `OPS-NOTES.md` and `INSTALL.md`, including that this **recurs by design**:
  Workspace reauth policies expire the credential on a schedule, so a permanently-installed
  LaunchAgent will meet it periodically. Not a fault in the install, and not upgrade-related.

The fix, for the record:

```bash
gcloud auth login                                              # interactive, needs a browser
launchctl kickstart -k gui/$(id -u)/com.hermes.gateway-tunnel   # pick up the new token
```

Confirmed on the live install: recovered to HTTP 302 in ~6s.

---

- **Log moved out of `/tmp`** to `~/Library/Logs/hermes-gateway-tunnel.log`, and the
  supervisor **rotates it** (2 MB cap). The old setup pointed gcloud's raw stderr at a
  `/tmp` file that nothing rotated, which is how it reached **27 MB / 413k lines** of the
  same repeated auth error. All five references across `INSTALL.md`, `OPS-NOTES.md` and the
  plist's own instructions were updated to the new path — a stale `tail -f` in a runbook is
  worse than none, since it shows an empty file and looks like "no errors".

---

- **The supervisor and the plist had drifted out of step, and the pair as committed could
  not start.** `762a5ad` moved the installed supervisor to `~/.local/bin` (correctly — a
  LaunchAgent must not reference a git worktree), but two halves were left behind: the
  supervisor still did `source "${HERE}/../00-vars.sh"` unconditionally, and the plist
  template passed none of that config. In `~/.local/bin` there is no `00-vars.sh`, so
  `VM_NAME` was unset and the script died instantly under `set -u` — **the gateway would
  never come up from a clean install**.

  This is the same shape as the fresh-install defects in 0.13.0: it works in a checkout,
  because a checkout *does* have `00-vars.sh` beside the script, and only fails once
  installed somewhere else. Fixed by making config arrive from the environment (the plist
  now passes `VM_NAME`, `ZONE`, `PROJECT_ID`, `DASHBOARD_PORT`), with `00-vars.sh` used
  only as a fallback when the script is run straight out of a repo. A missing config now
  produces `ERROR: VM_NAME/ZONE/PROJECT_ID not set and no 00-vars.sh beside this script`
  instead of a bare `unbound variable`.

  Verified three ways: the isolated script with no config errors clearly; with config in
  the environment it starts and launches its child; and a full
  `install-gateway-launchagent.sh` run renders every placeholder, passes `plutil -lint`,
  and reports the gateway UP on HTTP 302.

---

## [0.16.1] — 2026-08-22

### Fixed

- **`hermesctl` failed for every invocation via the PATH** — i.e. the only way anyone
  actually runs it. `install-hermesctl.sh` symlinks it into `~/.local/bin`, and the script
  located `00-vars.sh` with `dirname "${BASH_SOURCE[0]}"`, which resolves to the
  *symlink's* directory. So it looked for `~/.local/bin/../00-vars.sh` and exited with
  "cannot find 00-vars.sh". It only worked when run by its full path inside the repo,
  which is how it was tested. Now walks the symlink chain by hand — not `readlink -f`,
  which is GNU-only on older macOS.

  *Testing lesson: exercising a script from its source directory does not test the way
  users invoke it.*

---

## [0.16.0] — 2026-08-22

Adds **`hermesctl`** — one command for every routine operation, so day-to-day running of
the agent no longer means remembering `gcloud compute ssh --tunnel-through-iap` strings.

### Added

- **`scripts/hermesctl`** (run on your PC) and **`scripts/install-hermesctl.sh`** to put
  it on your PATH. It reads `00-vars.sh`, so a cloned install works with no edits.
  - **health** — `status` (the 14-point check), `doctor`,
    `logs gateway|dashboard|shim|autoupdate|honcho|searxng`
  - **updates** — `update` (server now), `update-desktop` (this Mac), `update-all`,
    `update-check`, `autoupdate [show|off|on]`
  - **services** — `gateway status|start|stop|restart|kick`, `dashboard restart`,
    `restart-all`
  - **access** — `tunnel`, `open`, `ssh`
  - **machine** — `vm status|start|stop`, `disk`
- **README "Everyday commands"** section covering the whole surface, and the split
  between updating the server (automatic, weekly) and the desktop app (manual, because it
  has no auto-update feed).

### Design notes

- **`hermesctl update` runs the autoupdate *unit*, not `hermes update` directly.** That
  way a manual update gets the same cgroup isolation, dashboard restart and post-update
  verification as the Sunday run — rather than being a second, subtly different code path
  that could reintroduce the "updater killed by the restart it triggered" bug (0.15.0).
- **`gateway kick` exists because `restart` cannot fix a wedged gateway.** systemd only
  restarts a process that *exits*; a gateway hung on a stalled tool call stays `active`
  forever. `kick` stops it, clears stale `gateway.lock`/`gateway.pid`, and starts clean.
- **`vm stop` confirms before acting** and says what it costs: stopping halts the agent,
  cron and the weekly update, while the disk and Cloud NAT keep billing.
- **Transient `exit 255` from `gcloud compute ssh` is retried** up to 3 times. Every
  wrapped command is idempotent, so a retry is always safe.
- **`restart-all` restarts the Vertex shim first**, because Honcho's first memory call
  fails if the shim is not up.

### Fixed

- **`update-check` reported the hint instead of the answer.** `hermes update --check`
  prints its verdict and then `Run 'hermes update' to install.`; taking the last line
  showed that instruction even when the install was already current. Now picks the line
  that actually says `N commits behind` or `up to date`.

### Verified

Every command exercised against the live VM: `vm status` → `RUNNING`; `autoupdate` →
timer armed for `Sun 2026-08-23 04:09:15 UTC`, `last ok 2026-08-22T09:43:02Z`, no
failures; `gateway status` → active, 13 min uptime; `open` → tunnel up; `update-check` →
`9 commits behind origin/main` on both server and Mac.

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
