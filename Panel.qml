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
// first-party dropbox plugin: a quiet Crabigator mark that takes the accent
// colour while reviews (or lessons) are waiting, and a drop-down that shows the
// counts, the next-review countdown, a 24-hour forecast, and where you stand in
// the current level.
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
    if (panelFlick) panelFlick.contentY = 0
    wk.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

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
    function refresh(): string { wk.refresh(); return "ok" }
    function status(): string {
      if (!wk.configured) return "not connected"
      return wk.lessonsNow + " lessons, " + wk.reviewsNow + " reviews"
    }
  }

  // ---- the recolourable mark -------------------------------------------------

  component Mark: Item {
    id: markRoot
    property real size: Math.round(Style.bar.iconFont * 1.3)
    property color tint: root.foreground
    implicitWidth: size
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
    fixedWidth: Math.round(Style.bar.iconFont * 1.3) + Style.space(17)
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
        if (text === "r" || text === "R") wk.refresh()
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

          // -------------------------------------------------- forecast

          Column {
            visible: wk.configured
            width: parent.width
            spacing: Style.space(8)

            RowLayout {
              width: parent.width
              PanelSectionHeader {
                text: "NEXT 24 HOURS"
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.fillWidth: true
              }
              Text {
                text: wk.upcomingReviews > 0 ? "+" + wk.upcomingReviews : "nothing scheduled"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Forecast {
              width: parent.width
              bars: Model.forecastBars(wk.forecast, wk.reviewsNow)
              barColor: root.accent
            }

            Text {
              visible: wk.reviewsNow === 0
              width: parent.width
              text: {
                var rel = Model.relativeTime(wk.nextReviewsAt, clock.date)
                return rel === "" ? "No upcoming reviews." : "Next review " + rel + "."
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          PanelSeparator {
            visible: wk.configured
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
              onClicked: wk.refresh()
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

  component Forecast: Item {
    id: forecast
    property var bars: []
    property color barColor: root.accent
    readonly property int slots: Math.max(1, bars.length)
    readonly property real peak: {
      var maximum = 1
      for (var i = 0; i < bars.length; i++)
        if (bars[i].count > maximum) maximum = bars[i].count
      return maximum
    }
    implicitHeight: Style.space(44)
    visible: bars.length > 0

    Row {
      anchors.fill: parent
      spacing: 2

      Repeater {
        model: forecast.bars
        delegate: Item {
          width: (forecast.width - (forecast.slots - 1) * 2) / forecast.slots
          height: forecast.height

          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: Math.max(2, Math.round(parent.height * (modelData.count / forecast.peak)))
            radius: 1
            color: modelData.count > 0
              ? forecast.barColor
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
            opacity: modelData.count > 0 ? 0.9 : 0.6
          }
        }
      }
    }
  }
}
