#!/bin/sh
# OmaControl web-search focus helper.
#
# Called right after a Web Search chip opens a Google query via
# Qt.openUrlExternally(). On Hyprland the freshly opened tab is created without
# stealing focus, so the search stays in the background. This dispatches
# `hl.dsp.focus` at the default browser's window class so the result actually
# comes to the foreground.
#
# The browser class usually matches its desktop-file id (vivaldi-stable,
# firefox, google-chrome...). If the browser is being launched fresh the
# window may still be mapping, so the dispatch retries for up to ~2s.
#
# Runs under the sanitized bootstrap environment (trusted /usr/bin PATH).
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/bootstrap.sh"

command -v hyprctl >/dev/null 2>&1 || exit 0

BROWSER=$(xdg-settings get default-web-browser 2>/dev/null)
CLASS=""
case "$BROWSER" in
  *vivaldi*) CLASS="vivaldi-stable" ;;
  *firefox*) CLASS="firefox" ;;
  *chrome*) CLASS="google-chrome" ;;
  *chromium*) CLASS="chromium" ;;
  *brave*) CLASS="brave-browser" ;;
  *edge*) CLASS="microsoft-edge" ;;
  *librewolf*) CLASS="librewolf" ;;
  *opera*) CLASS="opera" ;;
  *zen*) CLASS="zen" ;;
  *qutebrowser*) CLASS="qutebrowser" ;;
esac

if [ -z "$CLASS" ]; then
  CLASS="(firefox|vivaldi-stable|google-chrome|chromium|brave-browser|microsoft-edge|librewolf|opera|qutebrowser|zen|zen-browser)"
fi

i=0
while [ "$i" -lt 20 ]; do
  hyprctl dispatch "hl.dsp.focus({ window = hl.get_window(\"class:$CLASS\") })" >/dev/null 2>&1
  i=$((i + 1))
  sleep 0.1
done
exit 0
