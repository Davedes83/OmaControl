#!/bin/sh
# OmControl app-net — live TCP/UDP socket counts for one app (non-root):
#   established (TCP ESTABLISHED), listening (TCP LISTEN), udp (UDP sockets).
# Maps socket inodes from /proc/<pid>/fd/* into /proc/net/{tcp,tcp6,udp,udp6}.
NAME="$1"
if [ -z "$NAME" ]; then
  echo '{}'
  exit 0
fi
LC_ALL=C OMC_NAME="$NAME" python3 - <<'PY'
import os, re, sys
name = os.environ["OMC_NAME"]
pids = []
for d in os.listdir("/proc"):
    if not d.isdigit():
        continue
    base = "/proc/" + d
    try:
        with open(base + "/comm") as f:
            comm = f.read().strip()
        if comm == name or (len(name) <= 15 and comm[:15] == name[:15]):
            pids.append(int(d))
    except Exception:
        continue
if not pids:
    print("{}"); raise SystemExit
inode_pids = {}
for pid in pids:
    try:
        fds = os.listdir(f"/proc/{pid}/fd")
    except Exception:
        continue
    for fd in fds:
        try:
            t = os.readlink(f"/proc/{pid}/fd/{fd}")
        except Exception:
            continue
        m = re.match(r"^socket:\[(\d+)\]$", t)
        if m:
            inode_pids[m.group(1)] = pid
if not inode_pids:
    print("{}"); raise SystemExit
established = listening = udp = 0
def scan(path, is_udp):
    global established, listening, udp
    try:
        with open(path) as f:
            for line in f:
                parts = line.split()
                if len(parts) < 10 or parts[0] == "sl" or parts[0][0] not in "0123456789":
                    continue
                inode = parts[9]
                if inode not in inode_pids:
                    continue
                if is_udp:
                    udp += 1
                else:
                    st = parts[3]
                    if st == "0A":
                        listening += 1
                    elif st == "01":
                        established += 1
    except Exception:
        pass
scan("/proc/net/tcp", False)
scan("/proc/net/tcp6", False)
scan("/proc/net/udp", True)
scan("/proc/net/udp6", True)
print('{"established":%d,"listening":%d,"udp":%d}' % (established, listening, udp))
PY