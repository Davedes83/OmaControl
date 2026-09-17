#!/bin/sh
# Schema/migration tests for backend/schema.sh.
#
# Exercises every repair path against throwaway databases:
#   * brand-new (no file) and empty (valid file, no objects) databases
#   * version-5-marked DBs missing tables, indexes, or metric columns
#   * combined states that mix a missing index with missing columns
#   * unrecoverable (corrupt) files, which must signal failure
#   * user_version gating and legacy-marker cleanup
#
# Run via tests/run-tests.sh, or directly: ./tests/schema-tests.sh [sh|dash|bash --posix]

set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$DIR/.." && pwd)
. "$DIR/lib.sh"
. "$ROOT/backend/schema.sh"

TMPROOT="${TMPDIR:-/tmp}"

tdir() {
  mktemp -d "$TMPROOT/omc-schema.XXXXXX"
}

q() {
  sqlite3 -cmd ".timeout 1500" "$1" "$2" 2>/dev/null
}

tables() { q "$1" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('metrics','proc_history','app_meta','events');"; }
indexes() { q "$1" "SELECT count(*) FROM sqlite_master WHERE type='index' AND name IN ('idx_metrics_ts','idx_proc_history_ts','idx_events_ts') AND sql IS NOT NULL;"; }
columns() { q "$1" "SELECT count(*) FROM pragma_table_info('metrics');"; }
uv() { q "$1" "PRAGMA user_version;"; }

# A complete repair run returns 0 and verifies everything it owns.
repair_ok() {
  # repair_ok DB [DATA_DIR]
  if schema_repair "$1" "${2:-$1}"; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------- fresh DB
T=$(tdir)
DB="$T/h.db"
schema_repair "$DB" "$T"
rc=$?
check_eq "fresh DB: repair exits 0" "0" "$rc"
check_eq "fresh DB: user_version=5" "5" "$(uv "$DB")"
check_eq "fresh DB: 4 base tables" "4" "$(tables "$DB")"
check_eq "fresh DB: 3 base indexes" "3" "$(indexes "$DB")"
check_eq "fresh DB: 15 metric columns" "15" "$(columns "$DB")"
check_eq "fresh DB: journal_mode=wal" "wal" "$(q "$DB" "PRAGMA journal_mode;")"
if [ -f "$T/.omc_wal_on" ]; then
  ok "fresh DB: WAL marker written"
else
  fail "fresh DB: WAL marker written"
fi
rm -rf "$T"

# ----------------------------------------------------- empty (no objects) DB
T=$(tdir)
DB="$T/h.db"
: >"$DB"
repair_ok "$DB" "$T"
check_eq "empty DB: repair exits 0" "0" "$?"
check_eq "empty DB: user_version=5" "5" "$(uv "$DB")"
check_eq "empty DB: 4 base tables" "4" "$(tables "$DB")"
check_eq "empty DB: 3 base indexes" "3" "$(indexes "$DB")"
check_eq "empty DB: journal_mode=wal" "wal" "$(q "$DB" "PRAGMA journal_mode;")"
rm -rf "$T"

# ---------------------------------------- v5-marked but metrics-table missing
T=$(tdir)
DB="$T/h.db"
schema_repair "$DB" "$T" || true
sqlite3 "$DB" "DROP TABLE metrics; PRAGMA user_version=5;" 2>/dev/null
schema_repair "$DB" "$T"
rc=$?
check_eq "missing metrics table: repair exits 0" "0" "$rc"
check_eq "missing metrics table: 4 tables" "4" "$(tables "$DB")"
check_eq "missing metrics table: metric columns restored" "15" "$(columns "$DB")"
check_eq "missing metrics table: user_version stays 5" "5" "$(uv "$DB")"
rm -rf "$T"

# --------------------------------- v5-marked but the other three tables gone
T=$(tdir)
DB="$T/h.db"
schema_repair "$DB" "$T" || true
sqlite3 "$DB" "DROP TABLE proc_history; DROP TABLE app_meta; DROP TABLE events; PRAGMA user_version=5;" 2>/dev/null
schema_repair "$DB" "$T"
rc=$?
check_eq "missing proc_history/app_meta/events: repair exits 0" "0" "$rc"
check_eq "missing proc_history/app_meta/events: 4 tables" "4" "$(tables "$DB")"
check_eq "missing proc_history/app_meta/events: 3 indexes" "3" "$(indexes "$DB")"
check_eq "missing proc_history/app_meta/events: user_version stays 5" "5" "$(uv "$DB")"
rm -rf "$T"

# ------------------------------------------------- v5-marked but indexes gone
T=$(tdir)
DB="$T/h.db"
schema_repair "$DB" "$T" || true
sqlite3 "$DB" "DROP INDEX idx_metrics_ts; DROP INDEX idx_proc_history_ts; DROP INDEX idx_events_ts; PRAGMA user_version=5;" 2>/dev/null
schema_repair "$DB" "$T"
rc=$?
check_eq "missing indexes: repair exits 0" "0" "$rc"
check_eq "missing indexes: 3 indexes restored" "3" "$(indexes "$DB")"
check_eq "missing indexes: user_version stays 5" "5" "$(uv "$DB")"
rm -rf "$T"

# ----------------------------------------- v4-layout metrics marked as v5
# Both table/index objects complete, but the six v5 metric columns absent —
# the ALTER path must repair without touching user_version.
T=$(tdir)
DB="$T/h.db"
sqlite3 "$DB" "
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
CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER, type TEXT,
  app TEXT, publisher TEXT, msg TEXT, read INTEGER DEFAULT 0);
CREATE INDEX idx_events_ts ON events(ts);
PRAGMA user_version=5;" 2>/dev/null
schema_repair "$DB" "$T"
rc=$?
check_eq "v4-layout marked v5: repair exits 0" "0" "$rc"
check_eq "v4-layout marked v5: metric columns added" "15" "$(columns "$DB")"
check_eq "v4-layout marked v5: user_version stays 5" "5" "$(uv "$DB")"
rm -rf "$T"

# --------------------------------------- unmarked v4-layout DB (version bump)
# user_version squeezed only after the whole schema verifies.
T=$(tdir)
DB="$T/h.db"
sqlite3 "$DB" "
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
CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER, type TEXT,
  app TEXT, publisher TEXT, msg TEXT, read INTEGER DEFAULT 0);
CREATE INDEX idx_events_ts ON events(ts);" 2>/dev/null
schema_repair "$DB" "$T"
rc=$?
check_eq "unmarked v4-layout: repair exits 0" "0" "$rc"
check_eq "unmarked v4-layout: metric columns added" "15" "$(columns "$DB")"
check_eq "unmarked v4-layout: user_version bumped to 5" "5" "$(uv "$DB")"
rm -rf "$T"

# ---------------------------------------------------------- corrupt file
T=$(tdir)
DB="$T/h.db"
printf '%s\n' "this is not a sqlite database" >"$DB"
schema_repair "$DB" "$T"
rc=$?
if [ "$rc" -ne 0 ]; then
  ok "corrupt DB: repair signals failure (exit $rc)"
else
  fail "corrupt DB: repair signals failure (exit $rc)"
fi
rm -rf "$T"

# ----------------------------------------------------- legacy marker cleanup
T=$(tdir)
DB="$T/h.db"
schema_repair "$DB" "$T" || true
touch "$DB.schema_mark_v4"
schema_repair "$DB" "$T" || true
if [ -e "$DB.schema_mark_v4" ]; then
  fail "legacy marker: removed after repair"
else
  ok "legacy marker: removed after repair"
fi
rm -rf "$T"

# ------------------------------------------------------------ idempotency
T=$(tdir)
DB="$T/h.db"
schema_repair "$DB" "$T" || true
schema_repair "$DB" "$T"
rc=$?
check_eq "second repair (idempotent): exits 0" "0" "$rc"
check_eq "second repair (idempotent): user_version stays 5" "5" "$(uv "$DB")"
check_eq "second repair (idempotent): 4 tables" "4" "$(tables "$DB")"
check_eq "second repair (idempotent): 3 indexes" "3" "$(indexes "$DB")"
check_eq "second repair (idempotent): 15 metric columns" "15" "$(columns "$DB")"
rm -rf "$T"

finish
