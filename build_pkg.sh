#!/bin/bash
set -e

VERSION="0.1.0"
IDENTIFIER="com.merabytes.shellguard"
SRCDIR="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="$SRCDIR/dist"
PKGROOT="$SRCDIR/packaging/pkg/root"
SCRIPTS="$SRCDIR/packaging/pkg/scripts"

mkdir -p "$OUTDIR" "$PKGROOT/Library/Application Support/shellguard" \
         "$PKGROOT/etc/shellguard" \
         "$PKGROOT/Library/LaunchDaemons" \
         "$SCRIPTS"

# Python source
cp -r "$SRCDIR/shellguard/"*.py "$PKGROOT/Library/Application Support/shellguard/"

# Config example
cp "$SRCDIR/config/shellguard.conf" "$PKGROOT/etc/shellguard/shellguard.conf.example"

# launchd plist
cat > "$PKGROOT/Library/LaunchDaemons/${IDENTIFIER}.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${IDENTIFIER}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>/Library/Application Support/shellguard/daemon.py</string>
    <string>-c</string>
    <string>/etc/shellguard/shellguard.conf</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/var/log/shellguard.log</string>
  <key>StandardErrorPath</key>
  <string>/var/log/shellguard.log</string>
</dict>
</plist>
EOF

# postinstall script
cat > "$SCRIPTS/postinstall" << 'SCRIPT'
#!/bin/bash
set -e
CONF=/etc/shellguard/shellguard.conf
if [ ! -f "$CONF" ]; then
    cp /etc/shellguard/shellguard.conf.example "$CONF"
fi
chmod +x "/Library/Application Support/shellguard/pam_hook.py"

# PAM hook for macOS (su, login, sshd)
for PAM_FILE in /etc/pam.d/sshd /etc/pam.d/login /etc/pam.d/su; do
    [ -f "$PAM_FILE" ] || continue
    LINE="session optional pam_exec.so /Library/Application Support/shellguard/pam_hook.py"
    grep -qF "shellguard" "$PAM_FILE" || echo "$LINE" >> "$PAM_FILE"
done

launchctl load -w /Library/LaunchDaemons/com.merabytes.shellguard.plist || true
SCRIPT
chmod +x "$SCRIPTS/postinstall"

# preremove script
cat > "$SCRIPTS/preinstall" << 'SCRIPT'
#!/bin/bash
launchctl unload /Library/LaunchDaemons/com.merabytes.shellguard.plist 2>/dev/null || true
SCRIPT
chmod +x "$SCRIPTS/preinstall"

# Build pkg
pkgbuild \
    --root "$PKGROOT" \
    --scripts "$SCRIPTS" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location "/" \
    "$OUTDIR/shellguard_${VERSION}.pkg"

echo "Built: $OUTDIR/shellguard_${VERSION}.pkg"
