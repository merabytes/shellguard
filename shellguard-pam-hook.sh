#!/bin/sh
# shellguard-pam-hook — called by PAM (pam_exec.so) on session open/close
#
# /etc/pam.d/sshd (add):
#   session optional pam_exec.so /usr/local/bin/shellguard-pam-hook
#
# /etc/pam.d/login (add):
#   session optional pam_exec.so /usr/local/bin/shellguard-pam-hook
#
# PAM_TYPE is "open_session" or "close_session"
# PAM_USER, PAM_TTY, PAM_RHOST are set by PAM.

[ "$PAM_TYPE" = "open_session" ] || exit 0

# Load config
CONFIG_FILE="${SHELLGUARD_CONF:-/etc/shellguard/shellguard.conf}"
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
else
    # Minimal fallback — edit these directly if no config file
    TELEGRAM_ENABLED=${TELEGRAM_ENABLED:-0}
    TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-""}
    TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-""}
fi

HOST=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo "unknown")
HOST=${SHELLGUARD_HOST:-$HOST}

# Build message
TYPE="Shell"
[ "$PAM_SERVICE" = "sshd" ] && TYPE="SSH Login"

MSG="[ShellGuard] PAM: $TYPE
Host: $HOST
User: ${PAM_USER:-unknown}
TTY: ${PAM_TTY:-unknown}
Service: ${PAM_SERVICE:-unknown}"

[ -n "$PAM_RHOST" ] && MSG="${MSG}
From: $PAM_RHOST"

# Notify
if [ "$TELEGRAM_ENABLED" = "1" ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
    curl -sf --max-time 10 \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${MSG}" > /dev/null 2>&1 &
fi

if [ "$SLACK_ENABLED" = "1" ] && [ -n "$SLACK_WEBHOOK_URL" ]; then
    _esc=$(printf '%s' "$MSG" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n",$0}' | sed 's/\\n$//')
    curl -sf --max-time 10 "$SLACK_WEBHOOK_URL" \
        -H 'Content-Type: application/json' \
        -d "{\"text\":\"${_esc}\"}" > /dev/null 2>&1 &
fi

if [ "$WEBHOOK_ENABLED" = "1" ] && [ -n "$WEBHOOK_URL" ]; then
    _esc=$(printf '%s' "$MSG" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n",$0}' | sed 's/\\n$//')
    curl -sf --max-time 10 "$WEBHOOK_URL" \
        -H 'Content-Type: application/json' \
        -d "{\"host\":\"${HOST}\",\"text\":\"${_esc}\"}" > /dev/null 2>&1 &
fi

exit 0
