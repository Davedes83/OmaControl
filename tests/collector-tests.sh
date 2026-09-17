#!/bin/sh
# End-to-end collector test in an isolated data directory.
#
# Stages a damaged, version-5-marked database (missing the v5 metric columns
# AND the events index), then runs the real collector against a throwaway
# $OMCONTROL_DATA_DIR/$OMCONTROL_DB. Verifies, without ever touching the
# user's real database:
#   * schema repair converges (tables, indexes, columns, user_version, WAL)
#   * the collector exits 0 and emits parseable JSON with the core keys
#   * a second run is equally clean (idempotent repair / steady state)
#   * transient temp files are cleaned up (trap + TMPFILES)
#   * the standalone reader (sample-json.sh) still produces valid JSON
#
# Run via tests/run-tests.sh, or directly: ./tests/collector-tests.sh [sh|dash|bash --posix]

set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$DIR/.." && pwd)
. "$DIR/lib.sh"

TMPROOT="${TMPDIR:-/tmp}"
T=$(mktemp -d "$TMPROOT/omc-collector.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM

export OMCONTROL_DATA_DIR="$T"
export OMCONTROL_DB="$T/history.db"

q() { sqlite3 -cmd ".timeout 1500" "$1" "$2" 2>/dev/null; }

# Marker-imperfect damaged DB: all four tables exist (so the table object
# count passes) with their real, never-changed column sets, but the v5 metric
# columns and the events index are missing (so both the ALTER path and the
# recreate-index path must fire). This mirrors a genuine marked-v5 database
# whose migration stalled partway.
sqlite3 "$OMCONTROL_DB" "
CREATE TABLE metrics (ts INTEGER PRIMARY KEY, cpu_pct REAL, mem_used_mb INTEGER,
  mem_total_mb INTEGER, gpu_pct REAL, gpu_mem_mb INTEGER, gpu_temp INTEGER,
  cpu_temp INTEGER, proc_count INTEGER);
CREATE INDEX idx_metrics_ts ON metrics(ts);
CREATE TABLE proc_history (ts INTEGER PRIMARY KEY, procs TEXT NOT NULL);
CREATE INDEX idx_proc_history_ts ON proc_history(ts);
CREATE TABLE app_meta (
  name TEXT PRIMARY KEY, exe TEXT, pkg TEXT, publisher TEXT,
  desc TEXT, verified INTEGER DEFAULT 0, source TEXT DEFAULT 'unknown',
  first_seen INTEGER, updated INTEGER
);
CREATE TABLE events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER, type TEXT, app TEXT, publisher TEXT, msg TEXT, read INTEGER DEFAULT 0
);
PRAGMA user_version=5;" 2>/dev/null

run_interp "$ROOT/backend/collect.sh" >"$T/out1.json" 2>"$T/out1.err"
rc1=$?
check_eq "collect #1: exits 0" "0" "$rc1"
if [ "$rc1" -ne 0 ]; then
  echo "  # collect #1 stderr:"
  sed 's/^/  /' "$T/out1.err"
fi

check_eq "collect #1: user_version=5" "5" "$(q "$OMCONTROL_DB" "PRAGMA user_version;")"
check_eq "collect #1: 4 base tables" "4" "$(q "$OMCONTROL_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('metrics','proc_history','app_meta','events');")"
check_eq "collect #1: 3 base indexes" "3" "$(q "$OMCONTROL_DB" "SELECT count(*) FROM sqlite_master WHERE type='index' AND name IN ('idx_metrics_ts','idx_proc_history_ts','idx_events_ts') AND sql IS NOT NULL;")"
check_eq "collect #1: 15 metric columns" "15" "$(q "$OMCONTROL_DB" "SELECT count(*) FROM pragma_table_info('metrics');")"
check_eq "collect #1: journal_mode=wal" "wal" "$(q "$OMCONTROL_DB" "PRAGMA journal_mode;")"
if [ -f "$T/.omc_wal_on" ]; then
  ok "collect #1: WAL marker written"
else
  fail "collect #1: WAL marker written"
fi

python3 - "$T/out1.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for key in ("ts", "cpu_pct", "mem_used_mb", "proc_count", "processes"):
    if key not in data:
        sys.exit("collect #1: JSON missing key %r" % key)
PY
rc=$?
check_eq "collect #1: JSON parses with core keys" "0" "$rc"

run_interp "$ROOT/backend/collect.sh" >"$T/out2.json" 2>"$T/out2.err"
rc2=$?
check_eq "collect #2 (steady state): exits 0" "0" "$rc2"
python3 - "$T/out2.json" <<'PY'
import json, sys
json.load(open(sys.argv[1]))
PY
check_eq "collect #2 (steady state): JSON parses" "0" "$?"

# Transients are named with a `.<name>.$$` PID suffix, so any remaining file
# whose basename ends in a digit is an uncleaned temp. mindepth 1 keeps the
# temp dir itself (mktemp's random suffix can end in a digit) out of the scan.
left=$(find "$T" -mindepth 1 -maxdepth 1 -name '*[0-9]' | wc -l)
check_eq "collect: no transient temp files left behind" "0" "$left"

run_interp "$ROOT/backend/sample-json.sh" >"$T/sample.json" 2>"$T/sample.err"
rcs=$?
check_eq "sample-json: exits 0" "0" "$rcs"
if [ "$rcs" -eq 0 ]; then
  python3 - "$T/sample.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for key in ("cpu", "mem", "procs", "apps", "events", "alert_prefs"):
    if key not in data:
        sys.exit("sample-json: JSON missing key %r" % key)
PY
  check_eq "sample-json: JSON parses with core keys" "0" "$?"
else
  echo "  # sample-json stderr:"
  sed 's/^/  /' "$T/sample.err" 2>/dev/null
fi

if [ -f "$T/history.db" ]; then
  ok "collect: wrote to the isolated data directory only"
else
  fail "collect: wrote to the isolated data directory only"
fi

finish
