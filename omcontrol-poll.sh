#!/bin/sh
# OmaControl continuous sampler — keeps the history database filled even when
# no OmaControl UI is open. Runs collect.sh on an adaptive cadence and
# re-applies enforcement + privacy checks roughly every ~15s.
# Managed by the omcontrol-collect systemd --user service.
#
# Every tool here is invoked through a fixed absolute path and the sanitized
# bootstrap environment, so the ambient user/browser environment can never
# shadow a binary or inject LD_* state into the long-lived sampler.
#
# Cadence policy (adaptive + backoff):
#   * healthy + idle (latest sample old enough, CPU < 15%)  -> sleep 5s
#   * healthy + active                                      -> sleep 2s
#   * consecutive collect failures (wedged DB, heavy load)  -> exponential
#     backoff 2/4/8/16 -> capped 30s, resetting on first success. This stops
#     a wedged collector from hammering itself in a tight loop.

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/backend/bootstrap.sh"

T="/usr/bin/timeout"
S="/usr/bin/sleep"
[ -x "$T" ] || exit 1
[ -x "$S" ] || exit 1

DATA_DIR="${OMCONTROL_DATA_DIR:-$HOME/.local/share/omcontrol}"
DB="${OMCONTROL_DB:-$DATA_DIR/history.db}"

FL=0
I=0
SLEEP=2
while true; do
  # timeout guard with process-group termination: a wedged collector gets
  # SIGTERM on the whole group at the deadline and SIGKILL after a 2s grace,
  # so it can never stall or keep writing to the sampling loop forever.
  "$T" -k 2 30 /bin/sh "$SELF_DIR/backend/collect.sh" > /dev/null 2>&1
  RC=$?
  I=$((I + 1))

  if [ "$RC" -ne 0 ]; then
    FL=$((FL + 1))
    if [ "$FL" -gt 4 ]; then
      SLEEP=30
    else
      P=1; K=0
      while [ "$K" -lt "$FL" ]; do P=$((P * 2)); K=$((K + 1)); done
      SLEEP=$((2 * P))
    fi
  else
    FL=0
    # Adaptive cadence from the freshest metric row: idle system -> slower
    # polling, active system -> tight 2s. Missing/broken DB falls back to 2s.
    LIVE=$(sqlite3 -cmd ".timeout 1500" "$DB" "SELECT ts, cpu_pct FROM metrics ORDER BY ts DESC LIMIT 1;" 2>/dev/null)
    LTS=$(echo "$LIVE" | cut -d'|' -f1 2>/dev/null)
    LCPU=$(echo "$LIVE" | cut -d'|' -f2 2>/dev/null)
    NOW=$(date +%s)
    AGE=$((NOW - ${LTS:-0}))
    if [ -n "$LTS" ] && [ "$AGE" -le 8 ] && [ -n "$LCPU" ] && [ "${LCPU%.*}" -lt 15 ] 2>/dev/null; then
      SLEEP=5
    else
      SLEEP=2
    fi
  fi

  if [ $((I % 3)) -eq 0 ]; then
    "$T" -k 2 15 /bin/sh "$SELF_DIR/backend/enforce.sh" > /dev/null 2>&1
    "$T" -k 2 15 /bin/sh "$SELF_DIR/backend/privacy.sh" > /dev/null 2>&1
  fi
  "$S" "$SLEEP"
done