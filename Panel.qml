import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "davedes.omcontrol"
  ipcTarget: "davedes.omcontrol"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string dataDir: Quickshell.env("HOME") + "/.local/share/omcontrol"
  readonly property string rulesPath: dataDir + "/rules.json"

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property color accented: Color.accent
  readonly property color textDim1: Qt.darker(root.contentForeground, 1.4)
  readonly property color textDim2: Qt.darker(root.contentForeground, 1.7)

  // Live state from bar widget
  readonly property var sysData: hostWidget ? hostWidget.lastData : null
  readonly property bool ready: sysData !== null
  readonly property bool alert: hostWidget ? hostWidget.alert : false
  readonly property bool privacyAlert: hostWidget ? hostWidget.privacyAlert : false

  // Tab state: 0=Overview, 1=Processes, 2=Privacy, 3=Rules, 4=Settings
  property int activeTab: 0
  property var processes: []
  property string processInfoText: ""
  property string processInfoName: ""
  property string enforceResult: ""
  property var rules: []

  // Chart drill-down: clicking a history chart shows the top apps at that time.
  // chartDrillTs is the clicked epoch (seconds); -1 = closed.
  property real chartDrillTs: -1
  property string chartDrillSeries: ""
  property string chartDrillMetric: "cpu"
  property var chartDrillData: []
  property bool chartDrillLoading: false

  // Bar icon stats mirror (multi-select; owned + persisted by the bar widget).
  readonly property var barStats: hostWidget ? hostWidget.barStats : ["cpu", "cputemp"]
  readonly property string barStatMode: hostWidget ? hostWidget.barStatMode : "icon"
  readonly property var barStatsCatalog: Model.barStatsCatalog()

  function isBarStat(id) {
    if (!Array.isArray(root.barStats)) return false
    return root.barStats.indexOf(id) >= 0
  }

  function toggleBarStat(id) {
    if (!hostWidget) return
    var list = Array.isArray(root.barStats) ? root.barStats.slice() : []
    var idx = list.indexOf(id)
    if (idx >= 0) list.splice(idx, 1)
    else list.push(id)
    hostWidget.setBarStats(list)
  }

  // Process list sort: "name" | "cpu" | "mem" | "swap" | "io" | "gpu" | "gpumem"
  property string processSort: "cpu"
  property int processSortDir: -1

  // Shared process-table geometry: ALL rows and the header use these exact
  // widths so the columns always line up and can never overlap.
  readonly property real procMarginX: Style.space(8)
  readonly property real procColGap: Style.space(4)
  readonly property real procColPid: Style.space(40)
  readonly property real procColCpu: Style.space(44)
  readonly property real procColMem: Style.space(44)
  readonly property real procColSwap: Style.space(44)
  readonly property real procColIo: Style.space(48)
  readonly property real procColGpu: Style.space(44)
  readonly property real procColGpuMem: Style.space(46)
  readonly property real procColAct: Style.space(60)

  function procNameWidth(total) {
    return Math.max(1,
      total - root.procMarginX * 2
      - root.procColPid - root.procColCpu - root.procColMem
      - root.procColSwap - root.procColIo - root.procColGpu
      - root.procColGpuMem - root.procColAct - root.procColGap * 8)
  }

  // Privacy data is owned by the bar widget (its 2s loop keeps alerts firing);
  // the panel just mirrors it.
  readonly property var privacyDevices: hostWidget ? hostWidget.privacyDevices : []
  readonly property var privacyEvents: hostWidget ? hostWidget.privacyEvents : []

  // Chart window
  property int chartWindow: 3600

  // Drill-down: the Overview tab shows a set of live metric tiles; clicking
  // one opens a detail view scoped to that metric. "system" is the reset view.
  property string detailView: "system"

  readonly property color warnColor: Qt.darker(Color.urgent, 1.15)

  function open() {
    refresh()
    root.controller.show()
  }

  function openTab(index) {
    root.activeTab = index
    root.open()
  }

  function openDetail(name) {
    root.activeTab = 0
    root.detailView = name
    root.open()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function refresh() {
    // Collection is owned by the bar widget's 2s loop; the panel consumes
    // hostWidget.lastData. Only fall back to a local collect when standalone.
    if (hostWidget && "refresh" in hostWidget) hostWidget.refresh()
    else if (!collectProc.running) collectProc.running = true
    loadRules()
  }

  function loadRules() {
    rulesLoadProc.running = true
  }

  function killProcess(pid) {
    if (!pid) return
    killProc.command = ["sh", "-c", "kill -9 " + pid]
    killProc.running = false
    killProc.running = true
    // Refresh after a short delay
    refreshTimer.start()
  }

  function enforceRules() {
    enforceProc.running = true
    refreshTimer.start()
  }

  function addRule(name, pattern) {
    if (!name || !pattern) return
    var newRules = root.rules.slice()
    newRules.push({"name": name, "pattern": pattern, "action": "kill", "enabled": true})
    saveRules(newRules)
  }

  function removeRule(index) {
    var newRules = root.rules.slice()
    newRules.splice(index, 1)
    saveRules(newRules)
  }

  function toggleRule(index) {
    var newRules = root.rules.slice()
    newRules[index].enabled = !newRules[index].enabled
    saveRules(newRules)
  }

  function saveRules(newRules) {
    root.rules = newRules
    var json = JSON.stringify({"rules": newRules}, null, 2)
    // Pass the JSON on the command line (quoted) so no stdin plumbing is needed.
    var safe = json.replace(/'/g, "'\\''")
    saveProc.command = ["sh", "-c", "mkdir -p '" + root.dataDir + "' && cat <<'EOF' > '" + root.rulesPath + "'\n" + json + "\nEOF"]
    saveProc.running = true
  }

  // ---- Detail view helpers
  function detailColor(v) {
    if (!v || v.pct === undefined) return root.contentForeground
    if (v.critical) return Color.urgent
    if (v.warn) return root.warnColor
    return root.accented
  }

  function historyFor(key) {
    if (!root.ready) return []
    var hist = root.chartWindow <= 3600 ? root.sysData.history_1h
             : root.chartWindow <= 21600 ? root.sysData.history_6h
             : root.sysData.history_24h
    if (!hist) return []
    if (key === "cpu") return hist.map(function(p) { return { ts: p.ts, value: p.cpu || 0 } })
    if (key === "mem") return hist.map(function(p) { return { ts: p.ts, value: p.mem || 0 } })
    if (key === "gpu") return hist.map(function(p) { return { ts: p.ts, value: p.gpu || 0 } })
    if (key === "temp") return hist.map(function(p) { return { ts: p.ts, value: p.ctemp || 0 } })
    return []
  }

  function diskList() {
    if (!root.ready) return []
    var disks = root.sysData.disks || []
    var seen = {}
    var out = []
    for (var i = 0; i < disks.length; i++) {
      if (!seen[disks[i].mount]) {
        seen[disks[i].mount] = true
        out.push(disks[i])
      }
    }
    out.sort(function(a, b) { return b.pct - a.pct })
    return out
  }

  function diskTotal() {
    var list = root.diskList()
    var used = 0, size = 0
    for (var i = 0; i < list.length; i++) {
      used += list[i].used_gb
      size += list[i].size_gb
    }
    return { used_gb: used.toFixed(1), size_gb: size.toFixed(1), pct: size > 0 ? (used / size * 100).toFixed(1) : 0 }
  }

  function diskCount() {
    var list = root.diskList()
    var n = 0
    for (var i = 0; i < list.length; i++) {
      if (list[i].pct > 90) n++
    }
    return n
  }

  function topMount() {
    var list = root.diskList()
    if (list.length === 0) return { mount: "--", pct: 0 }
    var top = list[0]
    for (var i = 1; i < list.length; i++) {
      if (list[i].pct > top.pct) top = list[i]
    }
    return top
  }

  function netList() {
    if (!root.ready) return []
    var nets = root.sysData.nets || []
    var out = []
    for (var i = 0; i < nets.length; i++) {
      if (nets[i].rx_kbs > 0 || nets[i].tx_kbs > 0) out.push(nets[i])
    }
    if (out.length === 0) {
      for (var j = 0; j < nets.length; j++) out.push(nets[j])
    }
    out.sort(function(a, b) { return (b.rx_kbs + b.tx_kbs) - (a.rx_kbs + a.tx_kbs) })
    return out
  }

  function netTotals() {
    var nets = root.sysData ? (root.sysData.nets || []) : []
    var down = 0, up = 0
    for (var i = 0; i < nets.length; i++) {
      down += nets[i].rx_kbs
      up += nets[i].tx_kbs
    }
    return { down: Model.fmtRate(down), up: Model.fmtRate(up) }
  }

  function netActive() {
    var nets = root.sysData ? (root.sysData.nets || []) : []
    var n = 0
    for (var i = 0; i < nets.length; i++) {
      if (nets[i].rx_kbs > 0 || nets[i].tx_kbs > 0) n++
    }
    return n
  }

  function diskToTile(disk) {
    return {
      name: disk.mount === "/" ? "Root" : disk.dev,
      value: disk,
      pctText: disk.pct.toFixed(1) + "% — " + disk.used_gb + " / " + disk.size_gb + " GB",
      frac: disk.pct / 100,
      warn: disk.pct > 80,
      critical: disk.pct > 90
    }
  }

  function netToTile(net) {
    var hasTraffic = net.rx_kbs > 0 || net.tx_kbs > 0
    return {
      name: net.iface,
      value: net,
      frac: hasTraffic ? 1 : 0,
      pctText: Model.fmtRate(net.rx_kbs) + " ↓  " + Model.fmtRate(net.tx_kbs) + " ↑",
      warn: false,
      critical: false
    }
  }

  // ---- Process info lookup
  function lookupProcess(name) {
    processInfoName = name
    processInfoProc.command = ["sh", "-c", "sh " + Qt.resolvedUrl("backend/process-info.sh").toString().replace("file://", "") + " " + name]
    processInfoProc.running = true
  }

  Timer {
    id: refreshTimer
    interval: 500
    onTriggered: root.refresh()
  }

  // ---- Data handlers

  function onCollect(text) {
    var parsed = Model.parseCollect(text)
    if (parsed && hostWidget && "setPrivacyAlert" in hostWidget) {
      hostWidget.lastData = parsed
      hostWidget.setPrivacyAlert()
    } else if (parsed) {
      root.processes = parsed.processes || []
    }
  }

  function onRulesLoad(text) {
    try {
      var obj = JSON.parse(text)
      root.rules = obj.rules || []
    } catch (e) {}
  }

  function onEnforce(text) {
    root.enforceResult = text
  }

  function onProcessInfo(text) {
    root.processInfoText = text
  }

  // ---- Processes from collect output
  onReadyChanged: {
    if (ready) root.processes = sysData.processes || []
  }
  onSysDataChanged: {
    if (sysData) root.processes = sysData.processes || []
  }

  function sortedProcesses() {
    var list = root.processes.slice()
    var dir = root.processSortDir >= 0 ? 1 : -1
    if (root.processSort === "name") {
      list.sort(function(a, b) {
        var na = (a.name || "").toLowerCase()
        var nb = (b.name || "").toLowerCase()
        if (na === nb) return 0
        return na < nb ? -dir : dir
      })
    } else {
      list.sort(function(a, b) {
        var va = root.processSort === "cpu" ? (a.cpu || 0)
               : root.processSort === "mem" ? (a.mem || 0)
               : root.processSort === "swap" ? (a.swap || 0)
               : root.processSort === "io" ? (a.io_kbs || 0)
               : root.processSort === "gpu" ? (a.gpu || 0)
               : (a.gpu_mem || 0)
        var vb = root.processSort === "cpu" ? (b.cpu || 0)
               : root.processSort === "mem" ? (b.mem || 0)
               : root.processSort === "swap" ? (b.swap || 0)
               : root.processSort === "io" ? (b.io_kbs || 0)
               : root.processSort === "gpu" ? (b.gpu || 0)
               : (b.gpu_mem || 0)
        return (va - vb) * dir
      })
    }
    return list
  }

  function setProcessSort(key) {
    if (root.processSort === key) {
      root.processSortDir = root.processSortDir >= 0 ? -1 : 1
    } else {
      root.processSort = key
      root.processSortDir = key === "name" ? 1 : -1
    }
  }

  // ---- Chart drill-down (click a chart → apps running at that time)
  function openChartDrill(ts, series) {
    var secs = Math.floor(ts)
    root.chartDrillTs = secs
    root.chartDrillSeries = series || "CPU"
    root.chartDrillMetric = series === "MEMORY" ? "mem" : series === "GPU" ? "gpu" : "cpu"
    root.chartDrillData = []
    root.chartDrillLoading = true
    procHistProc.command = ["sh", "-c", "sh " + Qt.resolvedUrl("backend/procs-at.sh").toString().replace("file://", "") + " " + secs]
    procHistProc.running = true
  }

  function onProcHist(text) {
    root.chartDrillLoading = false
    try {
      var arr = JSON.parse(text)
      root.chartDrillData = Array.isArray(arr) ? arr : []
    } catch (e) {
      root.chartDrillData = []
    }
  }

  function chartDrillRows() {
    var list = root.chartDrillData.slice()
    var key = root.chartDrillMetric
    list.sort(function(a, b) {
      var va = key === "mem" ? (a.mem || 0)
             : key === "swap" ? (a.swap || 0)
             : key === "io" ? (a.io_kbs || 0)
             : key === "gpu" ? (a.gpu || 0)
             : key === "gpu_mem" ? (a.gpu_mem || 0)
             : (a.cpu || 0)
      var vb = key === "mem" ? (b.mem || 0)
             : key === "swap" ? (b.swap || 0)
             : key === "io" ? (b.io_kbs || 0)
             : key === "gpu" ? (b.gpu || 0)
             : key === "gpu_mem" ? (b.gpu_mem || 0)
             : (b.cpu || 0)
      return vb - va
    })
    return list
  }

  function chartDrillTimeText() {
    if (root.chartDrillTs < 0) return ""
    var d = new Date(root.chartDrillTs * 1000)
    return Qt.formatTime(d, "HH:mm") + "  ·  " + Qt.formatDate(d, "ddd MMM d")
  }

  // ---- Lifecycle
  Component.onCompleted: refresh()

  Process {
    id: collectProc
    command: ["sh", "-c", "sh " + Qt.resolvedUrl("backend/collect.sh").toString().replace("file://", "")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onCollect(text)
    }
  }

  Process {
    id: killProc
    command: ["true"]
    stdout: StdioCollector { waitForEnd: true }
  }

  Process {
    id: enforceProc
    command: ["sh", "-c", "sh " + Qt.resolvedUrl("backend/enforce.sh").toString().replace("file://", "")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onEnforce(text)
    }
  }

  Process {
    id: rulesLoadProc
    command: ["cat", root.rulesPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onRulesLoad(text)
    }
  }

  Process {
    id: processInfoProc
    command: ["true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onProcessInfo(text)
    }
  }

  Process {
    id: procHistProc
    command: ["true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onProcHist(text)
    }
  }

  Process {
    id: saveProc
    command: ["true"]
    stdout: StdioCollector { waitForEnd: true }
  }

  // ---- Reusable components

  component PanelTitle: PanelSectionHeader {
    foreground: root.contentForeground
    fontFamily: root.contentFontFamily
    font.letterSpacing: 1
  }

  component Tab: Item {
    id: tab
    property string label: ""
    property int index: 0
    property bool active: root.activeTab === tab.index

    width: tabLabel.implicitWidth + Style.space(24)
    height: Style.space(28)

    Rectangle {
      anchors.fill: parent
      radius: Math.round(height / 2)
      color: tab.active ? root.accented : "transparent"
    }

    Rectangle {
      anchors.fill: parent
      radius: Math.round(height / 2)
      visible: tabHover.containsMouse && !tab.active
      color: Qt.darker(root.contentForeground, 1.4)
      opacity: 0.25
    }

    Text {
      id: tabLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: tab.label
      color: tab.active ? Color.background : root.textDim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 0.5
    }

    MouseArea {
      id: tabHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.activeTab = tab.index
    }
  }

  component StatCard: Item {
    id: card
    property string label: ""
    property string value: ""
    property string subLabel: ""
    property color valueColor: root.contentForeground
    signal clicked

    width: parent ? (parent.width - parent.spacing) / 2 : 0
    height: Style.space(64)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius || 6
      color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.06)
    }

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius || 6
      visible: cardHover.containsMouse
      color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.10)
    }

    Column {
      anchors.fill: parent
      anchors.margins: Style.space(8)
      spacing: Style.space(2)

      Text {
        text: card.label
        color: root.textDim1
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1
      }
      Text {
        text: card.value
        color: card.valueColor
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }
      Text {
        visible: card.subLabel !== ""
        text: card.subLabel
        color: root.textDim2
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        maximumLineCount: 2
        elide: Text.ElideRight
      }
    }

    MouseArea {
      id: cardHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: card.clicked()
    }
  }

  // Mission Center-style device info section shown at the top of each
  // drill-down detail view. Always visible; auto-sizes to its content.
  component DeviceInfoSection: Rectangle {
    id: infoCard
    property string device: ""
    property string title: ""
    property var extraRows: []

    visible: infoCard.rows.length > 0
    width: parent.width
    radius: Style.cornerRadius || 6
    color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.05)
    border.color: Qt.rgba(root.accented.r, root.accented.g, root.accented.b, 0.35)
    border.width: 1
    implicitHeight: infoBody.implicitHeight + infoPadd * 2

    readonly property var rows: {
      var base = root.ready ? Model.deviceInfoRows(infoCard.device, root.sysData) : []
      if (infoCard.extraRows && infoCard.extraRows.length > 0) return base.concat(infoCard.extraRows)
      return base
    }

    property int infoPadd: Style.space(12)

    Column {
      id: infoBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: infoCard.infoPadd
      spacing: Style.space(10)

      Row {
        id: infoHeader
        width: parent.width
        spacing: Style.space(8)

        Text {
          text: infoCard.title
          color: root.accented
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1
          anchors.verticalCenter: parent.verticalCenter
        }

        Rectangle {
          width: 1
          height: Style.space(18)
          color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.15)
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          text: infoCard.rows[0] ? infoCard.rows[0].value : ""
          color: root.textDim1
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(6)

        Repeater {
          model: infoCard.rows.slice(1)
          delegate: InfoRow {
            width: parent.width
            label: modelData.label
            value: modelData.value
          }
        }
      }
    }
  }

  component InfoRow: Item {
    id: infoRow
    property string label: ""
    property string value: ""

    width: parent ? parent.width : 0
    height: Math.max(Style.space(20), valText.implicitHeight)

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.space(8)

      Text {
        text: infoRow.label
        color: root.textDim1
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        width: Style.space(150)
        elide: Text.ElideRight
      }

      Item {
        width: parent.width - Style.space(150) - parent.spacing
        height: Math.max(Style.space(20), valText.implicitHeight)

        Text {
          id: valText
          anchors.right: parent.right
          text: infoRow.value
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        }
      }
    }
  }

  component SortHeader: Item {
    id: sortHdr
    property string label: ""
    property bool active: false
    property int dir: 0
    property string sortKey: ""
    signal clicked

    width: parent ? parent.width : 0
    height: Style.space(20)

    Text {
      id: hdrLabel
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
      text: sortHdr.label + (sortHdr.dir === 0 ? "" : (sortHdr.dir > 0 ? " ↑" : " ↓"))
      color: sortHdr.active ? root.accented : root.textDim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: sortHdr.active
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        root.setProcessSort(sortHdr.sortKey)
        sortHdr.clicked()
      }
    }
  }

  component ProcessRow: Item {
    id: procRow
    property var procData: null
    property int index: 0

    width: parent ? parent.width : 0
    height: Style.space(38)

    Rectangle {
      anchors.fill: parent
      radius: 4
      color: procRow.index % 2 === 0
        ? "transparent"
        : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.03)
    }

    Row {
      anchors.fill: parent
      anchors.leftMargin: root.procMarginX
      anchors.rightMargin: root.procMarginX
      spacing: root.procColGap

      // Name fills the remaining width and elides.
      Text {
        id: procName
        width: root.procNameWidth(procRow.width)
        anchors.verticalCenter: parent.verticalCenter
        text: procRow.procData ? procRow.procData.name : ""
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        width: root.procColPid
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: procRow.procData ? procRow.procData.pid : ""
        color: root.textDim2
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        width: root.procColCpu
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: procRow.procData ? Model.fmtPct(procRow.procData.cpu) : ""
        color: procRow.procData && procRow.procData.cpu > 50 ? Color.urgent : root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      Text {
        width: root.procColMem
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: procRow.procData ? procRow.procData.mem.toFixed(1) + "%" : ""
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: root.procColSwap
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: procRow.procData ? Model.fmtMemShort(procRow.procData.swap) : ""
        color: procRow.procData && procRow.procData.swap > 512 ? root.warnColor : root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: root.procColIo
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: procRow.procData ? Model.fmtRateShort(procRow.procData.io_kbs) : ""
        color: procRow.procData && procRow.procData.io_kbs > 1024 ? root.warnColor : root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: root.procColGpu
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: procRow.procData ? (procRow.procData.gpu > 0 ? procRow.procData.gpu.toFixed(1) + "%" : "-") : ""
        color: procRow.procData && procRow.procData.gpu > 80 ? root.warnColor : root.accented
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: root.procColGpuMem
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: procRow.procData ? Model.fmtMemShort(procRow.procData.gpu_mem) : ""
        color: procRow.procData && procRow.procData.gpu_mem > 2048 ? root.warnColor : root.accented
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
      }

      // Action buttons share a fixed-width slot at the far right.
      Item {
        width: root.procColAct
        height: parent.height

        Rectangle {
          id: infoBtn
          anchors.right: killBtn.left
          anchors.rightMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(22)
          height: Style.space(22)
          radius: 4
          color: infoArea.containsMouse ? root.accented : "transparent"
          border.color: root.accented
          border.width: 1
          opacity: infoArea.containsMouse ? 1.0 : 0.6

          Text {
            anchors.centerIn: parent
            text: "?"
            color: infoArea.containsMouse ? Color.background : root.accented
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          MouseArea {
            id: infoArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (procRow.procData) root.lookupProcess(procRow.procData.name)
            }
          }
        }

        Rectangle {
          id: killBtn
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(22)
          height: Style.space(22)
          radius: 4
          color: killArea.containsMouse ? Color.urgent : "transparent"
          border.color: Color.urgent
          border.width: 1
          opacity: killArea.containsMouse ? 1.0 : 0.6

          Text {
            anchors.centerIn: parent
            text: "×"
            color: killArea.containsMouse ? Color.background : Color.urgent
            font.pixelSize: Style.font.body
            font.bold: true
          }

          MouseArea {
            id: killArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (procRow.procData) root.killProcess(procRow.procData.pid)
            }
          }
        }
      }
    }

    Rectangle {
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: 1
      color: root.contentForeground
      opacity: 0.05
    }
  }

  // Read-only process row for the chart drill-down view. Same column geometry
  // as ProcessRow; the whole row deep-dives via lookupProcess.
  component DrillRow: Item {
    id: drillRow
    property var procData: null
    property int index: 0

    width: parent ? parent.width : 0
    height: Style.space(38)

    Rectangle {
      anchors.fill: parent
      radius: 4
      color: drillRow.index % 2 === 0
        ? "transparent"
        : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.03)
    }

    Rectangle {
      anchors.fill: parent
      radius: 4
      visible: drillArea.containsMouse
      color: Qt.rgba(root.accented.r, root.accented.g, root.accented.b, 0.08)
    }

    Row {
      anchors.fill: parent
      anchors.leftMargin: root.procMarginX
      anchors.rightMargin: root.procMarginX
      spacing: root.procColGap

      Text {
        width: root.procNameWidth(drillRow.width)
        anchors.verticalCenter: parent.verticalCenter
        text: drillRow.procData ? drillRow.procData.name : ""
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        width: root.procColPid
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: drillRow.procData ? drillRow.procData.pid : ""
        color: root.textDim2
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        width: root.procColCpu
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: drillRow.procData ? Model.fmtPct(drillRow.procData.cpu) : ""
        color: drillRow.procData && drillRow.procData.cpu > 50 ? Color.urgent : root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      Text {
        width: root.procColMem
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: drillRow.procData ? drillRow.procData.mem.toFixed(1) + "%" : ""
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: root.procColSwap
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: drillRow.procData ? Model.fmtMemShort(drillRow.procData.swap) : ""
        color: drillRow.procData && drillRow.procData.swap > 512 ? root.warnColor : root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: root.procColIo
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: drillRow.procData ? Model.fmtRateShort(drillRow.procData.io_kbs) : ""
        color: drillRow.procData && drillRow.procData.io_kbs > 1024 ? root.warnColor : root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: root.procColGpu
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: drillRow.procData ? (drillRow.procData.gpu > 0 ? drillRow.procData.gpu.toFixed(1) + "%" : "-") : ""
        color: drillRow.procData && drillRow.procData.gpu > 80 ? root.warnColor : root.accented
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: root.procColGpuMem
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: drillRow.procData ? Model.fmtMemShort(drillRow.procData.gpu_mem) : ""
        color: drillRow.procData && drillRow.procData.gpu_mem > 2048 ? root.warnColor : root.accented
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    MouseArea {
      id: drillArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (drillRow.procData) {
          root.activeTab = 1
          root.lookupProcess(drillRow.procData.name)
        }
      }
    }

    Rectangle {
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: 1
      color: root.contentForeground
      opacity: 0.05
    }
  }

  component PrivacyRow: Item {
    id: privRow
    property var deviceData: null

    width: parent ? parent.width : 0
    height: Style.space(36)

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: privRow.deviceData ? (privRow.deviceData.device === "camera" ? "󰄀" : "󰍬") : ""
      color: Color.urgent
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(32)
      anchors.verticalCenter: parent.verticalCenter
      text: privRow.deviceData ? privRow.deviceData.name : ""
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      width: Style.space(150)
    }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(190)
      anchors.verticalCenter: parent.verticalCenter
      text: privRow.deviceData ? (privRow.deviceData.device === "camera" ? "Camera" : "Microphone") : ""
      color: Color.urgent
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(270)
      anchors.verticalCenter: parent.verticalCenter
      text: privRow.deviceData ? "PID " + privRow.deviceData.pid : ""
      color: root.textDim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }

    Rectangle {
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: 1
      color: root.contentForeground
      opacity: 0.05
    }
  }

  component RuleRow: Item {
    id: ruleRow
    property var ruleData: null
    property int ruleIndex: 0

    width: parent ? parent.width : 0
    height: Style.space(36)

    Rectangle {
      anchors.fill: parent
      radius: 4
      color: ruleRow.ruleData && ruleRow.ruleData.enabled
        ? Qt.rgba(root.accented.r, root.accented.g, root.accented.b, 0.08)
        : "transparent"
    }

    // Toggle
    Rectangle {
      id: toggleDot
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(14)
      height: Style.space(14)
      radius: 7
      color: ruleRow.ruleData && ruleRow.ruleData.enabled ? root.accented : root.textDim2

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggleRule(ruleRow.ruleIndex)
      }
    }

    Text {
      anchors.left: toggleDot.right
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: ruleRow.ruleData ? ruleRow.ruleData.name : ""
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      width: Style.space(120)
    }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(150)
      anchors.verticalCenter: parent.verticalCenter
      text: ruleRow.ruleData ? ruleRow.ruleData.pattern : ""
      color: root.textDim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      width: Style.space(140)
    }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(300)
      anchors.verticalCenter: parent.verticalCenter
      text: ruleRow.ruleData ? ruleRow.ruleData.action.toUpperCase() : ""
      color: root.textDim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    // Remove button
    Rectangle {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(20)
      height: Style.space(20)
      radius: 4
      color: removeArea.containsMouse ? Color.urgent : "transparent"
      border.color: Color.urgent
      border.width: 1
      opacity: removeArea.containsMouse ? 1.0 : 0.5

      Text {
        anchors.centerIn: parent
        text: "×"
        color: removeArea.containsMouse ? Color.background : Color.urgent
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      MouseArea {
        id: removeArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.removeRule(ruleRow.ruleIndex)
      }
    }

    Rectangle {
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: 1
      color: root.contentForeground
      opacity: 0.05
    }
  }

  // ---- Panel body

  component DetailTile: Item {
    id: tile
    signal clicked
    property var valueObj: null

    width: parent ? parent.width : 0
    height: Style.space(54)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius || 6
      color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.05)
    }

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius || 6
      visible: tileHover.containsMouse
      border.color: root.accented
      border.width: 1
    }

    Column {
      anchors.fill: parent
      anchors.margins: Style.space(6)
      anchors.rightMargin: Style.space(8)
      anchors.leftMargin: Style.space(8)
      spacing: Style.space(6)

      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: tile.valueObj ? tile.valueObj.name : ""
          elide: Text.ElideRight
          width: parent.width - pctText.implicitWidth - parent.spacing
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.title
          color: tile.valueObj ? root.detailColor(tile.valueObj) : root.textDim1
          font.bold: true
        }

        Text {
          id: pctText
          anchors.verticalCenter: parent.verticalCenter
          text: tile.valueObj ? tile.valueObj.pctText : ""
          elide: Text.ElideRight
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          color: root.textDim1
          horizontalAlignment: Text.AlignRight
        }
      }

      Rectangle {
        width: parent.width
        height: Style.space(4)
        radius: 2
        color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.10)

        Rectangle {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width * (tile.valueObj ? Math.max(0, Math.min(1, tile.valueObj.frac)) : 0)
          height: parent.height
          radius: 2
          color: tile.valueObj ? root.detailColor(tile.valueObj) : root.accented
        }
      }
    }

    MouseArea {
      id: tileHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tile.clicked()
    }
  }

  component LiveBars: Item {
    id: lb
    property var values: []
    property int cols: 4
    property color activeColor: root.accented
    property string maxLabel: ""

    height: lbLabel.implicitHeight + gridCol.implicitHeight + Style.space(6)
    width: parent ? parent.width : 0

    Text {
      id: lbLabel
      anchors.top: parent.top
      anchors.left: parent.left
      textFormat: Text.PlainText
      text: lb.maxLabel
      color: root.textDim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 0.8
    }

    Flow {
      id: gridCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: lbLabel.bottom
      anchors.topMargin: Style.space(4)
      spacing: Style.space(4)

      Repeater {
        model: lb.values

        delegate: Column {
          required property int index
          required property var modelData
          readonly property real frac: modelData && modelData.frac !== undefined ? modelData.frac : 0
          width: gridCol.width <= 0 ? 0 : (gridCol.width - (lb.cols - 1) * Style.space(4)) / lb.cols
          spacing: Style.space(2)

          Rectangle {
            width: parent.width
            height: Style.space(46)
            radius: 2
            color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

            Rectangle {
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              height: parent.height * frac
              radius: 2
              color: root.detailColor(modelData)
            }
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: modelData && modelData.name !== undefined ? modelData.name : ""
            color: root.textDim2
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  component DetailChart: Item {
    id: dch
    property var chartClicked: null
    property var series: []
    property var seriesColors: []
    property var seriesNames: []
    property string title: ""
    property int windowSecs: root.chartWindow
    property var formatValue: null
    property bool drillable: false

    // ---- Time-domain zoom / pan (scrub). viewStart/viewEnd in epoch
    // seconds; -1 means "follow the data" (full window).
    property real viewStart: -1
    property real viewEnd: -1
    readonly property bool zoomed: viewStart >= 0 && viewEnd > viewStart
    readonly property real minZoomSpan: 30

    onWindowSecsChanged: resetView()

    function resetView() { viewStart = -1; viewEnd = -1 }

    function dataStart() {
      var pts = dch.series && dch.series[0]
      return (pts && pts.length > 1) ? pts[0].ts : 0
    }
    function dataEnd() {
      var pts = dch.series && dch.series[0]
      return (pts && pts.length > 1) ? pts[pts.length - 1].ts : 0
    }
    function fullEnd() { return dch.dataEnd() }
    function fullStart() {
      var de = dch.fullEnd()
      var win = dch.windowSecs || root.chartWindow
      if (de <= 0) return Math.floor(Date.now() / 1000) - win
      var fs = de - win
      var ds = dch.dataStart()
      return ds > fs ? ds : fs
    }
    function domainStart() { return dch.zoomed ? dch.viewStart : dch.fullStart() }
    function domainEnd() { return dch.zoomed ? dch.viewEnd : dch.fullEnd() }

    function timeAtX(x) {
      var s = dch.domainStart(), e = dch.domainEnd()
      return s + (e - s) * x / Math.max(1, dchCanvas.width - 1)
    }

    function panBy(seconds) {
      var span = dch.viewEnd - dch.viewStart
      var fs = dch.fullStart(), fe = dch.fullEnd()
      var ns = dch.viewStart + seconds
      if (ns < fs) ns = fs
      if (ns > fe - span) ns = fe - span
      if (ns < fs) ns = fs
      dch.viewStart = ns
      dch.viewEnd = ns + span
    }

    function zoomTo(t1, t2) {
      if (t2 < t1) { var t = t1; t1 = t2; t2 = t }
      var span = t2 - t1
      if (span < dch.minZoomSpan) {
        var c = (t1 + t2) / 2
        t1 = c - dch.minZoomSpan / 2
        t2 = c + dch.minZoomSpan / 2
        span = dch.minZoomSpan
      }
      var fs = dch.fullStart(), fe = dch.fullEnd()
      if (t1 < fs) { t1 = fs; t2 = t1 + span }
      if (t2 > fe) { t2 = fe; t1 = t2 - span }
      if (t1 < fs) t1 = fs
      dch.viewStart = t1
      dch.viewEnd = Math.max(t1 + 1, t2)
    }

    function wheelZoom(x, up) {
      var fs = dch.fullStart(), fe = dch.fullEnd()
      var fullSpan = fe - fs
      if (fullSpan <= 0) return
      var span = dch.domainEnd() - dch.domainStart()
      var f = up ? 0.75 : 1.3333
      var ns = Math.max(dch.minZoomSpan, Math.min(Math.max(fullSpan, dch.minZoomSpan), span * f))
      var t = dch.timeAtX(x)
      var frac = span > 0 ? (t - dch.domainStart()) / span : 0.5
      var nStart = t - frac * ns
      if (nStart < fs) nStart = fs
      if (nStart > fe - ns) nStart = fe - ns
      if (nStart < fs) nStart = fs
      dch.viewStart = nStart
      dch.viewEnd = nStart + ns
    }

    implicitHeight: Style.space(120)
    width: parent ? parent.width : 0

    Text {
      id: dchHeader
      anchors.top: parent.top
      anchors.left: parent.left
      textFormat: Text.PlainText
      text: dch.title
      color: root.textDim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }

    // Drill-down affordance: shown only for charts that fetch app snapshots.
    Text {
      id: dchHint
      anchors.top: parent.top
      anchors.right: parent.right
      textFormat: Text.PlainText
      visible: dch.drillable
      text: "󰂃 " + (dch.zoomed
        ? "RANGE " + Qt.formatTime(new Date(dch.viewStart * 1000), "HH:mm:ss") + "\u2013" + Qt.formatTime(new Date(dch.viewEnd * 1000), "HH:mm:ss") + " \u21ba reset"
        : "click for apps \u00b7 drag to zoom \u00b7 wheel")
      color: Qt.rgba(root.accented.r, root.accented.g, root.accented.b, 0.75)
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }

    Canvas {
      id: dchCanvas
      anchors.top: dchHeader.bottom
      anchors.topMargin: Style.space(4)
      anchors.left: parent.left
      anchors.right: parent.right
      height: parent.implicitHeight - dchHeader.implicitHeight - Style.space(4)

      property real hoverX: -1
      onHoverXChanged: requestPaint()

      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      Connections {
        target: dch
        function onSeriesChanged() { dchCanvas.requestPaint() }
        function onSeriesColorsChanged() { dchCanvas.requestPaint() }
        function onSeriesNamesChanged() { dchCanvas.requestPaint() }
      }

      HoverHandler {
        onPointChanged: dchCanvas.hoverX = hovered ? point.position.x : -1
        onHoveredChanged: if (!hovered) dchCanvas.hoverX = -1
      }

      MouseArea {
        id: chartHover
        anchors.fill: parent
        visible: dch.drillable
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor

        property real pressX: -1
        property real lastX: -1
        property real selX1: -1
        property real selX2: -1
        property bool moving: false
        property real lastDrill: 0

        onPressed: function(mouse) {
          pressX = mouse.x; lastX = mouse.x
          selX1 = mouse.x; selX2 = -1
          moving = false
        }
        onPositionChanged: function(mouse) {
          if (pressX < 0) return
          if (!moving && Math.abs(mouse.x - pressX) > 4) moving = true
          if (moving && dch.zoomed) {
            var span = dch.domainEnd() - dch.domainStart()
            dch.panBy((lastX - mouse.x) * span / Math.max(1, width - 1))
            lastX = mouse.x
            dchCanvas.requestPaint()
          } else if (moving) {
            selX2 = mouse.x
            dchCanvas.requestPaint()
          }
        }
        onReleased: function(mouse) {
          var wasMoving = moving
          var x = mouse.x
          pressX = -1
          if (wasMoving && selX1 >= 0 && selX2 >= 0 && Math.abs(selX2 - selX1) > 4) {
            if (dch.zoomed) {
              moving = false; selX1 = selX2 = -1; dchCanvas.requestPaint(); return
            }
            dch.zoomTo(dch.timeAtX(Math.min(selX1, selX2)), dch.timeAtX(Math.max(selX1, selX2)))
            moving = false; selX1 = selX2 = -1; dchCanvas.requestPaint(); return
          }
          moving = false; selX1 = selX2 = -1
          var now = new Date().getTime()
          if (now - chartHover.lastDrill < 380) {
            chartHover.lastDrill = 0
            dch.resetView()
            dchCanvas.requestPaint()
            return
          }
          chartHover.lastDrill = now
          if (!dch.series || !dch.series[0] || dch.series[0].length < 2) { dchCanvas.requestPaint(); return }
          if (dch.chartClicked) dch.chartClicked(dch.timeAtX(x))
          dchCanvas.requestPaint()
        }
        onDoubleClicked: {
          chartHover.lastDrill = 0
          dch.resetView()
          dchCanvas.requestPaint()
        }
        onWheel: function(wheel) {
          dch.wheelZoom(mouseX, wheel.angleDelta.y > 0)
          dchCanvas.requestPaint()
        }
      }

      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.clearRect(0, 0, width, height)

        function fmtValue(v) {
          if (dch.formatValue) return dch.formatValue(v)
          return Math.round(v) + "%"
        }

        var n = dch.series.length
        if (n === 0) return
        if (!dch.series[0] || dch.series[0].length < 2) {
          ctx.font = "11px " + root.contentFontFamily
          ctx.fillStyle = root.textDim2
          ctx.textAlign = "center"
          ctx.fillText("Collecting data...", width / 2, height / 2)
          return
        }

        var pts = dch.series[0]
        var now = Math.floor(Date.now() / 1000)
        var start = dch.domainStart()
        var end = dch.domainEnd()
        var span = Math.max(1, end - start)

        function xOf(ts) {
          return Math.max(0, Math.min(width - 1, (ts - start) * width / span))
        }

        for (var s = 0; s < n; s++) {
          var list = dch.series[s]
          if (!list || list.length < 2) continue
          var max = 1
          for (var vi = 0; vi < list.length; vi++) {
            if (list[vi].ts < start || list[vi].ts > end) continue
            if (list[vi].value > max) max = list[vi].value
          }
          ctx.beginPath()
          var drawn = false
          for (var i = 0; i < list.length; i++) {
            var p = list[i]
            if (p.ts < start || p.ts > end) continue
            var x = xOf(p.ts)
            var y = height - (p.value / max) * height * 0.9
            if (!drawn) { ctx.moveTo(x, y); drawn = true }
            else ctx.lineTo(x, y)
          }
          if (!drawn) continue
          ctx.strokeStyle = dch.seriesColors[s]
          ctx.lineWidth = 1.5
          ctx.stroke()

          if (s === 0) {
            var vp0 = []
            for (var q0 = 0; q0 < list.length; q0++)
              if (list[q0].ts >= start && list[q0].ts <= end) vp0.push(list[q0])
            if (vp0.length > 1) {
              ctx.lineTo(xOf(vp0[vp0.length - 1].ts), height)
              ctx.lineTo(xOf(vp0[0].ts), height)
              ctx.closePath()
              ctx.fillStyle = Qt.rgba(dch.seriesColors[0].r, dch.seriesColors[0].g, dch.seriesColors[0].b, 0.10)
              ctx.fill()
            }
          }
        }

        // Range-select band (drag when not zoomed)
        if (chartHover.selX1 >= 0 && chartHover.selX2 >= 0 && !dch.zoomed) {
          var bx = Math.min(chartHover.selX1, chartHover.selX2)
          var bw = Math.abs(chartHover.selX2 - chartHover.selX1)
          if (bw > 4) {
            ctx.fillStyle = Qt.rgba(root.accented.r, root.accented.g, root.accented.b, 0.12)
            ctx.fillRect(bx, 0, bw, height)
            ctx.fillStyle = root.accented
            ctx.fillRect(bx, 0, 1, height)
            ctx.fillRect(bx + bw, 0, 1, height)
          }
        }

        // Zoomed range pill
        if (dch.zoomed) {
          var ztxt = Qt.formatTime(new Date(dch.viewStart * 1000), "HH:mm:ss") + "\u2013" + Qt.formatTime(new Date(dch.viewEnd * 1000), "HH:mm:ss")
          ctx.font = "bold 9px " + root.contentFontFamily
          var zw = ctx.measureText(ztxt).width + 12
          ctx.fillStyle = Qt.rgba(0.05, 0.05, 0.08, 0.75)
          ctx.fillRect(4, 2, zw, 14)
          ctx.strokeStyle = Qt.rgba(root.accented.r, root.accented.g, root.accented.b, 0.5)
          ctx.lineWidth = 1
          ctx.strokeRect(4.5, 2.5, zw - 1, 13)
          ctx.fillStyle = root.accented
          ctx.textBaseline = "middle"
          ctx.fillText(ztxt, 9, 9.5)
          ctx.textBaseline = "alphabetic"
        }

        if (dchCanvas.hoverX >= 0) {
          var tAt = start + dchCanvas.hoverX * span / (width - 1)
          var bestTs = null, bestD = Infinity
          for (var h = 0; h < n; h++) {
            var hl = dch.series[h]
            if (!hl) continue
            for (var k = 0; k < hl.length; k++) {
              var dd = Math.abs(hl[k].ts - tAt)
              if (dd < bestD) { bestD = dd; bestTs = hl[k].ts }
            }
          }
          if (bestTs !== null) {
            var cxx = xOf(bestTs)
            ctx.strokeStyle = Qt.rgba(root.contentForeground.r, root.contentForeground.g,
                                      root.contentForeground.b, 0.4)
            ctx.lineWidth = 1
            ctx.beginPath()
            ctx.moveTo(cxx + 0.5, 0)
            ctx.lineTo(cxx + 0.5, height)
            ctx.stroke()

            var label = Qt.formatTime(new Date(bestTs * 1000), "HH:mm:ss")
            for (var m = 0; m < n; m++) {
              var ml = dch.series[m]
              if (!ml) continue
              var mv = null
              var mBest = null, mBestD = Infinity
              for (var q = 0; q < ml.length; q++) {
                var md = Math.abs(ml[q].ts - bestTs)
                if (md < mBestD) { mBestD = md; mBest = ml[q] }
              }
              if (mBest) mv = mBest.value
              var mName = dch.seriesNames && dch.seriesNames[m] ? dch.seriesNames[m] : ("s" + m)
              label += "   " + mName + " " + (mv === null ? "--" : fmtValue(mv))
            }

            var fg = root.contentForeground
            var bg = Color.popups ? Color.popups.background : Qt.rgba(0.1, 0.1, 0.14, 1)
            ctx.font = "10px " + root.contentFontFamily
            var w = ctx.measureText(label).width + 12
            var bx = Math.max(2, Math.min(width - w - 2, cxx - w / 2))
            ctx.fillStyle = Qt.rgba(bg.r, bg.g, bg.b, 0.92)
            ctx.fillRect(bx, 2, w, 16)
            ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.25)
            ctx.lineWidth = 1
            ctx.strokeRect(bx + 0.5, 2.5, w - 1, 15)
            ctx.fillStyle = fg
            ctx.textBaseline = "alphabetic"
            ctx.fillText(label, bx + 6, 2 + 8 + 3.6)
          }
        }
      }
    }
  }

  component DetailHeader: Item {
    id: dh
    signal back()
    property string title: ""
    property string subtitle: ""

    width: parent ? parent.width : 0
    height: Style.space(28)

    Rectangle {
      id: dhBack
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(26)
      height: Style.space(26)
      radius: Style.space(8)
      color: dhBackHover.containsMouse ? root.accented : Qt.rgba(root.accented.r, root.accented.g, root.accented.b, 0.12)
      border.color: dhBackHover.containsMouse ? root.accented : Qt.rgba(root.accented.r, root.accented.g, root.accented.b, 0.4)
      border.width: 1
      Text {
        anchors.centerIn: parent
        text: "󰅂"
        color: dhBackHover.containsMouse ? Color.background : root.accented
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }
      MouseArea {
        id: dhBackHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: dh.back()
      }
    }

    Text {
      anchors.left: dhBack.right
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: dh.title
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.title
      font.bold: true
      elide: Text.ElideRight
      width: parent.width - dhBack.width - Style.space(16)
      clip: true
    }

    Text {
      visible: subtitle !== ""
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: dh.subtitle
      color: root.textDim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(contentCol.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        var f = panelScroller
        var max = Math.max(0, f.contentHeight - f.height)
        var target = dy > 0
          ? Math.min(max, f.contentY + Style.space(42))
          : Math.max(0, f.contentY - Style.space(42))
        f.contentY = target
      }
      onCloseRequested: {
        if (root.processInfoText !== "") root.processInfoText = ""
        else if (root.chartDrillTs >= 0) root.chartDrillTs = -1
        else if (root.detailView !== "system") root.detailView = "system"
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        if (t === "1") root.activeTab = 0
        if (t === "2") root.activeTab = 1
        if (t === "3") root.activeTab = 2
        if (t === "4") root.activeTab = 3
        if (t === "5") root.activeTab = 4
      }

      Flickable {
        id: panelScroller
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: contentCol.implicitHeight
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: contentCol
          width: parent.width
          spacing: Style.space(12)

          // ---- Hero header
          Item {
            width: parent.width
            implicitHeight: heroIcon.implicitHeight

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.alert ? "󰀨" : "󰍛"
              color: root.alert ? Color.urgent : root.accented
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.rightMargin: heroActions.width + Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: "OmaControl"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                visible: root.ready
                text: root.ready
                  ? (root.alert ? Model.alertReason(root.sysData) : "System OK — " + root.sysData.proc_count + " processes")
                  : "Loading..."
                color: root.alert ? Color.urgent : root.textDim1
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
                elide: Text.ElideRight
              }
            }

            Row {
              id: heroActions
              spacing: Style.space(4)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter

              PanelActionButton {
                iconText: "󰑓"
                tooltipText: "Refresh (R)"
                foreground: root.contentForeground
                onClicked: root.refresh()
              }
              PanelActionButton {
                iconText: "\uf201"
                tooltipText: "App Window"
                foreground: root.contentForeground
                onClicked: root.hostWidget.openApp()
              }
              PanelActionButton {
                iconText: "󰅖"
                tooltipText: "Close (Esc)"
                foreground: root.contentForeground
                onClicked: root.close()
              }
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          // ---- Tab bar
          Row {
            spacing: Style.space(4)
            width: parent.width

            Tab { label: "Overview"; index: 0 }
            Tab { label: "Processes"; index: 1 }
            Tab { label: "Privacy"; index: 2 }
            Tab { label: "Rules"; index: 3 }
            Tab { label: "Settings"; index: 4 }
          }

          // ---- Tab: Overview
          Column {
            visible: root.activeTab === 0
            width: parent.width
            spacing: Style.space(8)

            // — System overview tiles —
            Column {
              visible: root.detailView === "system" && root.chartDrillTs < 0
              width: parent.width
              spacing: Style.space(8)

              Row {
                width: parent.width
                spacing: Style.space(8)
                StatCard {
                  label: "CPU"
                  value: root.ready ? Model.fmtPct(root.sysData.cpu_pct) : "--"
                  valueColor: root.ready
                    ? (root.sysData.cpu_pct > 80 ? Color.urgent
                      : root.sysData.cpu_pct > 50 ? root.warnColor
                      : root.accented)
                    : root.contentForeground
                  subLabel: root.ready ? Model.fmtTemp(root.sysData.cpu_temp) + "  ·  " + (root.sysData.cores ? root.sysData.cores.length : 0) + " cores" : ""
                  onClicked: root.openDetail("cpu")
                }
                StatCard {
                  label: "MEMORY"
                  value: root.ready ? Model.fmtMemPct(root.sysData.mem_used_mb, root.sysData.mem_total_mb) : "--"
                  valueColor: root.ready
                    ? (root.sysData.mem_used_mb / root.sysData.mem_total_mb > 0.85 ? Color.urgent : root.accented)
                    : root.contentForeground
                  subLabel: root.ready ? Model.fmtMem(root.sysData.mem_used_mb) + " used  ·  " + Model.fmtMem(root.sysData.mem_avail_mb) + " avail" : ""
                  onClicked: root.openDetail("mem")
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)
                StatCard {
                  label: "GPU"
                  value: root.ready ? Model.fmtPct(root.sysData.gpu_pct) : "--"
                  valueColor: root.ready
                    ? (root.sysData.gpu_pct > 80 ? Color.urgent : root.accented)
                    : root.contentForeground
                  subLabel: root.ready ? Model.fmtTemp(root.sysData.gpu_temp) + "  ·  " + Model.fmtGpuMem(root.sysData.gpu_mem_mb) + " / " + Model.fmtGpuMem(root.sysData.gpu_mem_total_mb) : ""
                  onClicked: root.openDetail("gpu")
                }
                StatCard {
                  label: "DISKS"
                  value: root.ready ? Model.fmtPct(root.sysData.disks && root.sysData.disks.length > 0 ? root.sysData.disks[0].pct : 0) : "--"
                  valueColor: root.ready && root.sysData.disks && root.sysData.disks[0] && root.sysData.disks[0].pct > 85 ? Color.urgent : root.accented
                  subLabel: root.ready
                    ? (function() {
                        var d = root.sysData.disks || []
                        var used = 0, size = 0
                        for (var i = 0; i < d.length; i++) { used += d[i].used_gb; size += d[i].size_gb }
                        return d.length + " mount(s)  ·  " + used.toFixed(0) + "G / " + size.toFixed(0) + "G"
                      })()
                    : ""
                  onClicked: root.openDetail("disks")
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)
                StatCard {
                  label: "NETWORK"
                  value: root.ready
                    ? (function() {
                        var nets = root.sysData.nets || []
                        var total = 0
                        for (var i = 0; i < nets.length; i++) total += nets[i].rx_kbs + nets[i].tx_kbs
                        return total > 0 ? Model.fmtRate(total) : "idle"
                      })()
                    : "--"
                  valueColor: root.accented
                  subLabel: root.ready ? (function() {
                      var n = root.sysData.nets || []
                      var d = 0, u = 0, active = 0
                      for (var i = 0; i < n.length; i++) {
                        d += n[i].rx_kbs; u += n[i].tx_kbs
                        if (n[i].rx_kbs > 0 || n[i].tx_kbs > 0) active++
                      }
                      return "↓" + Model.fmtRate(d) + "  ↑" + Model.fmtRate(u) + "  ·  " + active + "/" + n.length + " active"
                    })() : ""
                  onClicked: root.openDetail("net")
                }
                StatCard {
                  label: "SYSTEM"
                  value: root.ready ? Model.fmtUptime(root.sysData.uptime_s) : "--"
                  valueColor: root.contentForeground
                  subLabel: root.ready ? root.sysData.proc_count + " procs  ·  kernel " + (root.sysData.kernel || "").split("-")[0] : ""
                  onClicked: root.openDetail("sys")
                }
                StatCard {
                  label: "BATTERY"
                  value: root.ready && root.sysData.battery && root.sysData.battery.present
                    ? root.sysData.battery.percent + "%"
                    : "--"
                  valueColor: root.ready && root.sysData.battery && root.sysData.battery.present && root.sysData.battery.percent < 20
                    ? Color.urgent
                    : (root.ready && root.sysData.battery && root.sysData.battery.present ? root.accented : root.contentForeground)
                  subLabel: root.ready && root.sysData.battery && root.sysData.battery.present
                    ? (root.sysData.battery.status || "") + (root.sysData.battery.power_w > 0 ? "  ·  " + Model.fmtPower(root.sysData.battery.power_w) : "")
                    : ""
                  onClicked: root.openDetail("sys")
                }
              }

              // Privacy status
              Rectangle {
                width: parent.width
                height: Style.space(32)
                radius: 6
                color: root.privacyAlert
                  ? Qt.rgba(root.warnColor.r, root.warnColor.g, root.warnColor.b, 0.15)
                  : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.06)

                Row {
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  spacing: Style.space(6)

                  Text {
                    text: root.privacyAlert ? "󰄀" : "󰤂"
                    color: root.privacyAlert ? root.warnColor : root.accented
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: root.privacyAlert
                      ? "Privacy alert: " + root.privacyDevices.length + " device(s) in use"
                      : "Privacy: No active device access"
                    color: root.privacyAlert ? root.warnColor : root.accented
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }

              // New-app alerts
              Rectangle {
                visible: root.sysData && root.sysData.new_apps && root.sysData.new_apps.length > 0
                width: parent.width
                implicitHeight: newAppsCol.implicitHeight + Style.space(12)
                radius: 6
                color: Qt.rgba(root.accented.r, root.accented.g, root.accented.b, 0.10)
                border.color: root.accented
                border.width: 1

                Column {
                  id: newAppsCol
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  spacing: Style.space(4)

                  Text {
                    textFormat: Text.PlainText
                    text: "New applications detected"
                    color: root.accented
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1
                  }

                  Repeater {
                    model: root.sysData ? (root.sysData.new_apps || []) : []
                    delegate: Row {
                      spacing: Style.space(6)
                      Text {
                        text: "󰫆"
                        color: root.accented
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                      }
                      Text {
                        text: modelData.name
                        color: root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }
                  }
                }
              }

              // Recently discovered apps
              Column {
                visible: root.sysData && root.sysData.recent_apps && root.sysData.recent_apps.length > 0
                width: parent.width
                spacing: Style.space(4)

                PanelTitle { text: "RECENTLY OPENED APPS" }

                Repeater {
                  model: root.sysData ? (root.sysData.recent_apps || []) : []
                  delegate: Row {
                    width: parent.width
                    spacing: Style.space(8)
                    Text {
                      text: Model.fmtTimeAgo(modelData.ts)
                      color: root.textDim2
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      width: Style.space(60)
                    }
                    Text {
                      text: modelData.name
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }
                }
              }

              // History chart
              Item {
                width: parent.width
                height: Style.space(110)

                HistoryChart {
                  anchors.fill: parent
                  history: root.ready ? (root.chartWindow <= 3600 ? root.sysData.history_1h : (root.chartWindow <= 21600 ? root.sysData.history_6h : root.sysData.history_24h)) : []
                  windowSecs: root.chartWindow
                }
              }

              Row {
                spacing: Style.space(4)
                anchors.horizontalCenter: parent.horizontalCenter
                ChartChip { label: "1H"; seconds: 3600 }
                ChartChip { label: "6H"; seconds: 21600 }
                ChartChip { label: "24H"; seconds: 86400 }
              }
            }

            // — Detail views (drill-down from tiles) —

            // CPU detail
            Column {
              visible: root.detailView === "cpu" && root.chartDrillTs < 0
              width: parent.width
              spacing: Style.space(8)

              DetailHeader {
                title: "󰍛  CPU"
                subtitle: root.ready ? Model.fmtTemp(root.sysData.cpu_temp) : ""
                onBack: root.detailView = "system"
              }

              DeviceInfoSection {
                device: "cpu"
                title: "CPU DEVICE"
              }

              Row {
                width: parent.width
                spacing: Style.space(8)
                StatCard {
                  label: "LOAD"
                  value: root.ready ? (root.sysData.load_1 || 0).toFixed(2) : "--"
                  valueColor: root.accented
                  subLabel: "1 min"
                }
                StatCard {
                  label: "TEMP"
                  value: root.ready ? Model.fmtTemp(root.sysData.cpu_temp) : "--"
                  valueColor: root.ready && root.sysData.cpu_temp > 80 ? root.warnColor : root.contentForeground
                  subLabel: "Package"
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)
                StatCard {
                  label: "FREQUENCY"
                  value: root.ready ? Model.fmtFreq(root.sysData.cpu_hz_mhz) : "--"
                  valueColor: root.accented
                  subLabel: "Avg per core"
                }
                StatCard {
                  label: "USAGE"
                  value: root.ready ? Model.fmtPct(root.sysData.cpu_pct) : "--"
                  valueColor: root.ready && root.sysData.cpu_pct > 80 ? root.warnColor : root.accented
                  subLabel: root.ready ? "5m " + (root.sysData.load_5 || 0).toFixed(2) + "   15m " + (root.sysData.load_15 || 0).toFixed(2) : ""
                }
              }

              PanelTitle { text: "CORES" }

              LiveBars {
                width: parent.width
                values: root.ready ? root.sysData.cores.map(function(c) {
                  return {
                    name: c.id.toString(),
                    frac: c.pct / 100,
                    pctText: c.pct.toFixed(1) + "%",
                    warn: c.pct > 50,
                    critical: c.pct > 85
                  }
                }) : []
                cols: Math.max(2, Math.min(4, Math.ceil(Math.sqrt((root.sysData && root.sysData.cores ? root.sysData.cores.length : 0)))))
                activeColor: root.accented
                maxLabel: (root.sysData && root.sysData.cores ? root.sysData.cores.length : 0) + " cores"
              }

              DetailChart {
                width: parent.width
                series: [historyFor("cpu")]
                seriesColors: [root.accented]
                seriesNames: ["CPU"]
                title: "CPU HISTORY"
                drillable: true
                chartClicked: function(ts) { root.openChartDrill(ts, "CPU") }
              }

              Row {
                spacing: Style.space(4)
                anchors.horizontalCenter: parent.horizontalCenter
                ChartChip { label: "1H"; seconds: 3600 }
                ChartChip { label: "6H"; seconds: 21600 }
                ChartChip { label: "24H"; seconds: 86400 }
              }
            }

            // Memory detail
            Column {
              visible: root.detailView === "mem" && root.chartDrillTs < 0
              width: parent.width
              spacing: Style.space(8)

              DetailHeader {
                title: "󰍛  Memory"
                subtitle: root.ready ? Model.fmtMemPct(root.sysData.mem_used_mb, root.sysData.mem_total_mb) : ""
                onBack: root.detailView = "system"
              }

              DeviceInfoSection {
                device: "mem"
                title: "MEMORY DEVICE"
              }

              PanelTitle { text: "BREAKDOWN" }
              Row {
                width: parent.width
                spacing: Style.space(8)
                StatCard {
                  label: "USED"
                  value: root.ready ? Model.fmtMem(root.sysData.mem_used_mb) : "--"
                  valueColor: root.accented
                  subLabel: root.ready ? Model.fmtMemPct(root.sysData.mem_used_mb, root.sysData.mem_total_mb) + " used" : ""
                }
                StatCard {
                  label: "FREE"
                  value: root.ready ? Model.fmtMem(root.sysData.mem_free_mb) : "--"
                  valueColor: root.contentForeground
                  subLabel: "Unused"
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)
                StatCard {
                  label: "TOTAL"
                  value: root.ready ? Model.fmtMem(root.sysData.mem_total_mb) : "--"
                  valueColor: root.contentForeground
                  subLabel: "Installed"
                }
                StatCard {
                  label: "AVAILABLE"
                  value: root.ready ? Model.fmtMem(root.sysData.mem_avail_mb) : "--"
                  valueColor: root.accented
                  subLabel: root.ready ? Model.fmtMemPct(root.sysData.mem_avail_mb, root.sysData.mem_total_mb) + " free" : ""
                }
              }

              Repeater {
                model: [
                  { name: "Cached", value: root.ready ? root.sysData.mem_cached_mb : 0 },
                  { name: "Buffers", value: root.ready ? root.sysData.mem_buffers_mb : 0 },
                  { name: "Available", value: root.ready ? root.sysData.mem_avail_mb : 0 }
                ]
                delegate: DetailTile {
                  valueObj: ({ name: modelData.name, frac: (root.ready && root.sysData.mem_total_mb > 0 ? modelData.value / root.sysData.mem_total_mb : 0), pctText: Model.fmtMem(modelData.value), warn: false, critical: false })
                  onClicked: root.detailView = "system"
                }
              }

              PanelTitle { text: "SWAP" }
              Row {
                width: parent.width
                spacing: Style.space(8)
                StatCard {
                  label: "SWAP"
                  value: root.ready ? Model.fmtMemPct(root.sysData.swap_used_mb, root.sysData.swap_total_mb) : "--"
                  valueColor: root.accented
                  subLabel: root.ready ? Model.fmtMem(root.sysData.swap_used_mb) + " / " + Model.fmtMem(root.sysData.swap_total_mb) : ""
                }
                StatCard {
                  label: "FREE"
                  value: root.ready ? Model.fmtMem(Math.max(0, root.sysData.swap_total_mb - root.sysData.swap_used_mb)) : "--"
                  valueColor: root.contentForeground
                  subLabel: "Available"
                }
              }

              DetailChart {
                width: parent.width
                series: [historyFor("mem")]
                seriesColors: [root.accented]
                seriesNames: ["MEM"]
                title: "MEMORY HISTORY"
                drillable: true
                chartClicked: function(ts) { root.openChartDrill(ts, "MEMORY") }
              }

              Row {
                spacing: Style.space(4)
                anchors.horizontalCenter: parent.horizontalCenter
                ChartChip { label: "1H"; seconds: 3600 }
                ChartChip { label: "6H"; seconds: 21600 }
                ChartChip { label: "24H"; seconds: 86400 }
              }
            }

            // Disk detail
            Column {
              visible: root.detailView === "disks" && root.chartDrillTs < 0
              width: parent.width
              spacing: Style.space(8)

              DetailHeader {
                title: "󰋊  Disks"
                onBack: root.detailView = "system"
              }

              DeviceInfoSection {
                device: "disks"
                title: "STORAGE DEVICES"
              }

              Row {
                width: parent.width
                spacing: Style.space(8)
                StatCard {
                  label: "USED"
                  value: root.ready ? diskTotal().used_gb : "--"
                  valueColor: root.accented
                  subLabel: "Across all mounts"
                }
                StatCard {
                  label: "CAPACITY"
                  value: root.ready ? diskTotal().size_gb : "--"
                  valueColor: root.contentForeground
                  subLabel: root.ready ? diskTotal().pct + "% full" : ""
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)
                StatCard {
                  label: "CRITICAL"
                  value: root.ready ? diskCount() : "--"
                  valueColor: root.ready && diskCount() > 0 ? Color.urgent : root.accented
                  subLabel: root.ready && diskCount() > 0 ? "Mount(s) > 90%" : "None"
                }
                StatCard {
                  label: "TOP MOUNT"
                  value: root.ready ? topMount().mount : "--"
                  valueColor: root.accented
                  subLabel: root.ready ? topMount().pct.toFixed(1) + "% used" : ""
                }
              }

              Repeater {
                model: root.diskList()
                delegate: DetailTile {
                  valueObj: diskToTile(modelData)
                  onClicked: root.detailView = "system"
                }
              }
            }

            // Network detail
            Column {
              visible: root.detailView === "net" && root.chartDrillTs < 0
              width: parent.width
              spacing: Style.space(8)

              DetailHeader {
                title: "󰖟  Network"
                onBack: root.detailView = "system"
              }

              DeviceInfoSection {
                device: "net"
                title: "NETWORK DEVICES"
              }

              Row {
                width: parent.width
                spacing: Style.space(8)
                StatCard {
                  label: "DOWNLOAD"
                  value: root.ready ? netTotals().down : "--"
                  valueColor: root.accented
                  subLabel: "Combined ↓"
                }
                StatCard {
                  label: "UPLOAD"
                  value: root.ready ? netTotals().up : "--"
                  valueColor: root.accented
                  subLabel: "Combined ↑"
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)
                StatCard {
                  label: "ACTIVE"
                  value: root.ready ? netActive() : "--"
                  valueColor: root.accented
                  subLabel: "I/f with traffic"
                }
                StatCard {
                  label: "TOTAL"
                  value: root.ready ? netList().length : "--"
                  valueColor: root.contentForeground
                  subLabel: "Interfaces"
                }
              }

              Repeater {
                model: root.netList()
                delegate: DetailTile {
                  valueObj: netToTile(modelData)
                  onClicked: root.detailView = "system"
                }
              }
            }

            // GPU detail
            Column {
              visible: root.detailView === "gpu" && root.chartDrillTs < 0
              width: parent.width
              spacing: Style.space(8)

              DetailHeader {
                title: "󰍛  GPU"
                subtitle: root.ready ? Model.fmtTemp(root.sysData.gpu_temp) : ""
                onBack: root.detailView = "system"
              }

              DeviceInfoSection {
                device: "gpu"
                title: "GPU DEVICE"
              }

              Row {
                width: parent.width
                spacing: Style.space(8)
                StatCard {
                  label: "GPU"
                  value: root.ready ? Model.fmtPct(root.sysData.gpu_pct) : "--"
                  valueColor: root.ready && root.sysData.gpu_pct > 80 ? root.warnColor : root.accented
                  subLabel: root.ready ? root.sysData.gpu_clock_mhz + " MHz" : ""
                }
                StatCard {
                  label: "MEMORY"
                  value: root.ready ? Model.fmtGpuMem(root.sysData.gpu_mem_mb) : "--"
                  valueColor: root.accented
                  subLabel: root.ready ? "/ " + Model.fmtGpuMem(root.sysData.gpu_mem_total_mb) : ""
                }
              }

              PanelTitle { text: "SYSTEM" }

              Repeater {
                model: [
                  { name: "Power", value: root.ready ? Model.fmtPower(root.sysData.gpu_power_w) : "--", warn: false, critical: false, frac: 0 },
                  { name: "Fan", value: root.ready ? Math.round(root.sysData.gpu_fan_pct) + "%" : "--", warn: false, critical: false, frac: 0 },
                  { name: "Temp", value: root.ready ? Model.fmtTemp(root.sysData.gpu_temp) : "--", warn: root.ready && root.sysData.gpu_temp > 70, critical: root.ready && root.sysData.gpu_temp > 85, frac: root.ready ? root.sysData.gpu_temp / 100 : 0 }
                ]
                delegate: DetailTile {
                  valueObj: ({ name: modelData.name, value: modelData.value, pctText: modelData.value, frac: modelData.frac, warn: modelData.warn, critical: modelData.critical })
                  onClicked: root.detailView = "system"
                }
              }

              DetailChart {
                width: parent.width
                series: [historyFor("gpu")]
                seriesColors: [root.accented]
                seriesNames: ["GPU"]
                title: "GPU HISTORY"
                drillable: true
                chartClicked: function(ts) { root.openChartDrill(ts, "GPU") }
              }

              Row {
                spacing: Style.space(4)
                anchors.horizontalCenter: parent.horizontalCenter
                ChartChip { label: "1H"; seconds: 3600 }
                ChartChip { label: "6H"; seconds: 21600 }
                ChartChip { label: "24H"; seconds: 86400 }
              }
            }

            // Battery / system detail
            Column {
              visible: root.detailView === "sys" && root.chartDrillTs < 0
              width: parent.width
              spacing: Style.space(8)

              DetailHeader {
                title: "󰋊  System"
                onBack: root.detailView = "system"
              }

              DeviceInfoSection {
                device: "sys"
                title: "SYSTEM"
              }

              DeviceInfoSection {
                device: "batt"
                title: "BATTERY"
              }

              PanelTitle { text: "INFO" }

              Repeater {
                model: [
                  { name: "Uptime", value: root.ready ? Model.fmtUptime(root.sysData.uptime_s) : "--" },
                  { name: "Hostname", value: root.ready ? root.sysData.host : "--" },
                  { name: "Kernel", value: root.ready ? root.sysData.kernel : "--" },
                  { name: "Processes", value: root.ready ? root.sysData.proc_count : "--" },
                  { name: "Battery", value: root.ready ? (root.sysData.battery.present ? root.sysData.battery.percent + "% — " + root.sysData.battery.status : "No battery") : "--" },
                  { name: "Power", value: root.ready ? Model.fmtPower(root.sysData.battery.power_w) : "--" },
                  { name: "Load avg", value: root.ready ? (root.sysData.load_1 || 0).toFixed(2) + " / " + (root.sysData.load_5 || 0).toFixed(2) + " / " + (root.sysData.load_15 || 0).toFixed(2) : "--" },
                  { name: "Root disk", value: root.ready ? Model.fmtPct(root.sysData.disks && root.sysData.disks.length > 0 ? root.sysData.disks[0].pct : 0) + " — " + (root.sysData.disks && root.sysData.disks.length > 0 ? root.sysData.disks[0].used_gb + " GB" : "") : "--" },
                  { name: "Net I/F", value: root.ready ? (root.sysData.nets || []).length : "--" },
                  { name: "CPU cores", value: root.ready ? (root.sysData.cores || []).length : "--" },
                  { name: "GPU mem", value: root.ready ? Model.fmtGpuMem(root.sysData.gpu_mem_mb) + " / " + Model.fmtGpuMem(root.sysData.gpu_mem_total_mb) : "--" }
                ]
                delegate: DetailTile {
                  valueObj: ({ name: modelData.name, value: modelData.value, pctText: modelData.value, frac: 0, warn: false, critical: false })
                  onClicked: root.detailView = "system"
                }
              }
            }

            // Chart drill-down: apps running at a clicked chart point
            Column {
              visible: root.chartDrillTs >= 0
              width: parent.width
              spacing: Style.space(8)

              DetailHeader {
                title: "󰂃  " + root.chartDrillSeries + " — APPS AT " + root.chartDrillTimeText()
                onBack: root.chartDrillTs = -1
              }

              Text {
                width: parent.width
                text: "Nearest recorded snapshot. Sorted by " + (root.chartDrillMetric.toUpperCase()) + ". Click an app for its full details."
                color: root.textDim2
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }

              Item {
                width: parent.width
                height: Style.space(24)

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: root.procMarginX
                  anchors.rightMargin: root.procMarginX
                  spacing: root.procColGap

                  Text {
                    width: root.procNameWidth(parent.width)
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignLeft
                    text: "PROCESS"
                    color: root.textDim2
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1.2
                  }
                  Text {
                    width: root.procColPid
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: "PID"
                    color: root.textDim2
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1.2
                  }
                  Text {
                    width: root.procColCpu
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: "CPU"
                    color: root.textDim2
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1.2
                  }
                  Text {
                    width: root.procColMem
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: "Memory"
                    color: root.textDim2
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1.2
                  }
                  Text {
                    width: root.procColSwap
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: "Swap"
                    color: root.textDim2
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1.2
                  }
                  Text {
                    width: root.procColIo
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: "I/O"
                    color: root.textDim2
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1.2
                  }
                  Text {
                    width: root.procColGpu
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: "GPU"
                    color: root.textDim2
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1.2
                  }
                  Text {
                    width: root.procColGpuMem
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: "G.Mem"
                    color: root.textDim2
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1.2
                  }
                }
              }

              Repeater {
                model: root.chartDrillRows()
                delegate: DrillRow {
                  procData: modelData
                  index: index
                }
              }

              Text {
                visible: root.chartDrillData.length === 0 && !root.chartDrillLoading
                width: parent.width
                text: "No process snapshot recorded near this time (data collection may not have been running). Try a more recent point."
                color: root.textDim2
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }

              Text {
                visible: root.chartDrillLoading
                width: parent.width
                text: "Loading…"
                color: root.textDim2
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- Tab: Processes
          Column {
            visible: root.activeTab === 1
            width: parent.width
            spacing: Style.space(4)

            // Process detail view (drill-down; hides the list)
            Column {
              visible: root.processInfoText !== ""
              width: parent.width
              spacing: Style.space(8)

              DetailHeader {
                title: "󰂚  " + root.processInfoName
                onBack: root.processInfoText = ""
              }

              Rectangle {
                width: parent.width
                radius: 6
                color: Qt.rgba(root.accented.r, root.accented.g, root.accented.b, 0.08)
                border.color: root.accented
                border.width: 1
                implicitHeight: infoBody.implicitHeight + Style.space(16)

                Column {
                  id: infoBody
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  spacing: Style.space(4)

                  Text {
                    width: parent.width
                    text: "DESCRIPTION"
                    color: root.textDim2
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1
                  }

                  Text {
                    width: parent.width
                    text: {
                      try {
                        var o = JSON.parse(root.processInfoText)
                        return o.description || "No description available."
                      } catch (e) {
                        return root.processInfoText
                      }
                    }
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }
              }
            }

            // Process list (hidden while a process detail is showing)
            Column {
              visible: root.processInfoText === ""
              width: parent.width
              spacing: Style.space(4)

              PanelTitle { text: "PROCESSES" }

              // Column headers — click to sort. The Item wrapper + anchored
              // Row mirror ProcessRow so every column lines up exactly.
              Item {
                id: procHeaderRow
                width: parent.width
                height: Style.space(24)

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: root.procMarginX
                  anchors.rightMargin: root.procMarginX
                  spacing: root.procColGap

                  Text {
                    width: root.procNameWidth(procHeaderRow.width)
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignLeft
                    text: "PROCESS"
                    color: root.textDim2
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1.2
                  }
                  Text {
                    width: root.procColPid
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: "PID"
                    color: root.textDim2
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1.2
                  }
                  SortHeader {
                    sortKey: "cpu"
                    label: "CPU"
                    active: root.processSort === "cpu"
                    dir: root.processSort === "cpu" ? root.processSortDir : 0
                    width: root.procColCpu
                  }
                  SortHeader {
                    sortKey: "mem"
                    label: "Memory"
                    active: root.processSort === "mem"
                    dir: root.processSort === "mem" ? root.processSortDir : 0
                    width: root.procColMem
                  }
                  SortHeader {
                    sortKey: "swap"
                    label: "Swap"
                    active: root.processSort === "swap"
                    dir: root.processSort === "swap" ? root.processSortDir : 0
                    width: root.procColSwap
                  }
                  SortHeader {
                    sortKey: "io"
                    label: "Drive"
                    active: root.processSort === "io"
                    dir: root.processSort === "io" ? root.processSortDir : 0
                    width: root.procColIo
                  }
                  SortHeader {
                    sortKey: "gpu"
                    label: "GPU"
                    active: root.processSort === "gpu"
                    dir: root.processSort === "gpu" ? root.processSortDir : 0
                    width: root.procColGpu
                  }
                  SortHeader {
                    sortKey: "gpumem"
                    label: "GPU Mem"
                    active: root.processSort === "gpumem"
                    dir: root.processSort === "gpumem" ? root.processSortDir : 0
                    width: root.procColGpuMem
                  }
                  Item {
                    width: root.procColAct
                    height: parent.height
                  }
                }
              }

              Repeater {
                model: root.sortedProcesses()
                delegate: ProcessRow {
                  procData: modelData
                  index: index
                }
              }

              Text {
                visible: root.processes.length === 0
                width: parent.width
                text: "No process data yet. Waiting for first sample..."
                color: root.textDim2
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- Tab: Privacy
          Column {
            visible: root.activeTab === 2
            width: parent.width
            spacing: Style.space(4)

            PanelTitle { text: "PRIVACY MONITOR" }

            Text {
              width: parent.width
              text: "Active hardware device access detected by OmaControl."
              color: root.textDim2
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.privacyDevices
              delegate: PrivacyRow {
                deviceData: modelData
              }
            }

            Rectangle {
              visible: root.privacyDevices.length === 0
              width: parent.width
              height: Style.space(40)
              radius: 6
              color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.04)

              Text {
                anchors.centerIn: parent
                text: "No active device access detected"
                color: root.accented
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            PanelTitle { text: "PRIVACY LOG" }

            Text {
              width: parent.width
              text: "Start/stop history for webcam, microphone, and location access."
              color: root.textDim2
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.privacyEvents
              delegate: Rectangle {
                property var ev: modelData
                width: parent.width
                height: Style.space(24)
                radius: 4
                color: ev.action === "start"
                  ? Qt.rgba(0.96, 0.27, 0.42, 0.12)
                  : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.05)

                Row {
                  width: parent.width
                  height: parent.height
                  spacing: Style.space(6)

                  Text {
                    text: ev.action === "start"
                      ? (ev.device === "camera" ? "󰄀" : (ev.device === "location" ? "󰍺" : "󰍬"))
                      : "󰅙"
                    color: ev.action === "start" ? Color.urgent : root.textDim1
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    text: (ev.action === "start" ? "START " : "STOP  ")
                      + (ev.device === "camera" ? "Camera" : (ev.device === "location" ? "Location" : "Mic"))
                    color: ev.action === "start" ? Color.urgent : root.textDim1
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                  Text {
                    elide: Text.ElideRight
                    text: ev.name
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Item {
                    width: 1
                    height: 1
                  }
                  Text {
                    text: Model.fmtClock(ev.ts) + " (" + Model.fmtTimeAgo(ev.ts) + ")"
                    color: root.textDim2
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            Text {
              visible: root.privacyEvents.length === 0
              width: parent.width
              text: "No access logged yet."
              color: root.textDim2
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---- Tab: Rules
          Column {
            visible: root.activeTab === 3
            width: parent.width
            spacing: Style.space(4)

            PanelTitle { text: "ENFORCEMENT RULES" }

            Text {
              width: parent.width
              text: "Define patterns to automatically kill matching processes."
              color: root.textDim2
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.rules
              delegate: RuleRow {
                ruleData: modelData
                ruleIndex: index
              }
            }

            // Add-rule form
            Rectangle {
              width: parent.width
              height: Style.space(102)
              radius: 6
              color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.05)
              border.color: root.textDim2
              border.width: 1

              Column {
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: Style.space(6)

                Text {
                  text: "Add rule"
                  color: root.textDim1
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1
                }

                TextField {
                  id: ruleNameField
                  width: parent.width
                  placeholderText: "Name (e.g. Block uBlock)"
                  font.pixelSize: Style.font.caption
                  horizontalPadding: Style.space(8)
                  verticalPadding: Style.space(4)
                }

                Row {
                  width: parent.width
                  spacing: Style.space(6)

                  TextField {
                    id: rulePatternField
                    width: parent.width - addRuleBtn.width - Style.space(6)
                    placeholderText: "Process pattern (e.g. firefox)"
                    font.pixelSize: Style.font.caption
                    horizontalPadding: Style.space(8)
                    verticalPadding: Style.space(4)
                    onAccepted: addRuleBtn.click()
                  }

                  Rectangle {
                    id: addRuleBtn
                    width: Style.space(28)
                    height: Style.space(28)
                    radius: 6
                    color: addRuleArea.containsMouse ? root.accented : "transparent"
                    border.color: root.accented
                    border.width: 1

                    Text {
                      anchors.centerIn: parent
                      text: "󰄾"
                      color: addRuleArea.containsMouse ? Color.background : root.accented
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }

                    MouseArea {
                      id: addRuleArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        if (rulePatternField.text.trim() !== "") {
                          root.addRule(
                            ruleNameField.text.trim() !== "" ? ruleNameField.text.trim() : "Block " + rulePatternField.text.trim(),
                            rulePatternField.text.trim())
                          ruleNameField.text = ""
                          rulePatternField.text = ""
                        }
                      }
                    }
                  }
                }
              }
            }

            // Enforce button
            Rectangle {
              width: parent.width
              height: Style.space(32)
              radius: 6
              color: enforceArea.containsMouse ? Color.urgent : "transparent"
              border.color: Color.urgent
              border.width: 1

              Text {
                anchors.centerIn: parent
                text: "Enforce Rules Now"
                color: enforceArea.containsMouse ? Color.background : Color.urgent
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              MouseArea {
                id: enforceArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.enforceRules()
              }
            }

            // Enforcement result
            Rectangle {
              visible: root.enforceResult !== ""
              width: parent.width
              height: Style.space(32)
              radius: 6
              color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.06)

              Text {
                anchors.centerIn: parent
                text: {
                  try {
                    var obj = JSON.parse(root.enforceResult)
                    if (obj.killed.length === 0) return "No matching processes found"
                    return "Killed " + obj.killed.length + " process(es)"
                  } catch (e) {
                    return "Enforcement complete"
                  }
                }
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- Tab: Settings (bar icon stats multi-select)
          Column {
            visible: root.activeTab === 4
            width: parent.width
            spacing: Style.space(8)

            PanelTitle { text: "BAR ICON STATS" }

            Text {
              width: parent.width
              text: "Choose which stats appear in the bar icon. Select any number — order matches your selection order."
              color: root.textDim2
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                text: "Show as:"
                color: root.textDim1
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }

              Rectangle {
                id: iconModeBtn
                width: Style.space(64)
                height: Style.space(26)
                radius: 6
                border.color: root.barStatMode === "icon" ? root.accented : root.textDim2
                border.width: 1
                color: (iconModeArea.containsMouse || root.barStatMode === "icon")
                  ? Qt.rgba(root.accented.r, root.accented.g, root.accented.b, 0.18)
                  : "transparent"

                Text {
                  anchors.centerIn: parent
                  text: "Icon"
                  color: root.barStatMode === "icon" ? root.accented : root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                MouseArea {
                  id: iconModeArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: hostWidget.setBarStatMode("icon")
                }
              }

              Rectangle {
                id: nameModeBtn
                width: Style.space(64)
                height: Style.space(26)
                radius: 6
                border.color: root.barStatMode === "name" ? root.accented : root.textDim2
                border.width: 1
                color: root.barStatMode === "name" ? Qt.rgba(root.accented.r, root.accented.g, root.accented.b, 0.18) : "transparent"

                Text {
                  anchors.centerIn: parent
                  text: "Name"
                  color: root.barStatMode === "name" ? root.accented : root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: hostWidget.setBarStatMode("name")
                }
              }
            }

            Rectangle {
              width: parent.width
              height: Style.space(40)
              radius: 6
              color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.06)

              Row {
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: Style.space(8)

                Text {
                  id: previewVLabel
                  text: "Preview:"
                  color: root.textDim1
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: root.barStats.length === 0
                    ? "󰍛 (icon only)"
                    : "󰍛 " + root.barStats.map(function(id) {
                        var v = Model.barStatValue(root.sysData, id)
                        if (!v) return null
                        return (root.barStatMode === "name" ? Model.barStatLabel(id) : Model.barStatGlyph(id)) + " " + v
                      }).filter(function(v) { return v }).join("  ")
                  color: root.accented
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight
                  width: parent.width - previewVLabel.width - Style.space(16)
                }
              }
            }

            Flow {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.barStatsCatalog
                delegate: Item {
                  id: statRow

                  width: (parent.width - Style.space(6)) / 2
                  height: Style.space(30)

                  Rectangle {
                    anchors.fill: parent
                    radius: 6
                    color: statHover.containsMouse || root.isBarStat(modelData.id)
                      ? Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)
                      : "transparent"
                    border.color: root.isBarStat(modelData.id) ? root.accented : root.textDim2
                    border.width: 1
                  }

                  Row {
                    anchors.fill: parent
                    anchors.margins: Style.space(6)
                    spacing: Style.space(8)

                    Text {
                      id: checkGlyph
                      text: root.isBarStat(modelData.id) ? "󰄲" : "󰄱"
                      color: root.isBarStat(modelData.id) ? root.accented : root.textDim2
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      text: modelData.glyph || ""
                      color: root.accented
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      text: modelData.label
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      anchors.verticalCenter: parent.verticalCenter
                      width: parent.width - checkGlyph.width - Style.space(30) - statValue.width - Style.space(12)
                      elide: Text.ElideRight
                    }

                    Text {
                      id: statValue
                      text: Model.barStatValue(root.sysData, modelData.id)
                      color: root.textDim2
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      anchors.verticalCenter: parent.verticalCenter
                      horizontalAlignment: Text.AlignRight
                    }
                  }

                  MouseArea {
                    id: statHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleBarStat(modelData.id)
                  }
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              Rectangle {
                width: Style.space(96)
                height: Style.space(28)
                radius: 6
                color: resetAllArea.containsMouse ? Color.urgent : "transparent"
                border.color: Color.urgent
                border.width: 1

                Text {
                  anchors.centerIn: parent
                  text: "Reset to default"
                  color: resetAllArea.containsMouse ? Color.background : Color.urgent
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                MouseArea {
                  id: resetAllArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: hostWidget.setBarStats(["cpu", "cputemp"])
                }
              }
            }

            Text {
              width: parent.width
              text: "5: settings  •  Tip: stats with no live value are hidden in the bar."
              color: root.textDim2
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }
          }

          // ---- Keyboard hint
          Text {
            width: parent.width
            text: "1-5: tabs  •  R: refresh  •  Esc: close"
            color: root.textDim2
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  // ---- Chart sub-components

  component ChartChip: Item {
    property string label: ""
    property int seconds: 3600
    property bool active: root.chartWindow === seconds

    width: chipLabel.implicitWidth + Style.space(16)
    height: Style.space(20)

    Rectangle {
      anchors.fill: parent
      radius: Math.round(height / 2)
      color: active ? root.accented : "transparent"
    }

    Rectangle {
      anchors.fill: parent
      radius: Math.round(height / 2)
      visible: chipHover.containsMouse && !active
      color: Qt.darker(root.contentForeground, 1.4)
      opacity: 0.25
    }

    Text {
      id: chipLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: label
      color: active ? Color.background : root.textDim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 0.5
    }

    MouseArea {
      id: chipHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.chartWindow = seconds
    }
  }

  component HistoryChart: Item {
    id: chart
    property var history: []
    property int windowSecs: 3600
    readonly property color tintCpu: Color.accent
    readonly property color tintGpu: Color.muted

    Text {
      id: chartHeader
      anchors.top: parent.top
      anchors.left: parent.left
      textFormat: Text.PlainText
      text: "RESOURCE HISTORY \u00b7 LAST " + (chart.windowSecs >= 3600 ? Math.round(chart.windowSecs / 3600) + "H" : Math.round(chart.windowSecs / 60) + " MIN")
      color: Qt.darker(root.contentForeground, 1.4)
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
    }

    Canvas {
      id: canvas
      anchors.top: chartHeader.bottom
      anchors.topMargin: Style.space(4)
      anchors.left: parent.left
      anchors.right: parent.right
      height: parent.height - chartHeader.implicitHeight - Style.space(4)

      property real hoverX: -1
      onHoverXChanged: requestPaint()

      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()

      HoverHandler {
        onPointChanged: canvas.hoverX = hovered ? point.position.x : -1
        onHoveredChanged: if (!hovered) canvas.hoverX = -1
      }

      Connections {
        target: chart
        function onHistoryChanged() { canvas.requestPaint() }
      }

      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.clearRect(0, 0, width, height)

        var pts = chart.history
        if (!pts || pts.length < 2) {
          ctx.font = "11px " + root.contentFontFamily
          ctx.fillStyle = root.textDim2
          ctx.textAlign = "center"
          ctx.fillText("Collecting data...", width / 2, height / 2)
          return
        }

        var now = Math.floor(Date.now() / 1000)
        var start = now - chart.windowSecs
        var span = chart.windowSecs

        function xOf(ts) {
          return Math.max(0, Math.min(width - 1, (ts - start) * width / span))
        }

        // CPU line
        var maxCpu = Math.max(100, Model.maxField(pts, "cpu"))
        ctx.beginPath()
        for (var i = 0; i < pts.length; i++) {
          var x = xOf(pts[i].ts)
          var y = height - (pts[i].cpu / maxCpu) * height * 0.9
          if (i === 0) ctx.moveTo(x, y)
          else ctx.lineTo(x, y)
        }
        ctx.strokeStyle = chart.tintCpu
        ctx.lineWidth = 1.5
        ctx.stroke()

        // Fill under CPU
        ctx.lineTo(xOf(pts[pts.length - 1].ts), height)
        ctx.lineTo(xOf(pts[0].ts), height)
        ctx.closePath()
        ctx.fillStyle = Qt.rgba(chart.tintCpu.r, chart.tintCpu.g, chart.tintCpu.b, 0.12)
        ctx.fill()

        // GPU line (if data exists)
        var hasGpu = false
        for (var g = 0; g < pts.length; g++) {
          if (pts[g].gpu > 0) { hasGpu = true; break }
        }
        if (hasGpu) {
          var maxGpu = Math.max(100, Model.maxField(pts, "gpu"))
          ctx.beginPath()
          for (var j = 0; j < pts.length; j++) {
            var xg = xOf(pts[j].ts)
            var yg = height - (pts[j].gpu / maxGpu) * height * 0.9
            if (j === 0) ctx.moveTo(xg, yg)
            else ctx.lineTo(xg, yg)
          }
          ctx.strokeStyle = chart.tintGpu
          ctx.lineWidth = 1.2
          ctx.stroke()
        }

        // Legend
        ctx.font = "10px " + root.contentFontFamily
        ctx.textBaseline = "top"
        ctx.fillStyle = chart.tintCpu
        ctx.fillRect(4, 3, 10, 3)
        ctx.fillStyle = root.textDim1
        ctx.fillText("CPU", 18, 0)
        if (hasGpu) {
          ctx.fillStyle = chart.tintGpu
          ctx.fillRect(48, 3, 10, 3)
          ctx.fillStyle = root.textDim1
          ctx.fillText("GPU", 62, 0)
        }

        // Hover: vertical guide + exact readings at that time
        if (canvas.hoverX >= 0) {
          var tAt = start + canvas.hoverX * span / (width - 1)
          var best = null, bestD = Infinity
          for (var h = 0; h < pts.length; h++) {
            var dd = Math.abs(pts[h].ts - tAt)
            if (dd < bestD) { bestD = dd; best = pts[h] }
          }
          if (best) {
            var cxx = xOf(best.ts)
            ctx.strokeStyle = Qt.rgba(root.contentForeground.r, root.contentForeground.g,
                                      root.contentForeground.b, 0.4)
            ctx.lineWidth = 1
            ctx.beginPath()
            ctx.moveTo(cxx + 0.5, 0)
            ctx.lineTo(cxx + 0.5, height)
            ctx.stroke()

            var label = Qt.formatTime(new Date(best.ts * 1000), "HH:mm:ss")
              + "   CPU " + Math.round(best.cpu) + "%"
              + (hasGpu ? "   GPU " + (best.gpu > 0 ? Math.round(best.gpu) + "%" : "--") : "")

            var fg = root.contentForeground
            var bg = Color.popups ? Color.popups.background : Qt.rgba(0.1, 0.1, 0.14, 1)
            ctx.font = "10px " + root.contentFontFamily
            var w = ctx.measureText(label).width + 12
            var bx = Math.max(2, Math.min(width - w - 2, cxx - w / 2))
            ctx.fillStyle = Qt.rgba(bg.r, bg.g, bg.b, 0.92)
            ctx.fillRect(bx, 2, w, 16)
            ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.25)
            ctx.lineWidth = 1
            ctx.strokeRect(bx + 0.5, 2.5, w - 1, 15)
            ctx.fillStyle = fg
            ctx.textBaseline = "alphabetic"
            ctx.fillText(label, bx + 6, 2 + 8 + 3.6)
          }
        }
      }
    }
  }
}
