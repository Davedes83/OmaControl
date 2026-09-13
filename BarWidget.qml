import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "davedes.omcontrol"

  property var lastData: null
  property bool privacyAlert: false
  property string lastError: ""
  property var privacyDevices: []
  property var privacyEvents: []
  property var barStats: ["cpu", "cputemp"]
  property string barStatMode: "name"
  property bool barShowBell: true
  property int unreadCount: 0
  property string bellColorToken: "dim"

  // Color matches the event-kind hue used for chart markers (HistoryGraph.evColor).
  readonly property color bellColor: {
    switch (root.bellColorToken) {
      case "danger": return root.bar && root.bar.urgent ? root.bar.urgent : Color.urgent
      case "green": return Qt.rgba(0.24, 0.7, 0.44, 1)
      case "accent": return Color.accent
      default: return root.bar && root.bar.foreground ? root.bar.foreground : Color.foreground
    }
  }

  readonly property bool bellActive: root.barShowBell && root.unreadCount > 0

  readonly property bool ready: lastData !== null
  readonly property real cpuPct: ready ? lastData.cpu_pct : 0
  readonly property int cpuTemp: ready ? lastData.cpu_temp : 0
  readonly property int gpuTemp: ready ? lastData.gpu_temp : 0
  readonly property bool alert: ready ? Model.hasAlert(lastData) || privacyAlert : false

  // Toasts for new apps / privacy access are the single choke point in
  // backend/sql-ins.py (gated by alert_prefs.json modes). The bar only flags.
  readonly property string alertUrgency: root.setting("alertUrgency", "normal")

  readonly property string label: {
    if (!ready) return "󰍛 ..."
    var icon = alert ? "󰀨 " : "󰍛 "
    var parts = []
    var list = root.barStats || []
    for (var i = 0; i < list.length; i++) {
      var v = Model.barStatValue(lastData, list[i])
      if (!v) continue
      var lead = root.barStatMode === "none" ? "" : Model.barStatLabel(list[i])
      parts.push(lead ? lead + " " + v : v)
    }
    var prefix = (root.barShowBell && root.unreadCount > 0) ? "󰂞 " + root.unreadCount + " " : ""
    if (parts.length === 0) return (prefix + icon).trim()
    return prefix + icon + parts.join("  ")
  }

  function refresh() {
    collectProc.running = true
  }

  function open() {
    if (appLoader.item) appLoader.item.open = true
  }

  function close() {
    if (appLoader.item) appLoader.item.open = false
  }

  function toggle() {
    if (appLoader.item) appLoader.item.open = !appLoader.item.open
  }

  function appTab(tab) {
    if (appLoader.item) {
      appLoader.item.open = true
      appLoader.item.activeTab = tab
    }
  }

  function openTab(tab) {
    root.appTab(tab)
  }

  function openApp() {
    if (appLoader.item) appLoader.item.open = true
  }

  readonly property bool opened: appLoader.item ? appLoader.item.open === true : false

  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  function enforceRules() {
    if (!enforceProc.running) enforceProc.running = true
  }

  function onEnforce(text) {
    root.refresh()
    var killed = 0
    try {
      var d = JSON.parse(text)
      killed = (d.killed || []).length
    } catch (e) {}
    root.notify("OmaControl", "Enforced rules — " + killed + " process(es) matched", "normal")
  }

  // ---- Desktop notifications

  function notify(headline, body, urgency) {
    if (!root.bar || !root.bar.run) return
    var u = urgency || root.alertUrgency
    var appName = Util.shellQuote("OmaControl")
    var headlineQ = Util.shellQuote(headline)
    var bodyQ = body ? " " + Util.shellQuote(body) : ""
    root.bar.run("omarchy-notification-send --app-name " + appName + " -u " + u + " " + headlineQ + bodyQ)
  }

  Loader {
    id: appLoader
    active: true
    source: Qt.resolvedUrl("AppWindow.qml")
    visible: false
    onStatusChanged: {
      if (status === Loader.Error) console.log("OMC APP LOAD ERROR: " + (typeof errorString === "function" ? errorString() : "?"))
    }
  }

  Component.onCompleted: {
    barStatsLoadProc.running = true
    refresh()
    privacyProc.running = true
    unreadProc.running = true
  }

  IpcHandler {
    target: "davedes.omcontrol"

    function refresh(): void {
      root.broadcast("refresh")
    }

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function openTab(tab: int): void { root.openTab(tab !== null ? Number(tab) : 0) }
    function setBarStats(stats: string): void {
      if (stats !== null) root.setBarStats(String(stats).split(",").map(function(s) { return s.trim() }).filter(function(s) { return s }))
    }
    function setBarStatMode(mode: string): void {
      if (mode !== null) root.setBarStatMode(String(mode))
    }
    function enforce(): void { root.enforceRules() }
    function state(): string {
      return JSON.stringify({
        ready: root.ready,
        opened: root.opened,
        alert: root.alert,
        appWindow: appLoader.item ? appLoader.item.open === true : false,
        activeTab: appLoader.item ? appLoader.item.activeTab : 0,
        barStats: root.barStats || [],
        barStatMode: root.barStatMode || "name"
      })
    }
    function openApp(): void {
      if (appLoader.item) appLoader.item.open = true
    }
    function closeApp(): void {
      if (appLoader.item) appLoader.item.open = false
    }
    function toggleApp(): void {
      if (appLoader.item) appLoader.item.open = !appLoader.item.open
    }
    function setAppTab(tab: int): void {
      if (appLoader.item) appLoader.item.activeTab = Number(tab)
    }
    function toggleProcRows(): bool {
      return appLoader.item ? appLoader.item.toggleProcRows() : false
    }
    function procRowsInfo(): string {
      return appLoader.item ? appLoader.item.procRowsInfo() : "{}"
    }
  }

  Process {
    id: collectProc
    command: ["sh", Qt.resolvedUrl("backend/collect.sh").toString().replace("file://", "")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = Model.parseCollect(text)
        if (data) {
          root.lastData = data
          root.lastError = ""
          root.setPrivacyAlert()
        } else {
          root.lastError = "parse error"
        }
      }
    }
  }

  Process {
    id: enforceProc
    command: ["sh", Qt.resolvedUrl("backend/enforce.sh").toString().replace("file://", "")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onEnforce(text)
    }
  }

  Process {
    id: privacyProc
    command: ["sh", Qt.resolvedUrl("backend/privacy.sh").toString().replace("file://", "")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onPrivacy(text)
    }
  }

  readonly property string dataDir: Quickshell.env("HOME") + "/.local/share/omcontrol"
  readonly property string barStatsPath: dataDir + "/barstats.json"

  Process {
    id: barStatsLoadProc
    command: ["sh", "-c", "cat '" + root.barStatsPath + "' 2>/dev/null || true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          if (parsed && parsed.barShowBell !== undefined) root.barShowBell = parsed.barShowBell === true
          if (Array.isArray(parsed)) {
            root.barStats = parsed
          } else if (parsed && parsed.stats) {
            root.barStats = parsed.stats
            if (parsed.mode === "name" || parsed.mode === "none") root.barStatMode = parsed.mode
          }
        } catch (e) {}
      }
    }
  }

  function saveBarPrefs() {
    var json = JSON.stringify({ stats: root.barStats, mode: root.barStatMode, barShowBell: root.barShowBell })
    var safe = json.replace(/'/g, "'\\''")
    barStatsSaveProc.command = ["sh", "-c", "mkdir -p '" + root.dataDir + "' && printf '%s' '" + safe + "' > '" + root.barStatsPath + "'"]
    barStatsSaveProc.running = false
    barStatsSaveProc.running = true
  }

  function setBarStats(list) {
    if (!Array.isArray(list)) return
    root.barStats = list
    root.saveBarPrefs()
  }

  function setBarStatMode(mode) {
    if (mode !== "name" && mode !== "none") return
    root.barStatMode = mode
    root.saveBarPrefs()
  }

  Process {
    id: barStatsSaveProc
    running: false
  }

  function setPrivacyAlert() {
    root.privacyAlert = root.privacyDevices && root.privacyDevices.length > 0
  }

  function onPrivacy(text) {
    var parsed = Model.parsePrivacy(text)
    root.setPrivacyAlertFrom(parsed.devices)
    root.privacyEvents = parsed.events
  }

  function setPrivacyAlertFrom(devices) {
    root.privacyAlert = devices && devices.length > 0
    root.privacyDevices = devices || []
  }

  Process {
    id: unreadProc
    command: ["sh", Qt.resolvedUrl("backend/unread.sh").toString().replace("file://", "")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          root.unreadCount = d && d.count ? Number(d.count) : 0
          root.bellColorToken = d && d.color ? String(d.color) : "dim"
        } catch (e) {
          root.unreadCount = 0
          root.bellColorToken = "dim"
        }
      }
    }
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.refresh()
      privacyProc.running = true
      barStatsLoadProc.running = true
      if (root.barShowBell) unreadProc.running = true
    }
  }

  visible: ready
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.label
    fontSize: Style.font.caption
    active: root.alert || root.bellActive
    activeColor: root.alert ? (root.bar && root.bar.urgent ? root.bar.urgent : Color.urgent) : root.bellColor
    tooltipText: {
      if (!root.ready) return "OmaControl — loading..."
      var tip = "OmaControl\n"
      tip += "CPU: " + Model.fmtPct(root.cpuPct) + "  " + Model.fmtTemp(root.cpuTemp) + "\n"
      tip += "RAM: " + Model.fmtMem(root.lastData.mem_used_mb) + " / " + Model.fmtMem(root.lastData.mem_total_mb) + "\n"
      tip += "GPU: " + Model.fmtPct(root.lastData.gpu_pct) + "  " + Model.fmtTemp(root.gpuTemp) + "\n"
      tip += "Processes: " + root.lastData.proc_count
      if (root.privacyAlert) tip += "\n⚠ Privacy alert active"
      if (root.alert) tip += "\n⚠ " + Model.alertReason(root.lastData)
      tip += "\n\nLeft: window • Middle: refresh • Right: menu"
      return tip
    }
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.toggle()
      else if (b === Qt.MiddleButton) root.refresh()
      else if (b === Qt.RightButton) contextMenu.open = true
    }
  }

  // ---- Right-click context menu

  PopupCard {
    id: contextMenu
    anchorItem: button
    bar: root.bar
    triggerMode: "click"
    contentWidth: Style.space(210)

    function dismiss() { contextMenu.open = false }

    // contentHeight sizes the whole popup window; the card's padding + border
    // (verticalContentInset) is drawn on top, so it must be added back or the
    // last row gets clipped.
    contentHeight: menuCol.implicitHeight + contextMenu.verticalContentInset + Style.space(4)

    Column {
      id: menuCol
      width: parent.width
      spacing: Style.space(2)

      component MenuItem: Item {
        id: item
        property string glyph: ""
        property string label: ""
        property var action: null

        width: parent ? parent.width : 0
        height: Style.space(28)

        Rectangle {
          anchors.fill: parent
          radius: 12
          color: itemHover.containsMouse ? Qt.darker(root.bar.foreground, 1.3) : "transparent"
          opacity: itemHover.containsMouse ? 0.3 : 0
        }

        Row {
          anchors.fill: parent
          anchors.margins: Style.space(2)
          spacing: Style.space(8)

          Text {
            text: item.glyph
            color: root.bar.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            width: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            text: item.label
            color: root.bar.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        MouseArea {
          id: itemHover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            contextMenu.dismiss()
            if (item.action) item.action()
          }
        }
      }

      Text {
        text: "OmaControl"
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1
        anchors.left: parent.left
        anchors.leftMargin: Style.space(6)
        topPadding: Style.space(2)
      }

      MenuItem { glyph: "󰋗"; label: "Activity"; action: function() { root.appTab(0) } }
      MenuItem { glyph: "󰦨"; label: "Apps"; action: function() { root.appTab(1) } }
      MenuItem { glyph: "󰍬"; label: "Alerts"; action: function() { root.appTab(2) } }
      MenuItem { glyph: "󰃶"; label: "Events"; action: function() { root.appTab(3) } }
      MenuItem { glyph: "󰚠"; label: "Settings"; action: function() { root.appTab(4) } }

      Item { width: parent.width; height: Style.space(4) }

      MenuItem { glyph: "󰑓"; label: "Refresh"; action: function() { root.refresh() } }
    }
  }
}