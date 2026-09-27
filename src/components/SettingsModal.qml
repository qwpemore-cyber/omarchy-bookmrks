import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// Settings sheet. A shell of its own so the header's gear button has
// something real to open, and so a setting has a place to go that is not the
// bookmark form — the two do different things and would fight over the same
// fields otherwise.
//
// Nothing is configurable yet, and the sheet says so rather than pretending:
// an empty box that looks broken is worse than an empty box that admits it.
Item {
  id: root

  readonly property bool opened: modalOpen
  property bool modalOpen: false

  signal closed()

  function open() {
    modalOpen = true
  }

  function close() {
    modalOpen = false
    closed()
  }

  function cancel() {
    close()
  }

  // A settings sheet is a read-mostly surface: there is no text field to type
  // into, so the catcher's own Escape is what closes it and nothing has to be
  // forwarded from a field the way the bookmark form has to.
  Rectangle {
    anchors.fill: parent
    color: Util.alpha(Color.background, 0.72)
  }

  MouseArea {
    anchors.fill: parent
    onClicked: function(mouse) { mouse.accepted = true }
  }

  BorderSurface {
    id: card
    anchors.centerIn: parent
    // Clamped to the panel, for the same reason the bookmark form is: a card
    // with a literal width overflows a narrow window and its buttons go with it.
    width: Math.min(Style.space(330), parent.width - Style.space(16))
    height: Math.max(
      Style.space(120),
      Math.min(form.implicitHeight + Style.space(20) * 2, parent.height - Style.space(24)))
    color: Util.alpha(Color.popups.background, 0.97)
    borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
    radius: Style.cornerRadius

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onCloseRequested: root.cancel()
    }

    ColumnLayout {
      id: form
      anchors.fill: parent
      anchors.margins: Style.space(14)
      spacing: Style.space(9)

      Text {
        Layout.fillWidth: true
        text: "Settings"
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
        font.bold: true
        color: Color.popups.text
      }

      PanelSeparator { Layout.fillWidth: true }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(4)

        Text {
          Layout.fillWidth: true
          text: "Nothing to configure yet"
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          color: Util.alpha(Color.popups.text, 0.7)
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          Layout.fillWidth: true
          text: "Your bookmarks live in ~/.config/omarchy/bookmarks.json and can be edited there, or from the panel itself."
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Util.alpha(Color.popups.text, 0.45)
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }
      }

      Item { Layout.fillHeight: true; Layout.minimumHeight: 0 }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(7)

        Item { Layout.fillWidth: true }

        Button {
          text: "Close"
          selected: true
          horizontalPadding: Style.space(18)
          verticalPadding: Style.space(6)
          onClicked: root.close()
        }
      }
    }
  }
}
