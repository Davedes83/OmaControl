#!/usr/bin/python3
"""OmaControl shared preference store.

flock-serialized, schema-validated, fsync'd atomic read/write of the bar-stats
preference file shared by the bar widget and the app window. Both components
(and bar-prefs.sh) go through this single helper so a stale read can never
overwrite a newer in-memory state and a torn write can never be observed.

Usage:
  prefs.py read     # dump current JSON to stdout ({} if absent/unreadable)
  prefs.py write    # read JSON on stdin, validate, replace atomically

Path: $OMCONTROL_BAR_PREFS (default $OMCONTROL_DATA_DIR/barstats.json)
Lock: <path>.lock, flock(2) — shared on read, exclusive on write.
"""
import fcntl
import json
import os
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def pref_path():
    p = os.environ.get("OMCONTROL_BAR_PREFS")
    if p:
        return p
    data_dir = os.environ.get(
        "OMCONTROL_DATA_DIR", os.path.expanduser("~/.local/share/omcontrol"))
    return os.path.join(data_dir, "barstats.json")


def open_lock(path):
    lockp = path + ".lock"
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    except OSError:
        pass
    return open(lockp, "a+b")


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def schema_ok(d):
    """barstats.json schema: object with optional stats list, mode, booleans."""
    if not isinstance(d, dict):
        return False
    if "stats" in d:
        if not isinstance(d["stats"], list):
            return False
        for s in d["stats"]:
            if not isinstance(s, dict) or not isinstance(s.get("name"), str):
                return False
    if "mode" in d and d["mode"] not in ("name", "none"):
        return False
    for k in ("barShowBell", "showBuyButton"):
        if k in d and not isinstance(d[k], (bool, int)):
            return False
    return True


def cmd_read():
    path = pref_path()
    lock = open_lock(path)
    try:
        fcntl.flock(lock, fcntl.LOCK_SH)
        print(json.dumps(read_json(path)))
        sys.stdout.flush()
    finally:
        try:
            fcntl.flock(lock, fcntl.LOCK_UN)
        except Exception:
            pass
        lock.close()


def cmd_write():
    path = pref_path()
    try:
        raw = sys.stdin.read()
        data = json.loads(raw)
    except Exception as e:
        print("invalid JSON on stdin: %s" % e, file=sys.stderr)
        return 1
    if not schema_ok(data):
        print("schema validation failed", file=sys.stderr)
        return 2
    lock = open_lock(path)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        directory = os.path.dirname(path) or "."
        os.makedirs(directory, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".barstats.", suffix=".tmp", dir=directory)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(data, f)
                f.flush()
                os.fsync(f.fileno())
            os.rename(tmp, path)
            try:
                dfd = os.open(directory, os.O_RDONLY)
                os.fsync(dfd)
                os.close(dfd)
            except OSError:
                pass
            print("ok")
            sys.stdout.flush()
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
    finally:
        try:
            fcntl.flock(lock, fcntl.LOCK_UN)
        except Exception:
            pass
        lock.close()
    return 0


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "read":
        cmd_read()
        return 0
    if cmd == "write":
        return cmd_write()
    print("usage: prefs.py read|write", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())