# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden in dieser Datei dokumentiert.

Das Format basiert auf [Keep a Changelog](https://keepachangelog.com/de/1.1.0/),
die Versionierung folgt [Semantic Versioning](https://semver.org/lang/de/).

## [Unreleased]

### Geändert

- Überarbeitete vcontrold-Konfiguration (`etc/vcontrold/vcontrold.xml`, `etc/vcontrold/vito.xml`)

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

[Unreleased]: https://github.com/Wilkware/viss2mqtt/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Wilkware/viss2mqtt/releases/tag/v1.0.0
