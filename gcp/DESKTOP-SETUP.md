# Hermes Desktop App → Cloud Backend

Connect the Hermes Desktop app (or a browser) on your Mac to the Hermes instance
running on the `hermes-agent` VM. The desktop is just a UI; the agent, memory,
knowledge, and Vertex billing all live on the VM.

## 1. Install the desktop app

Download from <https://hermes-agent.nousresearch.com/>:

| OS | Download | Type |
|---|---|---|
| macOS 12+ | <https://hermes-assets.nousresearch.com/Hermes-Setup.dmg> | `.dmg` |
| Windows 10/11 | <https://hermes-assets.nousresearch.com/Hermes-Setup.exe> | `.exe` |
| Linux | `curl -fsSL https://hermes-agent.nousresearch.com/install.sh \| bash` | script |

On first launch pick **Blank Slate** (everything off) and **Keep current (local)**
for the terminal backend — you're attaching to the remote VM, so the local shell
stays empty.

## 2. Backend on the VM (already set up by the install scripts)

`02-vm-install.sh` installs `hermes-dashboard.service`, which runs the dashboard on
`0.0.0.0:9119` with a basic-auth gate reading credentials from `~/.hermes/.env`.
The `0.0.0.0` bind is what turns auth ON (a loopback bind runs with auth OFF and the
desktop can't sign in). The port is **never** opened in the GCP firewall — you reach
it over an SSH tunnel, so nothing is exposed to the internet.

Check / (re)set the login on the VM at any time:

```bash
# on the VM
HERMES_DASHBOARD_PASSWORD='your-strong-password' dashboard-setup.sh kennet 9119
systemctl --user status hermes-dashboard.service
```

`dashboard-setup.sh` is idempotent: it strips any old/duplicate/placeholder
`HERMES_DASHBOARD_BASIC_AUTH_*` lines and writes exactly one clean set — the two
gotchas that blocked sign-in during the first setup.

## 3. Tunnel from your Mac

**One-off (manual):**
```bash
gcloud compute ssh hermes-agent --zone=europe-west1-b -- -L 9119:localhost:9119 -N -f
```
`-N -f` runs it backgrounded with no shell. Verify: `curl -sS -I http://localhost:9119/`
should print `HTTP/1.1 302 Found`. Only one tunnel can bind 9119; "Address already in
use" means one is already up.

**Persistent (recommended — no morning re-run).** The manual tunnel dies on Mac
sleep/reboot, so every morning the desktop app shows *"Remote gateway sign-in required"*
until you re-tunnel. Install a **LaunchAgent** that starts the tunnel at login and
auto-restarts it on any drop (sleep/wake, VM reboot), so the app reconnects on its own —
template: [`configs/com.hermes.tunnel.plist`](configs/com.hermes.tunnel.plist).

```bash
# adjust the plist for your machine first (gcloud path via `which gcloud`, your /Users path)
cp gcp/configs/com.hermes.tunnel.plist ~/Library/LaunchAgents/com.hermes.tunnel.plist
pkill -f 'L 9119:localhost:9119' 2>/dev/null || true      # free the port from any manual tunnel
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.hermes.tunnel.plist
launchctl kickstart -k gui/$(id -u)/com.hermes.tunnel
curl -sS -I --retry 40 --retry-delay 1 --retry-all-errors http://localhost:9119/   # want HTTP/1.1 302
```
Reconnect after a drop takes ~20–40s (launchd throttle + gcloud cold start), so on wake
give it a moment before the app connects. Manage it:
```bash
launchctl kickstart -k gui/$(id -u)/com.hermes.tunnel   # force reconnect now
launchctl bootout   gui/$(id -u)/com.hermes.tunnel      # stop + disable (back to manual)
tail -f ~/Library/Logs/hermes-tunnel.log                # errors, if any
```
Note this only reconnects the *admin UI* tunnel — the Slack bot on the VM is 24/7 and
never depended on it (Socket Mode is outbound from the VM).

## 4. Connect the app

Desktop app → **Settings → Gateway → Remote gateway**:
- Remote URL: `http://localhost:9119`
- **Sign in** with your username / password (e.g. `kennet`)
- Reconnect

There is no token to copy — once you sign in, the desktop reuses the session for the
chat WebSocket automatically. (Or just use the browser at <http://localhost:9119>.)

## When it stops working

Almost always the tunnel died (Mac slept/rebooted, or the VM was stopped/restarted).
Symptom: `localhost:9119` won't load in either the app or the browser.

```bash
# 1. VM running?
gcloud compute instances start hermes-agent --zone=europe-west1-b   # if stopped
# 2. re-open the tunnel
gcloud compute ssh hermes-agent --zone=europe-west1-b -- -L 9119:localhost:9119 -N -f
```

The dashboard itself is a systemd service (`Restart=always`, linger enabled), so it
comes back on its own after a VM reboot. The Mac-side tunnel needs rerunning — **unless
you installed the LaunchAgent in §3**, which auto-reconnects it for you (give it ~20–40s
after wake). If the app still shows *"Remote gateway sign-in required"* after the tunnel
is back, it's just the ~12h session TTL: **Sign out & sign in** in the app (basic auth) —
and make sure Gateway settings are basic-auth `http://localhost:9119`, **not** OAuth.

> Watch the terminal prompt when pasting VM commands: `kennetkusk@hermes-agent` = VM,
> `kennetkusk@Mac` = your laptop. Auth/config commands must run on the VM. If in
> doubt, wrap them: `gcloud compute ssh hermes-agent --zone=europe-west1-b --command='...'`
> runs on the VM regardless of where your prompt is.
