#!/bin/sh
# OmaControl secure-execution bootstrap.
#
# Sourced immediately after a script's shebang (or by the python entrypoints'
# spawning process). It normalizes the environment so that no collector can be
# influenced by anything inherited from the caller:
#
#   * PATH is replaced with a fixed, root-owned allowlist. A shadow executable
#     dropped anywhere else on the user's PATH (~/bin, a repo dir, ...) can
#     never be resolved here.
#   * Locale is pinned to C so ps/sqlite/jq output parsing is deterministic.
#   * Dynamic-loader and interpreter module injection variables are dropped.
#   * The plugin data directory is guaranteed to exist.
umask 077

export PATH=/usr/bin:/bin
export LC_ALL=C

unset LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH LD_LIBRARY_PATH_64 \
      PYTHONHOME PYTHONSTARTUP PYTHONPATH PERL5LIB PERLLIB 2>/dev/null || true

: "${OMCONTROL_DATA_DIR:=$HOME/.local/share/omcontrol}"
export OMCONTROL_DATA_DIR
mkdir -p "$OMCONTROL_DATA_DIR" 2>/dev/null || true