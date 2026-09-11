#!/usr/bin/env python3
"""OmControl parameterized SQL writer.

Replaces hand-assembled `INSERT INTO events` / `INSERT INTO privacy_events`
string concatenation across collect.sh / enforce.sh / app-action.sh /
privacy.sh, where attacker-influenceable process/app names were previously
quoted with `sed "s/'/''/g"` only (incomplete under some SQLite escaping
configs). Every value here is a bound `?` parameter.

Reads tab-separated rows on stdin; one transaction covers the whole batch.
Row formats (op is the first field):

  event\t<ts>\t<type>\t<app>\t<pub|''>\t<msg>\t<known|0>
      publisher resolves from app_meta when <pub> is empty; when <known>=1
      the row is dropped unless the resolved publisher is not "Unknown".

  privacy\t<ts>\t<action>\t<device>\t<name>\t<pid>

Exit status: 0 ok, 3 on sqlite error.
"""
import os
import sqlite3
import sys

DB = os.environ.get("OMCONTROL_DB") or os.path.expanduser(
    "~/.local/share/omcontrol/history.db")

SCHEMA = (
    "CREATE TABLE IF NOT EXISTS events ("
    " id INTEGER PRIMARY KEY AUTOINCREMENT,"
    " ts INTEGER, type TEXT, app TEXT, publisher TEXT, msg TEXT,"
    " read INTEGER DEFAULT 0)",
    "CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts)",
    "CREATE TABLE IF NOT EXISTS privacy_events ("
    " id INTEGER PRIMARY KEY AUTOINCREMENT,"
    " ts INTEGER, action TEXT, device TEXT, name TEXT, pid INTEGER)",
    "CREATE INDEX IF NOT EXISTS idx_priv_ts ON privacy_events(ts)",
)
INSERT_EVENT = (
    "INSERT INTO events (ts, type, app, publisher, msg, read)"
    " VALUES (?, ?, ?, ?, ?, 0)"
)
INSERT_PRIVACY = (
    "INSERT INTO privacy_events (ts, action, device, name, pid)"
    " VALUES (?, ?, ?, ?, ?)"
)


def publisher(cur, cache, name):
    if name in cache:
        return cache[name]
    try:
        row = cur.execute(
            "SELECT publisher FROM app_meta WHERE name = ? LIMIT 1", (name,)
        ).fetchone()
    except sqlite3.Error:
        row = None
    cache[name] = row[0] if row and row[0] else "Unknown"
    return cache[name]


def main():
    con = sqlite3.connect(DB, timeout=3)
    try:
        for stmt in SCHEMA:
            con.execute(stmt)
        cur = con.cursor()
        events = []
        privacy = []
        meta = {}
        for line in sys.stdin:
            line = line.rstrip("\n")
            if not line:
                continue
            f = line.split("\t")
            op = f[0]
            try:
                if op == "event" and len(f) >= 6:
                    ts, etype, app, pub, msg = int(f[1]), f[2], f[3], f[4], f[5]
                    known = len(f) > 6 and f[6] == "1"
                    if not pub:
                        pub = publisher(cur, meta, app)
                        if known and pub == "Unknown":
                            continue
                    events.append((ts, etype, app, pub, msg))
                elif op == "privacy" and len(f) >= 6:
                    ts = int(f[1])
                    privacy.append((ts, f[2], f[3], f[4], int(f[5] if f[5] else 0)))
            except (ValueError, IndexError):
                continue
        if events:
            cur.executemany(INSERT_EVENT, events)
        if privacy:
            cur.executemany(INSERT_PRIVACY, privacy)
        con.commit()
    except sqlite3.Error as e:
        sys.stderr.write("sql-ins: %s\n" % e)
        sys.exit(3)
    finally:
        con.close()


if __name__ == "__main__":
    main()