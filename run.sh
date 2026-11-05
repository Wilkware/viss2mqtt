#!/usr/bin/env bash
# viss2mqtt – ein vclient-Lauf (Aufruf aus Cron und deploy.sh, unter dem Lock)
#
#   flock -w 30 /opt/viss2mqtt/vito.lock /opt/viss2mqtt/run.sh viss2mqtt-fast
#
# Befehlsliste und Template: local/RUN.lst bzw. local/RUN.tpl, falls vorhanden,
# sonst die Standarddateien RUN.lst / RUN.tpl aus dem Repository.
# Das erzeugte Skript landet immer in /opt/viss2mqtt/RUN.sh.

set -euo pipefail

RUN_DIR="/opt/viss2mqtt"
LOCAL_DIR="$RUN_DIR/local"
VCLIENT="/usr/local/bin/vclient"

# Liefert local/$1, falls vorhanden, sonst die Standarddatei
pick() {
    if [ -f "$LOCAL_DIR/$1" ]; then
        printf '%s\n' "$LOCAL_DIR/$1"
    else
        printf '%s\n' "$RUN_DIR/$1"
    fi
}

if [ $# -ne 1 ] || [[ ! "$1" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Aufruf: $0 LAUF (z. B. viss2mqtt oder viss2mqtt-fast)" >&2
    exit 2
fi
run="$1"
lst="$(pick "$run.lst")"
tpl="$(pick "$run.tpl")"
if [ ! -f "$lst" ] || [ ! -f "$tpl" ]; then
    echo "run.sh: $run.lst oder $run.tpl fehlt" >&2
    exit 1
fi

echo "run.sh: $lst + $tpl"
exec "$VCLIENT" -v -f "$lst" -t "$tpl" -x "$RUN_DIR/$run.sh"
