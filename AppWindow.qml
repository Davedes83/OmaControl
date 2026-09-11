import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "Model.js" as Model

// OmControl standalone app window (theme-aware). Shown via IPC openApp/closeApp.
//
// Tabs: Activity (live metric pills, zoomable history graph with hover tooltip +
// click-to-drill, mini range selector, process list with search + sparklines),
// Apps (grouped by name with quick-action menus: terminate/suspend/resume/renice),
// Alerts (threshold + runaway-process buckets with dismiss), Events (new-app and
// spike feed with unread dots). Plus a compact/expand mode.

PanelWindow {
  id: root
  property bool open: false
  property bool compact: false
  property string layerNamespace: "omarchy-omacontrol-app"

  visible: open
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: root.layerNamespace
  WlrLayershell.layer: WlrLayer.Overlay

  // ---- Theme (follows the running Omarchy theme automatically) ----
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color fg: Color.foreground
  readonly property color bg: Color.background
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color muted: Color.muted
  readonly property color surface: Color.popups.background
  readonly property color surfaceBorder: Color.popups.border
  readonly property color dim1: Qt.darker(fg, 1.35)
  readonly property color dim2: Qt.darker(fg, 1.7)
  readonly property color accentSoft: Qt.rgba(accent.r, accent.g, accent.b, 0.14)

  // ---- Data (DB snapshot via sample-json.sh) ----
  property var sample: ({ cpu: 0, mem: 0, gpu: 0, procs: 0, disk: 0,
                          net_rx_kbs: 0, net_tx_kbs: 0,
                          history_1h: [], history_6h: [], history_1d: [],
                          p_list: [], snaps: [], apps: [], catalog: [],
                          alerts: [], events: [], alert_prefs: {},
                          disabled: [], perms: {} })
  property string selMetric: "cpu"
  property int chartWindow: 3600
  property int activeTab: 0
  property string search: ""
  property var drillProcs: null
  property real drillTs: 0
  property var filteredProcs: []
  property bool sampleProcRunning: false
  property var filteredApps: []
  property var groupedApps: []
  property string appSearch: ""
  property string activityFilter: "all"
  property bool showDisabledOnly: false
  property string appsView: "publisher"
  property var dismissedAlerts: []
  property string alertFilter: "all"
  property string eventFilter: "all"
  property string eventSearch: ""
  property var filteredEvents: []
  property int alertsSeenTs: 0
  property int eventSeenTs: 0
  property int alertBadge: 0
  property int eventBadge: 0
  property var alertPrefs: ({ enabled: true, types: {} })
  property var detailApp: null
  property var detailStats: null
  property bool detailStatsBusy: false
  property var detailNet: null
  property bool detailNetBusy: false

  property var barPrefs: ({ stats: ["cpu", "cputemp"], mode: "icon" })
  property bool barPrefsLoaded: false
  readonly property string dataDir: Quickshell.env("HOME") + "/.local/share/omcontrol"
  readonly property string barStatsPath: dataDir + "/barstats.json"

  readonly property var metricUnits: ({ cpu: "%", mem: "%", gpu: "%", procs: "", disk: "%", net: "KB/s" })
  readonly property var filteredAlerts: root.computeAlerts()
  readonly property int activeAlertCount: root.filteredAlerts.length

  // The 8 alert sensitivities for the Alerts config tab (display order).
  readonly property var alertTypes: [
    "New App Launch", "Mic or Cam Access", "Service Change", "Unsigned App Launch",
    "Location Tracking", "New Service Launch", "App Update", "New Suspicious App"
  ]

  function liveValue(key) {
    switch (key) {
      case "cpu": return Math.round(root.sample.cpu * 10) / 10
      case "mem": return root.sample.mem
      case "gpu": return root.sample.gpu
      case "procs": return root.sample.procs
      case "disk": return root.sample.disk
      case "net": return "\u2193 " + root.fmtNet(root.sample.net_rx_kbs) + "   \u2191 " + root.fmtNet(root.sample.net_tx_kbs)
    }
    return 0
  }

  function fmtNet(kbs) {
    kbs = Math.max(0, Number(kbs) || 0)
    if (kbs >= 1024) return (kbs / 1024).toFixed(1) + "M"
    if (kbs >= 1) return Math.round(kbs) + "K"
    return "0"
  }

  function seriesFor(metric, windowSecs) {
    var list
    if (windowSecs >= 86400) list = root.sample.history_1d
    else if (windowSecs >= 21600) list = root.sample.history_6h
    else list = root.sample.history_1h
    var pts = []
    for (var i = 0; i < list.length; i++) {
      var h = list[i]
      var v
      switch (metric) {
        case "cpu": v = h.cpu; break
        case "mem": v = h.mem_pct; break
        case "gpu": v = h.gpu; break
        case "procs": v = h.procs; break
        case "disk": v = h.disk; break
        case "net": v = (h.rx || 0) + (h.tx || 0); break
        default: v = 0
      }
      pts.push({ ts: h.ts, v: v })
    }
    return pts
  }

  function nearestSnap(ts) {
    var snaps = root.sample.snaps
    if (!snaps.length) return null
    var best = null, bd = 1e18
    for (var i = 0; i < snaps.length; i++) {
      var d = Math.abs(snaps[i].ts - ts)
      if (d < bd) { bd = d; best = snaps[i] }
    }
    return (bd <= 150) ? best : null
  }

  function topAt(ts, n) {
    var snap = root.nearestSnap(ts)
    if (!snap || !snap.procs) return []
    var got = snap.procs.slice()
    got.sort(function(a, b) { return b.cpu - a.cpu })
    return got.slice(0, n)
  }

  function fmtTime(ts) {
    return Qt.formatTime(new Date(ts * 1000), "HH:mm:ss")
  }

  function fmtAgo(ts) {
    var s = Math.max(0, Math.floor(Date.now() / 1000 - ts))
    if (s < 60) return "just now"
    if (s < 3600) return Math.floor(s / 60) + "m ago"
    if (s < 86400) return Math.floor(s / 3600) + "h ago"
    return Math.floor(s / 86400) + "d ago"
  }

  // Merge the running apps with the known-apps catalog into one inventory,
  // apply the search + activity + disabled filters, sort, and (optionally)
  // regroup by publisher for the publisher view.
  function renderApps() {
    var q = root.appSearch.trim().toLowerCase()
    var byName = {}
    var src = root.sample.apps || []
    var cat = root.sample.catalog || []
    var i, a
    for (i = 0; i < src.length; i++) byName[(src[i].name || "").toLowerCase()] = src[i]
    for (i = 0; i < cat.length; i++) {
      var nm = cat[i].name || ""
      var k = nm.toLowerCase()
      if (byName[k]) {
        byName[k].running = true
        byName[k].disabled = cat[i].disabled
      } else {
        byName[k] = { name: nm, cpu: 0, mem: 0, io: 0, gpu: 0, pids: [], spark: [],
                      publisher: cat[i].publisher, verified: cat[i].verified,
                      source: cat[i].source, desc: cat[i].desc,
                      perms: cat[i].perms || [], disabled: cat[i].disabled, running: false }
      }
    }
    var out = []
    for (var key in byName) out.push(byName[key])
    if (q !== "") {
      out = out.filter(function(a) {
        return (a.name || "").toLowerCase().indexOf(q) >= 0
            || (a.publisher || "").toLowerCase().indexOf(q) >= 0
      })
    }
    if (root.activityFilter === "running") out = out.filter(function(a) { return a.running })
    if (root.activityFilter === "not") out = out.filter(function(a) { return !a.running })
    if (root.showDisabledOnly) out = out.filter(function(a) { return a.disabled })
    out.sort(function(a, b) {
      if (a.running !== b.running) return a.running ? -1 : 1
      return (b.cpu || 0) - (a.cpu || 0)
    })
    root.filteredApps = out.slice(0, 400)
    root.groupedApps = root.groupByPublisher(root.filteredApps)
  }

  function groupByPublisher(list) {
    var groups = {}
    var order = []
    for (var i = 0; i < list.length; i++) {
      var pub = (list[i].publisher || "Unknown") || "Unknown"
      if (!groups[pub]) { groups[pub] = []; order.push(pub) }
      groups[pub].push(list[i])
    }
    var out = []
    for (var j = 0; j < order.length; j++) {
      var apps = groups[order[j]]
      var running = 0, disabled = 0
      for (var k = 0; k < apps.length; k++) {
        if (apps[k].running) running++
        if (apps[k].disabled) disabled++
      }
      out.push({ publisher: order[j], apps: apps, noteCount: apps.length,
                runningCount: running, disabledCount: disabled })
    }
    out.sort(function(x, y) {
      var xr = x.runningCount > 0, yr = y.runningCount > 0
      if (xr !== yr) return xr ? -1 : 1
      var xn = 0, yn = 0, i
      for (i = 0; i < x.apps.length; i++) xn += x.apps[i].cpu || 0
      for (i = 0; i < y.apps.length; i++) yn += y.apps[i].cpu || 0
      return yn - xn
    })
    return out
  }

  function confirmedDisable(name) {
    // Disabling is persistent and cannot be undone by a restart — always
    // ask for explicit confirmation from the panel level.
    confirmBar.show(name)
  }

  function computeAlerts() {
    var src = root.sample.alerts || []
    var f = root.alertFilter
    var out = []
    for (var i = 0; i < src.length; i++) {
      var a = src[i]
      if (f === "critical" && a.severity !== "critical") continue
      if (f === "info" && a.severity !== "info") continue
      if (root.dismissedAlerts.indexOf(a.kind + "|" + a.ts + "|" + a.msg) >= 0) continue
      out.push(a)
    }
    return out
  }

  // Event kinds by filter bucket (spec: superset of entry types).
  function bucketKinds(f) {
    switch (f) {
      case "new_app": return ["app_launch"]
      case "exit": return ["app_exit"]
      case "security": return ["unsigned_launch", "publisher_block", "unknown_app"]
      case "permission": return ["mic_access", "cam_access", "location_access", "permission"]
      case "user": return ["user_kill", "user_disable", "user_enable", "user_pause", "user_resume", "user_priority"]
      case "spike": return ["cpu_spike", "mem_spike"]
      default: return null
    }
  }

  function computeEvents() {
    var src = root.sample.events || []
    var kinds = root.bucketKinds(root.eventFilter)
    var q = root.eventSearch.trim().toLowerCase()
    var out = []
    for (var i = 0; i < src.length; i++) {
      var e = src[i]
      if (kinds && kinds.indexOf(e.kind) < 0) continue
      if (q !== "") {
        var hay = ((e.app || "") + " " + (e.publisher || "") + " " + (e.msg || "")).toLowerCase()
        if (hay.indexOf(q) < 0) continue
      }
      out.push(e)
    }
    root.filteredEvents = out.slice(0, 200)
    return root.filteredEvents
  }

  function updateBadges() {
    var alerts = root.sample.alerts || []
    var crit = 0
    for (var i = 0; i < alerts.length; i++) {
      if (alerts[i].severity === "critical") crit++
    }
    root.alertBadge = crit
    var ev = root.sample.events || []
    var unread = 0
    for (var j = 0; j < ev.length; j++) if (!ev[j].read) unread++
    root.eventBadge = unread
  }

  function appAction(action, name) {
    appActionProc.command = ["sh",
      Qt.resolvedUrl("backend/app-action.sh").toString().replace("file://", ""),
      action, name]
    appActionProc.running = true
  }

  function loadStats(nm) {
    if (!nm) { root.detailStats = null; return }
    root.detailStatsBusy = true
    statsProc.command = [Qt.resolvedUrl("backend/app-stats.sh").toString().replace("file://", ""), nm]
    statsProc.running = true
  }

  function isBarPref(id) { return (root.barPrefs.stats || []).indexOf(id) >= 0 }
  function barPrefPreview() {
    var list = root.barPrefs.stats || []
    if (root.barPrefs.mode === "none") return "(values only, no icon or name)"
    var out = []
    for (var i = 0; i < list.length; i++) {
      var lead = root.barPrefs.mode === "name"
          ? Model.barStatLabel(list[i])
          : Model.barStatGlyph(list[i])
      if (lead) out.push(lead)
    }
    return out.length ? out.join("  ") : "(icon only)"
  }
  function toggleBarPref(id) {
    var list = (root.barPrefs.stats || []).slice()
    var i = list.indexOf(id)
    if (i >= 0) list.splice(i, 1); else list.push(id)
    root.barPrefs = { stats: list, mode: root.barPrefs.mode || "icon" }
    root.saveBarPrefs()
  }
  function setBarPrefMode(m) {
    if (m !== "icon" && m !== "name" && m !== "none") return
    root.barPrefs = { stats: root.barPrefs.stats || [], mode: m }
    root.saveBarPrefs()
  }
  function resetBarPrefs() {
    root.barPrefs = { stats: ["cpu", "cputemp"], mode: "icon" }
    root.saveBarPrefs()
  }
  function saveBarPrefs() {
    var json = JSON.stringify({ stats: root.barPrefs.stats || [], mode: root.barPrefs.mode || "icon" })
    var safe = json.replace(/'/g, "'\\''")
    barPrefsSaveProc.command = ["sh", "-c",
      "mkdir -p '" + root.dataDir + "' && printf '%s' '" + safe + "' > '" + root.barStatsPath + "'"]
    barPrefsSaveProc.running = false
    barPrefsSaveProc.running = true
  }
  function loadBarPrefs() {
    barPrefsLoadProc.command = ["sh", "-c", "cat '" + root.barStatsPath + "' 2>/dev/null || echo '{}'"]
    barPrefsLoadProc.running = true
  }

  function loadNet(nm) {
    if (!nm) { root.detailNet = null; return }
    root.detailNetBusy = true
    netProc.command = [Qt.resolvedUrl("backend/app-net.sh").toString().replace("file://", ""), nm]
    netProc.running = true
  }

  // Disable with confirm; enable is non-destructive so goes straight through.
  function disableApp(name) { root.confirmedDisable(name) }
  function enableApp(name) { root.appAction("enable", name) }

  function dismissAlert(key) {
    var arr = root.dismissedAlerts.slice()
    if (arr.indexOf(key) < 0) arr.push(key)
    root.dismissedAlerts = arr
  }

  function sparksFor(name) {
    var snaps = root.sample.snaps
    var out = []
    for (var i = 0; i < snaps.length; i++) {
      var procs = snaps[i].procs
      var v = -1
      for (var j = 0; j < procs.length; j++) {
        if (procs[j].name === name) { v = procs[j].cpu; break }
      }
      out.push(v)
    }
    return out
  }

  function renderList() {
    var q = root.search.trim().toLowerCase()
    var out = []
    for (var i = 0; i < root.sample.p_list.length; i++) {
      var p = root.sample.p_list[i]
      if (q !== "" && (p.name || "").toLowerCase().indexOf(q) < 0) continue
      out.push(p)
    }
    out.sort(function(a, b) { return b.cpu - a.cpu })
    root.filteredProcs = out
  }

  function onSampleReceived() {
    root.alertPrefs = root.sample.alert_prefs || { enabled: true, types: {} }
    root.renderList()
    root.renderApps()
    root.updateBadges()
    root.computeEvents()
  }

  // ---- persistence helpers (events read state + alert prefs) ----
  function runBackend(script, args) {
    var full = ["sh", Qt.resolvedUrl("backend/" + script).toString().replace("file://", "")].concat(args)
    actionProc.command = full
    actionProc.running = true
  }
  function markEventRead(id) { root.runBackend("events.sh", ["read", "" + id]) ; missingNsTimer() }
  function markAllEventsRead() { root.runBackend("events.sh", ["read-all"]); missingNsTimer() }
  function clearEvents() { root.runBackend("events.sh", ["clear"]); missingNsTimer() }
  function setAlertPref(type, on) { root.runBackend("alert-prefs.sh", ["set", type, on ? "on" : "off"]) }
  function setAlertsEnabled(on) { root.runBackend("alert-prefs.sh", ["set-enabled", on ? "on" : "off"]) }
  function refreshSoon() { refreshTimer.start() }

  onSampleChanged: root.onSampleReceived()
  onSearchChanged: root.renderList()
  onAppSearchChanged: root.renderApps()
  onActivityFilterChanged: root.renderApps()
  onShowDisabledOnlyChanged: root.renderApps()
  onEventSearchChanged: root.computeEvents()
  onEventFilterChanged: root.computeEvents()

  function onSample(text) {
    try {
      root.sample = JSON.parse(text)
    } catch (e) {}
    if (root.open) sampleTimer.start()
  }

  // ---- Data loop ----
  Timer {
    id: sampleTimer
    interval: 4000
    repeat: false
    running: false
    onTriggered: {
      if (root.open && !root.sampleProcRunning) {
        root.sampleProcRunning = true
        sampleProc.running = true
      }
    }
  }

  Process {
    id: sampleProc
    command: ["sh", Qt.resolvedUrl("backend/sample-json.sh").toString().replace("file://", "")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onSample(text)
    }
    onRunningChanged: {
      if (!running) {
        root.sampleProcRunning = false
        if (root.open) sampleTimer.start()
      }
    }
  }

  Process {
    id: appActionProc
  }
  Process {
    id: statsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.detailStatsBusy = false
        try {
          var parsed = JSON.parse(text)
          root.detailStats = parsed && parsed.name ? parsed : null
        } catch (e) { root.detailStats = null }
      }
    }
  }
  Process {
    id: netProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.detailNetBusy = false
        try {
          var parsed = JSON.parse(text)
          root.detailNet = parsed ? parsed : null
        } catch (e) { root.detailNet = null }
      }
    }
  }
  Process {
    id: barPrefsLoadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          if (Array.isArray(parsed)) root.barPrefs = { stats: parsed, mode: root.barPrefs.mode || "icon" }
          else if (parsed && parsed.stats) root.barPrefs = { stats: parsed.stats, mode: ["icon","name","none"].indexOf(parsed.mode) >= 0 ? parsed.mode : "icon" }
        } catch (e) {}
        root.barPrefsLoaded = true
      }
    }
  }
  Process { id: barPrefsSaveProc }
  Process { id: actionProc }
  Timer { id: refreshTimer; interval: 5000; repeat: false; running: false
    onTriggered: { if (root.open) sampleProc.running = true }
  }
  function missingNsTimer() { refreshTimer.start() }

  onDetailAppChanged: { root.loadStats(root.detailApp ? root.detailApp.name : ""); root.loadNet(root.detailApp ? root.detailApp.name : "") }
  onOpenChanged: {
    if (root.open) {
      if (!root.sampleProcRunning) {
        root.sampleProcRunning = true
        sampleProc.running = true
      }
      root.activeTab = 0
      root.drillProcs = null
    }
  }
  onActiveTabChanged: {
    if (root.activeTab === 2) root.alertsSeenTs = Math.floor(Date.now() / 1000)
    if (root.activeTab === 3) root.eventSeenTs = Math.floor(Date.now() / 1000)
    if (root.activeTab === 4 && !root.barPrefsLoaded) root.loadBarPrefs()
    root.updateBadges()
  }

  // ================================================================ UI
  // Scrim: outside-click closes.
  Item {
    anchors.fill: parent
    z: 0
    TapHandler {
      onTapped: root.open = false
    }
  }

  Rectangle {
    id: card
    z: 1
    width: root.compact ? Style.space(900) : Style.space(1100)
    height: root.compact ? Style.space(170) : Style.space(740)
    anchors.centerIn: parent
    radius: Style.cornerRadius || 12
    color: root.surface
    border.width: 1
    border.color: root.surfaceBorder
    clip: true
    Behavior on height { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
    Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

    // Consume clicks on the card body so they never reach the scrim.
    MouseArea { anchors.fill: parent }

    ColumnLayout {
      id: bodyCol
      anchors.fill: parent
      spacing: 0

      // ==================== Top bar
      Item {
        Layout.fillWidth: true
        Layout.preferredHeight: root.compact ? Style.space(48) : Style.space(64)

        Row {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(18)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(10)
          Rectangle {
            width: Style.space(34)
            height: Style.space(34)
            radius: Style.space(12)
            color: root.accentSoft
            border.width: 1
            border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.5)
            Text {
              anchors.centerIn: parent
              text: "\uf201"
              color: root.accent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }
          }
          Column {
            spacing: Style.space(1)
            Text {
              text: "OmaControl"
              color: root.fg
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              visible: !root.compact
              text: "Your machine, live"
              color: root.dim2
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Row {
          anchors.centerIn: parent
          spacing: Style.space(6)
          OMCPill {
            label: root.compact ? "\uf065  Expand" : "\uf066  Compact"
            active: false
            onChosen: root.compact = !root.compact
          }
        }
      }

      Item {
        Layout.fillWidth: true
        Layout.preferredHeight: 1
        Rectangle { anchors.fill: parent; color: root.surfaceBorder; opacity: 0.35 }
      }

      // ==================== Body (pages)
      Item {
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true

        // ---- Activity page
        Item {
          visible: root.activeTab === 0
          anchors.fill: parent
          anchors.margins: Style.space(16)

          Row {
            id: metricRow
            visible: !root.compact
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Style.space(8)

            OMCPill { label: "CPU"; value: root.liveValue("cpu") + "%"; active: root.selMetric === "cpu"; onChosen: root.selMetric = "cpu" }
            OMCPill { label: "Memory"; value: root.liveValue("mem") + "%"; active: root.selMetric === "mem"; onChosen: root.selMetric = "mem" }
            OMCPill { label: "GPU"; value: root.liveValue("gpu") + "%"; active: root.selMetric === "gpu"; onChosen: root.selMetric = "gpu" }
            OMCPill { label: "Processes"; value: Math.round(root.liveValue("procs")); active: root.selMetric === "procs"; onChosen: root.selMetric = "procs" }
            OMCPill { label: "Disk"; value: root.liveValue("disk") + "%"; active: root.selMetric === "disk"; onChosen: root.selMetric = "disk" }
            OMCPill { label: "Net"; value: root.liveValue("net"); active: root.selMetric === "net"; onChosen: root.selMetric = "net" }

            Item { width: Style.space(20); height: 1 }

            RangePill { seconds: 3600; active: root.chartWindow === 3600; onChosen: root.chartWindow = 3600 }
            RangePill { seconds: 21600; active: root.chartWindow === 21600; onChosen: root.chartWindow = 21600 }
            RangePill { seconds: 86400; active: root.chartWindow === 86400; onChosen: root.chartWindow = 86400 }
          }

          Text {
            id: homeHint
            visible: !root.compact
            anchors.top: metricRow.bottom
            anchors.topMargin: Style.space(6)
            anchors.left: parent.left
            anchors.right: parent.right
            text: "drag to zoom · wheel to zoom around cursor · drag when zoomed to pan · double-click reset · click a point for that moment's processes"
            color: root.dim2
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          HistoryGraph {
            id: graph
            anchors.top: root.compact ? parent.top : homeHint.bottom
            anchors.topMargin: root.compact ? 0 : Style.space(8)
            anchors.left: parent.left
            anchors.right: parent.right
            height: root.compact
                ? parent.height - Style.space(4)
                : Style.space(235)
            pts: root.seriesFor(root.selMetric, root.chartWindow)
            lineColor: root.accent
            events: root.sample.events || []
            dangerColor: root.urgent
            dangerThreshold: (root.selMetric === "procs" || root.selMetric === "net") ? -1 : 90
            maxValue: (root.selMetric === "procs" || root.selMetric === "net") ? -1 : 100
            unit: root.metricUnits[root.selMetric]
            windowSecs: root.chartWindow
            onDrilled: function(ts) {
              root.drillTs = ts
              root.drillProcs = root.topAt(ts, 20)
              if (!root.drillProcs.length) root.drillProcs = null
              if (root.compact) root.compact = false
            }
          }

          MiniOverview {
            id: mini
            visible: !root.compact
            anchors.top: graph.bottom
            anchors.topMargin: Style.space(6)
            anchors.left: parent.left
            anchors.right: parent.right
            height: Style.space(40)
            pts: root.seriesFor(root.selMetric, root.chartWindow)
            graph: graph
          }

          Item {
            id: pane
            visible: !root.compact
            anchors.top: mini.bottom
            anchors.topMargin: Style.space(8)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom

            Row {
              id: paneHeader
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              spacing: Style.space(8)

              Rectangle {
                width: parent.width - (root.drillProcs !== null ? Style.space(112) : 0)
                height: Style.space(30)
                radius: Style.space(12)
                color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.12)
                border.width: 1
                border.color: Qt.rgba(root.dim1.r, root.dim1.g, root.dim1.b, 0.4)
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "\uf002"
                  color: root.dim1
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
                TextInput {
                  id: searchInput
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(28)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.fg
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  clip: true
                  selectByMouse: true
                  onTextChanged: root.search = text
                }
              }

              OMCPill {
                visible: root.drillProcs !== null
                width: Style.space(104)
                label: "\uf053  Live"
                active: false
                onChosen: root.drillProcs = null
              }
            }

            Text {
              id: paneTitle
              anchors.top: paneHeader.bottom
              anchors.topMargin: Style.space(4)
              anchors.left: parent.left
              anchors.right: parent.right
              text: root.drillProcs
                  ? "Processes at " + root.fmtTime(root.drillTs) + " · click the chart elsewhere to change the moment"
                  : "Running processes · click a row for details & actions"
              color: root.dim1
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            ColHeader {
              id: procHeader
              anchors.top: paneTitle.bottom
              anchors.topMargin: Style.space(6)
              anchors.left: parent.left
              anchors.right: parent.right
              leftLabel: "PROCESS"
              midLabel: "TRUST"
              rightLabel: "TREND     MEM     CPU"
            }

            ListView {
              id: procList
              anchors.top: procHeader.bottom
              anchors.topMargin: Style.space(2)
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              clip: true
              spacing: Style.space(2)
              model: root.drillProcs !== null ? root.drillProcs : root.filteredProcs
              delegate: ProcRow {
                width: procList.width
                name: modelData.name
                cpu: modelData.cpu
                mem: modelData.mem
                io: modelData.io_kbs
                gpu: modelData.gpu
                publisher: modelData.publisher
                verified: modelData.verified
                perms: modelData.perms
                instances: modelData.instances
                disabled: modelData.disabled
                sparks: root.sparksFor(modelData.name)
                onDetails: root.detailApp = ({ name: modelData.name,
                  publisher: modelData.publisher, verified: modelData.verified,
                  source: modelData.source, desc: modelData.desc || "",
                  exe: modelData.exe || "", pkg: modelData.pkg || "",
                  perms: modelData.perms || [], disabled: modelData.disabled,
                  cpu: modelData.cpu, mem: modelData.mem, instances: modelData.instances })
                onKill: root.appAction("kill", modelData.name)
                onDisable: root.disableApp(modelData.name)
                onEnable: root.enableApp(modelData.name)
              }
            }
          }
        }

        // ---- Apps page
        Item {
          visible: root.activeTab === 1
          anchors.fill: parent
          anchors.margins: Style.space(16)

          Row {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Style.space(8)

            Rectangle {
              width: parent.width - Style.space(360)
              height: Style.space(30)
              radius: Style.space(12)
              color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.12)
              border.width: 1
              border.color: Qt.rgba(root.dim1.r, root.dim1.g, root.dim1.b, 0.4)
              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: "\uf002"
                color: root.dim1
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
              TextInput {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(28)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                color: root.fg
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                clip: true
                selectByMouse: true
                onTextChanged: root.appSearch = text
              }
            }

            OMCPill { label: "Running"; active: root.activityFilter === "running"; onChosen: root.activityFilter = "running" }
            OMCPill { label: "Not running"; active: root.activityFilter === "not"; onChosen: root.activityFilter = "not" }
            OMCPill { label: "All"; active: root.activityFilter === "all"; onChosen: root.activityFilter = "all" }
            OMCPill { label: "Disabled"; active: root.showDisabledOnly; onChosen: root.showDisabledOnly = !root.showDisabledOnly }
            OMCPill {
              width: Style.space(112)
              label: root.appsView === "publisher" ? "\uf0c9  By publisher" : "\uf03a  Flat list"
              active: false
              onChosen: root.appsView = (root.appsView === "publisher" ? "list" : "publisher")
            }
          }

          Text {
            id: appsTitle
            anchors.top: parent.top
            anchors.topMargin: Style.space(38)
            anchors.left: parent.left
            anchors.right: parent.right
            text: (root.filteredApps || []).length + " apps · "
                + "click a row for details · hover a publisher for bulk actions"
            color: root.dim1
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          ColHeader {
            id: appHeader
            anchors.top: appsTitle.bottom
            anchors.topMargin: Style.space(6)
            anchors.left: parent.left
            anchors.right: parent.right
            leftLabel: "APP"
            midLabel: "TRUST"
            rightLabel: "TREND     MEM     CPU"
          }

          ListView {
            id: appList
            visible: root.appsView === "list"
            anchors.top: appHeader.bottom
            anchors.topMargin: Style.space(2)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            clip: true
            spacing: Style.space(4)
            model: root.filteredApps
            delegate: AppRow {
              width: appList.width
              app: modelData
              showPublisher: true
              onDetails: root.detailApp = modelData
              onKill: root.appAction("kill", modelData.name)
              onDisable: root.disableApp(modelData.name)
              onEnable: root.enableApp(modelData.name)
            }
          }

          ListView {
            id: publisherList
            visible: root.appsView === "publisher"
            anchors.top: appHeader.bottom
            anchors.topMargin: Style.space(2)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            clip: true
            spacing: Style.space(6)
            model: root.groupedApps
            delegate: PublisherGroup {
              width: publisherList.width
              group: modelData
              onBulkKill: function(names) {
                for (var i = 0; i < names.length; i++) root.appAction("kill", names[i])
              }
              onBulkDisable: function(names) { if (names.length) root.confirmedDisable(names[0]) }
              onDetails: function(app) { root.detailApp = app }
              onKill: function(name) { root.appAction("kill", name) }
              onDisable: function(name) { root.disableApp(name) }
              onEnable: function(name) { root.enableApp(name) }
            }
          }
        }

        // ---- Alerts page
        Item {
          visible: root.activeTab === 2
          anchors.fill: parent
          anchors.margins: Style.space(16)

          Row {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Style.space(8)
            OMCPill { label: "Alerts config"; active: true; onChosen: {} }
            Item { width: Style.space(10); height: 1 }
            OMCPill {
              label: root.alertPrefs.enabled ? "Alerts ON" : "Alerts OFF"
              active: root.alertPrefs.enabled !== false
              onChosen: {
                var next = !root.alertPrefs.enabled
                root.alertPrefs = ({ "enabled": next, "types": root.alertPrefs.types || {} })
                root.setAlertsEnabled(next)
                root.refreshSoon()
              }
            }
          }

          Text {
            id: alertsTitle
            anchors.top: parent.top
            anchors.topMargin: Style.space(38)
            anchors.left: parent.left
            anchors.right: parent.right
            text: "What can show as Events · move an item between 'Notify' and 'Quiet' buckets"
            color: root.dim1
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Row {
            anchors.top: alertsTitle.bottom
            anchors.topMargin: Style.space(8)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            spacing: Style.space(10)

            Column {
              width: (parent.width - Style.space(10)) / 2
              spacing: Style.space(6)
              Rectangle {
                width: parent.width; height: Style.space(30); radius: Style.space(12)
                color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12)
                border.width: 1
                border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.4)
                Text {
                  anchors.left: parent.left; anchors.leftMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter
                  text: "Notify me"
                  color: root.accent
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }
              Repeater {
                model: root.alertTypes
                delegate: OMCPill {
                  width: parent.width
                  active: (root.alertPrefs.types || {})[modelData] === true
                  label: modelData
                  onChosen: {
                    var types = {}; var src = root.alertPrefs.types || {}
                    for (var k in src) types[k] = src[k]
                    types[modelData] = true
                    root.alertPrefs = ({ "enabled": root.alertPrefs.enabled, "types": types })
                    root.setAlertPref(modelData, true)
                    root.refreshSoon()
                  }
                }
              }
            }

            Column {
              width: (parent.width - Style.space(10)) / 2
              spacing: Style.space(6)
              Rectangle {
                width: parent.width; height: Style.space(30); radius: Style.space(12)
                color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.10)
                border.width: 1
                border.color: Qt.rgba(root.dim1.r, root.dim1.g, root.dim1.b, 0.25)
                Text {
                  anchors.left: parent.left; anchors.leftMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter
                  text: "No notifications"
                  color: root.dim1
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }
              Repeater {
                model: root.alertTypes
                delegate: OMCPill {
                  width: parent.width
                  active: !((root.alertPrefs.types || {})[modelData])
                  label: modelData
                  onChosen: {
                    var types = {}; var src = root.alertPrefs.types || {}
                    for (var k in src) types[k] = src[k]
                    types[modelData] = false
                    root.alertPrefs = ({ "enabled": root.alertPrefs.enabled, "types": types })
                    root.setAlertPref(modelData, false)
                    root.refreshSoon()
                  }
                }
              }
            }
          }

          Text {
            visible: false
            anchors.fill: parent
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: "Toggle the global switch to stop all alerts.\nOpen the Events tab to see what you would have been notified about."
            color: root.dim2
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            lineHeight: 1.4
          }
        }

        // ---- Events page
        Item {
          visible: root.activeTab === 3
          anchors.fill: parent
          anchors.margins: Style.space(16)

          Row {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Style.space(8)
            OMCPill { label: "All"; active: root.eventFilter === "all"; onChosen: root.eventFilter = "all" }
            OMCPill { label: "Launches"; active: root.eventFilter === "new_app"; onChosen: root.eventFilter = "new_app" }
            OMCPill { label: "Exits"; active: root.eventFilter === "exit"; onChosen: root.eventFilter = "exit" }
            OMCPill { label: "Spikes"; active: root.eventFilter === "spike"; onChosen: root.eventFilter = "spike" }
            OMCPill { label: "Permissions"; active: root.eventFilter === "permission"; onChosen: root.eventFilter = "permission" }
            OMCPill { label: "Security"; active: root.eventFilter === "security"; onChosen: root.eventFilter = "security" }
            OMCPill { label: "User"; active: root.eventFilter === "user"; onChosen: root.eventFilter = "user" }
            Item { width: Style.space(6); height: 1 }
            OMCPill {
              visible: root.eventBadge > 0
              width: Style.space(112)
              label: "\uf053  Mark all read"
              active: true
              onChosen: { root.markAllEventsRead(); root.eventBadge = 0; root.computeEvents() }
            }
            OMCPill {
              width: Style.space(84)
              label: "\uf00d  Clear"
              active: false
              onChosen: { root.clearEvents() }
            }
          }

          Rectangle {
            id: eventSearchBar
            anchors.top: parent.top
            anchors.topMargin: Style.space(38)
            anchors.left: parent.left
            anchors.right: parent.right
            height: Style.space(26)
            radius: Style.space(12)
            color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.12)
            border.width: 1
            border.color: Qt.rgba(root.dim1.r, root.dim1.g, root.dim1.b, 0.4)
            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: "\uf002"
              color: root.dim1
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
            TextInput {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(28)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              color: root.fg
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              clip: true
              selectByMouse: true
              onTextChanged: root.eventSearch = text
            }
          }

          Text {
            id: eventsTitle
            anchors.top: eventSearchBar.bottom
            anchors.topMargin: Style.space(4)
            anchors.left: parent.left
            anchors.right: parent.right
            text: "Persistent history · unread in bold · action buttons stop apps right now"
            color: root.dim1
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          ListView {
            id: eventList
            anchors.top: eventsTitle.bottom
            anchors.topMargin: Style.space(6)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            clip: true
            spacing: Style.space(4)
            model: root.filteredEvents
            delegate: EventRow {
              width: eventList.width
              event: modelData
              onMarkRead: function(id) { root.markEventRead(id) }
              onKill: function(name) { root.appAction("kill", name) }
              onDisable: function(name) { root.disableApp(name) }
              onEnable: function(name) { root.enableApp(name) }
              onDetails: function(name) {
                var src = root.sample.apps || []
                for (var i = 0; i < src.length; i++) {
                  if (src[i].name === name) { root.detailApp = src[i]; return }
                }
                var cat = root.sample.catalog || []
                for (var j = 0; j < cat.length; j++) {
                  if (cat[j].name === name) { root.detailApp = cat[j]; return }
                }
              }
            }
          }

          Text {
            anchors.fill: eventList
            visible: (root.filteredEvents || []).length === 0
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: "\uf0c3\n\nNo events match — try a different filter or clear the search"
            color: root.dim2
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            lineHeight: 1.4
          }
        }

        // ---- Settings page (bar icon stats)
        Item {
          visible: root.activeTab === 4
          anchors.fill: parent
          anchors.margins: Style.space(16)

          Column {
            width: parent.width
            spacing: Style.space(10)

            Text {
              text: "BAR ICON STATS"
              color: root.fg
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              font.letterSpacing: 1
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Choose which stats appear in the OmaControl bar icon. Selection order matches the bar label order."
              color: root.dim1
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              spacing: Style.space(6)
              Text {
                text: "Show as:"
                color: root.dim1
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
              Rectangle {
                width: Style.space(64); height: Style.space(26); radius: Style.space(12)
                border.width: 1
                border.color: root.barPrefs.mode === "icon" ? root.accent : root.dim1
                color: (setIconModeArea.containsMouse || root.barPrefs.mode === "icon")
                    ? root.accentSoft : "transparent"
                Text {
                  anchors.centerIn: parent
                  text: "Icon"
                  color: root.barPrefs.mode === "icon" ? root.accent : root.dim1
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                MouseArea {
                  id: setIconModeArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setBarPrefMode("icon")
                }
              }
              Rectangle {
                width: Style.space(64); height: Style.space(26); radius: Style.space(12)
                border.width: 1
                border.color: root.barPrefs.mode === "name" ? root.accent : root.dim1
                color: (setNameModeArea.containsMouse || root.barPrefs.mode === "name")
                    ? root.accentSoft : "transparent"
                Text {
                  anchors.centerIn: parent
                  text: "Name"
                  color: root.barPrefs.mode === "name" ? root.accent : root.dim1
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                MouseArea {
                  id: setNameModeArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setBarPrefMode("name")
                }
              }
              Rectangle {
                width: Style.space(64); height: Style.space(26); radius: Style.space(12)
                border.width: 1
                border.color: root.barPrefs.mode === "none" ? root.accent : root.dim1
                color: (setNoneModeArea.containsMouse || root.barPrefs.mode === "none")
                    ? root.accentSoft : "transparent"
                Text {
                  anchors.centerIn: parent
                  text: "None"
                  color: root.barPrefs.mode === "none" ? root.accent : root.dim1
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                MouseArea {
                  id: setNoneModeArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setBarPrefMode("none")
                }
              }
            }

            Rectangle {
              width: parent.width
              height: Style.space(36)
              radius: Style.space(12)
              color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.07)
              Row {
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: Style.space(8)
                Text {
                  text: "Preview:"
                  color: root.dim1
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: "\uf0c8  " + root.barPrefPreview()
                  color: root.accent
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight
                }
              }
            }

            Flow {
              width: parent.width
              spacing: Style.space(6)
              Repeater {
                model: Model.barStatsCatalog()
                delegate: Item {
                  width: (parent.width - Style.space(6)) / 2
                  height: Style.space(30)
                  Rectangle {
                    anchors.fill: parent
                    radius: Style.space(12)
                    color: tileHover.containsMouse || root.isBarPref(modelData.id)
                        ? Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.12)
                        : "transparent"
                    border.color: root.isBarPref(modelData.id) ? root.accent : root.dim1
                    border.width: 1
                  }
                  Row {
                    anchors.fill: parent
                    anchors.margins: Style.space(6)
                    spacing: Style.space(8)
                    Text {
                      text: root.isBarPref(modelData.id) ? "\uf14a" : "\uf0c8"
                      color: root.isBarPref(modelData.id) ? root.accent : root.dim1
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                      text: modelData.glyph || ""
                      color: root.accent
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                      text: modelData.label
                      color: root.dim1
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      anchors.verticalCenter: parent.verticalCenter
                      elide: Text.ElideRight
                      width: parent.width - Style.space(60)
                    }
                  }
                  MouseArea {
                    id: tileHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleBarPref(modelData.id)
                  }
                }
              }
            }

            Row {
              spacing: Style.space(6)
              Rectangle {
                width: resetText.implicitWidth + Style.space(20)
                height: Style.space(28); radius: Style.space(12)
                border.width: 1
                border.color: root.urgent
                color: resetPrefsArea.containsMouse ? root.urgent : "transparent"
                Text {
                  id: resetText
                  anchors.centerIn: parent
                  text: "Reset to default"
                  color: resetPrefsArea.containsMouse ? root.bg : root.urgent
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                MouseArea {
                  id: resetPrefsArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.resetBarPrefs()
                }
              }
            }

            Text {
              width: parent.width
              text: "Saved to barstats.json — the bar icon updates automatically. Stats with no live value are hidden."
              color: root.dim2
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }
      }

      Item {
        Layout.fillWidth: true
        Layout.preferredHeight: 1
        Rectangle { anchors.fill: parent; color: root.surfaceBorder; opacity: 0.35 }
      }

      // ==================== Bottom nav
      Item {
        Layout.fillWidth: true
        Layout.preferredHeight: root.compact ? 0 : Style.space(84)
        Rectangle {
          anchors.fill: parent
          color: "transparent"
        }
        Row {
          anchors.fill: parent
          NavTab { width: parent.width / 5; height: parent.height; iconText: "\uf201"; label: "Activity"; active: root.activeTab === 0; onChosen: root.activeTab = 0 }
          NavTab { width: parent.width / 5; height: parent.height; iconText: "\uf00a"; label: "Apps"; active: root.activeTab === 1; onChosen: root.activeTab = 1 }
          NavTab { width: parent.width / 5; height: parent.height; iconText: "\uf0f3"; label: "Alerts"; badge: root.alertBadge > 0 ? root.alertBadge : -1; active: root.activeTab === 2; onChosen: root.activeTab = 2 }
          NavTab { width: parent.width / 5; height: parent.height; iconText: "\uf017"; label: "Events"; badge: root.eventBadge > 0 ? root.eventBadge : -1; active: root.activeTab === 3; onChosen: root.activeTab = 3 }
          NavTab { width: parent.width / 5; height: parent.height; iconText: "\uf013"; label: "Settings"; active: root.activeTab === 4; onChosen: root.activeTab = 4 }
        }
      }
    }
  }

  // ==================== App Details side panel + Disable confirm (overlays on the card)
  DetailsPanel {
    id: detailsPanel
    visible: root.detailApp != null
    app: root.detailApp
    stats: root.detailStats
    statsBusy: root.detailStatsBusy
    netInfo: root.detailNet
    netBusy: root.detailNetBusy
    z: 60
    anchors.top: card.top
    anchors.topMargin: (root.compact ? Style.space(48) : Style.space(64)) + Style.space(16)
    anchors.bottom: card.bottom
    anchors.bottomMargin: root.compact ? 0 : Style.space(84)
    anchors.left: card.left
    anchors.leftMargin: Style.space(16)
    width: Style.space(430)
    onClose: root.detailApp = null
    onKill: function(name) { root.appAction("kill", name); root.detailApp = null }
    onDisable: function(name) { root.confirmedDisable(name) }
    onEnable: function(name) { root.enableApp(name) }
  }

  ConfirmBar {
    id: confirmBar
    z: 61
    anchors.left: card.left
    anchors.leftMargin: Style.space(16)
    anchors.right: card.right
    anchors.rightMargin: Style.space(16)
    anchors.bottom: card.bottom
    anchors.bottomMargin: root.compact ? Style.space(8) : Style.space(84)
    onYes: function(name) {
      root.appAction("disable", name)
      root.detailApp = null
    }
    onNo: {}
  }

  // Shared rounded-pill: used by the Activity MET selectors (label + optional
  // live value), the Apps filter row, the Alerts config chips and (via
  // RangePill) the history range selector — one shape everywhere.
  component OMCPill: Rectangle {
    id: pill
    property bool active: false
    property string label: ""
    property string value: ""
    signal chosen()
    radius: height / 2
    height: pill.value === "" ? Style.space(28) : Style.space(44)
    width: pill.value === ""
        ? Math.max(pillLabel.implicitWidth + Style.space(20), Style.space(40))
        : Math.max(Style.space(104), Math.min(Style.space(170), pillValue.implicitWidth + Style.space(24)))
    color: pill.active ? root.accent : root.accentSoft
    Text {
      id: pillLabel
      visible: pill.value === ""
      anchors.centerIn: parent
      text: pill.label
      color: pill.active ? "#FFFFFF" : root.dim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
    Column {
      visible: pill.value !== ""
      anchors.centerIn: parent
      spacing: -2
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: pill.label
        color: pill.active ? "#FFFFFF" : root.dim2
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        id: pillValue
        anchors.horizontalCenter: parent.horizontalCenter
        text: pill.value
        color: pill.active ? "#FFFFFF" : root.fg
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.heading
        font.bold: true
        elide: Text.ElideRight
        width: pill.width - Style.space(16)
        horizontalAlignment: Text.AlignHCenter
      }
    }
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: pill.chosen()
    }
  }

  component RangePill: OMCPill {
    id: rp
    property int seconds: 3600
    label: rp.seconds >= 86400 ? "1D" : (rp.seconds >= 21600 ? "6H" : "1H")
  }

  component NavTab: Rectangle {
    id: nt
    property string iconText: ""
    property string label: ""
    property int badge: -1
    property bool active: false
    signal chosen()
    color: "transparent"

    Item {
      id: ntBody
      anchors.centerIn: parent
      width: Math.max(ntIcon.implicitWidth, ntLabel.implicitWidth)
      height: ntIcon.height + Style.space(2) + ntLabel.height

      // Filled pill behind the icon + label for the active tab.
      Rectangle {
        visible: nt.active
        anchors.centerIn: parent
        width: ntBody.width + Style.space(16)
        height: Style.space(32)
        radius: height / 2
        color: root.accentSoft
      }

      Text {
        id: ntIcon
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        text: nt.iconText
        color: nt.active ? root.accent : root.dim1
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.body
      }

      Rectangle {
        visible: nt.badge >= 0
        width: Style.space(15)
        height: Style.space(15)
        radius: Style.space(8)
        color: root.urgent
        anchors.left: ntIcon.right
        anchors.leftMargin: Style.space(2)
        anchors.top: ntIcon.top
        anchors.topMargin: -Style.space(2)
        Text {
          anchors.centerIn: parent
          text: nt.badge
          color: root.bg
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        id: ntLabel
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: ntIcon.bottom
        anchors.topMargin: Style.space(2)
        text: nt.label
        color: nt.active ? root.accent : root.dim2
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: nt.chosen()
    }
  }

  component ActionChip: Item {
    id: chip
    property string label: ""
    property bool danger: false
    signal chosen()
    width: Style.space(16) + chipText.implicitWidth
    height: Style.space(22)
    Rectangle {
      anchors.fill: parent
      radius: Style.space(12)
      color: chip.danger ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.14)
                         : Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.12)
      border.width: 1
      border.color: chip.danger ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.4)
                                : Qt.rgba(root.dim1.r, root.dim1.g, root.dim1.b, 0.25)
    }
    Text {
      id: chipText
      anchors.centerIn: parent
      text: chip.label
      color: chip.danger ? root.urgent : root.dim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.chosen()
    }
  }

  component AppRow: Item {
    id: ar
    property var app: ({})
    property bool actionsOpen: false
    property bool showPublisher: false
    signal kill(string name)
    signal enable(string name)
    signal disable(string name)
    signal details(var app)
    readonly property bool hot: (app.cpu || 0) >= 80
    readonly property var appName: ar.app.name || "unknown"
    readonly property bool unsigned: !ar.app.verified
    readonly property int rowH: Style.space(32)
    implicitHeight: rowH + (ar.actionsOpen ? Style.space(30) : 0)
    width: parent ? parent.width : 0

    Rectangle {
      id: arBase
      width: parent.width
      height: ar.rowH
      radius: Style.space(12)
      color: ar.hot ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.08)
                    : (ar.app.disabled ? Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.03)
                                       : Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.05))
      border.width: 1
      border.color: ar.app.disabled ? Qt.rgba(root.dim1.r, root.dim1.g, root.dim1.b, 0.18)
                   : (ar.actionsOpen ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35)
                                     : Qt.rgba(root.dim1.r, root.dim1.g, root.dim1.b, 0.12))

      Rectangle {
        id: arRunDot
        anchors.left: parent.left
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(8)
        height: Style.space(8)
        radius: Style.space(4)
        color: ar.app.running === false ? root.dim2
             : (ar.hot ? root.urgent : Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.8))
      }

      Text {
        id: arName
        anchors.left: arRunDot.right
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(240)
        elide: Text.ElideRight
        text: (ar.hot ? "\uf071  " : "") + ar.appName
        color: ar.hot ? root.urgent : root.fg
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Text {
        id: arPublisher
        visible: ar.showPublisher && (ar.app.publisher || "Unknown") !== "Unknown"
        anchors.left: arName.right
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(170)
        elide: Text.ElideRight
        text: ar.app.publisher || "Unknown"
        color: root.dim1
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Row {
        id: arTags
        anchors.left: arPublisher.visible ? arPublisher.right : arName.right
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)
        Rectangle {
          visible: ar.app.disabled
          width: Style.space(48)
          height: Style.space(16)
          radius: Style.space(8)
          color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.14)
          Text {
            anchors.centerIn: parent
            text: "\uf05e  Disabled"
            color: root.dim1
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
        Rectangle {
          visible: ar.unsigned
          width: Style.space(60)
          height: Style.space(16)
          radius: Style.space(8)
          color: Qt.rgba(0.9, 0.6, 0.15, 0.18)
          border.width: 1
          border.color: Qt.rgba(0.9, 0.6, 0.15, 0.5)
          Text {
            anchors.centerIn: parent
            text: "\uf071  Unsigned"
            color: "#e0a030"
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
        Repeater {
          model: ar.app.perms || []
          delegate: Rectangle {
            width: (modelData === "camera" ? Style.space(44) : (modelData === "mic" ? Style.space(34) : Style.space(58)))
            height: Style.space(16)
            radius: Style.space(8)
            color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.10)
            border.width: 1
            border.color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.4)
            Text {
              anchors.centerIn: parent
              text: modelData === "camera" ? "\uf030  Cam" : (modelData === "mic" ? "\uf130  Mic" : ("\uf124 " + modelData))
              color: root.urgent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      Rectangle {
        id: arPidBadge
        anchors.right: arSpark.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(30)
        height: Style.space(16)
        radius: Style.space(8)
        color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.12)
        Text {
          anchors.centerIn: parent
          text: (ar.app.pids || []).length
          color: root.dim1
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }
      Sparkline {
        id: arSpark
        anchors.right: arMem.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(52)
        height: Style.space(14)
        data: ar.app.spark || []
      }
      Text {
        id: arMem
        anchors.right: arCpu.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: Math.round(ar.app.mem || 0) + "%"
        color: root.dim1
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }
      Rectangle {
        id: arCpu
        anchors.right: arMenuAnc.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(60)
        height: Style.space(16)
        radius: Style.space(8)
        color: ar.hot ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.14)
                      : Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.10)
        Text {
          anchors.centerIn: parent
          text: Math.round(ar.app.cpu || 0) + "%"
          color: ar.hot ? root.urgent : root.fg
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
      Rectangle {
        id: arMenuAnc
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(24)
        height: Style.space(22)
        radius: Style.space(12)
        color: ar.actionsOpen ? root.accentSoft : "transparent"
        Text {
          anchors.centerIn: parent
          text: ar.actionsOpen ? "\uf078" : "\uf054"
          color: root.dim1
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: ar.actionsOpen = !ar.actionsOpen
        }
      }
      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: ar.actionsOpen = !ar.actionsOpen
      }
    }

    Row {
      visible: ar.actionsOpen
      anchors.top: arBase.bottom
      anchors.topMargin: Style.space(4)
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      height: Style.space(22)
      spacing: Style.space(6)
      ActionChip { visible: ar.app.pids && ar.app.pids.length > 0; label: "Terminate"; danger: true; onChosen: ar.kill(ar.appName) }
      ActionChip { label: ar.app.disabled ? "Enable" : "Disable";
        onChosen: ar.app.disabled ? ar.enable(ar.appName) : ar.disable(ar.appName) }
      ActionChip { visible: ar.app.pids && ar.app.pids.length > 0; label: "Suspend"; onChosen: root.appAction("stop", ar.appName) }
      ActionChip { visible: ar.app.pids && ar.app.pids.length > 0; label: "Resume"; onChosen: root.appAction("cont", ar.appName) }
      ActionChip { visible: ar.app.pids && ar.app.pids.length > 0; label: "Slow down"; onChosen: root.appAction("slow", ar.appName) }
      ActionChip { visible: ar.app.pids && ar.app.pids.length > 0; label: "Speed up"; onChosen: root.appAction("fast", ar.appName) }
      ActionChip { label: "Details"; onChosen: ar.details(ar.app) }
    }
  }

  component AlertRow: Item {
    id: alr
    property var alert: ({})
    signal dismissed()
    implicitHeight: Style.space(30)
    width: parent ? parent.width : 0
    readonly property color dot: alr.alert.severity === "critical" ? root.urgent
                : (alr.alert.severity === "warning" ? root.accent : root.dim1)

    Rectangle {
      anchors.fill: parent
      radius: Style.space(12)
      color: alr.dot === root.urgent
          ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.07)
          : Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.05)
    }
    Rectangle {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(8)
      height: Style.space(8)
      radius: Style.space(4)
      color: alr.dot
    }
    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(28)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(44)
      text: { var k = alr.alert.kind || ""; k === "proc" ? "PROC" : k.toUpperCase() }
      color: root.dim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(80)
      anchors.right: dismissBtn.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: alr.alert.msg || ""
      color: root.fg
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
    Text {
      anchors.right: dismissBtn.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: root.fmtAgo(alr.alert.ts || 0)
      color: root.dim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
    Rectangle {
      id: dismissBtn
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(22)
      height: Style.space(22)
      radius: Style.space(12)
      color: "transparent"
      Text {
        anchors.centerIn: parent
        text: "\uf00d"
        color: root.dim1
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }
      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: alr.dismissed()
      }
    }
  }

  component EventRow: Item {
    id: evr
    property var event: ({})
    signal markRead(int id)
    signal kill(string name)
    signal disable(string name)
    signal enable(string name)
    signal details(string name)
    readonly property bool unread: !(event.read)
    readonly property bool actionsOpen: evr.actionOpen
    readonly property bool hasApp: (event.app || "") !== ""
    readonly property string kindLabel: {
      var k = event.kind || ""
      if (k === "app_launch" || k === "new_app") return "Launch"
      if (k === "app_exit") return "Exit"
      if (k === "cpu_spike" || k === "mem_spike") return "Spike"
      if (k === "mic_access") return "Mic"
      if (k === "cam_access") return "Cam"
      if (k === "location_access") return "Loc"
      if (k === "publisher_block" || k === "unsigned_launch" || k === "unknown_app") return "Security"
      if (k.indexOf("user_") === 0) return "Action"
      return (k || "Event").toUpperCase()
    }
    readonly property string icon: {
      var k = event.kind || ""
      if (k === "app_launch" || k === "new_app") return "\uf00a"
      if (k === "app_exit") return "\uf2d8"
      if (k === "cpu_spike" || k === "mem_spike") return "\uf496"
      if (k === "mic_access" || k === "cam_access" || k === "location_access") return "\uf124"
      if (k === "publisher_block" || k === "unsigned_launch" || k === "unknown_app") return "\uf132"
      if (k.indexOf("user_") === 0) return "\uf013"
      return "\uf0c3"
    }
    property bool actionOpen: false
    implicitHeight: (evr.actionOpen ? Style.space(52) : Style.space(30))
    width: parent ? parent.width : 0

    Rectangle {
      anchors.fill: parent
      radius: Style.space(12)
      color: evr.unread ? root.accentSoft : Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.05)
    }
    Rectangle {
      visible: evr.unread
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(7)
      height: Style.space(7)
      radius: Style.space(4)
      color: root.accent
    }
    Text {
      anchors.left: parent.left
      anchors.leftMargin: evr.unread ? Style.space(24) : Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(20)
      text: evr.icon
      color: evr.unread ? root.accent : root.dim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
    Rectangle {
      anchors.left: parent.left
      anchors.leftMargin: evr.unread ? Style.space(52) : Style.space(40)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(56)
      height: Style.space(15)
      radius: Style.space(8)
      color: Qt.rgba(root.dim1.r, root.dim1.g, root.dim1.b, 0.14)
      Text {
        anchors.centerIn: parent
        text: evr.kindLabel
        color: root.dim1
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
    Text {
      anchors.left: parent.left
      anchors.leftMargin: evr.unread ? Style.space(116) : Style.space(104)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(150)
      anchors.verticalCenter: parent.verticalCenter
      text: (hasApp ? (event.app + " — ") : "") + (event.msg || "")
      color: root.fg
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: evr.unread
      elide: Text.ElideRight
    }
    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      text: root.fmtAgo(event.ts || 0)
      color: root.dim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
    Row {
      visible: evr.actionOpen
      anchors.top: parent.top
      anchors.topMargin: Style.space(28)
      anchors.left: parent.left
      anchors.leftMargin: Style.space(104)
      spacing: Style.space(6)
      height: Style.space(20)
      ActionChip {
        visible: evr.unread
        label: "Mark read"
        onChosen: evr.markRead(evr.event.id)
      }
      ActionChip {
        visible: evr.hasApp
        label: "Kill"
        danger: true
        onChosen: evr.kill(evr.event.app)
      }
      ActionChip {
        visible: evr.hasApp && evr.event.kind !== "user_disable"
        label: "Disable"
        onChosen: evr.disable(evr.event.app)
      }
      ActionChip {
        visible: evr.hasApp && evr.event.kind === "user_disable"
        label: "Enable"
        onChosen: evr.enable(evr.event.app)
      }
      ActionChip {
        visible: evr.hasApp
        label: "Details"
        onChosen: evr.details(evr.event.app)
      }
    }
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: evr.actionOpen = !evr.actionOpen
    }
  }

  component PublisherGroup: Item {
    id: pg
    property var group: ({})
    signal bulkKill(var names)
    signal bulkDisable(var names)
    signal details(var app)
    signal kill(string name)
    signal disable(string name)
    signal enable(string name)
    property bool actionsOpen: false
    implicitHeight: (pg.actionsOpen ? Style.space(54) : Style.space(30))
                     + (pg.group.apps || []).length * Style.space(36)
    width: parent ? parent.width : 0
    clip: true

    Rectangle {
      anchors.fill: parent
      radius: Style.space(12)
      color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.04)
      border.width: 1
      border.color: Qt.rgba(root.dim1.r, root.dim1.g, root.dim1.b, 0.10)
    }

    Rectangle {
      id: pgHeader
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: Style.space(30)
      radius: Style.space(12)
      color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.10)

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: pg.actionsOpen = !pg.actionsOpen
      }
      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: "\uf022  " + (pg.group.publisher || "Unknown")
        color: root.fg
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(220)
        anchors.verticalCenter: parent.verticalCenter
        text: (pg.group.noteCount || 0) + " apps · " + (pg.group.runningCount || 0) + " running"
            + ((pg.group.disabledCount || 0) ? " · " + pg.group.disabledCount + " disabled" : "")
        color: root.dim1
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }
      Rectangle {
        anchors.right: parent.right
        anchors.rightMargin: Style.space(160)
        anchors.verticalCenter: parent.verticalCenter
        width: pg.actionsOpen ? Style.space(0) : Style.space(24)
        height: Style.space(16)
        radius: Style.space(8)
        color: pg.actionsOpen ? "transparent" : root.accentSoft
        Text {
          anchors.centerIn: parent
          text: "\uf054"
          color: root.dim1
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }
      Row {
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        visible: pg.actionsOpen
        spacing: Style.space(6)
        ActionChip {
          label: "Kill all running"
          danger: true
          onChosen: {
            var names = []
            var a = pg.group.apps || []
            for (var i = 0; i < a.length; i++) if (a[i].running) names.push(a[i].name)
            pg.bulkKill(names)
          }
        }
        ActionChip {
          label: "Disable all"
          onChosen: {
            var names = []
            var b = pg.group.apps || []
            for (var j = 0; j < b.length; j++) if (!b[j].disabled) names.push(b[j].name)
            pg.bulkDisable(names)
          }
        }
        ActionChip { label: "Close menu"; onChosen: pg.actionsOpen = false }
      }
    }

    Column {
      anchors.top: pgHeader.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.topMargin: Style.space(4)
      spacing: Style.space(4)
      Repeater {
        model: pg.group.apps || []
        delegate: AppRow {
          width: pg.width
          app: modelData
          showPublisher: false
          onDetails: pg.details(modelData)
          onKill: pg.kill(modelData.name)
          onDisable: pg.disable(modelData.name)
          onEnable: pg.enable(modelData.name)
        }
      }
    }
  }

  component DetailsPanel: Item {
    id: dp
    property var app: null
    property var stats: null
    property bool statsBusy: false
    property var netInfo: null
    property bool netBusy: false
    signal close()
    signal kill(string name)
    signal disable(string name)
    signal enable(string name)
    width: parent ? parent.width : 0
    implicitHeight: Style.space(300)

    function binaryPath() {
      if (!dp.app) return ""
      var parts = []
      if (dp.app.exe) parts.push("exe: " + dp.app.exe)
      if (dp.app.pkg) parts.push("pkg: " + dp.app.pkg)
      return parts.join("   ·   ")
    }
    function statEntries() {
      if (!dp.stats) return []
      var s = dp.stats
      function r(x) { return Math.round(x * 10) / 10 }
      return [
        { k: "PEAK CPU", v: r(s.max_cpu) + " %" },
        { k: "AVG CPU", v: r(s.avg_cpu) + " %" },
        { k: "PEAK MEM", v: r(s.max_mem_mb) + " MB" },
        { k: "AVG MEM", v: r(s.avg_mem_mb) + " MB" },
        { k: "PEAK GPU", v: r(s.max_gpu) + " %" },
        { k: "PEAK I/O", v: r(s.max_io_kbs) + " KB/s" }
      ]
    }
    function stampLine() {
      if (!dp.stats) return dp.statsBusy ? "Scanning tracked history…" : ""
      function d(ts) { return new Date(ts * 1000).toLocaleDateString() }
      return "Since first tracked: " + dp.stats.samples + " samples · " + d(dp.stats.first_ts) + " → " + d(dp.stats.last_ts)
    }
    function cpuNote() {
      if (!dp.stats) return ""
      var m = Math.max(dp.stats.max_cpu, dp.stats.avg_cpu)
      if (m <= 100) return ""
      return "CPU is % of one core — " + Math.round(m) + "% ≈ " + Math.round(m / 10) / 10 + " cores of parallel work"
    }
    function netLine() {
      if (dp.netInfo) {
        var parts = []
        if (dp.netInfo.established) parts.push(dp.netInfo.established + " tcp connections")
        if (dp.netInfo.listening) parts.push(dp.netInfo.listening + " listening")
        if (dp.netInfo.udp) parts.push(dp.netInfo.udp + " udp")
        return parts.length ? "Network: " + parts.join(" · ") : "Network: no open sockets"
      }
      return dp.netBusy ? "Scanning network sockets…" : ""
    }
    function statLegend() {
      if (!dp.stats) return []
      var s = dp.stats
      function r(x) { return Math.round(x * 10) / 10 }
      var arr = []
      arr.push({ h: "PEAK CPU", d: "% of one core, summed across threads" +
        (s.max_cpu > 100 ? " — " + s.max_cpu + "% ≈ " + r(s.max_cpu / 100) + " cores" : "") })
      arr.push({ h: "AVG CPU", d: "mean of the above across all tracked samples" })
      arr.push({ h: "PEAK MEM", d: "largest resident RAM footprint in MB" })
      arr.push({ h: "AVG MEM", d: "mean resident RAM footprint in MB" })
      arr.push({ h: "PEAK GPU", d: "GPU utilization %, sampled while it was the top GPU process" })
      arr.push({ h: "PEAK I/O", d: "highest disk throughput (read + write) in KB/s" })
      arr.push({ h: "NET", d: "live TCP/UDP socket count for this app right now" })
      return arr
    }

    Rectangle {
      anchors.fill: parent
      radius: Style.space(12)
      color: root.surface
      border.width: 1
      border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.45)
    }

    Row {
      anchors.top: parent.top
      anchors.topMargin: Style.space(10)
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(16)
      spacing: Style.space(8)
      Text {
        text: (dp.app && dp.app.name) || ""
        color: root.fg
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
        width: Math.min(parent.width * 0.42, Style.space(180))
      }
      Rectangle {
        visible: dp.app && !dp.app.verified
        width: Style.space(62); height: Style.space(16); radius: Style.space(8)
        color: Qt.rgba(0.9, 0.6, 0.15, 0.15)
        border.width: 1
        border.color: Qt.rgba(0.9, 0.6, 0.15, 0.45)
        Text { anchors.centerIn: parent; text: "Unsigned"; color: "#e0a030"; font.family: root.contentFontFamily; font.pixelSize: Style.font.caption }
      }
      Rectangle {
        visible: dp.app && dp.app.verified
        width: Style.space(70); height: Style.space(16); radius: Style.space(8)
        color: Qt.rgba(0.2, 0.7, 0.3, 0.15)
        border.width: 1
        border.color: Qt.rgba(0.2, 0.7, 0.3, 0.45)
        Text { anchors.centerIn: parent; text: "Verified"; color: "#3cb371"; font.family: root.contentFontFamily; font.pixelSize: Style.font.caption }
      }
      Rectangle {
        visible: !!(dp.app && dp.app.perms && dp.app.perms.length > 0)
        width: Math.min(Style.space(110), Style.space(14) + dpPermText.implicitWidth)
        height: Style.space(16); radius: Style.space(8)
        color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.10)
        border.width: 1
        border.color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.4)
        Text {
          id: dpPermText
          anchors.centerIn: parent
          text: "perm: " + ((dp.app && dp.app.perms ? dp.app.perms : []).join(", "))
          color: root.urgent
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    Text {
      anchors.top: parent.top
      anchors.topMargin: Style.space(38)
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(12)
      text: "Publisher: " + (dp.app && dp.app.publisher || "Unknown")
          + "   ·   " + (dp.app && dp.app.source || "unknown")
          + "   ·   disabled: " + (dp.app && dp.app.disabled ? "yes" : "no")
          + "   ·   instances: " + (dp.app ? (dp.app.instances !== undefined ? dp.app.instances : (dp.app.pids ? dp.app.pids.length : 0)) : 0)
      color: root.dim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
    Text {
      id: dpDesc
      anchors.top: parent.top
      anchors.topMargin: Style.space(58)
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(12)
      text: (dp.app && dp.app.desc) || "No description available for this binary."
      color: root.dim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      maximumLineCount: 2
      elide: Text.ElideRight
    }
    Column {
      id: dpInfo
      anchors.top: dpDesc.bottom
      anchors.topMargin: Style.space(10)
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(12)
      spacing: Style.space(8)

      Text {
        width: parent.width
        visible: dp.binaryPath() !== ""
        text: dp.binaryPath()
        color: root.dim2
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Flow {
        id: dpStatsFlow
        width: parent.width
        spacing: Style.space(6)
        Repeater {
          model: dp.statEntries()
          delegate: Rectangle {
            width: (dpStatsFlow.width - Style.space(6)) / 2
            height: Style.space(32)
            radius: Style.space(12)
            color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.10)
            border.width: 1
            border.color: Qt.rgba(root.dim1.r, root.dim1.g, root.dim1.b, 0.15)
            Text {
              anchors.top: parent.top
              anchors.topMargin: Style.space(4)
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              text: modelData.k
              color: root.dim2
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
            Text {
              anchors.top: parent.top
              anchors.topMargin: Style.space(15)
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              text: modelData.v
              color: root.fg
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              elide: Text.ElideRight
            }
          }
        }
      }

      Text {
        width: parent.width
        visible: dp.stampLine() !== ""
        text: dp.stampLine()
        color: root.dim2
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: dp.netLine() !== ""
        text: dp.netLine()
        color: root.dim1
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: "How to read the values"
        color: root.dim1
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
      Repeater {
        model: dp.statLegend()
        delegate: Row {
          width: parent.width
          spacing: Style.space(6)
          Text {
            width: Style.space(82)
            text: modelData.h
            color: root.dim1
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Text {
            width: parent.width - Style.space(88)
            text: modelData.d
            color: root.dim2
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
    Row {
      anchors.top: dpInfo.bottom
      anchors.topMargin: Style.space(16)
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      spacing: Style.space(6)
      ActionChip {
        visible: !!(dp.app && dp.app.pids && dp.app.pids.length > 0)
        label: "Terminate"
        danger: true
        onChosen: { dp.kill(dp.app.name); dp.close() }
      }
      ActionChip {
        label: (dp.app && dp.app.disabled) ? "Enable" : "Disable"
        onChosen: {
          if (dp.app && dp.app.disabled) dp.enable(dp.app.name)
          else dp.disable(dp.app.name)
        }
      }
      ActionChip { label: "Close"; onChosen: dp.close() }
    }
  }

  component ConfirmBar: Item {
    id: cb
    property var pending: []
    signal yes(string name)
    signal no()
    width: parent ? parent.width : 0
    implicitHeight: Style.space(0)
    visible: false

    function show(name) {
      cb.pending = [name]
      cb.visible = true
      cb.implicitHeight = Style.space(40)
    }

    Rectangle {
      anchors.fill: parent
      radius: Style.space(12)
      color: Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 0.97)
      border.width: 1
      border.color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.55)
    }
    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: "Disable '" + ((cb.pending && cb.pending[0]) || "") + "'? It will be killed now and blocked every time it starts. Use Enable later to undo."
      color: root.fg
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
    Row {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)
      ActionChip {
        label: "Yes, disable"
        danger: true
        onChosen: {
          var nm = (cb.pending && cb.pending[0]) || ""
          cb.visible = false; cb.implicitHeight = Style.space(0)
          cb.yes(nm)
        }
      }
      ActionChip {
        label: "Cancel"
        onChosen: { cb.visible = false; cb.implicitHeight = Style.space(0); cb.no() }
      }
    }
  }

  component ColHeader: Item {
    id: ch
    property string leftLabel: "PROCESS"
    property string midLabel: "TRUST"
    property string rightLabel: "TREND     MEM     CPU"
    height: Style.space(16)
    width: parent ? parent.width : 0

    Rectangle {
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: 1
      color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.25)
    }
    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: ch.leftLabel
      color: root.dim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    Text {
      visible: ch.midLabel !== ""
      anchors.left: parent.left
      anchors.leftMargin: Style.space(306)
      anchors.verticalCenter: parent.verticalCenter
      text: ch.midLabel
      color: root.dim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: ch.rightLabel
      color: root.dim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  component ProcRow: Item {
    id: pr
    property string name: ""
    property real cpu: 0
    property real mem: 0
    property real io: 0
    property real gpu: 0
    property string publisher: "Unknown"
    property bool verified: false
    property var perms: []
    property int instances: 1
    property bool disabled: false
    property var sparks: []
    property bool critical: cpu > 80
    signal details()
    signal kill(string name)
    signal disable(string name)
    signal enable(string name)
    implicitHeight: Style.space(26)
    width: parent ? parent.width : 0

    Rectangle {
      anchors.fill: parent
      radius: Style.space(12)
      color: pr.critical
          ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.10)
          : Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.05)
      border.width: pr.disabled ? 1 : 0
      border.color: Qt.rgba(root.dim1.r, root.dim1.g, root.dim1.b, 0.15)
    }
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: pr.details()
    }
    Text {
      id: prName
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(160)
      elide: Text.ElideRight
      text: pr.critical ? "\uf071  " + pr.name : pr.name
      color: pr.critical ? root.urgent : root.fg
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: pr.critical
    }
    Text {
      anchors.left: prName.right
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(120)
      elide: Text.ElideRight
      text: pr.publisher
      color: root.dim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
    Row {
      anchors.left: prName.right
      anchors.leftMargin: Style.space(136)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)
      Rectangle {
        visible: pr.disabled
        width: Style.space(50)
        height: Style.space(14)
        radius: Style.space(7)
        color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.14)
        Text {
          anchors.centerIn: parent
          text: "\uf05e Disabled"
          color: root.dim1
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }
      Rectangle {
        visible: !pr.verified
        width: Style.space(62)
        height: Style.space(14)
        radius: Style.space(7)
        color: Qt.rgba(0.9, 0.6, 0.15, 0.15)
        border.width: 1
        border.color: Qt.rgba(0.9, 0.6, 0.15, 0.45)
        Text {
          anchors.centerIn: parent
          text: "Unsigned"
          color: "#e0a030"
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }
      Repeater {
        model: pr.perms
        delegate: Rectangle {
          width: modelData === "camera" ? Style.space(40) : (modelData === "mic" ? Style.space(30) : Style.space(52))
          height: Style.space(14)
          radius: Style.space(7)
          color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.10)
          border.width: 1
          border.color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.4)
          Text {
            anchors.centerIn: parent
            text: modelData === "camera" ? "Cam" : (modelData === "mic" ? "Mic" : modelData)
            color: root.urgent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
      Rectangle {
        visible: pr.instances > 1
        width: Style.space(20)
        height: Style.space(14)
        radius: Style.space(7)
        color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.10)
        Text {
          anchors.centerIn: parent
          text: "×" + pr.instances
          color: root.dim1
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
    Sparkline {
      anchors.right: prMemBar.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(46)
      height: Style.space(14)
      data: pr.sparks
    }
    Text {
      anchors.right: prMemBar.left
      anchors.rightMargin: Style.space(62)
      anchors.verticalCenter: parent.verticalCenter
      text: Math.round(pr.mem) + "%"
      color: root.dim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
    Rectangle {
      id: prMemBar
      anchors.right: prCpu.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(34)
      height: Style.space(6)
      radius: Style.space(3)
      color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.18)
      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: parent.width * Math.min(1, pr.mem / 100)
        radius: Style.space(3)
        color: root.accent
      }
    }
    Rectangle {
      id: prCpu
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(64)
      height: Style.space(16)
      radius: Style.space(8)
      color: pr.critical ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.14)
                         : Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.10)
      Text {
        anchors.centerIn: parent
        text: Math.round(pr.cpu) + "%"
        color: pr.critical ? root.urgent : root.fg
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
  }

  component Sparkline: Canvas {
    id: spk
    property var data: []
    onDataChanged: requestPaint()
    onWidthChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var w = width, h = height
      var maxV = 1
      for (var i = 0; i < data.length; i++) if (data[i] > maxV) maxV = data[i]
      ctx.beginPath()
      for (var j = 0; j < data.length; j++) {
        var x = j * w / Math.max(1, data.length - 1)
        var v = data[j] < 0 ? 0 : data[j] / maxV
        var y = h - v * (h - 2) - 1
        if (j === 0) ctx.moveTo(x, y)
        else ctx.lineTo(x, y)
      }
      ctx.strokeStyle = Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.8)
      ctx.lineWidth = 1
      ctx.stroke()
    }
  }

  // ---- History graph with time-domain zoom/pan/scrub + hover + drill.
  component HistoryGraph: Canvas {
    id: hg
    property var pts: []
    property var events: []
    property color lineColor: root.accent
    property color dangerColor: root.urgent
    property real dangerThreshold: -1
    property int maxValue: 100
    property string unit: "%"
    property int windowSecs: 3600
    signal drilled(var ts)

    property real viewStart: -1
    property real viewEnd: -1
    readonly property bool zoomed: viewStart >= 0 && viewEnd > viewStart
    readonly property real minZoomSpan: 15

    onWindowSecsChanged: resetView()
    onPtsChanged: requestPaint()
    onEventsChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    function resetView() { viewStart = -1; viewEnd = -1; requestPaint() }

    function evColor(kind) {
      if (kind === "app_launch" || kind === "new_app") return "#3cb371"
      if (kind === "app_exit") return Qt.rgba(root.dim1.r, root.dim1.g, root.dim1.b, 0.85)
      if (kind.indexOf("spike") >= 0) return hg.dangerColor
      if (kind === "publisher_block" || kind === "unsigned_launch" || kind === "unknown_app"
          || kind === "mic_access" || kind === "cam_access" || kind === "location_access") return hg.dangerColor
      if (kind.indexOf("user_") === 0) return hg.lineColor
      return Qt.rgba(hg.lineColor.r, hg.lineColor.g, hg.lineColor.b, 0.7)
    }

    function dataStart() { return hg.pts.length ? hg.pts[0].ts : 0 }
    function dataEnd() { return hg.pts.length ? hg.pts[hg.pts.length - 1].ts : 0 }
    function fullEnd() { return hg.dataEnd() }
    function fullStart() {
      var de = hg.fullEnd()
      if (de <= 0) return Math.floor(Date.now() / 1000) - hg.windowSecs
      var fs = de - hg.windowSecs
      var ds = hg.dataStart()
      return ds > fs ? ds : fs
    }
    function domainStart() { return hg.zoomed ? hg.viewStart : hg.fullStart() }
    function domainEnd() { return hg.zoomed ? hg.viewEnd : hg.fullEnd() }

    function timeAtX(x) {
      var s = hg.domainStart(), e = hg.domainEnd()
      return s + (e - s) * x / Math.max(1, hg.width - 1)
    }

    function panBy(seconds) {
      var span = hg.viewEnd - hg.viewStart
      var fs = hg.fullStart(), fe = hg.fullEnd()
      var ns = hg.viewStart + seconds
      if (ns < fs) ns = fs
      if (ns > fe - span) ns = fe - span
      if (ns < fs) ns = fs
      hg.viewStart = ns
      hg.viewEnd = ns + span
      hg.requestPaint()
    }

    function zoomTo(t1, t2) {
      if (t2 < t1) { var t = t1; t1 = t2; t2 = t }
      var span = t2 - t1
      if (span < hg.minZoomSpan) {
        var c = (t1 + t2) / 2
        t1 = c - hg.minZoomSpan / 2
        t2 = c + hg.minZoomSpan / 2
        span = hg.minZoomSpan
      }
      var fs = hg.fullStart(), fe = hg.fullEnd()
      if (t1 < fs) { t1 = fs; t2 = t1 + span }
      if (t2 > fe) { t2 = fe; t1 = t2 - span }
      if (t1 < fs) t1 = fs
      hg.viewStart = t1
      hg.viewEnd = Math.max(t1 + 1, t2)
      hg.requestPaint()
    }

    function wheelZoom(x, up) {
      var fs = hg.fullStart(), fe = hg.fullEnd()
      var fullSpan = fe - fs
      if (fullSpan <= 0) return
      var span = hg.domainEnd() - hg.domainStart()
      var f = up ? 0.75 : 1.3333
      var ns = Math.max(hg.minZoomSpan, Math.min(Math.max(fullSpan, hg.minZoomSpan), span * f))
      var t = hg.timeAtX(x)
      var frac = span > 0 ? (t - hg.domainStart()) / span : 0.5
      var nStart = t - frac * ns
      if (nStart < fs) nStart = fs
      if (nStart > fe - ns) nStart = fe - ns
      if (nStart < fs) nStart = fs
      hg.viewStart = nStart
      hg.viewEnd = nStart + ns
      hg.requestPaint()
    }

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var w = width, h = height
      var topPad = 4, bottomPad = 18, leftPad = 8, rightPad = 8
      var plotW = Math.max(10, w - leftPad - rightPad)
      var plotH = Math.max(10, h - bottomPad - topPad)
      var yMax = hg.maxValue > 0 ? hg.maxValue : 10
      if (hg.maxValue < 0) {
        var mx = 0
        for (var i = 0; i < hg.pts.length; i++) if (hg.pts[i].v > mx) mx = hg.pts[i].v
        yMax = Math.max(10, mx * 1.15)
      }

      ctx.strokeStyle = Qt.rgba(root.dim1.r, root.dim1.g, root.dim1.b, 0.18)
      ctx.lineWidth = 1
      var steps = 4
      for (var gi = 0; gi <= steps; gi++) {
        var gv = yMax * gi / steps
        var gy = topPad + plotH - gv / yMax * plotH
        ctx.beginPath()
        ctx.moveTo(leftPad, gy + 0.5)
        ctx.lineTo(w - rightPad, gy + 0.5)
        ctx.stroke()
        ctx.fillStyle = root.dim2
        ctx.font = "9px " + root.contentFontFamily
        ctx.textAlign = "left"
        ctx.fillText("" + Math.round(gv), 2, gy - 2)
      }

      ctx.fillStyle = root.dim2
      ctx.textAlign = "center"
      var sT = hg.domainStart(), eT = hg.domainEnd()
      var xTicks = 4
      for (var xi = 0; xi <= xTicks; xi++) {
        var t = sT + (eT - sT) * xi / xTicks
        var tx = leftPad + plotW * xi / xTicks
        var label = hg.windowSecs >= 86400
            ? Qt.formatDateTime(new Date(t * 1000), "dd/MM HH:mm")
            : Qt.formatTime(new Date(t * 1000), "HH:mm")
        ctx.fillText(label, tx, h - 4)
      }

      if (hg.pts.length < 2) return
      var spanT = Math.max(1, hg.domainEnd() - hg.domainStart())

      // Clean single-pixel-width line (no area fill, no halo) in accent color.
      ctx.beginPath()
      var started = false
      for (var li = 0; li < hg.pts.length; li++) {
        var lp = hg.pts[li]
        var lX = leftPad + (lp.ts - hg.domainStart()) / spanT * plotW
        var lY = topPad + plotH - Math.max(0, Math.min(yMax, lp.v)) / yMax * plotH
        if (!started) { ctx.moveTo(lX, lY); started = true }
        else ctx.lineTo(lX, lY)
      }
      ctx.strokeStyle = hg.lineColor
      ctx.lineWidth = 2
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      ctx.stroke()

      // Spike highlight: any span whose values cross the danger threshold is
      // re-stroked in the danger color (segments, not a second series).
      if (hg.dangerThreshold > 0) {
        ctx.strokeStyle = hg.dangerColor
        ctx.lineWidth = 2
        var hot = false
        for (var di = 0; di < hg.pts.length; di++) {
          var dpt = hg.pts[di]
          var dX = leftPad + (dpt.ts - hg.domainStart()) / spanT * plotW
          var dY = topPad + plotH - Math.max(0, Math.min(yMax, dpt.v)) / yMax * plotH
          if (dpt.v >= hg.dangerThreshold) {
            if (!hot) { ctx.beginPath(); ctx.moveTo(dX, dY); hot = true }
            else ctx.lineTo(dX, dY)
          } else if (hot) {
            ctx.stroke()
            hot = false
          }
        }
        if (hot) ctx.stroke()
      }

      // Event markers: small filled circles hovering just above the line,
      // colored by event kind (green for launches).
      if (hg.events && hg.events.length) {
        var eST = hg.domainStart(), eET = hg.domainEnd()
        for (var mi = 0; mi < hg.events.length; mi++) {
          var ev = hg.events[mi]
          if (ev.ts < eST || ev.ts > eET) continue
          var mX = leftPad + (ev.ts - eST) / spanT * plotW
          var vAt = -1
          for (var bi = 0; bi < hg.pts.length; bi++) {
            if (hg.pts[bi].ts <= ev.ts) vAt = hg.pts[bi].v
            else {
              if (bi > 0 && hg.pts[bi].ts !== hg.pts[bi - 1].ts) {
                var f = (ev.ts - hg.pts[bi - 1].ts) / (hg.pts[bi].ts - hg.pts[bi - 1].ts)
                vAt = hg.pts[bi - 1].v + f * (hg.pts[bi].v - hg.pts[bi - 1].v)
              } else vAt = hg.pts[bi].v
              break
            }
          }
          if (vAt < 0) continue
          var mY = topPad + plotH - Math.max(0, Math.min(yMax, vAt)) / yMax * plotH
          var cY = Math.max(topPad + 2, mY - 7)
          ctx.beginPath()
          ctx.arc(mX, cY, 3.3, 0, Math.PI * 2)
          ctx.fillStyle = hg.evColor(ev.kind || ev.type || "")
          ctx.fill()
        }
      }

      if (dragStart >= 0 && !hg.zoomed) {
        var bX = Math.min(dragStart, dragCur)
        var bW = Math.abs(dragCur - dragStart)
        ctx.fillStyle = Qt.rgba(hg.lineColor.r, hg.lineColor.g, hg.lineColor.b, 0.12)
        ctx.fillRect(bX, topPad, bW, plotH)
        ctx.strokeStyle = Qt.rgba(hg.lineColor.r, hg.lineColor.g, hg.lineColor.b, 0.6)
        ctx.strokeRect(bX + 0.5, topPad + 0.5, bW - 1, plotH - 1)
      }

      if (hg.zoomed) {
        var pillText = root.fmtTime(hg.viewStart) + " – " + root.fmtTime(hg.viewEnd) + "   ↺ reset"
        ctx.font = "9px " + root.contentFontFamily
        var tw = ctx.measureText(pillText).width
        ctx.fillStyle = Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 0.92)
        ctx.fillRect(leftPad, 4, tw + 14, 16)
        ctx.strokeStyle = Qt.rgba(hg.lineColor.r, hg.lineColor.g, hg.lineColor.b, 0.4)
        ctx.strokeRect(leftPad + 0.5, 4.5, tw + 13, 15)
        ctx.fillStyle = hg.lineColor
        ctx.textAlign = "left"
        ctx.fillText(pillText, leftPad + 7, 16.4)
      }
    }

    property real dragStart: -1
    property real dragCur: -1
    property bool dragMoved: false
    property real hoverPointerX: -1

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.CrossCursor

      onEntered: {
        hg.hoverPointerX = 0
        hg.requestPaint()
      }
      onExited: {
        hg.hoverPointerX = -1
        hg.requestPaint()
        tip.hide()
      }
      onPositionChanged: function(mouse) {
        if (hg.dragStart >= 0) {
          if (hg.zoomed) {
            var movedT = hg.timeAtX(mouse.x)
            var startT = hg.timeAtX(hg.dragStart)
            hg.panBy(movedT - startT)
            hg.dragStart = mouse.x
          } else {
            hg.dragCur = mouse.x
            hg.requestPaint()
          }
        } else {
          hg.hoverPointerX = mouse.x
          hg.requestPaint()
          tip.showAt(hg.timeAtX(mouse.x), mouse.x, mouse.y)
        }
      }
      onPressed: function(mouse) {
        hg.dragStart = mouse.x
        hg.dragCur = mouse.x
        hg.dragMoved = false
      }
      onReleased: function(mouse) {
        if (hg.dragStart < 0) return
        var startX = hg.dragStart
        hg.dragStart = -1
        hg.dragCur = -1
        if (hg.dragMoved) {
          if (!hg.zoomed) hg.zoomTo(hg.timeAtX(startX), hg.timeAtX(mouse.x))
          hg.dragMoved = false
          hg.requestPaint()
        } else {
          if (hg.dataEnd() > 0) hg.drilled(hg.timeAtX(mouse.x))
        }
      }
      onDoubleClicked: hg.resetView()
      onWheel: function(wheel) {
        hg.wheelZoom(wheel.x, wheel.angleDelta.y > 0)
      }
    }

    // Hover tooltip (hard-coded dark card, native-app feel regardless of theme).
    Rectangle {
      id: tip
      z: 50
      visible: false
      width: Style.space(220)
      implicitHeight: tipCol.implicitHeight + Style.space(16)
      radius: Style.space(12)
      color: "#1e1b2e"
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, 0.14)
      Column {
        id: tipCol
        anchors.fill: parent
        anchors.margins: Style.space(8)
        spacing: Style.space(2)
        Row {
          spacing: Style.space(8)
          Text {
            id: tipTime
            color: "#ffffff"
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Text {
            id: tipValue
            color: Qt.rgba(1, 1, 1, 0.8)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
        Text {
          id: tipTop
          width: tip.width - Style.space(16)
          color: Qt.rgba(1, 1, 1, 0.7)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
        Text {
          id: tipMore
          text: "  click for all processes"
          color: hg.lineColor
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
      function showAt(ts, x, y) {
        var near = null
        for (var i = 0; i < hg.pts.length; i++) {
          if (hg.pts[i].ts >= ts) { near = hg.pts[i]; break }
        }
        if (!near && hg.pts.length) near = hg.pts[hg.pts.length - 1]
        if (!near) return
        tipTime.text = root.fmtTime(near.ts)
        tipValue.text = Math.round(near.v) + hg.unit
        var top = []
        var sel = root.nearestSnap(near.ts)
        if (sel && sel.procs) {
          var arr = sel.procs.slice()
          arr.sort(function(a, b) { return b.cpu - a.cpu })
          top = [arr[0], arr[1], arr[2]]
        }
        tipTop.text = ""
        for (var k = 0; k < top.length && top[k]; k++) {
          tipTop.text += (k > 0 ? " · " : "") + top[k].name + " " + Math.round(top[k].cpu) + "%"
        }
        tip.visible = true
        tip.parent = hg
        tip.width = Style.space(220)
        var px = x - tip.width / 2
        if (px < 4) px = 4
        if (px > hg.width - tip.width - 4) px = hg.width - tip.width - 4
        tip.x = px
        tip.y = y - tip.height - 22
        if (tip.y < 4) tip.y = y + 12
      }
      function hide() { tip.visible = false }
    }
  }

  // ---- Mini overview: full-history sparkline with a draggable selection band.
  component MiniOverview: Item {
    id: mo
    property var pts: []
    property var graph: null

    Canvas {
      id: moCan
      anchors.fill: parent
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var w = width, h = height
        ctx.fillStyle = Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.06)
        ctx.fillRect(0, 0, w, h)
        if (!mo.pts.length) return
        var mx = 0
        for (var i = 0; i < mo.pts.length; i++) if (mo.pts[i].v > mx) mx = mo.pts[i].v
        if (mx <= 0) return
        ctx.beginPath()
        for (var j = 0; j < mo.pts.length; j++) {
          var x = j * w / Math.max(1, mo.pts.length - 1)
          var y = h - 2 - mo.pts[j].v / mx * (h - 4)
          if (j === 0) ctx.moveTo(x, y)
          else ctx.lineTo(x, y)
        }
        ctx.strokeStyle = Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.45)
        ctx.lineWidth = 1
        ctx.stroke()

        var g = mo.graph
        if (!g) return
        var fs = g.fullStart(), fe = g.fullEnd()
        var span = Math.max(1, fe - fs)
        var s = g.zoomed ? g.viewStart : fs
        var e = g.zoomed ? g.viewEnd : fe
        var bx = (s - fs) / span * w
        var bw = (e - s) / span * w
        ctx.fillStyle = Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12)
        ctx.fillRect(bx, 0, bw, h)
        ctx.fillStyle = Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.85)
        ctx.fillRect(bx, 0, 2, h)
        ctx.fillRect(bx + bw - 2, 0, 2, h)
        ctx.fillRect(bx, h - 3, bw, 3)
      }
    }
    MouseArea {
      id: moMouse
      anchors.fill: parent
      property int grip: 0
      onPressed: function(mouse) {
        var g = mo.graph
        if (!g) return
        var fs = g.fullStart(), fe = g.fullEnd()
        var span = Math.max(1, fe - fs)
        var w = width
        var s = g.zoomed ? g.viewStart : fs
        var e = g.zoomed ? g.viewEnd : fe
        var bx = (s - fs) / span * w
        var bw = (e - s) / span * w
        grip = mouse.x < bx + 8 ? -1 : (mouse.x > bx + bw - 8 ? 1 : 0)
      }
      onPositionChanged: function(mouse) {
        var g = mo.graph
        if (!g || g.dataEnd() <= 0) return
        var fs = g.fullStart(), fe = g.fullEnd()
        var span = Math.max(1, fe - fs)
        var w = width
        var t = fs + span * mouse.x / w
        var s = g.zoomed ? g.viewStart : fs
        var e = g.zoomed ? g.viewEnd : fe
        var d = e - s
        if (grip === -1) {
          g.viewStart = Math.min(t, e - Math.max(10, d))
        } else if (grip === 1) {
          g.viewEnd = Math.max(t, s + Math.max(10, d))
        } else {
          g.viewStart = Math.max(fs, Math.min(fe - d, t - d / 2))
          g.viewEnd = g.viewStart + d
        }
        g.requestPaint()
      }
      onReleased: { grip = 0 }
    }
    Connections {
      target: mo.graph
      function onViewStartChanged() { moCan.requestPaint() }
      function onViewEndChanged() { moCan.requestPaint() }
    }
  }
}
