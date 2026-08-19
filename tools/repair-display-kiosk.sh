#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo starten." >&2; exit 1; }

TARGET_USER="${SUDO_USER:-pi}"
[[ "$TARGET_USER" == "root" ]] && TARGET_USER=pi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" ]] || TARGET_HOME="/home/$TARGET_USER"

CONFIG=""
CMDLINE=""
[[ -f /boot/firmware/config.txt ]] && CONFIG=/boot/firmware/config.txt
[[ -z "$CONFIG" && -f /boot/config.txt ]] && CONFIG=/boot/config.txt
[[ -f /boot/firmware/cmdline.txt ]] && CMDLINE=/boot/firmware/cmdline.txt
[[ -z "$CMDLINE" && -f /boot/cmdline.txt ]] && CMDLINE=/boot/cmdline.txt

[[ -n "$CONFIG" && -n "$CMDLINE" ]] || { echo "Bootdateien nicht gefunden." >&2; exit 1; }
cp -a "$CONFIG" "$CONFIG.cocktailbot-repair.bak"
cp -a "$CMDLINE" "$CMDLINE.cocktailbot-repair.bak"

python3 - "$CONFIG" "$CMDLINE" <<'PY'
from pathlib import Path
import sys
config, cmdline = map(Path, sys.argv[1:3])

lines = config.read_text(errors='replace').splitlines()
out=[]
in_block=False
prefixes=(
 'dtoverlay=vc4-fkms-v3d','dtoverlay=vc4-kms-v3d',
 'hdmi_force_hotplug','hdmi_group','hdmi_mode','hdmi_cvt',
 'hdmi_drive','config_hdmi_boost','framebuffer_width','framebuffer_height',
 'max_framebuffer_width','max_framebuffer_height','disable_fw_kms_setup',
)
for raw in lines:
    s=raw.strip()
    if s == '# BEGIN COCKTAILBOT DISPLAY': in_block=True; continue
    if s == '# END COCKTAILBOT DISPLAY': in_block=False; continue
    if in_block: continue
    active=s.lstrip('#').strip()
    if any(active.startswith(p) for p in prefixes): continue
    out.append(raw)
while out and not out[-1].strip(): out.pop()
out += ['', '# BEGIN COCKTAILBOT DISPLAY', '[all]', 'dtoverlay=vc4-kms-v3d', '# END COCKTAILBOT DISPLAY']
config.write_text('\n'.join(out)+'\n')

tokens=cmdline.read_text(errors='replace').split()
tokens=[t for t in tokens if t not in {'quiet','splash'} and not t.startswith('video=')]
tokens.append('video=HDMI-A-1:1024x600M@60')
cmdline.write_text(' '.join(tokens)+'\n')
PY

# LOW-active pump relays: safe HIGH level during boot.
python3 - "$CONFIG" "$CMDLINE" <<'PY'
from pathlib import Path
import sys
config, cmdline = map(Path, sys.argv[1:3])
pins='17,18,27,22,23,24,25,4,5,6,13,19,26,16,20,21,12,15'
lines=config.read_text(errors='replace').splitlines()
out=[]; block=False
for raw in lines:
    s=raw.strip()
    if s == '# BEGIN COCKTAILBOT PUMP SAFETY': block=True; continue
    if s == '# END COCKTAILBOT PUMP SAFETY': block=False; continue
    if block: continue
    if s.startswith('enable_uart='): continue
    if s.startswith('gpio='+pins+'=op,'): continue
    out.append(raw)
out += ['', '# BEGIN COCKTAILBOT PUMP SAFETY', '[all]', 'enable_uart=0', f'gpio={pins}=op,dh', '# END COCKTAILBOT PUMP SAFETY']
config.write_text('\n'.join(out)+'\n')

tokens=cmdline.read_text(errors='replace').split()
tokens=[t for t in tokens if not (t.startswith('console=serial0,') or t.startswith('console=ttyAMA') or t.startswith('console=ttyS'))]
cmdline.write_text(' '.join(tokens)+'\n')
PY

systemctl disable --now serial-getty@serial0.service serial-getty@ttyAMA0.service serial-getty@ttyS0.service >/dev/null 2>&1 || true
systemctl unmask dev-dri-card0.device dev-dri-card1.device dev-dri-renderD128.device >/dev/null 2>&1 || true
systemctl set-default graphical.target
if command -v raspi-config >/dev/null 2>&1; then
  raspi-config nonint do_boot_behaviour B4 || true
  raspi-config nonint do_blanking 1 || true
fi
if systemctl list-unit-files lightdm.service >/dev/null 2>&1; then
  systemctl enable lightdm.service >/dev/null 2>&1 || true
fi

# Finish the parts that were skipped when the older installer aborted.
mkdir -p "$TARGET_HOME/.config/autostart" "$TARGET_HOME/.config/labwc" "$TARGET_HOME/.local/state"
if [[ -f /opt/cocktailbot/source/raspberry/autostart/cocktailbot-kiosk.desktop ]]; then
  install -o "$TARGET_USER" -g "$TARGET_USER" -m 0644 \
    /opt/cocktailbot/source/raspberry/autostart/cocktailbot-kiosk.desktop \
    "$TARGET_HOME/.config/autostart/cocktailbot-kiosk.desktop"
fi
LABWC="$TARGET_HOME/.config/labwc/autostart"
touch "$LABWC"
sed -i '/# BEGIN COCKTAILBOT/,/# END COCKTAILBOT/d' "$LABWC" || true
cat >> "$LABWC" <<LABWC_EOF

# BEGIN COCKTAILBOT
/opt/cocktailbot/raspberry/start-kiosk.sh >> $TARGET_HOME/.local/state/cocktailbot-kiosk.log 2>&1 &
# END COCKTAILBOT
LABWC_EOF
chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config/autostart" "$TARGET_HOME/.config/labwc" "$TARGET_HOME/.local/state"

# Restore web readability and start the local API now.
chmod 0755 /opt/cocktailbot /opt/cocktailbot/web 2>/dev/null || true
find /opt/cocktailbot/web -type d -exec chmod 0755 {} + 2>/dev/null || true
find /opt/cocktailbot/web -type f -exec chmod 0644 {} + 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now cocktailbot.service >/dev/null 2>&1 || true

echo
echo "Reparatur gesetzt. Bootdateien:"
grep -E 'dtoverlay=vc4|hdmi_|framebuffer_|disable_fw_kms|COCKTAILBOT DISPLAY|COCKTAILBOT PUMP|gpio=|enable_uart' "$CONFIG" || true
echo "cmdline: $(cat "$CMDLINE")"
echo
echo "Jetzt neu starten: sudo reboot"
