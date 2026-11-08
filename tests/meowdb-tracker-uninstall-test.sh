#!/usr/bin/env bash
# Destructive behavior is tested only in an isolated fixture home; systemd/nginx are mocked.
set -Eeuo pipefail
script_dir="$(cd "$(dirname "$0")/.." && pwd)"
installer="$script_dir/pitzotzstory.sh"
bash -n "$installer"
source <(awk '/^as_user\(\)/ { printing=1 } /^if \[\[ -z "\$ACTION"/ { exit } printing { print }' "$installer")
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/meowdb-uninstall-test.XXXXXX")"
SUDO_MODE=false
ASSUME_YES=true
APP_NAME=pitzotzstory
COMPANION_NAME=pitzotzstory-companion
target_uid="$(id -u)"
systemctl_user() {
 printf '%s\n' "$*" >>"$events"
 if [[ "$1" == show ]]; then
  if [[ "$*" == *LoadState* ]]; then
   if [[ -f "$UNIT_DIR/$2.service" ]]; then echo loaded; else echo not-found; fi
  else echo inactive; fi
 elif [[ "$1" == stop && "${stop_fails:-false}" == true ]]; then return 1; fi
}
remove_proxy() { printf 'proxy removed\n' >>"$events"; }
fixture() {
 target_home="$sandbox/$1"
 UNIT_DIR="$target_home/.config/systemd/user"
 NGINX_FILE="$sandbox/no-nginx"; PANEL_PROFILES="$sandbox/no-panel"
 events="$target_home/events"
 mkdir -p "$UNIT_DIR/default.target.wants" "$UNIT_DIR/$APP_NAME.service.d" "$UNIT_DIR/$COMPANION_NAME.service.d" \
  "$target_home/.config/pitzotzstory" "$target_home/.config/pitzotzstory-companion" \
  "$target_home/.local/share/pitzotzstory/data" "$target_home/.local/share/pitzotzstory/backups" \
  "$target_home/.local/share/pitzotzstory/companion-runtime" "$target_home/.local/state/pitzotzstory-marketplace" "$target_home/flaresolverr"
 for name in "$APP_NAME" "$COMPANION_NAME"; do
  printf 'Legacy unit without managed marker\n' >"$UNIT_DIR/$name.service"
  ln -s "../$name.service" "$UNIT_DIR/default.target.wants/$name.service"
 done
 touch "$target_home/.local/share/pitzotzstory/data/database" "$target_home/.local/share/pitzotzstory/backups/private-backup" \
  "$target_home/.local/state/pitzotzstory-marketplace/credentials" "$target_home/flaresolverr/keep-arr-runtime" "$UNIT_DIR/flaresolverr.service"
}
fixture complete
namespace="$(printf '%s' "$(readlink -m -- "$target_home/.local/state/pitzotzstory-marketplace")" | sha256sum | cut -c1-12)"
owned_task="$(mktemp -d "/tmp/mt-$target_uid-$namespace-XXXXXX")"
foreign_task="$(mktemp -d "/tmp/mt-$target_uid-other-XXXXXX")"
uninstall_app
[[ ! -e "$owned_task" && -d "$foreign_task" ]]
[[ ! -e "$target_home/.local/share/pitzotzstory" && ! -e "$target_home/.config/pitzotzstory" && ! -e "$target_home/.config/pitzotzstory-companion" && ! -e "$target_home/.local/state/pitzotzstory-marketplace" ]]
[[ ! -e "$UNIT_DIR/$COMPANION_NAME.service.d" && ! -L "$UNIT_DIR/default.target.wants/$COMPANION_NAME.service" ]]
[[ -f "$target_home/flaresolverr/keep-arr-runtime" && -f "$UNIT_DIR/flaresolverr.service" ]]
grep -q '^stop pitzotzstory-companion$' "$events"
! grep -q '^stop flaresolverr$' "$events"
uninstall_app # Repeat is safe even with no services/files left.
fixture failed-stop
stop_fails=true
if uninstall_app; then echo 'FAIL: failed stop allowed removal'; exit 1; fi
[[ -f "$target_home/.local/share/pitzotzstory/data/database" && -f "$UNIT_DIR/$COMPANION_NAME.service" ]]
stop_fails=false
fixture redirected
mv "$target_home/.config/pitzotzstory-companion" "$sandbox/shared-config"
touch "$sandbox/shared-config/keep"
ln -s "$sandbox/shared-config" "$target_home/.config/pitzotzstory-companion"
if uninstall_app; then echo 'FAIL: redirected cleanup accepted'; exit 1; fi
[[ -f "$sandbox/shared-config/keep" && ! -e "$events" ]]
fixture cancel
ASSUME_YES=false
uninstall_app <<< 'no'
[[ -f "$target_home/.local/share/pitzotzstory/data/database" && ! -e "$events" ]]
ASSUME_YES=true
purge_app
[[ ! -d "$target_home/.local/share/pitzotzstory" ]]
printf 'PASS: complete app/legacy companion removal, ARR preservation, repeated uninstall, stop failure, redirected-path refusal, confirmation and purge alias. Fixtures: %s\n' "$sandbox"
