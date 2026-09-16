#!/bin/sh
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/bootstrap.sh"
# OmControl event-context — enrich a flagged event with full context:
# system state at the moment (nearest metrics row), app metadata (app_meta),
# and sibling-event counts. Called from the event detail popup.
#
# Usage: event-context.sh <ts> <app> <kind>
# Output: JSON object with state, app, and sibling fields.

TS="${1:-0}"
APP="${2:-}"
KIND="${3:-}"
DATA_DIR="${OMCONTROL_DATA_DIR:-$HOME/.local/share/omcontrol}"
DB="${OMCONTROL_DB:-$DATA_DIR/history.db}"

if [ -z "$TS" ] || [ ! -f "$DB" ]; then
  echo "{}"
  exit 0
fi

LC_ALL=C DB="$DB" TS="$TS" APP="$APP" KIND="$KIND" python3 - "$DB" <<'PY'
import json, os, sqlite3, sys

db    = sys.argv[1]
ts    = int(os.environ["TS"] or 0)
app   = os.environ.get("APP", "").strip()
kind  = os.environ.get("KIND", "").strip()

out = {"ts": ts, "app_name": app, "kind": kind}

if not os.path.exists(db):
    print(json.dumps(out)); sys.exit()

con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=3)
try:
    # ---- nearest system-metrics snapshot (±5 min) ----
    row = con.execute(
        "SELECT cpu_pct, mem_used_mb, mem_total_mb, gpu_pct, "
        "       cpu_temp, gpu_temp, proc_count "
        "FROM metrics WHERE ts >= ? ORDER BY ts ASC LIMIT 1",
        (ts - 300,)).fetchone()
    if not row:
        row = con.execute(
            "SELECT cpu_pct, mem_used_mb, mem_total_mb, gpu_pct, "
            "       cpu_temp, gpu_temp, proc_count "
            "FROM metrics WHERE ts <= ? ORDER BY ts DESC LIMIT 1",
            (ts + 300,)).fetchone()
    if row:
        cpu, memu, memt, gpu, ctemp, gtemp, procs = row
        out["state"] = {
            "cpu":     round(cpu or 0, 1),
            "mem_pct": round((memu or 0) * 100.0 / memt) if memt else 0,
            "mem_mb":  memu or 0,
            "gpu":     round(gpu or 0, 1),
            "cpu_temp": ctemp or 0,
            "gpu_temp": gtemp or 0,
            "procs":   procs or 0,
        }

    # ---- app metadata from the app_meta cache ----
    if app:
        arow = con.execute(
            "SELECT publisher, verified, desc, exe "
            "FROM app_meta WHERE LOWER(name)=LOWER(?) LIMIT 1",
            (app,)).fetchone()
        if arow:
            out["app"] = {
                "publisher": arow[0] or "",
                "verified":  int(arow[1] or 0),
                "desc":      arow[2] or "",
                "exe":       arow[3] or "",
            }

    # ---- sibling-event counts (last 7 days) ----
    week_ago = ts - 604800
    if app:
        out["app_count"] = con.execute(
            "SELECT count(*) FROM events "
            "WHERE LOWER(app)=LOWER(?) AND ts >= ?",
            (app, week_ago)).fetchone()[0]
    if kind:
        out["kind_count"] = con.execute(
            "SELECT count(*) FROM events "
            "WHERE LOWER(type)=LOWER(?) AND ts >= ?",
            (kind, week_ago)).fetchone()[0]

    out["ok"] = True
finally:
    con.close()

print(json.dumps(out))
PY
