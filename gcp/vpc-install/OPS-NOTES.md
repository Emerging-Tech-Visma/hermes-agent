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
8. [Stopping, starting and rebooting the VM](#8-stopping-starting-and-rebooting-the-vm)
9. [Scenario cookbook](#9-scenario-cookbook)
10. [Symptom → cause table](#10-symptom--cause-table)
11. [Keeping Hermes up to date (backend + desktop)](#11-keeping-hermes-up-to-date-backend--desktop)

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

> Weekly updates are **automated** by `hermes-autoupdate.timer` — see
> [§11](#11-keeping-hermes-up-to-date-backend--desktop), which also explains why the
> updater must not be launched from `hermes cron` or the desktop app, and how to update
> the desktop app itself. This section is the manual path.

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

# 4. Bring it back and verify. NOTE: `hermes update` restarts the gateway but NOT
#    the dashboard, so restarting it here is required, not belt-and-braces —
#    otherwise the dashboard keeps serving pre-update code (§11a).
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

## 8. Stopping, starting and rebooting the VM

### What happens when you stop it

Stopping the instance kills **everything** — the agent, the gateway, the dashboard,
SearXNG, Honcho, the Vertex shim, cron jobs. Nothing is lost: the boot disk persists,
so all config, memory, sessions and the Honcho database survive.

```bash
# on your PC
gcloud compute instances stop hermes-agent --zone=europe-west2-b
```

| Cost while stopped | |
|---|---|
| VM (vCPU/RAM) | **stops billing** |
| 100 GB boot disk | **keeps billing** (~$11/mo) |
| Cloud NAT gateway | **keeps billing** (~$35–45/mo) — it is not tied to the VM |
| Static internal IP (`10.10.0.3` today) | free, and **persists** across stop/start |

> So stopping saves roughly the compute only. If you are pausing for weeks, delete the
> NAT gateway too — and remember to recreate it before starting, or `apt`, Docker Hub
> and SearXNG's upstream fetches will all fail:
> ```bash
> gcloud compute routers nats delete hermes-nat --router=hermes-router --region=europe-west2 --quiet
> # to restore:
> gcloud compute routers nats create hermes-nat --router=hermes-router --region=europe-west2 \
>   --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges
> ```

### What happens when you start it again

**Everything comes back on its own.** Verified on this install:

| Component | Comes back? | Why |
|---|---|---|
| `hermes-dashboard.service` | ✅ | user unit, `enabled` + **linger** |
| `hermes-gateway.service` | ✅ | user unit, `enabled` + linger |
| `vertex-openai-proxy.service` | ✅ | user unit, `enabled` + linger |
| `memory-backup.timer` | ✅ | timer, `enabled`, `Persistent=true` catches missed runs |
| Honcho (4 containers) | ✅ | `restart: unless-stopped` + docker `enabled` at boot |
| SearXNG + Valkey | ✅ | `restart: unless-stopped` |
| Internal IP (`10.10.0.3` today) | ✅ | stays assigned to the instance; reassigned only on VM re-create |
| **Your IAP tunnel** | ❌ | **client-side — you must re-open it** |
| Dashboard session | ❌ | 12 h TTL; sign in again |

The only manual step is the tunnel on your PC:

```bash
gcloud compute instances start hermes-agent --zone=europe-west2-b
# wait ~45-60s for boot + containers, then:
gcloud compute start-iap-tunnel hermes-agent 9119 \
  --local-host-port=localhost:9119 --zone=europe-west2-b --project=test-disco-cm
```

Install the LaunchAgent (`configs/com.hermes.gateway-tunnel.plist`) and even that
becomes automatic.

### Full start-and-verify, one command

```bash
gcloud compute instances start hermes-agent --zone=europe-west2-b && \
sleep 60 && \
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap \
  --command='bash ~/hermes-install/03-verify.sh'
```

Expect **13/13**. If Honcho fails, its containers are usually just slower than the
health check — wait 30s and re-run before investigating.

### Rebooting (vs. stop/start)

```bash
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap --command='sudo reboot'
```

Same recovery story, faster. Reboot after a kernel update:

```bash
[ -f /var/run/reboot-required ] && cat /var/run/reboot-required.pkgs
```

> ⚠️ **Do not stop the VM if this is serving a team.** Cron jobs don't fire, and any
> Slack/messaging bot goes offline. `linger` and `Restart=always` cannot help a stopped
> instance.

---

## 9. Scenario cookbook

Copy-paste recipes for the things you'll actually do. All `hermes-ssh` below is the
alias from the top of this file.

### "I want a shell on the box"

```bash
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap
```

No public IP exists, so `--tunnel-through-iap` is mandatory every time. If it exits
**255**, that's the known transient — just retry, everything here is idempotent.

### "Update Hermes itself"

```bash
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap --command='
export PATH="$HOME/.local/bin:$PATH"
cp ~/.hermes/config.yaml ~/.hermes/config.yaml.bak-$(date +%F)
systemctl --user stop hermes-gateway.service hermes-dashboard.service
hermes update && hermes version
systemctl --user start hermes-dashboard.service hermes-gateway.service
hermes doctor'
```

Then re-check the three things an upgrade can silently reset (§3).

### "Restart the gateway"

```bash
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap \
  --command='systemctl --user restart hermes-gateway.service && systemctl --user is-active hermes-gateway.service'
```

### "The gateway is wedged — kill it and start clean"

`Restart=always` cannot see a hung-but-alive process, so this is the escalation:

```bash
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap --command='
systemctl --user stop hermes-gateway.service
pkill -u "$USER" -f "gateway run" || true
sleep 2
rm -f ~/.hermes/gateway.lock ~/.hermes/gateway.pid
systemctl --user start hermes-gateway.service
sleep 5
systemctl --user is-active hermes-gateway.service'
```

If it comes back `inactive (dead)` instead, that's **exit 78 = config error** — read the
journal, don't keep restarting (§2a-bis).

### "Restart everything"

```bash
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap --command='
systemctl --user restart vertex-openai-proxy.service hermes-dashboard.service hermes-gateway.service
sudo docker compose -f ~/searxng/docker-compose.yml restart
sudo docker compose -f ~/honcho/docker-compose.yml restart
sleep 20
bash ~/hermes-install/03-verify.sh'
```

Restart the **shim before Honcho** — Honcho's first call fails if the shim is down.

### "Start over from a virgin installation" (required before signing off install changes)

```bash
bash gcp/vpc-install/scripts/teardown.sh               # VM + network + SA, keeps the bucket
bash gcp/vpc-install/scripts/teardown.sh --with-bucket # also destroys memory backups
bash gcp/vpc-install/scripts/teardown.sh --vm-only     # just the VM (network/NAT stay, NAT keeps billing)
```

Requires typing the VM name to confirm; nothing is deleted before that. It also removes the
local gateway LaunchAgent, since leaving one pointed at a deleted VM makes it fail forever
and squat port 9119.

Confirm it really is virgin, then reinstall:

```bash
gcloud compute instances list --project=test-disco-cm   # expect: Listed 0 items.
gcloud compute networks list  --project=test-disco-cm   # expect: no hermes-vpc
```

**Why this is mandatory before signing off an install change:** a re-run over a live VM
cannot see fresh-state defects. On 2026-08-18 a from-scratch rebuild found five, four of
them install-blocking, all latent across three releases that had been re-run and declared
working. Details in [AGENTS.md](../../AGENTS.md).

> Cost note: `--vm-only` leaves Cloud NAT in place, and **NAT keeps billing with no VM
> attached**. Full teardown is the cheaper default.

### "Re-apply the whole managed config from the repo"

The installer is idempotent; this is the blunt fix for config drift:

```bash
# refresh the repo copy on the VM first (from your PC)
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap --command='rm -rf ~/hermes-install-new'
gcloud compute scp --zone=europe-west2-b --tunnel-through-iap --recurse \
  gcp/vpc-install hermes-agent:~/hermes-install-new
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap \
  --command='rm -rf ~/hermes-install && mv ~/hermes-install-new ~/hermes-install'
```

> Always delete the target first — `scp --recurse` of a directory *into* an existing
> one nests it (`hermes-install/vpc-install/...`) and every path then breaks.

```bash
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap --command='
export HERMES_DASHBOARD_PASSWORD="$(grep ^HERMES_DASHBOARD_BASIC_AUTH_PASSWORD= ~/.hermes/.env | cut -d= -f2-)"
bash ~/hermes-install/02-vm-install.sh 2>&1 | tail -20'
```

Re-running no longer logs you out — the session-signing secret is preserved (0.11.1).

### "The desktop app says Remote gateway sign-in required"

Nine times out of ten the gateway tunnel is simply down, not your credentials. Order of
checks:

```bash
lsof -nP -iTCP:9119 -sTCP:LISTEN                 # is anything serving locally?
launchctl list | grep -i hermes                  # status != 0 means the agent is failing
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9119/   # 302 = healthy auth gate
tail -20 /tmp/hermes-gateway-tunnel.log
launchctl kickstart -k gui/$(id -u)/com.hermes.gateway-tunnel      # force reconnect
```

- **302 is success**, not an error — it is the redirect to `/login`.
- **"Address already in use"** in the log: two tunnels are fighting for 9119. The pre-VPC
  install shipped a `com.hermes.tunnel` agent (SSH `-L` to a VM in `europe-west1-b` that no
  longer exists); it fails forever and competes for the port. Boot it out —
  `launchctl bootout gui/$(id -u)/com.hermes.tunnel` — and verify it is really gone, since
  KeepAlive can relaunch it between your bootout and your check.
- **A hand-started tunnel dies with its shell.** If the gateway worked and then stopped for
  no clear reason, whoever started it closed their terminal or the machine slept. Install
  the agent: `bash gcp/vpc-install/scripts/install-gateway-launchagent.sh`.
- **Credentials error in the log** (not an IAM problem): run `gcloud auth login`. launchd
  starts with almost no environment, which is why the plist sets `HOME` and `PATH`
  explicitly.
- Forgotten password: `cat ~/.hermes-dashboard-password` on the VM. Rotate with
  `HERMES_DASHBOARD_PASSWORD='new' ~/.local/bin/dashboard-setup.sh kennet 9119` — that
  forces every client to sign in again but preserves the session-signing secret.

### "Run one agent turn non-interactively" (scripted proof / smoke test)

`hermes -z '<prompt>'` runs a single turn and exits. This is the flag to use in scripts:
the **TUI** is what cannot be driven by piped stdin, not the CLI itself — an earlier note
in this repo wrongly concluded a scripted agent turn was impossible.

```bash
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap --command='
export PATH=$HOME/.local/bin:$PATH
hermes -z "Create /tmp/hermes-proof and write OK into proof.txt inside it. Reply with the path."
ls -l /tmp/hermes-proof/'
```

Proves the whole chain in one shot: model reachable, **tool-calling works on the current
model**, and the filesystem it touches is the VM's. Used on 2026-08-18 to verify
`gemini-3.7-flash` really tool-calls, not just answer.

### "Prove Honcho really remembers" (end-to-end, not liveness)

Port checks and single-shot shim completions both pass on a **completely dead** dialectic
— that is how a Gemini 3.x `HONCHO_MODEL` slips through (see AGENTS.md). This is the
check that actually matters; `03-verify.sh` test 13 automates it.

```bash
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap --command='
H=http://localhost:8000/v3/workspaces; J="Content-Type: application/json"
curl -s -X POST $H -H "$J" -d "{\"id\":\"probe\"}" >/dev/null
curl -s -X POST $H/probe/peers -H "$J" -d "{\"id\":\"p1\"}" >/dev/null
curl -s -X POST $H/probe/sessions -H "$J" -d "{\"id\":\"s1\"}" >/dev/null
curl -s -X POST $H/probe/sessions/s1/messages -H "$J" \
  -d "{\"messages\":[{\"peer_id\":\"p1\",\"content\":\"I keep a tortoise called Gustav.\"}]}" >/dev/null
curl -s -X POST $H/probe/peers/p1/chat -H "$J" -d "{\"query\":\"What pet do I have?\"}"'
```

The answer must contain *Gustav*. If it returns an error mentioning
**`thought_signature`**, `HONCHO_MODEL` is a Gemini 3.x model — set it back to
`google/gemini-2.5-flash` and re-run `02-vm-install.sh`.

> Two traps if you go looking for the *derived* memory rather than the answer:
> `…/peers/p1/representation` needs `-d '{"session_id":"s1"}'` — with `{}` it returns
> `{"representation":""}` even when memory exists — and the deriver **batches for up to 30
> minutes** (512-token / 1800s gates), so `queue/status` showing N pending / 0 in-progress
> is normal, not a fault. To see derivation now, set
> `DERIVER_REPRESENTATION_BATCH_WORK_UNIT_TARGET_TOKENS=0` in `~/honcho/.env`, recreate the
> deriver, wait ~40s — then put it back. Full detail in AGENTS.md.

### "Check the Vertex shim behind Honcho"

```bash
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap --command='
systemctl --user is-active vertex-openai-proxy.service
curl -s http://127.0.0.1:8900/health; echo
sudo journalctl _SYSTEMD_USER_UNIT=vertex-openai-proxy --no-pager -n 20'
```

Definitive test of whether Honcho really depends on it — stop it and query:

```bash
# with the shim down, a dialectic query returns HTTP 500; with it up, 200
systemctl --user stop vertex-openai-proxy.service
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  http://localhost:8000/v3/workspaces/WS/peers/PEER/chat \
  -H 'Content-Type: application/json' -d '{"query":"hi"}'
systemctl --user start vertex-openai-proxy.service
```

> Reading the shim's own access log needs journal access. If you see *"No journal files
> were opened due to insufficient permissions"*, you're not in `systemd-journal` yet:
> `sudo usermod -aG systemd-journal $USER` then log out and back in. Use
> `sudo journalctl _SYSTEMD_USER_UNIT=vertex-openai-proxy` meanwhile.

### "Free up disk"

```bash
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap --command='
df -h / | tail -1
sudo docker image prune -f
du -sh ~/.hermes/logs ~/.hermes/sessions ~/.cache/ms-playwright 2>/dev/null
sudo journalctl --vacuum-time=7d'
```

### "Rotate the dashboard password"

```bash
gcloud compute ssh hermes-agent --zone=europe-west2-b --tunnel-through-iap --command='
export PATH="$HOME/.local/bin:$PATH"
HERMES_DASHBOARD_PASSWORD="a-new-strong-password" dashboard-setup.sh kennet 9119'
```

Add `ROTATE_DASHBOARD_SECRET=1` to also invalidate every existing session (do that if a
password may have leaked).

### "Who can reach this box?"

```bash
gcloud projects get-iam-policy test-disco-cm \
  --flatten="bindings[].members" \
  --filter="bindings.role:roles/iap.tunnelResourceAccessor" \
  --format="value(bindings.members)"
```

Revoke instantly — no key rotation, no `authorized_keys` edits:

```bash
gcloud projects remove-iam-policy-binding test-disco-cm \
  --member="user:person@example.com" --role="roles/iap.tunnelResourceAccessor"
```

---

## 10. Symptom → cause table

| Symptom | Cause / fix |
|---|---|
| All services dead after logout | `linger` off → `sudo loginctl enable-linger $USER` (§2d) |
| Desktop app: "Remote gateway incomplete" | dashboard bound to `127.0.0.1` → auth is OFF. Must be `0.0.0.0` (§1) |
| Desktop app: can't sign in, no error | duplicate `HERMES_DASHBOARD_BASIC_AUTH_*` lines in `.env` → re-run `dashboard-setup.sh` (§5) |
| Sign-in works, then fails ~12h later | session TTL — sign out and in. Not a fault (§7) |
| `localhost:9119` won't load | the tunnel died (sleep/reboot/VM stop) (§7) |
| Gateway `active` but does nothing | wedged → §2b, then install the watchdog §2c |
| In-app / dashboard update reports failure | the updater ran inside the gateway cgroup and was reaped when `hermes update` restarted it. Use the timer or a plain SSH `hermes update` (§11b) |
| Updated Hermes, but the UI looks unchanged | `hermes update` does not restart `hermes-dashboard.service`; restart it (§11a) |
| Autoupdate timer enabled but never fires | malformed `AUTOUPDATE_SCHEDULE`; check `systemd-analyze calendar '<expr>'` (§11a) |
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
bash ~/hermes-install/03-verify.sh                 # 13/13 health check
hermes doctor && hermes gateway status             # Hermes' own view
systemctl --user restart hermes-dashboard.service hermes-gateway.service
journalctl --user -u hermes-gateway -n 100 --no-pager
sudo docker ps
hermes update                                      # upgrade the backend
HERMES_DASHBOARD_PASSWORD='pw' dashboard-setup.sh kennet 9119
```

Install-time detail and design rationale: **[INSTALL.md](INSTALL.md)**.

---

## 11. Keeping Hermes up to date (backend + desktop)

There are **two** things to update and they are genuinely separate. Conflating them is
the source of most confusion here.

| | Where it lives | How it updates |
|---|---|---|
| **Backend** — agent, gateway, dashboard | the VM | `hermes update`, automated by `hermes-autoupdate.timer` (weekly, Sunday) |
| **Desktop app** | your Mac | built from its own checkout; **manual, two commands** |

### 11a. Backend — automated weekly

`AUTOUPDATE_ENABLE=true` in `00-vars.sh` installs a systemd timer that runs
[`scripts/hermes-autoupdate.sh`](scripts/hermes-autoupdate.sh) every Sunday at 04:00 UTC
(plus a randomised delay up to 30 min). Each run:

1. `hermes update --check` — exits quietly if there is nothing to do (no restarts, no churn)
2. `hermes update --yes` — keeps Hermes' own pre-update backup
3. **restarts `hermes-dashboard.service`** — see the warning below
4. runs `03-verify.sh` and fails loudly if the new code does not pass

```bash
# is it armed, and when does it next fire?
systemctl --user list-timers hermes-autoupdate.timer --no-pager

# what happened last time?
sudo journalctl _SYSTEMD_USER_UNIT=hermes-autoupdate --no-pager -n 60

# run it now, without waiting for Sunday
systemctl --user start hermes-autoupdate.service

# just check, don't install
AUTOUPDATE_MODE=check ~/.local/bin/hermes-autoupdate.sh
```

State markers live in `~/.hermes/autoupdate/`: `last-success`, `last-failure`,
`last-check`, `pending`. `03-verify.sh` check 14 fails if `last-failure` exists, so a
broken update does not rot silently.

> ⚠️ **`hermes update` restarts the gateway but NOT our dashboard.**
> `hermes update --plan` lists exactly one service — `gateway [default] … systemd`. Our
> install also runs `hermes-dashboard.service`, which is the endpoint the desktop app and
> browser connect to, and the updater knows nothing about it. Without an explicit
> restart the dashboard keeps serving the **pre-update code**, so the app looks like it
> never updated. The autoupdate script handles this; if you ever run `hermes update` by
> hand, restart the dashboard yourself.

### 11b. Why a systemd timer and NOT `hermes cron`

This is the important bit, and it is not a style preference.

`hermes update` restarts `hermes-gateway.service`. A `hermes cron` job runs **inside that
gateway process**. The gateway unit sets `KillMode=mixed` and an `ExecStopPost` cgroup
cleanup, so when it stops, everything in its cgroup is reaped — **including a `hermes
update` launched from a cron job**. The job destroys its own runtime mid-flight.

The exact same trap catches updates started from the **desktop app or dashboard**: the
spawned updater is a child of the gateway, so `systemctl restart hermes-gateway` kills it
before it can finish. That is why an in-app update can report failure while having partly
succeeded.

A systemd timer is a separate unit with its own cgroup. When the updater restarts the
gateway, the updater itself is untouched. No Hermes code change and no
`systemd-run --scope` wrapper is required — the isolation comes free from *not launching
the updater from the thing being restarted*.

> **Do not "fix" this with `agent.restart_drain_timeout`.** Those keys are real
> (`gateway/restart.py`), but the default `restart_drain_timeout` is **0 — no drain at
> all**: a restart interrupts in-flight agents immediately. Setting it to `5` *increases*
> the wait. The 1800-second figure sometimes quoted here is `HERMES_AGENT_TIMEOUT`, the
> **idle-agent** timeout, which has nothing to do with restart drain. The only real drain
> in play is `cron_drain_timeout` (default 30s), and it is already short.

### 11c. Desktop app — manual, on your Mac

The desktop app is **not** covered by the timer and cannot be. It is built from its own
checkout — `hermes desktop` is documented as *"Build and launch the native desktop app"* —
and the installed bundle carries **no `app-update.yml`**, so there is no electron
auto-update feed to point at.

```bash
# on your Mac
export PATH="$HOME/.local/bin:$PATH"
hermes update          # updates the local checkout (which contains apps/desktop)
hermes desktop         # rebuild and launch the app from that checkout
```

> `/Applications/Hermes.app` is whatever the original DMG installed and does **not** get
> refreshed by `hermes update`. The freshly built app lives under
> `~/.hermes/hermes-agent/apps/desktop/release/`. If you want the `/Applications` copy to
> be current, replace it from there — or just launch via `hermes desktop`.

**Version skew is usually harmless.** The app is a thin client over the dashboard: all
compute, tools and memory are on the VM. Keeping the backend current matters far more
than keeping the app current. Update the app when you want new UI, or when a release note
says the client protocol changed.

### 11d. Turning it off, or making it human-in-the-loop

For a production agent you may not want unattended upgrades of a live service.

```bash
# report only — writes ~/.hermes/autoupdate/pending, installs nothing
# (00-vars.sh)  AUTOUPDATE_MODE="check"

# off entirely
# (00-vars.sh)  AUTOUPDATE_ENABLE="false"
```

Then re-run `02-vm-install.sh`, or on the VM directly:

```bash
systemctl --user disable --now hermes-autoupdate.timer
```

### 11e. If an unattended update breaks the install

```bash
sudo journalctl _SYSTEMD_USER_UNIT=hermes-autoupdate --no-pager -n 100   # what it did
ls -l ~/.hermes/backups/                                                # pre-update backup
bash ~/hermes-install/03-verify.sh                                      # what is broken now
```

Hermes takes a pre-update backup by default (do **not** pass `--no-backup` in the timer).
Rollback and re-install paths are in §3.
