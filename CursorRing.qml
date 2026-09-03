import QtQuick
import qs.Commons

// A white keyboard-focus ring with a single hairline just OUTSIDE the white
// band, so the ring reads whether it sits on a light theme accent, a vivid
// pink/blue queue button, or the dark panel -- and against a pale page edge.
//
// The hairline IS `ringColor` -- callers pass the element's *highlighted*
// colour (a queue button's lit fill, a chip's cursored tint), so the ring
// frames the white band in exactly the shade the focused element is wearing.
Item {
  id: cring

  property real ringRadius: Style.space(6)
  property real band: 2
  property color ringColor: Color.accent

  Rectangle {   // the outer hairline -- the element's own highlighted colour
    anchors.fill: parent
    radius: cring.ringRadius
    color: "transparent"
    border.width: 1
    border.color: cring.ringColor
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
