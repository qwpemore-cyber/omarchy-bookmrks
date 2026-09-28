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
  // Editing means replacing a row that is already there. The form opened from a
  // row's menu has a row number too — the one the new row goes after — and is
  // still creating, so this cannot be `editIndex >= 0` any more: that would head
  // the form "Edit bookmark" over an empty form for something that does not
  // exist yet.
  readonly property bool editing: editIndex >= 0 && afterIndex < 0
  readonly property bool opened: modalOpen

  // `type` and `kind` are real state: the placeholder, the buttons and the
  // cycles all read them, and neither has a visible field of its own. The text
  // values are not state here — they live in the fields, and submit() reads the
  // fields directly, so a second copy would only be a copy that can go stale.
  //
  // The id is the exception: it is not typed, it is the identity of the row
  // being edited. Dropping it would make submitted() carry a freshly minted id
  // for an existing bookmark. updateAt currently overwrites it with the stored
  // value, which hides the slip here, but the signal claims to hand over a
  // whole entry and it would stop being one.
  property string kind: "bookmark"
  property string type: "url"
  property string entryId: ""
  // How much the row being edited holds, so a save that would drop it can say
  // so before it happens rather than after.
  property int childCount: 0
  // Only ever sent for a bookmark: the model has no pin on anything else, and
  // the field below is the only place it can be set or cleared.
  property bool pinned: false
  readonly property bool runs: root.kind === "bookmark"
  readonly property bool folders: root.kind === "folder"
  readonly property bool isSection: root.kind === "section"
  readonly property string headline: (root.editing ? "Edit " : "New ") + root.kind

  // Which of the two text fields the keyboard is currently in. The sidebar
  // blocks its own key handling while this is non-negative.
  property int focusField: -1

  signal submitted(int index, string payloadJson)
  // A different signal rather than a flag on `submitted`, because the two cases
  // answer different questions: `submitted` says which row to replace, and this
  // one says which row to put the new thing after. Folding them together would
  // leave the panel reading the modal's memory to work out which it is looking
  // at, and that memory is one line of bookkeeping away from answering the
  // wrong question.
  signal submittedAfter(int row, string payloadJson)
  signal cancelled()

  // "after" is not a fourth kind of row, so it is not part of `kind`. It is a
  // statement about where the new row goes, and the modal is the only thing that
  // knows both halves of that: what was typed, and which row it was opened on.
  property int afterIndex: -1

  // The sidebar keeps this mounted and only toggles `visible`, so switching
  // between the list and the form costs no re-layout.
  property bool modalOpen: false
  visible: modalOpen

  // ---- lifecycle

  function openFor(index, entry) {
    afterIndex = -1
    fillFor(index, entry, entry ? entry.kind : "bookmark", entry ? entry.id : "")
  }

  // "New Bookmark…" and "New Folder…" in a row's menu. The form is empty, because
  // nothing has been typed yet, and it starts on the kind the menu item named —
  // the alternative is a form that opens on a bookmark when what was asked for
  // was a folder, and the field that matters is then the wrong one on screen.
  function openAfter(row, anchorEntry, kind) {
    fillFor(-1, null, kind || "bookmark", "")
    afterIndex = row
  }

  // editIndex and afterIndex are the two questions asked separately, because they
  // are two different questions. "Which row am I replacing" is -1 when the answer
  // is nothing; "which row is this going after" is -1 when the answer is nothing.
  // Deriving one from the other is what made this form head itself "Edit" the
  // first time round, and it is why they are set by the two callers and not
  // guessed at in here.
  function fillFor(index, entry, kind, id) {
    editIndex = index
    modalOpen = true

    var e = entry || {}
    kind = kind || e.kind || "bookmark"
    type = e.type || "url"
    entryId = id || e.id || ""
    childCount = e.childCount || 0
    labelField.text = e.label || ""
    targetField.text = e.target || ""
    iconField.text = e.icon || ""
    pinned = e.pinned === true
    focusField = -1
    kindError.visible = false
    targetError.visible = false

    // Focus after the surface is mounted, otherwise the first click that
    // opened the modal would immediately land in a field. The explicit
    // focusField assignment is load-bearing: reopening the form while the
    // target field still holds focus sends no activeFocusChanged, and the
    // catcher would stay unblocked with the editor silently eating arrows.
    // A folder and a section have no target, so the label is the only field
    // there is and it takes the focus instead.
    Qt.callLater(function() {
      if (root.runs) { targetField.forceActiveFocus(); focusField = 1 }
      else { labelField.forceActiveFocus(); focusField = 0 }
    })
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

  // A folder or a section is nothing but a name, and the model will not invent
  // one: an unnamed folder in a list of named things reads as a mistake.
  function labelProblem() {
    return "A " + root.kind + " needs a name."
  }

  // Changing a folder's kind would take everything inside it with it. The model
  // refuses that save, so the form says why rather than appearing to work.
  function kindProblem() {
    if (root.childCount > 0 && !root.folders)
      return "This folder holds " + root.childCount + (root.childCount === 1 ? " item" : " items")
        + ". Move or delete " + (root.childCount === 1 ? "it" : "them") + " first."
    return ""
  }

  // Validate through the model rather than duplicating its rules here, so a
  // target the model would reject never reaches the saved file.
  function submit() {
    // Refused before validation, so a folder with contents in it is told what
    // is wrong with it and not what is wrong with an empty label.
    var blocked = root.kindProblem()
    if (blocked !== "") {
      kindError.text = blocked
      kindError.visible = true
      return
    }
    kindError.visible = false

    if (!root.runs && String(labelField.text).trim() === "") {
      labelError.visible = true
      labelField.forceActiveFocus()
      focusField = 0
      return
    }
    labelError.visible = false

    var normalized = Model.normalizeNode({
      id: root.entryId,
      kind: root.kind,
      type: root.type,
      label: labelField.text,
      target: targetField.text,
      icon: iconField.text,
      pinned: root.pinned
    })
    if (!normalized) {
      targetError.text = root.targetProblem()
      targetError.visible = true
      targetField.forceActiveFocus()
      focusField = 1
      return
    }
    targetError.visible = false
    // Read before close(): close() is the modal's own business, and a mode flag
    // that only happens to still be true afterwards is a mode flag with a bug in
    // it waiting for the next thing to be added to close().
    var after = root.afterIndex
    close()
    if (after >= 0) submittedAfter(after, JSON.stringify(normalized))
    else submitted(root.editIndex, JSON.stringify(normalized))
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
    // A folder and a section have no type to cycle, so the key that would move
    // through them does nothing rather than changing a field that is not shown.
    if (!root.runs) return
    var types = Model.TYPES
    var at = types.indexOf(root.type)
    if (at === -1) at = 0
    type = types[(at + delta + types.length) % types.length]
  }

  // And the kind is a second axis now, so it gets the other one. Both cycles
  // leave what has been typed alone for the same reason: someone flipping
  // through the options is still deciding, not committing to a rewrite.
  function cycleKind(delta) {
    var kinds = Model.KINDS
    var at = kinds.indexOf(root.kind)
    if (at === -1) at = 0
    kind = kinds[(at + delta + kinds.length) % kinds.length]
    kindError.visible = false
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
      // Up and down step through the types, left and right through the kinds,
      // which is the form's own layout turned on its side.
      onMoveRequested: function(dx, dy) { if (dx !== 0) root.cycleKind(dx); root.cycleType(dy) }
      onActivateRequested: root.submit()
      onCloseRequested: root.cancel()
      // In the list this key deletes the selected bookmark. Here the only
      // destructive action is the form's own, so it steps the kind back
      // instead — and it only ever arrives with no field focused, i.e. before
      // the first click lands in the form.
      onDeleteRequested: root.cycleKind(-1)
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

      // ---- kind
      // What the row will be, which decides which of the fields below mean
      // anything. It sits above the type rather than beside it because the type
      // is a property of a bookmark and has no meaning until a bookmark has
      // been chosen — so this is the question that comes first.
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Text {
          text: "Kind"
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          color: Util.alpha(Color.popups.text, 0.7)
        }

        Item { Layout.fillWidth: true }

        Repeater {
          model: Model.KINDS
          delegate: Button {
            required property string modelData
            required property int index

            readonly property bool isCurrent: root.kind === modelData

            text: modelData
            selected: isCurrent
            hasCursor: isCurrent
            bordered: true
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(9)
            verticalPadding: Style.space(4)
            onClicked: { root.kind = modelData; root.kindError.visible = false }
          }
        }
      }

      // Why a kind change was not taken. Empty and hidden until there is
      // something to say, so the form does not carry a warning into every other
      // edit.
      Text {
        id: kindError
        Layout.fillWidth: true
        visible: false
        wrapMode: Text.WordWrap
        // Explicit, for the reason the panel's own empty state gives: the
        // default gap comes from the font's own metrics and two lines can land
        // on top of each other.
        lineHeight: 1.3
        text: "This folder holds items."
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        color: Color.urgent
      }

      // ---- type
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)
        visible: root.runs

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
          text: root.runs ? "Label" : "Name"
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          color: Util.alpha(Color.popups.text, 0.7)
        }

        TextField {
          id: labelField
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) { root.fieldKey(event) }
          Layout.fillWidth: true
          placeholderText: root.runs ? "shown in the sidebar" : "shown as a heading in the list"
          onActiveFocusChanged: root.focusField = activeFocus ? 0 : -1
        }

        Text {
          id: labelError
          Layout.fillWidth: true
          visible: false
          text: "A name is required."
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Color.urgent
        }
      }

      // ---- target
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(3)
        // A folder and a section have no target: there is nothing to open. The
        // field is hidden rather than disabled, because a greyed-out field is
        // an invitation to wonder why it is grey.
        visible: root.runs

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
          placeholderText: root.folders ? "optional: a folder glyph instead of the default"
            : root.isSection ? "a section is drawn as a heading; it needs no icon"
            : "optional: nerd-font glyph or desktop id"
          onActiveFocusChanged: root.focusField = activeFocus ? 2 : -1
        }
      }

      // ---- pin
      // A pin is what the pinned-only view is made of, so it is set here and
      // nowhere else, and it is only offered for the kind that can carry one.
      RowLayout {
        Layout.fillWidth: true
        visible: root.runs
        spacing: Style.space(7)

        Button {
          text: root.pinned ? "Pinned" : "Pin"
          selected: root.pinned
          hasCursor: root.pinned
          bordered: true
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(9)
          verticalPadding: Style.space(4)
          onClicked: root.pinned = !root.pinned
        }

        Text {
          Layout.fillWidth: true
          Layout.maximumWidth: Style.space(150)
          wrapMode: Text.WordWrap
          lineHeight: 1.3
          maximumLineCount: 2
          elide: Text.ElideRight
          text: "show in the pinned list"
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Util.alpha(Color.popups.text, 0.6)
        }

        Item { Layout.fillWidth: true }
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
