#!/usr/bin/env bash
#
# Install the Bookmarks Bar plugin into the Omarchy shell.
#
# The plugin is installed the supported way — a git checkout under
# ~/.config/omarchy/plugins/<id> — rather than a symlink, which
# `omarchy plugin validate` rejects outright:
# "symlinks are not allowed inside a plugin folder".
#
# Usage:
#   ./install.sh              install the copy in this folder
#   ./install.sh --remote     install by cloning from GitHub instead
#   ./install.sh --no-keybind install without touching ~/.config/hypr
#   ./install.sh --yes        never prompt (for scripts and agents)
#   ./install.sh --help
#
# After editing the plugin's QML, run `omarchy restart shell`. The shell sets
# QS_DISABLE_FILE_WATCHER=1 so a half-written tree is never loaded mid-write,
# which also means QML edits do not hot-reload; only manifest.json changes are
# noticed on their own.

set -euo pipefail

REPO_URL="git@github.com:qwpemore-cyber/omarchy-bookmrks.git"
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PLUGINS_DIR="$HOME/.config/omarchy/plugins"
DATA_DIR="$HOME/.config/omarchy"
DATA_FILE="$DATA_DIR/bookmarks.json"
BINDINGS="$HOME/.config/hypr/bindings.lua"

# The id lives in manifest.json and is read from there, so the shell, this
# script, and uninstall.sh can never disagree about it.
MANIFEST="$REPO_DIR/manifest.json"
PLUGIN_ID="$(jq -r '.id // ""' "$MANIFEST" 2>/dev/null || true)"

# The marker lines are Lua comments, so they must start with `--`. A `#` here
# is a syntax error, and a syntax error in bindings.lua takes down the whole
# Hyprland config — which is why they are written this way and why the write is
# verified afterwards.
BIND_BEGIN="-- >>> ${PLUGIN_ID:-bookmarks-bar} >>>"
BIND_END="-- <<< ${PLUGIN_ID:-bookmarks-bar} <<<"
BIND_KEY="SUPER + B"

MODE="local"
ADD_KEYBIND=1
ASSUME_YES=0

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
warn()  { printf '  ! %s\n' "$*" >&2; }
die()   { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

confirm() {
  local prompt="$1"
  (( ASSUME_YES )) && return 0
  if [[ -t 0 && -t 1 ]] && command -v gum >/dev/null 2>&1; then
    gum confirm "$prompt"
  else
    die "refusing to continue without confirmation; re-run with --yes"
  fi
}

usage() { sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while (( $# > 0 )); do
  case "$1" in
    --remote)     MODE="remote"; shift ;;
    --dev|--local) MODE="local"; shift ;;
    --no-keybind) ADD_KEYBIND=0; shift ;;
    --yes|-y)     ASSUME_YES=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "unknown option: $1" ;;
  esac
done

# ---------------------------------------------------------------- preflight

command -v omarchy >/dev/null 2>&1 || die "omarchy is not on PATH; is this an Omarchy system?"
command -v jq      >/dev/null 2>&1 || die "jq is required"
command -v git    >/dev/null 2>&1 || die "git is required"

[[ -f "$MANIFEST" ]] || die "no manifest.json next to this script"
[[ -n "$PLUGIN_ID" ]] || die "manifest.json has no id"
[[ -x /usr/bin/quicksell || -n "$(command -v quickshell)" ]] || die "quickshell is not on PATH"

# Validate before anything is copied, so a malformed manifest never reaches
# the trusted plugins directory. This is the same check the shell enforces.
omarchy plugin validate "$REPO_DIR" >/dev/null || die "manifest failed validation; nothing was installed"

bold "Bookmarks Bar"
info "id       $PLUGIN_ID"
info "source   $([[ $MODE == remote ]] && echo "$REPO_URL" || echo "$REPO_DIR")"

# ---------------------------------------------------------------- installed?

target="$PLUGINS_DIR/$PLUGIN_ID"
if [[ -e "$target" || -L "$target" ]]; then
  if confirm "$PLUGIN_ID is already installed. Update it?"; then
    bold "Updating"
    if omarchy plugin update "$PLUGIN_ID" --yes; then
      :
    else
      # `omarchy plugin update` only fast-forwards, and that has no second
      # route out. An install directory whose upstream history was rewritten
      # can never fast-forward onto it again, and neither can one with local
      # edits — both leave the user holding a stale copy with a plugin they
      # cannot refresh, and `update` is the supported command. The directory
      # is a copy of the source and holds no user data (the bookmarks live in
      # ~/.config/omarchy/bookmarks.json), so it is safe to bring the tree
      # back into line with the source rather than leave it stale.
      warn "plugin update could not fast-forward; re-syncing the install directory"
      src="$REPO_DIR"
      [[ $MODE == remote ]] && src="origin"
      git -C "$target" fetch --quiet --no-tags "$src" \
        && git -C "$target" reset --hard --quiet FETCH_HEAD \
        && git -C "$target" clean -fdq

      # A silent no-op here would report success and leave the broken copy in
      # place, so the result is checked rather than assumed.
      if [[ $MODE == local ]]; then
        want="$(git -C "$REPO_DIR" rev-parse HEAD)"
        got="$(git -C "$target" rev-parse HEAD)"
        if [[ "$want" != "$got" ]]; then
          die "re-sync left the install directory at $got, expected $want"
        fi
        info "install directory re-synced to $got"
      fi
    fi
  else
    info "left the installed copy alone"
    exit 0
  fi
else
  # A local-path install needs the folder to be a git checkout: the shell's
  # plugin lifecycle (and `omarchy plugin update`) assume one.
  if [[ $MODE == local ]]; then
    if [[ ! -d "$REPO_DIR/.git" ]]; then
      git -C "$REPO_DIR" init -q
      warn "initialised a git repo here, because a plugin must be a git checkout"
    fi
    if ! git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
      git -C "$REPO_DIR" remote add origin "$REPO_URL"
    fi
  fi

  bold "Installing"
  if [[ $MODE == remote ]]; then
    omarchy plugin add "$REPO_URL" --enable --yes
  else
    omarchy plugin add "$REPO_DIR" --enable --yes
  fi
fi

omarchy-shell -q shell rescanPlugins || true

# ---------------------------------------------------------------- data file

# The user's data lives outside the plugin folder, so reinstalling or
# removing the plugin never touches it. Seed it once, and never overwrite.
if [[ ! -f "$DATA_FILE" && -f "$REPO_DIR/bookmarks.example.json" ]]; then
  mkdir -p "$DATA_DIR"
  cp "$REPO_DIR/bookmarks.example.json" "$DATA_FILE"
  info "seeded $DATA_FILE from bookmarks.example.json"
fi

# ---------------------------------------------------------------- keybinding

if (( ADD_KEYBIND )); then
  if ! command -v hyprctl >/dev/null 2>&1; then
    warn "hyprctl not found; skipped the keybinding"
  elif [[ ! -f "$BINDINGS" ]]; then
    warn "$BINDINGS not found; add the binding by hand:"
    warn "  o.bind(\"$BIND_KEY\", \"Bookmarks bar\", \"omarchy-shell shell toggle $PLUGIN_ID\")"
  else
    # Rewritten rather than appended to, so re-running the installer cannot
    # stack duplicate blocks. awk is used rather than sed -i so the target
    # file keeps its own mode and ownership.
    stripped="$(mktemp)"
    updated="$(mktemp)"

    awk -v b="$BIND_BEGIN" -v e="$BIND_END" '
      $0 == b { skip = 1; next }
      $0 == e { skip = 0; next }
      !skip { print }
    ' "$BINDINGS" >"$stripped"

    {
      # Trim trailing blank lines a previous run may have left, then add
      # exactly one separator and one block.
      awk '{ lines[NR] = $0 } END {
        last = NR
        while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
        for (i = 1; i <= last; i++) print lines[i]
      }' "$stripped"
      printf '\n%s\n' "$BIND_BEGIN"
      printf 'o.bind("%s", "Bookmarks bar", "omarchy-shell shell toggle %s")\n' "$BIND_KEY" "$PLUGIN_ID"
      printf '%s\n' "$BIND_END"
    } >"$updated"

    # Keep the pre-edit file so a config that turns out to be unparseable can
    # be put back exactly as it was.
    cp "$BINDINGS" "$updated.pre"

    if cmp -s "$updated" "$BINDINGS"; then
      info "keybinding already present"
    else
      # Write through the original inode so its mode and ownership survive;
      # replacing the file with a mktemp one would not.
      cat "$updated" >"$BINDINGS"

      # Verify the config still loads. A broken bindings.lua is not a cosmetic
      # problem — hyprland refuses the whole config and the user loses every
      # keybinding on the machine — so undo the write if it does not parse.
      if command -v hyprctl >/dev/null 2>&1; then
        if [[ "$(hyprctl reload 2>&1)" == "ok" ]]; then
          info "bound $BIND_KEY to toggle the sidebar"
        else
          cp "$updated.pre" "$BINDINGS" 2>/dev/null || true
          hyprctl reload >/dev/null 2>&1 || true
          die "the new bindings.lua did not load; the original was restored"
        fi
      else
        info "bound $BIND_KEY to toggle the sidebar"
      fi
    fi
    rm -f "$stripped" "$updated" "$updated.pre"
  fi
fi

# ---------------------------------------------------------------- done

echo
bold "Installed"
info "toggle    omarchy-shell shell toggle $PLUGIN_ID"
info "data      $DATA_FILE"
info "list      omarchy plugin list | grep $PLUGIN_ID"
[[ $MODE == local ]] && info "update    ./install.sh   (or: omarchy plugin update $PLUGIN_ID)"
[[ $MODE == remote ]] && info "update    omarchy plugin update $PLUGIN_ID"
echo
info "press $BIND_KEY, or run the toggle command above"
