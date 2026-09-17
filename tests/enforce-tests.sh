#!/bin/sh
# enforce.sh tests: the unit-state capture used when masking (mocked systemctl,
# since enforce.sh's hardened PATH and systemctl's real exit codes would make a
# live call environment-dependent) and the --dry-run JSON contract, which never
# masks, kills, or touches anything outside the temp data directory.
#
# Run via tests/run-tests.sh, or directly: ./tests/enforce-tests.sh

set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$DIR/.." && pwd)
. "$DIR/lib.sh"

ENFORCE="$ROOT/backend/enforce.sh"
STATE_SH="$ROOT/backend/unit-state.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/omc-enforce.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM

# --- unit-state capture with a mocked systemctl -----------------------------
# systemctl --user is-active prints the state and exits nonzero for inactive
# units; a naive `|| echo unknown` fallback appends a second line (raw newline).
# unit-state.sh resolves `systemctl` through PATH, so shadow it with a stub
# that reproduces the three real-world branches.
FAKE="$T/bin"
mkdir -p "$FAKE"
cat >"$FAKE/systemctl" <<'STUB'
#!/bin/sh
u=
for a in "$@"; do u=$a; done
case "$u" in
  active.service) echo active; exit 0 ;;
  inactive.service) echo inactive; exit 1 ;;
  silent.service) exit 3 ;;
  *) exit 99 ;;
esac
STUB
chmod +x "$FAKE/systemctl"

check_eq "state: active unit printed once" \
  "active" "$(PATH="$FAKE:$PATH" sh "$STATE_SH" active.service)"
check_eq "state: inactive unit is one line (no unknown fallback)" \
  "inactive" "$(PATH="$FAKE:$PATH" sh "$STATE_SH" inactive.service)"
check_eq "state: silent failure falls back to unknown" \
  "unknown" "$(PATH="$FAKE:$PATH" sh "$STATE_SH" silent.service)"

# Every branch must emit exactly one line regardless of systemctl's exit code.
PATH="$FAKE:$PATH"
for u in active.service inactive.service silent.service; do
  n=$(sh "$STATE_SH" "$u" | wc -l)
  check_eq "state: $u output is exactly one line" "1" "$n"
done

# --- enforce.sh --dry-run JSON contract --------------------------------------
# Dry-run skips mask/stop/unmask and process kills; the only systemctl access
# is the read-only is-active state probe.
RULES="$T/rules.json"
cat >"$RULES" <<'EOF'
{"rules":[
  {"kind":"service","action":"disable","pattern":"omc-test-unit.service","enabled":true},
  {"kind":"service","action":"disable","pattern":"../evil.service","enabled":true},
  {"kind":"app","action":"kill","pattern":"definitelyNotRunning","enabled":true},
  {"kind":"service","action":"disable","pattern":"omc-disabled.service","enabled":false}
]}
EOF

OMCONTROL_DATA_DIR="$T/data" OMCONTROL_RULES="$RULES" OMCONTROL_DB="$T/data/history.db" \
  HOME="$T" sh "$ENFORCE" --dry-run >"$T/out.json" 2>"$T/err.txt"
check_eq "enforce --dry-run: exits 0" "0" "$?"

python3 - "$T/out.json" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
d = json.loads(raw)
assert set(d) == {"killed", "errors"}, d
units = [j for j in d["killed"] if "unit" in j and j.get("masked") == "yes"]
assert len(units) == 1, d
state = units[0]["state"]
# The masked stub is not on enforce.sh's hardened PATH, so this is the real
# systemctl — whatever it reports, it must be one bare token: a raw newline
# would both break this check and have made json.loads reject the document.
assert isinstance(state, str) and "\n" not in state and state, state
errs = d["errors"]
assert any(j.get("unit") == "../evil.service" and "error" in j for j in errs), errs
# The disabled rule and the app-kill rule must not produce enforcement entries.
assert len(d["killed"]) == 1, d
PY
check_eq "enforce --dry-run: JSON contract, single-line state, safe" "0" "$?"

# Nothing may have been written into the real data dirs.
if [ -e "$T/data/masked_services" ]; then
  fail "enforce --dry-run: left a masked_services artifact"
else
  ok "enforce --dry-run: left no masked_services artifact"
fi

finish
