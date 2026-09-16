#!/bin/sh
# OmaControl stdout guard.
#
# Every collector helper that is launched by the QML bar/widget layer or by
# omcontrol-poll.sh is run through this wrapper. It enforces:
#
#   * Hard byte cap on stdout (default 256 KB — well above any legitimate
#     payload; a runaway producer that exceeds it is sliced at the boundary
#     and the consumer receives truncated (unparseable) output, causing the
#     UI to fall back to its last known good state).
#   * The producer itself is spawned under the sanitized bootstrap environment
#     (trusted PATH, minimal HOME).
#
# Usage:  run-capped.sh <interpreter> <script> [args...]
#
# With a GNU coreutils timeout the caller wraps the call one level further:
#   timeout -k 2 N /bin/sh run-capped.sh /bin/sh <script> [args...]
# This makes the producer sit inside its own process-group and guarantees
# group-level SIGTERM → SIGKILL reaping, satisfying the hard-deadline
# requirement.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/bootstrap.sh"

MAX="${OMCONTROL_MAX_OUT_BYTES:-262144}"
case "$MAX" in ''|*[!0-9]*) MAX=262144 ;; esac
[ "$MAX" -gt 0 ] 2>/dev/null || MAX=262144

# Pipe the producer through head. When MAX bytes pass, head closes the
# read end of the pipe; the producer receives SIGPIPE and terminates,
# bounding both memory and CPU on a runaway script.
"$@" 2>/dev/null | /usr/bin/head -c "$MAX"
