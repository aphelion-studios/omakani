import QtQuick
import QtQuick.Controls
import qs.Commons
import "Kana.js" as Kana
import "Answer.js" as Answer

// One prompt of a lesson quiz or a review: the type-coloured header, the
// "<Type> <Meaning|Reading>" bar, and the answer field that turns green /
// red on submit. Matches the website's keys -- Enter submits then advances,
// f reveals item info, p plays audio -- and its romaji->kana field.
//
// The engine (lesson flow / review engine) drives it: set `subject`,
// `studyMaterial`, `questionType`, `progress`; listen for answered(correct)
// and advance(). It does NOT talk to the API or POST anything.
FocusScope {
  id: quiz

  property var subject: null
  property var studyMaterial: null
  property string questionType: "meaning"   // "meaning" | "reading"
  property var service: null
  property real progress: 0                  // 0..1 session position

  property color pageBg: Color.background
  property color fg: Color.foreground
  property string fontFamily: Style.font.family
  property string jpFamily: "Noto Sans CJK JP"
  property color radicalColor: "#00a1f1"
  property color kanjiColor: "#f100a1"
  property color vocabColor: "#a100f1"

  readonly property color okColor: "#93c01f"
  readonly property color noColor: "#e64a3b"

  // "input" -> "correct" | "wrong" ; Enter from a settled phase advances
  property string phase: "input"
  property string nudge: ""
  property bool infoOpen: false
  property bool _converting: false
  // the field's onAccepted and the scope's Return handler can both see one
  // keypress; this collapses them.
  property double _lastSubmit: 0

  signal answered(bool correct)
  signal advance()
  signal wrapUp()
  signal infoRequested()

  Component.onCompleted: Answer.useKana(Kana)
  onSubjectChanged: reset()

  readonly property string kind: subject ? String(subject.object || "") : ""
  readonly property var d: (subject && subject.data) || ({})
  readonly property string effectiveType: kind === "radical" ? "meaning" : questionType
  readonly property color typeColor: kind === "radical" ? radicalColor
    : kind === "kanji" ? kanjiColor : vocabColor
  readonly property string typeWord: kind === "radical" ? "Radical"
    : kind === "kanji" ? "Kanji" : "Vocabulary"
  readonly property string promptWord: kind === "radical" ? "Name"
    : effectiveType === "reading" ? "Reading" : "Meaning"
  readonly property bool readingPrompt: effectiveType === "reading"

  function reset() {
    phase = "input"
    nudge = ""
    infoOpen = false
    field.text = ""
    Qt.callLater(field.forceActiveFocus)
  }

  function submit() {
    var now = Date.now()
    if (now - _lastSubmit < 140) return
    _lastSubmit = now

    if (phase === "correct" || phase === "wrong") { quiz.advance(); return }
    if (field.text.replace(/\s/g, "") === "") { shake.restart(); return }

    if (readingPrompt && !Kana.isKana(field.text.replace(/\s/g, ""))) {
      _converting = true
      field.text = Kana.toKana(field.text)
      _converting = false
    }
    var res = Answer.check(subject, studyMaterial, effectiveType, field.text)
    if (res.status === "correct") {
      phase = "correct"
      quiz.answered(true)
      Qt.callLater(quiz.forceActiveFocus)
    } else if (res.status === "incorrect") {
      phase = "wrong"
      quiz.answered(false)
      shake.restart()
      Qt.callLater(quiz.forceActiveFocus)
    } else {
      nudge = res.reason || "Try again"
      shake.restart()
      nudgeTimer.restart()
    }
  }

  // test / automation hook: fill the field and submit
  function typeAndSubmit(text) {
    field.text = String(text)
    _lastSubmit = 0
    submit()
  }

  function playAudio() {
    if (service && (kind === "vocabulary" || kind === "kana_vocabulary") && subject && subject.id)
      service.playAudio(subject.id, "random")
  }

  Keys.onPressed: function (e) {
    if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { submit(); e.accepted = true }
    else if (e.key === Qt.Key_Escape && infoOpen) { infoOpen = false; e.accepted = true }
  }

  // f / p work once the answer is in -- as window shortcuts so they fire
  // regardless of which child holds focus. Disabled during input (you're
  // typing) so they don't eat a literal f / p.
  Shortcut {
    sequences: ["f"]
    enabled: quiz.visible && quiz.phase !== "input" && !quiz.infoOpen
    onActivated: { quiz.infoOpen = true; quiz.infoRequested() }
  }
  Shortcut {
    sequences: ["p"]
    enabled: quiz.visible && quiz.phase !== "input"
    onActivated: quiz.playAudio()
  }

  Timer { id: nudgeTimer; interval: 1600; onTriggered: quiz.nudge = "" }

  Rectangle {
    anchors.fill: parent
    color: quiz.pageBg

    // ---- thin session-progress bar, dead top ----
    Rectangle {
      id: progressBar
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: Style.space(3)
      color: Qt.rgba(quiz.fg.r, quiz.fg.g, quiz.fg.b, 0.12)
      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: parent.width * Math.max(0, Math.min(1, quiz.progress))
        color: "#ffffff"
        Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
      }
    }

    // ---- type-coloured header ----
    Rectangle {
      id: header
      anchors.top: progressBar.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: Math.round(parent.height * 0.34)
      color: quiz.typeColor

      Column {
        anchors.centerIn: parent
        spacing: Style.space(6)
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: quiz.d.characters || ""
          color: "white"
          font.family: quiz.jpFamily
          font.pixelSize: Math.min(header.height * 0.6, Style.font.displayLarge * 3)
          font.bold: true
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: quiz.typeWord + "  ·  Level " + (quiz.d.level || "?")
          color: Qt.rgba(1, 1, 1, 0.82)
          font.family: quiz.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }

    // ---- prompt-type bar ----
    Rectangle {
      id: promptBar
      anchors.top: header.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: Style.space(40)
      color: quiz.readingPrompt
        ? Qt.rgba(0, 0, 0, 0.55)
        : Qt.rgba(1, 1, 1, 0.92)
      Text {
        anchors.centerIn: parent
        text: quiz.typeWord + "  " + quiz.promptWord
        color: quiz.readingPrompt ? "#ffffff" : "#1a1a1a"
        font.family: quiz.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }
    }

    // ---- answer field ----
    Item {
      id: fieldWrap
      anchors.top: promptBar.bottom
      anchors.topMargin: Style.space(28)
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(parent.width - Style.space(64), Style.space(520))
      height: Style.space(52)

      property real shakeX: 0
      transform: Translate { x: fieldWrap.shakeX }

      Rectangle {
        anchors.fill: parent
        radius: Style.space(6)
        color: quiz.phase === "correct" ? quiz.okColor
          : quiz.phase === "wrong" ? quiz.noColor
          : "#ffffff"
        Behavior on color { ColorAnimation { duration: 140 } }

        TextField {
          id: field
          anchors.fill: parent
          anchors.rightMargin: Style.space(46)
          focus: quiz.phase === "input"
          background: Rectangle { color: "transparent" }
          color: quiz.phase === "input" ? "#141414" : "#ffffff"
          font.family: quiz.readingPrompt ? quiz.jpFamily : quiz.fontFamily
          font.pixelSize: Style.font.title
          horizontalAlignment: TextInput.AlignHCenter
          verticalAlignment: TextInput.AlignVCenter
          readOnly: quiz.phase !== "input"
          placeholderText: quiz.phase !== "input" ? ""
            : quiz.readingPrompt ? "答え" : "Your Response"
          placeholderTextColor: "#9a9a9a"
          onAccepted: quiz.submit()
          onTextChanged: {
            if (quiz._converting || !quiz.readingPrompt || quiz.phase !== "input") return
            var raw = field.text
            var loneN = /[^n]n$|^n$/i.test(raw)
            var head = loneN ? raw.slice(0, -1) : raw
            var converted = Kana.toKana(head) + (loneN ? raw.slice(-1) : "")
            if (converted !== raw) {
              quiz._converting = true
              var atEnd = field.cursorPosition >= raw.length
              field.text = converted
              if (atEnd) field.cursorPosition = converted.length
              quiz._converting = false
            }
          }
        }

        // submit chevron
        Rectangle {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.rightMargin: Style.space(6)
          width: Style.space(38)
          height: Style.space(38)
          radius: Style.space(5)
          color: chevHover.containsMouse ? Qt.rgba(0, 0, 0, 0.12) : "transparent"
          Text {
            anchors.centerIn: parent
            text: "›"
            color: quiz.phase === "input" ? "#141414" : "#ffffff"
            font.family: quiz.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }
          MouseArea {
            id: chevHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: quiz.submit()
          }
        }
      }

      SequentialAnimation {
        id: shake
        loops: 2
        NumberAnimation { target: fieldWrap; property: "shakeX"; to: -7; duration: 45 }
        NumberAnimation { target: fieldWrap; property: "shakeX"; to: 7; duration: 45 }
        NumberAnimation { target: fieldWrap; property: "shakeX"; to: 0; duration: 45 }
      }
    }

    // ---- nudge line ----
    Text {
      anchors.top: fieldWrap.bottom
      anchors.topMargin: Style.space(10)
      anchors.horizontalCenter: parent.horizontalCenter
      visible: quiz.nudge !== ""
      text: quiz.nudge
      color: "#e6c14a"
      font.family: quiz.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    // ---- settled hint ----
    Text {
      anchors.top: fieldWrap.bottom
      anchors.topMargin: Style.space(10)
      anchors.horizontalCenter: parent.horizontalCenter
      visible: quiz.phase !== "input" && quiz.nudge === ""
      text: quiz.phase === "correct"
        ? "Enter to continue   ·   f  item info   ·   p  audio"
        : "Enter to continue   ·   f  see why"
      color: Qt.darker(quiz.fg, 1.5)
      font.family: quiz.fontFamily
      font.pixelSize: Style.font.caption
    }

    // ---- toolbar ----
    Row {
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(18)
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(14)

      Repeater {
        model: [
          { g: "󰔟", act: "wrap", tip: "Wrap up" },
          { g: "󰋼", act: "info", tip: "Item info (f)" },
          { g: "󰕾", act: "audio", tip: "Audio (p)", vocab: true }
        ]
        delegate: Rectangle {
          visible: !modelData.vocab || quiz.kind === "vocabulary" || quiz.kind === "kana_vocabulary"
          width: Style.space(38)
          height: Style.space(38)
          radius: width / 2
          color: tbHover.containsMouse
            ? Qt.rgba(quiz.fg.r, quiz.fg.g, quiz.fg.b, 0.14) : "transparent"
          border.width: 1
          border.color: Qt.rgba(quiz.fg.r, quiz.fg.g, quiz.fg.b, 0.2)
          Text {
            anchors.centerIn: parent
            text: modelData.g
            color: quiz.fg
            font.family: Style.bar.iconFont ? quiz.fontFamily : quiz.fontFamily
            font.pixelSize: Style.font.body
          }
          MouseArea {
            id: tbHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (modelData.act === "wrap") quiz.wrapUp()
              else if (modelData.act === "info") { quiz.infoOpen = !quiz.infoOpen; quiz.infoRequested() }
              else if (modelData.act === "audio") quiz.playAudio()
            }
          }
        }
      }
    }

    // ---- item info (f) ----
    Rectangle {
      anchors.fill: parent
      visible: quiz.infoOpen
      color: quiz.pageBg
      z: 20

      SubjectPage {
        id: infoPage
        anchors.fill: parent
        anchors.topMargin: Style.space(6)
        overlayMode: true
        subject: quiz.subject
        service: quiz.service
        pageBg: quiz.pageBg
        fg: quiz.fg
        fontFamily: quiz.fontFamily
        jpFamily: quiz.jpFamily
        radicalColor: quiz.radicalColor
        kanjiColor: quiz.kanjiColor
        vocabColor: quiz.vocabColor
        onVisibleChanged: if (visible) Qt.callLater(focusPage)
        onCloseRequested: quiz.infoOpen = false
      }

      Text {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: Style.space(12)
        text: "f / Esc  close"
        color: Qt.darker(quiz.fg, 1.5)
        font.family: quiz.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  onInfoOpenChanged: if (!infoOpen) Qt.callLater(quiz.forceActiveFocus)
}
