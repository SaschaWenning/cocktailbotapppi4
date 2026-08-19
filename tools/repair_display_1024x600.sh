#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '\n\033[1;36m[CocktailBot Display]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[CocktailBot Display FEHLER]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Bitte mit sudo ausführen."

config_file=""
cmdline_file=""
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
[[ -n "$config_file" && -n "$cmdline_file" ]] || die "Bootdateien config.txt/cmdline.txt wurden nicht gefunden."

log "Stelle bewährte LCD7C/KMS-Konfiguration 1024x600@60 wieder her"
cp -a "$config_file" "${config_file}.cocktailbot-display-repair.bak" || true
cp -a "$cmdline_file" "${cmdline_file}.cocktailbot-display-repair.bak" || true

python3 - "$config_file" "$cmdline_file" <<'PY_DISPLAY'
from pathlib import Path
import sys

config, cmdline = map(Path, sys.argv[1:3])
lines = config.read_text(errors="replace").splitlines()
out = []
in_block = False
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
    "# LCD7C native resolution is selected by the kernel command line below.",
    "# END COCKTAILBOT DISPLAY",
]
config.write_text("\n".join(out) + "\n")

tokens = cmdline.read_text(errors="replace").split()
tokens = [t for t in tokens if t not in {"quiet", "splash"} and not t.startswith("video=")]
tokens.append("video=HDMI-A-1:1024x600M@60")
cmdline.write_text(" ".join(tokens) + "\n")
PY_DISPLAY

# Remove only the experimental CocktailBot overrides from V3/V4 if present.
TARGET_USER="${SUDO_USER:-pi}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
if [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]]; then
  if [[ -f "$TARGET_HOME/.config/kanshi/config" ]] && grep -Eq "COCKTAILBOT (PI4 )?DISPLAY" "$TARGET_HOME/.config/kanshi/config"; then
    rm -f "$TARGET_HOME/.config/kanshi/config"
  fi
fi
rm -f /opt/cocktailbot/raspberry/force-display-pi4.sh /opt/cocktailbot/raspberry/force-display.sh

log "Aktive Kernel-Cmdline:"
cat "$cmdline_file"
log "Displayblock in config.txt:"
sed -n '/# BEGIN COCKTAILBOT DISPLAY/,/# END COCKTAILBOT DISPLAY/p' "$config_file"

echo
echo "Fertig. Jetzt neu starten:"
echo "  sudo reboot"
