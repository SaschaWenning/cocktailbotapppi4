
## Display-Fix V6 – Pi 4 / doppelte Kernel-Auflösung
- `disable_fw_kms_setup=1` wird im CocktailBot-Displayblock gesetzt.
- Verhindert, dass die Raspberry-Pi-Firmware zusätzlich einen EDID-Modus wie `video=HDMI-A-1:1920x1080M@60` in die Kernel-Commandline einschleust.
- `cmdline.txt` enthält weiterhin ausschließlich `video=HDMI-A-1:1024x600M@60`.
- Relevant insbesondere für Pi 4; auf Pi 5 ist `disable_fw_kms_setup` laut Raspberry-Pi-Dokumentation bereits standardmäßig aktiv.
## V29 – LAN-/Tablet-Zugriff mit Admin-PIN (17.08.2026)

- Neuer Bereich **Einstellungen → Netzwerk & Tablet**.
- CocktailBot kann dort gezielt für Geräte im **gleichen lokalen WLAN/LAN** freigegeben oder wieder gesperrt werden.
- Der Raspberry-Dienst lauscht technisch auf `0.0.0.0:8080`, blockiert externe Geräte aber serverseitig, solange der LAN-Zugriff nicht ausdrücklich aktiviert wurde.
- Öffentliche Internet-IP-Adressen werden vom Backend grundsätzlich abgewiesen; die Freigabe ist nur für private/lokale Netze vorgesehen.
- Beim Aktivieren muss ein **4- bis 8-stelliger Admin-PIN** gesetzt werden. Der PIN wird auf dem Raspberry nur als PBKDF2-Hash mit zufälligem Salt gespeichert.
- Tablet/PC können Cocktails ohne Admin-PIN auswählen und zubereiten; der Einstellungsbereich fordert auf externen Geräten immer den Admin-PIN an.
- Kritische Remote-Aktionen wie Kalibrierung/Pumpenlauf, Reinigung, Priming, LED-Konfiguration, Lizenzänderungen, PayPal-Konfiguration, Bildverwaltung und Kiosk-Beenden sind zusätzlich serverseitig durch eine zeitlich begrenzte Admin-Sitzung geschützt.
- Die Netzwerkseite zeigt automatisch erkannte Raspberry-IP-Adressen als direkt nutzbare URLs wie `http://192.168.x.x:8080` an und bietet Kopieren per Touch.
- Der Raspberry veröffentlicht einen bereinigten App-Zustand für LAN-Geräte, damit Rezepte, aktive Größen, Designs, Preise, Party-/Statistikdaten und weitere nicht geheime Einstellungen auf dem Tablet übernommen werden.
- Einstellungs-Passwort und Lizenzcode werden nicht in den LAN-App-Zustand aufgenommen.
- Zubereitungen von einem Tablet synchronisieren Füllstände direkt zurück zum Raspberry; Verbrauchsereignisse werden für die zentrale Statistik im Raspberry-App-Zustand nachgeführt und gegen doppelte Übertragung dedupliziert.
- Die Statistik lädt beim Öffnen den aktuellen gemeinsamen Zustand; die Füllstandsseite aktualisiert die Pumpenzustände vom Raspberry.
- Der lokale Kiosk bleibt unverändert auf `http://127.0.0.1:8080` und funktioniert auch bei deaktiviertem LAN-Zugriff.


### Ergänzung – Lizenz- und Nutzungshinweis (18.08.2026)

- Neuer Bereich **Einstellungen → Info & Lizenz** mit Copyright, Kontakt zu Sascha Wenning / Printcore und den Nutzungsbedingungen für Privat- und Gewerbebetrieb.
- Beim Start erscheint ein nicht wegklickbarer Lizenz- und Nutzungshinweis, solange der Nutzer ihn nicht mit **„Akzeptieren“** bestätigt hat.
- Optional kann **„Diesen Hinweis nicht mehr anzeigen“** aktiviert werden; die Bestätigung wird versionsgebunden in den lokalen App-Einstellungen gespeichert.
- Über **Info & Lizenz → Start-Hinweis wieder anzeigen** kann die gespeicherte Ausblendung jederzeit zurückgesetzt werden.
- **„Ablehnen“** beendet am Raspberry den Chromium-Kiosk über den vorhandenen sicheren Kiosk-Exit-Endpunkt. Auf einem entfernten Tablet/PC wird nur die dortige Sitzung gesperrt, damit ein Remote-Nutzer nicht den Raspberry-Kiosk abschalten kann.

## Installer-Fix Raspberry Pi OS 32-Bit
- Standard-Buildmodus auf `auto` geändert: vorhandener `web-release` wird bevorzugt.
- Lokaler Flutter-Build wird auf `armhf` früh mit verständlicher Meldung abgebrochen.
- Verhindert den ARM64-Dart-SDK-Fehler auf Raspberry Pi OS 32-Bit mit 64-Bit-Kernel.

## Separate Installer für Raspberry Pi 4 und 5
- `install_pi4.sh` für Raspberry Pi 4, Pi 400 und Compute Module 4 ergänzt.
- `install_pi5.sh` für Raspberry Pi 5, Pi 500 und Compute Module 5 ergänzt.
- Beide Skripte prüfen vor der Installation das erkannte Hardwaremodell und weisen bei einem falschen Skript auf den korrekten Installer hin.
- Modell, Kernel-Architektur und OS-Architektur werden vor Installationsbeginn angezeigt.
- Beide Einstiegsskripte erzwingen den vorgebauten `web-release`, damit auf dem Raspberry Pi kein Flutter-/Dart-Build notwendig ist.
- Pi 4 unterstützt dabei sowohl `armhf` als auch `arm64`; Pi 5 warnt bei `armhf` und empfiehlt `arm64`.
- Das bestehende `install.sh` bleibt die gemeinsame Installationsbasis und muss dadurch nur einmal gepflegt werden.

### Pi-4-/Pi-5-Installertrennung (V4)

- Der neue Wayland-/kanshi-/wlr-randr-Fix für 1024x600 wird ausschließlich durch `install_pi4.sh` aktiviert.
- `install_pi5.sh` behält die zuvor funktionierende Displaykonfiguration unverändert bei.
- Der gemeinsame Installer entfernt beim Pi-5-Pfad nur versehentlich hinterlassene, eindeutig markierte V3-Pi-4-Displaydateien.

### Raspberry Pi 4 – X11 1024x600 Fix
- Pi 4 aktiviert jetzt vor Chromium einen getesteten XRandR-Custom-Mode `1024x600_60.00`.
- Verwendete Modeline: `49.00 1024 1064 1168 1312 600 603 613 624 -hsync +vsync`.
- Der Fix greift nur ueber `install_pi4.sh`; `install_pi5.sh` deaktiviert ihn explizit.
- Ursache: Das LCD7C meldet 1024x600 nicht per EDID, wodurch `rpd-x`/X11 zuvor 1600x900 gewaehlt hat.
