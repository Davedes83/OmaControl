#!/bin/sh
# OmControl app-action — quick actions on a running app (by process name).
# Usage: app-action.sh <action> <name>
#   kill    -> SIGTERM all processes of this name (one-off)
#   killall -> SIGKILL all processes of this name (one-off)
#   stop    -> SIGSTOP (suspend)
#   cont    -> SIGCONT (resume)
#   fast    -> renice -5 (priority boost)
#   slow    -> renice +5 (priority drop)
#   disable -> persistent rule: kill now + enforce kill-on-launch from now on
#   enable  -> remove the persistent disable rule

DATA_DIR="${OMCONTROL_DATA_DIR:-$HOME/.local/share/omcontrol}"
RULES_FILE="${OMCONTROL_RULES:-$DATA_DIR/rules.json}"
DB="${OMCONTROL_DB:-$DATA_DIR/history.db}"
mkdir -p "$DATA_DIR"

ACTION="$1"
NAME="$2"
[ -n "$ACTION" ] && [ -n "$NAME" ] || {
  echo "usage: app-action.sh <kill|killall|stop|cont|fast|slow|disable|enable> <name>" >&2
  exit 1
}

log_event() {
  local type="$1" msg="$2"
  [ -n "$DB" ] && [ -f "$DB" ] || return 0
  NOW=$(date +%s)
  MSG=$(echo "$msg" | sed "s/'/''/g")
  NM=$(echo "$NAME" | sed "s/'/''/g")
  PUB=$(sqlite3 -cmd ".timeout 1500" "$DB" "SELECT publisher FROM app_meta WHERE name='$NM' LIMIT 1;" 2>/dev/null | head -1)
  [ -z "$PUB" ] && PUB="Unknown"
  printf "INSERT INTO events (ts, type, app, publisher, msg, read) VALUES ($NOW, '%s', '%s', '%s', '%s', 0);\n" \
    "$type" "$NM" "${PUB}" "$MSG" | sqlite3 -cmd ".timeout 1500" "$DB" 2>/dev/null
}

rules_set_state() {
  # add/remove an app-wide disable rule in rules.json
  python3 - "$RULES_FILE" "$NAME" "$1" <<'PY'
import json, os, sys
path, name, on = sys.argv[1], sys.argv[2], sys.argv[3] == "on"
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    data = {"rules": []}
if not isinstance(data, dict) or "rules" not in data:
    data = {"rules": []}
rules = [r for r in data["rules"] if not (r.get("kind") == "app" and r.get("pattern") == name)]
if on:
    rules.append({"kind": "app", "pattern": name, "name": name, "action": "disable", "enabled": True})
data["rules"] = rules
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
print("ok")
PY
}

case "$ACTION" in
  kill) pkill -TERM -x "$NAME"; log_event "user_kill" "Terminated $NAME" ;;
  killall) pkill -KILL -x "$NAME"; log_event "user_kill" "Force-killed $NAME" ;;
  stop) pkill -STOP -x "$NAME"; log_event "user_pause" "Paused $NAME" ;;
  cont) pkill -CONT -x "$NAME"; log_event "user_resume" "Resumed $NAME" ;;
  fast)
    pids=$(pgrep -x "$NAME")
    [ -n "$pids" ] && renice -n -5 -p $pids >/dev/null 2>&1
    log_event "user_priority" "Priority boost applied to $NAME"
    ;;
  slow)
    pids=$(pgrep -x "$NAME")
    [ -n "$pids" ] && renice -n 5 -p $pids >/dev/null 2>&1
    log_event "user_priority" "Priority drop applied to $NAME"
    ;;
  disable)
    rules_set_state on
    pkill -KILL -x "$NAME" 2>/dev/null
    log_event "user_disable" "Disabled $NAME (blocked from launching)"
    ;;
  enable)
    rules_set_state off
    log_event "user_enable" "Re-enabled $NAME"
    ;;
  *) echo "unknown action: $ACTION" >&2; exit 1 ;;
esac
exit $?