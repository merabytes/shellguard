#!/bin/sh
# ShellGuard one-shot installer for Synology NAS (and other Debian/dpkg hosts)
#
# Interactive (prompts for Telegram token, chat ID, topic):
#   curl -fsSL https://raw.githubusercontent.com/merabytes/shellguard/main/scripts/install-synology.sh | sudo sh
#
# Non-interactive:
#   curl -fsSL ... | sudo SHELLGUARD_TG_TOKEN=xxx SHELLGUARD_TG_CHAT=-100... SHELLGUARD_TG_TOPIC=42 sh
#
# Pin version:
#   SHELLGUARD_VERSION=0.2.0 curl -fsSL ... | sudo sh
set -e

GITHUB_REPO="${SHELLGUARD_REPO:-merabytes/shellguard}"
VERSION="${SHELLGUARD_VERSION:-latest}"
CONF="/etc/shellguard/shellguard.conf"
TMPDIR="${TMPDIR:-/tmp}"

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

download_deb() {
    _deb="shellguard_${_ver}_all.deb"
    _url="https://github.com/${GITHUB_REPO}/releases/download/v${_ver}/${_deb}"

    echo "Downloading ${_url} ..."
    if ! curl -fsSL -o "${TMPDIR}/${_deb}" "$_url"; then
        echo "Failed to download ${_deb}" >&2
        echo "Check SHELLGUARD_VERSION or https://github.com/${GITHUB_REPO}/releases" >&2
        exit 1
    fi
    DEB_FILE="${TMPDIR}/${_deb}"
}

resolve_version() {
    if [ "$VERSION" = "latest" ]; then
        _api="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
        _ver=$(curl -fsSL "$_api" | grep '"tag_name"' | head -1 | cut -d'"' -f4 | sed 's/^v//')
        if [ -z "$_ver" ]; then
            echo "Could not resolve latest release version." >&2
            exit 1
        fi
    else
        _ver="${VERSION#v}"
    fi
    echo "ShellGuard version: $_ver"
}

install_deb() {
    need_cmd dpkg
    echo "Installing $DEB_FILE ..."
    dpkg -i --force-overwrite "$DEB_FILE" || {
        echo "Fixing dependencies..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -f -y
        fi
        dpkg -i --force-overwrite "$DEB_FILE"
    }
}

main() {
    require_root
    need_cmd curl

    resolve_version
    download_deb
    install_deb

    echo ""
    echo "Package installed. Configuring Telegram..."

    if [ -x /usr/bin/shellguard-configure ]; then
        /usr/bin/shellguard-configure --start
    elif [ -x /usr/lib/shellguard/configure.sh ]; then
        /usr/lib/shellguard/configure.sh --start
    else
        echo "Configure manually: vi $CONF && /usr/local/etc/rc.d/S99shellguard start" >&2
        exit 1
    fi

    echo ""
    echo "Done. ShellGuard will start on boot (Synology: $CONF)."
}

main "$@"
