#!/bin/sh
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/bootstrap.sh"
# OmaControl alert preferences — per-event-type notification mode + chart
# markers + resource alert thresholds.
# Modes: toast  = top-right desktop popup + bell badge
#        notify = bell badge only
#        none   = quiet (still logged in the events history)
# Chart markers are independent: charts.<type> on|off decides whether that
# event kind is drawn as a pin on the history chart.
# Thresholds: a named profile (mild|medium|severe) sets all resource alert
# limits; per-metric overrides in set-threshold win over the profile. The
# same values drive the collector's hysteresis and the bar bell (via
# sample-json.sh / collect.sh emitting the resolved thresholds).
# Usage: alert-prefs.sh
#   get | set <type> <toast|notify|none> | set-chart <type> <on|off>
#   set-enabled <on|off> | set-threshold <metric> <value>
#   set-profile <mild|medium|severe> | reset
# All writes are atomic (same-dir tempfile + fsync + rename) via omc_prefs.py.

DATA_DIR="${OMCONTROL_DATA_DIR:-$HOME/.local/share/omcontrol}"
PREFS="${OMCONTROL_ALERT_PREFS:-$DATA_DIR/alert_prefs.json}"
mkdir -p "$DATA_DIR"
BACKEND="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

OMC_BACKEND="$BACKEND" python3 - "$PREFS" "$@" <<'PY'
import json, os, sys

sys.path.insert(0, os.environ["OMC_BACKEND"])
from omc_prefs import PROFILES, THRESHOLD_KEYS, \
    load_alert_prefs, resolve_thresholds, save_alert_prefs, valid_threshold

p = sys.argv[1]
ACTION = sys.argv[2] if len(sys.argv) > 2 else ""
TYPE = sys.argv[3] if len(sys.argv) > 3 else ""
VAL = (sys.argv[3] if len(sys.argv) > 3 else "") if ACTION == "set-enabled" else (sys.argv[4] if len(sys.argv) > 4 else "")


def persist(d):
    save_alert_prefs(p, d)
    print("ok")


if ACTION == "get":
    d, changed = load_alert_prefs(p)
    if changed:
        save_alert_prefs(p, d)
    resolved = resolve_thresholds(d)
    out = dict(d)
    out["resolved_thresholds"] = {k: float(v) for k, v in resolved.items()}
    print(json.dumps(out))
elif ACTION == "reset":
    d, _ = load_alert_prefs(p)
    d["profile"] = "medium"
    d["thresholds"] = {}
    persist(d)
elif ACTION == "set-enabled":
    d, _ = load_alert_prefs(p)
    d["enabled"] = (VAL == "on")
    persist(d)
elif ACTION == "set":
    if VAL not in ("toast", "notify", "none"):
        print("mode must be one of toast|notify|none", file=sys.stderr)
        sys.exit(1)
    d, _ = load_alert_prefs(p)
    d["types"][TYPE] = VAL
    persist(d)
elif ACTION == "set-chart":
    if VAL not in ("on", "off"):
        print("value must be on|off", file=sys.stderr)
        sys.exit(1)
    d, _ = load_alert_prefs(p)
    d["charts"][TYPE] = (VAL == "on")
    persist(d)
elif ACTION == "set-threshold":
    metric = TYPE
    value = sys.argv[4] if len(sys.argv) > 4 else ""
    if not valid_threshold(metric, value):
        print("metric must be one of: %s" % " ".join(THRESHOLD_KEYS), file=sys.stderr)
        sys.exit(1)
    d, _ = load_alert_prefs(p)
    d.setdefault("thresholds", {})
    d["thresholds"][metric] = float(value)
    persist(d)
elif ACTION == "set-profile":
    profile = TYPE  # sys.argv[3] for <set-profile PROFILE>
    if profile not in PROFILES:
        print("profile must be one of: %s" % " ".join(sorted(PROFILES)), file=sys.stderr)
        sys.exit(1)
    d, _ = load_alert_prefs(p)
    d["profile"] = profile
    persist(d)
else:
    print("usage: alert-prefs.sh <get|set TYPE toast|notify|none|set-chart TYPE on|off|set-enabled on|off|set-threshold METRIC VALUE|set-profile mild|medium|severe|reset>", file=sys.stderr)
    sys.exit(1)
PY
