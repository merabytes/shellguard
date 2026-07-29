# ShellGuard

Real-time shell spawn detection for Linux servers. Monitors `/proc` for new shell processes and sends instant Telegram alerts with process ancestry — so you know if that `bash` came from a web app, a cronjob, or an attacker.

---

## What it does

ShellGuard runs as a lightweight daemon written in **pure POSIX sh** (no Python, no Ruby, no dependencies beyond `curl`). It polls `/proc/*/comm` every second and fires a Telegram notification whenever a new interactive shell or SSH session appears.

Each alert includes:

- **Host** and **IPs** of the machine
- **User**, **shell binary**, **PID**, and **TTY**
- **Active shell count** (in-memory, no files)
- **Parent process** and **ancestry chain** — the full path from the shell up to its origin

```
[ShellGuard] Shell Opened
Host: prod-web-01
IPs: 10.0.1.5
User: www-data  |  Shell: sh
PID: 4821  |  TTY: ?  |  Active shells: 2
Parent: python3 (pid 4800)
Chain: sh(4821) ← python3(4800) ← apache2(4750)
```

If your Flask app gets pwned via `os.system()`, you'll know within a second — and you'll see `python3` in the chain.

---

## Why process ancestry matters

Most shell monitors tell you *that* a shell spawned. ShellGuard tells you *why*.

| Chain | What happened |
|-------|--------------|
| `bash ← sshd` | Normal SSH login |
| `sh ← python3 ← gunicorn` | RCE via Python web app (`os.system`) |
| `dash ← sh ← node` | RCE via Node.js (`child_process.exec`) |
| `bash ← crond` | Cron job — probably fine |
| `sh ← (unknown)` | Suspicious — investigate |

---

## Architecture

```
/proc polling (1s)
       │
       ▼
  poll_proc()          # Linux: reads /proc/*/comm directly
  poll_ps()            # macOS fallback: ps snapshot via tmpfile
       │
       ▼
  on_event(type, pid)
    ├── proc_user()    # /proc/<pid>/status → Uid
    ├── proc_tty()     # /proc/<pid>/fd/0 → symlink
    ├── proc_parent()  # PPid from /proc/<pid>/status
    ├── proc_ancestry() # walks up the tree, stops at PID 1
    └── build_text()   # formats the Telegram message
       │
       ▼
  notify_telegram()    # curl POST to Bot API
```

Active shells are tracked in a **pure in-memory variable** (`ACTIVE_SHELLS`) — newline-separated records, pipe-delimited fields. No files written, no tmpfs, no manipulation surface.

---

## Installation

### From .deb (Debian/Ubuntu)

```bash
# Build the package
bash build_deb.sh

# Install
dpkg -i dist/shellguard_*.deb

# Configure
vi /etc/shellguard/shellguard.conf

# Start
systemctl enable --now shellguard
```

### Manual

```bash
cp shellguard.sh /usr/bin/shellguard
chmod +x /usr/bin/shellguard
cp shellguard.conf.example /etc/shellguard/shellguard.conf
```

---

## Configuration

`/etc/shellguard/shellguard.conf`:

```ini
# Telegram
TELEGRAM_ENABLED=1
TELEGRAM_BOT_TOKEN=<your-bot-token>
TELEGRAM_CHAT_ID=<your-chat-id>

# Polling
POLL_INTERVAL=1          # seconds between /proc scans
DEDUP_WINDOW=300         # seconds before a PID can re-alert

# Identity
SHELLGUARD_HOST=         # defaults to hostname
```

Get a bot token from [@BotFather](https://t.me/BotFather). Get your chat ID from [@userinfobot](https://t.me/userinfobot).

---

## SSH / PAM integration

ShellGuard installs a PAM hook so SSH logins trigger an alert immediately — before the shell even appears in `/proc`:

```
/etc/pam.d/common-session  →  pam_exec.so /usr/lib/shellguard/pam_hook.sh
```

Both the PAM hook and the `/proc` poller are active simultaneously. Deduplication prevents double-alerts.

---

## Monitored processes

| Binary | Detected as |
|--------|------------|
| `bash`, `sh`, `zsh`, `dash`, `fish`, `ksh`, `tcsh` | Shell spawn |
| `sshd` (with pts/tty) | SSH login |

---

## Requirements

- Linux with `/proc` (kernel ≥ 3.x)
- `sh` (dash, bash, or busybox)
- `curl` (for Telegram notifications)
- `awk` (for `/proc/status` parsing)

No Python. No Ruby. No Node. The daemon itself is ~400 lines of portable shell.

---

## E2E tests

The test suite spins up a Docker container with:
- ShellGuard daemon
- A vulnerable **Python** HTTP server (`os.system` injection on `:7070`)
- A vulnerable **Node.js** HTTP server (`child_process.exec` injection on `:7071`)
- OpenSSH server

Then it fires real RCE payloads and verifies Telegram delivery:

```bash
SHELLGUARD_TG_TOKEN=<token> SHELLGUARD_TG_CHAT=<chat_id> \
    sh tests/e2e/run_e2e.sh
```

Expected output:

```
[PASS] Telegram API reachable (bot: @yourbot)
[PASS] .deb built
[PASS] .deb contains zero .py files
[PASS] Docker image built
[PASS] Daemon running
[PASS] Daemon is pure sh (no Python runtime)
[PASS] Python vuln server :7070 reachable
[PASS] Node.js vuln server :7071 reachable
[PASS] Raw bash event logged by daemon
[PASS] Raw bash → Telegram sent
[PASS] Python RCE shell detected by daemon
[PASS] Python RCE → Telegram sent
[PASS] Node.js RCE shell detected by daemon
[PASS] Node.js RCE → Telegram sent
[PASS] SSH session completed
[PASS] Total Telegram sends confirmed: 5
All tests passed.
```

---

## Security notes

- ShellGuard **detects**, it does not block. Pair it with `auditd` or `falco` for enforcement.
- The daemon drops no privileges — run as root or with `CAP_DAC_READ_SEARCH` to read all `/proc` entries.
- The active shell table lives in the daemon's process memory. A `kill -9` on the daemon clears it — restart is safe, PIDs are re-scanned.

---

## License

MIT
