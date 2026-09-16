<a href='https://ko-fi.com/O3N726LJT4' target='_blank'><img height='36' style='border:0px;height:36px;' src='https://storage.ko-fi.com/cdn/kofi5.png?v=6' border='0' alt='Buy Me a Coffee at ko-fi.com' /></a>

<img width="1600" height="1120" alt="preview png" src="https://github.com/user-attachments/assets/df68baa0-a1b8-4d63-8e0e-78bf6dcaf091" />
<img width="1920" height="1015" alt="screenshot-2026-09-14_19-03-49" src="https://github.com/user-attachments/assets/8916a4b1-c37b-48c0-b900-ed631b80b4c3" />
<img width="1920" height="1015" alt="screenshot-2026-09-14_19-06-50" src="https://github.com/user-attachments/assets/4792270b-a501-4561-b7b1-67c0697b3fab" />
<img width="1920" height="993" alt="screenshot-2026-09-14_19-05-38" src="https://github.com/user-attachments/assets/26bd46ed-ddda-4b42-aa25-7f81124c9b9b" />

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

### Optional: background history sampler

The bar widget and CLI record while the shell is running. To also fill history
when the shell is closed, enable the hardened user service (fixed `PATH`,
`LC_ALL=C`, strict umask, process-group timeouts on every helper):

```bash
systemctl --user enable --now ~/.config/omarchy/plugins/davedes.omcontrol/systemd/omcontrol-collect.service
```

Verify: `systemctl --user status omcontrol-collect` and `omacontrol status`.

## Usage

- **Left-click** — open/close the App Window
- **Middle-click** — refresh sample
- **Right-click** — context menu (jump to tab, enforce rules, kill top process)

Also ships a CLI: `omacontrol status`, `omacontrol top --history 30m`, `omacontrol app kill <name>`, and more — run `omacontrol --help` for the full list.

## Remove

```bash
omarchy plugin remove davedes.omcontrol
systemctl --user disable --now omcontrol-collect
```

## Requirements

- [Omarchy](https://omarchy.org/) Linux, Hyprland, Quickshell
- `sqlite3`, `python3`, `nvidia-smi` (optional, for GPU metrics)

## License

MIT
