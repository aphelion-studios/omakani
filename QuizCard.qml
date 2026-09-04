import QtQuick
import QtQuick.Controls
import qs.Commons
import "Kana.js" as Kana
import "Answer.js" as Answer
import "Model.js" as Model

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
  property color radicalColor: "#0098e6"
  property color kanjiColor: "#fc02a9"
  property color vocabColor: "#a802fd"

  readonly property color okColor: "#34a553"
  readonly property color noColor: "#fc0234"
  readonly property bool lightUi: Model.lightBg(Color.background)

  // when set (reviews), item info hides the half you haven't answered yet
  property bool restrictInfo: false
  property bool meaningDone: false
  property bool readingDone: false

  // { text: "Guru", pass: true, up: true } -- the SRS-transition chip shown
  // under the character as a subject finishes (reviews only), or null
  property var srsPill: null

  // "input" -> "correct" | "wrong" ; Enter from a settled phase advances
  property string phase: "input"
  // nudge: transient yellow line under the field (retry reasons, ~1.6s)
  // tip: yellow line that stays up while the card is settled (WK's
  //      "multiple meanings" / "a bit off" hints)
  property string nudge: ""
  property string tip: ""
  property bool infoOpen: false
  // E: item info opened with every hidden section revealed
  property bool _infoRevealAll: false
  // the two reference overlays: Last Answers (reviews only) and Kana Chart
  property bool lastOpen: false
  property bool kanaOpen: false
  readonly property bool anyOverlay: infoOpen || lastOpen || kanaOpen
  // recent finished items, fed by the review engine; [] in Extra Study
  property var answerLog: []
  property bool _converting: false
  // the field's onAccepted and the scope's Return handler can both see one
  // keypress; this collapses them.
  property double _lastSubmit: 0

  signal answered(bool correct, string text)
  signal advance()
  signal wrapUp()
  signal infoRequested()

  // reviews vs lessons -- kept for anything review-only in the card
  property bool reviewMode: false
  // Last Answers ( , ) rides along in reviews and in Extra Study -- both keep a
  // per-session answer log. The primitive lesson quiz leaves it off.
  property bool showLastAnswers: reviewMode
  // settings: show the finish-a-subject SRS chip; auto-play a vocab's reading
  // once you answer its reading right
  property bool srsIndicator: true
  property bool autoplayReading: false

  property alias infoPageItem: infoPage
  readonly property alias fieldText: field.text

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
  // card stays stuck green/red on the previous answer.
  // guard on the id: the `subject` binding re-fires whenever the detail cache
  // re-merges (same record, new object) and an unguarded reset() there wipes
  // what you're typing mid-answer
  property var _lastSubjectId: null
  onSubjectChanged: {
    var sid = (subject && subject.id !== undefined) ? subject.id : null
    if (sid === _lastSubjectId) return
    _lastSubjectId = sid
    reset()
    // pull the component kanji so a component's reading typed for the whole
    // vocab can shake ("we want the vocabulary reading") instead of counting
    // wrong -- cached, so it's ready by the next encounter at worst
    if (service && subject && subject.data
        && (kind === "vocabulary" || kind === "kana_vocabulary")) {
      var cids = subject.data.component_subject_ids || []
      if (cids.length > 0) service.loadDetail(cids)
    }
  }

  // readings of this word's component kanji (minus its own), for Answer.check
  function _componentReadings() {
    if (!isVocab || !service || !subject || !subject.data) return []
    var ids = subject.data.component_subject_ids || []
    var out = []
    for (var i = 0; i < ids.length; i++) {
      var s = service.subjectDetail(ids[i])
      var rs = (s && s.data && s.data.readings) || []
      for (var j = 0; j < rs.length; j++)
        if (rs[j] && rs[j].reading) out.push(rs[j].reading)
    }
    return out
  }
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
    tip = ""
    infoOpen = false
    _infoRevealAll = false
    lastOpen = false
    kanaOpen = false
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
    var res = Answer.check(subject, studyMaterial, effectiveType, field.text,
                           { otherReadings: _componentReadings() })
    var typed = field.text.trim()
    if (res.status === "correct") {
      phase = "correct"
      kanaOpen = false
      tip = settleTip(res)
      quiz.answered(true, typed)
      if (autoplayReading && readingPrompt && canAudio) Qt.callLater(quiz.playAudio)
      Qt.callLater(quiz.forceActiveFocus)
    } else if (res.status === "incorrect") {
      phase = "wrong"
      kanaOpen = false
      tip = "Need help? View the correct "
        + (effectiveType === "reading" ? "reading" : "meaning") + " and mnemonic."
      quiz.answered(false, typed)
      shake.restart()
      Qt.callLater(quiz.forceActiveFocus)
    } else {
      nudge = res.reason || "Try again"
      shake.restart()
      nudgeTimer.restart()
    }
  }

  // the yellow line to leave up after a correct answer, matching the website:
  // a fuzzy-accepted typo, or a heads-up that the item has more than one
  // accepted meaning / reading than the one you gave.
  function settleTip(res) {
    if (res && res.fuzzy)
      return "Your answer was a bit off. Check the " + effectiveType
        + " to make sure you are correct."
    var arr = effectiveType === "reading" ? (d.readings || []) : (d.meanings || [])
    var n = 0
    for (var i = 0; i < arr.length; i++)
      if (arr[i] && arr[i].accepted_answer !== false) n += 1
    if (n > 1)
      return "Did you know this item has multiple possible "
        + (effectiveType === "reading" ? "readings" : "meanings") + "?"
    return ""
  }

  // test / automation hook: fill the field and submit
  function typeAndSubmit(text) {
    field.text = String(text)
    _lastSubmit = 0
    submit()
  }

  // the reading to hear: what you typed only if you got the reading RIGHT
  // (a wrong guess would otherwise play back your mistake, or an unrelated
  // clip), else the primary accepted reading -- so 近々 (ちかぢか / きんきん)
  // plays back a reading that actually exists
  function playbackReading() {
    var rs = (d.readings || []).filter(function (r) { return r.accepted_answer !== false })
    if (readingPrompt && phase === "correct") {
      var t = field.text.replace(/\s/g, "")
      // only if it's genuinely one of the word's readings
      for (var k = 0; k < rs.length; k++) if (rs[k].reading === t) return t
    }
    for (var i = 0; i < rs.length; i++) if (rs[i].primary) return rs[i].reading
    return rs.length ? rs[0].reading : ""
  }

  function playAudio() {
    if (canAudio && subject && subject.id)
      service.playAudio(subject.id, "random", playbackReading())
  }

  // hand keyboard focus to whatever is on top: an open panel drives its own
  // h/j/k/l, otherwise the answer field (during input) or the card itself (so
  // the settled-phase shortcuts keep working). Closing any panel lands you
  // back in the answer field.
  function _refocus() {
    if (kanaOpen) kanaPanel.forceActiveFocus()
    else if (lastOpen) lastPanel.forceActiveFocus()
    else if (infoOpen) infoPage.focusPage()
    else if (phase === "input") field.forceActiveFocus()
    else quiz.forceActiveFocus()
  }

  // the Kana Chart buttons -- drop a kana in at the caret, or rub one out.
  // bypasses the romaji->kana onTextChanged pass (the char is already kana).
  function insertKana(s) {
    if (phase !== "input") return
    var p = field.cursorPosition
    var t = field.text
    _converting = true
    field.text = t.slice(0, p) + s + t.slice(p)
    field.cursorPosition = p + s.length
    _converting = false
    Qt.callLater(_refocus)
  }
  function kanaBackspace() {
    if (phase !== "input" || field.cursorPosition <= 0) return
    var p = field.cursorPosition
    var t = field.text
    _converting = true
    field.text = t.slice(0, p - 1) + t.slice(p)
    field.cursorPosition = p - 1
    _converting = false
    Qt.callLater(_refocus)
  }

  function openInfo(revealAll) {
    if (phase === "input") return   // no peeking before you answer
    lastOpen = false; kanaOpen = false
    _infoRevealAll = (revealAll === true)
    infoOpen = true
    infoRequested()
    Qt.callLater(_refocus)
  }
  function openLast() {
    if (!showLastAnswers) return
    infoOpen = false; kanaOpen = false
    lastOpen = true
    Qt.callLater(_refocus)
  }
  function openKana() {
    infoOpen = false; lastOpen = false
    kanaOpen = true
    Qt.callLater(_refocus)
  }
  function closeOverlays() {
    infoOpen = false; _infoRevealAll = false; lastOpen = false; kanaOpen = false
    Qt.callLater(_refocus)
  }

  // a focused item still gets key events while hidden -- don't eat keys when
  // the card isn't the visible thing being driven
  Keys.enabled: quiz.visible

  Keys.onPressed: function (e) {
    if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { submit(); e.accepted = true }
    else if (e.key === Qt.Key_Escape && hotkeys.open) { hotkeys.close(); e.accepted = true }
    else if (e.key === Qt.Key_Escape && anyOverlay) { closeOverlays(); e.accepted = true }
  }

  // Reviews / lessons follow wanikani.com's hotkeys so the muscle memory
  // carries over (the rest of the plugin keeps the vim-style keys). F / E / J
  // are letters you'd type in a meaning answer, so they only fire once the
  // answer is in; / , ? never appear in an answer, so they're always live.
  Shortcut {
    sequences: ["f"]
    enabled: quiz.visible && quiz.phase !== "input" && !quiz.anyOverlay
    onActivated: quiz.openInfo(false)
  }
  // E is handled inside the item-info overlay (fold / unfold every card) --
  // it does nothing from the review page itself.
  Shortcut {
    sequences: ["j"]
    enabled: quiz.visible && quiz.phase !== "input" && quiz.canAudio && !quiz.anyOverlay
    onActivated: quiz.playAudio()
  }
  // / -- the kana keyboard, an input aid, so only while you're answering
  Shortcut {
    sequences: ["/"]
    enabled: quiz.visible && quiz.phase === "input" && !quiz.infoOpen && !quiz.lastOpen
    onActivated: quiz.kanaOpen ? quiz.closeOverlays() : quiz.openKana()
  }
  // , -- Last Answers (WK's "Last Session Data")
  Shortcut {
    sequences: [","]
    enabled: quiz.visible && quiz.showLastAnswers && !quiz.infoOpen && !quiz.kanaOpen
    onActivated: quiz.lastOpen ? quiz.closeOverlays() : quiz.openLast()
  }
  // ? -- toggle the hotkeys card
  Shortcut {
    sequences: ["?"]
    enabled: quiz.visible
    onActivated: hotkeys.toggle()
  }
  // w -- wrap up the session (the hourglass), between questions only
  Shortcut {
    sequences: ["w"]
    enabled: quiz.visible && quiz.phase !== "input" && !quiz.anyOverlay
    onActivated: quiz.wrapUp()
  }
  // Enter advances from a settled card even if focus drifted (e.g. just
  // closed item info); during input the field's own Enter handles submit
  Shortcut {
    sequences: ["Return", "Enter"]
    enabled: quiz.visible && quiz.phase !== "input" && !quiz.anyOverlay
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
      z: 30   // stays as the top rail even over the item-info overlay
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
        // centre the glyph's ink, not its advance box -- lone narrow radicals
        // (刂 "Knife" etc.) carry lopsided side bearings and drift left
        anchors.horizontalCenterOffset: charTextM.advanceWidth > 0
          ? (charTextM.advanceWidth / 2 - charTextM.tightBoundingRect.x
             - charTextM.tightBoundingRect.width / 2)
          : 0
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
      TextMetrics {
        id: charTextM
        font: charText.font
        text: charText.text
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
        // +nudge: the midpoint still read a touch high
        return (glyphBottom + barTop) / 2 - height / 2 + Style.space(3)
      }
      z: 15
      visible: quiz.srsIndicator && !!quiz.srsPill && quiz.phase === "correct" && !quiz.anyOverlay
      width: pillRow.implicitWidth + Style.space(18)
      height: Style.space(28)
      radius: Style.space(5)
      color: (quiz.srsPill && quiz.srsPill.pass) ? quiz.okColor : quiz.noColor
      Row {
        id: pillRow
        anchors.centerIn: parent
        spacing: Style.space(5)
        // the arrow rides in a white disc, matching the website
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(16)
          height: width
          radius: width / 2
          color: "#fcfdfd"
          Text {
            anchors.centerIn: parent
            text: (quiz.srsPill && quiz.srsPill.up) ? "↑" : "↓"
            color: srsChip.color
            font.family: quiz.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
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
      // reading: a darkened band over the type-colour header (leave it).
      // meaning: a light strip -- on light themes a shade of the theme's own
      // background plus a hairline, so it doesn't melt into a pale page
      color: quiz.readingPrompt
        ? Qt.rgba(0, 0, 0, 0.55)
        : (quiz.lightUi ? Qt.darker(quiz.pageBg, 1.06) : "#ebedef")
      border.width: (!quiz.readingPrompt && quiz.lightUi) ? 1 : 0
      border.color: Qt.rgba(quiz.fg.r, quiz.fg.g, quiz.fg.b, 0.14)
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
          // dark: a touch dimmer than the white text; light: pure white with
          // a thin border, like wanikani.com
          : (quiz.lightUi ? "#ffffff" : "#ebedef")
        border.width: quiz.lightUi && (quiz.phase === "input") ? 1 : 0
        border.color: Qt.rgba(0, 0, 0, 0.18)
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
          onAccepted: quiz.submit()

          // the always-live hotkeys ( / , ? ) -- a focused TextField eats them
          // before a window Shortcut can, so catch them here first
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function (e) {
            if (e.key === Qt.Key_Slash && !quiz.infoOpen && !quiz.lastOpen) {
              quiz.kanaOpen ? quiz.closeOverlays() : quiz.openKana(); e.accepted = true
            } else if (e.key === Qt.Key_Comma && quiz.showLastAnswers
                       && !quiz.infoOpen && !quiz.kanaOpen) {
              quiz.lastOpen ? quiz.closeOverlays() : quiz.openLast(); e.accepted = true
            } else if (e.key === Qt.Key_Question) {
              hotkeys.toggle(); e.accepted = true
            }
          }

          // a plain blinking caret (the default cursor doesn't flash here)
          cursorDelegate: Rectangle {
            width: 2
            color: "#141414"
            visible: field.cursorVisible
            SequentialAnimation on opacity {
              running: field.cursorVisible
              loops: Animation.Infinite
              NumberAnimation { to: 1; duration: 0 }
              PauseAnimation { duration: 520 }
              NumberAnimation { to: 0; duration: 0 }
              PauseAnimation { duration: 520 }
            }
          }
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

        // placeholder behind the cursor -- "答え" on a reading prompt, else
        // "Your Response"; clears the instant you type. (An explicit Text: the
        // TextField's own placeholderText doesn't render under this style.)
        // nudged left so the caret (fixed at the field centre) sits inside
        // the word -- "Your Re|sponse", not "Your R|esponse".
        Text {
          anchors.verticalCenter: parent.verticalCenter
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.horizontalCenterOffset: quiz.readingPrompt ? 0 : -Style.space(4)
          visible: quiz.phase === "input" && field.text === ""
          text: quiz.readingPrompt ? "答え" : "Your Response"
          color: "#9a9a9a"
          font.family: quiz.readingPrompt ? quiz.jpFamily : quiz.fontFamily
          font.pixelSize: Style.font.title
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

    // ---- hint bubble, WK-style: a grey speech bubble with a pointer ----
    // `nudge` is a transient retry reason; `tip` stays up while the card is
    // settled (multiple meanings / readings, "a bit off"). No key-command
    // crib here any more -- the ? hotkeys card covers that.
    Item {
      id: tipBubble
      anchors.top: fieldWrap.bottom
      anchors.topMargin: Style.space(16)
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(quiz.width - Style.space(80), tipText.implicitWidth + Style.space(28))
      height: tipText.implicitHeight + Style.space(16)
      visible: tipText.text !== ""

      readonly property color bubbleColor: "#6e6e6e"

      Rectangle {   // pointer, peeking above the bubble toward the field
        width: Style.space(10); height: width
        rotation: 45
        color: tipBubble.bubbleColor
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: -width / 2
      }
      Rectangle {
        anchors.fill: parent
        radius: Style.space(6)
        color: tipBubble.bubbleColor
      }
      Text {
        id: tipText
        anchors.centerIn: parent
        width: parent.width - Style.space(24)
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: quiz.nudge !== "" ? quiz.nudge : quiz.tip
        color: "#fcfdfd"
        font.family: quiz.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    // ---- the docked kana keyboard + toolbar, pinned to the bottom ----
    // keyboard sits ABOVE the buttons; the panels above anchor to this stack's
    // top so the buttons never sit on top of them
    Column {
      id: bottomStack
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(14)
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(10)
      z: 25

      KanaChart {
        id: kanaPanel
        anchors.horizontalCenter: parent.horizontalCenter
        visible: quiz.kanaOpen && quiz.phase === "input"
        width: Math.min(quiz.width - Style.space(48), Style.space(780))
        fg: quiz.fg
        fontFamily: quiz.fontFamily
        jpFamily: quiz.jpFamily
        onKanaPicked: function (k) { quiz.insertKana(k) }
        onBackspacePressed: quiz.kanaBackspace()
        onCloseRequested: quiz.closeOverlays()
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(2)

        Repeater {
          // website order: wrap · last answers · info · kana · audio
          model: [
            { g: "󰅐", act: "wrap",  show: true,             on: true },
            { g: "󰄬", act: "last",  show: quiz.showLastAnswers, on: quiz.showLastAnswers },
            { g: "󰈈", act: "info",  show: true,             on: quiz.phase !== "input" },
            { g: "ひ", act: "kana",  show: true,             on: quiz.phase === "input" },
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
            readonly property bool active: (modelData.act === "info" && quiz.infoOpen)
              || (modelData.act === "last" && quiz.lastOpen)
              || (modelData.act === "kana" && quiz.kanaOpen)
            color: active ? Qt.rgba(quiz.fg.r, quiz.fg.g, quiz.fg.b, 0.2)
              : !on ? Qt.rgba(quiz.fg.r, quiz.fg.g, quiz.fg.b, 0.05)
              : tbHover.containsMouse ? Qt.rgba(quiz.fg.r, quiz.fg.g, quiz.fg.b, 0.16)
              : Qt.rgba(quiz.fg.r, quiz.fg.g, quiz.fg.b, 0.09)
            border.width: 1
            border.color: Qt.rgba(quiz.fg.r, quiz.fg.g, quiz.fg.b, (on || active) ? 0.22 : 0.1)
            Text {
              anchors.centerIn: parent
              text: modelData.g
              color: Qt.rgba(quiz.fg.r, quiz.fg.g, quiz.fg.b, (on || active) ? 0.9 : 0.3)
              // ひ is a CJK glyph -- the UI font can't draw it
              font.family: modelData.act === "kana" ? quiz.jpFamily : quiz.fontFamily
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
                else if (modelData.act === "info") quiz.infoOpen ? quiz.closeOverlays() : quiz.openInfo()
                else if (modelData.act === "last") quiz.lastOpen ? quiz.closeOverlays() : quiz.openLast()
                else if (modelData.act === "kana") quiz.kanaOpen ? quiz.closeOverlays() : quiz.openKana()
                else if (modelData.act === "audio") quiz.playAudio()
              }
            }
          }
        }
      }
    }

    // ---- item info (f) ----
    // fills down to just above the toolbar so the buttons never sit on top of
    // it; the progress rail / counts float over on their own z
    Rectangle {
      readonly property bool drilled: quiz._infoStack.length > 0
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: bottomStack.top
      anchors.bottomMargin: Style.space(8)
      visible: quiz.infoOpen
      color: quiz.pageBg
      z: 20

      SubjectPage {
        id: infoPage
        anchors.fill: parent
        overlayMode: true
        // the overlay is shorter than a full page -- hand it the quiz header's
        // exact height so its coloured band lines up with the answer view
        bandHeight: header.height
        readonly property bool drilled: quiz._infoStack.length > 0
        // the "<Type> <Meaning|Reading>" bar -- only for the item you're on;
        // a drilled linked subject shows plain "<Type>"
        promptWord: (quiz.restrictInfo && !drilled) ? quiz.promptWord : ""
        // in a review, keep the half you haven't earned yet folded: on a
        // reading question the Meaning pane stays folded until you've cleared
        // meaning this session, and vice versa -- even after a wrong answer
        // (you still haven't done the other half). The half you were just
        // tested on is shown, with the ring on it.
        reviewFolds: quiz.restrictInfo && !drilled && !quiz._infoRevealAll
        hideLevel: quiz.restrictInfo && !quiz._infoRevealAll
        collapse: (!quiz.restrictInfo || drilled || quiz._infoRevealAll) ? ""
          : quiz.effectiveType === "reading" ? (quiz.meaningDone ? "" : "meaning")
          : quiz.effectiveType === "meaning" ? (quiz.readingDone ? "" : "reading")
          : ""
        // land the ring on the half you were just tested on -- whether you
        // missed it or nailed it -- so f drops you straight onto that card
        focusSection: (quiz.phase !== "input" && !drilled) ? quiz.effectiveType : ""
        // also fair game once you've answered a reading prompt -- you've
        // already committed your answer, so hearing it isn't a peek
        audioAllowed: !quiz.restrictInfo || quiz.readingDone || drilled
          || (quiz.readingPrompt && quiz.phase !== "input")
        // pin the item-info's KYOKO / KENICHI / Shift+J to the reading under
        // test, so a multi-reading word doesn't play an unrelated clip.
        // drilled into a linked subject -> let the page use its own primary.
        audioReading: drilled ? "" : quiz.playbackReading()
        subject: quiz._infoSubject
        service: quiz.service
        pageBg: quiz.pageBg
        fg: quiz.fg
        fontFamily: quiz.fontFamily
        jpFamily: quiz.jpFamily
        radicalColor: quiz.radicalColor
        kanjiColor: quiz.kanjiColor
        vocabColor: quiz.vocabColor
        onVisibleChanged: if (visible) Qt.callLater(focusPage)
        onNavigate: function (id) { quiz._infoDrill(id) }
        onCloseRequested: quiz._infoBack()
        onLastAnswersRequested: quiz.openLast()
      }
    }

    // ---- ✓ Last Answers ----
    // fills the answer area only -- the character header + prompt bar stay put
    // above, and it stops above the toolbar
    Rectangle {
      anchors.top: promptBar.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: bottomStack.top
      anchors.bottomMargin: Style.space(8)
      visible: quiz.lastOpen
      color: quiz.pageBg
      z: 21
      LastAnswers {
        id: lastPanel
        anchors.fill: parent
        visible: parent.visible
        log: quiz.answerLog
        service: quiz.service
        pageBg: quiz.pageBg
        fg: quiz.fg
        fontFamily: quiz.fontFamily
        jpFamily: quiz.jpFamily
        radicalColor: quiz.radicalColor
        kanjiColor: quiz.kanjiColor
        vocabColor: quiz.vocabColor
        // j still plays the word's audio here, same anti-peek rule as the quiz
        audioAvailable: quiz.canAudio && quiz.phase !== "input"
        onCloseRequested: quiz.closeOverlays()
        onInfoRequested: quiz.openInfo(false)
        onAudioRequested: quiz.playAudio()
      }
    }

    // ---- keyboard button + hotkeys card (bottom-right, like the website) ----
    HotkeysOverlay {
      id: hotkeys
      anchors.fill: parent
      z: 40
      fg: quiz.fg
      pageBg: quiz.pageBg
      fontFamily: quiz.fontFamily
      rows: {
        var m = [
          { k: "F", d: "Item Info" },
          { k: "j k", d: "Between cards in Item Info" },
          { k: "gg G", d: "First / last card in Item Info" },
          { k: "E", d: "Fold / Unfold All (in Item Info)" },
          { k: "J", d: "Audio Pronunciation" },
          { k: "/", d: "Hiragana IME Chart" }
        ]
        if (quiz.showLastAnswers) m.push({ k: ",", d: "Last Answers" })
        m.push({ k: "W", d: "Wrap Up Session" })
        m.push({ k: "↵", d: "Continue" })
        m.push({ k: "?", d: "Toggle this menu" })
        return m
      }
    }

  }

  onInfoOpenChanged: {
    if (!infoOpen) { _infoStack = []; Qt.callLater(_refocus) }
  }
}
