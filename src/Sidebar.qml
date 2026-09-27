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

  readonly property string dataPath: Quickshell.env("HOME") + "/.config/omarchy/bookmarks.json"
  readonly property string dataDir: Quickshell.env("HOME") + "/.config/omarchy"

  // Desktop id -> file:// URL. An empty string is a real answer ("looked,
  // this system has no such icon"), which is why it is cached too: without
  // it every rebuild would re-run a lookup that cannot succeed.
  property var iconCache: ({})

  ListModel { id: listModel }

  function entryAt(row) {
    if (row < 0 || row >= listModel.count) return null
    var role = listModel.get(row)
    return { id: role.entryId, type: role.type, label: role.label, target: role.target, icon: role.icon }
  }

  function bookmarkList() {
    var out = []
    for (var i = 0; i < listModel.count; i++) {
      var role = listModel.get(i)
      out.push({ id: role.entryId, type: role.type, label: role.label, target: role.target, icon: role.icon })
    }
    return out
  }

  function loadBookmarks(rawText) {
    // A missing or unreadable file parses to an empty list, and the panel
    // shows its "no bookmarks yet" state. install.sh seeds the file on first
    // run; a user who deletes it just starts over.
    rebuild(Model.parse(rawText).bookmarks)
  }

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
        iconSource: iconCache[entry.icon] !== undefined ? iconCache[entry.icon] : ""
      })
    }
    selectedIndex = listModel.count === 0 ? -1 : Util.clamp(selectedIndex < 0 ? 0 : selectedIndex, 0, listModel.count - 1)
    refreshIcons()
  }

  function persist(list) {
    bookmarkFile.setText(Model.serialize({ version: 1, bookmarks: list }))
  }

  // ---- mutations -----------------------------------------------------------

  function addEntry(payload) {
    var list = bookmarkList()
    var next = Model.append({ version: 1, bookmarks: list }, payload)
    if (next.length === list.length) return false
    persist(next)
    rebuild(next)
    selectedIndex = listModel.count - 1
    return true
  }

  function updateEntry(row, payload) {
    if (row < 0 || row >= listModel.count) return false
    // A partial payload cannot be normalised, and updateAt would hand the row
    // straight back. Saying "ok" to a caller whose edit vanished is worse than
    // refusing, so the rejection is reported instead of swallowed.
    if (!Model.normalizeEntry(payload)) return false
    var before = bookmarkList()
    var next = Model.updateAt({ version: 1, bookmarks: before }, row, payload)
    persist(next)
    rebuild(next)
    selectedIndex = Util.clamp(row, 0, listModel.count - 1)
    return true
  }

  function removeEntry(row) {
    if (row < 0 || row >= listModel.count) return false
    var list = Model.removeAt({ version: 1, bookmarks: bookmarkList() }, row)
    persist(list)
    rebuild(list)
    selectedIndex = listModel.count === 0 ? -1 : Util.clamp(row, 0, listModel.count - 1)
    return true
  }

  function moveEntry(row, delta) {
    if (row < 0 || row >= listModel.count) return false
    var list = Model.moveBy({ version: 1, bookmarks: bookmarkList() }, row, delta)
    if (JSON.stringify(list) === JSON.stringify(bookmarkList())) return false
    persist(list)
    rebuild(list)
    selectedIndex = Util.clamp(row + delta, 0, listModel.count - 1)
    return true
  }

  function launchEntry(row) {
    var argv = Model.argvFor(entryAt(row))
    if (argv.length === 0) return
    // A cmd bookmark is the user's own command line, so it goes through a
    // shell deliberately. url and app targets are data and stay argv-only.
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
    launchEntry(selectedIndex)
  }

  // ---- letter keys ---------------------------------------------------------

  // The catcher consumes the arrow keys and j/k before it gets here, and it
  // forwards the rest one character at a time. Which characters mean what is
  // written down once, in one function, so the handler below and the test that
  // checks the documented map against it cannot drift apart.
  //
  // Uppercase is used for the two that shift an entry: j/k are already taken by
  // moving the cursor, and a capital letter is the same physical key.
  function keyIntent(t) {
    if (t === "a" || t === "A") return "add"
    if (t === "J") return "moveUp"
    if (t === "K") return "moveDown"
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

  // Index arguments arrive as strings over IPC, and `Number("")` is 0, so a
  // caller that passes an empty or non-numeric value would otherwise address
  // row 0 — and a remove would delete the first bookmark. Anything that is not
  // a plain integer is rejected before it reaches a mutation.
  function rowFrom(value) {
    if (value === null || value === undefined) return -1
    var text = String(value).trim()
    if (!/^-?\d+$/.test(text)) return -1
    var row = Number(text)
    if (row < 0 || row >= listModel.count) return -1
    return row
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
  function dump(): string { return JSON.stringify(bookmarkList()) }

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
    if (!Object.prototype.hasOwnProperty.call(payload, "index")) return "invalid"
    var row = rowFrom(payload.index)
    delete payload.index
    if (row < 0) return "invalid"
    return updateEntry(row, payload) ? "ok" : "unknown"
  }

  function remove(rowJson: string): string {
    var row = rowFrom(rowJson)
    if (row < 0) return "invalid"
    return removeEntry(row) ? "ok" : "unknown"
  }

  function launch(payloadJson: string): string {
    var payload = parsePayload(payloadJson)
    if (!Object.prototype.hasOwnProperty.call(payload, "index")) return "invalid"
    var row = rowFrom(payload.index)
    if (row < 0) return "invalid"
    launchEntry(row)
    return "ok"
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

      PanelKeyCatcher {
        id: keys
        anchors.fill: parent
        // An open form owns the keyboard.
        blocked: modal.opened
        onMoveRequested: function(dx, dy) {
          if (root.overlayOpen) return
          root.moveCursor(dy)
          listView.positionViewAtIndex(root.selectedIndex, ListView.Contain)
        }
        onActivateRequested: root.activateCursor()
        // The sheet that is open gets Escape; only a bare panel closes.
        onCloseRequested: modal.opened ? modal.cancel()
          : settings.opened ? settings.cancel()
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
            text: root.empty ? "" : listModel.count + (listModel.count === 1 ? " item" : " items")
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
            required property string type
            required property string label
            required property string target
            required property string icon
            required property string iconSource

            width: ListView.view.width
            hasCursor: root.opened && !root.overlayOpen && root.selectedIndex === index

            onActivated: {
              root.selectedIndex = index
              root.launchEntry(index)
            }
            onEditRequested: {
              root.selectedIndex = index
              root.openModal(index)
            }
            onRemoveRequested: {
              root.selectedIndex = index
              root.removeEntry(index)
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

    Components.AddBookmarkModal {
      id: modal
      anchors.fill: parent
      onSubmitted: function(index, payloadJson) {
        var payload = root.parsePayload(payloadJson)
        if (index < 0) root.addEntry(payload)
        else root.updateEntry(index, payload)
        keys.forceActiveFocus()
      }
      onCancelled: keys.forceActiveFocus()
    }

    Components.SettingsModal {
      id: settings
      anchors.fill: parent
      // The panel owns the path; the sheet is only told.
      dataPath: root.dataPath
      onClosed: keys.forceActiveFocus()
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
