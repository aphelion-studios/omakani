import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar widget and dashboard for OmaWaniKani. One entry point, like the
// first-party dropbox plugin: a quiet alligator-head mark that takes the accent
// colour while reviews (or lessons) are waiting, and a drop-down with the counts
// and the Upcoming Reviews forecast (day list -> hour breakdown, mirroring the
// website). The rest of the dashboard sections land here across phase 2.
Panel {
  id: root
  moduleName: "io.github.aphelion-studios.omawanikani"
  ipcTarget: "io.github.aphelion-studios.omawanikani"
  manageIpc: false

  // The helper lives next to this file. Resolving it off the component URL
  // works for a bar widget, which the host hands `bar` / `settings` but no
  // manifest to read `__sourceDir` from.
  readonly property string helperPath: String(Qt.resolvedUrl("wanikani.py")).replace(/^file:\/\//, "")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // WaniKani's subject-type colours, held a touch off their vivid web values so
  // they read on a dark bar without shouting. Used for Level Progress and the
  // Item Spread pills, where the colour carries meaning.
  readonly property color radicalColor: "#1f93e6"
  readonly property color kanjiColor: "#e42e9c"
  readonly property color vocabColor: "#9457e8"

  function typeColor(type) {
    if (type === "radical" || type === "radicals") return radicalColor
    if (type === "kanji") return kanjiColor
    return vocabColor
  }

  readonly property bool showLessons: setting("showLessons", true) === true
  readonly property bool hideWhenZero: setting("hideWhenZero", false) === true

  readonly property bool anythingDue: wk.reviewsNow > 0 || (showLessons && wk.lessonsNow > 0)
  readonly property bool markActive: wk.configured && anythingDue && !wk.vacation

  // The mark always shows while unconnected (so the panel stays reachable to
  // paste a token) and while something is due; hideWhenZero only hides a
  // connected, caught-up widget.
  visible: !wk.configured || !hideWhenZero || anythingDue
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- panel cursor -------------------------------------------------------

  property bool cursorActive: false
  property int cursorIndex: 0
  readonly property var sections: wk.configured ? ["refresh", "forget"] : ["token"]
  readonly property string currentSection: sections.length === 0
    ? ""
    : String(sections[Math.max(0, Math.min(sections.length - 1, cursorIndex))])

  readonly property string statusText: Model.statusLine(wk.view)
  readonly property bool statusIsError: wk.lastError !== ""

  function sectionHasCursor(name) { return cursorActive && currentSection === name }

  function focusSection(name) {
    var index = sections.indexOf(name)
    if (index === -1) return
    cursorActive = true
    cursorIndex = index
  }

  function moveCursor(dy) {
    cursorActive = true
    if (dy === 0 || sections.length === 0) return
    cursorIndex = Math.max(0, Math.min(sections.length - 1, cursorIndex + dy))
  }

  function activateCursor() {
    var section = currentSection
    if (section === "token") tokenField.forceActiveFocus()
    else if (section === "refresh") wk.refresh()
    else if (section === "forget") wk.clearToken()
  }

  function commitToken() {
    var token = tokenField.text
    if (String(token).trim() === "") return
    tokenField.text = ""
    tokenField.focus = false
    wk.saveToken(token)
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = 0
    upcomingDrill = -1
    if (panelFlick) panelFlick.contentY = 0
    wk.refreshAll()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Which day the Upcoming Reviews section is drilled into; -1 is the day list.
  property int upcomingDrill: -1

  Service {
    id: wk
    settings: root.settings
    helperPath: root.helperPath
    onTokenRejected: function(message) {
      Qt.callLater(function() { tokenField.forceActiveFocus() })
    }
  }

  // Seconds only matter while the popup is open and counting down to the next
  // review; nothing else needs them.
  SystemClock {
    id: clock
    precision: root.opened ? SystemClock.Seconds : SystemClock.Minutes
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { wk.refreshAll(); return "ok" }
    function status(): string {
      if (!wk.configured) return "not connected"
      return wk.lessonsNow + " lessons, " + wk.reviewsNow + " reviews"
    }
  }

  // ---- the recolourable mark -------------------------------------------------

  // The alligator head fills its viewBox, so it needs to run a touch smaller
  // than a nominal bar glyph (which leaves ink room inside its em) to weigh the
  // same as the Nerd Font icons around it.
  readonly property int barMarkHeight: Math.round(Style.bar.iconFont * 1.02)

  component Mark: Item {
    id: markRoot
    // `size` is the mark's height; the alligator head is taller than it is wide,
    // so the box it occupies is narrower and the bar keeps its neighbours close.
    property real size: root.barMarkHeight
    readonly property real aspect: 0.78
    property color tint: root.foreground
    implicitWidth: Math.round(size * aspect)
    implicitHeight: size

    Image {
      id: markSource
      anchors.fill: parent
      source: Qt.resolvedUrl("icon.svg")
      sourceSize.width: markRoot.size * 2
      sourceSize.height: markRoot.size * 2
      fillMode: Image.PreserveAspectFit
      smooth: true
      visible: false
    }
    MultiEffect {
      anchors.fill: parent
      source: markSource
      colorization: 1.0
      colorizationColor: markRoot.tint
      Behavior on colorizationColor { ColorAnimation { duration: 160 } }
    }
  }

  // ---- bar button ---------------------------------------------------------

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // `text` feeds the pill sizing fallback and nothing else; the visible mark
    // is the child below, and labelVisible is off.
    text: "wanikani"
    labelVisible: false
    fixedWidth: Math.round(root.barMarkHeight * 0.78) + Style.space(10)
    tooltipText: Model.barTooltip(wk.view, clock.date)
    onPressed: function(pressedButton) {
      if (pressedButton === Qt.MiddleButton) wk.refresh()
      else root.toggle()
    }

    Mark {
      anchors.centerIn: parent
      tint: root.markActive ? root.accent
        : (!wk.configured
           ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.7)
           : root.foreground)
    }
  }

  // ---- dashboard --------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: tokenField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") wk.refreshAll()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            foreground: root.foreground
            fontFamily: root.fontFamily
            title: wk.configured
              ? Model.plural(wk.reviewsNow, "review", "reviews")
              : "Connect WaniKani"
            meta: {
              if (!wk.configured) return "read-only API token"
              if (wk.vacation) return "vacation mode"
              if (wk.reviewsNow > 0)
                return wk.lessonsNow > 0
                  ? "ready now  ·  " + Model.plural(wk.lessonsNow, "lesson", "lessons")
                  : "ready now"
              var rel = Model.relativeTime(wk.nextReviewsAt, clock.date)
              return rel === "" ? "all caught up" : "next review " + rel
            }
            iconOpacity: wk.configured && !root.anythingDue ? 0.5 : 1.0
            iconComponent: Component {
              Mark {
                size: Style.font.displayLarge
                tint: root.markActive ? root.accent : root.foreground
              }
            }
          }

          Text {
            visible: root.statusText !== ""
            width: parent.width
            text: root.statusText
            color: root.statusIsError ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ----------------------------------------------------- connect

          Column {
            visible: !wk.configured
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "API TOKEN"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: tokenField
                Layout.fillWidth: true
                password: true
                placeholderText: "Paste a WaniKani API token"
                foreground: root.foreground
                font.family: root.fontFamily
                enabled: !wk.actionBusy
                hasCursor: !activeFocus && root.sectionHasCursor("token")
                onHoveredChanged: if (hovered) root.focusSection("token")
                onAccepted: root.commitToken()
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) { focus = false; event.accepted = true }
                }
              }

              Button {
                text: "Connect"
                iconText: "󰌆"
                bordered: true
                enabled: !wk.actionBusy && tokenField.text !== ""
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.commitToken()
              }
            }

            Text {
              width: parent.width
              text: "wanikani.com → Settings → API Tokens → Generate a new token. "
                + "Read-only is enough for the dashboard. Stored in "
                + "~/.config/omarchy/wanikani.json with 0600 permissions."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------------------------------------------------- counts

          RowLayout {
            visible: wk.configured
            width: parent.width
            spacing: Style.space(12)

            Total {
              label: "LESSONS NOW"
              value: String(wk.lessonsNow)
              Layout.fillWidth: true
            }
            Total {
              label: "REVIEWS NOW"
              value: String(wk.reviewsNow)
              Layout.fillWidth: true
            }
          }

          PanelSeparator {
            visible: wk.configured
            foreground: root.foreground
          }

          // ------------------------------------------ upcoming reviews

          Column {
            id: upcomingBlock
            visible: wk.configured
            width: parent.width
            spacing: Style.space(8)

            readonly property var drillDay: root.upcomingDrill >= 0
              && root.upcomingDrill < wk.upcoming.length
              ? wk.upcoming[root.upcomingDrill] : null

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              PanelActionButton {
                visible: upcomingBlock.drillDay !== null
                iconText: "󰅁"
                tooltipText: "Back to the week"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.upcomingDrill = -1
              }

              PanelSectionHeader {
                text: upcomingBlock.drillDay
                  ? String(upcomingBlock.drillDay.labelLong || upcomingBlock.drillDay.label).toUpperCase()
                  : "UPCOMING REVIEWS"
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.fillWidth: true
              }

              Text {
                visible: wk.dashboardLoaded
                text: {
                  var d = upcomingBlock.drillDay
                  var added = d ? d.count : wk.upcomingTotal
                  return added > 0 ? "+" + added : "—"
                }
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            UpcomingRows {
              width: parent.width
              day: upcomingBlock.drillDay
              onDrillInto: function (index) { root.upcomingDrill = index }
            }

            Text {
              visible: wk.dashboardLoaded && upcomingBlock.drillDay === null
                && wk.upcomingTotal === 0
              width: parent.width
              text: {
                var rel = Model.relativeTime(wk.nextReviewsAt, clock.date)
                return "Nothing due in the next 5 days"
                  + (rel === "" || rel === "now" ? "." : " — next review " + rel + ".")
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              visible: !wk.dashboardLoaded
              width: parent.width
              text: wk.coldStart || wk.dashboardBusy
                ? "Building your dashboard… this first sync can take a few seconds."
                : "Loading…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator {
            visible: wk.configured
            foreground: root.foreground
          }

          // ----------------------------------------- level progress

          Column {
            visible: wk.configured && wk.dashboardLoaded
            width: parent.width
            spacing: Style.space(8)

            readonly property var lp: wk.levelProgress
            readonly property int gate: Number(lp.kanjiToLevelUp) || 0

            PanelSectionHeader {
              text: "LEVEL " + wk.level + " PROGRESS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            ProgressRow {
              width: parent.width
              label: "Radicals"
              tint: root.radicalColor
              passed: Number(parent.lp.radicals ? parent.lp.radicals.passed : 0)
              total: Number(parent.lp.radicals ? parent.lp.radicals.total : 0)
            }
            ProgressRow {
              width: parent.width
              label: "Kanji"
              tint: root.kanjiColor
              passed: Number(parent.lp.kanji ? parent.lp.kanji.passed : 0)
              total: Number(parent.lp.kanji ? parent.lp.kanji.total : 0)
            }
            ProgressRow {
              width: parent.width
              label: "Vocabulary"
              tint: root.vocabColor
              passed: Number(parent.lp.vocabulary ? parent.lp.vocabulary.passed : 0)
              total: Number(parent.lp.vocabulary ? parent.lp.vocabulary.total : 0)
            }

            Text {
              width: parent.width
              topPadding: Style.space(2)
              text: parent.gate > 0
                ? "Guru " + parent.gate + " more kanji to reach level " + (wk.level + 1)
                : "Kanji gate cleared — level " + (wk.level + 1) + " is unlocked."
              color: parent.gate > 0 ? root.foreground : root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator {
            visible: wk.configured && wk.dashboardLoaded
            foreground: root.foreground
          }

          // -------------------------------------------- item spread

          Column {
            visible: wk.configured && wk.dashboardLoaded
            width: parent.width
            spacing: Style.space(6)

            RowLayout {
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: "ITEM SPREAD"
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.fillWidth: true
              }
              Repeater {
                model: [
                  { t: "Rad", c: root.radicalColor },
                  { t: "Kan", c: root.kanjiColor },
                  { t: "Voc", c: root.vocabColor },
                ]
                delegate: Row {
                  spacing: Style.space(3)
                  Rectangle {
                    width: Style.space(6); height: Style.space(6); radius: width / 2
                    color: modelData.c
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: modelData.t
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            SpreadRow { width: parent.width; label: "Apprentice";   bucket: wk.itemSpread.apprentice }
            SpreadRow { width: parent.width; label: "Guru";         bucket: wk.itemSpread.guru }
            SpreadRow { width: parent.width; label: "Master";       bucket: wk.itemSpread.master }
            SpreadRow { width: parent.width; label: "Enlightened";  bucket: wk.itemSpread.enlightened }
            SpreadRow { width: parent.width; label: "Burned";       bucket: wk.itemSpread.burned }
          }

          PanelSeparator {
            visible: wk.configured && wk.dashboardLoaded
            foreground: root.foreground
          }

          // ---------------------------------------------------- footer

          RowLayout {
            visible: wk.configured
            width: parent.width
            spacing: Style.space(8)

            Text {
              Layout.fillWidth: true
              text: {
                var parts = []
                if (wk.level) parts.push("󰃀  Level " + wk.level)
                if (wk.username) parts.push(wk.username)
                if (wk.vacation) parts.push("vacation")
                return parts.join("   ·   ")
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            PanelActionButton {
              iconText: "󰑐"
              tooltipText: "Refresh"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !wk.refreshing
              Layout.alignment: Qt.AlignVCenter
              onClicked: wk.refreshAll()
            }

            PanelActionButton {
              iconText: "󰏌"
              tooltipText: "Open wanikani.com"
              foreground: root.foreground
              fontFamily: root.fontFamily
              Layout.alignment: Qt.AlignVCenter
              onClicked: Quickshell.execDetached(["xdg-open", "https://www.wanikani.com/dashboard"])
            }

            PanelActionButton {
              iconText: "󰌆"
              tooltipText: "Forget the stored API token"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !wk.actionBusy
              Layout.alignment: Qt.AlignVCenter
              onClicked: wk.clearToken()
            }
          }
        }
      }
    }
  }

  // ---- small components ------------------------------------------------

  component Total: Column {
    id: total
    property string label: ""
    property string value: ""
    spacing: Style.space(2)

    Text {
      text: total.label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }
    Text {
      text: total.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.displayLarge
    }
  }

  // One Level Progress line: "Radicals  19 / 20" over a tinted fill bar.
  component ProgressRow: Column {
    id: pr
    property string label: ""
    property color tint: root.accent
    property int passed: 0
    property int total: 0
    readonly property real frac: total > 0 ? Math.max(0, Math.min(1, passed / total)) : 0
    spacing: Style.space(3)

    RowLayout {
      width: parent.width
      Text {
        text: pr.label
        color: root.foreground
        opacity: 0.9
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.fillWidth: true
      }
      Text {
        text: pr.passed + " / " + pr.total
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
    }

    Rectangle {
      width: parent.width
      height: Style.space(4)
      radius: 2
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
      Rectangle {
        width: Math.round(parent.width * pr.frac)
        height: parent.height
        radius: parent.radius
        color: pr.tint
      }
    }
  }

  // A coloured number chip in the Item Spread table.
  component Pill: Rectangle {
    property int value: 0
    property color tint: root.accent
    readonly property bool filled: value > 0
    implicitHeight: Style.space(16)
    Layout.fillWidth: true
    Layout.minimumWidth: Style.space(24)
    radius: Style.space(4)
    color: filled ? tint
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
    Text {
      anchors.centerIn: parent
      text: String(parent.value)
      color: parent.filled ? "#ffffff" : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  // One Item Spread row: stage name, a chip per subject type, the stage total.
  component SpreadRow: RowLayout {
    id: sr
    property string label: ""
    property var bucket: ({})
    readonly property int rad: Number(bucket && bucket.radicals) || 0
    readonly property int kan: Number(bucket && bucket.kanji) || 0
    readonly property int voc: Number(bucket && bucket.vocabulary) || 0
    readonly property int total: rad + kan + voc
    spacing: Style.space(5)

    Text {
      text: sr.label
      color: root.foreground
      opacity: 0.85
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      Layout.preferredWidth: Style.space(72)
    }

    Pill { value: sr.rad; tint: root.radicalColor }
    Pill { value: sr.kan; tint: root.kanjiColor }
    Pill { value: sr.voc; tint: root.vocabColor }

    Text {
      text: String(sr.total)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      horizontalAlignment: Text.AlignRight
      Layout.preferredWidth: Style.space(28)
    }
  }

  // Upcoming Reviews, the website's forecast widget: a day list, or one day's
  // hour-by-hour breakdown when `day` is set. Each row is
  // label | bar | +delta | cumulative | (chevron on the day list).
  component UpcomingRows: Column {
    id: rows
    property var day: null
    signal drillInto(int index)

    readonly property bool isWeek: day === null || day === undefined
    readonly property var model: isWeek ? wk.upcoming : (day.hours || [])
    readonly property real peak: {
      var maximum = 1
      for (var i = 0; i < model.length; i++)
        if (Number(model[i].count) > maximum) maximum = Number(model[i].count)
      return maximum
    }

    spacing: Style.space(3)
    visible: wk.dashboardLoaded && model.length > 0

    Repeater {
      model: rows.model
      delegate: Item {
        id: rowItem
        width: rows.width
        height: Style.space(19)
        readonly property int count: Number(modelData.count) || 0
        readonly property bool clickable: rows.isWeek && count > 0

        Rectangle {
          anchors.fill: parent
          anchors.leftMargin: -Style.space(4)
          anchors.rightMargin: -Style.space(4)
          radius: Style.cornerRadius
          color: hover.containsMouse && rowItem.clickable
            ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
            : "transparent"
        }

        RowLayout {
          anchors.fill: parent
          spacing: Style.space(8)

          Text {
            text: String(modelData.label || "")
            color: root.foreground
            opacity: 0.85
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            Layout.preferredWidth: Style.space(rows.isWeek ? 30 : 42)
          }

          Item {
            Layout.fillWidth: true
            implicitHeight: Style.space(10)
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              height: parent.height
              radius: 2
              width: rowItem.count > 0
                ? Math.max(3, parent.width * (rowItem.count / rows.peak))
                : 0
              color: root.accent
              opacity: 0.9
            }
          }

          Text {
            text: rowItem.count > 0 ? "+" + rowItem.count : ""
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            horizontalAlignment: Text.AlignRight
            Layout.preferredWidth: Style.space(32)
          }

          Text {
            text: String(modelData.cumulative)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignRight
            Layout.preferredWidth: Style.space(34)
          }

          Text {
            visible: rows.isWeek
            text: "󰅂"
            color: rowItem.clickable
              ? root.dim
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        MouseArea {
          id: hover
          anchors.fill: parent
          hoverEnabled: true
          enabled: rowItem.clickable
          cursorShape: Qt.PointingHandCursor
          onClicked: rows.drillInto(index)
        }
      }
    }
  }
}
