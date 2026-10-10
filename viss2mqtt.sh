#!/usr/bin/env python3

import time
import datetime
import re
import paho.mqtt.client as mqtt

MQTT_CLID = 'viss2mqtt'
MQTT_SERV = '192.168.13.3' # mqtt server ip
MQTT_PORT = 1883 # mqtt server port
MQTT_KEEP = 60 # mqtt keep alive

TIME_STAMP = int(time.mktime(datetime.datetime.strptime("2026-10-09T18:50:37+0200","%Y-%m-%dT%H:%M:%S%z").timetuple())) #unix time

VISS_DATA = f"""{{\
"getTempA": 14.500000, "getTempAtp": 14.500000, "getTempAged": 14.500000, \
"getTempWWist": 49.099998, "getTempWWsoll": 45.000000, \
"getTempKist": 31.400000, "getTempKtp": 31.400000, "getTempKsoll": 7.000000, \
"getBetriebszeitStandby": 1193046.500000, \
"getBrennerStatus": "NOT OK", "getBrennerStatus2": "0", "getBrennerStufe": 0, "getBrennerStarts": {int(45404.000000 )}, "getBrennerStunden1": 22883.794922, "getBrennerStunden2": 6.957222, \
"getTempStp": 49.099998, \
"getTempRaumNorSollM1": 22.000000, "getTempRaumRedSollM1": 3.000000, \
"getPumpeStatusM1": 0, "getPumpeStatusSp": 0, "getPumpeStatusZirku": 1, \
"getBetriebArt": "WW", \
"getStatusFrostM1": {int(1.000000 )}, \
"getSystemTime": {TIME_STAMP}, \
"getDaempfung": 128.000000, \
"getStatusStoerung": 0, \
"getError0": "2023-08-11T10:48:32+0200 Brennerstoerung (D1)", "getError1": "2023-08-11T07:49:20+0200 Brennerstoerung (D1)", "getError2": "2023-08-07T16:51:12+0200 Brennerstoerung (D1)", "getError3": "2023-04-25T12:39:28+0200 Brennerstoerung (D1)", "getError4": "2023-04-24T21:09:20+0200 Brennerstoerung (D1)", "getError5": "2023-04-24T21:09:20+0200 Brennerstoerung (D1)", "getError6": "2023-04-24T20:26:40+0200 Brennerstoerung (D1)", "getError7": "2023-04-24T20:26:40+0200 Brennerstoerung (D1)", "getError8": "2023-04-24T20:22:24+0200 Brennerstoerung (D1)", "getError9": "2023-04-24T14:02:40+0200 Brennerstoerung (D1)"\
}}\
"""

#print(VISS_DATA)

# Create a new MQTT client instance
mqtt_client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, MQTT_CLID)

# Connect to the MQTT server
mqtt_client.connect(MQTT_SERV, MQTT_PORT, MQTT_KEEP)

# Publish a message to the specified topic
mqtt_client.publish('viss2mqtt/vito', payload=VISS_DATA, qos=0, retain=False)

# Disconnect from the MQTT server
mqtt_client.disconnect()

