#!/bin/sh
# OmControl alert preferences — config for the Alerts tab.
# Usage: alert-prefs.sh get|set <type> <on|off>|set-enabled <on|off>
DATA_DIR="${OMCONTROL_DATA_DIR:-$HOME/.local/share/omcontrol}"
PREFS="${OMCONTROL_ALERT_PREFS:-$DATA_DIR/alert_prefs.json}"
mkdir -p "$DATA_DIR"

DEFAULT='{"enabled":true,"types":{"New App Launch":true,"Mic or Cam Access":true,"Service Change":false,"Unsigned App Launch":true,"Location Tracking":false,"New Service Launch":false,"App Update":true,"New Suspicious App":true}}'

if [ ! -f "$PREFS" ]; then
  echo "$DEFAULT" > "$PREFS"
fi

ACTION="$1"
TYPE="$2"
VAL="$3"

case "$ACTION" in
  get) cat "$PREFS" ;;
  set-enabled)
    ON=0; [ "$VAL" = "on" ] && ON=1
    python3 - "$PREFS" "$ON" <<'PY'
import json, sys
p, on = sys.argv[1], sys.argv[2] == "1"
d = json.load(open(p)); d["enabled"] = on
open(p, "w").write(json.dumps(d, indent=2))
PY
    echo ok ;;
  set)
    ON=0; [ "$VAL" = "on" ] && ON=1
    python3 - "$PREFS" "$TYPE" "$ON" <<'PY'
import json, sys
p, t, on = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
d = json.load(open(p)); d.setdefault("types", {})[t] = on
open(p, "w").write(json.dumps(d, indent=2))
PY
    echo ok ;;
  *) echo "usage: alert-prefs.sh <get|set TYPE on|off|set-enabled on|off>" >&2; exit 1 ;;
esac