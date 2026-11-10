import QtQuick
import qs.Commons
import qs.Ui

// Battery icon (or a bolt, per the "icon" setting) plus the active limit when
// one is set (quiet at stock 100). Click opens the overlay with controls and
// health stats.
BarWidget {
  id: root
  moduleName: "io.github.alexdont.battery-limiter"

  // Resolved lazily and re-tried: at shell startup the widget can be built
  // before the service registers, and a one-shot binding would then hold
  // null forever (same defense as the color-studio widget).
  property var svc: null

  function resolveSvc() {
    if (!svc && bar && bar.shell) svc = bar.shell.serviceFor(moduleName)
    return svc
  }

  onBarChanged: resolveSvc()
  Component.onCompleted: resolveSvc()

  Timer {
    interval: 400
    repeat: true
    running: !root.svc
    onTriggered: root.resolveSvc()
  }

  // A bolt keeps the widget apart from the stock battery indicator next to it.
  readonly property string glyph: root.setting("icon", "battery") === "bolt" ? "󱐋" : "󰁹"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // setting() reads the per-widget shell.json entry (schema toggle in the
    // manifest); a stock 100% limit stays icon-only regardless.
    text: root.setting("showLimit", true) && root.svc && root.svc.supported && root.svc.limit < 100
      ? root.glyph + " " + root.svc.limit : root.glyph
    horizontalMargin: 7.5
    onPressed: function(b) {
      var s = root.resolveSvc()
      if (s) s.toggleOverlay()
    }
  }
}
