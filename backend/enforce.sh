#!/bin/sh
# OmControl enforcement engine — reads rules.json and enforces persistent rules.
# Usage: enforce.sh [--dry-run]
#   kind=app,     action=disable -> kill any matching process (kill-on-launch)
#   kind=service, action=disable -> systemctl --user mask the unit (persistent)
#   (legacy kill rules are honoured as well)

RULES_FILE="${OMCONTROL_RULES:-$HOME/.local/share/omcontrol/rules.json}"
DATA_DIR="${OMCONTROL_DATA_DIR:-$HOME/.local/share/omcontrol}"
DB="${OMCONTROL_DB:-$DATA_DIR/history.db}"
NOW=$(date +%s)
DRY_RUN=""
[ "$1" = "--dry-run" ] && DRY_RUN=1

if [ ! -f "$RULES_FILE" ]; then
  echo '{"killed":[],"errors":[]}'
  exit 0
fi

KILLED=""
ERRORS=""

log_block() {
  pid="$1"; name="$2"; pattern="$3"
  NM=$(echo "$name" | sed "s/'/''/g")
  PT=$(echo "$pattern" | sed "s/'/''/g")
  printf "INSERT INTO events (ts, type, app, publisher, msg, read) VALUES ($NOW, 'publisher_block', '%s', 'OmaControl', 'Blocked forbidden app: %s (%s)', 0);\n" \
    "$NM" "$NM" "$PT" | sqlite3 -cmd ".timeout 1500" "$DB" 2>/dev/null
}

TMP=$(mktemp /tmp/omc_rules.XXXXXX)
KFILE=$(mktemp /tmp/omc_killed.XXXXXX)
EFILE=$(mktemp /tmp/omc_errors.XXXXXX)
trap 'rm -f "$TMP" "$KFILE" "$EFILE"' EXIT INT TERM

python3 - "$RULES_FILE" > "$TMP" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit()
for r in data.get("rules", []):
    if not r.get("enabled"):
        continue
    if r.get("action") not in ("disable", "kill"):
        continue
    pat = r.get("pattern", "")
    kind = r.get("kind", "app")
    if pat:
        print(f"{kind}|{r.get('action')}|{pat}")
PY

grep -v '^$' "$TMP" | sed 's/\r$//' | while IFS='|' read -r kind action pattern; do
  [ -z "$pattern" ] && continue

  if [ "$kind" = "service" ]; then
    if [ -z "$DRY_RUN" ]; then
      systemctl --user mask "$pattern" >/dev/null 2>&1
      systemctl --user stop "$pattern" >/dev/null 2>&1
    fi
    printf '%s\n' "{\"unit\":\"$pattern\",\"masked\":\"yes\"}" >> "$KFILE"
    continue
  fi

  if [ -z "$DRY_RUN" ]; then
    PIDS=$(pgrep -x "$pattern" 2>/dev/null)
    [ -z "$PIDS" ] && PIDS=$(pgrep -f "$pattern" 2>/dev/null)
    for exepid in $(ls -d /proc/[0-9]* 2>/dev/null | sed 's|/proc/||'); do
      EXEN=$(basename "$(readlink "/proc/$exepid/exe" 2>/dev/null)" 2>/dev/null)
      if [ "$EXEN" = "$pattern" ]; then
        PIDS="$PIDS $exepid"
      fi
    done
    PIDS=$(echo "$PIDS" | tr ' ' '\n' | sort -un)
  else
    PIDS=""
  fi

  for pid in $PIDS; do
    [ -z "$pid" ] && continue
    NAME=$(basename "$(readlink /proc/$pid/exe 2>/dev/null)" 2>/dev/null)
    NAME=${NAME:-unknown}
    RESULT=0
    if [ -z "$DRY_RUN" ]; then
      kill -9 "$pid" 2>/dev/null
      RESULT=$?
      log_block "$pid" "$NAME" "$pattern"
    fi
    if [ "$RESULT" -eq 0 ]; then
      printf '%s\n' "{\"pid\":$pid,\"name\":\"$NAME\",\"pattern\":\"$pattern\"}" >> "$KFILE"
    else
      printf '%s\n' "{\"pid\":$pid,\"name\":\"$NAME\",\"error\":\"kill failed\"}" >> "$EFILE"
    fi
  done
done
KILLED_LIST="$(paste -sd, "$KFILE" 2>/dev/null)"
ERRORS_LIST="$(paste -sd, "$EFILE" 2>/dev/null)"
cat <<ENDJSON
{"killed":[$KILLED_LIST],"errors":[$ERRORS_LIST]}
ENDJSON