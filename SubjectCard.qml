import QtQuick
import qs.Commons

// A titled card on a subject page: uppercase section label above whatever
// content is nested inside it.
Rectangle {
  id: card

  property string title: ""
  property color bg: Color.background
  default property alias content: contentHolder.children

  color: bg
  radius: Style.space(6)
  implicitHeight: inner.implicitHeight + Style.space(32)

  Column {
    id: inner
    x: Style.space(16)
    y: Style.space(16)
    width: parent.width - Style.space(32)
    spacing: Style.space(10)

    Text {
      text: card.title.toUpperCase()
      color: Qt.darker(Color.foreground, 1.65)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
    }

    Item {
      id: contentHolder
      width: parent.width
      implicitHeight: childrenRect.height
    }
  }
}
