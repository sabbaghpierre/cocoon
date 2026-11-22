#!/usr/bin/env bash
# tool/test-browsers.sh — regression tests for custom browser binary support.
# Uses a temp HOME plus stub executables (including a path with a space) so it
# never touches a real cocoon installation.
set -euo pipefail
unset IFS GLOBIGNORE

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/libexec"
BIN="$ROOT/bin/cocoon"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$HOME/.config"
DESKTOP_DIR="$HOME/.local/share/applications"
mkdir -p "$DESKTOP_DIR" "$XDG_CONFIG_HOME"

PASS=0
FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1 (missing '$3')"; fi
}
assert_absent() {
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1 (unexpected '$3')"; fi
}
assert_exists() {
  if [[ -e "$2" ]]; then pass "$1"; else fail "$1 ($2 does not exist)"; fi
}

# ---- stubs: a path with a space, a branded Chrome 137 wrapper, ------------
# a Gecko wrapper, and an unidentifiable binary.
STUB_DIR="$TMP/bin/My Browsers"
mkdir -p "$STUB_DIR"
CHROME_STUB="$STUB_DIR/chrome wrapper"
BRANDED_STUB="$STUB_DIR/branded wrapper"
FIREFOX_STUB="$STUB_DIR/fire fox"
MYSTERY_STUB="$STUB_DIR/unknown tool"
NONEXEC="$STUB_DIR/not executable"
make_stub() { # <path> <version-line>
  cat >"$1" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then printf '%s\\n' "$2"; exit 0; fi
printf '%s\\n' "\$*" >>"\$MOCK_ARGS"
EOF
  chmod +x "$1"
}
make_stub "$CHROME_STUB" 'Chromium 120.0.6099.109'
make_stub "$BRANDED_STUB" 'Google Chrome 137.0.7151.0'
make_stub "$FIREFOX_STUB" 'Mozilla Firefox 140.0'
make_stub "$MYSTERY_STUB" 'Some Random Tool 1.0'
printf '#!/usr/bin/env bash\n' >"$NONEXEC"
export MOCK_ARGS="$TMP/launch.args"
: >"$MOCK_ARGS"

echo "== cocoon-browsers helpers =="

# shellcheck disable=SC1090
source "$LIB/cocoon-browsers"
_silent="$(bash -c 'source "$1"' _ "$LIB/cocoon-browsers" 2>/dev/null)"
assert_eq "sourcing the helper is silent" "" "$_silent"
assert_eq "is_path detects a path" "yes" \
  "$(cocoon_browser_is_path "$CHROME_STUB" && echo yes || echo no)"
assert_eq "is_path rejects a bare id" "no" \
  "$(cocoon_browser_is_path chromium && echo yes || echo no)"
assert_eq "resolve accepts an executable path with a space" "$CHROME_STUB" \
  "$(cocoon_browser_resolve "$CHROME_STUB")"
assert_eq "resolve makes a relative path absolute" "$CHROME_STUB" \
  "$(cd "$TMP" && cocoon_browser_resolve "./bin/My Browsers/chrome wrapper")"
assert_eq "resolve rejects a missing file" "" \
  "$(cocoon_browser_resolve "$STUB_DIR/missing" 2>/dev/null || true)"
if cocoon_browser_resolve "$STUB_DIR/missing" >/dev/null 2>&1; then rc=0; else rc=$?; fi
assert_eq "resolve returns non-zero for a missing file" "1" "$rc"
assert_eq "resolve rejects a non-executable file" "" \
  "$(cocoon_browser_resolve "$NONEXEC" 2>/dev/null || true)"
assert_eq "probe detects a Chromium wrapper" "chromium" \
  "$(cocoon_browser_probe_engine "$CHROME_STUB")"
assert_eq "probe detects a Firefox wrapper" "firefox" \
  "$(cocoon_browser_probe_engine "$FIREFOX_STUB")"
assert_eq "probe detects branded Chrome 137 as Chromium" "chromium" \
  "$(cocoon_browser_probe_engine "$BRANDED_STUB")"
assert_eq "probe is empty for an unknown binary" "" \
  "$(cocoon_browser_probe_engine "$MYSTERY_STUB")"
assert_eq "probe CLI reports the engine" "chromium" \
  "$(bash "$LIB/cocoon-browsers" --probe "$CHROME_STUB")"
assert_contains "probe CLI --json reports the engine and version" \
  "$(bash "$LIB/cocoon-browsers" --probe "$FIREFOX_STUB" --json)" \
  '"engine":"firefox"'

echo "== create, list, doctor =="

_create_out="$(bash "$BIN" create --name "My App" --url https://example.com \
  --engine chrome --browser-bin "$CHROME_STUB" --no-icon 2>&1)"
assert_contains "create accepted custom path with --engine" "$_create_out" "Created 'My App'"
DESKTOP="$DESKTOP_DIR/My App.desktop"
assert_exists "create wrote the .desktop file" "$DESKTOP"
EXEC_LINE="$(grep -m1 '^Exec=' "$DESKTOP")"
assert_contains "Exec pins the custom path with space" \
  "$EXEC_LINE" "--browser \"$CHROME_STUB\""

_list_json="$(bash "$BIN" list --json)"
assert_contains "list --json keeps the full custom path" \
  "$_list_json" "\"browser\":\"$CHROME_STUB\""
assert_contains "list --json keeps the path with a space" \
  "$_list_json" "My Browsers/chrome wrapper"
_list_table="$(bash "$BIN" list)"
assert_contains "list table keeps the full custom path" "$_list_table" "$CHROME_STUB"
_doctor="$(bash "$BIN" doctor "My App" 2>&1 || true)"
assert_contains "doctor resolves the custom path" "$_doctor" "ok: browser $CHROME_STUB"
assert_absent "doctor does not warn about a missing browser" "$_doctor" "pinned browser"
assert_absent "doctor does not truncate the path at the space" \
  "$_doctor" "not found"
_doctor_json="$(bash "$BIN" doctor --json 2>&1 || true)"
assert_contains "doctor --json keeps the full custom path" \
  "$_doctor_json" "\"browser\":\"$CHROME_STUB\""
if command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$_doctor_json" | python3 -c 'import json,sys; json.load(sys.stdin)'; then
    pass "doctor --json is valid JSON"
  else
    fail "doctor --json is valid JSON"
  fi
fi

# exec_escape must double '%' and escape '$' in custom paths.
SPECIAL="$STUB_DIR/cost%50 \$home wrapper"
make_stub "$SPECIAL" 'Chromium 121.0.0.0'
bash "$BIN" create --name "Special" --url https://example.com \
  --engine chrome --browser-bin "$SPECIAL" --no-icon >/dev/null 2>&1
assert_contains "create escapes % as %%" \
  "$(grep -m1 '^Exec=' "$DESKTOP_DIR/Special.desktop")" "cost%%50"
assert_contains "create escapes \$ in the Exec browser value" \
  "$(grep -m1 '^Exec=' "$DESKTOP_DIR/Special.desktop")" '\$home wrapper'
assert_contains "list --json unescapes %% and \$" \
  "$(bash "$BIN" list --json)" 'cost%50 $home wrapper'

echo "== engine inference and validation =="

bash "$BIN" create --name "Inferred" --url https://example.com \
  --browser-bin "$CHROME_STUB" --no-icon >/dev/null 2>&1
assert_contains "detected engine is used without --engine" \
  "$(grep -m1 '^Exec=' "$DESKTOP_DIR/Inferred.desktop")" "launch chrome"

_err="$(bash "$BIN" create --name "Mismatch" --url https://example.com \
  --engine chrome --browser-bin "$FIREFOX_STUB" --no-icon 2>&1 || true)"
assert_contains "confident probe mismatch is rejected" "$_err" \
  "is a firefox browser, but --engine is 'chrome'"
_err="$(bash "$BIN" create --name "NoEngine" --url https://example.com \
  --browser-bin "$MYSTERY_STUB" --no-icon 2>&1 || true)"
assert_contains "undetectable binary requires --engine" "$_err" "pass --engine"
_err="$(bash "$BIN" create --name "Missing" --url https://example.com \
  --engine chrome --browser-bin "$STUB_DIR/missing" --no-icon 2>&1 || true)"
assert_contains "missing binary is rejected" "$_err" "not an executable file"
_err="$(bash "$BIN" create --name "NoExec" --url https://example.com \
  --engine chrome --browser-bin "$NONEXEC" --no-icon 2>&1 || true)"
assert_contains "non-executable binary is rejected" "$_err" "not an executable file"

# A --browser-bin value without '/' is still the legacy --browser alias.
mkdir -p "$TMP/pathbin"
cp "$CHROME_STUB" "$TMP/pathbin/chromium"
PATH="$TMP/pathbin:$PATH" bash "$BIN" create --name "Alias" \
  --url https://example.com --browser-bin chromium --no-icon >/dev/null 2>&1
assert_contains "legacy bare-name alias still works" \
  "$(grep -m1 '^Exec=' "$DESKTOP_DIR/Alias.desktop")" '--browser "chromium"'

echo "== launcher resolution and safety guards =="

: >"$MOCK_ARGS"
bash "$LIB/cocoon-launch-chrome" --name "My App" --url https://example.com \
  --browser "$CHROME_STUB" >/dev/null 2>&1
_args="$(cat "$MOCK_ARGS")"
assert_contains "chrome launcher resolved a custom path" "$_args" "--app=https://example.com"
assert_contains "chrome launcher used an isolated data dir" "$_args" "--user-data-dir="
assert_contains "Chromium 120 keeps the link router" "$_args" "--load-extension"

: >"$MOCK_ARGS"
bash "$LIB/cocoon-launch-firefox" --name "My App" --url https://example.com \
  --browser "$FIREFOX_STUB" >/dev/null 2>&1
_args="$(cat "$MOCK_ARGS")"
assert_contains "firefox launcher resolved a custom path" "$_args" "--profile "
assert_contains "firefox launcher passed the URL" "$_args" "https://example.com"

if bash "$LIB/cocoon-launch-chrome" --name X --url https://example.com \
  --browser "$FIREFOX_STUB" >/dev/null 2>&1; then rc=0; else rc=$?; fi
assert_eq "chrome launcher rejects a custom Firefox path" "1" "$rc"

: >"$MOCK_ARGS"
bash "$LIB/cocoon-launch-chrome" --name X --url https://example.com \
  --browser "$BRANDED_STUB" >/dev/null 2>&1
assert_absent "Chrome 137 gate blocks --load-extension on a custom path" \
  "$(cat "$MOCK_ARGS")" "--load-extension"

echo "== open and edit round-trip =="

: >"$MOCK_ARGS"
bash "$BIN" open "My App" >/dev/null 2>&1 || true
sleep 0.3
assert_contains "cocoon open passes the custom path through" \
  "$(cat "$MOCK_ARGS")" "--app=https://example.com"

bash "$BIN" edit "My App" --url https://new.example >/dev/null 2>&1
_exec="$(grep -m1 '^Exec=' "$DESKTOP")"
assert_contains "edit preserves the escaped custom path" "$_exec" \
  "--browser \"$CHROME_STUB\""
assert_contains "edit updates the URL" "$_exec" "https://new.example"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
