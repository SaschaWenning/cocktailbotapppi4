#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${COCKTAILBOT_REPO_URL:-https://github.com/saschawenning/cocktailbotapp.git}"
REPO_BRANCH="${COCKTAILBOT_REPO_BRANCH:-main}"
INSTALL_ROOT="${COCKTAILBOT_INSTALL_ROOT:-/opt/cocktailbot}"
SOURCE_DIR="$INSTALL_ROOT/source"
WEB_DIR="$INSTALL_ROOT/web"
RUNTIME_DIR="$INSTALL_ROOT/raspberry"
VENV_DIR="$INSTALL_ROOT/venv"
FLUTTER_DIR="${COCKTAILBOT_FLUTTER_DIR:-/opt/flutter}"
ACTIVE_HIGH="${COCKTAILBOT_ACTIVE_HIGH:-0}"
KIOSK_DELAY="${COCKTAILBOT_KIOSK_DELAY_SECONDS:-30}"
BUILD_MODE="${COCKTAILBOT_BUILD_MODE:-auto}"
SKIP_APT="${COCKTAILBOT_SKIP_APT:-0}"
REBOOT_AFTER=0
USE_LOCAL_SOURCE=0
INSTALL_LCD="${COCKTAILBOT_INSTALL_LCD:-1}"
BOOT_OPTIMIZE="${COCKTAILBOT_BOOT_OPTIMIZE:-1}"
PICO_PORT="${COCKTAILBOT_PICO_PORT:-auto}"
PICO_BAUD="${COCKTAILBOT_PICO_BAUD:-115200}"
GPIO_CHIP="${COCKTAILBOT_GPIO_CHIP:-auto}"
IMAGE_BUILD="${COCKTAILBOT_IMAGE_BUILD:-0}"
LCD_REPO_URL="${COCKTAILBOT_LCD_REPO_URL:-https://github.com/goodtft/LCD-show.git}"
FORCE_X11_1024X600="${COCKTAILBOT_FORCE_X11_1024X600:-0}"

usage() {
  cat <<USAGE
CocktailBot Installer

Verwendung:
  sudo ./install.sh [Optionen]

Optionen:
  --reboot                  Raspberry Pi nach der Installation neu starten
  --local-source            den aktuellen Repository-Ordner statt GitHub verwenden
  --active-high 0|1         Relaislogik; Standard: 0 (LOW = EIN, HIGH = AUS)
  --kiosk-delay SEKUNDEN    Wartezeit bis Chromium startet; Standard: 30
  --build-mode auto|release|source
                            Standard: auto (web-release bevorzugt)
                            auto: web-release bevorzugen; lokaler Build nur auf kompatiblem 64-Bit-System
                            release: nur GitHub-Branch web-release verwenden
                            source: Flutter-App lokal bauen (64-Bit-Userland erforderlich)
  --user BENUTZER           Desktop-/Kioskbenutzer festlegen
  --repo URL                GitHub-Repository ändern
  --branch NAME             Git-Branch ändern; Standard: main
  --skip-lcd                GoodTFT LCD7C-Treiber nicht installieren
  --skip-boot-opt           Plymouth/cmdline/Display-Bootoptimierung überspringen
  --pico-port PORT          Pico-USB-Port; Standard: auto
  --gpio-chip auto|NUMMER   RP1-GPIO-Chip; Standard: auto (empfohlen)
  --image-build              Offline-Image-Build: Dienste nur aktivieren, nicht starten
  -h, --help                Hilfe anzeigen
USAGE
}

TARGET_USER="${COCKTAILBOT_USER:-${SUDO_USER:-}}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reboot) REBOOT_AFTER=1; shift ;;
    --local-source) USE_LOCAL_SOURCE=1; shift ;;
    --active-high) ACTIVE_HIGH="${2:?Wert fehlt}"; shift 2 ;;
    --kiosk-delay) KIOSK_DELAY="${2:?Wert fehlt}"; shift 2 ;;
    --build-mode) BUILD_MODE="${2:?Wert fehlt}"; shift 2 ;;
    --user) TARGET_USER="${2:?Benutzer fehlt}"; shift 2 ;;
    --repo) REPO_URL="${2:?URL fehlt}"; shift 2 ;;
    --branch) REPO_BRANCH="${2:?Branch fehlt}"; shift 2 ;;
    --skip-lcd) INSTALL_LCD=0; shift ;;
    --skip-boot-opt) BOOT_OPTIMIZE=0; shift ;;
    --pico-port) PICO_PORT="${2:?Port fehlt}"; shift 2 ;;
    --gpio-chip) GPIO_CHIP="${2:?GPIO-Chip fehlt}"; shift 2 ;;
    --image-build) IMAGE_BUILD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log() { printf '\n\033[1;36m[CocktailBot]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[CocktailBot WARNUNG]\033[0m %s\n' "$*" >&2; }
die() { printf '\n\033[1;31m[CocktailBot FEHLER]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Bitte mit sudo ausführen."
[[ "$ACTIVE_HIGH" =~ ^[01]$ ]] || die "--active-high muss 0 oder 1 sein."
[[ "$KIOSK_DELAY" =~ ^[0-9]+$ ]] || die "--kiosk-delay muss eine ganze Zahl sein."
(( KIOSK_DELAY <= 3600 )) || die "Die Kiosk-Verzögerung darf höchstens 3600 Sekunden betragen."
[[ "$BUILD_MODE" =~ ^(auto|release|source)$ ]] || die "--build-mode muss auto, release oder source sein."
[[ "$INSTALL_LCD" =~ ^[01]$ ]] || die "COCKTAILBOT_INSTALL_LCD muss 0 oder 1 sein."
[[ "$BOOT_OPTIMIZE" =~ ^[01]$ ]] || die "COCKTAILBOT_BOOT_OPTIMIZE muss 0 oder 1 sein."
[[ "$PICO_BAUD" =~ ^[0-9]+$ ]] || die "COCKTAILBOT_PICO_BAUD muss eine ganze Zahl sein."
[[ "$GPIO_CHIP" == "auto" || "$GPIO_CHIP" =~ ^[0-9]+$ ]] || die "--gpio-chip muss auto oder eine ganze Chipnummer sein."
[[ "$IMAGE_BUILD" =~ ^[01]$ ]] || die "COCKTAILBOT_IMAGE_BUILD muss 0 oder 1 sein."
[[ "$FORCE_X11_1024X600" =~ ^[01]$ ]] || die "COCKTAILBOT_FORCE_X11_1024X600 muss 0 oder 1 sein."

if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
  TARGET_USER="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $6 ~ /^\/home\// {print $1; exit}')"
fi
[[ -n "$TARGET_USER" ]] || die "Kein Desktopbenutzer gefunden. Nutze --user BENUTZER."
id "$TARGET_USER" >/dev/null 2>&1 || die "Benutzer '$TARGET_USER' existiert nicht."
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
[[ -d "$TARGET_HOME" ]] || die "Home-Verzeichnis fehlt: $TARGET_HOME"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

run_as_user() {
  runuser -u "$TARGET_USER" -- env \
    HOME="$TARGET_HOME" \
    USER="$TARGET_USER" \
    LOGNAME="$TARGET_USER" \
    PUB_CACHE="$TARGET_HOME/.pub-cache" \
    PATH="$FLUTTER_DIR/bin:/usr/local/bin:/usr/bin:/bin" \
    "$@"
}

install_packages() {
  [[ "$SKIP_APT" == "1" ]] && return 0
  log "Installiere Systempakete"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    ca-certificates curl git rsync unzip xz-utils zip libglu1-mesa gpiod \
    python3 python3-venv python3-pip python3-gpiozero python3-serial python3-cryptography \
    x11-xserver-utils unclutter util-linux onboard dbus-x11 dconf-cli

  if apt-cache show python3-lgpio >/dev/null 2>&1; then
    apt-get install -y python3-lgpio
  fi

  if apt-cache show chromium >/dev/null 2>&1; then
    apt-get install -y chromium
  elif apt-cache show chromium-browser >/dev/null 2>&1; then
    apt-get install -y chromium-browser
  else
    die "Weder chromium noch chromium-browser ist in den Paketquellen verfügbar."
  fi
}

sync_source() {
  log "Hole Repository $REPO_URL ($REPO_BRANCH)"
  install -d -m 0755 "$INSTALL_ROOT"

  if [[ "$USE_LOCAL_SOURCE" == "1" ]]; then
    [[ -f "$SCRIPT_DIR/app/pubspec.yaml" ]] || die "Im aktuellen Ordner fehlt app/pubspec.yaml."
    rm -rf "$SOURCE_DIR"
    install -d -m 0755 "$SOURCE_DIR"
    rsync -a --delete \
      --exclude '.dart_tool' --exclude 'build' --exclude '__pycache__' \
      "$SCRIPT_DIR/" "$SOURCE_DIR/"
  elif [[ -d "$SOURCE_DIR/.git" ]]; then
    git -C "$SOURCE_DIR" remote set-url origin "$REPO_URL"
    git -C "$SOURCE_DIR" fetch --depth 1 origin "$REPO_BRANCH"
    git -C "$SOURCE_DIR" checkout -B "$REPO_BRANCH" "origin/$REPO_BRANCH"
    git -C "$SOURCE_DIR" reset --hard "origin/$REPO_BRANCH"
    git -C "$SOURCE_DIR" clean -fdx
  else
    rm -rf "$SOURCE_DIR"
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$SOURCE_DIR"
  fi

  [[ -f "$SOURCE_DIR/app/pubspec.yaml" ]] || die "Repository enthält kein app/pubspec.yaml."
}

install_prebuilt_web() {
  local temp_release
  temp_release="$(mktemp -d)"
  if git clone --quiet --depth 1 --branch web-release "$REPO_URL" "$temp_release" 2>/dev/null \
      && [[ -f "$temp_release/index.html" ]]; then
    log "Installiere vorgebautes Flutter-Web-Release aus Branch web-release"
    rm -rf "$WEB_DIR"
    install -d -m 0755 "$WEB_DIR"
    rsync -a --delete --exclude '.git' "$temp_release/" "$WEB_DIR/"
    rm -rf "$temp_release"
    return 0
  fi
  rm -rf "$temp_release"
  return 1
}

install_flutter() {
  log "Installiere bzw. aktualisiere Flutter Stable unter $FLUTTER_DIR"
  install -d -o "$TARGET_USER" -g "$TARGET_GROUP" -m 0755 "$TARGET_HOME/.pub-cache"
  if [[ -d "$FLUTTER_DIR/.git" ]]; then
    run_as_user git -C "$FLUTTER_DIR" fetch --depth 1 origin stable
    run_as_user git -C "$FLUTTER_DIR" checkout -B stable origin/stable
    run_as_user git -C "$FLUTTER_DIR" reset --hard origin/stable
  else
    rm -rf "$FLUTTER_DIR"
    git clone --depth 1 --branch stable https://github.com/flutter/flutter.git "$FLUTTER_DIR"
    chown -R "$TARGET_USER:$TARGET_GROUP" "$FLUTTER_DIR"
  fi
}

build_web() {
  local userland_arch
  userland_arch="$(dpkg --print-architecture 2>/dev/null || true)"
  if [[ "$userland_arch" == "armhf" ]]; then
    die "Lokaler Flutter-Build ist auf Raspberry Pi OS 32-Bit (armhf) nicht möglich. Nutze --build-mode release/auto oder installiere Raspberry Pi OS 64-Bit (arm64)."
  fi
  install_flutter
  log "Baue Flutter-Web-App auf dem Raspberry Pi"
  chown -R "$TARGET_USER:$TARGET_GROUP" "$SOURCE_DIR/app"
  run_as_user "$FLUTTER_DIR/bin/flutter" config --no-analytics --enable-web
  run_as_user "$FLUTTER_DIR/bin/flutter" precache --web
  if [[ ! -f "$SOURCE_DIR/app/web/index.html" ]]; then
    run_as_user bash -lc "cd '$SOURCE_DIR/app' && '$FLUTTER_DIR/bin/flutter' create . --platforms web"
  fi
  run_as_user bash -lc "cd '$SOURCE_DIR/app' && '$FLUTTER_DIR/bin/flutter' pub get"
  run_as_user bash -lc "cd '$SOURCE_DIR/app' && '$FLUTTER_DIR/bin/flutter' build web --release"
  [[ -f "$SOURCE_DIR/app/build/web/index.html" ]] || die "Flutter-Build wurde nicht erzeugt."
  rm -rf "$WEB_DIR"
  install -d -m 0755 "$WEB_DIR"
  rsync -a --delete "$SOURCE_DIR/app/build/web/" "$WEB_DIR/"
}

fix_web_permissions() {
  log "Setze sichere Leserechte für den Flutter-Web-Build"
  [[ -d "$WEB_DIR" ]] || die "Web-Verzeichnis fehlt: $WEB_DIR"
  chmod 0755 "$INSTALL_ROOT" "$WEB_DIR"
  find "$WEB_DIR" -type d -exec chmod 0755 {} +
  find "$WEB_DIR" -type f -exec chmod 0644 {} +
  chown -R root:root "$WEB_DIR"
  [[ -r "$WEB_DIR/index.html" ]] || die "index.html ist für den Webdienst nicht lesbar."
}

install_runtime() {
  log "Installiere GPIO-/Webdienst"
  install -d -m 0755 "$RUNTIME_DIR"
  getent group gpio >/dev/null 2>&1 || groupadd --system gpio
  getent group dialout >/dev/null 2>&1 || groupadd --system dialout
  usermod -aG dialout "$TARGET_USER" || true
  install -m 0755 "$SOURCE_DIR/raspberry/cocktailbot_server.py" "$RUNTIME_DIR/cocktailbot_server.py"
  install -m 0755 "$SOURCE_DIR/raspberry/start-kiosk.sh" "$RUNTIME_DIR/start-kiosk.sh"
  install -m 0755 "$SOURCE_DIR/raspberry/start-onboard.sh" "$RUNTIME_DIR/start-onboard.sh"
  install -m 0644 "$SOURCE_DIR/raspberry/requirements.txt" "$RUNTIME_DIR/requirements.txt"
  [[ -f "$SOURCE_DIR/raspberry/license_public_key.pem" ]] || die "Lizenz-Public-Key fehlt im Repository."

  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    rm -rf "$VENV_DIR"
    python3 -m venv --system-site-packages "$VENV_DIR"
  fi
  "$VENV_DIR/bin/pip" install --disable-pip-version-check -r "$RUNTIME_DIR/requirements.txt"

  install -d -m 0755 /etc/cocktailbot
  install -o root -g root -m 0644 \
    "$SOURCE_DIR/raspberry/license_public_key.pem" \
    /etc/cocktailbot/license_public_key.pem
  cat > /etc/cocktailbot/cocktailbot.env <<ENV
COCKTAILBOT_ACTIVE_HIGH=$ACTIVE_HIGH
COCKTAILBOT_STATE_FILE=/var/lib/cocktailbot/machine_state.json
COCKTAILBOT_APP_STATE_FILE=/var/lib/cocktailbot/app_state.json
COCKTAILBOT_NETWORK_ACCESS_FILE=/var/lib/cocktailbot/network_access.json
COCKTAILBOT_PICO_PORT=$PICO_PORT
COCKTAILBOT_PICO_BAUD=$PICO_BAUD
COCKTAILBOT_GPIO_CHIP=$GPIO_CHIP
COCKTAILBOT_LICENSE_FILE=/var/lib/cocktailbot/license.json
COCKTAILBOT_LICENSE_PUBLIC_KEY=/etc/cocktailbot/license_public_key.pem
ENV
  chmod 0644 /etc/cocktailbot/cocktailbot.env

  cat > /etc/cocktailbot/kiosk.env <<ENV
COCKTAILBOT_KIOSK_URL=http://127.0.0.1:8080
COCKTAILBOT_KIOSK_DELAY_SECONDS=$KIOSK_DELAY
COCKTAILBOT_CHROMIUM_PROFILE=$TARGET_HOME/.config/cocktailbot-chromium
COCKTAILBOT_KIOSK_STOP_FILE=/var/lib/cocktailbot/kiosk.stop
COCKTAILBOT_FORCE_X11_1024X600=$FORCE_X11_1024X600
ENV
  chmod 0644 /etc/cocktailbot/kiosk.env

  sed \
    -e "s/__USER__/$TARGET_USER/g" \
    -e "s/__GROUP__/$TARGET_GROUP/g" \
    "$SOURCE_DIR/raspberry/systemd/cocktailbot.service.in" \
    > /etc/systemd/system/cocktailbot.service
  chmod 0644 /etc/systemd/system/cocktailbot.service

  chown root:root /etc/systemd/system/cocktailbot.service "$RUNTIME_DIR/cocktailbot_server.py"
  chown "$TARGET_USER:$TARGET_GROUP" "$RUNTIME_DIR/start-kiosk.sh"
  chmod 0755 "$RUNTIME_DIR/start-kiosk.sh"
}

install_lcd_driver() {
  [[ "$INSTALL_LCD" == "1" ]] || { log "LCD-Installation übersprungen"; return 0; }

  log "Installiere GoodTFT LCD7C-Treiber für 7-Zoll 1024x600"
  local lcd_dir="$TARGET_HOME/LCD-show"
  rm -rf "$lcd_dir"
  run_as_user git clone --depth 1 "$LCD_REPO_URL" "$lcd_dir"

  [[ -f "$lcd_dir/LCD7C-show" ]] || die "LCD7C-show wurde im GoodTFT-Repository nicht gefunden."
  chmod +x "$lcd_dir/LCD7C-show"

  # Das Originalskript rebootet am Ende. Der zentrale Installer entscheidet
  # selbst, ob und wann neu gestartet wird.
  sed -i -E \
    's/^[[:space:]]*(sudo[[:space:]]+)?reboot([[:space:]]*)$/# reboot durch CocktailBot-Installer unterdrueckt/' \
    "$lcd_dir/LCD7C-show"

  (
    cd "$lcd_dir"
    ./LCD7C-show
  )
  chown -R "$TARGET_USER:$TARGET_GROUP" "$lcd_dir" || true
  log "LCD7C-Treiber installiert"
}

configure_display_and_boot() {
  [[ "$BOOT_OPTIMIZE" == "1" ]] || { log "Bootoptimierung übersprungen"; return 0; }

  local cmdline_file=""
  local config_file=""
  if [[ -f /boot/firmware/cmdline.txt ]]; then
    cmdline_file=/boot/firmware/cmdline.txt
  elif [[ -f /boot/cmdline.txt ]]; then
    cmdline_file=/boot/cmdline.txt
  fi
  if [[ -f /boot/firmware/config.txt ]]; then
    config_file=/boot/firmware/config.txt
  elif [[ -f /boot/config.txt ]]; then
    config_file=/boot/config.txt
  fi

  [[ -n "$config_file" && -n "$cmdline_file" ]] || die "Bootdateien config.txt/cmdline.txt wurden nicht gefunden."

  log "Setze Display auf den auf LCD7C getesteten KMS-Modus 1024x600@60"
  cp -a "$config_file" "${config_file}.cocktailbot.bak" || true
  cp -a "$cmdline_file" "${cmdline_file}.cocktailbot.bak" || true

  # GoodTFT/LCD-show legt je nach Version unterschiedliche Legacy-HDMI- und
  # Framebuffer-Zeilen an (teils mit '=', teils mit Leerzeichen). Python
  # bereinigt beides ohne fragile sed-RegEx und setzt danach exakt die auf dem
  # realen CocktailBot getestete KMS-Konfiguration.
  python3 - "$config_file" "$cmdline_file" <<'PY_DISPLAY'
from pathlib import Path
import sys

config, cmdline = map(Path, sys.argv[1:3])
lines = config.read_text(errors="replace").splitlines()
out = []
in_block = False

# Prefix comparison is done after stripping a possible leading '#'. This also
# removes commented legacy settings that could later accidentally be enabled.
legacy_prefixes = (
    "dtoverlay=vc4-fkms-v3d",
    "dtoverlay=vc4-kms-v3d",
    "disable_fw_kms_setup",
    "hdmi_force_hotplug",
    "hdmi_group",
    "hdmi_mode",
    "hdmi_cvt",
    "hdmi_drive",
    "config_hdmi_boost",
    "framebuffer_width",
    "framebuffer_height",
    "max_framebuffer_width",
    "max_framebuffer_height",
)

for raw in lines:
    stripped = raw.strip()
    if stripped == "# BEGIN COCKTAILBOT DISPLAY":
        in_block = True
        continue
    if stripped == "# END COCKTAILBOT DISPLAY":
        in_block = False
        continue
    if in_block:
        continue

    active = stripped.lstrip("#").strip()
    if any(active.startswith(prefix) for prefix in legacy_prefixes):
        continue
    out.append(raw)

while out and not out[-1].strip():
    out.pop()
out += [
    "",
    "# BEGIN COCKTAILBOT DISPLAY",
    "[all]",
    "dtoverlay=vc4-kms-v3d",
    "disable_fw_kms_setup=1",
    "# Prevent Raspberry Pi firmware from injecting an EDID-selected video= mode.",
    "# LCD7C native resolution is selected by the kernel command line below.",
    "# END COCKTAILBOT DISPLAY",
]
config.write_text("\n".join(out) + "\n")

tokens = cmdline.read_text(errors="replace").split()
tokens = [
    t for t in tokens
    if t not in {"quiet", "splash"}
    and not t.startswith("video=")
]
tokens.append("video=HDMI-A-1:1024x600M@60")
cmdline.write_text(" ".join(tokens) + "\n")
PY_DISPLAY

  # GoodTFT installations from older runs may have masked DRM devices.
  systemctl unmask dev-dri-card0.device >/dev/null 2>&1 || true
  systemctl unmask dev-dri-card1.device >/dev/null 2>&1 || true
  systemctl unmask dev-dri-renderD128.device >/dev/null 2>&1 || true
  systemctl disable NetworkManager-wait-online.service >/dev/null 2>&1 || true

  log "Aktiviere grafischen Desktopstart und automatisches Login"
  systemctl set-default graphical.target
  if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint do_boot_behaviour B4 || warn "Desktop-Autologin konnte nicht gesetzt werden."
    raspi-config nonint do_blanking 1 || warn "Bildschirmabschaltung konnte nicht deaktiviert werden."
  fi
  if systemctl list-unit-files lightdm.service >/dev/null 2>&1; then
    systemctl enable lightdm.service >/dev/null 2>&1 || true
  fi

  log "Boot-Displaykonfiguration gesetzt: KMS + Firmware-EDID-Override aus + HDMI-A-1 1024x600@60"
}
configure_pump_boot_safety() {
  # These BCM GPIOs are exclusively used by the 18 pump relays.
  local config_file=""
  local cmdline_file=""
  local safe_drive="dh"
  local pins="17,18,27,22,23,24,25,4,5,6,13,19,26,16,20,21,12,15"

  [[ "$ACTIVE_HIGH" == "1" ]] && safe_drive="dl"

  if [[ -f /boot/firmware/config.txt ]]; then
    config_file=/boot/firmware/config.txt
  elif [[ -f /boot/config.txt ]]; then
    config_file=/boot/config.txt
  fi
  if [[ -f /boot/firmware/cmdline.txt ]]; then
    cmdline_file=/boot/firmware/cmdline.txt
  elif [[ -f /boot/cmdline.txt ]]; then
    cmdline_file=/boot/cmdline.txt
  fi

  if [[ -n "$config_file" ]]; then
    log "Setze alle Pumpen-GPIOs bereits im Bootloader auf AUS"
    cp -a "$config_file" "${config_file}.cocktailbot-pumps.bak" || true
    python3 - "$config_file" "$pins" "$safe_drive" <<'PY_PUMPS_CONFIG'
from pathlib import Path
import sys

config = Path(sys.argv[1])
pins = sys.argv[2]
safe_drive = sys.argv[3]
lines = config.read_text(errors="replace").splitlines()
out = []
in_block = False
for raw in lines:
    stripped = raw.strip()
    if stripped == "# BEGIN COCKTAILBOT PUMP SAFETY":
        in_block = True
        continue
    if stripped == "# END COCKTAILBOT PUMP SAFETY":
        in_block = False
        continue
    if in_block:
        continue
    if stripped.startswith("enable_uart="):
        continue
    if stripped.startswith(f"gpio={pins}=op,"):
        continue
    out.append(raw)
while out and not out[-1].strip():
    out.pop()
out += [
    "",
    "# BEGIN COCKTAILBOT PUMP SAFETY",
    "[all]",
    "enable_uart=0",
    f"gpio={pins}=op,{safe_drive}",
    "# END COCKTAILBOT PUMP SAFETY",
]
config.write_text("\n".join(out) + "\n")
PY_PUMPS_CONFIG
  else
    warn "Keine config.txt gefunden; Pumpen-GPIOs konnten nicht früh auf AUS gesetzt werden."
  fi

  if [[ -n "$cmdline_file" ]]; then
    cp -a "$cmdline_file" "${cmdline_file}.cocktailbot-pumps.bak" || true
    python3 - "$cmdline_file" <<'PY_PUMPS_CMDLINE'
from pathlib import Path
import sys

p = Path(sys.argv[1])
tokens = p.read_text(errors="replace").split()
tokens = [t for t in tokens if not (
    t.startswith("console=serial0,") or
    t.startswith("console=ttyAMA") or
    t.startswith("console=ttyS")
)]
p.write_text(" ".join(tokens) + "\n")
PY_PUMPS_CMDLINE
  fi

  # GPIO15 belongs to pump 18. Do not let a serial getty claim it again.
  systemctl disable --now serial-getty@serial0.service >/dev/null 2>&1 || true
  systemctl disable --now serial-getty@ttyAMA0.service >/dev/null 2>&1 || true
  systemctl disable --now serial-getty@ttyS0.service >/dev/null 2>&1 || true
}

report_gpio_configuration() {
  log "Prüfe Raspberry-Pi-GPIO-Backend"

  if [[ "$IMAGE_BUILD" == "1" ]]; then
    log "Image-Build: GPIO-Hardwareprüfung wird übersprungen; pinctrl-rp1 wird beim echten Serverstart automatisch erkannt."
    return 0
  fi

  if [[ "$GPIO_CHIP" != "auto" ]]; then
    if [[ -e "/dev/gpiochip${GPIO_CHIP}" ]]; then
      log "GPIO-Chip manuell festgelegt: gpiochip${GPIO_CHIP}"
    else
      die "Konfigurierter GPIO-Chip gpiochip${GPIO_CHIP} existiert nicht. Nutze --gpio-chip auto oder prüfe gpiodetect."
    fi
    return 0
  fi

  if ! command -v gpiodetect >/dev/null 2>&1; then
    warn "gpiodetect fehlt. Automatische RP1-Erkennung kann nicht vorab geprüft werden."
    return 0
  fi

  local rp1_line
  rp1_line="$(gpiodetect 2>/dev/null | awk '/\[pinctrl-rp1\]/ {print; exit}')"
  if [[ -n "$rp1_line" ]]; then
    log "RP1-GPIO automatisch erkannt: $rp1_line"
    log "CocktailBot ermittelt die gpiochip-Nummer bei jedem Serverstart neu."
  else
    log "Kein pinctrl-rp1 gefunden; gpiozero verwendet sein Standard-Backend (z. B. Raspberry Pi 4)."
  fi
}

configure_kiosk() {
  log "Konfiguriere Desktop-Autostart und Kioskstart nach ${KIOSK_DELAY} Sekunden"
  install -d -o "$TARGET_USER" -g "$TARGET_GROUP" -m 0755 \
    "$TARGET_HOME/.config/autostart" "$TARGET_HOME/.config/labwc" "$TARGET_HOME/.local/state"

  install -o "$TARGET_USER" -g "$TARGET_GROUP" -m 0644 \
    "$SOURCE_DIR/raspberry/autostart/cocktailbot-kiosk.desktop" \
    "$TARGET_HOME/.config/autostart/cocktailbot-kiosk.desktop"

  # Die aktuelle Flutter-App besitzt eine eigene Touch-Tastatur als Popup.
  # Ein automatisch gestartetes Onboard würde darüber liegen und wird daher
  # für CocktailBot nicht mehr autogestartet. Das Skript bleibt als manuelle
  # Fallback-Option installiert.
  chown "$TARGET_USER:$TARGET_GROUP" "$RUNTIME_DIR/start-onboard.sh"
  chmod 0755 "$RUNTIME_DIR/start-onboard.sh"
  rm -f "$TARGET_HOME/.config/autostart/cocktailbot-onboard.desktop"
  pkill -u "$TARGET_USER" -x onboard >/dev/null 2>&1 || true

  install -d -o "$TARGET_USER" -g "$TARGET_GROUP" -m 0755 "$TARGET_HOME/Desktop"
  cat > "$TARGET_HOME/Desktop/CocktailBot starten.desktop" <<EOF_DESKTOP
[Desktop Entry]
Type=Application
Name=CocktailBot starten
Comment=CocktailBot Kiosk starten
Exec=$RUNTIME_DIR/start-kiosk.sh
Icon=applications-system
Terminal=false
EOF_DESKTOP
  chown "$TARGET_USER:$TARGET_GROUP" "$TARGET_HOME/Desktop/CocktailBot starten.desktop"
  chmod 0755 "$TARGET_HOME/Desktop/CocktailBot starten.desktop"

  local labwc_file="$TARGET_HOME/.config/labwc/autostart"
  touch "$labwc_file"
  sed -i '/# BEGIN COCKTAILBOT/,/# END COCKTAILBOT/d' "$labwc_file"
  cat >> "$labwc_file" <<LABWC

# BEGIN COCKTAILBOT
/opt/cocktailbot/raspberry/start-kiosk.sh >> $TARGET_HOME/.local/state/cocktailbot-kiosk.log 2>&1 &
# END COCKTAILBOT
LABWC
  chown "$TARGET_USER:$TARGET_GROUP" "$labwc_file"
  chmod 0644 "$labwc_file"

  if command -v raspi-config >/dev/null 2>&1; then
    # B4 = Desktop mit automatischer Anmeldung. 1 = Bildschirmabschaltung aus.
    raspi-config nonint do_boot_behaviour B4 || warn "Desktop-Autologin konnte nicht automatisch gesetzt werden."
    raspi-config nonint do_blanking 1 || warn "Bildschirmabschaltung konnte nicht automatisch deaktiviert werden."
  else
    warn "raspi-config fehlt; Desktop-Autologin und Bildschirmabschaltung bitte manuell prüfen."
  fi
  systemctl set-default graphical.target >/dev/null 2>&1 || true
}

start_services() {
  log "Aktiviere CocktailBot-Dienst"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable cocktailbot.service

  if [[ "$IMAGE_BUILD" == "1" ]]; then
    log "Image-Build: Dienst ist für den ersten echten Boot aktiviert; Start/Hardwaretest im Chroot wird übersprungen."
    return 0
  fi

  systemctl restart cocktailbot.service

  for _ in $(seq 1 30); do
    local api_status
    if api_status="$(curl -fsS --max-time 2 http://127.0.0.1:8080/api/status 2>/dev/null)"; then
      log "CocktailBot-API ist erreichbar"
      if grep -q '"picoConnected":true' <<<"$api_status"; then
        log "Pico-2-LED-Controller ist über USB-Serial verbunden"
      else
        warn "Pico-2-LED-Controller wurde noch nicht erkannt. Pumpensteuerung bleibt verfügbar; prüfe USB-Kabel und /dev/ttyACM*."
      fi
      return 0
    fi
    sleep 1
  done

  systemctl --no-pager --full status cocktailbot.service || true
  journalctl -u cocktailbot.service -n 80 --no-pager || true
  die "CocktailBot-Dienst ist nicht erreichbar."
}

install_packages
sync_source

if [[ "$BUILD_MODE" == "release" ]]; then
  install_prebuilt_web || die "Branch web-release fehlt. Warte auf die GitHub-Action oder nutze --build-mode source."
elif [[ "$BUILD_MODE" == "auto" ]]; then
  if ! install_prebuilt_web; then
    if [[ "$(dpkg --print-architecture 2>/dev/null || true)" == "armhf" ]]; then
      die "Kein web-release vorhanden und Raspberry Pi OS läuft mit 32-Bit-Userland (armhf). Ein lokaler Flutter-Build ist hier nicht möglich."
    fi
    warn "Kein web-release vorhanden; die App wird jetzt lokal gebaut."
    build_web
  fi
else
  build_web
fi

fix_web_permissions
install_runtime
install_lcd_driver
configure_display_and_boot
configure_pump_boot_safety
report_gpio_configuration
configure_kiosk
start_services

cat <<SUMMARY

============================================================
CocktailBot wurde installiert.

Repository:       $REPO_URL
Installationsort: $INSTALL_ROOT
Kioskbenutzer:    $TARGET_USER
Kioskstart:       nach $KIOSK_DELAY Sekunden
Web/API:          http://127.0.0.1:8080
Relaislogik:      COCKTAILBOT_ACTIVE_HIGH=$ACTIVE_HIGH
Pumpen-Bootschutz: aktiv (GPIOs frueh auf AUS)
LCD7C/GoodTFT:    $INSTALL_LCD
Bootoptimierung:  $BOOT_OPTIMIZE
Pico LED-Port:     $PICO_PORT
Pico Baudrate:     $PICO_BAUD
GPIO-Chip:         $GPIO_CHIP (auto erkennt pinctrl-rp1 dynamisch)
Image-Build:        $IMAGE_BUILD
Displayziel:      1024x600
X11-Custom-Mode:  $FORCE_X11_1024X600 (Pi 4 = aktiv)

Status prüfen:
  systemctl status cocktailbot.service
  curl http://127.0.0.1:8080/api/status
  ls -l /dev/serial/by-id/ 2>/dev/null || true

Aktualisieren:
  sudo /opt/cocktailbot/source/tools/update.sh

WICHTIG: Vor dem Anschluss von Flüssigkeiten jede Pumpe kurz testen.
============================================================
SUMMARY

if [[ "$REBOOT_AFTER" == "1" ]]; then
  log "Starte Raspberry Pi neu"
  systemctl reboot
else
  echo "Zum Aktivieren des automatischen Kioskstarts jetzt neu starten:"
  echo "  sudo reboot"
fi
