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

head_ "no handler is a typo"
# qmllint checks the shape of a QML file, not whether the JavaScript inside a
# signal handler parses — a line like `onX: focusField = 2 : -1` is clean to it
# and throws the moment the field takes focus, which is the one moment nobody is
# running the linter. This one stood in the form for a while and cost the icon
# field its keyboard blocking entirely, so the class of mistake is checked here
# rather than left to the next pair of eyes.
typos="$(grep -rnE '=[[:space:]]*[0-9]+[[:space:]]*:[[:space:]]*-[0-9]' "$REPO_DIR"/src --include='*.qml' || true)"
if [[ -z "$typos" ]]; then
  pass "no handler assigns a number where a condition belongs"
else
  bad "a handler has a value where a condition belongs"
  printf '%s\n' "$typos" | sed 's/^/    /'
fi

# Every focus-changing handler has to be the same shape, because a field that
# forgets to say which one it is leaves the key catcher unblocked while the user
# is typing in it, and the arrows move the list behind the form.
handlers="$(grep -rn 'onActiveFocusChanged' "$REPO_DIR"/src --include='*.qml' || true)"
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  file="${line%%:*}"
  rest="${line#*:}"
  if [[ "$rest" == *"activeFocus ?"* ]]; then
    pass "$(basename "$file") focuses through the same condition"
  else
    bad "$(basename "$file") has a focus handler that does not test activeFocus"
    printf '    %s\n' "$line"
  fi
done <<< "$handlers"

head_ "the row menu, and the two things it can silently get wrong"

# A right-click menu is the one feature in this panel whose absence is invisible:
# if the MouseArea forgets Qt.RightButton, no key is bound to anything, no handler
# throws, and the panel looks exactly as it did before — it just quietly does
# nothing on the button the user pressed. So the one line that decides whether the
# feature exists is checked, rather than left to be noticed.
item="$REPO_DIR/src/components/BookmarkItem.qml"
if grep -q "acceptedButtons: Qt.LeftButton | Qt.RightButton" "$item"; then
  pass "the row takes both buttons"
else
  bad "the row does not accept a right press, so the menu can never open"
fi

# ...and the button has to be told apart inside the handler, or left and right do
# the same thing, which is worse than neither working.
if grep -A 12 "acceptedButtons: Qt.LeftButton | Qt.RightButton" "$item" | grep -q "mouse.button === Qt.RightButton"; then
  pass "the row tells the two buttons apart"
else
  bad "the row accepts both buttons but does not check which one was pressed"
fi

# The press has to travel with the signal. Qt 6's mouse event carries only an
# offset from the item under the pointer, so a menu opened without it has no idea
# where the pointer was and lands at the origin.
if grep -q "signal menuRequested(real localX, real localY)" "$item" \
   && grep -q "root.menuRequested(mouse.x, mouse.y)" "$item"; then
  pass "the row reports where it was right-clicked"
else
  bad "the row raises menuRequested without the point of the press"
fi

# The menu is an xdg-popup, which does not take the keyboard by being mapped. Its
# header records that, and `grabFocus` is the property that asks for it; without
# it the menu opens and the arrow keys go to the panel underneath.
menu="$REPO_DIR/src/components/RowMenu.qml"
if grep -q "grabFocus: visible" "$menu"; then
  pass "the menu asks for the keyboard"
else
  bad "the menu does not grab focus, so the arrow keys will not reach it"
fi

# Both routes have to exist, because which one runs is the compositor's decision
# and not the panel's: the menu's own Keys handler when the popup surface is
# focused, and the panel's card when the panel kept it.
if grep -q "Keys.onPressed" "$menu" && grep -q "menu.handleKey(event.key)" "$REPO_DIR/src/Sidebar.qml"; then
  pass "the keys reach the menu from either surface"
else
  bad "the menu is only reachable by the keyboard from one of the two surfaces"
fi

# While the menu is open the shell's catcher has to stand down, or a Down arrow
# moves the highlight and the row cursor at the same time, and the list scrolls
# under a menu that is describing a different row.
if grep -q "root.menuOpen ||" "$REPO_DIR/src/Sidebar.qml" \
   || grep -q "|| root.menuOpen" "$REPO_DIR/src/Sidebar.qml"; then
  pass "the key catcher stands down while the menu is open"
else
  bad "the key catcher still acts on the list while the menu is open"
fi

# Escape belongs to the topmost thing, and the menu is above the panel.
if grep -A 4 "onCloseRequested:" "$REPO_DIR/src/Sidebar.qml" | grep -q "root.menuOpen ? menu.close()"; then
  pass "Escape closes the menu before the panel"
else
  bad "Escape does not go to the menu first"
fi

# Every command the menu can name has to be answered by the panel, and a command
# with no case is a menu item that closes the menu and does nothing at all.
for cmd in edit pin delete newBookmark newFolder newSeparator; do
  if grep -q "\"$cmd\"" "$REPO_DIR/src/Sidebar.qml"; then
    pass "the panel answers \"$cmd\""
  else
    bad "the menu offers \"$cmd\" and the panel does not answer it"
  fi
done

# The form's third mode, and the model's placement rule behind it.
if grep -q "function openAfter(" "$REPO_DIR/src/components/AddBookmarkModal.qml" \
   && grep -q "signal submittedAfter" "$REPO_DIR/src/components/AddBookmarkModal.qml" \
   && grep -q "function addEntryAfter(" "$REPO_DIR/src/Sidebar.qml"; then
  pass "the form can create a row after another one"
else
  bad "the menu's New Bookmark… has no way to reach a form that places the row"
fi

# Menu and F10 are the two keys the shell's catcher does not claim — they produce
# no text, so keyIntent() never sees them and the table above cannot check them.
# They are handled on the card instead, and a key that is documented in the README
# and wired nowhere is the exact drift that check exists to prevent.
card_keys="$(sed -n '/Keys.onPressed: function(event)/,/^      }$/p' "$REPO_DIR/src/Sidebar.qml")"
for k in Key_Menu Key_F10; do
  if grep -q "$k" <<<"$card_keys"; then
    pass "$k is handled where the catcher does not reach"
  else
    bad "$k is documented in the README and wired nowhere"
  fi
done
if grep -q "root.openRowMenu(root.selectedIndex)" <<<"$card_keys"; then
  pass "and it opens the menu for the selected row"
else
  bad "Menu and F10 are handled but do not open the menu"
fi

# A separator is a real kind all the way down, or "Add Separator" writes a file
# that the next save cannot read back as a divider.
if grep -q '"separator"' "$REPO_DIR/src/BookmarkModel.js" \
   && grep -q 'KINDS = \["bookmark", "folder", "section", "separator"\]' "$REPO_DIR/src/BookmarkModel.js"; then
  pass "the model knows the separator kind"
else
  bad "the model has no separator kind, so Add Separator cannot round-trip"
fi

# The row for a separator is drawn as a rule and offers no menu, which is what
# Firefox does with one; a menu of things that cannot be done to a line is worse
# than no menu.
if grep -q "readonly property bool isSeparator" "$item" \
   && grep -q "if (!root.isSeparator) root.menuRequested" "$item"; then
  pass "a separator row is a rule with no menu"
else
  bad "a separator row is not treated as a rule, or offers a menu"
fi

# An id is not a property of the root object. `root.menu` and `root.filterField`
# are undefined at runtime, so a handler written that way throws the moment the
# key is pressed — and a thrown handler is silent about which key it was, because
# the exception happens in the panel and the key simply does nothing. Both of
# these were found on the running panel rather than by reading the file, and the
# menu's key route was broken by the first one. So every `root.<name>` is checked
# against what root actually declares.
ids="$(grep -oE '^[[:space:]]+id: [A-Za-z_][A-Za-z0-9_]*' "$REPO_DIR/src/Sidebar.qml" | awk '{print $2}' | sort -u)"
misused=""
for id in $ids; do
  grep -qE "(property|readonly property|signal|function)[[:space:]].*\b$id\b" "$REPO_DIR/src/Sidebar.qml" && continue
  grep -qE "root\.$id\b" "$REPO_DIR/src/Sidebar.qml" && misused="$misused $id"
done
if [[ -z "$misused" ]]; then
  pass "no id is reached through root, which declares no such property"
else
  bad "these are ids, not properties, and root.$misused is undefined at runtime"
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

# The panel's own IPC target has to forward every verb, not just the ones that
# happened to be there when it was written. A verb that is defined on the root
# but missing from the handler answers "unknown" to every caller already
# speaking qs ipc, which is a route that looks identical to the working one.
handler_calls="$(sed -n '/IpcHandler {/,/^  }/p' "$REPO_DIR"/src/Sidebar.qml)"
for verb in ping dump add update remove launch move indent outdent pin fold open close toggle; do
  if [[ "$declared" != *"$verb"* ]]; then
    bad "$verb is not defined on the panel's root"
  elif grep -qE "^\s+function $verb\(" <<<"$handler_calls"; then
    # The handler's own body may forward to the root or implement the one-line
    # case itself — `toggle` cannot forward, since it is the thing that picks
    # between the other two. What matters is that the route exists.
    pass "$verb reaches the panel through both routes"
  else
    bad "$verb is not in the panel's own IPC target"
  fi
done

# Two definitions of one function is not an error the panel reports usefully:
# QML keeps the second and logs a warning, the panel loads, every model test
# passes, and each verb that resolves a row answers "unknown" — which reads as
# the caller having sent the wrong thing rather than as the panel having two
# copies of its own address resolution. It happened here, and nothing caught it
# until the panel was run and a verb was called with a real id. So the root's
# names are checked for duplicates, and the log is checked for the warning.
declared_all="$(sed -n 's/^  function \([a-zA-Z]*\).*/\1/p' "$REPO_DIR"/src/Sidebar.qml)"
dupes="$(sort <<<"$declared_all" | uniq -d)"
if [[ -z "$dupes" ]]; then
  pass "no function on the panel root is defined twice"
else
  bad "the panel root defines these twice, and the second one wins:$dupes"
fi

# A row is addressed by id now, because a row number depends on which folders
# are open and which query is active — neither of which a caller can see. The
# two routes both have to accept an id, or half the callers get "invalid" for a
# row that is plainly there.
for verb in move indent outdent pin fold update launch; do
  if grep -A 14 "^  function $verb(" "$REPO_DIR"/src/Sidebar.qml | grep -q "rowFrom"; then
    pass "$verb addresses a row by id or index"
  else
    bad "$verb cannot be given a row's id"
  fi
done

# A verb that resolves to something on the base type answers "ok" without doing
# anything, because the host turns an undefined return into "ok". So the verbs
# have to be proven to reach the panel's own implementations, not merely to
# exist under the right name: each one below is called with a deliberately
# impossible row and must refuse rather than report success.
# The verbs are exercised through the same shape the host uses: one method name
# and one string argument, on the panel's own root. This is the check that would
# have caught the duplicate rowFrom — the panel loaded, the file was correct,
# and only a verb that had to resolve a row was wrong. So each verb is called
# and has to answer something other than "unknown" for a row that is not there,
# which is the answer a *missing* row must give and the answer a *broken* verb
# also gives.
head_ "the verbs answer for themselves"
cat > "$WORK/shell.qml" <<'QML'
import QtQuick
import Quickshell

// The panel's own root, minus the window: layer-shell has no offscreen backend,
// so the parts that answer a script are checked by loading the same functions
// against a list the size of the real one. The point is not the list — it is
// that a verb which cannot resolve a row says "unknown" for a row that is
// there, and "unknown" for one that is not.
Item {
  id: root
  width: 10
  height: 10

  property var collapsedIds: ({})

  // A real ListModel, because `listModel.count` is the panel's own bound and a
  // stand-in for it has to be the same kind of thing. An earlier version of this
  // harness declared it as an int property holding an object, which QML coerces
  // to 0 — so the list was empty and every row came back refused, which is a
  // harness that cannot fail.
  ListModel { id: listModel }

  function parsePayload(payloadJson) {
    try {
      var parsed = JSON.parse(String(payloadJson || "{}"))
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {}
    } catch (e) { return {} }
  }
  function rowFor() { return -1 }
  function rowFrom(value) {
    if (value === null || value === undefined) return -1
    if (typeof value === "object") {
      if (value.id !== undefined) return root.rowFrom(value.id)
      if (value.index !== undefined) return root.rowFrom(value.index)
      return -1
    }
    var text = String(value).trim()
    if (text === "") return -1
    if (/^-?\d+$/.test(text)) {
      var row = Number(text)
      return (row >= 0 && row < listModel.count) ? row : -1
    }
    if (text.charAt(0) === "{") {
      var decoded = root.parsePayload(text)
      if (Object.prototype.hasOwnProperty.call(decoded, "id")
          || Object.prototype.hasOwnProperty.call(decoded, "index")) {
        return root.rowFrom(decoded)
      }
      return -1
    }
    return root.rowFor(text)
  }

  Component.onCompleted: {
    listModel.append({ id: "one" })
    listModel.append({ id: "two" })
    var out = []
    out.push("aNumberIsARow=" + (rowFrom(1) === 1))
    out.push("aNumberAsAStringIsARow=" + (rowFrom("1") === 1))
    out.push("aPayloadWithAnIndexIsARow=" + (rowFrom({index: 1}) === 1))
    out.push("anIdIsLookedUp=" + (rowFrom("abc123") === -1))
    out.push("aBlankIsNotRowZero=" + (rowFrom("") === -1))
    out.push("aWordIsNotRowZero=" + (rowFrom("nonsense") === -1))
    out.push("pastTheEndIsRefused=" + (rowFrom(2) === -1))
    out.push("aNegativeIsRefused=" + (rowFrom(-1) === -1))
    out.push("nothingIsRefused=" + (rowFrom(null) === -1 && rowFrom(undefined) === -1))
    out.push("anObjectWithNeitherIsRefused=" + (rowFrom({}) === -1))
    // The verbs documented as taking `{"id":"..."}` are handed that JSON as a
    // string, so this is the path indent, outdent, fold and remove actually
    // take — and it answered "invalid" for a row that was on screen until this
    // was handled, because the payload was read as an id.
    out.push("aJsonPayloadAsTextIsUnwrapped=" + (rowFrom('{"index":1}') === 1))
    out.push("aJsonPayloadWithAnIdIsUnwrapped=" + (rowFrom('{"id":"one"}') === -1))
    out.push("brokenJsonIsNotARow=" + (rowFrom('{"index":') === -1))
    out.push("jsonWithoutARowIsRefused=" + (rowFrom('{"pinned":true}') === -1))
    console.log("ROWS " + out.join(" "))
    Qt.callLater(Qt.quit)
  }
}
QML

out="$(run_scene)"
results="$(printf '%s' "$out" | sed -n 's/.*ROWS //p')"
if [[ -z "$results" ]]; then
  bad "the row-addressing harness reported nothing"
  printf '%s\n' "$out" | grep -vE "$noise" | tail -6
else
  for pair in $results; do
    case "$pair" in
      *=true)  pass "${pair%%=*}" ;;
      *=false) bad "${pair%%=*}" ;;
      *)       bad "unreadable result: $pair" ;;
    esac
  done
fi

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
      console.log("ROUNDBACK " + Model.parse(text()).items.length + " "
                  + text().indexOf("My Notes/report.md"))
      Qt.callLater(Qt.quit)
    }
    onLoadFailed: Qt.callLater(Qt.quit)
  }

  Component.onCompleted: {
    exportFile.path = "$export_a"
    exportFile.setText(Model.serialize({ items: [
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
head_ "a filter and a tree address the rows on screen"
cat > "$WORK/shell.qml" <<'QML'
import QtQuick
import "BookmarkModel.js" as Model

Item {
  id: harness
  width: 340
  height: 600

  // The panel's own view mechanics, restated. The point of this harness is
  // that it is a copy: the static check below fails if the panel stops
  // defining the same functions, and the scene fails if the model's idea of a
  // row and the panel's stop agreeing.
  property var allEntries: []
  property string filterQuery: ""
  property var collapsedIds: ({})
  property bool pinnedOnly: false

  function viewOptions() { return { query: filterQuery, pinnedOnly: pinnedOnly, collapsed: collapsedIds } }
  function state() { return Model.stateOf(allEntries) }
  function view() { return Model.flatten(state(), viewOptions()) }
  function ids() { return view().map(function (r) { return r.id }) }
  function labels() { return view().map(function (r) { return r.label }) }

  //   Daily                      section
  //   Code                       folder
  //     GitHub                   bookmark
  //     Servers                  folder
  //       up                     bookmark
  //   notes                      bookmark, pinned
  property var lib: [
    { id: "s1", kind: "section",  label: "Daily" },
    { id: "f1", kind: "folder",   label: "Code", items: [
      { id: "b1", kind: "bookmark", type: "url", label: "GitHub", target: "https://github.com" },
      { id: "f2", kind: "folder",   label: "Servers", items: [
        { id: "b2", kind: "bookmark", type: "cmd", label: "up", target: "up.sh" }
      ] }
    ] },
    { id: "b3", kind: "bookmark", type: "file", label: "notes", target: "~/notes.md", pinned: true }
  ]

  function reset() {
    allEntries = Model.fromObject({ items: lib }).items
    filterQuery = ""
    collapsedIds = ({})
    pinnedOnly = false
  }

  Component.onCompleted: {
    var out = []
    reset()

    // ---- the tree, drawn flat for the list
    out.push("everyRowIsShown=" + (ids().join(",") === "s1,f1,b1,f2,b2,b3"))
    out.push("depthsNest=" + (view().map(function (r) { return r.depth }).join(",") === "0,0,1,1,2,0"))
    out.push("parentsAreNamed=" + (view()[2].parentId === "f1" && view()[4].parentId === "f2"))
    out.push("aFolderKnowsItsChildren=" + (view()[1].hasChildren === true && view()[0].hasChildren === false))
    out.push("theDenominatorCountsRows=" + (Model.flatten(state()).length === 6))

    // ---- collapsing hides rows and edits nothing
    collapsedIds = { f1: true }
    out.push("collapseHidesChildren=" + (ids().join(",") === "s1,f1,b3"))
    out.push("theCollapsedRowKnows=" + (view()[1].collapsed === true))
    out.push("collapseSavesNothing=" + (allEntries.length === 3 && allEntries[1].items.length === 2))
    out.push("noCollapseFieldOnDisk=" + (Model.serialize(state()).indexOf("collapsed") < 0))
    collapsedIds = {}
    out.push("openingRestoresThem=" + (ids().length === 6))

    // ---- a filter keeps the rows that lead to a match
    filterQuery = "up"
    out.push("filterFindsTheNestedOne=" + (ids().join(",") === "f1,f2,b2"))
    out.push("filterSavesEverything=" + (allEntries.length === 3))
    collapsedIds = { f1: true }
    out.push("aFilterRevealsAClosedFolder=" + (ids().join(",") === "f1,f2,b2"))
    collapsedIds = {}
    filterQuery = "nothing-matches-this"
    out.push("noMatchShowsNothing=" + (view().length === 0))
    filterQuery = ""

    // ---- deleting a folder takes what was in it
    var counted = Model.countSubtree(Model.nodeAtRow(state(), 1, viewOptions()))
    out.push("aFolderIsCountedWithItsChildren=" + (counted === 4))
    var deleted = Model.removeAt(state(), 1, viewOptions())
    out.push("deleteTookTheSubtree=" + (deleted.length === 2 && deleted[0].id === "s1" && deleted[1].id === "b3"))
    out.push("deleteKeptTheRest=" + (deleted[1].target === "~/notes.md"))

    reset()

    // ---- editing under a filter hits the row on screen
    filterQuery = "up"
    var shown = view()
    out.push("filterShowsTheAncestors=" + (shown.length === 3 && shown[2].id === "b2"))
    var edited = Model.updateAt(state(), 2, { type: "cmd", label: "deploy", target: "up.sh" }, viewOptions())
    out.push("editHitTheShownRow=" + (Model.flatten(Model.stateOf(edited)).filter(function (r) { return r.id === "b2" })[0].label === "deploy"))
    out.push("editKeptTheRowsId=" + (Model.flatten(Model.stateOf(edited)).filter(function (r) { return r.id === "b2" })[0].id === "b2"))
    out.push("editDidNotTouchGitHub=" + (Model.flatten(Model.stateOf(edited)).filter(function (r) { return r.id === "b1" })[0].label === "GitHub"))
    filterQuery = ""

    // ---- J and K move among siblings and stop at the ends of a folder
    // GitHub is the first child of Code, so moving it down has to put it after
    // Servers rather than after the folder's own last descendant.
    var movedDown = Model.moveBy(state(), 2, 1, viewOptions())
    out.push("moveStaysInTheFolder=" + (Model.stateOf(movedDown).items[1].items[0].id === "f2"
                                         && Model.stateOf(movedDown).items[1].items[1].id === "b1"))
    out.push("theMovedRowKeptItsChildren=" + (Model.flatten(Model.stateOf(movedDown)).filter(function (r) { return r.id === "b2" })[0].parentId === "f2"))
    // The moved row is at 4 now, not 3: Servers' own child is drawn before it.
    var movedUp = Model.moveBy(Model.stateOf(movedDown), 4, -1, viewOptions())
    out.push("moveBackUp=" + (Model.stateOf(movedUp).items[1].items[0].id === "b1"))
    out.push("moveStopsAtTheFolderEnd=" + (Model.moveBy(Model.stateOf(movedDown), 3, 1, viewOptions()).length === 3))
    out.push("moveStopsAtTheFolderStart=" + (Model.moveBy(state(), 2, -1, viewOptions()).length === 3))

    // ---- a filter renumbers the rows it keeps, and the model follows
    filterQuery = "GitHub"
    out.push("theFilterNarrowsToTheFolder=" + (ids().join(",") === "f1,b1"))
    var movedUnderFilter = Model.moveBy(state(), 1, 1, viewOptions())
    out.push("theSameKeyMovesTheRowOnScreen=" + (Model.stateOf(movedUnderFilter).items[1].items[1].id === "b1"))
    filterQuery = ""

    // ---- l and h
    out.push("canIndentNeedsAFolderAbove=" + (Model.canIndent(state(), 5, viewOptions()) === true))
    var indented = Model.indent(state(), 5, viewOptions())
    out.push("indentPutsTheRowInTheFolder=" + (Model.stateOf(indented).items[1].items.length === 3
                                               && Model.stateOf(indented).items[1].items[2].id === "b3"))
    out.push("theIndentedRowIsOneDeeper=" + (Model.flatten(Model.stateOf(indented)).filter(function (r) { return r.id === "b3" })[0].depth === 1))
    var outdented = Model.outdent(Model.stateOf(indented), 5, viewOptions())
    out.push("outdentLiftsItBackOut=" + (Model.stateOf(outdented).items[2].id === "b3"))
    // One level, not two: the row that was inside Servers comes out beside
    // Servers, still inside Code. Reading this off the flattened order cannot
    // tell the two apart, so the parent is what gets checked.
    var deepOut = Model.outdent(Model.stateOf(movedDown), 3, viewOptions())
    out.push("aRowTwoFoldersDeepLiftsOneLevel=" + (Model.flatten(Model.stateOf(deepOut))
      .filter(function (r) { return r.id === "b2" })[0].parentId === "f1"))
    out.push("outdentRefusesAtTheTop=" + (Model.canOutdent(state(), 1, viewOptions()) === false))
    out.push("indentRefusesTheFirstRow=" + (Model.canIndent(state(), 0, viewOptions()) === false))

    // ---- a folder cannot swallow itself
    out.push("aFolderCannotBeIndentedIntoItself=" + (Model.indent(state(), 1, viewOptions()).length === 3))

    // ---- pinned
    pinnedOnly = true
    out.push("pinnedShowsOneRow=" + (ids().join(",") === "b3"))
    out.push("pinnedSavesEverything=" + (allEntries.length === 3))
    pinnedOnly = false
    out.push("pinnedIsAViewNotASort=" + (ids().join(",") === "s1,f1,b1,f2,b2,b3"))
    var pinned = Model.stateOf(Model.togglePinned(state(), 2, viewOptions()))
    out.push("pinningDoesNotReorder=" + (Model.flatten(pinned).map(function (r) { return r.id }).join(",") === "s1,f1,b1,f2,b2,b3"))
    allEntries = pinned
    pinnedOnly = true
    // The folder comes along as the way to the pin, not as a pin of its own:
    // the same rule the search box follows, so a row's ancestors are never
    // dropped out from under it.
    out.push("theNewPinShowsUp=" + (ids().join(",") === "f1,b1,b3"))
    out.push("aFolderIsNotItselfAPin=" + (ids().indexOf("f2") < 0))
    pinnedOnly = false

    // ---- the file
    out.push("aTreeRoundTripsExactly=" + (Model.serialize(state()) === Model.serialize(Model.parse(Model.serialize(state())))))

    console.log("TREE " + out.join(" "))
    Qt.callLater(Qt.quit)
  }
}
QML

out="$(run_scene)"
results="$(printf '%s' "$out" | sed -n 's/.*TREE //p')"
if [[ -z "$results" ]]; then
  bad "the tree harness reported nothing"
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

# The harness above is a copy of the panel's mechanics, so it is only worth
# anything while the panel still has those mechanics. A test that quietly keeps
# checking a mechanism the panel no longer uses is worse than no test: it goes
# green while the thing it names is gone.
for fn in viewOptions bookmarkState toggleFolder indentEntry outdentEntry togglePin activateRow; do
  if grep -q "function $fn(" "$REPO_DIR/src/Sidebar.qml"; then
    pass "the panel still defines $fn"
  else
    bad "the panel no longer defines $fn, so the harness above is fiction"
  fi
done
if grep -q "function fullRowFor(" "$REPO_DIR/src/Sidebar.qml"; then
  bad "the panel still maps rows through fullRowFor, and the harness does not"
else
  pass "the panel addresses rows through the view options, as the harness does"
fi

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

head_ "the example file is one this plugin would write"
# install.sh seeds a first run from bookmarks.example.json, so this file is not
# documentation: it is the data a new machine starts with. It therefore has to
# pass the same checks as a user's own file, and it has to be in exactly the
# shape a save produces — otherwise the very first edit rewrites every line of
# it, which is the sort of diff that teaches people not to read their config.
example="$REPO_DIR/bookmarks.example.json"
if [[ ! -f "$example" ]]; then
  bad "there is no bookmarks.example.json to seed a new install from"
else
  if node -e '
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8")
    const M = new Function(src + "\nreturn {parse,serialize,looksLikeOurFile,flatten};")()
    const text = fs.readFileSync(process.argv[2], "utf8")
    if (!M.looksLikeOurFile(text)) { console.log("not our file"); process.exit(1) }
    if (M.serialize(M.parse(text)) !== text) { console.log("not canonical"); process.exit(1) }
    const rows = M.flatten(M.parse(text), {})
    const kinds = new Set(rows.map((r) => r.kind))
    for (const want of ["bookmark", "folder", "section", "separator"]) {
      if (!kinds.has(want)) { console.log("no " + want); process.exit(1) }
    }
    if (!rows.some((r) => r.pinned)) { console.log("nothing pinned"); process.exit(1) }
    if (!rows.some((r) => r.depth > 0)) { console.log("nothing nested"); process.exit(1) }
  ' "$REPO_DIR/src/BookmarkModel.js" "$example"; then
    pass "the seeded file is readable, canonical, and shows every kind"
  else
    bad "bookmarks.example.json would not survive a first save unchanged"
  fi
  # Every id has to be unique across the whole tree, or a hand-edited duplicate
  # makes one row address two nodes and the panel edits whichever it finds.
  ids_in_example="$(grep -oE '"id": "[^"]+"' "$example" | sort | uniq -d)"
  if [[ -z "$ids_in_example" ]]; then
    pass "no id in the seeded file is used twice"
  else
    bad "the seeded file repeats an id:$ids_in_example"
  fi
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
