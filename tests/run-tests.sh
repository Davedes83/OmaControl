#!/bin/sh
# OmaControl test runner — runs every suite under a chosen shell.
#
# Usage:
#   tests/run-tests.sh [interpreter [flags]]
#
# Examples:
#   tests/run-tests.sh                 # default: sh
#   tests/run-tests.sh dash            # strict POSIX (Debian/Ubuntu default sh)
#   tests/run-tests.sh bash --posix    # bash in POSIX compatibility mode
#
# Each suite fails (nonzero) if any check fails; the runner exits nonzero if
# any suite failed.

set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$DIR/lib.sh"

OMC_TEST_SH="${1:-sh}"
export OMC_TEST_SH

_interp0=${OMC_TEST_SH%% *}
if command -v "$_interp0" >/dev/null 2>&1; then
  :
else
  echo "interpreter not found: $OMC_TEST_SH" >&2
  exit 2
fi

FAILED=0
for suite in schema-tests collector-tests; do
  echo "== $suite =="
  run_interp "$DIR/$suite.sh"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "PASS: $suite"
  else
    echo "FAIL: $suite (exit $rc)"
    FAILED=1
  fi
done

echo "== summary: $([ "$FAILED" -eq 0 ] && echo ALL PASSED || echo FAILED) =="
[ "$FAILED" -eq 0 ]
