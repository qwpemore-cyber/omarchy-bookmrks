// The add/edit form. One component for both, told which by the row it is given.
// Owns field validation, the type cycle, and focus. Enter submits and Escape
// cancels, and both are forwarded from the fields — a bare Escape here would
// close the whole panel instead of the form.

import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs
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

  // `type` is real state: the placeholder, the type buttons and cycleType all
  // read it, and it has no visible field of its own. The three text values are
  // not state here — they live in the fields, and submit() reads the fields
  // directly, so a second copy would only be a copy that can go stale.
  //
  // The id is the exception: it is not typed, it is the identity of the row
  // being edited. Dropping it would make submitted() carry a freshly minted id
  // for an existing bookmark. updateAt currently overwrites it with the stored
  // value, which hides the slip here, but the signal claims to hand over a
  // whole entry and it would stop being one.
  property string type: "url"
  property string entryId: ""
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

    var e = entry || {}
    type = e.type || "url"
    entryId = e.id || ""
    labelField.text = e.label || ""
    targetField.text = e.target || ""
    iconField.text = e.icon || ""
    focusField = -1

    // Focus after the surface is mounted, otherwise the first click that
    // opened the modal would immediately land in a field. The explicit
    // focusField assignment is load-bearing: reopening the form while the
    // target field still holds focus sends no activeFocusChanged, and the
    // catcher would stay unblocked with the editor silently eating arrows.
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

  // The message follows the reason. "A target is required" next to a full
  // relative path would send the user looking for the wrong problem, so a
  // rejected-but-present target says what a path has to look like instead.
  function targetProblem() {
    if (String(targetField.text).trim() === "") return "A target is required."
    if (root.type === "file" && !Model.isFileTarget(String(targetField.text).trim()))
      return "Use a full path, or start it with ~."
    return "That target is not valid."
  }

  // Validate through the model rather than duplicating its rules here, so a
  // target the model would reject never reaches the saved file.
  function submit() {
    var normalized = Model.normalizeEntry({
      id: root.entryId,
      type: root.type,
      label: labelField.text,
      target: targetField.text,
      icon: iconField.text
    })
    if (!normalized) {
      targetError.text = root.targetProblem()
      targetError.visible = true
      targetField.forceActiveFocus()
      focusField = 1
      return
    }
    targetError.visible = false
    close()
    submitted(root.editIndex, JSON.stringify(normalized))
  }

  // The catcher stands aside whenever a field has focus, which is the whole
  // time the form is being used, so Return and Escape would never arrive
  // anywhere: the editor ignores both, and the form could then only ever be
  // saved or abandoned with a mouse. Every field forwards just these two.
  function fieldKey(event) {
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.submit()
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Escape) {
      root.cancel()
      event.accepted = true
    }
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
    // Matches the settings sheet: see the note there about stray marks.
    color: Util.alpha(Color.background, 0.97)
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
    // Never wider than the panel it is drawn inside. The panel is 300 units and
    // this card asked for 330, so the form overflowed the window by 30 units:
    // the card is centred, so 15 units hung off each side, and the right end
    // of the fields and the buttons were clipped by the window edge. The
    // clamp only ever bites on a narrow panel, since 330 fits comfortably
    // inside the available 282.
    width: Math.min(Style.space(330), parent.width - Style.space(16))
    // A form with four rows of content must not outgrow a short screen.
    // Clamped rather than plain Math.min: on a very short panel the
    // second term goes negative, and a negative height is not a small
    // form, it is a form that silently does not render.
    height: Math.max(
      Style.space(120),
      Math.min(form.implicitHeight + Style.space(20) * 2, parent.height - Style.space(24)))
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
      // In the list this key deletes the selected bookmark. Here the only
      // destructive action is the form's own, so it steps the type instead
      // — and it only ever arrives with no field focused, i.e. before
      // the first click lands in the form.
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
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) { root.fieldKey(event) }
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
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) { root.fieldKey(event) }
          Layout.fillWidth: true
          placeholderText: root.type === "url" ? "https://example.com"
            : root.type === "app" ? "firefox or org.gnome.Nautilus"
            : root.type === "file" ? "~/notes.md or /etc/hosts"
            : "any shell command"
          onActiveFocusChanged: root.focusField = activeFocus ? 1 : -1
        }

        // Typing a path by hand is how a bookmark works forever, so the field
        // above is never replaced or made read-only by this. The two pickers
        // are a shortcut for the first time and for paths you have forgotten;
        // both fill the same field, and either is optional.
        RowLayout {
          Layout.fillWidth: true
          Layout.topMargin: Style.space(2)
          spacing: Style.space(6)
          visible: root.type === "file"

          Button {
            id: browseFileButton
            text: "File…"
            onClicked: filePicker.open()
          }

          Button {
            id: browseFolderButton
            text: "Folder…"
            onClicked: folderPicker.open()
          }

          Item { Layout.fillWidth: true }
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
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) { root.fieldKey(event) }
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

    // ---- pickers
    // The form is a child of a PanelWindow, and a dialog opened from one has to
    // be a child of the form rather than of the window: that is what gives it a
    // real parent to sit against. `open()` is a method call here, not an
    // assignment — `open` is a read-only property, and setting it does nothing
    // but log a TypeError.

    function acceptPath(chosen) {
      var text = String(chosen === undefined || chosen === null ? "" : chosen).trim()
      if (text === "") return
      targetField.text = text
      targetError.visible = false
      targetField.forceActiveFocus()
      focusField = 1
    }

    FileDialog {
      id: filePicker
      title: "Choose a file"
      fileMode: FileDialog.OpenFile
      onAccepted: root.acceptPath(selectedFile)
    }

    FolderDialog {
      id: folderPicker
      title: "Choose a folder"
      // A folder picker answers with a directory URL. Stripping the scheme
      // rather than storing the URL keeps the target in the one form the model
      // accepts and the one xdg-open is given at launch, so "file:///home/bo"
      // can never reach the file rule and be silently dropped on save.
      onAccepted: root.acceptPath(String(selectedFolder).replace(/^file:\/\//, ""))
    }
  }
}
