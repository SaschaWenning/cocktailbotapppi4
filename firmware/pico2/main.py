# === CocktailBot Pico 2 LED Controller ===
# 240x WS2812B an GPIO0 / MicroPython USB-Serial
#
# Befehle:
#   COLOR R G B
#   OFF
#   READY
#   BUSY
#   ERROR
#   RAINBOW
#   PULSE R G B
#   BLINK R G B
#   BRIGHT 0..255
#   STATUS
#
# Wichtig: Alle Animationen sind NICHT BLOCKIEREND. Der Pico prueft zwischen
# jedem Animations-Frame auf neue USB-Serial-Befehle. Dadurch kann z.B. ein
# laufender RAINBOW sofort von "BLINK 255 0 0" unterbrochen werden.

import machine
import neopixel
import select
import sys
import time

LED_PIN = 0
NUM_LEDS = 240
BRIGHTNESS = 0.5

RAINBOW_INTERVAL_MS = 18
PULSE_INTERVAL_MS = 20
BLINK_INTERVAL_MS = 300

np = neopixel.NeoPixel(machine.Pin(LED_PIN), NUM_LEDS)

current_mode = "OFF"
current_color = (0, 0, 0)
running = True

# Effektzustand
rainbow_frame = 0
pulse_step = 0
pulse_direction = 1
blink_on = False
last_effect_update = time.ticks_ms()


def clamp_byte(value):
    return max(0, min(255, int(value)))


def apply_brightness(color):
    return tuple(int(clamp_byte(c) * BRIGHTNESS) for c in color)


def set_all(color):
    np.fill(apply_brightness(color))
    np.write()


def set_off():
    np.fill((0, 0, 0))
    np.write()


def wheel(pos):
    """RGB-Farbkreis, Helligkeit wird beim Setzen separat angewendet."""
    pos &= 255
    if pos < 85:
        return (pos * 3, 255 - pos * 3, 0)
    if pos < 170:
        pos -= 85
        return (255 - pos * 3, 0, pos * 3)
    pos -= 170
    return (0, pos * 3, 255 - pos * 3)


def reset_effect_state(now=None):
    global rainbow_frame, pulse_step, pulse_direction, blink_on, last_effect_update
    rainbow_frame = 0
    pulse_step = 0
    pulse_direction = 1
    blink_on = False
    last_effect_update = time.ticks_ms() if now is None else now


def render_rainbow():
    global rainbow_frame
    for i in range(NUM_LEDS):
        pixel_index = (i * 256 // NUM_LEDS + rainbow_frame) & 255
        np[i] = apply_brightness(wheel(pixel_index))
    np.write()
    rainbow_frame = (rainbow_frame + 1) & 255


def render_pulse():
    global pulse_step, pulse_direction
    # 0..50..0: ca. 2 Sekunden pro kompletter Atembewegung.
    factor = pulse_step / 50.0
    color = tuple(int(c * factor) for c in current_color)
    set_all(color)

    pulse_step += pulse_direction
    if pulse_step >= 50:
        pulse_step = 50
        pulse_direction = -1
    elif pulse_step <= 0:
        pulse_step = 0
        pulse_direction = 1


def render_blink():
    global blink_on
    blink_on = not blink_on
    if blink_on:
        set_all(current_color)
    else:
        set_off()


def update_effect(now):
    """Zeichnet hoechstens EINEN Frame und kehrt sofort zur Hauptschleife zurueck."""
    global last_effect_update

    if current_mode == "RAINBOW":
        if time.ticks_diff(now, last_effect_update) >= RAINBOW_INTERVAL_MS:
            last_effect_update = now
            render_rainbow()
        return

    if current_mode == "PULSE":
        if time.ticks_diff(now, last_effect_update) >= PULSE_INTERVAL_MS:
            last_effect_update = now
            render_pulse()
        return

    if current_mode in ("BLINK", "BUSY", "ERROR"):
        if time.ticks_diff(now, last_effect_update) >= BLINK_INTERVAL_MS:
            last_effect_update = now
            render_blink()
        return


def handle_command(cmd):
    global current_mode, current_color, BRIGHTNESS

    parts = cmd.strip().split()
    if not parts:
        return

    action = parts[0].upper()
    now = time.ticks_ms()

    try:
        if action == "COLOR" and len(parts) >= 4:
            current_mode = "COLOR"
            current_color = tuple(clamp_byte(v) for v in parts[1:4])
            reset_effect_state(now)
            set_all(current_color)
            print("OK: COLOR {} {} {}".format(*current_color))

        elif action == "OFF":
            current_mode = "OFF"
            current_color = (0, 0, 0)
            reset_effect_state(now)
            set_off()
            print("OK: OFF")

        elif action == "READY":
            current_mode = "COLOR"
            current_color = (0, 255, 0)
            reset_effect_state(now)
            set_all(current_color)
            print("OK: READY")

        elif action == "BUSY":
            current_mode = "BUSY"
            current_color = (255, 255, 0)
            reset_effect_state(now)
            # Sofort sichtbar, nicht erst nach 300 ms.
            set_all(current_color)
            print("OK: BUSY")

        elif action == "ERROR":
            current_mode = "ERROR"
            current_color = (255, 0, 0)
            reset_effect_state(now)
            set_all(current_color)
            print("OK: ERROR")

        elif action == "RAINBOW":
            current_mode = "RAINBOW"
            reset_effect_state(now)
            render_rainbow()
            print("OK: RAINBOW")

        elif action == "PULSE" and len(parts) >= 4:
            current_mode = "PULSE"
            current_color = tuple(clamp_byte(v) for v in parts[1:4])
            reset_effect_state(now)
            render_pulse()
            print("OK: PULSE {} {} {}".format(*current_color))

        elif action == "BLINK" and len(parts) >= 4:
            current_mode = "BLINK"
            current_color = tuple(clamp_byte(v) for v in parts[1:4])
            reset_effect_state(now)
            # Bei Zubereitung kommt "BLINK 255 0 0": sofort ROT zeigen.
            set_all(current_color)
            print("OK: BLINK {} {} {}".format(*current_color))

        elif action == "BRIGHT" and len(parts) >= 2:
            value = clamp_byte(parts[1])
            BRIGHTNESS = value / 255.0
            # Statische Farbe sofort neu rendern. Animationen greifen die neue
            # Helligkeit bereits beim naechsten Frame auf.
            if current_mode == "COLOR":
                set_all(current_color)
            elif current_mode == "OFF":
                set_off()
            print("OK: BRIGHT {}".format(value))

        elif action == "STATUS":
            print(
                "STATUS mode={} rgb={},{},{} bright={}".format(
                    current_mode,
                    current_color[0],
                    current_color[1],
                    current_color[2],
                    int(BRIGHTNESS * 255),
                )
            )

        else:
            print("ERROR: Unknown command '{}'".format(cmd))

    except (ValueError, TypeError) as exc:
        print("ERROR: Invalid command '{}': {}".format(cmd, exc))


print("Pico LED Controller ready")
print("Supported: COLOR, OFF, READY, BUSY, ERROR, RAINBOW, PULSE, BLINK, BRIGHT, STATUS")
set_off()

poll = select.poll()
poll.register(sys.stdin, select.POLLIN)

while running:
    try:
        # Erst ALLE bereits angekommenen Befehle verarbeiten. Damit haben
        # Maschinenzustands-Befehle immer Vorrang vor einem Idle-Effekt.
        while True:
            events = poll.poll(0)
            if not events:
                break
            line = sys.stdin.readline()
            if not line:
                break
            handle_command(line.strip())

        update_effect(time.ticks_ms())

        # Kurze Pause: genug Reaktionszeit, ohne den Pico mit Busy-Wait zu belasten.
        time.sleep_ms(5)

    except KeyboardInterrupt:
        set_off()
        running = False
        print("Shutdown")

    except Exception as exc:
        print("ERROR: {}".format(exc))
        # LEDs in einen sicheren Zustand bringen, Serial aber weiterleben lassen.
        set_off()
        time.sleep_ms(100)
