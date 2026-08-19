#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$HOME/cocktailbotapppi4}"
TEST_DIR="${TEST_DIR:-/opt/cocktailbot-native-test}"
STOP_FILE="/var/lib/cocktailbot/kiosk.stop"
DISPLAY_VALUE="${DISPLAY_VALUE:-:0}"
XAUTHORITY_VALUE="${XAUTHORITY_VALUE:-$HOME/.Xauthority}"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "Repo nicht gefunden: $REPO_DIR" >&2
  exit 1
fi

echo "== Backend prüfen =="
curl -fsS --max-time 3 http://127.0.0.1:8080/api/status >/dev/null
echo "Backend OK"

echo "== Native Testdatei vom GitHub-Testbranch holen =="
cd "$REPO_DIR"
git fetch origin native-linux-arm64-test
git show FETCH_HEAD:cocktailbot-linux-arm64-test.tar.gz \
  > /tmp/cocktailbot-linux-arm64-test.tar.gz
git show FETCH_HEAD:cocktailbot-linux-arm64-test.tar.gz.sha256 \
  > /tmp/cocktailbot-linux-arm64-test.tar.gz.sha256

(
  cd /tmp
  sha256sum -c cocktailbot-linux-arm64-test.tar.gz.sha256
)

echo "== Testbundle installieren =="
sudo rm -rf "$TEST_DIR"
sudo mkdir -p "$TEST_DIR"
sudo tar -xzf /tmp/cocktailbot-linux-arm64-test.tar.gz -C "$TEST_DIR"
sudo chown -R "$USER:$USER" "$TEST_DIR"

if [[ ! -x "$TEST_DIR/cocktailbot_app" ]]; then
  echo "Native Binary fehlt: $TEST_DIR/cocktailbot_app" >&2
  exit 1
fi

echo "== Chromium-Kiosk anhalten; Backend bleibt aktiv =="
sudo mkdir -p "$(dirname "$STOP_FILE")"
sudo touch "$STOP_FILE"
pkill -TERM -x chromium 2>/dev/null || true
sleep 2

if ! command -v wmctrl >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y wmctrl
fi

echo "== Native Flutter-App starten =="
export DISPLAY="$DISPLAY_VALUE"
export XAUTHORITY="$XAUTHORITY_VALUE"
export GDK_BACKEND=x11

"$TEST_DIR/cocktailbot_app" &
APP_PID=$!
echo "$APP_PID" > /tmp/cocktailbot-native-test.pid

for _ in $(seq 1 30); do
  WIN_ID="$(wmctrl -lp 2>/dev/null | awk -v pid="$APP_PID" '$3 == pid {print $1; exit}')"
  if [[ -n "${WIN_ID:-}" ]]; then
    wmctrl -i -r "$WIN_ID" -b add,fullscreen || true
    break
  fi
  sleep 0.2
done

echo
echo "Native Test läuft (PID $APP_PID)."
echo "Jetzt auf dem Display die Cocktailübersicht scrollen."
echo
echo "CPU-Messung in einem zweiten SSH-Fenster:"
echo "  pidstat -p $APP_PID 1 8"
echo
echo "Zur Web-Version zurück:"
echo "  cd ~/cocktailbotapppi4 && ./stop-native-test.sh"
echo

wait "$APP_PID"
