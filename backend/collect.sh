#!/bin/sh
# OmControl data collector — outputs a single JSON blob with system metrics.
# Called via Quickshell Process{} every 2s.
#
# All rate meters (CPU, per-core CPU, disk IO, network) share one 0.2s
# sampling window so the script stays cheap.

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/bootstrap.sh"
DATA_DIR="$OMCONTROL_DATA_DIR"
DB="${OMCONTROL_DB:-$DATA_DIR/history.db}"
NOW=$(/usr/bin/date +%s)

# Prune stale temp files from past invocations that got killed mid-run.
find "$DATA_DIR" -maxdepth 1 -mmin +30 \
  \( -name '.omc_*' -o -name '.cur_names.*' -o -name '.new_names.*' \
     -o -name '.promote.*' -o -name '.fresh.*' -o -name '.seen.*' \) -delete 2>/dev/null

# Single-collector guard: BarWidget spawns collect.sh every 2s AND the
# omcontrol-collect service runs it on the same cadence. Only one may run
# per tick; the loser exits quietly and BarWidget just reuses its last
# sample (parseCollect("") falls back to the previous payload).
exec 9>"$DATA_DIR/.omc_collect.lock" 2>/dev/null || exit 0
flock -n 9 2>/dev/null || exit 0

# Escape a value for embedding inside a JSON double-quoted string: backslash
# then quote doubling. Control chars are stripped so stray tabs/newlines can
# never break the stdout blob.
esc() {
  printf '%s' "$1" | tr -d '\000-\037\177' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# --- Toast notifications are fired from sql-ins.py (single choke point),
#     which reads alert_prefs.json itself; nothing here needs the file. ---

# --- One-time schema bootstrap. Marker file keeps this off the hot path:
#     previously these CREATE/ALTER statements ran sqlite3 5x on every tick.
#     The column check is a self-heal: if a migration was interrupted by a
#     transient lock (mark set but columns missing), it re-runs instead of
#     leaving the INSERT/roll queries broken. ---
SCHEMA_MARK="${DB}.schema_mark_v4"
HAS_DISK_COLS=$(sqlite3 -cmd ".timeout 1500" "$DB" "SELECT count(*) FROM pragma_table_info('metrics') WHERE name IN ('disk_io','disk_r','disk_w');" 2>/dev/null)
if [ ! -f "$SCHEMA_MARK" ] || [ "$HAS_DISK_COLS" != "3" ]; then
  sqlite3 -cmd ".timeout 1500" "$DB" <<'SQL' 2>/dev/null
CREATE TABLE IF NOT EXISTS metrics (
  ts INTEGER PRIMARY KEY,
  cpu_pct REAL,
  mem_used_mb INTEGER,
  mem_total_mb INTEGER,
  gpu_pct REAL,
  gpu_mem_mb INTEGER,
  gpu_temp INTEGER,
  cpu_temp INTEGER,
  proc_count INTEGER,
  disk_pct REAL,
  disk_io REAL,
  disk_r REAL,
  disk_w REAL,
  net_rx_bytes INTEGER,
  net_tx_bytes INTEGER
);
CREATE INDEX IF NOT EXISTS idx_metrics_ts ON metrics(ts);
CREATE TABLE IF NOT EXISTS proc_history (
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
CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
SQL
  # Legacy DBs predate the disk/net columns; add them if missing.
  sqlite3 -cmd ".timeout 1500" "$DB" "ALTER TABLE metrics ADD COLUMN disk_pct REAL;" 2>/dev/null || true
  sqlite3 -cmd ".timeout 1500" "$DB" "ALTER TABLE metrics ADD COLUMN disk_io REAL;" 2>/dev/null || true
  sqlite3 -cmd ".timeout 1500" "$DB" "ALTER TABLE metrics ADD COLUMN disk_r REAL;" 2>/dev/null || true
  sqlite3 -cmd ".timeout 1500" "$DB" "ALTER TABLE metrics ADD COLUMN disk_w REAL;" 2>/dev/null || true
  sqlite3 -cmd ".timeout 1500" "$DB" "ALTER TABLE metrics ADD COLUMN net_rx_bytes INTEGER;" 2>/dev/null || true
  sqlite3 -cmd ".timeout 1500" "$DB" "ALTER TABLE metrics ADD COLUMN net_tx_bytes INTEGER;" 2>/dev/null || true
  # Only mark the migration complete once the columns actually exist, so a
  # failed/healed-already DB keeps retrying instead of wedging permanently.
  if [ "$(sqlite3 -cmd ".timeout 1500" "$DB" "SELECT count(*) FROM pragma_table_info('metrics') WHERE name IN ('disk_io','disk_r','disk_w');" 2>/dev/null)" = "3" ]; then
    touch "$SCHEMA_MARK"
  fi
fi

# One-time WAL switch (persistent per-DB): readers (sample-json, rollups,
# omcontrol CLI) no longer block on the collector's writes and vice versa.
WAL_MARK="$DATA_DIR/.omc_wal_on"
if [ ! -f "$WAL_MARK" ]; then
  sqlite3 -cmd ".timeout 1500" "$DB" "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;" >/dev/null 2>/dev/null
  touch "$WAL_MARK"
fi

D="$DATA_DIR"
CPU_PRE="$D/.omc_cpu_pre.$$"
CPU_POST="$D/.omc_cpu_post.$$"
DS_PRE="$D/.omc_disk_pre.$$"
DS_POST="$D/.omc_disk_post.$$"
NET_CUR="$D/.omc_net_cur.$$"
NET_STATE_NEW="$D/.omc_net_state.new.$$"
DISKIO="$D/.omc_diskio.$$"
DF_FILE="$D/.omc_df.$$"
PS_FILE="$D/.omc_ps.$$"
PROC_IO_PRE="$D/.omc_proc_io_pre.$$"
PROC_IO_POST="$D/.omc_proc_io_post.$$"
PROC_SWAP="$D/.omc_proc_swap.$$"
TMPFILES="$CPU_PRE $CPU_POST $DS_PRE $DS_POST $NET_CUR $NET_STATE_NEW $DISKIO $DF_FILE $PS_FILE $PROC_IO_PRE $PROC_IO_POST $PROC_SWAP $DATA_DIR/.cur_names.$$ $DATA_DIR/.new_names.$$ $DATA_DIR/.promote.$$ $DATA_DIR/.fresh.$$ $DATA_DIR/.seen.$$"
trap 'rm -f -- $TMPFILES' EXIT INT TERM

# --- Top 20 processes by CPU (snapshot once; used for per-proc IO + swap) ---
# pcpu from ps is thread-summed and can exceed 100% (e.g. 300% = 3 cores of
# work). Divide by the core count so every surface reports average CPU across
# cores instead — 100% = one core fully busy.
NCORES=$(nproc 2>/dev/null || echo 1)
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

# --- Sample capture (one 0.2s window for CPU/disk/proc-IO deltas; the
#     network rate is a tick-to-tick delta computed later, not this window) ---
awk '/^cpu /{print "cpu", $5+$6, $2+$3+$4+$5+$6+$7+$8; next}
     /^cpu[0-9]+ /{sub("cpu","",$1); print $1, $5+$6, $2+$3+$4+$5+$6+$7+$8}' /proc/stat > "$CPU_PRE"
awk '{print $3, $6, $10}' /proc/diskstats > "$DS_PRE"

sleep 0.2

awk '/^cpu /{print "cpu", $5+$6, $2+$3+$4+$5+$6+$7+$8; next}
     /^cpu[0-9]+ /{sub("cpu","",$1); print $1, $5+$6, $2+$3+$4+$5+$6+$7+$8}' /proc/stat > "$CPU_POST"
awk '{print $3, $6, $10}' /proc/diskstats > "$DS_POST"

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
DF_DEVS=""
while read -r fs blk used avail pct mount; do
  [ "$fs" = "Filesystem" ] && continue
  # /dev/path → /proc/diskstats device name. LUKS/dm mounts show up as
  # /dev/mapper/<name> in df but dm-N in diskstats, so resolve via sysfs.
  case "$fs" in
    /dev/mapper/*)
      dev=""
      for dmn_dev in /sys/class/block/dm-*/dm/name; do
        [ -r "$dmn_dev" ] || continue
        [ "$(cat "$dmn_dev" 2>/dev/null)" = "${fs#/dev/mapper/}" ] && { dev=$(basename "${dmn_dev%/dm/name}"); break; }
      done
      [ -z "$dev" ] && continue
      ;;
    /dev/*)
      dev=${fs#/dev/}
      ;;
    *) continue ;;
  esac
  [ "$blk" -gt 0 ] || continue
  case "$mount" in
    /*) ;;
    *) continue ;;
  esac
  DF_DEVS="$DF_DEVS $dev"
  total_gb=$(awk "BEGIN{printf \"%.1f\", $blk/1048576}")
  used_gb=$(awk "BEGIN{printf \"%.1f\", $used/1048576}")
  pctv=$(awk "BEGIN{printf \"%.1f\", $used*100/$blk}")
  set -- $(awk -v d="$dev" '$1==d{print $2, $3}' "$DISKIO")
  rk=${1:-0}; wk=${2:-0}
  DISKS="$DISKS{\"dev\":\"$(esc "$dev")\",\"mount\":\"$(esc "$mount")\",\"size_gb\":$total_gb,\"used_gb\":$used_gb,\"pct\":$pctv,\"read_kbs\":$rk,\"write_kbs\":$wk},"
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

# Total disk I/O across the real filesystem devices (KB/s) → the "Disk"
# metric is now a read/write rate, not a capacity percentage. Summing the
# df-mounted partitions avoids double-counting whole-device + partition
# entries that /proc/diskstats also carries.
set -- $(awk -v devs="${DF_DEVS## }" 'BEGIN { n = split(devs, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
  { if ($1 in want) { r += $2; w += $3; hit = 1 } }
  END { if (hit) printf "%.1f %.1f", r, w; else printf "x" }' "$DISKIO")
if [ -z "${1:-}" ] || [ "${1:-}" = "x" ]; then
  # No df devices in diskstats (rare): fall back to physical whole devices.
  set -- $(awk '!/^(loop|dm-|ram|zram|sr)/ { r += $2; w += $3; hit = 1 } END { if (hit) printf "%.1f %.1f", r, w; else printf "0 0" }' "$DISKIO")
fi
DISK_R_TOT=${1:-0}
DISK_W_TOT=${2:-0}
DISK_IO_TOT=$(awk "BEGIN{printf \"%.1f\", $DISK_R_TOT + $DISK_W_TOT}")

# --- Network rates (KB/s). Mirrors the netspeed bar widget's reading: the
#     delta between this tick and the last is divided by the real elapsed
#     milliseconds, then EMA-smoothed (0.3/0.7) for a steady label. Virtual
#     links (docker/br/veth/bridges) are excluded so wifi/ethernet win. ---
NET_STATE="$D/.omc_net_state"
NOW_MS=$(date +%s%3N 2>/dev/null || echo ${NOW}000)
[ -f "$NET_STATE" ] || : > "$NET_STATE"   # first run: no prior counters, all rates 0

awk 'NR>2 { sub(":","",$1); nm=tolower($1)
      if (nm=="lo" || nm ~ /^docker[0-9]*/ || nm ~ /^br-/ || nm ~ /^virbr[0-9]*/ || nm ~ /^veth/ || nm ~ /^vboxnet[0-9]*/) next
      print nm, $2, $10 }' /proc/net/dev > "$NET_CUR"

NETS=$(awk -v now="$NOW_MS" -v stateout="$NET_STATE_NEW" 'NR==FNR {
      rx[$1]=$2; tx[$1]=$3; order[++n]=$1; next }
    {
      ems = now - $6
      if (ems < 1) ems = 2000
      if ($1 in rx) {
        drx = rx[$1] - $2; if (drx < 0) drx = 0
        dtx = tx[$1] - $3; if (dtx < 0) dtx = 0
        rr = drx * 1000.0 / 1024.0 / ems
        tt = dtx * 1000.0 / 1024.0 / ems
        srx[$1] = 0.3 * rr + 0.7 * $4
        stx[$1] = 0.3 * tt + 0.7 * $5
      }
    }
    END {
      for (i = 1; i <= n; i++) {
        nm = order[i]
        if (!(nm in srx)) { srx[nm] = 0; stx[nm] = 0 }
        if (srx[nm] < 0.05) srx[nm] = 0
        if (stx[nm] < 0.05) stx[nm] = 0
        printf "%s %d %d %.2f %.2f %d\n", nm, rx[nm], tx[nm], srx[nm], stx[nm], now > stateout
        printf "{\"iface\":\"%s\",\"rx_kbs\":%.1f,\"tx_kbs\":%.1f},", nm, srx[nm], stx[nm]
      }
    }' "$NET_CUR" "$NET_STATE")

mv "$NET_STATE_NEW" "$NET_STATE"
if [ -n "$NETS" ]; then
  NETS="[${NETS%,}]"
else
  NETS="[]"
fi

# Cumulative rx/tx bytes across the same real interfaces (for history rolls).
set -- $(awk 'NR>2 { sub(":","",$1); nm=tolower($1)
      if (nm=="lo" || nm ~ /^docker[0-9]*/ || nm ~ /^br-/ || nm ~ /^virbr[0-9]*/ || nm ~ /^veth/ || nm ~ /^vboxnet[0-9]*/) next
      r+=$2; t+=$10 } END{print r+0, t+0}' /proc/net/dev)
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
  GPU_LINE=$(timeout 10 nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,fan.speed,clocks.sm,utilization.encoder,utilization.decoder --format=csv,noheader,nounits 2>/dev/null | sed 's/\[N\/A\]/0/g' | tail -1)
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
    # One -q -x dump per tick; also reused by the GPU process map below.
    GPUXML="$D/.omc_gpuxml.$$"
    TMPFILES="$TMPFILES $GPUXML"
    timeout 10 nvidia-smi -q -x 2>/dev/null > "$GPUXML"
    if [ -s "$GPUXML" ]; then
      GPU_NAME=$(sed -n '0,/<product_name>/s/.*<product_name>\([^<]*\)<\/product_name>.*/\1/p' "$GPUXML")
      GPU_DRIVER=$(sed -n '0,/<driver_version>/s/.*<driver_version>\([^<]*\)<\/driver_version>.*/\1/p' "$GPUXML")
      GPU_POWER_MAX=$(sed -n '0,/<max_power_limit>/s/.*<max_power_limit>\([0-9.]*\).*/\1/p' "$GPUXML")
      GPU_LINK_GEN=$(sed -n '0,/<current_link_gen>/s/.*<current_link_gen>\([0-9]*\).*/\1/p' "$GPUXML")
      GPU_LINK_GEN_MAX=$(sed -n '0,/<max_link_gen>/s/.*<max_link_gen>\([0-9]*\).*/\1/p' "$GPUXML")
      GPU_LINK_WIDTH=$(sed -n '0,/<current_link_width>/s/.*<current_link_width>\([0-9]*\)x.*/\1/p' "$GPUXML")
      GPU_LINK_WIDTH_MAX=$(sed -n '0,/<max_link_width>/s/.*<max_link_width>\([0-9]*\)x.*/\1/p' "$GPUXML")
      GPU_BUS=$(sed -n '0,/<pci_bus_id>/s/.*<pci_bus_id>00000000:\([0-9a-f]*:[0-9a-f]*\.[0-9]*\)<\/pci_bus_id>.*/0000:\1/p' "$GPUXML")
      # GPU_ENC stays the utilization.encoder percentage from the query above;
      # <session_count> is a session count, not a load figure, so it must not
      # overwrite it.
      # Clocks: current from <clocks>, max from <max_clocks> — pull within section
      GPU_MEM_CLOCK=$(awk '
        /<clocks>/ {sec="cur"} /<\/clocks>/ {sec=""; next}
        /<max_clocks>/ {sec="max"} /<\/max_clocks>/ {sec=""; next}
        /<min_clocks>/ {sec="min"} /<\/min_clocks>/ {sec=""; next}
        sec=="cur" && /<mem_clock>/ {gsub(/[^0-9]/,""); print; exit}' "$GPUXML")
      GPU_MEM_CLOCK_MAX=$(awk '
        /<max_clocks>/ {sec="max"; next} /<\/max_clocks>/ {sec=""; next}
        sec=="max" && /<mem_clock>/ {gsub(/[^0-9]/,""); print; exit}' "$GPUXML")
      GPU_GRAPHICS_CLOCK=$(awk '
        /<max_clocks>/ {sec="max"; next} /<\/max_clocks>/ {sec=""; next}
        sec=="max" && /<graphics_clock>/ {gsub(/[^0-9]/,""); print; exit}' "$GPUXML")
    fi
  fi
fi

# --- GPU: AMD fallback (amdgpu sysfs) when nvidia-smi is absent or empty.
#     gpu_busy_percent + vram counters live under /sys/class/drm/card*/device,
#     temperature under the matching hwmon chip. ---
if [ -z "$GPU_NAME" ]; then
  for ADEV in /sys/class/drm/card*/device; do
    [ -r "$ADEV/gpu_busy_percent" ] || continue
    GPU_PCT=$(cat "$ADEV/gpu_busy_percent" 2>/dev/null)
    GPU_PCT=${GPU_PCT:-0}
    GPU_NAME="AMD GPU"
    GPU_DRIVER="amdgpu"
    if [ -r "$ADEV/mem_info_vram_used" ]; then
      V=$(cat "$ADEV/mem_info_vram_used" 2>/dev/null); [ -n "$V" ] || V=0
      GPU_MEM=$((V / 1048576))
    fi
    if [ -r "$ADEV/mem_info_vram_total" ]; then
      V=$(cat "$ADEV/mem_info_vram_total" 2>/dev/null); [ -n "$V" ] || V=0
      GPU_MEM_TOTAL=$((V / 1048576))
    fi
    for hw in /sys/class/hwmon/hwmon*; do
      [ -r "$hw/name" ] || continue
      [ "$(cat "$hw/name" 2>/dev/null)" = "amdgpu" ] || continue
      T=$(cat "$hw/temp1_input" 2>/dev/null)
      [ -n "$T" ] && GPU_TEMP=$((T / 1000))
      break
    done
    break
  done
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
# Always create the file: the merged PROCS awk below reads it, and it stays
# empty whenever the driver produced no XML (no NVIDIA, unloaded driver, …).
: > "$GPU_PROC_MAP"
# nvidia-smi only lists compute contexts via --query-compute-apps (usually
# empty), so parse the XML process table which includes graphical processes.
# Reuses the -q -x dump written by the GPU block above (one smi XML per tick).
if command -v nvidia-smi >/dev/null 2>&1; then
  if [ -z "$GPUXML" ] || [ ! -s "$GPUXML" ]; then
    GPUXML="$D/.omc_gpuxml.$$"
    TMPFILES="$TMPFILES $GPUXML"
    timeout 10 nvidia-smi -q -x 2>/dev/null > "$GPUXML"
  fi
  [ -s "$GPUXML" ] && awk '
    /<process_info>/ { inproc=1 }
    inproc && /<pid>/ { gsub(/[^0-9]/, "", $0); pidname=$0 }
    inproc && /<used_memory>/ {
      gsub(/[^0-9]/, "", $0); mem=$0
      if (pidname != "") { print pidname, mem }
      inproc=0
    }
  ' "$GPUXML" > "$GPU_PROC_MAP"
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
    gsub(/[<>\x00-\x1F\x7F"\\]/, " ", $4)
    c = (ncores > 0) ? $2 / ncores : $2
    g = ($1 in gpu) ? gpu[$1] : 0
    gpct = (g > 0 && gpu_total > 0) ? g * 100 / gpu_total : 0
    swm = ($1 in swap) ? swap[$1] / 1024 : 0
    ior = ($1 in rate) ? rate[$1] : 0
    printf "{\"pid\":%s,\"cpu\":%.2f,\"mem\":%s,\"swap\":%.1f,\"io_kbs\":%.1f,\"gpu_mem\":%.0f,\"gpu\":%.1f,\"name\":\"%s\"}%s",
      $1, c, $3, swm, ior, g, gpct, $4, (++n < 20 ? "," : "")
  }' gpumap="$GPU_PROC_MAP" swapmap="$PROC_SWAP" ratemap="$PROC_IO_RATE" \
  gpu_total="$GPU_MEM_TOTAL" ncores="$NCORES" "$GPU_PROC_MAP" "$PROC_SWAP" "$PROC_IO_RATE" "$PS_FILE")

# --- Persist sample, prune old data, and record metric spikes all in ONE
#     sqlite3 call (was 5 separate invocations per tick). ---
SQL="INSERT OR REPLACE INTO metrics (ts, cpu_pct, mem_used_mb, mem_total_mb, gpu_pct, gpu_temp, cpu_temp, proc_count, disk_pct, disk_io, disk_r, disk_w, net_rx_bytes, net_tx_bytes) VALUES ($NOW, $CPU_PCT, $MEM_USED_MB, $MEM_TOTAL_MB, $GPU_PCT, $GPU_TEMP, $CPU_TEMP, $PROC_COUNT, $DISK_MAX_PCT, $DISK_IO_TOT, $DISK_R_TOT, $DISK_W_TOT, $NET_TOT_RX, $NET_TOT_TX);
DELETE FROM metrics WHERE ts < $NOW - 604800;
DELETE FROM proc_history WHERE ts < $NOW - 86400;
DELETE FROM events WHERE ts < $NOW - 1209600;"

# Metric-spike events (persistent log for the Events tab).
SPC=$(printf "%d" "${CPU_PCT%.*}" 2>/dev/null); [ -z "$SPC" ] && SPC=0
if [ "$SPC" -ge 95 ]; then
  SQL="$SQL
INSERT INTO events (ts, type, app, publisher, msg) VALUES ($NOW, 'cpu_spike', '', '', 'CPU peaked at $CPU_PCT%')
  WHERE NOT EXISTS (SELECT 1 FROM events WHERE type='cpu_spike' AND ts > $NOW - 30);"
fi
SMM=$((MEM_TOTAL_KB > 0 ? (MEM_TOTAL_KB - MEM_AVAIL_KB) * 100 / MEM_TOTAL_KB : 0))
if [ "$SMM" -ge 92 ]; then
  SQL="$SQL
INSERT INTO events (ts, type, app, publisher, msg) VALUES ($NOW, 'mem_spike', '', '', 'Memory peaked at $SMM%')
  WHERE NOT EXISTS (SELECT 1 FROM events WHERE type='mem_spike' AND ts > $NOW - 30);"
fi
sqlite3 -cmd ".timeout 1500" "$DB" <<SQL 2>/dev/null
$SQL
SQL

# --- Persist per-process snapshot once per minute (chart drill-down) + refresh
#     app metadata (publisher/verified/desc; cached in app_meta) ---
PROC_MIN=$((NOW / 60))
LAST_PROCMIN=$(cat "$DATA_DIR/.omc_proc_min" 2>/dev/null || echo 0)
if [ "$PROC_MIN" -gt "$LAST_PROCMIN" ]; then
  PROC_TS=$((PROC_MIN * 60))
  # Per-process network KB/s for this minute (ss-based, like the netspeed
  # widget). Merged into the snapshot so the chart drill-down can show who
  # drove a network spike; bandwidth-only pids are appended to the CPU list.
  NETPROCS_FILE="$D/.omc_netprocs.$$"
  TMPFILES="$TMPFILES $NETPROCS_FILE"
  OMCONTROL_DATA_DIR="$DATA_DIR" python3 "$(dirname "$0")/net-procs.py" > "$NETPROCS_FILE" 2>/dev/null
  PROC_JSON=$(PROCS_RAW="$PROCS" OMC_NETPROCS="$NETPROCS_FILE" python3 - <<'PY'
import json, os, sys
raw = os.environ.get("PROCS_RAW", "").strip()
net = []
try:
    net = json.load(open(os.environ["OMC_NETPROCS"]))
except Exception:
    net = []
try:
    procs = json.loads("[" + raw + "]") if raw else []
except Exception:
    procs = []
netmap = {}
for e in net:
    netmap[str(e.get("pid"))] = e
pidset = set()
for p in procs:
    pid = str(p.get("pid", ""))
    n = netmap.get(pid)
    p["nr"] = float(n.get("rx", 0)) if n else 0.0
    p["nt"] = float(n.get("tx", 0)) if n else 0.0
    pidset.add(pid)
appended = 0
for e in net:
    if str(e.get("pid")) in pidset:
        continue
    procs.append({"pid": int(e.get("pid") or 0), "cpu": 0.0, "mem": 0.0,
                  "swap": 0.0, "io_kbs": 0.0, "gpu_mem": 0.0, "gpu": 0.0,
                  "name": e.get("name") or str(e.get("pid") or "?"),
                  "nr": float(e.get("rx", 0) or 0), "nt": float(e.get("tx", 0) or 0)})
    appended += 1
    if appended >= 20:
        break
print(json.dumps(procs))
PY
)
  PROC_JSON_SQL=$(echo "$PROC_JSON" | sed "s/'/''/g")
  sqlite3 -cmd ".timeout 1500" "$DB" "INSERT OR REPLACE INTO proc_history VALUES ($PROC_TS, '$PROC_JSON_SQL');" 2>/dev/null
  awk '{print $1, $4}' "$PS_FILE" | OMCONTROL_DB="$DB" python3 "$(dirname "$0")/app-meta.py" 2>/dev/null
  # App-exit events: names in last minute's snapshot that are gone now
  # (only "real" apps: resolved to a package/core, never ephemeral shells
  # or churning kernel worker threads).
  ps -eo comm --no-headers 2>/dev/null | sed 's/[[:space:]]*$//' \
    | grep -vE '^(sh|bash|zsh|dash|fish|ps|pgrep|grep|awk|sed|sleep|cat|head|tail|true|false|tee|sort|uniq|comm|notify-send|xargs|find|rm|cp|mv|mkdir|dirname|basename|logout|timeout|omcontrol-poll|sd_notify|kworker.*|kthreadd|ksoftirqd|kswapd|kcompactd|khugepaged|kblockd|kdevtmpfs|khelper|writeback|jbd2|kcryptd|dmcrypt_write|oom_reaper|migration|watchdog|cpuhp|rcu|scsi_|usb_|irq/|ata_|xfs-|btrfs-|flush-|events_unbound|netns|kauditd|\[.*\]|systemd-udevd)$' \
    | sort -u > "$DATA_DIR/.cur_names_min.$$"
  if [ -f "$DATA_DIR/.last_names_min" ]; then
    while IFS= read -r nm; do
      [ -z "$nm" ] && continue
      grep -qx "$nm" "$DATA_DIR/.cur_names_min.$$" && continue
      nm=$(printf '%s' "$nm" | tr -d '\r')
      printf 'event\t%s\tapp_exit\t%s\t\tApp closed: %s\t1\n' "$PROC_TS" "$nm" "$nm"
    done < "$DATA_DIR/.last_names_min" | OMCONTROL_DB="$DB" python3 "$(dirname "$0")/sql-ins.py" 2>/dev/null
  fi
  mv "$DATA_DIR/.cur_names_min.$$" "$DATA_DIR/.last_names_min"
  echo "$PROC_MIN" > "$DATA_DIR/.omc_proc_min"
fi

# --- Downsampled history rolls moved out of the collector: collect.sh runs on
#     a 2s tick and its history_1h/6h/24h were only consumed by the deleted
#     Panel.qml. The app window now recomputes its own rolls at 30s intervals
#     via sample-json.sh (cached on disk), so nothing here queries the table.

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
  grep -vE '^(sh|bash|zsh|dash|fish|ps|pgrep|grep|awk|sed|sleep|cat|head|tail|true|false|tee|sort|uniq|comm|notify-send|omarchy-notification-send|xargs|find|rm|cp|mv|mkdir|dirname|basename|timeout|kworker.*|kthreadd|ksoftirqd|kswapd|kcompactd|khugepaged|kblockd|kdevtmpfs|khelper|writeback|jbd2|kcryptd|dmcrypt_write|oom_reaper|migration|watchdog|cpuhp|rcu|scsi_|usb_|irq/|ata_|xfs-|btrfs-|flush-|events_unbound|netns|kauditd|systemd-udevd)$' | \
  sort | uniq > "$DATA_DIR/.cur_names.$$"

comm -23 "$DATA_DIR/.cur_names.$$" <(sort "$SEEN_FILE") > "$DATA_DIR/.new_names.$$"
comm -12 "$DATA_DIR/.new_names.$$" <(sort "$CAND_FILE") > "$DATA_DIR/.promote.$$"
comm -23 "$DATA_DIR/.new_names.$$" <(sort "$CAND_FILE") > "$DATA_DIR/.fresh.$$"

NEW_APPS="[]"
if [ -s "$DATA_DIR/.promote.$$" ]; then
  NEW_APPS=$(awk '{gsub(/["\\]/, " ", $0); printf "{\"name\":\"%s\",\"first_seen\":'$NOW'}", $0; if (NR < n) printf ","}' n="$(wc -l < "$DATA_DIR/.promote.$$")" "$DATA_DIR/.promote.$$")
  NEW_APPS="[$NEW_APPS]"
  while IFS= read -r nm; do
    nm=$(echo "$nm" | tr -d '\r')
    [ -n "$nm" ] || continue
    echo "$NOW $nm" >> "$NEWAPPS_LOG"
  done < "$DATA_DIR/.promote.$$"

  # Classify each first-seen launch via the app-meta cache: verified apps are
  # plain launches, known-but-unverified are unsigned_launch, anything without
  # a resolved publisher is an unknown_app — the Security bucket / chart pins.
  OMCONTROL_NOW="$NOW" python3 - "$DB" "$DATA_DIR/.promote.$$" <<'PY' | \
      OMCONTROL_DB="$DB" python3 "$(dirname "$0")/sql-ins.py" 2>/dev/null
import os, sqlite3, sys
db = sys.argv[1]
now = int(os.environ.get("OMCONTROL_NOW") or 0)
names = []
for ln in open(sys.argv[2], encoding="utf-8", errors="replace"):
    nm = ln.rstrip("\n\r")
    if nm.strip():
        names.append(nm)
if not names:
    sys.exit()
con = sqlite3.connect(db, timeout=3)
try:
    for nm in names:
        row = con.execute("SELECT publisher, verified FROM app_meta WHERE name=?", (nm,)).fetchone()
        if row is None or row[0] in ("", "Unknown"):
            typ, known = "unknown_app", "0"
        elif int(row[1] or 0):
            typ, known = "app_launch", "1"
        else:
            typ, known = "unsigned_launch", "1"
        print("event\t%s\t%s\t%s\t\tApp started: %s\t%s" % (now, typ, nm, nm, known))
finally:
    con.close()
PY
  cat "$DATA_DIR/.promote.$$" >> "$SEEN_FILE"
fi

sort -u "$SEEN_FILE" | tail -4000 > "$DATA_DIR/.seen.$$" && mv "$DATA_DIR/.seen.$$" "$SEEN_FILE"
cp "$DATA_DIR/.fresh.$$" "$CAND_FILE"

RECENT_APPS=$(tail -20 "$NEWAPPS_LOG" | tail -5 | awk '{gsub(/["\\]/, " ", $2); printf "{\"name\":\"%s\",\"ts\":%s},", $2, $1}' | sed 's/,$//')
[ -n "$RECENT_APPS" ] && RECENT_APPS="[$RECENT_APPS]" || RECENT_APPS="[]"

rm -f "$DATA_DIR/.cur_names.$$" "$DATA_DIR/.new_names.$$" "$DATA_DIR/.promote.$$" "$DATA_DIR/.fresh.$$"

# Prunes and metric-spike events are folded into the single sqlite3 call above.

# --- Output JSON ---
# Capped as a last resort: a malfunctioning producer must never be able to
# retain unbounded output in the long-lived shell. 262 KB is far above the
# ~10 KB this blob realistically reaches.
{ cat <<ENDJSON
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
  "cpu_name": "$(esc "$CPU_NAME")",
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
  "disk_io": $DISK_IO_TOT,
  "disk_r": $DISK_R_TOT,
  "disk_w": $DISK_W_TOT,
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
  "gpu_name": "$(esc "$GPU_NAME")",
  "gpu_driver": "$(esc "$GPU_DRIVER")",
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
    "status": "$(esc "$BAT_STATUS")",
    "power_w": $BAT_POWER_W,
    "model": "$(esc "$BAT_MODEL")"
  },
  "host": "$(esc "$HOST")",
  "kernel": "$(esc "$KERNEL")",
  "os_pretty": "$(esc "$OS_PRETTY")",
  "proc_count": $PROC_COUNT,
  "ts": $NOW,
  "processes": [$PROCS],
  "new_apps": $NEW_APPS,
  "recent_apps": $RECENT_APPS
}
ENDJSON
} | /usr/bin/head -c "${OMCONTROL_MAX_OUT_BYTES:-1048576}" 2>/dev/null