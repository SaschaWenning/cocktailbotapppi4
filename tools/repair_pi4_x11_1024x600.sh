#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo ausfuehren." >&2; exit 1; }

TARGET_USER="${SUDO_USER:-pi}"
if [[ "$TARGET_USER" == "root" ]] || ! id "$TARGET_USER" >/dev/null 2>&1; then
  TARGET_USER="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $6 ~ /^\/home\// {print $1; exit}')"
fi
[[ -n "$TARGET_USER" ]] || { echo "Kein Desktopbenutzer gefunden." >&2; exit 1; }
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
KIOSK_ENV=/etc/cocktailbot/kiosk.env
KIOSK_SCRIPT=/opt/cocktailbot/raspberry/start-kiosk.sh

[[ -f "$KIOSK_SCRIPT" ]] || { echo "CocktailBot-Kioskskript fehlt: $KIOSK_SCRIPT" >&2; exit 1; }
install -d -m 0755 /etc/cocktailbot
[[ -f "$KIOSK_ENV" ]] || touch "$KIOSK_ENV"
cp -a "$KIOSK_ENV" "${KIOSK_ENV}.bak.$(date +%Y%m%d-%H%M%S)" || true
cp -a "$KIOSK_SCRIPT" "${KIOSK_SCRIPT}.bak.$(date +%Y%m%d-%H%M%S)" || true

if grep -q '^COCKTAILBOT_FORCE_X11_1024X600=' "$KIOSK_ENV"; then
  sed -i 's/^COCKTAILBOT_FORCE_X11_1024X600=.*/COCKTAILBOT_FORCE_X11_1024X600=1/' "$KIOSK_ENV"
else
  printf '\nCOCKTAILBOT_FORCE_X11_1024X600=1\n' >> "$KIOSK_ENV"
fi

python3 - "$KIOSK_SCRIPT" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
if 'force_x11_1024x600()' in s:
    print('Kioskskript enthaelt den X11-1024x600-Fix bereits.')
    raise SystemExit(0)

needle='rm -f "$STOP_FILE" 2>/dev/null || true\n\nsleep "$DELAY"\n'
if needle not in s:
    raise SystemExit('Kioskskript hat ein unbekanntes Format; keine automatische Aenderung vorgenommen.')

block=r'''rm -f "$STOP_FILE" 2>/dev/null || true

FORCE_X11_1024X600="${COCKTAILBOT_FORCE_X11_1024X600:-0}"
force_x11_1024x600() {
  [[ "$FORCE_X11_1024X600" == "1" ]] || return 0
  [[ -n "${DISPLAY:-}" ]] || return 0
  command -v xrandr >/dev/null 2>&1 || return 0

  local output=""
  for _ in $(seq 1 30); do
    output="$(xrandr --query 2>/dev/null | awk '/ connected/{print $1; exit}')"
    [[ -n "$output" ]] && break
    sleep 1
  done
  [[ -n "$output" ]] || return 0

  local mode="1024x600_60.00"
  xrandr --newmode "$mode" 49.00 1024 1064 1168 1312 600 603 613 624 -hsync +vsync >/dev/null 2>&1 || true
  xrandr --addmode "$output" "$mode" >/dev/null 2>&1 || true
  xrandr --output "$output" --mode "$mode" --primary || true
}

force_x11_1024x600

sleep "$DELAY"
'''
p.write_text(s.replace(needle,block))
print('Kioskskript wurde fuer X11 1024x600 erweitert.')
PY

chmod 0755 "$KIOSK_SCRIPT"

echo
echo "CocktailBot Pi-4 X11-Fix ist jetzt dauerhaft aktiviert."
echo "Beim naechsten Desktop-/Kioskstart wird vor Chromium 1024x600 gesetzt."
echo
echo "Aktueller X11-Modus:"
if command -v xrandr >/dev/null 2>&1; then
  runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" DISPLAY=:0 xrandr --current 2>/dev/null | head -n 3 || true
fi
echo
echo "Zum Testen nach einem Neustart:"
echo "  sudo reboot"
echo "  DISPLAY=:0 xrandr --current"
