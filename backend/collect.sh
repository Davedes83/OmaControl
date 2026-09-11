#!/bin/sh
# OmControl data collector — outputs a single JSON blob with system metrics.
# Called via Quickshell Process{} every 2s.
#
# All rate meters (CPU, per-core CPU, disk IO, network) share one 0.2s
# sampling window so the script stays cheap.

DATA_DIR="${OMCONTROL_DATA_DIR:-$HOME/.local/share/omcontrol}"
mkdir -p "$DATA_DIR"
DB="${OMCONTROL_DB:-$DATA_DIR/history.db}"
NOW=$(date +%s)

# Prune stale temp files from past invocations that got killed mid-run.
find "$DATA_DIR" -maxdepth 1 -name '.omc_*' -mmin +30 -delete 2>/dev/null

# --- Alert preferences (shared with the Alerts tab; imported by app-action.sh) ---
ALERT_PREFS="${OMCONTROL_ALERT_PREFS:-$DATA_DIR/alert_prefs.json}"
ALERTS_ENABLED=1
pref_enabled() {
  [ -f "$ALERT_PREFS" ] || { echo 1; return; }
  python3 - "$ALERT_PREFS" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(1 if d.get("enabled", True) else 0)
except Exception:
    print(1)
PY
}
pref_on() {
  [ -f "$ALERT_PREFS" ] || { echo 1; return; }
  python3 - "$ALERT_PREFS" "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(1 if d.get("types", {}).get(sys.argv[2], False) else 0)
except Exception:
    print(0)
PY
}
ALERTS_ENABLED=$(pref_enabled)

# --- Ensure DB exists ---
if [ ! -f "$DB" ]; then
  sqlite3 -cmd ".timeout 1500" "$DB" "CREATE TABLE IF NOT EXISTS metrics (
    ts INTEGER PRIMARY KEY,
    cpu_pct REAL,
    mem_used_mb INTEGER,
    mem_total_mb INTEGER,
    gpu_pct REAL,
    gpu_mem_mb INTEGER,
    gpu_temp INTEGER,
    cpu_temp INTEGER,
    proc_count INTEGER
  );
  CREATE INDEX IF NOT EXISTS idx_metrics_ts ON metrics(ts);"
fi

# Per-process snapshots (for chart drill-down). Idempotent; existing DBs need it.
sqlite3 -cmd ".timeout 1500" "$DB" "CREATE TABLE IF NOT EXISTS proc_history (
  ts INTEGER PRIMARY KEY,
  procs TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_proc_history_ts ON proc_history(ts);
CREATE TABLE IF NOT EXISTS app_meta (
  name TEXT PRIMARY KEY, exe TEXT, pkg TEXT, publisher TEXT,
  desc TEXT, verified INTEGER DEFAULT 0, source TEXT DEFAULT 'unknown',
  first_seen INTEGER, updated INTEGER
);
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER, type TEXT, app TEXT, publisher TEXT, msg TEXT, read INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);" 2>/dev/null

# Add disk usage column to metrics if missing (in place, idempotent).
sqlite3 -cmd ".timeout 1500" "$DB" "ALTER TABLE metrics ADD COLUMN disk_pct REAL;" 2>/dev/null || true
sqlite3 -cmd ".timeout 1500" "$DB" "ALTER TABLE metrics ADD COLUMN net_rx_bytes INTEGER;" 2>/dev/null || true
sqlite3 -cmd ".timeout 1500" "$DB" "ALTER TABLE metrics ADD COLUMN net_tx_bytes INTEGER;" 2>/dev/null || true

D="$DATA_DIR"
CPU_PRE="$D/.omc_cpu_pre.$$"
CPU_POST="$D/.omc_cpu_post.$$"
DS_PRE="$D/.omc_disk_pre.$$"
DS_POST="$D/.omc_disk_post.$$"
NET_PRE="$D/.omc_net_pre.$$"
NET_POST="$D/.omc_net_post.$$"
DISKIO="$D/.omc_diskio.$$"
DF_FILE="$D/.omc_df.$$"
PS_FILE="$D/.omc_ps.$$"
PROC_IO_PRE="$D/.omc_proc_io_pre.$$"
PROC_IO_POST="$D/.omc_proc_io_post.$$"
PROC_SWAP="$D/.omc_proc_swap.$$"
TMPFILES="$CPU_PRE $CPU_POST $DS_PRE $DS_POST $NET_PRE $NET_POST $DISKIO $DF_FILE $PS_FILE $PROC_IO_PRE $PROC_IO_POST $PROC_SWAP"
trap 'rm -f $TMPFILES' EXIT INT TERM

# --- Top 20 processes by CPU (snapshot once; used for per-proc IO + swap) ---
ps -eo pid,pcpu,pmem,comm --sort=-pcpu --no-headers | head -20 > "$PS_FILE"

# --- Per-process I/O baseline (read+write bytes) so the same 0.2s window
#     below yields live accumulated KB/s for each process. ---
PROC_IO_AWK='{
  f="/proc/"$1"/io"; r=0; w=0
  while ((getline l < f) > 0) {
    if (l ~ /^read_bytes:/)  { split(l, a, " "); r = a[2] + 0 }
    else if (l ~ /^write_bytes:/) { split(l, a, " "); w = a[2] + 0 }
  }
  close(f)
  print $1, r, w
}'
awk "$PROC_IO_AWK" "$PS_FILE" > "$PROC_IO_PRE"

# --- Swap per process (VmSwap in kB) ---
awk '{ f="/proc/"$1"/status"; s=0; while ((getline l < f) > 0) { if (l ~ /^VmSwap:/) { match(l, /^VmSwap: *[0-9]+/); s=substr(l,RLENGTH)+0; break } } close(f); print $1, s }' "$PS_FILE" > "$PROC_SWAP"

# --- Sample capture (one 0.2s window for all deltas) ---
awk '/^cpu /{print "cpu", $5+$6, $2+$3+$4+$5+$6+$7+$8; next}
     /^cpu[0-9]+ /{sub("cpu","",$1); print $1, $5+$6, $2+$3+$4+$5+$6+$7+$8}' /proc/stat > "$CPU_PRE"
awk '{print $3, $6, $10}' /proc/diskstats > "$DS_PRE"
awk 'NR>2{sub(":","",$1); print $1, $2, $10}' /proc/net/dev > "$NET_PRE"

sleep 0.2

awk '/^cpu /{print "cpu", $5+$6, $2+$3+$4+$5+$6+$7+$8; next}
     /^cpu[0-9]+ /{sub("cpu","",$1); print $1, $5+$6, $2+$3+$4+$5+$6+$7+$8}' /proc/stat > "$CPU_POST"
awk '{print $3, $6, $10}' /proc/diskstats > "$DS_POST"
awk 'NR>2{sub(":","",$1); print $1, $2, $10}' /proc/net/dev > "$NET_POST"

# --- Per-process I/O post (accumulated) ---
awk "$PROC_IO_AWK" "$PS_FILE" > "$PROC_IO_POST"

# --- Aggregate CPU usage ---
set -- $(awk '$1=="cpu"{print $2,$3}' "$CPU_PRE"); PREV_IDLE=$1; PREV_TOTAL=$2
set -- $(awk '$1=="cpu"{print $2,$3}' "$CPU_POST"); CURR_IDLE=$1; CURR_TOTAL=$2
IDLE_DIFF=$((CURR_IDLE - PREV_IDLE))
TOTAL_DIFF=$((CURR_TOTAL - PREV_TOTAL))
if [ "$TOTAL_DIFF" -gt 0 ]; then
  CPU_PCT=$(awk "BEGIN{printf \"%.1f\", (1 - $IDLE_DIFF / $TOTAL_DIFF) * 100}")
else
  CPU_PCT="0.0"
fi

# --- Per-core CPU ---
CORES_LIST=$(awk 'NR==FNR { idle[$1]=$2; tot[$1]=$3; next }
  $1 != "cpu" {
    i = $2 - idle[$1]; t = $3 - tot[$1];
    if (t > 0) pct = (1 - i / t) * 100; else pct = 0;
    printf "{\"id\":%d,\"pct\":%.1f},", $1, pct
  }' "$CPU_PRE" "$CPU_POST")
if [ -n "$CORES_LIST" ]; then
  CORES="[${CORES_LIST%,}]"
else
  CORES="[]"
fi

# --- Load average ---
LOAD_1=$(awk '{print $1}' /proc/loadavg)
LOAD_5=$(awk '{print $2}' /proc/loadavg)
LOAD_15=$(awk '{print $3}' /proc/loadavg)

# --- CPU frequency (current) ---
CPU_HZ=""
if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
  CPU_HZ=$(awk '{printf "%d", $1/1000}' /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)
fi
if [ -z "$CPU_HZ" ]; then
  CPU_HZ=$(awk 'NR<=32 && $1=="cpu" && $2=="MHz" {printf "%d", $4; exit}' /proc/cpuinfo 2>/dev/null)
fi
CPU_HZ=${CPU_HZ:-0}

# --- Uptime ---
UPTIME_S=$(awk '{printf "%d", $1}' /proc/uptime)

# --- Memory + swap ---
MEM_TOTAL_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
MEM_AVAIL_KB=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
MEM_FREE_KB=$(awk '/^MemFree:/{print $2}' /proc/meminfo)
MEM_BUFFERS_KB=$(awk '/^Buffers:/{print $2}' /proc/meminfo)
MEM_CACHED_KB=$(awk '/^Cached:/{print $2}' /proc/meminfo)
SWAP_TOTAL_KB=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
SWAP_FREE_KB=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
MEM_USED_KB=$((MEM_TOTAL_KB - MEM_AVAIL_KB))
MEM_USED_MB=$((MEM_USED_KB / 1024))
MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))
MEM_FREE_MB=$((MEM_FREE_KB / 1024))
MEM_AVAIL_MB=$((MEM_AVAIL_KB / 1024))
MEM_CACHED_MB=$((MEM_CACHED_KB / 1024))
MEM_BUFFERS_MB=$((MEM_BUFFERS_KB / 1024))
SWAP_TOTAL_MB=$((SWAP_TOTAL_KB / 1024))
SWAP_USED_MB=$(((SWAP_TOTAL_KB - SWAP_FREE_KB) / 1024))

# --- CPU temperature ---
CPU_TEMP=""
for zone in /sys/class/thermal/thermal_zone*/temp; do
  TYPE=$(echo "$zone" | sed 's|/temp||;s|.*/||')
  if [ "$TYPE" = "x86_pkg_temp" ] || [ -z "$CPU_TEMP" ]; then
    RAW=$(cat "$zone" 2>/dev/null)
    if [ -n "$RAW" ]; then
      CPU_TEMP=$((RAW / 1000))
    fi
  fi
done
CPU_TEMP=${CPU_TEMP:-0}

# --- Disk IO rates (bytes->KB/s) + df usage ---
awk 'NR==FNR { r[$1]=$2; w[$1]=$3; next }
  { if (!($1 in r)) { r[$1]=$2; w[$1]=$3; next }
    dr=($2-r[$1])*512*5/1024; dw=($3-w[$1])*512*5/1024;
    if (dr<0) dr=0; if (dw<0) dw=0;
    printf "%s %.1f %.1f\n", $1, dr, dw }' "$DS_PRE" "$DS_POST" > "$DISKIO"

df -P > "$DF_FILE" 2>/dev/null
DISKS=""
DISK_MAX_PCT=0
while read -r fs blk used avail pct mount; do
  [ "$fs" = "Filesystem" ] && continue
  case "$fs" in
    /dev/*) ;;
    *) continue ;;
  esac
  [ "$blk" -gt 0 ] || continue
  case "$mount" in
    /*) ;;
    *) continue ;;
  esac
  dev=$(echo "$fs" | sed 's|^/dev/||')
  total_gb=$(awk "BEGIN{printf \"%.1f\", $blk/1048576}")
  used_gb=$(awk "BEGIN{printf \"%.1f\", $used/1048576}")
  pctv=$(awk "BEGIN{printf \"%.1f\", $used*100/$blk}")
  set -- $(awk -v d="$dev" '$1==d{print $2, $3}' "$DISKIO")
  rk=${1:-0}; wk=${2:-0}
  DISKS="$DISKS{\"dev\":\"$dev\",\"mount\":\"$mount\",\"size_gb\":$total_gb,\"used_gb\":$used_gb,\"pct\":$pctv,\"read_kbs\":$rk,\"write_kbs\":$wk},"
  # Report the busiest real filesystem as the overall "Disk" metric.
  OLDIFS=$IFS; IFS=.; set -- $pctv; IFS=$OLDIFS
  DISK_PCT_INT=$1
  [ "$DISK_PCT_INT" -gt "$DISK_MAX_PCT" ] && DISK_MAX_PCT=$DISK_PCT_INT
done < "$DF_FILE"
if [ -n "$DISKS" ]; then
  DISKS="[${DISKS%,}]"
else
  DISKS="[]"
fi

# --- Network rates (KB/s per interface, excl. loopback) ---
NETS=$(awk 'NR==FNR { rx[$1]=$2; tx[$1]=$3; next }
  { if ($1=="lo") next
    if (!($1 in rx)) { rx[$1]=$2; tx[$1]=$3; next }
    r=($2-rx[$1])*5/1024; t=($3-tx[$1])*5/1024;
    if (r<0) r=0; if (t<0) t=0;
    printf "{\"iface\":\"%s\",\"rx_kbs\":%.1f,\"tx_kbs\":%.1f},", $1, r, t }' \
  "$NET_PRE" "$NET_POST")
if [ -n "$NETS" ]; then
  NETS="[${NETS%,}]"
else
  NETS="[]"
fi

# Cumulative rx/tx bytes across all non-loopback interfaces (for history rolls).
set -- $(awk '$1!="lo"{r+=$2; t+=$3} END{print r+0, t+0}' "$NET_POST")
NET_TOT_RX=$1
NET_TOT_TX=$2
[ -z "$NET_TOT_RX" ] && NET_TOT_RX=0
[ -z "$NET_TOT_TX" ] && NET_TOT_TX=0

# --- GPU (nvidia-smi) ---
GPU_PCT="0"
GPU_MEM="0"
GPU_MEM_TOTAL="0"
GPU_TEMP="0"
GPU_POWER="0"
GPU_FAN="0"
GPU_CLOCK="0"
GPU_NAME=""
GPU_DRIVER=""
GPU_POWER_MAX="0"
GPU_MEM_CLOCK="0"
GPU_GRAPHICS_CLOCK="0"
GPU_LINK_GEN=""
GPU_LINK_GEN_MAX=""
GPU_LINK_WIDTH=""
GPU_LINK_WIDTH_MAX=""
GPU_BUS=""
GPU_ENC="0"
GPU_DEC="0"
GPU_MEM_CLOCK_MAX="0"
if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_LINE=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,fan.speed,clocks.sm,utilization.encoder,utilization.decoder --format=csv,noheader,nounits 2>/dev/null | sed 's/\[N\/A\]/0/g' | tail -1)
  if [ -n "$GPU_LINE" ]; then
    GPU_PCT=$(echo "$GPU_LINE" | awk -F',' '{gsub(/ /,"",$1); print $1}')
    GPU_MEM=$(echo "$GPU_LINE" | awk -F',' '{gsub(/ /,"",$2); print $2}')
    GPU_MEM_TOTAL=$(echo "$GPU_LINE" | awk -F',' '{gsub(/ /,"",$3); print $3}')
    GPU_TEMP=$(echo "$GPU_LINE" | awk -F',' '{gsub(/ /,"",$4); print $4}')
    GPU_POWER=$(echo "$GPU_LINE" | awk -F',' '{gsub(/ /,"",$5); print $5}')
    GPU_FAN=$(echo "$GPU_LINE" | awk -F',' '{gsub(/ /,"",$6); print $6}')
    GPU_CLOCK=$(echo "$GPU_LINE" | awk -F',' '{gsub(/ /,"",$7); print $7}')
    GPU_ENC=$(echo "$GPU_LINE" | awk -F',' '{gsub(/ /,"",$8); print $8}')
    GPU_DEC=$(echo "$GPU_LINE" | awk -F',' '{gsub(/ /,"",$9); print $9}')
    GPU_SMI_XML=$(nvidia-smi -q -x 2>/dev/null)
    if [ -n "$GPU_SMI_XML" ]; then
      GPU_NAME=$(echo "$GPU_SMI_XML" | sed -n '0,/<product_name>/s/.*<product_name>\([^<]*\)<\/product_name>.*/\1/p')
      GPU_DRIVER=$(echo "$GPU_SMI_XML" | sed -n '0,/<driver_version>/s/.*<driver_version>\([^<]*\)<\/driver_version>.*/\1/p')
      GPU_POWER_MAX=$(echo "$GPU_SMI_XML" | sed -n '0,/<max_power_limit>/s/.*<max_power_limit>\([0-9.]*\).*/\1/p')
      GPU_LINK_GEN=$(echo "$GPU_SMI_XML" | sed -n '0,/<current_link_gen>/s/.*<current_link_gen>\([0-9]*\).*/\1/p')
      GPU_LINK_GEN_MAX=$(echo "$GPU_SMI_XML" | sed -n '0,/<max_link_gen>/s/.*<max_link_gen>\([0-9]*\).*/\1/p')
      GPU_LINK_WIDTH=$(echo "$GPU_SMI_XML" | sed -n '0,/<current_link_width>/s/.*<current_link_width>\([0-9]*\)x.*/\1/p')
      GPU_LINK_WIDTH_MAX=$(echo "$GPU_SMI_XML" | sed -n '0,/<max_link_width>/s/.*<max_link_width>\([0-9]*\)x.*/\1/p')
      GPU_BUS=$(echo "$GPU_SMI_XML" | sed -n '0,/<pci_bus_id>/s/.*<pci_bus_id>00000000:\([0-9a-f]*:[0-9a-f]*\.[0-9]*\)<\/pci_bus_id>.*/0000:\1/p')
      GPU_ENC=$(echo "$GPU_SMI_XML" | awk '/<encoder_stats>/{sec=1} sec && /<session_count>/{gsub(/[^0-9]/,""); print; exit} /<\/encoder_stats>/{sec=0}')
      # Clocks: current from <clocks>, max from <max_clocks> — pull within section
      GPU_MEM_CLOCK=$(echo "$GPU_SMI_XML" | awk '
        /<clocks>/ {sec="cur"} /<\/clocks>/ {sec=""; next}
        /<max_clocks>/ {sec="max"} /<\/max_clocks>/ {sec=""; next}
        /<min_clocks>/ {sec="min"} /<\/min_clocks>/ {sec=""; next}
        sec=="cur" && /<mem_clock>/ {gsub(/[^0-9]/,""); print; exit}')
      GPU_MEM_CLOCK_MAX=$(echo "$GPU_SMI_XML" | awk '
        /<max_clocks>/ {sec="max"; next} /<\/max_clocks>/ {sec=""; next}
        sec=="max" && /<mem_clock>/ {gsub(/[^0-9]/,""); print; exit}')
      GPU_GRAPHICS_CLOCK=$(echo "$GPU_SMI_XML" | awk '
        /<max_clocks>/ {sec="max"; next} /<\/max_clocks>/ {sec=""; next}
        sec=="max" && /<graphics_clock>/ {gsub(/[^0-9]/,""); print; exit}')
    fi
    unset GPU_SMI_XML
  fi
fi

# --- CPU identity ---
CPU_NAME=$(sed -n 's/^model name[[:space:]]*: *//p' /proc/cpuinfo | head -1 | tr -d '\r')
CPU_THREADS=$(grep -m1 '^siblings' /proc/cpuinfo | awk '{print $3}' 2>/dev/null)
CPU_CORES=$(grep -m1 '^cpu cores' /proc/cpuinfo | awk '{print $4}' 2>/dev/null)
CPU_MAX_MHZ=$(awk '{printf "%d", $1/1000}' /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo 0)

# --- Battery ---
BAT_PRESENT=0
BAT_PCT=0
BAT_STATUS=""
BAT_POWER_W=0
BAT_MODEL=""
for f in /sys/class/power_supply/BAT*/uevent; do
  [ -e "$f" ] || continue
  BAT_PRESENT=1
  BAT_PCT=$(grep -m1 '^POWER_SUPPLY_CAPACITY=' "$f" | cut -d= -f2)
  BAT_STATUS=$(grep -m1 '^POWER_SUPPLY_STATUS=' "$f" | cut -d= -f2)
  BAT_POWER=$(grep -m1 '^POWER_SUPPLY_POWER_NOW=' "$f" | cut -d= -f2)
  BAT_MODEL=$(grep -m1 '^POWER_SUPPLY_MODEL_NAME=' "$f" | cut -d= -f2)
  break
done
BAT_PCT=$(echo "$BAT_PCT" | tr -cd '0-9')
[ -z "$BAT_PCT" ] && BAT_PCT=0
BAT_POWER=$(echo "$BAT_POWER" | tr -cd '0-9')
if [ -n "$BAT_POWER" ]; then
  BAT_POWER_W=$(awk "BEGIN{printf \"%.1f\", $BAT_POWER/1000000}")
fi
BAT_POWER_W=${BAT_POWER_W:-0}

# --- System identity ---
HOST=$(hostname)
KERNEL=$(uname -r)
OS_PRETTY=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2 | head -1)

# --- Process count ---
PROC_COUNT=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l)

# --- Top 20 processes by CPU (with per-process GPU memory % if available) ---
GPU_PROC_MAP="$D/.omc_gpu_proc.$$"
TMPFILES="$TMPFILES $GPU_PROC_MAP"
# nvidia-smi only lists compute contexts via --query-compute-apps (usually
# empty), so parse the XML process table which includes graphical processes.
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi -q -x 2>/dev/null | awk '
    /<process_info>/ { inproc=1 }
    inproc && /<pid>/ { gsub(/[^0-9]/, "", $0); pidname=$0 }
    inproc && /<used_memory>/ {
      gsub(/[^0-9]/, "", $0); mem=$0
      if (pidname != "") { print pidname, mem }
      inproc=0
    }
  ' > "$GPU_PROC_MAP"
fi

# --- Per-process disk I/O rate (KB/s, from the 0.2s window) ---
PROC_IO_RATE="$D/.omc_proc_io_rate.$$"
TMPFILES="$TMPFILES $PROC_IO_RATE"
awk 'NR==FNR { r[$1]=$2; w[$1]=$3; next }
  { rr = ($2 - r[$1]) * 5 / 1024; ww = ($3 - w[$1]) * 5 / 1024
    if (rr < 0) rr = 0; if (ww < 0) ww = 0
    print $1, (rr + ww) }' "$PROC_IO_PRE" "$PROC_IO_POST" > "$PROC_IO_RATE"

PROCS=$(awk '
  FILENAME == gpumap { gpu[$1]=$2; next }
  FILENAME == swapmap { swap[$1]=$2; next }
  FILENAME == ratemap { rate[$1]=$2; next }
  {
    gsub(/[<>\x00-\x1F\x7F]/, " ", $4)
    g = ($1 in gpu) ? gpu[$1] : 0
    gpct = (g > 0 && gpu_total > 0) ? g * 100 / gpu_total : 0
    swm = ($1 in swap) ? swap[$1] / 1024 : 0
    ior = ($1 in rate) ? rate[$1] : 0
    printf "{\"pid\":%s,\"cpu\":%s,\"mem\":%s,\"swap\":%.1f,\"io_kbs\":%.1f,\"gpu_mem\":%.0f,\"gpu\":%.1f,\"name\":\"%s\"}%s",
      $1, $2, $3, swm, ior, g, gpct, $4, (++n < 20 ? "," : "")
  }' gpumap="$GPU_PROC_MAP" swapmap="$PROC_SWAP" ratemap="$PROC_IO_RATE" \
  gpu_total="$GPU_MEM_TOTAL" "$GPU_PROC_MAP" "$PROC_SWAP" "$PROC_IO_RATE" "$PS_FILE")

# --- Store sample in DB ---
sqlite3 -cmd ".timeout 1500" "$DB" "INSERT OR REPLACE INTO metrics (ts, cpu_pct, mem_used_mb, mem_total_mb, gpu_pct, gpu_temp, cpu_temp, proc_count, disk_pct, net_rx_bytes, net_tx_bytes) VALUES ($NOW, $CPU_PCT, $MEM_USED_MB, $MEM_TOTAL_MB, $GPU_PCT, $GPU_TEMP, $CPU_TEMP, $PROC_COUNT, $DISK_MAX_PCT, $NET_TOT_RX, $NET_TOT_TX);"

# --- Persist per-process snapshot once per minute (chart drill-down) + refresh
#     app metadata (publisher/verified/desc; cached in app_meta) ---
PROC_MIN=$((NOW / 60))
LAST_PROCMIN=$(cat "$DATA_DIR/.omc_proc_min" 2>/dev/null || echo 0)
if [ "$PROC_MIN" -gt "$LAST_PROCMIN" ]; then
  PROC_TS=$((PROC_MIN * 60))
  PROC_JSON="[$PROCS]"
  PROC_JSON_SQL=$(echo "$PROC_JSON" | sed "s/'/''/g")
  sqlite3 -cmd ".timeout 1500" "$DB" "INSERT OR REPLACE INTO proc_history VALUES ($PROC_TS, '$PROC_JSON_SQL');" 2>/dev/null
  awk '{print $1, $4}' "$PS_FILE" | OMCONTROL_DB="$DB" python3 "$(dirname "$0")/app-meta.py" 2>/dev/null
  # App-exit events: names in last minute's snapshot that are gone now
  # (only "real" apps: resolved to a package/core, never ephemeral shells).
  ps -eo comm --no-headers 2>/dev/null | sed 's/[[:space:]]*$//' \
    | grep -vE '^(sh|bash|zsh|dash|fish|ps|pgrep|grep|awk|sed|sleep|cat|head|tail|true|false|tee|sort|uniq|comm|notify-send|xargs|find|rm|cp|mv|mkdir|dirname|basename|logout|timeout|omcontrol-poll|sd_notify)$' \
    | sort -u > "$DATA_DIR/.cur_names_min.$$"
  if [ -f "$DATA_DIR/.last_names_min" ]; then
    while IFS= read -r nm; do
      [ -z "$nm" ] && continue
      grep -qx "$nm" "$DATA_DIR/.cur_names_min.$$" && continue
      PUB=$(sqlite3 -cmd ".timeout 1500" "$DB" "SELECT publisher||'|'||pkg FROM app_meta WHERE name='${nm%$'\r'}' COLLATE BINARY;" 2>/dev/null | head -1)
      PUB=$(echo "$PUB" | tr -d '\r')
      if [ -n "$PUB" ] && [ "$PUB" != "Unknown|" ]; then
        printf "INSERT INTO events (ts, type, app, publisher, msg) VALUES ($PROC_TS, 'app_exit', '%s', '%s', 'App closed: %s');\n" \
          "${nm}" "${PUB%%|*}" "${nm}" | sqlite3 -cmd ".timeout 1500" "$DB" 2>/dev/null
      fi
    done < "$DATA_DIR/.last_names_min"
  fi
  mv "$DATA_DIR/.cur_names_min.$$" "$DATA_DIR/.last_names_min"
  echo "$PROC_MIN" > "$DATA_DIR/.omc_proc_min"
fi

# --- History: downsampled averages for chart ---
HISTORY_1H=$(sqlite3 -cmd ".timeout 1500" "$DB" "
  SELECT '[' || group_concat(json_object('ts', ts, 'cpu', cpu, 'mem', mem, 'gpu', gpu, 'gtemp', gtemp, 'ctemp', ctemp)) || ']'
  FROM (SELECT (ts/60)*60 as ts, avg(cpu_pct) as cpu, avg(mem_used_mb) as mem, avg(gpu_pct) as gpu, avg(gpu_temp) as gtemp, avg(cpu_temp) as ctemp
  FROM metrics WHERE ts > $NOW - 3600 GROUP BY ts/60 ORDER BY ts);
" 2>/dev/null)
[ -z "$HISTORY_1H" ] && HISTORY_1H="[]"

HISTORY_6H=$(sqlite3 -cmd ".timeout 1500" "$DB" "
  SELECT '[' || group_concat(json_object('ts', ts, 'cpu', cpu, 'mem', mem, 'gpu', gpu, 'gtemp', gtemp, 'ctemp', ctemp)) || ']'
  FROM (SELECT (ts/300)*300 as ts, avg(cpu_pct) as cpu, avg(mem_used_mb) as mem, avg(gpu_pct) as gpu, avg(gpu_temp) as gtemp, avg(cpu_temp) as ctemp
  FROM metrics WHERE ts > $NOW - 21600 GROUP BY ts/300 ORDER BY ts);
" 2>/dev/null)
[ -z "$HISTORY_6H" ] && HISTORY_6H="[]"

HISTORY_24H=$(sqlite3 -cmd ".timeout 1500" "$DB" "
  SELECT '[' || group_concat(json_object('ts', ts, 'cpu', cpu, 'mem', mem, 'gpu', gpu, 'gtemp', gtemp, 'ctemp', ctemp)) || ']'
  FROM (SELECT (ts/300)*300 as ts, avg(cpu_pct) as cpu, avg(mem_used_mb) as mem, avg(gpu_pct) as gpu, avg(gpu_temp) as gtemp, avg(cpu_temp) as ctemp
  FROM metrics WHERE ts > $NOW - 86400 GROUP BY ts/300 ORDER BY ts);
" 2>/dev/null)
[ -z "$HISTORY_24H" ] && HISTORY_24H="[]"

# --- New-app detection ---
SEEN_FILE="$DATA_DIR/apps_seen"
CAND_FILE="$DATA_DIR/apps_cand"
NEWAPPS_LOG="$DATA_DIR/new_apps.log"
touch "$SEEN_FILE" "$CAND_FILE" "$NEWAPPS_LOG"

ps -eo pid,comm 2>/dev/null | while read -r pid name; do
  [ -z "$name" ] && continue
  case "$name" in \[*\]) continue ;; esac
  if [ -r "/proc/$pid/cmdline" ] && [ -n "$(head -c1 "/proc/$pid/cmdline" 2>/dev/null)" ]; then
    echo "$name"
  fi
done | \
  grep -vE '^(sh|bash|zsh|dash|fish|ps|pgrep|grep|awk|sed|sleep|cat|head|tail|true|false|tee|sort|uniq|comm|notify-send|omarchy-notification-send|xargs|find|rm|cp|mv|mkdir|dirname|basename|timeout)$' | \
  sort | uniq > "$DATA_DIR/.cur_names.$$"

comm -23 "$DATA_DIR/.cur_names.$$" <(sort "$SEEN_FILE") > "$DATA_DIR/.new_names.$$"
comm -12 "$DATA_DIR/.new_names.$$" <(sort "$CAND_FILE") > "$DATA_DIR/.promote.$$"
comm -23 "$DATA_DIR/.new_names.$$" <(sort "$CAND_FILE") > "$DATA_DIR/.fresh.$$"

NEW_APPS="[]"
if [ -s "$DATA_DIR/.promote.$$" ]; then
  NEW_APPS=$(awk '{printf "{\"name\":\"%s\",\"first_seen\":'$NOW'}", $0; if (NR < n) printf ","}' n="$(wc -l < "$DATA_DIR/.promote.$$")" "$DATA_DIR/.promote.$$")
  NEW_APPS="[$NEW_APPS]"
  while IFS= read -r nm; do
    nm=$(echo "$nm" | tr -d '\r')
    echo "$NOW $nm" >> "$NEWAPPS_LOG"
    PUB=$(sqlite3 -cmd ".timeout 1500" "$DB" "SELECT publisher, pkg, verified FROM app_meta WHERE name='$(echo "$nm" | sed "s/'/''/g")';" 2>/dev/null | head -1 | tr '|' $'\n' | tr -d '\r')
    set -- $PUB
    publisher="${1:-Unknown}"
    [ -z "$publisher" ] && publisher="Unknown"
    printf "INSERT INTO events (ts, type, app, publisher, msg, read) VALUES ($NOW, 'app_launch', '%s', '%s', 'App started: %s', 0);\n" \
      "${nm}" "${publisher}" "${nm}" | sqlite3 -cmd ".timeout 1500" "$DB" 2>/dev/null
    if [ "$ALERTS_ENABLED" = "1" ] && [ "$(pref_on 'New App Launch')" = "1" ]; then
      notify-send -a OmaControl "New app launched" "$nm" 2>/dev/null
    fi
  done < "$DATA_DIR/.promote.$$"
  cat "$DATA_DIR/.promote.$$" >> "$SEEN_FILE"
fi

sort -u "$SEEN_FILE" | tail -4000 > "$DATA_DIR/.seen.$$" && mv "$DATA_DIR/.seen.$$" "$SEEN_FILE"
cp "$DATA_DIR/.fresh.$$" "$CAND_FILE"

RECENT_APPS=$(tail -20 "$NEWAPPS_LOG" | tail -5 | awk '{printf "{\"name\":\"%s\",\"ts\":%s},", $2, $1}' | sed 's/,$//')
[ -n "$RECENT_APPS" ] && RECENT_APPS="[$RECENT_APPS]" || RECENT_APPS="[]"

rm -f "$DATA_DIR/.cur_names.$$" "$DATA_DIR/.new_names.$$" "$DATA_DIR/.promote.$$" "$DATA_DIR/.fresh.$$"

# --- Prune data older than 7 days ---
sqlite3 "$DB" "DELETE FROM metrics WHERE ts < $NOW - 604800;" 2>/dev/null
# Per-process snapshots only need to span the 24h chart window.
sqlite3 "$DB" "DELETE FROM proc_history WHERE ts < $NOW - 86400;" 2>/dev/null
# Neighbourhood of events only needs to span the visible tooling window.
sqlite3 "$DB" "DELETE FROM events WHERE ts < $NOW - 1209600;" 2>/dev/null

# --- Metric-spike events (persistent log for the Events tab) ---
SPC=$(printf "%d" "${CPU_PCT%.*}" 2>/dev/null); [ -z "$SPC" ] && SPC=0
if [ "$SPC" -ge 95 ]; then
  printf "INSERT INTO events (ts, type, app, publisher, msg) VALUES ($NOW, 'cpu_spike', '', '', 'CPU peaked at %s%%');\n" "$CPU_PCT" | sqlite3 -cmd ".timeout 1500" "$DB" 2>/dev/null
fi
SMM=$((MEM_TOTAL_KB > 0 ? (MEM_TOTAL_KB - MEM_AVAIL_KB) * 100 / MEM_TOTAL_KB : 0))
if [ "$SMM" -ge 92 ]; then
  printf "INSERT INTO events (ts, type, app, publisher, msg) VALUES ($NOW, 'mem_spike', '', '', 'Memory peaked at %s%%');\n" "$SMM" | sqlite3 -cmd ".timeout 1500" "$DB" 2>/dev/null
fi

# --- Output JSON ---
cat <<ENDJSON
{
  "cpu_pct": $CPU_PCT,
  "cores": $CORES,
  "load_1": $LOAD_1,
  "load_5": $LOAD_5,
  "load_15": $LOAD_15,
  "cpu_hz_mhz": $CPU_HZ,
  "cpu_max_mhz": $CPU_MAX_MHZ,
  "cpu_threads": ${CPU_THREADS:-0},
  "cpu_cores": ${CPU_CORES:-0},
  "cpu_name": "$CPU_NAME",
  "uptime_s": $UPTIME_S,
  "mem_used_mb": $MEM_USED_MB,
  "mem_total_mb": $MEM_TOTAL_MB,
  "mem_avail_mb": $MEM_AVAIL_MB,
  "mem_free_mb": $MEM_FREE_MB,
  "mem_cached_mb": $MEM_CACHED_MB,
  "mem_buffers_mb": $MEM_BUFFERS_MB,
  "swap_total_mb": $SWAP_TOTAL_MB,
  "swap_used_mb": $SWAP_USED_MB,
  "cpu_temp": $CPU_TEMP,
  "disk_pct": $DISK_MAX_PCT,
  "disks": $DISKS,
  "nets": $NETS,
  "gpu_pct": $GPU_PCT,
  "gpu_mem_mb": $GPU_MEM,
  "gpu_mem_total_mb": $GPU_MEM_TOTAL,
  "gpu_temp": $GPU_TEMP,
  "gpu_power_w": $GPU_POWER,
  "gpu_power_max_w": $GPU_POWER_MAX,
  "gpu_fan_pct": $GPU_FAN,
  "gpu_clock_mhz": $GPU_CLOCK,
  "gpu_mem_clock_mhz": $GPU_MEM_CLOCK,
  "gpu_graphics_max_mhz": $GPU_GRAPHICS_CLOCK,
  "gpu_name": "$GPU_NAME",
  "gpu_driver": "$GPU_DRIVER",
  "gpu_link_gen": "$GPU_LINK_GEN",
  "gpu_link_gen_max": "$GPU_LINK_GEN_MAX",
  "gpu_link_width": "$GPU_LINK_WIDTH",
  "gpu_link_width_max": "$GPU_LINK_WIDTH_MAX",
  "gpu_bus": "$GPU_BUS",
  "gpu_enc_pct": $GPU_ENC,
  "gpu_dec_pct": $GPU_DEC,
  "gpu_mem_clock_max_mhz": $GPU_MEM_CLOCK_MAX,
  "battery": {
    "present": $BAT_PRESENT,
    "percent": $BAT_PCT,
    "status": "$BAT_STATUS",
    "power_w": $BAT_POWER_W,
    "model": "$BAT_MODEL"
  },
  "host": "$HOST",
  "kernel": "$KERNEL",
  "os_pretty": "$OS_PRETTY",
  "proc_count": $PROC_COUNT,
  "ts": $NOW,
  "processes": [$PROCS],
  "history_1h": $HISTORY_1H,
  "history_6h": $HISTORY_6H,
  "history_24h": $HISTORY_24H,
  "new_apps": $NEW_APPS,
  "recent_apps": $RECENT_APPS
}
ENDJSON