#!/bin/sh
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/bootstrap.sh"
# match-pids.sh <name> — print pids (one per line) whose process comm OR
# resolved exe basename equals <name>.
#
# comm (as shown by `ps -o comm` and /proc/<pid>/comm) is truncated to 15
# characters, so two long-lived binaries can collide on the same truncated
# name. The /proc/<pid>/exe symlink resolves to the real binary; matching the
# full basename catches processes whose comm was truncated, and is what rule
# matching should use everywhere (enforce.sh, app-action.sh).
NAME="$1"
[ -n "$NAME" ] || exit 0
for d in /proc/[0-9]*; do
  [ -d "$d" ] || continue
  pid=${d#/proc/}
  IFS= read -r comm < "$d/comm" 2>/dev/null || continue
  if [ "$comm" = "$NAME" ]; then
    echo "$pid"
    continue
  fi
  exe=$(readlink "$d/exe" 2>/dev/null)
  [ -n "$exe" ] || continue
  [ "${exe##*/}" = "$NAME" ] && echo "$pid"
done
