#!/bin/sh
# ShellGuard one-shot installer for Synology NAS (and other Debian/dpkg hosts)
#
#   curl -fsSL https://raw.githubusercontent.com/merabytes/shellguard/main/scripts/install-synology.sh | sudo sh
#
# Non-interactive / verbose (env vars AFTER sudo, before sh):
#   curl -fsSL ... | sudo SHELLGUARD_VERSION=2.2.4 SHELLGUARD_VERBOSE=1 sh
#   curl -fsSL ... | sudo SHELLGUARD_TG_TOKEN=xxx SHELLGUARD_TG_CHAT=-100... sh
set -e

INSTALLER_VERSION="6"

GITHUB_REPO="${SHELLGUARD_REPO:-merabytes/shellguard}"
VERSION="${SHELLGUARD_VERSION:-latest}"
CONF="/etc/shellguard/shellguard.conf"
TMPDIR="${TMPDIR:-/tmp}"

vlog() {
    [ "${SHELLGUARD_VERBOSE:-0}" = "1" ] && printf '[verbose] %s\n' "$*" >&2
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Run as root: curl ... | sudo sh" >&2
        exit 1
    fi
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

release_url() {
    _file=$1
    printf 'https://github.com/%s/releases/download/v%s/%s' "$GITHUB_REPO" "$_ver" "$_file"
}

resolve_version() {
    if [ "$VERSION" = "latest" ]; then
        _api="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
        _json=$(curl -fsSL "$_api" 2>/dev/null) || _json=""
        _ver=$(printf '%s' "$_json" | grep '"tag_name"' | head -1 | cut -d'"' -f4 | sed 's/^v//')
        if [ -z "$_ver" ]; then
            echo "Could not resolve latest release version." >&2
            exit 1
        fi
    else
        _ver="${VERSION#v}"
    fi
    echo "ShellGuard version: $_ver"
}

download_deb() {
    _deb="shellguard_${_ver}_all.deb"
    _url=$(release_url "$_deb")

    echo "Downloading $_url ..."
    if ! curl -fsSL -L -o "${TMPDIR}/${_deb}" "$_url"; then
        echo "Failed to download ${_deb}" >&2
        exit 1
    fi
    DEB_FILE="${TMPDIR}/${_deb}"
    DEB_NAME="$_deb"
}

sha256_of() {
    _file=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$_file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$_file" | awk '{print $1}'
    else
        echo "Need sha256sum or shasum for integrity check." >&2
        exit 1
    fi
}

verify_checksum() {
    _deb=$1
    _sums="${TMPDIR}/SHA256SUMS"
    _url=$(release_url "SHA256SUMS")

    if [ "${SHELLGUARD_SKIP_CHECKSUM:-0}" = "1" ]; then
        echo "WARNING: skipping SHA256 verification (SHELLGUARD_SKIP_CHECKSUM=1)" >&2
        return 0
    fi

    echo "Downloading checksums from $_url ..."
    if ! curl -fsSL -L -o "$_sums" "$_url"; then
        echo "Failed to download SHA256SUMS — refusing to install unverified package." >&2
        echo "Set SHELLGUARD_SKIP_CHECKSUM=1 to override (not recommended)." >&2
        exit 1
    fi

    _expected=$(awk -v f="$DEB_NAME" '$2 == f { print $1; exit }' "$_sums")
    if [ -z "$_expected" ]; then
        echo "Package $DEB_NAME not found in SHA256SUMS." >&2
        exit 1
    fi

    _actual=$(sha256_of "$_deb")
    if [ "$_expected" != "$_actual" ]; then
        echo "SHA256 mismatch for $DEB_NAME." >&2
        echo "  expected: $_expected" >&2
        echo "  actual:   $_actual" >&2
        exit 1
    fi
    echo "SHA256 verified OK."
}

# Last-resort fallback if Synology dpkg ignores --no-debsig
install_deb_extract() {
    _deb=$1
    _root="/tmp/shellguard.deb.$$"
    rm -rf "$_root"
    mkdir -p "$_root"

    need_cmd dpkg-deb

    echo "Installing $_deb via dpkg-deb extract ..."
    dpkg-deb -x "$_deb" "$_root"
    dpkg-deb -e "$_deb" "$_root/DEBIAN"

    for _dir in usr etc lib; do
        if [ -d "$_root/$_dir" ]; then
            mkdir -p "/$_dir"
            cp -a "$_root/$_dir/." "/$_dir/"
        fi
    done

    if [ -f "$_root/DEBIAN/postinst" ]; then
        chmod 755 "$_root/DEBIAN/postinst"
        DEBIAN_FRONTEND=noninteractive sh "$_root/DEBIAN/postinst" configure || true
    fi

    rm -rf "$_root"
    echo "ShellGuard files installed."
}

install_deb() {
    need_cmd dpkg
    verify_checksum "$DEB_FILE"

    echo "Installing $DEB_FILE ..."
    if dpkg --no-debsig --force-all -i "$DEB_FILE" 2>/tmp/shellguard_dpkg.err; then
        return
    fi

    if grep -qi 'debsig\|signature' /tmp/shellguard_dpkg.err 2>/dev/null; then
        echo "dpkg still ran debsig despite --no-debsig — falling back to dpkg-deb extract ..."
        install_deb_extract "$DEB_FILE"
        return
    fi

    if command -v apt-get >/dev/null 2>&1; then
        echo "Fixing dependencies ..."
        apt-get install -f -y
        dpkg --no-debsig --force-all -i "$DEB_FILE" && return
    fi

    cat /tmp/shellguard_dpkg.err >&2
    exit 1
}

run_configure() {
    _cfg="${TMPDIR}/shellguard-configure.$$"
    _args="--start"
    [ "${SHELLGUARD_VERBOSE:-0}" = "1" ] && _args="--verbose $_args"

    _cfg_url=$(release_url "configure.sh")
    echo "Fetching configure.sh from release ..."
    if curl -fsSL -L -o "$_cfg" "$_cfg_url" && [ -s "$_cfg" ]; then
        chmod +x "$_cfg"
        vlog "configure source: $_cfg_url"
        sh "$_cfg" $_args
        return
    fi

    _raw="https://raw.githubusercontent.com/${GITHUB_REPO}/main/scripts/configure.sh"
    echo "Release configure.sh unavailable — trying main branch ..."
    if curl -fsSL -L -o "$_cfg" "$_raw" && [ -s "$_cfg" ]; then
        chmod +x "$_cfg"
        vlog "configure source: $_raw"
        sh "$_cfg" $_args
        return
    fi

    echo "Using installed shellguard-configure ..."
    if [ -x /usr/bin/shellguard-configure ]; then
        /usr/bin/shellguard-configure $_args
    elif [ -x /usr/lib/shellguard/configure.sh ]; then
        /usr/lib/shellguard/configure.sh $_args
    else
        echo "Configure manually: vi $CONF && /usr/local/etc/rc.d/S99shellguard start" >&2
        exit 1
    fi
}

main() {
    require_root
    need_cmd curl

    echo "ShellGuard installer v${INSTALLER_VERSION}"
    vlog "SHELLGUARD_VERSION=${SHELLGUARD_VERSION:-latest}"
    vlog "SHELLGUARD_VERBOSE=${SHELLGUARD_VERBOSE:-0}"
    vlog "Tip: curl ... | sudo SHELLGUARD_VERSION=2.2.4 SHELLGUARD_VERBOSE=1 sh"

    resolve_version
    download_deb
    install_deb

    echo ""
    echo "Package installed. Configuring Telegram ..."
    run_configure

    echo ""
    echo "Done. ShellGuard will start on boot."
}

main "$@"
