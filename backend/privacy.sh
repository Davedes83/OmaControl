#!/bin/sh
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/bootstrap.sh"
# OmaControl privacy monitor — checks for active webcam/mic/location usage.
# Logs start/stop events into an append-only history for the Privacy tab.
# Outputs JSON: {"devices":[...], "events":[...]}

DATA_DIR="${OMCONTROL_DATA_DIR:-$HOME/.local/share/omcontrol}"
mkdir -p "$DATA_DIR"
DB="${OMCONTROL_DB:-$DATA_DIR/history.db}"
STATE="$DATA_DIR/privacy_state.json"
LOG="$DATA_DIR/privacy_events.log"
NOW=$(date +%s)

# --- Ensure DB + events table exist ---
sqlite3 -cmd ".timeout 1500" "$DB" "CREATE TABLE IF NOT EXISTS privacy_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER,
  action TEXT,
  device TEXT,
  name TEXT,
  pid INTEGER
); CREATE INDEX IF NOT EXISTS idx_priv_ts ON privacy_events(ts);" 2>/dev/null

# --- Collect current access entries: one per line "device|pid|name" ---
TMP=$(mktemp)
: > "$TMP"

# Webcam via fuser; ${device}:/dev/video*
for dev in /dev/video0 /dev/video1 /dev/video2; do
  if [ -c "$dev" ]; then
    PIDS=$(fuser "$dev" 2>/dev/null | tr -s ' ')
    if [ -n "$PIDS" ]; then
      for pid in $PIDS; do
        pid=$(echo "$pid" | tr -d ' ')
        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
          NAME=$(basename "$(readlink /proc/$pid/exe 2>/dev/null)" 2>/dev/null)
          NAME=${NAME:-unknown}
          echo "camera|$pid|$NAME" >> "$TMP"
        fi
      done
    fi
  fi
done

# Microphone via pactl (active capture streams). The real OS pid lives in
# application.process.id (a Client: line is only a PulseAudio client index).
pactl list source-outputs 2>/dev/null | awk '
  /^Source Output #/ { if (pid && name) printf "microphone|%s|%s\n", pid, name; pid=""; name="" }
  /application\.process\.id/ { gsub(/^.* = "/, ""); gsub(/"/, "", $0); pid=$0 }
  tolower($0) ~ /application name:/ { sub(/^[^:]*: */, ""); gsub(/"/, "", $0); name=$0 }
  END { if (pid && name) printf "microphone|%s|%s\n", pid, name }
' >> "$TMP"

# Location service
if systemctl --user is-active geoclue-agent >/dev/null 2>&1; then
  GEO=$(gdbus call --session --dest org.freedesktop.GeoClue2 --object-path /org/freedesktop/GeoClue2/Manager --method org.freedesktop.GeoClue2.Manager.GetClient 2>/dev/null)
fi
if [ -n "$GEO" ]; then
  echo "location|0|geoclue-agent" >> "$TMP"
fi

# --- Diff against previous state to log start/stop events ---
sort -u "$TMP" > "$TMP.sorted"
if [ ! -f "$STATE" ]; then
  # First run: seed state, don't log spurious "start" for pre-existing access
  :
else
  # Each line in state file is "device|pid|name"
  sort -u "$STATE" > "$TMP.prev"
fi
# Accumulate start/stop rows and flush through the parameterized writer in one
# transaction (bound params — device/app names were quoted with sed before).
if [ -f "$TMP.prev" ]; then
  { comm -23 "$TMP.sorted" "$TMP.prev" | while IFS='|' read -r dev pid name; do
      printf 'privacy\t%s\tstart\t%s\t%s\t%s\n' "$NOW" "$dev" "$name" "$pid"
    done
    comm -13 "$TMP.sorted" "$TMP.prev" | while IFS='|' read -r dev pid name; do
      printf 'privacy\t%s\tstop\t%s\t%s\t%s\n' "$NOW" "$dev" "$name" "$pid"
    done
  } | OMCONTROL_DB="$DB" python3 "$(dirname "$0")/sql-ins.py" 2>/dev/null
fi
sort -u "$TMP.sorted" > "$STATE"
rm -f "$TMP" "$TMP.sorted" "$TMP.prev"

# --- Build JSON output ---
DEVICES=""
while IFS='|' read -r dev pid name; do
  ENTRY="{\"pid\":$pid,\"device\":\"$dev\",\"name\":\"$name\"}"
  if [ -n "$DEVICES" ]; then DEVICES="$DEVICES,"; fi
  DEVICES="$DEVICES$ENTRY"
done < "$STATE"

EVENTS=$(sqlite3 -cmd ".timeout 1500" "$DB" "
  SELECT '[' || group_concat(json_object('ts', ts, 'action', action, 'device', device, 'name', name, 'pid', pid)) || ']'
  FROM (SELECT ts, action, device, name, pid FROM privacy_events ORDER BY id DESC LIMIT 30);
" 2>/dev/null)
[ -z "$EVENTS" ] && EVENTS="[]"

cat <<ENDJSON
{"devices":[$DEVICES], "events":$EVENTS}
ENDJSON