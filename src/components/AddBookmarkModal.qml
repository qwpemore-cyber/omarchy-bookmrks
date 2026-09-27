import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "../BookmarkModel.js" as Model

// Add / edit form for a single bookmark. Drawn as a full-surface scrim so it
// owns every click while it is open — a list row behind a half-transparent
// form is a misclick waiting to happen.
//
// Owns no data: the caller seeds it with `openFor(index)` and reads the result
// from the `submitted` signal. `focusField` is exported so the sidebar can
// point the PanelKeyCatcher at whichever field is live.
Item {
  id: root

  // -1 means "adding a new bookmark"; otherwise the row being edited.
  property int editIndex: -1
  readonly property bool editing: editIndex >= 0
  readonly property bool opened: modalOpen

  property string type: "url"
  property string label: ""
  property string target: ""
  property string icon: ""
  readonly property string headline: editing ? "Edit bookmark" : "New bookmark"

  // Which of the two text fields the keyboard is currently in. The sidebar
  // blocks its own key handling while this is non-negative.
  property int focusField: -1

  signal submitted(int index, string payloadJson)
  signal cancelled()

  // The sidebar keeps this mounted and only toggles `visible`, so switching
  // between the list and the form costs no re-layout.
  property bool modalOpen: false
  visible: modalOpen

  // ---- lifecycle

  function openFor(index, entry) {
    editIndex = index
    modalOpen = true

    if (entry) {
      type = entry.type || "url"
      label = entry.label || ""
      target = entry.target || ""
      icon = entry.icon || ""
    } else {
      type = "url"
      label = ""
      target = ""
      icon = ""
    }

    labelField.text = label
    targetField.text = target
    iconField.text = icon
    focusField = -1

    // Focus after the surface is mounted, otherwise the first click that
    // opened the modal would immediately land in a field.
    Qt.callLater(function() { targetField.forceActiveFocus(); focusField = 1 })
  }

  function close() {
    modalOpen = false
    focusField = -1
  }

  function cancel() {
    close()
    cancelled()
  }

    // Validate through the model rather than duplicating its rules here, so a
    // target the model would reject never reaches the saved file.
    function submit() {
      var normalized = Model.normalizeEntry({
        type: root.type,
        label: labelField.text,
        target: targetField.text,
        icon: iconField.text
      })
      if (!normalized) {
      targetError.visible = true
      targetField.forceActiveFocus()
      focusField = 1
      return
    }
    targetError.visible = false
    close()
    submitted(root.editIndex, JSON.stringify(normalized))
  }

  // Type switching only changes the hint; the target stays untouched so
  // flipping url -> app and back does not lose what was typed.
  function cycleType(delta) {
    var types = Model.TYPES
    var at = types.indexOf(root.type)
    if (at === -1) at = 0
    type = types[(at + delta + types.length) % types.length]
  }

  // ---- surfaces

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(Color.background, 0.72)
  }

  MouseArea {
    anchors.fill: parent
    // Swallow presses on the scrim so nothing behind the form reacts to a
    // click that was meant for the form.
    onClicked: function(mouse) { mouse.accepted = true }
  }

  BorderSurface {
    id: card
    anchors.centerIn: parent
    width: Style.space(330)
    // A form with four rows of content must not outgrow a short screen.
    height: Math.min(form.implicitHeight + Style.space(20) * 2, parent.height - Style.space(24))
    color: Util.alpha(Color.popups.background, 0.97)
    borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
    radius: Style.cornerRadius

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      // While a field has focus, every key belongs to the editor.
      blocked: root.focusField >= 0
      onMoveRequested: function(dx, dy) { root.cycleType(dy) }
      onActivateRequested: root.submit()
      onCloseRequested: root.cancel()
      onDeleteRequested: root.cycleType(-1)
    }

    ColumnLayout {
      id: form
      anchors.fill: parent
      anchors.margins: Style.space(14)
      spacing: Style.space(9)

      Text {
        Layout.fillWidth: true
        text: root.headline
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
        font.bold: true
        color: Color.popups.text
      }

      // ---- type selector
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Text {
          text: "Type"
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          color: Util.alpha(Color.popups.text, 0.7)
        }

        Item { Layout.fillWidth: true }

        Repeater {
          model: Model.TYPES
          delegate: Button {
            required property string modelData
            required property int index

            readonly property bool isCurrent: root.type === modelData

            text: modelData
            selected: isCurrent
            hasCursor: isCurrent
            bordered: true
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(9)
            verticalPadding: Style.space(4)
            onClicked: root.type = modelData
          }
        }
      }

      // ---- label
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(3)

        Text {
          text: "Label"
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          color: Util.alpha(Color.popups.text, 0.7)
        }

        TextField {
          id: labelField
          Layout.fillWidth: true
          placeholderText: "shown in the sidebar"
          onActiveFocusChanged: root.focusField = activeFocus ? 0 : -1
        }
      }

      // ---- target
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(3)

        Text {
          text: "Target"
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          color: Util.alpha(Color.popups.text, 0.7)
        }

        TextField {
          id: targetField
          Layout.fillWidth: true
          placeholderText: root.type === "url" ? "https://example.com"
            : root.type === "app" ? "firefox or org.gnome.Nautilus"
            : "any shell command"
          onActiveFocusChanged: root.focusField = activeFocus ? 1 : -1
        }

        Text {
          id: targetError
          Layout.fillWidth: true
          visible: false
          text: "A target is required."
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Color.urgent
        }
      }

      // ---- icon
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(3)

        Text {
          text: "Icon"
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          color: Util.alpha(Color.popups.text, 0.7)
        }

        TextField {
          id: iconField
          Layout.fillWidth: true
          placeholderText: "optional: nerd-font glyph or desktop id"
          onActiveFocusChanged: root.focusField = activeFocus ? 2 : -1
        }
      }

      Item { Layout.fillHeight: true; Layout.minimumHeight: 0 }

      // ---- actions
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(7)

        Button {
          text: "Cancel"
          horizontalPadding: Style.space(14)
          verticalPadding: Style.space(6)
          onClicked: root.cancel()
        }

        Item { Layout.fillWidth: true }

        Button {
          text: "Save"
          selected: true
          horizontalPadding: Style.space(18)
          verticalPadding: Style.space(6)
          onClicked: root.submit()
        }
      }
    }
  }
}
