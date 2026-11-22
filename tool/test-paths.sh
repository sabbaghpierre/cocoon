#!/usr/bin/env bash
# tool/test-paths.sh — regression tests for the legacy data-path read fallback.
# Uses a temp HOME plus COCOON_DATA_ROOT / COCOON_LEGACY_DATA_ROOT overrides so
# it never touches a real installation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export COCOON_DATA_ROOT="$TMP/data"
export COCOON_LEGACY_DATA_ROOT="$TMP/legacy"
NEW="$COCOON_DATA_ROOT"
LEGACY="$COCOON_LEGACY_DATA_ROOT"
DESKTOP_DIR="$HOME/.local/share/applications"
mkdir -p "$DESKTOP_DIR" "$HOME/.local/share/icons/hicolor/128x128/apps" "$NEW" "$LEGACY"

PASS=0
FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
assert_eq() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
assert_contains() { # <desc> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1 (missing '$3' in output)"; fi
}
assert_exists() { # <desc> <path>
  if [[ -e "$2" ]]; then pass "$1"; else fail "$1 ($2 does not exist)"; fi
}
assert_absent() { # <desc> <path>
  if [[ ! -e "$2" ]]; then pass "$1"; else fail "$1 ($2 unexpectedly exists)"; fi
}

# ---- helper functions under test (sourced with env overrides in effect) ----
# shellcheck disable=SC1090
source "$ROOT/libexec/cocoon-paths.sh"

echo "== path resolution =="

mkdir -p "$NEW/chrome-both" "$LEGACY/chrome-both"
assert_eq "new profile wins when both roots have it" \
  "$NEW/chrome-both" "$(cocoon_find_profile chrome both)"

mkdir -p "$LEGACY/chrome-oldonly"
assert_eq "legacy profile used when only legacy exists" \
  "$LEGACY/chrome-oldonly" "$(cocoon_find_profile chrome oldonly)"

assert_eq "no profile anywhere resolves to the NEW root" \
  "$NEW/chrome-fresh" "$(cocoon_find_profile chrome fresh)"
assert_absent "no-dir case creates nothing in legacy root" "$LEGACY/chrome-fresh"

printf 'old log\n' >"$LEGACY/oldapp.log"
assert_eq "existing legacy log found" "$LEGACY/oldapp.log" "$(cocoon_find_log oldapp)"
assert_eq "missing log resolves to NEW root" "$NEW/newapp.log" "$(cocoon_find_log newapp)"

_silent="$(bash -c 'source "$1"' _ "$ROOT/libexec/cocoon-paths.sh" 2>/dev/null)"
assert_eq "paths helper emits no stdout on source" "" "$_silent"

echo "== doctor =="

cat >"$DESKTOP_DIR/legacyapp.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=legacyapp
Exec=$ROOT/libexec/cocoon-launch-chrome --name "legacyapp" --url "https://example.com"
Terminal=false
Type=Application
Icon=legacyapp
StartupWMClass=legacyapp
EOF
mkdir -p "$LEGACY/chrome-legacyapp" "$LEGACY/chrome-ghost"
_doctor_json="$(bash "$ROOT/libexec/cocoon-doctor" --json 2>/dev/null || true)"
assert_contains "doctor --json reports the legacy profile path" \
  "$_doctor_json" "\"profile_dir\":\"$LEGACY/chrome-legacyapp\""
assert_contains "doctor --json reports a legacy orphan dir" \
  "$_doctor_json" "\"$LEGACY/chrome-ghost\""

echo "== remove --purge =="

cat >"$DESKTOP_DIR/purgeme.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=purgeme
Exec=$ROOT/libexec/cocoon-launch-chrome --name "purgeme" --url "https://example.org"
Terminal=false
Type=Application
StartupWMClass=purgeme
EOF
mkdir -p "$NEW/chrome-purgeme" "$LEGACY/chrome-purgeme"
printf 'new log\n' >"$NEW/purgeme.log"
printf 'legacy log\n' >"$LEGACY/purgeme.log"
bash "$ROOT/bin/cocoon" remove --purge "purgeme" >/dev/null 2>&1
assert_absent "purge deletes the legacy profile" "$LEGACY/chrome-purgeme"
assert_absent "purge deletes the legacy log" "$LEGACY/purgeme.log"
assert_absent "purge deletes the new profile" "$NEW/chrome-purgeme"
assert_absent "purge deletes the new log" "$NEW/purgeme.log"

echo "== launchers =="

mkdir -p "$TMP/mockbin"
cat >"$TMP/mockbin/mockchrome" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_ARGS"
EOF
cp "$TMP/mockbin/mockchrome" "$TMP/mockbin/mockfox"
chmod +x "$TMP/mockbin/mockchrome" "$TMP/mockbin/mockfox"
export PATH="$TMP/mockbin:$PATH"
export MOCK_ARGS="$TMP/launch.args"
: >"$MOCK_ARGS"

mkdir -p "$LEGACY/chrome-legacybrowser"
bash "$ROOT/libexec/cocoon-launch-chrome" --name "legacybrowser" \
  --url "https://example.com" --browser mockchrome >/dev/null 2>&1
_args="$(cat "$MOCK_ARGS")"
assert_contains "chrome launcher passes legacy --user-data-dir" \
  "$_args" "--user-data-dir=$LEGACY/chrome-legacybrowser"
assert_exists "chrome launcher writes log to the NEW root" "$NEW/legacybrowser.log"
assert_absent "chrome launcher writes no log to the legacy root" "$LEGACY/legacybrowser.log"
assert_exists "native-host manifest written into the resolved legacy profile" \
  "$LEGACY/chrome-legacybrowser/NativeMessagingHosts/com.cocoon.open_external.json"

mkdir -p "$LEGACY/firefox-legacyfox"
bash "$ROOT/libexec/cocoon-launch-firefox" --name "legacyfox" \
  --url "https://example.org" --browser mockfox >/dev/null 2>&1
_args="$(cat "$MOCK_ARGS")"
assert_contains "firefox launcher passes legacy --profile" \
  "$_args" "--profile $LEGACY/firefox-legacyfox"
assert_exists "firefox launcher writes user.js into the resolved legacy profile" \
  "$LEGACY/firefox-legacyfox/user.js"
assert_exists "firefox launcher writes log to the NEW root" "$NEW/legacyfox.log"
assert_absent "firefox launcher writes no log to the legacy root" "$LEGACY/legacyfox.log"

echo "== native messaging host =="

_msg='{"url":"https://example.com"}'
_bytes="$(printf "\\$(printf '%03o' "${#_msg}")\\000\\000\\000%s" "$_msg" |
  timeout 5 bash "$ROOT/libexec/cocoon-open-external" 2>/dev/null | od -An -tu1 | tr -s ' ')"
assert_contains "native host stdout is a clean framed reply (no source noise)" \
  "$_bytes" "11 0 0 0"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
