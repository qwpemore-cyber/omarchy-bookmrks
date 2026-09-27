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
| A row renders wrong, or the wrong icon | `src/components/BookmarkItem.qml` | One row's layout and its type glyph |
| Add or edit form misbehaves | `src/components/AddBookmarkModal.qml` | Field validation, the type cycle, focus |
| Settings sheet looks wrong | `src/components/SettingsModal.qml` | Its own layout; the data path is handed to it by the panel |
| An entry will not save, or saves wrong | `src/BookmarkModel.js` → `normalize`, `validate` | Every field is checked here, once |
| A URL, app or command launches the wrong thing | `src/BookmarkModel.js` → `launchArgv` | The exact argv per type; the only place it is built |
| An icon never appears | `src/BookmarkModel.js` → `iconFor` | Desktop lookup, then the per-type glyph |
| `SUPER + B` does nothing | `install.sh` and `~/.config/hypr/bindings.lua` | The binding block is written by the installer, not by the panel |
| Data is not being saved | `src/Sidebar.qml` → `dataPath` | One expression; the settings sheet is told this value |
| A quoted or `$`-containing target misbehaves | `src/BookmarkModel.js` → `launchArgv`, `iconFor` | Both build command lines; neither may concatenate |

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
  (`"$1"`, never `eval`). See `iconFor`.
- **One authority per value.** The data path, the key map, and the type list
  each exist in exactly one place; a second copy is a second answer.
- **A sheet over the list owns the surface.** Anything that acts on the list
  checks `overlayOpen` first, or it acts on rows nobody can see.
- **A card is clamped to its parent.** `Math.min(...)` against `parent.width`,
  never a literal width.
- **Wrapped text sets `lineHeight`.** The default comes from font metrics and
  let two lines land on top of each other.
- **Text is measured, not eyeballed.** `test/smoke.sh` walks the rendered
  geometry and fails on overflow, clipping, or a binding that resolved to
  nothing.
- **A documented verb is a verb that exists.** The README is compared against
  the source, in both directions.
