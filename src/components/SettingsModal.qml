// The settings sheet, opened by the gear button in the panel header.
//
// Read-only for now: no fields, so nothing has to be forwarded from a text
// input, and Enter has nothing to submit. dataPath is handed to it by the
// panel rather than worked out here, so there is one answer to where the
// bookmarks live. Add new settings inside the ColumnLayout below the title.

import QtQuick
import QtQuick.Dialogs
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../BookmarkModel.js" as Model

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
  // Without this the sheet is painted forever. `opened` is only a flag; nothing
  // hides the item, so closing it changes a boolean and leaves a full-panel
  // scrim and card sitting on top of the bookmark list. AddBookmarkModal has
  // this line; this one was written without it, and the panel came up blank.
  visible: modalOpen

  signal closed()
  // The sheet reads the file but never writes it. Export, import and a refresh
  // are three different outcomes and they are kept apart by name, because a
  // signal that said "here are the bookmarks" and quietly meant "replace these
  // bookmarks" is how a settings page deletes a list.
  signal exportRequested(string path)
  signal replaceRequested(var bookmarks)
  signal mergeRequested(var bookmarks)

  // Where the panel keeps the bookmarks. The default repeats the panel's own
  // expression so the sheet is right on its own, and Sidebar overwrites it
  // with root.dataPath so there is one authority, not two that can drift.
  // This used to be Quickshell.dataPath, which is ~/.local/share — a
  // different directory, so the sheet pointed at a file that does not exist.
  // Spelled the same way the panel spells it, so the two cannot drift: the
  // sheet is useful on its own and the panel still overwrites this with its own
  // path, and one authority ends up being one expression rather than a habit.
  readonly property string homeDir: Quickshell.env("HOME")
  property string dataPath: homeDir + "/.config/omarchy/bookmarks.json"
  // Handed in rather than worked out here, so the sheet does not need a Date of
  // its own and the panel stays the one place that knows what day it is.
  property string today: ""
  // The entries a picked file holds, waiting to be merged or used as the whole
  // list. null means nothing has been picked, which is deliberately not the same
  // thing as an empty array: a file with no bookmarks in it is a real answer,
  // and "replace" with it would empty the panel.
  property var pendingImport: null
  // One line saying what an import did, because a sheet that closes over a
  // successful import and shows nothing leaves the user guessing whether it
  // worked -- and the two ways in look identical once the list is rebuilt.
  property string notice: ""

  // The dialogs sit at root level for the same reason the pickers do in the
  // bookmark form. A save dialog is parented to the window that opened it, and
  // a sheet that closes the moment it is dismissed is a parent that can be gone
  // before the platform finished asking where the file should go.
  FileDialog {
    id: saveDialog
    title: "Export bookmarks"
    fileMode: FileDialog.SaveFile
    defaultSuffix: "json"
    nameFilters: ["JSON file (*.json)"]
    // The panel is the one that writes. This only says where to.
    onAccepted: root.exportRequested(selectedFile)
  }

  FileDialog {
    id: openDialog
    title: "Import bookmarks"
    fileMode: FileDialog.OpenFile
    nameFilters: ["JSON file (*.json)"]
    onAccepted: {
      // Quickshell.Io offers one file type, FileView, so reading an arbitrary
      // chosen path means a second view pointed at it. The reload is what makes
      // picking the same file twice work: a path set to the value it already has
      // is not a change, so nothing would be read the second time and the sheet
      // would sit there doing nothing.
      importView.path = selectedFile
      Qt.callLater(function () { importView.reload() })
    }
  }

  FileView {
    id: importView
    // preload stays on because a view with it off does not announce a read it
    // was not asked for, and asking for one on the same tick as the path change
    // is the race this file used to have.
    preload: true
    watchChanges: false
    atomicWrites: false
    printErrors: false
    onLoaded: {
      var raw = text()
      // Anything that is not this plugin's own data file is refused outright:
      // reading it as "zero bookmarks" is how a replace empties the list.
      if (!Model.looksLikeOurFile(raw)) { root.mergeRequested(null); return }
      // Which of the two ways in is a question about what the file means, not
      // about what the user is typing, so it is asked -- as two buttons in this
      // sheet rather than as a dialog on top of it. A confirmation dialog with a
      // destructive option and an Escape key is one keystroke away from
      // replacing a list with nothing, and there is no honest way to label an
      // Escape-to-cancel key that also means the destructive one.
      root.pendingImport = Model.parse(raw).bookmarks
    }
    onLoadFailed: root.mergeRequested(null)
  }

  function open() {
    modalOpen = true
  }

  function close() {
    modalOpen = false
    // A picked file that was never merged or replaced is forgotten. Otherwise
    // the next time the sheet opens it is still asking about a file that was
    // chosen minutes and one restart ago.
    pendingImport = null
    closed()
  }

  function cancel() {
    close()
  }

  // A settings sheet is a read-mostly surface: there is no text field to type
  // into, so the catcher's own Escape is what closes it and nothing has to be
  // forwarded from a field the way the bookmark form has to.
  // Opaque enough to actually hide what is behind it. At 0.72 the panel's own
  // header and rows showed through as faint stray marks inside the sheet,
  // which read as broken glyphs rather than as a dimmed backdrop.
  Rectangle {
    anchors.fill: parent
    color: Util.alpha(Color.background, 0.97)
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

    // How tall one line of body text actually is in the font in use. Measured
    // with TextMetrics because there is no `fontMetrics` attached property on
    // this item type here — binding to it threw a ReferenceError, and the
    // fallback happened to give the right answer, so it looked correct while
    // logging an error twice a second.
    TextMetrics {
      id: bodyMetrics
      font.family: Style.font.family
      font.pixelSize: Style.font.body
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
          font.bold: true
          color: Util.alpha(Color.popups.text, 0.9)
          // Wraps rather than elides: a heading that loses its last word is
          // worse than a heading on two lines, and at 200px wide this one needs
          // 173px of the 156px available.
          wrapMode: Text.WordWrap
          lineHeight: Model.lineHeightFor(Math.round(Style.font.body * 1.25), bodyMetrics.height)
          horizontalAlignment: Text.AlignHCenter
        }

        // A path is one long unbreakable token, so it cannot live inside a
        // wrapped paragraph: it either overflows the card or gets chopped. Its
        // own row, allowed to elide in the middle, keeps both ends readable
        // when the panel is narrow.
        Text {
          Layout.fillWidth: true
          Layout.topMargin: Style.space(4)
          text: root.dataPath
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          color: Util.alpha(Color.popups.text, 0.7)
          elide: Text.ElideMiddle
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          Layout.fillWidth: true
          text: root.notice !== "" ? root.notice
            : "Your bookmarks are kept in that file. Export it to move them, or edit it there."
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          color: Util.alpha(Color.popups.text, 0.7)
          wrapMode: Text.WordWrap
          lineHeight: Model.lineHeightFor(Math.round(Style.font.body * 1.3), bodyMetrics.height)
          horizontalAlignment: Text.AlignHCenter
        }
      }

      // Three actions, in the order somebody actually needs them: get your
      // bookmarks out, put somebody else's in, or just go look at the file.
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(7)

        Button {
          Layout.fillWidth: true
          text: "Export\u2026"
          horizontalPadding: Style.space(18)
          verticalPadding: Style.space(6)
          onClicked: {
            // The suggested name carries the date, so a second export lands
            // beside the first one instead of on top of it.
            saveDialog.selectedFile = Model.exportName(root.homeDir, root.today)
            saveDialog.open()
          }
        }

        Button {
          Layout.fillWidth: true
          text: "Import\u2026"
          horizontalPadding: Style.space(18)
          verticalPadding: Style.space(6)
          onClicked: openDialog.open()
        }

        Button {
          Layout.fillWidth: true
          text: "Reveal bookmarks.json"
          horizontalPadding: Style.space(18)
          verticalPadding: Style.space(6)
          // A text file is a text file, and the fastest way to understand why
          // a bookmark does not launch is to read what it actually says.
          onClicked: Util.execArgv(["xdg-open", root.dataPath])
        }
      }

      // Shown only once a file has been read. Merge is the one that looks
      // chosen because it is the one that cannot lose anything, and "replace"
      // says what it does in its own name rather than in a warning nobody reads.
      ColumnLayout {
        Layout.fillWidth: true
        visible: root.pendingImport !== null
        spacing: Style.space(7)

        PanelSeparator { Layout.fillWidth: true }

        Text {
          Layout.fillWidth: true
          text: root.pendingImport === null ? ""
            : "That file has " + root.pendingImport.length
              + (root.pendingImport.length === 1 ? " bookmark." : " bookmarks.")
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          color: Util.alpha(Color.popups.text, 0.7)
          wrapMode: Text.WordWrap
          lineHeight: Model.lineHeightFor(Math.round(Style.font.body * 1.3), bodyMetrics.height)
          horizontalAlignment: Text.AlignHCenter
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(7)

          Button {
            Layout.fillWidth: true
            text: "Cancel"
            onClicked: root.pendingImport = null
          }

          Button {
            Layout.fillWidth: true
            text: "Replace"
            onClicked: {
              root.replaceRequested(root.pendingImport)
              root.pendingImport = null
            }
          }

          Button {
            Layout.fillWidth: true
            text: "Merge"
            selected: true
            onClicked: {
              root.mergeRequested(root.pendingImport)
              root.pendingImport = null
            }
          }
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
