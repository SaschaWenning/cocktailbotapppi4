#!/usr/bin/env bash
set -euo pipefail

STOP_FILE="/var/lib/cocktailbot/kiosk.stop"

if [[ -f /tmp/cocktailbot-native-test.pid ]]; then
  PID="$(cat /tmp/cocktailbot-native-test.pid 2>/dev/null || true)"
  if [[ -n "${PID:-}" ]]; then
    kill -TERM "$PID" 2>/dev/null || true
  fi
  rm -f /tmp/cocktailbot-native-test.pid
fi

pkill -TERM -x cocktailbot_app 2>/dev/null || true
sudo rm -f "$STOP_FILE"

echo "Nativer Test beendet. Web-Kiosk ist wieder freigegeben."
echo "Falls Chromium nicht automatisch startet: sudo reboot"
