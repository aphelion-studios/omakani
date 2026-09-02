import QtQuick
import qs.Commons

// The website's Kana Chart: a docked on-screen kana keyboard for when typing
// isn't an option. Tab across あ..ら + 雑; every key drops its kana into the
// answer field verbatim (no romaji step), Backspace rubs one out.
//
// Pointer- or keyboard-driven: while it's open it holds focus. In the grid
// h/j/k/l move the highlight; k off the top row hops up to the tab strip,
// where h/l switch tab (あ/か/さ/…) and j (or Enter) drops back into the grid.
// Enter/Space inserts, Backspace deletes, / or Esc closes.
// A FocusScope (not a bare Item) so forceActiveFocus() from the host reliably
// routes keys here and the answer field lets go of them.
FocusScope {
  id: kb

  property color fg: Color.foreground
  property string fontFamily: Style.font.family
  property string jpFamily: Qt.fontFamilies().indexOf("Noto Sans JP") >= 0
    ? "Noto Sans JP" : "Noto Sans CJK JP"

  signal kanaPicked(string kana)
  signal backspacePressed()
  signal closeRequested()

  property int tab: 0
  property int selRow: 0
  property int selCol: 0
  // keyboard focus is on the tab strip (k'd up off the top row) rather than
  // the kana grid
  property bool onTabBar: false

  function _reset() { tab = 0; selRow = 0; selCol = 0; onTabBar = false }
  function grabKeys() { kb.forceActiveFocus() }
  onVisibleChanged: {
    if (visible) { _reset(); Qt.callLater(kb.forceActiveFocus) }
  }
  Keys.enabled: kb.visible

  readonly property var tabNames: ["あ", "か", "さ", "た", "な", "は", "ま", "ら", "雑"]

  // per tab: a list of rows, each row a list of [kana, romaji]
  readonly property var pages: [
    // あ
    [[["あ","a"],["い","i"],["う","u"],["え","e"],["お","o"]]],
    // か / が
    [[["か","ka"],["き","ki"],["く","ku"],["け","ke"],["こ","ko"],["きゃ","kya"],["きゅ","kyu"],["きょ","kyo"]],
     [["が","ga"],["ぎ","gi"],["ぐ","gu"],["げ","ge"],["ご","go"],["ぎゃ","gya"],["ぎゅ","gyu"],["ぎょ","gyo"]]],
    // さ / ざ
    [[["さ","sa"],["し","shi"],["す","su"],["せ","se"],["そ","so"],["しゃ","sha"],["しゅ","shu"],["しょ","sho"]],
     [["ざ","za"],["じ","ji"],["ず","zu"],["ぜ","ze"],["ぞ","zo"],["じゃ","ja"],["じゅ","ju"],["じょ","jo"]]],
    // た / だ
    [[["た","ta"],["ち","chi"],["つ","tsu"],["て","te"],["と","to"],["ちゃ","cha"],["ちゅ","chu"],["ちょ","cho"]],
     [["だ","da"],["ぢ","ji"],["づ","zu"],["で","de"],["ど","do"],["ぢゃ","ja"],["ぢゅ","ju"],["ぢょ","jo"]]],
    // な
    [[["な","na"],["に","ni"],["ぬ","nu"],["ね","ne"],["の","no"],["にゃ","nya"],["にゅ","nyu"],["にょ","nyo"]]],
    // は / ば / ぱ
    [[["は","ha"],["ひ","hi"],["ふ","fu"],["へ","he"],["ほ","ho"],["ひゃ","hya"],["ひゅ","hyu"],["ひょ","hyo"]],
     [["ば","ba"],["び","bi"],["ぶ","bu"],["べ","be"],["ぼ","bo"],["びゃ","bya"],["びゅ","byu"],["びょ","byo"]],
     [["ぱ","pa"],["ぴ","pi"],["ぷ","pu"],["ぺ","pe"],["ぽ","po"],["ぴゃ","pya"],["ぴゅ","pyu"],["ぴょ","pyo"]]],
    // ま
    [[["ま","ma"],["み","mi"],["む","mu"],["め","me"],["も","mo"],["みゃ","mya"],["みゅ","myu"],["みょ","myo"]]],
    // ら
    [[["ら","ra"],["り","ri"],["る","ru"],["れ","re"],["ろ","ro"],["りゃ","rya"],["りゅ","ryu"],["りょ","ryo"]]],
    // 雑
    [[["や","ya"],["ゆ","yu"],["よ","yo"],["わ","wa"],["を","wo"],["ん","nn"],["ー","-"],["っ","ltsu"]]]
  ]

  readonly property var page: pages[tab]
  function _rowLen(r) { return (page[r] || []).length }
  function _clampSel() {
    selRow = Math.max(0, Math.min(selRow, page.length - 1))
    selCol = Math.max(0, Math.min(selCol, _rowLen(selRow) - 1))
  }
  function _setTab(t) {
    tab = Math.max(0, Math.min(t, tabNames.length - 1))
    selRow = 0
    selCol = Math.min(selCol, _rowLen(0) - 1)
  }
  function _pick() {
    var cell = (page[selRow] || [])[selCol]
    if (cell) kb.kanaPicked(cell[0])
  }

  implicitWidth: Style.space(780)
  implicitHeight: panel.implicitHeight

  Keys.onPressed: function (e) {
    if (e.key === Qt.Key_Escape || e.key === Qt.Key_Slash) {
      kb.closeRequested(); e.accepted = true; return
    }
    if (e.key === Qt.Key_Backspace) { kb.backspacePressed(); e.accepted = true; return }

    if (kb.onTabBar) {
      if (e.text === "h" || e.key === Qt.Key_Left) { kb._setTab(kb.tab - 1) }
      else if (e.text === "l" || e.key === Qt.Key_Right) { kb._setTab(kb.tab + 1) }
      else if (e.text === "j" || e.key === Qt.Key_Down
               || e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
        kb.onTabBar = false
      }
      e.accepted = true
      return
    }

    if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) {
      kb._pick(); e.accepted = true
    }
    else if (e.text === "j" || e.key === Qt.Key_Down) { kb.selRow += 1; kb._clampSel(); e.accepted = true }
    else if (e.text === "k" || e.key === Qt.Key_Up) {
      if (kb.selRow > 0) { kb.selRow -= 1; kb._clampSel() }
      else kb.onTabBar = true          // up off the top row -> the tab strip
      e.accepted = true
    }
    else if (e.text === "l" || e.key === Qt.Key_Right) {
      if (kb.selCol < kb._rowLen(kb.selRow) - 1) kb.selCol += 1
      e.accepted = true
    }
    else if (e.text === "h" || e.key === Qt.Key_Left) {
      if (kb.selCol > 0) kb.selCol -= 1
      e.accepted = true
    }
    else { e.accepted = true }   // don't leak keys back to the field
  }

  Rectangle {
    id: panel
    width: parent.width
    implicitHeight: tabRow.height + grid.implicitHeight + Style.space(28)
    height: implicitHeight
    radius: Style.space(8)
    color: Qt.rgba(kb.fg.r, kb.fg.g, kb.fg.b, 0.07)
    border.width: 1
    border.color: Qt.rgba(kb.fg.r, kb.fg.g, kb.fg.b, 0.12)

    // ---- tab strip ----
    Row {
      id: tabRow
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      height: Style.space(38)

      Repeater {
        model: kb.tabNames
        delegate: Item {
          width: (tabRow.width - Style.space(96)) / kb.tabNames.length
          height: tabRow.height
          readonly property bool sel: index === kb.tab
          // keyboard ring: the active tab while focus is on the strip
          Rectangle {
            anchors.fill: parent
            anchors.margins: Style.space(2)
            radius: Style.space(4)
            color: "transparent"
            border.width: 2
            border.color: kb.fg
            visible: parent.sel && kb.onTabBar
          }
          Text {
            anchors.centerIn: parent
            text: modelData
            color: parent.sel ? kb.fg : Qt.darker(kb.fg, 1.7)
            font.family: kb.jpFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: parent.sel
          }
          Rectangle {
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - Style.space(10)
            height: 2
            radius: 1
            visible: parent.sel && !kb.onTabBar
            color: kb.fg
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: kb._setTab(index)
          }
        }
      }

      // Backspace, pinned to the right
      Rectangle {
        width: Style.space(96)
        height: Style.space(28)
        anchors.verticalCenter: parent.verticalCenter
        radius: Style.space(4)
        color: bsHover.containsMouse
          ? Qt.rgba(kb.fg.r, kb.fg.g, kb.fg.b, 0.16)
          : Qt.rgba(kb.fg.r, kb.fg.g, kb.fg.b, 0.09)
        border.width: 1
        border.color: Qt.rgba(kb.fg.r, kb.fg.g, kb.fg.b, 0.18)
        Text {
          anchors.centerIn: parent
          text: "⌫  Backspace"
          color: Qt.darker(kb.fg, 1.2)
          font.family: kb.fontFamily
          font.pixelSize: Style.font.caption
        }
        MouseArea {
          id: bsHover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: kb.backspacePressed()
        }
      }
    }

    // ---- kana grid ----
    Column {
      id: grid
      anchors.top: tabRow.bottom
      anchors.topMargin: Style.space(8)
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(6)

      Repeater {
        model: kb.page
        delegate: Row {
          spacing: Style.space(6)
          property var cells: modelData
          property int rowIndex: index
          Repeater {
            model: parent.cells
            delegate: Rectangle {
              readonly property int myRow: parent.rowIndex
              readonly property int myCol: index
              readonly property bool sel: !kb.onTabBar
                && kb.selRow === myRow && kb.selCol === myCol
              width: Style.space(84)
              height: Style.space(50)
              radius: Style.space(5)
              color: sel || kHover.containsMouse
                ? Qt.rgba(kb.fg.r, kb.fg.g, kb.fg.b, 0.2)
                : Qt.rgba(kb.fg.r, kb.fg.g, kb.fg.b, 0.10)
              border.width: sel ? 2 : 1
              border.color: sel
                ? Qt.rgba(kb.fg.r, kb.fg.g, kb.fg.b, 0.75)
                : Qt.rgba(kb.fg.r, kb.fg.g, kb.fg.b, 0.14)
              Column {
                anchors.centerIn: parent
                spacing: Style.space(1)
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: modelData[0]
                  color: kb.fg
                  font.family: kb.jpFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: modelData[1]
                  color: Qt.darker(kb.fg, 1.8)
                  font.family: kb.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
              MouseArea {
                id: kHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  kb.selRow = parent.myRow
                  kb.selCol = parent.myCol
                  kb.kanaPicked(modelData[0])
                }
              }
            }
          }
        }
      }
    }
  }
}
