#!/bin/sh
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/bootstrap.sh"
# OmControl procs-at — given an epoch timestamp, returns the nearest recorded
# per-process snapshot (top 20 by CPU at that minute) as a JSON array.
# Usage: procs-at.sh <epoch_seconds>
# Outputs [] when no snapshot is within the 150s tolerance (e.g. no data yet).

TS="${1:-0}"
DATA_DIR="${OMCONTROL_DATA_DIR:-$HOME/.local/share/omcontrol}"
DB="${OMCONTROL_DB:-$DATA_DIR/history.db}"

if [ ! -f "$DB" ]; then
  echo "[]"
  exit 0
fi

OUT=$(sqlite3 -cmd ".timeout 1500" "$DB" "
  SELECT procs FROM proc_history
  WHERE ts BETWEEN $((TS - 150)) AND $((TS + 150))
  ORDER BY abs($TS - ts) LIMIT 1;" 2>/dev/null)

if [ -n "$OUT" ]; then
  echo "$OUT"
else
  echo "[]"
fi