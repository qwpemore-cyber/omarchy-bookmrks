# Bookmarks Bar for Omarchy

A keyboard-driven sidebar for Omarchy that keeps the things you open all day —
links, apps, and commands — one `SUPER + B` away.

![type: module](https://img.shields.io/badge/type-QML%20%2B%20Quickshell-blue)

## What it does

- A panel on the **left edge** that slides in and out.
- Three kinds of row, the way Firefox's bookmark tree is built:
  | kind | what it is | runs? |
  |------|------------|-------|
  | `bookmark` | a thing you can open | yes |
  | `folder` | a named group that holds other rows | no — `Return` opens it |
  | `section` | a heading between groups of rows | no — `Return` does nothing |
- Four types of bookmark, all handled the same way once saved:
  | type | what it is | example target |
  |------|------------|----------------|
  | `url` | a web address | `https://github.com` |
  | `app` | a desktop entry | `org.gnome.Nautilus` |
  | `cmd` | any command | `omarchy-capture-screenshot` |
  | `file` | a file or folder | `~/notes.md`, `/etc/hosts` |
- Nesting to any depth, with the keyboard: `l` puts a row inside the folder
  above it and `h` takes it back out one level.
- Pinning a bookmark, and a filter that shows the pinned rows on their own.
- Add, edit, reorder, and delete entries from the sidebar. Deleting a folder
  deletes what is in it, and says how much.
- A filter box that searches names and targets as you type. A folder opens
  itself to show a match inside it, and closes again when the search is cleared.
- Export and import, so the list can be moved to another machine.
- Icons resolved from your installed `.desktop` files, falling back to a glyph
  per type.
- Follows your theme and font size, and respects reduced motion.

## Usage

Open the panel with `SUPER + B`, or from a terminal:

```sh
omarchy-shell shell summon omarchy-bookmarks-bar   # open
omarchy-shell shell hide omarchy-bookmarks-bar     # close
omarchy-shell shell toggle omarchy-bookmarks-bar   # either way
```

Move with `j`/`k`, launch the selected entry with `Return`, and `a` to add.
Nothing needs the mouse — see [Keys](#keys) for the full map.

### Adding an entry

Press `a` and pick what the row will be: a **bookmark**, a **folder**, or a
**section**. A folder or a section has nothing to run, so the form hides the
type and target fields entirely and asks only for a name.

Adding while a folder is selected puts the new row **inside** that folder. If
that was not what you wanted, `h` lifts it back out to where you were.

For a bookmark, fill in **Label** (what the list shows) and **Target** (what
actually runs), then `Return`:

| type | Target accepts | example |
|------|----------------|---------|
| `url` | a web address | `https://github.com` |
| `app` | a desktop entry id, or a bare command | `org.gnome.Nautilus`, `firefox` |
| `cmd` | any command line | `omarchy-capture-screenshot` |
| `file` | a full path, or one starting with `~` | `~/notes.md`, `/home/bo/code` |

A `file` entry can be typed or picked: **File…** and **Folder…** fill the same
Target field, and the field stays editable afterwards. The label is the last
segment of the path, so `/tmp/My Notes/report.md` is listed as `report.md`. A
path that is not there yet is still saved — an unmounted drive is not a broken
bookmark — and `~` is stored as typed and expanded at launch, so a saved panel
keeps working on a machine with a different user name. A relative path is
refused: it would mean a different file depending on where the panel was
started from.

In the form, `j`/`k` pick the type, `h`/`l` pick the kind, `Return` saves and
`Escape` cancels, so the whole thing works without touching the pointer.
**Icon** is optional: leave it empty and the panel uses a themed desktop icon
when there is one, otherwise a glyph for the type. **Pin** marks a bookmark as
one of the ones worth keeping in view, and is what the pin button in the header
filters down to.

Editing a folder does not offer to turn it into a bookmark while it still has
things in it: the form says how many are in there rather than saving a change
that would drop them. Empty the folder first, or move them out with `h`.

`cmd` is the only type that goes through a shell, which is the point of it. A
`url` or `app` target is passed as an argument and can never become a command
line, so a target containing spaces or quotes still does what it says.

### The right-click menu

Right-click any row for the same menu Firefox gives a bookmark, a folder or a
heading, with Firefox's own labels:

| On a bookmark | On a folder | On a heading |
| --- | --- | --- |
| Edit Bookmark… | Edit Folder… | Edit Section… |
| Pin Bookmark | | |
| | | |
| New Bookmark… | New Bookmark… | New Bookmark… |
| New Folder… | New Folder… | New Folder… |
| Add Separator | Add Separator | Add Separator |
| | | |
| Delete Bookmark | Delete Folder (*n* bookmarks) | Delete Section (*n* items) |

The menu opens at the pointer, in a window of its own, and closes on a click
anywhere else. It takes the keyboard too: `Up`/`Down` move, `Return` runs,
`Escape` closes. `Menu` and `F10` open it for the selected row, which is what
Firefox binds to a tree row as well.

Three details in there are Firefox's rather than obvious:

- **`Add Separator` needs a real kind.** A section with an empty name is a
  section called `(unnamed)`, so a rule is written as `{"kind": "separator"}`.
  It has no label, no target, no icon and no children, and it is the one kind
  with no menu of its own — in Firefox too, because there is nothing you can do
  to a line but delete it.
- **Where the new row goes follows the row you clicked.** `New Bookmark…` puts
  the new row *after* that row, not inside it, unless the row is a folder — then
  "after" a folder means inside it, which is the only place a container can put
  something it has no sibling relation to.
- **`Delete Folder` counts what it holds.** A folder with four bookmarks in it
  says `(4 bookmarks)`, because a delete that reads as one item is the one count
  that is not a nicety.

### Searching

The box above the list filters as you type, on both the label and the target —
the name somebody gave a bookmark and the thing it points at are rarely the same
word, and the target is usually what they remember. The header counts what is
shown out of what exists (`2 of 14`), so a filter that hid something cannot
quietly look like a list that never had it.

A search never changes what is saved. Filtering hides rows; it does not delete
them, and edit, delete and reorder still act on the entry you clicked, not on
whatever slid into its place. `Escape` clears the query before it closes
anything, and the box starts empty every time the panel opens.

### Moving to another machine

The gear button opens the settings sheet, which has three things in it:

- **Export…** writes your list to a JSON file, named
  `omarchy-bookmarks-YYYY-MM-DD.json` so a second export lands beside the first
  one instead of overwriting it. Copy that file to the other machine however you
  like — a USB stick, `scp`, a synced folder.
- **Import…** reads one back. When the file is read, two buttons appear: **Merge**
  adds anything you do not already have and leaves the rest alone, and **Replace**
  makes the file the whole list. **Merge** is the one that cannot lose anything.
- **Reveal bookmarks.json** opens the live file in your editor.

Importing the same file twice adds nothing the second time. An entry is
recognised by its `id` and also by what it points at, so a bookmark that reached
the file by hand, or through another machine, is not duplicated. A file that is
not this panel's own — some other tool's JSON, a half-written file — is refused
and nothing is changed, so a stray file can never be read as "zero bookmarks" and
silently empty the list.

`file` targets keep their `~`, so a list exported from one account and imported
on another still points at the right home directory.

### Where your entries live

`~/.config/omarchy/bookmarks.json`, outside the plugin folder on purpose:
reinstalling, updating, or removing the plugin never touches your data. Edit it
with any editor, or through the panel — the panel watches the file, so an
external edit shows up immediately.

## Install

```sh
git clone https://github.com/qwpemore-cyber/omarchy-bookmrks.git
cd omarchy-bookmrks
./install.sh
```

`install.sh` installs the copy in the folder you cloned, so edits to
`src/*.qml` reload in the running shell without a restart. To install from
GitHub instead:

```sh
./install.sh --remote
```

Options:

| flag | effect |
|------|--------|
| `--remote` | install by cloning from GitHub rather than using this folder |
| `--no-keybind` | install without editing `~/.config/hypr` |
| `--yes` | never prompt |

The installer also seeds `~/.config/omarchy/bookmarks.json` from
`bookmarks.example.json` the first time, and adds this to
`~/.config/hypr/bindings.lua`:

```lua
-- >>> omarchy-bookmarks-bar >>>
o.bind("SUPER + B", "Bookmarks bar", "omarchy-shell shell toggle omarchy-bookmarks-bar")
-- <<< omarchy-bookmarks-bar <<<
```

`bindings.lua` is Lua, so those markers are `--` comments and not `#`. The
installer reloads Hyprland after writing and puts the file back the way it was
if the new config does not parse, so a bad edit can never leave you without
keybindings.

## Uninstall

```sh
./uninstall.sh            # remove the plugin, keep your bookmarks
./uninstall.sh --purge    # also delete your bookmark list
```

The keybinding block is removed by marker, so running either script repeatedly
is safe and never stacks duplicates.

## Your data

Bookmarks live in `~/.config/omarchy/bookmarks.json`, outside the plugin
folder. Reinstalling or removing the plugin never touches it.

```json
{
  "version": 2,
  "items": [
    { "id": "s1", "kind": "section", "label": "Daily" },
    { "id": "f1", "kind": "folder", "label": "Code", "items": [
      { "id": "b1", "kind": "bookmark", "type": "url", "label": "GitHub", "target": "https://github.com", "icon": "", "pinned": true },
      { "id": "b2", "kind": "bookmark", "type": "app", "label": "Files", "target": "org.gnome.Nautilus", "icon": "org.gnome.Nautilus", "pinned": false }
    ] },
    { "id": "b3", "kind": "bookmark", "type": "cmd", "label": "Screenshot", "target": "omarchy-capture-screenshot", "icon": "", "pinned": false }
  ]
}
```

`bookmarks.example.json` in this repository is the same thing, in the exact
shape a save writes.

Three fields carry the meaning: `kind` says what the row is (`bookmark`,
`folder` or `section`), `items` nests children inside their parent, and
`pinned` marks a bookmark as one of the ones the pin button filters down to.
Order is the order in the array, so there is no separate position to keep in
step with it.

An older `version: 1` file with a flat `bookmarks` array is read as it stands
and rewritten in this shape the first time anything is saved, with a copy of
the original left at `~/.config/omarchy/bookmarks.json.bak`. Nothing is dropped
in the conversion, and the panel never writes the v1 shape again.

Unknown fields are ignored, missing fields are filled in, and a malformed
entry is skipped rather than taking the whole list down — including an entry
that is malformed several folders down, which is checked recursively so one bad
row in a nested folder is not taken as a reason to discard the file.

## Command from elsewhere

The panel answers IPC calls, so you can drive it from Hyprland, a key binding,
or a script:

```sh
omarchy-shell shell toggle omarchy-bookmarks-bar
omarchy-shell shell summon omarchy-bookmarks-bar   # open only
omarchy-shell shell hide omarchy-bookmarks-bar     # close only
```

`call` reaches the panel's root item, one argument, so it takes a method and a
JSON payload. Every verb answers `"ok"`, `"invalid"`, `"unknown"` or
`"boundary"`, so a script can tell a rejected payload from a row that is not
there from a move that had nowhere to go:

```sh
omarchy-shell shell call omarchy-bookmarks-bar ping ''
omarchy-shell shell call omarchy-bookmarks-bar dump ''

# add a bookmark, a folder, or a section
omarchy-shell shell call omarchy-bookmarks-bar add \
  '{"type":"url","label":"GitHub","target":"https://github.com"}'
omarchy-shell shell call omarchy-bookmarks-bar add \
  '{"kind":"folder","label":"Code"}'

# edit a row — "index" is stripped before the entry is validated
omarchy-shell shell call omarchy-bookmarks-bar update \
  '{"index":0,"type":"url","label":"GitHub (work)","target":"https://github.com"}'

# remove a row
omarchy-shell shell call omarchy-bookmarks-bar remove 0
```

### Addressing a row

A row number depends on which folders are open and on what is in the filter
box, neither of which a script can see. So every verb that takes a row also
takes the row's **id**, which is in the file and does not move:

```sh
omarchy-shell shell call omarchy-bookmarks-bar pin '{"id":"b1"}'
omarchy-shell shell call omarchy-bookmarks-bar fold '{"id":"f1"}'
omarchy-shell shell call omarchy-bookmarks-bar indent '{"id":"b1"}'
omarchy-shell shell call omarchy-bookmarks-bar outdent '{"id":"b1"}'
omarchy-shell shell call omarchy-bookmarks-bar move '{"id":"b1","delta":1}'
omarchy-shell shell call omarchy-bookmarks-bar launch '{"id":"b1"}'
```

`update` and `launch` take the same id:

```sh
omarchy-shell shell call omarchy-bookmarks-bar update '{"id":"b1","label":"New name"}'
omarchy-shell shell call omarchy-bookmarks-bar launch '{"id":"b1"}'
```

A bare number still means a row number, so anything written against the flat
list keeps working.

`update` is a patch: the fields it carries are the fields that change, and the
rest of the row is left as it was. Sending a whole row still works. Setting a
label to `""` does not leave a blank row — it renames the row to its host, its
filename or its first word, the way a browser names a bookmark it was given
none, and leaves the target alone. An edit that would change nothing answers
`unknown` rather than `ok`, because nothing was written.

A row that is not currently visible is not addressable. Folding a folder or
filtering the list takes its contents out of the rows the panel will act on, and
the panel acts on the list it draws — one list, so a row number means the same
thing to a script as it does to the keyboard. Open the folder or clear the
filter first and the id resolves again. `dump` is the exception: it always
answers the whole tree, view or no view.

`dump` answers the file's own shape — `{ "version": 2, "items": [...] }` with
the whole tree in it, nesting included — so it can be written straight back out.

`pin` without a `pinned` field flips whatever the row is now; with one it sets
it outright, so a script does not have to read the state before writing it.
`fold` opens or closes a folder. Folding is a view and is never written to the
file, because a folder that closed itself would be a surprise on the next
launch.

A practical one, if you want entries that follow your day:

```sh
# a scratch entry for a throwaway command
omarchy-shell shell call omarchy-bookmarks-bar add \
  '{"type":"cmd","label":"Today","target":"date +%A"}'

# run whatever is on row 2 without opening the panel
omarchy-shell shell call omarchy-bookmarks-bar launch '{"index":2}'
```

The replies are worth branching on: `"ok"` landed, `"invalid"` the payload was
refused, `"unknown"` the row is not there, `"boundary"` the move had nowhere to
go — the last row in its folder, or a row that is already at the top level.
That distinction is real rather than decorative — a blank `remove` argument is
refused instead of quietly taking row 0, and a `update` whose payload is
incomplete is refused instead of reporting a save that never happened.

To rebind it, edit the marked block in `~/.config/hypr/bindings.lua` and run
`hyprctl reload`. `SUPER + B` is the default because it is free on a stock
Omarchy install — change it freely.

## Keys

The panel is built for the keyboard, so nothing needs the mouse:

| key | action |
|-----|--------|
| `j` / `Down` | next row |
| `k` / `Up` | previous row |
| `Return` / `Space` | open a folder, launch a bookmark, nothing on a section |
| `a` | add a bookmark, folder or section |
| `Tab` | edit the selected row |
| `Shift`+`Tab` | remove the selected row |
| `x` | remove the selected row |
| `J` / `K` | move the selected row up / down among its siblings |
| `l` / `Right` | put the selected row inside the folder above it |
| `h` / `Left` | take the selected row out one level |
| `/` | search, putting the cursor in the filter box |
| `Menu` / `F10` | open the right-click menu for the selected row |
| `Escape` | close the menu, else clear the search, else close the panel |

`j`/`k` and `J`/`K` stop at the ends of whatever folder the row is in, so a row
cannot be walked out of its folder by holding the key down. `l` and `h` need a
folder: `l` does nothing on the first row of a folder, and `h` does nothing on a
row at the top level.

While the filter box has the cursor, `j` and `k` are letters and go into the
box, not up and down the list; `Return` still launches the highlighted bookmark
and `Escape` clears the box.

The same letters work in the add/edit form: `j`/`k` and `h`/`l` pick the type
and the kind, and `Return` saves while `Escape` cancels.

`test/smoke.sh` checks this table against the panel, so a key documented here
that no longer works fails the test rather than surprising a user.

## How it is put together

| file | role |
|------|------|
| `manifest.json` | plugin id, entry point, the contract the shell reads |
| `src/Sidebar.qml` | the panel, the list, persistence, and the IPC handler |
| `src/components/BookmarkItem.qml` | one row: indentation, glyph, label, pin mark, right-click |
| `src/components/RowMenu.qml` | the right-click menu, in its own window at the pointer |
| `src/components/AddBookmarkModal.qml` | the add/edit form and keyboard handling |
| `src/components/SettingsModal.qml` | the export/import sheet |
| `src/BookmarkModel.js` | the tree: parse, normalise, migrate, project to rows, indent/outdent, pin, insert after a row, and the argv for each type |

`BookmarkModel.js` is deliberately free of QML so it can be tested on its own:

```sh
node test/bookmark-model.test.js     # the data layer
./test/smoke.sh                      # QML, rendering, injection, lint, manifest
```

`smoke.sh` runs everything under `QT_QPA_PLATFORM=offscreen`, so it never
draws on the running session. That is not just politeness: a bare `quickshell`
instance does not inherit the hosted plugin's theme, so an on-screen test run
paints the wrong colours and looks like a broken panel when it is only a test
artefact. What it can cover is parsing, the data pipeline under hostile input,
row and form instantiation, and the icon lookup; the panel window itself needs
a real Wayland display, so that part is exercised by running the plugin.

Design notes worth knowing before you change things:

- **Launching.** `url` goes to `omarchy-launch-webapp`, `app` to `gtk-launch`
  for a desktop id or `uwsm-app --` for a bare command, and `cmd` to `bash -c`.
  Everything is passed as an argv array, never through a shell string, so a
  target containing spaces or quotes is handled correctly. The one place a
  shell script is unavoidable — resolving a desktop id to an icon file — takes
  the id as a positional parameter, because interpolating it into the script
  text would let a name like `x$(rm -rf ~)` run.
- **Writes.** The file is written to a temporary file and renamed into place,
  so an interrupted save cannot leave a truncated list behind.
- **One projection, one set of row numbers.** The list is drawn from
  `Model.flatten(state, options)`, and every edit, move and delete is addressed
  by row *in that same projection* with the same options. That is what keeps a
  filtered or folded list from acting on the wrong row: there is no second
  index to fall out of step with the first.
- **Nothing that loses data is silent.** Changing a folder's kind while it holds
  things is refused rather than saved, an import that cannot be read leaves the
  list alone, and the first write of a v2 file leaves the v1 original at
  `bookmarks.json.bak`.
- **The plugin id.** `omarchy-bookmarks-bar` is fine even though it starts with
  `omarchy-`; the reserved namespace is `omarchy.`, with a dot.

## If something breaks

**[DEBUGGING.md](DEBUGGING.md)** maps each symptom to the file and the function
that causes it, lists the command that checks each kind of thing, and records
the mistakes this project has already made — so a second one is recognisable
rather than new.

Two things are worth knowing before you file anything: the panel is themed by
the Omarchy shell and does not look right outside it, and QML has no hot
reload, so an edit needs `omarchy restart shell` before you can see it.

## Requirements

Omarchy 4.x with Quickshell (`omarchy-shell`). Developed against Omarchy 4.0.4
and Quickshell 0.3.1.
