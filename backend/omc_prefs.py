#!/usr/bin/env python3
"""OmControl shared alert-prefs helpers.

The legacy boolean prefs files (true meant "notify", but "toast" for New App
Launch; false meant "none") must map to the same toast/notify/none strings
everywhere the alert prefs are interpreted — alert-prefs.sh (editing) and
sql-ins.py (event gating) both used to carry this mapping independently.
Single source of truth here so the two cannot drift.
"""

MODE_LEGACY_TOAST = ("New App Launch",)


def normalize_mode(v, sens):
    if v is True:
        return "toast" if sens in MODE_LEGACY_TOAST else "notify"
    if v is False:
        return "none"
    return v if v in ("toast", "notify", "none") else "none"