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
  WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

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
  property var sample: ({ cpu: 0, mem: 0, gpu: 0, procs: 0, disk: 0, disk_r: 0, disk_w: 0,
                          net_rx_kbs: 0, net_tx_kbs: 0,
                          history_1h: [], history_6h: [], history_1d: [],
                          p_list: [], snaps: [], apps: [], catalog: [],
                          alerts: [], events: [], alert_prefs: {},
                          disabled: [], perms: {} })
  property string selMetric: "cpu"
  property int chartWindow: 3600

  // Omarchy-style rotating tagline under the title; a new quip every 5s.
  readonly property var subtitles: [
    "Your machine, live",
    "Keeping an eye on your CPU since forever",
    "Every process has a story — here it is",
    "Spikes, apps, and the occasional villain",
    "Sampled every 2 seconds. Yes, really.",
    "Your RAM called. It wants peace.",
    "Somebody downloaded something…",
    "The GPU snores. The charts do not.",
    "Events: where apps get caught red-handed",
    "Kill, disable, repeat.",
    "The charts never lie. Mostly.",
    "Logged on since PID 1"
  ]
  property int subtitleIdx: 0
  readonly property string subtitleText: root.subtitles[root.subtitleIdx % root.subtitles.length]
  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: root.subtitleIdx++
  }

  // Net and Disk series are KB/s (bytes), matching the pill/popup/tooltip.
  readonly property var chartPtsRaw: root.seriesFor(root.selMetric, root.chartWindow)
  readonly property real chartScale: 1
  readonly property string chartUnit: root.metricUnits[root.selMetric] || ""
  readonly property var chartPts: root.chartPtsRaw

  property int activeTab: 0
  property string search: ""
  property var drillProcs: null
  property real drillTs: 0
  property var rangeSummary: null
  property var filteredProcs: []
  property bool sampleProcRunning: false
  property var filteredApps: []
  property string appSearch: ""
  property string activityFilter: "all"
  property string procSort: "cpu"
  property string appSort: "cpu"
  property bool showDisabledOnly: false
  property var dismissedAlerts: []
  property string alertFilter: "all"
  property string eventFilter: "all"
  property string eventSearch: ""
  property var filteredEvents: []
  property int alertsSeenTs: 0
  property int eventSeenTs: 0
  property int alertBadge: 0
  property int eventBadge: 0
  property var alertPrefs: ({ enabled: true, types: {}, charts: {} })
  property var detailApp: null
  property var eventDetail: null
  property var detailStats: null
  property bool detailStatsBusy: false
  property var detailNet: null
  property bool detailNetBusy: false
  property var procDetail: []
  property bool procDetailBusy: false
  property var eventCtx: null
  property bool eventCtxBusy: false

  property var barPrefs: ({ stats: ["cpu", "cputemp"], mode: "name" })
  property bool barPrefsLoaded: false
  readonly property string dataDir: Quickshell.env("HOME") + "/.local/share/omcontrol"
  readonly property string barStatsPath: dataDir + "/barstats.json"

  // Hardened spawner: helpers run under a fixed absolute interpreter through
  // the stdio-cap wrapper with a GNU timeout (own process group → group
  // SIGTERM then SIGKILL grace) and an explicit minimal environment, so no
  // inherited PATH/LD_* variable can influence or shadow the tooling.
  readonly property string runnerPath: Qt.resolvedUrl("backend/run-capped.sh").toString().replace("file://", "")
  readonly property int maxOutputBytes: 1048576
  readonly property var trustedEnv: ({
    "PATH": "/usr/bin:/bin",
    "HOME": Quickshell.env("HOME"),
    "OMCONTROL_DATA_DIR": root.dataDir,
    "LC_ALL": "C"
  })
  function capText(text) {
    return typeof text === "string" && text.length > root.maxOutputBytes
      ? text.slice(0, root.maxOutputBytes) : (text || "")
  }

  readonly property var metricUnits: ({ cpu: "%", mem: "%", gpu: "%", procs: "", disk: "KB/s", net: "KB/s" })
  readonly property var sortOptions: [
    { v: "cpu", label: "CPU" },
    { v: "gpu", label: "GPU" },
    { v: "mem", label: "Memory" },
    { v: "disk", label: "Disk I/O" },
    { v: "net", label: "Net" }
  ]
  readonly property var filteredAlerts: root.computeAlerts()
  readonly property int activeAlertCount: root.filteredAlerts.length

  // History-graph markers: per-kind visibility from the Alerts tab, plus the
  // master toggle as an override. Notifications stay mode-property only.
  readonly property var chartEvents: root.computeChartEvents()

  function computeChartEvents() {
    var alertsOn = root.alertPrefs.enabled !== false
    var ev = root.sample.events || []
    var out = []
    for (var i = 0; i < ev.length; i++) {
      if (!alertsOn) continue
      if (!root.chartShown(root.sensitivityForKind(ev[i].kind))) continue
      out.push(ev[i])
    }
    return out
  }

  // The 8 alert sensitivities for the Alerts config tab (display order).
  readonly property var alertTypes: [
    "New App Launch", "Mic or Cam Access", "Service Change", "Unsigned App Launch",
    "Location Tracking", "New Service Launch", "App Update", "New Suspicious App",
    "App Exit"
  ]

  function liveValue(key) {
    switch (key) {
      case "cpu": return Math.round(root.sample.cpu * 10) / 10
      case "mem": return root.sample.mem
      case "gpu": return root.sample.gpu
      case "procs": return root.sample.procs
      case "disk": return root.sample.disk
      case "net": return "\u2193 " + root.fmtNet(root.sample.net_rx_kbs) + "   \u2191 " + root.fmtNet(root.sample.net_tx_kbs)
      case "ctemp": return root.sample.ctemp || 0
      case "gtemp": return root.sample.gtemp || 0
    }
    return 0
  }

  function fmtNet(kbs) {
    kbs = Math.max(0, Number(kbs) || 0)
    if (kbs >= 1048576) return (kbs / 1048576).toFixed(1) + "G"
    if (kbs >= 1024) return (kbs / 1024).toFixed(1) + "M"
    if (kbs >= 1) return Math.round(kbs) + "K"
    return "0"
  }

  function fmtNetFull(kbs) {
    kbs = Math.max(0, Number(kbs) || 0)
    if (kbs >= 1048576) return (kbs / 1048576).toFixed(1) + " GB/s"
    if (kbs >= 1024) return (kbs / 1024).toFixed(1) + " MB/s"
    return Math.round(kbs) + " KB/s"
  }

  function seriesFor(metric, windowSecs) {
    var list = windowSecs <= 3600 ? root.sample.history_1h
             : windowSecs <= 21600 ? root.sample.history_6h
             : root.sample.history_1d
    var minTs = list.length ? list[list.length - 1].ts - windowSecs : 0
    var pts = []
    for (var i = 0; i < list.length; i++) {
      var h = list[i]
      if (minTs > 0 && h.ts < minTs) continue
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

  function tempSeriesFor(windowSecs) {
    var list = windowSecs <= 3600 ? root.sample.history_1h
             : windowSecs <= 21600 ? root.sample.history_6h
             : root.sample.history_1d
    var minTs = list.length ? list[list.length - 1].ts - windowSecs : 0
    var pts = []
    for (var i = 0; i < list.length; i++) {
      if (minTs > 0 && list[i].ts < minTs) continue
      pts.push({ ts: list[i].ts, ctemp: list[i].ctemp || 0, gtemp: list[i].gtemp || 0 })
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
    var map = {}
    var list = root.sample.p_list || []
    for (var i = 0; i < list.length; i++) map[(list[i].name || "").toLowerCase()] = list[i]
    var got = snap.procs.slice()
    var isNet = root.selMetric === "net"
    var isIo = root.selMetric === "disk"
    got.sort(function(a, b) {
      if (isNet) {
        var an = (a.nr || 0) + (a.nt || 0)
        var bn = (b.nr || 0) + (b.nt || 0)
        if (bn !== an) return bn - an
      }
      if (isIo) {
        var ai = (a.io_kbs || 0)
        var bi = (b.io_kbs || 0)
        if (bi !== ai) return bi - ai
      }
      return b.cpu - a.cpu
    })
    var out = []
    for (var j = 0; j < got.length && out.length < n; j++) {
      var e = got[j]
      var en = map[(e.name || "").toLowerCase()] || {}
      var copy = {}
      for (var k in e) copy[k] = e[k]
      copy.verified = en.verified === undefined ? 0 : en.verified
      copy.publisher = en.publisher || "Unknown"
      copy.perms = en.perms || []
      copy.disabled = !!en.disabled
      out.push(copy)
    }
    return out
  }

  function showRangePopup(t1, t2) {
    root.rangeSummary = root.buildRangeSummary(t1, t2)
  }

  function rangeMetricLabel(m) {
    if (m === "cpu") return "CPU"
    if (m === "mem") return "Memory"
    if (m === "gpu") return "GPU"
    if (m === "procs") return "Processes"
    if (m === "disk") return "Disk"
    if (m === "net") return "Network"
    return m
  }

  function fmtRangePeak(metric, v) {
    if (!isFinite(v) || v < 0) return "–"
    if (metric === "net" || metric === "disk") return Model.fmtRate(v)
    if (metric === "procs") return Math.round(v) + ""
    return (v >= 100 ? Math.round(v) : v.toFixed(1)) + "%"
  }

  function fmtRangeVal(metric, v) {
    if (!isFinite(v) || v < 0) return "–"
    if (metric === "net") return Model.fmtRate(v)
    if (metric === "procs") return Math.round(v) + ""
    if (metric === "disk") return Math.round(v) + " KB/s"
    return (v >= 100 ? Math.round(v) : v.toFixed(1)) + "%"
  }

  // True when a per-minute snapshot actually carries per-app data for the
  // pill metric (net/disk values are absent on older snapshots collected
  // before those fields existed; a snap full of zeroes means nothing to rank).
  function snapHasMetric(sp, metric) {
    if (metric !== "net" && metric !== "disk") return true
    var procs = sp.procs || []
    for (var j = 0; j < procs.length; j++) {
      var e = procs[j]
      if (metric === "net" && ((e.nr || 0) + (e.nt || 0)) > 0) return true
      if (metric === "disk" && (e.io_kbs || 0) > 0) return true
    }
    return false
  }

  // Aggregate everything we know about a dragged time range for the Activity
  // popup: device-level stats from the history series plus per-app averages
  // from the per-minute process snapshots, ranked by the selected pill's metric.
  function buildRangeSummary(t1, t2) {
    if (t2 < t1) { var tt = t1; t1 = t2; t2 = tt }
    var metric = root.selMetric
    var pts = root.chartPtsRaw
    var sum = 0, peak = -1, ppeak = 0, n = 0
    for (var i = 0; i < pts.length; i++) {
      var p = pts[i]
      if (p.ts < t1 || p.ts > t2) continue
      sum += p.v
      n++
      if (p.v > peak) { peak = p.v; ppeak = p.ts }
    }
    var acc = {}
    var snaps = root.sample.snaps || []
    var nsnap = 0, nsnapData = 0
    for (var s = 0; s < snaps.length; s++) {
      var sp = snaps[s]
      if (sp.ts < t1 || sp.ts > t2) continue
      nsnap++
      if (!root.snapHasMetric(sp, metric)) continue
      nsnapData++
      var procs = sp.procs || []
      for (var j = 0; j < procs.length; j++) {
        var e = procs[j]
        var name = e.name || "?"
        var rec = acc[name] || { name: name, s: 0, k: 0, srx: 0, stx: 0 }
        var val
        if (metric === "cpu") val = e.cpu || 0
        else if (metric === "mem") val = e.mem || 0
        else if (metric === "gpu") val = e.gpu || 0
        else if (metric === "disk") val = e.io_kbs || 0
        else if (metric === "net") val = (e.nr || 0) + (e.nt || 0)
        else val = e.cpu || 0
        if ((metric === "net" || metric === "disk") && val <= 0) continue
        rec.s += val
        rec.k++
        rec.srx += (e.nr || 0)
        rec.stx += (e.nt || 0)
        acc[name] = rec
      }
    }
    var list = root.sample.p_list || []
    var map = {}
    for (var m = 0; m < list.length; m++) map[(list[m].name || "").toLowerCase()] = list[m]
    var rows = []
    for (var nm in acc) {
      var r = acc[nm]
      var key = metric === "net" ? (r.srx + r.stx) / Math.max(1, r.k) : r.s / Math.max(1, r.k)
      var pi = map[(nm || "").toLowerCase()] || {}
      rows.push({ name: nm, pretty: pi.pretty_name || nm, v: key,
                  srx: r.srx / Math.max(1, r.k), stx: r.stx / Math.max(1, r.k) })
    }
    rows.sort(function(a, b) { return b.v - a.v })
    if (rows.length > 10) rows.length = 10
    return { t1: t1, t2: t2, metric: metric, mlabel: root.rangeMetricLabel(metric),
             nsnap: nsnap, nsnapData: nsnapData, devAvg: n > 0 ? sum / n : 0, devPeak: peak < 0 ? null : peak,
             peakAt: ppeak ? root.fmtTime(ppeak) : "", rows: rows }
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

  function fmtFullDate(ts) {
    return Qt.formatDateTime(new Date(ts * 1000), "yyyy-MM-dd HH:mm:ss")
  }

  function eventTypeColor(kind) { return Model.eventTypeColor(kind) }
  // Canvas2D can't alpha-blend the hex strings Model.js returns, so convert
  // "#RRGGBB" → "rgba(r,g,b,a)" for translucent strokes.
  function hexRgba(hex, alpha) {
    var h = String(hex || "#888888").replace("#", "")
    if (h.length < 6) h = "888888"
    return "rgba(" + parseInt(h.substring(0, 2), 16) + ","
        + parseInt(h.substring(2, 4), 16) + ","
        + parseInt(h.substring(4, 6), 16) + "," + alpha + ")"
  }
  function eventIcon(kind) { return Model.eventIcon(kind) }
  function eventKindLabel(kind) {
    if (kind === "app_launch" || kind === "new_app") return "Launch"
    if (kind === "app_exit") return "Exit"
    if (kind === "cpu_spike" || kind === "mem_spike") return "Spike"
    if (kind === "mic_access") return "Mic access"
    if (kind === "cam_access") return "Camera access"
    if (kind === "location_access") return "Location access"
    if (kind === "permission") return "Permission"
    if (kind === "publisher_block" || kind === "unsigned_launch" || kind === "unknown_app") return "Security"
    if (kind === "suspicious_app") return "Suspicious app"
    if (kind === "service_change") return "Service change"
    if (kind === "service_launch") return "Service launch"
    if (kind === "app_update") return "App update"
    if (kind.indexOf("user_") === 0) return "Action"
    return (kind || "Event").toUpperCase()
  }

  function eventKindExplain(kind) {
    switch (kind) {
      case "app_launch":
      case "new_app": return "An application was launched. First-seen launches are recorded so you can spot something that started running without you realising."
      case "app_exit": return "A previously-running application exited (left the process list)."
      case "cpu_spike": return "System CPU load across all cores peaked above 95% during a 0.2s sample window."
      case "mem_spike": return "System memory usage exceeded 92% — only a small amount of RAM was free at that moment."
      case "mic_access": return "An application accessed the microphone."
      case "cam_access": return "An application accessed the camera."
      case "location_access": return "An application accessed location data."
      case "permission": return "An application was granted access to a sensitive permission."
      case "publisher_block": return "An executable without a known, verifiable publisher was launched and blocked by your policy."
      case "unsigned_launch": return "A binary that does not come from a verified, signed package was started — it was not in the trusted catalog."
      case "unknown_app": return "A process with no registered package or publisher started. It is not in the app catalog at all, so nothing can be verified about its origin."
      case "suspicious_app": return "This binary matched suspicion heuristics (unusual path, name, or origin) and was flagged."
      case "service_change": return "A system service was started or stopped."
      case "service_launch": return "A system service was launched."
      case "app_update": return "An installed application was updated."
      default:
        if (kind.indexOf("user_") === 0) return "A manual action (allow, disable or enable) taken from the OmaControl UI."
        return (kind || "System event") + " was logged by the system monitor."
    }
  }

  // Merge the running apps with the known-apps catalog into one inventory,
  // apply the search + activity + disabled filters, and sort.
  function renderApps() {
    var q = root.appSearch.trim().toLowerCase()
    var byName = {}
    var src = root.sample.apps || []
    var cat = root.sample.catalog || []
    var i, a
    for (i = 0; i < src.length; i++) {
      var srcNm = (src[i].name || "").toLowerCase()
      byName[srcNm] = src[i]
      byName[srcNm].running = true
    }
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
      return (root.sortVal(b, root.appSort) || 0) - (root.sortVal(a, root.appSort) || 0)
    })
    root.filteredApps = out.slice(0, 400)
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
    var alertsOn = root.alertPrefs.enabled !== false
    var alerts = root.sample.alerts || []
    var crit = 0
    for (var i = 0; i < alerts.length; i++) {
      if (alerts[i].severity === "critical") crit++
    }
    root.alertBadge = alertsOn ? crit : 0
    var ev = root.sample.events || []
    var unread = 0
    for (var j = 0; j < ev.length; j++) {
      if (!alertsOn || ev[j].read) continue
      var sens = root.sensitivityForKind(ev[j].kind)
      if (sens && root.alertMode(sens) === "none") continue
      unread++
    }
    root.eventBadge = unread
  }

  function appAction(action, name) {
    appActionProc.command = ["/usr/bin/timeout", "-k", "2", "8", "/bin/sh", root.runnerPath, "/bin/sh",
      Qt.resolvedUrl("backend/app-action.sh").toString().replace("file://", ""),
      action, name]
    appActionProc.running = true
  }

  function loadStats(nm) {
    if (!nm) { root.detailStats = null; return }
    root.detailStatsBusy = true
    statsProc.command = ["/usr/bin/timeout", "-k", "2", "8", "/bin/sh", root.runnerPath, "/bin/sh",
      Qt.resolvedUrl("backend/app-stats.sh").toString().replace("file://", ""), nm]
    statsProc.running = true
  }

  function loadEventContext(ev) {
    root.eventCtx = null
    root.eventCtxBusy = true
    var args = ["/usr/bin/timeout", "-k", "2", "8", "/bin/sh", root.runnerPath, "/bin/sh",
                Qt.resolvedUrl("backend/event-context.sh").toString().replace("file://", ""),
                "" + (ev && ev.ts ? ev.ts : 0), (ev && ev.app) || "", (ev && ev.kind) || ""]
    eventCtxProc.command = args
    eventCtxProc.running = true
  }

  function isBarPref(id) { return (root.barPrefs.stats || []).indexOf(id) >= 0 }
  function barPrefPreview() {
    var list = root.barPrefs.stats || []
    if (root.barPrefs.mode === "none") return "(values only, no names)"
    var out = []
    for (var i = 0; i < list.length; i++) {
      var lead = Model.barStatLabel(list[i])
      if (lead) out.push(lead)
    }
    return out.length ? out.join("  ") : "(no stats selected)"
  }
  function toggleBarPref(id) {
    var list = (root.barPrefs.stats || []).slice()
    var i = list.indexOf(id)
    if (i >= 0) list.splice(i, 1); else list.push(id)
    root.barPrefs = { stats: list, mode: root.barPrefs.mode || "name", barShowBell: root.barPrefs.barShowBell !== false, showBuyButton: root.barPrefs.showBuyButton !== false }
    root.saveBarPrefs()
  }
  function setBarPrefMode(m) {
    if (m !== "name" && m !== "none") return
    root.barPrefs = { stats: root.barPrefs.stats || [], mode: m, barShowBell: root.barPrefs.barShowBell !== false, showBuyButton: root.barPrefs.showBuyButton !== false }
    root.saveBarPrefs()
  }
  function resetBarPrefs() {
    root.barPrefs = { stats: ["cpu", "cputemp"], mode: "name", barShowBell: true, showBuyButton: true }
    root.saveBarPrefs()
  }
  function setBarShowBell(on) {
    root.barPrefs = { stats: root.barPrefs.stats || [], mode: root.barPrefs.mode || "name", barShowBell: !!on, showBuyButton: root.barPrefs.showBuyButton !== false }
    root.saveBarPrefs()
    root.runBackend("bar-prefs.sh", ["set-show-bell", on ? "on" : "off"])
  }
  function setShowBuyButton(on) {
    root.barPrefs = { stats: root.barPrefs.stats || [], mode: root.barPrefs.mode || "name", barShowBell: root.barPrefs.barShowBell !== false, showBuyButton: !!on }
    root.saveBarPrefs()
  }
  function openBuyMeACoffee() {
    Qt.openUrlExternally("https://ko-fi.com/davedes")
  }
  function saveBarPrefs() {
    var json = JSON.stringify({ stats: root.barPrefs.stats || [], mode: root.barPrefs.mode || "name", barShowBell: root.barPrefs.barShowBell !== false, showBuyButton: root.barPrefs.showBuyButton !== false })
    var safe = json.replace(/'/g, "'\\''")
    barPrefsSaveProc.command = ["/usr/bin/timeout", "-k", "2", "5", "/bin/sh", root.runnerPath, "/bin/sh", "-c",
      "mkdir -p '" + root.dataDir + "' && printf '%s' '" + safe + "' > '" + root.barStatsPath + "'"]
    barPrefsSaveProc.running = false
    barPrefsSaveProc.running = true
  }
  function loadBarPrefs() {
    barPrefsLoadProc.command = ["/usr/bin/timeout", "-k", "2", "5", "/bin/sh", root.runnerPath, "/bin/sh", "-c",
      "cat '" + root.barStatsPath + "' 2>/dev/null || echo '{}'"]
    barPrefsLoadProc.running = true
  }

  function loadNet(nm) {
    if (!nm) { root.detailNet = null; return }
    root.detailNetBusy = true
    netProc.command = ["/usr/bin/timeout", "-k", "2", "8", "/bin/sh", root.runnerPath, "/bin/sh",
      Qt.resolvedUrl("backend/app-net.sh").toString().replace("file://", ""), nm]
    netProc.running = true
  }

  function loadProcDetail(nm) {
    if (!nm) {
      root.procDetail = []
      return
    }
    root.procDetailBusy = true
    procDetailProc.command = ["/usr/bin/timeout", "-k", "2", "8", "/bin/sh", root.runnerPath, "/usr/bin/python3",
      Qt.resolvedUrl("backend/process-detail.sh").toString().replace("file://", ""), nm]
    procDetailProc.running = true
  }

  function pidsFor(name) {
    var arr = root.sample.p_list || []
    var out = []
    for (var i = 0; i < arr.length; i++) {
      if (arr[i].name === name && arr[i].pid) out.push(arr[i].pid)
    }
    return out
  }

  function toggleProcRows() {
    detailsPanel.procOpen = !detailsPanel.procOpen
    if (!detailsPanel.procOpen) detailsPanel.procShowAll = false
    return detailsPanel.procOpen
  }

  function procRowsInfo() {
    return JSON.stringify({ open: detailsPanel.procOpen, n: (root.procDetail || []).length })
  }

  function fmtDur(s) {
    s = Math.max(0, Math.floor(s || 0))
    var d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60)
    if (d > 0) return d + "d " + h + "h"
    if (h > 0) return h + "h " + m + "m"
    if (m > 0) return m + "m " + (s % 60) + "s"
    return s + "s"
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
    out.sort(function(a, b) { return root.sortVal(b, root.procSort) - root.sortVal(a, root.procSort) })
    root.filteredProcs = out
  }

  // Live per-process resource value used by the sort dropdowns.
  function sortVal(p, key) {
    switch (key) {
      case "gpu":  return p.gpu || 0
      case "mem":  return p.mem || 0
      case "disk": return p.io_kbs || p.io || 0
      case "net":  return p.net_kbs || p.net || 0
      case "cpu":
      default:     return p.cpu || 0
    }
  }

  function onSampleReceived() {
    root.alertPrefs = root.sample.alert_prefs || { enabled: true, types: {}, charts: {} }
    root.renderList()
    root.renderApps()
    root.updateBadges()
    root.computeEvents()
  }

  // ---- persistence helpers (events read state + alert prefs) ----
  function runBackend(script, args) {
    var full = ["/usr/bin/timeout", "-k", "2", "8", "/bin/sh", root.runnerPath, "/bin/sh",
                Qt.resolvedUrl("backend/" + script).toString().replace("file://", "")].concat(args)
    actionProc.command = full
    actionProc.running = true
  }
  function markEventRead(id) { root.runBackend("events.sh", ["read", "" + id]) ; missingNsTimer() }
  function markAllEventsRead() { root.runBackend("events.sh", ["read-all"]); missingNsTimer() }
  function clearEvents() { root.runBackend("events.sh", ["clear"]); missingNsTimer() }
  function setAlertPref(type, mode) { root.runBackend("alert-prefs.sh", ["set", type, mode]) }
  function setAlertsEnabled(on) { root.runBackend("alert-prefs.sh", ["set-enabled", on ? "on" : "off"]) }
  function setAlertMode(type, mode) {
    var types = {}; var src = root.alertPrefs.types || {}
    for (var k in src) types[k] = src[k]
    types[type] = mode
    root.alertPrefs = ({ "enabled": root.alertPrefs.enabled, "types": types, "charts": root.alertPrefs.charts || {} })
    root.setAlertPref(type, mode)
    root.refreshSoon()
  }

  function setChartToggle(type, on) {
    var charts = {}; var src = root.alertPrefs.charts || {}
    for (var k in src) charts[k] = src[k]
    charts[type] = on
    root.alertPrefs = ({ "enabled": root.alertPrefs.enabled, "types": root.alertPrefs.types || {}, "charts": charts })
    root.runBackend("alert-prefs.sh", ["set-chart", type, on ? "on" : "off"])
    root.refreshSoon()
  }

  // Whether chart markers for an event kind are shown (defaults to shown).
  function chartShown(type) {
    if (!type) return true
    return (root.alertPrefs.charts || {})[type] !== false
  }

  // Normalized per-sensitivity notification mode: "toast" | "notify" | "none".
  // Handles legacy boolean prefs (true meant notify, but toast for new apps).
  function alertMode(type) {
    var v = (root.alertPrefs.types || {})[type]
    if (v === true) return type === "New App Launch" ? "toast" : "notify"
    if (v === false) return "none"
    if (v === "toast" || v === "notify" || v === "none") return v
    return "none"
  }

  // Event kind → alert sensitivity label (bell-badge gating).
  // Every kind the toast funnel knows is mapped so a "none" mode can silence
  // the bell for it; kinds without a mapping always count when alerts are on.
  function sensitivityForKind(kind) {
    var map = {
      "app_launch": "New App Launch",
      "app_exit": "App Exit",
      "mic_access": "Mic or Cam Access", "cam_access": "Mic or Cam Access", "permission": "Mic or Cam Access",
      "location_access": "Location Tracking",
      "unsigned_launch": "Unsigned App Launch", "unknown_app": "Unsigned App Launch", "publisher_block": "Unsigned App Launch",
      "suspicious_app": "New Suspicious App",
      "service_change": "Service Change",
      "service_launch": "New Service Launch",
      "app_update": "App Update"
    }
    return map[kind] || null
  }
  function refreshSoon() { refreshTimer.start() }

  onSampleChanged: root.onSampleReceived()
  onSearchChanged: root.renderList()
  onAppSearchChanged: root.renderApps()
  onActivityFilterChanged: root.renderApps()
  onShowDisabledOnlyChanged: root.renderApps()
  onProcSortChanged: root.renderList()
  onAppSortChanged: root.renderApps()
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
    clearEnvironment: true
    environment: root.trustedEnv
    command: ["/usr/bin/timeout", "-k", "2", "10", "/bin/sh", root.runnerPath, "/bin/sh",
              Qt.resolvedUrl("backend/sample-json.sh").toString().replace("file://", "")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onSample(root.capText(text))
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
    clearEnvironment: true
    environment: root.trustedEnv
  }
  Process {
    id: statsProc
    clearEnvironment: true
    environment: root.trustedEnv
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.detailStatsBusy = false
        try {
          var parsed = JSON.parse(root.capText(text))
          root.detailStats = parsed && parsed.name ? parsed : null
        } catch (e) { root.detailStats = null }
      }
    }
  }
  Process {
    id: netProc
    clearEnvironment: true
    environment: root.trustedEnv
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.detailNetBusy = false
        try {
          var parsed = JSON.parse(root.capText(text))
          root.detailNet = parsed ? parsed : null
        } catch (e) { root.detailNet = null }
      }
    }
  }
  Process {
    id: procDetailProc
    clearEnvironment: true
    environment: root.trustedEnv
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.procDetailBusy = false
        try {
          var parsed = JSON.parse(root.capText(text))
          root.procDetail = (parsed && parsed.pids) ? parsed.pids : []
        } catch (e) { root.procDetail = [] }
      }
    }
  }
  Process {
    id: eventCtxProc
    clearEnvironment: true
    environment: root.trustedEnv
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.eventCtxBusy = false
        try {
          var parsed = JSON.parse(root.capText(text))
          root.eventCtx = (parsed && parsed.ok) ? parsed : null
        } catch (e) { root.eventCtx = null }
      }
    }
  }
  Process {
    id: barPrefsLoadProc
    clearEnvironment: true
    environment: root.trustedEnv
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(root.capText(text))
          if (Array.isArray(parsed)) root.barPrefs = { stats: parsed, mode: root.barPrefs.mode || "name" }
          else if (parsed && parsed.stats) root.barPrefs = { stats: parsed.stats, mode: ["name","none"].indexOf(parsed.mode) >= 0 ? parsed.mode : "name" }
          root.barPrefs = { stats: root.barPrefs.stats || [], mode: root.barPrefs.mode || "name", barShowBell: parsed.barShowBell !== false, showBuyButton: parsed.showBuyButton !== false }
        } catch (e) {}
        root.barPrefsLoaded = true
      }
    }
  }
  Process {
    id: barPrefsSaveProc
    clearEnvironment: true
    environment: root.trustedEnv
  }
  Process {
    id: actionProc
    clearEnvironment: true
    environment: root.trustedEnv
  }
  Timer { id: refreshTimer; interval: 5000; repeat: false; running: false
    onTriggered: { if (root.open) sampleProc.running = true }
  }
  function missingNsTimer() { refreshTimer.start() }

  onDetailAppChanged: {
    root.loadStats(root.detailApp ? root.detailApp.name : "")
    root.loadNet(root.detailApp ? root.detailApp.name : "")
    root.loadProcDetail(root.detailApp ? root.detailApp.name : "")
  }
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
    width: Math.min(root.compact ? Style.space(900) : Style.space(1100), root.width - Style.space(40))
    height: Math.min(root.compact ? Style.space(170) : Style.space(740), root.height - Style.space(40))
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
              text: root.subtitleText
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
            spacing: Style.space(16)

            OMCPill { label: "CPU"; value: root.liveValue("cpu") + "%"; active: root.selMetric === "cpu"; onChosen: { root.selMetric = "cpu"; if (root.rangeSummary) root.rangeSummary = root.buildRangeSummary(root.rangeSummary.t1, root.rangeSummary.t2) } }
            OMCPill { label: "Memory"; value: root.liveValue("mem") + "%"; active: root.selMetric === "mem"; onChosen: { root.selMetric = "mem"; if (root.rangeSummary) root.rangeSummary = root.buildRangeSummary(root.rangeSummary.t1, root.rangeSummary.t2) } }
            OMCPill { label: "GPU"; value: root.liveValue("gpu") + "%"; active: root.selMetric === "gpu"; onChosen: { root.selMetric = "gpu"; if (root.rangeSummary) root.rangeSummary = root.buildRangeSummary(root.rangeSummary.t1, root.rangeSummary.t2) } }
            OMCPill { label: "Processes"; value: Math.round(root.liveValue("procs")); active: root.selMetric === "procs"; onChosen: { root.selMetric = "procs"; if (root.rangeSummary) root.rangeSummary = root.buildRangeSummary(root.rangeSummary.t1, root.rangeSummary.t2) } }
            OMCPill { label: "Disk"; value: "\u2193 " + root.fmtNet(root.sample.disk_r) + "  \u2191 " + root.fmtNet(root.sample.disk_w); active: root.selMetric === "disk"; onChosen: { root.selMetric = "disk"; if (root.rangeSummary) root.rangeSummary = root.buildRangeSummary(root.rangeSummary.t1, root.rangeSummary.t2) } }
            OMCPill { label: "Net"; value: root.liveValue("net"); active: root.selMetric === "net"; onChosen: { root.selMetric = "net"; if (root.rangeSummary) root.rangeSummary = root.buildRangeSummary(root.rangeSummary.t1, root.rangeSummary.t2) } }
          }

          Row {
            id: rangeRow
            z: 90
            visible: !root.compact
            anchors.top: parent.top
            anchors.right: parent.right
            spacing: Style.space(8)

            RangePill { seconds: 900; active: root.chartWindow === 900; onChosen: root.chartWindow = 900 }
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
            text: "drag a range to see what used it (popup, ranked by the selected pill) · wheel to zoom · drag when zoomed to pan · double-click reset · click a point for that moment's processes"
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
            pts: root.chartPts
            lineColor: root.accent
            events: root.chartEvents
            dangerColor: root.urgent
            dangerThreshold: (root.selMetric === "procs" || root.selMetric === "net" || root.selMetric === "disk") ? -1 : 90
            maxValue: (root.selMetric === "procs" || root.selMetric === "net" || root.selMetric === "disk") ? -1 : 100
            unit: root.chartUnit
            windowSecs: root.chartWindow
            onDrilled: function(ts) {
              // Clicking near an event pin opens the full event-detail popup;
              // anywhere else keeps the process drill-down.
              var evs = root.chartEvents
              var best = null, bd = 60
              for (var i = 0; i < evs.length; i++) {
                var dd = Math.abs(evs[i].ts - ts)
                if (dd < bd) { bd = dd; best = evs[i] }
              }
              if (best) { root.eventDetail = best; return }
              root.drillTs = ts
              root.drillProcs = root.topAt(ts, 20)
              if (!root.drillProcs.length) root.drillProcs = null
              if (root.compact) root.compact = false
            }
            onRangeSelected: function(t1, t2) {
              root.showRangePopup(t1, t2)
            }
          }

          TemperatureStrip {
            id: tempStrip
            visible: !root.compact
            anchors.top: graph.bottom
            anchors.topMargin: Style.space(4)
            anchors.left: parent.left
            anchors.right: parent.right
            height: Style.space(34)
            pts: root.tempSeriesFor(root.chartWindow)
            domainStart: graph.domStart
            domainEnd: graph.domEnd
          }

          MiniOverview {
            id: mini
            visible: !root.compact
            anchors.top: tempStrip.bottom
            anchors.topMargin: Style.space(6)
            anchors.left: parent.left
            anchors.right: parent.right
            height: Style.space(40)
            pts: root.chartPts
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
              z: 90
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              spacing: Style.space(8)

              Rectangle {
                width: parent.width - (root.drillProcs !== null ? Style.space(112) : 0) - Style.space(166)
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
              SortMenu {
                visible: root.drillProcs === null
                options: root.sortOptions
                value: root.procSort
                onChosen: function(v) { root.procSort = v }
              }
            }

            Text {
              id: paneTitle
              anchors.top: paneHeader.bottom
              anchors.topMargin: Style.space(4)
              anchors.left: parent.left
              anchors.right: parent.right
              text: root.drillProcs
                  ? (root.selMetric === "net"
                      ? "Network usage at " + root.fmtTime(root.drillTs) + " · ranked by transfer · click the chart elsewhere to change the moment"
                      : root.selMetric === "disk"
                        ? "Disk I/O at " + root.fmtTime(root.drillTs) + " · ranked by I/O · click the chart elsewhere to change the moment"
                        : "Processes at " + root.fmtTime(root.drillTs) + " · click the chart elsewhere to change the moment")
                  : "Running processes · click a row for details & actions · NET column = live transfer per process"
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
              midX: Style.space(168)
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
                pid: Number(modelData.pid) || 0
                cpu: modelData.cpu
                mem: modelData.mem
                io: modelData.io_kbs
                gpu: modelData.gpu
                net: (modelData.nr !== undefined || modelData.nt !== undefined)
                    ? ((Number(modelData.nr) || 0) + (Number(modelData.nt) || 0)) : -1
                verified: modelData.verified
                perms: modelData.perms
instances: Number(modelData.instances) || 1
                disabled: modelData.disabled
                sparks: root.sparksFor(modelData.name)
                onDetails: root.detailApp = ({ name: modelData.name,
                  publisher: modelData.publisher, verified: modelData.verified,
                  source: modelData.source, desc: modelData.desc || "",
                  exe: modelData.exe || "", pkg: modelData.pkg || "",
                  perms: modelData.perms || [], disabled: modelData.disabled,
                  pids: root.pidsFor(modelData.name),
                  cpu: modelData.cpu, mem: modelData.mem, instances: modelData.instances })
                onKill: root.appAction("kill", modelData.name)
                onDisable: root.disableApp(modelData.name)
                onEnable: root.enableApp(modelData.name)
              }
            }
          }

          // ---- Dragged-range popup: aggregates the highlighted area for the
          // selected pill (CPU → top CPU apps, MEM → top memory apps, Net →
          // top transfer apps, etc.). Shown when the user drags a range on the
          // history graph; rebuilt live if a pill is switched while open.
          Item {
            id: rangePopup
            visible: root.rangeSummary !== null
            anchors.fill: parent
            z: 150

            MouseArea {
              anchors.fill: parent
              hoverEnabled: false
              onClicked: root.rangeSummary = null
            }

            Shortcut {
              sequence: "Escape"
              onActivated: root.rangeSummary = null
            }

            Rectangle {
              anchors.centerIn: parent
              width: Math.min(parent.width - Style.space(48), Style.space(360))
              implicitHeight: rpCol.implicitHeight + Style.space(20)
              radius: Style.space(14)
              color: root.surface
              border.width: 1
              border.color: root.surfaceBorder

              Column {
                id: rpCol
                anchors.fill: parent
                anchors.margins: Style.space(12)
                spacing: Style.space(6)

                Row {
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    width: parent.width - Style.space(24)
                    text: (root.rangeSummary ? root.rangeSummary.mlabel : "") + " in dragged range"
                    color: root.fg
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    text: "\uf2d3"
                    color: root.dim1
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.rangeSummary = null
                    }
                  }
                }

                Text {
                  width: parent.width
                  text: root.rangeSummary
                      ? root.fmtTime(root.rangeSummary.t1) + " – " + root.fmtTime(root.rangeSummary.t2)
                        + "   ·   " + root.rangeSummary.nsnap + " minute sample" + (root.rangeSummary.nsnap === 1 ? "" : "s")
                      : ""
                  color: root.dim1
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  width: parent.width
                  visible: root.rangeSummary
                           && (root.rangeSummary.metric === "net" || root.rangeSummary.metric === "disk")
                           && root.rangeSummary.nsnapData < root.rangeSummary.nsnap
                  text: root.rangeSummary
                      ? "· per-app " + (root.rangeSummary.metric === "net" ? "network" : "disk I/O")
                        + " in " + root.rangeSummary.nsnapData + " of " + root.rangeSummary.nsnap + " minute sample"
                        + (root.rangeSummary.nsnap === 1 ? "" : "s")
                      : ""
                  color: root.dim1
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  width: parent.width
                  visible: root.rangeSummary && root.rangeSummary.devPeak !== null
                  text: root.rangeSummary
                      ? ("Device peak " + root.fmtRangePeak(root.rangeSummary.metric, root.rangeSummary.devPeak)
                         + (root.rangeSummary.peakAt ? " @ " + root.rangeSummary.peakAt + " · avg " + root.fmtRangeVal(root.rangeSummary.metric, root.rangeSummary.devAvg) : ""))
                      : ""
                  color: root.dim2
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                Rectangle {
                  width: parent.width
                  height: 1
                  color: root.surfaceBorder
                  visible: root.rangeSummary && root.rangeSummary.rows.length > 0
                }

                Repeater {
                  model: root.rangeSummary ? root.rangeSummary.rows : []
                  delegate: Row {
                    width: rpCol.width
                    spacing: Style.space(8)

                    Rectangle {
                      width: Style.space(7)
                      height: Style.space(7)
                      anchors.verticalCenter: parent.verticalCenter
                      radius: Style.space(2)
                      color: root.accent
                      opacity: 0.6 + 0.4 * (1 - index / Math.max(1, root.rangeSummary.rows.length))
                    }

                    Text {
                      width: parent.width - Style.space(120)
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.pretty
                      color: root.fg
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }

                    Text {
                      width: Style.space(104)
                      anchors.verticalCenter: parent.verticalCenter
                      horizontalAlignment: Text.AlignRight
                      text: root.rangeSummary
                          ? (root.rangeSummary.metric === "net"
                              ? Model.fmtRateShort(modelData.srx) + "↓ " + Model.fmtRateShort(modelData.stx) + "↑"
                              : root.fmtRangeVal(root.rangeSummary.metric, modelData.v))
                          : ""
                      color: root.dim1
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  visible: root.rangeSummary && root.rangeSummary.rows.length === 0
                  text: root.rangeSummary
                      ? (root.rangeSummary.nsnap === 0
                          ? "No per-minute process samples cover this range (samples keep ~90 minutes). Zoomed/app-level listing starts applying as new minutes land."
                          : root.rangeSummary.nsnapData === 0 && (root.rangeSummary.metric === "net" || root.rangeSummary.metric === "disk")
                              ? "No per-app " + (root.rangeSummary.metric === "net" ? "network" : "disk I/O")
                                + " data in these minutes yet (per-app collection only started recently)."
                              : "No per-process data for this range.")
                      : ""
                  color: root.dim2
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  width: parent.width
                  text: "Esc or click outside to close · switch a pill to re-ranked · drag again for a new range"
                  color: root.dim2
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
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
            z: 90
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Style.space(8)

            Rectangle {
              width: parent.width - Style.space(516)
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

            SortMenu {
              options: root.sortOptions
              value: root.appSort
              onChosen: function(v) { root.appSort = v }
            }

            OMCPill { label: "Running"; active: root.activityFilter === "running"; onChosen: root.activityFilter = "running" }
            OMCPill { label: "Not running"; active: root.activityFilter === "not"; onChosen: root.activityFilter = "not" }
            OMCPill { label: "All"; active: root.activityFilter === "all"; onChosen: root.activityFilter = "all" }
            OMCPill { label: "Disabled"; active: root.showDisabledOnly; onChosen: root.showDisabledOnly = !root.showDisabledOnly }
          }

          Text {
            id: appsTitle
            anchors.top: parent.top
            anchors.topMargin: Style.space(38)
            anchors.left: parent.left
            anchors.right: parent.right
            text: (root.filteredApps || []).length + " apps · click a row for details · NET column = system-wide transfer"
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
            midX: Style.space(248)
          }

          ListView {
            id: appList
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
              onDetails: root.detailApp = modelData
              onKill: root.appAction("kill", modelData.name)
              onDisable: root.disableApp(modelData.name)
              onEnable: root.enableApp(modelData.name)
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
            Text {
              text: "\uf013  Alerts config"
              color: root.fg
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
            Item { width: Style.space(10); height: 1 }
            OMCPill {
              label: root.alertPrefs.enabled ? "Alerts ON" : "Alerts OFF"
              active: root.alertPrefs.enabled !== false
              onChosen: {
                var next = !root.alertPrefs.enabled
                root.alertPrefs = ({ "enabled": next, "types": root.alertPrefs.types || {}, "charts": root.alertPrefs.charts || {} })
                root.setAlertsEnabled(next)
                root.refreshSoon()
              }
            }
          }

          Text {
            id: alertsTitle
            anchors.top: parent.top
            anchors.topMargin: Style.space(44)
            anchors.left: parent.left
            anchors.right: parent.right
            text: "Per event type, pick how it surfaces — Toast · Notify me · Quiet — and whether it leaves a marker on the history chart"
            color: root.dim1
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            lineHeight: 1.3
            wrapMode: Text.WordWrap
          }

          Text {
            id: alertsHelp
            anchors.top: alertsTitle.bottom
            anchors.topMargin: Style.space(8)
            anchors.left: parent.left
            anchors.right: parent.right
            text: "Each type gets one notification mode below; the Chart marker switch is independent of it. The Alerts ON/OFF pill above silences everything at once."
            color: root.dim2
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            lineHeight: 1.3
            wrapMode: Text.WordWrap
          }

          Row {
            anchors.top: alertsHelp.bottom
            anchors.topMargin: Style.space(14)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            spacing: Style.space(8)

            Column {
              width: (parent.width - Style.space(24)) / 4
              spacing: Style.space(6)
              Rectangle {
                width: parent.width; height: Style.space(30); radius: Style.space(12)
                color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12)
                border.width: 1
                border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.4)
                Text {
                  anchors.left: parent.left; anchors.leftMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter
                  text: "Toast"
                  color: root.accent
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }
              Text {
                width: parent.width
                height: Style.space(34)
                text: "Instant desktop pop-up, plus a count dot on the Events tab."
                color: root.dim2
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                lineHeight: 1.3
                wrapMode: Text.WordWrap
              }
              Repeater {
                model: root.alertTypes
                delegate: OMCPill {
                  width: parent.width
                  active: root.alertMode(modelData) === "toast"
                  label: modelData
                  onChosen: root.setAlertMode(modelData, "toast")
                }
              }
            }

            Column {
              width: (parent.width - Style.space(24)) / 4
              spacing: Style.space(6)
              Rectangle {
                width: parent.width; height: Style.space(30); radius: Style.space(12)
                color: Qt.rgba(0.878, 0.627, 0.188, 0.10)
                border.width: 1
                border.color: Qt.rgba(0.878, 0.627, 0.188, 0.45)
                Text {
                  anchors.left: parent.left; anchors.leftMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter
                  text: "Notify me"
                  color: "#e0a030"
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }
              Text {
                width: parent.width
                height: Style.space(34)
                text: "No pop-up; adds a red count dot on the Events (bell) tab to check later."
                color: root.dim2
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                lineHeight: 1.3
                wrapMode: Text.WordWrap
              }
              Repeater {
                model: root.alertTypes
                delegate: OMCPill {
                  width: parent.width
                  active: root.alertMode(modelData) === "notify"
                  label: modelData
                  onChosen: root.setAlertMode(modelData, "notify")
                }
              }
            }

            Column {
              width: (parent.width - Style.space(24)) / 4
              spacing: Style.space(6)
              Rectangle {
                width: parent.width; height: Style.space(30); radius: Style.space(12)
                color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.10)
                border.width: 1
                border.color: Qt.rgba(root.dim1.r, root.dim1.g, root.dim1.b, 0.25)
                Text {
                  anchors.left: parent.left; anchors.leftMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter
                  text: "No notification"
                  color: root.dim1
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }
              Text {
                width: parent.width
                height: Style.space(34)
                text: "No pop-up or badge — the event is only logged for later."
                color: root.dim2
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                lineHeight: 1.3
                wrapMode: Text.WordWrap
              }
              Repeater {
                model: root.alertTypes
                delegate: OMCPill {
                  width: parent.width
                  active: root.alertMode(modelData) === "none"
                  label: modelData
                  onChosen: root.setAlertMode(modelData, "none")
                }
              }
            }

            Column {
              width: (parent.width - Style.space(24)) / 4
              spacing: Style.space(6)
              Rectangle {
                width: parent.width; height: Style.space(30); radius: Style.space(12)
                color: Qt.rgba(0.36, 0.55, 0.95, 0.10)
                border.width: 1
                border.color: Qt.rgba(0.36, 0.55, 0.95, 0.45)
                Text {
                  anchors.left: parent.left; anchors.leftMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter
                  text: "Chart marker"
                  color: "#6f9cff"
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }
              Text {
                width: parent.width
                height: Style.space(34)
                text: "Pin on the history chart to spot patterns — independent of the modes above."
                color: root.dim2
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                lineHeight: 1.3
                wrapMode: Text.WordWrap
              }
              Repeater {
                model: root.alertTypes
                delegate: OMCPill {
                  width: parent.width
                  active: root.chartShown(modelData)
                  label: root.chartShown(modelData) ? modelData : (modelData + " · hidden")
                  onChosen: root.setChartToggle(modelData, !root.chartShown(modelData))
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
            text: "Persistent history · click any row for full details and actions"
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
              onDetails: function(ev) {
                root.eventDetail = ev
                if (!ev.read) root.markEventRead(ev.id)
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

          Flickable {
            id: settingsFlick
            anchors.fill: parent
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            contentHeight: settingsCol.implicitHeight
            interactive: settingsCol.implicitHeight > settingsFlick.height

            Column {
              id: settingsCol
              width: settingsFlick.width
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
                      text: modelData.label
                      color: root.dim1
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      anchors.verticalCenter: parent.verticalCenter
                      elide: Text.ElideRight
                      width: parent.width - Style.space(26)
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

            Rectangle {
              width: parent.width
              height: Style.space(42)
              radius: Style.space(12)
              color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.07)
              Row {
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: Style.space(8)
                Text {
                  text: "\uf0f3"
                  color: root.barPrefs.barShowBell !== false ? root.accent : root.dim1
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  width: parent.width - Style.space(70)
                  elide: Text.ElideRight
                  text: "Show unread bell badge in the top bar"
                  color: root.fg
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
                Rectangle {
                  width: Style.space(46); height: Style.space(22); radius: Style.space(11)
                  border.width: 1
                  border.color: root.barPrefs.barShowBell !== false ? root.accent : root.dim1
                  color: (bellHover.containsMouse || root.barPrefs.barShowBell !== false) ? root.accentSoft : "transparent"
                  Text {
                    anchors.centerIn: parent
                    text: root.barPrefs.barShowBell !== false ? "ON" : "OFF"
                    color: root.barPrefs.barShowBell !== false ? root.accent : root.dim1
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                  MouseArea {
                    id: bellHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setBarShowBell(root.barPrefs.barShowBell === false)
                  }
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

            // ---- Support / Buy Me a Coffee (same pattern as the mouse &
            // keybind settings plugin; hidden via the toggle below).
            Text {
              text: "SUPPORT"
              color: root.fg
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              font.letterSpacing: 1
            }

            Rectangle {
              visible: root.barPrefs.showBuyButton !== false
              width: parent.width
              height: Style.space(50)
              radius: Style.space(12)
              color: donateRowHover.containsMouse ? Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.14) : Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.07)
              Row {
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: Style.space(8)
                Image {
                  id: kofiImage
                  visible: kofiImage.status !== Image.Error
                  width: 143
                  height: 36
                  anchors.verticalCenter: parent.verticalCenter
                  sourceSize.height: 72
                  fillMode: Image.PreserveAspectFit
                  smooth: true
                  mipmap: true
                  source: "https://storage.ko-fi.com/cdn/kofi5.png?v=6"
                }
                Rectangle {
                  visible: kofiImage.status === Image.Error || kofiImage.status === Image.Null || kofiImage.status === Image.Loading
                  width: 143
                  height: 36
                  radius: Style.space(12)
                  color: "transparent"
                  border.width: 1
                  border.color: root.dim1
                  Text {
                    anchors.centerIn: parent
                    text: "☕ Buy Me a Coffee"
                    color: "#FF813F"
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }
                Text {
                  width: parent.width - Style.space(180)
                  elide: Text.ElideRight
                  text: "Donate a coffee to support OmaControl"
                  color: root.fg
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
              MouseArea {
                id: donateRowHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openBuyMeACoffee()
              }
            }

            Rectangle {
              width: parent.width
              height: Style.space(42)
              radius: Style.space(12)
              color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.07)
              Row {
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: Style.space(8)
                Text {
                  text: "\uf7b6"
                  color: root.barPrefs.showBuyButton !== false ? root.accent : root.dim1
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  width: parent.width - Style.space(70)
                  elide: Text.ElideRight
                  text: "Show the Buy Me a Coffee button"
                  color: root.fg
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
                Rectangle {
                  width: Style.space(46); height: Style.space(22); radius: Style.space(11)
                  border.width: 1
                  border.color: root.barPrefs.showBuyButton !== false ? root.accent : root.dim1
                  color: (buyCoffeeHover.containsMouse || root.barPrefs.showBuyButton !== false) ? root.accentSoft : "transparent"
                  Text {
                    anchors.centerIn: parent
                    text: root.barPrefs.showBuyButton !== false ? "ON" : "OFF"
                    color: root.barPrefs.showBuyButton !== false ? root.accent : root.dim1
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                  MouseArea {
                    id: buyCoffeeHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setShowBuyButton(root.barPrefs.showBuyButton === false)
                  }
                }
              }
            }
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

  // ==================== Event details modal (one click from an Events row)
  EventDetailPanel {
    id: eventDetailPanel
    visible: root.eventDetail != null
    event: root.eventDetail
    z: 63
    anchors.fill: card
    onEventChanged: {
      if (root.eventDetail) root.loadEventContext(root.eventDetail)
      else root.eventCtx = null
    }
    onClose: root.eventDetail = null
    onKill: function(name) { root.appAction("kill", name); root.eventDetail = null }
    onDisable: function(name) { root.disableApp(name); root.eventDetail = null }
    onEnable: function(name) { root.enableApp(name); root.eventDetail = null }
  }

  // Shared rounded-pill: used by the Activity MET selectors (label + optional
  // live value), the Apps filter row and the Alerts config chips — one shape
  // everywhere.
  component OMCPill: Rectangle {
    id: pill
    property bool active: false
    property string label: ""
    property string value: ""
    property color pillColor: root.accent
    signal chosen()
    radius: height / 2
    height: pill.value === "" ? Style.space(28) : Style.space(44)
    width: pill.value === ""
        ? Math.max(pillLabel.implicitWidth + Style.space(20), Style.space(40))
        : Math.max(Style.space(116), Math.min(Style.space(170), pillValue.implicitWidth + Style.space(24)))
    color: pill.active
        ? pill.pillColor
        : Qt.rgba(pill.pillColor.r, pill.pillColor.g, pill.pillColor.b, 0.12)
    border.width: 1
    border.color: pill.active
        ? pill.pillColor
        : Qt.rgba(pill.pillColor.r, pill.pillColor.g, pill.pillColor.b, 0.35)
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
      spacing: 1
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
    label: rp.seconds >= 86400 ? "1d"
         : rp.seconds >= 21600 ? "6h"
         : rp.seconds >= 3600 ? "1h"
         : "15m"
  }

  // Sort dropdown for the Activity / Apps lists. Options: [{v, label}].
  // Purely visual — the caller binds `value` and re-renders on change.
  component SortMenu: Item {
    id: sm
    property var options: []
    property string value: ""
    property bool open: false
    property string prefix: "Sort"
    signal chosen(var v)
    width: Style.space(158)
    height: Style.space(30)
    z: 60

    readonly property string cur: (function() {
      for (var i = 0; i < sm.options.length; i++)
        if ((sm.options[i].v || "") === sm.value) return sm.options[i].label
      return ""
    })()

    Rectangle {
      id: smBtn
      anchors.fill: parent
      radius: Style.space(12)
      color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.12)
      border.width: 1
      border.color: sm.open
          ? root.accent
          : Qt.rgba(root.dim1.r, root.dim1.g, root.dim1.b, 0.4)
      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(18)
        anchors.verticalCenter: parent.verticalCenter
        text: sm.prefix + " \u25bc  " + sm.cur
        color: root.fg
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: sm.open = !sm.open
      }
    }

    Rectangle {
      visible: sm.open
      anchors.top: smBtn.bottom
      anchors.topMargin: Style.space(4)
      anchors.right: parent.right
      z: 80
      width: Style.space(182)
      height: smContent.implicitHeight + Style.space(8)
      color: root.surface
      radius: Style.space(10)
      border.width: 1
      border.color: root.surfaceBorder
      MouseArea {
        anchors.fill: parent
        onClicked: sm.open = false
      }

      Column {
        id: smContent
        anchors.top: parent.top
        anchors.topMargin: Style.space(4)
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(2)
        Repeater {
          model: sm.options
          delegate: Rectangle {
            width: parent.width
            height: Style.space(26)
            radius: Style.space(7)
            color: modelData.v === sm.value
                ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                : "transparent"
            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.label
              color: modelData.v === sm.value ? root.accent : root.fg
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                sm.chosen(modelData.v)
                sm.open = false
              }
            }
          }
        }
      }
    }
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

      Row {
        id: arTags
        anchors.left: arName.right
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)
        Rectangle {
          visible: ar.app.disabled
          width: arDisTxt.implicitWidth + Style.space(12)
          height: Style.space(16)
          radius: Style.space(8)
          color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.14)
          Text {
            id: arDisTxt
            anchors.centerIn: parent
            text: "\uf05e  Disabled"
            color: root.dim1
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
        Rectangle {
          visible: ar.app.verified
          width: arVerTxt.implicitWidth + Style.space(12)
          height: Style.space(16)
          radius: Style.space(8)
          color: Qt.rgba(0.3, 0.75, 0.45, 0.18)
          border.width: 1
          border.color: Qt.rgba(0.3, 0.75, 0.45, 0.5)
          Text {
            id: arVerTxt
            anchors.centerIn: parent
            text: "\uf058  Verified"
            color: "#3fbf6f"
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
        Rectangle {
          visible: ar.unsigned
          width: arUnsTxt.implicitWidth + Style.space(12)
          height: Style.space(16)
          radius: Style.space(8)
          color: Qt.rgba(0.9, 0.6, 0.15, 0.18)
          border.width: 1
          border.color: Qt.rgba(0.9, 0.6, 0.15, 0.5)
          Text {
            id: arUnsTxt
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

      Text {
        id: arPid
        anchors.right: parent.right
        anchors.rightMargin: Style.space(476)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(60)
        horizontalAlignment: Text.AlignHCenter
        text: (function() {
          var p = ar.app.pids || []
          if (p.length === 0) return ""
          if (p.length === 1) return String(p[0])
          return String(p[0]) + " +" + (p.length - 1)
        })()
        elide: Text.ElideRight
        color: root.dim1
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }
      Sparkline {
        id: arSpark
        anchors.right: parent.right
        anchors.rightMargin: Style.space(380)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(96)
        height: Style.space(14)
        data: ar.app.spark || []
      }
      Text {
        id: arNet
        anchors.right: parent.right
        anchors.rightMargin: Style.space(312)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(56)
        horizontalAlignment: Text.AlignHCenter
        text: root.fmtNet((root.sample.net_rx_kbs || 0) + (root.sample.net_tx_kbs || 0))
        color: root.dim1
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        id: arDisk
        anchors.right: parent.right
        anchors.rightMargin: Style.space(240)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(56)
        horizontalAlignment: Text.AlignHCenter
        text: root.fmtNet(ar.app.io || 0)
        color: root.dim1
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        id: arGpu
        anchors.right: parent.right
        anchors.rightMargin: Style.space(176)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(48)
        horizontalAlignment: Text.AlignHCenter
        text: Math.round(ar.app.gpu || 0) + "%"
        color: root.dim1
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        id: arMem
        anchors.right: parent.right
        anchors.rightMargin: Style.space(112)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(48)
        horizontalAlignment: Text.AlignHCenter
        text: Math.round(ar.app.mem || 0) + "%"
        color: root.dim1
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }
      Rectangle {
        id: arCpu
        anchors.right: parent.right
        anchors.rightMargin: Style.space(40)
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
        anchors.rightMargin: Style.space(8)
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
    signal details(var event)
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
    readonly property color typed: root.eventTypeColor(event.kind || "")
    readonly property string icon: root.eventIcon(event.kind || "")
    property bool actionOpen: false
    implicitHeight: (evr.actionOpen ? Style.space(54) : Style.space(30))
    width: parent ? parent.width : 0

    Rectangle {
      anchors.fill: parent
      radius: Style.space(12)
      color: evr.unread ? root.accentSoft : Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.05)
    }
    Rectangle {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.top: parent.top
      anchors.topMargin: Style.space(6)
      width: Style.space(3)
      height: Style.space(18)
      radius: Style.space(2)
      color: evr.typed
    }
    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(18)
      anchors.top: parent.top
      anchors.topMargin: Style.space(5)
      width: Style.space(20)
      height: Style.space(20)
      horizontalAlignment: Text.AlignHCenter
      text: evr.icon
      color: evr.typed
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
    Rectangle {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(48)
      anchors.top: parent.top
      anchors.topMargin: Style.space(5)
      width: Style.space(56)
      height: Style.space(15)
      radius: Style.space(8)
      color: Qt.rgba(evr.typed.r, evr.typed.g, evr.typed.b, 0.15)
      Text {
        anchors.centerIn: parent
        text: evr.kindLabel
        color: evr.typed
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(112)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(96)
      anchors.top: parent.top
      anchors.topMargin: Style.space(5)
      height: Style.space(20)
      verticalAlignment: Text.AlignVCenter
      text: (hasApp ? (event.app + " — ") : "") + (event.msg || "")
      color: root.fg
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: evr.unread
      elide: Text.ElideRight
    }
    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(44)
      anchors.top: parent.top
      anchors.topMargin: Style.space(5)
      height: Style.space(20)
      verticalAlignment: Text.AlignVCenter
      text: root.fmtAgo(event.ts || 0)
      color: root.dim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
    Text {
      id: evrChevron
      z: 5
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.top: parent.top
      anchors.topMargin: Style.space(5)
      width: Style.space(26)
      height: Style.space(20)
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      text: evr.actionOpen ? "\uf077" : "\uf078"
      color: root.dim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: evr.actionOpen = !evr.actionOpen
      }
    }
    Row {
      z: 4
      visible: evr.actionOpen
      anchors.top: parent.top
      anchors.topMargin: Style.space(30)
      anchors.left: parent.left
      anchors.leftMargin: Style.space(112)
      spacing: Style.space(6)
      height: Style.space(22)
      ActionChip {
        label: "Details"
        onChosen: evr.details(evr.event)
      }
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
    }
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: evr.details(evr.event)
    }
  }

  component EventDetailPanel: Item {
    id: edp
    property var event: ({})

    // Guarded alias so the hidden panel (event === null) never hits null derefs.
    readonly property var ev: edp.event || {}
    signal close()
    signal kill(string name)
    signal disable(string name)
    signal enable(string name)
    readonly property color typed: root.eventTypeColor(edp.ev.kind || "")
    readonly property bool hasApp: (edp.ev.app || "") !== ""
    readonly property var snapProcs: root.topAt(edp.ev.ts || 0, 8)
    readonly property bool loading: root.eventCtxBusy && !root.eventCtx
    readonly property string verifiedLine: (function() {
      var a = root.eventCtx && root.eventCtx.app
      if (!a) return ""
      var tag = a.verified ? "\uf058 Verified" : "\uf071 Unsigned"
      var pub = (a.publisher && a.publisher !== "Unknown" && a.publisher !== "")
          ? " · " + a.publisher : ""
      return tag + pub
    })()
    readonly property string appDesc: (root.eventCtx && root.eventCtx.app && root.eventCtx.app.desc) || ""
    readonly property var ctxApp: root.eventCtx && root.eventCtx.app
    readonly property bool ctxAppVerified: !!(edp.ctxApp && edp.ctxApp.verified)
    readonly property string ctxAppPublisher: (edp.ctxApp && edp.ctxApp.publisher) || ""
    readonly property string siblingsLine: (function() {
      var c = root.eventCtx
      if (!c) return ""
      var parts = []
      if (edp.hasApp && typeof c.app_count === "number") parts.push(c.app_count + "× this app")
      if (typeof c.kind_count === "number") parts.push(c.kind_count + "× of this kind")
      return parts.length ? "This week: " + parts.join(" · ") : ""
    })()
    readonly property var ctxPills: (function() {
      var s = root.eventCtx && root.eventCtx.state
      if (!s) return []
      var arr = [
        { k: "CPU", v: Math.round(s.cpu) + "%" },
        { k: "MEM", v: (s.mem_pct || 0) + "%" },
        { k: "GPU", v: Math.round(s.gpu) + "%" },
        { k: "PROCS", v: "" + s.procs }
      ]
      if (s.cpu_temp) arr.push({ k: "CPU TMP", v: s.cpu_temp + "°" })
      if (s.gpu_temp) arr.push({ k: "GPU TMP", v: s.gpu_temp + "°" })
      return arr
    })()

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.35)
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: edp.close()
      }
    }

    Rectangle {
      width: Math.min(parent.width * 0.5, Style.space(420))
      height: Math.min(parent.height - Style.space(80),
                       edpBody.implicitHeight + Style.space(40))
      anchors.centerIn: parent
      radius: Style.space(16)
      color: root.surface
      border.width: 1
      border.color: root.surfaceBorder
      clip: true
      MouseArea { anchors.fill: parent }

      Text {
        anchors.top: parent.top
        anchors.topMargin: Style.space(10)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(14)
        text: "\uf00d"
        color: root.dim2
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.body
        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: edp.close()
        }
      }

      Column {
        id: edpBody
        anchors.fill: parent
        anchors.margins: Style.space(20)
        spacing: Style.space(10)

        Row {
          spacing: Style.space(8)
          Rectangle {
            width: Style.space(36)
            height: Style.space(36)
            radius: width / 2
            color: edp.typed
            Text {
              anchors.centerIn: parent
              text: root.eventIcon(edp.ev.kind || "")
              color: "white"
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }
          }
          Column {
            anchors.verticalCenter: parent.verticalCenter
            Text {
              text: edp.ev.app || "System"
              color: root.fg
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              text: edp.ev.publisher || "Unknown"
              color: root.dim1
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
        Text {
          width: edpBody.width
          text: root.eventKindLabel(edp.ev.kind || "")
          color: edp.typed
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
        Text {
          width: edpBody.width
          text: root.eventKindExplain(edp.ev.kind || "")
          wrapMode: Text.WordWrap
          color: root.dim1
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          width: edpBody.width
          text: edp.ev.msg || ""
          wrapMode: Text.WordWrap
          color: root.fg
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          text: root.fmtFullDate(edp.ev.ts || 0)
          color: root.dim2
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          visible: edp.loading
          text: "Loading context\u2026"
          color: root.dim2
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.italic: true
        }
        Rectangle {
          visible: edp.hasApp && !edp.loading
          width: edpBody.width
          color: edp.typed.a < 0.05 ? root.surface : Qt.rgba(edp.typed.r, edp.typed.g, edp.typed.b, 0.08)
          radius: Style.space(10)
          border.width: 1
          border.color: Qt.rgba(edp.typed.r, edp.typed.g, edp.typed.b, 0.25)
          Column {
            anchors.fill: parent
            anchors.margins: Style.space(10)
            spacing: Style.space(4)
            Text {
              visible: edp.verifiedLine !== ""
              text: edp.verifiedLine
              color: edp.ctxAppVerified ? "#3cb371" : "#e0a030"
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Text {
              visible: edp.ctxAppPublisher !== "" && edp.verifiedLine === ""
              text: edp.ctxAppPublisher
              color: root.dim1
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              visible: edp.appDesc !== ""
              width: edpBody.width - Style.space(22)
              text: edp.appDesc
              wrapMode: Text.WordWrap
              color: root.dim1
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
        Row {
          visible: edp.ctxPills.length > 0
          spacing: Style.space(6)
          Repeater {
            model: edp.ctxPills
            delegate: Rectangle {
              width: Style.space(56)
              height: Style.space(34)
              radius: Style.space(8)
              color: root.accentSoft
              Column {
                anchors.centerIn: parent
                spacing: Style.space(1)
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: modelData.v
                  color: root.fg
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: modelData.k
                  color: root.dim2
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
        Text {
          visible: edp.siblingsLine !== ""
          text: edp.siblingsLine
          color: root.dim2
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          text: "PROCESSES AT " + root.fmtTime(edp.ev.ts || 0)
          color: root.dim1
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
        Text {
          visible: edp.snapProcs.length === 0
          width: edpBody.width
          text: "No minute snapshot captured for this exact moment"
          color: root.dim2
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
        Repeater {
          model: edp.snapProcs
          delegate: Item {
            id: evProc
            readonly property bool isEvApp: (modelData.name || "").toLowerCase() === (edp.ev.app || "").toLowerCase()
            width: edpBody.width - Style.space(2)
            height: Style.space(19)
            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width * 0.55
              text: (evProc.isEvApp ? "\u25c9 " : "") + (modelData.name || "unknown")
              color: evProc.isEvApp ? root.accent : root.fg
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: evProc.isEvApp
              elide: Text.ElideRight
            }
            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: Math.round(modelData.cpu || 0) + "% CPU"
                  + (modelData.mem ? " · " + Math.round(modelData.mem) + " MB" : "")
                  + (modelData.pid ? " · " + modelData.pid : "")
              color: evProc.isEvApp ? root.accent : root.dim1
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
        Row {
          spacing: Style.space(8)
          ActionChip {
            visible: edp.hasApp
            label: "Kill"
            danger: true
            onChosen: edp.kill(edp.ev.app)
          }
          ActionChip {
            visible: edp.hasApp && edp.ev.kind !== "user_disable"
            label: "Disable"
            onChosen: edp.disable(edp.ev.app)
          }
          ActionChip {
            visible: edp.hasApp && edp.ev.kind === "user_disable"
            label: "Enable"
            onChosen: edp.enable(edp.ev.app)
          }
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
    property bool procOpen: false
    property bool procShowAll: false
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
        { k: "PEAK I/O", v: root.fmtNetFull(s.max_io_kbs) }
      ]
    }
    function stampLine() {
      if (!dp.stats) return dp.statsBusy ? "Scanning tracked history…" : ""
      function d(ts) { return new Date(ts * 1000).toLocaleDateString() }
      return "Since first tracked: " + dp.stats.samples + " samples · " + d(dp.stats.first_ts) + " → " + d(dp.stats.last_ts)
    }
    function cpuNote() {
      if (!dp.stats) return ""
      var cores = dp.stats.cores || 0
      return (cores > 1 ? "CPU is an average across all " + Math.round(cores)
              + " cores — 100% means one core fully busy" : "CPU is shown per core — 100% = one core fully busy")
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
    function procShown() {
      var arr = root.procDetail || []
      if (!arr.length) return []
      return arr.slice(0, dp.procShowAll ? arr.length : 6)
    }
    function procMore() { return Math.max(0, (root.procDetail || []).length - 6) }
    function statLegend() {
      if (!dp.stats) return []
      var s = dp.stats
      function r(x) { return Math.round(x * 10) / 10 }
      var arr = []
      arr.push({ h: "PEAK CPU", d: "average across all cores — 100% means one core fully busy" })
      arr.push({ h: "AVG CPU", d: "mean of the above across all tracked samples" })
      arr.push({ h: "PEAK MEM", d: "largest resident RAM footprint in MB" })
      arr.push({ h: "AVG MEM", d: "mean resident RAM footprint in MB" })
      arr.push({ h: "PEAK GPU", d: "GPU utilization %, sampled while it was the top GPU process" })
      arr.push({ h: "PEAK I/O", d: "highest disk throughput (read + write), auto-scaled KB/s → MB/s → GB/s" })
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
      text: (dp.app && dp.app.source || "unknown")
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
      text: (dp.app && dp.app.desc && dp.app.desc.trim() !== "")
        ? dp.app.desc
        : ((dp.app && dp.app.exe) ? ("Binary: " + dp.app.exe + " — no description available.")
                                  : "No description available for this binary.")
      color: root.dim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      maximumLineCount: 2
      elide: Text.ElideRight
    }
    Flickable {
      id: dpScroll
      anchors.top: dpDesc.bottom
      anchors.topMargin: Style.space(10)
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(12)
      anchors.bottom: dpChips.top
      anchors.bottomMargin: Style.space(8)
      clip: true
      contentWidth: width
      contentHeight: dpInfo.implicitHeight
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: dpInfo
        width: dpScroll.width
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

      Column {
        width: parent.width
        visible: !!dp.app && (root.procDetail.length > 0 || root.procDetailBusy)
        spacing: Style.space(4)

        Rectangle {
          id: procHeader
          width: parent.width
          height: Style.space(22)
          radius: Style.space(11)
          color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.10)
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            preventStealing: true
            onPressed: console.log("PROC HEADER PRESS")
            onClicked: {
              console.log("PROC HEADER CLICK pre=" + dp.procOpen + " n=" + root.procDetail.length)
              dp.procOpen = !dp.procOpen
              if (!dp.procOpen) dp.procShowAll = false
              dpScroll.contentY = Math.max(0, procHeader.mapToItem(dpInfo, 0, 0).y - Style.space(4))
            }
            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: (dp.procOpen ? "\uf078  " : "\uf054  ")
                  + "Running processes (" + root.procDetail.length + ")"
              color: root.dim1
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }
        }

        Text {
          visible: root.procDetailBusy && root.procDetail.length === 0
          text: "Scanning live processes…"
          color: root.dim2
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }

        Repeater {
          visible: dp.procOpen
          model: dp.procOpen ? dp.procShown() : []
          delegate: Column {
            width: dpInfo.width
            spacing: Style.space(1)
            Rectangle {
              width: parent.width
              height: Style.space(44)
              radius: Style.space(10)
              color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.08)
              Row {
                anchors.top: parent.top
                anchors.topMargin: Style.space(5)
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(6)
                Text {
                  text: "#" + modelData.pid
                  color: root.fg
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Rectangle {
                  width: Math.max(Style.space(46), stateChipText.implicitWidth + Style.space(12))
                  height: Style.space(14)
                  radius: Style.space(7)
                  color: modelData.state === "Z"
                      ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.12)
                      : Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.12)
                  Text {
                    id: stateChipText
                    anchors.centerIn: parent
                    text: modelData.state_label
                    color: modelData.state === "Z" ? root.urgent : root.dim1
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
                Text {
                  text: modelData.user
                  color: root.dim1
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  visible: modelData.threads > 1
                  text: "·  " + modelData.threads + " threads"
                  color: root.dim2
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  visible: modelData.rss_mb > 0
                  text: "·  " + modelData.rss_mb + " MB"
                  color: root.dim2
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  visible: modelData.elapsed_s > 0
                  text: "·  up " + root.fmtDur(modelData.elapsed_s)
                  color: root.dim2
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  visible: modelData.cpu_s > 0
                  text: "·  " + (modelData.cpu_s >= 10 ? Math.round(modelData.cpu_s) : modelData.cpu_s) + "s cpu"
                  color: root.dim2
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  visible: modelData.unit !== ""
                  text: "·  " + modelData.unit
                  color: root.dim2
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.top: parent.top
                anchors.topMargin: Style.space(22)
                text: modelData.cmdline
                color: root.dim2
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }
        }

        Rectangle {
          width: parent.width
          height: Style.space(22)
          radius: Style.space(11)
          visible: dp.procOpen && !dp.procShowAll && dp.procMore() > 0
          color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.08)
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            preventStealing: true
            onClicked: dp.procShowAll = true
            Text {
              anchors.centerIn: parent
              text: "+ " + dp.procMore() + " more instance(s)"
              color: root.dim2
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
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
  }
    Row {
      id: dpChips
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(10)
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
    property real midX: Style.space(306)
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
      anchors.leftMargin: ch.midX
      anchors.verticalCenter: parent.verticalCenter
      text: ch.midLabel
      color: root.dim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    // Right columns mirror ProcRow/AppRow's fixed right-side geometry so the
    // labels sit directly over the data they describe.
    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(40)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(60)
      horizontalAlignment: Text.AlignHCenter
      text: "CPU"
      color: root.dim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(112)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(48)
      horizontalAlignment: Text.AlignHCenter
      text: "MEM"
      color: root.dim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(176)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(48)
      horizontalAlignment: Text.AlignHCenter
      text: "GPU"
      color: root.dim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(240)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(56)
      horizontalAlignment: Text.AlignHCenter
      text: "DISK"
      color: root.dim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(312)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(56)
      horizontalAlignment: Text.AlignHCenter
      text: "NET"
      color: root.dim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(380)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(96)
      horizontalAlignment: Text.AlignHCenter
      text: "TREND"
      color: root.dim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(476)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(60)
      horizontalAlignment: Text.AlignHCenter
      text: "PID"
      color: root.dim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  component ProcRow: Item {
    id: pr
    property string name: ""
    property int pid: 0
    property real cpu: 0
    property real mem: 0
    property real io: 0
property real gpu: 0
    property real net: -1
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
    Row {
      anchors.left: prName.right
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)
      Rectangle {
        visible: pr.disabled
        width: prDisTxt.implicitWidth + Style.space(10)
        height: Style.space(14)
        radius: Style.space(7)
        color: Qt.rgba(root.dim2.r, root.dim2.g, root.dim2.b, 0.14)
        Text {
          id: prDisTxt
          anchors.centerIn: parent
          text: "\uf05e Disabled"
          color: root.dim1
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }
      Rectangle {
        visible: pr.verified
        width: prVerTxt.implicitWidth + Style.space(10)
        height: Style.space(14)
        radius: Style.space(7)
        color: Qt.rgba(0.3, 0.75, 0.45, 0.18)
        border.width: 1
        border.color: Qt.rgba(0.3, 0.75, 0.45, 0.5)
        Text {
          id: prVerTxt
          anchors.centerIn: parent
          text: "\uf058 Verified"
          color: "#3fbf6f"
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }
      Rectangle {
        visible: !pr.verified
        width: prUnsTxt.implicitWidth + Style.space(10)
        height: Style.space(14)
        radius: Style.space(7)
        color: Qt.rgba(0.9, 0.6, 0.15, 0.15)
        border.width: 1
        border.color: Qt.rgba(0.9, 0.6, 0.15, 0.45)
        Text {
          id: prUnsTxt
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
      anchors.right: parent.right
      anchors.rightMargin: Style.space(380)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(96)
      height: Style.space(14)
      data: pr.sparks
    }
    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(476)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(60)
      horizontalAlignment: Text.AlignHCenter
      text: pr.pid > 0 ? String(pr.pid) : ""
      color: root.dim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(312)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(56)
      horizontalAlignment: Text.AlignHCenter
      text: root.fmtNet(pr.net >= 0 ? pr.net
          : (root.sample.net_rx_kbs || 0) + (root.sample.net_tx_kbs || 0))
      color: root.dim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(240)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(56)
      horizontalAlignment: Text.AlignHCenter
      text: root.fmtNet(pr.io)
      color: root.dim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(176)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(48)
      horizontalAlignment: Text.AlignHCenter
      text: Math.round(pr.gpu) + "%"
      color: root.dim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(112)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(48)
      horizontalAlignment: Text.AlignHCenter
      text: Math.round(pr.mem) + "%"
      color: root.dim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
    Rectangle {
      id: prCpu
      anchors.right: parent.right
      anchors.rightMargin: Style.space(40)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(60)
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

    // Property-backed forms of domainStart()/domainEnd() so external bindings
    // (e.g. the temperature strip) re-evaluate on zoom/pan instead of calling
    // the functions (function calls aren't tracked by the binding engine).
    readonly property real domStart: hg.zoomed ? hg.viewStart : hg.fullStart()
    readonly property real domEnd: hg.zoomed ? hg.viewEnd : hg.fullEnd()

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

      ctx.strokeStyle = Qt.rgba(root.dim1.r, root.dim1.g, root.dim1.b, 0.09)
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
        ctx.textAlign = "right"
        ctx.fillText(gv < 10 ? ("" + (gv % 1 !== 0 ? gv.toFixed(1) : Math.round(gv))) : ("" + Math.round(gv)), w - rightPad - 2, gy - 2)
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

      // Subtle gradient fill under the curve (own closed path, so the stroke
      // below stays a crisp single line instead of a filled outline).
      ctx.beginPath()
      var fStarted = false
      for (var fi = 0; fi < hg.pts.length; fi++) {
        var fp = hg.pts[fi]
        var fX = leftPad + (fp.ts - hg.domainStart()) / spanT * plotW
        var fY = topPad + plotH - Math.max(0, Math.min(yMax, fp.v)) / yMax * plotH
        if (!fStarted) { ctx.moveTo(fX, fY); fStarted = true }
        else ctx.lineTo(fX, fY)
      }
      ctx.lineTo(leftPad + plotW, topPad + plotH)
      ctx.lineTo(leftPad, topPad + plotH)
      ctx.closePath()
      var grad = ctx.createLinearGradient(0, topPad, 0, topPad + plotH)
      grad.addColorStop(0, Qt.rgba(hg.lineColor.r, hg.lineColor.g, hg.lineColor.b, 0.18))
      grad.addColorStop(1, Qt.rgba(hg.lineColor.r, hg.lineColor.g, hg.lineColor.b, 0.0))
      ctx.fillStyle = grad
      ctx.fill()

      // Clean single-pixel-width line overlay in accent color.
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

      // Event pins: a diamond tab at the top edge with a faint vertical guide
      // down to the curve — every logged event (incl. every toast) stays
      // pinned on the chart at its timestamp.
      if (hg.events && hg.events.length) {
        var eST = hg.domainStart(), eET = hg.domainEnd()
        for (var pi = 0; pi < hg.events.length; pi++) {
          var ev2 = hg.events[pi]
          if (ev2.ts < eST || ev2.ts > eET) continue
          var pinX = leftPad + (ev2.ts - eST) / spanT * plotW
          var pinVal = -1
          for (var bi2 = 0; bi2 < hg.pts.length; bi2++) {
            if (hg.pts[bi2].ts <= ev2.ts) pinVal = hg.pts[bi2].v
            else {
              if (bi2 > 0 && hg.pts[bi2].ts !== hg.pts[bi2 - 1].ts) {
                var f2 = (ev2.ts - hg.pts[bi2 - 1].ts) / (hg.pts[bi2].ts - hg.pts[bi2 - 1].ts)
                pinVal = hg.pts[bi2 - 1].v + f2 * (hg.pts[bi2].v - hg.pts[bi2 - 1].v)
              } else pinVal = hg.pts[bi2].v
              break
            }
          }
          var pinCol = root.eventTypeColor(ev2.kind || ev2.type || "")
          // Faint vertical guide from the pin down to the interpolated curve
          // value (or the plot floor if the event predates the data).
          var pinBase = pinVal >= 0
              ? topPad + plotH - Math.max(0, Math.min(yMax, pinVal)) / yMax * plotH
              : topPad + plotH - 1
          ctx.strokeStyle = root.hexRgba(pinCol, 0.22)
          ctx.lineWidth = 1
          ctx.beginPath()
          ctx.moveTo(pinX + 0.5, topPad + 11)
          ctx.lineTo(pinX + 0.5, Math.max(topPad + 11, pinBase - 4))
          ctx.stroke()
          // Diamond pin head pinned to the top edge.
          ctx.beginPath()
          ctx.moveTo(pinX, topPad + 2)
          ctx.lineTo(pinX + 4, topPad + 6)
          ctx.lineTo(pinX, topPad + 10)
          ctx.lineTo(pinX - 4, topPad + 6)
          ctx.closePath()
          ctx.fillStyle = pinCol
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
    signal rangeSelected(real t1, real t2)

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
            if (!hg.dragMoved && Math.abs(mouse.x - hg.dragStart) >= 6) hg.dragMoved = true
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
          if (!hg.zoomed) {
            hg.zoomTo(hg.timeAtX(startX), hg.timeAtX(mouse.x))
            hg.rangeSelected(hg.viewStart, hg.viewEnd)
          }
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
          id: tipEvents
          width: tip.width - Style.space(16)
          color: Qt.rgba(0.72, 0.92, 1, 0.92)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          visible: false
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
        tipValue.text = (root.selMetric === "disk" || root.selMetric === "net") ? Model.fmtRate(near.v)
                        : Math.round(near.v) + hg.unit
        var top = []
        var sel = root.nearestSnap(near.ts)
        if (sel && sel.procs) {
          var arr = sel.procs.slice()
          var tipNet = root.selMetric === "net"
          var tipIo = root.selMetric === "disk"
          arr.sort(function(a, b) {
            if (tipNet) {
              var an2 = (a.nr || 0) + (a.nt || 0)
              var bn2 = (b.nr || 0) + (b.nt || 0)
              if (bn2 !== an2) return bn2 - an2
            }
            if (tipIo) {
              var ai2 = (a.io_kbs || 0)
              var bi2 = (b.io_kbs || 0)
              if (bi2 !== ai2) return bi2 - ai2
            }
            return b.cpu - a.cpu
          })
          top = [arr[0], arr[1], arr[2]]
        }
        tipTop.text = ""
        for (var k = 0; k < top.length && top[k]; k++) {
          tipTop.text += (k > 0 ? " · " : "") + top[k].name + " "
              + (tipNet ? Math.round((top[k].nr || 0) + (top[k].nt || 0)) + " KB/s"
                        : tipIo ? Math.round(top[k].io_kbs || 0) + " KB/s"
                                 : Math.round(top[k].cpu) + "%")
        }
        // Pinned events near this moment (the 3 closest within ±5 min).
        var pins = []
        for (var pi = 0; pi < hg.events.length; pi++) {
          var pe = hg.events[pi]
          var pd = Math.abs(pe.ts - near.ts)
          if (pd > 300) continue
          pins.push({ d: pd, e: pe })
        }
        pins.sort(function(a, b) { return a.d - b.d })
        var ptxt = ""
        for (var q = 0; q < pins.length && q < 3; q++) {
          var pev = pins[q].e
          ptxt += (q > 0 ? "\n" : "") + "◆ " + Qt.formatTime(new Date(pev.ts * 1000), "HH:mm")
              + "  " + (pev.app || pev.msg || pev.kind)
        }
        tipEvents.text = ptxt
        tipEvents.visible = ptxt.length > 0
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

  // Thin CPU/GPU temperature readout that shares the main graph's time domain,
  // so scrubbing/zooming the chart re-scopes it automatically via graph.domStart/domEnd.
  component TemperatureStrip: Canvas {
    id: ts
    property var pts: []
    property real domainStart: -1
    property real domainEnd: -1
    onPtsChanged: requestPaint()
    onDomainStartChanged: requestPaint()
    onDomainEndChanged: requestPaint()
    onWidthChanged: requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (ts.pts.length < 2 || ts.domainEnd <= ts.domainStart) return
      var leftPad = 8, rightPad = 8
      var plotW = width - leftPad - rightPad
      var minT = 1e9, maxT = -1e9
      for (var i = 0; i < ts.pts.length; i++) {
        minT = Math.min(minT, ts.pts[i].ctemp, ts.pts[i].gtemp)
        maxT = Math.max(maxT, ts.pts[i].ctemp, ts.pts[i].gtemp)
      }
      if (maxT <= minT) { minT -= 1; maxT += 1 }
      var spanT = ts.domainEnd - ts.domainStart

      function drawLine(key, color) {
        ctx.beginPath()
        var started = false
        for (var i = 0; i < ts.pts.length; i++) {
          var p = ts.pts[i]
          var x = leftPad + (p.ts - ts.domainStart) / spanT * plotW
          var y = height - 2 - (p[key] - minT) / (maxT - minT) * (height - 4)
          if (!started) { ctx.moveTo(x, y); started = true } else ctx.lineTo(x, y)
        }
        ctx.strokeStyle = color
        ctx.lineWidth = 1.5
        ctx.stroke()
      }
      drawLine("ctemp", root.accent)
      drawLine("gtemp", Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.5))

      ctx.fillStyle = root.dim2
      ctx.font = "8px " + root.contentFontFamily
      ctx.textAlign = "right"
      ctx.fillText(Math.round(maxT) + "°C", width - rightPad, 8)
      ctx.fillText(Math.round(minT) + "°C", width - rightPad, height - 2)
    }
  }
}
