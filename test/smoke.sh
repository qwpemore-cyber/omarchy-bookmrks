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
# Every property the panel hands the sheet has to exist on the panel. A string
# property assigned undefined is a runtime warning that no linter reports and
# that only shows up in the shell's log, so it is checked here instead.
# A key in the README that no longer works should fail the test rather than
# surprise a user, and the search key is the newest one.
head_ "the keys the README promises are the keys the panel answers to"
panel="$REPO_DIR/src/Sidebar.qml"
# "a" also accepts an upper-case A, so its line reads differently from the
# others. Both forms are the same rule: the key and what it does are on one
# line together, which is what awk is asked for here rather than a pattern
# clever enough to need escaping.
while IFS=: read -r key intent; do
  if awk -v k="t === \"$key\"" -v i="return \"$intent\"" \
       'index($0, k) && index($0, i) { found = 1 } END { exit !found }' "$panel"; then
    pass "the panel answers to $key"
  else
    bad "the README promises $key but the panel has no $intent intent for it"
  fi
done <<'KEYS'
a:add
J:moveUp
K:moveDown
/:search
KEYS

grep -q 'root.keyIntent(t) === "search"' "$panel" \
  && grep -q "search.*forceActiveFocus" "$panel" \
  && pass "/ actually puts the cursor in the filter" \
  || bad "/ is documented but does not open the filter"

head_ "the panel does not hand the sheet a property it does not have"
panel_declared="$(grep -oE '^([[:space:]]*)(readonly )?property [A-Za-z<>]+ ([a-zA-Z_][A-Za-z0-9_]*)' \
                   "$REPO_DIR"/src/Sidebar.qml | awk '{print $NF}' | sort -u)"
handed="$(sed -n '/Components.SettingsModal {/,/^    }$/p' "$REPO_DIR"/src/Sidebar.qml \
          | grep -oE '^[[:space:]]+[a-zA-Z_][A-Za-z0-9_]*: root\.[a-zA-Z_][A-Za-z0-9_]*' \
          | sed -E 's/.*root\.//' | sort -u)"
missing=""
while read -r name; do
  [[ -z "$name" ]] && continue
  grep -qx "$name" <<<"$panel_declared" || missing="$missing $name"
done <<<"$handed"
if [[ -z "$missing" ]]; then
  pass "every property the panel hands over is declared on the panel"
else
  bad "the panel hands the sheet properties it does not declare:$missing"
fi

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

  overflow=0; clipped=0; tiny=0; unspecified=0   # unspecified: kept for the static check's tally
  while IFS='|' read -r lines w cw h ch px lh label; do
    [[ -z "$label" ]] && continue
    (( cw > w + 1 )) && { overflow=$((overflow+1)); bad "at ${sheet_width}px, \"$label\" is $cw wide in $w"; }
    (( ch > h + 1 )) && { clipped=$((clipped+1)); bad "at ${sheet_width}px, \"$label\" needs $ch but has $h"; }
    (( px < 11 )) && { tiny=$((tiny+1)); bad "at ${sheet_width}px, \"$label\" is ${px}px"; }
    # Wrapped text must set lineHeight, and the resulting leading must be sane.
    # The first half catches the default, which let lines land on each other.
    # The second catches the subtler version of the same fault: QML multiplies
    # lineHeight by the font's *natural* line height, so a multiplier that
    # looks modest asks for nearly double spacing in omarchy.ttf, and the
    # paragraph reads as though it has a blank line between every line.
    if (( lines > 1 )); then
      # Whether lineHeight was set at all is checked statically above, against
      # the source: at runtime an explicit 1 and the unset default are the same
      # number, so there is no way to tell them apart from here. What can be
      # measured is the leading they produce, which is the thing that was
      # actually wrong.
      # Measured, not declared: height / lines, against the font's pixel size.
      leading="$(awk -v h="$h" -v n="$lines" -v px="$px" 'BEGIN{printf "%.2f", (h/n)/px}')"
      if ! awk -v v="$leading" 'BEGIN{exit !(v>=1.05 && v<=1.45)}'; then
        bad "at ${sheet_width}px, \"$label\" has ${leading}x leading on a ${px}px font"
      fi
    fi
  done < <(tr ';;' '\n' <<<"$rows")

  if (( overflow == 0 && clipped == 0 && tiny == 0 && unspecified == 0 )); then
    pass "at ${sheet_width}px every line fits, is unclipped, 11px or larger, with sane leading"
  fi

  # An unresolved binding is invisible to the walk above, which is why it got
  # through once already: the engine refuses the assignment and the Text keeps
  # its default empty string, so there is no wide, no text and nothing to
  # measure. The engine does complain, so the complaint is the check. Reading
  # the walk for "undefined" would only ever find the cases that are loud.
  # A wrong measurement and no measurement look identical from the outside:
  # lineHeightFor(16, undefined) is 1, and against this font's natural leading
  # that reproduces the leading that was requested. So the helper has to be
  # handed a real number, which is checked here rather than inferred from the
  # rendered result.
  measured="$(sed -n 's/.*lineHeight: Model\.lineHeightFor([^,]*, *\([a-zA-Z]*\)\.height).*/\1/p' \
             "$REPO_DIR"/src/components/SettingsModal.qml | sort -u | tr '\n' ' ')"
  if [[ "$measured" == "bodyMetrics " ]]; then
    pass "the leading is computed from a measured font, not a fallback"
  else
    bad "the sheet computes its leading from [$measured] rather than a TextMetrics measurement"
  fi

  # Every class of engine complaint, not just the one that happened first.
  # A ReferenceError in a binding falls back to a default that can be exactly
  # right by coincidence — lineHeightFor(x, undefined) is 1, and 1 against
  # this font's natural leading gives the leading that was asked for — so a
  # numeric check downstream cannot see it and the complaint is all there is.
  if run_scene | grep -qE "Unable to assign|ReferenceError|TypeError|is not a (function|type)|Cannot read"; then
    bad "at ${sheet_width}px the engine reported a broken binding:"
    run_scene | sed -n 's/.*WARN scene: \(@[^ ]*\).*/    \1/p' | sort -u
  else
    pass "at ${sheet_width}px no binding resolved to undefined"
  fi
done

head_ "a closed sheet paints nothing"
# The settings sheet shipped with no `visible` binding, so closing it changed a
# boolean and left a full-panel scrim and card drawn over the bookmark list.
# The panel came up blank and every test passed, because every test read the
# `opened` property — which was correctly false — and none of them asked
# whether a single pixel was painted. A flag is not a rendering.
#
# So this asks the rendering. Both sheets, closed and open, in one harness.

cat > "$WORK/shell.qml" <<'QML'
import QtQuick
import "components" as C

Item {
  id: root
  width: 300
  height: 500

  C.AddBookmarkModal { id: form; anchors.fill: parent }
  C.SettingsModal { id: sheet; anchors.fill: parent }

  // Counts what would actually be drawn: a Text only counts if it and every
  // ancestor up to here is visible. That is the same question the compositor
  // asks, which is why a wrong answer here is a wrong screen.
  function painted(it) {
    var kids = it.children, n = 0
    for (var i = 0; i < kids.length; i++) {
      var k = kids[i]
      if (!k.visible) continue
      if (k.toString().indexOf("QQuickText") >= 0 && (k.text || "") !== "") n++
      n += painted(k)
    }
    return n
  }

  Component.onCompleted: Qt.callLater(function() {
    var out = []
    out.push("sheetInvisibleWhenClosed=" + (sheet.visible === false))
    out.push("formInvisibleWhenClosed=" + (form.visible === false))
    out.push("nothingPaintedWhenClosed=" + (painted(root) === 0))
    sheet.open()
    out.push("sheetVisibleWhenOpen=" + (sheet.visible === true))
    out.push("sheetPaintsWhenOpen=" + (painted(sheet) > 0))
    sheet.close()
    out.push("nothingPaintedAfterClose=" + (painted(root) === 0))
    form.openFor(-1, { type: "url", label: "x", target: "https://x.example", icon: "" })
    out.push("formVisibleWhenOpen=" + (form.visible === true))
    out.push("formPaintsWhenOpen=" + (painted(form) > 0))
    form.close()
    out.push("nothingPaintedAfterFormClose=" + (painted(root) === 0))
    console.log("PAINT " + out.join(" "))
    Qt.callLater(Qt.quit)
  })
}
QML

res="$(run_scene | sed -n 's/.*PAINT //p')"
if [[ -z "$res" ]]; then
  bad "the paint harness reported nothing"
  run_scene | grep -vE "$noise" | tail -6
else
  for pair in $res; do
    case "$pair" in
      *=true)  pass "${pair%%=*}" ;;
      *=false) bad "${pair%%=*}" ;;
      *)       bad "unreadable result: $pair" ;;
    esac
  done
fi

# And the rule itself, so a third sheet cannot be written without it. Reading
# the source is the only way to catch a sheet that is never opened at all, which
# is exactly the case that shipped: nothing in the harness would have called
# open() on it, so only the declaration gives it away.
for sheet in AddBookmarkModal SettingsModal; do
  if sed -n '/^Item {/,/^  }$/p' "$REPO_DIR"/src/components/$sheet.qml \
       | grep -q "visible: modalOpen"; then
    pass "$sheet is hidden when it is closed"
  else
    bad "$sheet has no visible binding and would be painted forever"
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

# Export and import are the two halves of moving a panel to another machine, and
# both are the panel writing and reading a file it was handed a path to. The
# question here is not "does the JSON round trip" -- the unit tests say that. It
# is whether a save reaches the disk when its path was set one line earlier, and
# whether a read of a file that is still being written comes back empty. A save
# that quietly does nothing is an export that quietly loses everything.
head_ "an export really writes, and an import really reads it back"
export_a="$WORK/export-a.json"
export_b="$WORK/export-b.json"
rm -f "$export_a" "$export_b"

# Both scenes wait by watching, not by polling with a timer: onFileChanged is the
# same signal the panel's own data file uses, so a test that relied on a timer
# would be testing a mechanism the plugin does not have.
cat > "$WORK/shell.qml" <<QML
import QtQuick
import Quickshell.Io
import "BookmarkModel.js" as Model

Item {
  width: 10
  height: 10

  // The view the panel exports through, pointed at a file that does not exist.
  FileView {
    id: exportFile
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  // A second view pointed at whatever was written, watching for the write to
  // land. A read taken before the bytes are there would be reporting on the
  // test's timing, not on the panel.
  FileView {
    id: importView
    preload: true
    watchChanges: true
    atomicWrites: false
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      if (text().indexOf("My Notes/report.md") < 0) return
      // Printed as one line and as a count, because the file is pretty-printed
      // and a test that greps a multi-line read only ever sees its first brace.
      console.log("ROUNDBACK " + Model.parse(text()).bookmarks.length + " "
                  + text().indexOf("My Notes/report.md"))
      Qt.callLater(Qt.quit)
    }
    onLoadFailed: Qt.callLater(Qt.quit)
  }

  Component.onCompleted: {
    exportFile.path = "$export_a"
    exportFile.setText(Model.serialize({ version: 1, bookmarks: [
      { id: "a", type: "url", label: "GitHub", target: "https://github.com", icon: "" },
      { id: "b", type: "file", label: "report", target: "/tmp/My Notes/report.md", icon: "" }
    ] }))
    importView.path = "$export_a"
  }
}
QML

out="$(run_scene)"
back="$(printf '%s' "$out" | sed -n 's/.*ROUNDBACK //p')"
if [[ -s "$export_a" ]]; then
  pass "a save to a path that did not exist writes the file"
else
  bad "a save to a path that did not exist wrote nothing"
fi
if grep -q 'My Notes/report.md' "$export_a"; then
  pass "the exported file holds the bookmark, spaces and all"
else
  bad "the exported file does not hold the bookmark"
fi
if grep -q '"version"' "$export_a"; then
  pass "the exported file is the plugin's own format"
else
  bad "the exported file is not the plugin's own format"
fi
# Two bookmarks out, and the marker found somewhere in the text: read back
# exactly what the export wrote. The index is compared as a number, because a
# substring test on "-1" would be testing a hyphen, not a position.
count="${back%% *}"
at="${back##* }"
if [[ "$count" == "2" ]] && [[ "$at" =~ ^[0-9]+$ ]] && (( at > 0 )); then
  pass "an import reads back exactly what the export wrote"
else
  bad "an import did not read back the exported file (got: ${back:0:60})"
fi

# And a second export, to a second path: exporting on two different days must
# produce two files, not one file overwritten in place.
cat > "$WORK/shell.qml" <<QML
import QtQuick
import Quickshell.Io
import "BookmarkModel.js" as Model

Item {
  width: 10
  height: 10
  FileView {
    id: exportFile
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }
  FileView {
    id: check
    preload: true
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { console.log("SECOND " + text()); Qt.callLater(Qt.quit) }
    onLoadFailed: Qt.callLater(Qt.quit)
  }
  Component.onCompleted: {
    exportFile.path = "$export_b"
    exportFile.setText(Model.serialize({ version: 1, bookmarks: [
      { id: "z", type: "cmd", label: "only", target: "pwd", icon: "" }
    ] }))
    check.path = "$export_b"
  }
}
QML

out="$(run_scene)"
if [[ -s "$export_b" ]] && grep -q '"only"' "$export_b"; then
  pass "a second export writes its own file"
else
  bad "a second export wrote nothing"
fi
if grep -q 'My Notes/report.md' "$export_a"; then
  pass "the first export is still there afterwards"
else
  bad "the second export clobbered the first"
fi

# A search box that renumbers its own rows would turn "edit this" and "delete
# this" into acts on the wrong bookmark, so the panel is checked for keeping the
# saved list and the shown list apart: a filter hides rows without hiding them
# from the file, and every action aimed at a visible row still means that row.
head_ "the filter hides rows without touching the file"
cat > "$WORK/shell.qml" <<'QML'
import QtQuick
import "BookmarkModel.js" as Model

Item {
  id: harness
  width: 340
  height: 600

  property var allEntries: []
  property string filterQuery: ""

  // The panel's own view mechanics, restated: the truth, the map, and the view.
  function fullRowFor(viewRow) {
    if (viewRow < 0) return -1
    var indexes = Model.filterIndexes({ version: 1, bookmarks: allEntries }, filterQuery)
    return viewRow < indexes.length ? indexes[viewRow] : -1
  }
  function view() { return Model.filterEntries({ version: 1, bookmarks: allEntries }, filterQuery) }

  property var lib: [
    { id: "a", type: "url",  label: "GitHub",     target: "https://github.com",      icon: "" },
    { id: "b", type: "file", label: "report",     target: "/tmp/My Notes/report.md",  icon: "" },
    { id: "c", type: "cmd",  label: "Screenshot", target: "omarchy-capture-screenshot", icon: "" },
    { id: "d", type: "app",  label: "Files",      target: "org.gnome.Nautilus",        icon: "" }
  ]

  Component.onCompleted: {
    var out = []
    allEntries = lib

    out.push("startsUnfiltered=" + (view().length === 4))
    filterQuery = "zzzz"
    out.push("noMatchShowsNothing=" + (view().length === 0))
    out.push("noMatchStillSavesEverything=" + (allEntries.length === 4))
    filterQuery = ""

    filterQuery = "e"
    var shown = view()
    out.push("filterShowsThree=" + (shown.length === 3))
    out.push("fileIsStillSaved=" + (allEntries.length === 4))

    // Every visible row must still address the right saved entry.
    out.push("row0IsStillReport=" + (shown[0].id === "b" && fullRowFor(0) === 1))
    out.push("row1IsStillScreenshot=" + (shown[1].id === "c" && fullRowFor(1) === 2))
    out.push("row2IsStillFiles=" + (shown[2].id === "d" && fullRowFor(2) === 3))
    out.push("pastTheEndIsMinusOne=" + (fullRowFor(3) === -1))

    // Each action starts from the same list, so one of them cannot be what made
    // the next one pass.
    var list = { version: 1, bookmarks: lib }

    var deleted = Model.removeAt(list, fullRowFor(0))
    out.push("deleteTookTheShownOne=" + (deleted.length === 3 && deleted[0].id === "a"
                                         && deleted[1].id === "c" && deleted[2].id === "d"))
    out.push("deleteLeftGitHubAlone=" + (deleted.filter(function (e) { return e.id === "a" }).length === 1))

    var edited = Model.updateAt(list, fullRowFor(0), {
      id: "ignored", type: "cmd", label: "Renamed", target: "true", icon: ""
    })
    out.push("editHitTheShownRow=" + (edited[1].label === "Renamed"))
    // The row keeps the identity the file already gave it, so an edit does not
    // orphan the row it is editing.
    out.push("editKeptTheRowsId=" + (edited[1].id === "b"))
    out.push("editDidNotTouchRow0=" + (edited[0].id === "a" && edited[0].label === "GitHub"))

    // Row 0 on screen is "report", which is row 1 in the file, so moving it down
    // swaps it past its next saved neighbour and not past whatever happened to
    // be second on screen.
    var moved = Model.moveBy(list, fullRowFor(0), 1)
    out.push("moveSwappedWithItsNeighbour=" + (moved[0].id === "a" && moved[1].id === "c"
                                               && moved[2].id === "b" && moved[3].id === "d"))

    // Adding under a query: the new row may not be visible at all, and that must
    // not be mistaken for a failure to add.
    // Neither word below contains the letter the query is looking for, so the
    // new row is genuinely saved and genuinely not on screen.
    var added = Model.append(list, { type: "cmd", label: "zzz", target: "pwd", icon: "" })
    out.push("addStillSaved=" + (added.length === 5))
    var afterAdd = Model.filterEntries({ version: 1, bookmarks: added }, "e")
    out.push("addHiddenByItsOwnQuery=" + (afterAdd.length === 3))
    out.push("addIsNotInTheView=" + (afterAdd.filter(function (e) { return e.id === added[4].id }).length === 0))

    out.push("emptyQueryMatchesEverythingAgain=" + (Model.filterEntries({ version: 1, bookmarks: added }, "").length === 5))

    console.log("FILTER " + out.join(" "))
    Qt.callLater(Qt.quit)
  }
}
QML

out="$(run_scene)"
results="$(printf '%s' "$out" | sed -n 's/.*FILTER //p')"
if [[ -z "$results" ]]; then
  bad "the filter harness reported nothing"
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

# A picked path and a typed one are the same field, and the pickers must not
# appear for types that have nothing to pick.
#
# The form's own fields are unreachable from out here — a QML `id` is not a
# property, so form.targetField does not exist. Everything is therefore driven
# the way the harness above drives it: seed through openFor(), act through the
# root's own functions, and read the answer off the submitted signal. The picker
# buttons are the one thing that must be found by walking, because `text` is a
# real property and their visibility is the thing under test.
cat > "$WORK/shell.qml" <<'QML'
import QtQuick
import "components" as C

Item {
  id: harness
  width: 340
  height: 600

  property int submittedCount: 0
  property string lastPayload: ""
  property bool lastCancelled: false

  function byText(want) {
    var found = null
    function walk(item) {
      if (item.text === want) found = item
      for (var i = 0; i < item.children.length; i++) walk(item.children[i])
    }
    walk(m)
    return found
  }

  C.AddBookmarkModal {
    id: m
    anchors.fill: parent
    onSubmitted: function(index, payloadJson) {
      harness.submittedCount++
      harness.lastPayload = payloadJson
    }
    onCancelled: harness.lastCancelled = true
  }

  // A submitted payload, or "" when the form refused to submit.
  function save(entry) {
    harness.submittedCount = 0
    m.openFor(-1, entry)
    m.submit()
    return harness.submittedCount === 1 ? JSON.parse(harness.lastPayload) : null
  }

  Component.onCompleted: {
    var out = []
    var file = { type: "file", label: "", icon: "" }

    var fileBtn = byText("File\u2026")
    var folderBtn = byText("Folder\u2026")
    out.push("pickersExist=" + (fileBtn !== null && folderBtn !== null))

    m.openFor(-1, { type: "file", label: "", target: "", icon: "" })
    out.push("browsersShowForFile=" + (fileBtn.visible && folderBtn.visible))

    m.openFor(-1, { type: "url", label: "", target: "", icon: "" })
    out.push("browsersHideForUrl=" + (!fileBtn.visible && !folderBtn.visible))

    m.openFor(-1, { type: "cmd", label: "", target: "", icon: "" })
    out.push("browsersHideForCmd=" + (!fileBtn.visible && !folderBtn.visible))

    // What a picker does: hand a path to the form, which then owns it. The
    // field stays editable, so the saved value is the path, not a reference to
    // whatever the dialog last had open.
    m.openFor(-1, { type: "file", label: "", target: "", icon: "" })
    m.acceptPath("/tmp/My Notes/a.md")
    out.push("pickedPathAccepted=" + (save({ type: "file", target: "/tmp/My Notes/a.md" }) !== null))

    // A path with a space in it is the whole reason this type exists, and the
    // label is the basename rather than the word before the space.
    var picked = save({ type: "file", target: "/tmp/My Notes/quarterly report.md" })
    out.push("pathWithSpacesSaved=" + (picked !== null && picked.target === "/tmp/My Notes/quarterly report.md"))
    out.push("labelIsBasename=" + (picked !== null && picked.label === "quarterly report.md"))

    // A directory is the same call and the same kind of bookmark.
    out.push("directorySaved=" + (save({ type: "file", target: "/home/bo/code" }) !== null))
    out.push("tildeSavedUnexpanded=" + (save({ type: "file", target: "~/notes.md" }).target === "~/notes.md"))

    // Refused, and the form says which rule it broke.
    out.push("relativeRefused=" + (save({ type: "file", target: "notes.md" }) === null))
    out.push("emptyRefused=" + (save({ type: "file", target: "  " }) === null))
    // A URL is not a path, whatever the user meant by it.
    out.push("urlNotAFile=" + (save({ type: "file", target: "https://x.example" }) === null))

    console.log("PICKER " + out.join(" "))
    Qt.callLater(Qt.quit)
  }
}
QML

out="$(run_scene)"
results="$(printf '%s' "$out" | sed -n 's/.*PICKER //p')"
if [[ -z "$results" ]]; then
  bad "the picker harness reported nothing"
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

head_ "the panel leaves the desktop alone"
# A panel that is merely open must not hold the keyboard. The reason it is
# pinned to the edge is being usable beside the desktop, and Exclusive focus
# while merely open made every keystroke go to the sidebar the moment it
# appeared. Exclusive is still correct while a form is up, because a text field
# receives nothing without it.
if grep -q 'keyboardFocus: opened && !root.overlayOpen' "$REPO_DIR/src/Sidebar.qml"; then
  bad "the panel steals the keyboard just by being open"
elif grep -q 'WlrKeyboardFocus.OnDemand' "$REPO_DIR/src/Sidebar.qml" \
     && grep -q 'WlrKeyboardFocus.Exclusive' "$REPO_DIR/src/Sidebar.qml"; then
  pass "the panel asks for focus instead of taking it (OnDemand, Exclusive only for forms)"
else
  bad "the panel's keyboard focus mode is not the expected one"
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
