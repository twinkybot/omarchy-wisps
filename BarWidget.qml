import QtQuick
import qs.Commons
import qs.Ui

// Bar pill for the Wisps overlay. Left click opens the tuning popup; middle
// click quick-toggles the wisp on/off. Settings persist through the standard
// bar-widget `settings` object and are pushed to the running service
// (Wisps.qml) via applyConfig().
BarWidget {
  id: root
  moduleName: "bert.wisps"

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null

  readonly property var defaults: ({
    enabled: true,
    size: "Medium",
    corner: "Bottom right",
    layer: "In front of windows",
    follow: true,
    glow: true,
    haunt: true,
    preview: "Off"
  })

  function effective() {
    var out = {}
    var s = root.settings || {}
    for (var k in defaults) out[k] = (s[k] !== undefined ? s[k] : defaults[k])
    return out
  }

  function pushConfig() {
    if (service && service.applyConfig) service.applyConfig(effective())
  }

  function setKey(key, value) {
    var entry = { id: root.moduleName }
    var s = root.settings || {}
    for (var k in s) if (k !== "id") entry[k] = s[k]
    entry[key] = value
    root.settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(root.moduleName, entry)
    pushConfig()
  }

  function injectPanel() {
    var t = panelLoader.item
    if (!t) return
    if ("bar" in t) t.bar = root.bar
    if ("anchorItem" in t) t.anchorItem = button
    if ("hostWidget" in t) t.hostWidget = root
    if ("widget" in t) t.widget = root
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey() }
  function close() { if (panelLoader.item && panelLoader.item.close) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle() }

  // The pill reports the loudest thing happening across every session, so a
  // wisp hidden behind a fullscreen window still gets your attention.
  readonly property var live: service && service.wisps ? service.wisps : []
  readonly property string worst: {
    var order = ["attention", "trouble", "working", "done", "idle"]
    for (var i = 0; i < order.length; i++)
      for (var j = 0; j < live.length; j++)
        if (live[j].state === order[i]) return order[i]
    return "idle"
  }
  readonly property int sessionCount: service && service.sessions ? service.sessions.length : 0

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: { injectPanel(); pushConfig() }
  onSettingsChanged: pushConfig()
  onServiceChanged: pushConfig()
  Component.onCompleted: {
    // "Preview a state" is a debug look, not a mode. It suppresses real
    // session polling, so if it survived a restart a user who peeked at one
    // state once would silently never see their agent again.
    if (effective().preview !== "Off") setKey("preview", "Off")
    pushConfig()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Popup.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "👻"
    horizontalMargin: 8.75
    dimmed: !root.effective().enabled || root.worst === "idle"
    tooltipText: {
      if (!root.effective().enabled) return "Wisps (off)"
      var n = root.sessionCount
      var who = n === 0 ? "no sessions" : n === 1 ? "1 session" : n + " sessions"
      var what = root.worst === "attention" ? "waiting on you"
               : root.worst === "trouble" ? "something went wrong"
               : root.worst === "working" ? "working"
               : root.worst === "done" ? "just finished"
               : "dozing"
      return "Wisps — " + what + " (" + who + ")"
    }

    onPressed: function (b) {
      if (!root.bar) return
      if (b === Qt.MiddleButton) root.setKey("enabled", !root.effective().enabled)
      else root.togglePanel()
    }
  }
}
