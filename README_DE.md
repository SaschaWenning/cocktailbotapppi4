# CocktailBotApp – Raspberry Pi Kiosk + Pico 2 + lokales PayPal

Repository:

```text
https://github.com/saschawenning/cocktailbotapp.git
```

## Architektur

- **Raspberry Pi**: Flutter-Web-App, Chromium-Kiosk, 18 Pumpen über BCM-GPIO, lokales REST-API, lokales PayPal-Backend und SQLite-Zahlungsdatenbank.
- **Raspberry Pi Pico 2**: 240 WS2812B-LEDs über GPIO0; Steuerung per USB-Serial.
- **PayPal**: Nur die PayPal-API ist extern. Es gibt keinen Cloudflare-Worker und keinen externen QR-Code-Dienst.

Die Web-App und das lokale Backend laufen über `http://127.0.0.1:8080`. Der Server bindet bewusst nur an Loopback, damit Pumpen- und Zahlungs-API nicht im LAN offen stehen.

## Installation

### 1. Repository klonen

```bash
git clone https://github.com/saschawenning/cocktailbotapp.git
cd cocktailbotapp
```

### 2. Komplettinstallation

Für eine Neuinstallation gibt es jetzt zwei eindeutige Einstiegsskripte. Beide prüfen das Raspberry-Pi-Modell und verwenden den vorgebauten `web-release`, damit Flutter/Dart nicht auf dem Pi selbst kompiliert werden muss.

**Raspberry Pi 4 / Pi 400 / Compute Module 4:**

```bash
chmod +x install_pi4.sh
sudo ./install_pi4.sh --reboot
```

**Raspberry Pi 5 / Pi 500 / Compute Module 5:**

```bash
chmod +x install_pi5.sh
sudo ./install_pi5.sh --reboot
```

Das bisherige `install.sh` bleibt als gemeinsamer Installer erhalten. Die Pi-spezifischen Skripte führen zuerst eine Hardware-/Architekturprüfung aus und rufen anschließend `install.sh` mit `--build-mode release` auf.

Die Installation richtet ein:

- Chromium-Kioskstart nach 30 Sekunden
- Desktop-Autologin
- GoodTFT `LCD7C-show`
- 1024×600 Displaykonfiguration
- Bootoptimierungen
- Python-/Flask-Dienst
- GPIO-Pumpensteuerung mit automatischer RP1-`gpiochip`-Erkennung auf Raspberry Pi 5
- Pico-2-USB-Serial-Bridge
- lokales PayPal-Backend
- SQLite unter `/var/lib/cocktailbot/payments.db`
- Flutter-Web-App

Das **lokale PayPal-Backend wird bei jeder Installation vollständig mitinstalliert**, aber der Installer fragt bewusst **keine PayPal-Zugangsdaten** ab. Dadurch kann jede Maschine mit demselben Installationsskript eingerichtet werden, auch wenn der Betreiber PayPal überhaupt nicht nutzt.

Normale Installation je nach Hardware:

```bash
# Raspberry Pi 4
sudo ./install_pi4.sh --reboot

# Raspberry Pi 5
sudo ./install_pi5.sh --reboot
```

Nach der Installation läuft CocktailBot vollständig; die Bezahlfunktion bleibt einfach inaktiv, solange keine PayPal-Zugangsdaten hinterlegt wurden.

Auf dem Raspberry Pi 5 erkennt CocktailBot den RP1-GPIO-Chip automatisch über `pinctrl-rp1`. Dadurch ist die Pumpensteuerung nicht von einer festen Nummer wie `gpiochip0`, `gpiochip4` oder `gpiochip15` abhängig. Für Diagnosezwecke kann mit `--gpio-chip NUMMER` manuell überschrieben werden; im Normalbetrieb sollte `auto` verwendet werden.

## PayPal lokal konfigurieren

Die PayPal Client-ID und das Client-Secret gehören **nicht** ins GitHub-Repository und **nicht** in Flutter.

Wenn PayPal verwendet werden soll, erfolgt die Erstkonfiguration **erst später und ausdrücklich durch den Betreiber**:

```bash
sudo cocktailbot-paypal-config
```

Das Skript fragt ab:

- `sandbox` oder `live`
- PayPal Client-ID
- PayPal Client-Secret (verdeckt)
- optionale Return-/Cancel-URL

Gespeichert wird ausschließlich auf dem Raspberry:

```text
/etc/cocktailbot/paypal.env
```

Berechtigung:

```text
0600 root:root
```

Standardmäßig wird `sandbox` verwendet. Erst nach vollständigem Test auf `live` umstellen.

Status prüfen:

```bash
curl http://127.0.0.1:8080/api/payment/status
```

PayPal-Zugang testen:

```bash
curl -X POST http://127.0.0.1:8080/api/payment/test
```

## Zahlungsablauf

1. Die App synchronisiert Maschinen-ID und Verkaufspreise mit dem lokalen Raspberry-Dienst.
2. Beim Bestellen sendet der Browser nur Rezept-ID, Rezeptname, Kategorie und Größe.
3. **Der Betrag wird vom Raspberry aus der lokal gespeicherten Preiskonfiguration bestimmt.** Ein vom Browser manipulierter `amount`-Wert wird nicht verwendet.
4. Der Raspberry holt serverseitig einen PayPal OAuth-Token und erstellt eine Orders-v2-Order mit `intent=CAPTURE`.
5. Die PayPal-Freigabe-URL wird an die Flutter-App zurückgegeben.
6. Flutter erzeugt den QR-Code **lokal** mit `qr_flutter`; kein externer QR-Dienst wird benötigt.
7. Die App fragt den lokalen Raspberry alle vier Sekunden nach dem Zahlungsstatus.
8. Sobald PayPal `APPROVED` meldet, führt der Raspberry serverseitig den Capture aus.
9. Nur `COMPLETED` gilt als bezahlt. Der Raspberry verifiziert zusätzlich Betrag und Währung gegen die lokale Bestellung.
10. Vor der Cocktailzubereitung wird die Order in SQLite atomar als `used` markiert. Eine zweite Verwendung derselben Zahlung wird mit HTTP 409 abgewiesen.

### Lokale Payment-Endpunkte

```text
GET  /api/payment/status
POST /api/payment/test
POST /api/payment/config
POST /api/payment/create-order
GET  /api/payment/order-status?orderId=...
POST /api/payment/mark-used
```

## Pumpenbelegung BCM

| Pumpe | GPIO | Pumpe | GPIO |
|---:|---:|---:|---:|
| 1 | 17 | 10 | 6 |
| 2 | 18 | 11 | 13 |
| 3 | 27 | 12 | 19 |
| 4 | 22 | 13 | 26 |
| 5 | 23 | 14 | 16 |
| 6 | 24 | 15 | 20 |
| 7 | 25 | 16 | 21 |
| 8 | 4 | 17 | 12 |
| 9 | 5 | 18 | 15 |

Standard: `LOW = Pumpe EIN`, `HIGH = Pumpe AUS` (`--active-high 0`).

Für LOW-aktive Relais:

```bash
sudo ./install.sh --active-high 0 --reboot
```

## Pico-2-LED-Steuerung

Firmware:

```text
firmware/pico2/main.py
```

Unterstützte Befehle:

```text
COLOR r g b
OFF
READY
BUSY
ERROR
RAINBOW
PULSE r g b
BLINK r g b
BRIGHT 0..255
```

Der Raspberry sucht automatisch in `/dev/serial/by-id/` und `/dev/ttyACM*`.

Fester Port:

```bash
sudo ./install.sh --pico-port /dev/ttyACM0 --reboot
```

Die Pumpen funktionieren weiter, wenn der Pico nicht angeschlossen ist.

## LCD / Kiosk

Standardmäßig wird der GoodTFT-LCD7C-Treiber installiert. Zusätzlich werden u. a. 1024×600, grafischer Desktopstart, Autologin und Chromium-Kiosk eingerichtet.

Ohne GoodTFT-Installation:

```bash
sudo ./install.sh --skip-lcd --reboot
```

Ohne zusätzliche Bootoptimierung:

```bash
sudo ./install.sh --skip-boot-opt --reboot
```

Andere Kiosk-Verzögerung:

```bash
sudo ./install.sh --kiosk-delay 45 --reboot
```

## Aktualisierung

```bash
sudo /opt/cocktailbot/source/tools/update.sh
```

Die PayPal-Zugangsdaten in `/etc/cocktailbot/paypal.env` werden bei Updates nicht überschrieben. LCD-Treiber und Bootoptimierungen werden durch `update.sh` nicht erneut ausgeführt.

## Diagnose

```bash
systemctl status cocktailbot.service
journalctl -u cocktailbot.service -n 100 --no-pager
curl http://127.0.0.1:8080/api/status
curl http://127.0.0.1:8080/api/payment/status
ls -l /dev/serial/by-id/ 2>/dev/null || true
```

## Wichtige Dateien

```text
app/lib/main.dart                         Flutter-App
app/pubspec.yaml                          Flutter-Abhängigkeiten
raspberry/cocktailbot_server.py           GPIO + Pico + lokales PayPal
raspberry/start-kiosk.sh                  Chromium-Kiosk
firmware/pico2/main.py                    Pico-2-LED-Firmware
tools/configure-paypal.sh                 lokale PayPal-Konfiguration
tools/update.sh                           Update
install_pi4.sh                            Einstieg für Raspberry Pi 4/400/CM4
install_pi5.sh                            Einstieg für Raspberry Pi 5/500/CM5
install.sh                                Gemeinsamer Komplettinstaller
/etc/cocktailbot/paypal.env               PayPal-Secrets (nur auf dem Pi)
/var/lib/cocktailbot/payments.db           SQLite-Zahlungsdatenbank
```

## Sicherheit

- PayPal Client-Secret niemals in GitHub committen.
- Der CocktailBot-Webserver bleibt standardmäßig auf `127.0.0.1` gebunden.
- Die SQLite-Datenbank verhindert die erneute Verwendung einer bereits verwendeten Order.
- Vor dem Anschluss von Flüssigkeiten jede Pumpe einzeln prüfen.

## Offline-Gewerbelizenz

CocktailBot unterstützt eine gerätegebundene Offline-Gewerbelizenz ohne Lizenzserver. Unter **Einstellungen → Gewerbelizenz** zeigt der Raspberry eine hardwarebasierte Geräte-ID an. Diese ID wird an den Lizenzgeber gesendet. Der separate CocktailBot-Lizenzgenerator signiert genau diese Geräte-ID und erzeugt einen `CBL1-...` Lizenzcode. Der Raspberry prüft die Signatur lokal mit dem öffentlichen Ed25519-Schlüssel.

Der private Signierschlüssel gehört ausschließlich in den Lizenzgenerator und darf niemals in dieses Repository übernommen werden.

## Offline-Image-Build (V26)

Für den CocktailBot-Master-Image-Builder unterstützt `install.sh` den Schalter `--image-build`. Dabei werden Dateien, Dienste, Kiosk und Displaykonfiguration vollständig vorbereitet, aber der CocktailBot-Dienst und GPIO-Hardwaretest nicht im Chroot gestartet. Auf dem echten Raspberry Pi wird `pinctrl-rp1` anschließend beim Serverstart automatisch erkannt.

## LAN-/Tablet-Zugriff (V29)

Der lokale Raspberry-Kiosk bleibt unter `http://127.0.0.1:8080` erreichbar. Externe Geräte sind standardmäßig gesperrt.

1. CocktailBot am Raspberry öffnen.
2. **Einstellungen → Netzwerk & Tablet** öffnen.
3. Einen **4- bis 8-stelligen Admin-PIN** festlegen.
4. **Zugriff im lokalen Netzwerk erlauben** aktivieren und speichern.
5. Eine der angezeigten Adressen, z. B. `http://192.168.178.45:8080`, auf Tablet oder PC im selben WLAN/LAN öffnen.

Cocktails können auf einem freigegebenen Tablet normal ausgewählt und zubereitet werden. Beim Öffnen der Einstellungen von einem externen Gerät wird der Admin-PIN verlangt. Kritische Remote-Aktionen werden zusätzlich im Raspberry-Backend geprüft. Die Freigabe ist ausschließlich für private/lokale Netze gedacht und ersetzt keine sichere Internet-Freigabe, VPN- oder Reverse-Proxy-Konfiguration.
