#!/usr/bin/env bash
# Private-clone regression tests; no network calls or real credentials.
set -Eeuo pipefail
script_dir="$(cd "$(dirname "$0")/.." && pwd)"
installer="$script_dir/meowdb-tracker.sh"
bash -n "$installer"
source <(awk '/^as_user\(\)/ { printing=1 } /^if \[\[ -z "\$ACTION"/ { exit } printing { print }' "$installer")
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
SUDO_MODE=false
REF=main
SHARE_DIR="$sandbox/state"
mkdir -p "$SHARE_DIR" "$sandbox/bin"
export TEST_ARGS="$sandbox/args" TEST_CONFIG="$sandbox/config" TEST_RESULT=0
cat >"$sandbox/bin/git" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" >"$TEST_ARGS"
[[ "$GIT_TERMINAL_PROMPT" == 0 ]]
if [[ -n "${GIT_CONFIG_GLOBAL:-}" ]]; then
  [[ -f "$GIT_CONFIG_GLOBAL" ]]
  cp "$GIT_CONFIG_GLOBAL" "$TEST_CONFIG"
else
  : >"$TEST_CONFIG"
fi
exit "$TEST_RESULT"
EOF
chmod +x "$sandbox/bin/git"
export PATH="$sandbox/bin:$PATH"
unset MEOWDB_GITHUB_TOKEN GH_TOKEN GITHUB_TOKEN GIT_CONFIG_GLOBAL
GITHUB_TOKEN_FILE=""
clone_repository https://github.com/Flawkee/meowdb-tracker.git "$sandbox/checkout"
[[ ! -s "$TEST_CONFIG" ]]
export MEOWDB_GITHUB_TOKEN=fixture-primary GH_TOKEN=fixture-secondary GITHUB_TOKEN=fixture-third
check_auth() {
  local expected="$1"
  grep -q "Authorization: Basic $(printf 'x-access-token:%s' "$expected" | base64 | tr -d '\n')" "$TEST_CONFIG"
  ! grep -q "$expected" "$TEST_ARGS"
  [[ -z "$(find "$SHARE_DIR" -name '.git-auth.*' -print)" ]]
}
clone_repository https://github.com/Flawkee/meowdb-tracker.git "$sandbox/checkout"
check_auth fixture-primary
unset MEOWDB_GITHUB_TOKEN
clone_repository https://github.com/Flawkee/meowdb-tracker.git "$sandbox/checkout"
check_auth fixture-secondary
unset GH_TOKEN
export TEST_RESULT=22
if clone_repository https://github.com/Flawkee/meowdb-tracker.git "$sandbox/checkout"; then exit 1; else [[ $? == 22 ]]; fi
check_auth fixture-third
export TEST_RESULT=0
if clone_repository https://github.com.evil.test/repo.git "$sandbox/checkout"; then exit 1; fi
if clone_repository git@github.com:Flawkee/meowdb-tracker.git "$sandbox/checkout"; then exit 1; fi
GITHUB_TOKEN='fixture whitespace'
if clone_repository https://github.com/Flawkee/meowdb-tracker.git "$sandbox/checkout"; then exit 1; fi
GITHUB_TOKEN=fixture-third
GITHUB_TOKEN_FILE="$sandbox/token"
printf 'fixture-file\n' >"$GITHUB_TOKEN_FILE"
chmod 600 "$GITHUB_TOKEN_FILE"
# Mock Unix mode bits so this test also runs under Git Bash on NTFS.
stat() { if [[ "$*" == *"$sandbox/token"* ]]; then printf '%s\n' "$TEST_MODE"; else command stat "$@"; fi; }
TEST_MODE=600
clone_repository https://github.com/Flawkee/meowdb-tracker.git "$sandbox/checkout"
check_auth fixture-file
TEST_MODE=644
if clone_repository https://github.com/Flawkee/meowdb-tracker.git "$sandbox/checkout"; then exit 1; fi
GITHUB_TOKEN_FILE="$sandbox/missing"
if clone_repository https://github.com/Flawkee/meowdb-tracker.git "$sandbox/checkout"; then exit 1; fi
[[ -z "$(find "$SHARE_DIR" -name '.git-auth.*' -print)" ]]
printf 'PASS: private GitHub cloning, token precedence, host restriction, file validation, and cleanup on success/failure.\n'
