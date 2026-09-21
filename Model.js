// Data parsing + formatting for OmaControl.
// Pure JS so it stays testable; all input is shell script JSON output.

.pragma library

// ---- formatting

function fmtPct(v) {
  if (!isFinite(v) || v < 0) return "--"
  return v.toFixed(1) + "%"
}

function fmtTemp(v) {
  if (!isFinite(v) || v <= 0) return "--"
  return Math.round(v) + "°C"
}

function fmtMem(mb) {
  if (!isFinite(mb) || mb < 0) return "--"
  if (mb >= 1024) return (mb / 1024).toFixed(1) + " GB"
  return Math.round(mb) + " MB"
}

function fmtMemShort(mb) {
  if (!isFinite(mb) || mb <= 0) return "-"
  if (mb >= 1024) return (mb / 1024).toFixed(1) + "G"
  return Math.round(mb) + "M"
}

function fmtRateShort(kbs) {
  if (!isFinite(kbs) || kbs <= 0) return "-"
  if (kbs >= 1024) return (kbs / 1024).toFixed(1) + "M"
  if (kbs < 1) return "<1K"
  return Math.round(kbs) + "K"
}

// ---- rate/size/time formatting (theme colors live in QML, not here) ----

// Compact one-token forms for the bar label.
function fmtPctShort(v) { return isFinite(v) && v >= 0 ? Math.round(v) + "%" : "--" }
function fmtTempShort(v) { return isFinite(v) && v > 0 ? Math.round(v) + "°" : "--" }
function fmtFreqShort(mhz) { return isFinite(mhz) && mhz > 0 ? (mhz >= 1000 ? (mhz / 1000).toFixed(2) + "G" : Math.round(mhz) + "M") : "--" }

function fmtRate(kbs) {
  if (!isFinite(kbs) || kbs < 0) return "--"
  if (kbs >= 1048576) return (kbs / 1048576).toFixed(1) + " GB/s"
  if (kbs >= 1024) return (kbs / 1024).toFixed(1) + " MB/s"
  return Math.round(kbs) + " KB/s"
}

function fmtUptime(secs) {
  if (!isFinite(secs) || secs < 0) return "--"
  var d = Math.floor(secs / 86400)
  var h = Math.floor((secs % 86400) / 3600)
  var m = Math.floor((secs % 3600) / 60)
  var out = ""
  if (d > 0) out += d + "d "
  if (h > 0) out += h + "h "
  out += m + "m"
  return out
}

// ---- aggregator helpers (used by the bar-stats catalog) ----

function netSumKbs(data, field) {
  if (!data || !data.nets) return 0
  var total = 0
  for (var i = 0; i < data.nets.length; i++) {
    total += data.nets[i][field] || 0
  }
  return total
}

function topDiskPct(data) {
  if (!data || !data.disks) return 0
  var top = 0
  for (var i = 0; i < data.disks.length; i++) {
    if (data.disks[i].pct > top) top = data.disks[i].pct
  }
  return top
}

function batteryPct(data) {
  if (!data || !data.battery || !data.battery.present) return 0
  return data.battery.percent
}

// ---- bar-stats catalog: every readable stat that can be shown in the bar
// icon label. Each entry returns a short one-token string for the label.
// The value functions return "--" when the stat isn't meaningful, which the
// label builder drops so only live values are shown.

function barStatsCatalog() {
  return [
    { id: "cpu",      label: "CPU",       value: function(d) { return fmtPctShort(d ? d.cpu_pct : -1) } },
    { id: "cputemp",  label: "CPU temp",  value: function(d) { return fmtTempShort(d ? d.cpu_temp : 0) } },
    { id: "cpufreq",  label: "CPU freq",  value: function(d) { return fmtFreqShort(d ? d.cpu_hz_mhz : 0) } },
    { id: "gpu",      label: "GPU",       value: function(d) { return fmtPctShort(d ? d.gpu_pct : -1) } },
    { id: "gputemp",  label: "GPU temp",  value: function(d) { return fmtTempShort(d ? d.gpu_temp : 0) } },
    { id: "gpuclock", label: "GPU clock", value: function(d) { return fmtFreqShort(d ? d.gpu_clock_mhz : 0) } },
    { id: "gpuram",   label: "GPU mem",   value: function(d) { return fmtMemShort(d ? d.gpu_mem_mb : 0) } },
    { id: "gpupwr",   label: "GPU power", value: function(d) { return isFinite(d && d.gpu_power_w) && d.gpu_power_w > 0 ? d.gpu_power_w.toFixed(0) + "W" : "--" } },
    { id: "ram",      label: "RAM",       value: function(d) { return fmtMemShort(d ? d.mem_used_mb : 0) } },
    { id: "rampct",   label: "RAM %",     value: function(d) { return d && d.mem_total_mb > 0 ? fmtPctShort(d.mem_used_mb / d.mem_total_mb * 100) : "--" } },
    { id: "swap",     label: "Swap",      value: function(d) { return fmtMemShort(d ? d.swap_used_mb : 0) } },
    { id: "load",     label: "Load",      value: function(d) { return d && isFinite(d.load_1) ? d.load_1.toFixed(1) : "--" } },
    { id: "dpct",     label: "Disk %",    value: function(d) { return fmtPctShort(topDiskPct(d)) } },
    { id: "down",     label: "Net ↓",     value: function(d) { var r = fmtRateShort(netSumKbs(d, "rx_kbs")); return r === "-" ? "0" : r } },
    { id: "up",       label: "Net ↑",     value: function(d) { var r = fmtRateShort(netSumKbs(d, "tx_kbs")); return r === "-" ? "0" : r } },
    { id: "procs",    label: "Processes", value: function(d) { return d ? String(d.proc_count) : "--" } },
    { id: "uptime",   label: "Uptime",    value: function(d) { return d ? fmtUptime(d.uptime_s) : "--" } },
    { id: "batt",     label: "Battery",   value: function(d) { return batteryPct(d) > 0 ? batteryPct(d) + "%" : "--" } }
  ]
}

function barStatById(id) {
  var cat = barStatsCatalog()
  for (var i = 0; i < cat.length; i++) {
    if (cat[i].id === id) return cat[i]
  }
  return null
}

// Value for a single selected stat id, or "" when it's not meaningful.
// Used by the bar label builder to drop dead values from multi-stat labels.
function barStatValue(data, id) {
  var entry = barStatById(id)
  if (!entry || !data) return ""
  var v = entry.value(data)
  return v && v !== "--" && v !== "-" ? v : ""
}

function barStatLabel(id) {
  var entry = barStatById(id)
  return entry ? entry.label : ""
}

// ---- alert detection
// Thresholds are read from the data itself (data.alert_thresholds — emitted
// by collect.sh / sample-json.sh from alert_prefs.json via backend/omc_prefs.py).
// The defaults below mirror that "medium" profile as a safety fallback so the
// bar keeps working even if a payload predates the thresholds field.

function alertThresholds(data) {
  if (data && data.alert_thresholds) return data.alert_thresholds
  return { cpu_pct: 90, cpu_temp: 85, gpu_temp: 85 }
}

function hasAlert(data) {
  if (!data) return false
  var th = alertThresholds(data)
  if (data.cpu_pct > th.cpu_pct) return true
  if (data.cpu_temp > th.cpu_temp) return true
  if (data.gpu_temp > th.gpu_temp) return true
  return false
}

function alertReason(data) {
  if (!data) return ""
  var th = alertThresholds(data)
  var reasons = []
  if (data.cpu_pct > th.cpu_pct) reasons.push("High CPU")
  if (data.cpu_temp > th.cpu_temp) reasons.push("CPU hot")
  if (data.gpu_temp > th.gpu_temp) reasons.push("GPU hot")
  return reasons.join(", ")
}

// ---- parse collect.sh output

function parseCollect(text) {
  try {
    return JSON.parse(text)
  } catch (e) {
    return null
  }
}

// ---- parse privacy.sh output

function parsePrivacy(text) {
  try {
    var obj = JSON.parse(text)
    return {
      devices: obj.devices || [],
      events: obj.events || []
    }
  } catch (e) {
    return { devices: [], events: [] }
  }
}

// ---- event kind styling (category color + glyph, shared by EventRow and
// EventDetailPanel so the list and the detail view always agree)

function eventTypeColor(kind) {
  if (!kind) return "#94a3b8"
  if (kind === "app_launch" || kind === "new_app") return "#22c55e" // green
  if (kind === "app_exit") return "#94a3b8" // gray
  if (kind === "cpu_spike" || kind === "mem_spike") return "#ef4444" // red
  if (kind === "mic_access" || kind === "cam_access" || kind === "location_access") return "#3b82f6" // blue
  if (kind === "publisher_block" || kind === "unsigned_launch" || kind === "unknown_app"
      || kind === "suspicious_app") return "#f59e0b" // amber
  if (kind.indexOf("user_") === 0) return "#8b5cf6" // purple
  return "#94a3b8"
}

function eventIcon(kind) {
  if (kind === "app_launch" || kind === "new_app") return "\uf00a"
  if (kind === "app_exit") return "\uf2d8"
  if (kind === "cpu_spike" || kind === "mem_spike") return "\uf496"
  if (kind === "mic_access" || kind === "cam_access" || kind === "location_access") return "\uf124"
  if (kind === "publisher_block" || kind === "unsigned_launch" || kind === "unknown_app"
      || kind === "suspicious_app") return "\uf132"
  if (kind.indexOf("user_") === 0) return "\uf013"
  return "\uf0c3"
}

// ---- time formatting

function fmtTimeAgo(ts) {
  if (!ts) return ""
  var diff = Math.floor(Date.now() / 1000) - ts
  if (diff < 60) return diff + "s ago"
  if (diff < 3600) return Math.floor(diff / 60) + "m ago"
  if (diff < 86400) return Math.floor(diff / 3600) + "h ago"
  return Math.floor(diff / 86400) + "d ago"
}

function fmtClock(ts) {
  if (!ts) return ""
  var d = new Date(ts * 1000)
  var h = d.getHours()
  var m = d.getMinutes()
  return (h < 10 ? "0" + h : h) + ":" + (m < 10 ? "0" + m : m)
}

// ---- history helpers for chart

function filterHistory(history, windowSecs) {
  if (!history || history.length === 0) return []
  var now = Math.floor(Date.now() / 1000)
  var cutoff = now - windowSecs
  var out = []
  for (var i = 0; i < history.length; i++) {
    if (history[i].ts >= cutoff) out.push(history[i])
  }
  return out
}

function maxField(history, field) {
  var m = 0
  for (var i = 0; i < history.length; i++) {
    var v = history[i][field]
    if (v > m) m = v
  }
  return m
}

// ---- kill confirmation label

function killLabel(proc) {
  if (!proc) return ""
  return "Kill " + proc.name + " (PID " + proc.pid + ")?"
}
