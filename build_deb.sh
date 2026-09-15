#!/bin/sh
# Build shellguard packages for multiple distros
# Outputs:
#   dist/shellguard_<VERSION>_<distro>_all.deb  (Debian/Ubuntu)
#   dist/shellguard-<VERSION>.tar.gz             (universal tarball — RPM/APK/manual)
#   dist/shellguard-<VERSION>-1.noarch.rpm       (if rpmbuild available)
# Usage: sh build_deb.sh [--deb-only] [--with-rpm]
set -e

if [ -n "${VERSION:-}" ]; then
    :
elif [ -f "$(dirname "$0")/VERSION" ]; then
    VERSION="$(tr -d '[:space:]' < "$(dirname "$0")/VERSION")"
else
    VERSION="0.2.0"
fi
SRCDIR="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="$SRCDIR/dist"
mkdir -p "$OUTDIR"

DEB_ONLY=0
WITH_RPM=0
for arg in "$@"; do
    case "$arg" in
        --deb-only)  DEB_ONLY=1 ;;
        --with-rpm)  WITH_RPM=1 ;;
    esac
done

# ── DEB targets (uses locally cached Docker images — no pull needed) ──────────
# Add/remove lines here as images become available
DEB_TARGETS="
debian:12-slim     debian12-bookworm
debian:bookworm    debian12-bookworm-full
ubuntu:latest      ubuntu-latest
"

build_deb() {
    IMAGE="$1"
    LABEL="$2"
    OUTFILE="shellguard_${VERSION}_${LABEL}_all.deb"
    echo "==> .deb  [$LABEL]  ($IMAGE)"

    docker run --rm --network none \
        -v "$SRCDIR:/src:ro" \
        -v "$OUTDIR:/dist" \
        "$IMAGE" \
        sh -c "
set -e

PKGDIR=/tmp/deb_build
cp -r /src/packaging/deb \"\$PKGDIR\"

mkdir -p \"\$PKGDIR/usr/bin\"
cp /src/shellguard.sh \"\$PKGDIR/usr/bin/shellguard\"
chmod 755 \"\$PKGDIR/usr/bin/shellguard\"

mkdir -p \"\$PKGDIR/usr/lib/shellguard\"
cp /src/shellguard-pam-hook.sh \"\$PKGDIR/usr/lib/shellguard/pam_hook.sh\"
cp /src/scripts/configure.sh \"\$PKGDIR/usr/lib/shellguard/configure.sh\"
cp /src/packaging/synology/S99shellguard \"\$PKGDIR/usr/lib/shellguard/synology-rc\"
chmod 755 \"\$PKGDIR/usr/lib/shellguard/pam_hook.sh\"
chmod 755 \"\$PKGDIR/usr/lib/shellguard/configure.sh\"
chmod 755 \"\$PKGDIR/usr/lib/shellguard/synology-rc\"
cp /src/scripts/configure.sh \"\$PKGDIR/usr/bin/shellguard-configure\"
chmod 755 \"\$PKGDIR/usr/bin/shellguard-configure\"

mkdir -p \"\$PKGDIR/etc/shellguard\"
cp /src/config/shellguard.conf \"\$PKGDIR/etc/shellguard/shellguard.conf.example\"

chmod 755 \"\$PKGDIR/DEBIAN/postinst\" \"\$PKGDIR/DEBIAN/prerm\"
sed -i 's/^Version:.*/Version: $VERSION/' \"\$PKGDIR/DEBIAN/control\"

dpkg-deb --build \"\$PKGDIR\" \"/dist/$OUTFILE\"
echo \"Built: $OUTFILE\"
"
}

# ── Universal tarball (source for RPM/APK/manual install) ────────────────────
build_tarball() {
    echo "==> .tar.gz  [universal]"
    TARNAME="shellguard-${VERSION}"
    TMPDIR="/tmp/${TARNAME}"

    rm -rf "$TMPDIR"
    mkdir -p "$TMPDIR/usr/bin"
    mkdir -p "$TMPDIR/usr/lib/shellguard"
    mkdir -p "$TMPDIR/etc/shellguard"
    mkdir -p "$TMPDIR/lib/systemd/system"

    cp "$SRCDIR/shellguard.sh"            "$TMPDIR/usr/bin/shellguard"
    cp "$SRCDIR/shellguard-pam-hook.sh"   "$TMPDIR/usr/lib/shellguard/pam_hook.sh"
    cp "$SRCDIR/config/shellguard.conf"   "$TMPDIR/etc/shellguard/shellguard.conf.example"
    cp "$SRCDIR/packaging/deb/lib/systemd/system/shellguard.service" \
       "$TMPDIR/lib/systemd/system/shellguard.service"
    cp "$SRCDIR/packaging/install.sh"     "$TMPDIR/install.sh" 2>/dev/null || true

    chmod 755 "$TMPDIR/usr/bin/shellguard"
    chmod 755 "$TMPDIR/usr/lib/shellguard/pam_hook.sh"

    tar -czf "$OUTDIR/${TARNAME}.tar.gz" -C /tmp "$TARNAME"
    rm -rf "$TMPDIR"
    echo "Built: ${TARNAME}.tar.gz"
}

# ── RPM (requires rpmbuild — via --with-rpm flag or auto-detected) ────────────
build_rpm() {
    if ! command -v rpmbuild >/dev/null 2>&1; then
        echo "==> .rpm  [SKIP — rpmbuild not found, use tarball + fpm or build on RHEL host]"
        return 0
    fi
    echo "==> .rpm  [noarch]"
    TARNAME="shellguard-${VERSION}"

    # Setup tree
    RPMROOT="$OUTDIR/_rpmbuild"
    rm -rf "$RPMROOT"
    mkdir -p "$RPMROOT"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

    # Source tarball
    cp "$OUTDIR/${TARNAME}.tar.gz" "$RPMROOT/SOURCES/"

    cat > "$RPMROOT/SPECS/shellguard.spec" << SPECEOF
Name:           shellguard
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        Shell and SSH session alerting daemon (pure sh)
License:        MIT
URL:            https://github.com/merabytes/shellguard
Source0:        shellguard-${VERSION}.tar.gz
BuildArch:      noarch
Requires:       curl

%description
ShellGuard monitors /proc for new interactive shells and SSH logins and sends
real-time Telegram alerts with process ancestry. Pure POSIX sh, no Python.

%prep
%setup -q

%install
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/lib/shellguard
mkdir -p %{buildroot}/etc/shellguard
mkdir -p %{buildroot}/lib/systemd/system
install -m 755 usr/bin/shellguard                    %{buildroot}/usr/bin/shellguard
install -m 755 usr/lib/shellguard/pam_hook.sh        %{buildroot}/usr/lib/shellguard/pam_hook.sh
install -m 644 etc/shellguard/shellguard.conf.example %{buildroot}/etc/shellguard/shellguard.conf.example
install -m 644 lib/systemd/system/shellguard.service  %{buildroot}/lib/systemd/system/shellguard.service

%post
[ ! -f /etc/shellguard/shellguard.conf ] && cp /etc/shellguard/shellguard.conf.example /etc/shellguard/shellguard.conf || true
PAM_LINE="session optional pam_exec.so /usr/lib/shellguard/pam_hook.sh"
for f in /etc/pam.d/sshd /etc/pam.d/login /etc/pam.d/system-auth; do
    [ -f "\$f" ] && ! grep -qF shellguard "\$f" && echo "\$PAM_LINE" >> "\$f" || true
done
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload && systemctl enable --now shellguard.service || true

%preun
if [ \$1 -eq 0 ]; then
    command -v systemctl >/dev/null 2>&1 && systemctl disable --now shellguard.service 2>/dev/null || true
    for f in /etc/pam.d/sshd /etc/pam.d/login /etc/pam.d/system-auth; do
        [ -f "\$f" ] && sed -i '/shellguard/d' "\$f" || true
    done
fi

%files
/usr/bin/shellguard
/usr/lib/shellguard/pam_hook.sh
%config(noreplace) /etc/shellguard/shellguard.conf.example
/lib/systemd/system/shellguard.service
SPECEOF

    rpmbuild --define "_topdir $RPMROOT" -bb "$RPMROOT/SPECS/shellguard.spec"
    find "$RPMROOT/RPMS" -name '*.rpm' -exec cp {} "$OUTDIR/" \;
    rm -rf "$RPMROOT"
    echo "Built: shellguard-${VERSION}-1.noarch.rpm"
}

# ── APK (Alpine — requires abuild, best done on Alpine host/CI) ───────────────
build_apk() {
    # Generate the APKBUILD for reference; actual build needs Alpine host
    mkdir -p "$SRCDIR/packaging/apk"
    cat > "$SRCDIR/packaging/apk/APKBUILD" << APKEOF
# Maintainer: ShellGuard <shellguard@merabytes.com>
pkgname=shellguard
pkgver=${VERSION}
pkgrel=0
pkgdesc="Shell and SSH session alerting daemon (pure sh)"
url="https://github.com/merabytes/shellguard"
arch="noarch"
license="MIT"
depends="curl"
source="shellguard-\${pkgver}.tar.gz"
builddir="\$srcdir/shellguard-\${pkgver}"

package() {
    install -Dm755 "\$builddir/usr/bin/shellguard"                 "\$pkgdir/usr/bin/shellguard"
    install -Dm755 "\$builddir/usr/lib/shellguard/pam_hook.sh"     "\$pkgdir/usr/lib/shellguard/pam_hook.sh"
    install -Dm644 "\$builddir/etc/shellguard/shellguard.conf.example" "\$pkgdir/etc/shellguard/shellguard.conf.example"
    install -Dm644 "\$builddir/lib/systemd/system/shellguard.service"  "\$pkgdir/lib/systemd/system/shellguard.service"
}

post_install() {
    [ ! -f /etc/shellguard/shellguard.conf ] && cp /etc/shellguard/shellguard.conf.example /etc/shellguard/shellguard.conf || true
}
APKEOF
    echo "==> .apk  APKBUILD generado en packaging/apk/APKBUILD (build en Alpine host con: abuild -r)"
}

# ── Run all builds ────────────────────────────────────────────────────────────

CANONICAL_LABEL="debian12-bookworm"
CANONICAL_DEB="shellguard_${VERSION}_all.deb"

# .deb para cada distro
printf '%s\n' "$DEB_TARGETS" | while IFS= read -r line; do
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
    [ -z "$line" ] && continue
    IMAGE="$(printf '%s' "$line" | awk '{print $1}')"
    LABEL="$(printf '%s' "$line" | awk '{print $2}')"
    build_deb "$IMAGE" "$LABEL"
done

# Canonical noarch package (Synology, curl one-liners, README)
if [ -f "$OUTDIR/shellguard_${VERSION}_${CANONICAL_LABEL}_all.deb" ]; then
    cp "$OUTDIR/shellguard_${VERSION}_${CANONICAL_LABEL}_all.deb" "$OUTDIR/$CANONICAL_DEB"
    echo "Canonical: $CANONICAL_DEB"
fi

if [ "$DEB_ONLY" = "1" ]; then
    echo ""
    echo "── Packages built ──────────────────────────────────────────"
    ls -lh "$OUTDIR"/*.deb 2>/dev/null | awk '{print $5, $9}'
    exit 0
fi

# Universal tarball
build_tarball

# RPM (si --with-rpm o rpmbuild disponible)
[ "$WITH_RPM" = "1" ] && build_rpm || build_rpm

# APK APKBUILD (build manual en Alpine)
build_apk

echo ""
echo "── Packages built ──────────────────────────────────────────"
ls -lh "$OUTDIR"/*.deb "$OUTDIR"/*.tar.gz "$OUTDIR"/*.rpm 2>/dev/null | awk '{print $5, $9}'
echo ""
echo "Para instalar en Alpine:"
echo "  cp dist/shellguard-${VERSION}.tar.gz packaging/apk/"
echo "  # en host Alpine: cd packaging/apk && abuild checksum && abuild -r"
