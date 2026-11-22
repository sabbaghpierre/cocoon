#!/usr/bin/env bash
# Cocoon installer — isolated webapps (Omarchy-style) for any distro/DE.
# From a clone: ./install.sh [--prefix DIR] [--no-path] [--uninstall]
# Fresh machine: curl -fsSL https://raw.githubusercontent.com/sabbaghpierre/cocoon/main/install.sh | bash
set -euo pipefail

unset IFS GLOBIGNORE

[[ -n "${HOME:-}" ]] || { echo "install.sh: HOME is not set." >&2; exit 1; }

REPO="${COCOON_REPO:-sabbaghpierre/cocoon}"
REF="${COCOON_REF:-main}"
TARBALL_URL="${COCOON_TARBALL_URL:-}"
DATA_ROOT="$HOME/.local/share/cocoon"
LEGACY_DATA_ROOT="$HOME/.local/share/webapps"
HOST_NAME="com.cocoon.open_external"
LEGACY_HOST_NAME="com.webappkit.open_external"
EXT_ID="ojjpgedkhjmaochljkpgamkcmfnbhocl"
NO_PATH=false
UNINSTALL=false
PREFIX=""
TMPDIR_WK=""
FETCH_ERR=""
LEGACY_PREFIXES=()
LEGACY_BINS=()

usage() {
  echo "Usage: install.sh [--prefix DIR] [--no-path] [--uninstall]"
  echo "Env:   COCOON_REPO=owner/repo  COCOON_REF=branch-or-tag  COCOON_TARBALL_URL=url"
  echo "       (default: $REPO@$REF)"
}

while (($# > 0)); do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --prefix=*) PREFIX="${1#--prefix=}"; shift ;;
    --no-path) NO_PATH=true; shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "install.sh: unknown flag: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ "$PREFIX" != "" ]] || PREFIX="$DATA_ROOT"
BIN_DST="$PREFIX/bin"
LIBEXEC_DST="$PREFIX/libexec"
COCOON_BIN="$BIN_DST/cocoon"

die() { echo "install.sh: $*" >&2; exit 1; }
warn() { echo "install.sh: warning: $*" >&2; }

cleanup() { [[ -n "$TMPDIR_WK" ]] && rm -rf "$TMPDIR_WK" || true; }
trap cleanup EXIT

add_legacy_prefix() {
  local p="${1%/}" b found
  [[ -n "$p" ]] || return 0
  for b in "$p/bin"; do
    found=0
    for lp in "${LEGACY_BINS[@]+"${LEGACY_BINS[@]}"}"; do
      [[ "$lp" == "$b" ]] && found=1
    done
    ((found == 0)) && LEGACY_BINS+=("$b")
  done
  found=0
  for lp in "${LEGACY_PREFIXES[@]+"${LEGACY_PREFIXES[@]}"}"; do
    [[ "$lp" == "$p" ]] && found=1
  done
  ((found == 0)) && LEGACY_PREFIXES+=("$p")
}

detect_legacy_prefixes() {
  local d
  add_legacy_prefix "$LEGACY_DATA_ROOT"
  local IFS=:
  for d in ${PATH-}; do
    [[ -n "$d" ]] || continue
    if [[ -x "$d/webapp-create" || -x "$d/webapp-launch-chrome" || -x "$d/webapp-list" ]]; then
      add_legacy_prefix "$(dirname "$d")"
    fi
  done
}
detect_legacy_prefixes

atomic_replace() {
  local dest="$1" tmp="$2" mode=""
  if [[ -e "$dest" ]]; then
    if command -v stat >/dev/null 2>&1; then
      mode="$(stat -c '%a' "$dest" 2>/dev/null || stat -f '%Lp' "$dest" 2>/dev/null || true)"
    elif command -v chmod >/dev/null 2>&1; then
      chmod --reference="$dest" "$tmp" 2>/dev/null || true
    fi
  fi
  [[ -n "$mode" ]] && chmod "$mode" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dest"
}

config_tmp() { # $1=path -> mktemp path in same directory
  local p="$1" d
  d="$(dirname "$p")"
  mkdir -p "$d" 2>/dev/null || true
  mktemp "${p}.cocoon.XXXXXX" 2>/dev/null || true
}

managed_pattern_file() {
  local pf="$1" lp
  {
    printf '%s\n' \
      '# webapp-kit' \
      '# webapp-kit: managed by install.sh' \
      '# /webapp-kit' \
      '# cocoon: managed by install.sh' \
      '# /cocoon' \
      'export PATH="$HOME/.local/share/webapps/bin:$PATH"' \
      'export PATH="$HOME/.local/share/cocoon/bin:$PATH"'
    for lp in "${LEGACY_BINS[@]+"${LEGACY_BINS[@]}"}"; do
      printf 'export PATH="%s:$PATH"\n' "$lp"
      printf 'if not contains -- "%s" $PATH\n' "$lp"
      printf '    set -gx PATH "%s" $PATH\n' "$lp"
      printf 'set -gx PATH "%s" $PATH\n' "$lp"
    done
    for lp in "$BIN_DST" "$DATA_ROOT/bin" "$LEGACY_DATA_ROOT/bin"; do
      printf 'export PATH="%s:$PATH"\n' "$lp"
      printf 'if not contains -- "%s" $PATH\n' "$lp"
      printf '    set -gx PATH "%s" $PATH\n' "$lp"
      printf 'set -gx PATH "%s" $PATH\n' "$lp"
    done
  } >"$pf"
}

clean_config_to() { # $1=source $2=dest : drop only lines/blocks managed by us
  local src="$1" dst="$2" pf stage
  pf="$(mktemp 2>/dev/null)" || return 1
  managed_pattern_file "$pf"
  cp -f "$src" "$dst"
  if grep -q '^# webapp-kit: managed by install.sh$' "$dst" 2>/dev/null &&
    grep -q '^# /webapp-kit$' "$dst" 2>/dev/null; then
    sed -i '/^# webapp-kit: managed by install.sh$/,/^# \/webapp-kit$/d' "$dst"
  fi
  if grep -q '^# cocoon: managed by install.sh$' "$dst" 2>/dev/null &&
    grep -q '^# /cocoon$' "$dst" 2>/dev/null; then
    sed -i '/^# cocoon: managed by install.sh$/,/^# \/cocoon$/d' "$dst"
  fi
  stage="$(mktemp 2>/dev/null)" || return 1
  grep -v -F -f "$pf" "$dst" >"$stage" 2>/dev/null || true
  rm -f "$pf"
  mv -f "$stage" "$dst"
  return 0
}

strip_managed_path() { # $1=file
  local file="$1" tmp
  [[ -f "$file" ]] || return 0
  tmp="$(config_tmp "$file")" || return 0
  clean_config_to "$file" "$tmp" || { rm -f "$tmp"; return 0; }
  atomic_replace "$file" "$tmp"
}

if [[ "$PREFIX" == "$DATA_ROOT" ]]; then
  PATH_LINE='export PATH="$HOME/.local/share/cocoon/bin:$PATH"'
else
  PATH_LINE="export PATH=\"$BIN_DST:\$PATH\""
fi

if [[ "$UNINSTALL" == "true" ]]; then
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    strip_managed_path "$rc"
  done
  FISH_CONF="$HOME/.config/fish/config.fish"
  if [[ -f "$FISH_CONF" ]]; then
    tmp="$(config_tmp "$FISH_CONF")" || true
    if [[ -n "${tmp:-}" && -f "$tmp" ]]; then
      clean_config_to "$FISH_CONF" "$tmp" || true
      atomic_replace "$FISH_CONF" "$tmp"
      if ! grep -q '[^[:space:]]' "$FISH_CONF" 2>/dev/null; then rm -f "$FISH_CONF"; fi
    fi
  fi
  rm -f "$HOME/.config/plasma-workspace/env/cocoon-path.sh"
  if [[ -f "$HOME/.config/plasma-workspace/env/local-bin-path.sh" ]] &&
    grep -q 'webapp' "$HOME/.config/plasma-workspace/env/local-bin-path.sh" 2>/dev/null; then
    rm -f "$HOME/.config/plasma-workspace/env/local-bin-path.sh"
  fi
  rm -rf "$BIN_DST" "$LIBEXEC_DST" "$PREFIX/ext"
  rm -f "$PREFIX/VERSION"
  for p in "${LEGACY_PREFIXES[@]+"${LEGACY_PREFIXES[@]}"}"; do
    [[ -d "$p/bin" ]] || continue
    rm -f "$p/bin"/webapp-* "$p/bin/webapp-tui" 2>/dev/null || true
    rmdir "$p/bin" 2>/dev/null || true
  done
  while IFS= read -r -d '' m; do rm -f "$m"; done < <(
    find "$HOME/.config" -maxdepth 6 -type f \( -name "$HOST_NAME.json" -o -name "$LEGACY_HOST_NAME.json" \) -print0 2>/dev/null || true
  )
  # Flatpak sandboxes keep their own ~/.config under ~/.var/app/<app-id>.
  # Remove ONLY our two exact manifest filenames there — never app data.
  while IFS= read -r -d '' m; do rm -f "$m"; done < <(
    find "$HOME/.var/app" -maxdepth 8 -type f \( -name "$HOST_NAME.json" -o -name "$LEGACY_HOST_NAME.json" \) -print0 2>/dev/null || true
  )
  echo "Uninstalled Cocoon code from $PREFIX."
  echo "Kept your data: profiles, desktops, icons, KWin rules ($DATA_ROOT)."
  echo "To purge everything instead, run: cocoon uninstall --purge"
  exit 0
fi

for cmd in curl tar mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required to install Cocoon."
done
if ! TMPDIR_PROBE="$(mktemp -d 2>/dev/null)"; then
  die "cannot create temp dirs (check TMPDIR='$TMPDIR' and disk space)."
fi
rm -rf "$TMPDIR_PROBE"
CA_OK=false
for caf in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
  [[ -f "$caf" ]] && CA_OK=true
done
if [[ "$CA_OK" != "true" ]]; then
  warn "no TLS CA bundle found; HTTPS downloads may fail (install ca-certificates)."
fi

classify_curl_error() {
  local host
  host="$(printf '%s' "$3" | sed -n 's|^[A-Za-z][A-Za-z0-9+.-]*://\([^/]*\).*|\1|p')"
  [[ -z "$host" ]] && host="$3"
  case "$1" in
    6) printf 'DNS failure resolving %s (offline? broken resolver?)' "$host" ;;
    7) printf 'cannot connect to %s (offline? firewall/proxy?)' "$host" ;;
    28) printf 'connection to %s timed out' "$host" ;;
    35 | 60 | 77) printf 'TLS/CA failure for %s (install ca-certificates; corp proxy?)' "$host" ;;
    22) printf 'HTTP error from %s (captive portal? blocked host?)' "$host" ;;
    5 | 9) printf 'FTP/access issue (unexpected for %s)' "$host" ;;
    *) printf 'curl exit %s for %s: %s' "$1" "$host" "$(printf '%s' "$2" | tr '\n' ' ')" ;;
  esac
}

fetch_file() { # $1=url $2=dest [$3=max-time]
  local url="$1" dest="$2" mt="${3:-120}" err rc
  err="$(curl -fsSL --retry 3 --retry-delay 2 --max-time "$mt" "$url" -o "$dest" 2>&1)" && return 0
  rc=$?
  rm -f "$dest" 2>/dev/null || true
  FETCH_ERR="$(classify_curl_error "$rc" "$err" "$url")"
  return 1
}

SCRIPT_SRC="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
if [[ -n "$SCRIPT_SRC" && "$SCRIPT_SRC" != "bash" && "$SCRIPT_SRC" != "/dev/stdin" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SRC")" && pwd)"
fi
SRC=""
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/bin/cocoon" && -f "$SCRIPT_DIR/libexec/cocoon-create" ]]; then
  SRC="$SCRIPT_DIR"
else
  ERRORS=""
  URLS=()
  if [[ -n "$TARBALL_URL" ]]; then
    URLS+=("$TARBALL_URL")
  else
    URLS+=("https://github.com/$REPO/archive/refs/heads/$REF.tar.gz")
    URLS+=("https://github.com/$REPO/archive/refs/tags/$REF.tar.gz")
  fi
  for url in "${URLS[@]}"; do
    TMPDIR_WK="$(mktemp -d)"
    if fetch_file "$url" "$TMPDIR_WK/cocoon.tar.gz"; then
      if tar -xzf "$TMPDIR_WK/cocoon.tar.gz" -C "$TMPDIR_WK" 2>"$TMPDIR_WK/tar.err"; then
        while IFS= read -r f; do
          SRC="$(dirname "$(dirname "$f")")"
          break
        done < <(find "$TMPDIR_WK" -maxdepth 4 -path '*/bin/cocoon' -type f 2>/dev/null || true)
        if [[ -n "$SRC" && -f "$SRC/libexec/cocoon-create" ]]; then break; fi
        SRC=""
        ERRORS="${ERRORS}tarball from $url unpacked but holds no bin/cocoon + libexec/cocoon-create; "
      else
        ERRORS="${ERRORS}tarball from $url failed to unpack; "
      fi
    else
      ERRORS="${ERRORS}${FETCH_ERR}; "
    fi
    rm -rf "$TMPDIR_WK"
    TMPDIR_WK=""
  done
  if [[ -z "$SRC" ]] && command -v git >/dev/null 2>&1; then
    TMPDIR_WK="$(mktemp -d)"
    if git clone --depth 1 --branch "$REF" "https://github.com/$REPO.git" "$TMPDIR_WK/git" >"$TMPDIR_WK/git.log" 2>&1 &&
      [[ -f "$TMPDIR_WK/git/bin/cocoon" ]]; then
      SRC="$TMPDIR_WK/git"
    else
      ERRORS="${ERRORS}git clone failed; "
      rm -rf "$TMPDIR_WK"
      TMPDIR_WK=""
    fi
  fi
  if [[ -z "$SRC" ]]; then
    TMPDIR_WK="$(mktemp -d)"
    if fetch_file "https://api.github.com/repos/$REPO/git/trees/$REF?recursive=1" "$TMPDIR_WK/tree.json"; then
      TREE_OK=true
      while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        mkdir -p "$TMPDIR_WK/raw/$(dirname "$p")"
        if ! fetch_file "https://raw.githubusercontent.com/$REPO/$REF/$p" "$TMPDIR_WK/raw/$p"; then
          TREE_OK=false
          ERRORS="${ERRORS}${FETCH_ERR}; "
          break
        fi
      done < <(grep -o '"path": *"[^"]*"' "$TMPDIR_WK/tree.json" 2>/dev/null |
        sed 's/"path": *"//;s/"$//' |
        grep -E '^(bin/cocoon|libexec/[^"]+|ext/[^"]+|VERSION)$' || true)
      if [[ "$TREE_OK" == "true" && -f "$TMPDIR_WK/raw/bin/cocoon" ]]; then
        SRC="$TMPDIR_WK/raw"
      else
        rm -rf "$TMPDIR_WK"
        TMPDIR_WK=""
      fi
    else
      ERRORS="${ERRORS}${FETCH_ERR}; "
      rm -rf "$TMPDIR_WK"
      TMPDIR_WK=""
    fi
  fi
  if [[ -z "${SRC:-}" || ! -f "$SRC/bin/cocoon" ]]; then
    echo "install.sh: could not fetch Cocoon ($REPO@$REF)." >&2
    echo "Details: $ERRORS" >&2
    echo "Hints: check network/DNS, proxy env (env | grep -i proxy), and that" >&2
    echo "  github.com + codeload.github.com + raw.githubusercontent.com resolve." >&2
    exit 1
  fi
fi

legacy_found=false
[[ -d "$LEGACY_DATA_ROOT" ]] && legacy_found=true
for p in "${LEGACY_PREFIXES[@]+"${LEGACY_PREFIXES[@]}"}"; do
  [[ -x "$p/bin/webapp-create" || -x "$p/bin/webapp-launch-chrome" ]] && legacy_found=true
done

sed_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//&/\\&}"
  s="${s//|/\\|}"
  printf '%s' "$s"
}

dir_has_browser_state() { # true when a profile dir holds real browser state
  local d="$1"
  [[ -f "$d/Default/Preferences" || -f "$d/Preferences" || -f "$d/prefs.js" ]]
}

merge_data_dir() { # $1=src $2=dest — merge per-file with mv -n, never overwrite
  local src="$1" dest="$2" item rel target
  local -a items=()
  [[ -d "$src" && -d "$dest" ]] || return 0
  mapfile -d '' -t items < <(find "$src" -mindepth 1 -print0 2>/dev/null || true)
  for item in "${items[@]}"; do
    rel="${item#"$src"/}"
    target="$dest/$rel"
    if [[ -d "$item" && -d "$target" && ! -L "$target" ]]; then
      merge_data_dir "$item" "$target"
    else
      # mv -n keeps the existing item on conflict; nothing is ever deleted.
      mv -n -- "$item" "$target" 2>/dev/null || true
    fi
  done
  rmdir "$src" 2>/dev/null || true
}

migrate_data_root() {
  local item base dest tmp
  [[ "$legacy_found" == "true" ]] || return 0
  [[ -d "$LEGACY_DATA_ROOT" && "$LEGACY_DATA_ROOT" != "$DATA_ROOT" ]] || return 0
  if [[ ! -e "$DATA_ROOT" ]]; then
    mv -- "$LEGACY_DATA_ROOT" "$DATA_ROOT" 2>/dev/null || return 0
    return 0
  fi
  [[ -d "$DATA_ROOT" ]] || return 0
  local -a items=()
  mapfile -d '' -t items < <(find "$LEGACY_DATA_ROOT" -mindepth 1 -maxdepth 1 -print0 2>/dev/null || true)
  for item in "${items[@]}"; do
    base="$(basename "$item")"
    dest="$DATA_ROOT/$base"
    if [[ ! -e "$dest" && ! -L "$dest" ]]; then
      mv -n -- "$item" "$dest" 2>/dev/null || true
      continue
    fi
    if [[ -d "$item" && -d "$dest" && ! -L "$dest" ]]; then
      if dir_has_browser_state "$item" && ! dir_has_browser_state "$dest"; then
        # The legacy copy is the real profile: promote it instead of leaving
        # an empty new dir to shadow its logins. Move the new dir aside first
        # and fold its contents into the promoted one (no data deleted).
        tmp="$DATA_ROOT/.cocoon-migrate-$base.$$"
        [[ -e "$tmp" || -L "$tmp" ]] && tmp="$tmp-$RANDOM"
        if mv -- "$dest" "$tmp" 2>/dev/null && mv -- "$item" "$dest" 2>/dev/null; then
          merge_data_dir "$tmp" "$dest"
        else
          [[ -d "$tmp" && ! -e "$dest" && ! -L "$dest" ]] && mv -- "$tmp" "$dest" 2>/dev/null || true
          merge_data_dir "$item" "$dest"
        fi
      else
        merge_data_dir "$item" "$dest"
      fi
    else
      # File/symlink conflict: keep both sides (mv -n is a no-op here).
      mv -n -- "$item" "$dest" 2>/dev/null || true
    fi
  done
  rmdir "$LEGACY_DATA_ROOT" 2>/dev/null || true
}

migrate_desktops() {
  local dir="$HOME/.local/share/applications" f tmp esc_bin
  [[ -d "$dir" ]] || return 0
  esc_bin="$(sed_escape "$BIN_DST")"
  while IFS= read -r -d '' f; do
    grep -q -E 'webapp-launch-(chrome|firefox)' "$f" 2>/dev/null || continue
    tmp="$(config_tmp "$f")" || continue
    sed -e "s|[^ =]*/bin/webapp-launch-chrome|$esc_bin/cocoon launch chrome|g" \
      -e "s|[^ =]*/bin/webapp-launch-firefox|$esc_bin/cocoon launch firefox|g" \
      -e 's|webapp-launch-chrome|cocoon launch chrome|g' \
      -e 's|webapp-launch-firefox|cocoon launch firefox|g' "$f" >"$tmp"
    if cmp -s "$f" "$tmp"; then rm -f "$tmp"; else atomic_replace "$f" "$tmp"; fi
  done < <(find "$dir" -maxdepth 1 -type f -name '*.desktop' -print0 2>/dev/null || true)
}

migrate_manifests() {
  local old new tmp esc_path
  esc_path="$(sed_escape "$COCOON_BIN")"
  while IFS= read -r -d '' old; do
    new="$(dirname "$old")/$HOST_NAME.json"
    tmp="$(config_tmp "$new")" || continue
    sed -e "s|\"name\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"name\":\"$HOST_NAME\"|" \
      -e "s|\"description\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"description\":\"Cocoon: open webapp links in the default browser\"|" \
      -e "s|\"path\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"path\":\"$esc_path\"|" \
      -e "s|\"allowed_origins\"[[:space:]]*:[[:space:]]*\[[^]]*\]|\"allowed_origins\":[\"chrome-extension://$EXT_ID/\"]|" \
      "$old" >"$tmp"
    [[ -f "$new" ]] || chmod 644 "$tmp" 2>/dev/null || true
    atomic_replace "$new" "$tmp"
    rm -f "$old"
  done < <(find "$HOME/.config" -maxdepth 6 -type f -name "$LEGACY_HOST_NAME.json" -print0 2>/dev/null || true)
}

migrate_kwin_rules() {
  local file="$HOME/.config/kwinrulesrc" tmp
  [[ -f "$file" ]] || return 0
  grep -q '^Description=webapp: ' "$file" 2>/dev/null || return 0
  tmp="$(config_tmp "$file")" || return 0
  sed 's|^Description=webapp: |Description=cocoon: |' "$file" >"$tmp"
  atomic_replace "$file" "$tmp"
}

remove_legacy_binaries() {
  local p d
  for p in "${LEGACY_PREFIXES[@]+"${LEGACY_PREFIXES[@]}"}"; do
    [[ -d "$p/bin" ]] || continue
    rm -f "$p/bin"/webapp-* "$p/bin/webapp-tui" 2>/dev/null || true
    rmdir "$p/bin" 2>/dev/null || true
  done
  local IFS=:
  for d in ${PATH-}; do
    [[ -n "$d" ]] || continue
    rm -f "$d/webapp-tui" 2>/dev/null || true
  done
}

if [[ "$legacy_found" == "true" ]]; then
  echo "Cocoon: migrating legacy webapp-kit install (no logins/profiles will be lost)."
  migrate_data_root
  migrate_desktops
  migrate_manifests
  migrate_kwin_rules
  remove_legacy_binaries
fi

mkdir -p "$BIN_DST" "$LIBEXEC_DST"
cp -f "$SRC/bin/cocoon" "$COCOON_BIN"
chmod +x "$COCOON_BIN"
for f in "$SRC"/libexec/*; do
  [[ -f "$f" ]] || continue
  cp -f "$f" "$LIBEXEC_DST/"
  chmod +x "$LIBEXEC_DST/$(basename "$f")"
done
if [[ -d "$SRC/ext" ]]; then
  rm -rf "$PREFIX/ext"
  cp -rf "$SRC/ext" "$PREFIX/ext"
  chmod -R a+rX "$PREFIX/ext"
fi
if [[ -f "$SRC/VERSION" ]]; then
  cp -f "$SRC/VERSION" "$PREFIX/VERSION"
fi
rm -f "$BIN_DST"/webapp-* "$BIN_DST/webapp-tui" 2>/dev/null || true

TUI_URL="https://github.com/$REPO/releases/latest/download/cocoon-tui"
if fetch_file "$TUI_URL" "$BIN_DST/cocoon-tui" 120; then
  # If the release publishes a checksum, verify before executing the binary.
  CHECK_DIR="$(mktemp -d 2>/dev/null || true)"
  if [[ -n "$CHECK_DIR" ]] && fetch_file "$TUI_URL.sha256" "$CHECK_DIR/cocoon-tui.sha256" 30 2>/dev/null; then
    EXPECTED="$(awk '{print $1}' "$CHECK_DIR/cocoon-tui.sha256" 2>/dev/null | head -n1)"
    ACTUAL="$(sha256sum "$BIN_DST/cocoon-tui" 2>/dev/null | awk '{print $1}')"
    if [[ -n "$EXPECTED" && "$EXPECTED" == "$ACTUAL" ]]; then
      echo "Cocoon: cocoon-tui checksum verified."
    else
      warn "cocoon-tui checksum mismatch; discarding the download"
      rm -f "$BIN_DST/cocoon-tui"
    fi
  fi
  if [[ -f "$BIN_DST/cocoon-tui" ]]; then
    chmod +x "$BIN_DST/cocoon-tui"
    echo "Cocoon: installed cocoon-tui."
  fi
  rm -rf "$CHECK_DIR" 2>/dev/null || true
else
  warn "could not fetch cocoon-tui ($FETCH_ERR). Shell commands work without it."
fi

if [[ "$NO_PATH" != "true" ]]; then
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -e "$rc" ]] || touch "$rc" 2>/dev/null || true
    tmp="$(config_tmp "$rc")" || continue
    clean_config_to "$rc" "$tmp" || { rm -f "$tmp"; continue; }
    printf '\n# cocoon: managed by install.sh\n%s\n# /cocoon\n' "$PATH_LINE" >>"$tmp"
    atomic_replace "$rc" "$tmp"
  done
  FISH_CONF="$HOME/.config/fish/config.fish"
  if command -v fish >/dev/null 2>&1 || [[ "${SHELL:-}" == *fish* ]] || [[ -f "$FISH_CONF" ]]; then
    mkdir -p "$(dirname "$FISH_CONF")"
    [[ -f "$FISH_CONF" ]] || touch "$FISH_CONF" 2>/dev/null || true
    tmp="$(config_tmp "$FISH_CONF")" || true
    if [[ -n "${tmp:-}" && -f "$tmp" ]]; then
      clean_config_to "$FISH_CONF" "$tmp" || true
      printf '\n# cocoon: managed by install.sh\nif not contains -- "%s" $PATH\n    set -gx PATH "%s" $PATH\nend\n# /cocoon\n' \
        "$BIN_DST" "$BIN_DST" >>"$tmp"
      atomic_replace "$FISH_CONF" "$tmp"
    fi
  fi
  if [[ -f "$HOME/.config/plasma-workspace/env/local-bin-path.sh" ]] &&
    grep -q 'webapp' "$HOME/.config/plasma-workspace/env/local-bin-path.sh" 2>/dev/null; then
    rm -f "$HOME/.config/plasma-workspace/env/local-bin-path.sh"
  fi
  if [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* || "${XDG_CURRENT_DESKTOP:-}" == *lasma* ]] ||
    command -v plasmashell >/dev/null 2>&1 || command -v kwriteconfig6 >/dev/null 2>&1; then
    ENV_FILE="$HOME/.config/plasma-workspace/env/cocoon-path.sh"
    mkdir -p "$(dirname "$ENV_FILE")"
    tmp="$(config_tmp "$ENV_FILE")" || true
    if [[ -n "${tmp:-}" && -f "$tmp" ]]; then
      cat >"$tmp" <<EOF
# cocoon: managed by install.sh — PATH for Plasma sessions (POSIX sh).
case ":\$PATH:" in
  *":$BIN_DST:"*) ;;
  *) PATH="$BIN_DST:\$PATH"; export PATH ;;
esac
EOF
      atomic_replace "$ENV_FILE" "$tmp"
    fi
  fi
  export PATH="$BIN_DST:$PATH"
fi

echo "Installed Cocoon to $BIN_DST"
if [[ -x "$COCOON_BIN" ]]; then
  "$COCOON_BIN" doctor --deps >/dev/null 2>&1 || true
fi
echo ""
echo "Quickstart:  cocoon create \"ChatGPT\" https://chatgpt.com chrome"
echo "Overview:    cocoon help"
if [[ "${SHELL:-}" == *fish* ]]; then
  echo "(Run 'exec fish' or open a new terminal so the PATH update takes effect.)"
else
  echo "(Open a new terminal so the PATH update takes effect.)"
fi
