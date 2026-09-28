// One row in the list: icon, label, target, and the edit/remove buttons that
// appear on hover. A delegate, so its properties ARE required — the view
// rejects a row that does not supply them, which is deliberate. If a row
// renders wrong or the wrong glyph shows, this is the file.

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "../BookmarkModel.js" as Model

// One bookmark row. The list delegate supplies the data roles; this component
// owns only how a row looks and which hover actions it exposes.
//
// The row is a single fixed-height line so the list never reflows: the
// edit/remove buttons appear on the hovered (or keyboard-cursored) row and
// the label elides to make room for them.
Item {
  id: root

  // ---- data, supplied by the delegate
  //
  // Plain properties with defaults, deliberately not `required`. A delegate
  // fills a component's required properties from model roles by re-declaring
  // them, and when the component declares the same ones as required the two
  // declarations collide: the roles stop binding and every required property
  // reports "was not initialized". The shell's own delegates declare `required`
  // in the delegate alone, for this reason. The delegate in Sidebar.qml is
  // where the model roles and their required-ness belong.
  //
  // `index` is not here at all: a delegate already has the row index, and
  // declaring one in the component would shadow the context property the
  // delegate's handlers read.
  property string entryId: ""
  property string kind: "bookmark"
  property string type: ""
  property string label: ""
  property string target: ""
  property string icon: ""
  // A resolved file:// URL for a desktop-icon id, or "" when there is no
  // icon to draw (see Sidebar.qml's icon lookup).
  property string iconSource: ""

  // The tree's shape, supplied by the delegate. `depth` is how many folders
  // deep this row sits, `hasChildren` and `collapsed` say whether the folder
  // glyph is a door that opens something, and `pinned` marks the rows the
  // pinned-only view is built from.
  property int depth: 0
  property bool hasChildren: false
  property bool collapsed: false
  property bool pinned: false

  // Set by the delegate so the mouse and the keyboard agree on which row is
  // current. Never read containsMouse here: the panel owns that state.
  property bool hasCursor: false

  signal activated()
  signal editRequested()
  signal removeRequested()
  // Raised by a right press on the row, carrying the point in this row's own
  // coordinates. The row sends no row number: the panel is the only thing that
  // can turn an id into a row number under the filter and collapse state the list
  // is actually showing, and sending the number from here would be sending it for
  // a view this row cannot see. The point travels with the signal because
  // QQuickMouseEvent in Qt 6 has no scene coordinates — only x and y relative to
  // the item under the pointer — so the press has to be located here, while this
  // row still knows where it is on screen, or the menu opens at the origin.
  signal menuRequested(real localX, real localY)

  readonly property int rowHeight: Style.space(32)
  readonly property int iconSize: Style.font.iconLarge
  // One step of indentation. Deep enough to read as nesting on a 300px panel,
  // small enough that four levels still leave room for a label.
  readonly property int depthStep: Style.space(11)
  // The whole row slides right by one step per level, so a child is visibly
  // under its folder rather than merely somewhere below it. The glyph column
  // keeps its width, so the icons stay in a line and the labels stagger.
  readonly property int indent: root.depth * root.depthStep
  readonly property bool isFolder: root.kind === "folder"
  readonly property bool isSection: root.kind === "section"
  // Firefox's separator: a line, with no name, no glyph, no target and no
  // children. It is a fourth kind rather than a section with an empty label
  // because a nameless section normalises to "(unnamed)" — a heading that says
  // "(unnamed)" over a rule is not a divider.
  readonly property bool isSeparator: root.kind === "separator"
  // A section is a divider, not a row of things: it has no glyph of its own to
  // press and nothing to run, so it is drawn as a label and a rule. A separator
  // is the same drawing with the label left out.
  readonly property bool divider: root.isSection || root.isSeparator
  // Only a section has a name to draw. The rule under it and the rule that *is*
  // the row are the same one, so a separator is shorter than any other row.
  readonly property bool named: root.divider && !root.isSeparator

  // Which renderer the icon field deserves. Mirrors BookmarkModel.iconKind
  // so a row previews exactly what the model recorded. A folder's icon is
  // resolved from its own fields, so it goes through the kind-aware path.
  readonly property string iconKind: Model.iconKind(root.kind === "bookmark"
    ? { type: root.type, target: root.target, icon: root.icon }
    : { kind: root.kind, label: root.label, icon: root.icon })
  readonly property bool showsAppIcon: root.iconKind === "app" && root.iconSource !== ""

  // A rule is thinner than a row. It has to keep some height so it can be
  // clicked at all — a zero-height row is not reachable with the pointer, and a
  // separator that cannot be right-clicked is a separator nobody can delete.
  readonly property int effectiveHeight: root.isSeparator ? Style.space(17) : rowHeight
  implicitHeight: effectiveHeight
  implicitWidth: 1

  // The row itself is the click target. Declared before the visual children
  // so those are in front of it: the two hover buttons keep their own clicks,
  // and the transparent Text items let presses fall through to this area.
  // The clickable strip stops short of the buttons on the hovered row so a
  // click aimed at "remove" never launches the bookmark.
  //
  // Right-click opens the menu, which is Firefox's split on a Places row, and it
  // is spelled the way the shell spells it everywhere else: both buttons in
  // acceptedButtons, and the button chosen inside onClicked. A MouseArea that
  // does not list Qt.RightButton reports nothing at all for a right press, so
  // the menu cannot be opened by pressing the right button — and nothing in the
  // panel complains, because no handler was ever called.
  MouseArea {
    id: rowClick
    anchors.fill: parent
    anchors.rightMargin: root.hasCursor && !root.isSeparator ? Style.space(52) : 0
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) {
        // A separator has nothing to add to and nothing to run, so it has no
        // menu — the same as Firefox, where a separator row is not a place you
        // can be taken anywhere. Right-click on one does nothing, on purpose,
        // rather than opening a menu of things that are not there.
        if (!root.isSeparator) root.menuRequested(mouse.x, mouse.y)
      } else {
        root.activated()
      }
    }
  }

  CursorSurface {
    anchors.fill: parent
    anchors.leftMargin: Style.space(3)
    anchors.rightMargin: Style.space(3)
    hasCursor: root.hasCursor
    current: root.hasCursor
  }

  RowLayout {
    anchors.fill: parent
    anchors.leftMargin: Style.space(11) + root.indent
    anchors.rightMargin: Style.space(7)
    spacing: Style.space(9)

    // A folder that has something in it says so with a chevron, which is the
    // one thing on the row that tells you pressing it will change the list
    // rather than start something. It sits to the left of the glyph so the
    // glyph column itself stays a straight line down the panel.
    Text {
      Layout.preferredWidth: root.hasChildren && !root.isSeparator ? Style.space(9) : Style.space(0)
      visible: root.hasChildren && !root.isSeparator
      Layout.alignment: Qt.AlignVCenter
      text: Model.chevronFor(root.collapsed)
      textFormat: Text.PlainText
      font.family: Style.font.family
      font.pixelSize: Math.round(Style.font.bodySmall)
      color: Util.alpha(root.hasCursor ? Color.accent : Color.foreground, 0.7)
    }

    Item {
      Layout.preferredWidth: root.isSeparator ? Style.space(0) : Style.space(20)
      Layout.fillHeight: true

      // Nerd-font glyph, used for the type and for any bookmark whose icon
      // is a glyph rather than a desktop id. Sized off the row height so it
      // stays optically centred whatever the theme's spacing scale is.
      // A resolved app icon is opaque enough to sit on top, but a symbolic or
      // transparent one would let the type glyph show through it, so the glyph
      // steps aside only once the image has actually decoded. Until then — and
      // if the file is missing — it is the fallback, which is the point of it.
      Text {
        id: glyph
        anchors.centerIn: parent
        width: parent.width
        height: parent.height
        visible: root.divider === false && (!root.showsAppIcon || iconImage.status !== Image.Ready)
        // The folder's own glyph opens and closes with the folder, so the
        // thing that looks like the control is the control. Every codepoint
        // here was checked against the font's cmap, not assumed: one that the
        // font lacks draws as an empty box and nothing reports it.
        text: root.divider ? "" : Model.kindGlyph({
          kind: root.kind, type: root.type
        }, root.collapsed)
        textFormat: Text.PlainText
        font.family: Style.font.family
        font.pixelSize: Math.round(parent.height * 0.5)
        color: root.hasCursor ? Color.accent : Color.foreground
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }

      Image {
        id: iconImage
        anchors.centerIn: parent
        width: root.iconSize
        height: width
        visible: root.showsAppIcon
        source: root.iconSource
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        cache: true
        // Decode at physical pixels: a HiDPI panel would otherwise upscale
        // a small PNG into a blur.
        sourceSize.width: Math.round(width * Screen.devicePixelRatio)
        sourceSize.height: Math.round(height * Screen.devicePixelRatio)
      }
    }

    // A section is a heading with a rule under it, so its label is smaller and
    // dimmer than a row's and the rule is what separates it from what follows.
    // There is no glyph and no target: pressing one does nothing, on purpose.
    Text {
      id: sectionLabel
      visible: root.named
      text: root.label
      textFormat: Text.PlainText
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      font.capitalization: Font.AllUppercase
      color: Util.alpha(root.hasCursor ? Color.accent : Color.foreground, 0.55)
      elide: Text.ElideRight
      maximumLineCount: 1
    }

    // For a section this is the underline beneath the heading. For a separator
    // it is the whole row, so it is inset the same way the glyph column is and
    // drawn a shade stronger: with nothing else on the line, a rule at 12%
    // opacity reads as a rendering artefact rather than as a decision.
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: 1
      Layout.leftMargin: root.isSeparator ? Style.space(11) + root.indent : 0
      Layout.rightMargin: root.isSeparator ? Style.space(11) : 0
      visible: root.divider
      // It takes the accent when the row cursor is on it, like everything else
      // in this file. A separator has no label to go bold and no glyph to
      // recolour, so the rule is the only thing that can say which row is
      // selected — and which row Delete is about to remove.
      color: Util.alpha(root.hasCursor ? Color.accent : Color.foreground, root.isSeparator ? 0.55 : 0.12)
    }

    Text {
      Layout.fillWidth: true
      visible: !root.divider
      text: root.label
      textFormat: Text.PlainText
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      // A folder is a container, not a thing you run, so it is bold where a
      // bookmark is not: the eye should be able to tell at a glance which rows
      // open something.
      font.bold: root.hasCursor || root.isFolder
      color: root.hasCursor ? Color.accent
        : root.isFolder ? Util.alpha(Color.foreground, 0.92)
        : Color.foreground
      elide: Text.ElideRight
      maximumLineCount: 1
    }

    // Pinned rows say so. A dot rather than a word: the row is already narrow,
    // and the mark has to be readable without stealing the label's space.
    Text {
      Layout.alignment: Qt.AlignVCenter
      visible: root.pinned
      text: Model.KIND_GLYPHS.pin
      textFormat: Text.PlainText
      font.family: Style.font.family
      font.pixelSize: Math.round(Style.font.caption)
      color: Util.alpha(root.hasCursor ? Color.accent : Color.foreground, 0.8)
    }

    Button {
      id: editButton
      Layout.alignment: Qt.AlignVCenter
      visible: root.hasCursor
      text: ""
      // "Edit Text" from the stock Omarchy menu, so the codepoint is one
      // this desktop's Nerd Font is known to carry.
      iconText: String.fromCodePoint(0x0F044)
      tooltipText: "Edit"
      horizontalPadding: Style.space(5)
      verticalPadding: Style.space(5)
      iconSize: Style.font.bodySmall
      onClicked: function(mouse) { root.editRequested() }
    }

    Button {
      id: removeButton
      Layout.alignment: Qt.AlignVCenter
      visible: root.hasCursor
      text: ""
      // "Remove", likewise from the stock menu.
      iconText: String.fromCodePoint(0xF0B4C)
      tooltipText: "Remove"
      horizontalPadding: Style.space(5)
      verticalPadding: Style.space(5)
      iconSize: Style.font.bodySmall
      onClicked: function(mouse) { root.removeRequested() }
    }
  }
}
