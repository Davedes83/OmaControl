#!/bin/sh
# OmaControl sample-json — light DB snapshot for the standalone app window:
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
  ROLLS_OUT=$(
    sqlite3 -cmd ".timeout 3000" "$DB" <<SQL 2>/dev/null
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
  printf '%s\n%s\n%s\n' "$H1" "$H6" "$H1D" >"$ROLL_CACHE.tmp.$$"
  mv "$ROLL_CACHE.tmp.$$" "$ROLL_CACHE"
  echo "$NOW" >"$ROLL_STAMP"
fi

# Live network rates from the two most recent metric samples (KB/s).
NET_L=$(sqlite3 -cmd ".timeout 3000" "$DB" "SELECT ts, COALESCE(net_rx_bytes,0), COALESCE(net_tx_bytes,0) FROM metrics WHERE net_rx_bytes IS NOT NULL ORDER BY ts DESC LIMIT 2;" 2>/dev/null)
RX_KBS=0
TX_KBS=0
OLD_IFS=$IFS
IFS='| 
'
set -- $NET_L
IFS=$OLD_IFS
T2=$1
B2=$2
C2=$3
T1=$4
B1=$5
C1=$6
if [ -n "$T2" ] && [ -n "$T1" ] && [ "$T2" != "$T1" ]; then
  DT=$((T2 - T1))
  [ "$DT" -gt 0 ] && B_DT=$((B2 - B1)) && C_DT=$((C2 - C1)) &&
    RX_KBS=$(awk "BEGIN{printf \"%.1f\", ($B_DT>0? $B_DT:0) / $DT / 1024}") &&
    TX_KBS=$(awk "BEGIN{printf \"%.1f\", ($C_DT>0? $C_DT:0) / $DT / 1024}")
fi
[ -z "$RX_KBS" ] && RX_KBS=0
[ -z "$TX_KBS" ] && TX_KBS=0

# Disabled app names from rules.json.
DISABLED=$(
  python3 - "$RULES" <<'PY'
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
export OMC_BACKEND="$SELF_DIR"
# Final payload is piped through a hard byte cap as a last resort; a runaway
# producer must never be able to retain unbounded output in the long-lived
# shell. Real payloads are far smaller than the 256 KB ceiling.
{
  H1="$H1" H6="$H6" H1D="$H1D" CPU="$CPU" MEM="$MEM" GPU="$GPU" PROCS="$PROCS" DISK="$DISK" DISK_R="$DISK_R" DISK_W="$DISK_W" RX="$RX_KBS" TX="$TX_KBS" CTEMP="$CTEMP" GTEMP="$GTEMP" python3 - "$DB" <<'PY'
import json, os, sqlite3, sys, time
from collections import defaultdict

NOW = int(os.environ["OMC_NOW"])
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=3)

# ---- active alert thresholds: same single source as collect.sh/Model.js.
# omc_prefs.resolve_thresholds maps the named profile + per-metric overrides
# from alert_prefs.json into the concrete numbers the hysteresis below uses.
sys.path.insert(0, os.environ.get("OMC_BACKEND", ""))
_TH_DEFAULTS = {"cpu_pct": 90, "mem_pct": 85, "gpu_pct": 80, "cpu_temp": 85,
                "gpu_temp": 85, "proc_cpu_pct": 80, "proc_mem_pct": 30,
                "hold": 90}
try:
    from omc_prefs import alert_profile, resolve_thresholds
    _prefsobj = json.loads(os.environ.get("OMC_PREFS", "{}") or "{}")
    TH = resolve_thresholds(_prefsobj)
    ALERT_PROFILE = alert_profile(_prefsobj)
except Exception:
    TH = dict(_TH_DEFAULTS)
    ALERT_PROFILE = "medium"
TH_HOLD = int(float(TH.get("hold", 90)))

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
catalog.sort(key=lambda x: (not x["running"], x["name"].lower()))
catalog = catalog[:150]

# ---- alerts: resource thresholds (sustained + debounce) + runaway processes.
# Hysteresis: a resource alert needs the latest sample over threshold AND at
# least 2 of the last 3 samples over it (a single-tick spike is ignored), and
# once raised it holds for a grace window so the bell/badge doesn't flicker as
# the load hovers around the threshold. State persists across calls in
# .alert_state.json (atomic tmp+rename, never a torn read).
alerts = []
state_path = os.path.join(os.path.dirname(sys.argv[1]), ".alert_state.json")
try:
    state = json.load(open(state_path))
except Exception:
    state = {}

def sustained(fn):
    over = 0
    for r in mrows:
        if fn(r):
            over += 1
    return over >= 2 and bool(mrows) and fn(mrows[0])

def update_alert(kind, firing, severity, msg, ts, priv=False, hold=None):
    st = state.get(kind, {})
    on = bool(st.get("on"))
    since = st.get("since")
    last_msg = st.get("msg", "")
    if hold is None:
        hold = TH_HOLD
    if firing:
        if not on or not since:
            since = ts
        on = True
        last_msg = msg
    elif on:
        age = NOW - (since or ts)
        if age < 0 or age >= hold:
            on = False
    if on and (msg or not any(a["kind"] == kind for a in alerts)) and \
            not any(a["kind"] == kind and a["msg"] == (msg or last_msg) for a in alerts):
        alerts.append({"kind": kind, "severity": severity, "msg": msg or last_msg,
                       "ts": since or ts, "priv": priv})
    state[kind] = {"on": on}
    if since is not None:
        state[kind]["since"] = since
    state[kind]["msg"] = last_msg

mrows = con.execute("SELECT ts, cpu_pct, mem_used_mb, mem_total_mb, gpu_pct FROM metrics "
                    "ORDER BY ts DESC LIMIT 3").fetchall()

def mem_fn(r):
    return r[2] * 100.0 / (r[3] or 1) >= TH["mem_pct"]

def cpu_fn(r):
    return (r[1] or 0) >= TH["cpu_pct"]

def gpu_fn(r):
    return (r[4] or 0) >= TH["gpu_pct"]

if mrows:
    amem = mrows[0][2] * 100.0 / (mrows[0][3] or 1)
    if sustained(mem_fn):
        update_alert("memory", True, "critical", "Memory at %s%%" % round(amem), mrows[0][0])
    else:
        update_alert("memory", False, "critical", "Memory at %s%%" % round(amem), mrows[0][0])
    if sustained(cpu_fn):
        update_alert("cpu", True, "critical", "CPU peaked at %s%%" % round(mrows[0][1] or 0), mrows[0][0])
    else:
        update_alert("cpu", False, "critical", "CPU peaked at %s%%" % round(mrows[0][1] or 0), mrows[0][0])
    if sustained(gpu_fn):
        update_alert("gpu", True, "warning", "GPU usage at %s%%" % round(mrows[0][4] or 0), mrows[0][0])
    else:
        update_alert("gpu", False, "warning", "GPU usage at %s%%" % round(mrows[0][4] or 0), mrows[0][0])
last_ts = snaps[-1]["ts"] if snaps else (mrows[0][0] if mrows else NOW)
# Process alerts are aggregated and keyed only by kind ("proc_cpu"/
# "proc_mem"), not per process. A per-process key would make N offenders
# write the same state slot and stomp one another's message (and let the win
# of a later under-threshold process clear a live alert). Aggregating yields
# one stable, bounded entry ("3 processes using high CPU") top-offender-first.
cpu_procs = sorted([(p, p.get("cpu") or 0) for p in p_list if (p.get("cpu") or 0) >= TH["proc_cpu_pct"]],
                   key=lambda x: -x[1])
mem_procs = sorted([(p, p.get("mem") or 0) for p in p_list if (p.get("mem") or 0) >= TH["proc_mem_pct"]],
                   key=lambda x: -x[1])


def proc_cpu_msg(procs):
    if len(procs) == 1:
        p, v = procs[0]
        nm = p.get("name") or "unknown"
        known = mnorm.get(norm(nm), {}).get("publisher") not in ("", "Unknown", None)
        return "%s at %s%% CPU" % (nm, round(v, 1)) if known else "A process is using %s%% CPU" % round(v, 1)
    p, v = procs[0]
    nm = p.get("name") or "unknown"
    known = mnorm.get(norm(nm), {}).get("publisher") not in ("", "Unknown", None)
    if not known:
        return "%d processes are using high CPU" % len(procs)
    return "%d processes using high CPU (top: %s at %s%%)" % (len(procs), nm, round(v, 1))


def proc_mem_msg(procs):
    if len(procs) == 1:
        p, v = procs[0]
        nm = p.get("name") or "unknown"
        known = mnorm.get(norm(nm), {}).get("publisher") not in ("", "Unknown", None)
        return "%s using %s%% of memory" % (nm, round(v, 1)) if known else "A process is using %s%% of memory" % round(v, 1)
    p, v = procs[0]
    nm = p.get("name") or "unknown"
    known = mnorm.get(norm(nm), {}).get("publisher") not in ("", "Unknown", None)
    if not known:
        return "%d processes are using high memory" % len(procs)
    return "%d processes using high memory (top: %s at %s%%)" % (len(procs), nm, round(v, 1))


if cpu_procs:
    update_alert("proc_cpu", True, "critical", proc_cpu_msg(cpu_procs), last_ts, priv=True)
else:
    update_alert("proc_cpu", False, "critical", "", last_ts, priv=True)
if mem_procs:
    update_alert("proc_mem", True, "info", proc_mem_msg(mem_procs), last_ts, priv=True)
else:
    update_alert("proc_mem", False, "info", "", last_ts, priv=True)
alerts = alerts[:16]
try:
    tmp_path = state_path + ".tmp." + str(os.getpid())
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(state, f)
    os.replace(tmp_path, state_path)
except Exception:
    pass

# ---- events: persistent log (events table) merged with privacy history.
events = []
lastread = 0
try:
    lastread = int(open(os.path.join(os.path.dirname(sys.argv[1]), "events_lastread_ts")).read().strip())
except Exception:
    pass
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
    "alert_profile": ALERT_PROFILE,
    "alert_thresholds": {k: float(v) for k, v in TH.items()},
    "disabled": disabled,
    "perms": {k: v for k, v in perms.items()},
}))
PY
} | /usr/bin/head -c "${OMCONTROL_MAX_OUT_BYTES:-1048576}" 2>/dev/null
