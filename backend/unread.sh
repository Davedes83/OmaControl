#!/bin/sh
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/bootstrap.sh"
# OmaControl unread count for the top-bar bell — events whose sensitivity mode
# is not "none", gated by the master Alerts ON/OFF flag.
DATA_DIR="${OMCONTROL_DATA_DIR:-$HOME/.local/share/omcontrol}"
DB="${OMCONTROL_DB:-$DATA_DIR/history.db}"
PREFS="${OMCONTROL_ALERT_PREFS:-$DATA_DIR/alert_prefs.json}"
BACKEND="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OMC_BACKEND="$BACKEND" python3 - "$DB" "$PREFS" <<'PY'
import json, os, sqlite3, sys
sys.path.insert(0, os.environ["OMC_BACKEND"])
from omc_prefs import DEVICE_TO_SENS, KIND_TO_SENS
db, prefs_path = sys.argv[1], sys.argv[2]
try:
    prefs = json.load(open(prefs_path))
except Exception:
    prefs = {"enabled": True, "types": {}}
if prefs.get("enabled") is False:
    print(json.dumps({"count": 0, "color": "dim"}))
    raise SystemExit
types = prefs.get("types", {})
# DB "type"/"device" -> alert sensitivity label is shared via omc_prefs
# (same table sql-ins.py uses for toast gating).
# Map sensitivity label → chart color token (matches HistoryGraph.evColor).
COLORS = {
    "App Exit": "dim",
    "New App Launch": "green",
    "Mic or Cam Access": "danger", "Location Tracking": "danger",
    "Unsigned App Launch": "danger", "New Suspicious App": "danger",
    "Service Change": "accent", "New Service Launch": "accent",
    "App Update": "accent",
}
PRIORITY = ["danger", "green", "accent", "dim"]


def sensitivity(typ):
    return KIND_TO_SENS.get(typ)

try:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    top = "dim"
    total = 0

    def add(sens, c, tok):
        global top, total
        if not sens or types.get(sens, "none") == "none":
            return
        total += c
        if PRIORITY.index(tok) < PRIORITY.index(top):
            top = tok

    for typ, c in con.execute(
            "SELECT type, COUNT(*) FROM events WHERE read=0 GROUP BY type"):
        add(sensitivity(typ), c, COLORS.get(sensitivity(typ), "accent"))

    # privacy (mic/cam/location) rows have no read column; the feed marks them
    # read once events_lastread_ts passes their timestamp, so mirror that.
    try:
        lastread = int(open(os.path.join(os.path.dirname(db), "events_lastread_ts")).read().strip())
    except Exception:
        lastread = 0
    for action, device, c in con.execute(
            "SELECT action, device, COUNT(*) FROM privacy_events"
            " WHERE action='start' AND ts > ? GROUP BY action, device", (lastread,)):
        sens = DEVICE_TO_SENS.get(device)
        add(sens, c, "danger")
    print(json.dumps({"count": total, "color": top}))
except Exception:
    print(json.dumps({"count": 0, "color": "dim"}))
PY
