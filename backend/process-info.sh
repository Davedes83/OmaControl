#!/bin/sh
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/bootstrap.sh"
# OmaControl process info — given a process name, returns a human-readable description.
# Usage: process-info.sh <process_name>

NAME="$1"
if [ -z "$NAME" ]; then
  echo '{"description":"No process name provided."}'
  exit 0
fi

# Try to find the package that owns this binary
PKG=""
BIN_PATH=$(which "$NAME" 2>/dev/null)
if [ -n "$BIN_PATH" ]; then
  PKG=$(pacman -Qo "$BIN_PATH" 2>/dev/null | awk '{print $5, $6}')
fi

# Also check /usr/bin, /usr/sbin, /usr/lib
if [ -z "$PKG" ] && [ -f "/usr/bin/$NAME" ]; then
  PKG=$(pacman -Qo "/usr/bin/$NAME" 2>/dev/null | awk '{print $5, $6}')
fi
if [ -z "$PKG" ] && [ -f "/usr/sbin/$NAME" ]; then
  PKG=$(pacman -Qo "/usr/sbin/$NAME" 2>/dev/null | awk '{print $5, $6}')
fi

# Local dictionary of common Linux processes
DESC=""
case "$NAME" in
  # Core system
  systemd) DESC="Systemd init manager — PID 1, manages all system services and resources." ;;
  bash | zsh | fish | sh) DESC="Shell process — a command-line interpreter session." ;;
  sshd) DESC="SSH daemon — accepts incoming remote login connections." ;;
  cron | crond) DESC="Cron daemon — runs scheduled tasks at configured intervals." ;;
  dbus-daemon) DESC="D-Bus message broker — inter-process communication backbone." ;;
  NetworkManager) DESC="NetworkManager — manages network connections (Wi-Fi, Ethernet, VPN)." ;;
  wpa_supplicant) DESC="Wi-Fi authentication daemon — handles WPA/WPA2/WPA3 key negotiation." ;;
  pulseaudio | pipewire) DESC="Audio server — manages all audio input/output for desktop applications." ;;
  wireplumber) DESC="PipeWire session manager — routes audio/video streams between apps and hardware." ;;
  Xwayland) DESC="X11 compatibility layer — runs legacy X11 apps under Wayland." ;;
  Hyprland) DESC="Hyprland compositor — the Wayland window manager and compositor running your desktop." ;;
  quickshell) DESC="Quickshell — the Qt/QML shell framework powering Omarchy's status bar and widgets." ;;
  mako | dunst) DESC="Notification daemon — displays desktop notifications." ;;
  swaybg | swww) DESC="Wallpaper renderer — sets and manages the desktop background image." ;;
  wl-copy | wl-paste) DESC="Wayland clipboard utility — copies/pastes text and images." ;;
  fuzzel | wofi | rofi | tofi) DESC="Application launcher — fuzzy-search menu for opening apps." ;;
  alacritty | foot | kitty | ghostty) DESC="Terminal emulator — a window for running shell commands." ;;
  neovim | nvim | vim) DESC="Text editor — terminal-based code/text editing." ;;
  btop | htop | top) DESC="System monitor — interactive real-time process and resource viewer." ;;
  git) DESC="Git — version control system for tracking code changes." ;;
  node | npm | npx) DESC="Node.js — JavaScript runtime for server-side and tooling." ;;
  opencode) DESC="Opencode — AI coding assistant CLI running in the terminal." ;;
  python | python3) DESC="Python interpreter — runs Python scripts and packages." ;;
  rustc | cargo) DESC="Rust toolchain — compiler and package manager for Rust code." ;;
  docker | podman) DESC="Container runtime — runs isolated application containers." ;;
  containerd) DESC="Container runtime daemon — manages container lifecycle for Docker/Podman." ;;
  pacman) DESC="Pacman — Arch Linux package manager for installing/updating software." ;;
  reflector) DESC="Mirror list updater — refreshes Arch Linux package mirror rankings." ;;
  ufw | firewalld | iptables) DESC="Firewall — manages network packet filtering rules." ;;
  gpg-agent) DESC="GPG agent — manages cryptographic key passphrases for signing/encryption." ;;
  polkitd | polkit-agent) DESC="PolicyKit agent — handles privilege escalation authentication prompts." ;;
  thermald) DESC="Intel thermal daemon — prevents CPU overheating by throttling when needed." ;;
  tlp | powerprofiles) DESC="Power management — optimizes laptop battery and performance profiles." ;;
  libvirt | libvirtd) DESC="Virtual machine manager daemon — manages QEMU/KVM virtual machines." ;;
  ssh-agent) DESC="SSH agent — caches decrypted SSH keys for passwordless authentication." ;;
  xdg-desktop-portal) DESC="Desktop portal — provides file picker, screencast, and other sandboxed services." ;;
  xdg-document-portal) DESC="Document portal — provides document access for sandboxed apps." ;;
  swayidle) DESC="Idle daemon — triggers screen lock/screensaver after inactivity." ;;
  swaylock) DESC="Screen locker — locks the desktop and requires password to unlock." ;;
  grim | slurp | satty) DESC="Screenshot tool — captures screen regions or full screen under Wayland." ;;
  wluma) DESC="Ambient display backlight — adjusts screen brightness based on ambient light." ;;
  cliphist) DESC="Clipboard history — stores and retrieves previously copied items." ;;
  playerctl) DESC="Media controller — play/pause/skip for music players (Spotify, MPV, etc)." ;;
  brightnessctl | light) DESC="Backlight control — sets screen brightness level." ;;
  udiskie) DESC="Auto-mount daemon — automatically mounts USB drives and external storage." ;;
  xfce4-power-manager) DESC="Power manager — handles laptop lid close, suspend, and battery alerts." ;;
  mpv) DESC="Media player — lightweight video/audio player." ;;
  firefox | firefox-bin) DESC="Firefox web browser — Mozilla's open-source web browser." ;;
  chromium | chrome) DESC="Web browser — Google Chrome or Chromium-based browser." ;;
  code | code-server) DESC="Visual Studio Code — Microsoft's code editor." ;;
  discord) DESC="Discord — voice/text chat application." ;;
  spotify) DESC="Spotify — music streaming application." ;;
  steam) DESC="Steam — Valve's gaming platform and store." ;;
  # Kernel threads (no userspace binary)
  kworker) DESC="Kernel worker thread — runs deferred background work on CPU workqueues." ;;
  kworker/*) DESC="Kernel workqueue thread — performs deferred background I/O and cleanup work for the kernel; the part after kworker/ names the workqueue." ;;
  kswapd*) DESC="Kernel swap daemon — reclaims memory pages when the system is under memory pressure." ;;
  ksoftirqd*) DESC="Kernel softirq thread — processes deferred software interrupts." ;;
  kcompactd*) DESC="Kernel memory-compaction daemon — defragments memory for large allocations." ;;
  khugepaged) DESC="Kernel hugepage daemon — promotes regular pages into huge pages." ;;
  kthreadd) DESC="Kernel thread forker — spawns and supervises all other kernel threads." ;;
  kblockd) DESC="Kernel block-layer worker — processes block device request queues." ;;
  jbd2/* | kjournald*) DESC="Filesystem journaling thread — writes journal transactions (ext4/btrfs) for crash safety." ;;
  kcryptd | dmcrypt_write*) DESC="Device-mapper crypt worker — performs on-the-fly disk encryption/decryption." ;;
  oom_reaper) DESC="OOM killer reaper — reaps processes the out-of-memory killer condemned." ;;
  migration/*) DESC="Per-CPU migration thread — moves tasks between CPUs for load balancing." ;;
  watchdog/*) DESC="Per-CPU watchdog thread — drives the hardware watchdog timer." ;;
  rcu*) DESC="RCU kernel worker — coordinates grace periods and reclaims kernel memory." ;;
  *) DESC="" ;;
esac

# Build description
if [ -n "$DESC" ]; then
  FINAL="$DESC"
  if [ -n "$PKG" ]; then
    FINAL="$FINAL Installed as: $PKG"
  fi
else
  if [ -n "$PKG" ]; then
    FINAL="Owned by package: $PKG"
  else
    FINAL="Unknown system process. No package found via pacman."
  fi
fi

# Escape for JSON
FINAL=$(echo "$FINAL" | sed 's/"/\\"/g' | tr '\n' ' ')

echo "{\"name\":\"$NAME\",\"description\":\"$FINAL\",\"package\":\"$PKG\"}"
