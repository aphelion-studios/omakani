import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The full OmaKani app: subject browser, lessons and reviews done in-shell.
// A `panel`-kind plugin, mounted by the shell and summoned with
//   omarchy-shell -q shell toggle io.github.aphelion-studios.omakani
// It reads the shared Service the bar widget also uses.
//
// Host contract (same as the Spotify full player): the shell sets `opened`
// through open()/close(); the window closing itself routes back through
// requestClose() -> shell.hide().
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  property string omarchyPath: ""

  property bool opened: false
  property bool closingFromHost: false

  readonly property string pluginId: manifest && manifest.id
    ? String(manifest.id) : "io.github.aphelion-studios.omakani"

  readonly property color bg: Color.background
  readonly property color fg: Color.foreground
  readonly property color accent: Color.accent
  readonly property string fontFamily: Style.font.family
  readonly property string jpFamily: "Noto Sans CJK JP"

  readonly property bool startLessons: !!service && service.configured
    && !service.vacation && service.lessonsNow > 0
  readonly property bool startReviews: !!service && service.configured
    && !service.vacation && service.reviewsNow > 0

  // Website type colours (vivid variants, tuned against the dark app ground).
  readonly property color radicalColor: "#00a1f1"
  readonly property color kanjiColor: "#f100a1"
  readonly property color vocabColor: "#a100f1"

  // ---- navigation stack -------------------------------------------------
  // Each entry: { view: "home" | "browse" | "subject", level, id }
  property var navStack: [{ view: "home" }]
  readonly property var currentPage: navStack.length > 0
    ? navStack[navStack.length - 1] : ({ view: "home" })
  readonly property string view: String(currentPage.view || "home")

  // Route keyboard focus to whichever view is showing (each owns its keys).
  onViewChanged: Qt.callLater(applyFocus)
  function applyFocus() {
    if (!opened) return
    if (view === "browse") levelBrowser.focusGrid()
    else if (view === "subject") subjectPage.focusPage()
    else if (view === "quiz") quizCard.forceActiveFocus()
    else focusScope.forceActiveFocus()
  }

  // Set while a linked-subject fetch triggered by detailReady is in flight,
  // so the follow-up fetch doesn't recurse.
  property bool hydratingLinks: false

  function pushPage(page) {
    var next = navStack.slice()
    next.push(page)
    navStack = next
  }

  function popPage() {
    if (navStack.length <= 1) return
    navStack = navStack.slice(0, navStack.length - 1)
  }

  function resetNav() {
    navStack = [{ view: "home" }]
  }

  function goBrowse(level) {
    var n = Math.max(1, Math.min(60, parseInt(String(level), 10) || 1))
    pushPage({ view: "browse", level: n })
    if (root.service) root.service.loadBrowse(n)
  }

  function goSubject(id) {
    var n = parseInt(String(id), 10)
    if (!isFinite(n)) return
    pushPage({ view: "subject", id: n })
    if (root.service) root.service.loadDetail([n])
  }

  // A single-prompt quiz for one subject -- the primitive the lesson flow
  // and review engine drive. `type` is "meaning" | "reading".
  function goQuiz(id, type) {
    var n = parseInt(String(id), 10)
    if (!isFinite(n)) return
    pushPage({ view: "quiz", id: n, quizType: type === "reading" ? "reading" : "meaning" })
    if (root.service) root.service.loadDetail([n])
  }

  // After a subject's detail lands, pull in any linked subjects (components,
  // amalgamations, look-alikes) we don't have yet so their chips show real
  // characters -- one extra request, capped.
  function hydrateLinks() {
    if (hydratingLinks || !root.service || view !== "subject") return
    var subject = root.service.subjectDetail(currentPage.id)
    if (!subject || !subject.data) return
    var d = subject.data
    var ids = []
      .concat(d.component_subject_ids || [])
      .concat((d.amalgamation_subject_ids || []).slice(0, 60))
      .concat(d.visually_similar_subject_ids || [])
    var missing = ids.filter(function (x) {
      return !root.service.subjectDetail(x)
    })
    if (missing.length === 0) return
    hydratingLinks = true
    root.service.loadDetail(missing.slice(0, 100))
  }

  function open(payloadJson) {
    closingFromHost = false
    opened = true
    resetNav()
    if (service) service.refreshAll()
    Qt.callLater(applyFocus)
  }

  function close() {
    closingFromHost = true
    opened = false
    closingFromHost = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  // Lets keybinds (and debugging) drive the app straight to a view:
  //   omarchy-shell -q io.github.aphelion-studios.omakani.app browse 7
  //   omarchy-shell -q io.github.aphelion-studios.omakani.app subject 440
  IpcHandler {
    target: "io.github.aphelion-studios.omakani.app"

    function home(): void { root.open(""); root.resetNav() }
    function browse(level: string): void {
      root.open("")
      root.resetNav()
      root.goBrowse(parseInt(level, 10) || (root.service ? root.service.level : 1))
    }
    function subject(id: string): void {
      root.open("")
      root.resetNav()
      root.goSubject(parseInt(id, 10))
    }
    function quiz(id: string, type: string): void {
      root.open("")
      root.resetNav()
      root.goQuiz(parseInt(id, 10), type)
    }
    function qanswer(text: string): string {
      if (root.view !== "quiz") return "not in a quiz"
      quizCard.typeAndSubmit(text)
      return quizCard.phase + (quizCard.nudge ? " (" + quizCard.nudge + ")" : "")
    }
    function state(): string {
      return JSON.stringify({
        opened: root.opened,
        view: root.view,
        stackDepth: root.navStack.length,
        page: root.currentPage,
        detailError: root.service ? root.service.detailError : "",
        browseError: root.service ? root.service.browseError : "",
        browseCursor: levelBrowser.cursor,
        browseRows: levelBrowser.rows.length,
        browseKeyFocus: levelBrowser.hasKeyFocus
      })
    }
  }

  Connections {
    target: root.service
    enabled: root.service !== null
    function onDetailReady(ids) {
      if (root.hydratingLinks) {
        root.hydratingLinks = false
        return
      }
      root.hydrateLinks()
    }
  }

  FloatingWindow {
    id: window
    visible: root.opened
    title: "OmaKani"
    color: root.bg
    implicitWidth: 1120
    implicitHeight: 780
    minimumSize: Qt.size(720, 560)

    onVisibleChanged: {
      if (!visible && root.opened && !root.closingFromHost) root.requestClose()
    }

    Rectangle {
      anchors.fill: parent
      color: root.bg
    }

    FocusScope {
      id: focusScope
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: {
        if (root.navStack.length > 1) root.popPage()
        else root.requestClose()
      }
      Keys.onPressed: function (e) {
        // On the home screen only; the browser and subject page own their keys.
        if (root.view !== "home") return
        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.text === "b") {
          if (root.service && root.service.configured)
            root.goBrowse(root.service.level || 1)
          e.accepted = true
        }
      }

      // ---- top strip: back + breadcrumb ----
      Item {
        id: topStrip
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.space(44)
        z: 2

        Row {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(18)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(12)

          Text {
            visible: root.navStack.length > 1
            text: "‹ Back"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(6)
              cursorShape: Qt.PointingHandCursor
              onClicked: root.popPage()
            }
          }

          Text {
            text: {
              if (root.view === "browse") return "OmaKani  /  Level " + root.currentPage.level
              if (root.view === "subject") return "OmaKani  /  Subject"
              return "OmaKani"
            }
            color: Qt.darker(root.fg, 1.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        Text {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(18)
          anchors.verticalCenter: parent.verticalCenter
          text: "Esc to " + (root.navStack.length > 1 ? "go back" : "close")
          color: Qt.darker(root.fg, 1.9)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // ---- page area ----
      Item {
        id: pageArea
        anchors.top: topStrip.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom

        // -------------------------------------------------- HOME
        Column {
          visible: root.view === "home"
          anchors.centerIn: parent
          spacing: Style.space(18)
          width: Math.min(parent.width - Style.space(80), Style.space(520))

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "OmaKani"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            text: {
              if (!root.service) return "Connecting to the service…"
              if (!root.service.configured) return "Add your API token from the bar widget first."
              var s = root.service
              return s.username + "   ·   Level " + s.level + "\n"
                + s.reviewsNow + " reviews   ·   " + s.lessonsNow + " lessons ready"
            }
          }

          // Start Lessons / Start Reviews — shown for whichever queue has
          // something waiting. Interim: opens the session on wanikani.com
          // until the in-shell flow lands.
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(12)
            visible: !!root.service && root.service.configured
              && (root.startLessons || root.startReviews)

            Repeater {
              model: {
                var out = []
                if (root.startLessons)
                  out.push({ text: "Start Lessons", url: "https://www.wanikani.com/subjects/lesson" })
                if (root.startReviews)
                  out.push({ text: "Start Reviews", url: "https://www.wanikani.com/subjects/review" })
                return out
              }
              delegate: Rectangle {
                width: startLabel.implicitWidth + Style.space(44)
                height: Style.space(40)
                radius: Style.space(6)
                color: startHover.containsMouse
                  ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.24)
                  : Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.14)
                border.width: 1
                border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.4)

                Text {
                  id: startLabel
                  anchors.centerIn: parent
                  text: modelData.text + "  ›"
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                MouseArea {
                  id: startHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: Quickshell.execDetached(["xdg-open", String(modelData.url)])
                }
              }
            }
          }

          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: !!root.service && root.service.configured
            width: browseLabel.implicitWidth + Style.space(40)
            height: Style.space(40)
            radius: Style.space(6)
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, browseHover.containsMouse ? 0.14 : 0.08)
            border.width: 1
            border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.25)

            Text {
              id: browseLabel
              anchors.centerIn: parent
              text: "Browse subjects"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            MouseArea {
              id: browseHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.goBrowse(root.service ? (root.service.level || 1) : 1)
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: !!root.service && root.service.configured
            text: "Lessons and reviews land here next."
            color: Qt.darker(root.fg, 1.9)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // -------------------------------------------------- BROWSE
        LevelBrowser {
          id: levelBrowser
          visible: root.view === "browse"
          anchors.fill: parent
          service: root.service
          level: root.view === "browse" ? root.currentPage.level : 1
          fg: root.fg
          pageBg: root.bg
          fontFamily: root.fontFamily
          jpFamily: root.jpFamily
          radicalColor: root.radicalColor
          kanjiColor: root.kanjiColor
          vocabColor: root.vocabColor
          onOpenSubject: function (subjectId) { root.goSubject(subjectId) }
          onChangeLevel: function (newLevel) {
            var next = root.navStack.slice()
            next[next.length - 1] = { view: "browse", level: newLevel }
            root.navStack = next
            if (root.service) root.service.loadBrowse(newLevel)
          }
          onVisibleChanged: if (visible) Qt.callLater(focusGrid)
        }

        // -------------------------------------------------- SUBJECT
        SubjectPage {
          id: subjectPage
          visible: root.view === "subject"
          anchors.fill: parent
          service: root.service
          subject: (root.view === "subject" && root.service)
            ? root.service.subjectDetail(root.currentPage.id) : null
          pageBg: root.bg
          fg: root.fg
          fontFamily: root.fontFamily
          jpFamily: root.jpFamily
          radicalColor: root.radicalColor
          kanjiColor: root.kanjiColor
          vocabColor: root.vocabColor
          onNavigate: function (subjectId) { root.goSubject(subjectId) }
          onVisibleChanged: if (visible) Qt.callLater(focusPage)
        }

        // loading / empty state for the subject page
        Text {
          anchors.centerIn: parent
          visible: root.view === "subject" && !subjectPage.subject
          text: (root.service && root.service.detailError)
            ? root.service.detailError : "Loading subject…"
          color: Qt.darker(root.fg, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        // -------------------------------------------------- QUIZ (primitive)
        QuizCard {
          id: quizCard
          visible: root.view === "quiz"
          anchors.fill: parent
          service: root.service
          subject: (root.view === "quiz" && root.service)
            ? root.service.subjectDetail(root.currentPage.id) : null
          studyMaterial: subject && subject.study_material ? subject.study_material : null
          questionType: root.view === "quiz" ? root.currentPage.quizType : "meaning"
          pageBg: root.bg
          fg: root.fg
          fontFamily: root.fontFamily
          jpFamily: root.jpFamily
          radicalColor: root.radicalColor
          kanjiColor: root.kanjiColor
          vocabColor: root.vocabColor
          onAdvance: root.popPage()
          onWrapUp: root.popPage()
          onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
        }

        Text {
          anchors.centerIn: parent
          visible: root.view === "quiz" && !quizCard.subject
          text: (root.service && root.service.detailError)
            ? root.service.detailError : "Loading…"
          color: Qt.darker(root.fg, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }
    }
  }
}
