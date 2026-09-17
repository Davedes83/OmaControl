#!/bin/sh
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/bootstrap.sh"
# OmaControl enforcement engine — reads rules.json and enforces persistent rules.
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

# Reject anything that isn't a plain user unit name: no absolute/relative paths,
# no leading dot, no whitespace or shell metacharacters, no glob patterns, and
# only the character set systemd allows in unit names ([A-Za-z0-9_.@:-]), ending
# in ".service". A JIT'd rule string is never worth trusting systemctl to parse.
valid_unit() {
  case "$1" in
    *.service) ;;
    *) return 1 ;;
  esac
  case "$1" in
    .*) return 1 ;;
    */*) return 1 ;;
    *[!A-Za-z0-9_.@:-]*) return 1 ;;
  esac
  return 0
}

# Mask/unmask only ever run after valid_unit() — a persisted rule must be a
# legitimate unit name before it can affect the systemd user manager.
mask_unit() {
  valid_unit "$1" || return 1
  systemctl --user mask "$1" >/dev/null 2>&1
  systemctl --user stop "$1" >/dev/null 2>&1
}
unmask_unit() {
  valid_unit "$1" || return 1
  systemctl --user unmask "$1" >/dev/null 2>&1
  systemctl --user restart "$1" >/dev/null 2>&1
}

if [ ! -f "$RULES_FILE" ]; then
  echo '{"killed":[],"errors":[]}'
  exit 0
fi

KILLED=""
ERRORS=""

# Rows accumulate here and are flushed to sql-ins.py once, after the loop.
LFILE=$(mktemp /tmp/omc_lblock.XXXXXX)

log_block() {
  pid="$1"
  name="$2"
  pattern="$3"
  printf 'event\t%s\tpublisher_block\t%s\tOmaControl\tBlocked forbidden app: %s (%s)\t0\n' \
    "$NOW" "$name" "$name" "$pattern" >>"$LFILE"
}

TMP=$(mktemp /tmp/omc_rules.XXXXXX)
KFILE=$(mktemp /tmp/omc_killed.XXXXXX)
EFILE=$(mktemp /tmp/omc_errors.XXXXXX)
PFILE=$(mktemp /tmp/omc_pfile.XXXXXX)
CUR_MASKED=$(mktemp /tmp/omc_masked.XXXXXX)
MSVC_LIST="$DATA_DIR/masked_services"
trap 'rm -f "$TMP" "$KFILE" "$EFILE" "$LFILE" "$PFILE" "$CUR_MASKED"' EXIT INT TERM

python3 - "$RULES_FILE" >"$TMP" <<'PY'
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
    # Track every unit this run asks to mask so we can un-mask the ones whose
    # rule went away — a mask once applied must not outlive the rule.
    if valid_unit "$pattern"; then
      # Status before masking, surfaced in the caller's JSON so the reviewer
      # can see exactly which unit was affected and in what state.
      STATE=$(systemctl --user is-active "$pattern" 2>/dev/null || echo unknown)
      if [ -z "$DRY_RUN" ]; then
        mask_unit "$pattern"
        echo "$pattern" >>"$CUR_MASKED"
      fi
      printf '%s\n' "{\"unit\":\"$pattern\",\"masked\":\"yes\",\"state\":\"$STATE\"}" >>"$KFILE"
    else
      printf '%s\n' "{\"unit\":\"$pattern\",\"error\":\"invalid unit name\"}" >>"$EFILE"
    fi
    continue
  fi

  if [ -z "$DRY_RUN" ]; then
    # Match on comm AND the full resolved exe basename (comm is truncated to
    # 15 chars; match-pids.sh closes that gap by also matching readlink exe).
    # Deliberately no pgrep -f fallback: a command-line regex match can hit
    # unrelated processes whose argv merely contains the pattern string.
    PIDS=$(sh "$(dirname "$0")/match-pids.sh" "$pattern")
    # Drop our own pid so a pattern that matches the enforcement tooling can
    # never make us kill ourselves.
    PIDS=$(echo "$PIDS" | grep -vx "$$" | sort -un)
  else
    PIDS=""
  fi

  for pid in $PIDS; do
    [ -z "$pid" ] && continue
    NAME=$(basename "$(readlink /proc/$pid/exe 2>/dev/null)" 2>/dev/null)
    NAME=${NAME:-unknown}
    PAT=$(printf '%s' "$pattern" | tr -d '\n\r|')
    printf '%s|%s|%s\n' "$pid" "$(echo "$NAME" | tr -d '\n\r|')" "$PAT" >>"$PFILE"
  done
done

# Reap collected app-match targets with a SIGTERM grace before SIGKILL:
# a well-behaved app exits on TERM (a user kill, a rule, whatever), and only
# survivors after the grace get the SIGKILL. The killed set is reported once.
if [ -z "$DRY_RUN" ] && [ -s "$PFILE" ]; then
  while IFS='|' read -r pid name pat; do
    [ -z "$pid" ] && continue
    kill -TERM "$pid" 2>/dev/null
  done <"$PFILE"
  sleep 1
  while IFS='|' read -r pid name pat; do
    [ -z "$pid" ] && continue
    [ -d "/proc/$pid" ] || continue
    kill -KILL "$pid" 2>/dev/null
    log_block "$pid" "$name" "$pat"
    printf '%s\n' "{\"pid\":$pid,\"name\":\"$name\",\"pattern\":\"$pat\"}" >>"$KFILE"
  done <"$PFILE"
fi

# Unmask services whose disable rule vanished (or was disabled): the mask is
# persistent, so without this an enable/rule removal would never take effect.
# Every unit here is a legitimate-name from the tracked mask list (or a prior
# valid_unit()); unmask and return the unit to its prior lifecycle.
if [ -z "$DRY_RUN" ] && [ -f "$MSVC_LIST" ]; then
  if [ -s "$CUR_MASKED" ]; then
    grep -Fxvf "$CUR_MASKED" "$MSVC_LIST" | while IFS= read -r unit; do
      [ -z "$unit" ] && continue
      if valid_unit "$unit"; then
        unmask_unit "$unit"
        printf '%s\n' "{\"unit\":\"$unit\",\"masked\":\"no\"}" >>"$KFILE"
      fi
    done
  else
    grep -v '^$' "$MSVC_LIST" | while IFS= read -r unit; do
      [ -z "$unit" ] && continue
      if valid_unit "$unit"; then
        unmask_unit "$unit"
        printf '%s\n' "{\"unit\":\"$unit\",\"masked\":\"no\"}" >>"$KFILE"
      fi
    done
  fi
  cp "$CUR_MASKED" "$MSVC_LIST" 2>/dev/null
  touch "$MSVC_LIST"
fi

# Flush audit rows through the parameterized writer (one transaction).
if [ -s "$LFILE" ]; then
  OMCONTROL_DB="$DB" python3 "$(dirname "$0")/sql-ins.py" <"$LFILE" 2>/dev/null
fi
KILLED_LIST="$(paste -sd, "$KFILE" 2>/dev/null)"
ERRORS_LIST="$(paste -sd, "$EFILE" 2>/dev/null)"
cat <<ENDJSON
{"killed":[$KILLED_LIST],"errors":[$ERRORS_LIST]}
ENDJSON
