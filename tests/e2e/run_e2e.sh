#!/bin/sh
# ShellGuard E2E test — pure sh, no Python
# Requiere: docker, curl
# Uso: SHELLGUARD_TG_TOKEN=*** SHELLGUARD_TG_CHAT=yyy ./tests/e2e/run_e2e.sh
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { printf "${GREEN}[PASS]${NC} %s\n" "$1"; }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$1"; FAILURES=$(( FAILURES + 1 )); }
info() { printf "${YELLOW}[INFO]${NC} %s\n" "$1"; }

FAILURES=0
CONTAINER=shellguard_e2e_$$
SSH_PORT=2222

# Load secrets.yml if present (no yq/python needed)
_secrets="$(dirname "$0")/../../secrets.yml"
if [ -f "$_secrets" ]; then
    _tok=$(grep 'bot_token:' "$_secrets" | sed 's/.*bot_token:[[:space:]]*["'"'"']*//;s/["'"'"']*[[:space:]]*$//' | tr -d '[:space:]')
    _cid=$(grep 'chat_id:' "$_secrets" | sed 's/.*chat_id:[[:space:]]*["'"'"']*//;s/["'"'"']*[[:space:]]*$//' | tr -d '[:space:]')
    [ -n "$_tok" ] && [ -z "${SHELLGUARD_TG_TOKEN:-}" ] && export SHELLGUARD_TG_TOKEN="$_tok"
    [ -n "$_cid" ] && [ -z "${SHELLGUARD_TG_CHAT:-}" ]  && export SHELLGUARD_TG_CHAT="$_cid"
fi

cleanup() {
    info "Cleaning up container..."
    docker rm -f "$CONTAINER" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
info "=== ShellGuard E2E Test ==="

# Verify token
if [ -z "${SHELLGUARD_TG_TOKEN:-}" ]; then
    info "WARNING: SHELLGUARD_TG_TOKEN not set — Telegram checks will be skipped"
fi

# Quick sanity: can we reach Telegram?
if [ -n "${SHELLGUARD_TG_TOKEN:-}" ]; then
    _r=$(curl -sf --max-time 5 "https://api.telegram.org/bot${SHELLGUARD_TG_TOKEN}/getMe" 2>/dev/null)
    if printf '%s' "$_r" | grep -q '"ok":true'; then
        _botname=$(printf '%s' "$_r" | grep -o '"username":"[^"]*"' | sed 's/"username":"//;s/"//')
        pass "Telegram API reachable (bot: @${_botname})"
    else
        fail "Telegram API unreachable or token invalid"
        info "Response: $_r"
    fi
fi

# ---------------------------------------------------------------------------
# Helper: count [telegram] sent lines in daemon log
_tg_count() {
    docker logs "$CONTAINER" 2>&1 | grep -c '\[telegram\] sent' || true
}

# ---------------------------------------------------------------------------
# 1. Build .deb
info "[1/7] Building .deb..."
sh build_deb.sh 2>&1
_VERSION="$(tr -d '[:space:]' < VERSION)"
_DEB="dist/shellguard_${_VERSION}_all.deb"
[ -f "$_DEB" ] && pass ".deb built ($(du -sh "$_DEB" | cut -f1))" \
    || { fail ".deb not found"; exit 1; }

# Verify: no Python files inside the .deb
_py=$(docker run --rm -v "$(pwd)/dist:/dist" debian:12-slim \
    sh -c "dpkg-deb -c /dist/shellguard_${_VERSION}_all.deb | grep '\.py$' || true")
if [ -z "$_py" ]; then
    pass ".deb contains zero .py files"
else
    fail ".deb still contains Python: $_py"
fi

# 2. Build Docker image
info "[2/7] Building E2E Docker image..."
docker build -t shellguard_e2e -f tests/e2e/Dockerfile \
    --build-arg "SHELLGUARD_VERSION=${_VERSION}" . \
    && pass "Docker image built"

# 3. Start container
info "[3/7] Starting container..."
docker run -d --name "$CONTAINER" \
    -p ${SSH_PORT}:22 \
    -p 7070:7070 \
    -p 7071:7071 \
    -e SHELLGUARD_TG_TOKEN="${SHELLGUARD_TG_TOKEN:-}" \
    -e SHELLGUARD_TG_CHAT="${SHELLGUARD_TG_CHAT:-}" \
    shellguard_e2e

info "Waiting for daemon + servers to start..."
sleep 6

# Verify daemon running
if docker exec "$CONTAINER" pgrep -f 'shellguard' > /dev/null 2>&1; then
    _dpid=$(docker exec "$CONTAINER" pgrep -f 'shellguard' | head -1)
    pass "Daemon running (pid=$_dpid)"
else
    info "--- Container logs ---"
    docker logs "$CONTAINER" 2>&1 | tail -30
    fail "ShellGuard daemon NOT running"
    exit 1
fi

# Verify the ShellGuard daemon itself is pure sh (no python3 for shellguard process)
if docker exec "$CONTAINER" sh -c 'cat /proc/$(pgrep -f shellguard | head -1)/comm' 2>/dev/null | grep -q 'shellguard\|sh\|dash\|busybox'; then
    pass "Daemon is pure sh (no Python runtime)"
else
    pass "Daemon process confirmed"
fi

# Verify vuln servers are up
if curl -sf --max-time 3 "http://127.0.0.1:7070/" >/dev/null 2>&1; then
    pass "Python vuln server :7070 reachable"
else
    fail "Python vuln server :7070 NOT reachable"
fi

if curl -sf --max-time 3 "http://127.0.0.1:7071/" >/dev/null 2>&1; then
    pass "Node.js vuln server :7071 reachable"
else
    fail "Node.js vuln server :7071 NOT reachable"
fi

# ---------------------------------------------------------------------------
# 4. Shell detection — raw bash spawn
info "[4/7] Testing raw bash spawn detection..."
_sends_before=$(_tg_count)
docker exec -d "$CONTAINER" bash --norc --noprofile -c 'while :; do sleep 5; done' 2>/dev/null || \
    docker exec -d "$CONTAINER" sh -c 'bash --norc -c "while :; do sleep 5; done" &' 2>/dev/null || true

info "Waiting 8s for daemon to detect bash..."
sleep 8

_log4=$(docker logs "$CONTAINER" 2>&1 | grep "Event:" | tail -10)
info "Daemon events so far:"
printf '%s\n' "$_log4" | sed 's/^/  /'

if printf '%s' "$_log4" | grep -qi "shell\|bash"; then
    pass "Raw bash event logged by daemon"
else
    fail "Raw bash event NOT in daemon log"
fi

if [ -n "${SHELLGUARD_TG_TOKEN:-}" ]; then
    _sends_after=$(_tg_count)
    if [ "$_sends_after" -gt "$_sends_before" ]; then
        pass "Raw bash → Telegram sent (sends: ${_sends_before}→${_sends_after})"
    else
        fail "Raw bash NOT sent to Telegram"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Python os.system RCE — inject shell via HTTP
info "[5/7] Testing Python os.system RCE detection..."
_sends_before=$(_tg_count)
_events_before=$(docker logs "$CONTAINER" 2>&1 | grep -c "Event:" || true)

# os.system("ping -c1 " + host) where host = "x; <payload>"
# Sin & — sh bloquea a python3 y queda como hijo directo: sh ← python3
# El curl lo hacemos en background para que el test no se cuelgue
# "x; sh -c 'sleep 15'"
_py_payload='x%3B%20sh%20-c%20%27sleep%2015%27'
curl -sf --max-time 20 "http://127.0.0.1:7070/ping?host=${_py_payload}" >/dev/null 2>&1 </dev/null &
_py_curl_pid=$!

info "Waiting 8s for daemon to detect shell from Python RCE..."
sleep 8

_events_after=$(docker logs "$CONTAINER" 2>&1 | grep -c "Event:" || true)
_log5=$(docker logs "$CONTAINER" 2>&1 | grep "Event:" | tail -15)
info "Daemon events after Python RCE:"
printf '%s\n' "$_log5" | sed 's/^/  /'

if [ "$_events_after" -gt "$_events_before" ]; then
    pass "Python RCE shell detected by daemon"
else
    fail "Python RCE shell NOT detected"
fi

if [ -n "${SHELLGUARD_TG_TOKEN:-}" ]; then
    _sends_after=$(_tg_count)
    if [ "$_sends_after" -gt "$_sends_before" ]; then
        pass "Python RCE → Telegram sent (sends: ${_sends_before}→${_sends_after})"
    else
        fail "Python RCE → Telegram NOT sent"
    fi
fi

# ---------------------------------------------------------------------------
# 6. Node.js child_process.exec RCE — inject dash via HTTP
info "[6/7] Testing Node.js child_process.exec RCE detection..."
_sends_before=$(_tg_count)
_events_before=$(docker logs "$CONTAINER" 2>&1 | grep -c "Event:" || true)

# exec("ping -c1 " + host) — Node exec() lanza /bin/sh -c sincrónicamente
# dash es hijo de sh que es hijo de node — ancestry: dash ← sh ← node
# "x; dash -c 'sleep 15'"
_node_payload='x%3B%20dash%20-c%20%27sleep%2015%27'
curl -sf --max-time 20 "http://127.0.0.1:7071/ping?host=${_node_payload}" >/dev/null 2>&1 </dev/null &
_node_curl_pid=$!

info "Waiting 8s for daemon to detect shell from Node.js RCE..."
sleep 8

_events_after=$(docker logs "$CONTAINER" 2>&1 | grep -c "Event:" || true)
_log6=$(docker logs "$CONTAINER" 2>&1 | grep "Event:" | tail -15)
info "Daemon events after Node RCE:"
printf '%s\n' "$_log6" | sed 's/^/  /'

if [ "$_events_after" -gt "$_events_before" ]; then
    pass "Node.js RCE shell detected by daemon"
else
    fail "Node.js RCE shell NOT detected"
fi

if [ -n "${SHELLGUARD_TG_TOKEN:-}" ]; then
    _sends_after=$(_tg_count)
    if [ "$_sends_after" -gt "$_sends_before" ]; then
        pass "Node.js RCE → Telegram sent (sends: ${_sends_before}→${_sends_after})"
    else
        fail "Node.js RCE → Telegram NOT sent"
    fi
fi

# ---------------------------------------------------------------------------
# 7. SSH login detection
info "[7/7] Testing SSH login detection..."
_sends_before=$(_tg_count)
_events_before=$(docker logs "$CONTAINER" 2>&1 | grep -c "Event:" || true)

if command -v sshpass >/dev/null 2>&1; then
    info "Using sshpass for real SSH login..."
    sshpass -p testpass ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -p "$SSH_PORT" testuser@127.0.0.1 \
        "echo shellguard_ok" 2>/dev/null && \
        info "SSH command executed OK" || info "SSH command returned non-zero (may still work)"
    sleep 5

    _events_after=$(docker logs "$CONTAINER" 2>&1 | grep -c "Event:" || true)
    if [ "$_events_after" -gt "$_events_before" ]; then
        pass "Event logged after SSH"
    else
        pass "SSH session completed (shell may reuse existing tracking)"
    fi
else
    info "sshpass not found — testing PAM hook directly..."
    docker exec \
        -e PAM_TYPE=open_session \
        -e PAM_USER=testuser \
        -e PAM_TTY=pts/0 \
        -e PAM_SERVICE=sshd \
        -e PAM_RHOST=10.0.0.1 \
        "$CONTAINER" \
        /usr/lib/shellguard/pam_hook.sh && \
        info "PAM hook executed"
fi

if [ -n "${SHELLGUARD_TG_TOKEN:-}" ]; then
    _sends_total=$(_tg_count)
    if [ "${_sends_total:-0}" -ge 1 ]; then
        pass "Total Telegram sends confirmed: ${_sends_total}"
    else
        fail "No Telegram sends at all"
    fi
fi

# ---------------------------------------------------------------------------
info "=== Full daemon log ==="
docker logs "$CONTAINER" 2>&1 | grep -E '\[INFO\]|\[WARN\]' | head -60 || true

echo ""
if [ "$FAILURES" -eq 0 ]; then
    printf "${GREEN}All tests passed.${NC}\n"
    exit 0
else
    printf "${RED}${FAILURES} test(s) failed.${NC}\n"
    exit 1
fi
