// Vulnerable Express app — intentional OS command injection.
// GET /exec?cmd=<command>
const express = require('express');
const { exec } = require('child_process');
const app = express();

app.get('/exec', (req, res) => {
    const cmd = req.query.cmd;
    if (!cmd) return res.status(400).json({ error: 'cmd param required' });

    // INTENTIONALLY VULNERABLE — for ShellGuard E2E testing only
    exec(cmd, { timeout: 30000 }, (err, stdout, stderr) => {
        res.json({
            cmd,
            stdout: stdout || '',
            stderr: stderr || '',
            returncode: err ? err.code || 1 : 0,
        });
    });
});

app.get('/health', (_, res) => res.send('ok'));

app.listen(8081, '0.0.0.0', () => console.log('vuln_node listening on :8081'));
