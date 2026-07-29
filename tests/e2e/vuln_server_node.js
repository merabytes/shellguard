// Vulnerable Node.js HTTP server — child_process.exec RCE.
// GET /ping?host=<cmd>  →  exec("ping -c1 " + host)
// ShellGuard should detect the /bin/sh spawned by exec().
const http = require('http');
const { URL } = require('url');
const { exec } = require('child_process');

http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const host = url.searchParams.get('host') || '';

  res.writeHead(200);

  if (host) {
    // VULNERABLE: unsanitized input passed to shell
    exec('ping -c1 ' + host, (err, stdout, stderr) => {
      res.end('exit=' + (err ? err.code : 0) + '\n');
    });
  } else {
    res.end('ok\n');
  }
}).listen(7071, '0.0.0.0', () => {
  process.stdout.write('vuln-node listening :7071\n');
});
