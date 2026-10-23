# viss2mqtt

Viessmann-OptoLink-Daten über [vcontrold](https://github.com/openv/vcontrold) nach MQTT.

viss2mqtt liest in regelmäßigen Abständen die Betriebsdaten einer Viessmann-Heizung (hier: **Vitotronic 150 KB1**, Device-ID `2092`, Protokoll `KW2`) über die OptoLink-Schnittstelle aus, prüft die Werte auf Plausibilität und veröffentlicht sie als **ein JSON-Objekt** auf einem MQTT-Topic. Abnehmer ist in meinem Fall der MQTT-Server in Symcon, grundsätzlich funktioniert aber jeder MQTT-Broker.

Es gibt zwei Abfragen, die sich per Lock abwechseln:

- **Voller Lauf** alle 5 Minuten mit allen 34 Werten
- **Schnelllauf** jede Minute mit 5 Werten (Brennerstatus, Brennerstarts, Außen-, Kessel- und Warmwassertemperatur)

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
10. [Stolperfallen](#10-stolperfallen)
11. [Fehlersuche](#11-fehlersuche)
12. [Versionshistorie](#12-versionshistorie)

## 1. Funktionsweise

```text
┌──────────────── Vito-Rechner (z. B. Raspberry Pi) ─────────────────┐
│                                                                    │
│ Vitotronic ──OptoLink──> vcontrold ──localhost:3002──> vclient     │          ┌──────────────┐
│  150 KB1   /dev/ttyVITO  (Daemon)                        │         │          │   Symcon     │
│                                                          ▼         │   MQTT   │ MQTT Server  │
│                           viss2mqtt.lst + .tpl ──> viss2mqtt.sh ───┼─────────>│  → Device    │
│                           (cron, flock)            (Python)        │  :1883   │              │
└────────────────────────────────────────────────────────────────────┘          └──────────────┘
```

vcontrold und vclient laufen auf einem eigenen Rechner an der Heizung. Symcon läuft auf einem anderen Rechner und bekommt die Daten **nur per MQTT**. Symcon greift nicht direkt auf vcontrold zu, deshalb lauscht vcontrold nur auf `localhost`.

1. `vcontrold` läuft als Daemon und spricht über den OptoLink-Adapter (`/dev/ttyVITO`) mit der Heizungssteuerung.
2. Ein Cronjob ruft `vclient` auf. `vclient` arbeitet alle Befehle aus der `.lst`-Datei ab.
3. Die Ergebnisse werden in das zugehörige Template (`.tpl`) eingesetzt. Daraus entsteht ein Python-Skript (`.sh`), das `vclient` direkt im Anschluss ausführt.
4. Das Skript wandelt die Rohwerte in passende Typen um (Zahl, Bool, Text, Unix-Zeit), verwirft unplausible Werte und sendet das Ergebnis per MQTT.

Fehlende oder verworfene Werte werden einfach **nicht** mitgeschickt – der Empfänger behält dann den zuletzt gültigen Wert.

### Voller Lauf und Schnelllauf

| | Voller Lauf | Schnelllauf |
| --- | --- | --- |
| Intervall | alle 5 min (:00, :05, …) | jede Minute |
| Dateien | `viss2mqtt.lst` / `.tpl` / `.sh` | `viss2mqtt-fast.lst` / `.tpl` / `.sh` |
| Befehle | 34 | 5 |
| Dauer | ca. 75 s | ca. 10 s |
| Lock-Wartezeit | bis 60 s | bis 30 s |
| MQTT-Client-ID | `viss2mqtt` | `viss2mqtt-fast` |

Beide Läufe senden auf **dasselbe Topic** mit **denselben Schlüsseln und Typen** und verwenden dieselbe Plausibilitätsprüfung. Die Zählerprüfung der Brennerstarts nutzt dieselbe `state.json` mit dem Schlüssel `starts`. Über das gemeinsame Lock `/tmp/vito.lock` (`flock`) greifen nie zwei Läufe gleichzeitig auf vcontrold zu. Fällt ein Schnelllauf in einen vollen Lauf, wartet er und läuft direkt danach.

## 2. Voraussetzungen

- Viessmann-Heizung mit OptoLink-Schnittstelle (getestet: Vitotronic 150 KB1)
- OptoLink-Adapter (USB/seriell), z. B. per udev-Regel als `/dev/ttyVITO` eingebunden
- Linux-Rechner (z. B. Raspberry Pi) mit
  - [vcontrold / vclient](https://github.com/openv/vcontrold) (hier unter `/usr/local/sbin/vcontrold` und `/usr/local/bin/vclient`)
  - `flock` (Paket `util-linux`, meist vorinstalliert)
  - Python 3
  - [paho-mqtt](https://pypi.org/project/paho-mqtt/) **ab Version 2.0** (wegen `mqtt.CallbackAPIVersion.VERSION2`)
- Ein über das Netz erreichbarer MQTT-Broker, z. B. die MQTT-Server-Instanz in Symcon

## 3. Dateien im Repository

| Datei | Beschreibung |
| ----- | ------------ |
| `viss2mqtt.lst` | Befehlsliste des vollen Laufs (für `vclient -f`), ein Befehl pro Zeile. Die Reihenfolge bestimmt die Platzhalter-Nummern im Template. |
| `viss2mqtt.tpl` | Template des vollen Laufs. Enthält MQTT-Konfiguration, Typumwandlung und Plausibilitätsprüfung. |
| `viss2mqtt.sh` | Von `vclient` **erzeugtes** Skript (Beispielausgabe). Wird bei jedem Lauf überschrieben – nicht von Hand bearbeiten. |
| `viss2mqtt-fast.lst` | Befehlsliste des Schnelllaufs (5 Befehle). |
| `viss2mqtt-fast.tpl` | Template des Schnelllaufs, gleiche Prüfungen und Typen wie `viss2mqtt.tpl`. |
| `viss2mqtt.cron` | Crontab-Einträge für beide Läufe, inklusive Lock. |
| `.gitattributes`, `.editorconfig` | Schützen Zeilenenden und Dateiende der `.lst`-Dateien. |
| `etc/vcontrold/vcontrold.xml` | Daemon-Konfiguration (TTY, Netzwerk, Logging, Units, Enums, Protokoll `KW2`). |
| `etc/vcontrold/vito.xml` | Bereinigte Gerätedefinition für die Vitotronic 150 KB1 (ID `2092`) – nur geprüfte Befehle, Schreibzugriff auf wenige unkritische Werte beschränkt. |

> Die `.lst`-Dateien enden mit einem Zeilenumbruch und danach einer Zeile aus einem einzelnen Leerzeichen. Dieses Dateiende nicht entfernen. `.gitattributes` sorgt für LF-Zeilenenden, `.editorconfig` verhindert, dass Editoren das Dateiende oder das Leerzeichen verändern.

### vcontrold-Konfiguration im Überblick

**vcontrold.xml**

- Serielle Schnittstelle `/dev/ttyVITO` (udev-Symlink auf den OptoLink-Adapter)
- Der Daemon lauscht nur auf `localhost:3002`, ein `<allow>` ist dafür nicht nötig. Für einen direkten Zugriff von einem anderen Rechner `<listen>` entfernen und dessen IP per `<allow ip="…"/>` freigeben.
- Logging nach `/var/log/vcontrold/vcontrold.log`, kein Syslog
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

`getBrennerStatus` liest Adresse `0842`. Die früher verwendete Adresse `55D3` liefert auf der KB1 immer `255`. `getBetriebszeitStandby` und `getBrennerStatus2` (`0849`, immer `0`) sind zwar definiert, werden aber nicht abgefragt.

## 4. Installation

Alle Schritte auf dem Vito-Rechner ausführen.

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
flock -w 30 /tmp/vito.lock /usr/local/bin/vclient -h localhost:3002 -c getTempA
```

### 4.2 viss2mqtt

```bash
sudo mkdir -p /opt/viss2mqtt
sudo cp viss2mqtt.lst viss2mqtt.tpl viss2mqtt-fast.lst viss2mqtt-fast.tpl /opt/viss2mqtt/
sudo pip3 install "paho-mqtt>=2.0"
```

Die Jobs laufen als root. In `/opt/viss2mqtt` werden die erzeugten Skripte, die Logs und die Statusdatei `state.json` abgelegt.

> Nach dem Übertragen das Dateiende der `.lst`-Dateien prüfen (siehe [Stolperfallen](#10-stolperfallen)).

Manueller Testlauf:

```bash
sudo flock -w 30 /tmp/vito.lock /usr/local/bin/vclient -v -f /opt/viss2mqtt/viss2mqtt-fast.lst -t /opt/viss2mqtt/viss2mqtt-fast.tpl -x /opt/viss2mqtt/viss2mqtt-fast.sh
```

Die Ausgabe `exit with count=0` ist bei `-f` normal. Entscheidend ist, dass im erzeugten `.sh` die Werte eingesetzt sind. Das erzeugte Skript lässt sich auch einzeln starten:

```bash
sudo python3 /opt/viss2mqtt/viss2mqtt-fast.sh
```

### 4.3 Cronjobs

Die Einträge aus [viss2mqtt.cron](viss2mqtt.cron) in die Crontab von root übernehmen (`sudo crontab -e`):

```cron
# Schnelllauf: jede Minute
* * * * * flock -w 30 /tmp/vito.lock /usr/local/bin/vclient -v -f /opt/viss2mqtt/viss2mqtt-fast.lst -t /opt/viss2mqtt/viss2mqtt-fast.tpl -x /opt/viss2mqtt/viss2mqtt-fast.sh > /opt/viss2mqtt/viss2mqtt-fast.log 2>&1

# Voller Lauf: alle 5 Minuten
*/5 * * * * flock -w 60 /tmp/vito.lock /usr/local/bin/vclient -v -f /opt/viss2mqtt/viss2mqtt.lst -t /opt/viss2mqtt/viss2mqtt.tpl -x /opt/viss2mqtt/viss2mqtt.sh > /opt/viss2mqtt/viss2mqtt.log 2>&1
```

- `vclient` **immer mit absolutem Pfad** angeben – der PATH von Cron enthält `/usr/local/bin` nicht.
- Die Ausgabe des letzten Laufs steht in `viss2mqtt.log` bzw. `viss2mqtt-fast.log`.
- Die Werte des vollen Laufs kommen ca. 75 s nach dem Start in Symcon an, die des Schnelllaufs nach ca. 10 s.

## 5. Konfiguration

Die Einstellungen stehen am Anfang beider Templates:

| Konstante | Standard | Beschreibung |
| --------- | -------- | ------------ |
| `MQTT_CLID` | `viss2mqtt` / `viss2mqtt-fast` | Client-ID am Broker (muss je Lauf eindeutig sein) |
| `MQTT_SERV` | `192.168.13.3` | IP-Adresse des MQTT-Brokers (Symcon) |
| `MQTT_PORT` | `1883` | Port des MQTT-Brokers |
| `MQTT_KEEP` | `60` | Keep-Alive in Sekunden |
| `MQTT_TOPIC` | `viss2mqtt/vito` | Topic, auf dem das JSON veröffentlicht wird |
| `STATE_FILE` | `/opt/viss2mqtt/state.json` | Letzte gültige Zählerstände für die Plausibilitätsprüfung (von beiden Läufen geteilt) |

Ändert sich Broker, Topic oder Grenzwert, beide Templates anpassen.

### Werte hinzufügen oder entfernen

1. Befehl in der `.lst`-Datei ergänzen bzw. entfernen (der Befehl muss in `vito.xml` definiert sein und eine `<unit>` haben).
2. Im `data`-Block des Templates den passenden Eintrag anlegen bzw. löschen.
3. `.lst` und `.tpl` immer **gemeinsam** austauschen.

**Wichtig:** Die Platzhalter sind über die Zeilennummer an die `.lst`-Datei gebunden. Zeile *n* der Befehlsdatei entspricht `$Cn`, `$n` und `$Rn` im Template. Wird eine Zeile eingefügt oder gelöscht, müssen alle folgenden Nummern im Template angepasst werden.

| Platzhalter | Bedeutung |
| ----------- | --------- |
| `$Cn` | Name des *n*-ten Befehls (wird als JSON-Schlüssel verwendet) |
| `$n` | Zahlenwert des Ergebnisses |
| `$Rn` | Ergebnis als Text (Rohwert inkl. Fehlermeldungen) |

Alle Platzhalter stehen im Template in Anführungszeichen. Dadurch erzeugt ein fehlgeschlagener Befehl keinen Python-Syntaxfehler, sondern der Wert wird beim Parsen verworfen.

> Typ eines Werts (Bool, Int, Float, String) nicht nachträglich ändern – siehe [Stolperfallen](#10-stolperfallen).

### Hilfsfunktionen im Template

| Funktion | Zweck |
| -------- | ----- |
| `num(value, cast, lo, hi)` | Zahl parsen, optional mit Grenzwerten; sonst `None` |
| `counter(key, value, per_hour, slack)` | Zählerstand gegen den letzten gültigen Stand prüfen (siehe [Plausibilitätsprüfung](#7-plausibilitätsprüfung)) |
| `flag(value)` | `0`/`1` → `false`/`true` |
| `txt(value)` | Text übernehmen, Fehlermeldungen (`ERR`, `NOT OK`, …) verwerfen (nur voller Lauf) |
| `ts(value)` | ISO-Zeitstempel der Heizung → Unix-Zeit (nur voller Lauf) |

## 6. Ausgelesene Werte

Die Spalte **Fast** markiert die Werte, die zusätzlich jede Minute im Schnelllauf kommen.

| Nr. | Befehl | Typ | Gültiger Bereich | Fast | Beschreibung |
| --: | ------ | --- | ---------------- | :--: | ------------ |
| 1 | `getTempA` | float | −40 … 60 °C | ✓ | Außentemperatur |
| 2 | `getTempAtp` | float | −40 … 60 °C | | Außentemperatur, tiefpassgefiltert |
| 3 | `getTempAged` | float | −40 … 60 °C | | Außentemperatur, gedämpft |
| 4 | `getTempWWist` | float | 5 … 100 °C | ✓ | Warmwasser-Isttemperatur |
| 5 | `getTempWWsoll` | float | 5 … 100 °C | | Warmwasser-Solltemperatur |
| 6 | `getTempKist` | float | 5 … 110 °C | ✓ | Kessel-Isttemperatur |
| 7 | `getTempKtp` | float | 5 … 110 °C | | Kesseltemperatur, tiefpassgefiltert |
| 8 | `getTempKsoll` | float | 5 … 110 °C | | Kessel-Solltemperatur |
| 9 | `getBrennerStatus` | bool | – | ✓ | Brenner an/aus |
| 10 | `getBrennerStufe` | int | 0 … 2 | | Brennerstufe |
| 11 | `getBrennerStarts` | int | Zähler, max. 30/h | ✓ | Brennerstarts |
| 12 | `getBrennerStunden1` | float | Zähler, max. 1 h/h | | Betriebsstunden Stufe 1 |
| 13 | `getBrennerStunden2` | float | Zähler, max. 1 h/h | | Betriebsstunden Stufe 2 |
| 14 | `getTempStp` | float | 5 … 100 °C | | Speichertemperatur |
| 15 | `getTempRaumNorSollM1` | float | 3 … 40 °C | | Raum-Solltemperatur normal (Heizkreis 1) |
| 16 | `getTempRaumRedSollM1` | float | 3 … 40 °C | | Raum-Solltemperatur reduziert (Heizkreis 1) |
| 17 | `getPumpeStatusM1` | int | – | | Heizkreispumpe Heizkreis 1 |
| 18 | `getPumpeStatusSp` | int | – | | Speicherladepumpe |
| 19 | `getPumpeStatusZirku` | int | – | | Zirkulationspumpe |
| 20 | `getBetriebArt` | string | – | | Betriebsart |
| 21 | `getStatusFrostM1` | int | – | | Frostschutz Heizkreis 1 |
| 22 | `getSystemTime` | int | – | | Systemzeit der Heizung (Unix-Zeit) |
| 23 | `getDaempfung` | float | – | | Dämpfung (Zeitkonstante Außentemperatur, K90) |
| 24 | `getStatusStoerung` | int | – | | Sammelstörung |
| 25–34 | `getError0` … `getError9` | string | – | | Fehlerhistorie (Zeitstempel + Fehlertext) |

`getBrennerStufe` ist nicht im Schnelllauf enthalten. Sie kann deshalb bis zu 5 Minuten vom Brennerstatus abweichen.

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

Voller Lauf (gekürzt):

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

Schnelllauf:

```json
{
  "getBrennerStatus": true,
  "getBrennerStarts": 45410,
  "getTempA": 14.6,
  "getTempKist": 52.8,
  "getTempWWist": 46.8
}
```

Liefert vcontrold überhaupt keinen Wert (z. B. Daemon nicht erreichbar), wird nichts gesendet und das Skript beendet sich mit einer Fehlermeldung.

## 9. Einbindung in Symcon

1. In Symcon eine **MQTT Server**-Instanz anlegen (bzw. eine vorhandene verwenden) und Port `1883` freigeben.
2. Darunter eine **MQTT Server Device**-Instanz für das Topic `viss2mqtt/vito` anlegen.
3. Das Device legt für jeden JSON-Schlüssel automatisch eine Variable an. Der **Ident** der Variable ist der vclient-Befehlsname (z. B. `getTempA`), der Variablentyp folgt dem JSON-Typ.

Da beide Läufe auf dasselbe Topic senden und fehlende Werte nicht übertragen werden, aktualisiert jede Nachricht nur die enthaltenen Variablen. Alle anderen behalten ihren letzten Wert.

Name, Icon, Darstellung und Archivierung der Variablen legst du selbst in Symcon fest. viss2mqtt sendet nur die Werte.

> Archiv-Hinweis: Mit dem Schnelllauf kommen die fünf schnellen Werte jede Minute. Ist für sie das Logging aktiv, sind das rund 525.000 Einträge pro Variable und Jahr.

## 10. Stolperfallen

| Thema | Erkenntnis |
| ----- | ---------- |
| **Typwechsel im JSON** | Ändert sich der Typ eines Werts (z. B. String → Bool), **löscht das MQTT Server Device die Variable und legt sie neu an** – mit neuer ID, ohne Name, Darstellung und Logging. Typen deshalb nicht ändern, ohne das einzuplanen. Archivdaten lassen sich mit `AC_ChangeVariableID` auf die neue Variable übertragen (die Zielvariable darf noch nicht geloggt sein). |
| **Variable löschen** | Eine Variable im Device erst löschen, wenn der Wert nicht mehr im Payload steht (also zuerst `.lst`/`.tpl` ändern). Sonst wird sie beim nächsten Lauf sofort neu angelegt. |
| **`<allow>` + `localhost`** | `<allow ip="127.0.0.1"/>` zusammen mit `<listen>localhost</listen>` weist IPv6 `::1` ab („timeout wait:vctrld>“). Mit `listen localhost` ist kein `allow` nötig. |
| **`<syslog>y</syslog>`** | Die Startmeldung von vcontrold geht als Broadcast an alle Terminals. Deshalb `syslog n`. |
| **Befehle ohne `<unit>`** | vcontrold ignoriert sie („command unknown“). |
| **Ende der `.lst`** | vclient `-f` braucht `\n` am Ende der letzten Befehlszeile, sonst wird das letzte Zeichen abgeschnitten. Prüfen mit `cat -A datei.lst` (`$` markiert nur das Zeilenende). |
| **Cron-PATH** | Ohne absoluten Pfad meldet Cron „flock: failed to execute vclient“. |
| **Gleichzeitiger Zugriff** | Manuelle vclient-Aufrufe immer mit `flock -w 30 /tmp/vito.lock …` starten. Ohne Lock am besten zwischen :02 und :04 (bzw. :07–:09), weil der volle Lauf vcontrold ab :00 ca. 75 s belegt. |
| **vcontrold-Neustart** | Ein Cronlauf kann in dieser Zeit ausfallen. Das ist kein Fehler, der nächste Lauf holt die Werte nach. |
| **`exit with count=0`** | Normale vclient-Ausgabe bei `-f`, kein Fehler. |
| **Hintergrund-Testschleifen** | Mit `nohup sh -c '…'` gestartete Schleifen lassen sich nicht über den Logdateinamen beenden. Die PID mit `pgrep -af` suchen. |

## 11. Fehlersuche

| Problem | Mögliche Ursache / Lösung |
| ------- | ------------------------- |
| Es kommt nichts in Symcon an | `viss2mqtt.log` / `viss2mqtt-fast.log` ansehen; Lauf manuell starten (siehe 4.2); Broker-IP und Port in den Templates kontrollieren. |
| `flock: failed to execute vclient` | `vclient` in der Crontab ohne absoluten Pfad. |
| `timeout wait:vctrld>` | vcontrold nicht erreichbar oder `<allow ip="127.0.0.1"/>` blockiert IPv6 (siehe Stolperfallen). |
| `no values received from vcontrold` | vcontrold läuft nicht, falscher Port oder OptoLink-Adapter nicht verbunden (`/dev/ttyVITO`). |
| Einzelne Werte fehlen dauerhaft | Befehl liefert Fehler oder liegt außerhalb der Grenzen – mit `vclient -c <Befehl>` gegenprüfen. |
| Letzter Wert der `.lst` fehlt oder hat einen falschen Namen | Das Zeilenende der letzten Zeile fehlt. |
| Werte landen unter falschem Namen | Reihenfolge in der `.lst` und Nummern im Template passen nicht zusammen. |
| Variable in Symcon plötzlich neu (andere ID, Logging aus) | Der JSON-Typ des Werts hat sich geändert (siehe Stolperfallen). |
| `AttributeError: CallbackAPIVersion` | paho-mqtt ist älter als 2.0 – aktualisieren. |
| Zähler werden nicht mehr aktualisiert | Nach einem Sprung wird der neue Stand erst beim zweiten konsistenten Wert übernommen; ggf. `state.json` löschen. |

## 12. Versionshistorie

Siehe [CHANGELOG.md](CHANGELOG.md).
