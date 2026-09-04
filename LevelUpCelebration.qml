import QtQuick
import QtQuick.Shapes
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
  // +/-3 of its own 600-tall viewBox, close to a full pixel at this size;
  // 0.02 read as way too energetic, closer to the source's own proportion
  readonly property real propBounce: Math.max(0.6, root.height * 0.006)
  // viewBox units -> actual pixels, for the sparkles' hand-carried path data
  readonly property real vbScale: root.width / 1610.09

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
  // instead of used as a mask -- stand in as a twinkling accent shape.
  // Drawn as native QML Shapes (the path data straight from the source
  // SVG's own clip-path <path d="...">, level-independent like the rest of
  // the artwork) rather than loaded as separate tiny SVG files -- an
  // overlaid same-viewBox Image per sparkle intermittently rendered solid
  // black instead of its own fill while fading, which a Shape sidesteps
  // entirely since there's no image decode/cache involved at all.
  // the website's own version fills in from its inner (medal-facing) point
  // outward to full size, THEN empties back starting from that same inner
  // side too -- so the shrink has to anchor on the *outer* point (ox2/oy2,
  // the inner point reflected through the shape's own middle), not the
  // inner one, or the near-medal side would be the last bit left instead
  // of the first to go.
  Repeater {
    model: [
      { d: "m1000.65,75.85l143.08-66.22c9.53-4.41,20.76.68,23.72,10.76l6.55,22.34c2.67,9.11-2.55,18.66-11.66,21.34l-149.63,43.88c-8.55,2.51-17.6-1.94-20.85-10.24h0c-3.31-8.46.54-18.04,8.79-21.86Z", ox: 940, oy: 116, ox2: 1210, oy2: 4, delay: 0 },
      { d: "m626.53,97.7l1.31-2.47c4.46-8.38,1.64-18.78-6.44-23.77l-109.94-59.34c-9.18-5.67-21.26-2.04-25.79,7.76l-11.88,25.68c-4.63,10.01.75,21.79,11.34,24.85l120.52,36.13c8.18,2.36,16.89-1.33,20.88-8.84Z", ox: 663, oy: 111, ox2: 377, oy2: -11, delay: 500 },
      { d: "m486.07,166.36l113.17-16.23c5.69-.82,11.03,2.94,12.2,8.57h0c1.1,5.32-1.89,10.63-7,12.45l-108.94,38.82c-6.3,2.25-13.12-1.67-14.35-8.25l-4.22-22.59c-1.14-6.08,3.02-11.89,9.15-12.77Z", ox: 673, oy: 173, ox2: 407, oy2: 177, delay: 1000 },
      { d: "m1001.43,164.07h0c0,6.09,4.32,11.32,10.29,12.48l112.03,21.71c6.86,1.33,13.51-3.13,14.88-9.98l3.85-19.2c1.56-7.76-4.28-15.04-12.19-15.21l-115.87-2.52c-7.13-.15-12.99,5.58-12.99,12.71Z", ox: 940, oy: 173, ox2: 1210, oy2: 177, delay: 1500 }
    ]
    delegate: Shape {
      id: spark
      width: root.width
      height: root.height
      opacity: 0
      // 0 = collapsed to the active anchor (empty), 1 = full size -- the
      // anchor itself switches between the inner and outer point below
      property real revealT: 0
      property real anchorX: modelData.ox
      property real anchorY: modelData.oy
      preferredRendererType: Shape.CurveRenderer
      transform: [
        Scale { origin.x: spark.anchorX; origin.y: spark.anchorY
          xScale: spark.revealT; yScale: spark.revealT },
        Scale { xScale: root.vbScale; yScale: root.vbScale }
      ]

      ShapePath {
        fillColor: "#e243a2"
        strokeWidth: -1
        PathSvg { path: modelData.d }
      }

      SequentialAnimation {
        running: root.visible
        loops: Animation.Infinite
        PauseAnimation { duration: modelData.delay }
        PropertyAction { target: spark; property: "anchorX"; value: modelData.ox }
        PropertyAction { target: spark; property: "anchorY"; value: modelData.oy }
        ParallelAnimation {
          NumberAnimation { target: spark; property: "opacity"; from: 0; to: 1
            duration: 350; easing.type: Easing.OutCubic }
          NumberAnimation { target: spark; property: "revealT"; from: 0; to: 1
            duration: 350; easing.type: Easing.OutCubic }
        }
        PauseAnimation { duration: 550 }
        PropertyAction { target: spark; property: "anchorX"; value: modelData.ox2 }
        PropertyAction { target: spark; property: "anchorY"; value: modelData.oy2 }
        ParallelAnimation {
          NumberAnimation { target: spark; property: "opacity"; from: 1; to: 0
            duration: 350; easing.type: Easing.InCubic }
          NumberAnimation { target: spark; property: "revealT"; from: 1; to: 0
            duration: 350; easing.type: Easing.InCubic }
        }
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
      asynchronous: false

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
    y: root.height * 0.58
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
    y: root.height * 0.9
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
