#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="translarr"
REPO="${TRANSLARR_REPO:-Flawkee/Translarr}"
REF="${TRANSLARR_REF:-main}"
ACTION=""
ASSUME_YES=false
NO_PROXY=false
FFMPEG_ARG=""
FFPROBE_ARG=""
MKVEXTRACT_ARG=""
GITHUB_TOKEN_FILE="${TRANSLARR_GITHUB_TOKEN_FILE:-}"
DOTNET_SDK_VERSION="10.0.112"
DOTNET_RUNTIME_VERSION="10.0.12"
NODE_VERSION="24.21.0"

usage() {
    cat <<'EOF'
Usage: translarr.sh [options] [install|upgrade|rollback|show|uninstall|purge]

Options:
  --repo OWNER/REPO|URL   Source repository (default: Flawkee/Translarr)
  --ref REF               Git branch or tag (default: main)
  --github-token-file PATH
                          Read a private-repository token from a mode 0600 file
  --ffmpeg PATH           Override the installed ffmpeg executable
  --ffprobe PATH          Override the installed ffprobe executable
  --mkvextract PATH       Override the installed mkvextract executable
  --no-proxy              Do not configure nginx/dashboard when running with sudo
  --yes                   Confirm the irreversible purge action
  -h, --help              Show this help

Actions:
  install     Install a rootless user service; retained state is reused
  upgrade     Back up state/code, stage a release, health-check, and auto-rollback
  rollback    Restore the most recent retained pre-upgrade code and state
  show        Display paths, tool detection, service status, and URL
  uninstall   Remove service/code/proxy while preserving config, data, and backups
  purge       Remove everything owned by Translarr (requires typing PURGE or --yes)

When run through sudo on Swizzin, the installer installs FFmpeg, FFprobe, and
MKVToolNix from the host package repository. Exact executable paths remain optional.
Private repositories may use the Swizzin user's SSH configuration or a protected
GitHub token file. Authentication is applied only while staging the repository.
The native .NET engine is built before the existing service is stopped. An installed
.NET 10+ SDK is reused; otherwise Microsoft's pinned SDK is cached for this user.
The React frontend is built with Node.js before publishing. An installed compatible
Node.js is reused; otherwise a checksum-verified official release is cached per user.
The published app includes its .NET runtime and static UI; Python and Node.js are
not required to run it.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        install|upgrade|rollback|show|uninstall|purge)
            [[ -n "$ACTION" ]] && { echo "Only one action may be supplied." >&2; exit 2; }
            ACTION="$1"
            shift
            ;;
        --repo)
            [[ -n "${2:-}" ]] || { echo "--repo needs a value." >&2; exit 2; }
            REPO="$2"
            shift 2
            ;;
        --ref)
            [[ -n "${2:-}" ]] || { echo "--ref needs a value." >&2; exit 2; }
            REF="$2"
            shift 2
            ;;
        --github-token-file)
            [[ -n "${2:-}" ]] || { echo "--github-token-file needs a value." >&2; exit 2; }
            GITHUB_TOKEN_FILE="$2"
            shift 2
            ;;
        --ffmpeg)
            [[ -n "${2:-}" ]] || { echo "--ffmpeg needs a value." >&2; exit 2; }
            FFMPEG_ARG="$2"
            shift 2
            ;;
        --ffprobe)
            [[ -n "${2:-}" ]] || { echo "--ffprobe needs a value." >&2; exit 2; }
            FFPROBE_ARG="$2"
            shift 2
            ;;
        --mkvextract)
            [[ -n "${2:-}" ]] || { echo "--mkvextract needs a value." >&2; exit 2; }
            MKVEXTRACT_ARG="$2"
            shift 2
            ;;
        --no-proxy)
            NO_PROXY=true
            shift
            ;;
        --yes|-y)
            ASSUME_YES=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$REPO" == http://* || "$REPO" == https://* || "$REPO" == git@* ]]; then
    REPO_URL="${REPO%.git}.git"
else
    REPO="${REPO#github.com/}"
    REPO="${REPO%.git}"
    REPO_URL="https://github.com/${REPO}.git"
fi

if [[ $EUID -eq 0 ]]; then
    if [[ -z "${SUDO_USER:-}" || "$SUDO_USER" == "root" ]]; then
        echo "Run with sudo from the normal Swizzin user, not from a root login." >&2
        exit 1
    fi
    SUDO_MODE=true
    target_user="$SUDO_USER"
else
    SUDO_MODE=false
    target_user="$(id -un)"
fi

target_home="$(getent passwd "$target_user" | cut -d: -f6)"
target_uid="$(id -u "$target_user")"
target_group="$(id -gn "$target_user")"
[[ -n "$target_home" && "$target_home" != "/" ]] || {
    echo "Could not resolve a safe home directory for $target_user." >&2
    exit 1
}

CONFIG_DIR="$target_home/.config/translarr"
ENV_FILE="$CONFIG_DIR/env"
UNIT_DIR="$target_home/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/translarr.service"
LEGACY_WORKER_UNIT_FILE="$UNIT_DIR/translarr-worker.service"
SHARE_DIR="$target_home/.local/share/translarr"
APP_DIR="$SHARE_DIR/app"
DATA_DIR="$SHARE_DIR/data"
TOOLS_DIR="$SHARE_DIR/tools"
BACKUP_DIR="$SHARE_DIR/backups"
SDK_DIR="$SHARE_DIR/sdk/$DOTNET_SDK_VERSION"
NODE_DIR="$SHARE_DIR/node/$NODE_VERSION"
LOCK_FILE="$SHARE_DIR/.installed"
NGINX_FILE="/etc/nginx/apps/translarr.conf"
PANEL_PROFILES="/opt/swizzin/core/custom/profiles.py"

as_user() {
    if $SUDO_MODE; then
        sudo -u "$target_user" -H "$@"
    else
        "$@"
    fi
}

systemctl_user() {
    if $SUDO_MODE; then
        sudo -u "$target_user" \
            XDG_RUNTIME_DIR="/run/user/$target_uid" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$target_uid/bus" \
            systemctl --user "$@"
    else
        systemctl --user "$@"
    fi
}

install_for_user() {
    local mode="$1" source="$2" destination="$3"
    if $SUDO_MODE; then
        install -m "$mode" -o "$target_user" -g "$target_group" "$source" "$destination"
    else
        install -m "$mode" "$source" "$destination"
    fi
}

ensure_dirs() {
    as_user mkdir -p "$CONFIG_DIR" "$UNIT_DIR" "$SHARE_DIR" "$DATA_DIR" \
        "$TOOLS_DIR" "$BACKUP_DIR"
    as_user chmod 700 "$CONFIG_DIR" "$DATA_DIR" "$BACKUP_DIR"
}

check_base_dependencies() {
    local missing=()
    local command_name
    for command_name in git curl tar xz ss base64 stat tee sha256sum; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    if ((${#missing[@]})); then
        echo "Missing installer dependencies: ${missing[*]}" >&2
        echo "Install git, curl, tar, xz-utils, iproute2, and coreutils, then retry." >&2
        exit 1
    fi
}

install_media_packages() {
    local needs_ffmpeg=false needs_mkvtoolnix=false
    if [[ -z "$FFMPEG_ARG" ]] && ! command -v ffmpeg >/dev/null 2>&1; then
        needs_ffmpeg=true
    fi
    if [[ -z "$FFPROBE_ARG" ]] && ! command -v ffprobe >/dev/null 2>&1; then
        needs_ffmpeg=true
    fi
    if [[ -z "$MKVEXTRACT_ARG" ]] && ! command -v mkvextract >/dev/null 2>&1; then
        needs_mkvtoolnix=true
    fi
    if ! $needs_ffmpeg && ! $needs_mkvtoolnix; then
        return 0
    fi
    if ! $SUDO_MODE || ! command -v apt-get >/dev/null 2>&1; then
        echo "FFmpeg, FFprobe, and MKVToolNix are required." >&2
        echo "Run the installer through sudo on Swizzin or provide absolute tool paths." >&2
        exit 1
    fi
    local packages=()
    $needs_ffmpeg && packages+=(ffmpeg)
    $needs_mkvtoolnix && packages+=(mkvtoolnix)
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
}

enable_linger() {
    $SUDO_MODE || return 0
    if ! loginctl show-user "$target_user" 2>/dev/null | grep -q '^Linger=yes$'; then
        loginctl enable-linger "$target_user"
    fi
}

choose_port() {
    local port
    for _ in {1..300}; do
        port="$(shuf -i 18000-29999 -n 1)"
        if ! ss -Htan | awk '{print $4}' | grep -Eq "(^|:)$port$"; then
            printf '%s\n' "$port"
            return 0
        fi
    done
    echo "Unable to select a free port." >&2
    return 1
}

env_value() {
    local key="$1"
    [[ -f "$ENV_FILE" ]] || return 0
    sed -n "s/^${key}=//p" "$ENV_FILE" | tail -n 1
}

write_initial_env() {
    [[ -f "$ENV_FILE" ]] && return 0
    local port root_path tmp
    port="$(choose_port)"
    if $SUDO_MODE && ! $NO_PROXY; then
        root_path="/translarr"
    else
        root_path=""
    fi
    tmp="$(mktemp)"
    cat >"$tmp" <<EOF
TRANSLARR_HOST=127.0.0.1
TRANSLARR_PORT=$port
TRANSLARR_DATA_DIR=$DATA_DIR
TRANSLARR_ROOT_PATH=$root_path
TRANSLARR_SECURE_COOKIES=$([[ -n "$root_path" ]] && echo true || echo false)
PATH=$TOOLS_DIR:$target_home/.local/bin:/usr/local/bin:/usr/bin:/bin
EOF
    install_for_user 0600 "$tmp" "$ENV_FILE"
    rm -f "$tmp"
}

prepare_proxy_env() {
    $SUDO_MODE || return 0
    $NO_PROXY && return 0
    local tmp
    tmp="$(mktemp)"
    awk '
        BEGIN { root_seen = 0; cookie_seen = 0 }
        /^TRANSLARR_ROOT_PATH=/ { print "TRANSLARR_ROOT_PATH=/translarr"; root_seen = 1; next }
        /^TRANSLARR_SECURE_COOKIES=/ { print "TRANSLARR_SECURE_COOKIES=true"; cookie_seen = 1; next }
        { print }
        END {
            if (!root_seen) print "TRANSLARR_ROOT_PATH=/translarr"
            if (!cookie_seen) print "TRANSLARR_SECURE_COOKIES=true"
        }
    ' "$ENV_FILE" >"$tmp"
    install_for_user 0600 "$tmp" "$ENV_FILE"
    rm -f "$tmp"
}

link_external_tool() {
    local name="$1" supplied="$2" resolved
    [[ -n "$supplied" ]] || return 0
    if [[ "$supplied" != /* || ! -x "$supplied" ]]; then
        echo "$name path must be an absolute executable file: $supplied" >&2
        exit 1
    fi
    resolved="$(readlink -f "$supplied")"
    as_user ln -sfn "$resolved" "$TOOLS_DIR/$name"
    echo "External $name exposed to Translarr as $TOOLS_DIR/$name"
}

configure_tools() {
    link_external_tool ffmpeg "$FFMPEG_ARG"
    link_external_tool ffprobe "$FFPROBE_ARG"
    link_external_tool mkvextract "$MKVEXTRACT_ARG"

    local tool found
    for tool in ffmpeg ffprobe mkvextract; do
        if [[ -x "$TOOLS_DIR/$tool" ]]; then
            found="$(readlink -f "$TOOLS_DIR/$tool")"
        else
            found="$(as_user env PATH="$target_home/.local/bin:/usr/local/bin:/usr/bin:/bin" \
                sh -c "command -v $tool" 2>/dev/null || true)"
        fi
        if [[ -n "$found" ]]; then
            echo "Detected $tool: $found"
        elif [[ "$tool" == "mkvextract" ]]; then
            echo "Optional mkvextract was not detected."
        else
            echo "Warning: $tool was not detected; install it externally or set its path in the UI."
        fi
    done
}

ensure_dotnet_sdk() {
    local candidate version installer install_status=0
    candidate="$(as_user sh -c 'command -v dotnet' 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
        version="$(as_user "$candidate" --version 2>/dev/null || true)"
        if [[ "$version" =~ ^([0-9]+)\. ]] && (( BASH_REMATCH[1] >= 10 )); then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi
    candidate="$SDK_DIR/dotnet"
    if [[ -x "$candidate" ]] && as_user "$candidate" --list-sdks 2>/dev/null | grep -q "^${DOTNET_SDK_VERSION} "; then
        printf '%s\n' "$candidate"
        return 0
    fi
    echo "Preparing Microsoft .NET SDK $DOTNET_SDK_VERSION in $SDK_DIR (no system-wide SDK installation)." >&2
    installer="$(as_user mktemp "$SHARE_DIR/.dotnet-install.XXXXXX")" || return 1
    if ! as_user curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --silent --show-error \
        --location --connect-timeout 20 --max-time 180 \
        --output "$installer" https://dot.net/v1/dotnet-install.sh; then
        as_user rm -f "$installer"
        return 1
    fi
    as_user bash "$installer" --version "$DOTNET_SDK_VERSION" --install-dir "$SDK_DIR" \
        --no-path >&2 || install_status=$?
    as_user rm -f "$installer"
    if (( install_status != 0 )) || ! as_user "$candidate" --version >&2; then
        echo "The per-user .NET SDK could not start. Check the Microsoft Debian/Ubuntu native-library requirements." >&2
        return 1
    fi
    printf '%s\n' "$candidate"
}

ensure_node() {
    local candidate binary_dir architecture checksum stage archive
    candidate="$(as_user sh -c 'command -v node' 2>/dev/null || true)"
    if [[ -n "$candidate" ]] && as_user "$candidate" -e 'const [major,minor]=process.versions.node.split(".").map(Number);process.exit(major>=24||(major===22&&minor>=12)?0:1)' >/dev/null 2>&1; then
        binary_dir="$(dirname "$candidate")"
        if as_user env PATH="$binary_dir:$PATH" npm --version >/dev/null 2>&1; then
            printf '%s\n' "$binary_dir"
            return 0
        fi
    fi
    if [[ -x "$NODE_DIR/bin/node" && -x "$NODE_DIR/bin/npm" ]] && [[ "$(as_user "$NODE_DIR/bin/node" --version)" == "v$NODE_VERSION" ]]; then
        printf '%s\n' "$NODE_DIR/bin"
        return 0
    fi
    case "$(uname -m)" in
        x86_64) architecture=x64; checksum=fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6 ;;
        aarch64|arm64) architecture=arm64; checksum=6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2 ;;
        *) echo "Node.js build tools require Linux x86_64 or arm64." >&2; return 1 ;;
    esac
    echo "Preparing official Node.js $NODE_VERSION build tools (no system-wide installation)." >&2
    stage="$(as_user mktemp -d "$SHARE_DIR/.node.XXXXXX")" || return 1
    archive="$stage/node.tar.xz"
    if ! as_user curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --silent --show-error \
        --location --connect-timeout 20 --max-time 300 --output "$archive" \
        "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-$architecture.tar.xz"; then
        as_user rm -rf "$stage"
        return 1
    fi
    if ! printf '%s  %s\n' "$checksum" "$archive" | as_user sha256sum --check --status; then
        echo "Node.js archive checksum did not match the pinned official release; staging cancelled." >&2
        as_user rm -rf "$stage"
        return 1
    fi
    as_user mkdir -p "$stage/root" "$SHARE_DIR/node"
    if ! as_user tar -xJf "$archive" -C "$stage/root" --strip-components=1; then
        as_user rm -rf "$stage"
        return 1
    fi
    if [[ "$(as_user "$stage/root/bin/node" --version)" != "v$NODE_VERSION" ]]; then
        echo "The staged Node.js build tools cannot run on this host." >&2
        as_user rm -rf "$stage"
        return 1
    fi
    if [[ -e "$NODE_DIR" ]]; then
        as_user mv "$NODE_DIR" "$SHARE_DIR/node/replaced-$NODE_VERSION-$(date +%Y%m%d-%H%M%S)" || return 1
    fi
    as_user mv "$stage/root" "$NODE_DIR" || return 1
    as_user rm -rf "$stage"
    printf '%s\n' "$NODE_DIR/bin"
}

stage_frontend() {
    local stage="$1" node_bin
    if [[ ! -f "$stage/frontend/package-lock.json" ]]; then
        echo "This release is missing the React frontend dependency lockfile." >&2
        return 1
    fi
    node_bin="$(ensure_node)" || return 1
    as_user env PATH="$node_bin:$PATH" npm --prefix "$stage/frontend" ci --no-fund --no-audit >&2 || return 1
    as_user env PATH="$node_bin:$PATH" npm --prefix "$stage/frontend" run build >&2 || return 1
    [[ -f "$stage/frontend/dist/index.html" ]] || { echo "The frontend build did not produce index.html." >&2; return 1; }
}

stage_native_engine() {
    local stage="$1" runtime sdk
    case "$(uname -m)" in
        x86_64) runtime=linux-x64 ;;
        aarch64|arm64) runtime=linux-arm64 ;;
        *) echo "The native Translarr release supports Linux x86_64 and arm64." >&2; return 1 ;;
    esac
    if [[ ! -x "$stage/.engine/Translarr.Engine" ]]; then
        if [[ ! -f "$stage/engine/Translarr.Engine/Translarr.Engine.csproj" ]]; then
            echo "This release has no native Translarr engine project or published binary." >&2
            return 1
        fi
        stage_frontend "$stage" || return 1
        sdk="$(ensure_dotnet_sdk)" || return 1
        echo "Publishing the self-contained $runtime engine with runtime $DOTNET_RUNTIME_VERSION..." >&2
        if ! as_user env DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
            "$sdk" publish "$stage/engine/Translarr.Engine/Translarr.Engine.csproj" \
            --configuration Release --runtime "$runtime" --self-contained true \
            -p:RuntimeFrameworkVersion="$DOTNET_RUNTIME_VERSION" \
            --output "$stage/.engine" >&2; then
            return 1
        fi
    fi
    if [[ ! -f "$stage/.engine/ui/index.html" || ! -d "$stage/.engine/ui/assets" ]]; then
        echo "The published native engine is missing its React frontend/assets." >&2
        return 1
    fi
    if [[ -f "$stage/THIRD_PARTY_NOTICES.md" ]]; then
        as_user cp -- "$stage/THIRD_PARTY_NOTICES.md" "$stage/.engine/THIRD_PARTY_NOTICES.md" || return 1
    fi
    if ! as_user "$stage/.engine/Translarr.Engine" --help >&2; then
        echo "The native engine cannot start on this host; the installed service has not been stopped." >&2
        return 1
    fi
}

stage_release() {
    local stage
    stage="$(as_user mktemp -d "$SHARE_DIR/.stage.XXXXXX")"
    echo "Fetching $REPO_URL at $REF..." >&2
    if ! clone_repository "$stage"; then
        as_user rm -rf "$stage"
        return 1
    fi
    if ! stage_native_engine "$stage"; then
        as_user rm -rf "$stage"
        return 1
    fi
    printf '%s\n' "$stage"
}

clone_repository() {
    local destination="$1" token="${TRANSLARR_GITHUB_TOKEN:-${GH_TOKEN:-}}" encoded permissions clone_status=0 auth_file=""
    if [[ -n "$GITHUB_TOKEN_FILE" ]]; then
        [[ "$GITHUB_TOKEN_FILE" == /* ]] || GITHUB_TOKEN_FILE="$(pwd)/$GITHUB_TOKEN_FILE"
        if [[ ! -f "$GITHUB_TOKEN_FILE" || -L "$GITHUB_TOKEN_FILE" ]]; then
            echo "GitHub token file must be a regular, non-symlink file: $GITHUB_TOKEN_FILE" >&2
            return 1
        fi
        permissions="$(stat -c '%a' "$GITHUB_TOKEN_FILE")"
        permissions="${permissions: -3}"
        if (( (8#$permissions & 8#077) != 0 )); then
            echo "GitHub token file must not be readable by group or others: $GITHUB_TOKEN_FILE" >&2
            return 1
        fi
        token="$(<"$GITHUB_TOKEN_FILE")"
    fi
    if [[ -z "$token" ]]; then
        as_user git clone --quiet --depth 1 --branch "$REF" "$REPO_URL" "$destination"
        return
    fi
    if [[ "$REPO_URL" != https://github.com/* ]]; then
        echo "GitHub token authentication requires an https://github.com/ repository URL." >&2
        return 1
    fi
    if [[ "$token" == *$'\n'* || "$token" == *$'\r'* || "$token" == *[[:space:]]* ]]; then
        echo "GitHub token contains invalid whitespace." >&2
        return 1
    fi
    encoded="$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
    auth_file="$(as_user mktemp "$SHARE_DIR/.git-auth.XXXXXX")"
    if ! printf '[http "https://github.com/"]\n\textraHeader = Authorization: Basic %s\n' "$encoded" | \
        as_user tee "$auth_file" >/dev/null; then
        as_user rm -f "$auth_file"
        token=""
        encoded=""
        return 1
    fi
    if ! as_user chmod 600 "$auth_file"; then
        as_user rm -f "$auth_file"
        token=""
        encoded=""
        return 1
    fi
    as_user env GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL="$auth_file" \
        git clone --quiet --depth 1 --branch "$REF" "$REPO_URL" "$destination" || clone_status=$?
    if ! as_user rm -f "$auth_file"; then
        echo "Could not remove the temporary GitHub authentication file: $auth_file" >&2
        clone_status=1
    fi
    token=""
    encoded=""
    auth_file=""
    return "$clone_status"
}

write_unit() {
    local tmp service_command
    if [[ -x "$APP_DIR/.engine/Translarr.Engine" ]]; then
        service_command="\"$APP_DIR/.engine/Translarr.Engine\" run"
    elif [[ -f "$APP_DIR/engine/Translarr.Engine/Translarr.Engine.csproj" ]]; then
        echo "The active release is missing its published engine; refusing to start the old Python backend." >&2
        return 1
    elif as_user "$APP_DIR/.venv/bin/python" -m translarr run --help >/dev/null 2>&1; then
        service_command="$APP_DIR/.venv/bin/python -m translarr run --workers 2"
    else
        service_command="$APP_DIR/.venv/bin/python -m translarr serve"
    fi
    tmp="$(mktemp)"
    cat >"$tmp" <<EOF
[Unit]
Description=Translarr subtitle translation service
Wants=network-online.target
After=network-online.target

[Service]
Type=exec
EnvironmentFile=$ENV_FILE
Environment="TRANSLARR_UI_DIR=$APP_DIR/.engine/ui"
WorkingDirectory=$APP_DIR
ExecStart=$service_command
Restart=on-failure
RestartSec=5
TimeoutStopSec=90
NoNewPrivileges=true
PrivateTmp=true
UMask=0077

[Install]
WantedBy=default.target
EOF
    if ! install_for_user 0644 "$tmp" "$UNIT_FILE"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    systemctl_user disable translarr-worker 2>/dev/null || true
    as_user rm -f "$LEGACY_WORKER_UNIT_FILE"
    systemctl_user daemon-reload
}

stop_service() {
    systemctl_user stop translarr-worker 2>/dev/null || true
    systemctl_user stop translarr 2>/dev/null || true
}

start_service() {
    systemctl_user enable --now translarr
}

health_wait() {
    local port health_path deadline
    port="$(env_value TRANSLARR_PORT)"
    if [[ -x "$APP_DIR/.engine/Translarr.Engine" ]] || as_user "$APP_DIR/.venv/bin/python" -m translarr run --help >/dev/null 2>&1; then
        health_path="/health/ready"
    else
        health_path="/health"
    fi
    deadline=$((SECONDS + 150))
    while (( SECONDS < deadline )); do
        if curl -fsS --max-time 3 "http://127.0.0.1:${port}${health_path}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

snapshot_state() {
    local destination="$1"
    as_user mkdir -p "$destination"
    as_user tar -C "$target_home" -czf "$destination/state.tar.gz" \
        .config/translarr .local/share/translarr/data
}

restore_state_with_quarantine() {
    local archive="$1" quarantine="$2"
    as_user mkdir -p "$quarantine"
    [[ ! -d "$CONFIG_DIR" ]] || as_user mv "$CONFIG_DIR" "$quarantine/config"
    [[ ! -d "$DATA_DIR" ]] || as_user mv "$DATA_DIR" "$quarantine/data"
    as_user tar -C "$target_home" -xzf "$archive"
}

configure_nginx() {
    $SUDO_MODE || return 0
    $NO_PROXY && return 0
    local port auth_block="" htpasswd_file tmp
    port="$(env_value TRANSLARR_PORT)"
    htpasswd_file="/etc/htpasswd.d/htpasswd.${target_user}"
    if [[ -f "$htpasswd_file" ]]; then
        auth_block="    auth_basic \"Restricted\";
    auth_basic_user_file $htpasswd_file;"
    fi
    mkdir -p /etc/nginx/apps
    tmp="$(mktemp)"
    cat >"$tmp" <<EOF
location = /translarr {
    return 301 \$scheme://\$host/translarr/;
}

location /translarr/ {
    proxy_pass http://127.0.0.1:${port}/;
    proxy_http_version 1.1;
    proxy_set_header Host \$http_host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Prefix /translarr;
    proxy_redirect off;
${auth_block}
}
EOF
    install -m 0644 "$tmp" "$NGINX_FILE"
    rm -f "$tmp"
    if nginx -t; then
        systemctl reload nginx
    else
        rm -f "$NGINX_FILE"
        echo "nginx validation failed; removed $NGINX_FILE." >&2
        return 1
    fi
}

configure_dashboard() {
    $SUDO_MODE || return 0
    $NO_PROXY && return 0
    mkdir -p "$(dirname "$PANEL_PROFILES")" /install
    touch "$PANEL_PROFILES"
    if ! grep -q '^class translarr_meta:' "$PANEL_PROFILES"; then
        cat >>"$PANEL_PROFILES" <<'EOF'


class translarr_meta:
    name = "translarr"
    pretty_name = "Translarr"
    baseurl = "/translarr"
    systemd = "translarr"
    img = "translarr"
    runas = "user"
EOF
    fi
    local logo="$APP_DIR/.engine/ui/logo.png"
    [[ -f "$logo" ]] || logo="$APP_DIR/src/translarr/static/logo.png"
    if [[ -f "$logo" ]]; then
        install -D -m 0644 "$logo" \
            /opt/swizzin/static/img/apps/translarr.png
    fi
    touch /install/.translarr.lock
    systemctl restart panel 2>/dev/null || true
}

remove_proxy_dashboard() {
    if ! $SUDO_MODE; then
        [[ ! -e "$NGINX_FILE" ]] || echo "Run uninstall with sudo to remove $NGINX_FILE."
        return 0
    fi
    rm -f "$NGINX_FILE" /install/.translarr.lock /opt/swizzin/static/img/apps/translarr.png
    if [[ -f "$PANEL_PROFILES" ]]; then
        local profiles_tmp
        profiles_tmp="$(mktemp)"
        awk '/^class translarr_meta:/ { skipping = 1; next } /^class / { skipping = 0 } !skipping { print }' "$PANEL_PROFILES" >"$profiles_tmp"
        install -m 0644 "$profiles_tmp" "$PANEL_PROFILES"
        rm -f "$profiles_tmp"
    fi
    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
        systemctl reload nginx
    fi
    systemctl restart panel 2>/dev/null || true
}

install_app() {
    check_base_dependencies
    install_media_packages
    enable_linger
    ensure_dirs
    write_initial_env
    prepare_proxy_env
    configure_tools
    if [[ -f "$LOCK_FILE" && -d "$APP_DIR" ]]; then
        echo "Translarr is already installed. Use upgrade instead." >&2
        return 1
    fi
    local stage
    stage="$(stage_release)" || { echo "Release staging failed." >&2; return 1; }
    stop_service
    [[ ! -e "$APP_DIR" ]] || as_user mv "$APP_DIR" "$BACKUP_DIR/incomplete-$(date +%Y%m%d-%H%M%S)"
    as_user mv "$stage" "$APP_DIR"
    write_unit
    start_service
    if ! health_wait; then
        stop_service
        echo "Translarr did not become healthy. Inspect: journalctl --user -u translarr -n 100" >&2
        return 1
    fi
    as_user touch "$LOCK_FILE"
    configure_nginx
    configure_dashboard
    show_status
}

upgrade_app() {
    [[ -f "$LOCK_FILE" && -d "$APP_DIR" ]] || {
        echo "Translarr is not installed. Use install." >&2
        return 1
    }
    check_base_dependencies
    install_media_packages
    ensure_dirs
    configure_tools
    local stage stamp backup
    stage="$(stage_release)" || { echo "Release staging failed; current service was untouched." >&2; return 1; }
    stamp="$(date +%Y%m%d-%H%M%S)"
    backup="$BACKUP_DIR/pre-upgrade-$stamp"
    stop_service
    if ! snapshot_state "$backup"; then
        start_service || true
        echo "State backup failed; the existing release was kept and restarted. Staged code remains at $stage." >&2
        return 1
    fi
    if ! as_user mv "$APP_DIR" "$backup/app"; then
        start_service || true
        echo "Could not retain the old application code; upgrade cancelled." >&2
        return 1
    fi
    if ! as_user mv "$stage" "$APP_DIR"; then
        as_user mv "$backup/app" "$APP_DIR"
        start_service || true
        echo "Could not activate the staged release; the previous code was restored." >&2
        return 1
    fi
    if write_unit && start_service && health_wait; then
        echo "Upgrade succeeded. Rollback backup retained at $backup"
        configure_nginx
        configure_dashboard
        return 0
    fi

    echo "Upgrade health check failed; restoring old code and state." >&2
    stop_service
    as_user mv "$APP_DIR" "$backup/failed-app"
    as_user mv "$backup/app" "$APP_DIR"
    restore_state_with_quarantine "$backup/state.tar.gz" "$backup/failed-state"
    write_unit
    start_service
    if health_wait; then
        echo "Automatic rollback succeeded. Failed release retained at $backup/failed-app" >&2
    else
        echo "Rollback also failed. Inspect: journalctl --user -u translarr -n 100" >&2
    fi
    return 1
}

newest_rollback_backup() {
    local candidate newest=""
    shopt -s nullglob
    for candidate in "$BACKUP_DIR"/*; do
        [[ -d "$candidate/app" && -f "$candidate/state.tar.gz" ]] || continue
        if [[ -z "$newest" || "$candidate" -nt "$newest" ]]; then
            newest="$candidate"
        fi
    done
    shopt -u nullglob
    printf '%s\n' "$newest"
}

rollback_app() {
    [[ -d "$APP_DIR" ]] || { echo "Active application code was not found." >&2; return 1; }
    local selected stamp current
    selected="$(newest_rollback_backup)"
    [[ -n "$selected" ]] || { echo "No usable rollback backup was found." >&2; return 1; }
    stamp="$(date +%Y%m%d-%H%M%S)"
    current="$BACKUP_DIR/pre-rollback-$stamp"
    echo "Rolling back to $selected"
    echo "This restores the selected backup's database and credentials; newer state is retained only in $current." >&2
    stop_service
    snapshot_state "$current"
    as_user mv "$APP_DIR" "$current/app"
    as_user mv "$selected/app" "$APP_DIR"
    restore_state_with_quarantine "$selected/state.tar.gz" "$current/displaced-state"
    write_unit
    start_service
    if health_wait; then
        echo "Rollback succeeded. The replaced version is retained at $current"
        return 0
    fi

    echo "Rollback target failed health check; restoring the version just replaced." >&2
    stop_service
    as_user mv "$APP_DIR" "$selected/failed-rollback-app"
    as_user mv "$current/app" "$APP_DIR"
    restore_state_with_quarantine "$current/state.tar.gz" "$selected/failed-rollback-state"
    write_unit
    start_service
    health_wait || echo "Restored version is not healthy; inspect the user journal." >&2
    return 1
}

show_status() {
    local port root_path status url tool found
    port="$(env_value TRANSLARR_PORT)"
    root_path="$(env_value TRANSLARR_ROOT_PATH)"
    status="$(systemctl_user is-active translarr 2>/dev/null || true)"
    if [[ -f "$NGINX_FILE" ]]; then
        url="https://$(hostname -f)/translarr/"
    else
        url="http://$(hostname -f):${port:-unknown}${root_path:-/}"
    fi
    echo
    echo "Translarr status"
    echo "  service : ${status:-not installed}"
    echo "  URL     : $url"
    echo "  port    : ${port:-unknown} (retained across upgrades)"
    echo "  config  : $CONFIG_DIR"
    echo "  data    : $DATA_DIR"
    echo "  code    : $APP_DIR"
    echo "  backups : $BACKUP_DIR"
    for tool in ffmpeg ffprobe mkvextract; do
        if [[ -x "$TOOLS_DIR/$tool" ]]; then
            found="$(readlink -f "$TOOLS_DIR/$tool")"
        else
            found="$(as_user env PATH="$target_home/.local/bin:/usr/local/bin:/usr/bin:/bin" \
                sh -c "command -v $tool" 2>/dev/null || true)"
        fi
        echo "  $tool : ${found:-not detected}"
    done
    echo
    echo "Commands:"
    echo "  systemctl --user status translarr"
    echo "  journalctl --user -u translarr -f"
    echo
}

uninstall_app() {
    systemctl_user disable --now translarr-worker translarr 2>/dev/null || true
    as_user rm -f "$UNIT_FILE" "$LEGACY_WORKER_UNIT_FILE" "$LOCK_FILE"
    systemctl_user daemon-reload 2>/dev/null || true
    [[ ! -d "$APP_DIR" ]] || as_user rm -rf "$APP_DIR"
    remove_proxy_dashboard
    echo "Translarr service and code removed. Config, database, and backups were preserved."
    echo "Run '$0 purge' only if you intend to delete all retained Translarr state."
}

purge_app() {
    if ! $ASSUME_YES; then
        echo "This deletes Translarr config, credentials, database, code, and backups."
        echo "It does not delete media or generated subtitle files."
        read -r -p "Type PURGE to continue: " confirmation
        [[ "$confirmation" == "PURGE" ]] || { echo "Purge cancelled."; return 0; }
    fi
    uninstall_app
    [[ ! -d "$CONFIG_DIR" ]] || as_user rm -rf "$CONFIG_DIR"
    [[ ! -d "$SHARE_DIR" ]] || as_user rm -rf "$SHARE_DIR"
    echo "Deleted $CONFIG_DIR and $SHARE_DIR. Recovery requires an external backup."
}

if [[ -z "$ACTION" ]]; then
    echo "Translarr installer"
    echo "  install | upgrade | rollback | show | uninstall | purge | exit"
    read -r -p "Action: " ACTION
fi

case "$ACTION" in
    install) install_app ;;
    upgrade) upgrade_app ;;
    rollback) rollback_app ;;
    show) show_status ;;
    uninstall) uninstall_app ;;
    purge) purge_app ;;
    exit) exit 0 ;;
    *) echo "Unknown action: $ACTION" >&2; usage >&2; exit 2 ;;
esac
