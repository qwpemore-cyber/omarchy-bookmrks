#!/usr/bin/env bash
#
# Remove the Bookmarks Bar plugin and everything this installer added.
#
# The plugin folder and the keybinding go; your bookmarks do not. Data lives in
# ~/.config/omarchy/bookmarks.json, outside the plugin folder, so a removal can
# never take your list with it. Pass --purge to delete that too.
#
# Usage:
#   ./uninstall.sh              remove the plugin, keep your bookmarks
#   ./uninstall.sh --purge      also delete ~/.config/omarchy/bookmarks.json
#   ./uninstall.sh --yes        never prompt
#   ./uninstall.sh --help

set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

DATA_DIR="$HOME/.config/omarchy"
DATA_FILE="$DATA_DIR/bookmarks.json"
BINDINGS="$HOME/.config/hypr/bindings.lua"

MANIFEST="$REPO_DIR/manifest.json"
PLUGIN_ID="$(jq -r '.id // ""' "$MANIFEST" 2>/dev/null || true)"

# Lua comments, so `--` and not `#`: a stray `#` here would make hyprland
# reject the entire config and take every keybinding down with it.
BIND_BEGIN="-- >>> ${PLUGIN_ID:-bookmarks-bar} >>>"
BIND_END="-- <<< ${PLUGIN_ID:-bookmarks-bar} <<<"

PURGE=0
ASSUME_YES=0

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf 'uninstall.sh: %s\n' "$*" >&2; exit 1; }

confirm() {
  local prompt="$1"
  (( ASSUME_YES )) && return 0
  if [[ -t 0 && -t 1 ]] && command -v gum >/dev/null 2>&1; then
    gum confirm "$prompt"
  else
    die "refusing to continue without confirmation; re-run with --yes"
  fi
}

usage() { sed -n '3,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while (( $# > 0 )); do
  case "$1" in
    --purge)  PURGE=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$PLUGIN_ID" ]] || die "could not read the plugin id from manifest.json"

bold "Removing Bookmarks Bar"
info "id  $PLUGIN_ID"

# ---------------------------------------------------------------- keybinding

if [[ -f "$BINDINGS" ]] && grep -qxF -- "$BIND_BEGIN" "$BINDINGS" 2>/dev/null; then
  tmp="$(mktemp)"
  # Drop the block, then any trailing blank lines it left behind, so a file
  # this script has touched once comes back byte-for-byte.
  awk -v b="$BIND_BEGIN" -v e="$BIND_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }
  ' "$BINDINGS" | awk '{ lines[NR] = $0 } END {
    last = NR
    while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
    for (i = 1; i <= last; i++) print lines[i]
  }' >"$tmp"
  # Only write when a block really was there, so an unrelated bindings.lua is
  # never touched. `cat >` writes through the original inode, which keeps its
  # mode and ownership.
  if cmp -s "$tmp" "$BINDINGS"; then
    info "no keybinding block found"
  else
    cat "$tmp" >"$BINDINGS"
    command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
    info "removed the keybinding"
  fi
  rm -f "$tmp"
else
  info "no keybinding block found"
fi

# ---------------------------------------------------------------- plugin

if command -v omarchy >/dev/null 2>&1; then
  if omarchy plugin list --json 2>/dev/null | jq -e --arg id "$PLUGIN_ID" 'any(.[]; .id == $id)' >/dev/null; then
    # Removes the shell.json entry, unloads the panel, and deletes the
    # checkout under ~/.config/omarchy/plugins.
    omarchy plugin remove "$PLUGIN_ID" --yes
  else
    info "plugin is not installed"
  fi
  omarchy-shell -q shell rescanPlugins || true
else
  warn "omarchy is not on PATH; skipped removing the plugin"
fi

# ---------------------------------------------------------------- data

if (( PURGE )); then
  if [[ -f "$DATA_FILE" ]] && confirm "Delete $DATA_FILE with your bookmarks?"; then
    rm -f "$DATA_FILE"
    info "deleted $DATA_FILE"
  fi
else
  info "kept $DATA_FILE"
fi

echo
bold "Done"
info "reinstall with ./install.sh"
echo
