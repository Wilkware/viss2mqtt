#!/usr/bin/env python3
# viss2mqtt – vclient-Template fuer Vitotronic 150 KB1 -> MQTT (Symcon #36731)
# Aufruf (cron, alle 5 min, siehe viss2mqtt.cron):
#   flock -w 60 /opt/viss2mqtt/vito.lock /usr/local/bin/vclient -f viss2mqtt.lst -t viss2mqtt.tpl -x viss2mqtt.sh
# Platzhalter: C+Nr = Befehlsname, Nr = Zahlenwert, R+Nr = Ergebnistext.
# Die Reihenfolge MUSS zur viss2mqtt.lst passen (1 Zeile = 1 Nummer).
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
    "$C1": num("$1", lo=-40, hi=60),            # getTempA (128.5 = Fuehlerfehler)
    "$C2": num("$2", lo=-40, hi=60),            # getTempAtp
    "$C3": num("$3", lo=-40, hi=60),            # getTempAged
    # Warmwasser
    "$C4": num("$4", lo=5, hi=100),            # getTempWWist
    "$C5": num("$5", lo=5, hi=100),            # getTempWWsoll
    # Kessel
    "$C6": num("$6", lo=5, hi=110),            # getTempKist
    "$C7": num("$7", lo=5, hi=110),            # getTempKtp
    "$C8": num("$8", lo=5, hi=110),            # getTempKsoll
    # Brenner
    "$C9": flag("$R9"),          # getBrennerStatus (Bool: Brenner an/aus)
    "$C10": num("$10", int, 0, 2),     # getBrennerStufe
    "$C11": counter("starts", num("$11", int, 0), 30, 3),  # getBrennerStarts (max. 30/h)
    "$C12": counter("hours1", num("$12", float, 0), 1.0, 0.2),  # getBrennerStunden1 (max. 1 h/h)
    "$C13": counter("hours2", num("$13", float, 0), 1.0, 0.2),  # getBrennerStunden2 (max. 1 h/h)
    # Speicher / Raumsoll
    "$C14": num("$14", lo=5, hi=100),          # getTempStp
    "$C15": num("$15", lo=3, hi=40),          # getTempRaumNorSollM1
    "$C16": num("$16", lo=3, hi=40),          # getTempRaumRedSollM1
    # Pumpen (RT: "0"/"1"/"2", "NOT OK" -> weggelassen)
    "$C17": num("$R17", int),    # getPumpeStatusM1
    "$C18": num("$R18", int),    # getPumpeStatusSp
    "$C19": num("$R19", int),    # getPumpeStatusZirku
    # Betrieb
    "$C20": txt("$R20"),         # getBetriebArt
    "$C21": num("$21", int),     # getStatusFrostM1
    "$C22": ts("$R22"),          # getSystemTime
    "$C23": num("$23"),          # getDaempfung
    "$C24": num("$R24", int),    # getStatusStoerung
    # Fehlerhistorie
    "$C25": txt("$R25"),         # getError0
    "$C26": txt("$R26"),         # getError1
    "$C27": txt("$R27"),         # getError2
    "$C28": txt("$R28"),         # getError3
    "$C29": txt("$R29"),         # getError4
    "$C30": txt("$R30"),         # getError5
    "$C31": txt("$R31"),         # getError6
    "$C32": txt("$R32"),         # getError7
    "$C33": txt("$R33"),         # getError8
    "$C34": txt("$R34"),         # getError9
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
