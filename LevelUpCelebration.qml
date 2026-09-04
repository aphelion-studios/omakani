import QtQuick
import qs.Commons
import "Model.js" as Model

// The main window's level-up celebration, in place of the wordmark/greeting
// on a fresh level-up. WaniKani's own badge/ribbon/mascot artwork -- imported
// once via `wanikani.py import-levelup-image` (see its module docstring in
// wanikani.py for why this can't be fetched automatically) -- with the level
// number and a few twinkling stars layered on top in QML, since neither is
// baked into the reusable template (one import covers every future level).
// Stays until dismissed via the X, same as the website.
Item {
  id: root

  property int level: 0
  property string imagePath: ""
  property color fg: Color.foreground
  // the caption's ink -- the source SVG leaves this text with no fill at
  // all (SVG defaults to black, invisible on a dark theme), so the caller
  // hands in whatever it uses for text on its own vivid-coloured surfaces
  property color textColor: "#fcfdfd"
  property string jpFamily: Qt.fontFamilies().indexOf("Noto Sans JP") >= 0
    ? "Noto Sans JP" : "Noto Sans CJK JP"

  signal dismissed()

  // the template's own viewBox is 1610.09 x 600 -- match it so the image
  // fills these bounds exactly with no letterboxing, keeping the fractional
  // positions below aligned to the real artwork
  readonly property real artAspect: 1610.09 / 600
  implicitHeight: width / artAspect
  height: implicitHeight

  // the directory `import-levelup-image` drops the template *and* the
  // pieces isolated from it (levelup_f1.svg, levelup_sparkle-1.svg, ...)
  // into -- same directory, so this is just string surgery on the one
  // path the service already hands over
  readonly property string cacheDir: {
    var i = root.imagePath.lastIndexOf("/")
    return i >= 0 ? root.imagePath.substring(0, i) : ""
  }
  function pieceSource(name) {
    return root.cacheDir !== "" ? "file://" + root.cacheDir + "/levelup_" + name + ".svg" : ""
  }
  // how far the mascots' flag/horn props bounce -- the source moves them
  // +/-3 of its own 600-tall viewBox, which is only a fraction of a pixel
  // at this size; nudged up a bit so the wobble actually reads
  readonly property real propBounce: Math.max(1.5, root.height * 0.02)

  Image {
    id: art
    anchors.fill: parent
    source: root.imagePath !== "" ? "file://" + root.imagePath : ""
    fillMode: Image.PreserveAspectFit
    sourceSize.width: 1200
    smooth: true
    asynchronous: true
  }

  // four "sparkle" flourishes -- the source only animates these through a
  // CSS stroke-dashoffset wipe with no static rest frame (blank without
  // that animation running), so their clip-path shapes -- filled solid
  // instead of used as a mask -- stand in as a twinkling accent shape
  Repeater {
    model: [
      { cid: "sparkle-1", delay: 0 },
      { cid: "sparkle-2", delay: 500 },
      { cid: "sparkle-3", delay: 1000 },
      { cid: "sparkle-4", delay: 1500 }
    ]
    delegate: Image {
      id: spark
      width: root.width
      height: root.height
      source: root.pieceSource(modelData.cid)
      fillMode: Image.PreserveAspectFit
      sourceSize.width: 1200
      smooth: true
      asynchronous: true
      opacity: 0

      SequentialAnimation {
        running: root.visible
        loops: Animation.Infinite
        PauseAnimation { duration: modelData.delay }
        NumberAnimation { target: spark; property: "opacity"; from: 0; to: 1
          duration: 350; easing.type: Easing.OutCubic }
        PauseAnimation { duration: 550 }
        NumberAnimation { target: spark; property: "opacity"; from: 1; to: 0
          duration: 350; easing.type: Easing.InCubic }
        PauseAnimation { duration: 900 }
      }
    }
  }

  // the four mascots' flag/horn props -- a small continuous bounce, same
  // as the source's own bounce-animation (0.2s each way, staggered)
  Repeater {
    model: [
      { pid: "f1", delay: 0 },
      { pid: "f2", delay: 300 },
      { pid: "f3", delay: 100 },
      { pid: "f4", delay: 0 }
    ]
    delegate: Image {
      id: prop
      width: root.width
      height: root.height
      source: root.pieceSource(modelData.pid)
      fillMode: Image.PreserveAspectFit
      sourceSize.width: 1200
      smooth: true
      asynchronous: true

      SequentialAnimation {
        running: root.visible
        loops: Animation.Infinite
        PauseAnimation { duration: modelData.delay }
        NumberAnimation { target: prop; property: "y"; from: -root.propBounce; to: root.propBounce
          duration: 200; easing.type: Easing.InOutQuad }
        NumberAnimation { target: prop; property: "y"; from: root.propBounce; to: -root.propBounce
          duration: 200; easing.type: Easing.InOutQuad }
      }
    }
  }

  // the level number -- not baked into the template, so it's rendered here,
  // roughly centred on the ribbon (the ribbon's own curve is gentle enough
  // that a flat centred line reads the same at this size)
  Text {
    anchors.horizontalCenter: parent.horizontalCenter
    y: root.height * 0.685
    text: Model.kanjiNumeral(root.level)
    color: "#fcfdfd"
    font.family: root.jpFamily
    font.pixelSize: Math.max(10, root.height * 0.1)
    font.bold: true
    style: Text.Raised
    styleColor: Qt.rgba(0, 0, 0, 0.35)
  }

  // the "congratulations" caption -- also not baked into the template (see
  // textColor above), at the same spot the original sat, near the bottom
  // of the source artwork's own viewBox
  Text {
    anchors.horizontalCenter: parent.horizontalCenter
    y: root.height * 0.85
    text: "レベルアップおめでとう！"
    color: root.textColor
    font.family: root.jpFamily
    font.pixelSize: Math.max(10, root.height * 0.09)
    font.bold: true
  }

  // four twinkling stars, where the template's own (stripped) decorative
  // stars sat -- real motion, not just a static illustration
  Repeater {
    model: [
      { fx: 0.256, fy: 0.212, delay: 0 },
      { fx: 0.737, fy: 0.237, delay: 450 },
      { fx: 0.154, fy: 0.403, delay: 900 },
      { fx: 0.820, fy: 0.403, delay: 1350 }
    ]
    delegate: Text {
      id: star
      x: root.width * modelData.fx - width / 2
      y: root.height * modelData.fy - height / 2
      text: "✦"
      color: "#ffbf59"
      font.pixelSize: Math.max(8, root.height * 0.09)
      opacity: 0
      scale: 0.5
      transformOrigin: Item.Center

      SequentialAnimation {
        running: root.visible
        loops: Animation.Infinite
        PauseAnimation { duration: modelData.delay }
        ParallelAnimation {
          NumberAnimation { target: star; property: "opacity"; from: 0; to: 1
            duration: 450; easing.type: Easing.OutCubic }
          NumberAnimation { target: star; property: "scale"; from: 0.5; to: 1
            duration: 450; easing.type: Easing.OutCubic }
        }
        PauseAnimation { duration: 850 }
        ParallelAnimation {
          NumberAnimation { target: star; property: "opacity"; from: 1; to: 0
            duration: 450; easing.type: Easing.InCubic }
          NumberAnimation { target: star; property: "scale"; from: 1; to: 0.5
            duration: 450; easing.type: Easing.InCubic }
        }
        PauseAnimation { duration: 700 }
      }
    }
  }

  // dismiss -- stays up until this is pressed, same as the website
  Rectangle {
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.margins: Style.space(2)
    width: Style.space(20)
    height: width
    radius: width / 2
    color: closeHover.containsMouse
      ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.18)
      : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
    Behavior on color { ColorAnimation { duration: 100 } }

    Text {
      anchors.centerIn: parent
      text: "✕"
      color: root.fg
      font.pixelSize: Style.font.caption
    }
    MouseArea {
      id: closeHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.dismissed()
    }
  }
}
