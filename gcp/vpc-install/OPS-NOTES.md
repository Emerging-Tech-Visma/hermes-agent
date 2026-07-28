# Hermes on GCP — SSH operations notes

Day-2 operations. Everything here runs **over SSH on the VM** unless a heading says
"on your PC".

**Get in** (the VM has no public IP, so the IAP flag is required every time):

```bash
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap
```

**Run one command without an interactive session** — use this whenever you are unsure
which machine your prompt is on:

```bash
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap \
  --command='systemctl --user status hermes-gateway.service'
```

Put this in your shell profile to save typing:

```bash
alias hermes-ssh='gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap'
alias hermes-gw='gcloud compute start-iap-tunnel hermes-agent 9119 --local-host-port=localhost:9119 --zone=europe-west2-b --project=test-disco-cm'
```

---

## Contents

1. [Triage — start here](#1-triage--start-here)
2. [Idle, stuck, or wedged gateways](#2-idle-stuck-or-wedged-gateways)
3. [Updating the Hermes backend](#3-updating-the-hermes-backend)
4. [Updating the other services](#4-updating-the-other-services)
5. [Setup the desktop app cannot do](#5-setup-the-desktop-app-cannot-do)
6. [Backup and restore](#6-backup-and-restore)
7. [Gateway/tunnel problems (on your PC)](#7-gatewaytunnel-problems-on-your-pc)
8. [Symptom → cause table](#8-symptom--cause-table)

---

## 1. Triage — start here

One block that tells you almost everything:

```bash
export PATH="$HOME/.local/bin:$PATH"

echo "── hermes ─────────────────"; hermes version; hermes doctor 2>&1 | tail -20
echo "── services ───────────────"; systemctl --user list-units 'hermes*' 'memory-backup*' --no-pager
echo "── containers ─────────────"; sudo docker ps --format '{{.Names}}\t{{.Status}}'
echo "── listeners ──────────────"; sudo ss -ltnp | grep -E ':(9119|8080|8000)\b'
echo "── linger ─────────────────"; loginctl show-user "$USER" -p Linger
echo "── disk / mem ─────────────"; df -h / | tail -1; free -h | head -2
```

Or just run the full check:

```bash
bash ~/hermes-install/03-verify.sh
```

**Expected listeners:** `9119` on `0.0.0.0` (dashboard — correct, see below),
`8080` and `8000` on `127.0.0.1` only (SearXNG, Honcho).

> `9119` on `0.0.0.0` is **not** a misconfiguration. Hermes only engages its
> basic-auth provider on a non-loopback bind; on `127.0.0.1` the dashboard runs with
> auth **OFF**. It is safe because the VM has no external IP and the firewall admits
> only Google's IAP range. If you ever see `8080` or `8000` on `0.0.0.0`, that **is**
> a problem — SearXNG and Honcho have no authentication.

---

## 2. Idle, stuck, or wedged gateways

The gateway runs cron jobs and messaging connections. It has three distinct failure
modes and they need different fixes.

### 2a. Normal idle — not a fault

`HERMES_AGENT_TIMEOUT` (default `1800` seconds) is how long the gateway keeps an
**inactive agent run** alive before tearing it down. A gateway sitting idle with no
active run is working correctly. Check the actual value:

```bash
grep HERMES_AGENT_TIMEOUT ~/.hermes/.env
```

Raise it if long-running tasks get cut off mid-flight:

```bash
sed -i 's/^HERMES_AGENT_TIMEOUT=.*/HERMES_AGENT_TIMEOUT=3600/' ~/.hermes/.env
systemctl --user restart hermes-gateway.service
```

Related: if very large contexts die mid-stream, raise the read timeout instead —
that is a different setting.

```bash
sed -i 's/^HERMES_STREAM_READ_TIMEOUT=.*/HERMES_STREAM_READ_TIMEOUT=1800/' ~/.hermes/.env
systemctl --user restart hermes-gateway.service
```

### 2a-bis. `inactive (dead)` right after a config change — exit 78

The unit that actually runs is the one **the Hermes installer generates**, and it sets
`RestartPreventExitStatus=78`. Hermes exits `78` on a **configuration error**, and that
exit code deliberately does *not* restart-loop — so a gateway that goes
`inactive (dead)` immediately after you edited `config.yaml` or `.env` is almost always
this, not a crash.

```bash
systemctl --user show hermes-gateway.service -p ExecMainStatus -p Result
journalctl --user -u hermes-gateway -n 40 --no-pager    # the actual config error
```

Fix the config, then start it. Restarting without fixing will just exit 78 again.
`RestartForceExitStatus=75` is the inverse: exit 75 always restarts.

```bash
hermes doctor            # usually names the bad key
systemctl --user start hermes-gateway.service
```

> Do **not** replace this unit with a hand-written one. It encodes `KillMode=mixed`,
> a SIGUSR1 `ExecReload`, an `ExecStopPost` cgroup cleanup and the venv
> `PATH`/`VIRTUAL_ENV`. Regenerate it with `hermes gateway install` if it is lost.

### 2b. Wedged — process alive, doing nothing

This is the annoying one. `Restart=always` does **not** help, because systemd only
restarts a process that *exits*; a gateway hung on a stalled tool call or a dropped
upstream connection stays "active" forever.

Diagnose:

```bash
hermes gateway status                                   # Hermes' own health view
systemctl --user status hermes-gateway.service           # systemd's view
journalctl --user -u hermes-gateway -n 100 --no-pager    # recent logs
tail -50 ~/.hermes/logs/gateway.log                      # Hermes' own log
```

Signs of a wedge: `systemctl` says `active (running)`, but `journalctl` has no new
lines for a long time and `hermes gateway status` reports unhealthy or times out.

Escalating fixes — try in order:

```bash
# 1. Graceful restart (almost always enough)
systemctl --user restart hermes-gateway.service

# 2. Hermes-level restart
hermes gateway restart

# 3. Stale lock/pid files left behind by an unclean kill.
#    Symptom: the gateway refuses to start, claiming it is already running.
systemctl --user stop hermes-gateway.service
ls -la ~/.hermes/gateway.lock ~/.hermes/gateway.pid 2>/dev/null
rm -f ~/.hermes/gateway.lock ~/.hermes/gateway.pid
systemctl --user start hermes-gateway.service

# 4. Nothing is holding the port / no orphan processes?
sudo ss -ltnp | grep -E ':(9119|8765)\b'
pgrep -af 'hermes' | grep -v grep

# 5. Last resort — kill orphans, then start clean
systemctl --user stop hermes-gateway.service
pkill -u "$USER" -f 'hermes gateway' || true
sleep 2
rm -f ~/.hermes/gateway.lock ~/.hermes/gateway.pid
systemctl --user start hermes-gateway.service
```

### 2c. Automatic watchdog for wedges

Since `Restart=always` cannot detect a wedge, add a timer that probes
`hermes gateway status` and restarts on failure. Run this **once** on the VM:

```bash
cat > ~/.local/bin/gateway-watchdog.sh <<'EOF'
#!/usr/bin/env bash
# Restart the Hermes gateway if it is alive but unhealthy.
# Covers the "wedged, not exited" case that Restart=always cannot see.
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"

systemctl --user is-active hermes-gateway.service >/dev/null 2>&1 || exit 0

if timeout 60 hermes gateway status >/dev/null 2>&1; then
  exit 0
fi

logger -t hermes-watchdog "gateway status check failed — restarting"
systemctl --user restart hermes-gateway.service
EOF
chmod +x ~/.local/bin/gateway-watchdog.sh

cat > ~/.config/systemd/user/gateway-watchdog.service <<EOF
[Unit]
Description=Restart Hermes gateway if unhealthy

[Service]
Type=oneshot
Environment=HOME=${HOME}
Environment=PATH=${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${HOME}/.local/bin/gateway-watchdog.sh
EOF

cat > ~/.config/systemd/user/gateway-watchdog.timer <<'EOF'
[Unit]
Description=Check Hermes gateway health every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now gateway-watchdog.timer
systemctl --user list-timers gateway-watchdog.timer --no-pager
```

Watch it work: `journalctl -t hermes-watchdog -n 20 --no-pager`

### 2d. Everything died after you logged out

That is `linger`, not the gateway:

```bash
loginctl show-user "$USER" -p Linger      # want Linger=yes
sudo loginctl enable-linger "$USER"
```

Without linger, systemd kills **all** your user services when your last SSH session
closes. This is the classic "worked yesterday, dead this morning" cause.

---

## 3. Updating the Hermes backend

### The normal path

```bash
export PATH="$HOME/.local/bin:$PATH"

# 1. Snapshot config before touching anything.
cp ~/.hermes/config.yaml ~/.hermes/config.yaml.bak-$(date +%F)
cp ~/.hermes/.env        ~/.hermes/.env.bak-$(date +%F)

# 2. Stop the services so nothing writes state mid-upgrade.
systemctl --user stop hermes-gateway.service hermes-dashboard.service

# 3. Upgrade in place.
hermes version          # note the current version
hermes update
hermes version          # confirm it moved

# 4. Bring it back and verify.
systemctl --user start hermes-dashboard.service hermes-gateway.service
hermes doctor
bash ~/hermes-install/03-verify.sh
```

### If `hermes update` fails

This install was created by the official installer, so re-running it upgrades in
place. It will not delete `~/.hermes/config.yaml`, `.env`, `memories/`, `sessions/`
or `skills/` — but take the backups in step 1 anyway.

```bash
systemctl --user stop hermes-gateway.service hermes-dashboard.service
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-browser
systemctl --user start hermes-dashboard.service hermes-gateway.service
hermes version && hermes doctor
```

### After any upgrade — check these three things

An upgrade can quietly reset or invalidate config:

```bash
# 1. Is the Vertex model catalog still declared? Without it the /model picker
#    collapses to a single entry.
grep -A5 'models:' ~/.hermes/config.yaml

# 2. Are the managed .env keys still present?
grep -E 'SEARXNG_URL|HONCHO_BASE_URL|HERMES_DASHBOARD_BASIC_AUTH_USERNAME' ~/.hermes/.env

# 3. Did the systemd unit get replaced with a loopback bind? (auth would be OFF)
grep -- '--host' ~/.config/systemd/user/hermes-dashboard.service   # want 0.0.0.0
```

To re-apply the whole managed configuration from the repo, just re-run the installer
script — it is idempotent and rewrites config, units and helper scripts:

```bash
export HERMES_DASHBOARD_PASSWORD='your-existing-or-new-password'
bash ~/hermes-install/02-vm-install.sh
```

To refresh the repo files on the VM first, from **your PC**:

```bash
gcloud compute scp --zone=europe-west2-b --tunnel-through-iap --recurse \
  gcp/vpc-install hermes-agent:~/hermes-install-new
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap \
  --command='rm -rf ~/hermes-install && mv ~/hermes-install-new ~/hermes-install'
```

> Delete the old directory before copying. `gcloud compute scp --recurse` of a
> directory **into an existing target nests it** (`hermes-install/vpc-install/...`),
> and then all your paths are wrong.

---

## 4. Updating the other services

### Everything, in order

```bash
# OS
sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
sudo apt-get autoremove -y

# Chrome (comes from Google's apt repo, so apt upgrade already did it)
google-chrome --version

# Playwright Chromium
npx --yes playwright install chromium \
  || PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64 npx --yes playwright install chromium

# SearXNG
cd ~/searxng && sudo docker compose pull && sudo docker compose up -d

# Honcho
cd ~/honcho && git pull && sudo docker compose pull && sudo docker compose up -d

# Reclaim disk from old images
sudo docker image prune -f

# Verify the lot
bash ~/hermes-install/03-verify.sh
```

### Reboot when the kernel changes

```bash
[ -f /var/run/reboot-required ] && echo "REBOOT NEEDED" && cat /var/run/reboot-required.pkgs
sudo reboot
```

Everything comes back on its own — `linger` plus `Restart=always` on the Hermes
services, and `restart: unless-stopped` on the containers. Only the **tunnel on your
PC** needs re-opening (or it self-heals if you installed the LaunchAgent). Wait ~60s
after the reboot, then:

```bash
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap \
  --command='bash ~/hermes-install/03-verify.sh'
```

### Individual service control

```bash
# Hermes services
systemctl --user restart hermes-dashboard.service
systemctl --user restart hermes-gateway.service
systemctl --user status  hermes-dashboard.service
journalctl --user -u hermes-dashboard -f            # follow logs

# Containers
sudo docker compose -f ~/searxng/docker-compose.yml restart
sudo docker compose -f ~/honcho/docker-compose.yml restart
sudo docker compose -f ~/searxng/docker-compose.yml logs -f searxng

# Timers
systemctl --user list-timers --no-pager
systemctl --user start memory-backup.service        # force a backup now
```

### SearXNG stopped returning results

Usually an upstream engine started blocking the NAT egress IP, or the JSON format
setting was lost.

GET with `?format=json` is the documented API shape — SearXNG supports GET and POST
on `/search`. A **403 has two possible causes**, so check both before changing
anything: the requested format is not enabled (`search.formats` lost `json` —
"requesting an unset format will return a 403 Forbidden error"), *or* the limiter is
back on and is blocking a programmatic client. A **429** is the limiter specifically.

```bash
# What is it actually returning?
curl -s -o /dev/null -w '%{http_code}\n' 'http://localhost:8080/search?q=test&format=json'
#   200 -> gates are open (but see the results check below)
#   403 -> check BOTH settings below
#   429 -> limiter is on
grep -A4 'formats:' ~/searxng/settings.yml     # want html + json
grep 'limiter:' ~/searxng/settings.yml         # want false

# Real results, or empty?
curl -s 'http://localhost:8080/search?q=hermes+agent&format=json' | jq '.results | length'

# Engine-level errors
sudo docker compose -f ~/searxng/docker-compose.yml logs --tail=100 searxng | grep -i error
```

If one engine is blocked, disable it in `~/searxng/settings.yml` and restart — the
others carry the query.

---

## 5. Setup the desktop app cannot do

The desktop app is a client. These things exist only on the VM and must be done over
SSH.

| Task | Where | Command |
|---|---|---|
| Reset the dashboard password | VM | `HERMES_DASHBOARD_PASSWORD='new' dashboard-setup.sh kennet 9119` |
| Switch to a hashed password | VM | edit `~/.hermes/.env`, set `…_PASSWORD_HASH`, delete `…_PASSWORD` |
| Add / change the Vertex model catalog | VM | edit `providers.vertex.models` in `~/.hermes/config.yaml`, restart dashboard |
| Change region or model | VM | edit `~/.hermes/config.yaml` + `~/.hermes/.env`, restart both services |
| Honcho LLM keys | VM | `nano ~/honcho/.env` then `cd ~/honcho && sudo docker compose up -d` |
| SearXNG engines / formats | VM | `nano ~/searxng/settings.yml` then `sudo docker compose restart` |
| Install a skill | VM | `hermes skills` (interactive) |
| Add an MCP server | VM | edit `mcp_servers:` in `~/.hermes/config.yaml` |
| Cron jobs / routines | VM | `hermes cron` — needs `hermes-gateway.service` running |
| Firewall / VPC / NAT | **your PC** | `gcloud compute firewall-rules …` |
| Grant someone gateway access | **your PC** | see below |
| Resize the VM | **your PC** | see below |

### Reset the dashboard password

```bash
export PATH="$HOME/.local/bin:$PATH"
HERMES_DASHBOARD_PASSWORD='a-new-strong-password' dashboard-setup.sh kennet 9119
```

The script is idempotent for a reason: appending auth lines twice leaves **multiple**
`HERMES_DASHBOARD_BASIC_AUTH_*` sets in `.env` and the wrong one wins, with no useful
error. It strips all existing lines then writes exactly one clean set. It also
regenerates the signing secret, which invalidates existing sessions — intended when
resetting a password. Note the file is `~/.hermes/.env`, **not** `~/.env`.

### Give a colleague access to the gateway (on your PC)

```bash
gcloud projects add-iam-policy-binding test-disco-cm \
  --member="user:colleague@example.com" \
  --role="roles/iap.tunnelResourceAccessor" --condition=None
gcloud projects add-iam-policy-binding test-disco-cm \
  --member="user:colleague@example.com" \
  --role="roles/compute.osLogin" --condition=None
```

They also need the dashboard username/password. Revoke by swapping
`add-iam-policy-binding` for `remove-iam-policy-binding` — access dies immediately,
with no key rotation anywhere.

### Resize the VM (on your PC)

```bash
gcloud compute instances stop hermes-agent --zone=europe-west2-b
gcloud compute instances set-machine-type hermes-agent \
  --zone=europe-west2-b --machine-type=e2-standard-8
gcloud compute instances start hermes-agent --zone=europe-west2-b
```

Grow the disk without stopping (filesystem resize is online on Ubuntu):

```bash
gcloud compute disks resize hermes-agent --zone=europe-west2-b --size=200GB
# then, on the VM:
sudo growpart /dev/sda 1 && sudo resize2fs /dev/sda1 && df -h /
```

---

## 6. Backup and restore

The hourly timer backs up `~/.hermes` to GCS, **excluding** `.env`, caches, and lock
files. Honcho's Postgres data lives in a Docker volume and is **not** covered.

```bash
# Force a backup and check it
systemctl --user start memory-backup.service
journalctl --user -u memory-backup -n 20 --no-pager
gcloud storage ls -r gs://test-disco-cm-hermes-memory/hermes-state | head -20
```

**Restore Hermes state:**

```bash
systemctl --user stop hermes-gateway.service hermes-dashboard.service
gcloud storage rsync --recursive \
  gs://test-disco-cm-hermes-memory/hermes-state ~/.hermes
# .env was excluded from backup — re-create the credentials:
HERMES_DASHBOARD_PASSWORD='...' dashboard-setup.sh kennet 9119
systemctl --user start hermes-dashboard.service hermes-gateway.service
```

### Honcho's API keys do NOT survive a VM rebuild

This surprises people, so state it plainly: `~/honcho/.env` holds Honcho's AI Studio
Gemini key and OpenAI embeddings key, and it is **deliberately excluded** from the GCS
backup (it is a secret) and never committed to the repo. A new VM therefore starts with
`.env` identical to the shipped template, and Honcho will not start until you paste the
keys back. Nothing is lost from your accounts — AI Studio keys remain viewable at
<https://aistudio.google.com/apikey> — but you must re-enter them.

Symptom after any rebuild: `03-verify.sh` check 7 fails, nothing listening on `:8000`.

```bash
nano ~/honcho/.env      # LLM_GEMINI_API_KEY, LLM_OPENAI_API_KEY
cd ~/honcho && sudo docker compose up -d
```

**Durable fix — keep them in Secret Manager** so a rebuild can restore them without a
manual copy/paste. One-time setup:

```bash
# Store (run once per key, from your PC or the VM)
printf %s 'AIza...' | gcloud secrets create honcho-gemini-key --data-file=- --replication-policy=user-managed --locations=europe-west2
printf %s 'sk-...'  | gcloud secrets create honcho-openai-key --data-file=- --replication-policy=user-managed --locations=europe-west2

# Let the VM's service account read them
for s in honcho-gemini-key honcho-openai-key; do
  gcloud secrets add-iam-policy-binding "$s" \
    --member="serviceAccount:hermes-agent@test-disco-cm.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"
done
```

Then after any rebuild, restoring is two lines on the VM:

```bash
sed -i "s|^LLM_GEMINI_API_KEY=.*|LLM_GEMINI_API_KEY=$(gcloud secrets versions access latest --secret=honcho-gemini-key)|" ~/honcho/.env
sed -i "s|^LLM_OPENAI_API_KEY=.*|LLM_OPENAI_API_KEY=$(gcloud secrets versions access latest --secret=honcho-openai-key)|" ~/honcho/.env
cd ~/honcho && sudo docker compose up -d
```

Note `--locations=europe-west2` keeps the secrets EU-resident, and this needs
`secretmanager.googleapis.com` enabled.

**Back up Honcho's database properly** (the volume is not in the GCS rsync):

```bash
# logical dump — adjust the service/user names to match ~/honcho/docker-compose.yml
cd ~/honcho
sudo docker compose exec -T postgres pg_dumpall -U postgres \
  | gzip > ~/honcho-$(date +%F).sql.gz
gcloud storage cp ~/honcho-$(date +%F).sql.gz \
  gs://test-disco-cm-hermes-memory/honcho/
```

**Whole-machine snapshot** — the only thing that captures everything including
Docker volumes. Run on **your PC**:

```bash
gcloud compute disks snapshot hermes-agent \
  --zone=europe-west2-b \
  --snapshot-names=hermes-agent-$(date +%Y%m%d) \
  --storage-location=europe-west2
```

Worth putting on a schedule:

```bash
gcloud compute resource-policies create snapshot-schedule hermes-daily \
  --region=europe-west2 --max-retention-days=14 \
  --daily-schedule --start-time=02:00 \
  --on-source-disk-delete=keep-auto-snapshots
gcloud compute disks add-resource-policies hermes-agent \
  --zone=europe-west2-b --resource-policies=hermes-daily
```

---

## 7. Gateway/tunnel problems (on your PC)

Symptom: the desktop app says *"Remote gateway sign-in required"* or
`localhost:9119` will not load. Almost always the tunnel, not the VM.

```bash
# 1. Is the tunnel up?
curl -sS -I http://localhost:9119/          # want 200, 302 or 401

# 2. Is the VM running?
gcloud compute instances describe hermes-agent --zone=europe-west2-b \
  --format='value(status)'                  # want RUNNING

# 3. Kill any half-dead tunnel and reopen
pkill -f 'start-iap-tunnel' || true
gcloud compute start-iap-tunnel hermes-agent 9119 \
  --local-host-port=localhost:9119 --zone=europe-west2-b --project=test-disco-cm

# 4. Using the LaunchAgent? Force a reconnect instead.
launchctl kickstart -k gui/$(id -u)/com.hermes.gateway-tunnel
tail -f /tmp/hermes-gateway-tunnel.log
```

| Tunnel error | Meaning |
|---|---|
| `Address already in use` | a tunnel is already bound to 9119 — you are done |
| `permission denied … iap.tunnelInstances.accessViaIAP` | you lack `roles/iap.tunnelResourceAccessor` |
| `connection refused` after tunnel opens | tunnel is fine; the **dashboard service** is down on the VM |
| `4033` / handshake failures | firewall rule for `35.235.240.0/20` on 9119 is missing |
| hangs then times out | VM is stopped, or Cloud NAT was deleted |

If the tunnel is up but the app still will not sign in, it is usually the **12-hour
session TTL**: **Sign out and sign back in** in the app. Also confirm Gateway
settings are basic-auth `http://localhost:9119`, **not** OAuth.

`gcloud compute ssh` **intermittently exits 255** — a transient SSH failure. Just
retry; every script here is idempotent.

---

## 8. Symptom → cause table

| Symptom | Cause / fix |
|---|---|
| All services dead after logout | `linger` off → `sudo loginctl enable-linger $USER` (§2d) |
| Desktop app: "Remote gateway incomplete" | dashboard bound to `127.0.0.1` → auth is OFF. Must be `0.0.0.0` (§1) |
| Desktop app: can't sign in, no error | duplicate `HERMES_DASHBOARD_BASIC_AUTH_*` lines in `.env` → re-run `dashboard-setup.sh` (§5) |
| Sign-in works, then fails ~12h later | session TTL — sign out and in. Not a fault (§7) |
| `localhost:9119` won't load | the tunnel died (sleep/reboot/VM stop) (§7) |
| Gateway `active` but does nothing | wedged → §2b, then install the watchdog §2c |
| Gateway `inactive (dead)` after a config edit | exit **78** = config error; `RestartPreventExitStatus=78` stops the restart loop on purpose (§2a-bis) |
| Gateway won't start, "already running" | stale `gateway.lock` / `gateway.pid` → §2b step 3 |
| Dashboard login rejects `curl -u user:pass` | not a fault — raw HTTP Basic isn't the flow. `POST /auth/password-login` with `{"provider":"basic","username":…,"password":…}` mints a session token (§7) |
| Long tasks cut off mid-run | `HERMES_AGENT_TIMEOUT` too low (§2a) |
| Big contexts die mid-stream | raise `HERMES_STREAM_READ_TIMEOUT` (§2a) |
| `HTTP 400 — no access to model` | `GOOGLE_API_KEY`/`GEMINI_API_KEY` set in `~/.hermes/.env`, switching Hermes to the AI-Studio `gemini` provider. Remove them; `vertex` uses ADC |
| Vertex 404 on a model that "exists" | that model isn't served in this region. AI Studio ≠ Vertex — probe it (INSTALL.md §12) |
| `/model` picker shows one model only | `providers.vertex.models` catalog missing from `config.yaml` (§3) |
| Search returns nothing, SearXNG 403 | two possible gates: `search.formats` lost `json`, **or** `server.limiter` is back on (§4) |
| Search returns nothing, SearXNG 429 | `server.limiter` is on — set it `false` (§4) |
| Search returns nothing, 200 OK | upstream engine blocking the NAT IP — disable it in `settings.yml` (§4) |
| Honcho unreachable on `:8000` | `~/honcho/.env` has no LLM keys, so it never started (INSTALL.md §6) |
| Honcho broke after a VM rebuild | its keys live only in `~/honcho/.env`, which is excluded from backup by design — re-paste them, or use Secret Manager (§6) |
| "Remote gateway session has expired" right after an installer re-run | the session-signing secret was rotated. Fixed in 0.11.1 (preserved by default); just sign out and back in (§7) |
| Browser tool fails to launch | Playwright Chromium missing → re-run with the platform override (§4) |
| `apt`/`docker pull`/search all fail | Cloud NAT gone. Private Google Access covers Google APIs only |
| Disk filling up | `sudo docker image prune -f`; check `~/.hermes/logs`, `sessions/`, `~/.cache/ms-playwright` |
| Everything unreachable, VM `RUNNING` | firewall rules for `35.235.240.0/20` were changed or removed |

---

## Quick reference

```bash
# ── on your PC ───────────────────────────────────────────────────────────────
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap
gcloud compute start-iap-tunnel hermes-agent 9119 --local-host-port=localhost:9119 \
  --zone=europe-west2-b --project=test-disco-cm
gcloud compute instances describe hermes-agent --zone=europe-west2-b --format='value(status)'

# ── on the VM ────────────────────────────────────────────────────────────────
bash ~/hermes-install/03-verify.sh                 # 9/9 health check
hermes doctor && hermes gateway status             # Hermes' own view
systemctl --user restart hermes-dashboard.service hermes-gateway.service
journalctl --user -u hermes-gateway -n 100 --no-pager
sudo docker ps
hermes update                                      # upgrade the backend
HERMES_DASHBOARD_PASSWORD='pw' dashboard-setup.sh kennet 9119
```

Install-time detail and design rationale: **[INSTALL.md](INSTALL.md)**.
