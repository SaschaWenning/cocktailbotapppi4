#!/usr/bin/env bash
set -Eeuo pipefail

export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"
if [[ -S "/run/user/$(id -u)/bus" ]]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
fi

sleep "${COCKTAILBOT_KEYBOARD_DELAY_SECONDS:-6}"
mkdir -p "$HOME/.local/state"

# Onboard soll im X11-Kiosk automatisch auf Eingabefelder reagieren. Die App
# ruft zusätzlich /api/keyboard/show auf, damit Flutter-Web-Felder zuverlässig
# auch dann eine Tastatur bekommen, wenn AT-SPI den Fokus nicht erkennt.
if command -v dconf >/dev/null 2>&1; then
  dconf write /org/onboard/auto-show/enabled true >/dev/null 2>&1 || true
fi
if command -v gsettings >/dev/null 2>&1; then
  gsettings set org.onboard auto-show true >/dev/null 2>&1 || true
  gsettings set org.onboard.auto-show enabled true >/dev/null 2>&1 || true
  gsettings set org.onboard.window docking-enabled true >/dev/null 2>&1 || true
  gsettings set org.onboard.window force-to-top true >/dev/null 2>&1 || true
fi

pgrep -u "$USER" -x onboard >/dev/null 2>&1 && exit 0
exec onboard >> "$HOME/.local/state/cocktailbot-onboard.log" 2>&1
