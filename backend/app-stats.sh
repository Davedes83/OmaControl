#!/bin/sh
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/bootstrap.sh"
# OmaControl app-stats — aggregate per-app resource usage since tracking start,
# derived from the proc_history snapshots. Prints one JSON object:
#   {"name":..., "samples":N, "first_ts":S, "last_ts":S,
#    "max_cpu":maxPct,"avg_cpu":avgPct,"max_mem_mb":maxMB,"avg_mem_mb":avgMB,
#    "max_gpu":maxPct,"max_io_kbs":maxKBps}
DATA_DIR="${OMCONTROL_DATA_DIR:-$HOME/.local/share/omcontrol}"
DB="${OMCONTROL_DB:-$DATA_DIR/history.db}"
NAME="$1"

if [ -z "$NAME" ] || [ ! -f "$DB" ]; then
  echo '{}'
  exit 0
fi

LC_ALL=C NAME="$NAME" python3 - "$DB" <<'PY'
import json, os, sqlite3, sys
db, name = sys.argv[1], os.environ["NAME"]
cores = os.cpu_count() or 1
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
agg = {}
for (ts, procs,) in con.execute("SELECT ts, procs FROM proc_history ORDER BY ts"):
    try:
        arr = json.loads(procs)
    except Exception:
        continue
    for p in arr or []:
        if p.get("name") != name:
            continue
        cpu = p.get("cpu", 0) or 0
        mem = p.get("mem", 0) or 0
        gpu = p.get("gpu", 0) or 0
        io = p.get("io_kbs", 0) or 0
        if agg.get("max_cpu", -1) < cpu: agg["max_cpu"] = cpu
        if agg.get("max_mem_mb", -1) < mem: agg["max_mem_mb"] = mem
        if agg.get("max_gpu", -1) < gpu: agg["max_gpu"] = gpu
        if agg.get("max_io_kbs", -1) < io: agg["max_io_kbs"] = io
        agg["samples"] = agg.get("samples", 0) + 1
        agg["sum_cpu"] = agg.get("sum_cpu", 0.0) + cpu
        agg["sum_mem"] = agg.get("sum_mem", 0.0) + mem
        if agg.get("first_ts") is None: agg["first_ts"] = ts
        agg["last_ts"] = ts
if not agg.get("samples"):
    print("{}"); raise SystemExit
n = agg["samples"]
out = {
    "name": name,
    "cores": cores,
    "samples": n,
    "first_ts": agg.get("first_ts"),
    "last_ts": agg.get("last_ts"),
    "max_cpu": round(agg.get("max_cpu", 0), 1),
    "avg_cpu": round(agg.get("sum_cpu", 0.0) / n, 1),
    "max_mem_mb": round(agg.get("max_mem_mb", 0), 1),
    "avg_mem_mb": round(agg.get("sum_mem", 0.0) / n, 1),
    "max_gpu": round(agg.get("max_gpu", 0), 1),
    "max_io_kbs": round(agg.get("max_io_kbs", 0), 1),
}
print(json.dumps(out))
PY
