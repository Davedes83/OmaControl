#!/bin/sh
# unit-state.sh <unit> — print a unit's state as exactly one bare line.
# systemctl --user is-active prints its state and exits nonzero for inactive
# units, so a naive `|| echo unknown` fallback appends a second line (and a
# raw newline) to the value. Keep the first line, and fall back to "unknown"
# only when nothing was printed. Internal helper for enforce.sh.
STATE=$(systemctl --user is-active "$1" 2>/dev/null | head -n 1)
[ -n "$STATE" ] || STATE=unknown
printf '%s\n' "$STATE"
