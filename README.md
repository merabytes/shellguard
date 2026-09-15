# ShellGuard

Detects new shells and SSH logins on Linux — including **Synology NAS** — and sends instant **Telegram** alerts with process ancestry.

Pure POSIX `sh`. No Python. No EDR agent required. Just `curl` and `awk`.

**Example alert:**

```
[ShellGuard] Shell Opened
Host: nas-backup
User: admin  |  Shell: bash
Parent: sshd (pid 1234)
Chain: bash(5678) ← sshd(1234)
```

You'll see whether a shell came from SSH, cron, a web app, or somewhere suspicious.

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
