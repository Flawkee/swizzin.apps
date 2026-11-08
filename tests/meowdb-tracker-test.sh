#!/usr/bin/env bash
# Exercises upgrade/rollback against a sandbox; never touches systemd/nginx.
set -Eeuo pipefail
script_dir="$(cd "$(dirname "$0")/.." && pwd)"
installer="$script_dir/pitzotzstory.sh"
if LC_ALL=C grep -q $'\r' "$installer"; then
 echo 'FAIL: installer must use Unix LF line endings.' >&2
 exit 1
fi
bash -n "$installer"
# Load functions only; skip user detection, global setup, and the entry point.
source <(awk '/^as_user\(\)/ { printing=1 } /^if \[\[ -z "\$ACTION"/ { exit } printing { print }' "$installer")
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/meowdb-installer-test.XXXXXX")"
SUDO_MODE=false
NO_PROXY=true
APP_NAME=pitzotzstory
check_dependencies() { :; }
write_unit() { printf 'unit\n' >>"$events"; }
stop_service() { printf 'stop\n' >>"$events"; }
start_service() {
 printf 'start\n' >>"$events"
 if [[ "$(cat "$APP_DIR/version")" == broken ]]; then printf 'incompatible\n' >"$DATA_DIR/database"; fi
}
health_wait() { [[ "$(cat "$APP_DIR/version")" != broken ]]; }
stage_release() { printf '%s\n' "$next_stage"; }
configure_nginx() { :; }
configure_dashboard() { :; }
companion_prepare() { :; }
companion_snapshot() { :; }
companion_apply() { COMPANION_URL=http://127.0.0.1:8199; }
companion_restore() { :; }

scenario() {
 local version="$1"
 target_home="$sandbox/$version"
 CONFIG_DIR="$target_home/.config/$APP_NAME"
 ENV_FILE="$CONFIG_DIR/env"
 SHARE_DIR="$target_home/.local/share/$APP_NAME"
 APP_DIR="$SHARE_DIR/app"
 DATA_DIR="$SHARE_DIR/data"
 BACKUP_DIR="$SHARE_DIR/backups"
 UNIT_DIR="$target_home/.config/systemd/user"
 LOCK_FILE="$SHARE_DIR/.installed"
 events="$target_home/events"
 ensure_dirs
 mkdir -p "$APP_DIR" "$DATA_DIR/keys"
 printf 'original\n' >"$APP_DIR/version"
 printf 'database\n' >"$DATA_DIR/database"
 printf 'secret-key\n' >"$DATA_DIR/keys/key"
 printf 'URLS=http://127.0.0.1:19090\n' >"$ENV_FILE"
 touch "$LOCK_FILE"
 next_stage="$SHARE_DIR/.stage.fixture"
 mkdir -p "$next_stage"
 printf '%s\n' "$version" >"$next_stage/version"
 if [[ "$version" == broken ]]; then
  if upgrade_app; then echo 'FAIL: broken release was accepted.' >&2; exit 1; fi
  [[ "$(cat "$APP_DIR/version")" == original ]]
  [[ "$(cat "$DATA_DIR/database")" == database ]]
 else
  upgrade_app
  [[ "$(cat "$APP_DIR/version")" == updated ]]
  [[ "$(cat "$DATA_DIR/database")" == database ]]
 fi
 [[ "$(cat "$DATA_DIR/keys/key")" == secret-key ]]
 [[ "$(port_value)" == 19090 ]]
 [[ "$(grep -c start "$events")" -ge 1 ]]
 printf 'PASS: %s upgrade preserves port and keys; correct code/data activated.\n' "$version"
}
scenario updated
scenario broken
printf 'Installer upgrade and automatic rollback tests passed. Sandbox: %s\n' "$sandbox"
