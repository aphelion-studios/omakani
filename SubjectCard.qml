import QtQuick
import qs.Commons

// A titled card on a subject page: uppercase section label above whatever
// content is nested inside it. When `collapsible`, the title row toggles the
// content -- a review's item info folds the half you're being tested on so
// it can't hand you the answer at a glance, but you can still open it.
Rectangle {
  id: card

  property string title: ""
  property color bg: Color.background
  property bool collapsible: false
  property bool collapsed: false
  default property alias content: contentHolder.children

  readonly property bool folded: collapsible && collapsed

  color: bg
  radius: Style.space(6)
  implicitHeight: folded
    ? headRow.implicitHeight + Style.space(28)
    : headRow.implicitHeight + Style.space(10) + inner.implicitHeight + Style.space(32)

  // ---- header (click toggles when collapsible) ----
  Item {
    id: headRow
    x: Style.space(16)
    y: Style.space(16)
    width: parent.width - Style.space(32)
    implicitHeight: titleText.implicitHeight

    Row {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: card.collapsible
        text: card.collapsed ? "▸" : "▾"
        color: Qt.darker(Color.foreground, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
      Text {
        id: titleText
        anchors.verticalCenter: parent.verticalCenter
        text: card.title.toUpperCase()
        color: Qt.darker(Color.foreground, 1.65)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: card.folded
        text: "— tap to reveal"
        color: Qt.darker(Color.foreground, 2.1)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      anchors.fill: parent
      anchors.margins: -Style.space(8)
      enabled: card.collapsible
      cursorShape: Qt.PointingHandCursor
      onClicked: card.collapsed = !card.collapsed
    }
  }

  // ---- content ----
  Item {
    id: inner
    x: Style.space(16)
    anchors.top: headRow.bottom
    anchors.topMargin: Style.space(10)
    width: parent.width - Style.space(32)
    implicitHeight: childrenRect.height
    visible: !card.folded

    Item {
      id: contentHolder
      width: parent.width
      implicitHeight: childrenRect.height
    }
  }
}
