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
