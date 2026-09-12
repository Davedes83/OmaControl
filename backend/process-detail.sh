#!/usr/bin/env python3
"""OmControl per-PID detail — maps a process name to every running instance
with a /proc snapshot. Called on demand from the detail panel.

Usage: process-detail.sh <name>
Output: {"name": <name>, "pids": [ {pid, ppid, user, uid, state, state_label,
        threads, rss_mb, vsize_mb, vmpeak_mb, cpu_s, elapsed_s, cmdline,
        exe, cwd, fds, unit}, ... ]}  (sorted by pid, capped at 25)
"""
import json
import os
import pwd
import sys
import time

NAME = sys.argv[1] if len(sys.argv) > 1 else ""

STATE_LABEL = {
    "R": "running", "S": "sleeping", "D": "disk wait", "Z": "zombie",
    "T": "stopped", "t": "stopped", "X": "dead", "I": "idle",
}


def status(pid):
    try:
        d = {}
        with open("/proc/%d/status" % pid) as f:
            for line in f:
                k, _, v = line.partition(":")
                d[k.strip()] = v.strip()
        return d
    except OSError:
        return {}


def first_uid(d):
    for tok in d.get("Uid", "").replace("\t", " ").split():
        try:
            return int(tok)
        except ValueError:
            pass
    return None


def mb(kb):
    try:
        return round(int(kb.split()[0]) / 1024.0, 1)
    except (TypeError, ValueError, IndexError):
        return 0.0


def unit_of(cgroup_line):
    tail = cgroup_line.split(":", 2)[-1].strip().rstrip("/")
    return tail.rsplit("/", 1)[-1] if tail else ""


def main():
    result = {"name": NAME, "pids": []}
    if not NAME:
        print(json.dumps(result))
        return

    btime = 0
    try:
        with open("/proc/stat") as f:
            for line in f:
                if line.startswith("btime "):
                    btime = int(line.split()[1])
                    break
    except (OSError, ValueError):
        pass
    clk = os.sysconf("SC_CLK_TCK") or 100
    now = time.time()

    matched = []
    try:
        procs = os.listdir("/proc")
    except OSError:
        procs = []
    for ent in procs:
        if not ent.isdigit():
            continue
        pid = int(ent)
        try:
            with open("/proc/%d/comm" % pid) as f:
                comm = f.read().strip()
            cand = comm == NAME
            if not cand:
                with open("/proc/%d/cmdline" % pid) as f:
                    argv = f.read().replace("\0", " ").strip()
                base = argv.split(" ", 1)[0].rsplit("/", 1)[-1] if argv else ""
                cand = base == NAME
            if not cand:
                continue
        except OSError:
            continue
        matched.append(pid)
    matched = sorted(matched)[:25]

    for pid in matched:
        st = status(pid)
        if not st:
            continue
        utime = stime = 0.0
        started = 0
        try:
            with open("/proc/%d/stat" % pid) as f:
                toks = f.read().split(")", 1)[1].split()
            utime = int(toks[11]) / clk
            stime = int(toks[12]) / clk
            started = btime + int(toks[19]) / clk
        except (OSError, ValueError, IndexError):
            pass
        uid = first_uid(st)
        user = ""
        if uid is not None:
            try:
                user = pwd.getpwuid(uid).pw_name
            except KeyError:
                user = str(uid)
        state = (st.get("State", "?") or "?")[0:1]
        entry = {
            "pid": pid,
            "ppid": int(st.get("PPid", "0") or 0),
            "user": user,
            "uid": uid,
            "state": state,
            "state_label": STATE_LABEL.get(state, state),
            "threads": int(st.get("Threads", "0") or 0),
            "rss_mb": mb(st.get("VmRSS", "0")),
            "vsize_mb": mb(st.get("VmSize", "0")),
            "vmpeak_mb": mb(st.get("VmPeak", "0")),
            "cpu_s": round(utime + stime, 1),
            "elapsed_s": int(max(0, now - started)) if started else 0,
            "cmdline": "",
            "exe": "",
            "cwd": "",
            "fds": 0,
            "unit": "",
        }
        try:
            with open("/proc/%d/cmdline" % pid) as f:
                entry["cmdline"] = f.read().replace("\0", " ").strip()
        except OSError:
            pass
        for key, path in (("exe", "exe"), ("cwd", "cwd")):
            try:
                entry[key] = os.readlink("/proc/%d/%s" % (pid, path))
            except OSError:
                pass
        try:
            entry["fds"] = len(os.listdir("/proc/%d/fd" % pid))
        except OSError:
            pass
        try:
            with open("/proc/%d/cgroup" % pid) as f:
                entry["unit"] = unit_of(f.read().strip().splitlines()[-1])
        except (OSError, IndexError):
            pass
        result["pids"].append(entry)

    print(json.dumps(result))


if __name__ == "__main__":
    main()