#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON_INSTALLER="$SCRIPT_DIR/install.sh"

log() { printf '\n\033[1;36m[CocktailBot Pi 5]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[CocktailBot Pi 5 WARNUNG]\033[0m %s\n' "$*" >&2; }
die() { printf '\n\033[1;31m[CocktailBot Pi 5 FEHLER]\033[0m %s\n' "$*" >&2; exit 1; }

show_help() {
  cat <<'USAGE'
CocktailBot Installer fuer Raspberry Pi 5

Verwendung:
  sudo ./install_pi5.sh [Optionen]

Das Skript prueft das Raspberry-Pi-Modell und verwendet immer den
vorgebauten Flutter-Web-Release. Dadurch wird Flutter/Dart nicht auf dem
Raspberry Pi selbst kompiliert und die Installation bleibt reproduzierbar.
Raspberry Pi OS 64-Bit (arm64) wird fuer den Pi 5 empfohlen.

Alle weiteren Optionen werden an install.sh weitergereicht, z. B.:
  --reboot
  --active-high 0|1
  --kiosk-delay SEKUNDEN
  --user BENUTZER
  --skip-lcd
  --skip-boot-opt
  --pico-port PORT
  --gpio-chip auto|NUMMER

Hinweis: --build-mode wird absichtlich auf "release" festgelegt.
USAGE
}

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    show_help
    exit 0
  fi
done

[[ -f "$COMMON_INSTALLER" ]] || die "Gemeinsamer Installer fehlt: $COMMON_INSTALLER"
[[ $EUID -eq 0 ]] || die "Bitte mit sudo ausfuehren: sudo ./install_pi5.sh --reboot"

MODEL="Unbekannt"
if [[ -r /proc/device-tree/model ]]; then
  MODEL="$(tr -d '\0' < /proc/device-tree/model)"
elif [[ -r /sys/firmware/devicetree/base/model ]]; then
  MODEL="$(tr -d '\0' < /sys/firmware/devicetree/base/model)"
fi

case "$MODEL" in
  *"Raspberry Pi 5"*|*"Raspberry Pi 500"*|*"Compute Module 5"*) ;;
  *"Raspberry Pi 4"*|*"Raspberry Pi 400"*|*"Compute Module 4"*)
    die "Erkannt wurde '$MODEL'. Bitte verwende stattdessen: sudo ./install_pi4.sh --reboot"
    ;;
  *)
    die "Dieses Skript ist fuer Raspberry Pi 5/500/Compute Module 5 vorgesehen. Erkannt: '$MODEL'"
    ;;
esac

USERLAND_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
KERNEL_ARCH="$(uname -m)"

case "$USERLAND_ARCH" in
  arm64) ;;
  armhf)
    warn "Raspberry Pi OS 32-Bit (armhf) erkannt. Die Installation kann den vorgebauten Web-Release verwenden; fuer Raspberry Pi 5 wird jedoch Raspberry Pi OS 64-Bit (arm64) empfohlen."
    ;;
  *) die "Nicht unterstuetzte OS-Architektur: $USERLAND_ARCH. Erwartet wird arm64 oder armhf." ;;
esac

log "Hardware- und Systempruefung"
printf '  Modell:          %s\n' "$MODEL"
printf '  Kernel:          %s\n' "$KERNEL_ARCH"
printf '  OS-Architektur:  %s\n' "$USERLAND_ARCH"
printf '  Web-Buildmodus:  release (vorgebaut)\n'

log "Der gemeinsame Installer wird jetzt mit Pi-5-sicherem Release-Build gestartet."
export COCKTAILBOT_FORCE_X11_1024X600=0
exec bash "$COMMON_INSTALLER" "$@" --build-mode release
