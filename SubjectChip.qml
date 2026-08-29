import QtQuick
import qs.Commons

// A clickable pill for a subject: its character(s) in a CJK face tinted by
// type, with the meaning trailing when known. Feed it either an explicit
// object/characters/meaning (level browser, slim data) or a full `resource`
// from the detail cache (component links, which resolve lazily).
Rectangle {
  id: chip

  property int subjectId: 0
  property var resource: null
  property string object: ""
  property string characters: ""
  property string meaning: ""
  property bool cursored: false
  property bool hovered: false
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
  color: Qt.rgba(tint.r, tint.g, tint.b, lit ? 0.32 : 0.16)
  border.width: cursored ? 2 : 1
  border.color: Qt.rgba(tint.r, tint.g, tint.b, lit ? 1.0 : 0.4)

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

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
      color: Qt.darker(chip.fg, 1.5)
      font.family: chip.fontFamily
      font.pixelSize: Style.font.caption
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
