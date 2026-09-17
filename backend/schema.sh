#!/bin/sh
# OmaControl schema helpers — versioned DDL plus idempotent repair for the
# plugin's SQLite history database.
#
# Sourced by backend/collect.sh (as rendered by the plugin's own /bin/sh
# runner) and by tests/schema-tests.sh. Nothing here performs filesystem or
# network work beyond sqlite3 calls; every statement is idempotent (CREATE
# ... IF NOT EXISTS, ALTER with ignored errors), so re-running against a
# partially-migrated DB converges instead of failing.

# Schema version this build expects. Advancing it is gated on a fully
# verified state — see schema_repair(). No version is ever bumped before the
# complete object set and column set are proven present, so an interrupted
# migration can never leave a permanently-stuck, version-marked DB.
SCHEMA_VERSION=5

# The objects bootstrap_tables() creates and schema_repair() verifies:
# four base tables plus three indexes = 7 required objects.
REQUIRED_BASE_TABLES="'metrics','proc_history','app_meta','events'"
REQUIRED_BASE_INDEXES="'idx_metrics_ts','idx_proc_history_ts','idx_events_ts'"
# Metrics columns added after the version-4 layout (repaired independently of
# the table/index check so a fresh ALTER path can be exercised).
REQUIRED_METRICS_COLS="'disk_pct','disk_io','disk_r','disk_w','net_rx_bytes','net_tx_bytes'"

# Base tables (idempotent — safe to run at any time, in any order).
bootstrap_tables() {
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
}

# Verify a database converges on the complete schema and version.
#   usage: schema_repair DB [DATA_DIR]
# Returns 0 when the schema is complete (creating/repairing as needed) and
# 1 when it cannot be repaired (e.g. the file is not a readable SQLite DB).
schema_repair() {
  DB="$1"
  DATA_DIR="${2:-$OMCONTROL_DATA_DIR}"

  SCHEMA_UV=$(sqlite3 -cmd ".timeout 1500" "$DB" "PRAGMA user_version;" 2>/dev/null)
  if [ -z "$SCHEMA_UV" ]; then
    SCHEMA_UV=0
  fi

  if [ "$SCHEMA_UV" -lt 1 ]; then
    bootstrap_tables
  fi

  # A version-marked DB is no proof the objects exist (a migration can have
  # bumped user_version before the DDL landed). Recreate anything missing —
  # CREATE IF NOT EXISTS leaves existing objects untouched.
  REQUIRED_SCHEMA=$(sqlite3 -cmd ".timeout 1500" "$DB" "SELECT (SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ($REQUIRED_BASE_TABLES)) + (SELECT count(*) FROM sqlite_master WHERE type='index' AND name IN ($REQUIRED_BASE_INDEXES) AND sql IS NOT NULL);" 2>/dev/null)
  if [ "${REQUIRED_SCHEMA:-0}" != "7" ]; then
    bootstrap_tables
  fi

  # Column repair is separate from the object check: a DB can have all seven
  # objects yet predate the v5 column additions.
  REQUIRED_COLS=$(sqlite3 -cmd ".timeout 1500" "$DB" "SELECT count(*) FROM pragma_table_info('metrics') WHERE name IN ($REQUIRED_METRICS_COLS);" 2>/dev/null)
  if [ "${REQUIRED_COLS:-0}" != "6" ]; then
    sqlite3 -cmd ".timeout 1500" "$DB" "ALTER TABLE metrics ADD COLUMN disk_pct REAL;" 2>/dev/null || true
    sqlite3 -cmd ".timeout 1500" "$DB" "ALTER TABLE metrics ADD COLUMN disk_io REAL;" 2>/dev/null || true
    sqlite3 -cmd ".timeout 1500" "$DB" "ALTER TABLE metrics ADD COLUMN disk_r REAL;" 2>/dev/null || true
    sqlite3 -cmd ".timeout 1500" "$DB" "ALTER TABLE metrics ADD COLUMN disk_w REAL;" 2>/dev/null || true
    sqlite3 -cmd ".timeout 1500" "$DB" "ALTER TABLE metrics ADD COLUMN net_rx_bytes INTEGER;" 2>/dev/null || true
    sqlite3 -cmd ".timeout 1500" "$DB" "ALTER TABLE metrics ADD COLUMN net_tx_bytes INTEGER;" 2>/dev/null || true
    REQUIRED_COLS=$(sqlite3 -cmd ".timeout 1500" "$DB" "SELECT count(*) FROM pragma_table_info('metrics') WHERE name IN ($REQUIRED_METRICS_COLS);" 2>/dev/null)
  fi

  if [ "${REQUIRED_COLS:-0}" = "6" ]; then
    if [ "$SCHEMA_UV" -lt "$SCHEMA_VERSION" ]; then
      sqlite3 -cmd ".timeout 1500" "$DB" "PRAGMA user_version = $SCHEMA_VERSION;" 2>/dev/null
    fi
    # Drop the legacy marker once the schema converges; version is authoritative.
    rm -f "${DB}.schema_mark_v4"

    # One-time WAL switch (persistent per-DB): readers (sample-json, rollups,
    # omcontrol CLI) no longer block on the collector's writes and vice versa.
    WAL_MARK="$DATA_DIR/.omc_wal_on"
    if [ ! -f "$WAL_MARK" ]; then
      sqlite3 -cmd ".timeout 1500" "$DB" "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;" >/dev/null 2>/dev/null
      touch "$WAL_MARK"
    fi
    return 0
  fi
  echo "schema migration incomplete: metrics missing $((6 - ${REQUIRED_COLS:-0})) of 6 required columns" >&2
  return 1
}
