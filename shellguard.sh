#!/bin/sh
# shellguard — shell/SSH session alerter
# Zero Python. Runs on BusyBox, Synology NAS, Alpine, Debian, macOS.
# Requires: sh, curl, ca-certificates
#
# Usage: shellguard [-c /path/to/shellguard.conf] [-v]

set -u

# ---------------------------------------------------------------------------
# Defaults (override in shellguard.conf)
# ---------------------------------------------------------------------------
SHELLGUARD_HOST=""
POLL_INTERVAL=2
DEDUP_WINDOW=60
LOG_FILE="/var/log/shellguard.log"
LOG_STDOUT=1

TELEGRAM_ENABLED=0
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
TELEGRAM_TOPIC_ID=""

SLACK_ENABLED=0
SLACK_WEBHOOK_URL=""

WEBHOOK_ENABLED=0
WEBHOOK_URL=""
WEBHOOK_SECRET=""

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
VERBOSE=0
CONFIG_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--config) CONFIG_FILE="$2"; shift ;;
        -v|--verbose) VERBOSE=1 ;;
        *) ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
if [ -z "$CONFIG_FILE" ]; then
    for _p in /etc/shellguard/shellguard.conf \
               "$HOME/.config/shellguard/shellguard.conf" \
               ./shellguard.conf; do
        [ -f "$_p" ] && { CONFIG_FILE=$_p; break; }
    done
fi
[ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

[ -z "$SHELLGUARD_HOST" ] && \
    SHELLGUARD_HOST=$(hostname 2>/dev/null || \
                      cat /proc/sys/kernel/hostname 2>/dev/null || \
                      echo "unknown")

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_log() {
    _lvl=$1; shift
    _msg="$(date '+%Y-%m-%d %H:%M:%S') [${_lvl}] $*"
    [ "$LOG_STDOUT" = "1" ] && printf '%s\n' "$_msg"
    if [ -n "$LOG_FILE" ]; then
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
        printf '%s\n' "$_msg" >> "$LOG_FILE" 2>/dev/null
    fi
}
log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_debug() { [ "$VERBOSE" = "1" ] && _log DEBUG "$@" || true; }

# ---------------------------------------------------------------------------
# Local IPs (cached)
# ---------------------------------------------------------------------------
LOCAL_IPS=""

_get_local_ips() {
    # Try hostname -I (Linux/BusyBox)
    _ips=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^127\.' | tr '\n' '|' | sed 's/|$//')
    [ -n "$_ips" ] && { printf '%s' "$_ips"; return; }
    # Try /proc/net/fib_trie (Linux)
    if [ -f /proc/net/fib_trie ]; then
        _ips=$(awk '/32 host/{getline; if($2 !~ /^127\./) printf "%s|",$2}' \
               /proc/net/fib_trie 2>/dev/null | sed 's/|$//')
        [ -n "$_ips" ] && { printf '%s' "$_ips"; return; }
    fi
    # Try ifconfig (macOS)
    _ips=$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' | tr '\n' '|' | sed 's/|$//')
    printf '%s' "${_ips:-unknown}"
}

ensure_ips() {
    [ -n "$LOCAL_IPS" ] || LOCAL_IPS=$(_get_local_ips)
}

# ---------------------------------------------------------------------------
# Active shells — pure in-memory "array of objects"
# ACTIVE_SHELLS = newline-separated records, fields pipe-delimited:
#   pid|user|ip|tty|comm|ppid|pcomm|start
# Runs entirely in the daemon process — no files, no subshells for core ops.
# ---------------------------------------------------------------------------
ACTIVE_SHELLS=""

# active_add <pid> <user> <ip> <tty> <comm> <ppid> <pcomm>
active_add() {
    _ts=$(date '+%Y-%m-%dT%H:%M:%S')
    ACTIVE_SHELLS="${ACTIVE_SHELLS}$1|$2|$3|$4|$5|$6|$7|${_ts}
"
}

# Purge records whose PID is no longer in /proc (in-place, no subshell)
active_purge() {
    _new=""
    _oifs="$IFS"; IFS="
"
    for _e in $ACTIVE_SHELLS; do
        IFS="$_oifs"
        [ -z "$_e" ] && { IFS="
"; continue; }
        _p="${_e%%|*}"            # extract pid — pure parameter expansion
        [ -d "/proc/$_p" ] && _new="${_new}${_e}
"
        IFS="
"
    done
    IFS="$_oifs"
    ACTIVE_SHELLS="$_new"
}

# Count live shells (purges first)
active_count() {
    active_purge
    [ -z "$ACTIVE_SHELLS" ] && { printf '0'; return; }
    _n=0
    _oifs="$IFS"; IFS="
"
    for _e in $ACTIVE_SHELLS; do
        [ -n "$_e" ] && _n=$(( _n + 1 ))
    done
    IFS="$_oifs"
    printf '%d' "$_n"
}

# ---------------------------------------------------------------------------
# Dedup — per-PID timestamp files in /tmp/.shellguard/seen/
# ---------------------------------------------------------------------------
SEEN_DIR="/tmp/.shellguard/seen"
mkdir -p "$SEEN_DIR" 2>/dev/null

is_seen() {
    _f="$SEEN_DIR/$1"
    [ -f "$_f" ] || return 1
    _ts=$(cat "$_f" 2>/dev/null)
    [ -z "$_ts" ] && return 1
    _age=$(( $(date +%s) - _ts ))
    [ "$_age" -lt "$DEDUP_WINDOW" ]
}

mark_seen() {
    printf '%s\n' "$(date +%s)" > "$SEEN_DIR/$1"
}

cleanup_seen() {
    _now=$(date +%s)
    for _f in "$SEEN_DIR"/*; do
        [ -f "$_f" ] || continue
        _ts=$(cat "$_f" 2>/dev/null)
        [ -z "$_ts" ] && continue
        [ $(( _now - _ts )) -gt $(( DEDUP_WINDOW * 2 )) ] && rm -f "$_f"
    done
}

# ---------------------------------------------------------------------------
# Process helpers (Linux /proc)
# ---------------------------------------------------------------------------
proc_comm() {
    cat "/proc/$1/comm" 2>/dev/null | tr -d '\n'
}

proc_user() {
    _uid=$(stat -c '%u' "/proc/$1" 2>/dev/null) || \
        _uid=$(stat -f '%u' "/proc/$1" 2>/dev/null) || _uid=""
    [ -z "$_uid" ] && { printf 'unknown'; return; }
    _name=$(awk -F: -v u="$_uid" '$3==u{print $1;exit}' /etc/passwd 2>/dev/null)
    printf '%s' "${_name:-$_uid}"
}

proc_tty() {
    _t=$(readlink "/proc/$1/fd/0" 2>/dev/null)
    case "$_t" in
        /dev/pts/*|/dev/tty*) printf '%s' "${_t#/dev/}" ;;
        *) printf '?' ;;
    esac
}

proc_parent() {
    _ppid=$(awk '/^PPid:/{print $2}' "/proc/$1/status" 2>/dev/null)
    if [ -n "$_ppid" ] && [ "$_ppid" -gt 0 ] 2>/dev/null; then
        _pc=$(cat "/proc/$_ppid/comm" 2>/dev/null | tr -d '\n')
        printf '%s %s' "$_ppid" "${_pc:-unknown}"
    else
        printf '0 '
    fi
}

# Walk /proc ancestry up to _maxdepth hops, return chain like:
#   bash(1234) ← python3(1200) ← sshd(800)
proc_ancestry() {
    _pid=$1 _maxdepth=${2:-5}
    _chain="" _cur="$_pid" _depth=0
    # Start from grandparent (parent already shown in Parent: line)
    _cur=$(awk '/^PPid:/{print $2}' "/proc/$_cur/status" 2>/dev/null)
    [ -z "$_cur" ] || [ "$_cur" = "0" ] || [ "$_cur" = "1" ] && { printf ''; return; }
    while [ "$_depth" -lt "$_maxdepth" ]; do
        _ppid=$(awk '/^PPid:/{print $2}' "/proc/$_cur/status" 2>/dev/null)
        [ -z "$_ppid" ] || [ "$_ppid" = "0" ] || [ "$_ppid" = "1" ] && break
        _pc=$(cat "/proc/$_ppid/comm" 2>/dev/null | tr -d '\n')
        [ -z "$_pc" ] && break
        _chain="${_chain} ← ${_pc}(${_ppid})"
        _cur="$_ppid"
        _depth=$(( _depth + 1 ))
    done
    printf '%s' "$_chain"
}

# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------
_curl_post() {
    curl -sf --max-time 10 "$@" > /dev/null 2>&1
}

notify_telegram() {
    [ "$TELEGRAM_ENABLED" = "1" ] || return 0
    [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] || return 1
    _tg_args="--data-urlencode chat_id=${TELEGRAM_CHAT_ID} --data-urlencode text=$1"
    [ -n "${TELEGRAM_TOPIC_ID:-}" ] && \
        _tg_args="$_tg_args --data-urlencode message_thread_id=${TELEGRAM_TOPIC_ID}"
    _curl_post \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        $_tg_args
    _rc=$?
    [ "$_rc" = "0" ] && log_info "[telegram] sent" || log_warn "[telegram] failed (curl rc=$_rc)"
}

notify_slack() {
    [ "$SLACK_ENABLED" = "1" ] || return 0
    [ -n "$SLACK_WEBHOOK_URL" ] || return 1
    _esc=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | \
           awk '{printf "%s\\n",$0}' | sed 's/\\n$//')
    _curl_post "$SLACK_WEBHOOK_URL" \
        -H 'Content-Type: application/json' \
        -d "{\"text\":\"${_esc}\"}"
    _rc=$?
    [ "$_rc" = "0" ] && log_info "[slack] sent" || log_warn "[slack] failed"
}

notify_webhook() {
    [ "$WEBHOOK_ENABLED" = "1" ] || return 0
    [ -n "$WEBHOOK_URL" ] || return 1
    _esc=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | \
           awk '{printf "%s\\n",$0}' | sed 's/\\n$//')
    _curl_post "$WEBHOOK_URL" \
        -H 'Content-Type: application/json' \
        -d "{\"host\":\"${SHELLGUARD_HOST}\",\"text\":\"${_esc}\"}"
    _rc=$?
    [ "$_rc" = "0" ] && log_info "[webhook] sent" || log_warn "[webhook] failed"
}

notify_all() {
    notify_telegram "$1"
    notify_slack    "$1"
    notify_webhook  "$1"
}

# ---------------------------------------------------------------------------
# Build notification text
# ---------------------------------------------------------------------------
build_text() {
    _etype=$1 _pid=$2 _user=$3 _tty=$4 _comm=$5 _ppid=$6 _pcomm=$7 _ancestry=$8
    ensure_ips
    _active=$(active_count)
    if [ "$_etype" = "ssh" ]; then
        printf '[ShellGuard] SSH Login\nHost: %s\nIPs: %s\nUser: %s\nPID: %s | TTY: %s\nActive shells: %s' \
            "$SHELLGUARD_HOST" "$LOCAL_IPS" "$_user" "$_pid" "$_tty" "$_active"
    else
        _out=$(printf '[ShellGuard] Shell Opened\nHost: %s\nIPs: %s\nUser: %s\nShell: %s\nPID: %s | TTY: %s\nActive shells: %s' \
            "$SHELLGUARD_HOST" "$LOCAL_IPS" "$_user" "$_comm" "$_pid" "$_tty" "$_active")
        if [ -n "$_pcomm" ] && [ "$_ppid" != "0" ] 2>/dev/null; then
            _out=$(printf '%s\nParent: %s (pid %s)' "$_out" "$_pcomm" "$_ppid")
        fi
        if [ -n "$_ancestry" ]; then
            _out=$(printf '%s\nChain: %s(pid %s)%s' "$_out" "$_comm" "$_pid" "$_ancestry")
        fi
        printf '%s' "$_out"
    fi
}

# ---------------------------------------------------------------------------
# Dispatch event
# ---------------------------------------------------------------------------
on_event() {
    _etype=$1 _pid=$2
    is_seen "$_pid" && { log_debug "dedup: pid=$_pid"; return; }
    mark_seen "$_pid"

    _user=$(proc_user "$_pid")
    _tty=$(proc_tty "$_pid")
    _comm=$(proc_comm "$_pid")
    _par=$(proc_parent "$_pid")
    _ppid=$(printf '%s' "$_par" | cut -d' ' -f1)
    _pcomm=$(printf '%s' "$_par" | cut -d' ' -f2-)
    _ancestry=$(proc_ancestry "$_pid")
    ensure_ips

    active_add "$_pid" "$_user" "$LOCAL_IPS" "$_tty" "$_comm" "$_ppid" "$_pcomm"

    log_info "Event: type=$_etype pid=$_pid user=$_user comm=$_comm tty=$_tty parent=${_pcomm}(${_ppid})${_ancestry}"
    _msg=$(build_text "$_etype" "$_pid" "$_user" "$_tty" "$_comm" "$_ppid" "$_pcomm" "$_ancestry")
    notify_all "$_msg"
}

# ---------------------------------------------------------------------------
# Polling — /proc/*/comm (Linux) or ps (macOS)
# ---------------------------------------------------------------------------
PREV_PIDS=" "

poll_proc() {
    _curr=" "
    for _cf in /proc/[0-9]*/comm; do
        [ -f "$_cf" ] || continue
        _c=$(cat "$_cf" 2>/dev/null | tr -d '\n')
        _pid=$(printf '%s' "$_cf" | sed 's|/proc/||;s|/comm||')
        case "$_c" in
            bash|sh|zsh|dash|fish|tcsh|ksh|-bash|-sh|-zsh|-dash)
                _etype="shell" ;;
            sshd)
                _t=$(readlink "/proc/$_pid/fd/0" 2>/dev/null)
                case "$_t" in /dev/pts/*|/dev/tty*) _etype="ssh" ;;
                    *) continue ;; esac ;;
            *) continue ;;
        esac
        _curr="$_curr$_pid "
        case "$PREV_PIDS" in
            *" $_pid "*) log_debug "known: pid=$_pid" ;;
            *)
                sleep 0.05 2>/dev/null || true
                on_event "$_etype" "$_pid"
                ;;
        esac
    done
    PREV_PIDS="$_curr"
}

poll_ps() {
    _tmpf="/tmp/.shellguard_ps.$$"
    ps -axo pid=,user=,tty=,comm= 2>/dev/null > "$_tmpf" || { rm -f "$_tmpf"; return; }
    while IFS= read -r _line; do
        set -- $_line
        [ $# -lt 4 ] && continue
        _pid=$1 _user=$2 _tty=$3; shift 3; _comm=$*
        case "$_comm" in
            bash|sh|zsh|dash|fish|tcsh|ksh|-bash|-sh|-zsh|-dash) _etype="shell" ;;
            sshd|ssh)
                case "$_tty" in ?|??) continue ;; esac
                _etype="ssh" ;;
            *) continue ;;
        esac
        case "$PREV_PIDS" in
            *" $_pid "*) log_debug "known: pid=$_pid" ;;
            *) on_event "$_etype" "$_pid" ;;
        esac
    done < "$_tmpf"
    rm -f "$_tmpf"
    # Note: poll_ps doesn't maintain PREV_PIDS — uses is_seen/mark_seen inside on_event
}

if [ -d /proc/1 ]; then POLL_FN=poll_proc; else POLL_FN=poll_ps; fi

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log_info "ShellGuard starting (host=$SHELLGUARD_HOST poll=${POLL_INTERVAL}s dedup=${DEDUP_WINDOW}s)"

trap '
    log_info "Shutting down"
    exit 0
' TERM INT

log_info "Poll loop starting (backend=$POLL_FN)"
_tick=0
while true; do
    $POLL_FN
    _tick=$(( _tick + 1 ))
    if [ "$_tick" -ge 300 ]; then
        cleanup_seen
        active_purge
        _tick=0
    fi
    log_debug "active shells: $(active_count)"
    sleep "$POLL_INTERVAL"
done
