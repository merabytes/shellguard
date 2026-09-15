#!/bin/sh
# ShellGuard one-shot installer for Synology NAS (and other Debian/dpkg hosts)
#
# Public repo:
#   curl -fsSL https://raw.githubusercontent.com/merabytes/shellguard/main/scripts/install-synology.sh | sudo sh
#
# Private repo (repo + releases return 404 without auth):
#   export GITHUB_TOKEN=ghp_xxxxxxxx
#   curl -fsSL \
#     -H "Authorization: Bearer ${GITHUB_TOKEN}" \
#     -H "Accept: application/vnd.github.raw" \
#     "https://api.github.com/repos/merabytes/shellguard/contents/scripts/install-synology.sh?ref=main" \
#     | sudo GITHUB_TOKEN="${GITHUB_TOKEN}" sh
#
# Or from release assets (after v0.2.2):
#   curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" \
#     -O "https://github.com/merabytes/shellguard/releases/download/v0.2.2/install-synology.sh"
#   chmod +x install-synology.sh && sudo GITHUB_TOKEN="${GITHUB_TOKEN}" ./install-synology.sh
#
# Non-interactive:
#   ... | sudo GITHUB_TOKEN=... SHELLGUARD_TG_TOKEN=xxx SHELLGUARD_TG_CHAT=-100... sh
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

curl_auth() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$@"
    else
        curl -fsSL "$@"
    fi
}

private_repo_hint() {
    echo "" >&2
    echo "If this repo is private, raw.githubusercontent.com returns 404." >&2
    echo "Use a GitHub PAT (read access) with GITHUB_TOKEN, for example:" >&2
    echo "" >&2
    echo '  export GITHUB_TOKEN=ghp_xxxxxxxx' >&2
    echo '  curl -fsSL \' >&2
    echo '    -H "Authorization: Bearer ${GITHUB_TOKEN}" \' >&2
    echo '    -H "Accept: application/vnd.github.raw" \' >&2
    echo "    \"https://api.github.com/repos/${GITHUB_REPO}/contents/scripts/install-synology.sh?ref=main\" \\" >&2
    echo '    | sudo GITHUB_TOKEN="${GITHUB_TOKEN}" sh' >&2
    echo "" >&2
    echo "Or make the repository public: Settings → General → Change visibility." >&2
}

download_deb() {
    _deb="shellguard_${_ver}_all.deb"
    _url="https://github.com/${GITHUB_REPO}/releases/download/v${_ver}/${_deb}"

    echo "Downloading ${_url} ..."
    if ! curl_auth -L -o "${TMPDIR}/${_deb}" "$_url"; then
        echo "Failed to download ${_deb}" >&2
        private_repo_hint
        exit 1
    fi
    DEB_FILE="${TMPDIR}/${_deb}"
}

resolve_version() {
    if [ "$VERSION" = "latest" ]; then
        _api="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
        _json=$(curl_auth "$_api" 2>/dev/null) || _json=""
        _ver=$(printf '%s' "$_json" | grep '"tag_name"' | head -1 | cut -d'"' -f4 | sed 's/^v//')
        if [ -z "$_ver" ]; then
            echo "Could not resolve latest release version." >&2
            private_repo_hint
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
    echo "Done. ShellGuard will start on boot."
}

main "$@"
