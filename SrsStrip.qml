import QtQuick
import qs.Commons

// SRS "Guru progress" strip under a chip on the Level Progress page, mirroring
// wanikani.com: once the item is Guru'd it's a solid green bar; on the way
// there it's five segments (rounded outer ends, square middles), one filling
// per Apprentice stage.
//
//   locked / not started  -> hidden (the cell shows a word caption instead)
//   stage 1..4            -> that many of five green
//   stage 5+ (Guru+)      -> one solid green bar
Item {
  id: strip

  property int stage: 0
  property bool locked: false
  property color fg: Color.foreground
  property color passedColor: "#34a553"

  implicitHeight: Style.space(5)

  readonly property bool gurued: stage >= 5
  readonly property real barH: Style.space(4)
  readonly property real endR: Style.space(2)
  readonly property color track: Qt.rgba(fg.r, fg.g, fg.b, 0.14)

  // Guru'd -> one solid bar
  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    height: strip.barH
    radius: height / 2
    visible: strip.gurued
    color: strip.passedColor
  }

  // on the way to Guru -> five segments
  Row {
    width: strip.width
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(3)
    visible: !strip.gurued
    readonly property real segW: (strip.width - 4 * Style.space(3)) / 5
    Repeater {
      model: 5
      delegate: Rectangle {
        width: parent.segW
        height: strip.barH
        topLeftRadius: index === 0 ? strip.endR : 0
        bottomLeftRadius: index === 0 ? strip.endR : 0
        topRightRadius: index === 4 ? strip.endR : 0
        bottomRightRadius: index === 4 ? strip.endR : 0
        color: index < strip.stage ? strip.passedColor : strip.track
      }
    }
  }
}
