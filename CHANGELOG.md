# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden in dieser Datei dokumentiert.

Das Format basiert auf [Keep a Changelog](https://keepachangelog.com/de/1.1.0/),
die Versionierung folgt [Semantic Versioning](https://semver.org/lang/de/).

## [Unreleased]

## [2.1.2] - 2026-10-23

### Behoben

- Neustart-Hinweis für vcontrold (`deploy.sh`, README): `stop`, 3 s warten, `start` statt `systemctl restart`. Bei `restart` brach der neue Prozess sofort mit `status=1` ab, weil Port/TTY noch belegt waren, und systemd startete erst 2 Minuten später erneut

## [2.1.1] - 2026-10-23

### Behoben

- `install.sh` fragte nach dem sudo-Passwort, obwohl sudo ohne Passwort erlaubt ist (`sudo -v` verlangt es, sobald nicht alle sudoers-Regeln `NOPASSWD` haben). Jetzt wird zuerst `sudo -n` versucht

## [2.1.0] - 2026-10-23

Der Git-Checkout liegt direkt in `/opt/viss2mqtt` und ist zugleich das Laufzeitverzeichnis. Pfade in Cron und Templates bleiben unverändert.

### Hinzugefügt

- `.gitignore` für die auf dem Vito-Rechner erzeugten Dateien (`viss2mqtt.sh`, `viss2mqtt-fast.sh`, Logs, `state.json`, Lock)
- `install.sh --state DATEI`; ohne Angabe übernimmt `install.sh` `state.json` automatisch aus der neuesten Sicherung `/opt/viss2mqtt.bak-*`
- README: Umstellung einer älteren Installation (alte Jobs stoppen, Ordner sichern, neu klonen)

### Geändert

- `deploy.sh`: kein Kopieren von `.lst`/`.tpl` mehr. `git pull` läuft unter dem Lock der Cronjobs; schlägt die Prüfung danach fehl, wird der Checkout auf den vorherigen Stand zurückgesetzt
- `deploy.sh`, `install.sh`: brechen ab, wenn sie nicht aus `/opt/viss2mqtt` gestartet werden
- Beispielskript `viss2mqtt.sh` nach `examples/viss2mqtt.sh` verschoben, damit die bei jedem Lauf erzeugte Datei `git pull` nicht blockiert

## [2.0.0] - 2026-10-23

Verteilung per Git und Betrieb als normaler Benutzer statt root.

**Umstellung nötig:** Cronjobs, Benutzer und Lock-Pfad ändern sich. Eine bestehende Installation wird einmalig mit `./install.sh` umgestellt (siehe README, Abschnitt 4.2). Topic, Schlüssel und Datentypen des MQTT-Payloads bleiben unverändert, in Symcon ist nichts anzupassen.

### Hinzugefügt

- `install.sh`: einmalige Einrichtung bzw. Umstellung einer root-Installation. Entfernt alte viss2mqtt-Einträge aus den Crontabs von root und Benutzer (mit Sicherung), übergibt `/opt/viss2mqtt` samt `state.json` dem Benutzer, räumt das alte Lock auf, legt `/var/log/vcontrold` an und ruft `deploy.sh` auf
- `deploy.sh`: holt Updates per `git pull --ff-only`, prüft und verteilt alle Dateien auf dem Vito-Rechner
  - Prüfungen vor dem Verteilen: CRLF, Zeilenumbruch nach dem letzten Befehl, Anzahl Befehle gleich Anzahl Platzhalter im Template, jeder Befehl in `vito.xml` definiert, gültiges XML
  - `.lst`/`.tpl` nach `/opt/viss2mqtt/` unter dem gemeinsamen Lock, nur geänderte Dateien
  - vcontrold-Konfiguration nach `/etc/vcontrold/` mit `.bak`; Neustart nur als Hinweis
  - `viss2mqtt.cron` nach `/etc/cron.d/viss2mqtt`, Warnung bei doppelten Einträgen in alten Crontabs
  - Testlauf des Schnelllaufs, Optionen `--dry-run`, `--no-pull`, `--no-test`
- README: Aufbau auf dem Vito-Rechner, Erstinstallation und Updates mit den Skripten, weitere Fehlerbilder
- README: Badges (Python, Version, Lizenz, Spende) wie bei den anderen *2mqtt-Projekten
- `LICENSE`: MIT-Lizenz

### Geändert

- Cronjobs laufen als normaler Benutzer statt als root: `viss2mqtt.cron` ist jetzt eine Datei für `/etc/cron.d` mit Benutzerfeld `@USER@`, `SHELL` und `PATH`
- Lock von `/tmp/vito.lock` nach `/opt/viss2mqtt/vito.lock` verlegt (Cron, Templates, README). Die alte Datei in `/tmp` gehört root und lässt sich von anderen Benutzern nicht verlässlich öffnen
- `.gitattributes`: LF auch für `*.sh`, `*.tpl`, `*.cron` und `*.xml`

## [1.2.0] - 2026-10-23

Schnelllauf jede Minute und Abgleich mit den Erkenntnissen aus dem Betrieb.

### Hinzugefügt

- Schnelllauf `viss2mqtt-fast.lst` / `viss2mqtt-fast.tpl`: Brennerstatus, Brennerstarts, Außen-, Kessel- und Warmwassertemperatur jede Minute. Gleiches Topic, gleiche Typen und dieselbe Plausibilitätsprüfung wie der volle Lauf, gemeinsame `state.json`
- `viss2mqtt.cron`: Crontab-Einträge für beide Läufe mit gemeinsamem Lock (`flock /tmp/vito.lock`), damit nie zwei vclient-Läufe gleichzeitig auf vcontrold zugreifen
- `.gitattributes` und `.editorconfig`: `.lst`-Dateien immer mit LF, Dateiende und Leerzeichen am Zeilenende bleiben erhalten
- README: Schnelllauf, Aufbau mit zwei Rechnern, Abschnitt „Stolperfallen“ (u. a. Typwechsel im JSON, `<allow>`/IPv6, Dateiende der Befehlsliste, Cron-PATH) und erweiterte Fehlersuche

### Geändert

- **Befehlslisten umbenannt:** `viss2mqtt.cmd` → `viss2mqtt.lst`. Die Endung `.cmd` steht unter Windows für Batch-Dateien und wurde deshalb beim Download blockiert bzw. beim Doppelklick ausgeführt. Auf dem Vito-Rechner Dateien umbenennen und Crontab anpassen
- Cron: `vclient` mit absolutem Pfad (`/usr/local/bin/vclient`), Ausgabe in `viss2mqtt.log` bzw. `viss2mqtt-fast.log`, Jobs laufen als root
- `vcontrold.xml`: `<syslog>n</syslog>`, weil `y` die Startmeldung als Broadcast an alle Terminals schickt
- `vcontrold.xml`: Netzwerk-Kommentar korrigiert – vcontrold läuft auf einem eigenen Rechner, Symcon erhält die Daten nur per MQTT
- Templates: Aufruf im Kopfkommentar mit `flock` und absolutem Pfad, Verweis auf `viss2mqtt.cron`

### Behoben

- `vcontrold.xml`: `<allow ip="127.0.0.1"/>` entfernt. Zusammen mit `<listen>localhost</listen>` wurde IPv6 `::1` abgewiesen („timeout wait:vctrld>“)
- `viss2mqtt-fast.tpl`: Verweis auf die nicht vorhandene Datei `viss2mqtt-fast.cron`

### Entfernt

- `vito.xml`: Testbefehl `get` – ohne `<unit>` wird er von vcontrold ignoriert („command unknown“)

## [1.1.0] - 2026-10-10

Überarbeitete vcontrold-Konfiguration für die Vitotronic 150 KB1.

### Hinzugefügt

- `vcontrold.xml`: Units `UTS` (Temperatur 1 Byte, vorzeichenbehaftet) und `CO1` (1-Byte-Zähler)
- `vcontrold.xml`: Gerätetyp `20 92` (V150KB1) in der Unit `DeviceType`
- `vito.xml`: neue Lesebefehle, u. a. Anlagenschema, Umschaltventil, Spar-/Partybetrieb, Party-Solltemperaturen, Extern Sperren/Anforderung, Frostgrenze (A3), weitere Codieradressen (K51, A5–A8, FA, FB) sowie alle Schaltzeiten für M1, M2, Warmwasser und Zirkulation
- README: Übersicht der vcontrold-Konfiguration und Anlegen des Log-Verzeichnisses

### Geändert

- `vcontrold.xml`: Daemon lauscht nur noch auf `localhost`, Zugriff nur von `127.0.0.1`
- `vcontrold.xml`: Log nach `/var/log/vcontrold/vcontrold.log`, zusätzlich Syslog
- `vito.xml`: komplett neu strukturiert und nach Gruppen sortiert (Gerät, Außentemperatur, Kessel, Brenner, Warmwasser, Pumpen, Betriebsarten, Raumsoll, Störungen, Konfiguration, Schaltzeiten)
- `getBrennerStatus`: Adresse `55D3` (lieferte immer 255) → `0842` – liefert jetzt 0/1 synchron zur Brennerstufe
- `getBrennerStufe`: Unit `ST` statt `RT`, liefert die Stufe 0/1/2 als Zahl
- `getDaempfung`: Unit `CO1` (1 Byte) statt `CO` (4 Byte)
- `viss2mqtt.sh`: Beispielausgabe mit dem aktuellen Template und der neuen vcontrold-Konfiguration erzeugt (Stand 10.10.2026, enthält u. a. den Fühlerfehlerwert `128.5` bei `getTempA`, der von der Plausibilitätsprüfung verworfen wird)

### Behoben

- `setTempWWsoll`: Länge 2 → 1 Byte, vorher wurde dabei auch Adresse `0x6301` überschrieben
- Unit `BrennerStoerung`: doppelter Eintrag für `08`, fehlender Eintrag für `09`
- Fehlercode `28`: „Unterbrechung Vorlauftemperatursensor“ statt „Aussentemperatursensor“
- Tippfehler „Flammensigal“ → „Flammensignal“ (Codes `F3`, `F4`)
- Einheitliche Anführungszeichen in den Enum-Definitionen, Umlaute im Fehlertext `9E` ersetzt

### Entfernt

- `vcontrold.xml`: Protokoll `GWG` (wird von der KB1 nicht verwendet)
- `vito.xml`: Befehle ohne `addr`/`len`/`unit` und reine GWG-Testbefehle
- `vito.xml`: Schreibbefehle auf Zähler, Codieradressen, Umschaltventil und Pumpen
- `vito.xml`: doppelte bzw. irreführende Befehle (z. B. „Drehzahl“, die tatsächlich den Pumpenstatus `3906` liefert)

## [1.0.0] - 2026-10-10

### Hinzugefügt

- `viss2mqtt.cmd`: Befehlsliste für vclient mit 34 Werten der Vitotronic 150 KB1 (Temperaturen, Brenner, Pumpen, Betriebsart, Systemzeit, Störstatus, Fehlerhistorie)
- `viss2mqtt.tpl`: vclient-Template, das ein Python-Skript erzeugt und alle Werte als ein JSON-Objekt auf `viss2mqtt/vito` veröffentlicht
- Typumwandlung der Rohwerte (Zahl, Bool, Text, Unix-Zeit)
- Plausibilitätsprüfung: Messwerte außerhalb fester Grenzen werden verworfen (z. B. `128.5` °C als Fehlerwert des Außenfühlers)
- Zählerprüfung für Brennerstarts und Betriebsstunden gegen den letzten gültigen Stand (`state.json`), inklusive Übernahme eines neuen Niveaus nach zwei konsistenten Werten
- Fehlertolerantes Template: alle Platzhalter in Anführungszeichen, fehlgeschlagene Befehle führen nicht mehr zu Syntaxfehlern, sondern werden weggelassen
- Kein Versand, wenn vcontrold keinerlei Werte liefert
- Unterstützung für paho-mqtt 2.x (`CallbackAPIVersion.VERSION2`), Warten auf Zustellung vor dem Disconnect
- `viss2mqtt.sh`: Beispiel eines von vclient erzeugten Skripts
- `etc/vcontrold/`: ursprüngliche Initialversionen von `vcontrold.xml` und `vito.xml` (Device-ID `2092`, Protokoll `KW2`)
- Ausführliche README

[Unreleased]: https://github.com/Wilkware/viss2mqtt/compare/v2.1.2-patch...HEAD
[2.1.2]: https://github.com/Wilkware/viss2mqtt/compare/v2.1.1-patch...v2.1.2-patch
[2.1.1]: https://github.com/Wilkware/viss2mqtt/compare/v2.1.0-feature...v2.1.1-patch
[2.1.0]: https://github.com/Wilkware/viss2mqtt/compare/v2.0.0-release...v2.1.0-feature
[2.0.0]: https://github.com/Wilkware/viss2mqtt/compare/v1.2.0-feature...v2.0.0-release
[1.2.0]: https://github.com/Wilkware/viss2mqtt/compare/v1.1.0-feature...v1.2.0-feature
[1.1.0]: https://github.com/Wilkware/viss2mqtt/compare/v1.0.0-release...v1.1.0-feature
[1.0.0]: https://github.com/Wilkware/viss2mqtt/releases/tag/v1.0.0-release
