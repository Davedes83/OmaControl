# OmaControl

**A native task manager for Omarchy that actually remembers what happened.**

Stock task managers show you *right now*. The moment something spikes and you look away, that information is gone. OmaControl keeps a running history of your system so you can scroll back and answer the question every Linux user eventually asks: *"what was my machine doing at 3am, and why is my fan still spinning?"*

It lives as a single icon in your Omarchy top bar and opens into a full monitoring app — built specifically for Hyprland + Quickshell, with zero Electron, zero background daemon binaries, and zero data leaving your machine.

## Why you'd want this over `btop`/`htop`

`btop` is great at showing you the present. It can't tell you what launched an hour ago, whether your webcam turned on while you were away, or which unsigned binary just showed up on your system. OmaControl is built around three ideas stock monitors skip entirely:

- **History, not just a snapshot.** Every 2 seconds, CPU, memory, GPU, disk, network, and temperature get written to a local SQLite database. Scrub back through the last hour, six hours, or day, click any point on the graph, and see exactly which processes were responsible.
- **A memory for events, not just processes.** New app launched. Unsigned binary ran for the first time. Microphone turned on. A process spiked the CPU. All of it lands in a persistent, filterable Events feed — click any entry to see the full system state at that exact moment, not just a log line.
- **Real enforcement, not just visibility.** Kill a runaway process, or permanently disable an app so it can't relaunch — even across reboots — instead of fighting the same background process every session.

## Features

### 📊 Activity — a history graph you can actually use
- Live CPU / Memory / GPU / Disk / Network / Process-count readouts, each with a full history graph behind it
- **Drag to zoom, scroll to pan** — scrub back through 1 hour, 6 hours, or a full day of history
- **Temperature strip** rendered directly under the graph, synced to whatever time range you're viewing
- **Event pins** overlaid right on the timeline — see exactly when an app launched or a spike happened relative to the resource curve, and jump straight into the details
- Hover any point for a ranked breakdown of exactly which processes were driving that moment

### 📦 Apps — everything installed, everything running
- Grouped by publisher, with trust/verification status pulled straight from your package manager
- Live permission indicators — see at a glance which apps currently hold camera, mic, or location access
- One click into a full detail panel: description, binary path, package, peak & average CPU/memory/GPU/I/O pulled from history, and a live count of open network sockets — no root required

### 🔔 Alerts — notifications on your terms
- Per-event-type control: desktop **toast**, silent **badge only**, or **off** — independently for new app launches, unsigned binaries, mic/camera access, location access, service changes, and more
- Toggle whether any event type shows up as a pin on the Activity chart, separately from its notification behavior

### 📜 Events — a real audit trail
- Every launch, exit, resource spike, permission access, and security flag, filterable by category (Launches, Exits, Spikes, Permissions, Security, User actions)
- Click any event for full context: the exact system state at that moment, the app's publisher and description, and how often that event type or app has shown up over the last week
- Unread events are tracked with a badge on the bar icon, not just buried in a log

### ⚙️ Process control that sticks
- Kill, suspend, resume, or renice any process
- **Disable an app permanently** — kills it now and blocks it from relaunching, enforced on every future launch, surviving reboots — not just a one-time kill you'll have to repeat tomorrow

### 🛡️ Security & privacy, built in
- New and unsigned/unverified binaries are automatically flagged, separate from ordinary launches
- Desktop notification the moment your camera, microphone, or location gets accessed by any app
- Works with both **NVIDIA** (`nvidia-smi`) and **AMD** (`amdgpu` sysfs) for GPU utilization and temperature — this isn't an NVIDIA-only tool

### 🖥️ A bar icon that shows what *you* care about
- Fully customizable: pick any combination of CPU, GPU, temps, RAM, swap, disk, network, process count, uptime, or battery
- Three display styles per stat — icon+value, label+value, or value only

### ⌨️ A real CLI for scripting
Everything the GUI can do is scriptable via `omcontrol`:

```bash
omcontrol status                        # current sample + store summary
omcontrol top --history 30m             # busiest apps over a time range
omcontrol history --metric cpu --seconds 3600
omcontrol procs-at <epoch_ts>           # process snapshot at a point in time
omcontrol app disable <name>            # kill now, block on relaunch
omcontrol rules add <name>              # persistent disable rule
omcontrol events --limit 50             # recent events
```

## Install

```bash
omarchy plugin add https://github.com/Davedes83/OmaControl.git --enable
```

Add the widget to your bar in `~/.config/omarchy/shell.json` (hot-reloads on save):

```json
{
  "bar": {
    "layout": {
      "right": [
        { "id": "davedes.omcontrol" }
      ]
    }
  }
}
```

```bash
omarchy restart shell
```

**Requirements:** [Omarchy](https://omarchy.org/), Hyprland, Quickshell, `sqlite3`, `python3`. GPU metrics work out of the box on both NVIDIA and AMD — no extra packages needed for AMD.

## Usage

- **Left-click** the bar icon — open/close the app window
- **Middle-click** — refresh the current sample instantly
- **Right-click** — jump to any tab, enforce disable rules, or kill the top CPU consumer without opening the window at all

## How it works, briefly

A lightweight collector samples `/proc` every 2 seconds and writes into a local SQLite database, downsampling older data automatically so the database stays bounded no matter how long it's been running. Nothing is sent anywhere — the entire history lives at `~/.local/share/omcontrol/history.db` on your machine, readable by the `omcontrol` CLI or any tool that speaks SQLite.

## Data & config

| Path | Contents |
|---|---|
| `~/.local/share/omcontrol/history.db` | Full metrics/events/app-metadata history |
| `~/.local/share/omcontrol/barstats.json` | Bar icon stat selection |
| `~/.local/share/omcontrol/rules.json` | Persistent app-disable rules |
| `~/.local/share/omcontrol/alert_prefs.json` | Per-event notification modes |

Override any of these with `OMCONTROL_DB`, `OMCONTROL_DATA_DIR`, or `OMCONTROL_RULES`.

## Remove

```bash
omarchy plugin remove davedes.omcontrol
```

## License

MIT