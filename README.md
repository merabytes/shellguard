# ShellGuard

Detects new shells and SSH logins on Linux — including **Synology NAS** — and sends instant **Telegram** alerts with **process ancestry**.

Pure POSIX `sh`. No Python. No EDR agent required. Just `curl` and `awk`.

## Contents

- [What it does](#what-it-does)
- [Parent & ancestry](#parent--ancestry)
- [Install — Synology NAS](#install--synology-nas)
- [Install — Debian / Ubuntu](#install--debian--ubuntu)
- [Configuration](#configuration)
- [License](#license)

---

## What it does

ShellGuard polls `/proc` for new interactive shells and SSH sessions. Each alert includes:

- **Host** and **IPs**
- **User**, **shell**, **PID**, **TTY**
- **Parent process** — what spawned the shell
- **Ancestry chain** — full path from the shell up to its origin

**Example alert:**

```
[ShellGuard] Shell Opened
Host: nas-backup
IPs: 10.0.1.5
User: www-data  |  Shell: sh
PID: 4821  |  TTY: ?  |  Active shells: 2
Parent: python3 (pid 4800)
Chain: sh(4821) ← python3(4800) ← apache2(4750)
```

Most shell monitors tell you *that* a shell spawned. ShellGuard tells you *why*.

---

## Parent & ancestry

| Chain | What happened |
|-------|---------------|
| `bash ← sshd` | Normal SSH login |
| `sh ← python3 ← gunicorn` | RCE via Python web app (`os.system`) |
| `dash ← sh ← node` | RCE via Node.js (`child_process.exec`) |
| `bash ← crond` | Cron job — probably fine |
| `sh ← (unknown)` | Suspicious — investigate |

If your app gets pwned and the attacker drops a shell, you'll see the full chain within a second — not just "someone ran bash".

---

## Install — Synology NAS

SSH as `root` and run:

```bash
curl -fsSL https://raw.githubusercontent.com/merabytes/shellguard/main/scripts/install-synology.sh | sudo sh
```

You'll be prompted for your Telegram **bot token**, **chat ID**, and optional **topic ID** (for forum groups).

Non-interactive:

```bash
curl -fsSL https://raw.githubusercontent.com/merabytes/shellguard/main/scripts/install-synology.sh | \
  sudo SHELLGUARD_TG_TOKEN='YOUR_BOT_TOKEN' \
       SHELLGUARD_TG_CHAT='-1001234567890' \
       SHELLGUARD_TG_TOPIC='42' \
       sh
```

Reconfigure or restart:

```bash
sudo shellguard-configure --start
sudo /usr/local/etc/rc.d/S99shellguard status
tail -f /var/log/shellguard.log
```

**Telegram setup:** create a bot with [@BotFather](https://t.me/BotFather). Add it to your group/channel as admin. Get the chat ID from [@userinfobot](https://t.me/userinfobot) or `getUpdates`. For forum topics, use the topic number from the Telegram URL.

---

## Install — Debian / Ubuntu

Same one-liner — works on any host with `dpkg`:

```bash
curl -fsSL https://raw.githubusercontent.com/merabytes/shellguard/main/scripts/install-synology.sh | sudo sh
```

Manual `.deb` install: grab `shellguard_*_all.deb` and `SHA256SUMS` from [Releases](https://github.com/merabytes/shellguard/releases), then:

```bash
sha256sum -c SHA256SUMS
sudo dpkg --no-debsig --force-all -i shellguard_*_all.deb
sudo shellguard-configure --start
```

---

## Configuration

Config file: `/etc/shellguard/shellguard.conf`

```sh
TELEGRAM_ENABLED=1
TELEGRAM_BOT_TOKEN=123456789:AAF...
TELEGRAM_CHAT_ID=-1001234567890
TELEGRAM_TOPIC_ID=42          # optional, forum topics
```

---

## License

MIT
