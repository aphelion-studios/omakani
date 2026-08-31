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
  property string jpFamily: Qt.fontFamilies().indexOf("Noto Sans JP") >= 0
    ? "Noto Sans JP" : "Noto Sans CJK JP"
  property color radicalColor: "#01a9fd"
  property color kanjiColor: "#fc02a9"
  property color vocabColor: "#a802fd"

  readonly property color okColor: "#93c01f"
  readonly property color noColor: "#fc0234"

  // when set (reviews), item info hides the half you haven't answered yet
  property bool restrictInfo: false
  property bool meaningDone: false
  property bool readingDone: false

  // { text: "Guru", pass: true, up: true } -- the SRS-transition chip shown
  // under the character as a subject finishes (reviews only), or null
  property var srsPill: null

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

  // reviews vs lessons -- kept for anything review-only in the card
  property bool reviewMode: false

  property alias infoPageItem: infoPage

  // drilling into a linked subject (a kanji chip in Composition, etc.) from
  // the item-info overlay -- a small back stack; Esc pops one, then closes
  property var _infoStack: []
  property int _infoPending: 0
  readonly property var _infoSubject: _infoStack.length > 0
    ? _infoStack[_infoStack.length - 1] : quiz.subject
  function _infoDrill(id) {
    if (!service) return
    var res = service.subjectDetail(id)
    if (res) { _infoStack = _infoStack.concat([res]); return }
    _infoPending = parseInt(String(id), 10)
    service.loadDetail([id])
  }
  function _infoBack() {
    if (_infoStack.length > 0) _infoStack = _infoStack.slice(0, -1)
    else infoOpen = false
  }
  Connections {
    target: quiz.service
    enabled: quiz.service !== null && quiz._infoPending > 0
    function onDetailReady(ids) {
      var res = quiz.service.subjectDetail(quiz._infoPending)
      quiz._infoPending = 0
      if (res) quiz._infoStack = quiz._infoStack.concat([res])
    }
  }

  Component.onCompleted: Answer.useKana(Kana)
  // the queue can ask both halves of one subject back to back, so `subject`
  // doesn't change between them -- reset on the question type too, or the
  // card stays stuck green/red on the previous answer
  onSubjectChanged: reset()
  onQuestionTypeChanged: reset()

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
  // audio (p) only makes sense for vocab, and only once the reading is fair
  // game -- on a meaning prompt you haven't reached yet, hearing it is a peek
  readonly property bool isVocab: kind === "vocabulary" || kind === "kana_vocabulary"
  readonly property bool canAudio: !!service && isVocab
    && (readingPrompt || readingDone)

  function reset() {
    phase = "input"
    nudge = ""
    infoOpen = false
    _infoStack = []
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

  // the reading to hear: what was just typed on a reading prompt, else the
  // primary accepted reading -- so 近々 (ちかぢか / きんきん) never plays back
  // the reading you weren't asked
  function playbackReading() {
    if (readingPrompt && phase !== "input") {
      var t = field.text.replace(/\s/g, "")
      if (t !== "") return t
    }
    var rs = (d.readings || []).filter(function (r) { return r.accepted_answer !== false })
    for (var i = 0; i < rs.length; i++) if (rs[i].primary) return rs[i].reading
    return rs.length ? rs[0].reading : ""
  }

  function playAudio() {
    if (canAudio && subject && subject.id)
      service.playAudio(subject.id, "random", playbackReading())
  }

  function openInfo() {
    if (phase === "input") return   // no peeking before you answer
    infoOpen = true
    infoRequested()
  }

  // a focused item still gets key events while hidden -- don't eat keys when
  // the card isn't the visible thing being driven
  Keys.enabled: quiz.visible

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
    onActivated: quiz.openInfo()
  }
  Shortcut {
    sequences: ["p"]
    enabled: quiz.visible && quiz.phase !== "input" && quiz.canAudio
    onActivated: quiz.playAudio()
  }
  // w = wrap up the session (the hourglass), between questions only
  Shortcut {
    sequences: ["w"]
    enabled: quiz.visible && quiz.phase !== "input" && !quiz.infoOpen
    onActivated: quiz.wrapUp()
  }
  // Enter advances from a settled card even if focus drifted (e.g. just
  // closed item info); during input the field's own Enter handles submit
  Shortcut {
    sequences: ["Return", "Enter"]
    enabled: quiz.visible && quiz.phase !== "input" && !quiz.infoOpen
    onActivated: quiz.submit()
  }

  Timer { id: nudgeTimer; interval: 1600; onTriggered: quiz.nudge = "" }

  Rectangle {
    anchors.fill: parent
    color: quiz.pageBg

    // ---- thin session-progress bar, dead top: a dark rail that fills white
    // left-to-right as the session is cleared, like the website ----
    Rectangle {
      id: progressBar
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: Style.space(4)
      color: Qt.rgba(0, 0, 0, 0.45)
      z: 10
      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: parent.width * Math.max(0, Math.min(1, quiz.progress))
        color: "#fcfdfd"
        Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
      }
    }

    // ---- type-coloured header ----
    Rectangle {
      id: header
      anchors.top: progressBar.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      // WaniKani's review header is fairly shallow -- match it
      height: Math.round(parent.height * 0.26)
      color: quiz.typeColor

      // just the character -- no "Kanji · Level 7" line: the level leaks which
      // of two look-alike subjects (矢 lv3 vs 失 lv7) you're being asked.
      // Nudged up so the SRS chip has room in the gap below.
      Text {
        id: charText
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: -Style.space(4)
        text: quiz.d.characters || ""
        color: "#fcfdfd"
        // WaniKani sets its subject characters at a regular weight (Noto
        // Sans JP); match that rather than bolding.
        font.family: quiz.jpFamily
        font.pixelSize: Math.min(header.height * 0.56, Style.font.displayLarge * 3)
        font.weight: Font.Normal
      }
    }

    // SRS-transition chip as a subject finishes (reviews) -- centred in the
    // gap between the character's visual bottom and the prompt bar; floats,
    // so it never nudges the layout
    Rectangle {
      id: srsChip
      anchors.horizontalCenter: parent.horizontalCenter
      y: {
        // a CJK glyph fills ~the em and sits roughly centred on the text
        // item's centre line; its ink bottom is ~0.46em below that centre
        // (empirically tuned -- ascent-based estimates ran low here). Centre
        // the chip between that and the prompt bar's top edge.
        var glyphBottom = header.y + charText.y + charText.height / 2
                          + charText.font.pixelSize * 0.46
        var barTop = header.y + header.height
        return (glyphBottom + barTop) / 2 - height / 2
      }
      z: 15
      visible: !!quiz.srsPill && quiz.phase === "correct"
      width: pillRow.implicitWidth + Style.space(20)
      height: Style.space(28)
      radius: Style.space(5)
      color: (quiz.srsPill && quiz.srsPill.pass) ? quiz.okColor : quiz.noColor
      Row {
        id: pillRow
        anchors.centerIn: parent
        spacing: Style.space(5)
        Text {
          text: (quiz.srsPill && quiz.srsPill.up) ? "↑" : "↓"
          color: "#fcfdfd"
          font.family: quiz.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        Text {
          text: quiz.srsPill ? quiz.srsPill.text : ""
          color: "#fcfdfd"
          font.family: quiz.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
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
        : "#ebedef"
      // "<Type> <Meaning|Reading>" -- the type in a regular weight, the part
      // you're being tested on in bold, matching the website
      Row {
        anchors.centerIn: parent
        spacing: Style.space(6)
        Text {
          text: quiz.typeWord
          color: quiz.readingPrompt ? "#fcfdfd" : "#1a1a1a"
          font.family: quiz.fontFamily
          font.pixelSize: Style.font.subtitle
          font.weight: Font.Normal
        }
        Text {
          text: quiz.promptWord
          color: quiz.readingPrompt ? "#fcfdfd" : "#1a1a1a"
          font.family: quiz.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }
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
          : "#ebedef"   // a touch dimmer than the white text -- less blinding
        Behavior on color { ColorAnimation { duration: 140 } }

        TextField {
          id: field
          anchors.fill: parent
          // symmetric so the text centres in the whole bar (the chevron
          // floats over the right margin), matching the website
          anchors.leftMargin: Style.space(46)
          anchors.rightMargin: Style.space(46)
          focus: quiz.phase === "input"
          background: Rectangle { color: "transparent" }
          color: quiz.phase === "input" ? "#141414" : "#fcfdfd"
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
            color: quiz.phase === "input" ? "#141414" : "#fcfdfd"
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
      // same order as the toolbar buttons below: wrap, info, audio
      text: quiz.phase === "correct"
        ? ("Enter to continue   ·   w  wrap up   ·   f  item info"
           + (quiz.canAudio ? "   ·   p  audio" : ""))
        : "Enter to continue   ·   w  wrap up   ·   f  see why"
      color: Qt.darker(quiz.fg, 1.5)
      font.family: quiz.fontFamily
      font.pixelSize: Style.font.caption
    }

    // ---- toolbar: grey button row, like the website's ----
    Row {
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(18)
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(2)

      Repeater {
        model: [
          { g: "󰅐", act: "wrap",  show: true,        on: true },
          { g: "󰈈", act: "info",  show: true,        on: quiz.phase !== "input" },
          // the glyph alone (quiet vs loud speaker) signals playback
          { g: (quiz.service && quiz.service.audioPlaying) ? "󰕾" : "󰕿",
            act: "audio", show: quiz.isVocab, on: quiz.canAudio }
        ]
        delegate: Rectangle {
          visible: modelData.show
          width: Style.space(58)
          height: Style.space(34)
          radius: Style.space(4)
          readonly property bool on: modelData.on
          color: !on ? Qt.rgba(quiz.fg.r, quiz.fg.g, quiz.fg.b, 0.05)
            : tbHover.containsMouse ? Qt.rgba(quiz.fg.r, quiz.fg.g, quiz.fg.b, 0.16)
            : Qt.rgba(quiz.fg.r, quiz.fg.g, quiz.fg.b, 0.09)
          border.width: 1
          border.color: Qt.rgba(quiz.fg.r, quiz.fg.g, quiz.fg.b, on ? 0.22 : 0.1)
          Text {
            anchors.centerIn: parent
            text: modelData.g
            color: Qt.rgba(quiz.fg.r, quiz.fg.g, quiz.fg.b, on ? 0.9 : 0.3)
            font.family: quiz.fontFamily
            font.pixelSize: Style.font.body
          }
          MouseArea {
            id: tbHover
            anchors.fill: parent
            hoverEnabled: true
            enabled: parent.on
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (modelData.act === "wrap") quiz.wrapUp()
              else if (modelData.act === "info") quiz.infoOpen ? quiz.infoOpen = false : quiz.openInfo()
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
        // while drilled into a linked subject (a kanji chip, etc.) show it
        // fully -- the review folds only apply to the item you're on
        readonly property bool drilled: quiz._infoStack.length > 0
        // in a review, keep the half you haven't earned yet folded: on a
        // reading question the Meaning pane stays folded until you've cleared
        // meaning this session, and vice versa -- even after a wrong answer
        // (you still haven't done the other half). The half you were just
        // tested on is shown, with the ring on it if you missed.
        reviewFolds: quiz.restrictInfo && !drilled
        hideLevel: quiz.restrictInfo
        collapse: (!quiz.restrictInfo || drilled) ? ""
          : quiz.effectiveType === "reading" ? (quiz.meaningDone ? "" : "meaning")
          : quiz.effectiveType === "meaning" ? (quiz.readingDone ? "" : "reading")
          : ""
        focusSection: (quiz.phase === "wrong" && !drilled) ? quiz.effectiveType : ""
        audioAllowed: !quiz.restrictInfo || quiz.readingDone || drilled
        subject: quiz._infoSubject
        service: quiz.service
        pageBg: quiz.pageBg
        fg: quiz.fg
        fontFamily: quiz.fontFamily
        jpFamily: quiz.jpFamily
        radicalColor: quiz.radicalColor
        kanjiColor: quiz.kanjiColor
        vocabColor: quiz.vocabColor
        navHint: quiz._infoStack.length > 0
          ? "h / j / k / l  navigate   ·   Enter  fold / unfold   ·   Esc  back"
          : "h / j / k / l  navigate   ·   Enter  fold / unfold   ·   Esc  close"
        onVisibleChanged: if (visible) Qt.callLater(focusPage)
        onNavigate: function (id) { quiz._infoDrill(id) }
        onCloseRequested: quiz._infoBack()
      }
    }
  }

  onInfoOpenChanged: {
    if (!infoOpen) { _infoStack = []; Qt.callLater(quiz.forceActiveFocus) }
  }
}
