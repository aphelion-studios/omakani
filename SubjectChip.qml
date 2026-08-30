import QtQuick
import qs.Commons

// A clickable pill for a subject: its character(s) in a CJK face tinted by
// type, with the meaning trailing when known. Feed it either an explicit
// object/characters/meaning (level browser, slim data) or a full `resource`
// from the detail cache (component links, which resolve lazily).
//
// `locked` items (not yet unlocked on the account) render hollow with a
// dashed border, the way the website's level page shows them.
Rectangle {
  id: chip

  property int subjectId: 0
  property var resource: null
  property string object: ""
  property string characters: ""
  property string meaning: ""
  property bool cursored: false
  property bool hovered: false
  property bool locked: false
  readonly property bool lit: cursored || hovered

  property string fontFamily: Style.font.family
  property string jpFamily: "Noto Sans CJK JP"
  property color fg: Color.foreground
  property color radicalColor: "#00a1f1"
  property color kanjiColor: "#f100a1"
  property color vocabColor: "#a100f1"

  signal activated()

  readonly property var rdata: resource && resource.data ? resource.data : null
  readonly property string kind: object !== "" ? object
    : (resource ? String(resource.object || "") : "")

  function resourceMeaning() {
    if (!rdata || !rdata.meanings) return ""
    var m = rdata.meanings
    for (var i = 0; i < m.length; i++)
      if (m[i].primary) return m[i].meaning
    return m.length ? m[0].meaning : ""
  }

  readonly property string glyph: characters !== "" ? characters
    : (rdata && rdata.characters ? rdata.characters : "")
  readonly property string label: meaning !== "" ? meaning : resourceMeaning()

  readonly property color tint: {
    if (kind === "radical") return radicalColor
    if (kind === "kanji") return kanjiColor
    if (kind === "vocabulary" || kind === "kana_vocabulary") return vocabColor
    return Qt.darker(fg, 1.5)
  }

  implicitWidth: row.implicitWidth + Style.space(20)
  implicitHeight: Style.space(34)
  radius: Style.space(5)

  color: locked
    ? (lit ? Qt.rgba(tint.r, tint.g, tint.b, 0.10) : "transparent")
    : Qt.rgba(tint.r, tint.g, tint.b, lit ? 0.34 : 0.16)
  // The keyboard cursor gets a bright foreground-coloured ring; hover/normal
  // keep the tint border. Locked items draw their border in the dashed Canvas.
  border.width: cursored ? 2 : (locked ? 0 : 1)
  border.color: cursored
    ? Qt.rgba(fg.r, fg.g, fg.b, 0.95)
    : Qt.rgba(tint.r, tint.g, tint.b, hovered ? 0.9 : 0.4)

  Loader {
    anchors.fill: parent
    active: chip.locked && !chip.cursored
    sourceComponent: Canvas {
      id: dashed
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var a = chip.lit ? 0.95 : 0.5
        ctx.strokeStyle = Qt.rgba(chip.tint.r, chip.tint.g, chip.tint.b, a)
        ctx.lineWidth = chip.cursored ? 2 : 1.3
        ctx.setLineDash([4, 3])
        var r = chip.radius
        var i = ctx.lineWidth / 2
        var w = width - i
        var h = height - i
        ctx.beginPath()
        ctx.moveTo(i + r, i)
        ctx.arcTo(w, i, w, i + r, r)
        ctx.arcTo(w, h, w - r, h, r)
        ctx.arcTo(i, h, i, h - r, r)
        ctx.arcTo(i, i, i + r, i, r)
        ctx.closePath()
        ctx.stroke()
      }
      Component.onCompleted: requestPaint()
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      Connections {
        target: chip
        function onLitChanged() { dashed.requestPaint() }
        function onCursoredChanged() { dashed.requestPaint() }
      }
    }
  }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)
    opacity: chip.locked && !chip.lit ? 0.55 : 1.0

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: chip.glyph !== "" ? chip.glyph
        : (chip.label !== "" ? chip.label : "#" + chip.subjectId)
      color: chip.fg
      font.family: chip.jpFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: chip.glyph !== "" && chip.label !== ""
      text: chip.label
      color: chip.fg
      font.family: chip.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: chip.hovered = true
    onExited: chip.hovered = false
    onClicked: chip.activated()
  }
}
