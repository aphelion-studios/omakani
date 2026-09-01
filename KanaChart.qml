import QtQuick
import qs.Commons

// A read-only hiragana reference, opened with the ひ toolbar button during a
// review (or lesson). Three blocks -- gojūon, dakuten / handakuten, yōon --
// each cell showing the kana over its romaji. Purely a lookup aid: it never
// types anything, unlike the website's on-screen kana keyboard.
//
// j / k (or the arrows) scroll; Esc / ひ / f close.
FocusScope {
  id: chart

  property color pageBg: Color.background
  property color fg: Color.foreground
  property string fontFamily: Style.font.family
  property string jpFamily: Qt.fontFamilies().indexOf("Noto Sans JP") >= 0
    ? "Noto Sans JP" : "Noto Sans CJK JP"

  signal closeRequested()

  // "" cells are gaps in the grid (や row, わ row, ん)
  readonly property var gojuon: [
    ["あ","a"],  ["い","i"],  ["う","u"],   ["え","e"],  ["お","o"],
    ["か","ka"], ["き","ki"], ["く","ku"],  ["け","ke"], ["こ","ko"],
    ["さ","sa"], ["し","shi"],["す","su"],  ["せ","se"], ["そ","so"],
    ["た","ta"], ["ち","chi"],["つ","tsu"], ["て","te"], ["と","to"],
    ["な","na"], ["に","ni"], ["ぬ","nu"],  ["ね","ne"], ["の","no"],
    ["は","ha"], ["ひ","hi"], ["ふ","fu"],  ["へ","he"], ["ほ","ho"],
    ["ま","ma"], ["み","mi"], ["む","mu"],  ["め","me"], ["も","mo"],
    ["や","ya"], ["",""],     ["ゆ","yu"],  ["",""],     ["よ","yo"],
    ["ら","ra"], ["り","ri"], ["る","ru"],  ["れ","re"], ["ろ","ro"],
    ["わ","wa"], ["",""],     ["",""],      ["",""],     ["を","wo"],
    ["ん","n"],  ["",""],     ["",""],      ["",""],     ["",""]
  ]
  readonly property var dakuten: [
    ["が","ga"], ["ぎ","gi"], ["ぐ","gu"], ["げ","ge"], ["ご","go"],
    ["ざ","za"], ["じ","ji"], ["ず","zu"], ["ぜ","ze"], ["ぞ","zo"],
    ["だ","da"], ["ぢ","ji"], ["づ","zu"], ["で","de"], ["ど","do"],
    ["ば","ba"], ["び","bi"], ["ぶ","bu"], ["べ","be"], ["ぼ","bo"],
    ["ぱ","pa"], ["ぴ","pi"], ["ぷ","pu"], ["ぺ","pe"], ["ぽ","po"]
  ]
  readonly property var yoon: [
    ["きゃ","kya"],["きゅ","kyu"],["きょ","kyo"],
    ["しゃ","sha"],["しゅ","shu"],["しょ","sho"],
    ["ちゃ","cha"],["ちゅ","chu"],["ちょ","cho"],
    ["にゃ","nya"],["にゅ","nyu"],["にょ","nyo"],
    ["ひゃ","hya"],["ひゅ","hyu"],["ひょ","hyo"],
    ["みゃ","mya"],["みゅ","myu"],["みょ","myo"],
    ["りゃ","rya"],["りゅ","ryu"],["りょ","ryo"],
    ["ぎゃ","gya"],["ぎゅ","gyu"],["ぎょ","gyo"],
    ["じゃ","ja"], ["じゅ","ju"], ["じょ","jo"],
    ["びゃ","bya"],["びゅ","byu"],["びょ","byo"],
    ["ぴゃ","pya"],["ぴゅ","pyu"],["ぴょ","pyo"]
  ]

  component KanaBlock: Column {
    property string label: ""
    property var cells: []
    property int cols: 5
    spacing: Style.space(10)
    Text {
      text: label.toUpperCase()
      color: Qt.darker(chart.fg, 1.65)
      font.family: chart.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
    }
    Grid {
      columns: cols
      spacing: Style.space(6)
      Repeater {
        model: cells
        delegate: Rectangle {
          width: Style.space(58)
          height: Style.space(52)
          radius: Style.space(5)
          readonly property bool empty: !modelData[0]
          color: empty ? "transparent"
            : Qt.rgba(chart.fg.r, chart.fg.g, chart.fg.b, 0.06)
          Column {
            anchors.centerIn: parent
            spacing: Style.space(1)
            visible: !parent.empty
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: modelData[0]
              color: chart.fg
              font.family: chart.jpFamily
              font.pixelSize: Style.font.subtitle
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: modelData[1]
              color: Qt.darker(chart.fg, 1.8)
              font.family: chart.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }

  Keys.enabled: chart.visible
  Keys.onPressed: function (e) {
    var step = Style.space(120)
    if (e.key === Qt.Key_Escape || e.text === "f" || e.text === "ひ") {
      chart.closeRequested(); e.accepted = true
    } else if (e.key === Qt.Key_Down || e.text === "j") {
      flick.contentY = Math.min(Math.max(0, flick.contentHeight - flick.height), flick.contentY + step)
      e.accepted = true
    } else if (e.key === Qt.Key_Up || e.text === "k") {
      flick.contentY = Math.max(0, flick.contentY - step); e.accepted = true
    } else if (e.key === Qt.Key_PageDown || e.key === Qt.Key_Space) {
      flick.contentY = Math.min(Math.max(0, flick.contentHeight - flick.height), flick.contentY + flick.height * 0.9)
      e.accepted = true
    } else if (e.key === Qt.Key_PageUp) {
      flick.contentY = Math.max(0, flick.contentY - flick.height * 0.9); e.accepted = true
    } else {
      e.accepted = true   // don't leak keys back to the quiz card
    }
  }
  onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)

  Rectangle { anchors.fill: parent; color: chart.pageBg }

  // ---- title ----
  Text {
    id: titleText
    anchors.top: parent.top
    anchors.topMargin: Style.space(24)
    anchors.horizontalCenter: parent.horizontalCenter
    text: "Kana Chart"
    color: chart.fg
    font.family: chart.fontFamily
    font.pixelSize: Style.font.heading
    font.bold: true
  }

  Flickable {
    id: flick
    anchors.top: titleText.bottom
    anchors.topMargin: Style.space(18)
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(92)   // clear of the hint + toolbar
    contentWidth: width
    contentHeight: blocks.implicitHeight + Style.space(40)
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: blocks
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(28)

      KanaBlock { label: "Gojūon";               cells: chart.gojuon;  cols: 5 }
      KanaBlock { label: "Dakuten · Handakuten"; cells: chart.dakuten; cols: 5 }
      KanaBlock { label: "Yōon";                 cells: chart.yoon;    cols: 3 }
    }
  }

  // ---- hint ----
  Text {
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(58)
    anchors.horizontalCenter: parent.horizontalCenter
    text: "j / k  scroll   ·   Esc  close"
    color: Qt.darker(chart.fg, 1.9)
    font.family: chart.fontFamily
    font.pixelSize: Style.font.caption
  }
}
