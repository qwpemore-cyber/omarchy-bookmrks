# If something breaks

A map from what you see to the code that causes it. Every entry names one
file and one thing to look at, so a bug report can start from a line number
instead of from a guess.

## Read this first

Two things are true about this project and they explain most surprises:

- **The panel is themed by the shell, not by itself.** `Style` and `Color`
  come from `/usr/share/omarchy/shell/Commons` and resolve against
  `~/.config/omarchy/theme/`. A bare `quickshell` run outside the Omarchy shell
  therefore paints the wrong colours or a white panel. That is a test
  artefact, not a bug — check the panel inside Omarchy before believing it.
- **QML does not hot reload.** Any edit to a `.qml` file needs
  `omarchy restart shell`. Without it you are looking at the old file and will
  "fix" something that was already fixed.

## Symptoms

| What you see | Look at | Why |
|---|---|---|
| Panel does not appear at all | `manifest.json` → `singletons` | The file name must match the singleton id, or nothing loads |
| Panel appears white or unthemed | nothing — it is not the plugin | See "Read this first"; run it through the shell |
| Old code still running after an edit | nothing — it is not the plugin | `omarchy restart shell`; QML has no hot reload |
| Errors in the log after a change | `src/Sidebar.qml` | The panel root: data path, model, key handling, launch |
| A row renders wrong, indented wrongly, or shows the wrong icon | `src/components/BookmarkItem.qml` | One row's layout: indent, chevron, kind glyph, pin mark |
| Add or edit form misbehaves | `src/components/AddBookmarkModal.qml` | Field validation, the kind and type cycles, focus |
| A row will not indent or outdent | `src/BookmarkModel.js` → `canIndent`, `indent`, `outdent` | The rules about which row can move where |
| A nested row is edited or deleted and the wrong one changes | `src/Sidebar.qml` → `viewOptions` | Every mutation is addressed by row in the current projection |
| Settings sheet looks wrong | `src/components/SettingsModal.qml` | Its own layout; the data path is handed to it by the panel |
| An entry will not save, or saves wrong | `src/BookmarkModel.js` → `normalizeNode` | Every field is checked here, once |
| An old `version: 1` file looks wrong or empty | `src/BookmarkModel.js` → `itemsOf`, `fromObject` | The v1 shape is read here, and rewritten as v2 on the next save |
| A URL, app or command launches the wrong thing | `src/BookmarkModel.js` → `argvFor` | The exact argv per type; the only place it is built. A folder and a section have none |
| An icon never appears | `src/Sidebar.qml` → `refreshIcons`, `pumpIconQueue` | The desktop lookup runs here, one at a time through a single Process |
| `SUPER + B` does nothing | `install.sh` and `~/.config/hypr/bindings.lua` | The binding block is written by the installer, not by the panel |
| Data is not being saved | `src/Sidebar.qml` → `dataPath` | One expression; the settings sheet is told this value |
| A quoted or `$`-containing target misbehaves | `src/BookmarkModel.js` → `argvFor`; `src/Sidebar.qml` → `pumpIconQueue` | The one is an argv array, the other passes the desktop id as a positional parameter; neither concatenates |
| an export produced an empty or missing file | `Sidebar.qml` → `exportTo` | `setText` right after setting `path`; the write is async and has to be waited on with `onFileChanged` |
| importing wiped the list | `Sidebar.qml` → `mergeImported` | a file that failed the `looksLikeOurFile()` check was read as zero bookmarks, then replaced |
| a filter or a folded folder edited the wrong row | `Sidebar.qml` → `viewOptions` | an action addressed the view row without the same options the list was drawn with |
| the desktop is unusable while the panel is open | `Sidebar.qml` | `WlrLayershell.keyboardFocus`: `keyboardFocus: opened && !root.overlayOpen` |

## Where each kind of check lives

| Question | Run |
|---|---|
| Is the data logic still correct? | `node test/bookmark-model.test.js` |
| Does it parse, instantiate, and lay out? | `./test/smoke.sh` — offscreen, draws nothing on your session |
| Would Omarchy accept the plugin? | `omarchy plugin validate .` |
| Is the installed copy current? | `./install.sh` — re-syncs, or hard re-syncs and verifies |
| What did the panel say at runtime? | `strings /run/user/1000/quickshell/by-id/*/log.qslog \| grep -i bookmark` |

`./test/smoke.sh` is grouped under bold headings. The heading a failure appears
under names the area, and the failure text names the file where the check found
it, so a red line points at both the problem and the place to fix it.

## The rules that keep being relearned

Each of these was a real bug here, and each has a check that now fails if it
comes back:

- **Never build a command line by concatenation.** Use positional parameters
  (`"$1"`, never `eval`), and an argv array where there is one. See
  `argvFor` and the icon lookup in `Sidebar.qml`.
- **One authority per value.** The data path, the key map, and the type list
  each exist in exactly one place; a second copy is a second answer.
- **A sheet over the list owns the surface.** Anything that acts on the list
  checks `overlayOpen` first, or it acts on rows nobody can see.
- **A card is clamped to its parent.** `Math.min(...)` against `parent.width`,
  never a literal width.
- **Wrapped text sets `lineHeight`.** The default comes from font metrics and
  let two lines land on top of each other.
- **A flag is not a rendering.** `opened: false` proves nothing; only
  `visible` hides anything. Every sheet gates its own visibility, and
  `test/smoke.sh` counts the Text items that would actually be drawn, because
  the property was correctly false while the pixels were still on screen.
- **Text is measured, not eyeballed.** `test/smoke.sh` walks the rendered
  geometry and fails on overflow, clipping, or a binding that resolved to
  nothing.
- **A documented verb is a verb that exists.** The README is compared against
  the source, in both directions.
- **A filter changes the view, never the data.** Hiding rows renumbers the ones
  that are left, so the panel resolves a row once, through `viewOptions()`, and
  hands the *same* options to every model call. There is no second index to
  fall out of step with the list that is on screen. See `Model.flatten` and
  `Model.nodeAtRow`.
- **A row is addressed by its id, not its number.** Row numbers depend on which
  folders are open and what is in the filter box, neither of which a script can
  see — so every verb takes an id as well, and a bare number still means a row
  number.
- **A node that cannot be run is refused, not approximated.** `argvFor` returns
  nothing for a folder and for a section, so there is no code path where one of
  them reaches a shell.
- **Nothing that loses data is silent.** A folder that still holds things
  refuses to become a bookmark; a section carries no `pinned` key at all,
  because a field in a hand-edited file that does nothing is worse than no
  field; and the first v2 write leaves the v1 original at `bookmarks.json.bak`.
- **A save is asynchronous.** `FileView.setText()` returns before the bytes
  land, so anything that reads a file straight after writing it sees a file
  that exists and is empty. Wait on `onFileChanged`, which is what the panel's
  own data file does.
- **A property handed to another object is declared.** A `QString` assigned
  `undefined` is a warning in the shell's log and nothing at all to
  `qmllint`; `test/smoke.sh` checks the panel's handover both ways.
- **An unreadable file is not an empty one.** Import refuses anything that is
  not this plugin's format, and "nothing picked" (`null`) is a different answer
  from "a file with no bookmarks" (`[]`), because only one of those followed by
  a replace loses work.
