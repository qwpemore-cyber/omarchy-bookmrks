# Bookmarks Bar for Omarchy

A keyboard-driven sidebar for Omarchy that keeps the things you open all day —
links, apps, and commands — one `SUPER + B` away.

![type: module](https://img.shields.io/badge/type-QML%20%2B%20Quickshell-blue)

## What it does

- A panel on the **left edge** that slides in and out.
- Three kinds of entry, all handled the same way once saved:
  | type | what it is | example target |
  |------|------------|----------------|
  | `url` | a web address | `https://github.com` |
  | `app` | a desktop entry | `org.gnome.Nautilus` |
  | `cmd` | any command | `omarchy-capture-screenshot` |
- Add, edit, reorder, and delete entries from the sidebar.
- Icons resolved from your installed `.desktop` files, falling back to a glyph
  per type.
- Follows your theme and font size, and respects reduced motion.

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
omarchy-shell shell call omarchy-bookmarks-bar open
omarchy-shell shell call omarchy-bookmarks-bar close
```

To rebind it, edit the marked block in `~/.config/hypr/bindings.lua` and run
`hyprctl reload`. `SUPER + B` is the default because it is free on a stock
Omarchy install — change it freely.

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
node test/bookmark-model.test.js
```

Design notes worth knowing before you change things:

- **Launching.** `url` goes to `omarchy-launch-webapp`, `app` to `omarchy-launch`
  (or `gtk-launch` for a desktop id), and `cmd` to `bash -c`. Everything is
  passed as an argv array, never through a shell string, so a target
  containing spaces or quotes is handled correctly.
- **Writes.** The file is written to a temporary file and renamed into place,
  so an interrupted save cannot leave a truncated list behind.
- **The plugin id.** `omarchy-bookmarks-bar` is fine even though it starts with
  `omarchy-`; the reserved namespace is `omarchy.`, with a dot.

## Requirements

Omarchy 4.x with Quickshell (`omarchy-shell`). Developed against Omarchy 4.0.4
and Quickshell 0.3.1.
