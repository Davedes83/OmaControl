// Data parsing + formatting for OmControl.
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

function fmtMemPct(used, total) {
  if (!isFinite(used) || !isFinite(total) || total <= 0) return "--"
  return ((used / total) * 100).toFixed(1) + "%"
}

function fmtGpuMem(mb) {
  if (!isFinite(mb) || mb <= 0) return "--"
  return Math.round(mb) + " MiB"
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

function fmtPower(watts) {
  if (!isFinite(watts) || watts <= 0) return "--"
  if (watts >= 100) return Math.round(watts) + " W"
  return watts.toFixed(1) + " W"
}

function fmtFreq(mhz) {
  if (!isFinite(mhz) || mhz <= 0) return "--"
  if (mhz >= 1000) return (mhz / 1000).toFixed(2) + " GHz"
  return Math.round(mhz) + " MHz"
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
    { id: "load",     label: "Load",      value: function(d) { return d ? d.load_1.toFixed(1) : "--" } },
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

// ---- Mission Center-style device info rows --------------------------------
// Each builder returns [{label, value}] key/value pairs for the overview
// dropdown cards. Values are already formatted for display.

function gpuInfoRows(d) {
  if (!d) return []
  var rows = []
  if (d.gpu_name) rows.push({ label: "Name", value: d.gpu_name })
  if (d.gpu_driver) rows.push({ label: "Driver", value: d.gpu_driver })
  rows.push({ label: "Utilization", value: fmtPct(d.gpu_pct) })
  rows.push({ label: "Clock Speed",
    value: fmtFreq(d.gpu_clock_mhz) + " / " + fmtFreq(d.gpu_graphics_max_mhz) })
  rows.push({ label: "Power Draw",
    value: fmtPowerNice(d.gpu_power_w) + " / " + fmtPowerNice(d.gpu_power_max_w) })
  rows.push({ label: "Memory Usage",
    value: fmtGpuMem(d.gpu_mem_mb) + " / " + fmtMemNice(d.gpu_mem_total_mb) })
  rows.push({ label: "Memory Speed",
    value: fmtFreq(d.gpu_mem_clock_mhz) + " / " + fmtFreq(d.gpu_mem_clock_max_mhz) })
  rows.push({ label: "Video encode",
    value: fmtPct(d.gpu_enc_pct !== undefined ? d.gpu_enc_pct : 0) })
  rows.push({ label: "Video decode",
    value: fmtPct(d.gpu_dec_pct !== undefined ? d.gpu_dec_pct : 0) })
  rows.push({ label: "Temperature", value: fmtTemp(d.gpu_temp) })
  rows.push({ label: "PCI Express speed",
    value: "PCIe Gen " + (d.gpu_link_gen || 0) + " x" + (d.gpu_link_width || "?") })
  rows.push({ label: "Max PCI Express speed",
    value: "PCIe Gen " + (d.gpu_link_gen_max || 0) + " x" + (d.gpu_link_width_max || "?") })
  if (d.gpu_bus) rows.push({ label: "PCI bus address", value: d.gpu_bus })
  return rows
}

function cpuInfoRows(d) {
  if (!d) return []
  var rows = []
  if (d.cpu_name) rows.push({ label: "Name", value: d.cpu_name })
  rows.push({ label: "Utilization", value: fmtPct(d.cpu_pct) })
  rows.push({ label: "Clock Speed",
    value: fmtFreq(d.cpu_hz_mhz) + " / " + fmtFreq(d.cpu_max_mhz) })
  if (d.cpu_cores > 0) rows.push({ label: "Cores",
    value: d.cpu_cores + " / " + (d.cpu_threads || d.cpu_cores) + " threads" })
  rows.push({ label: "Temperature", value: fmtTemp(d.cpu_temp) })
  rows.push({ label: "Load (1m / 5m / 15m)",
    value: (d.load_1 || 0).toFixed(2) + "  /  " + (d.load_5 || 0).toFixed(2) + "  /  " + (d.load_15 || 0).toFixed(2) })
  return rows
}

function memInfoRows(d) {
  if (!d) return []
  var rows = []
  rows.push({ label: "Total", value: fmtMemNice(d.mem_total_mb) })
  rows.push({ label: "Used", value: fmtMem(d.mem_used_mb) + "  (" + fmtMemPct(d.mem_used_mb, d.mem_total_mb) + ")" })
  rows.push({ label: "Available", value: fmtMem(d.mem_avail_mb) })
  rows.push({ label: "Free", value: fmtMem(d.mem_free_mb) })
  rows.push({ label: "Cached", value: fmtMem(d.mem_cached_mb) })
  rows.push({ label: "Buffers", value: fmtMem(d.mem_buffers_mb) })
  rows.push({ label: "Swap", value: fmtMem(d.swap_used_mb) + "  (" + fmtMemPct(d.swap_used_mb, d.swap_total_mb) + ")" })
  return rows
}

function diskInfoRows(d) {
  if (!d || !d.disks) return []
  var rows = []
  for (var i = 0; i < d.disks.length; i++) {
    var disk = d.disks[i]
    rows.push({ label: disk.mount + "  (" + disk.dev + ")",
      value: disk.used_gb.toFixed(0) + "G / " + disk.size_gb.toFixed(0) + "G   ·   " + disk.pct.toFixed(0) + "%" })
    rows.push({ label: "I/O",
      value: "↓" + fmtRate(disk.read_kbs) + "   ↑" + fmtRate(disk.write_kbs) })
  }
  return rows
}

function netInfoRows(d) {
  if (!d || !d.nets) return []
  var rows = []
  for (var i = 0; i < d.nets.length; i++) {
    var n = d.nets[i]
    if (n.rx_kbs === 0 && n.tx_kbs === 0) continue
    rows.push({ label: n.iface,
      value: "↓" + fmtRate(n.rx_kbs) + "   ↑" + fmtRate(n.tx_kbs) })
  }
  return rows
}

function sysInfoRows(d) {
  if (!d) return []
  var rows = []
  if (d.os_pretty) rows.push({ label: "OS", value: d.os_pretty })
  if (d.host) rows.push({ label: "Host", value: d.host })
  if (d.kernel) rows.push({ label: "Kernel", value: d.kernel })
  rows.push({ label: "Uptime", value: fmtUptime(d.uptime_s) })
  rows.push({ label: "Processes", value: String(d.proc_count) })
  return rows
}

function battInfoRows(d) {
  if (!d || !d.battery || !d.battery.present) return []
  var rows = []
  var b = d.battery
  if (b.model) rows.push({ label: "Model", value: b.model })
  rows.push({ label: "Charge", value: b.percent + "%" })
  if (b.status) rows.push({ label: "Status", value: b.status })
  rows.push({ label: "Power", value: fmtPower(b.power_w) })
  return rows
}

function deviceInfoRows(device, d) {
  switch (device) {
    case "cpu": return cpuInfoRows(d)
    case "mem": return memInfoRows(d)
    case "gpu": return gpuInfoRows(d)
    case "disks": return diskInfoRows(d)
    case "net": return netInfoRows(d)
    case "sys": return sysInfoRows(d)
    case "batt": return battInfoRows(d)
  }
  return []
}

function fmtPowerNice(w) {
  if (!isFinite(w) || w <= 0) return "--"
  return (w < 10 ? w.toFixed(2) : w.toFixed(1)) + " W"
}

function fmtMemNice(mb) {
  if (!isFinite(mb) || mb <= 0) return "--"
  if (mb >= 1024) return (mb / 1024).toFixed(2) + " GiB"
  return Math.round(mb) + " MiB"
}

// ---- alert detection

function hasAlert(data) {
  if (!data) return false
  if (data.cpu_pct > 90) return true
  if (data.cpu_temp > 85) return true
  if (data.gpu_temp > 85) return true
  return false
}

function alertReason(data) {
  if (!data) return ""
  var reasons = []
  if (data.cpu_pct > 90) reasons.push("High CPU")
  if (data.cpu_temp > 85) reasons.push("CPU hot")
  if (data.gpu_temp > 85) reasons.push("GPU hot")
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
