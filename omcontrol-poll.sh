#!/bin/sh
# OmControl continuous sampler — keeps the history database filled even when
# no OmaControl UI is open. Runs collect.sh every 2 seconds in a tight loop
# and re-applies enforcement rules roughly every 5 seconds.
# Managed by the omcontrol-collect systemd --user service.

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
I=0
while true; do
  sh "$SELF_DIR/backend/collect.sh" > /dev/null 2>&1
  I=$((I + 1))
  if [ $((I % 3)) -eq 0 ]; then
    sh "$SELF_DIR/backend/enforce.sh" > /dev/null 2>&1
  fi
  if [ $((I % 3)) -eq 0 ]; then
    sh "$SELF_DIR/backend/privacy.sh" > /dev/null 2>&1
  fi
  sleep 2
done