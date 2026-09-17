#!/bin/sh
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/bootstrap.sh"
# OmaControl bar preferences. Usage: bar-prefs.sh set-show-bell <on|off>
# ALL writes go through the shared prefs.py store (flock + fsync + atomic
# rename + schema validation) so bar and app-window writers can't race.
DATA_DIR="${OMCONTROL_DATA_DIR:-$HOME/.local/share/omcontrol}"
FILE="${OMCONTROL_BAR_PREFS:-$DATA_DIR/barstats.json}"
export OMCONTROL_BAR_PREFS="$FILE"
mkdir -p "$DATA_DIR"

NEW_JSON=$(python3 - "$FILE" "$@" <<'PY'
import json, os, sys
path, action = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""
val = sys.argv[3] if len(sys.argv) > 3 else ""
try:
    d = json.load(open(path)) if os.path.exists(path) else {}
except Exception:
    d = {}
if action == "set-show-bell":
    d["barShowBell"] = (val == "on")
    print(json.dumps(d))
else:
    print("usage: bar-prefs.sh set-show-bell <on|off>", file=sys.stderr)
    sys.exit(1)
PY
) || exit $?

printf '%s\n' "$NEW_JSON" | "$SELF_DIR/prefs.py" write && echo "ok"