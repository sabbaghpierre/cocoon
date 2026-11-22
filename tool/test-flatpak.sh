#!/usr/bin/env bash
# tool/test-flatpak.sh — regression tests for Flatpak browser launch support.
# Uses a temp HOME and a STUB `flatpak` on PATH; never touches a real
# installation or a real Flatpak app.
set -euo pipefail
unset IFS GLOBIGNORE

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/libexec"
BIN="$ROOT/bin/cocoon"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$HOME/.config"
export COCOON_DATA_ROOT="$HOME/.local/share/cocoon"
export XDG_CURRENT_DESKTOP=niri
DESKTOP_DIR="$HOME/.local/share/applications"
STUB_BIN="$TMP/stubbin"
mkdir -p "$DESKTOP_DIR" "$XDG_CONFIG_HOME" "$STUB_BIN" "$COCOON_DATA_ROOT"

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
assert_absent_file() {
  if [[ ! -e "$2" ]]; then pass "$1"; else fail "$1 ($2 unexpectedly exists)"; fi
}

# ---- stub flatpak ----------------------------------------------------------
APPS_FILE="$TMP/apps"
MOCK_FP_ARGS="$TMP/flatpak.args"
printf 'org.chromium.Chromium\norg.mozilla.firefox\ncom.example.Unmapped\n' >"$APPS_FILE"
export MOCK_FP_APPS="$APPS_FILE" MOCK_FP_ARGS
cat >"$STUB_BIN/flatpak" <<'EOF'
#!/usr/bin/env bash
{
  printf 'CALL %s\n' "$*"
  printf 'arg:%s\n' "$@"
} >>"${MOCK_FP_ARGS:?}"
case "${1:-}" in
  list)
    cat "${MOCK_FP_APPS:?}"
    ;;
  info)
    grep -Fxq "${2:-}" "${MOCK_FP_APPS:?}"
    ;;
  run)
    shift
    app=""
    for a in "$@"; do
      case "$a" in
        --*) ;;
        *) [[ -z "$app" ]] && app="$a" ;;
      esac
    done
    case "$app" in
      org.chromium.Chromium) printf 'Chromium 120.0.6099.109\n' ;;
      org.mozilla.firefox) printf 'Mozilla Firefox 140.0\n' ;;
      *) printf 'Stub 1.0\n' ;;
    esac
    ;;
esac
EOF
# deterministic compositor detection (no real KWin rule warnings in doctor)
cat >"$STUB_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$STUB_BIN/flatpak" "$STUB_BIN/pgrep"
export PATH="$STUB_BIN:$PATH"

echo "== detector: launchable flatpak ids =="

JSON="$(bash "$LIB/cocoon-browsers" --json)"
assert_contains "JSON carries a launchable flatpak id" \
  "$JSON" '"id":"flatpak:org.chromium.Chromium"'
assert_contains "JSON bin is a flatpak run prefix" \
  "$JSON" '"bin":"flatpak run org.chromium.Chromium"'
assert_contains "JSON marks source=flatpak" "$JSON" '"source":"flatpak"'
assert_contains "JSON marks the row supported" "$JSON" '"supported":true}'
assert_contains "JSON reports the flatpak version" \
  "$JSON" '"version":"Chromium 120.0.6099.109"'
if command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$JSON" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
r = [x for x in rows if x["id"] == "flatpak:org.chromium.Chromium"]
assert len(r) == 1, rows
assert r[0]["source"] == "flatpak" and r[0]["supported"] is True
assert r[0]["engine"] == "chromium" and r[0]["bin"] == "flatpak run org.chromium.Chromium"
'; then pass "flatpak JSON row has the full launchable shape"; else fail "flatpak JSON row has the full launchable shape"; fi
fi

# A native equivalent on PATH must not suppress the flatpak row.
printf '#!/usr/bin/env bash\nprintf "Chromium 120\\n"\n' >"$STUB_BIN/chromium"
chmod +x "$STUB_BIN/chromium"
JSON_NATIVE="$(bash "$LIB/cocoon-browsers" --json)"
assert_contains "flatpak row kept even when a native equivalent exists" \
  "$JSON_NATIVE" '"id":"flatpak:org.chromium.Chromium"'
LIST_ALL="$(bash "$LIB/cocoon-browsers" --list --all)"
assert_contains "--all emits the genuine flatpak id" "$LIST_ALL" 'flatpak:org.chromium.Chromium'

echo "== create with a flatpak pin =="

printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' |
  base64 -d >"$TMP/icon.png"
CREATE_OUT="$(bash "$BIN" create --name "FP Chromium" --url https://example.com \
  --browser flatpak:org.chromium.Chromium --icon "$TMP/icon.png" 2>&1)"
assert_contains "create succeeds with a mock flatpak" "$CREATE_OUT" "Created 'FP Chromium'"
DESKTOP="$DESKTOP_DIR/FP Chromium.desktop"
EXEC_LINE="$(grep -m1 '^Exec=' "$DESKTOP")"
assert_contains "Exec pins the flatpak id" "$EXEC_LINE" \
  '--browser "flatpak:org.chromium.Chromium"'
assert_contains "Exec still targets the chrome engine" "$EXEC_LINE" 'launch chrome'

echo "== launcher argv =="

: >"$MOCK_FP_ARGS"
bash "$BIN" launch chrome --name "FP Chromium" --url https://example.com \
  --browser flatpak:org.chromium.Chromium >/dev/null 2>&1
ASSERT_ARGV="$(cat "$MOCK_FP_ARGS")"
assert_contains "launcher runs flatpak run with a per-run filesystem bind" \
  "$ASSERT_ARGV" "CALL run --filesystem=$COCOON_DATA_ROOT"
assert_contains "filesystem bind is an exact argv element" \
  "$ASSERT_ARGV" "arg:--filesystem=$COCOON_DATA_ROOT"
assert_contains "app id is a single argv element after run" \
  "$ASSERT_ARGV" 'arg:org.chromium.Chromium'
assert_contains "isolated data dir still passed to the browser" \
  "$ASSERT_ARGV" "--user-data-dir=$COCOON_DATA_ROOT/chrome-FP-Chromium"
assert_absent "no host filesystem grant" "$ASSERT_ARGV" '--filesystem=host'
assert_absent "no extension load flag in sandbox" "$ASSERT_ARGV" '--load-extension'

echo "== link router disabled in sandbox =="

LOG_FILE="$COCOON_DATA_ROOT/FP-Chromium.log"
assert_contains "log records the sandbox limitation" \
  "$(cat "$LOG_FILE")" 'link-router unsupported in sandbox (flatpak)'
assert_absent "no --load-extension in the exec log" \
  "$(cat "$LOG_FILE")" '--load-extension'
assert_absent_file "no native-host manifest in the isolated profile" \
  "$COCOON_DATA_ROOT/chrome-FP-Chromium/NativeMessagingHosts/com.cocoon.open_external.json"
assert_absent_file "no host config manifest written for the flatpak id" \
  "$HOME/.config/chromium/NativeMessagingHosts/com.cocoon.open_external.json"

echo "== doctor =="

DOCTOR="$(bash "$LIB/cocoon-doctor" "FP Chromium" 2>&1)" && DOCTOR_RC=0 || DOCTOR_RC=$?
assert_contains "doctor resolves the flatpak pin" \
  "$DOCTOR" 'ok: browser flatpak:org.chromium.Chromium'
assert_contains "doctor reports link-out unsupported" \
  "$DOCTOR" 'link-out unsupported in sandbox (flatpak)'
assert_contains "doctor is green for a flatpak app" "$DOCTOR" 'doctor: all green'
assert_eq "doctor exits 0" "0" "$DOCTOR_RC"
DOCTOR_JSON="$(bash "$LIB/cocoon-doctor" --json 2>&1 || true)"
assert_contains "doctor --json keeps the flatpak id" \
  "$DOCTOR_JSON" '"browser":"flatpak:org.chromium.Chromium"'
assert_contains "doctor --json reports linkout_status=unsupported" \
  "$DOCTOR_JSON" '"linkout_status":"unsupported"'
if command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$DOCTOR_JSON" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["issue_count"] == 0, r["issue_count"]
assert r["apps"][0]["linkout_status"] == "unsupported"
'; then pass "doctor --json has no health issues for the flatpak app"; else fail "doctor --json has no health issues for the flatpak app"; fi
fi

echo "== firefox flatpak launcher =="

: >"$MOCK_FP_ARGS"
WAYLAND_DISPLAY=wayland-0 bash "$BIN" launch firefox \
  --name "FP Firefox" --url https://example.org \
  --browser flatpak:org.mozilla.firefox >/dev/null 2>&1
FF_ARGV="$(cat "$MOCK_FP_ARGS")"
assert_contains "firefox flatpak injects Wayland env inside the sandbox" \
  "$FF_ARGV" 'arg:--env=MOZ_ENABLE_WAYLAND=1'
assert_contains "firefox flatpak passes the isolated profile" \
  "$FF_ARGV" "--profile $COCOON_DATA_ROOT/firefox-FP-Firefox"

echo "== strict validation =="

reject() { # <desc> <browser value> <expected error fragment>
  local err
  err="$(bash "$BIN" create --name "Reject" --url https://example.com \
    --browser "$2" --no-icon 2>&1 || true)"
  assert_contains "$1" "$err" "$3"
}
reject "uninstalled but known app id is rejected" \
  'flatpak:com.google.Chrome' 'not installed'
reject "unmapped app id is rejected" \
  'flatpak:org.unknown.App' 'unknown browser'
reject "installed but unmapped app is rejected" \
  'flatpak:com.example.Unmapped' 'unknown browser'
reject "free-form flatpak run string is rejected" \
  'flatpak run org.chromium.Chromium' 'unknown browser'
reject "malformed flatpak id is rejected" \
  'flatpak:nodot' 'unknown browser'
reject "shell metacharacters in app id are rejected" \
  'flatpak:org.chromium.Chromium; touch /tmp/pwned' 'unknown browser'
MISMATCH_ERR="$(bash "$BIN" create --name Reject --url https://example.com \
  --engine chrome --browser flatpak:org.mozilla.firefox --no-icon 2>&1 || true)"
assert_contains "engine comes from the mapping table, not user input" \
  "$MISMATCH_ERR" "is a firefox browser, but --engine is 'chrome'"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
