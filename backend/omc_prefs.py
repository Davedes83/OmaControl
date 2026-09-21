#!/usr/bin/python3
"""OmaControl shared alert-prefs helpers (sensitivities + resource thresholds).

Single source of truth for alert semantics so alert-prefs.sh (editing),
sql-ins.py (toast gating), sample-json.sh (hysteresis thresholds), collect.sh
(bar thresholds), and the QML UI (Model.js reading the emitted resolved
thresholds) can never drift apart.

The legacy boolean prefs files (true meant "notify", but "toast" for New App
Launch; false meant "none") must map to the same toast/notify/none strings
everywhere the alert prefs are interpreted. The mappings below are the single
home for that, plus the resource-threshold model:
  * a named profile ("mild" | "medium" | "severe") picks a base threshold set,
  * per-metric overrides in prefs["thresholds"] always win over the profile,
  * resolved thresholds are what every consumer uses (resolve_thresholds()).
"""

import json
import os
import tempfile

MODE_LEGACY_TOAST = ("New App Launch",)


def normalize_mode(v, sens):
    if v is True:
        return "toast" if sens in MODE_LEGACY_TOAST else "notify"
    if v is False:
        return "none"
    return v if v in ("toast", "notify", "none") else "none"


# DB event "type" -> alert sensitivity label. Was maintained separately in
# unread.sh (SENS) and sql-ins.py (TOAST_TYPE); one table here so both read
# the same mapping.
KIND_TO_SENS = {
    "app_launch": "New App Launch",
    "app_exit": "App Exit",
    "mic_access": "Mic or Cam Access",
    "cam_access": "Mic or Cam Access",
    "permission": "Mic or Cam Access",
    "location_access": "Location Tracking",
    "unsigned_launch": "Unsigned App Launch",
    "unknown_app": "Unsigned App Launch",
    "publisher_block": "Unsigned App Launch",
    "suspicious_app": "New Suspicious App",
    "service_change": "Service Change",
    "service_launch": "New Service Launch",
    "app_update": "App Update",
}

# privacy_events "device" -> alert sensitivity label.
DEVICE_TO_SENS = {
    "microphone": "Mic or Cam Access",
    "camera": "Mic or Cam Access",
    "location": "Location Tracking",
}

# ---- resource alert thresholds ------------------------------------------

# Default thresholds ("medium" profile): the values that shipped hardcoded in
# Model.js and sample-json.sh before they became configurable. "mild" relaxes
# them (fewer bells), "severe" tightens them (earlier warnings). Per-metric
# overrides in the stored prefs ("thresholds" object) always win over the
# profile so a user can tune one value without leaving the profile.
PROFILE_DEFAULT = "medium"

PROFILES = {
    "mild": {
        "cpu_pct": 95,      # total CPU usage % (all cores)
        "mem_pct": 90,      # used memory as % of total
        "gpu_pct": 88,      # GPU utilization %
        "cpu_temp": 92,     # °C
        "gpu_temp": 92,     # °C
        "proc_cpu_pct": 92, # any single process at >= this % CPU
        "proc_mem_pct": 40, # any single process at >= this % of memory
        "hold": 150,        # hysteresis latch window (seconds)
    },
    "medium": {
        "cpu_pct": 90,
        "mem_pct": 85,
        "gpu_pct": 80,
        "cpu_temp": 85,
        "gpu_temp": 85,
        "proc_cpu_pct": 80,
        "proc_mem_pct": 30,
        "hold": 90,
    },
    "severe": {
        "cpu_pct": 80,
        "mem_pct": 75,
        "gpu_pct": 70,
        "cpu_temp": 78,
        "gpu_temp": 78,
        "proc_cpu_pct": 70,
        "proc_mem_pct": 25,
        "hold": 60,
    },
}

THRESHOLD_KEYS = tuple(sorted(PROFILES["medium"].keys()))


def valid_threshold(key, value):
    """A threshold value is a finite positive number of a known metric."""
    if key not in PROFILES["medium"]:
        return False
    try:
        v = float(value)
    except (TypeError, ValueError):
        return False
    return v > 0 and v == v  # NaN rejects itself


def resolve_thresholds(d):
    """Effective thresholds from alert prefs: profile base + per-metric overrides.

    Missing/non-dict prefs resolve to the "medium" profile so every consumer
    shares one fallback constant even when the file cannot be read.
    """
    prefs = d if isinstance(d, dict) else {}
    profile = prefs.get("profile", PROFILE_DEFAULT)
    base = dict(PROFILES.get(profile, PROFILES[PROFILE_DEFAULT]))
    for k, v in (prefs.get("thresholds") or {}).items():
        if k in base:
            try:
                base[k] = float(v)
            except (TypeError, ValueError):
                pass
    return base


def alert_profile(d):
    """Named profile of these prefs, normalized to a known profile."""
    if not isinstance(d, dict):
        return PROFILE_DEFAULT
    p = d.get("profile", PROFILE_DEFAULT)
    return p if p in PROFILES else PROFILE_DEFAULT


# ---- alert_prefs.json access --------------------------------------------
# Reads and writes both go through these helpers. Writes are atomic
# (tempfile in the same directory + fsync + rename) so a crash mid-write can
# never leave a torn JSON file for sample-json.sh / sql-ins.py / unread.sh /
# collect.sh to choke on. Reads of a corrupt file warn on stderr and preserve
# a backup (path.corrupt) before degrading to defaults, so user prefs are
# never silently erased.

def _quarantine(path, why):
    try:
        with open(path, "rb") as f:
            blob = f.read()
        with open(path + ".corrupt", "wb") as b:
            b.write(blob)
        import sys
        print("warning: %s is unreadable (%s); kept a copy at %s.corrupt"
              % (path, why, path), file=sys.stderr)
    except Exception:
        pass


def load_alert_prefs(path):
    """Return (dict, changed). Always a dict with all keys materialized.

    changed is True when the on-disk content needed migration/normalization
    (so callers can persist it back); a missing file loads defaults without
    reporting a change.
    """
    try:
        with open(path, "r", encoding="utf-8") as f:
            d = json.load(f)
    except FileNotFoundError:
        return {
            "enabled": True, "types": {}, "charts": {},
            "profile": PROFILE_DEFAULT, "thresholds": {},
        }, False
    except Exception as e:
        _quarantine(path, str(e))
        d = None
    if d is None:
        d = {}
    elif not isinstance(d, dict):
        _quarantine(path, "root value is not a JSON object")
        d = {}
    d.setdefault("enabled", True)
    d.setdefault("types", {})
    d.setdefault("charts", {})
    profile = d.get("profile", PROFILE_DEFAULT)
    if profile not in PROFILES:
        d["profile"] = PROFILE_DEFAULT
        profile = PROFILE_DEFAULT
        changed = True
    else:
        changed = False
    d["profile"] = profile
    d.setdefault("thresholds", {})
    changed = _normalize_types(d, changed)
    return d, changed


def _normalize_types(d, changed):
    for t, v in list((d["types"] or {}).items()):
        n = normalize_mode(v, t)
        if n != v:
            d["types"][t] = n
            changed = True
    return changed


def save_alert_prefs(path, d):
    """Atomic write: same-dir tempfile + fsync + rename. Raises on failure."""
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".alert_prefs.", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(d, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.rename(tmp, path)
        try:
            dfd = os.open(directory, os.O_RDONLY)
            os.fsync(dfd)
            os.close(dfd)
        except OSError:
            pass
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass