#!/usr/bin/env bash
# cocoon-paths.sh — shared data-root resolution for the cocoon-* toolkit.
#
# SOURCE-ONLY. Sourcing this file MUST emit nothing on stdout: cocoon-open-external
# is a Chrome native messaging host with a binary stdio protocol, so a stray
# byte from an imported helper would corrupt every message. All output happens
# only when one of the functions below is explicitly called.
#
# The canonical WRITE root is $COCOON_DATA_ROOT (default ~/.local/share/cocoon).
# The legacy root ($COCOON_LEGACY_DATA_ROOT, default ~/.local/share/webapps) is
# READ-ONLY: it is probed so profiles/logs left by an interrupted or manual
# migration keep working, but new data is never created there.
#
# Env overrides (COCOON_DATA_ROOT / COCOON_LEGACY_DATA_ROOT) exist for tests.

COCOON_DATA_ROOT="${COCOON_DATA_ROOT:-$HOME/.local/share/cocoon}"
COCOON_LEGACY_DATA_ROOT="${COCOON_LEGACY_DATA_ROOT:-$HOME/.local/share/webapps}"

# Directory holding this helper (normally <prefix>/libexec). Computed once at
# source time; all probes below are side-effect free.
COCOON_PATHS_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd 2>/dev/null)" || COCOON_PATHS_SELF_DIR=""
COCOON_PATHS_SELF_PREFIX=""
if [[ -n "$COCOON_PATHS_SELF_DIR" ]]; then
  COCOON_PATHS_SELF_PREFIX="$(cd "$COCOON_PATHS_SELF_DIR/.." 2>/dev/null && pwd 2>/dev/null)" || COCOON_PATHS_SELF_PREFIX=""
fi

cocoon_data_root() { printf '%s' "$COCOON_DATA_ROOT"; }
cocoon_legacy_data_root() { printf '%s' "$COCOON_LEGACY_DATA_ROOT"; }

# New root first, then legacy root — one path per line (mapfile-friendly).
cocoon_data_roots() {
  printf '%s\n' "$COCOON_DATA_ROOT"
  printf '%s\n' "$COCOON_LEGACY_DATA_ROOT"
}

# cocoon_find_profile <chrome|firefox> <slug>
# Existing dir, new root first then legacy; if neither exists, print the NEW
# path (the caller creates it). Never creates anything by itself.
cocoon_find_profile() {
  local engine="${1:-}" slug="${2:-}" root dir
  [[ -n "$engine" && -n "$slug" ]] || return 0
  for root in "$COCOON_DATA_ROOT" "$COCOON_LEGACY_DATA_ROOT"; do
    [[ -n "$root" ]] || continue
    dir="$root/${engine}-${slug}"
    [[ -d "$dir" ]] && { printf '%s' "$dir"; return 0; }
  done
  printf '%s' "$COCOON_DATA_ROOT/${engine}-${slug}"
}

# cocoon_find_log <slug> — existing log (new then legacy), else the NEW path.
cocoon_find_log() {
  local slug="${1:-}" root file
  [[ -n "$slug" ]] || return 0
  for root in "$COCOON_DATA_ROOT" "$COCOON_LEGACY_DATA_ROOT"; do
    [[ -n "$root" ]] || continue
    file="$root/${slug}.log"
    [[ -f "$file" ]] && { printf '%s' "$file"; return 0; }
  done
  printf '%s' "$COCOON_DATA_ROOT/${slug}.log"
}

# cocoon_find_libexec_helper <filename> — self-dir, new-prefix/libexec, then
# legacy-prefix/libexec. Prints nothing when not found (caller keeps its own
# hardcoded fallback for old installs lacking this helper).
cocoon_find_libexec_helper() {
  local name="${1:-}" cand
  [[ -n "$name" ]] || return 0
  for cand in \
    "$COCOON_PATHS_SELF_DIR/$name" \
    "$COCOON_DATA_ROOT/libexec/$name" \
    "$COCOON_LEGACY_DATA_ROOT/libexec/$name"; do
    [[ -n "$cand" && -f "$cand" ]] && { printf '%s' "$cand"; return 0; }
  done
  return 0
}

# cocoon_find_ext — ext/open-external in self-prefix, new prefix, legacy prefix.
cocoon_find_ext() {
  local cand
  for cand in \
    "$COCOON_PATHS_SELF_PREFIX/ext/open-external" \
    "$COCOON_DATA_ROOT/ext/open-external" \
    "$COCOON_LEGACY_DATA_ROOT/ext/open-external"; do
    [[ -n "$cand" && -f "$cand/manifest.json" && -f "$cand/inject.js" ]] && { printf '%s' "$cand"; return 0; }
  done
  return 0
}
