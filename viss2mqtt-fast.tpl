#!/usr/bin/env python3
# viss2mqtt-fast – Schnelllauf der Vitotronic 150 KB1 -> MQTT (Symcon #36731)
# Nur die Werte, die man zeitnah sehen will: Brennerstatus, Brennerstarts,
# Aussentemperatur, Kesseltemperatur, Warmwassertemperatur (Ist).
# Aufruf (cron, jede Minute, siehe viss2mqtt.cron):
#   flock -w 30 /opt/viss2mqtt/vito.lock /opt/viss2mqtt/run.sh viss2mqtt-fast
# run.sh nimmt local/viss2mqtt-fast.lst/.tpl, falls vorhanden, sonst diese Datei.
# Platzhalter: C+Nr = Befehlsname, Nr = Zahlenwert, R+Nr = Ergebnistext.
# Die Reihenfolge MUSS zur viss2mqtt-fast.lst passen (1 Zeile = 1 Nummer):
#   1 getBrennerStatus, 2 getBrennerStarts, 3 getTempA, 4 getTempKist, 5 getTempWWist
# Gleiches Topic, gleiche Typen und gleiche Plausibilitaetspruefung wie
# viss2mqtt.tpl. Fehlende/verworfene Werte fehlen im Payload, Symcon behaelt
# den letzten Wert. Die Zaehlerpruefung (Starts) nutzt dieselbe state.json und
# denselben Schluessel "starts" wie der 5-Minuten-Lauf; beide Laeufe sind per
# flock serialisiert, schreiben also nie gleichzeitig.
# Typen NICHT aendern: ein Typwechsel loescht die Variable im MQTT-Device.
# Stand: 05.11.2026

import configparser
import json
import os
import time
import paho.mqtt.client as mqtt

# Standardwerte; eigene Werte in CONFIG_FILE, Abschnitt [mqtt]
# (host, port, user, password, topic), siehe examples/viss2mqtt.ini
CONFIG_FILE = '/opt/viss2mqtt/local/viss2mqtt.ini'
_cfg = configparser.ConfigParser(interpolation=None)
_cfg.read(CONFIG_FILE)  # fehlt die Datei, gelten die Standardwerte

MQTT_CLID = 'viss2mqtt-fast'
MQTT_SERV = _cfg.get('mqtt', 'host', fallback='192.168.13.3')  # MQTT-Server (Symcon)
MQTT_PORT = _cfg.getint('mqtt', 'port', fallback=1883)
MQTT_USER = _cfg.get('mqtt', 'user', fallback='')  # leer = ohne Anmeldung
MQTT_PASS = _cfg.get('mqtt', 'password', fallback='')
MQTT_KEEP = 60
MQTT_TOPIC = _cfg.get('mqtt', 'topic', fallback='viss2mqtt/vito')
STATE_FILE = '/opt/viss2mqtt/state.json'  # letzte gueltige Zaehlerstaende


def num(value, cast=float, lo=None, hi=None):
    """Zahl aus vclient-Ergebnis, None bei Fehler/NOT OK/leer oder ausserhalb [lo, hi]."""
    try:
        n = cast(float(str(value).strip()))
    except (TypeError, ValueError):
        return None
    if (lo is not None and n < lo) or (hi is not None and n > hi):
        return None
    return n


def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(state):
    try:
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, STATE_FILE)
    except OSError:
        pass  # ohne Statusdatei wird beim naechsten Lauf neu angefangen


STATE = load_state()


def counter(key, value, per_hour, slack):
    """Zaehlerstand pruefen: darf nicht sinken und nicht schneller steigen als
    per_hour * vergangene Stunden + slack. Ausreisser -> None. Liegt der neue Stand
    zweimal hintereinander konsistent auf einem anderen Niveau (z.B. Reglertausch),
    wird er als neue Basis uebernommen."""
    if value is None:
        return None
    now = time.time()
    st = STATE.get(key)
    if st:
        delta = value - st["v"]
        if delta < 0 or delta > per_hour * (now - st["t"]) / 3600 + slack:
            cand = st.get("cand")
            if cand is not None and abs(value - cand["v"]) <= per_hour * (now - cand["t"]) / 3600 + slack:
                pass  # zweiter, konsistenter Wert auf neuem Niveau -> uebernehmen
            else:
                st["cand"] = {"v": value, "t": now}
                return None
    STATE[key] = {"v": value, "t": now}
    return value


def flag(value):
    """vclient-Ergebnis '0'/'1' -> False/True, None bei Fehler."""
    n = num(value, int)
    return None if n is None else n > 0


data = {
    "$C1": flag("$R1"),                                    # getBrennerStatus (Bool: Brenner an/aus)
    "$C2": counter("starts", num("$2", int, 0), 30, 3),    # getBrennerStarts (max. 30/h)
    "$C3": num("$3", lo=-40, hi=60),                       # getTempA (128.5 = Fuehlerfehler)
    "$C4": num("$4", lo=5, hi=110),                        # getTempKist
    "$C5": num("$5", lo=5, hi=100),                        # getTempWWist
}

payload = {k: v for k, v in data.items() if v is not None}

save_state(STATE)

# Nichts senden, wenn vcontrold gar nichts geliefert hat
if not payload:
    raise SystemExit("viss2mqtt-fast: no values received from vcontrold")

client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, MQTT_CLID)
if MQTT_USER:
    client.username_pw_set(MQTT_USER, MQTT_PASS or None)
client.connect(MQTT_SERV, MQTT_PORT, MQTT_KEEP)
client.loop_start()
info = client.publish(MQTT_TOPIC, payload=json.dumps(payload, ensure_ascii=False), qos=0, retain=False)
info.wait_for_publish(timeout=5)
client.loop_stop()
client.disconnect()
