#!/bin/sh
# Build shellguard .deb — pure sh, no Python
set -e

VERSION="0.2.0"
SRCDIR="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="$SRCDIR/dist"
mkdir -p "$OUTDIR"

docker run --rm \
    -v "$SRCDIR:/src" \
    -v "$OUTDIR:/dist" \
    debian:12-slim \
    sh -c '
set -e
apt-get update -qq && apt-get install -y -qq dpkg 2>/dev/null

PKGDIR=/tmp/deb_build
cp -r /src/packaging/deb "$PKGDIR"

# Main daemon script → /usr/bin/shellguard
mkdir -p "$PKGDIR/usr/bin"
cp /src/shellguard.sh "$PKGDIR/usr/bin/shellguard"
chmod 755 "$PKGDIR/usr/bin/shellguard"

# PAM hook → /usr/lib/shellguard/pam_hook.sh
mkdir -p "$PKGDIR/usr/lib/shellguard"
cp /src/shellguard-pam-hook.sh "$PKGDIR/usr/lib/shellguard/pam_hook.sh"
chmod 755 "$PKGDIR/usr/lib/shellguard/pam_hook.sh"

# Config example → /etc/shellguard/
mkdir -p "$PKGDIR/etc/shellguard"
cp /src/config/shellguard.conf "$PKGDIR/etc/shellguard/shellguard.conf.example"

chmod 755 "$PKGDIR/DEBIAN/postinst"
chmod 755 "$PKGDIR/DEBIAN/prerm"

dpkg-deb --build "$PKGDIR" "/dist/shellguard_'"$VERSION"'_all.deb"
echo "Built: shellguard_'"$VERSION"'_all.deb"
'
