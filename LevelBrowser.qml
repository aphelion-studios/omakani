import QtQuick
import qs.Commons

// The level browser: every subject on one level as a grid of chips,
// radicals then kanji then vocabulary. "[" / "]" step levels; the arrow
// keys or h/j/k/l move the cursor; Enter opens the subject page.
Item {
  id: browser

  property var service: null
  property int level: 1
  property color fg: Color.foreground
  property color pageBg: Color.background
  property string fontFamily: Style.font.family
  property string jpFamily: "Noto Sans CJK JP"
  property color radicalColor: "#00a1f1"
  property color kanjiColor: "#f100a1"
  property color vocabColor: "#a100f1"

  signal openSubject(int subjectId)
  signal changeLevel(int newLevel)

  readonly property var rows: (service && service.browseData
    && Number(service.browseData.level) === level)
    ? (service.browseData.subjects || []) : []
  readonly property bool loading: service ? service.browseBusy : false

  function countOf(kind) {
    return rows.filter(function (r) {
      return kind === "vocabulary"
        ? (r.object === "vocabulary" || r.object === "kana_vocabulary")
        : r.object === kind
    }).length
  }

  function focusGrid() { grid.forceActiveFocus() }

  Column {
    anchors.fill: parent
    anchors.margins: Style.space(24)
    spacing: Style.space(16)

    // ---- level header ----
    Row {
      width: parent.width
      spacing: Style.space(14)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "‹"
        color: browser.level > 1 ? browser.fg : Qt.darker(browser.fg, 2)
        font.family: browser.fontFamily
        font.pixelSize: Style.font.heading
        MouseArea {
          anchors.fill: parent; anchors.margins: -Style.space(6)
          cursorShape: Qt.PointingHandCursor
          onClicked: if (browser.level > 1) browser.changeLevel(browser.level - 1)
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "Level " + browser.level
        color: browser.fg
        font.family: browser.fontFamily
        font.pixelSize: Style.font.heading
        font.bold: true
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "›"
        color: browser.level < 60 ? browser.fg : Qt.darker(browser.fg, 2)
        font.family: browser.fontFamily
        font.pixelSize: Style.font.heading
        MouseArea {
          anchors.fill: parent; anchors.margins: -Style.space(6)
          cursorShape: Qt.PointingHandCursor
          onClicked: if (browser.level < 60) browser.changeLevel(browser.level + 1)
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: browser.loading ? "loading…"
          : browser.countOf("radical") + " radicals   "
            + browser.countOf("kanji") + " kanji   "
            + browser.countOf("vocabulary") + " vocabulary"
        color: Qt.darker(browser.fg, 1.6)
        font.family: browser.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    // ---- grid ----
    GridView {
      id: grid
      width: parent.width
      height: parent.height - y
      clip: true
      focus: true
      cellWidth: Math.floor(width / Math.max(1, Math.floor(width / Style.space(190))))
      cellHeight: Style.space(46)
      model: browser.rows
      currentIndex: 0
      keyNavigationEnabled: true
      keyNavigationWraps: false
      boundsBehavior: Flickable.StopAtBounds

      Keys.onPressed: function (e) {
        if (e.text === "h") { moveCurrentIndexLeft(); e.accepted = true }
        else if (e.text === "l") { moveCurrentIndexRight(); e.accepted = true }
        else if (e.text === "j") { moveCurrentIndexDown(); e.accepted = true }
        else if (e.text === "k") { moveCurrentIndexUp(); e.accepted = true }
        else if (e.text === "[") { if (browser.level > 1) browser.changeLevel(browser.level - 1); e.accepted = true }
        else if (e.text === "]") { if (browser.level < 60) browser.changeLevel(browser.level + 1); e.accepted = true }
        else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
          if (currentIndex >= 0 && currentIndex < browser.rows.length)
            browser.openSubject(browser.rows[currentIndex].id)
          e.accepted = true
        }
      }

      delegate: Item {
        width: grid.cellWidth
        height: grid.cellHeight

        SubjectChip {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - Style.space(8)
          subjectId: modelData.id
          object: modelData.object
          characters: modelData.characters || ""
          meaning: modelData.meaning || ""
          cursored: GridView.isCurrentItem && grid.activeFocus
          fontFamily: browser.fontFamily
          jpFamily: browser.jpFamily
          fg: browser.fg
          radicalColor: browser.radicalColor
          kanjiColor: browser.kanjiColor
          vocabColor: browser.vocabColor
          onActivated: {
            grid.currentIndex = index
            browser.openSubject(modelData.id)
          }
        }
      }

      Text {
        anchors.centerIn: parent
        visible: browser.rows.length === 0
        text: browser.loading ? "Loading level " + browser.level + "…"
          : "Nothing on level " + browser.level + " yet."
        color: Qt.darker(browser.fg, 1.6)
        font.family: browser.fontFamily
        font.pixelSize: Style.font.body
      }
    }
  }
}
