# OmaControl

An Omarchy shell plugin (Quickshell, Hyprland) that turns your top-bar icon into an advanced task manager — real-time system monitoring, a per-app history database, process control, privacy alerts, and persistent event tracking.

## Features

- **Live system monitoring in the bar** — CPU %, CPU/GPU temp, RAM, network and more as a single compact icon. Stats shown are fully customisable and persist to `barstats.json`:
  - `icon` — glyph + value, `name` — label + value, `none` — values only
  - pick any combination of stats (CPU, GPU, clocks, RAM, swap, disk, net up/down, processes, uptime, battery…)
- **App Window** (left-click the bar icon) with five tabs:
  - **Activity** — live MET pills (CPU, Memory, GPU, Processes, Disk, NET up/down) with interactive history graphs over 1H / 6H / 1D; click a graph point to see that moment's processes
  - **Apps** — running apps and publishers with trust status, one-click details, and live action buttons
  - **Alerts** — configurable thresholds and new-app/privacy alert controls
  - **Events** — persistent history of significant events (unread in bold, action buttons stop apps instantly)
  - **Settings** — choose which stats the bar icon shows and how they're rendered
- **Per-app Details panel** — description/provenance (`exe`/`pkg`), peak & average CPU, memory, GPU and I/O from historical samples, plus a live count of TCP/UDP sockets for that app (no root required)
- **Privacy alerts** — desktop notifications when the camera, microphone, or location are newly in use
- **New-app detection** — notifies when an application is first seen running
- **Process control** — kill, suspend/resume, priority boost/drop, or permanently disable an app (kill-now + enforce on next launch)
- **Historical database** — samples collected every 2 s from `/proc` (plus `nvidia-smi` for GPU) into SQLite; downsampled on the way in so you always have the full picture

## Installation

```bash
omarchy plugin add https://github.com/Davedes83/OmaControl.git --enable
```

Then make sure the bar widget is in your bar layout in `~/.config/omarchy/shell.json` (it hot-reloads on save):

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

Restart the shell:

```bash
omarchy restart shell
```

## Remove

```bash
omarchy plugin remove davedes.omcontrol
```

## Usage

1. **Left-click** the bar icon to open/close the App Window
2. **Middle-click** to refresh the current sample
3. **Right-click** for the context menu — jump to any tab, enforce rules, kill the top CPU process, or refresh
4. In **Settings** choose the stats the icon shows and whether each is rendered as an icon, name, or value-only

The widget also ships a CLI, `omcontrol`, for scripting:

```bash
omcontrol status                 # current sample + store summary
omcontrol top --history 30m      # busiest apps over the last range
omcontrol top --from TS --to TS  # ... between timestamps
omcontrol history --metric cpu --seconds 3600   # downsampled series
omcontrol procs-at <epoch_ts>    # process snapshot nearest to a timestamp
omcontrol rules                  # list persistent disable rules
omcontrol rules add <name>       # disable an app permanently
omcontrol rules rm <name>        # remove a disable rule
omcontrol events --limit 50      # recent persistent events
omcontrol events read-all        # mark all events read
omcontrol alert-prefs get        # show alert notification preferences
omcontrol alert-prefs set <type> on|off
omcontrol app open|close|toggle|tab 3
omcontrol app kill <name>        # SIGTERM all processes of this name
omcontrol app stop|cont <name>   # suspend / resume
omcontrol app fast|slow <name>   # renice ±5 priority
omcontrol app disable <name>     # kill now + enforce kill-on-launch
omcontrol app enable <name>      # remove the persistent disable rule
```

Ranges accept `5m/10m/30m/1h/6h/24h/3d`; metrics are `cpu|mem|gpu|gtemp|ctemp`.

## Data

- `~/.local/share/omcontrol/history.db` — SQLite history (metrics, per-app snapshots, app metadata)
- `~/.local/share/omcontrol/barstats.json` — bar icon stat selection
- `~/.local/share/omcontrol/rules.json` — persistent disable rules

Environment overrides: `OMCONTROL_DB`, `OMCONTROL_DATA_DIR`, `OMCONTROL_RULES`.

## How It Works

- `collect.sh` samples `/proc` every 2 s (CPU, memory, disk, per-process stats, network byte counters) and `nvidia-smi` for GPU utilization/temps, then writes to SQLite; old samples are downsampled out-of-band to keep the table bounded.
- Per-app history (`app-stats.sh`) aggregates peak/avg CPU, memory, GPU and I/O from the per-process snapshot blobs in `proc_history`.
- Live per-app socket counts come from `/proc/<pid>/fd` inode mapping into `/proc/net/{tcp,tcp6,udp,udp6}` — a small window into each app's network footprint without root.
- Alert/enforcement rules are applied on sample ingestion; disallowed apps are killed at launch. Everything runs from the plugin's own backend scripts, so it keeps working even if the database grows large.

## Requirements

- [Omarchy](https://omarchy.org/) Linux
- Hyprland compositor
- Quickshell (the shell framework)
- `sqlite3`, `python3`, `nvidia-smi` (for GPU metrics; everything else works without an NVIDIA GPU)

## License

MIT