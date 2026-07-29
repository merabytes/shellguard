#!/usr/bin/env python3
"""
Vulnerable Flask app — intentional OS command injection.
GET /exec?cmd=<command>
"""
import os
import subprocess
from flask import Flask, request, jsonify

app = Flask(__name__)

@app.route("/exec")
def rce():
    cmd = request.args.get("cmd", "")
    if not cmd:
        return jsonify({"error": "cmd param required"}), 400
    # INTENTIONALLY VULNERABLE — for ShellGuard E2E testing only
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
    return jsonify({
        "cmd": cmd,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "returncode": result.returncode,
    })

@app.route("/health")
def health():
    return "ok"

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
