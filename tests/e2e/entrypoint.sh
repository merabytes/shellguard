#!/bin/sh
set -e

echo "[entrypoint] Starting ShellGuard daemon..."
/usr/bin/shellguard -c /etc/shellguard/shellguard.conf -v &
DAEMON_PID=$!
echo "[entrypoint] ShellGuard PID=$DAEMON_PID"
sleep 1

echo "[entrypoint] Starting vuln Python server (:7070)..."
python3 /opt/vuln_server_python.py &
sleep 1

echo "[entrypoint] Starting vuln Node.js server (:7071)..."
node /opt/vuln_server_node.js &
sleep 1

echo "[entrypoint] Starting sshd..."
exec /usr/sbin/sshd -D -e
