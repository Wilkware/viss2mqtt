#!/usr/bin/env python3
# viss2mqtt – vclient-Template fuer Vitotronic 150 KB1 -> MQTT (Symcon #36731)
# Aufruf (cron, alle 5 min):
#   vclient -f viss2mqtt.cmd -t viss2mqtt.tpl -x viss2mqtt.sh
# Platzhalter: C+Nr = Befehlsname, Nr = Zahlenwert, R+Nr = Ergebnistext.
# Die Reihenfolge MUSS zur viss2mqtt.cmd passen (1 Zeile = 1 Nummer).
# Alle Werte stehen in Anfuehrungszeichen und werden erst hier geparst:
# ein fehlgeschlagener Befehl fuehrt so nicht mehr zu einem Syntaxfehler,
# sondern der Wert wird einfach weggelassen (Symcon behaelt den alten Wert).
# Plausibilitaetspruefung (10.10.2026): unmoegliche Werte werden hier verworfen,
# statt sie nach Symcon zu schicken (z.B. 128.5 = Fehlerwert des Aussenfuehlers,
# Zaehler-Bitfehler wie 242012 statt 45404). Verworfene Werte fehlen im Payload,
# Symcon behaelt den letzten gueltigen Wert. Zaehler werden gegen den letzten
# akzeptierten Wert geprueft (state.json), siehe counter().
# Stand: 10.10.2026

import json
import os
import time
import datetime
import paho.mqtt.client as mqtt

MQTT_CLID = 'viss2mqtt'
MQTT_SERV = '192.168.13.3'  # MQTT-Server (Symcon)
MQTT_PORT = 1883
MQTT_KEEP = 60
MQTT_TOPIC = 'viss2mqtt/vito'
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


def txt(value):
    """Text aus vclient-Ergebnis, None wenn leer oder Fehlermeldung."""
    value = str(value).strip()
    if not value or value.startswith(("ERR", "SRV ERR", "server error", "NOT OK")):
        return None
    return value


def flag(value):
    """vclient-Ergebnis '0'/'1' -> False/True, None bei Fehler."""
    n = num(value, int)
    return None if n is None else n > 0


def ts(value):
    """ISO-Zeit der Heizung -> Unix-Zeit, None bei Fehler."""
    try:
        return int(datetime.datetime.strptime(str(value).strip(), "%Y-%m-%dT%H:%M:%S%z").timestamp())
    except ValueError:
        return None


data = {
    # Aussentemperatur
    "getTempA": num("128.500000", lo=-40, hi=60),            # getTempA (128.5 = Fuehlerfehler)
    "getTempAtp": num("14.600000", lo=-40, hi=60),            # getTempAtp
    "getTempAged": num("13.900000", lo=-40, hi=60),            # getTempAged
    # Warmwasser
    "getTempWWist": num("46.799999", lo=5, hi=100),            # getTempWWist
    "getTempWWsoll": num("45.000000", lo=5, hi=100),            # getTempWWsoll
    # Kessel
    "getTempKist": num("52.799999", lo=5, hi=110),            # getTempKist
    "getTempKtp": num("52.799999", lo=5, hi=110),            # getTempKtp
    "getTempKsoll": num("7.000000", lo=5, hi=110),            # getTempKsoll
    # Brenner
    "getBrennerStatus": flag("0"),          # getBrennerStatus (Bool: Brenner an/aus)
    "getBrennerStufe": num("0.000000", int, 0, 2),     # getBrennerStufe
    "getBrennerStarts": counter("starts", num("45410.000000", int, 0), 30, 3),  # getBrennerStarts (max. 30/h)
    "getBrennerStunden1": counter("hours1", num("22884.503906", float, 0), 1.0, 0.2),  # getBrennerStunden1 (max. 1 h/h)
    "getBrennerStunden2": counter("hours2", num("6.957222", float, 0), 1.0, 0.2),  # getBrennerStunden2 (max. 1 h/h)
    # Speicher / Raumsoll
    "getTempStp": num("46.799999", lo=5, hi=100),          # getTempStp
    "getTempRaumNorSollM1": num("22.000000", lo=3, hi=40),          # getTempRaumNorSollM1
    "getTempRaumRedSollM1": num("3.000000", lo=3, hi=40),          # getTempRaumRedSollM1
    # Pumpen (RT: "0"/"1"/"2", "NOT OK" -> weggelassen)
    "getPumpeStatusM1": num("0", int),    # getPumpeStatusM1
    "getPumpeStatusSp": num("0", int),    # getPumpeStatusSp
    "getPumpeStatusZirku": num("1", int),    # getPumpeStatusZirku
    # Betrieb
    "getBetriebArt": txt("WW"),         # getBetriebArt
    "getStatusFrostM1": num("1.000000", int),     # getStatusFrostM1
    "getSystemTime": ts("2026-10-10T15:15:46+0200"),          # getSystemTime
    "getDaempfung": num("128.000000"),          # getDaempfung
    "getStatusStoerung": num("0", int),    # getStatusStoerung
    # Fehlerhistorie
    "getError0": txt("2023-08-11T10:48:32+0200 Brennerstoerung (D1)"),         # getError0
    "getError1": txt("2023-08-11T07:49:20+0200 Brennerstoerung (D1)"),         # getError1
    "getError2": txt("2023-08-07T16:51:12+0200 Brennerstoerung (D1)"),         # getError2
    "getError3": txt("2023-04-25T12:39:28+0200 Brennerstoerung (D1)"),         # getError3
    "getError4": txt("2023-04-24T21:09:20+0200 Brennerstoerung (D1)"),         # getError4
    "getError5": txt("2023-04-24T21:09:20+0200 Brennerstoerung (D1)"),         # getError5
    "getError6": txt("2023-04-24T20:26:40+0200 Brennerstoerung (D1)"),         # getError6
    "getError7": txt("2023-04-24T20:26:40+0200 Brennerstoerung (D1)"),         # getError7
    "getError8": txt("2023-04-24T20:22:24+0200 Brennerstoerung (D1)"),         # getError8
    "getError9": txt("2023-04-24T14:02:40+0200 Brennerstoerung (D1)"),         # getError9
}

payload = {k: v for k, v in data.items() if v is not None}

save_state(STATE)

# Nichts senden, wenn vcontrold gar nichts geliefert hat
if not payload:
    raise SystemExit("viss2mqtt: no values received from vcontrold")

client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, MQTT_CLID)
client.connect(MQTT_SERV, MQTT_PORT, MQTT_KEEP)
client.loop_start()
info = client.publish(MQTT_TOPIC, payload=json.dumps(payload, ensure_ascii=False), qos=0, retain=False)
info.wait_for_publish(timeout=5)
client.loop_stop()
client.disconnect()
