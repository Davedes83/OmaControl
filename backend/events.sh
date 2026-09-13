#!/bin/sh
# OmControl events — persistent audit-log interface.
# Usage: events.sh list|unread|read <id>|read-all|clear [--limit N]
DATA_DIR="${OMCONTROL_DATA_DIR:-$HOME/.local/share/omcontrol}"
DB="${OMCONTROL_DB:-$DATA_DIR/history.db}"
ACTION="$1"
LIMIT="${3:-200}"
case "$LIMIT" in
  ''|*[!0-9]*|0) echo "usage: events.sh list [--limit <positive integer>]" >&2; exit 1 ;;
esac

if [ "$ACTION" = "list" ]; then
  sqlite3 -cmd ".timeout 3000" "$DB" "
    SELECT '[' || group_concat(json_object('id', id, 'ts', ts, 'type', type, 'app', app,
                                           'publisher', publisher, 'msg', msg, 'read', read)) || ']'
    FROM (SELECT id, ts, type, app, publisher, msg, read FROM events ORDER BY id DESC LIMIT $LIMIT);" 2>/dev/null
  [ -z "$(sqlite3 -cmd '.timeout 3000' "$DB" 'SELECT 1 FROM events LIMIT 1;' 2>/dev/null)" ] && echo "[]"
  echo ""
elif [ "$ACTION" = "unread" ]; then
  sqlite3 -cmd ".timeout 3000" "$DB" "SELECT count(*) FROM events WHERE read=0;" 2>/dev/null
elif [ "$ACTION" = "read" ]; then
  case "$2" in
    ''|*[!0-9]*) echo "usage: events.sh read <integer id>" >&2; exit 1 ;;
  esac
  sqlite3 -cmd ".timeout 3000" "$DB" "UPDATE events SET read=1 WHERE id=$2;" 2>/dev/null
  echo ok
elif [ "$ACTION" = "read-all" ]; then
  sqlite3 -cmd ".timeout 3000" "$DB" "UPDATE events SET read=1;" 2>/dev/null
  date +%s > "$DATA_DIR/events_lastread_ts" 2>/dev/null
  echo ok
elif [ "$ACTION" = "clear" ]; then
  sqlite3 -cmd ".timeout 3000" "$DB" "DELETE FROM events; DELETE FROM privacy_events;" 2>/dev/null
  date +%s > "$DATA_DIR/events_lastread_ts" 2>/dev/null
  echo ok
else
  echo "usage: events.sh <list|unread|read ID|read-all|clear>" >&2
  exit 1
fi