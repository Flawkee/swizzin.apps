#!/usr/bin/env bash
# PitzotzStory: one self-contained .NET service hosting React and background workers.
set -Eeuo pipefail
umask 077
APP_NAME="pitzotzstory"
REPO="${PITZOTZSTORY_REPO:-${MEOWDB_REPO:-Flawkee/meowdb-tracker}}"
REF="${PITZOTZSTORY_REF:-${MEOWDB_REF:-main}}"
SOURCE=""
GITHUB_TOKEN_FILE="${PITZOTZSTORY_GITHUB_TOKEN_FILE:-${MEOWDB_GITHUB_TOKEN_FILE:-}}"
ACTION=""
NO_PROXY=false
ASSUME_YES=false
DOTNET_SDK_VERSION="10.0.402"
DOTNET_RUNTIME_VERSION="10.0.13"
NODE_VERSION="24.21.0"
COMPANION_NAME="pitzotzstory-companion"
COMPANION_VERSION="3.5.2"
COMPANION_RUNTIME=""

usage() {
 cat <<'EOF'
Usage: pitzotzstory.sh [options] [install|upgrade|rollback|show|uninstall|purge]
  --repo OWNER/REPO|URL  Git source (default: Flawkee/meowdb-tracker)
  --ref REF              Branch/tag (default main)
  --source PATH          Build an existing local source checkout instead of cloning
  --github-token-file PATH  Private GitHub PAT file (chmod 600)
  --no-proxy             Skip nginx and Swizzin panel configuration
  --yes                  Confirm complete uninstall/purge without prompting
Run as your normal user, or sudo from that user to configure nginx and Swizzin.
One rootless user service serves React, the API, SignalR and marketplace/push workers.
Install/upgrade build before stopping the service. Upgrade backs up state and rolls
back if startup fails. Install also sets up the marketplace companion; upgrade
updates its three modules and restarts it, preserving its port and browser state.
Fresh companion setup needs Python 3.11+, Chromium and Xvfb (installed with sudo).
Uninstall removes the app AND companion, including all data, keys, backups and
browser state. Export a backup first. Purge is an alias for complete uninstall.
Separate FlareSolverr/ARR services and shared system dependencies are retained.
Requires git, curl, tar, xz, ss and coreutils; uses .NET 10 and Node 22.12+/24+ to
build, downloading per-user tools if needed. No Node or .NET runtime is needed
at runtime: the published Linux executable includes its own .NET runtime.
Private GitHub HTTPS clones accept PITZOTZSTORY_GITHUB_TOKEN, MEOWDB_GITHUB_TOKEN, GH_TOKEN or GITHUB_TOKEN
(in that order), or --github-token-file / MEOWDB_GITHUB_TOKEN_FILE (takes priority).
Use a fine-grained PAT with Contents: read access to the private repository.
With sudo, preserve the chosen token variable, e.g.:
  sudo --preserve-env=MEOWDB_GITHUB_TOKEN bash pitzotzstory.sh install
Supply credentials again for upgrades; they are not saved in app configuration.
SSH URLs use the normal user's SSH key. Never put credentials in a repository URL.
EOF
}
while (($#)); do
 case "$1" in
  install|upgrade|rollback|show|uninstall|purge) [[ -z "$ACTION" ]] || { echo 'Only one action is allowed.' >&2; exit 2; }; ACTION="$1"; shift ;;
  --repo|--ref|--source|--github-token-file) [[ -n "${2:-}" ]] || { echo "$1 needs a value." >&2; exit 2; }; case "$1" in --repo) REPO="$2";; --ref) REF="$2";; --source) SOURCE="$2";; --github-token-file) GITHUB_TOKEN_FILE="$2";; esac; shift 2 ;;
  --no-proxy) NO_PROXY=true; shift ;;
  --yes|-y) ASSUME_YES=true; shift ;;
  --help|-h) usage; exit 0 ;;
  *) echo "Unknown argument: $1" >&2; exit 2 ;;
 esac
done
if [[ $EUID -eq 0 ]]; then
 [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] || { echo 'Run through sudo from the normal Swizzin user.' >&2; exit 1; }
 SUDO_MODE=true; target_user="$SUDO_USER"
else SUDO_MODE=false; target_user="$(id -un)"; fi
target_home="$(getent passwd "$target_user" | cut -d: -f6)"
target_uid="$(id -u "$target_user")"
target_group="$(id -gn "$target_user")"
[[ "$target_home" == /* && "$target_home" != / ]] || { echo 'Unsafe user home.' >&2; exit 1; }
CONFIG_DIR="$target_home/.config/$APP_NAME"
ENV_FILE="$CONFIG_DIR/env"
SHARE_DIR="$target_home/.local/share/$APP_NAME"
APP_DIR="$SHARE_DIR/app"
DATA_DIR="$SHARE_DIR/data"
BACKUP_DIR="$SHARE_DIR/backups"
SDK_DIR="$SHARE_DIR/sdk/$DOTNET_SDK_VERSION"
NODE_DIR="$SHARE_DIR/node/$NODE_VERSION"
UNIT_DIR="$target_home/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/$APP_NAME.service"
LOCK_FILE="$SHARE_DIR/.installed"
COMPANION_DIR="$target_home/.config/pitzotzstory-companion"
COMPANION_UNIT="$UNIT_DIR/pitzotzstory-companion.service"
NGINX_FILE="/etc/nginx/apps/$APP_NAME.conf"
PANEL_PROFILES="/opt/swizzin/core/custom/profiles.py"

as_user() { if $SUDO_MODE; then sudo -u "$target_user" -H "$@"; else "$@"; fi; }
systemctl_user() {
 if $SUDO_MODE; then sudo -u "$target_user" XDG_RUNTIME_DIR="/run/user/$target_uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$target_uid/bus" systemctl --user "$@";
 else systemctl --user "$@"; fi
}
migrate_brand() {
 local old new stamp archive file temp
 local legacy_share="$target_home/.local/share/meowdb-tracker"
 [[ -d "$legacy_share" && ! -L "$legacy_share" ]] || return 0
 if [[ -e "$SHARE_DIR" ]]; then echo 'Both legacy and PitzotzStory data exist; migration stopped to avoid overwriting either.' >&2; return 1; fi
 if [[ -f /etc/nginx/apps/meowdb-tracker.conf ]] && ! $SUDO_MODE; then echo 'Run upgrade through sudo to migrate nginx and Swizzin too.' >&2; return 1; fi
 stamp="$(date +%Y%m%d-%H%M%S)"
 archive="$(as_user mktemp "$target_home/.local/share/pitzotzstory-migration-$stamp.XXXXXX.tar.gz")" || return 1
 # Preflight all destinations before stopping either service.
 for new in "$CONFIG_DIR" "$COMPANION_DIR" "$target_home/.local/state/pitzotzstory-marketplace" "$UNIT_FILE" "$COMPANION_UNIT" "$UNIT_FILE.d" "$COMPANION_UNIT.d"; do
  [[ ! -e "$new" ]] || { echo "Migration conflict: $new" >&2; return 1; }
 done
 systemctl_user stop meowdb-tracker || return 1
 if [[ -f "$UNIT_DIR/cozy-flaresolverr.service" ]]; then
  systemctl_user stop cozy-flaresolverr || { systemctl_user start meowdb-tracker; return 1; }
 fi
 # Archive encrypted data, keys and original service definitions before changing paths.
 local -a entries=(.local/share/meowdb-tracker/data .config/meowdb-tracker)
 for file in meowdb-tracker.service meowdb-tracker.service.d cozy-flaresolverr.service cozy-flaresolverr.service.d; do
  [[ ! -e "$UNIT_DIR/$file" ]] || entries+=(".config/systemd/user/$file")
 done
 as_user tar -C "$target_home" -czf "$archive" "${entries[@]}" || { systemctl_user start meowdb-tracker; systemctl_user start cozy-flaresolverr 2>/dev/null || true; return 1; }
 if ! migrate_brand_files; then
  echo "Brand migration failed; restoring original service paths. Archive: $archive" >&2
  systemctl_user stop "$APP_NAME" "$COMPANION_NAME" 2>/dev/null || true
  systemctl_user disable "$APP_NAME" "$COMPANION_NAME" 2>/dev/null || true
  as_user rm -f -- "$UNIT_FILE" "$COMPANION_UNIT"
  as_user rm -rf -- "$UNIT_FILE.d" "$COMPANION_UNIT.d"
  for old in "$legacy_share" "$target_home/.config/meowdb-tracker" "$target_home/.config/cozy-flaresolverr" "$target_home/.local/state/meowdb-marketplace"; do
   case "$old" in
    "$legacy_share") new="$SHARE_DIR";;
    */.config/meowdb-tracker) new="$CONFIG_DIR";;
    */.config/cozy-flaresolverr) new="$COMPANION_DIR";;
    *) new="$target_home/.local/state/pitzotzstory-marketplace";;
   esac
   if [[ -L "$old" && "$(readlink "$old")" == "$new" ]]; then as_user rm -- "$old"; fi
   if [[ ! -e "$old" && -d "$new" ]]; then as_user mv "$new" "$old"; fi
  done
  as_user tar -C "$target_home" -xzf "$archive" --wildcards '.config/*'
  systemctl_user daemon-reload
  systemctl_user enable --now meowdb-tracker
  [[ ! -f "$UNIT_DIR/cozy-flaresolverr.service" ]] || systemctl_user enable --now cozy-flaresolverr
  return 1
 fi
 echo "PitzotzStory migration complete. Original state archive: $archive"
}
# Dynamic scope keeps the migration archive and exact validated paths in the caller.
migrate_brand_files() {
 for old in "$legacy_share" "$target_home/.config/meowdb-tracker" "$target_home/.config/cozy-flaresolverr" "$target_home/.local/state/meowdb-marketplace"; do
  case "$old" in
   "$legacy_share") new="$SHARE_DIR";;
   */.config/meowdb-tracker) new="$CONFIG_DIR";;
   */.config/cozy-flaresolverr) new="$COMPANION_DIR";;
   *) new="$target_home/.local/state/pitzotzstory-marketplace";;
  esac
  [[ -e "$old" && ! -L "$old" ]] || continue
  [[ ! -e "$new" ]] || { echo "Migration conflict: $new" >&2; return 1; }
  as_user mv "$old" "$new" || return 1
  as_user ln -s "$new" "$old" || return 1
 done
 if [[ -d "$UNIT_DIR/meowdb-tracker.service.d" ]]; then as_user cp -a "$UNIT_DIR/meowdb-tracker.service.d" "$UNIT_FILE.d" || return 1; fi
 for file in "$UNIT_DIR/cozy-flaresolverr.service" "$UNIT_DIR/cozy-flaresolverr.service.d"; do
  [[ ! -e "$file" ]] || as_user cp -a "$file" "${file/cozy-flaresolverr/pitzotzstory-companion}" || return 1
 done
 # Rewrite managed paths, preserving custom ports, flags and EnvironmentFiles.
 for file in "$ENV_FILE" "$COMPANION_UNIT" "$COMPANION_UNIT.d/"*.conf "$UNIT_FILE.d/"*.conf; do
  [[ -f "$file" ]] || continue
  as_user sed -i -e 's|/meowdb-tracker|/pitzotzstory|g' -e 's|/cozy-flaresolverr|/pitzotzstory-companion|g' -e 's|/meowdb-marketplace|/pitzotzstory-marketplace|g' "$file" || return 1
 done
 as_user sed -i 's|^Tracker__BasePath=.*|Tracker__BasePath=/PitzotzStory|' "$ENV_FILE" || return 1
 systemctl_user disable meowdb-tracker cozy-flaresolverr 2>/dev/null || true
 systemctl_user daemon-reload || return 1
 # Reuse the old executable until the staged upgrade is ready.
 if [[ -f "$UNIT_DIR/meowdb-tracker.service" ]]; then
  temp="$(mktemp)" || return 1
  sed -e 's|/meowdb-tracker|/pitzotzstory|g' "$UNIT_DIR/meowdb-tracker.service" >"$temp" || return 1
  install_for_user 0644 "$temp" "$UNIT_FILE" || { rm -f "$temp"; return 1; }
  rm -f "$temp"
 fi
 if [[ -f "$COMPANION_UNIT" ]]; then as_user sed -i 's|^Description=.*|Description=PitzotzStory marketplace browser companion|' "$COMPANION_UNIT" || return 1; fi
 systemctl_user enable --now "$APP_NAME" || return 1
 if [[ -f "$COMPANION_UNIT" ]]; then systemctl_user enable --now "$COMPANION_NAME" || return 1; fi
 # Disabled legacy units are archived above; avoid two services for one database.
 as_user rm -f -- "$UNIT_DIR/meowdb-tracker.service" "$UNIT_DIR/cozy-flaresolverr.service" || return 1
 as_user rm -rf -- "$UNIT_DIR/meowdb-tracker.service.d" "$UNIT_DIR/cozy-flaresolverr.service.d" || return 1
 systemctl_user daemon-reload || return 1
}
install_for_user() {
 if $SUDO_MODE; then install -m "$1" -o "$target_user" -g "$target_group" "$2" "$3";
 else install -m "$1" "$2" "$3"; fi
}
env_value() { [[ -f "$ENV_FILE" ]] || return 0; sed -n "s/^${1}=//p" "$ENV_FILE" | tail -n 1; }
ensure_dirs() {
 as_user mkdir -p "$CONFIG_DIR" "$SHARE_DIR" "$DATA_DIR" "$BACKUP_DIR" "$UNIT_DIR"
 as_user chmod 700 "$CONFIG_DIR" "$SHARE_DIR" "$DATA_DIR" "$BACKUP_DIR"
}
check_dependencies() {
 local cmd
 for cmd in git curl tar xz ss shuf sha256sum getent base64; do command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; return 1; }; done
 if $SUDO_MODE; then loginctl enable-linger "$target_user"; fi
}
write_env() {
 [[ ! -f "$ENV_FILE" ]] || return 0
 local port temp
 for _ in {1..300}; do
  port="$(shuf -i 18000-29999 -n 1)"
  if ! ss -Htan | awk '{print $4}' | grep -Eq "(^|:)$port$"; then break; fi
  port=""
 done
 [[ -n "$port" ]] || { echo 'Could not select a free port.' >&2; return 1; }
 temp="$(mktemp)"
 cat >"$temp" <<EOF
URLS=http://127.0.0.1:$port
Tracker__DataDir=$DATA_DIR
Tracker__BasePath=/PitzotzStory
Tracker__SecureCookies=true
ASPNETCORE_ENVIRONMENT=Production
EOF
 install_for_user 0600 "$temp" "$ENV_FILE"
 rm -f "$temp"
}
port_value() { local value; value="$(env_value URLS)"; printf '%s\n' "${value##*:}"; }

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



clone_repository() {
    local repo_url="$1" destination="$2" token="${PITZOTZSTORY_GITHUB_TOKEN:-${MEOWDB_GITHUB_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}}" encoded permissions clone_status=0 auth_file=""
    if [[ -n "${GITHUB_TOKEN_FILE:-}" ]]; then
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
        as_user env GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 --branch "$REF" "$repo_url" "$destination"
        return
    fi
    if [[ "$repo_url" != https://github.com/* ]]; then
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
        git clone --quiet --depth 1 --branch "$REF" "$repo_url" "$destination" || clone_status=$?
    if ! as_user rm -f "$auth_file"; then
        echo "Could not remove the temporary GitHub authentication file: $auth_file" >&2
        clone_status=1
    fi
    token=""
    encoded=""
    auth_file=""
    return "$clone_status"
}


stage_release() {
 local stage sdk node_bin runtime
 case "$(uname -m)" in x86_64) runtime=linux-x64;; aarch64|arm64) runtime=linux-arm64;; *) echo 'Only Linux x64 and arm64 are supported.' >&2; return 1;; esac
 stage="$(as_user mktemp -d "$SHARE_DIR/.stage.XXXXXX")"
 if [[ -n "$SOURCE" ]]; then
  [[ -d "$SOURCE" && -f "$SOURCE/backend/MeowDb.Tracker/MeowDb.Tracker.csproj" ]] || { echo 'Invalid --source checkout.' >&2; return 1; }
  if ! as_user tar -C "$SOURCE" --exclude=.git --exclude=node_modules --exclude=bin --exclude=obj --exclude=wwwroot --exclude=artifacts --exclude=data -cf - . | as_user tar -C "$stage" -xf -; then return 1; fi
 else
  local repo_url="$REPO"
  if [[ "$repo_url" != https://* && "$repo_url" != git@* && "$repo_url" != ssh://* ]]; then repo_url="https://github.com/${repo_url%.git}.git"; fi
  if ! clone_repository "$repo_url" "$stage" >&2; then
   as_user rm -rf "$stage"
   echo 'Clone failed. For a private GitHub repository, supply a read-access PAT (see --help) or configure SSH.' >&2
   return 1
  fi
 fi
 [[ -f "$stage/frontend/package-lock.json" ]] || { echo 'Frontend lockfile missing.' >&2; return 1; }
 node_bin="$(ensure_node)" || return 1
 sdk="$(ensure_dotnet_sdk)" || return 1
 as_user env PATH="$node_bin:$PATH" npm --prefix "$stage/frontend" ci --no-fund --no-audit >&2 || return 1
 as_user env PATH="$node_bin:$PATH" npm --prefix "$stage/frontend" run build >&2 || return 1
 as_user env DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 "$sdk" publish "$stage/backend/MeowDb.Tracker/MeowDb.Tracker.csproj" -c Release -r "$runtime" --self-contained true -p:RuntimeFrameworkVersion="$DOTNET_RUNTIME_VERSION" -o "$stage/publish" >&2 || return 1
 [[ -x "$stage/publish/MeowDb.Tracker" && -f "$stage/publish/wwwroot/index.html" && -f "$stage/publish/wwwroot/icon-192.png" ]] || return 1
 printf '%s\n' "$stage"
}
# The companion never modifies the existing ARR FlareSolverr service.
companion_prepare() {
 local release="$1" module load exec runtime py="" dependency native="$target_home/flaresolverr"
 for module in cozy_browser mesos_browser browser_lifecycle; do
  [[ -f "$release/publish/integrations/cozy-flaresolverr/$module.py" ]] || { echo "Missing companion module: $module.py" >&2; return 1; }
 done
 load="$(systemctl_user show "$COMPANION_NAME" -p LoadState --value 2>/dev/null || true)"
 if [[ -n "$load" && "$load" != not-found ]]; then
  [[ -f "$COMPANION_UNIT" && ! -L "$COMPANION_UNIT" ]] || { echo 'Companion uses a nonstandard service unit; update it manually. No service was changed.' >&2; return 1; }
  exec="$(systemctl_user show "$COMPANION_NAME" -p ExecStart --value)" || return 1
  [[ "$exec" == *"$COMPANION_DIR/cozy_browser.py"* ]] || { echo 'Existing companion has a custom entry point; update it manually. No service was changed.' >&2; return 1; }
  return 0
 fi
 if [[ -x "$native/venv/bin/python" && -f "$native/src/flaresolverr_service.py" && -f "$native/package.json" ]] &&
    as_user "$native/venv/bin/python" -c 'import json,sys;sys.exit(json.load(open(sys.argv[1])).get("version") != sys.argv[2])' "$native/package.json" "$COMPANION_VERSION"; then
  COMPANION_RUNTIME="$native"
  return 0
 fi
 if $SUDO_MODE; then
  if ! command -v python3 >/dev/null || ! command -v Xvfb >/dev/null || ! python3 -c 'import venv,ensurepip,sys;assert sys.version_info >= (3,11)' >/dev/null 2>&1; then
   apt-get install -y python3 python3-venv xvfb || return 1
  fi
  if ! command -v chromium >/dev/null && ! command -v chromium-browser >/dev/null && ! command -v google-chrome >/dev/null; then
   apt-get install -y chromium || apt-get install -y chromium-browser || return 1
  fi
 fi
 command -v Xvfb >/dev/null || { echo 'Install Xvfb first, or run install through sudo.' >&2; return 1; }
 command -v chromium >/dev/null || command -v chromium-browser >/dev/null || command -v google-chrome >/dev/null || { echo 'Install Chromium/Chrome first, or run install through sudo.' >&2; return 1; }
 for dependency in python3.13 python3.12 python3.11 python3; do
  if as_user "$dependency" -c 'import venv,ensurepip,sys;assert sys.version_info >= (3,11)' >/dev/null 2>&1; then py="$dependency"; break; fi
 done
 [[ -n "$py" ]] || { echo 'Companion setup needs Python 3.11+ and python3-venv. Install them first, or run through sudo.' >&2; return 1; }
 runtime="$SHARE_DIR/companion-runtime/v$COMPANION_VERSION"
 if [[ ! -f "$runtime/.ready" || ! -x "$runtime/venv/bin/python" ]]; then
  # Build at the final path because venv launchers contain absolute paths.
  as_user mkdir -p "$SHARE_DIR/companion-runtime" || return 1
  [[ ! -e "$runtime" ]] || as_user mv "$runtime" "$BACKUP_DIR/incomplete-companion-$(date +%Y%m%d-%H%M%S)" || return 1
  as_user env GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 --branch "v$COMPANION_VERSION" https://github.com/FlareSolverr/FlareSolverr.git "$runtime" || return 1
  as_user "$py" -m venv "$runtime/venv" || return 1
  as_user "$runtime/venv/bin/python" -m pip install -r "$runtime/requirements.txt" || return 1
  as_user touch "$runtime/.ready" || return 1
 fi
 COMPANION_RUNTIME="$runtime"
}
companion_snapshot() {
 local backup="$1"
 as_user mkdir -p "$backup" || return 1
 [[ ! -d "$COMPANION_DIR" ]] || as_user cp -a "$COMPANION_DIR" "$backup/config" || return 1
 [[ ! -f "$COMPANION_UNIT" ]] || as_user cp -a "$COMPANION_UNIT" "$backup/unit" || return 1
 [[ ! -d "$COMPANION_UNIT.d" ]] || as_user cp -a "$COMPANION_UNIT.d" "$backup/dropins" || return 1
 if systemctl_user is-active --quiet "$COMPANION_NAME"; then as_user touch "$backup/was-active" || return 1; fi
 as_user touch "$backup/complete"
}
companion_health() {
 local deadline=$((SECONDS + 90)) pid port
 while ((SECONDS < deadline)); do
  pid="$(systemctl_user show "$COMPANION_NAME" -p MainPID --value 2>/dev/null || true)"
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
   # Read only PORT, honoring custom EnvironmentFiles without printing secrets.
   port="$(as_user python3 -c 'import sys;d=dict(x.split(b"=",1) for x in open("/proc/"+sys.argv[1]+"/environ","rb").read().split(b"\0") if b"=" in x);p=d.get(b"PORT",b"8191").decode();print(p if p.isdigit() and 0<int(p)<65536 else "")' "$pid" 2>/dev/null || true)"
   if [[ -n "$port" ]] && curl -fsS --max-time 3 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then COMPANION_URL="http://127.0.0.1:$port"; return 0; fi
  fi
  sleep 2
 done
 echo 'Companion did not become healthy; inspect journalctl --user -u pitzotzstory-companion.' >&2
 return 1
}
companion_apply() {
 local release="$1" module temp port=8199 new=false
 [[ -n "${COMPANION_RUNTIME:-}" ]] && new=true
 as_user mkdir -p "$COMPANION_DIR" "$COMPANION_UNIT.d" || return 1
 as_user chmod 700 "$COMPANION_DIR" || return 1
 if ! $new; then systemctl_user stop "$COMPANION_NAME" || return 1; fi
 for module in cozy_browser mesos_browser browser_lifecycle; do
  install_for_user 0600 "$release/publish/integrations/cozy-flaresolverr/$module.py" "$COMPANION_DIR/$module.py" || return 1
 done
 temp="$(mktemp)" || return 1
 printf '[Service]\nKillMode=control-group\nTimeoutStopSec=10\n' >"$temp"
 install_for_user 0644 "$temp" "$COMPANION_UNIT.d/90-browser-lifecycle.conf" || { rm -f "$temp"; return 1; }
 rm -f "$temp"
 if $new; then
  if [[ ! -f "$COMPANION_DIR/env" ]]; then
   if ss -Htan | awk '{print $4}' | grep -Eq '(^|:)8199$'; then
    port=""
    for _ in {1..300}; do
     port="$(shuf -i 18000-29999 -n 1)"
     if ! ss -Htan | awk '{print $4}' | grep -Eq "(^|:)$port$"; then break; fi
     port=""
    done
    [[ -n "$port" ]] || { echo 'No free companion port found.' >&2; return 1; }
   fi
   temp="$(mktemp)" || return 1
   printf 'HOST=127.0.0.1\nPORT=%s\nLOG_LEVEL=warn\nLOG_HTML=false\nHEADLESS=true\n' "$port" >"$temp"
   install_for_user 0600 "$temp" "$COMPANION_DIR/env" || { rm -f "$temp"; return 1; }
   rm -f "$temp"
  fi
  temp="$(mktemp)" || return 1
  cat >"$temp" <<EOF
# Managed by pitzotzstory.sh
[Unit]
Description=PitzotzStory marketplace browser companion
Wants=network-online.target
After=network-online.target
[Service]
Type=exec
EnvironmentFile=$COMPANION_DIR/env
Environment="PYTHONPATH=$COMPANION_RUNTIME/src"
Environment="TRACKER_BROWSER_STATE_DIR=$target_home/.local/state/pitzotzstory-marketplace"
WorkingDirectory=$COMPANION_RUNTIME
ExecStart="$COMPANION_RUNTIME/venv/bin/python" -u "$COMPANION_DIR/cozy_browser.py"
Restart=on-failure
RestartSec=5
KillMode=control-group
TimeoutStopSec=10
UMask=0077
[Install]
WantedBy=default.target
EOF
  install_for_user 0644 "$temp" "$COMPANION_UNIT" || { rm -f "$temp"; return 1; }
  rm -f "$temp"
 fi
 systemctl_user daemon-reload || return 1
 if $new; then systemctl_user enable --now "$COMPANION_NAME" || return 1
 else systemctl_user start "$COMPANION_NAME" || return 1; fi
 companion_health
}
companion_restore() {
 local backup="$1"
 [[ -f "$backup/complete" ]] || return 0
 if systemctl_user is-active --quiet "$COMPANION_NAME"; then
  systemctl_user stop "$COMPANION_NAME" || return 1
 else systemctl_user stop "$COMPANION_NAME" 2>/dev/null || true; fi
 # Quarantine partial code; browser credentials and caches are elsewhere.
 [[ ! -d "$COMPANION_DIR" ]] || as_user mv "$COMPANION_DIR" "$backup/failed-config" || return 1
 [[ ! -d "$COMPANION_UNIT.d" ]] || as_user mv "$COMPANION_UNIT.d" "$backup/failed-dropins" || return 1
 if [[ -f "$backup/unit" ]]; then install_for_user 0644 "$backup/unit" "$COMPANION_UNIT" || return 1
 else systemctl_user disable "$COMPANION_NAME" 2>/dev/null || true; as_user rm -f "$COMPANION_UNIT" || return 1; fi
 [[ ! -d "$backup/config" ]] || as_user cp -a "$backup/config" "$COMPANION_DIR" || return 1
 [[ ! -d "$backup/dropins" ]] || as_user cp -a "$backup/dropins" "$COMPANION_UNIT.d" || return 1
 systemctl_user daemon-reload || return 1
 if [[ -f "$backup/was-active" ]]; then systemctl_user start "$COMPANION_NAME" && companion_health || return 1; fi
 return 0
}

write_unit() {
 local temp
 temp="$(mktemp)"
 cat >"$temp" <<EOF
[Unit]
Description=PitzotzStory (React, API, marketplace monitor and push)
Wants=network-online.target
After=network-online.target
[Service]
Type=exec
EnvironmentFile=$ENV_FILE
WorkingDirectory=$APP_DIR/publish
ExecStart=$APP_DIR/publish/MeowDb.Tracker
Restart=on-failure
RestartSec=5
TimeoutStopSec=60
NoNewPrivileges=true
PrivateTmp=true
UMask=0077
[Install]
WantedBy=default.target
EOF
 install_for_user 0644 "$temp" "$UNIT_FILE"
 rm -f "$temp"
 systemctl_user daemon-reload
}
stop_service() { systemctl_user stop "$APP_NAME" 2>/dev/null || true; }
start_service() { systemctl_user enable --now "$APP_NAME"; }
health_wait() {
 local port deadline
 port="$(port_value)"; deadline=$((SECONDS + 90))
 while ((SECONDS < deadline)); do
  if curl -fsS --max-time 3 "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then return 0; fi
  sleep 2
 done
 return 1
}
snapshot_state() {
 as_user mkdir -p "$1"
 as_user tar -C "$target_home" -czf "$1/state.tar.gz" ".config/$APP_NAME" ".local/share/$APP_NAME/data"
}
restore_state() {
 local archive="$1" quarantine="$2"
 as_user mkdir -p "$quarantine"
 [[ ! -d "$CONFIG_DIR" ]] || as_user mv "$CONFIG_DIR" "$quarantine/config"
 [[ ! -d "$DATA_DIR" ]] || as_user mv "$DATA_DIR" "$quarantine/data"
 as_user tar -C "$target_home" -xzf "$archive"
}
configure_nginx() {
 $SUDO_MODE || return 0
 $NO_PROXY && return 0
 command -v nginx >/dev/null || { echo 'NGINX not installed; use --no-proxy or install nginx.' >&2; return 1; }
 local port temp backup=""
 port="$(port_value)"; temp="$(mktemp)"
 mkdir -p /etc/nginx/apps
 [[ ! -f "$NGINX_FILE" ]] || { backup="$(mktemp)"; cp "$NGINX_FILE" "$backup"; }
 cat >"$temp" <<EOF
location = /meowdb-tracker { return 308 /PitzotzStory/\$is_args\$args; }
location ~ ^/meowdb-tracker/(.*)$ { return 308 /PitzotzStory/\$1\$is_args\$args; }
location = /PitzotzStory { return 308 /PitzotzStory/\$is_args\$args; }
location /PitzotzStory/ {
    # The application authenticates every user through Emby or the local admin.
    auth_basic off;
    proxy_pass http://127.0.0.1:$port/;
    proxy_http_version 1.1;
    proxy_set_header Host \$http_host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_buffering off;
    # Encrypted instance backups allow 64 MB plus multipart headers.
    client_max_body_size 65m;
    proxy_redirect off;
}
EOF
 install -m 0644 "$temp" "$NGINX_FILE"; rm -f "$temp"
 local legacy_nginx="/etc/nginx/apps/meowdb-tracker.conf" legacy_backup=""
 if [[ -f "$legacy_nginx" ]]; then legacy_backup="$(mktemp)"; mv "$legacy_nginx" "$legacy_backup"; fi
 if nginx -t; then systemctl reload nginx; [[ -z "$legacy_backup" ]] || rm -f "$legacy_backup"; [[ -z "$backup" ]] || rm -f "$backup";
 else
  if [[ -n "$backup" ]]; then cp "$backup" "$NGINX_FILE"; rm -f "$backup"; else rm -f "$NGINX_FILE"; fi
  [[ -z "$legacy_backup" ]] || mv "$legacy_backup" "$legacy_nginx"
  echo 'NGINX configuration failed validation; previous configuration restored.' >&2; return 1
 fi
}
configure_dashboard() {
 $SUDO_MODE || return 0
 $NO_PROXY && return 0
 [[ -d /opt/swizzin/core ]] || { echo 'Swizzin not found; skipping dashboard.'; return 0; }
 mkdir -p "$(dirname "$PANEL_PROFILES")" /install
 touch "$PANEL_PROFILES"
 if grep -q '^class meowdbtracker_meta:' "$PANEL_PROFILES"; then
  local migrated_panel; migrated_panel="$(mktemp)"
  awk '/^class meowdbtracker_meta:/ {skip=1;next} /^class / {skip=0} !skip {print}' "$PANEL_PROFILES" >"$migrated_panel"
  install -m 0644 "$migrated_panel" "$PANEL_PROFILES"; rm -f "$migrated_panel"
 fi
 rm -f /install/.meowdbtracker.lock /opt/swizzin/static/img/apps/meowdb-tracker.png
 if ! grep -q '^class pitzotzstory_meta:' "$PANEL_PROFILES"; then
  cat >>"$PANEL_PROFILES" <<'EOF'

class pitzotzstory_meta:
    name = "pitzotzstory"
    process = "MeowDb.Tracker"
    pretty_name = "PitzotzStory"
    baseurl = "/PitzotzStory"
    systemd = "pitzotzstory"
    img = "pitzotzstory"
    runas = "user"
EOF
 fi
 install -D -m 0644 "$APP_DIR/publish/wwwroot/icon-192.png" /opt/swizzin/static/img/apps/pitzotzstory.png
 touch /install/.pitzotzstory.lock
 systemctl restart panel 2>/dev/null || true
}
remove_proxy() {
 $SUDO_MODE || { echo 'Run uninstall through sudo to also remove nginx/panel entries.'; return 0; }
 rm -f "$NGINX_FILE" /install/.pitzotzstory.lock /opt/swizzin/static/img/apps/pitzotzstory.png
 if [[ -f "$PANEL_PROFILES" ]]; then
  local temp; temp="$(mktemp)"
  awk '/^class pitzotzstory_meta:/ { skip=1; next } /^class / { skip=0 } !skip { print }' "$PANEL_PROFILES" >"$temp"
  install -m 0644 "$temp" "$PANEL_PROFILES"; rm -f "$temp"
 fi
 if command -v nginx >/dev/null && nginx -t; then systemctl reload nginx; fi
 systemctl restart panel 2>/dev/null || true
}
show_status() {
 echo "PitzotzStory: $(systemctl_user is-active "$APP_NAME" 2>/dev/null || true)"
 echo "  URL: https://$(hostname -f)/PitzotzStory/"
 echo "  Loopback port: $(port_value)"
 echo "  Code: $APP_DIR"
 echo "  Config: $ENV_FILE"
 echo "  Data and encryption keys: $DATA_DIR"
 echo "  Backups: $BACKUP_DIR"
 echo "  Companion: $(systemctl_user is-active "$COMPANION_NAME" 2>/dev/null || true)"
 echo "  Companion modules: $COMPANION_DIR"
 if [[ -n "${COMPANION_URL:-}" ]]; then echo "  Companion URL: $COMPANION_URL (set Marketplace companion URL and Mesos Watch URL in Settings)"; fi
 echo '  Companion logs: journalctl --user -u pitzotzstory-companion -f'
 if [[ -f "$DATA_DIR/setup-code" ]]; then echo "  First setup: read $DATA_DIR/setup-code and enter it in the browser."; fi
 echo '  Logs: journalctl --user -u pitzotzstory -f'
 echo '  nginx/panel setup requires sudo. HTTPS is required for production sign-in and Web Push.'
}
install_app() {
 check_dependencies; ensure_dirs; write_env
 [[ ! -f "$LOCK_FILE" ]] || { echo 'Already installed; use upgrade.' >&2; return 1; }
 local stage backup
 stage="$(stage_release)" || { echo 'Build failed; active service was not changed.' >&2; return 1; }
 companion_prepare "$stage" || { echo 'Companion preparation failed; install cancelled.' >&2; return 1; }
 backup="$BACKUP_DIR/pre-install-companion-$(date +%Y%m%d-%H%M%S)"
 companion_snapshot "$backup/companion" || return 1
 stop_service
 [[ ! -e "$APP_DIR" ]] || as_user mv "$APP_DIR" "$BACKUP_DIR/incomplete-$(date +%Y%m%d-%H%M%S)"
 as_user mv "$stage" "$APP_DIR"
 if ! companion_apply "$APP_DIR" || ! write_unit || ! start_service || ! health_wait; then
  stop_service
  companion_restore "$backup/companion" || echo 'Companion restoration failed; inspect its journal.' >&2
  echo 'Startup failed. Inspect the user journal.' >&2; return 1
 fi
 as_user touch "$LOCK_FILE"
 configure_nginx; configure_dashboard; show_status
}
upgrade_app() {
 [[ -f "$LOCK_FILE" && -d "$APP_DIR" ]] || { echo 'Install first.' >&2; return 1; }
 check_dependencies; ensure_dirs
 local stage backup
 stage="$(stage_release)" || { echo 'Build failed; active service untouched.' >&2; return 1; }
 companion_prepare "$stage" || { echo 'Companion preparation failed; active services untouched.' >&2; return 1; }
 backup="$BACKUP_DIR/pre-upgrade-$(date +%Y%m%d-%H%M%S)"
 companion_snapshot "$backup/companion" || { echo 'Companion backup failed; upgrade cancelled.' >&2; return 1; }
 stop_service
 if ! snapshot_state "$backup"; then start_service; echo 'Backup failed; upgrade cancelled.' >&2; return 1; fi
 if ! as_user mv "$APP_DIR" "$backup/app"; then start_service; return 1; fi
 if ! as_user mv "$stage" "$APP_DIR"; then as_user mv "$backup/app" "$APP_DIR"; start_service; return 1; fi
 if companion_apply "$APP_DIR" && write_unit && start_service && health_wait; then
  echo "Upgrade complete; rollback retained at $backup"
  echo "Companion updated and ready at $COMPANION_URL"
  configure_nginx; configure_dashboard; return 0
 fi
 echo 'Startup failed; restoring previous code, database, keys and companion.' >&2
 stop_service
 companion_restore "$backup/companion" || echo 'Companion restoration failed; inspect its journal.' >&2
 as_user mv "$APP_DIR" "$backup/failed-app"
 as_user mv "$backup/app" "$APP_DIR"
 restore_state "$backup/state.tar.gz" "$backup/failed-state"
 write_unit; start_service
 health_wait || echo 'Rollback also failed; inspect the journal.' >&2
 return 1
}
rollback_app() {
 local backup="" candidate current
 for candidate in "$BACKUP_DIR"/*; do
  [[ -d "$candidate/app" && -f "$candidate/state.tar.gz" ]] || continue
  if [[ -z "$backup" || "$candidate" -nt "$backup" ]]; then backup="$candidate"; fi
 done
 [[ -n "$backup" && -d "$APP_DIR" ]] || { echo 'No usable rollback backup.' >&2; return 1; }
 current="$BACKUP_DIR/pre-rollback-$(date +%Y%m%d-%H%M%S)"
 companion_snapshot "$current/companion" || return 1
 stop_service
 if ! snapshot_state "$current"; then start_service; return 1; fi
 as_user mv "$APP_DIR" "$current/app"
 as_user mv "$backup/app" "$APP_DIR"
 restore_state "$backup/state.tar.gz" "$current/displaced-state"
 if companion_restore "$backup/companion" && write_unit && start_service && health_wait; then echo "Rollback succeeded. Displaced state is in $current"; return 0; fi
 stop_service
 companion_restore "$current/companion" || echo 'Companion restoration failed; inspect its journal.' >&2
 as_user mv "$APP_DIR" "$backup/failed-rollback-app"
 as_user mv "$current/app" "$APP_DIR"
 restore_state "$current/state.tar.gz" "$backup/failed-rollback-state"
 write_unit; start_service
 health_wait || echo 'Restored version is unhealthy; inspect the journal.' >&2
 return 1
}
uninstall_app() {
 local confirmation path canonical_home service load active namespace task
 local state="$target_home/.local/state/pitzotzstory-marketplace"
 local -a paths=(
  "$target_home/.local/share/pitzotzstory" "$target_home/.config/pitzotzstory"
  "$target_home/.config/pitzotzstory-companion" "$state"
  "$target_home/.config/systemd/user/pitzotzstory.service"
  "$target_home/.config/systemd/user/pitzotzstory.service.d"
  "${UNIT_DIR}/pitzotzstory-companion.service"
  "${UNIT_DIR}/pitzotzstory-companion.service.d"
 )
 if ! $ASSUME_YES; then
  echo 'This removes PitzotzStory and its marketplace companion, ALL accounts, data, encryption keys, backups and browser state. Export your backup elsewhere first.'
  read -r -p 'Type REMOVE to uninstall completely: ' confirmation || return 1
  [[ "$confirmation" == REMOVE ]] || { echo 'Uninstall cancelled. Nothing changed.'; return 0; }
 fi
 if ! $SUDO_MODE && { [[ -e "$NGINX_FILE" || -e /install/.pitzotzstory.lock || -e /opt/swizzin/static/img/apps/pitzotzstory.png ]] || { [[ -f "$PANEL_PROFILES" ]] && grep -q '^class pitzotzstory_meta:' "$PANEL_PROFILES"; }; }; then
  echo 'Run uninstall through sudo from your normal user to remove nginx/panel entries too. Nothing was removed.' >&2; return 1
 fi
 # Validate every recursive target before stopping services or deleting anything.
 canonical_home="$(readlink -f -- "$target_home")" || return 1
 [[ -n "$canonical_home" && "$canonical_home" != / ]] || return 1
 for path in "${paths[@]}" "$target_home/.config/systemd/user/default.target.wants"; do
  [[ "$(readlink -m -- "$path")" == "$canonical_home${path#"$target_home"}" ]] || {
   echo "Refusing cleanup through a redirected path: $path. Nothing was removed." >&2; return 1;
  }
 done
 # Includes older manually installed companion units without a managed marker.
 for service in "$APP_NAME" "$COMPANION_NAME"; do
  load="$(systemctl_user show "$service" -p LoadState --value)" || return 1
  [[ "$load" != not-found ]] || continue
  systemctl_user disable "$service" || return 1
  systemctl_user stop "$service" || { echo "Could not stop $service; files retained." >&2; return 1; }
  # Scope cleanup to this unit; never pkill Chromium used by other applications.
  systemctl_user kill --kill-who=all --signal=SIGKILL "$service" 2>/dev/null || true
  active="$(systemctl_user show "$service" -p ActiveState --value)" || return 1
  [[ "$active" == inactive || "$active" == failed ]] || { echo "$service is still running; files retained." >&2; return 1; }
 done
 # Interrupted browser tasks use this installation's hashed state-directory namespace.
 namespace="$(printf '%s' "$(readlink -m -- "$state")" | sha256sum | cut -c1-12)" || return 1
 for task in /tmp/mt-"$target_uid"-"$namespace"-*; do
  [[ -d "$task" && ! -L "$task" ]] || continue
  [[ "$(stat -c %u -- "$task")" == "$target_uid" ]] || continue
  as_user rm -rf -- "$task" || return 1
 done
 for path in "${paths[@]}"; do as_user rm -rf -- "$path" || return 1; done
 # Remove dangling enablement links too, including a previously deleted unit.
 as_user rm -f -- "$target_home/.local/share/meowdb-tracker" "$target_home/.config/meowdb-tracker" "$target_home/.config/cozy-flaresolverr" "$target_home/.local/state/meowdb-marketplace" "$UNIT_DIR/meowdb-tracker.service" "$UNIT_DIR/cozy-flaresolverr.service"
 as_user rm -rf -- "$UNIT_DIR/cozy-flaresolverr.service.d"
 as_user rm -f -- "$UNIT_DIR/default.target.wants/$APP_NAME.service" "$UNIT_DIR/default.target.wants/$COMPANION_NAME.service" || return 1
 systemctl_user daemon-reload || return 1
 systemctl_user reset-failed "$APP_NAME" "$COMPANION_NAME" 2>/dev/null || true
 for path in "$target_home/.local/share/"pitzotzstory-migration-*.tar.gz; do
  [[ ! -f "$path" || -L "$path" ]] || as_user rm -f -- "$path" || return 1
 done
 remove_proxy || return 1
 echo 'Completely removed PitzotzStory and its companion, including data, keys, backups, browser state and dedicated runtimes.'
 echo 'Separate FlareSolverr/ARR installations and shared system packages were not removed.'
}
purge_app() { uninstall_app; }
if [[ -z "$ACTION" ]]; then
 echo 'PitzotzStory: install | upgrade | rollback | show | uninstall | purge | exit'
 read -r -p 'Action: ' ACTION
fi
case "$ACTION" in
 install) migrate_brand; install_app;; upgrade) migrate_brand; upgrade_app;; rollback) rollback_app;; show) show_status;; uninstall) uninstall_app;; purge) purge_app;; exit) exit 0;; *) usage; exit 2;;
esac
