#!/usr/bin/python3
"""OmaControl resolved-alert-thresholds CLI.

Print the active resource alert configuration for the shell collectors so they
never hardcode thresholds:

  omc-thresholds.py [prefs-path]

Output (two lines):
  1. the named profile ("mild" | "medium" | "severe")
  2. a JSON object of resolved thresholds (profile base + per-metric overrides)

Missing/corrupt prefs resolve to "medium" defaults so consumers stay working
even when alert_prefs.json cannot be read.
"""
import json
import os
import sys

sys.path.insert(0, os.environ.get("OMC_BACKEND", ""))
from omc_prefs import alert_profile, load_alert_prefs, resolve_thresholds

path = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
    "~/.local/share/omcontrol/alert_prefs.json")
d, _ = load_alert_prefs(path)
print(alert_profile(d))
print(json.dumps({k: float(v) for k, v in sorted(resolve_thresholds(d).items())}))