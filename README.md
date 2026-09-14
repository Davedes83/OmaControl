<a href='https://ko-fi.com/O3N726LJT4' target='_blank'><img height='36' style='border:0px;height:36px;' src='https://storage.ko-fi.com/cdn/kofi5.png?v=6' border='0' alt='Buy Me a Coffee at ko-fi.com' /></a>

<img width="1600" height="1120" alt="preview png" src="https://github.com/user-attachments/assets/df68baa0-a1b8-4d63-8e0e-78bf6dcaf091" />

# OmaControl

An Omarchy shell plugin (Quickshell, Hyprland) that turns your top-bar icon into an advanced task manager — live system monitoring, per-app history, process control, and privacy alerts.

## Features

- **Live bar stats** — CPU, temps, RAM, network, and more as a compact, customizable icon
- **App Window** with tabs for Activity (live graphs, 1H/6H/1D), Apps (running processes + trust status), Alerts, Events, and Settings
- **Per-app details** — CPU/mem/GPU/I/O history, provenance, and live socket counts (no root needed)
- **Privacy alerts** — notified when camera, mic, or location get used
- **Process control** — kill, suspend/resume, renice, or permanently disable an app
- **Historical database** — SQLite-backed samples every 2s, downsampled over time

## Installation

```bash
omarchy plugin add https://github.com/Davedes83/OmaControl.git --enable
```

Add the widget to `~/.config/omarchy/shell.json`:

```json
{
  "bar": {
    "layout": {
      "right": [{ "id": "davedes.omcontrol" }]
    }
  }
}
```

```bash
omarchy restart shell
```

## Usage

- **Left-click** — open/close the App Window
- **Middle-click** — refresh sample
- **Right-click** — context menu (jump to tab, enforce rules, kill top process)

Also ships a CLI: `omcontrol status`, `omcontrol top --history 30m`, `omcontrol app kill <name>`, and more — run `omcontrol --help` for the full list.

## Remove

```bash
omarchy plugin remove davedes.omcontrol
```

## Requirements

- [Omarchy](https://omarchy.org/) Linux, Hyprland, Quickshell
- `sqlite3`, `python3`, `nvidia-smi` (optional, for GPU metrics)

## License

MIT
