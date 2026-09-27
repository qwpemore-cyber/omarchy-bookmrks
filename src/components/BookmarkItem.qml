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
  property string type: ""
  property string label: ""
  property string target: ""
  property string icon: ""
  // A resolved file:// URL for a desktop-icon id, or "" when there is no
  // icon to draw (see Sidebar.qml's icon lookup).
  property string iconSource: ""

  // Set by the delegate so the mouse and the keyboard agree on which row is
  // current. Never read containsMouse here: the panel owns that state.
  property bool hasCursor: false

  signal activated()
  signal editRequested()
  signal removeRequested()

  readonly property int rowHeight: Style.space(32)
  readonly property int iconSize: Style.font.iconLarge
  // Which renderer the icon field deserves. Mirrors BookmarkModel.iconKind
  // so a row previews exactly what the model recorded.
  readonly property string iconKind: Model.iconKind({ type: root.type, target: root.target, icon: root.icon })
  readonly property bool showsAppIcon: root.iconKind === "app" && root.iconSource !== ""

  implicitHeight: rowHeight
  implicitWidth: 1

  // The row itself is the click target. Declared before the visual children
  // so those are in front of it: the two hover buttons keep their own clicks,
  // and the transparent Text items let presses fall through to this area.
  // The clickable strip stops short of the buttons on the hovered row so a
  // click aimed at "remove" never launches the bookmark.
  MouseArea {
    id: rowClick
    anchors.fill: parent
    anchors.rightMargin: root.hasCursor ? Style.space(52) : 0
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton
    onClicked: function(mouse) { root.activated() }
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
    anchors.leftMargin: Style.space(11)
    anchors.rightMargin: Style.space(7)
    spacing: Style.space(9)

    Item {
      Layout.preferredWidth: Style.space(20)
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
        visible: !root.showsAppIcon || iconImage.status !== Image.Ready
        text: Model.typeGlyph(root.type)
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

    Text {
      Layout.fillWidth: true
      text: root.label
      textFormat: Text.PlainText
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: root.hasCursor
      color: root.hasCursor ? Color.accent : Color.foreground
      elide: Text.ElideRight
      maximumLineCount: 1
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
