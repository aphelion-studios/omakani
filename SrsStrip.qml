import QtQuick
import qs.Commons

// A thin SRS-stage indicator shown under a subject chip on the Level Progress
// page -- the same green "how far along" language wanikani.com uses on its
// level page and that the section bars use here. The fill is deliberately NOT
// the chip's own colour so it reads as a separate progress mark:
//
//   stage 0        locked / not started   -> faint empty track
//   stage 1..4     Apprentice             -> dim ink, growing
//   stage 5..6     Guru                   -> green (counts toward level-up)
//   stage 7..8     Master / Enlightened   -> green, nearly full
//   stage 9        Burned                 -> full, muted gold
Item {
  id: strip

  property int stage: 0
  property bool locked: false
  property color fg: Color.foreground
  property color passedColor: "#93c01f"

  implicitHeight: Style.space(4)

  readonly property bool started: !locked && stage > 0
  readonly property bool passed: stage >= 5
  readonly property bool burned: stage >= 9
  readonly property real frac: {
    if (!started) return 0
    if (burned) return 1
    return Math.max(0.16, Math.min(1, stage / 8))
  }

  Rectangle {
    anchors.verticalCenter: parent.verticalCenter
    width: parent.width
    height: Style.space(3)
    radius: height / 2
    color: Qt.rgba(strip.fg.r, strip.fg.g, strip.fg.b, 0.14)

    Rectangle {
      height: parent.height
      radius: parent.radius
      width: Math.round(parent.width * strip.frac)
      color: strip.burned
        ? "#c8a24a"
        : strip.passed
          ? strip.passedColor
          : Qt.rgba(strip.fg.r, strip.fg.g, strip.fg.b, 0.4)
      Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 160 } }
    }
  }
}
