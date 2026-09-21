#!/bin/sh
# alert-prefs.sh + omc_prefs.py tests: threshold profiles, per-metric
# overrides, atomic writes, and corruption quarantine for alert_prefs.json.
#
# Real user prefs are never touched — everything runs against a throwaway
# $OMCONTROL_ALERT_PREFS and isolated $OMCONTROL_DATA_DIR.
#
# Run via tests/run-tests.sh, or directly: ./tests/alert-prefs-tests.sh

set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$DIR/.." && pwd)
. "$DIR/lib.sh"

TMPROOT="${TMPDIR:-/tmp}"
T=$(mktemp -d "$TMPROOT/omc-alertprefs.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM

export OMCONTROL_DATA_DIR="$T"
export OMCONTROL_DB="$T/history.db"
P="$T/alert_prefs.json"
export OMCONTROL_ALERT_PREFS="$P"
AP="$ROOT/backend/alert-prefs.sh"

# --- helpers ---------------------------------------------------------------
# --- default bootstrapping -------------------------------------------------
run_interp "$AP" get | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("profile") == "medium", d'
check_eq "get: missing file returns medium profile" "0" "$?"
run_interp "$AP" get >"$T/get1.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["resolved_thresholds"]["cpu_pct"] == 90.0, d' "$T/get1.json"
check_eq "get: resolved cpu_pct default is 90" "0" "$?"

# --- profile switching -----------------------------------------------------
check_run "set-profile severe: exits 0" run_interp "$AP" set-profile severe
run_interp "$AP" get | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["profile"] == "severe", d; assert d["resolved_thresholds"]["cpu_pct"] == 80.0, d'
check_eq "set-profile severe: profile applied" "0" "$?"
run_interp "$AP" set-profile bogus >/dev/null 2>&1
[ "$?" -ne 0 ]
check_eq "set-profile bogus: rejected" "0" "$?"

# --- per-metric override wins over the profile -----------------------------
check_run "set-threshold mem_pct 70: exits 0" run_interp "$AP" set-threshold mem_pct 70
run_interp "$AP" get | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["thresholds"]["mem_pct"] == 70.0, d; assert d["resolved_thresholds"]["mem_pct"] == 70.0, d; assert d["resolved_thresholds"]["cpu_pct"] == 80.0, d'
check_eq "set-threshold: override wins, rest stays on profile" "0" "$?"
run_interp "$AP" set-threshold bogus 50 >/dev/null 2>&1
[ "$?" -ne 0 ]
check_eq "set-threshold unknown metric: rejected" "0" "$?"
run_interp "$AP" set-threshold cpu_pct abc >/dev/null 2>&1
[ "$?" -ne 0 ]
check_eq "set-threshold non-numeric: rejected" "0" "$?"

# --- corruption quarantine -------------------------------------------------
printf '{broken' >"$P"
run_interp "$AP" get >"$T/corrupt.json" 2>"$T/corrupt.err"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("profile") == "medium", d' "$T/corrupt.json"
check_eq "corrupt file: read degrades to defaults" "0" "$?"
if [ -f "$P.corrupt" ]; then
  ok "corrupt file: backup preserved"
else
  fail "corrupt file: backup preserved"
fi

# --- reset restores medium + clears overrides ------------------------------
check_run "reset: exits 0" run_interp "$AP" reset
run_interp "$AP" get | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["profile"] == "medium", d; assert d["thresholds"] == {}, d'
check_eq "reset: cleared override and profile" "0" "$?"

# --- atomicity: a burst of mixed writes leaves one parseable file, no *.tmp
n=0
while [ "$n" -lt 8 ]; do
  run_interp "$AP" set-threshold cpu_pct $((87 + n)) >/dev/null 2>&1
  n=$((n + 1))
done
run_interp "$AP" set-profile mild >/dev/null 2>&1
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["thresholds"]["cpu_pct"] == 94.0, d' "$P"
check_eq "atomic writes: last write won, file parses" "0" "$?"
left=$(find "$T" -name '*.tmp' | wc -l)
check_eq "atomic writes: no temp files left" "0" "$left"

# --- omc-thresholds.py agrees with the get path ----------------------------
OMC_BACKEND="$ROOT/backend" python3 "$ROOT/backend/omc-thresholds.py" "$P" >"$T/th.txt"
check_eq "omc-thresholds.py: profile line" "mild" "$(sed -n '1p' "$T/th.txt")"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert "hold" in d and d["proc_cpu_pct"] == 92.0, d' "$(sed -n '2p' "$T/th.txt")"
check_eq "omc-thresholds.py: resolved JSON line" "0" "$?"

finish