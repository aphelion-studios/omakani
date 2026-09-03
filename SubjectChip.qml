import QtQuick
import qs.Commons

// A clickable pill for a subject: its character(s) in a CJK face tinted by
// type, with the meaning trailing when known. Feed it either an explicit
// object/characters/meaning (level browser, slim data) or a full `resource`
// from the detail cache (component links, which resolve lazily).
//
// Three states, mirroring the website's level page:
//   normal      solid brand colour, white glyph
//   inLessons   unlocked but not started -- a light wash of the brand colour
//               with the brand colour as the glyph
//   locked      hollow, long-dashed brand-colour border, brand-colour glyph
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
  // unlocked but not yet learned -- sits in the lesson queue
  property bool inLessons: false
  readonly property bool lit: cursored || hovered

  property string fontFamily: Style.font.family
  property string jpFamily: "Noto Sans CJK JP"
  property color fg: Color.foreground
  property color radicalColor: "#01a9fd"
  property color kanjiColor: "#fc02a9"
  property color vocabColor: "#a802fd"

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
  // a pale version of the brand colour for the lessons chip -- reads as
  // "light <colour>" on any theme (Qt.lighter desaturates + brightens)
  readonly property color lessonTint: Qt.lighter(tint, 1.8)
  // glyph / meaning ink: white on the solid chip; the brand colour on the
  // hollow (locked) chip; a deeper brand colour on the pale lessons chip
  readonly property color ink: locked ? tint
    : inLessons ? Qt.darker(tint, 1.4)
    : fg

  implicitWidth: row.implicitWidth + Style.space(20)
  implicitHeight: Style.space(34)
  radius: Style.space(5)

  // normal -> solid brand colour; inLessons -> a pale wash of it; locked ->
  // hollow (dashed border painted in the Canvas below). The focus ring, not
  // the fill, marks the current selection.
  color: locked
    ? (lit ? Qt.rgba(tint.r, tint.g, tint.b, 0.10) : "transparent")
    : inLessons
      ? (lit ? Qt.darker(lessonTint, 1.06) : lessonTint)
      : tint
  border.width: cursored ? 2 : (inLessons ? 1 : 0)
  border.color: cursored
    ? Qt.rgba(fg.r, fg.g, fg.b, 0.95)
    : Qt.rgba(tint.r, tint.g, tint.b, 0.35)

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
        ctx.lineWidth = chip.cursored ? 2 : 1.4
        ctx.setLineDash([8, 4])
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

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: chip.glyph !== "" ? chip.glyph
        : (chip.label !== "" ? chip.label : "#" + chip.subjectId)
      color: chip.ink
      font.family: chip.jpFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: chip.glyph !== "" && chip.label !== ""
      text: chip.label
      color: chip.ink
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
