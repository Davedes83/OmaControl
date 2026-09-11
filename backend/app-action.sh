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
  type="$1" msg="$2" now=""
  [ -f "$DB" ] || return 0
  now=$(date +%s)
  # Publisher is resolved from app_meta inside sql-ins.py (bound params).
  printf 'event\t%s\t%s\t%s\t\t%s\t0\n' "$now" "$type" "$NAME" "$msg" \
    | OMCONTROL_DB="$DB" python3 "$(dirname "$0")/sql-ins.py" 2>/dev/null
}

# Read-modify-write of rules.json, serialized with flock (a double-click or a
# GUI action racing enforce.sh/poll would otherwise clobber a concurrent write)
# and written atomically (tmp + rename).
rules_set_state() {
  { flock 9 || return 1
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
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
print("ok")
PY
  } 9>"$RULES_FILE.lock"
}

case "$ACTION" in
  kill) PIDS=$(sh "$(dirname "$0")/match-pids.sh" "$NAME"); [ -n "$PIDS" ] && kill -TERM $PIDS 2>/dev/null; log_event "user_kill" "Terminated $NAME" ;;
  killall) PIDS=$(sh "$(dirname "$0")/match-pids.sh" "$NAME"); [ -n "$PIDS" ] && kill -KILL $PIDS 2>/dev/null; log_event "user_kill" "Force-killed $NAME" ;;
  stop) PIDS=$(sh "$(dirname "$0")/match-pids.sh" "$NAME"); [ -n "$PIDS" ] && kill -STOP $PIDS 2>/dev/null; log_event "user_pause" "Paused $NAME" ;;
  cont) PIDS=$(sh "$(dirname "$0")/match-pids.sh" "$NAME"); [ -n "$PIDS" ] && kill -CONT $PIDS 2>/dev/null; log_event "user_resume" "Resumed $NAME" ;;
  fast)
    PIDS=$(sh "$(dirname "$0")/match-pids.sh" "$NAME")
    [ -n "$PIDS" ] && renice -n -5 -p $PIDS >/dev/null 2>&1
    log_event "user_priority" "Priority boost applied to $NAME"
    ;;
  slow)
    PIDS=$(sh "$(dirname "$0")/match-pids.sh" "$NAME")
    [ -n "$PIDS" ] && renice -n 5 -p $PIDS >/dev/null 2>&1
    log_event "user_priority" "Priority drop applied to $NAME"
    ;;
  disable)
    rules_set_state on
    PIDS=$(sh "$(dirname "$0")/match-pids.sh" "$NAME")
    [ -n "$PIDS" ] && kill -KILL $PIDS 2>/dev/null
    log_event "user_disable" "Disabled $NAME (blocked from launching)"
    ;;
  enable)
    rules_set_state off
    log_event "user_enable" "Re-enabled $NAME"
    ;;
  *) echo "unknown action: $ACTION" >&2; exit 1 ;;
esac
exit $?