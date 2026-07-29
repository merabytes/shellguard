#!/usr/bin/env python3
"""
Vulnerable Python HTTP server — os.system RCE.
GET /ping?host=<cmd>   → os.system("ping -c1 " + host)
ShellGuard should detect the bash spawned by the shell injection.
"""
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # silence access log

    def do_GET(self):
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)
        host = params.get("host", [""])[0]

        self.send_response(200)
        self.end_headers()

        if host:
            # VULNERABLE: unsanitized input passed to shell
            ret = os.system("ping -c1 " + host)
            self.wfile.write(f"exit={ret}\n".encode())
        else:
            self.wfile.write(b"ok\n")

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 7070), Handler)
    print("vuln-python listening :7070", flush=True)
    server.serve_forever()
