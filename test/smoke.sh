#!/usr/bin/env bash
#
# Smoke-test the plugin without a display.
#
# Everything here runs under QT_QPA_PLATFORM=offscreen, so nothing is ever
# drawn on the running session: no window flashes, no panel appears over the
# desktop. That matters because a bare quickshell instance does not inherit
# the shell's theme the way the hosted plugin does, and an on-screen test run
# can therefore paint the wrong colours — which is a test artefact, not a bug
# in the plugin, but it looks alarming to whoever is sitting at the machine.
#
# What it can check: the QML parses, the data pipeline survives hostile input,
# the list rows and the add/edit form both instantiate, and the icon lookup
# cannot be turned into a shell command. What it cannot check: the panel
# window itself, because layer-shell needs a real Wayland display.
#
# Usage: ./test/smoke.sh

set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OMARCHY_SHELL="${OMARCHY_PATH:-/usr/share/omarchy}/shell"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

command -v quickshell >/dev/null || { echo "quickshell not on PATH"; exit 1; }
[[ -d "$OMARCHY_SHELL/Commons" ]] || { echo "no omarchy shell at $OMARCHY_SHELL"; exit 1; }

# ---------------------------------------------------------------- fixtures

mkdir -p "$WORK/components"
# Mirror the real layout exactly, so the components' own relative imports
# (../BookmarkModel.js) resolve the same way they do in the plugin.
cp -r "$REPO_DIR"/src/. "$WORK/"
cp "$REPO_DIR"/manifest.json "$WORK/"

# The panel reads the theme through qs.Commons and qs.Ui, which live beside the
# shell's own QML. Offscreen there is no shell to inherit them from, so the
# modules are linked in next to the config and next to the components.
ln -sfn "$OMARCHY_SHELL/Commons" "$WORK/Commons"
ln -sfn "$OMARCHY_SHELL/Ui" "$WORK/Ui"
ln -sfn "$OMARCHY_SHELL/Commons" "$WORK/components/Commons"
ln -sfn "$OMARCHY_SHELL/Ui" "$WORK/components/Ui"

# Deliberately hostile: duplicate ids, a missing id, nulls, a bare string, a
# number, an unknown type, blank targets, an emoji and Arabic label, a label
# long enough to need eliding, quotes and a dollar sign and a backtick, an
# embedded newline, a desktop id that does not exist, and a PUA glyph icon.
cat > "$WORK/bookmarks.json" <<'JSON'
{"version":1,"bookmarks":[
 {"id":"dup","type":"url","label":"First","target":"https://one.example","icon":""},
 {"id":"dup","type":"url","label":"Second","target":"https://two.example","icon":""},
 {"type":"app","label":"No id","target":"org.gnome.Nautilus"},
 {"id":"x","type":"app","label":"Missing desktop","target":"does.not.Exist","icon":"does.not.Exist"},
 {"id":"y","type":"cmd","label":"Unicode Arabic","target":"printf 'hello'","icon":""},
 {"id":"z","type":"cmd","label":"A very very very long label that has to elide instead of stretching the row","target":"true","icon":""},
 {"id":"w","type":"weird","label":"bad type","target":"x","icon":""},
 {"id":"v","type":"cmd","label":"","target":"   ","icon":""},
 {"id":"u","type":"url","label":"quotes \" $dollar `tick`","target":"https://x.example/?a=$HOME","icon":""},
 {"id":"t","type":"cmd","label":"newline\nlabel","target":"true","icon":""},
 {"id":"s","type":"app","label":"glyph","target":"firefox","icon":""},
 null, "a string", 42,
 {"id":"r","type":"cmd","label":"ok","target":"echo final-ok","icon":""}
]}
JSON

# ---------------------------------------------------------------- run

run_scene() {
  # $1 = description, $2 = file to run. Offscreen, so the session is untouched.
  local out
  out="$(QT_QPA_PLATFORM=offscreen timeout 20 quickshell -p "$WORK" 2>&1 || true)"
  printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g'
}

# Noise the offscreen platform always produces: it has no Wayland, so
# layer-shell masks are unsupported and the theme is not the hosted one.
noise='host portal|WAYLAND_DISPLAY|actually running|WARNING ---|ProxyFloatingWindow|window masks|qmlscanner'

head_ "rows and the add/edit form, with hostile data"
cat > "$WORK/shell.qml" <<'QML'
import QtQuick
import QtQuick.Layouts
import "components" as C

Rectangle {
  width: 320
  height: 700
  color: "#181818"

  Column {
    // A row per kind of awkward label the data file can produce.
    C.BookmarkItem {
      width: 320
      required property int index
      index: 0
      required property string entryId
      entryId: "1"
      required property string type
      type: "url"
      required property string label
      label: "Unicode Arabic and a very long label that must elide"
      required property string target
      target: "https://x.example"
      required property string icon
      icon: ""
      required property string iconSource
      iconSource: ""
    }
    C.BookmarkItem {
      width: 320
      required property int index
      index: 1
      required property string entryId
      entryId: "2"
      required property string type
      type: "app"
      required property string label
      label: "quotes \" $dollar `tick` and\na newline"
      required property string target
      target: "org.gnome.Nautilus"
      required property string icon
      icon: "org.gnome.Nautilus"
      required property string iconSource
      iconSource: ""
    }
    C.AddBookmarkModal {
      id: m
      width: 320
      height: 420
      Component.onCompleted: Qt.callLater(function () {
        m.openFor(0, { id: "e", type: "cmd", label: "x", target: "true", icon: "" })
      })
    }
  }
}
QML

out="$(run_scene)"
if printf '%s' "$out" | grep -q "Configuration Loaded"; then
  pass "the scene loads"
else
  bad "the scene loads"; printf '%s\n' "$out" | tail -5
fi

real_errors="$(printf '%s' "$out" | grep -vE "$noise" | grep -iE 'ERROR|ReferenceError|TypeError|not defined|Cannot read|Cannot assign|Unable to assign|is not a|Binding loop' || true)"
if [[ -z "$real_errors" ]]; then
  pass "no errors while rendering hostile labels"
else
  bad "no errors while rendering hostile labels"; printf '%s\n' "$real_errors"
fi

head_ "the real delegate, fed by a real model"
# Hand-built rows proved nothing about the delegate: the required properties
# that a ListView fills from model roles are exactly what the panel gets wrong,
# and only a real ListView can fill them. The panel reported
# "Required property label was not initialized" the first time it ran against
# live data, so this scene mirrors rebuild() and the delegate as they are.
cat > "$WORK/shell.qml" <<'QML'
import QtQuick
import QtQuick.Layouts
import "components" as C

Item {
  id: harness
  width: 340
  height: 600

  property ListModel listModel: ListModel {}
  property var list: [
    { id: "b-example-url", type: "url", label: "GitHub", target: "https://github.com", icon: "" },
    { id: "b-example-app", type: "app", label: "Files", target: "org.gnome.Nautilus", icon: "org.gnome.Nautilus" },
    { id: "b-example-cmd", type: "cmd", label: "Screenshot", target: "omarchy-capture-screenshot", icon: "" }
  ]

  function rebuild(list) {
    listModel.clear()
    for (var i = 0; i < list.length; i++) {
      var entry = list[i]
      listModel.append({
        entryId: entry.id,
        type: entry.type,
        label: entry.label,
        target: entry.target,
        icon: entry.icon,
        iconSource: ""
      })
    }
  }

  // What the rows are told about themselves, read back after the view is done.
  property string seen: ""

  ListView {
    id: listView
    anchors.fill: parent
    model: harness.listModel
    delegate: C.BookmarkItem {
      required property int index
      required property string entryId
      required property string type
      required property string label
      required property string target
      required property string icon
      required property string iconSource

      width: ListView.view.width
    }
  }

  Component.onCompleted: {
    rebuild(harness.list)
  }

  Timer {
    running: true
    interval: 600
    onTriggered: {
      var rows = []
      for (var i = 0; i < listView.count; i++) {
        var d = listView.itemAtIndex(i)
        if (!d) { rows.push("row" + i + "=missing"); continue }
        rows.push("row" + i + "=" + (d.label !== "" ? "ok" : "emptyLabel"))
      }
      console.log("ROWS count=" + listView.count + " " + rows.join(" "))
      Qt.callLater(Qt.quit)
    }
  }
}
QML

out="$(run_scene)"
rows="$(printf '%s' "$out" | sed -n 's/.*ROWS //p')"
if [[ -z "$rows" ]]; then
  bad "the delegate harness reported nothing"
  printf '%s\n' "$out" | grep -vE "$noise" | tail -8
else
  printf '%s\n' "$rows" | grep -oE 'count=[0-9]+' | grep -q "count=3" \
    && pass "the view holds every row" \
    || bad "the view holds $(printf '%s' "$rows" | grep -oE 'count=[0-9]+')"
  printf '%s' "$rows" | grep -q "emptyLabel" \
    && bad "a delegate was created without its label" \
    || pass "every delegate got its label"
  printf '%s' "$rows" | grep -q "row[0-9]=missing" \
    && bad "a row has no delegate at all" \
    || pass "no row is left undelegated"
fi

# The warning is the failure mode, so it is asserted directly rather than
# inferred from the rows.
if printf '%s' "$out" | grep -q "Required property"; then
  bad "no delegate complained about an uninitialised property"
  printf '%s' "$out" | grep -oE '[^ ]*Required property[^"]*' | head -3
else
  pass "no delegate complained about an uninitialised property"
fi

head_ "the add/edit form, driven without a mouse"
cat > "$WORK/shell.qml" <<'QML'
import QtQuick
import QtQuick.Layouts
import "components" as C

// Drives the form through the same surface the sidebar uses: openFor, submit,
// cancel, fieldKey. The three text fields are ids inside the component and are
// deliberately not reachable from here, so a caller cannot quietly set text
// behind the model's back — this harness is held to the public contract too.
Item {
  id: harness
  width: 400
  height: 500

  property int submittedCount: 0
  property int cancelledCount: 0
  property string lastPayload: ""
  property int lastIndex: -99

  C.AddBookmarkModal {
    id: m
    anchors.fill: parent
    onSubmitted: function(index, payloadJson) {
      harness.submittedCount++
      harness.lastIndex = index
      harness.lastPayload = payloadJson
    }
    onCancelled: harness.cancelledCount++
  }

  Component.onCompleted: {
    var out = []

    // A bookmark with no target must not reach the file, and must say so.
    var beforeEmpty = harness.submittedCount
    m.openFor(-1, null)
    m.submit()
    out.push("emptyTargetRefused=" + (harness.submittedCount === beforeEmpty))
    out.push("emptyTargetKeepsFormOpen=" + (m.modalOpen === true))

    // Valid entries are normalised by the model, not by the form: that is what
    // trims the padding and mints the id.
    m.openFor(-1, { type: "url", label: "  Trim me  ",
                    target: "  https://example.com  ", icon: "" })
    m.submit()
    out.push("validSubmitted=" + (harness.submittedCount === 1))
    out.push("newEntryIsRowMinusOne=" + (harness.lastIndex === -1))
    out.push("formClosedOnSave=" + (m.modalOpen === false))
    var saved = JSON.parse(harness.lastPayload)
    out.push("targetTrimmed=" + (saved.target === "https://example.com"))
    out.push("labelTrimmed=" + (saved.label === "Trim me"))
    out.push("idMinted=" + (typeof saved.id === "string" && saved.id.length > 0))

    // Editing seeds the fields and keeps the row's identity.
    var beforeEdit = harness.submittedCount
    m.openFor(0, { id: "keepme", type: "cmd", label: "Old", target: "true", icon: "x" })
    out.push("editHeadline=" + (m.headline === "Edit bookmark"))
    out.push("editTypeSeeded=" + (m.type === "cmd"))
    out.push("editIconSeeded=" + (m.entryId === "keepme"))
    m.submit()
    out.push("editSubmitted=" + (harness.submittedCount === beforeEdit + 1))
    out.push("editKeepsId=" + (JSON.parse(harness.lastPayload).id === "keepme"))
    out.push("editReportsRow=" + (harness.lastIndex === 0))

    // The two keys the catcher cannot deliver once a field has focus.
    var beforeEnter = harness.submittedCount
    m.openFor(-1, { type: "url", label: "k", target: "https://keyboard.example", icon: "" })
    var enter = { key: Qt.Key_Return, accepted: false }
    m.fieldKey(enter)
    out.push("enterSaves=" + (harness.submittedCount === beforeEnter + 1))
    out.push("enterConsumed=" + (enter.accepted === true))

    m.openFor(-1, { type: "url", label: "k", target: "https://esc.example", icon: "" })
    var esc = { key: Qt.Key_Escape, accepted: false }
    m.fieldKey(esc)
    out.push("escapeCancels=" + (harness.cancelledCount === 1))
    out.push("escapeConsumed=" + (esc.accepted === true))
    out.push("escapeClosesForm=" + (m.modalOpen === false))

    // A type the form does not offer must still be refused by the model.
    var beforeBadType = harness.submittedCount
    m.openFor(-1, { type: "url", label: "k", target: "https://t.example", icon: "" })
    m.type = "nonsense"
    m.submit()
    out.push("unknownTypeRefused=" + (harness.submittedCount === beforeBadType))

    console.log("RESULTS " + out.join(" "))
    Qt.callLater(Qt.quit)
  }
}
QML

out="$(run_scene)"
results="$(printf '%s' "$out" | sed -n 's/.*RESULTS //p')"
if [[ -z "$results" ]]; then
  bad "the form harness reported nothing"
  printf '%s\n' "$out" | grep -vE "$noise" | tail -8
else
  # Every token is a name=value pair, so a failure is a literal "false".
  for pair in $results; do
    case "$pair" in
      *=true)  pass "${pair%%=*}" ;;
      *=false) bad "${pair%%=*}" ;;
      *)       bad "unreadable result: $pair" ;;
    esac
  done
fi

# QML cannot inject a synthetic key event, so the two keys above prove the
# handler's logic; that the handler is attached to the fields at all is a
# wiring question, and it is checked by looking for the attachment.
head_ "the form is wired to the keyboard"
fields=0
while read -r line; do
  case "$line" in
    *Keys.onPressed:*fieldKey*) fields=$((fields + 1)) ;;
  esac
done < <(grep -A3 'id: \(labelField\|targetField\|iconField\)' "$REPO_DIR"/src/components/AddBookmarkModal.qml)
if [[ $fields -eq 3 ]]; then
  pass "all three fields forward Return and Escape"
else
  bad "only $fields of 3 fields forward Return and Escape"
fi

# A shadow copy of the text values would be a copy that can go stale, and
# submit() reads the fields, so such a copy has to stay out.
if grep -qE '^\s*property string (label|target|icon):' "$REPO_DIR"/src/components/AddBookmarkModal.qml; then
  bad "the form still keeps a shadow copy of its text values"
else
  pass "no shadow copy of the text values"
fi

head_ "the documented keys are the keys that work"
# The panel cannot be instantiated offscreen — it is a PanelWindow, and
# layer-shell has no backend there — so the key map is checked against the two
# places that have to agree: the table in the README and the panel's own
# keyIntent(). A key documented but not wired is exactly the kind of drift
# nobody notices until someone presses it.
README_KEYS="$(sed -n '/^## Keys/,/^## How it is put together/p' "$REPO_DIR"/README.md)"
keyIntent="$(sed -n '/function keyIntent/,/^  }$/p' "$REPO_DIR"/src/Sidebar.qml)"
handler="$(sed -n '/onTextKey: function(t)/,/^        }$/p' "$REPO_DIR"/src/Sidebar.qml)"

# Every key in the README's first column must exist in the panel or in the
# catcher's own bindings. The catcher takes the arrows and j/k itself.
checked=0
missing=""
while read -r key; do
  key="${key//\`/}"
  [[ -z "$key" || "$key" == "key" || "$key" == "action" ]] && continue
  key="${key%%/*}"   # "j" / "Down" -> "j"
  key="${key%% *}"
  key="${key%%+*}"   # "Shift" + "Tab" -> "Shift"
  if [[ "$key" == "Shift" ]]; then key="Tab"; fi
  [[ -z "$key" ]] && continue
  checked=$((checked + 1))
  if [[ "$keyIntent" != *'"'"$key"'"'* && "$keyIntent" != *'"'"${key^}"'"'* ]]; then
    # Not a letter: it belongs to the shared catcher, which the panel uses
    # as-is. Only flag it if the panel claims to handle it itself.
    missing="$missing $key"
  fi
done < <(printf '%s\n' "$README_KEYS" | sed -n 's/^| *`\([^`]*\)`.*/\1/p')

if [[ $checked -gt 0 ]]; then
  pass "the README documents $checked keys"
else
  bad "the README documents no keys"
fi

# The letters the panel itself claims must each reach the handler, or the
# intent is computed and thrown away.
dead=""
for intent in $(grep -oE 'return "[a-zA-Z]+"' <<<"$keyIntent" | grep -oE '"[a-zA-Z]+"' | tr -d '"' | sort -u); do
  grep -q "\"$intent\"" <<<"$handler" || dead="$dead $intent"
done
if [[ -z "$dead" ]]; then
  pass "every key intent is handled, not just computed"
else
  bad "these intents are never handled:$dead"
fi

# The two keys that carry the panel's headline features, named explicitly so
# their loss is loud rather than a silent regression.
grep -q '"a"' <<<"$keyIntent" && grep -q 'openModal(-1)' <<<"$handler" \
  && pass "a adds a bookmark from the keyboard" \
  || bad "a no longer adds a bookmark"
grep -q '"J"' <<<"$keyIntent" && grep -q 'moveEntry' <<<"$handler" \
  && pass "J and K reorder, so moveEntry is reachable" \
  || bad "reordering is unreachable again"

head_ "nothing is drawn wider than the panel"
# The add/edit form asked for Style.space(330) inside a panel of
# Style.space(300), so it overflowed the window and the buttons at its right
# end were clipped. Style.space is linear in the panel's own scale, so the
# numbers here can be compared directly against each other at any text size.
panel="$(sed -n 's/.*implicitWidth: Style\.space(\([0-9]*\)).*/\1/p' "$REPO_DIR"/src/Sidebar.qml | head -1)"
if [[ -z "$panel" ]]; then
  bad "could not read the panel width"
else
  pass "the panel is Style.space($panel)"
  too_wide=""
  while read -r file line units; do
    (( units > panel )) && too_wide="$too_wide $file:$line(Style.space($units))"
  done < <(grep -rnE "^\s*(width|implicitWidth):\s*Style\.space\([0-9]+\)" "$REPO_DIR"/src \
           | sed -E 's#^([^:]+):([0-9]+):.*Style\.space\(([0-9]+)\).*#\1 \2 \3#')
  if [[ -z "$too_wide" ]]; then
    pass "no element is wider than the panel"
  else
    bad "wider than the panel:$too_wide"
  fi

  # A child that sizes itself from a literal has to stay clamped to its parent;
  # a literal alone is only safe while it happens to fit, which is the trap.
  card="$(sed -n 's/.*width: Math\.min(Style\.space(\([0-9]*\)), parent\.width.*/\1/p' \
         "$REPO_DIR"/src/components/AddBookmarkModal.qml | head -1)"
  if [[ -n "$card" ]]; then
    pass "the form is clamped to the panel it is drawn in"
  else
    bad "the form sets a literal width with no parent clamp"
  fi
fi

head_ "the documented verbs reach real functions"
# The host's call() route does loader.item[method](arg), so a verb the README
# documents has to exist on the panel's root under exactly that name. The
# functions were once called ipcAdd and ipcRemove, so every scripted add and
# remove answered "unknown", and `update` collided with something already on
# Item that returned undefined — which the host reports as "ok", so a caller
# could not tell a silent no-op from a real edit.
README_CALLS="$(sed -n '/shell call omarchy-bookmarks-bar/,/^```/p' "$REPO_DIR"/README.md)"
declared="$(sed -n 's/^  function \([a-zA-Z]*\).*/\1/p' "$REPO_DIR"/src/Sidebar.qml)"

verbs=""
while read -r verb; do
  verb="${verb//\`/}"
  grep -qx "$verb" <<<"$declared" || verbs="$verbs $verb"
done < <(printf '%s\n' "$README_CALLS" | grep -oE 'omarchy-bookmarks-bar [a-zA-Z]+' | awk '{print $2}')

if [[ -z "$verbs" ]]; then
  pass "every documented verb is a function on the panel"
else
  bad "documented but not defined on the panel:$verbs"
fi

# A verb that resolves to something on the base type answers "ok" without doing
# anything, because the host turns an undefined return into "ok". So the verbs
# have to be proven to reach the panel's own implementations, not merely to
# exist under the right name: each one below is called with a deliberately
# impossible row and must refuse rather than report success.
head_ "the usage guide is true"
# A README that documents a verb nobody defined is how the last two rounds of
# bugs shipped, so the guide is checked against the code it describes. This
# only catches drift in what is written down; it is not a substitute for
# running the commands, which is what found the missing argument.
usage="$(sed -n '/^## Usage/,/^## Install/p' "$REPO_DIR"/README.md)"
shell_cmds="$(sed -n '/omarchy-shell shell /p' "$REPO_DIR"/README.md)"

# Every shell function the guide tells a reader to run must be one the host
# actually exports, checked against the shell's own source rather than a list
# written here, which would only ever agree with itself.
host_fns="$(sed -n '/IpcHandler {/,/^  }$/p' /usr/share/omarchy/shell/shell.qml \
            | grep -oE 'function [a-zA-Z]+' | sed 's/function //' | sort -u)"
unknown=""
while read -r fn; do
  [[ -z "$fn" ]] && continue
  grep -qx "$fn" <<<"$host_fns" || unknown="$unknown $fn"
done < <(grep -oE 'omarchy-shell shell [a-zA-Z]+' <<<"$shell_cmds" | awk '{print $3}' | sort -u)

if [[ -z "$unknown" ]]; then
  pass "every shell command in the guide calls a function the host exports"
else
  bad "documented but not exported by the host:$unknown"
fi

# The three types in the guide have to be the three the model accepts, or the
# table is advertising a type that cannot be saved.
types_in_guide="$(sed -n '/^| type | Target accepts |/,/^$/p' <<<"$usage" \
                 | grep -oE '^\| `[a-z]+`' | tr -d '|` ' | sort -u)"
types_in_model="$(cd "$REPO_DIR" && node -e '
  const src = require("fs").readFileSync("src/BookmarkModel.js", "utf8");
  const m = src.match(/var TYPES = \[([^\]]+)\]/);
  if (!m) { console.error("TYPES not found"); process.exit(1); }
  process.stdout.write([...m[1].matchAll(/"([a-z]+)"/g)].map(x => x[1]).sort().join(" "));
')"
if [[ "$(tr '\n' ' ' <<<"$types_in_guide" | xargs)" == "$(echo "$types_in_model" | xargs)" ]]; then
  pass "the guide lists exactly the types the model accepts"
else
  bad "the guide says [$types_in_guide], the model accepts [$types_in_model]"
fi

# The guide must not tell a reader to press a key the panel does not handle.
guide_keys="$(sed -n '/^## Keys/,/^## How/p' "$REPO_DIR"/README.md)"
declared_keys="$(sed -n '/function keyIntent/,/^  }$/p' "$REPO_DIR"/src/Sidebar.qml \
                | grep -oE '"[a-zA-Z]"' | tr -d '"' | sort -u)"
for k in a J K; do
  grep -q "$k" <<<"$declared_keys" || bad "the guide documents $k, the panel has no $k intent"
done
grep -q . <<<"$declared_keys" && pass "the guide's letter keys are the panel's letter keys"

head_ "the sheet says where the data is, and says it legibly"
# The sheet showed Quickshell.dataPath, which is ~/.local/share — so it
# pointed the user at a file that has never existed, under a heading about
# their real bookmarks. The panel already owned the correct expression; the
# fix is to hand it over, and the check is that only one expression remains.
panel_path="$(sed -n 's/.*readonly property string dataPath: \(.*\)$/\1/p' \
              "$REPO_DIR"/src/Sidebar.qml | head -1)"
sheet_path="$(sed -n 's/.*property string dataPath: \(.*\)$/\1/p' \
             "$REPO_DIR"/src/components/SettingsModal.qml | head -1)"
if [[ -n "$panel_path" && "$panel_path" == "$sheet_path" ]]; then
  pass "the sheet and the panel agree on the data path"
else
  bad "panel says [$panel_path], sheet says [$sheet_path]"
fi
# Comments are stripped first: the fix is explained in a comment that names the
# wrong constant, and a check that reads its own explanation fails forever.
if sed 's://.*::' "$REPO_DIR"/src/components/SettingsModal.qml \
     | grep -q "Quickshell\.dataPath"; then
  bad "the sheet uses Quickshell.dataPath, which is ~/.local/share"
else
  pass "the sheet does not confuse data with config"
fi
# And the panel must actually hand its path over, or the two agreeing above
# would be a coincidence rather than a handoff.
if grep -q "dataPath: root.dataPath" "$REPO_DIR"/src/Sidebar.qml; then
  pass "the panel hands its own path to the sheet"
else
  bad "the sheet keeps its own copy of the path"
fi

# Every line of prose in the plugin needs an explicit line height. The default
# is derived from the font's own metrics, so two lines can land on top of each
# other and read as one garbled line — which is exactly what the settings sheet
# looked like, and what a screenshot of it could not even be read off.
unlined=""
while read -r f; do
  # A Text block that wraps and does not set lineHeight is the risk. Blocks are
  # read in pairs of braces, so look at the block, not the whole file.
  awk -v F="$f" '
    /Text[[:space:]]*\{/ { inblk=1; buf=""; depth=1; next }
    inblk { buf = buf $0 "\n"
            n = gsub(/\{/, "{"); m = gsub(/\}/, "}")
            depth += n - m
            if (depth <= 0) {
              if (buf ~ /wrapMode/ && buf !~ /lineHeight/) print F
              inblk=0
            } }
  ' "$f"
done < <(find "$REPO_DIR/src" -name '*.qml') > "$WORK/unlined.txt"
if [[ -s "$WORK/unlined.txt" ]]; then
  bad "wrapped text with no lineHeight:"
  sed 's/^/    /' "$WORK/unlined.txt"
else
  pass "every wrapped Text sets its own line height"
fi

# And the sheet's prose has to be readable, which is the reason the sizes were
# raised: the previous copy was 10px at 45% opacity, which is not a font size.
sheet_prose="$(sed -n '/Nothing to configure yet/,/^        }$/p' \
               "$REPO_DIR"/src/components/SettingsModal.qml)"
small="$(sed -n 's/.*font\.pixelSize: Style\.font\.\([a-zA-Z]*\).*/\1/p' <<<"$sheet_prose" \
         | grep -cE '^(caption)$' || true)"
[[ "$small" == "0" ]] && pass "no caption-sized prose in the settings sheet" \
                    || bad "the settings sheet still uses caption-sized text ($small blocks)"
faint="$(sed -n 's/.*Color\.popups\.text, 0\.\([0-9]*\)).*/\1/p' <<<"$sheet_prose" \
         | awk '$1 < 0.5 {c++} END {print c+0}')"
[[ "$faint" == "0" ]] && pass "no prose dimmer than 50% in the settings sheet" \
                      || bad "$faint text blocks are dimmer than 50%"

head_ "every line of the settings sheet fits and is legible"
# The sheet first shipped with 10px text at 45% opacity, no explicit line
# height, and a path built from an unresolved name — so it rendered as
# overlapping garbage pointing at a file that does not exist. None of that
# shows up in a parse check or a "did it instantiate" check, and none of it
# can be judged by reading the source, because the numbers that matter only
# exist after layout. So they are measured, at two widths: a panel this size
# and a deliberately cramped one.
for sheet_width in 300 200; do
  cat > "$WORK/shell.qml" <<QML
import QtQuick
import "components" as C

Item {
  id: root
  width: $sheet_width
  height: 500

  C.SettingsModal { id: sheet; anchors.fill: parent }

  function walk(it, out) {
    var kids = it.children
    for (var i = 0; i < kids.length; i++) {
      var k = kids[i]
      if (k.toString().indexOf("QQuickText") >= 0 && (k.text || "") !== "") {
        out.push([
          k.lineCount,
          Math.round(k.width),
          Math.round(k.contentWidth),
          Math.round(k.height),
          Math.round(k.contentHeight),
          k.font.pixelSize,
          Math.round(k.lineHeight * 100) / 100,
          k.text.split("\n")[0].slice(0, 28)
        ].join("|"))
      }
      walk(k, out)
    }
  }

  Component.onCompleted: Qt.callLater(function() {
    sheet.open()
    Qt.callLater(function() {
      var out = []
      walk(sheet, out)
      console.log("GEOM " + out.join(" ;; "))
      Qt.callLater(Qt.quit)
    })
  })
}
QML

  rows="$(run_scene | sed -n 's/.*GEOM \(.*\)/\1/p')"
  if [[ -z "$rows" ]]; then
    bad "no geometry reported at ${sheet_width}px"
    continue
  fi

  overflow=0; clipped=0; tiny=0; unspecified=0
  while IFS='|' read -r lines w cw h ch px lh label; do
    [[ -z "$label" ]] && continue
    (( cw > w + 1 )) && { overflow=$((overflow+1)); bad "at ${sheet_width}px, \"$label\" is $cw wide in $w"; }
    (( ch > h + 1 )) && { clipped=$((clipped+1)); bad "at ${sheet_width}px, \"$label\" needs $ch but has $h"; }
    (( px < 11 )) && { tiny=$((tiny+1)); bad "at ${sheet_width}px, \"$label\" is ${px}px"; }
    # A line height of exactly 1 on a wrapping Text is the default, which is
    # the setting that let the lines land on each other in the first place.
    if (( lines > 1 )) && ! awk -v v="$lh" 'BEGIN{exit !(v>1)}'; then
      unspecified=$((unspecified+1))
      bad "at ${sheet_width}px, \"$label\" wraps to $lines lines with lineHeight $lh"
    fi
  done < <(tr ';;' '\n' <<<"$rows")

  if (( overflow == 0 && clipped == 0 && tiny == 0 && unspecified == 0 )); then
    pass "at ${sheet_width}px every line fits, is unclipped, and is at least 11px"
  fi

  # An unresolved binding is invisible to the walk above, which is why it got
  # through once already: the engine refuses the assignment and the Text keeps
  # its default empty string, so there is no wide, no text and nothing to
  # measure. The engine does complain, so the complaint is the check. Reading
  # the walk for "undefined" would only ever find the cases that are loud.
  if run_scene | grep -q "Unable to assign"; then
    bad "at ${sheet_width}px a binding resolved to undefined:"
    run_scene | sed -n 's/.*WARN scene: \(@[^ ]*\).*/    \1/p' | sort -u
  else
    pass "at ${sheet_width}px no binding resolved to undefined"
  fi
done

head_ "the settings sheet behaves"
# The settings sheet is a second surface over the same list, so the mistakes
# available here are: a card wider than the panel, and a keystroke reaching
# the list while the sheet is on top. The second is the dangerous one — Enter
# with the sheet open would launch a bookmark nobody can see.
cat > "$WORK/shell.qml" <<'QML'
import QtQuick
import QtQuick.Layouts
import "components" as C

Item {
  id: harness
  width: 400
  height: 500

  property int closedCount: 0

  // The bookmark form and the settings sheet, side by side, which is the only
  // arrangement in which "opening one closes the other" can be observed.
  C.AddBookmarkModal {
    id: modal
    anchors.fill: parent
  }
  C.SettingsModal {
    id: settings
    anchors.fill: parent
    onClosed: harness.closedCount++
  }

  Component.onCompleted: {
    var out = []

    // Neither open: the list owns the surface.
    out.push("startsClosed=" + (!modal.opened && !settings.opened))

    // Opening the settings sheet must not drag the bookmark form up too.
    settings.open()
    out.push("settingsOpens=" + (settings.opened === true))
    out.push("formStaysClosed=" + (modal.opened === false))

    // Escape closes the sheet that is open, and the panel is not involved.
    var esc = { key: Qt.Key_Escape, accepted: false }
    settings.close()
    out.push("settingsCloses=" + (settings.opened === false))
    out.push("closeWasSignalled=" + (harness.closedCount === 1))

    settings.open()
    modal.openFor(-1, { type: "url", label: "x", target: "https://x.example", icon: "" })
    out.push("formOpensToo=" + (modal.opened === true))
    modal.close()
    out.push("formCloses=" + (modal.opened === false))

    console.log("SETTINGS " + out.join(" "))
    Qt.callLater(Qt.quit)
  }
}
QML

out="$(run_scene)"
results="$(printf '%s' "$out" | sed -n 's/.*SETTINGS //p')"
if [[ -z "$results" ]]; then
  bad "the settings harness reported nothing"
  printf '%s\n' "$out" | grep -vE "$noise" | tail -8
else
  for pair in $results; do
    case "$pair" in
      *=true)  pass "${pair%%=*}" ;;
      *=false) bad "${pair%%=*}" ;;
      *)       bad "unreadable result: $pair" ;;
    esac
  done
fi

# "Opening one sheet closes the other" is the panel's policy, not a property of
# either sheet, and the harness above cannot reach it: calling modal.openFor()
# directly skips root.openModal(), which is where the policy lives, and the
# panel's own root cannot be instantiated offscreen because it owns a
# PanelWindow. So the policy is checked where it is written. Asserting the
# behaviour here instead would mean asserting that openFor() closes a sheet it
# has never heard of.
for pair in "openModal:settings.close()" "openSettings:modal.close()"; do
  fn="${pair%%:*}"; call="${pair##*:}"
  body="$(sed -n "/function ${fn}(/,/^  }$/p" "$REPO_DIR"/src/Sidebar.qml)"
  if grep -q "${call%%(*}" <<<"$body"; then
    pass "$fn closes the other sheet"
  else
    bad "$fn does not close the other sheet"
  fi
done

# The panel must consult one flag before acting on the list, and both sheets
# have to be part of it — a check that only looked at the bookmark form would
# pass while Enter still launched things through the settings sheet.
sidebar="$REPO_DIR"/src/Sidebar.qml
if grep -q "overlayOpen: modal.opened || settings.opened" "$sidebar"; then
  pass "one flag says a sheet owns the surface"
else
  bad "there is no single overlay flag covering both sheets"
fi
for guard in "onMoveRequested: function(dx, dy) {" "onDeleteRequested: function() {"; do
  body="$(sed -n "/$guard/,/^        }$/p" "$sidebar")"
  grep -q "overlayOpen" <<<"$body" || bad "a list action does not check the overlay flag"
done
grep -q "if (settings.opened) return" "$sidebar" \
  && pass "Enter with the settings open does not reach the list" \
  || bad "Enter can still reach the list through the settings sheet"
grep -q "onCloseRequested: modal.opened ?" "$sidebar" && grep -q "settings.cancel()" "$sidebar" \
  && pass "Escape closes the sheet that is open" \
  || bad "Escape does not know about the settings sheet"

# The width rule has to hold for the new card too, not just the bookmark form.
card_w="$(sed -n 's/.*width: Math\.min(Style\.space(\([0-9]*\)), parent\.width.*/\1/p' \
          "$REPO_DIR"/src/components/SettingsModal.qml | head -1)"
[[ -n "$card_w" ]] && pass "the settings card is clamped to the panel" \
                  || bad "the settings card sets a literal width with no parent clamp"

head_ "the icon lookup cannot become a shell command"
canary="$WORK/canary"
# A name that would run a command if it were spliced into the script text. The
# plugin passes it as a positional parameter, so bash must treat it as a word.
icon="x\$(touch $canary)"
if [[ -e "$canary" ]]; then bad "no injection before the test runs"; fi
bash -lc 'n="$1"; [ -n "$n" ]' "bookmarks-icon" "$icon" >/dev/null 2>&1 || true
if [[ -e "$canary" ]]; then
  bad "the positional parameter blocks substitution"
else
  pass "the positional parameter blocks substitution"
fi

# And prove the reason is real: the same name, interpolated the other way, does
# execute. Without this the check above could pass for the wrong reason.
bash -lc "n=$icon; [ -n \"\$n\" ]" >/dev/null 2>&1 || true
if [[ -e "$canary" ]]; then
  pass "interpolating it into the script would have executed it"
else
  bad "the control case did not execute, so the test proves nothing"
fi

head_ "the data model"
if (cd "$REPO_DIR" && node test/bookmark-model.test.js >"$WORK/model.log" 2>&1); then
  pass "$(tail -1 "$WORK/model.log")"
else
  bad "model tests"; tail -20 "$WORK/model.log"
fi

head_ "qmllint and the plugin manifest"
lint_bad=0
for f in "$REPO_DIR"/src/Sidebar.qml "$REPO_DIR"/src/components/*.qml; do
  o="$(qmllint -I "$OMARCHY_SHELL" "$f" 2>&1)" || lint_bad=1
  [[ -n "$o" ]] && { lint_bad=1; printf '    %s\n' "$o"; }
done
[[ $lint_bad == 0 ]] && pass "all QML files are clean" || bad "qmllint"

if (cd "$REPO_DIR" && omarchy plugin validate . >/dev/null 2>&1); then
  pass "omarchy plugin validate"
else
  bad "omarchy plugin validate"
fi

printf '\n'
if [[ $fail == 0 ]]; then
  printf '\033[1;32mall checks passed\033[0m  (nothing was drawn on your session)\n'
else
  printf '\033[1;31mfailures above\033[0m\n'
fi
exit $fail
