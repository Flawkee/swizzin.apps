#!/usr/bin/env bash
set -Eeuo pipefail
source <(awk '/^as_user\(\)/ {printing=1} /^if \[\[ -z "\$ACTION"/ {exit} printing {print}' /repo/pitzotzstory.sh)
target_home=$(mktemp -d); target_uid=$(id -u); SUDO_MODE=false
APP_NAME=pitzotzstory; COMPANION_NAME=pitzotzstory-companion
CONFIG_DIR="$target_home/.config/pitzotzstory"; SHARE_DIR="$target_home/.local/share/pitzotzstory"; ENV_FILE="$CONFIG_DIR/env"
UNIT_DIR="$target_home/.config/systemd/user"; UNIT_FILE="$UNIT_DIR/pitzotzstory.service"; COMPANION_DIR="$target_home/.config/pitzotzstory-companion"; COMPANION_UNIT="$UNIT_DIR/pitzotzstory-companion.service"
systemctl_user(){ printf '%s\n' "$*" >>"$target_home/events"; }
mkdir -p "$target_home/.local/share/meowdb-tracker/data/keys" "$target_home/.config/meowdb-tracker" "$target_home/.config/cozy-flaresolverr" "$UNIT_DIR/cozy-flaresolverr.service.d"
printf secret >"$target_home/.local/share/meowdb-tracker/data/keys/key"
printf database >"$target_home/.local/share/meowdb-tracker/data/tracker.sqlite3"
printf 'URLS=http://127.0.0.1:19123\nTracker__DataDir=%s/.local/share/meowdb-tracker/data\nTracker__BasePath=/meowdb-tracker\n' "$target_home" >"$target_home/.config/meowdb-tracker/env"
printf 'ExecStart=%s/.local/share/meowdb-tracker/app/publish/MeowDb.Tracker\n' "$target_home" >"$UNIT_DIR/meowdb-tracker.service"
printf 'ExecStart=python %s/.config/cozy-flaresolverr/cozy_browser.py\n' "$target_home" >"$UNIT_DIR/cozy-flaresolverr.service"
printf '[Service]\nEnvironment=PORT=8199\n' >"$UNIT_DIR/cozy-flaresolverr.service.d/custom.conf"
migrate_brand
[[ $(cat "$SHARE_DIR/data/keys/key") == secret && $(cat "$SHARE_DIR/data/tracker.sqlite3") == database ]]
[[ -L "$target_home/.local/share/meowdb-tracker" ]]
grep -q '^Tracker__BasePath=/PitzotzStory$' "$ENV_FILE"
grep -q '19123' "$ENV_FILE"
grep -q '.config/pitzotzstory-companion/cozy_browser.py' "$COMPANION_UNIT"
grep -q 'PORT=8199' "$COMPANION_UNIT.d/custom.conf"
grep -q 'disable meowdb-tracker cozy-flaresolverr' "$target_home/events"
migrate_brand
printf 'PASS: legacy migration preserves database, keys, ports and drop-ins; repeated migration is safe.\n'

# Recreate a legacy installation and force failure after file relocation.
systemctl_user(){ if [[ "$*" == 'enable --now pitzotzstory' ]]; then return 1; fi; }
for pair in "$SHARE_DIR:$target_home/.local/share/meowdb-tracker" "$CONFIG_DIR:$target_home/.config/meowdb-tracker" "$COMPANION_DIR:$target_home/.config/cozy-flaresolverr"; do
 new=${pair%%:*}; old=${pair#*:}; rm "$old"; mv "$new" "$old"
done
mv "$UNIT_FILE" "$UNIT_DIR/meowdb-tracker.service"; mv "$COMPANION_UNIT" "$UNIT_DIR/cozy-flaresolverr.service"; mv "$COMPANION_UNIT.d" "$UNIT_DIR/cozy-flaresolverr.service.d"
if migrate_brand; then echo 'FAIL: injected failure was accepted'; exit 1; fi
[[ -d "$target_home/.local/share/meowdb-tracker" && ! -L "$target_home/.local/share/meowdb-tracker" ]]
[[ $(cat "$target_home/.local/share/meowdb-tracker/data/keys/key") == secret ]]
[[ -f "$UNIT_DIR/meowdb-tracker.service" ]]
echo 'PASS: failed branding migration restores legacy directories, services and keys.'
