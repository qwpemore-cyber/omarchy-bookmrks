# Bookmarks Bar for Omarchy

A keyboard-driven sidebar for Omarchy that keeps the things you open all day —
links, apps, and commands — one `SUPER + B` away.

![type: module](https://img.shields.io/badge/type-QML%20%2B%20Quickshell-blue)

## What it does

- A panel on the **left edge** that slides in and out.
- Four kinds of entry, all handled the same way once saved:
  | type | what it is | example target |
  |------|------------|----------------|
  | `url` | a web address | `https://github.com` |
  | `app` | a desktop entry | `org.gnome.Nautilus` |
  | `cmd` | any command | `omarchy-capture-screenshot` |
  | `file` | a file or folder | `~/notes.md`, `/etc/hosts` |
- Add, edit, reorder, and delete entries from the sidebar.
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

Press `a`, pick a type, fill in **Label** (what the list shows) and **Target**
(what actually runs), then `Return`:

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

In the form, `j`/`k` and `h`/`l` pick the type, `Return` saves and `Escape`
cancels, so the whole thing works without touching the pointer. **Icon** is
optional: leave it empty and the panel uses a themed desktop icon when there is
one, otherwise a glyph for the type.

`cmd` is the only type that goes through a shell, which is the point of it. A
`url` or `app` target is passed as an argument and can never become a command
line, so a target containing spaces or quotes still does what it says.

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
  "version": 1,
  "bookmarks": [
    { "id": "b1", "type": "url", "label": "GitHub", "target": "https://github.com", "icon": "" },
    { "id": "b2", "type": "app", "label": "Files", "target": "org.gnome.Nautilus", "icon": "org.gnome.Nautilus" },
    { "id": "b3", "type": "cmd", "label": "Screenshot", "target": "omarchy-capture-screenshot", "icon": "" }
  ]
}
```

Unknown fields are ignored, missing fields are filled in, and a malformed
entry is skipped rather than taking the whole list down.

## Command from elsewhere

The panel answers three IPC calls, so you can drive it from Hyprland, a key
binding, or a script:

```sh
omarchy-shell shell toggle omarchy-bookmarks-bar
omarchy-shell shell summon omarchy-bookmarks-bar   # open only
omarchy-shell shell hide omarchy-bookmarks-bar     # close only
```

`call` reaches the panel's root item, one argument, so it takes a method and a
JSON payload. All four verbs answer `"ok"`, `"invalid"` or `"unknown"`, so a
script can tell the difference between a rejected payload and a row that is not
there:

```sh
omarchy-shell shell call omarchy-bookmarks-bar ping ''
omarchy-shell shell call omarchy-bookmarks-bar dump ''

# add a bookmark
omarchy-shell shell call omarchy-bookmarks-bar add \
  '{"type":"url","label":"GitHub","target":"https://github.com"}'

# edit row 0 — "index" is stripped before the entry is validated
omarchy-shell shell call omarchy-bookmarks-bar update \
  '{"index":0,"type":"url","label":"GitHub (work)","target":"https://github.com"}'

# remove row 0
omarchy-shell shell call omarchy-bookmarks-bar remove 0
```

`remove` takes a row number, not JSON, and a blank or non-numeric argument is
refused rather than read as row 0.

A practical one, if you want entries that follow your day:

```sh
# a scratch entry for a throwaway command
omarchy-shell shell call omarchy-bookmarks-bar add \
  '{"type":"cmd","label":"Today","target":"date +%A"}'

# run whatever is on row 2 without opening the panel
omarchy-shell shell call omarchy-bookmarks-bar launch '{"index":2}'
```

The replies are worth branching on: `"ok"` landed, `"invalid"` the payload was
refused, `"unknown"` the row is not there. That distinction is real rather than
decorative — a blank `remove` argument is refused instead of quietly taking row
0, and a `update` whose payload is incomplete is refused instead of reporting a
save that never happened.

To rebind it, edit the marked block in `~/.config/hypr/bindings.lua` and run
`hyprctl reload`. `SUPER + B` is the default because it is free on a stock
Omarchy install — change it freely.

## Keys

The panel is built for the keyboard, so nothing needs the mouse:

| key | action |
|-----|--------|
| `j` / `Down` | next bookmark |
| `k` / `Up` | previous bookmark |
| `Return` / `Space` | launch the selected bookmark |
| `a` | add a bookmark |
| `Tab` | edit the selected bookmark |
| `Shift`+`Tab` | remove the selected bookmark |
| `x` | remove the selected bookmark |
| `J` / `K` | move the selected bookmark up / down |
| `Escape` | close the panel |

The same letters work in the add/edit form: `j`/`k` and `h`/`l` pick the type,
and `Return` saves while `Escape` cancels. `h` and `l` do nothing in the list
itself — a vertical list has nothing for them to move.

`test/smoke.sh` checks this table against the panel, so a key documented here
that no longer works fails the test rather than surprising a user.

## How it is put together

| file | role |
|------|------|
| `manifest.json` | plugin id, entry point, the contract the shell reads |
| `src/Sidebar.qml` | the panel, the list, persistence, and the IPC handler |
| `src/BookmarkItem.qml` | one row: icon, label, and its edit/remove buttons |
| `src/AddBookmarkModal.qml` | the add/edit form and keyboard handling |
| `src/BookmarkModel.js` | pure data logic: parse, normalise, add, update, remove, move, and the argv for each type |

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
