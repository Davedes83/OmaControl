#!/bin/sh
# OmaControl continuous sampler — keeps the history database filled even when
# no OmaControl UI is open. Runs collect.sh every 2 seconds in a tight loop
# and re-applies enforcement rules roughly every 5 seconds.
# Managed by the omcontrol-collect systemd --user service.
#
# Every tool here is invoked through a fixed absolute path and the sanitized
# bootstrap environment, so the ambient user/browser environment can never
# shadow a binary or inject LD_* state into the long-lived sampler.

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/backend/bootstrap.sh"

T="/usr/bin/timeout"
S="/usr/bin/sleep"
[ -x "$T" ] || exit 1
[ -x "$S" ] || exit 1

I=0
while true; do
  # timeout guard with process-group termination: a wedged collector gets
  # SIGTERM on the whole group at the deadline and SIGKILL after a 2s grace,
  # so it can never stall or keep writing to the sampling loop forever.
  "$T" -k 2 30 /bin/sh "$SELF_DIR/backend/collect.sh" > /dev/null 2>&1
  I=$((I + 1))
  if [ $((I % 3)) -eq 0 ]; then
    "$T" -k 2 15 /bin/sh "$SELF_DIR/backend/enforce.sh" > /dev/null 2>&1
  fi
  if [ $((I % 3)) -eq 0 ]; then
    "$T" -k 2 15 /bin/sh "$SELF_DIR/backend/privacy.sh" > /dev/null 2>&1
  fi
  "$S" 2
done