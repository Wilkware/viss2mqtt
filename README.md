# viss2mqtt

Viessmann-OptoLink-Daten über [vcontrold](https://github.com/openv/vcontrold) nach MQTT.

viss2mqtt liest in regelmäßigen Abständen die Betriebsdaten einer Viessmann-Heizung (hier: **Vitotronic 150 KB1**, Device-ID `2092`, Protokoll `KW2`) über die OptoLink-Schnittstelle aus, prüft die Werte auf Plausibilität und veröffentlicht sie als **ein JSON-Objekt** auf einem MQTT-Topic. Abnehmer ist in meinem Fall der MQTT-Server in Symcon, grundsätzlich funktioniert aber jeder MQTT-Broker.

## Inhaltsverzeichnis

1. [Funktionsweise](#1-funktionsweise)
2. [Voraussetzungen](#2-voraussetzungen)
3. [Dateien im Repository](#3-dateien-im-repository)
4. [Installation](#4-installation)
5. [Konfiguration](#5-konfiguration)
6. [Ausgelesene Werte](#6-ausgelesene-werte)
7. [Plausibilitätsprüfung](#7-plausibilitätsprüfung)
8. [MQTT-Payload](#8-mqtt-payload)
9. [Einbindung in Symcon](#9-einbindung-in-symcon)
10. [Fehlersuche](#10-fehlersuche)
11. [Versionshistorie](#11-versionshistorie)

## 1. Funktionsweise

```text
Vitotronic ──OptoLink──> vcontrold ──TCP:3002──> vclient ──> viss2mqtt.sh (Python) ──MQTT──> Symcon
                         (Daemon)                  │
                                                   ├─ -f viss2mqtt.cmd   (welche Werte)
                                                   ├─ -t viss2mqtt.tpl   (Template)
                                                   └─ -x viss2mqtt.sh    (erzeugtes Skript, wird ausgeführt)
```

1. `vcontrold` läuft als Daemon und spricht über den OptoLink-Adapter (`/dev/ttyVITO`) mit der Heizungssteuerung.
2. Ein Cronjob ruft `vclient` auf. `vclient` arbeitet alle Befehle aus `viss2mqtt.cmd` ab.
3. Die Ergebnisse werden in das Template `viss2mqtt.tpl` eingesetzt. Daraus entsteht das Python-Skript `viss2mqtt.sh`, das `vclient` direkt im Anschluss ausführt.
4. Das Skript wandelt die Rohwerte in passende Typen um (Zahl, Bool, Text, Unix-Zeit), verwirft unplausible Werte und sendet das Ergebnis per MQTT.

Fehlende oder verworfene Werte werden einfach **nicht** mitgeschickt – der Empfänger behält dann den zuletzt gültigen Wert.

## 2. Voraussetzungen

- Viessmann-Heizung mit OptoLink-Schnittstelle (getestet: Vitotronic 150 KB1)
- OptoLink-Adapter (USB/seriell), z. B. per udev-Regel als `/dev/ttyVITO` eingebunden
- Linux-Rechner (z. B. Raspberry Pi) mit
  - [vcontrold / vclient](https://github.com/openv/vcontrold)
  - Python 3
  - [paho-mqtt](https://pypi.org/project/paho-mqtt/) **ab Version 2.0** (wegen `mqtt.CallbackAPIVersion.VERSION2`)
- Ein erreichbarer MQTT-Broker, z. B. die MQTT-Server-Instanz in Symcon

## 3. Dateien im Repository

| Datei | Beschreibung |
| ----- | ------------ |
| `viss2mqtt.cmd` | Liste der vclient-Befehle, ein Befehl pro Zeile. Die Reihenfolge bestimmt die Platzhalter-Nummern im Template. |
| `viss2mqtt.tpl` | vclient-Template, aus dem das Python-Skript erzeugt wird. Enthält MQTT-Konfiguration, Typumwandlung und Plausibilitätsprüfung. |
| `viss2mqtt.sh` | Von `vclient` **erzeugtes** Skript (Beispielausgabe). Wird bei jedem Lauf überschrieben – nicht von Hand bearbeiten. |
| `etc/vcontrold/vcontrold.xml` | Daemon-Konfiguration (TTY, Netzwerk, Logging, Units, Enums, Protokoll `KW2`). |
| `etc/vcontrold/vito.xml` | Bereinigte Gerätedefinition für die Vitotronic 150 KB1 (ID `2092`) – nur geprüfte Befehle, Schreibzugriff auf wenige unkritische Werte beschränkt. |

### vcontrold-Konfiguration im Überblick

**vcontrold.xml**

- Serielle Schnittstelle `/dev/ttyVITO` (udev-Symlink auf den OptoLink-Adapter)
- Der Daemon lauscht nur auf `localhost:3002` und erlaubt ausschließlich `127.0.0.1`. Läuft vclient auf einem anderen Rechner, `<listen>` entfernen und die IP per `<allow>` freigeben.
- Logging nach `/var/log/vcontrold/vcontrold.log` und zusätzlich ins Syslog
- Zusätzliche Units, die von `vito.xml` benötigt werden:
  - `UTS` – Temperatur 1 Byte, vorzeichenbehaftet (z. B. Frostgrenze −9 … 15 °C)
  - `CO1` – 1-Byte-Zähler (z. B. Zeitkonstante der Außentemperatur)
- Nur die Protokolle, die tatsächlich gebraucht werden; `GWG` ist entfernt

**vito.xml** – die Befehle sind nach Gruppen sortiert:

| Gruppe | Lesen | Schreiben |
| ------ | ----- | --------- |
| Gerät | Gerätetyp, Anlagenschema, Systemzeit | Systemzeit |
| Außentemperatur | aktuell, Tiefpass, gedämpft | – |
| Kessel | Ist, Tiefpass, Soll, Betriebszeit Standby | – |
| Brenner | Status, Status Stufe 2, Stufe, Starts, Stunden Stufe 1/2 | – |
| Warmwasser | Ist, Speicher, Soll, Speichervorrang | WW-Soll |
| Pumpen / Ventil | Heizkreispumpe M1/M2, Speicherladepumpe, Zirkulation, Umschaltventil | – |
| Betriebsarten | Betriebsart, Spar- und Partybetrieb (M1/M2) | Partybetrieb |
| Raumsoll | normal, reduziert, Party (M1/M2) | alle drei (M1/M2) |
| Extern / Frost / Störung | Extern Sperren/Anforderung, Frostwarnung, Sammelstörung, Fehlerhistorie | – |
| Konfiguration | Codieradressen K51, K90, A3, A5–A8, FA, FB | – |
| Schaltzeiten | Heizkreis M1/M2, Warmwasser, Zirkulation (Mo–So) | – |

## 4. Installation

### 4.1 vcontrold

vcontrold nach Anleitung des [openv-Projekts](https://github.com/openv/vcontrold) installieren, das Log-Verzeichnis anlegen und die beiden Konfigurationsdateien übernehmen:

```bash
sudo mkdir -p /var/log/vcontrold
sudo chown nobody:dialout /var/log/vcontrold
sudo cp etc/vcontrold/vcontrold.xml etc/vcontrold/vito.xml /etc/vcontrold/
sudo systemctl restart vcontrold
```

> `vito.xml` setzt die Units `UTS` und `CO1` voraus. Beide Dateien deshalb immer zusammen austauschen.

Test der Verbindung:

```bash
vclient -h localhost:3002 -c getTempA
```

### 4.2 viss2mqtt

```bash
sudo mkdir -p /opt/viss2mqtt
sudo cp viss2mqtt.cmd viss2mqtt.tpl /opt/viss2mqtt/
pip3 install "paho-mqtt>=2.0"
```

Das Verzeichnis `/opt/viss2mqtt` muss für den ausführenden Benutzer beschreibbar sein, da dort das erzeugte Skript und die Statusdatei `state.json` abgelegt werden.

Manueller Testlauf:

```bash
cd /opt/viss2mqtt
vclient -h localhost:3002 -f viss2mqtt.cmd -t viss2mqtt.tpl -x viss2mqtt.sh
```

### 4.3 Cronjob

Abfrage alle 5 Minuten (`crontab -e`):

```cron
*/5 * * * * cd /opt/viss2mqtt && vclient -h localhost:3002 -f viss2mqtt.cmd -t viss2mqtt.tpl -x viss2mqtt.sh >/dev/null 2>&1
```

## 5. Konfiguration

Die Einstellungen stehen am Anfang von `viss2mqtt.tpl`:

| Konstante | Standard | Beschreibung |
| --------- | -------- | ------------ |
| `MQTT_CLID` | `viss2mqtt` | Client-ID am Broker |
| `MQTT_SERV` | `192.168.13.3` | IP-Adresse des MQTT-Brokers (Symcon) |
| `MQTT_PORT` | `1883` | Port des MQTT-Brokers |
| `MQTT_KEEP` | `60` | Keep-Alive in Sekunden |
| `MQTT_TOPIC` | `viss2mqtt/vito` | Topic, auf dem das JSON veröffentlicht wird |
| `STATE_FILE` | `/opt/viss2mqtt/state.json` | Letzte gültige Zählerstände für die Plausibilitätsprüfung |

### Werte hinzufügen oder entfernen

1. Befehl in `viss2mqtt.cmd` ergänzen bzw. entfernen (der Befehl muss in `vito.xml` definiert sein).
2. Im `data`-Block von `viss2mqtt.tpl` den passenden Eintrag anlegen bzw. löschen.

**Wichtig:** Die Platzhalter sind über die Zeilennummer an `viss2mqtt.cmd` gebunden. Zeile *n* der Befehlsdatei entspricht `$Cn`, `$n` und `$Rn` im Template. Wird eine Zeile eingefügt oder gelöscht, müssen alle folgenden Nummern im Template angepasst werden.

| Platzhalter | Bedeutung |
| ----------- | --------- |
| `$Cn` | Name des *n*-ten Befehls (wird als JSON-Schlüssel verwendet) |
| `$n` | Zahlenwert des Ergebnisses |
| `$Rn` | Ergebnis als Text (Rohwert inkl. Fehlermeldungen) |

Alle Platzhalter stehen im Template in Anführungszeichen. Dadurch erzeugt ein fehlgeschlagener Befehl keinen Python-Syntaxfehler mehr, sondern der Wert wird beim Parsen verworfen.

### Hilfsfunktionen im Template

| Funktion | Zweck |
| -------- | ----- |
| `num(value, cast, lo, hi)` | Zahl parsen, optional mit Grenzwerten; sonst `None` |
| `counter(key, value, per_hour, slack)` | Zählerstand gegen den letzten gültigen Stand prüfen (siehe [Plausibilitätsprüfung](#7-plausibilitätsprüfung)) |
| `flag(value)` | `0`/`1` → `false`/`true` |
| `txt(value)` | Text übernehmen, Fehlermeldungen (`ERR`, `NOT OK`, …) verwerfen |
| `ts(value)` | ISO-Zeitstempel der Heizung → Unix-Zeit |

## 6. Ausgelesene Werte

| Nr. | Befehl | Typ | Gültiger Bereich | Beschreibung |
| --: | ------ | --- | ---------------- | ------------ |
| 1 | `getTempA` | float | −40 … 60 °C | Außentemperatur |
| 2 | `getTempAtp` | float | −40 … 60 °C | Außentemperatur, tiefpassgefiltert |
| 3 | `getTempAged` | float | −40 … 60 °C | Außentemperatur, gedämpft |
| 4 | `getTempWWist` | float | 5 … 100 °C | Warmwasser-Isttemperatur |
| 5 | `getTempWWsoll` | float | 5 … 100 °C | Warmwasser-Solltemperatur |
| 6 | `getTempKist` | float | 5 … 110 °C | Kessel-Isttemperatur |
| 7 | `getTempKtp` | float | 5 … 110 °C | Kesseltemperatur, tiefpassgefiltert |
| 8 | `getTempKsoll` | float | 5 … 110 °C | Kessel-Solltemperatur |
| 9 | `getBrennerStatus` | bool | – | Brenner an/aus |
| 10 | `getBrennerStufe` | int | 0 … 2 | Brennerstufe |
| 11 | `getBrennerStarts` | int | Zähler, max. 30/h | Brennerstarts |
| 12 | `getBrennerStunden1` | float | Zähler, max. 1 h/h | Betriebsstunden Stufe 1 |
| 13 | `getBrennerStunden2` | float | Zähler, max. 1 h/h | Betriebsstunden Stufe 2 |
| 14 | `getTempStp` | float | 5 … 100 °C | Speichertemperatur |
| 15 | `getTempRaumNorSollM1` | float | 3 … 40 °C | Raum-Solltemperatur normal (Heizkreis 1) |
| 16 | `getTempRaumRedSollM1` | float | 3 … 40 °C | Raum-Solltemperatur reduziert (Heizkreis 1) |
| 17 | `getPumpeStatusM1` | int | – | Heizkreispumpe Heizkreis 1 |
| 18 | `getPumpeStatusSp` | int | – | Speicherladepumpe |
| 19 | `getPumpeStatusZirku` | int | – | Zirkulationspumpe |
| 20 | `getBetriebArt` | string | – | Betriebsart |
| 21 | `getStatusFrostM1` | int | – | Frostschutz Heizkreis 1 |
| 22 | `getSystemTime` | int | – | Systemzeit der Heizung (Unix-Zeit) |
| 23 | `getDaempfung` | float | – | Dämpfung |
| 24 | `getStatusStoerung` | int | – | Sammelstörung |
| 25–34 | `getError0` … `getError9` | string | – | Fehlerhistorie (Zeitstempel + Fehlertext) |

## 7. Plausibilitätsprüfung

Über die OptoLink-Schnittstelle kommen gelegentlich unmögliche Werte an, etwa `128.5` °C als Fehlerwert des Außenfühlers oder Bitfehler bei Zählern (z. B. `242012` statt `45404` Brennerstarts). Solche Werte würden in Symcon Archiv und Diagramme verfälschen und werden deshalb schon vor dem Versand verworfen.

**Messwerte** werden gegen feste Grenzen geprüft (siehe Tabelle oben). Werte außerhalb des Bereichs fehlen im Payload.

**Zählerstände** (Brennerstarts, Betriebsstunden) werden gegen den letzten akzeptierten Stand aus `state.json` geprüft:

- Ein Zähler darf nicht sinken.
- Er darf nicht schneller steigen als `per_hour × vergangene Stunden + slack`.
- Liefert die Heizung **zweimal hintereinander** einen konsistenten Wert auf einem neuen Niveau (z. B. nach einem Reglertausch), wird dieser als neue Basis übernommen.

Ist `state.json` nicht vorhanden oder nicht lesbar, beginnt die Prüfung beim nächsten Lauf von vorn; der erste Wert wird dann ungeprüft übernommen.

## 8. MQTT-Payload

Topic: `viss2mqtt/vito` (QoS 0, nicht retained)

```json
{
  "getTempA": 14.5,
  "getTempAtp": 14.5,
  "getTempAged": 14.5,
  "getTempWWist": 49.1,
  "getTempWWsoll": 45.0,
  "getTempKist": 31.4,
  "getTempKtp": 31.4,
  "getTempKsoll": 7.0,
  "getBrennerStatus": false,
  "getBrennerStufe": 0,
  "getBrennerStarts": 45404,
  "getBrennerStunden1": 22883.79,
  "getBrennerStunden2": 6.96,
  "getTempStp": 49.1,
  "getTempRaumNorSollM1": 22.0,
  "getTempRaumRedSollM1": 3.0,
  "getPumpeStatusM1": 0,
  "getPumpeStatusSp": 0,
  "getPumpeStatusZirku": 1,
  "getBetriebArt": "WW",
  "getStatusFrostM1": 1,
  "getSystemTime": 1791564637,
  "getDaempfung": 128.0,
  "getStatusStoerung": 0,
  "getError0": "2023-08-11T10:48:32+0200 Brennerstoerung (D1)",
  "getError1": "2023-08-11T07:49:20+0200 Brennerstoerung (D1)"
}
```

Liefert vcontrold überhaupt keinen Wert (z. B. Daemon nicht erreichbar), wird nichts gesendet und das Skript beendet sich mit einer Fehlermeldung.

## 9. Einbindung in Symcon

1. In Symcon eine **MQTT Server**-Instanz anlegen (bzw. eine vorhandene verwenden) und den Port `1883` freigeben.
2. Eine **MQTT Client Device**-Instanz (oder ein eigenes Modul/Skript) auf das Topic `viss2mqtt/vito` abonnieren.
3. Das empfangene JSON dekodieren und die einzelnen Schlüssel auf Variablen verteilen.

Da fehlende Werte nicht übertragen werden, sollte die Auswertung nur die tatsächlich vorhandenen Schlüssel aktualisieren – so bleiben die letzten gültigen Werte erhalten.

## 10. Fehlersuche

| Problem | Mögliche Ursache / Lösung |
| ------- | ------------------------- |
| Es kommt nichts in Symcon an | `vclient` manuell ausführen (siehe 4.2) und Ausgabe prüfen; Broker-IP und Port in `viss2mqtt.tpl` kontrollieren. |
| `no values received from vcontrold` | vcontrold läuft nicht, falscher Port oder OptoLink-Adapter nicht verbunden (`/dev/ttyVITO`). |
| Einzelne Werte fehlen dauerhaft | Befehl liefert Fehler oder liegt außerhalb der Grenzen – mit `vclient -c <Befehl>` gegenprüfen. |
| Werte landen unter falschem Namen | Reihenfolge in `viss2mqtt.cmd` und Nummern im Template passen nicht zusammen. |
| `AttributeError: CallbackAPIVersion` | paho-mqtt ist älter als 2.0 – aktualisieren. |
| Zähler werden nicht mehr aktualisiert | Nach einem Sprung wird der neue Stand erst beim zweiten konsistenten Wert übernommen; ggf. `state.json` löschen. |

## 11. Versionshistorie

Siehe [CHANGELOG.md](CHANGELOG.md).
