import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Markup.js" as Markup

// One subject's full page: the type-coloured header plus the Meaning /
// Reading / Context / Composition cards from the website, with the mnemonic
// markup rendered in colour and the component graph as clickable chips.
//
// `subject` is a full resource from the helper's `detail` command
// (data + study_material). `resolve(id)` returns an already-loaded resource
// for a linked subject, or null; `navigate(id)` asks the app to open one.
Item {
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

  // a review's item info collapses the half you're being tested on (like the
  // website) -- present but folded, so f can't hand you the answer at a
  // glance, but you can still open it. "" | "meaning" | "reading".
  property string collapse: ""
  readonly property bool meaningFolded: collapse === "meaning"
  readonly property bool readingFolded: collapse === "reading"

  // which section the focus ring should land on when the overlay opens --
  // "" | "meaning" | "reading" (set to the tested half on a wrong answer)
  property string focusSection: ""

  // key-hint line shown in the (scrolling) header when keyNav is on
  property string navHint: keyNav
    ? "j / k  section   ·   h / l  chip   ·   Enter  open · fold   ·   Esc  back"
    : ""

  signal navigate(int subjectId)
  signal closeRequested()

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
  // visible section cards, top-to-bottom (Component.onCompleted fires
  // bottom-up, so sort by on-screen position)
  function visibleNav() {
    var v = navCards.filter(function (c) { return c && c.visible })
    v.sort(function (a, b) {
      return a.mapToItem(body, 0, 0).y - b.mapToItem(body, 0, 0).y
    })
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
    chipIndex = 0      // new section -> highlight its first chip
    focusIndex = Math.max(0, Math.min(focusIndex + delta, v.length - 1))
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

  onSubjectChanged: {
    flick.contentY = 0
    focusIndex = 0
    chipIndex = 0
    _syncedSection = ""
    resetToken += 1     // cards drop manual folds, back to their defaults
    Qt.callLater(hydrateLinks)
    Qt.callLater(syncFocusToSection)
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

  function focusPage() { keys.forceActiveFocus() }

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

    Keys.onPressed: function (e) {
      var step = Style.space(64)
      // j/k move the section ring, Enter toggles a fold (or opens the
      // highlighted chip on a chip section), h/l step the chip cursor,
      // Esc / f go back a page or close
      if (page.keyNav) {
        if (e.text === "j") { page.moveFocus(1); e.accepted = true; return }
        else if (e.text === "k") { page.moveFocus(-1); e.accepted = true; return }
        else if (e.text === "l") { page.moveChip(1); e.accepted = true; return }
        else if (e.text === "h") { page.moveChip(-1); e.accepted = true; return }
        else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
          page.activateFocused(); e.accepted = true; return
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
      else if (e.text === "p" && !page.overlayMode) { page.playAudio("random"); e.accepted = true }
    }

  Flickable {
    id: flick
    anchors.fill: parent
    contentWidth: width
    contentHeight: body.implicitHeight
    boundsBehavior: Flickable.StopAtBounds
    clip: true

    Column {
      id: body
      width: flick.width
      spacing: 0

      // ---------------------------------------------------- header band
      Rectangle {
        width: parent.width
        implicitHeight: header.implicitHeight + Style.space(44)
        color: page.typeColor

        // key hint -- lives in the (scrolling) header so it doesn't sit over
        // the content when you scroll down
        Text {
          visible: page.keyNav && page.navHint !== ""
          anchors.top: parent.top
          anchors.right: parent.right
          anchors.margins: Style.space(12)
          text: page.navHint
          color: "#fcfdfd"
          font.family: page.fontFamily
          font.pixelSize: Style.font.caption
        }

        Column {
          id: header
          anchors.centerIn: parent
          width: parent.width - Style.space(64)
          spacing: Style.space(8)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            // in the review overlay never fall back to the meaning
            text: page.sd.characters || (page.overlayMode ? "" : page.primaryMeaning())
            color: "#fcfdfd"
            font.family: page.jpFamily
            font.pixelSize: Style.font.displayLarge * 2.4
            font.weight: page.sd.characters ? Font.Normal : Font.Bold
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            // the meaning sits in the Meaning card; don't also spell it in
            // the header of the review overlay
            visible: !page.overlayMode
            text: page.primaryMeaning()
            color: "#fcfdfd"
            font.family: page.fontFamily
            font.pixelSize: Style.font.display
            font.bold: true
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            // hide the level in a live review -- it leaks which of two
            // look-alikes you're being asked (browsing keeps it)
            text: (page.overlayMode && page.hideLevel)
              ? page.typeLabel
              : page.typeLabel + "  ·  Level " + (page.sd.level || "?")
            color: Qt.rgba(1, 1, 1, 0.82)
            font.family: page.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }

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
              font.family: page.fontFamily
              font.pixelSize: Style.font.body
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

            // audio (vocab only) -- KYOKO / KENICHI, or press p for a random one
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
                text: (page.service && page.service.audioError !== "")
                  ? page.service.audioError : "or press  p"
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
                fg: page.fg
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
                fg: page.fg
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
                fg: page.fg
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

      Item { width: 1; height: Style.space(32) }
    }
  }
  }
}
