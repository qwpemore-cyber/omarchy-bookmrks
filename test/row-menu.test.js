// Runs the real menu logic out of RowMenu.qml without a display.
//
// The functions are read out of the QML file and evaluated here, so this tests
// the file rather than a copy of it: if `itemsFor` changes, this changes. The
// Qt enums are stubbed with the values they have in QML, and `root` is a plain
// object standing in for the PopupWindow.

const fs = require("fs");
const path = require("path");

const QML = path.join(__dirname, "..", "src", "components", "RowMenu.qml");
const source = fs.readFileSync(QML, "utf8");

const Qt = { Key_Escape: 0x01000000, Key_Down: 0x01000005, Key_Up: 0x01000003, Key_Home: 0x01000010, Key_End: 0x01000011, Key_Return: 0x01000004, Key_Enter: 0x01000004, Key_Space: 0x20 };

// Pull a top-level function out of the QML by brace-matching from its name.
function fn(name) {
  const start = source.search(new RegExp("^  function " + name + "\\(", "m"));
  if (start === -1) throw new Error("no function " + name + " in RowMenu.qml");
  const open = source.indexOf("{", start);
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    if (source[i] === "{") depth++;
    else if (source[i] === "}") {
      depth--;
      if (depth === 0) return source.slice(start, i + 1);
    }
  }
  throw new Error("unbalanced braces in " + name);
}

const names = ["itemsFor", "editLabel", "deleteLabel", "itemRowHeight", "heightOf", "focusFirstCommand", "focusLastCommand", "moveHighlight", "handleKey", "runHighlighted"];

// In QML these functions are all in one component scope, so they call each other
// unqualified: `itemsFor` says `editLabel(kind)` and means itself. Compiling them
// one at a time would not reproduce that, so they are compiled together.
const compile = new Function("Qt", "root", names.map(fn).join("\n") + "\nreturn {" + names.join(",") + "};");

let failures = 0;
let count = 0;
function eq(what, got, want) {
  count++;
  if (JSON.stringify(got) === JSON.stringify(want)) return;
  failures++;
  console.log("FAIL " + what + "\n  got  " + JSON.stringify(got) + "\n  want " + JSON.stringify(want));
}

// A stand-in for the PopupWindow: the properties the menu reads, and the two
// things it does — close itself, and raise the action it ran.
function menuFor(entry, subtreeCount) {
  const raised = [];
  const root = {
    entry: entry,
    subtreeCount: subtreeCount || 0,
    highlighted: -1,
    visible: false,
    // The shell's popup metrics, as Style.spacing reports them, so the numbers the
    // menu computes with here are the numbers it draws with there.
    rowHeight: 28,
    separatorHeight: 9,
    rowIndex: -1,
    closed: 0,
    action(name, payload) { raised.push([name, payload.rowIndex]); }
  };
  Object.assign(root, compile(Qt, root));
  // `items` is a bound property in the QML, not a function, so it is rebuilt
  // here from the same expression: entry === null ? [] : itemsFor(entry).
  Object.defineProperty(root, "items", { get() { return root.entry === null ? [] : root.itemsFor(root.entry); } });
  // close() is the popup's own, not a logic function: it hides and re-raises.
  root.close = function () { root.visible = false; root.closed++; root.dismissed = (root.dismissed || 0) + 1; };
  return { root, raised };
}

const bookmark = { kind: "bookmark", label: "GitHub", pinned: false };
const pinned = { kind: "bookmark", label: "GitHub", pinned: true };
const folder = { kind: "folder", label: "Code" };
const section = { kind: "section", label: "Daily" };
const separator = { kind: "separator", label: "" };

// --- what is in the menu, per kind -----------------------------------------

const b = menuFor(bookmark, 0);
eq("a bookmark's menu is Firefox's, in Firefox's order",
   b.root.items.map((i) => i.label),
   ["Edit Bookmark…", "Pin Bookmark", "", "New Bookmark…", "New Folder…", "Add Separator", "", "Delete Bookmark"]);

const p = menuFor(pinned, 0);
eq("a pinned bookmark offers to be unpinned, not pinned",
   p.root.items.map((i) => i.label)[1], "Unpin Bookmark");

const f = menuFor(folder, 3);
eq("a folder has no pin, and counts what it holds",
   f.root.items.map((i) => i.label),
   ["Edit Folder…", "", "New Bookmark…", "New Folder…", "Add Separator", "", "Delete Folder (3 bookmarks)"]);

const f1 = menuFor(folder, 1);
eq("a folder holding one row counts in the singular",
   f1.root.items.map((i) => i.label).pop(), "Delete Folder (1 bookmark)");

const f0 = menuFor(folder, 0);
eq("an empty folder counts nothing rather than counting zero",
   f0.root.items.map((i) => i.label).pop(), "Delete Folder");

const s = menuFor(section, 2);
eq("a section edits as a section and deletes with its own count",
   s.root.items.map((i) => i.label),
   ["Edit Section…", "", "New Bookmark…", "New Folder…", "Add Separator", "", "Delete Section (2 items)"]);

const sep = menuFor(separator, 0);
eq("a separator has no menu at all", sep.root.items, []);

const none = menuFor(null, 0);
eq("no row means no menu", none.root.items, []);

// A row that arrives with no kind at all is a bookmark, because that is what
// every field in the file defaults to, and a menu that is empty for an ordinary
// bookmark is a bug that only shows up on a malformed file.
const bare = menuFor({ label: "thing" }, 0);
eq("a row with no kind is treated as a bookmark", bare.root.items[0].label, "Edit Bookmark…");

// --- the gaps ---------------------------------------------------------------

eq("the gaps are in the list, not on it, so the keys can skip them",
   b.root.items.filter((i) => i.action === "").length, 2);
eq("a gap has no height of a row", b.root.itemRowHeight(b.root.items[2]), 9);
eq("a command has the shell's popup row height", b.root.itemRowHeight(b.root.items[0]), 28);
eq("the menu is as tall as its items and nothing else", b.root.heightOf(b.root.items), 28 * 6 + 9 * 2);

// --- the keyboard -----------------------------------------------------------

const k = menuFor(bookmark, 0);
k.root.visible = true;
k.root.focusFirstCommand();
eq("a menu opens on its first command, not on the gap under it", k.root.highlighted, 0);
k.root.moveHighlight(1);
eq("Down from the first command goes to the second, which is one down", k.root.items[k.root.highlighted].label, "Pin Bookmark");
k.root.moveHighlight(1);
eq("Down from the second command skips the gap", k.root.items[k.root.highlighted].label, "New Bookmark…");
k.root.moveHighlight(1);
k.root.moveHighlight(1);
k.root.moveHighlight(1);
eq("Down walks on to the last command, skipping the second gap", k.root.items[k.root.highlighted].label, "Delete Bookmark");
k.root.moveHighlight(1);
eq("Down from the last command wraps to the first", k.root.items[k.root.highlighted].label, "Edit Bookmark…");
k.root.moveHighlight(-1);
eq("Up from the first wraps to the last", k.root.items[k.root.highlighted].label, "Delete Bookmark");
k.root.focusFirstCommand();
eq("Home returns to the first command", k.root.items[k.root.highlighted].label, "Edit Bookmark…");
k.root.focusLastCommand();
eq("End returns to the last command", k.root.items[k.root.highlighted].label, "Delete Bookmark");

// Enter on a highlighted command runs it and closes the menu. Running it before
// closing would be a bug of its own: the panel acts on the row through its own
// index, and the menu's row is the row the user was looking at.
k.root.highlighted = 5;
k.root.rowIndex = 3;
k.root.runHighlighted();
eq("Enter runs the highlighted command, carrying the row it was opened on",
   k.raised, [["newSeparator", 3]]);
eq("and running it closes the menu", k.root.closed, 1);

// A menu whose highlight sits on a gap runs nothing, rather than falling through
// to the first command and deleting something.
const g = menuFor(bookmark, 0);
g.root.visible = true;
g.root.highlighted = 2;
g.root.runHighlighted();
eq("a gap runs nothing at all", g.raised, []);
eq("and does not close the menu either", g.root.closed, 0);

// Escape is the menu's to handle, and it closes only the menu.
const e = menuFor(bookmark, 0);
e.root.visible = true;
eq("Escape is claimed by the menu", e.root.handleKey(Qt.Key_Escape), true);
eq("Escape closes the menu", e.root.closed, 1);

const h = menuFor(bookmark, 0);
h.root.visible = true;
eq("an arrow key is claimed by the menu", h.root.handleKey(Qt.Key_Down), true);
eq("a key that is not the menu's is left for the panel to answer",
   h.root.handleKey(Qt.Key_Tab || 0x01000001), false);
const shut = menuFor(bookmark, 0);
shut.root.visible = false;
eq("a closed menu claims no keys, so the panel keeps its own", shut.root.handleKey(Qt.Key_Down), false);

const r = menuFor(bookmark, 0);
r.root.visible = true;
r.root.highlighted = 0;
eq("Return is claimed", r.root.handleKey(Qt.Key_Return), true);
eq("Return runs the command", r.raised.map((a) => a[0]), ["edit"]);

// Nothing is highlighted yet, so a Down must not land on a gap — and an Up from
// nowhere must land on the last command, not the first.
const n = menuFor(bookmark, 0);
n.root.visible = true;
n.root.highlighted = -1;
n.root.moveHighlight(1);
eq("Down from no highlight lands on the first command", n.root.items[n.root.highlighted].label, "Edit Bookmark…");
n.root.highlighted = -1;
n.root.moveHighlight(-1);
eq("Up from no highlight lands on the last command", n.root.items[n.root.highlighted].label, "Delete Bookmark");

// A menu of nothing but gaps must not spin or throw when the keys arrive.
const empty = menuFor(separator, 0);
empty.root.visible = true;
empty.root.moveHighlight(1);
empty.root.runHighlighted();
eq("a menu with no commands survives the keys", [empty.raised, empty.root.closed], [[], 0]);

console.log(count + " passed, " + failures + " failed");
process.exit(failures === 0 ? 0 : 1);
