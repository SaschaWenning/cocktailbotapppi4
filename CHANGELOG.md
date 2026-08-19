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

## V28.1 – Flutter-Compile-Fix für Verbrauchsstatistik

- Behebt den Dart-Compilefehler in der neuen V28-Verbrauchsstatistik: `averageCost` wird jetzt explizit als `double` geführt.
- Die Durchschnittskosten-Getter verwenden ebenfalls explizit `0.0`, damit die Typinferenz unter aktuellen Dart-/Flutter-Versionen eindeutig `double` bleibt.
- Keine funktionalen Änderungen an Statistik, PayPal oder Preisen pro Cocktailgröße gegenüber V28.

## V28 – Verbrauchsstatistik & PayPal-Preise pro Größe (16.08.2026)

- **Verbrauchsstatistik komplett neu aufgebaut**: Zeitraumfilter für Heute, 7 Tage, 30 Tage, Party und Gesamt sowie Umschaltung zwischen Cocktails und Zutaten.
- Neue kompakte Kennzahlen für **Zubereitungen, Gesamtkosten, Durchschnittskosten und ausgegebene Getränkemenge**.
- Pro Cocktail werden **Anzahl, Gesamtkosten, Durchschnittskosten, Gesamtmenge und die tatsächliche Aufteilung nach Cocktailgröße** angezeigt.
- Kosten werden ab V28 bei jeder Zubereitung mit dem **damals gültigen Zutatenpreis** gespeichert; spätere Preisänderungen verändern historische Kosten nicht mehr.
- Zutatenstatistik zeigt Verbrauch und historische Kosten; fehlende Literpreise werden sichtbar markiert.
- Neue Hinweise für **beliebtesten Cocktail** und **beliebteste Größe**.
- Bei PayPal-Zubereitungen werden zusätzlich **Einnahmen** und **Einnahmen minus Zutatenkosten** angezeigt.
- Bestehende alte Statistikzähler bleiben erhalten; Detailauswertungen beginnen mit der V28-Historie.
- **PayPal-Standardpreise können jetzt pro aktivierter Größe** gepflegt werden – getrennt für Cocktails, alkoholfreie Cocktails und Shots.
- **Einzelpreise pro Cocktail sind ebenfalls größenabhängig**. Nur aktivierte Größen werden angezeigt.
- Auf der Cocktail-Detailseite ändert sich der angezeigte PayPal-Preis sofort mit der ausgewählten Größe.
- Das lokale Raspberry-PayPal-Backend ermittelt den Preis serverseitig aus **Rezept + Größe** und bleibt kompatibel zu alten Preisangaben.
- Bestehende V27-Einzelpreise werden beim Update automatisch auf die aktuell aktivierten Größen übernommen.

## V27 – Kompakte Füllstände & neue Warnschwellen (15.08.2026)

- **Füllstände** sind auf 1024×600 jetzt als responsives Raster aufgebaut; bei normaler Displaybreite stehen **3 Pumpen nebeneinander**.
- Füllstandskarten wurden kompakter gestaltet: Pumpennummer, Zutat, Prozent-Badge, Fortschrittsbalken, Behältergröße, aktueller Füllstand sowie Speichern/Auffüllen auf einer Karte.
- **Warnschwellen** komplett neu gestaltet: zwei klar getrennte Touch-Panels mit Symbol, aktuellem Grenzwert und Slider.
- Cocktailkarten-Warnung bleibt von 1–10 Restcocktails einstellbar; Füllstandswarnung bleibt in 5-%-Schritten von 5–90 % einstellbar.
- Auf schmaleren Displays fällt das Raster automatisch auf zwei bzw. eine Spalte zurück.

# V26 – Image-Build-Unterstützung

- `install.sh` unterstützt jetzt `--image-build` / `COCKTAILBOT_IMAGE_BUILD=1`.
- Im Image-Build werden CocktailBot-Dienst und Kiosk vorbereitet und aktiviert, aber nicht im Chroot gestartet.
- GPIO-Hardwaretests werden beim Offline-Image-Build übersprungen; auf dem echten Raspberry erkennt der Server `pinctrl-rp1` weiterhin dynamisch.
- Grundlage für reproduzierbare CocktailBot-Images für Raspberry Pi Imager.

# CocktailBot Changelog

## V25 – Raspberry Pi 5 GPIO-Autoerkennung nach Kernel-Updates

- Der Installer installiert jetzt `gpiod`, damit der reale GPIO-Chip über seinen Kernel-Namen erkannt werden kann.
- Auf Raspberry Pi 5 wird nicht mehr auf feste Nummern wie `gpiochip0`, `gpiochip4` oder `gpiochip15` vertraut. CocktailBot sucht bei jedem Serverstart nach **`pinctrl-rp1`** und verwendet dessen aktuelle `gpiochip`-Nummer.
- Damit wird der Fehler `lgpio.error: can not open gpiochip` nach Kernel-/Raspberry-Pi-OS-Updates abgefangen, wenn sich die Chipnummer des RP1 ändert.
- Die Korrektur erfolgt in CocktailBot selbst; die systemweite Datei von `python3-gpiozero` muss bei einer Neuinstallation nicht mehr manuell editiert werden.
- Neuer optionaler Installer-Schalter `--gpio-chip auto|NUMMER`; Standard ist `auto`.
- `tools/update.sh` übernimmt eine manuell gesetzte Chipnummer, falls ein Betreiber den Auto-Modus ausdrücklich überschrieben hat.
- Der Server protokolliert beim Start die tatsächlich verwendete GPIO-Chipnummer und die Erkennungsquelle.

## V24 – Branding entfernt & Rezept-Hinweise

- Der Branding-Bereich wurde vollständig aus den Einstellungen und aus der Liste der Gewerbefunktionen entfernt.
- Der sichtbare Produktname ist fest **CocktailBot** und kann nicht mehr durch einen Bar- oder Firmennamen ersetzt werden.
- In der 1024×600-Topnavigation wird **CocktailBot** jetzt dauerhaft neben dem Cocktail-Symbol angezeigt.
- Im Rezepteditor gibt es ein direkt sichtbares mehrzeiliges Feld **„Hinweise für die Zubereitung“**. Jede Zeile wird als eigener Hinweis gespeichert.
- Beispiele: „Frische Minze hinzufügen“, „Limettenstücke ins Glas geben“, „Mit Crushed Ice auffüllen“.
- Vorhandene Rezept-Hinweise bleiben kompatibel und werden beim Bearbeiten automatisch in das neue Textfeld übernommen.
- Die Hinweise werden auf der Cocktail-Detailseite unter **Hinweise** angezeigt.
- Der mitgelieferte Mojito enthält als Beispiel Hinweise für frische Minze und Limettenstücke.

## V23 – Partybestand und lernende Einkaufsliste

- Der Lagerbestand für die Partyplanung wird jetzt direkt in der **Einkaufsliste** gepflegt und nicht mehr aus den Pumpen-Füllständen abgeleitet.
- Pro benötigter Zutat kann ein Bestand in ml eingetragen und gespeichert werden. Das Feld darf leer bleiben; dann gilt der Bestand als unbekannt und der komplette geplante Bedarf wird als Einkaufsmenge ausgewiesen.
- Ein gespeicherter Bestand wird nach jeder erfolgreich zubereiteten Portion automatisch um die tatsächlich verwendete Rezeptmenge reduziert – auch bei manuellen Zutaten.
- Die Einkaufsliste zeigt pro Zutat **Bedarf**, **Bestand** und **Einkaufen** sowie die gesamte Einkaufsmenge.
- Partyplaner und Einkaufsliste zeigen jetzt deutlich den Hinweis, dass aussagekräftige Prognosen erst nach mehreren abgeschlossenen Partys mit derselben Partykarte entstehen.
- Der Partyplaner zeigt nur noch den geplanten Zutatenbedarf; Bestands- und Einkaufsberechnung findet ausschließlich in der Einkaufsliste statt.
- Neue sichtbare Texte wurden für alle vorhandenen App-Sprachen ergänzt.

## V22 – Einkaufsliste Navigation

- Der Menüpunkt **Einkaufsliste** öffnet nicht mehr versehentlich den Partyplaner.
- Neue eigenständige Einkaufsliste mit Partykarte, Gästezahl und Reserve.
- Zeigt geplanten Zutatenbedarf, vorhandene Mengen und fehlende Einkaufsmengen.
- Fehlende Zutaten werden in der Liste zuerst angezeigt.


## V21 – Raspberry-Dateibrowser für Rezeptbilder
- Rezeptbilder werden wieder über den nativen Chromium/Raspberry-Dateidialog ausgewählt.
- Ordner, USB-Sticks und andere eingebundene Laufwerke können im Dateidialog durchsucht werden.
- Die bisherige USB-Kachelansicht wird im Rezepteditor nicht mehr verwendet.
- Ausgewählte Bilder werden über den lokalen Raspberry-Dienst mit Pillow automatisch gedreht, auf maximal 1200 px verkleinert und als optimiertes JPEG übernommen.

## V20 – Black/Lime Standarddesign (2026-08-14)

- Neues Standarddesign **Standard / Benutzerdefiniert**.
- Standardfarben: Schwarz/Anthrazit mit Limegreen-Akzenten.
- Kein spezieller Hintergrund, keine Textur und kein Theme-Muster im Standarddesign.
- Hintergrund, Karten, Navigation, Akzente, Texte, Rahmen, Fortschritt und Statusfarben bleiben über Design/Farben frei einstellbar.
- Die sechs Spezialdesigns aus V19 bleiben zusätzlich auswählbar.
- „Standarddesign wiederherstellen“ setzt jetzt auf Black/Lime zurück.


## V19 – Vollständige Designwelten

- Die sechs Designs sind nicht mehr nur Farb-Presets, sondern vollständige visuelle Stile.
- **Edel / Exklusiv:** schwarzer Luxus-Hintergrund mit Goldglanz und feinen diagonalen Linien.
- **Modern / Clean:** heller Weiß-/Hellgrau-Verlauf mit dezenten blauen Flächen.
- **Futuristisch / Neon:** dunkler Navy-Hintergrund mit Cyan-/Magenta-Glow und Neon-Raster.
- **Tropisch / Sommer:** Türkis-/Sand-Verlauf mit Sonne, Wellen und abstrahierten Palmblättern.
- **Industrial / Loft:** dunkle Metallflächen mit Plattennähten, Nieten und technischer Struktur.
- **Vintage / Klassisch:** warmer Pergament-Hintergrund mit Papierkorn und klassischem Doppelrahmen.
- Der gewählte visuelle Stil wird jetzt zusammen mit den Farben gespeichert und bei vorhandenen V18-Presets automatisch erkannt.
- Globale fest eingebaute Türkis-Akzente in Cocktail-Detailseite, Kalibrierung, Rezeptverwaltung und weiteren Einstellungsbereichen wurden entfernt. Diese Elemente verwenden nun die Akzent-, Sekundär-, Warn- und Fehlerfarben des aktiven Designs.
- Navigationstext erhält automatisch eine zum Navigationshintergrund passende helle oder dunkle Kontrastfarbe.
- Cocktailkarten verwenden Rahmen und Kartenfarben des aktiven Designs.
- Material-Karten, Chips, Buttons, Eingabefelder, Fortschrittsanzeigen und AppBar reagieren stärker auf die aktive Designwelt.
- Statusfarben bleiben semantisch (Erfolg/Warnung/Fehler), stammen aber aus dem jeweiligen Theme.

## V18 – Neue Designkollektion

- Die bisherigen sechs Preset-Designs wurden vollständig aus der Auswahl entfernt.
- War auf einem bestehenden Gerät exakt eines der alten Presets aktiv, wird es beim Update automatisch auf das neue Standarddesign **Edel / Exklusiv** migriert; eigene manuelle Farbanpassungen bleiben erhalten.
- Neue Designkollektion: **Edel / Exklusiv**, **Modern / Clean**, **Futuristisch / Neon**, **Tropisch / Sommer**, **Industrial / Loft** und **Vintage / Klassisch**.
- Die Presets orientieren sich an den zuvor erstellten CocktailBot-Designvorschauen und verwenden jeweils eigene Hintergrund-, Karten-, Navigations-, Akzent-, Status- und Textfarben.
- Helle Presets verwenden nun automatisch ein helles Material-Farbschema; dunkle Presets ein dunkles. Dadurch bleiben Dialoge, Eingaben und Material-Komponenten besser lesbar.
- **Edel / Exklusiv** ist das neue Standarddesign bei Neuinstallation bzw. nach „Standarddesign wiederherstellen“.
- Designnamen werden über die Übersetzungslogik ausgegeben; bei Nicht-Deutsch steht mindestens eine englische Bezeichnung zur Verfügung.
- Die freie RGB-Farbanpassung bleibt zusätzlich erhalten.

## V17 – Manuelle Zutaten in der Cocktailkarte

- Zutaten, die im Rezept als **nicht automatisch / manuell** eingestellt sind, werden in der Cocktail-Detailkarte direkt gekennzeichnet.
- Neben der jeweiligen Zutat erscheint ein kompaktes orangefarbenes **„Manuell“**-Badge mit Hand-Symbol.
- Automatisch über Pumpen dosierte Zutaten bleiben unverändert ohne Badge.
- Die Kennzeichnung verwendet die vorhandene Übersetzung für „Manuell“ und funktioniert damit in allen App-Sprachen.


## V16 – Touchfreundlicher Bildimport vom USB-Stick

- Der native Chromium/Linux-Dateidialog wird beim Anlegen/Bearbeiten eigener Cocktails nicht mehr verwendet.
- Neuer CocktailBot-eigener USB-Bildbrowser als großes Touch-Popup mit Vorschaubildern.
- Unterstützt JPG, JPEG, PNG und WebP auf automatisch eingehängten USB-Sticks unter `/media/<user>` bzw. `/run/media/<user>`.
- Neu laden im Popup ermöglicht das Einstecken eines USB-Sticks, ohne die App zu verlassen.
- Bilder werden serverseitig gedreht, auf maximal 1200 px verkleinert und als JPEG optimiert, bevor sie in das Rezept übernommen werden.
- Neue lokale API: `GET /api/images/usb` und `GET /api/images/usb/file?id=...`.
- Pillow wird als Raspberry-Abhängigkeit installiert.


## V15 – Mehrfachauswahl bei Getränkegrößen (14.08.2026)

- Cocktailgrößen und Shotgrößen können in den Einstellungen jetzt unabhängig voneinander per Checkbox aktiviert oder deaktiviert werden.
- Mehrere Größen können gleichzeitig aktiv sein; nur die aktive Standardgröße muss immer freigegeben bleiben.
- Die Standardgröße wird weiterhin separat festgelegt und beim Öffnen eines Getränks vorausgewählt.
- Auf der Cocktail-Detailseite werden alle freigegebenen Größen direkt als Auswahlchips angezeigt, sodass der Nutzer ohne Dropdown zwischen den Größen wählen kann.
- Aktivierte Größen werden dauerhaft gespeichert; bestehende Installationen übernehmen beim ersten Start automatisch alle bisher vorhandenen Größen als aktiviert.
- Neue Größen werden beim Hinzufügen automatisch aktiviert und als neue Standardgröße gesetzt.
- Neue UI-Texte wurden für alle vorhandenen App-Sprachen ergänzt.

## V14 – Neuinstallation, Display/Kiosk und Cocktailkarten (14.08.2026)

- Der Installer übernimmt den auf dem realen LCD7C erfolgreich getesteten Zustand direkt bei der Neuinstallation: KMS (`vc4-kms-v3d`) und `video=HDMI-A-1:1024x600M@60`.
- Legacy-GoodTFT-HDMI-/Framebuffer-Zeilen werden robust per Python entfernt, einschließlich Varianten mit Leerzeichen statt `=`.
- DRM-Geräte `card0`, `card1` und `renderD128` werden entmaskiert.
- Grafischer Desktop, Desktop-Autologin, CocktailBot-Service und Kiosk-Autostart werden während derselben Installation eingerichtet.
- Pumpen-Bootschutz und Entfernen der seriellen GPIO-Konsole verwenden ebenfalls robuste Python-Verarbeitung statt komplexer `sed`-Ausdrücke.
- LOW-aktive Relais bleiben Standard und alle 18 Pumpen werden beim Boot auf den sicheren AUS-Pegel gesetzt.
- Herz-/Favoriten-Symbole wurden von Cocktail-Kacheln und Cocktail-Detailseite entfernt.


## V13 – Display/Desktop/Kiosk-Reparatur
- KMS/1024×600-Konfiguration ohne komplexe sed-Regex.
- Neues `tools/repair-display-kiosk.sh` repariert Bootauflösung, Desktop-Autologin, Kiosk-Autostart, Webrechte und Dienst nach einem abgebrochenen Installer.
- LOW-aktive Pumpen-Bootsicherheit bleibt erhalten.

## V12 – Desktop-/KMS-Installer-Fix (2026-08-14)

- Fehlerhaften mehrzeiligen `sed`-Ausdruck in der Display-/KMS-Konfiguration behoben.
- `config.txt`-Bereinigung verwendet jetzt einzelne `sed -e`-Regeln.
- `cmdline.txt`-Bereinigung verwendet ebenfalls einzelne robuste `sed -e`-Regeln.
- Dadurch läuft die Installation nach dem GoodTFT-LCD-Schritt weiter bis Desktop-Autologin, Pumpen-Bootschutz, Kiosk und Dienste.
- Für bereits installierten LCD-Treiber kann die Reparatur mit `--skip-lcd` fortgesetzt werden.

Dieses Dokument fasst die bisherigen Einzeldateien `CHANGES_*.md` zusammen. Der jeweils neueste Stand ist maßgeblich; zwischenzeitliche Lösungen, die später ersetzt wurden, sind entsprechend als überholt zusammengeführt.

## V11 – Pumpen-Bootschutz (14.08.2026)

- LOW-aktive Relais (`COCKTAILBOT_ACTIVE_HIGH=0`) sind der sichere Standard.
- Alle 18 Pumpen-GPIOs werden beim Installieren/Update bereits in `config.txt` auf den AUS-Pegel gesetzt.
- Bei LOW-aktiven Relais wird `op,dh`, bei `--active-high 1` automatisch `op,dl` verwendet.
- Die Pumpen-Sicherheitskonfiguration läuft auch bei `--skip-boot-opt`.
- GPIO15 ist für Pumpe 18 reserviert; die GPIO-UART-Konsole wird deaktiviert, damit Linux diesen Pin beim Boot nicht übernimmt.
- Der Pico 2 bleibt über USB-Serial angebunden.
- Der Raspberry-Dienst initialisiert alle Pumpenausgänge explizit als AUS.
- `tools/update.sh` übernimmt vorhandene Relaislogik und verwendet LOW-aktiv als sicheren Fallback.

Hinweis: Die allerersten Momente direkt nach dem Anlegen der Versorgung können rein softwareseitig nicht vollständig garantiert werden. Für absolut glitchfreie Leistungsfreigabe ist zusätzliche Hardware-Absicherung sinnvoll.

## V10 – Einstellbare Füllstandswarnungen (13.08.2026)

- Unter **Einstellungen → Füllstände** gibt es den Bereich **Warnschwellen**.
- Cocktailkarte: orange Warnung einstellbar von 1 bis 10 Restcocktails, Standard **2**.
- Füllstandsseite: orange Warnung einstellbar von 5 % bis 90 %, Standard **20 %**.
- Werte werden in `SharedPreferences` gespeichert.
- Rezept-Verfügbarkeit bleibt unabhängig von der Warnfarbe und wird weiterhin aus den tatsächlich benötigten Mengen berechnet.
- Neue Texte wurden in die vorhandene Übersetzungslogik aufgenommen.

## V9 – Übersetzungen (13.08.2026)

- Fehlende Übersetzungen in den Einstellungen ergänzt.
- Gewerbelizenz, PayPal-Kassenmodus, Cocktailpreise, Branding, Partykarten, Partyplaner, Einkaufsliste sowie Sicherheit/Freigaben lokalisiert.
- App-schließen-Dialog, Raspberry-Verbindungsstatus, Lizenzmeldungen, PayPal-Status, Zutaten-löschen-Dialoge, LED-Status und Pumpen-Fortschritt lokalisiert.
- Nicht übersetzte neue Texte fallen bei Nicht-Deutsch-Sprachen mindestens auf Englisch statt Deutsch zurück.

## V8 – PayPal und Zubereitungsfortschritt (13.08.2026)

### Fortschritt

- `makeRecipe()` wartet nicht mehr zuerst bis zum Ende des Pumpenjobs.
- Der Maschinenstatus wird während der Zubereitung ungefähr alle 180–200 ms abgefragt.
- Fortschritt, aktive Pumpen und Prozentanzeige werden live aktualisiert.
- Nach Abschluss springt die Anzeige sauber auf 100 %.

### PayPal

- Zahlungsstatus wird automatisch etwa alle 2 Sekunden geprüft.
- Überlappende Statusabfragen werden verhindert.
- Nach bestätigter Zahlung verschwindet der QR-Code.
- Stattdessen erscheint ein Erfolgsstatus mit **Cocktail zubereiten**.
- Erst beim Start der Zubereitung wird die Zahlung als verwendet markiert.

## V7 – LED-Firmware, nicht blockierende Effekte (13.08.2026)

- `RAINBOW` blockiert die USB-Serial-Verarbeitung nicht mehr.
- Ein `BLINK 255 0 0` kann Rainbow sofort unterbrechen.
- `PULSE`, `BLINK`, `BUSY` und `ERROR` laufen als nicht blockierende Zustandsmaschine.
- `BUSY` und `ERROR` funktionieren korrekt.
- Rainbow berücksichtigt die globale Helligkeit.
- Neue Befehle werden vor jedem Animationsframe verarbeitet.
- `STATUS` wurde als Diagnosebefehl ergänzt.

## V6 – Lizenzdatei-Import (13.08.2026)

- Der private Windows-Lizenzgenerator bleibt separat und unverändert nutzbar.
- Die vom Generator gespeicherte TXT-Datei kann direkt über **Einstellungen → Gewerbelizenz → Lizenzdatei importieren** ausgewählt werden.
- Die App liest den signierten `CBL1-...`-Code automatisch aus der Datei.
- Der Raspberry prüft Signatur und Hardware-Geräte-ID.
- Nur bei erfolgreicher Prüfung wird die Lizenz unter `/var/lib/cocktailbot/license.json` mit restriktiven Rechten gespeichert.
- Der Kunde muss keinen langen Lizenzcode manuell eintippen.

## V5 – Gerätegebundene Offline-Gewerbelizenz (13.08.2026)

- Kein externer Lizenzserver erforderlich.
- Geräte-ID basiert bevorzugt auf `rpi-machine-id`, mit Hardware-Seriennummer als Fallback.
- Aus der Hardwarekennung wird eine CocktailBot-Geräte-ID im Format `CB-XXXX-XXXX-XXXX-XXXX` erzeugt.
- Gewerbelizenzen werden mit Ed25519 signiert.
- Der private Schlüssel bleibt ausschließlich im separaten Lizenzgenerator.
- Auf dem Raspberry liegt nur der öffentliche Prüfschlüssel.
- Eine Lizenz für Raspberry A wird auf Raspberry B abgelehnt.
- Lizenzstatus und Aktivierung laufen über die lokale Raspberry-API.

## Zutatenverwaltung (13.08.2026)

- Zutaten können über einen Papierkorb-Button gelöscht werden.
- Vor dem Löschen erscheint eine Sicherheitsabfrage.
- Zutaten, die noch von Rezepten oder gespeicherten Cocktaillisten referenziert werden, können nicht gelöscht werden.
- Pumpenzuordnungen und Kalibrierungen werden beim zulässigen Löschen bereinigt.
- Verbrauchsdaten der gelöschten Zutat werden entfernt.

## Bildschirmtastatur (13.08.2026)

Die ursprüngliche Onboard-Lösung wurde durch eine eigene In-App-Popup-Tastatur ersetzt.

- Tippen auf ein editierbares Feld öffnet die CocktailBot-Tastatur.
- Zahlenfelder erhalten einen Nummernblock, Textfelder eine QWERTZ-Tastatur.
- Die Tastatur besitzt eine eigene Eingabevorschau, damit verdeckte Formularfelder trotzdem lesbar bleiben.
- Text und Cursor werden in einem eigenen lokalen Eingabepuffer verwaltet.
- Langsames Tippen überschreibt nicht mehr den vorherigen Buchstaben bzw. die vorherige Zahl.
- Das eigentliche Chromium-/Flutter-Eingabefeld wird während der Popup-Eingabe ent-fokussiert, damit Browser-Selektionen den Text nicht zurücksetzen.
- `TextInputFormatter` und `onChanged` bleiben berücksichtigt.
- Onboard bleibt höchstens als manuelle Fallback-Option vorhanden und wird nicht mehr automatisch von CocktailBot gestartet.

## Navigation und Cocktailkarte (13.08.2026)

- Die zwischenzeitliche feste linke Navigation wurde durch die endgültige **horizontale Top-Navigation** ersetzt.
- Auf Displays ab 760 px sitzt die Hauptnavigation fest oben als Kopfzeile von links nach rechts.
- Auf 1024×600 im Querformat nutzt der Inhalt darunter die volle Breite.
- Die Cocktail-Detailseite verwendet dieselbe Top-Navigation.
- Cocktailkarte im Querformat: Bild links, Details/Zutaten rechts.
- Cocktailbilder werden auf kleinen Displays mit `BoxFit.contain` dargestellt und nicht abgeschnitten.

## Installer und Raspberry-Kiosk (13.08.2026)

- GoodTFT `LCD7C-show` darf den Raspberry nicht dauerhaft auf Legacy-`fbdev` festlegen.
- `vc4-kms-v3d` wird nach der LCD-Treiberinstallation reaktiviert.
- Legacy-HDMI-/Framebuffer-Einstellungen werden entfernt.
- 1024×600 wird über `video=HDMI-A-1:1024x600M@60` festgelegt.
- Webdateien werden auf lesbare Rechte normalisiert (`0755` Verzeichnisse, `0644` Dateien), um Flask-500-Fehler zu vermeiden.
- CocktailBot-systemd verwendet `WorkingDirectory=/var/lib/cocktailbot` und `GPIOZERO_PIN_FACTORY=lgpio`.
- Chromium startet im Kioskmodus mit Touch-Unterstützung und bereinigtem Cache-/Service-Worker-Verhalten.
- Der Kiosk kann über **App schließen** beendet werden und landet anschließend auf dem Desktop.

## PayPal lokal auf dem Raspberry

- Cloudflare-/externes Backend wurde entfernt.
- PayPal Orders v2 läuft über den lokalen Python-Dienst auf dem Raspberry.
- Zugangsdaten liegen ausschließlich in `/etc/cocktailbot/paypal.env`.
- Lokale Endpunkte umfassen Status, Test, Konfiguration, Order-Erstellung, Order-Status und `mark-used`.
- Preise werden serverseitig validiert; Browserwerte werden nicht blind vertraut.
- Zahlungen werden lokal in SQLite nachverfolgt und nur einmal verwendet.

## Pico 2 LEDs

- Pico 2 steuert 240 WS2812B an GPIO0 über MicroPython und USB-Serial.
- Unterstützte Befehle umfassen `COLOR`, `OFF`, `READY`, `BUSY`, `ERROR`, `RAINBOW`, `PULSE`, `BLINK`, `BRIGHT` und `STATUS`.
- Ein fehlender Pico ist nicht kritisch für Pumpen/API-Betrieb.