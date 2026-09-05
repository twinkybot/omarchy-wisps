import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Tuning popup for the Wisps overlay. Reads/writes through the host BarWidget
// (`widget.settings` / `widget.setKey`).
Panel {
  id: root
  moduleName: "bert.wisps"
  ipcTarget: "bert.wisps"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var widget: null
  readonly property var barIdentity: hostWidget || root

  function open() { root.controller.show() }
  function openFromHotkey() { root.open() }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  readonly property var cfg: (widget && widget.settings) ? widget.settings : ({})
  function val(k, dflt) { return cfg[k] !== undefined ? cfg[k] : dflt }
  function put(k, v) { if (widget && widget.setKey) widget.setKey(k, v) }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(336))
    contentHeight: panel.fittedContentHeight(col.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: col
        anchors.fill: parent
        spacing: Style.space(12)

        Text {
          text: "👻  Wisps"
          textFormat: Text.PlainText
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Toggle {
          width: parent.width
          label: "Show wisps"
          checked: root.val("enabled", true)
          onClicked: root.put("enabled", !checked)
        }

        Dropdown {
          width: parent.width
          label: "Size"
          value: root.val("size", "Medium")
          options: ["Small", "Medium", "Large"]
          onChanged: root.put("size", value)
        }

        Dropdown {
          width: parent.width
          label: "Where they perch"
          value: root.val("corner", "Bottom right")
          options: ["Top left", "Top middle", "Top right", "Bottom left", "Bottom middle", "Bottom right"]
          onChanged: root.put("corner", value)
        }

        Dropdown {
          width: parent.width
          label: "Layer"
          value: root.val("layer", "In front of windows")
          options: ["In front of windows", "On the desktop", "Above everything"]
          onChanged: root.put("layer", value)
        }

        Toggle {
          width: parent.width
          label: "Come to the cursor when needed"
          description: "Drifts over to your pointer when the agent is waiting on you"
          checked: root.val("follow", true)
          onClicked: root.put("follow", !checked)
        }

        Toggle {
          width: parent.width
          label: "Glow"
          checked: root.val("glow", true)
          onClicked: root.put("glow", !checked)
        }

        Toggle {
          width: parent.width
          label: "Linger when idle"
          description: "Keeps dozing on screen between sessions"
          checked: root.val("haunt", true)
          onClicked: root.put("haunt", !checked)
        }

        Dropdown {
          width: parent.width
          label: "Preview a state"
          value: root.val("preview", "Off")
          options: ["Off", "Dozing", "Working", "Needs you", "Done", "Trouble"]
          onChanged: root.put("preview", value)
        }
      }
    }
  }
}
