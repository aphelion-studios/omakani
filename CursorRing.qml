import QtQuick
import qs.Commons
import "Model.js" as Model

// A white keyboard-focus ring with a single hairline just OUTSIDE the white
// band, so the ring reads whether it sits on a light theme accent, a vivid
// pink/blue queue button, or the dark panel -- and against a pale page edge.
Item {
  id: cring

  property real ringRadius: Style.space(6)
  property real band: 2

  readonly property bool lightUi: Model.lightBg(Color.background)
  // on light themes a plain dark defines the white band against a pale page;
  // on dark themes the panel background does it
  readonly property color hair: lightUi
    ? Qt.rgba(0, 0, 0, 0.35)
    : Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.45)

  Rectangle {   // the outer hairline
    anchors.fill: parent
    radius: cring.ringRadius
    color: "transparent"
    border.width: 1
    border.color: cring.hair
  }
  Rectangle {   // the white band, just inside the hairline
    anchors.fill: parent
    anchors.margins: 1
    radius: Math.max(0, cring.ringRadius - 1)
    color: "transparent"
    border.width: cring.band
    border.color: "#fcfdfd"
  }
}
