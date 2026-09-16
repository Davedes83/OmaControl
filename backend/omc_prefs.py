#!/usr/bin/python3
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