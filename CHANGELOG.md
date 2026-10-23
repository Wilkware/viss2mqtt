# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden in dieser Datei dokumentiert.

Das Format basiert auf [Keep a Changelog](https://keepachangelog.com/de/1.1.0/),
die Versionierung folgt [Semantic Versioning](https://semver.org/lang/de/).

## [Unreleased]

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

[Unreleased]: https://github.com/Wilkware/viss2mqtt/compare/v1.2.0-feature...HEAD
[1.2.0]: https://github.com/Wilkware/viss2mqtt/compare/v1.1.0-feature...v1.2.0-feature
[1.1.0]: https://github.com/Wilkware/viss2mqtt/compare/v1.0.0-release...v1.1.0-feature
[1.0.0]: https://github.com/Wilkware/viss2mqtt/releases/tag/v1.0.0-release
