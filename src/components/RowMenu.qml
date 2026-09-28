// The right-click menu for one row, in a window of its own.
//
// Firefox's `placesContext` is a single popup whose items are hidden according
// to what was clicked — nodeIsFolder, nodeIsURI, nodeIsSeparator — rather than
// three different menus. This is the same idea: one menu, and `itemsFor(row)`
// decides what is in it. The labels are Firefox's own, out of
// localization/en-US/browser/places.ftl, so a row's menu here says what the same
// row's menu in Firefox says.
//
// A PopupWindow is an xdg-popup, which is what puts the menu on screen at the
// cursor instead of inside a 300px panel that would have to clip it. It is also
// a separate surface, and Ui/KeyboardPanel.qml's header records why that used to
// be a problem: an xdg-popup does not get the keyboard by being mapped, it only
// gets it after a click or a hover routes focus through the surface it belongs
// to. A menu without arrow keys is not a menu, so `grabFocus` is what asks for
// the focus, and `handleKey` is also callable from the panel's own key catcher:
// whichever surface the compositor decides owns the keyboard, the same function
// moves the highlight and runs the command, so the two paths cannot disagree
// about what the menu is showing.

import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import ".."

PopupWindow {
  id: root

  // The surface the menu is anchored to, injected by the panel. A popup with no
  // anchor window has nothing to position against, and Qt puts it at 0,0 of the
  // screen, which is the top-left corner of the monitor.
  required property Item anchorItem
  readonly property var hostWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property var screen: hostWindow ? hostWindow.screen : null

  // The row this menu is about, as the panel's projection described it. The
  // panel fills this in, because it is the only thing that can turn an id into a
  // row number under the filter and collapse state the list is actually showing.
  property var entry: null
  property int rowIndex: -1
  // Where the pointer was when the button went down, already mapped into the
  // host window's content coordinates. The panel does the mapping, from the
  // delegate that received the press: by the time this surface exists the press
  // is over, and QQuickMouseEvent in Qt 6 carries only x and y relative to the
  // item under the pointer, so the point has to be converted while the item that
  // knows where it is still has it.
  property real anchorX: 0
  property real anchorY: 0
  // How many rows a delete of this row would take with it. The panel holds the
  // tree, so it is the only thing that can answer: asked of the row alone, a
  // folder's own child count is one short of the truth for every folder that
  // holds a folder.
  property int subtreeCount: 0

  // Which item is highlighted, as an index into `items`. -1 is "none", which is
  // a real state and not a mistake: a menu of only separators has nothing to run,
  // and a menu whose first item is a gap would otherwise open with Enter doing
  // nothing and read as broken.
  property int highlighted: -1

  // A menu is a list of commands, and Firefox's is built from three kinds of
  // thing: a command, a gap, and nothing at all. `action` is the command's name
  // as the panel knows it, so a label can change and the behaviour cannot.
  //
  // "Add Separator" is one click in Firefox and opens no form, so it is one click
  // here. "New Bookmark…" and "New Folder…" open the same form the panel's own +
  // button opens, placed under the row that was clicked.
  readonly property var items: entry === null ? [] : itemsFor(entry)

  readonly property bool opened: visible

  signal action(string action, var payload)
  signal dismissed()

  // An xdg-popup will not take the keyboard by being mapped, so the focus is
  // asked for explicitly and re-asked every time the menu opens. A window that
  // asks for focus and never gets it is silent about it, which is why the panel
  // also routes these keys here from its own catcher.
  grabFocus: visible

  readonly property int rowHeight: Style.spacing.popupRowHeight
  readonly property int separatorHeight: Style.space(9)
  readonly property int menuPadding: Style.spacing.popupPadding
  readonly property int margin: Style.gapsOut

  color: "transparent"
  implicitWidth: Style.space(212)
  implicitHeight: menuPadding * 2 + heightOf(items)

  function heightOf(list) {
    var total = 0
    for (var i = 0; i < list.length; i++) total += itemRowHeight(list[i])
    return total
  }

  function itemRowHeight(item) {
    return item.action === "" ? root.separatorHeight : root.rowHeight
  }

  // ---- what is in the menu -------------------------------------------------

  function itemsFor(row) {
    var kind = String(row && row.kind !== undefined ? row.kind : "bookmark")
    // A separator is a rule, not a place. Firefox draws no menu for one, and a
    // menu of things that cannot be done to a line is worse than no menu.
    if (kind === "separator") return []

    var head = [{ action: "edit", label: editLabel(kind) }]
    if (kind === "bookmark") {
      head.push({ action: "pin", label: row.pinned === true ? "Unpin Bookmark" : "Pin Bookmark" })
    }

    // The gap is a real item in the list rather than a root.margin on the group, so
    // that the arrow keys have something to skip over and `root.items` is the only
    // description of the menu there is.
    var add = [
      { action: "newBookmark", label: "New Bookmark…" },
      { action: "newFolder", label: "New Folder…" },
      { action: "newSeparator", label: "Add Separator" }
    ]

    return head
      .concat([{ action: "", label: "" }], add, [{ action: "", label: "" }])
      .concat([{ action: "delete", label: deleteLabel(row) }])
  }

  // Firefox's own labels, from places.ftl: places-edit-bookmark, -folder2 and
  // -generic, and places-delete-bookmark / -delete-folder.
  function editLabel(kind) {
    if (kind === "folder") return "Edit Folder…"
    if (kind === "section") return "Edit Section…"
    return "Edit Bookmark…"
  }

  // places-delete-bookmark counts the thing it is about to delete, and says so:
  // "Delete Bookmark" for one, "Delete Bookmarks" for the rest. A folder reports
  // the rows inside it, which is what would actually disappear — the folder and
  // everything under it — rather than the folder alone, which is one and reads
  // like a mistake.
  function deleteLabel(row) {
    var kind = String(row.kind)
    var count = root.subtreeCount
    if (kind === "folder") {
      if (count <= 0) return "Delete Folder"
      return "Delete Folder (" + count + (count === 1 ? " bookmark)" : " bookmarks)")
    }
    if (kind === "section") {
      if (count <= 0) return "Delete Section"
      return "Delete Section (" + count + (count === 1 ? " item)" : " items)")
    }
    return "Delete Bookmark"
  }

  // ---- opening and closing -------------------------------------------------

  function openFor(index, row, contentX, contentY, count) {
    root.rowIndex = index
    root.entry = row
    root.anchorX = contentX
    root.anchorY = contentY
    root.subtreeCount = count
    root.highlighted = -1
    root.visible = true
    root.focusFirstCommand()
    // Once the surface has keyboard focus, Qt still needs an item inside it to
    // be the active-focus target, and the item does not exist at map time.
    Qt.callLater(function() {
      if (root.visible) keyTarget.forceActiveFocus()
    })
  }

  function close() {
    if (!root.visible) return
    root.visible = false
    dismissed()
  }

  function focusFirstCommand() {
    for (var i = 0; i < root.items.length; i++) {
      if (root.items[i].action !== "") { root.highlighted = i; return }
    }
  }

  function focusLastCommand() {
    for (var i = root.items.length - 1; i >= 0; i--) {
      if (root.items[i].action !== "") { root.highlighted = i; return }
    }
  }

  // ---- the keyboard --------------------------------------------------------

  // One function, called from two places: the Keys handler on the surface, and
  // the panel's key catcher when the compositor gave the panel the keyboard
  // instead. Returns true when the key was the menu's to handle, so the panel
  // knows not to also act on it — otherwise Escape would close the menu and the
  // panel, which is the same key press reaching two handlers.
  function handleKey(key) {
    if (!root.visible) return false
    if (key === Qt.Key_Escape) { root.close(); return true }
    if (key === Qt.Key_Down) { root.moveHighlight(1); return true }
    if (key === Qt.Key_Up) { root.moveHighlight(-1); return true }
    if (key === Qt.Key_Home) { root.focusFirstCommand(); return true }
    if (key === Qt.Key_End) { root.focusLastCommand(); return true }
    if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Space) {
      root.runHighlighted(); return true
    }
    return false
  }

  function moveHighlight(delta) {
    if (root.items.length === 0) return
    if (root.highlighted < 0) { root.focusFirstCommand(); if (delta < 0) root.focusLastCommand(); return }
    var next = root.highlighted
    for (var step = 0; step < root.items.length; step++) {
      next = (next + delta + root.items.length) % root.items.length
      if (root.items[next].action !== "") { root.highlighted = next; return }
    }
  }

  function runHighlighted() {
    if (root.highlighted < 0 || root.highlighted >= root.items.length) return
    var item = root.items[root.highlighted]
    if (item.action === "") return
    var row = root.entry
    var index = root.rowIndex
    root.close()
    root.action(item.action, { row: row, rowIndex: index })
  }

  // ---- placement -----------------------------------------------------------

  // The same anchor block as Ui/PopupCard.qml, for the same reason: an xdg-popup
  // has to be told which surface it belongs to and where on it to sit, and
  // `PopupAdjustment.Slide` is what flips the menu upward when the cursor is low
  // enough that the menu would otherwise run off the bottom of the screen.
  anchor {
    id: popupAnchor
    window: root.hostWindow
    adjustment: PopupAdjustment.Slide
    edges: Edges.Top | Edges.Left
    gravity: Edges.Bottom | Edges.Right
    rect.width: 1
    rect.height: 1

    onAnchoring: {
      if (!root.hostWindow) return
      var w = root.implicitWidth
      var h = root.implicitHeight
      var sw = root.screen ? root.screen.width : root.hostWindow.width
      var sh = root.screen ? root.screen.height : root.hostWindow.height

      // Inside the panel's own bounds first, because the panel is narrow and that
      // clamp does most of the work, and only then against the screen for the
      // menu's own height, which is taller than any row of the list.
      var x = Math.max(root.margin, Math.min(root.anchorX, root.hostWindow.width - w - root.margin))
      var y = root.anchorY
      if (y + h > sh - root.margin) y = Math.max(root.margin, sh - h - root.margin)
      popupAnchor.rect.x = Math.round(x)
      popupAnchor.rect.y = Math.round(y)
    }
  }

  // Clicking anywhere else dismisses the menu, and so does a click back on the
  // panel. Ui/PopupCard.qml does it the same way: Hyprland's focus grab routes
  // input only to the listed surfaces, and `onCleared` fires when the grab goes
  // away because the pointer went somewhere else. Without this the menu would
  // stay on screen until something in it was pressed, which is not a menu, it is
  // a second panel.
  HyprlandFocusGrab {
    active: root.visible
    windows: root.hostWindow ? [root, root.hostWindow] : [root]
    onCleared: root.close()
  }

  // ---- the card ------------------------------------------------------------

  readonly property var borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Math.max(1, Style.space(2)))

  BorderSurface {
    id: card
    anchors.fill: parent
    color: Color.popups.background
    borderSpec: root.borderSpec
    radius: Style.cornerRadius
    opacity: root.visible ? 1 : 0

    Behavior on opacity {
      NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
    }

    // The active-focus target inside this surface. A window can have keyboard
    // focus and still deliver no key events, because Qt wants an item inside it
    // to hold the active focus, and that item is created with the surface.
    Item {
      id: keyTarget
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
      focus: true

      Keys.onPressed: function(event) {
        if (root.handleKey(event.key)) event.accepted = true
      }

      Column {
        id: menuColumn
        anchors.fill: parent
        spacing: 0

        Repeater {
          model: root.items

          delegate: Item {
            id: menuItem
            required property var modelData
            required property int index

            readonly property bool isCommand: modelData.action !== ""
            width: menuColumn.width
            height: root.itemRowHeight(modelData)

            // Firefox's menuseparator: a gap with a hairline in the middle. A gap
            // and not a bare 1px line, because the groups are what make a menu
            // scannable and a hairline on its own is a border.
            Item {
              anchors.fill: parent
              visible: !menuItem.isCommand
              Rectangle {
                anchors.centerIn: parent
                width: parent.width
                height: 1
                color: Util.alpha(Color.popups.text, 0.12)
              }
            }

            Rectangle {
              anchors.fill: parent
              visible: menuItem.isCommand
              color: menuItem.index === root.highlighted ? Util.alpha(Color.accent, 0.22) : "transparent"
              radius: Style.cornerRadius

              Text {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                verticalAlignment: Text.AlignVCenter
                text: menuItem.modelData.label
                textFormat: Text.PlainText
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                // The last group is the one that can lose something, so it is
                // allowed to look like it. Firefox does not do this, but a "New
                // Folder…" three lines above a "Delete Folder" is not a
                // distinction anyone should have to notice by reading twice.
                color: menuItem.modelData.action === "delete"
                  ? Util.alpha(Color.popups.text, 0.9)
                  : Color.popups.text
                elide: Text.ElideRight
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              visible: menuItem.isCommand
              cursorShape: Qt.PointingHandCursor
              // Hover moves the highlight because a keyboard user arriving at a
              // menu with no focus has to be able to see where they are, and
              // because a mouse user expects the item under the cursor to be the
              // one that will run.
              onEntered: if (menuItem.isCommand) root.highlighted = menuItem.index
              onClicked: {
                if (!menuItem.isCommand) return
                root.highlighted = menuItem.index
                root.runHighlighted()
              }
            }
          }
        }
      }
    }
  }
}
