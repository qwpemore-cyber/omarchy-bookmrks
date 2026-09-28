// The panel root, and the first file to open when something looks wrong.
//
// Owns: the data path, the list model, launching, the key map, the two sheets,
// and the verbs the host calls. It is the only file that knows where
// ~/.config/omarchy/bookmarks.json is — the settings sheet is told, it does
// not look.
//
// DEBUGGING.md has a symptom table. The short version: a row that renders
// wrong is BookmarkItem.qml, a form that misbehaves is AddBookmarkModal.qml,
// a save that is wrong is BookmarkModel.js, and a keystroke that does the
// wrong thing is here.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "BookmarkModel.js" as Model
import "components" as Components

// Bookmarks Bar — a left-edge launcher panel for the Omarchy shell.
//
// The shell hosts this as a `panel` plugin and drives it through the three
// entry-point hooks below (open / close / opened). The manifest sets
// keepLoaded, so the window, the list, and the cursor position all survive
// between summons.
//
// Launching is argv-based for url and app targets on purpose: those values
// are typed by a person or arrive over IPC, and Util.execArgv hands them to a
// login shell as positional parameters without re-tokenising, so a target can
// never turn into a command line. Only `cmd` bookmarks go through `bash -c`,
// which is the entire point of that type.
Item {
  id: root

  // ---- host contract -------------------------------------------------------

  // Set while the shell is hiding us, so the two close paths stay
  // distinguishable and the shell's openPanelIds never drifts out of sync.
  property bool closingFromHost: false
  property bool hidePending: false
  readonly property bool opened: window.opened

  // True while either sheet is on top. Everything that acts on the list — the
  // highlight, launching, deleting — has to check this, because a sheet draws
  // a scrim over the list without removing it. Enter with the settings sheet
  // open would otherwise launch a bookmark the user cannot see.
  readonly property bool overlayOpen: modal.opened || settings.opened
  // The row menu gets its own flag and is deliberately not part of overlayOpen.
  // overlayOpen hides the list and takes Exclusive keyboard focus, both of which
  // are right for a form drawn *over* the panel and exactly wrong for a context
  // menu: a menu floating over a blank panel, with the keys held by a form that
  // is not there. The list stays visible under the menu, as it does in Firefox.
  readonly property bool menuOpen: menu.opened

  // The shell injects its facade here; the fallback keeps the panel usable
  // if it is ever loaded outside the host.
  property var shell: null

  function open(payloadJson) {
    closingFromHost = false
    window.opened = true
  }

  function close() {
    // A panel the user dismissed has to tell the shell, or its openPanelIds
    // still claims to be open and the next toggle hides a panel that is not
    // showing.
    if (!closingFromHost && shell && typeof shell.hide === "function") {
      if (pluginId === "") {
        // The manifest has not been read yet, so there is no id to hide. The
        // dismissal is remembered and replayed below, once there is one.
        hidePending = true
      } else {
        closingFromHost = true
        shell.hide(pluginId)
      }
    }
    window.opened = false
    closingFromHost = false
  }

  // ---- identity ------------------------------------------------------------

  // Read from our own manifest rather than hardcoded, so the id the shell
  // knows us by and the id IPC callers pass can never drift apart.
  property string pluginId: ""
  readonly property string manifestPath: String(Qt.resolvedUrl("../manifest.json")).replace("file://", "")

  // ---- data ----------------------------------------------------------------

  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string dataPath: homeDir + "/.config/omarchy/bookmarks.json"
  readonly property string dataDir: homeDir + "/.config/omarchy"

  // Desktop id -> file:// URL. An empty string is a real answer ("looked,
  // this system has no such icon"), which is why it is cached too: without
  // it every rebuild would re-run a lookup that cannot succeed.
  property var iconCache: ({})

  ListModel { id: listModel }

  // The saved tree and the displayed list are two different things, and keeping
  // them in one ListModel is what makes a search box wrong: a filter that hides
  // rows would renumber the ones that are left, so "edit this" and "delete this"
  // would act on the wrong bookmark the moment anything was filtered out. So
  // allEntries is the truth the file is written from, and listModel is only what
  // the view is currently showing.
  //
  // allEntries is the top level of the tree, not a flat list. A row the view
  // shows is not a position in it — it is a position in a projection, which is
  // why every mutation below hands the model the row *and* the view's own
  // options, and the model does the translation.
  property var allEntries: []
  property string filterQuery: ""
  // Which folders are closed. This is panel state and is never written to the
  // file: opening a folder must not edit the user's bookmarks, and a saved
  // "collapsed" flag would make the file change every time it was merely looked
  // at. A map of id -> true rather than a list, so collapsing a folder that a
  // filter has hidden does not shift anything else's index.
  property var collapsedIds: ({})
  // Firefox's Toolbar against its Menu: a view over the same list, not a sort.
  // Nothing is reordered by pinning, so a pinned row keeps the position it was
  // given and this only decides what is drawn.
  property bool pinnedOnly: false
  // How many rows the whole tree holds, with no filter and nothing collapsed.
  // The header's "n of m" divides by this, and it must not move when a folder
  // is opened, or the count would claim rows appeared.
  readonly property int totalCount: Model.flatten(Model.stateOf(allEntries)).length
  // Today, as a date the export filename can use. It lives here because the
  // panel is the one place that knows what time it is, and a sheet handed
  // "undefined" for its date would name every export the same thing.
  readonly property string today: {
    var d = new Date()
    var m = d.getMonth() + 1
    var day = d.getDate()
    return d.getFullYear() + "-" + (m < 10 ? "0" + m : m) + "-" + (day < 10 ? "0" + day : day)
  }

  function entryAt(row) {
    if (row < 0 || row >= listModel.count) return null
    var r = listModel.get(row)
    return {
      id: r.entryId,
      kind: r.kind,
      type: r.type,
      label: r.label,
      target: r.target,
      icon: r.icon,
      pinned: r.pinned,
      // The form refuses to turn a folder that has things in it into a
      // bookmark, and it can only say so if it is told how many.
      childCount: r.childCount
    }
  }

  // The full tree, not what is on screen: everything that is written to disk or
  // handed to the model starts from this, so a search can never quietly become a
  // deletion.
  function bookmarkState() { return Model.stateOf(allEntries) }
  function bookmarkList() { return allEntries }

  // What the view is currently showing, handed to every model call that takes a
  // row. This is the whole of the row-addressing contract: the same three
  // things decide which row number 2 is, for the list that is on screen and for
  // the mutation that is about to act on it, so the two cannot disagree.
  function viewOptions() {
    return { query: filterQuery, pinnedOnly: pinnedOnly, collapsed: collapsedIds }
  }

  function setFilter(query) {
    var next = String(query === undefined || query === null ? "" : query)
    if (next === filterQuery) return
    filterQuery = next
    rebuildView()
    // A search that hides the selected row would otherwise leave the cursor
    // pointing at whatever slid into that place, so it starts at the top.
    selectedIndex = listModel.count === 0 ? -1 : 0
  }

  function clearFilter() {
    if (filterQuery === "") return
    filterQuery = ""
    rebuildView()
    selectedIndex = listModel.count === 0 ? -1 : 0
  }

  // The one place a v1 file is upgraded, and the one place the copy is taken.
  // The upgrade is one-way: an older build cannot read a v2 file, so the text
  // as it was is written next to it before anything overwrites it. Writing it
  // here rather than on the first save means the backup cannot lose a race with
  // the save that destroys the original.
  property bool backupWritten: false

  function loadBookmarks(rawText) {
    // A missing or unreadable file parses to an empty list, and the panel
    // shows its "no bookmarks yet" state. install.sh seeds the file on first
    // run; a user who deletes it just starts over.
    var text = String(rawText === undefined || rawText === null ? "" : rawText)
    if (text.trim() !== "" && !Model.looksLikeV2(text) && !backupWritten) {
      backupWritten = true
      backupFile.setText(text)
    }
    rebuild(Model.parse(text).items)
  }

  // Every load and every mutation ends here. The list arriving is always the
  // whole saved tree; what the view shows is decided afterwards.
  function rebuild(list) {
    allEntries = list
    rebuildView()
  }

  // The list is built from one projection, and the rows it appends carry
  // everything the model needs to find them again: a row number means nothing
  // without the filter and the collapsed set that produced it.
  function rebuildView() {
    var visible = Model.flatten(bookmarkState(), viewOptions())
    listModel.clear()
    for (var i = 0; i < visible.length; i++) {
      var r = visible[i]
      listModel.append({
        entryId: r.id,
        kind: r.kind,
        type: r.type,
        label: r.label,
        target: r.target,
        icon: r.icon,
        pinned: r.pinned,
        depth: r.depth,
        hasChildren: r.hasChildren,
        collapsed: r.collapsed,
        childCount: r.childCount,
        iconSource: iconCache[r.icon] !== undefined ? iconCache[r.icon] : ""
      })
    }
    selectedIndex = listModel.count === 0 ? -1 : Util.clamp(selectedIndex < 0 ? 0 : selectedIndex, 0, listModel.count - 1)
    refreshIcons()
  }

  function persist(list) {
    bookmarkFile.setText(Model.serialize(Model.stateOf(list)))
  }

  // ---- import and export ---------------------------------------------------

  // Export writes exactly what the file holds, so what leaves the machine and
  // what stays on it cannot differ, including the order and the nesting.
  function exportTo(path) {
    if (!path) return false
    exportFile.path = path
    exportFile.setText(Model.serialize(bookmarkState()))
    return true
  }

  // Both of these are handed a parsed file, not a list, because a list of the
  // top level is all a v1 file has and a v2 file's top level can contain folders
  // with children. Taking the state means neither shape has to be flattened
  // into something it is not.
  function replaceAll(state) {
    // A null here is the import refusing a file, not an empty file, and they
    // must not look the same: "replace with nothing" is the one outcome that
    // loses work.
    if (!state || typeof state !== "object") return false
    var next = Model.fromObject(state).items
    persist(next)
    rebuild(next)
    return true
  }

  function mergeImported(state) {
    if (!state || typeof state !== "object") return false
    var merged = Model.mergeEntries(bookmarkState(), Model.fromObject(state).items)
    if (merged.length === allEntries.length) return false
    persist(merged)
    rebuild(merged)
    return true
  }

  // The rows a delete takes with it, counted before it happens. A folder row
  // that silently swallowed four bookmarks would read as "one item deleted",
  // which is the one case where a count is not a nicety.
  property int lastRemovedCount: 0

  function addEntry(payload) {
    var before = bookmarkList()
    // Adding while a folder is selected puts the new row inside it, the way
    // every other tree puts a new child under the thing that is selected. It
    // is not a guess that has to be right: `l` and `h` move the row again, and
    // the cursor follows it either way, so nothing is lost by being wrong.
    // A section and a bookmark are not containers, so they get it at the top.
    var here = entryAt(selectedIndex)
    var parentRow = here && here.kind === "folder" ? selectedIndex : -1
    var next = Model.insertInto(bookmarkState(), parentRow, payload, viewOptions())
    // The top level does not grow when the row went inside a folder, so the
    // length cannot be what says whether anything happened.
    if (JSON.stringify(next) === JSON.stringify(before)) return false
    persist(next)
    rebuild(next)
    // The cursor follows the row that was just made, by its id. Counting rows
    // and taking the last one only works for an append at the top, and would
    // leave the cursor on the wrong row for every other case.
    var made = Model.indexForId(Model.stateOf(next), payload.id, viewOptions())
    selectedIndex = made >= 0 ? made
      : (listModel.count === 0 ? -1 : Util.clamp(selectedIndex, 0, listModel.count - 1))
    return true
  }

  // The menu's "New Bookmark…" and "New Folder…": the new row goes *after* the one
  // that was right-clicked, which is the placement Firefox makes and the one the
  // name says. It is a separate function from addEntry rather than a flag on it,
  // because the two place a row in different places in the tree and the panel
  // should have to say which it meant.
  function addEntryAfter(row, payload) {
    var before = bookmarkList()
    var next = Model.insertAfterRow(bookmarkState(), row, payload, viewOptions())
    if (JSON.stringify(next) === JSON.stringify(before)) return false
    persist(next)
    rebuild(next)
    var made = Model.indexForId(Model.stateOf(next), payload.id, viewOptions())
    selectedIndex = made >= 0 ? made
      : (listModel.count === 0 ? -1 : Util.clamp(row, 0, listModel.count - 1))
    return true
  }

  // The sheet owns the surface, exactly as openModal says: the settings sheet is
  // closed first, or the form would open on top of another sheet and there would
  // be two scrims.
  function openAfterRow(row, kind) {
    if (row < 0 || row >= listModel.count) return
    settings.close()
    modal.openAfter(row, entryAt(row), kind)
  }

  function updateEntry(row, payload) {
    if (row < 0 || row >= listModel.count) return false
    // There is no pre-flight validity check here on purpose. There used to be
    // one, and it normalised the payload on its own — which a partial payload
    // cannot survive, so a script that sent just a new name was refused and the
    // panel answered "unknown" for an edit it could have made. updateAt merges
    // the payload over the row now, and returns the tree untouched if the
    // result is not a valid row, so the comparison below is the real check: if
    // the list comes back the way it went in, nothing was saved and saying "ok"
    // to it would be a lie. That covers the refused edits and the pointless ones
    // — sending a bookmark the label it already has — in one place.
    var before = bookmarkList()
    var next = Model.updateAt(bookmarkState(), row, payload, viewOptions())
    if (JSON.stringify(next) === JSON.stringify(before)) return false
    persist(next)
    rebuild(next)
    selectedIndex = Util.clamp(row, 0, listModel.count - 1)
    return true
  }

  function removeEntry(row) {
    if (row < 0 || row >= listModel.count) return false
    var state = bookmarkState()
    var opts = viewOptions()
    var doomed = Model.nodeAtRow(state, row, opts)
    lastRemovedCount = Model.countSubtree(doomed)
    var list = Model.removeAt(state, row, opts)
    if (lastRemovedCount === 0) return false
    persist(list)
    rebuild(list)
    selectedIndex = listModel.count === 0 ? -1 : Util.clamp(row, 0, listModel.count - 1)
    return true
  }

  // Reordering moves a row among its siblings and stops at the ends of whatever
  // folder it is in. The flat list this replaced moved by position in the whole
  // list, which under a tree would step a bookmark out of its folder and into
  // the next one whenever it reached the end.
  function moveEntry(row, delta) {
    if (row < 0 || row >= listModel.count) return false
    var before = bookmarkList()
    var list = Model.moveBy(bookmarkState(), row, delta, viewOptions())
    if (JSON.stringify(list) === JSON.stringify(before)) return false
    persist(list)
    rebuild(list)
    // The moved row keeps its place among its siblings, so the cursor follows
    // it by the same delta rather than staying on whatever slid into the slot.
    selectedIndex = Util.clamp(row + delta, 0, listModel.count - 1)
    return true
  }

  // `l` and `h`: into the folder above, and back out to sit after the folder it
  // came from. Both refuse at the ends rather than moving a row somewhere the
  // key was not asking for, and both are the same shape as moveEntry so the
  // file is written by the same path.
  function indentEntry(row) {
    if (row < 0 || row >= listModel.count) return false
    if (!Model.canIndent(bookmarkState(), row, viewOptions())) return false
    var before = bookmarkList()
    var list = Model.indent(bookmarkState(), row, viewOptions())
    if (JSON.stringify(list) === JSON.stringify(before)) return false
    persist(list)
    rebuild(list)
    selectedIndex = Util.clamp(row, 0, listModel.count - 1)
    return true
  }

  function outdentEntry(row) {
    if (row < 0 || row >= listModel.count) return false
    if (!Model.canOutdent(bookmarkState(), row, viewOptions())) return false
    var before = bookmarkList()
    var list = Model.outdent(bookmarkState(), row, viewOptions())
    if (JSON.stringify(list) === JSON.stringify(before)) return false
    persist(list)
    rebuild(list)
    selectedIndex = Util.clamp(row, 0, listModel.count - 1)
    return true
  }

  // Collapse is the one thing here that is not saved, so it never calls persist
  // and never touches the file.
  function toggleFolder(row) {
    if (row < 0 || row >= listModel.count) return false
    var r = listModel.get(row)
    if (r.kind !== "folder") return false
    collapsedIds = Model.toggleCollapsed(collapsedIds, r.entryId)
    rebuildView()
    selectedIndex = Util.clamp(row, 0, listModel.count - 1)
    return true
  }

  function togglePin(row) {
    return setPin(row, null)
  }

  // `value` of null means "flip whatever it is now", which is what the panel's
  // own key does; a boolean sets it outright, which is what a script wants,
  // because a script should not have to read the state before it can write it.
  // Either way the answer is whether the file changed, so pinning something
  // already pinned reports "unknown" rather than a false "ok".
  function setPin(row, value) {
    if (row < 0 || row >= listModel.count) return false
    var before = bookmarkList()
    var state = bookmarkState()
    var opts = viewOptions()
    var list = value === null
      ? Model.togglePinned(state, row, opts)
      : Model.setPinned(state, row, value === true, opts)
    if (JSON.stringify(list) === JSON.stringify(before)) return false
    persist(list)
    rebuild(list)
    return true
  }

  function togglePinnedOnly() {
    pinnedOnly = !pinnedOnly
    rebuildView()
    selectedIndex = listModel.count === 0 ? -1 : 0
  }

  // A row is one of three things, and only one of them has a target to run.
  // Firefox's tree does the same: Return on a folder opens it, Return on a
  // section does nothing at all, and neither can reach a shell because the
  // model refuses to build an argv for either.
  function activateRow(row) {
    if (row < 0 || row >= listModel.count) return false
    var r = listModel.get(row)
    if (r.kind === "folder") return toggleFolder(row)
    if (r.kind === "section") return false
    return launchEntry(row)
  }

  function launchEntry(row) {
    // homeDir is passed in so a "~" written in the data file is expanded here,
    // at launch, rather than being flattened to one machine's home directory
    // when the bookmark was saved.
    var argv = Model.argvFor(entryAt(row), root.homeDir)
      if (argv.length === 0) return
      // A cmd bookmark is the user's own command line, so it goes through a
      // shell deliberately. url, app and file targets are data and stay
      // argv-only, so a path containing ";" or "$(...)" is just a path.
      if (argv[0] === "bash") Util.execDetached(argv[2])
      else Util.execArgv(argv)
    }

  // ---- icon lookup ---------------------------------------------------------

  property var iconQueue: []
  property bool iconLookupBusy: false

  function refreshIcons() {
    for (var i = 0; i < listModel.count; i++) queueIconLookup(i)
    pumpIconQueue()
  }

  function queueIconLookup(row) {
    var entry = entryAt(row)
    if (!entry || Model.iconKind(entry) !== "app") return
    if (iconCache[entry.icon] !== undefined) {
      listModel.setProperty(row, "iconSource", iconCache[entry.icon])
      return
    }
    iconQueue.push({ row: row, name: entry.icon })
  }

  // Lookups run one at a time through a single Process, so opening a long
  // list cannot spawn a burst of shells. Stale jobs are dropped in a loop
  // rather than by recursing, because a rebuild can invalidate every queued
  // row at once and the recursion would be as deep as the list.
  function pumpIconQueue() {
    while (!iconLookupBusy && iconQueue.length > 0) {
      var job = iconQueue.shift()

      // The list may have been rebuilt between queueing and running.
      var entry = entryAt(job.row)
      if (!entry || entry.icon !== job.name) continue

      iconLookup.iconName = job.name
      iconLookup.running = true
      return
    }
  }

  function onIconResolved(iconName, url) {
    iconCache[iconName] = url
    for (var i = 0; i < listModel.count; i++) {
      if (listModel.get(i).icon === iconName) listModel.setProperty(i, "iconSource", url)
    }
  }

  // ---- cursor --------------------------------------------------------------

  // One index drives the highlight, so the mouse and the keyboard can never
  // disagree about which row is current.
  property int selectedIndex: -1
  readonly property bool empty: listModel.count === 0

  function moveCursor(delta) {
    if (listModel.count === 0) return
    if (selectedIndex < 0) {
      selectedIndex = delta > 0 ? 0 : listModel.count - 1
      return
    }
    selectedIndex = Util.clamp(selectedIndex + delta, 0, listModel.count - 1)
  }

  function activateCursor() {
    if (modal.opened) { modal.submit(); return }
    // The settings sheet is read-only, so Enter has nothing to submit and must
    // not fall through to the list behind it.
    if (settings.opened) return
    if (selectedIndex < 0) return
    activateRow(selectedIndex)
  }

  // ---- letter keys ---------------------------------------------------------

  // The catcher consumes the arrow keys and j/k/h/l before it gets here, and it
  // forwards the rest one character at a time. Which characters mean what is
  // written down once, in one function, so the handler below and the test that
  // checks the documented map against it cannot drift apart.
  //
  // h and l are absent on purpose: the shell's own key catcher already claims
  // them, together with the left and right arrows, and reports them as a
  // horizontal move. Listing them here as well would document a path they never
  // travel, which is how "h and l do nothing" ended up written in the README
  // in the first place.
  //
  // Uppercase is used for the two that shift an entry: j/k are already taken by
  // moving the cursor, and a capital letter is the same physical key.
  function keyIntent(t) {
    if (t === "a" || t === "A") return "add"
    if (t === "J") return "moveUp"
    if (t === "K") return "moveDown"
    if (t === "/") return "search"
    return ""
  }

  function openModal(row) {
    if (row >= 0 && row >= listModel.count) return
    // The two sheets cannot both own the surface. Whichever is opened closes
    // the other, and the bookmark form is closed rather than left open
    // underneath, because two visible sheets would both be drawing a scrim.
    settings.close()
    modal.openFor(row, row >= 0 ? entryAt(row) : null)
  }

  // Opening the menu from the panel rather than from the row, because the row
  // cannot answer the two questions the menu asks of it: which row number this
  // is under the filter and collapse state the list is showing right now, and how
  // many rows a delete of it would take. Both need the model, and the panel is
  // the only thing holding it.
  // Called with a point for a right press, and without one for the Menu key and
  // F10. Without a point the menu opens on the row itself, which is the only
  // position the keyboard has: there is no pointer to be at the cursor, and
  // opening at 0,0 would put it in the corner of the screen, as far from the row
  // it is about as the panel allows.
  function openRowMenu(row, contentX, contentY) {
    if (row < 0 || row >= listModel.count) return
    var entry = entryAt(row)
    if (!entry || entry.kind === "separator") return
    selectedIndex = row
    var point = { x: contentX, y: contentY }
    if (contentX === undefined || contentX === null) {
      var item = listView.itemAtIndex(row)
      point = item ? item.mapToItem(window.contentItem, 0, item.height)
        : { x: 0, y: 0 }
    }
    menu.openFor(row, entry, point.x, point.y, Model.countSubtree(Model.nodeAtRow(bookmarkState(), row, viewOptions())))
  }

  // The menu's commands, in one place. The menu knows the labels and the order;
  // it does not know what any of them do, because every one of them is a thing
  // the panel can already do by another route, and a second implementation of
  // "delete this row" is a second place for the count and the cursor to go wrong.
  function runMenuAction(name, payload) {
    var row = payload && payload.rowIndex !== undefined ? payload.rowIndex : -1
    if (name === "edit") openModal(row)
    else if (name === "pin") togglePin(row)
    else if (name === "delete") removeEntry(row)
    else if (name === "newBookmark") openAfterRow(row, "bookmark")
    else if (name === "newFolder") openAfterRow(row, "folder")
    else if (name === "newSeparator") insertSeparatorAfter(row)
    // Focus goes back to the panel's own catcher, because the surface that just
    // had the keyboard is a window that is now closed. Without this the list
    // stops answering to the keyboard until something is clicked.
    keys.forceActiveFocus()
  }

  // "Add Separator" is one click in Firefox and opens no form, so it is one call
  // here. It is insertAfterRow rather than insertInto because a separator is not
  // a container: the row it was asked about is where it goes, next to it.
  function insertSeparatorAfter(row) {
    var before = bookmarkList()
    // The id is made here rather than read back out of the result. A separator
    // has no form to normalise and normalise it with, so asking the model where
    // it put the new row would mean asking "which row is new" — and a model that
    // answers that needs a piece of mutable state saying so, which is a worse
    // thing to carry than an id made in one line.
    var id = Model.makeId()
    var next = Model.insertAfterRow(bookmarkState(), row, { id: id, kind: "separator" }, viewOptions())
    if (JSON.stringify(next) === JSON.stringify(before)) return false
    persist(next)
    rebuild(next)
    // The cursor goes on the separator that was just made, not on the row that
    // was right-clicked, for the same reason adding a bookmark moves it: the
    // thing you just did is the thing you are now looking at.
    var made = Model.indexForId(Model.stateOf(next), id, viewOptions())
    selectedIndex = made >= 0 ? made
      : (listModel.count === 0 ? -1 : Util.clamp(row, 0, listModel.count - 1))
    return true
  }

  function openSettings() {
    modal.close()
    settings.open()
  }

  // ---- ipc -----------------------------------------------------------------

  // IPC callers are as likely to be a script as a person, so a malformed
  // payload is a normal return value rather than an exception thrown across
  // the socket.
  function parsePayload(payloadJson) {
    try {
      var parsed = JSON.parse(String(payloadJson || "{}"))
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {}
    } catch (e) {
      return {}
    }
  }

  // A row is named two ways, and this is the one place that decides which. An
  // id is a string of letters; a row number is digits. Anything else — a blank,
  // a word, a negative number past the start — is refused rather than coerced.
  //
  // This replaced an earlier version that accepted only digits, and it was
  // added *alongside* that one rather than in place of it. QML takes the second
  // definition and logs a duplicate-method warning; the panel then answers
  // "unknown" to every verb that resolves a row, which looks exactly like a
  // caller sending the wrong thing. It did, until the ids were actually tried
  // on the running panel — every test here passes, because the model's own
  // tests never load the panel. So the names on the root are checked below.
  function rowFrom(value) {
    if (value === null || value === undefined) return -1

    // A payload rather than a bare argument, for the verbs that take one.
    if (typeof value === "object") {
      if (value.id !== undefined) return rowFrom(value.id)
      if (value.index !== undefined) return rowFrom(value.index)
      return -1
    }

    // Index arguments arrive as strings over IPC, and `Number("")` is 0, so a
    // caller that passes an empty or non-numeric value would otherwise address
    // row 0 — and a remove would delete the first bookmark. Only a plain
    // integer is read as a position.
    var text = String(value).trim()
    if (text === "") return -1
    if (/^-?\d+$/.test(text)) {
      var row = Number(text)
      return (row >= 0 && row < listModel.count) ? row : -1
    }

    // A whole payload arrives as text, not as an object: `call()` hands a
    // string argument to a method that declares one, so the verbs documented as
    // taking `{"id":"..."}` get the JSON characters themselves. Treating that
    // as an id finds nothing, and the verb answers "invalid" for a row that is
    // on screen — which is what indent, outdent, fold and remove all did.
    if (text.charAt(0) === "{") {
      var decoded = parsePayload(text)
      if (Object.prototype.hasOwnProperty.call(decoded, "id")
          || Object.prototype.hasOwnProperty.call(decoded, "index")) {
        return rowFrom(decoded)
      }
      return -1
    }

    return rowFor(text)
  }

  // ---- scriptable surface --------------------------------------------------
  //
  // These live on the root item, not inside the IpcHandler below, because that
  // is the only place the host can reach. The shell's call() route invokes
  // loader.item[method](arg) — the plugin's root, one argument — so anything
  // declared only inside an IpcHandler is unreachable from
  // `omarchy-shell shell call` and answers "unknown", which looks exactly like
  // a broken plugin. The internal target name is not a contract, either: a
  // caller should not have to know that the handler is called "bookmarks".
  //
  // One JSON string in, one answer out. Every reply is a string, which is the
  // shape the shell's own plugins use, so a caller can branch on it instead of
  // guessing whether the request landed.
  function ping(): string { return "ok" }

  // The file's own shape, not a bare list. A dump is the one thing a caller is
  // likely to write straight back out, and a list of the top level cannot say
  // whether it is v1 or v2 — it is valid as either, so a v2 file dumped as a
  // list and fed to the import path would be taken as v1 and lose every folder.
  // The whole tree comes back, nesting and all, because the model is what
  // knows where the children are.
  function dump(): string { return JSON.stringify(bookmarkState()) }

  // The names are the verbs themselves, because the host looks the method up
  // by the name the caller passed. Naming these ipcAdd and the like made every
  // scripted add and remove answer "unknown", and — worse — `update` happened
  // to collide with something already on Item, which returned undefined and so
  // was reported as "ok" without the row ever changing. A caller cannot tell
  // that apart from a real success, which is why the smoke test now checks the
  // documented verbs against the functions actually defined here.
  function add(payloadJson: string): string {
    return addEntry(parsePayload(payloadJson)) ? "ok" : "invalid"
  }

  function update(payloadJson: string): string {
    var payload = parsePayload(payloadJson)
    // The row is named the same way as everywhere else — by id if there is one,
    // by position if the caller is old enough to use that. `index` is a field
    // of the row being written, not part of the request, so it is taken out
    // before the rest of the payload is treated as the new bookmark.
    var row = rowFrom(payload)
    if (row < 0) return "invalid"
    delete payload.index
    return updateEntry(row, payload) ? "ok" : "unknown"
  }

  function remove(rowJson: string): string {
    var row = rowFrom(rowJson)
    if (row < 0) return "invalid"
    return removeEntry(row) ? "ok" : "unknown"
  }

  function launch(payloadJson: string): string {
    var row = rowFrom(parsePayload(payloadJson))
    if (row < 0) return "invalid"
    launchEntry(row)
    return "ok"
  }

  // A row's place in a tree is not a number the caller can work out from what
  // it last saw, because a folder that is open makes some rows visible and a
  // filter hides others. Every verb below therefore takes the row's id, and the
  // panel finds it through the same projection the list is drawn from. `index`
  // is still accepted by the verbs that had it before, so a caller written
  // against the flat list keeps working.
  function rowFor(target) {
    var id = String(target === undefined || target === null ? "" : target).trim()
    if (id === "") return -1
    // indexForId, not rowForId: this has to come back as a number, and the two
    // are not interchangeable at this call site.
    return Model.indexForId(bookmarkState(), id, viewOptions())
  }

  function move(payloadJson: string): string {
    var payload = parsePayload(payloadJson)
    var row = rowFrom(payload)
    var delta = Number(payload.delta)
    if (row < 0 || !isFinite(delta) || delta === 0) return "invalid"
    return moveEntry(row, delta) ? "ok" : "boundary"
  }

  function indent(rowJson: string): string {
    var row = rowFrom(rowJson)
    if (row < 0) return "invalid"
    if (!Model.canIndent(bookmarkState(), row, viewOptions())) return "boundary"
    return indentEntry(row) ? "ok" : "unknown"
  }

  function outdent(rowJson: string): string {
    var row = rowFrom(rowJson)
    if (row < 0) return "invalid"
    if (!Model.canOutdent(bookmarkState(), row, viewOptions())) return "boundary"
    return outdentEntry(row) ? "ok" : "unknown"
  }

  function pin(payloadJson: string): string {
    var payload = parsePayload(payloadJson)
    var row = rowFrom(payload)
    if (row < 0) return "invalid"
    // An explicit value is honoured, so a script can pin and unpin without
    // having to know the current state first; with no value it is a toggle.
    var wants = Object.prototype.hasOwnProperty.call(payload, "pinned")
      ? payload.pinned === true || payload.pinned === "true"
      : null
    var done = wants === null ? togglePin(row) : setPin(row, wants)
    return done ? "ok" : "unknown"
  }

  // Folding is a view, not data, so it is the one thing here that is not saved:
  // asking the panel to open a folder it is already showing is a no-op, and the
  // answer is still ok, because the caller asked for the state and the state
  // is what it wanted.
  function fold(rowJson: string): string {
    var row = rowFrom(rowJson)
    if (row < 0) return "invalid"
    return toggleFolder(row) ? "ok" : "unknown"
  }

  // Same four verbs, reached by the plugin's own IPC target for callers that
  // already speak qs ipc. They forward rather than reimplement, so the two
  // routes cannot answer differently.
  IpcHandler {
    target: "bookmarks"
    function ping(): string { return root.ping() }
    function dump(): string { return root.dump() }
    function add(payloadJson: string): string { return root.add(payloadJson) }
    function update(payloadJson: string): string { return root.update(payloadJson) }
    function remove(rowJson: string): string { return root.remove(rowJson) }
    function launch(payloadJson: string): string { return root.launch(payloadJson) }
    function move(payloadJson: string): string { return root.move(payloadJson) }
    function indent(rowJson: string): string { return root.indent(rowJson) }
    function outdent(rowJson: string): string { return root.outdent(rowJson) }
    function pin(payloadJson: string): string { return root.pin(payloadJson) }
    function fold(rowJson: string): string { return root.fold(rowJson) }
    function open(): string { root.open(); return "ok" }
    function close(): string { root.close(); return "ok" }
    function toggle(): string { root.opened ? root.close() : root.open(); return "ok" }
  }

  // ---- window --------------------------------------------------------------

  PanelWindow {
    id: window

    // A dedicated `opened`, mirrored into the root, for the host's
    // isPluginOpen(). `visible` alone answers false in the same tick a summon
    // is delivered, which makes a summon -> toggle round trip look like the
    // panel never opened.
    property bool opened: false
    visible: opened

    // Pinned to the left edge, full height, and never reserving layout space.
    anchors { left: true; top: true; bottom: true }
    implicitWidth: Style.space(300)
    color: "transparent"
    WlrLayershell.namespace: "omarchy-bookmarks-bar"
    WlrLayershell.layer: WlrLayer.Overlay
    // The panel must never hold the keyboard hostage. Exclusive focus was
    // taken whenever the panel was merely open, which meant the instant the
    // panel appeared every keystroke on the desktop went to the sidebar: the
    // rest of the session was unusable while it sat there. OnDemand lets the
    // compositor hand over the keyboard when the panel is actually clicked and
    // take it straight back when focus moves away, so browsing the list and
    // working on the desktop are possible at the same time. Only the forms
    // need Exclusive, because a text field cannot receive anything at all
    // without it.
    WlrLayershell.keyboardFocus: root.overlayOpen
      ? WlrKeyboardFocus.Exclusive
      : (opened ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None)
    exclusionMode: ExclusionMode.Ignore

    // Only the sidebar's own pixels take input; the rest of the desktop stays
    // clickable straight through the window.
    mask: Region { item: card }

    onOpenedChanged: {
    // A filter left over from the last time would hide rows before the user
    // asked to see any, and would then filter what they just added.
    if (opened && root.filterQuery !== "") { root.clearFilter(); filterField.text = "" }
      // This pre-selects the first row so the list is already driven once the
      // keyboard arrives. It does not take the keyboard: with OnDemand focus
      // the compositor decides that, and until it does the panel is a
      // read-only overlay that the desktop is free to use.
      if (opened) keys.forceActiveFocus()
      else modal.close()
    }

    BorderSurface {
      id: card
      anchors.fill: parent
      anchors.leftMargin: Style.gapsOut
      anchors.topMargin: Style.gapsOut
      anchors.bottomMargin: Style.gapsOut
      color: Util.alpha(Color.popups.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(1)))
      radius: Style.cornerRadius

      // Keys the shell's catcher does not claim, and the fallback route for the
      // keys it does. It sits on the card rather than on the catcher because the
      // catcher is `blocked` while the menu is open: a blocked handler does not
      // accept the event, so it travels up the focus chain and arrives here. The
      // menu's own Keys handler is the other route, for when the compositor did
      // give the menu's surface the keyboard. Both call the same function, so
      // the highlight cannot end up in two places.
      Keys.onPressed: function(event) {
        if (root.menuOpen) {
          if (menu.handleKey(event.key)) { event.accepted = true; return }
        } else if (event.key === Qt.Key_Menu || event.key === Qt.Key_F10) {
          // Firefox opens a Places row's menu with the Menu key and with Shift+F10,
          // and on a tree both of those mean the selected row. Nothing else in
          // the panel claimed either key, so this is the only place they can go.
          if (root.selectedIndex >= 0) {
            root.openRowMenu(root.selectedIndex)
            event.accepted = true
            return
          }
        }
      }

      PanelKeyCatcher {
        id: keys
        anchors.fill: parent
        // An open form owns the keyboard, and so does the search field: j and k
        // are letters, and while somebody is typing a query they must land in
        // the field rather than moving the cursor through rows they cannot see.
        // The menu blocks the catcher too, and for a different reason than the
        // forms: the forms are on this surface, so the catcher would fight the
        // field for the same key. The menu is on a surface of its own, and the
        // catcher only sees these keys at all when the compositor gave the panel
        // the keyboard instead of the menu — which is exactly the case where the
        // panel has to route them to the menu rather than move the row cursor
        // underneath it. Blocked means "do not act"; the card below is where the
        // menu's keys are handled instead.
        blocked: modal.opened || settings.opened || filterField.activeFocus || root.menuOpen
        onMoveRequested: function(dx, dy) {
          if (root.overlayOpen) return
          // h, l and the two horizontal arrows arrive here, because the shell's
          // key catcher claims them and reports a move rather than a letter.
          // They are Firefox's own tree keys, and the panel used to ignore the
          // horizontal half of the signal entirely: the arrows did nothing and
          // h and l did nothing, which is what the README said out loud.
          // Right goes into the folder above, left comes back out beside it.
          if (dx !== 0) {
            if (dx > 0) root.indentEntry(root.selectedIndex)
            else root.outdentEntry(root.selectedIndex)
            listView.positionViewAtIndex(root.selectedIndex, ListView.Contain)
            return
          }
          root.moveCursor(dy)
          listView.positionViewAtIndex(root.selectedIndex, ListView.Contain)
        }
        onActivateRequested: root.activateCursor()
        // The sheet that is open gets Escape; only a bare panel closes.
        // Escape applies to the topmost layer, so a sheet goes before a query
        // and the panel is the last thing to go. A query is cleared here for the
        // case where the field does not hold focus, since a focused field takes
        // its own Escape and the catcher never sees one.
        onCloseRequested: root.menuOpen ? menu.close()
          : modal.opened ? modal.cancel()
          : settings.opened ? settings.cancel()
          : root.filterQuery !== "" ? (root.clearFilter(), filterField.text = "")
          : root.close()
        onDeleteRequested: function() {
          if (root.overlayOpen) return
          if (root.selectedIndex >= 0) root.removeEntry(root.selectedIndex)
        }
        onTextKey: function(t) {
          // Adding was reachable only by clicking +, which left a keyboard
          // user with an empty list able to do nothing at all.
          if (root.keyIntent(t) === "add") root.openModal(-1)
          // Reordering had a model, a panel function and no way to reach it.
          else if (root.keyIntent(t) === "moveUp") root.moveEntry(root.selectedIndex, -1)
          else if (root.keyIntent(t) === "moveDown") root.moveEntry(root.selectedIndex, 1)
          // "/" is where a keyboard user expects to find search, and a search
          // box that can only be reached with the pointer is not keyboard
          // reachable. Return never makes it to here: it is the launch key.
          else if (root.keyIntent(t) === "search") filterField.forceActiveFocus()
        }
        onTabRequested: function(direction) {
          // Tab edits the current row, Shift+Tab removes it, so the mouse-only
          // actions stay reachable from the keyboard.
          if (direction > 0) {
            root.openModal(root.selectedIndex < 0 ? 0 : root.selectedIndex)
          } else if (!root.overlayOpen && root.selectedIndex >= 0) {
            root.removeEntry(root.selectedIndex)
          }
        }
      }

      // The list and the header. Hidden outright while a sheet is open: a
      // scrim alone is not enough, because even a nearly opaque backdrop
      // shows the header's icons and the current row as faint marks inside
      // the sheet, and those read as corrupted glyphs rather than as a
      // backdrop. Hiding is also cheaper than repainting the list every frame.
      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(9)
        spacing: Style.space(6)
          visible: !root.overlayOpen

        RowLayout {
          Layout.fillWidth: true
          Layout.leftMargin: Style.space(4)
          spacing: Style.space(7)

          Text {
            text: "Bookmarks"
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            color: Util.alpha(Color.popups.text, 0.75)
          }

          Text {
            Layout.fillWidth: true
            // With a query up, "1 item" would be a lie about how much is
            // hidden, and a count that changes under the cursor is the only
            // feedback a search gives. The total counts rows in the tree, so a
            // folder with three bookmarks in it reads as four — which is what
            // the list is showing and therefore what the number must mean.
            text: root.empty ? ""
              : (root.filterQuery === "" && !root.pinnedOnly)
                ? (listModel.count + (listModel.count === 1 ? " item" : " items"))
                : (listModel.count + " of " + root.totalCount)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Util.alpha(Color.popups.text, 0.45)
            horizontalAlignment: Text.AlignRight
          }

          Button {
            text: ""
            // "Settings", from the stock Omarchy menu, so the codepoint is one
            // this desktop's Nerd Font is known to carry.
            iconText: String.fromCodePoint(0xF0493)
            tooltipText: "Settings"
            horizontalPadding: Style.space(5)
            verticalPadding: Style.space(3)
            fontSize: Style.font.bodySmall
            onClicked: root.openSettings()
          }

          // Firefox's Toolbar against its Menu: the same list, drawn with the
          // pinned rows and only the pinned rows. A filter over the same
          // projection the search box uses, so the two cannot disagree about
          // what a row number means.
          Button {
            text: ""
            // A thumbtack, checked against the font's cmap like every other
            // glyph in this plugin.
            iconText: Model.KIND_GLYPHS.pin
            tooltipText: root.pinnedOnly ? "Show everything" : "Show pinned only"
            horizontalPadding: Style.space(5)
            verticalPadding: Style.space(3)
            fontSize: Style.font.bodySmall
            active: root.pinnedOnly
            onClicked: root.togglePinnedOnly()
          }

          Button {
            text: ""
            iconText: "+"
            tooltipText: "Add bookmark"
            horizontalPadding: Style.space(5)
            verticalPadding: Style.space(3)
            fontSize: Style.font.subtitle
            onClicked: root.openModal(-1)
          }
        }

        PanelSeparator { Layout.fillWidth: true }

        // The search box. It sits above the list rather than in the header row
        // because it is a control with a hit area, not a label, and 300px wide
        // is not enough room for a header, a count, two buttons and a field.
        TextField {
          id: filterField
          objectName: "filterField"
          Layout.fillWidth: true
          Layout.margins: Style.space(3)
          placeholderText: "Filter by name or target"
          // Nothing is filtered on a fresh panel: a query left over from last
          // time would hide rows before the user asked to see any.
          text: root.filterQuery
          onTextChanged: root.setFilter(text)
          Keys.onEscapePressed: function(event) {
            if (root.filterQuery !== "") { root.clearFilter(); filterField.text = ""; event.accepted = true }
            else event.accepted = false
          }
        }

        // What the last delete took, said out loud. A folder goes with
        // everything in it, and a row that vanished with four others under it
        // looks like a panel that lost the wrong one. It sits under the filter
        // because that is where the list starts and where the eye already is,
        // and it takes itself away rather than needing a dismiss key, so it
        // cannot outlive the thing it is talking about.
        Text {
          objectName: "removeNotice"
          Layout.fillWidth: true
          Layout.leftMargin: Style.space(9)
          Layout.rightMargin: Style.space(9)
          Layout.bottomMargin: Style.space(3)
          visible: root.lastRemovedCount > 0
          text: root.lastRemovedCount === 1
            ? "Removed 1 bookmark."
            : "Removed a folder and " + (root.lastRemovedCount - 1) + " bookmarks inside it."
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Util.alpha(Color.popups.text, 0.7)
          elide: Text.ElideRight
          maximumLineCount: 1
          Timer {
            // Anything else that changes the list is a better use of the
            // space, and the count is only ever true for this one list.
            running: root.lastRemovedCount > 0
            interval: 4000
            onTriggered: root.lastRemovedCount = 0
          }
        }

        ListView {
          id: listView
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          model: listModel
          spacing: 1
          boundsBehavior: Flickable.StopAtBounds
          maximumFlickVelocity: 1200

          delegate: Components.BookmarkItem {
            required property int index
            required property string entryId
            required property string kind
            required property string type
            required property string label
            required property string target
            required property string icon
            required property bool pinned
            required property int depth
            required property bool hasChildren
            required property bool collapsed
            required property string iconSource

            width: ListView.view.width
            hasCursor: root.opened && !root.overlayOpen && root.selectedIndex === index

            // Return and a click are the same question asked two ways, so both
            // go through activateRow: a folder opens, a section does nothing,
            // and only a bookmark reaches the shell.
            onActivated: {
              root.selectedIndex = index
              root.activateRow(index)
            }
            onEditRequested: {
              root.selectedIndex = index
              root.openModal(index)
            }
            onRemoveRequested: {
              root.selectedIndex = index
              root.removeEntry(index)
            }
            // The row sends the press in its own coordinates. It is mapped here,
            // while the delegate that received it still exists and knows where it
            // sits: by the time the menu is a surface of its own, the press is
            // over, and Qt 6's mouse event carries nothing but an offset from the
            // item under the pointer.
            onMenuRequested: function(localX, localY) {
              var point = mapToItem(window.contentItem, localX, localY)
              root.openRowMenu(index, point.x, point.y)
            }

            // Hover moves the same index the keyboard moves, which is what
            // keeps a single highlight on screen at all times.
            HoverHandler {
              onHoveredChanged: if (hovered) root.selectedIndex = index
            }
          }

          // The empty state doubles as the hint for adding the first one.
          ColumnLayout {
            anchors.centerIn: parent
            width: parent.width * 0.82
            visible: root.empty
            spacing: Style.space(4)

            Text {
              Layout.fillWidth: true
              text: "No bookmarks yet"
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              color: Util.alpha(Color.popups.text, 0.6)
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              Layout.fillWidth: true
              text: "Press a to add a URL, an app, or a command."
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              color: Util.alpha(Color.popups.text, 0.55)
              wrapMode: Text.WordWrap
              // Explicit: the default derives the gap from the font's own
              // metrics, so two lines can land on top of each other and read
              // as one garbled line. A fixed multiple cannot.
              lineHeight: 1.3
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }
    }

    // A window of its own, so the menu can be at the cursor and taller than the
    // panel is. `anchorItem` is the card, which is only here to say which surface
    // this popup belongs to: the press point arrives already mapped into that
    // surface's content coordinates, so the menu never has to guess where the
    // panel is on the screen.
    Components.RowMenu {
      id: menu
      anchorItem: card
      onAction: function(name, payload) { root.runMenuAction(name, payload) }
      // The menu went away without running a command — a click elsewhere, or the
      // pointer leaving the panel. The panel takes the keyboard back, because the
      // surface that had it is closed and a list that answers to no keys is the
      // same as a panel that is not there.
      onDismissed: keys.forceActiveFocus()
    }

    Components.AddBookmarkModal {
      id: modal
      anchors.fill: parent
      onSubmitted: function(index, payloadJson) {
        var payload = root.parsePayload(payloadJson)
        if (index < 0) root.addEntry(payload)
        else root.updateEntry(index, payload)
        keys.forceActiveFocus()
      }
      onSubmittedAfter: function(row, payloadJson) {
        root.addEntryAfter(row, root.parsePayload(payloadJson))
        keys.forceActiveFocus()
      }
      onCancelled: keys.forceActiveFocus()
    }

    Components.SettingsModal {
      id: settings
      anchors.fill: parent
      // The panel owns the path; the sheet is only told.
      dataPath: root.dataPath
      today: root.today
      onClosed: keys.forceActiveFocus()
      onExportRequested: function(path) {
        settings.notice = root.exportTo(path)
          ? "Exported to " + path
          : "Export failed: no file was chosen."
      }
      onReplaceRequested: function(state) {
        settings.notice = root.replaceAll(state)
          ? "Replaced the list with the file's."
          : "That file could not be read as a bookmark file, so nothing was changed."
      }
      onMergeRequested: function(state) {
        settings.notice = root.mergeImported(state)
          ? "Merged in anything this panel did not already have."
          : state === null
            ? "That file could not be read as a bookmark file, so nothing was changed."
            : "Nothing to add: every bookmark in that file is already here."
      }
    }
  }

  // ---- persistence ---------------------------------------------------------

  // FileView cannot observe a file that does not exist yet, so the containing
  // directory is created first and the read follows on the next tick — the
  // same order the notifications service uses.
  Process {
    id: ensureDir
    command: ["mkdir", "-p", root.dataDir]
    onExited: Qt.callLater(function() { bookmarkFile.reload() })
  }

  // A second view for writing somewhere else. A file view is bound to one path,
  // so the export target cannot be the same object as the panel's own data:
  // pointing that one at the export would move the panel's list out of its own
  // file, and the next save would write the export back as the real data.
  FileView {
    id: exportFile
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  FileView {
    id: bookmarkFile
    path: root.dataPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadBookmarks(text())
    onLoadFailed: root.loadBookmarks("")
    onFileChanged: reload()
  }

  // The v1 file as it was, written once and never watched. The upgrade to v2
  // cannot be read back by an older build, so this is the only copy of the
  // original once the first save lands — which is exactly why it is written on
  // load, before the panel has any chance of saving over the file. Its own
  // view is needed because a FileView is bound to one path, and pointing the
  // data view at the backup would leave the panel reading the copy.
  FileView {
    id: backupFile
    path: root.dataPath + ".bak"
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  FileView {
    id: manifestFile
    path: root.manifestPath
    printErrors: false
    onLoaded: {
      try { root.pluginId = String(JSON.parse(text()).id || "") } catch (e) { root.pluginId = "" }
      // A dismissal that arrived before the id was known still has to reach
      // the shell, or openPanelIds keeps a panel it thinks is showing.
      if (root.pluginId !== "" && root.hidePending) {
        root.hidePending = false
        root.close()
      }
    }
  }

  // A themed desktop icon is a file on disk, not something QML can resolve
  // from a freedesktop id, so each unknown id gets one cheap lookup. The
  // direct hit covers the common layouts; the flat find is the fallback for
  // themed sub-directories.
  Process {
    id: iconLookup
    property string iconName: ""

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onIconResolved(iconLookup.iconName, String(text || "").trim())
    }
    onRunningChanged: if (running) root.iconLookupBusy = true
    onExited: {
      root.iconLookupBusy = false
      root.pumpIconQueue()
    }
    // The icon name arrives from the data file, so it is passed as a
    // positional parameter and read back as "$1" — never interpolated into
    // the script text. A name like `x$(rm -rf ~)` is a literal string to the
    // shell that way, where splicing it in with JSON.stringify would let bash
    // run the substitution.
    command: ["bash", "-lc", searchScript(), "bookmarks-icon", iconName]

    function searchScript() {
      return "n=\"$1\"; for d in \"$HOME/.local/share/icons\" \"$HOME/.icons\" /usr/share/icons /usr/local/share/icons; do"
        + " [ -d \"$d\" ] || continue;"
        + " for e in png svg xpm; do [ -f \"$d/$n.$e\" ] && printf 'file://%s' \"$d/$n.$e\" && exit 0; done;"
        + " r=$(find \"$d\" -type f -name \"$n.*\" 2>/dev/null | head -n 1);"
        + " [ -n \"$r\" ] && printf 'file://%s' \"$r\" && exit 0;"
        + " done; exit 0"
    }
  }

  Component.onCompleted: ensureDir.running = true
}
