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
  property string jpFamily: "Noto Sans CJK JP"

  property color radicalColor: "#00a1f1"
  property color kanjiColor: "#f100a1"
  property color vocabColor: "#a100f1"

  signal navigate(int subjectId)

  onSubjectChanged: flick.contentY = 0

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

  function scrollBy(dy) {
    var max = Math.max(0, flick.contentHeight - flick.height)
    flick.contentY = Math.max(0, Math.min(max, flick.contentY + dy))
  }

  FocusScope {
    id: keys
    anchors.fill: parent
    focus: true

    Keys.onPressed: function (e) {
      var step = Style.space(64)
      if (e.text === "j") { page.scrollBy(step); e.accepted = true }
      else if (e.text === "k") { page.scrollBy(-step); e.accepted = true }
      else if (e.text === "d") { page.scrollBy(flick.height * 0.5); e.accepted = true }
      else if (e.text === "u") { page.scrollBy(-flick.height * 0.5); e.accepted = true }
      else if (e.text === "g") { flick.contentY = 0; e.accepted = true }
      else if (e.text === "G") { flick.contentY = Math.max(0, flick.contentHeight - flick.height); e.accepted = true }
      else if (e.key === Qt.Key_Space) {
        page.scrollBy((e.modifiers & Qt.ShiftModifier) ? -flick.height * 0.8 : flick.height * 0.8)
        e.accepted = true
      }
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

        Column {
          id: header
          anchors.centerIn: parent
          width: parent.width - Style.space(64)
          spacing: Style.space(8)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: page.sd.characters || page.primaryMeaning()
            color: "white"
            font.family: page.jpFamily
            font.pixelSize: Style.font.displayLarge * 2.4
            font.bold: true
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: page.primaryMeaning()
            color: "white"
            font.family: page.fontFamily
            font.pixelSize: Style.font.display
            font.bold: true
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: page.typeLabel + "  ·  Level " + (page.sd.level || "?")
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
          width: parent.width
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
          width: parent.width
          visible: page.kind === "kanji" || page.kind === "vocabulary"
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
          width: parent.width
          visible: (page.sd.context_sentences || []).length > 0
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
          width: parent.width
          visible: (page.sd.component_subject_ids || []).length > 0
          title: page.kind === "kanji" ? "Radical Combination" : "Kanji Composition"
          bg: page.cardBg

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
                onActivated: page.navigate(modelData)
              }
            }
          }
        }

        // ---- Found In --------------------------------------------
        SubjectCard {
          width: parent.width
          visible: (page.sd.amalgamation_subject_ids || []).length > 0
          title: page.kind === "radical" ? "Found In Kanji" : "Found In Vocabulary"
          bg: page.cardBg

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
                onActivated: page.navigate(modelData)
              }
            }
          }
        }

        // ---- Visually Similar ------------------------------------
        SubjectCard {
          width: parent.width
          visible: (page.sd.visually_similar_subject_ids || []).length > 0
          title: "Visually Similar Kanji"
          bg: page.cardBg

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
