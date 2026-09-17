#!/bin/sh
# prefs.py tests: schema validation/rejection and the flock + atomic-rename
# guarantee under concurrent writers and readers (a reader must never observe
# a torn document, and no write may be lost or corrupt the store).
#
# Run via tests/run-tests.sh, or directly: ./tests/prefs-tests.sh

set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$DIR/.." && pwd)
. "$DIR/lib.sh"

PREFS="$ROOT/backend/prefs.py"
TMPROOT="${TMPDIR:-/tmp}"
T=$(mktemp -d "$TMPROOT/omc-prefs.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM

P="$T/barstats.json"

# --- input validation -------------------------------------------------------
printf 'not json' | python3 "$PREFS" write "$P" >/dev/null 2>&1
check_eq "invalid JSON: rejected (exit 1)" "1" "$?"

printf '{"mode":"bogus"}' | python3 "$PREFS" write "$P" >/dev/null 2>&1
check_eq "bad mode: rejected (exit 2)" "2" "$?"

printf '{"stats":[123]}' | python3 "$PREFS" write "$P" >/dev/null 2>&1
check_eq "bad stat entry: rejected (exit 2)" "2" "$?"

printf '{"stats":["cpu"],"mode":"name","barShowBell":true,"perProcNet":1}' |
  python3 "$PREFS" write "$P" >"$T/ok.out" 2>&1
check_eq "valid payload: accepted (exit 0)" "0" "$?"
check_eq "valid payload: prints ok" "ok" "$(cat "$T/ok.out")"

# --- concurrency ------------------------------------------------------------
# 30 writers race 30 readers through one prefs file. flock serializes the
# writers and the atomic rename means a reader observes either the previous or
# the new document, never a partial one.
: >"$T/reads"
(
  n=0
  while [ "$n" -lt 30 ]; do
    python3 "$PREFS" read "$P" >>"$T/reads" 2>/dev/null
    n=$((n + 1))
  done
) &
reader=$!

n=0
while [ "$n" -lt 30 ]; do
  printf '{"stats":["s%d"],"mode":"name"}' "$n" |
    python3 "$PREFS" write "$P" >/dev/null 2>&1 &
  n=$((n + 1))
done

wait "$reader" 2>/dev/null
wait 2>/dev/null

python3 - "$T/reads" "$P" <<'PY'
import json, sys
lines = [l for l in open(sys.argv[1]) if l.strip()]
assert len(lines) >= 15, "too few concurrent reads observed: %d" % len(lines)
for l in lines:
    json.loads(l)
final = json.load(open(sys.argv[2]))
assert final["mode"] == "name", final
assert isinstance(final["stats"], list) and final["stats"][0].startswith("s"), final
PY
check_eq "concurrent writers/readers: no torn reads, valid final file" "0" "$?"

finish
