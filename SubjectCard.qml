import QtQuick
import qs.Commons
import "Model.js" as Model

// A titled card on a subject page: uppercase section label above whatever
// content is nested inside it. When `collapsible`, the title row toggles the
// content -- a review's item info folds the half you're being tested on so
// it can't hand you the answer at a glance, but you can still open it. In the
// item-info overlay j/k move a focus ring between cards and h/l fold them.
Rectangle {
  id: card

  property string title: ""
  property color bg: Color.background
  property bool collapsible: false
  property bool navFocused: false
  // subject ids of the chips inside this card, if it's a chip section --
  // lets the item-info overlay's keyboard nav step through them
  property var chipIds: []

  // the parent's reactive default (anti-cheat, section type, ...); a user
  // fold overrides it until `resetToken` changes (e.g. the next subject)
  property bool defaultCollapsed: false
  property int resetToken: 0
  property var _userState: undefined
  readonly property bool collapsed: _userState === undefined ? defaultCollapsed : _userState
  onResetTokenChanged: _userState = undefined

  default property alias content: contentHolder.children
  readonly property bool folded: collapsible && collapsed

  function expand() { if (collapsible) _userState = false }
  function collapse() { if (collapsible) _userState = true }
  function toggle() { if (collapsible) _userState = !collapsed }

  readonly property bool lightUi: Model.lightBg(Color.background)
  // the item-info keyboard focus ring is tinted from this (usually the
  // subject's type colour)
  property color ringColor: Color.accent

  color: bg
  radius: Style.space(6)
  // light themes: a hairline so the card reads against the page (which may be
  // the same colour)
  border.width: lightUi ? 1 : 0
  border.color: Qt.rgba(0, 0, 0, 0.1)
  implicitHeight: folded
    ? headRow.implicitHeight + Style.space(28)
    : headRow.implicitHeight + Style.space(10) + inner.implicitHeight + Style.space(32)

  // keyboard focus ring for the item-info overlay (j/k move it between cards)
  CursorRing {
    anchors.fill: parent
    visible: card.navFocused
    ringRadius: card.radius
    ringColor: card.ringColor
  }

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
    }

    MouseArea {
      anchors.fill: parent
      anchors.margins: -Style.space(8)
      enabled: card.collapsible
      cursorShape: Qt.PointingHandCursor
      onClicked: card.toggle()
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
