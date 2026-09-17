#!/bin/sh
# Shared helpers + TAP-ish assertions for the OmaControl test suites.
# Sourced by tests/*-tests.sh. POSIX-only so the suites run under dash,
# bash, and bash --posix identically.

# Interpreter under test (default: /bin/sh). The collector/reader scripts are
# re-invoked with this shell so portability is actually exercised.
: "${OMC_TEST_SH:=sh}"

CHECKS=0
FAILS=0

ok() {
  CHECKS=$((CHECKS + 1))
  echo "ok $CHECKS - $1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILS=$((FAILS + 1))
  echo "not ok $CHECKS - $1"
  if [ "$#" -ge 2 ]; then
    echo "  # $2"
  fi
}

check_eq() {
  # check_eq NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    fail "$1" "expected '$2', got '$3'"
  fi
}

check_run() {
  # check_run NAME CMD [ARG...]  — passes when CMD exits 0
  _name=$1
  shift
  if "$@"; then
    ok "$_name"
  else
    fail "$_name" "command failed: $*"
  fi
}

finish() {
  echo "1..$CHECKS"
  if [ "$FAILS" -gt 0 ]; then
    echo "# $FAILS of $CHECKS checks failed"
  else
    echo "# all $CHECKS checks passed"
  fi
  [ "$FAILS" -eq 0 ]
}

# Run a backend script under the interpreter under test.
# OMC_TEST_SH may carry an option word, e.g. "bash --posix".
run_interp() {
  case "$OMC_TEST_SH" in
    *\ *)
      _interp=${OMC_TEST_SH%% *}
      _opt=${OMC_TEST_SH#* }
      "$_interp" "$_opt" "$@"
      ;;
    *)
      "$OMC_TEST_SH" "$@"
      ;;
  esac
}
