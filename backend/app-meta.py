#!/usr/bin/python3
"""OmControl app metadata resolver — for each "pid name" line on stdin, fill in
the app_meta table (publisher, package, verified, description) using pacman /
flatpak, caching results so resolution only happens once per app ever.

Usage: app-meta.py  (env: OMCONTROL_DB, optional OMCONTROL_RULES)
stdin:   lines of "PID NAME" for processes currently running
Does:     INSERT OR IGNORE into app_meta(name, ...), refreshes unknown rows
          whose last retry is older than one day.
"""
import json
import os
import re
import sqlite3
import subprocess
import sys
import time

DB = os.environ.get("OMCONTROL_DB", os.path.expanduser("~/.local/share/omcontrol/history.db"))
NOW = int(time.time())

# Processes we always trust (the platform itself).
CORE = {
    "systemd", "kthreadd", "quickshell", "Hyprland", "pipewire", "pipewire-pulse",
    "wireplumber", "Xwayland", "dbus-daemon", "dbus-broker", "systemd-oomd",
    "systemd-logind", "systemd-resolved", "systemd-udevd", "systemd-journald",
    "systemd-userdbd", "systemd-tmpfiles", "systemd-timesyncd", "systemd-hostnamed",
    "polkitd", "swaybg", "swayidle", "swaylock", "mako", "dunst", "cliphist",
    "grim", "slurp", "satty", "wluma", "playerctld", "udiskie", "firewalld",
    "NetworkManager", "wpa_supplicant", "docker", "containerd", "dockerd",
    "gpg-agent", "ssh-agent", "ssh", "sshd", "fuzzel", "rofi", "wofi", "tofi",
    "brightnessctl", "light", "xdg-desktop-portal", "xdg-desktop-portal-qt",
    "xdg-desktop-portal-hyprland", "xdg-permission-store", "pinentry",
}
CORE_DESC = {
    "systemd": "System and service manager (PID 1)",
    "quickshell": "Quickshell shell — powering the Omarchy desktop",
    "Hyprland": "Hyprland compositor",
    "pipewire": "Audio/video server",
    "wireplumber": "PipeWire session manager",
    "Xwayland": "X11 compatibility under Wayland",
    "dbus-daemon": "D-Bus message broker",
    "NetworkManager": "Network connection manager",
    "docker": "Container runtime",
    "containerd": "Container runtime daemon",
    "fuzzel": "Application launcher",
    "polkitd": "PolicyKit authorization daemon",
    "systemd-oomd": "Out-of-memory killer daemon",
    "grim": "Screenshot tool",
}

# Kernel threads have no userspace binary — classify by name so they get a
# meaningful description instead of "unknown".
KWORKER_TASK = {
    "btrfs-endio": "deferred read/write I/O completion for the btrfs filesystem",
    "btrfs-cow": "copy-on-write background work for the btrfs filesystem",
    "btrfs-fixup": "checksum fix-up work for the btrfs filesystem",
    "btrfs-dio": "direct-I/O completion for the btrfs filesystem",
    "btrfs-delalloc": "delayed-allocation flushing for the btrfs filesystem",
    "btrfs-freespace": "free-space management for the btrfs filesystem",
    "kcryptd": "on-the-fly dm-crypt disk encryption/decryption",
    "flush-": "flush writeback of dirty pages to a block device",
    "events": "general deferred kernel event processing",
    "events_power_efficient": "power-optimized deferred kernel event processing",
    "mm_percpu_wq": "memory-management per-CPU workqueue",
    "netns": "network-namespace cleanup work",
}

KTHREADS = [
    (r"^kworker/[^/]+-(.*)$", "kworker"),
    (r"^kworker\b|^kworker/\d+:\d+$|^kworker/u\d+:\d+$", None),
    (r"^kswapd\d*$", "kswapd — the kernel swap daemon; reclaims memory pages when the system is under pressure."),
    (r"^ksoftirqd(?:/\d+)?$", "ksoftirqd — kernel thread that processes deferred software interrupts."),
    (r"^kcompactd\d*$", "kcompactd — memory-compaction daemon; defragments memory for large/long-lived allocations."),
    (r"^khugepaged$", "khugepaged — kernel daemon that promotes regular pages into huge pages."),
    (r"^kthreadd$", "kthreadd — the kernel thread forker; spawns and supervises every other kernel thread."),
    (r"^rcu[a-z_]*$|^rcu[a-z_]*/\d+$", "RCU — Read-Copy-Update kernel workers; track grace periods and reclaim kernel memory."),
    (r"^migration/\d+$", "migration — per-CPU kernel thread that moves tasks between CPUs for load balancing."),
    (r"^watchdog/\d+$|^watchdogd$", "watchdog — per-CPU kernel thread driving the hardware watchdog."),
    (r"^cpuhp/\d+$", "cpuhp — CPU hotplug control thread."),
    (r"^kblockd$", "kblockd — block-layer workqueue; processes request queues for block devices."),
    (r"^kdevtmpfs$", "kdevtmpfs — maintains device nodes in devtmpfs (/dev)."),
    (r"^kcryptd$", "kcryptd — device-mapper crypt worker; does on-the-fly disk encryption/decryption."),
    (r"^dmcrypt_write$", "dmcrypt_write — device-mapper crypt write worker."),
    (r"^k*dm-flush|^kdmflush$|^dm-bufio", "device-mapper background I/O worker (LVM/dm-crypt)."),
    (r"^kjournald\d*$|^jbd2/", "Journalling thread — writes filesystem journal transactions (ext4/btrfs) for crash safety."),
    (r"^oom_reaper$", "oom_reaper — out-of-memory killer thread; reaps processes the OOM killer condemned."),
    (r"^kthrotld$", "kthrotld — block-device I/O throttling thread (blk-throttle)."),
    (r"^memcg.*$", "memcg — memory control-group kernel worker."),
]

def sh(args, timeout=12):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return (r.stdout or "").strip()
    except Exception:
        return ""

def flatpak_info(appid):
    remote = sh(["flatpak", "info", "--show-remote", appid])
    return ("Flatpak", remote or "Unknown") if remote else ("Flatpak", "Unknown")

def describe(name):
    me = os.path.dirname(os.path.abspath(__file__))
    out = sh(["sh", os.path.join(me, "process-info.sh"), name])
    if not out:
        return ""
    try:
        return json.loads(out).get("description", "")
    except Exception:
        return ""

def cmdline_of(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            data = f.read().decode("utf-8", "replace").split("\0")
        return [a for a in data if a]
    except Exception:
        return []

def resolve(name, pid):
    """Return (exe, pkg, publisher, desc, verified, source)."""
    exe = sh(["readlink", f"/proc/{pid}/exe"])
    if not exe:
        exe = sh(["which", name])
    if name in CORE:
        return (exe, "", "Omarchy core", CORE_DESC.get(name, "Core system component"), 1, "system")
    # Kernel threads have no userspace binary — classify by name.
    for pat, d in KTHREADS:
        m = re.match(pat, name)
        if m:
            if d == "kworker":
                t = m.group(1)
                desc = "Kernel worker thread — " + KWORKER_TASK.get(t,
                    "deferred background work (workqueue task: %s)" % t) + "."
            else:
                desc = d
            return (exe, "", "Linux kernel", desc, 1, "system")
    if not exe:
        args = cmdline_of(pid)
        desc = ""
        if args:
            if args[0].startswith("/") and os.path.exists(args[0]) and not desc:
                exe = args[0]
            desc = "Command: " + " ".join(args)[:110]
        return (exe, "", "Unknown", desc, 0, "unknown")
    # Flatpak app dirs
    if re.search(r"/(?:var/lib|home/|\.)flatpak/(?:app|repo)/", exe) or exe.startswith("/var/lib/flatpak"):
        m = re.search(r"flatpak/app/([^/]+)", exe)
        publisher, remote = flatpak_info(m.group(1)) if m else ("Flatpak", "Unknown")
        return (exe, m.group(1) if m else "", publisher, "Flatpak application", 1 if remote and remote != "Unknown" else 0, "flatpak")
    # pacman-owned binaries
    q = sh(["pacman", "-Qo", exe])
    m = re.match(r"^(.*) is owned by (\S+)", q)
    if m:
        pkg = m.group(2)
        info = sh(["pacman", "-Qi", pkg])
        packager = re.search(r"^Packager\s*:\s*(.+)$", info, re.M)
        verified_by = re.search(r"^Validated By\s*:\s*(.+)$", info, re.M)
        desc = re.search(r"^Description\s*:\s*(.+)$", info, re.M)
        publisher = packager.group(1).strip() if packager else pkg
        publisher = re.sub(r"\s*<[^>]*>\s*$", "", publisher).strip() or pkg
        in_sync = bool(sh(["pacman", "-Si", pkg]))
        verified = 1 if in_sync else (0 if verified_by and not verified_by.group(1).strip() else (1 if in_sync else 0))
        if not in_sync:
            verified = 0
        return (exe, pkg, publisher[:60], (desc.group(1).strip() if desc else "")[:120], 1 if verified else 0, "pacman")
    # Last resort — the process-info dictionary (shells, launchers, convenience
    # binaries that no single package cleanly owns).
    desc = describe(name)
    if not desc or "Unknown system process" in desc:
        args = cmdline_of(pid)
        if args:
            cmd = " ".join(args)[:110]
            desc = "Command: " + cmd if not desc else desc + " · " + cmd
    return (exe, "", "Unknown", desc[:120], 0, "unknown")

def main():
    con = sqlite3.connect(DB, timeout=8)
    con.execute("""CREATE TABLE IF NOT EXISTS app_meta (
        name TEXT PRIMARY KEY, exe TEXT, pkg TEXT, publisher TEXT,
        desc TEXT, verified INTEGER DEFAULT 0, source TEXT DEFAULT 'unknown',
        first_seen INTEGER, updated INTEGER);""")
    con.commit()
    now = NOW
    seen = {}
    for line in sys.stdin:
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        pid, name = parts[0], parts[1]
        try:
            pid = int(pid)
        except ValueError:
            continue
        name = name.strip()
        if not name or name.startswith("["):
            continue
        if name not in seen:
            seen[name] = pid
    if not seen:
        con.close()
        return
    rows = {}
    for name, pid in seen.items():
        r = con.execute(
            "SELECT exe, pkg, publisher, desc, verified, source, updated FROM app_meta WHERE name=?", (name,)).fetchone()
        if r is None:
            rows[name] = pid
        else:
            src = r[5]
            if src == "unknown" and (r[6] or 0) < now - 86400:
                rows[name] = pid
    if not rows:
        con.close()
        return
    for name, pid in rows.items():
        exe, pkg, publisher, desc, verified, source = resolve(name, pid)
        try:
            con.execute(
                """INSERT INTO app_meta (name, exe, pkg, publisher, desc, verified, source, first_seen, updated)
                   VALUES (?,?,?,?,?,?,?,?,?)
                   ON CONFLICT(name) DO UPDATE SET
                     exe=excluded.exe, pkg=excluded.pkg, publisher=excluded.publisher,
                     desc=excluded.desc, verified=excluded.verified, source=excluded.source,
                     updated=excluded.updated""",
                (name, exe or "", pkg or "", publisher or "", desc or "", 1 if verified else 0, source, now, now))
        except sqlite3.Error:
            pass
    con.commit()
    con.close()

if __name__ == "__main__":
    main()