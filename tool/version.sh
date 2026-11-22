#!/usr/bin/env bash
# tool/version.sh — Cocoon's single entry point for versioning.
# Without args: print current version. With a version: write VERSION and stamp
# the pubspec.yaml literal (Dart only accepts a literal version: field), then
# show the diff. `--check [tag]` verifies VERSION, the pubspec literal and,
# when a tag is supplied, the release tag all agree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"
PUBSPEC="$ROOT/tui/pubspec.yaml"

current="$(cat "$VERSION_FILE" 2>/dev/null || echo dev)"
pubspec_version() {
  sed -n 's/^version: //p' "$PUBSPEC" 2>/dev/null || true
}

if [[ "${1:-}" == "--check" ]]; then
  shift
  tag="${1:-}"
  status=0
  pv="$(pubspec_version)"
  if [[ -z "$current" || "$current" != "$pv" ]]; then
    echo "tool/version.sh: VERSION='$current' does not match tui/pubspec.yaml='$pv'" >&2
    status=1
  fi
  if [[ -n "$tag" && "${tag#v}" != "$current" ]]; then
    echo "tool/version.sh: tag '$tag' does not match VERSION='$current'" >&2
    status=1
  fi
  if ((status == 0)); then
    echo "version OK: $current"
  fi
  exit "$status"
fi

if (($# == 0)); then
  printf '%s\n' "$current"
  exit 0
fi

NEW="$1"
if [[ ! "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "tool/version.sh: version must look like 0.0.1, got '$NEW'" >&2
  exit 1
fi

printf '%s\n' "$NEW" >"$VERSION_FILE"
if [[ -f "$PUBSPEC" ]]; then
  sed -i "s/^version: .*/version: $NEW/" "$PUBSPEC"
fi
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$ROOT" diff -- VERSION tui/pubspec.yaml || true
else
  echo "VERSION=$NEW (pubspec stamped)"
fi
