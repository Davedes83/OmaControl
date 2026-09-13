#!/usr/bin/env python3
"""OmControl per-process network attribution for the chart drill-down.

Runs `ss -tinp` and keeps a cumulative-byte baseline per socket-owning PID
between snapshots; the minute-to-minute deltas become KB/s per process.
collect.sh merges the result into the proc_history snapshot (fields nr/nt) so
clicking a network spike on the chart can show who used that bandwidth.

Output (stdout): JSON array of {pid, name, rx, tx} sorted by rx+tx KB/s desc.
Never fails: prints [] and exits 0 on any error.
"""
import json
import os
import re
import subprocess
import sys
import time

DATA_DIR = os.environ.get("OMCONTROL_DATA_DIR",
                          os.path.expanduser("~/.local/share/omcontrol"))
BASE = os.path.join(DATA_DIR, ".omc_netprocs_base")

# ss -tinp prints one header, then for each socket a one-line summary ending
# in users:(("comm",pid=123,fd=4)) followed by an indented tcp_info block that
# carries the cumulative byte counters (bytes_sent / bytes_received).
SS_LINE_RE = re.compile(
    r"^\s*\S+\s+\d+\s+\d+\s+\S+\s+\S+\s+users:.*$")
SS_PROC_RE = re.compile(r'users:\(\(\"([^\"]*)\",\s*pid=(\d+),\s*fd=(\d+)\)\)')
SS_INFO_RE = re.compile(r"bytes_sent:(\d+).*?bytes_received:(\d+)", re.I)


def run_ss():
    """Grab an `ss -tinp` dump owned by this user (root sockets have no pid)."""
    try:
        out = subprocess.run(["ss", "-tinp"], capture_output=True, text=True,
                             timeout=20, check=False).stdout or ""
    except Exception:
        return ""
    return out


def parse(text):
    """Accumulate cumulative bytes_sent/received per socket-owning pid."""
    lines = text.splitlines()
    per_pid = {}
    names = {}
    for i in range(len(lines)):
        line = lines[i]
        if not line.startswith("ESTAB") or "users:((" not in line:
            continue
        if not SS_LINE_RE.match(line):
            continue
        pm = SS_PROC_RE.search(line)
        if not pm:
            continue
        sent = recv = 0
        if i + 1 < len(lines):
            im = SS_INFO_RE.search(lines[i + 1])
            if im:
                sent = int(im.group(1))
                recv = int(im.group(2))
        pid = pm.group(2)
        e = per_pid.get(pid)
        if e is None:
            e = per_pid[pid] = {"s": 0, "r": 0}
        e["s"] += sent
        e["r"] += recv
        names[pid] = pm.group(1)
    return per_pid, names


def comm_of(pid, names):
    try:
        with open("/proc/%s/comm" % pid, "r", encoding="utf-8",
                  errors="replace") as f:
            nm = f.read().strip()
        if nm:
            return nm
    except OSError:
        pass
    return names.get(pid, "pid" + str(pid))


def main():
    text = run_ss()
    if not text:
        print("[]")
        return 0
    now = time.time()
    cur, names = parse(text)

    have_base = os.path.exists(BASE)
    prev = {}
    if have_base:
        try:
            with open(BASE, "r", encoding="utf-8") as f:
                prev = json.load(f).get("pids", {})
        except Exception:
            prev = {}

    out = []
    for pid, e in cur.items():
        if not have_base:
            break  # first snapshot just establishes the baseline (warm-up)
        p = prev.get(pid, {})
        p_ts = float(p.get("ts") or now)
        elapsed = max(now - p_ts, 1.0)
        drx = e["r"] - (p.get("r") or 0)
        dtx = e["s"] - (p.get("s") or 0)
        if drx < 0:
            drx = 0
        if dtx < 0:
            dtx = 0
        rx = drx / 1024.0 / elapsed
        tx = dtx / 1024.0 / elapsed
        if rx + tx < 0.05:
            continue
        out.append({"pid": int(pid), "name": comm_of(pid, names),
                    "rx": round(rx, 1), "tx": round(tx, 1)})
    out.sort(key=lambda x: -(x["rx"] + x["tx"]))
    out = out[:40]

    # Persist the new baseline. PIDs that vanished from ss (all sockets closed)
    # keep their old counters so a reappearing process isn't over-counted; its
    # clock stays at the last time WE saw it, keeping the rate honest.
    newpids = {}
    for pid, p in prev.items():
        if pid not in cur:
            newpids[pid] = {"s": p.get("s", 0), "r": p.get("r", 0),
                            "ts": p.get("ts", now)}
    for pid, e in cur.items():
        newpids[pid] = {"s": e["s"], "r": e["r"], "ts": now}
    try:
        tmp = BASE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"pids": newpids}, f)
        os.replace(tmp, BASE)
    except Exception:
        pass

    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())