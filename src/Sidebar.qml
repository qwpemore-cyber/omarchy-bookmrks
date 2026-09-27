import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "BookmarkModel.js" as Model
import "BookmarkItem.qml" as BookmarkItem
import "AddBookmarkModal.qml" as AddBookmarkModal

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
  readonly property bool opened: window.opened

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
    if (!closingFromHost && pluginId !== "" && shell && typeof shell.hide === "function") {
      closingFromHost = true
      shell.hide(pluginId)
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
    var next = Model.updateAt({ version: 1, bookmarks: bookmarkList() }, row, payload)
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
  // list cannot spawn a burst of shells.
  function pumpIconQueue() {
    if (iconLookupBusy || iconQueue.length === 0) return
    var job = iconQueue.shift()

    // The list may have been rebuilt between queueing and running.
    var entry = entryAt(job.row)
    if (!entry || entry.icon !== job.name) return pumpIconQueue()

    iconLookup.iconName = job.name
    iconLookup.running = true
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
    if (selectedIndex < 0) return
    launchEntry(selectedIndex)
  }

  function openModal(row) {
    if (row >= 0 && row >= listModel.count) return
    modal.openFor(row, row >= 0 ? entryAt(row) : null)
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

  IpcHandler {
    target: "bookmarks"
    function add(payloadJson: string): string { return root.addEntry(root.parsePayload(payloadJson)) ? "ok" : "invalid" }
    function update(payloadJson: string): string {
      var payload = root.parsePayload(payloadJson)
      var row = Number(payload.index)
      delete payload.index
      if (isNaN(row)) return "invalid"
      return root.updateEntry(row, payload) ? "ok" : "unknown"
    }
    function remove(rowJson: string): string {
      var row = Number(String(rowJson))
      if (isNaN(row)) return "invalid"
      return root.removeEntry(row) ? "ok" : "unknown"
    }
    // Every function returns a reply string, which is the shape the shell's
    // own plugins use; a caller can then branch on the answer instead of
    // guessing whether the request landed.
    function open(): string { root.open(); return "ok" }
    function close(): string { root.close(); return "ok" }
    function toggle(): string { root.opened ? root.close() : root.open(); return "ok" }
    function dump(): string { return JSON.stringify(root.bookmarkList()) }
    function ping(): string { return "ok" }
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
    width: Style.space(300)
    color: "transparent"
    WlrLayershell.namespace: "omarchy-bookmarks-bar"
    WlrLayershell.layer: WlrLayer.Overlay
    // Focus is dropped while the form is up: the form's own fields hold it,
    // and the window must not keep exclusive focus behind them.
    WlrLayershell.keyboardFocus: opened && !modal.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Only the sidebar's own pixels take input; the rest of the desktop stays
    // clickable straight through the window.
    mask: Region { item: card }

    onOpenedChanged: {
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
          root.moveCursor(dy)
          listView.positionViewAtIndex(root.selectedIndex, ListView.Contain)
        }
        onActivateRequested: root.activateCursor()
        onCloseRequested: modal.opened ? modal.cancel() : root.close()
        onDeleteRequested: function() {
          if (root.selectedIndex >= 0) root.removeEntry(root.selectedIndex)
        }
        onTabRequested: function(direction) {
          // Tab edits the current row, Shift+Tab removes it, so the mouse-only
          // actions stay reachable from the keyboard.
          if (direction > 0) root.openModal(root.selectedIndex < 0 ? 0 : root.selectedIndex)
          else if (root.selectedIndex >= 0) root.removeEntry(root.selectedIndex)
        }
      }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(9)
        spacing: Style.space(6)

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

          delegate: BookmarkItem {
            required property int index
            required property string entryId
            required property string type
            required property string label
            required property string target
            required property string icon
            required property string iconSource

            width: ListView.view.width
            hasCursor: root.opened && !modal.opened && root.selectedIndex === index

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
              text: "Press + to add a URL, an app, or a command."
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: Util.alpha(Color.popups.text, 0.4)
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }
    }

    AddBookmarkModal {
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
    command: ["bash", "-lc", searchScript()]

    function searchScript() {
      return "n=" + JSON.stringify(iconName) + "; for d in \"$HOME/.local/share/icons\" \"$HOME/.icons\" /usr/share/icons /usr/local/share/icons; do"
        + " [ -d \"$d\" ] || continue;"
        + " for e in png svg xpm; do [ -f \"$d/$n.$e\" ] && printf 'file://%s' \"$d/$n.$e\" && exit 0; done;"
        + " r=$(find \"$d\" -type f -name \"$n.*\" 2>/dev/null | head -n 1);"
        + " [ -n \"$r\" ] && printf 'file://%s' \"$r\" && exit 0;"
        + " done; exit 0"
    }
  }

  Component.onCompleted: ensureDir.running = true
}
