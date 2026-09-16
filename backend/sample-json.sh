#!/bin/sh
# OmControl sample-json — light DB snapshot for the standalone app window:
# live values (latest metrics row), downsampled history rolls, enriched app
# list (publisher/verified/permissions/disabled), persistent events log,
# current-run permission badges, and alert-sensitivity preferences.

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/bootstrap.sh"
DATA_DIR="$OMCONTROL_DATA_DIR"
DB="${OMCONTROL_DB:-$DATA_DIR/history.db}"
RULES="${OMCONTROL_RULES:-$DATA_DIR/rules.json}"

if [ ! -f "$DB" ]; then
  echo '{"cpu":0,"mem":0,"gpu":0,"procs":0,"disk":0,"disk_r":0,"disk_w":0,"history":[],"p_list":[],"snaps":[],"apps":[],"catalog":[],"alerts":[],"events":[],"alert_prefs":{},"disabled":[],"perms":{}}'
  exit 0
fi

NOW=$(date +%s)

LIVE=$(sqlite3 -cmd ".timeout 3000" "$DB" "SELECT cpu_pct, mem_used_mb, mem_total_mb, gpu_pct, proc_count, COALESCE(disk_io,disk_pct,0), COALESCE(disk_r,0), COALESCE(disk_w,0), COALESCE(cpu_temp,0), COALESCE(gpu_temp,0) FROM metrics ORDER BY ts DESC LIMIT 1;" 2>/dev/null)
CPU=${LIVE%%|*} REST=${LIVE#*|}
MEM_USED=${REST%%|*} REST=${REST#*|}
MEM_TOTAL=${REST%%|*} REST=${REST#*|}
GPU=${REST%%|*} REST=${REST#*|}
PROCS=${REST%%|*} REST=${REST#*|}
DISK=${REST%%|*} REST=${REST#*|}
DISK_R=${REST%%|*} REST=${REST#*|}
DISK_W=${REST%%|*} REST=${REST#*|}
CTEMP=${REST%%|*} REST=${REST#*|}
GTEMP=$REST
[ -z "$CPU" ] && CPU=0
[ -z "$MEM_TOTAL" ] || [ "$MEM_TOTAL" = 0 ] && MEM_TOTAL=1
MEM=$((MEM_USED * 100 / MEM_TOTAL))
[ -z "$DISK" ] && DISK=0
[ -z "$DISK_R" ] && DISK_R=0
[ -z "$DISK_W" ] && DISK_W=0
[ -z "$CTEMP" ] && CTEMP=0
[ -z "$GTEMP" ] && GTEMP=0

# History rolls with disk + network included (net rates derived from
# cumulative byte counters: delta bytes / delta seconds / 1024 = KB/s).
# The app window polls this every 4s, but the chart is downsampled to
# 10s/300s/900s buckets — so rolls are recomputed at most every 30s and
# cached on disk; the cache is also the source between recomputes.
ROLL_BASE="${DB}.rolls"
ROLL_STAMP="$ROLL_BASE.stamp"
ROLL_CACHE="$ROLL_BASE.v4"
ROLLS_LAST=0
[ -f "$ROLL_STAMP" ] && ROLLS_LAST=$(cat "$ROLL_STAMP" 2>/dev/null || echo 0)
ROLLS_AGE=$((NOW - ${ROLLS_LAST:-0}))

if [ "$ROLLS_AGE" -lt 30 ] && [ -f "$ROLL_CACHE" ]; then
  H1=$(sed -n '1p' "$ROLL_CACHE")
  H6=$(sed -n '2p' "$ROLL_CACHE")
  H1D=$(sed -n '3p' "$ROLL_CACHE")
  [ -z "$H1" ] && H1="[]"
  [ -z "$H6" ] && H6="[]"
  [ -z "$H1D" ] && H1D="[]"
else
  ROLLS_OUT=$(sqlite3 -cmd ".timeout 3000" "$DB" <<SQL 2>/dev/null
SELECT '[' || group_concat(json_object('ts', ts, 'cpu', cpu, 'mem_pct', mem, 'gpu', gpu, 'procs', procs, 'disk', disk, 'rx', rx, 'tx', tx, 'ctemp', ctemp, 'gtemp', gtemp)) || ']'
FROM (SELECT (ts/10)*10 as ts, avg(cpu_pct) as cpu,
             round(avg(mem_used_mb) * 100.0 / avg(mem_total_mb)) as mem,
             avg(gpu_pct) as gpu, round(avg(proc_count)) as procs,
             round(avg(disk_io)) as disk,
             avg(cpu_temp) as ctemp, avg(gpu_temp) as gtemp,
             (max(net_rx_bytes) - min(net_rx_bytes)) / nullif(max(ts) - min(ts), 0) / 1024 as rx,
             (max(net_tx_bytes) - min(net_tx_bytes)) / nullif(max(ts) - min(ts), 0) / 1024 as tx
      FROM metrics WHERE ts > $NOW - 3600 GROUP BY ts/10 ORDER BY ts);
SELECT '[' || group_concat(json_object('ts', ts, 'cpu', cpu, 'mem_pct', mem, 'gpu', gpu, 'procs', procs, 'disk', disk, 'rx', rx, 'tx', tx, 'ctemp', ctemp, 'gtemp', gtemp)) || ']'
FROM (SELECT (ts/300)*300 as ts, avg(cpu_pct) as cpu,
             round(avg(mem_used_mb) * 100.0 / avg(mem_total_mb)) as mem,
             avg(gpu_pct) as gpu, round(avg(proc_count)) as procs,
             round(avg(disk_io)) as disk,
             avg(cpu_temp) as ctemp, avg(gpu_temp) as gtemp,
             round((max(net_rx_bytes) - min(net_rx_bytes)) / nullif(max(ts) - min(ts), 0) / 1024) as rx,
             round((max(net_tx_bytes) - min(net_tx_bytes)) / nullif(max(ts) - min(ts), 0) / 1024) as tx
      FROM metrics WHERE ts > $NOW - 21600 GROUP BY ts/300 ORDER BY ts);
SELECT '[' || group_concat(json_object('ts', ts, 'cpu', cpu, 'mem_pct', mem, 'gpu', gpu, 'procs', procs, 'disk', disk, 'rx', rx, 'tx', tx, 'ctemp', ctemp, 'gtemp', gtemp)) || ']'
FROM (SELECT (ts/900)*900 as ts, avg(cpu_pct) as cpu,
             round(avg(mem_used_mb) * 100.0 / avg(mem_total_mb)) as mem,
             avg(gpu_pct) as gpu, round(avg(proc_count)) as procs,
             round(avg(disk_io)) as disk,
             avg(cpu_temp) as ctemp, avg(gpu_temp) as gtemp,
             round((max(net_rx_bytes) - min(net_rx_bytes)) / nullif(max(ts) - min(ts), 0) / 1024) as rx,
             round((max(net_tx_bytes) - min(net_tx_bytes)) / nullif(max(ts) - min(ts), 0) / 1024) as tx
      FROM metrics WHERE ts > $NOW - 86400 GROUP BY ts/900 ORDER BY ts);
SQL
)
  H1=$(printf '%s\n' "$ROLLS_OUT" | sed -n '1p')
  H6=$(printf '%s\n' "$ROLLS_OUT" | sed -n '2p')
  H1D=$(printf '%s\n' "$ROLLS_OUT" | sed -n '3p')
  [ -z "$H1" ] && H1="[]"
  [ -z "$H6" ] && H6="[]"
  [ -z "$H1D" ] && H1D="[]"
  printf '%s\n%s\n%s\n' "$H1" "$H6" "$H1D" > "$ROLL_CACHE.tmp.$$"
  mv "$ROLL_CACHE.tmp.$$" "$ROLL_CACHE"
  echo "$NOW" > "$ROLL_STAMP"
fi

# Live network rates from the two most recent metric samples (KB/s).
NET_L=$(sqlite3 -cmd ".timeout 3000" "$DB" "SELECT ts, COALESCE(net_rx_bytes,0), COALESCE(net_tx_bytes,0) FROM metrics WHERE net_rx_bytes IS NOT NULL ORDER BY ts DESC LIMIT 2;" 2>/dev/null)
RX_KBS=0
TX_KBS=0
OLD_IFS=$IFS; IFS=$'| \n'; set -- $NET_L; IFS=$OLD_IFS
T2=$1; B2=$2; C2=$3
T1=$4; B1=$5; C1=$6
if [ -n "$T2" ] && [ -n "$T1" ] && [ "$T2" != "$T1" ]; then
  DT=$((T2 - T1))
  [ "$DT" -gt 0 ] && B_DT=$((B2 - B1)) && C_DT=$((C2 - C1)) && \
    RX_KBS=$(awk "BEGIN{printf \"%.1f\", ($B_DT>0? $B_DT:0) / $DT / 1024}") && \
    TX_KBS=$(awk "BEGIN{printf \"%.1f\", ($C_DT>0? $C_DT:0) / $DT / 1024}")
fi
[ -z "$RX_KBS" ] && RX_KBS=0
[ -z "$TX_KBS" ] && TX_KBS=0

# Disabled app names from rules.json.
DISABLED=$(python3 - "$RULES" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("[]"); sys.exit()
names = [r.get("pattern", "") for r in d.get("rules", [])
         if r.get("kind") == "app" and r.get("action") == "disable" and r.get("enabled")
         and r.get("pattern")]
import json as j
print(j.dumps(names))
PY
)

# Alert preferences.
PREFS="${OMCONTROL_ALERT_PREFS:-$DATA_DIR/alert_prefs.json}"
if [ -f "$PREFS" ]; then
  ALERT_PREFS=$(cat "$PREFS" 2>/dev/null)
else
  ALERT_PREFS='{"enabled":true,"types":{}}'
fi

export OMC_DB="$DB" OMC_NOW="$NOW" OMC_DISABLED="$DISABLED" OMC_PREFS="$ALERT_PREFS"
# Final payload is piped through a hard byte cap as a last resort; a runaway
# producer must never be able to retain unbounded output in the long-lived
# shell. Real payloads are far smaller than the 256 KB ceiling.
{ H1="$H1" H6="$H6" H1D="$H1D" CPU="$CPU" MEM="$MEM" GPU="$GPU" PROCS="$PROCS" DISK="$DISK" DISK_R="$DISK_R" DISK_W="$DISK_W" RX="$RX_KBS" TX="$TX_KBS" CTEMP="$CTEMP" GTEMP="$GTEMP" python3 - "$DB" <<'PY'
import json, os, sqlite3, sys, time
from collections import defaultdict

NOW = int(os.environ["OMC_NOW"])
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=3)

# ---- per-app metadata cache
meta = {}
for row in con.execute("SELECT name, publisher, verified, source, desc, exe, pkg FROM app_meta"):
    meta[row[0]] = {"publisher": row[1] or "Unknown", "verified": int(row[2] or 0),
                    "source": row[3] or "unknown", "desc": row[4] or "",
                    "exe": row[5] or "", "pkg": row[6] or ""}

def norm(n):
    return (n or "unknown").lower()

mnorm = {norm(k): v for k, v in meta.items()}

disabled = json.loads(os.environ.get("OMC_DISABLED", "[]"))

# ---- current permission badges (from privacy_state.json: dev|pid|name)
perms = defaultdict(list)
try:
    with open(os.path.join(os.path.dirname(sys.argv[1]), "privacy_state.json")) as f:
        for line in f:
            parts = line.strip().split("|")
            if len(parts) < 3:
                continue
            dev, pid, name = parts[0], parts[1], parts[2]
            if dev == "camera" and "camera" not in perms[name]:
                perms[name].append("camera")
            elif dev == "microphone" and "mic" not in perms[name]:
                perms[name].append("mic")
            elif dev == "location" and "location" not in perms[name]:
                perms[name].append("location")
except Exception:
    pass

def enrich(names):
    out = {}
    for nm in names:
        m = mnorm.get(nm, {})
        out[nm] = {
            "publisher": m.get("publisher", "Unknown"),
            "verified": m.get("verified", 0),
            "source": m.get("source", "unknown"),
            "desc": m.get("desc", ""),
            "exe": m.get("exe", ""),
            "pkg": m.get("pkg", ""),
            "perms": perms.get(nm, []),
            "disabled": nm in disabled,
        }
    return out

snaps = []
try:
    rows = con.execute(
        "SELECT ts, procs FROM proc_history ORDER BY ts DESC LIMIT 90").fetchall()
except Exception:
    rows = []
for ts, payload in sorted(rows):
    try:
        arr = json.loads(payload)
    except Exception:
        arr = []
    snaps.append({"ts": ts, "procs": arr})
p_list0 = snaps[-1]["procs"] if snaps else []

# ---- flatten p_list entries (enrich with meta/perms/disabled + instance count)
counts = defaultdict(int)
for p in p_list0:
    counts[norm(p.get("name"))] += 1
p_list = []
for p in p_list0:
    nm = norm(p.get("name"))
    m = mnorm.get(nm, {})
    pp = dict(p)
    pp["name"] = p.get("name") or "unknown"
    pp["publisher"] = m.get("publisher", "Unknown")
    pp["verified"] = m.get("verified", 0)
    pp.update({"perms": perms.get(nm, []), "instances": counts[nm], "disabled": nm in disabled,
               "source": m.get("source", "unknown"), "desc": m.get("desc", ""),
               "exe": m.get("exe", ""), "pkg": m.get("pkg", "")})
    p_list.append(pp)

# ---- apps: aggregate the latest snapshot by process name
groups = {}
series = {}
for snap in snaps:
    by_name = defaultdict(float)
    for p in snap["procs"]:
        nm = norm(p.get("name"))
        by_name[nm] += p.get("cpu") or 0
    for nm, v in by_name.items():
        series.setdefault(nm, []).append(round(v, 1))
for p in p_list:
    nm = norm(p.get("name"))
    g = groups.setdefault(nm, {"name": p.get("name") or "unknown", "cpu": 0.0,
                               "mem": 0.0, "io": 0.0, "gpu": 0.0, "pids": [],
                               "running": True})
    g["cpu"] += p.get("cpu") or 0
    g["mem"] += p.get("mem") or 0
    g["io"] += p.get("io_kbs") or 0
    g["gpu"] += p.get("gpu") or 0
    g["pids"].append(p.get("pid"))
apps = []
enr = enrich(list(groups.keys()))
for g in groups.values():
    nm = norm(g["name"])
    e = enr[nm]
    g.update(e)
    g["spark"] = series.get(nm, [])
    g["cpu"] = round(g["cpu"], 1)
    g["mem"] = round(g["mem"], 1)
    apps.append(g)
apps.sort(key=lambda x: -x["cpu"])
apps = apps[:60]

# ---- catalog: known apps (previously seen in app_meta) for the Apps inventory
running_names = {norm(p.get("name")) for p in p_list0}
installed = 0
catalog = []
for nm, m in sorted(meta.items()):
    if m.get("publisher") in ("Unknown", "") or m.get("source") in (""):
        continue
    inst = {}
    inst["name"] = nm
    inst["publisher"] = m["publisher"]
    inst["verified"] = m["verified"]
    inst["source"] = m["source"]
    inst["desc"] = m["desc"]
    inst["exe"] = m.get("exe", "")
    inst["pkg"] = m.get("pkg", "")
    inst["disabled"] = nm in disabled
    inst["running"] = norm(nm) in running_names
    inst["perms"] = perms.get(nm, [])
    catalog.append(inst)
    installed += 1
catalog.sort(key=lambda x: (not x["running"], x["name"].lower()))
catalog = catalog[:150]

# ---- alerts: resource thresholds + runaway processes
alerts = []
def alert(kind, severity, msg, ts):
    alerts.append({"kind": kind, "severity": severity, "msg": msg, "ts": ts})

mrow = con.execute("SELECT ts, cpu_pct, mem_used_mb, mem_total_mb, gpu_pct FROM metrics "
                   "ORDER BY ts DESC LIMIT 1").fetchone()
if mrow:
    mts, acpu, amem_mb, amem_tot, agpu = mrow
    amem = amem_mb * 100.0 / (amem_tot or 1)
    if amem >= 85:
        alert("memory", "critical", f"Memory at {round(amem)}%", mts)
    if (acpu or 0) >= 90:
        alert("cpu", "critical", f"CPU peaked at {round(acpu)}%", mts)
    if (agpu or 0) >= 80:
        alert("gpu", "warning", f"GPU usage at {round(agpu)}%", mts)
last_ts = snaps[-1]["ts"] if snaps else (mrow[0] if mrow else NOW)
for p in p_list:
    if (p.get("cpu") or 0) >= 80:
        alert("proc", "critical", f"{p.get('name') or 'unknown'} at {round(p.get('cpu'), 1)}% CPU", last_ts)
    elif (p.get("mem") or 0) >= 30:
        alert("proc", "info", f"{p.get('name') or 'unknown'} using {round(p.get('mem'), 1)}% of memory", last_ts)
alerts = alerts[:16]

# ---- events: persistent log (events table) merged with privacy history.
events = []
lastread = 0
try:
    lastread = int(open(os.path.join(os.path.dirname(sys.argv[1]), "events_lastread_ts")).read().strip())
except Exception:
    pass
evmap = {"start": None, "stop": None}
try:
    for row in con.execute(
            "SELECT id, ts, type, app, publisher, msg, read FROM events ORDER BY id DESC LIMIT 200"):
        events.append({"id": row[0], "ts": row[1], "kind": row[2], "app": row[3] or "",
                       "publisher": row[4] or "", "msg": row[5] or "", "read": int(row[6] or 0)})
    for row in con.execute(
            "SELECT id, ts, action, device, name, pid FROM privacy_events ORDER BY id DESC LIMIT 60"):
        _id, ts, action, device, name, pid = row
        kind = {"camera": "cam_access", "microphone": "mic_access", "location": "location_access"}.get(device, "permission")
        label = {"camera": "camera", "microphone": "microphone", "location": "location"}.get(device, device)
        events.append({"id": _id, "ts": ts, "kind": kind, "app": name or "",
                       "publisher": mnorm.get(norm(name), {}).get("publisher", "Unknown"),
                       "msg": f"{name or 'App'} {'started' if action=='start' else 'stopped'} using the {label}",
                       "read": 1 if ts <= lastread else 0})
except Exception:
    pass
events.sort(key=lambda x: -x["ts"])
events = events[:200]

def jload(s, fallback):
    """Parse a JSON env var; corrupt content must not panic the whole output."""
    try:
        v = json.loads(s)
        return v if v is not None else fallback
    except Exception:
        return fallback

print(json.dumps({
    "cpu": float(os.environ.get("CPU", "0") or 0),
    "mem": int(os.environ.get("MEM", "0") or 0),
    "gpu": float(os.environ.get("GPU", "0") or 0),
    "procs": int(os.environ.get("PROCS", "0") or 0),
    "disk": int(float(os.environ.get("DISK", "0") or 0)),
    "disk_r": int(float(os.environ.get("DISK_R", "0") or 0)),
    "disk_w": int(float(os.environ.get("DISK_W", "0") or 0)),
    "net_rx_kbs": float(os.environ.get("RX", "0") or 0),
    "net_tx_kbs": float(os.environ.get("TX", "0") or 0),
    "ctemp": float(os.environ.get("CTEMP", "0") or 0),
    "gtemp": float(os.environ.get("GTEMP", "0") or 0),
    "history_1h": jload(os.environ.get("H1", "[]"), []),
    "history_6h": jload(os.environ.get("H6", "[]"), []),
    "history_1d": jload(os.environ.get("H1D", "[]"), []),
    "p_list": p_list,
    "snaps": snaps,
    "apps": apps,
    "catalog": catalog,
    "alerts": alerts,
    "events": events,
    "alert_prefs": jload(os.environ.get("OMC_PREFS", "{}"), {}),
    "disabled": disabled,
    "perms": {k: v for k, v in perms.items()},
}))
PY
} | /usr/bin/head -c "${OMCONTROL_MAX_OUT_BYTES:-1048576}" 2>/dev/null