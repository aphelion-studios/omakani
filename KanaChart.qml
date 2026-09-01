import QtQuick
import qs.Commons

// The website's Kana Chart: a docked on-screen kana keyboard for when typing
// isn't an option. Tab across あ..ら + 雑; every button drops its kana into
// the answer field verbatim (no romaji step), Backspace rubs one out.
// Pointer-driven -- the ひ toolbar button opens and closes it, Esc closes.
Item {
  id: kb

  property color fg: Color.foreground
  property string fontFamily: Style.font.family
  property string jpFamily: Qt.fontFamilies().indexOf("Noto Sans JP") >= 0
    ? "Noto Sans JP" : "Noto Sans CJK JP"

  signal kanaPicked(string kana)
  signal backspacePressed()

  property int tab: 0
  // reset to the あ tab whenever it reopens (matches the website)
  onVisibleChanged: if (visible) tab = 0

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

  implicitWidth: Style.space(780)
  implicitHeight: panel.implicitHeight

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
            visible: parent.sel
            color: kb.fg
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: kb.tab = index
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
          Repeater {
            model: parent.cells
            delegate: Rectangle {
              width: Style.space(84)
              height: Style.space(50)
              radius: Style.space(5)
              color: kHover.containsMouse
                ? Qt.rgba(kb.fg.r, kb.fg.g, kb.fg.b, 0.18)
                : Qt.rgba(kb.fg.r, kb.fg.g, kb.fg.b, 0.10)
              border.width: 1
              border.color: Qt.rgba(kb.fg.r, kb.fg.g, kb.fg.b, 0.14)
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
                onClicked: kb.kanaPicked(modelData[0])
              }
            }
          }
        }
      }
    }
  }
}
