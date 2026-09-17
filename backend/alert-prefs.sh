#!/bin/sh
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/bootstrap.sh"
# OmaControl alert preferences — per-event-type notification mode + chart markers.
# Modes: toast  = top-right desktop popup + bell badge
#        notify = bell badge only
#        none   = quiet (still logged in the events history)
# Chart markers are independent: charts.<type> on|off decides whether that
# event kind is drawn as a pin on the history chart.
# Usage: alert-prefs.sh get | set <type> <toast|notify|none> | set-chart <type> <on|off> | set-enabled <on|off>
DATA_DIR="${OMCONTROL_DATA_DIR:-$HOME/.local/share/omcontrol}"
PREFS="${OMCONTROL_ALERT_PREFS:-$DATA_DIR/alert_prefs.json}"
mkdir -p "$DATA_DIR"
BACKEND="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

DEFAULT='{"enabled":true,"types":{"New App Launch":"toast","Mic or Cam Access":"notify","Service Change":"none","Unsigned App Launch":"notify","Location Tracking":"none","New Service Launch":"none","App Update":"notify","New Suspicious App":"notify","App Exit":"none","App Activity":"notify"},"charts":{"App Exit":false}}'

if [ ! -f "$PREFS" ]; then
  echo "$DEFAULT" > "$PREFS"
fi

OMC_BACKEND="$BACKEND" python3 - "$PREFS" "$@" <<'PY'
import json, os, sys

sys.path.insert(0, os.environ["OMC_BACKEND"])
from omc_prefs import normalize_mode

p = sys.argv[1]
ACTION = sys.argv[2] if len(sys.argv) > 2 else ""
TYPE = sys.argv[3] if len(sys.argv) > 3 else ""
VAL = (sys.argv[3] if len(sys.argv) > 3 else "") if ACTION == "set-enabled" else (sys.argv[4] if len(sys.argv) > 4 else "")


def load():
    try:
        d = json.load(open(p))
    except Exception:
        d = {"enabled": True, "types": {}}
    if not isinstance(d, dict):
        d = {"enabled": True, "types": {}}
    d.setdefault("types", {})
    d.setdefault("charts", {})
    d.setdefault("enabled", True)
    changed = False
    for t, v in list(d["types"].items()):
        n = normalize_mode(v, t)
        if n != v:
            d["types"][t] = n
            changed = True
    return d, changed


if ACTION == "get":
    d, changed = load()
    if changed:
        open(p, "w").write(json.dumps(d, indent=2))
    print(json.dumps(d))
elif ACTION == "set-enabled":
    d, _ = load()
    d["enabled"] = (VAL == "on")
    open(p, "w").write(json.dumps(d, indent=2))
    print("ok")
elif ACTION == "set":
    if VAL not in ("toast", "notify", "none"):
        print("mode must be one of toast|notify|none", file=sys.stderr)
        sys.exit(1)
    d, _ = load()
    d["types"][TYPE] = VAL
    open(p, "w").write(json.dumps(d, indent=2))
    print("ok")
elif ACTION == "set-chart":
    if VAL not in ("on", "off"):
        print("value must be on|off", file=sys.stderr)
        sys.exit(1)
    d, _ = load()
    d["charts"][TYPE] = (VAL == "on")
    open(p, "w").write(json.dumps(d, indent=2))
    print("ok")
else:
    print("usage: alert-prefs.sh <get|set TYPE toast|notify|none|set-chart TYPE on|off|set-enabled on|off>", file=sys.stderr)
    sys.exit(1)
PY
