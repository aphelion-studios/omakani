import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import "Markup.js" as Markup

// One subject's full page: the type-coloured header plus the Meaning /
// Reading / Context / Composition cards from the website, with the mnemonic
// markup rendered in colour and the component graph as clickable chips.
//
// `subject` is a full resource from the helper's `detail` command
// (data + study_material). `resolve(id)` returns an already-loaded resource
// for a linked subject, or null; `navigate(id)` asks the app to open one.
// FocusScope root (like ReviewEngine) so a plain forceActiveFocus() from the
// host reliably routes keys here, first show included.
FocusScope {
  id: page

  property var subject: null
  property var service: null
  property color pageBg: Color.background
  property color fg: Color.foreground
  property string fontFamily: Style.font.family
  property string jpFamily: Qt.fontFamilies().indexOf("Noto Sans JP") >= 0
    ? "Noto Sans JP" : "Noto Sans CJK JP"

  property color radicalColor: "#01a9fd"
  property color kanjiColor: "#fc02a9"
  property color vocabColor: "#a802fd"

  // when true (used as the quiz's item-info overlay), f / Esc ask to close
  property bool overlayMode: false
  // keyboard section/chip navigation (j/k ring, h/l chips, Enter fold/open,
  // Esc back) -- on in the overlay and in the standalone browser page
  property bool keyNav: overlayMode
  // hearing the word is a peek if you haven't cleared its reading yet
  property bool audioAllowed: true
  // apply the review's default folds (context folded); off when drilled into
  // a linked subject
  property bool reviewFolds: false
  // hide the "· Level N" everywhere in a live review (drilled pages too) --
  // the level leaks which look-alike you're being asked
  property bool hideLevel: false

  // in a review overlay the host passes the quiz header's exact pixel height so
  // the info band lines up with the answer view (the overlay is shorter than a
  // full page, so the plain 0.26 proportion would draw a smaller band). 0 ->
  // use the standalone proportion.
  property real bandHeight: 0
  // one shallow proportion everywhere -- browse page, item info, drilled linked
  // subject -- all read identically. In a review overlay the host hands us the
  // quiz header's own height so the two line up exactly.
  readonly property real _bandH: bandHeight > 0
    ? bandHeight : Math.round(page.height * 0.26)

  // the "<Type> <Meaning|Reading>" bar under the header, in a review overlay.
  // "" -> the bar shows the type (and level, unless hideLevel) instead.
  property string promptWord: ""
  readonly property bool _readingPrompt: promptWord === "Reading"

  // a review's item info collapses the half you're being tested on (like the
  // website) -- present but folded, so f can't hand you the answer at a
  // glance, but you can still open it. "" | "meaning" | "reading".
  property string collapse: ""
  readonly property bool meaningFolded: collapse === "meaning"
  readonly property bool readingFolded: collapse === "reading"

  // which section the focus ring should land on when the overlay opens --
  // "" | "meaning" | "reading" (set to the tested half on a wrong answer)
  property string focusSection: ""

  signal navigate(int subjectId)
  signal closeRequested()
  // [ / ] step to the previous / next item in this level (browse page only)
  signal stepSubject(int direction)
  // , swaps to the Last Answers panel (review overlay only), like the website
  signal lastAnswersRequested()

  // ---- section navigation (item-info overlay) --------
  //   j/k        move the section ring
  //   Enter      toggle fold on a text section; open the highlighted chip
  //              on a chip section (Composition / Found In / Visually Similar)
  //   h/l        step the highlighted chip backward / forward
  //   Esc        go back a page (drilled) or close
  property var navCards: []
  property int focusIndex: 0
  property int chipIndex: 0           // highlighted chip in the focused section
  // bumped on every subject change so cards drop any manual fold and go back
  // to their default state
  property int resetToken: 0

  // E in the item-info overlay: fold / unfold every collapsible card at once
  property bool _allExpanded: false
  function toggleExpandAll() {
    _allExpanded = !_allExpanded
    for (var i = 0; i < navCards.length; i++) {
      var c = navCards[i]
      if (!c || !c.collapsible) continue
      if (_allExpanded) c.expand()
      else c.collapse()
    }
    // the layout jumps as everything folds/unfolds -- keep the ringed card in view
    Qt.callLater(scrollToFocused)
  }

  function focusedChipIds() {
    var c = focusedCard()
    return (c && c.chipIds) ? c.chipIds : []
  }
  function moveChip(delta) {
    var ids = focusedChipIds()
    if (!ids.length) return
    chipIndex = Math.max(0, Math.min(chipIndex + delta, ids.length - 1))
    Qt.callLater(scrollToFocused)
  }
  function openChip() {
    var ids = focusedChipIds()
    if (chipIndex >= 0 && chipIndex < ids.length) page.navigate(ids[chipIndex])
  }
  function activateFocused() {
    if (focusedChipIds().length > 0) { openChip(); return }
    var c = focusedCard()
    if (c) c.toggle()
  }
  function registerCard(c) { var a = navCards.slice(); a.push(c); navCards = a }
  // fixed section order -- sorting the registered cards by on-screen Y raced
  // the layout pass (Component.onCompleted fires before positions settle), so
  // the ring sometimes started on Reading instead of Meaning
  readonly property var _sectionRank: ({
    meaning: 0, reading: 1, context: 2, composition: 3, foundin: 4, similar: 5
  })
  function _rankOf(key) {
    var r = _sectionRank[key]
    return r === undefined ? 9 : r
  }
  // visible section cards, in display order
  function visibleNav() {
    var v = navCards.filter(function (c) { return c && c.visible })
    v.sort(function (a, b) { return page._rankOf(a.navKey) - page._rankOf(b.navKey) })
    return v
  }
  function focusedCard() {
    var v = visibleNav()
    if (!v.length) return null
    return v[Math.max(0, Math.min(focusIndex, v.length - 1))]
  }
  // reactive key of the focused section, for the cards' focus-ring binding
  readonly property string focusedKey: {
    var _dep = navCards.length + focusIndex + resetToken   // keep it reactive
    var c = focusedCard()
    return c ? String(c.navKey) : ""
  }
  function scrollToFocused() {
    var c = focusedCard()
    if (!c) return
    var top = c.mapToItem(body, 0, 0).y
    var bot = top + c.height
    var pad = Style.space(16)
    if (top < flick.contentY + pad)
      flick.contentY = Math.max(0, top - pad)
    else if (bot > flick.contentY + flick.height - pad)
      flick.contentY = bot - flick.height + pad
  }
  function moveFocus(delta) {
    var v = visibleNav()
    if (!v.length) return
    var next = Math.max(0, Math.min(focusIndex + delta, v.length - 1))
    if (next === focusIndex) {
      // already at the edge -- scroll the rest of the way (past the header
      // at the top, past the tail padding at the bottom)
      flick.contentY = delta < 0 ? 0
        : Math.max(0, flick.contentHeight - flick.height)
      return
    }
    chipIndex = 0      // new section -> highlight its first chip
    focusIndex = next
    Qt.callLater(scrollToFocused)
  }
  // text sections (Meaning / Reading / Context) fold in the overlay; a plain
  // page only folds the anti-cheat half during a review. Chip sections don't
  // fold -- h/l navigate their chips instead.
  function cardCollapsible() { return keyNav || collapse !== "" }
  function startFolded(key) {
    if (collapse === key) return true          // anti-cheat: tested half
    if (reviewFolds && key === "context") return true
    return false
  }

  // land the ring on the tested half when the overlay opens after a miss --
  // once per focusSection value, so j/k can move away afterwards
  property string _syncedSection: ""
  onFocusSectionChanged: Qt.callLater(syncFocusToSection)
  onNavCardsChanged: Qt.callLater(syncFocusToSection)
  onVisibleChanged: if (visible) Qt.callLater(syncFocusToSection)
  function syncFocusToSection() {
    if (!keyNav || focusSection === "" || focusSection === _syncedSection) return
    var v = visibleNav()
    for (var i = 0; i < v.length; i++) {
      if (String(v[i].navKey) === focusSection) {
        focusIndex = i
        _syncedSection = focusSection
        Qt.callLater(scrollToFocused)
        return
      }
    }
  }

  // the `subject` binding re-fires every time the detail cache re-merges
  // (linked-chip hydration), handing back the *same* record -- guard on the
  // id so a re-merge doesn't reset the scroll position or the focus ring
  property int _loadedSubjectId: 0
  onSubjectChanged: {
    var sid = (subject && subject.id) ? Number(subject.id) : 0
    if (sid !== 0 && sid === _loadedSubjectId) {
      Qt.callLater(hydrateLinks)   // still top up any newly-missing chips
      return
    }
    _loadedSubjectId = sid
    flick.contentY = 0
    focusIndex = 0
    chipIndex = 0
    _syncedSection = ""
    _allExpanded = false
    resetToken += 1     // cards drop manual folds, back to their defaults
    Qt.callLater(hydrateLinks)
    Qt.callLater(syncFocusToSection)
    // browse page: warm the audio daemon + cache this clip so the first
    // SHIFT+J isn't a cold 10-second wait
    if (subject && !overlayMode && hasAudio && service)
      service.preloadAudio([sid])
    // the browser page's first subject arrives after focusPage() already
    // ran on an empty scope -- re-grab so the keyboard works right away
    if (subject && keyNav && !overlayMode && visible)
      focusPoke.kick()
  }

  // Bulletproof focus grab: forceActiveFocus() called while `flick` is still
  // hidden (subject not loaded yet) doesn't stick, and a single re-grab on
  // arrival races the layout pass. Poke a few frames until it takes.
  Timer {
    id: focusPoke
    interval: 16
    repeat: true
    property int ticks: 0
    function kick() { ticks = 0; restart() }
    onTriggered: {
      ticks += 1
      if (page.visible && page.keyNav && !page.overlayMode && !!page.subject)
        keys.forceActiveFocus()
      if (ticks >= 12 || !page.visible || keys.activeFocus) { stop(); ticks = 0 }
    }
  }

  property bool _hydrating: false
  function hydrateLinks() {
    if (_hydrating || !service || !subject || !subject.data) return
    var d = subject.data
    var ids = []
      .concat(d.component_subject_ids || [])
      .concat((d.amalgamation_subject_ids || []).slice(0, 60))
      .concat(d.visually_similar_subject_ids || [])
    var missing = ids.filter(function (x) { return !service.subjectDetail(x) })
    if (missing.length === 0) return
    _hydrating = true
    service.loadDetail(missing.slice(0, 100))
  }

  Connections {
    target: page.service
    enabled: page.service !== null
    function onDetailReady(ids) {
      if (page._hydrating) { page._hydrating = false; return }
    }
  }

  function resolve(id) {
    return service && typeof service.subjectDetail === "function"
      ? service.subjectDetail(id) : null
  }

  readonly property var sd: subject && subject.data ? subject.data : ({})
  readonly property string kind: subject ? String(subject.object || "") : ""
  // WaniKani's illustrated radical mnemonic (scraped by `wanikani.py
  // radical-images` -- not in the API); "" until that's been run
  readonly property string mnemonicImagePath: subject && subject.mnemonic_image_path
    ? String(subject.mnemonic_image_path) : ""
  readonly property string mnemonicImageAlt: subject && subject.mnemonic_image_alt
    ? String(subject.mnemonic_image_alt) : ""

  // unlock state, from the assignment (absent entirely => still locked)
  readonly property var asg: subject && subject.assignment ? subject.assignment : ({})
  readonly property bool itemLocked: !asg.id && !asg.unlocked_at
  readonly property bool showLockState: !overlayMode && !!subject
  readonly property var study: subject && subject.study_material ? subject.study_material : ({})

  readonly property color typeColor: {
    if (kind === "radical") return radicalColor
    if (kind === "kanji") return kanjiColor
    return vocabColor
  }
  readonly property string typeLabel: {
    if (kind === "radical") return "Radical"
    if (kind === "kanji") return "Kanji"
    if (kind === "kana_vocabulary") return "Vocabulary"
    return "Vocabulary"
  }

  readonly property var markupColors: ({
    radical: Qt.lighter(radicalColor, 1.25),
    kanji: Qt.lighter(kanjiColor, 1.3),
    vocabulary: Qt.lighter(vocabColor, 1.35),
    reading: "#c9b6ec",
    meaning: "#e7cb5c",
    jp: jpFamily
  })

  readonly property color cardBg: Qt.lighter(pageBg, 1.7)
  readonly property color muted: Qt.darker(fg, 1.5)
  readonly property color faint: Qt.darker(fg, 1.9)
  // mnemonic links (e.g. "rendaku") -- RichText's default blue is unreadable on
  // the dark card. Match the terminal: the theme's "cyan" palette slot is what
  // foot / the shell colour URLs with. Underline is kept (Qt underlines <a>).
  property string _themeColorsRaw: ""
  readonly property color linkColor: {
    var m = /(^|\n)\s*cyan\s*=\s*"?(#[0-9a-fA-F]{3,8})"?/.exec(page._themeColorsRaw || "")
    return m ? m[2] : Color.accent
  }
  FileView {
    id: themeColorsFile
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: page._themeColorsRaw = text()
    onFileChanged: reload()
  }
  Connections {
    target: Color
    function onAccentChanged() { themeColorsFile.reload() }
  }

  function primaryMeaning() {
    var list = sd.meanings || []
    for (var i = 0; i < list.length; i++)
      if (list[i].primary) return list[i].meaning
    return list.length ? list[0].meaning : ""
  }
  function altMeanings() {
    return (sd.meanings || [])
      .filter(function (m) { return !m.primary })
      .map(function (m) { return m.meaning })
  }
  function readingLabel(type) {
    if (type === "onyomi") return "On'yomi"
    if (type === "kunyomi") return "Kun'yomi"
    if (type === "nanori") return "Nanori"
    return ""
  }

  function focusPage() {
    keys.forceActiveFocus()
    if (keyNav && !overlayMode) focusPoke.kick()
  }
  readonly property bool hasKeyFocus: keys.activeFocus

  readonly property bool hasAudio: kind === "vocabulary" || kind === "kana_vocabulary"
  function playAudio(voice) {
    if (service && hasAudio && subject && subject.id)
      service.playAudio(subject.id, voice || "random")
  }

  function scrollBy(dy) {
    var max = Math.max(0, flick.contentHeight - flick.height)
    flick.contentY = Math.max(0, Math.min(max, flick.contentY + dy))
  }

  FocusScope {
    id: keys
    anchors.fill: parent
    // take focus whenever the page's FocusScope root is given focus
    focus: true
    // a focused item still gets key events while hidden -- don't eat keys
    // when this page isn't the visible view
    Keys.enabled: page.visible

    Keys.onPressed: function (e) {
      var step = Style.space(64)
      // [ / ] walk the level in order (standalone browse page only)
      if (!page.overlayMode
          && (e.text === "[" || e.text === "]"
              || e.key === Qt.Key_BracketLeft || e.key === Qt.Key_BracketRight)) {
        page.stepSubject((e.text === "]" || e.key === Qt.Key_BracketRight) ? 1 : -1)
        e.accepted = true
        return
      }
      // SHIFT+J plays the pronunciation on the browse page (plain j scrolls /
      // moves the ring there, so it can't double as audio like it does in a
      // review overlay)
      if (!page.overlayMode && e.key === Qt.Key_J && (e.modifiers & Qt.ShiftModifier)) {
        page.playAudio("random"); e.accepted = true; return
      }
      // j/k move the section ring, Enter toggles a fold (or opens the
      // highlighted chip on a chip section), h/l step the chip cursor,
      // e folds / unfolds every card, Esc / f go back a page or close
      if (page.keyNav) {
        if (e.text === "j") { page.moveFocus(1); e.accepted = true; return }
        else if (e.text === "k") { page.moveFocus(-1); e.accepted = true; return }
        else if (e.text === "l") { page.moveChip(1); e.accepted = true; return }
        else if (e.text === "h") { page.moveChip(-1); e.accepted = true; return }
        else if (e.text === "e" && page.overlayMode) {
          page.toggleExpandAll(); e.accepted = true; return
        }
        else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
          page.activateFocused(); e.accepted = true; return
        }
        else if (e.text === "," && page.overlayMode) {
          page.lastAnswersRequested(); e.accepted = true; return
        }
        else if ((e.text === "f" && page.overlayMode) || e.key === Qt.Key_Escape) {
          page.closeRequested(); e.accepted = true; return
        }
      } else {
        if (e.text === "j") { page.scrollBy(step); e.accepted = true; return }
        else if (e.text === "k") { page.scrollBy(-step); e.accepted = true; return }
      }
      if (e.text === "d") { page.scrollBy(flick.height * 0.5); e.accepted = true }
      else if (e.text === "u") { page.scrollBy(-flick.height * 0.5); e.accepted = true }
      else if (e.text === "g") { flick.contentY = 0; e.accepted = true }
      else if (e.text === "G") { flick.contentY = Math.max(0, flick.contentHeight - flick.height); e.accepted = true }
      else if (e.key === Qt.Key_Space) {
        page.scrollBy((e.modifiers & Qt.ShiftModifier) ? -flick.height * 0.8 : flick.height * 0.8)
        e.accepted = true
      }
    }

  // while the subject is loading, show nothing here -- the host draws a
  // plain "Loading subject…" so it doesn't flash an empty coloured header

  // The coloured band + type bar, pinned over the scroll area (both the review
  // overlay and the standalone browse page) so scrolling the cards never drags
  // the header away.
  Column {
    id: headBlock
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    z: 5
    visible: !!page.subject

    // in a review overlay QuizCard draws its 4px progress rail over the very
    // top; leave the same gap so the coloured band lines up with the answer view
    Item { width: 1; height: page.overlayMode ? Style.space(4) : 0 }

    // ---------------------------------------------------- header band
    Rectangle {
      width: parent.width
      implicitHeight: page._bandH
      color: page.typeColor

        Column {
          id: header
          anchors.centerIn: parent
          anchors.verticalCenterOffset: -Style.space(4)
          width: parent.width - Style.space(64)
          spacing: Style.space(8)

          Text {
            id: headerChar
            anchors.horizontalCenter: parent.horizontalCenter
            // centre the glyph's ink, not its advance box -- lone narrow
            // radicals (刂 etc.) have lopsided side bearings
            anchors.horizontalCenterOffset: headerCharM.advanceWidth > 0
              ? (headerCharM.advanceWidth / 2 - headerCharM.tightBoundingRect.x
                 - headerCharM.tightBoundingRect.width / 2)
              : 0
            // just the character (the meaning lives in the Meaning card and
            // the type in the bar below) -- charless radicals fall back to
            // the name so the band isn't empty on a browse page
            text: page.sd.characters || (page.overlayMode ? "" : page.primaryMeaning())
            color: "#fcfdfd"
            font.family: page.jpFamily
            font.pixelSize: Math.min(page._bandH * 0.56, Style.font.displayLarge * 3)
            font.weight: page.sd.characters ? Font.Normal : Font.Bold
          }
          TextMetrics {
            id: headerCharM
            font: headerChar.font
            text: headerChar.text
          }

          // locked / unlocked (browse only) -- solid outline for UNLOCKED,
          // dashed for LOCKED, the website's tile-border convention
          Item {
            visible: page.showLockState
            anchors.horizontalCenter: parent.horizontalCenter
            width: lockLbl.implicitWidth + Style.space(18)
            height: lockLbl.implicitHeight + Style.space(8)

            Canvas {
              id: lockBorder
              anchors.fill: parent
              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var inset = 1
                var x = inset, y = inset
                var w = width - 2 * inset, h = height - 2 * inset
                var r = h / 2
                ctx.beginPath()
                ctx.moveTo(x + r, y)
                ctx.arcTo(x + w, y, x + w, y + h, r)
                ctx.arcTo(x + w, y + h, x, y + h, r)
                ctx.arcTo(x, y + h, x, y, r)
                ctx.arcTo(x, y, x + w, y, r)
                ctx.closePath()
                if (!page.itemLocked) {
                  ctx.fillStyle = Qt.rgba(1, 1, 1, 0.16)
                  ctx.fill()
                }
                ctx.lineWidth = 1.5
                ctx.strokeStyle = "#fcfdfd"
                ctx.setLineDash(page.itemLocked ? [4, 3] : [])
                ctx.stroke()
              }
              Component.onCompleted: requestPaint()
              onWidthChanged: requestPaint()
              onHeightChanged: requestPaint()
              Connections {
                target: page
                function onItemLockedChanged() { lockBorder.requestPaint() }
              }
            }
            Text {
              id: lockLbl
              anchors.centerIn: parent
              text: page.itemLocked ? "LOCKED" : "UNLOCKED"
              color: "#fcfdfd"
              font.family: page.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

        }
      }

      // ---- type bar ----
      // review overlay: "<Type> <Meaning|Reading>" (dark for a reading prompt,
      // grey for meaning). Everywhere else: "<Type> · Level N" (level hidden
      // in a live review, kept on a browse page).
      Rectangle {
        id: typeBar
        width: parent.width
        implicitHeight: Style.space(40)
        color: page._readingPrompt ? Qt.rgba(0, 0, 0, 0.55) : "#ebedef"
        readonly property color ink: page._readingPrompt ? "#fcfdfd" : "#1a1a1a"
        Row {
          anchors.centerIn: parent
          // roomy, even gaps around the "·" in level mode; tight next to a
          // prompt word ("Vocabulary Meaning")
          spacing: page.promptWord === "" ? Style.space(10) : Style.space(6)
          Text {
            text: page.typeLabel
            color: typeBar.ink
            font.family: page.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: page.promptWord === ""
          }
          Text {
            visible: page.promptWord !== ""
            text: page.promptWord
            color: typeBar.ink
            font.family: page.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Text {
            visible: page.promptWord === "" && !page.hideLevel && !!page.sd.level
            text: "·"
            color: Qt.rgba(0, 0, 0, 0.5)
            font.family: page.fontFamily
            font.pixelSize: Style.font.subtitle
          }
          Text {
            visible: page.promptWord === "" && !page.hideLevel && !!page.sd.level
            text: "Level " + (page.sd.level || "?")
            color: Qt.rgba(0, 0, 0, 0.5)
            font.family: page.fontFamily
            font.pixelSize: Style.font.subtitle
          }
        }
      }
    }

  // ---- scrolling area: the cards, below the pinned header ----
  Flickable {
    id: flick
    anchors.top: headBlock.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    visible: !!page.subject
    contentWidth: width
    contentHeight: body.implicitHeight
    boundsBehavior: Flickable.StopAtBounds
    clip: true

    Column {
      id: body
      width: flick.width
      spacing: 0

      Item { width: 1; height: Style.space(20) }

      // ---------------------------------------------------- cards
      Column {
        width: parent.width - Style.space(48)
        x: Style.space(24)
        spacing: Style.space(16)

        // ---- Meaning ---------------------------------------------------
        SubjectCard {
          readonly property string navKey: "meaning"
          width: parent.width
          collapsible: page.cardCollapsible()
          defaultCollapsed: page.startFolded("meaning")
          resetToken: page.resetToken
          navFocused: page.keyNav && page.focusedKey === navKey
          Component.onCompleted: page.registerCard(this)
          title: page.kind === "radical" ? "Name" : "Meaning"
          bg: page.cardBg

          Column {
            width: parent.width
            spacing: Style.space(10)

            Row {
              spacing: Style.space(10)
              Text {
                text: page.primaryMeaning()
                color: page.fg
                font.family: page.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                visible: page.altMeanings().length > 0
                text: page.altMeanings().join(", ")
                color: page.muted
                font.family: page.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Text {
              visible: (page.sd.parts_of_speech || []).length > 0
              text: (page.sd.parts_of_speech || []).join(", ")
              color: page.faint
              font.family: page.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.italic: true
            }

            Text {
              width: parent.width
              visible: !!page.sd.meaning_mnemonic
              text: Markup.toHtml(page.sd.meaning_mnemonic, page.markupColors)
              textFormat: Text.RichText
              wrapMode: Text.WordWrap
              lineHeight: 1.35
              color: page.fg
              linkColor: page.linkColor
              onLinkActivated: function (l) { Qt.openUrlExternally(l) }
              font.family: page.fontFamily
              font.pixelSize: Style.font.body
            }

            // the illustrated radical mnemonic, on a white tile like the site
            Rectangle {
              visible: page.kind === "radical" && page.mnemonicImagePath !== ""
              width: Style.space(224)
              height: Style.space(224)
              radius: Style.space(6)
              color: "#fcfdfd"
              Image {
                anchors.centerIn: parent
                width: parent.width - Style.space(16)
                height: width
                fillMode: Image.PreserveAspectFit
                source: page.mnemonicImagePath !== ""
                  ? "file://" + page.mnemonicImagePath : ""
                sourceSize.width: 420
                sourceSize.height: 420
                smooth: true
              }
            }

            Rectangle {
              width: parent.width
              visible: !!page.sd.meaning_hint
              implicitHeight: hintT.implicitHeight + Style.space(16)
              color: Qt.rgba(page.fg.r, page.fg.g, page.fg.b, 0.05)
              radius: Style.space(4)
              Text {
                id: hintT
                x: Style.space(10); y: Style.space(8)
                width: parent.width - Style.space(20)
                text: "Hint  " + Markup.toHtml(page.sd.meaning_hint, page.markupColors)
                textFormat: Text.RichText
                wrapMode: Text.WordWrap
                color: page.muted
                linkColor: page.linkColor
                onLinkActivated: function (l) { Qt.openUrlExternally(l) }
                font.family: page.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Text {
              width: parent.width
              visible: (page.study.meaning_synonyms || []).length > 0
              text: "Your synonyms:  " + (page.study.meaning_synonyms || []).join(", ")
              wrapMode: Text.WordWrap
              color: page.muted
              font.family: page.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: parent.width
              visible: !!page.study.meaning_note
              text: "Note:  " + page.study.meaning_note
              wrapMode: Text.WordWrap
              color: page.muted
              font.family: page.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.italic: true
            }
          }
        }

        // ---- Reading -------------------------------------------------
        SubjectCard {
          readonly property string navKey: "reading"
          width: parent.width
          visible: page.kind === "kanji" || page.kind === "vocabulary"
            || page.kind === "kana_vocabulary"
          collapsible: page.cardCollapsible()
          defaultCollapsed: page.startFolded("reading")
          resetToken: page.resetToken
          navFocused: page.keyNav && page.focusedKey === navKey
          Component.onCompleted: page.registerCard(this)
          title: "Reading"
          bg: page.cardBg

          Column {
            width: parent.width
            spacing: Style.space(12)

            Flow {
              width: parent.width
              spacing: Style.space(20)

              Repeater {
                model: (page.sd.readings || []).filter(function (r) {
                  return r.accepted_answer !== false
                })
                delegate: Column {
                  spacing: Style.space(2)
                  Text {
                    text: modelData.reading
                    color: modelData.primary ? page.fg : page.muted
                    font.family: page.jpFamily
                    font.pixelSize: Style.font.heading
                    font.bold: modelData.primary
                  }
                  Text {
                    visible: !!page.readingLabel(modelData.type)
                    text: page.readingLabel(modelData.type)
                    color: page.faint
                    font.family: page.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            // audio (vocab only) -- KYOKO / KENICHI, or SHIFT+J for a random one
            Row {
              visible: page.hasAudio && page.audioAllowed
              spacing: Style.space(8)

              Repeater {
                model: [
                  { label: "▶  KYOKO", voice: "kyoko" },
                  { label: "▶  KENICHI", voice: "kenichi" }
                ]
                delegate: Rectangle {
                  width: audioLabel.implicitWidth + Style.space(20)
                  height: Style.space(30)
                  radius: Style.space(5)
                  color: Qt.rgba(page.vocabColor.r, page.vocabColor.g, page.vocabColor.b,
                    audioHover.containsMouse ? 0.3 : 0.16)
                  border.width: 1
                  border.color: Qt.rgba(page.vocabColor.r, page.vocabColor.g, page.vocabColor.b, 0.45)

                  Text {
                    id: audioLabel
                    anchors.centerIn: parent
                    text: modelData.label
                    color: page.fg
                    font.family: page.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                  MouseArea {
                    id: audioHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: page.playAudio(modelData.voice)
                  }
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                readonly property bool hasErr: page.service && page.service.audioError !== ""
                // the key hint only on the browse page -- in a review overlay
                // audio is on the J shortcut and j navigates the open panel
                visible: hasErr || !page.overlayMode
                text: hasErr ? page.service.audioError : "or press  SHIFT+J"
                color: page.faint
                font.family: page.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              width: parent.width
              visible: !!page.sd.reading_mnemonic
              text: Markup.toHtml(page.sd.reading_mnemonic, page.markupColors)
              textFormat: Text.RichText
              wrapMode: Text.WordWrap
              lineHeight: 1.35
              color: page.fg
              linkColor: page.linkColor
              onLinkActivated: function (l) { Qt.openUrlExternally(l) }
              font.family: page.fontFamily
              font.pixelSize: Style.font.body
            }

            Rectangle {
              width: parent.width
              visible: !!page.sd.reading_hint
              implicitHeight: rhintT.implicitHeight + Style.space(16)
              color: Qt.rgba(page.fg.r, page.fg.g, page.fg.b, 0.05)
              radius: Style.space(4)
              Text {
                id: rhintT
                x: Style.space(10); y: Style.space(8)
                width: parent.width - Style.space(20)
                text: "Hint  " + Markup.toHtml(page.sd.reading_hint, page.markupColors)
                textFormat: Text.RichText
                wrapMode: Text.WordWrap
                color: page.muted
                linkColor: page.linkColor
                onLinkActivated: function (l) { Qt.openUrlExternally(l) }
                font.family: page.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Text {
              width: parent.width
              visible: !!page.study.reading_note
              text: "Note:  " + page.study.reading_note
              wrapMode: Text.WordWrap
              color: page.muted
              font.family: page.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.italic: true
            }
          }
        }

        // ---- Context ------------------------------------------------
        SubjectCard {
          readonly property string navKey: "context"
          width: parent.width
          visible: (page.sd.context_sentences || []).length > 0
          collapsible: page.cardCollapsible()
          defaultCollapsed: page.startFolded("context")
          resetToken: page.resetToken
          navFocused: page.keyNav && page.focusedKey === navKey
          Component.onCompleted: page.registerCard(this)
          title: "Context"
          bg: page.cardBg

          Column {
            width: parent.width
            spacing: Style.space(14)

            Repeater {
              model: page.sd.context_sentences || []
              delegate: Column {
                width: parent.width
                spacing: Style.space(3)
                Text {
                  width: parent.width
                  text: modelData.ja
                  wrapMode: Text.WordWrap
                  color: page.fg
                  font.family: page.jpFamily
                  font.pixelSize: Style.font.subtitle
                }
                Text {
                  width: parent.width
                  text: modelData.en
                  wrapMode: Text.WordWrap
                  color: page.muted
                  font.family: page.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }
        }

        // ---- Composition ------------------------------------------
        SubjectCard {
          readonly property string navKey: "composition"
          width: parent.width
          visible: (page.sd.component_subject_ids || []).length > 0
          collapsible: false   // chip section: h/l navigate, no fold
          navFocused: page.keyNav && page.focusedKey === navKey
          Component.onCompleted: page.registerCard(this)
          title: page.kind === "kanji" ? "Radical Combination" : "Kanji Composition"
          bg: page.cardBg
          chipIds: page.sd.component_subject_ids || []

          Flow {
            width: parent.width
            spacing: Style.space(8)
            Repeater {
              model: page.sd.component_subject_ids || []
              delegate: SubjectChip {
                subjectId: modelData
                resource: page.resolve(modelData)
                fontFamily: page.fontFamily
                jpFamily: page.jpFamily
                fg: "#fcfdfd"
                radicalColor: page.radicalColor
                kanjiColor: page.kanjiColor
                vocabColor: page.vocabColor
                cursored: page.keyNav && page.chipIndex === index
                  && page.focusedKey === "composition"
                onActivated: page.navigate(modelData)
              }
            }
          }
        }

        // ---- Found In --------------------------------------------
        SubjectCard {
          readonly property string navKey: "foundin"
          width: parent.width
          visible: (page.sd.amalgamation_subject_ids || []).length > 0
          collapsible: false   // chip section: h/l navigate, no fold
          navFocused: page.keyNav && page.focusedKey === navKey
          Component.onCompleted: page.registerCard(this)
          title: page.kind === "radical" ? "Found In Kanji" : "Found In Vocabulary"
          bg: page.cardBg
          chipIds: (page.sd.amalgamation_subject_ids || []).slice(0, 60)

          Flow {
            width: parent.width
            spacing: Style.space(8)
            Repeater {
              model: (page.sd.amalgamation_subject_ids || []).slice(0, 60)
              delegate: SubjectChip {
                subjectId: modelData
                resource: page.resolve(modelData)
                fontFamily: page.fontFamily
                jpFamily: page.jpFamily
                fg: "#fcfdfd"
                radicalColor: page.radicalColor
                kanjiColor: page.kanjiColor
                vocabColor: page.vocabColor
                cursored: page.keyNav && page.chipIndex === index
                  && page.focusedKey === "foundin"
                onActivated: page.navigate(modelData)
              }
            }
          }
        }

        // ---- Visually Similar ------------------------------------
        SubjectCard {
          readonly property string navKey: "similar"
          width: parent.width
          visible: (page.sd.visually_similar_subject_ids || []).length > 0
          collapsible: false   // chip section: h/l navigate, no fold
          navFocused: page.keyNav && page.focusedKey === navKey
          Component.onCompleted: page.registerCard(this)
          title: "Visually Similar Kanji"
          bg: page.cardBg
          chipIds: page.sd.visually_similar_subject_ids || []

          Flow {
            width: parent.width
            spacing: Style.space(8)
            Repeater {
              model: page.sd.visually_similar_subject_ids || []
              delegate: SubjectChip {
                subjectId: modelData
                resource: page.resolve(modelData)
                fontFamily: page.fontFamily
                jpFamily: page.jpFamily
                fg: "#fcfdfd"
                radicalColor: page.radicalColor
                kanjiColor: page.kanjiColor
                vocabColor: page.vocabColor
                cursored: page.keyNav && page.chipIndex === index
                  && page.focusedKey === "similar"
                onActivated: page.navigate(modelData)
              }
            }
          }
        }
      }

      // extra room in the review overlay so the last card clears the
      // floating toolbar
      Item { width: 1; height: Style.space(page.overlayMode ? 76 : 32) }
    }
  }
  }
}
