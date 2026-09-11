#!/bin/sh
# OmControl privacy monitor — checks for active webcam/mic/location usage.
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

# Microphone via pactl (active capture streams)
pactl list source-outputs 2>/dev/null | awk '
  /^Source Output #/ { if (pid && name) printf "microphone|%s|%s\n", pid, name; pid=""; name="" }
  /Client:/ { gsub(/.*PID: /, ""); gsub(/[^0-9].*/, ""); pid=$0 }
  /Application Name:/ { gsub(/.*: /, ""); gsub(/"/, "", $0); name=$0 }
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
if [ -f "$STATE" ]; then
  # Each line in state file is "device|pid|name"
  sort -u "$STATE" > "$TMP.prev"
  sq() {
    printf '%s' "$1" | sed "s/'/''/g"
  }
  # Newly appeared lines
  comm -23 "$TMP.sorted" "$TMP.prev" | while IFS='|' read -r dev pid name; do
    sqlite3 -cmd ".timeout 1500" "$DB" "INSERT INTO privacy_events (ts,action,device,name,pid) VALUES ($NOW,'start','$(sq "$dev")','$(sq "$name")',$pid);" 2>/dev/null
  done
  # Lines that disappeared
  comm -13 "$TMP.sorted" "$TMP.prev" | while IFS='|' read -r dev pid name; do
    sqlite3 -cmd ".timeout 1500" "$DB" "INSERT INTO privacy_events (ts,action,device,name,pid) VALUES ($NOW,'stop','$(sq "$dev")','$(sq "$name")',$pid);" 2>/dev/null
  done
else
  # First run: seed state, don't log spurious "start" for pre-existing access
  :
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