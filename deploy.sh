#!/usr/bin/env bash
# viss2mqtt – Update per Git und Verteilung auf dem Vito-Rechner
#
# Der Git-Checkout ist zugleich das Laufzeitverzeichnis /opt/viss2mqtt.
# Aufruf als der Benutzer, unter dem die Cronjobs laufen (nicht als root).
# sudo wird nur für Dateien unter /etc aufgerufen.
#
#   ./deploy.sh              git pull, prüfen, verteilen, Testlauf
#   ./deploy.sh --dry-run    nur anzeigen, was sich ändern würde
#   ./deploy.sh --no-pull    ohne git pull
#   ./deploy.sh --no-test    ohne Testlauf
#
# Verteilt werden:
#   viss2mqtt.cron        -> /etc/cron.d/viss2mqtt
#   etc/vcontrold/*.xml   -> /etc/vcontrold/ (mit .bak, Neustart nur als Hinweis)
#
# Eigene Dateien unter local/ (gleicher relativer Pfad) haben Vorrang vor den
# Standarddateien, z. B. local/etc/vcontrold/vito.xml oder local/viss2mqtt.lst.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="/opt/viss2mqtt"
LOCAL_DIR="$REPO_DIR/local"
LOCAL_FILES=(
    etc/vcontrold/vcontrold.xml etc/vcontrold/vito.xml
    viss2mqtt.lst viss2mqtt.tpl viss2mqtt-fast.lst viss2mqtt-fast.tpl
    viss2mqtt.cron viss2mqtt.ini
)
MQTT_INI="$LOCAL_DIR/viss2mqtt.ini"
LOCK_FILE="$RUN_DIR/vito.lock"
OLD_LOCK_FILE="/tmp/vito.lock"
CRON_DST="/etc/cron.d/viss2mqtt"
VCONTROLD_DST="/etc/vcontrold"
VCONTROLD_FILES=(vcontrold.xml vito.xml)
VCLIENT="/usr/local/bin/vclient"
RUN_SCRIPT="$RUN_DIR/run.sh"
RUNS=(viss2mqtt viss2mqtt-fast)
TEST_RUN="viss2mqtt-fast"
RUN_USER="$(id -un)"

DRY_RUN=0
PULL=1
TEST=1
CHANGES=0
UPDATED=0
VCONTROLD_CHANGED=0
ARGS=("$@")

step() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   WARNUNG: %s\n' "$*" >&2; }
die() {
    printf '\nFEHLER: %s\n' "$*" >&2
    exit 1
}
# Liefert local/$1, falls vorhanden, sonst die Standarddatei aus dem Repository
pick() {
    if [ -f "$LOCAL_DIR/$1" ]; then
        printf '%s\n' "$LOCAL_DIR/$1"
    else
        printf '%s\n' "$REPO_DIR/$1"
    fi
}
# Pfad relativ zum Checkout für Meldungen
rel() { printf '%s\n' "${1#"$REPO_DIR"/}"; }
usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# Kopiert $1 nach $2 (als root), wenn sich der Inhalt unterscheidet.
# $3 = "bak": vorher Sicherung $2.bak anlegen
# Setzt UPDATED=1, wenn kopiert wurde (bei --dry-run: kopiert würde).
install_file() {
    local src="$1" dst="$2" backup="${3:-}"
    UPDATED=0
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        info "unverändert   $dst"
        return 0
    fi
    UPDATED=1
    CHANGES=$((CHANGES + 1))
    if [ "$DRY_RUN" -eq 1 ]; then
        info "würde ändern  $dst"
        return 0
    fi
    if [ "$backup" = "bak" ] && [ -f "$dst" ]; then
        sudo cp -p "$dst" "$dst.bak"
    fi
    sudo install -m 0644 -o root -g root "$src" "$dst"
    info "aktualisiert  $dst"
}

# Prüft eine Befehlsliste und ihr Template auf die bekannten Stolperfallen.
# Gibt bei einem Fehler die Meldung aus und liefert 1.
check_run() {
    local run="$1"
    local lst tpl vito lst_name tpl_name vito_name
    local content tail_blanks cmd n_cmds n_tpl
    local -a cmds
    lst="$(pick "$run.lst")"
    tpl="$(pick "$run.tpl")"
    vito="$(pick etc/vcontrold/vito.xml)"
    lst_name="$(rel "$lst")"
    tpl_name="$(rel "$tpl")"
    vito_name="$(rel "$vito")"

    if [ ! -f "$lst" ] || [ ! -f "$tpl" ]; then
        warn "$lst_name oder $tpl_name fehlt."
        return 1
    fi
    if [ "$(cat "$lst" "$tpl" | tr -dc '\r' | wc -c)" -gt 0 ]; then
        warn "$lst_name oder $tpl_name enthält CRLF-Zeilenenden."
        return 1
    fi

    # vclient -f schneidet ohne Zeilenumbruch das letzte Zeichen des letzten Befehls ab
    content="$(
        cat "$lst"
        printf x
    )"
    content="${content%x}"
    tail_blanks="${content##*[![:blank:]]}"
    content="${content%"$tail_blanks"}"
    if [[ "$content" != *$'\n' ]]; then
        warn "$lst_name: nach dem letzten Befehl fehlt der Zeilenumbruch."
        return 1
    fi

    mapfile -t cmds < <(grep -v '^[[:space:]]*$' "$lst" | tr -d '[:blank:]')
    n_cmds="${#cmds[@]}"
    n_tpl="$(grep -o '"\$C[0-9][0-9]*"' "$tpl" | sort -u | wc -l)"
    if [ "$n_cmds" -ne "$n_tpl" ]; then
        warn "$lst_name hat $n_cmds Befehle, $tpl_name erwartet $n_tpl."
        return 1
    fi

    # vcontrold kennt nur Befehle, die in vito.xml stehen
    for cmd in "${cmds[@]}"; do
        if ! grep -q "<command name=\"$cmd\"" "$vito"; then
            warn "$lst_name: Befehl $cmd ist in $vito_name nicht definiert."
            return 1
        fi
    done
    info "$lst_name: $n_cmds Befehle, passt zu $tpl_name und $vito_name"
}

# Prüft alle Dateien im Checkout. Liefert 1, wenn eine Prüfung fehlschlägt.
check_all() {
    local run f cron ok=0
    local -a xmls=()
    for run in "${RUNS[@]}"; do
        check_run "$run" || ok=1
    done
    for f in "${VCONTROLD_FILES[@]}"; do
        xmls+=("$(pick "etc/vcontrold/$f")")
    done
    if python3 - "${xmls[@]}" <<'EOF'; then
import sys
import xml.etree.ElementTree as ET
from xml.parsers.expat import ErrorString
failed = False
for path in sys.argv[1:]:
    try:
        ET.parse(path)
    except ET.ParseError as err:
        line, col = err.position
        reason = ErrorString(err.code)
        print(f"   {path}: Zeile {line}, Spalte {col + 1}: {reason}", file=sys.stderr)
        failed = True
sys.exit(1 if failed else 0)
EOF
        info "$(rel "${xmls[0]}"), $(rel "${xmls[1]}"): gültiges XML"
    else
        warn "vcontrold-Konfiguration ist kein gültiges XML."
        ok=1
    fi
    cron="$(pick viss2mqtt.cron)"
    if grep -q '@USER@' "$cron"; then
        info "$(rel "$cron"): ok"
    else
        warn "$(rel "$cron") enthält keinen Platzhalter @USER@."
        ok=1
    fi
    if [ -f "$MQTT_INI" ]; then
        if python3 - "$MQTT_INI" <<'EOF'; then
import configparser
import sys
cfg = configparser.ConfigParser(interpolation=None)
cfg.read(sys.argv[1])
cfg.getint("mqtt", "port", fallback=1883)
EOF
            info "$(rel "$MQTT_INI"): ok"
        else
            warn "$(rel "$MQTT_INI") ist fehlerhaft (Abschnitt [mqtt], port als Zahl)."
            ok=1
        fi
        if [ -n "$(find "$MQTT_INI" -perm /077)" ]; then
            warn "$(rel "$MQTT_INI") ist für andere lesbar – chmod 600 $MQTT_INI"
        fi
    fi
    return "$ok"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -n | --dry-run) DRY_RUN=1 ;;
        --no-pull) PULL=0 ;;
        --no-test) TEST=0 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "Unbekannte Option: $1"
            ;;
    esac
    shift
done

step "Voraussetzungen"
[ "$(id -u)" -ne 0 ] || die "Nicht als root starten, sondern als der Benutzer, unter dem die Cronjobs laufen sollen."
[ "$REPO_DIR" = "$RUN_DIR" ] || die "deploy.sh liegt in $REPO_DIR, erwartet wird der Checkout in $RUN_DIR (Pfade in Cron und Templates)."
[ -w "$RUN_DIR" ] || die "$RUN_DIR ist für $RUN_USER nicht beschreibbar – zuerst ./install.sh ausführen."
[ -x "$VCLIENT" ] || die "$VCLIENT nicht gefunden."
[ -x "$RUN_SCRIPT" ] || die "$RUN_SCRIPT fehlt oder ist nicht ausführbar."
command -v flock >/dev/null || die "flock nicht gefunden (Paket util-linux)."
command -v python3 >/dev/null || die "python3 nicht gefunden."
python3 - <<'EOF' || die "paho-mqtt ab Version 2.0 ist für $RUN_USER nicht verfügbar."
import sys
import paho.mqtt
sys.exit(0 if int(paho.mqtt.__version__.split(".")[0]) >= 2 else 1)
EOF
if ! git -C "$REPO_DIR" diff --quiet || ! git -C "$REPO_DIR" diff --cached --quiet; then
    die "Lokale Änderungen im Checkout $REPO_DIR (git status) – bitte erst klären."
fi
info "Benutzer $RUN_USER, Checkout $REPO_DIR"
[ "$DRY_RUN" -eq 0 ] || info "Trockenlauf: es wird nichts geändert"

if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$PULL" -eq 1 ]; then
        step "Git"
        git -C "$REPO_DIR" fetch --quiet
        info "Neue Commits (noch nicht geholt, die Prüfung unten nutzt den aktuellen Stand):"
        git -C "$REPO_DIR" log --oneline 'HEAD..@{u}' | sed 's/^/     /'
        git -C "$REPO_DIR" diff --stat 'HEAD..@{u}' | sed 's/^/     /'
    fi
    step "Prüfen"
    check_all || warn "Prüfung fehlgeschlagen."
else
    # Lock wie die Cronjobs: kein Lauf liest .lst/.tpl, während sie sich ändern
    exec 9>>"$LOCK_FILE"
    step "Lock"
    info "warte auf $LOCK_FILE ..."
    flock -w 120 9 || die "Lock $LOCK_FILE nicht erhalten."

    before="$(git -C "$REPO_DIR" rev-parse HEAD)"
    if [ "$PULL" -eq 1 ]; then
        step "Git"
        git -C "$REPO_DIR" pull --ff-only --quiet
        if [ "$before" = "$(git -C "$REPO_DIR" rev-parse HEAD)" ]; then
            info "bereits aktuell"
        else
            git -C "$REPO_DIR" log --oneline "$before..HEAD" | sed 's/^/   /'
        fi
    fi

    step "Prüfen"
    if ! check_all; then
        if [ "$before" != "$(git -C "$REPO_DIR" rev-parse HEAD)" ]; then
            git -C "$REPO_DIR" reset --hard --quiet "$before"
            die "Prüfung fehlgeschlagen – Checkout auf den vorherigen Stand ${before:0:7} zurückgesetzt. Passen die eigenen Dateien in local/ noch zum neuen Stand?"
        fi
        die "Prüfung fehlgeschlagen – bitte im Repo bzw. in local/ korrigieren."
    fi
    exec 9>&-

    # deploy.sh selbst kann sich geändert haben -> neue Fassung starten
    if ! git -C "$REPO_DIR" diff --quiet "$before" HEAD -- deploy.sh; then
        info "deploy.sh wurde aktualisiert – starte neue Fassung"
        exec bash "$REPO_DIR/deploy.sh" --no-pull "${ARGS[@]}"
    fi
fi
info "Stand: $(git -C "$REPO_DIR" describe --tags --always)"

step "Eigene Dateien ($LOCAL_DIR)"
found=0
for f in "${LOCAL_FILES[@]}"; do
    if [ -f "$LOCAL_DIR/$f" ]; then
        info "verwendet     local/$f"
        found=1
    fi
done
[ "$found" -eq 1 ] || info "keine – es gelten die Standarddateien aus dem Repository"

step "vcontrold-Konfiguration ($VCONTROLD_DST)"
for f in "${VCONTROLD_FILES[@]}"; do
    install_file "$(pick "etc/vcontrold/$f")" "$VCONTROLD_DST/$f" bak
    if [ "$UPDATED" -eq 1 ]; then
        VCONTROLD_CHANGED=1
    fi
done
[ -d /var/log/vcontrold ] || warn "/var/log/vcontrold fehlt – vcontrold kann nicht loggen (siehe install.sh)."

step "Cron ($CRON_DST)"
cron_tmp="$(mktemp)"
marker="$(mktemp)"
trap 'rm -f "$cron_tmp" "$marker"' EXIT
sed "s/@USER@/$RUN_USER/g" "$(pick viss2mqtt.cron)" >"$cron_tmp"
install_file "$cron_tmp" "$CRON_DST"
user_cron="$(crontab -l 2>/dev/null || true)"
if [ "$(grep -c '^[^#]*viss2mqtt' <<<"$user_cron" || true)" -gt 0 ]; then
    warn "Die Crontab von $RUN_USER enthält noch viss2mqtt-Einträge – Jobs laufen doppelt. Entfernen mit: crontab -e"
fi
root_cron="$(sudo crontab -l -u root 2>/dev/null || true)"
if [ "$(grep -c '^[^#]*viss2mqtt' <<<"$root_cron" || true)" -gt 0 ]; then
    warn "Die Crontab von root enthält noch viss2mqtt-Einträge – Jobs laufen doppelt. Entfernen mit: sudo crontab -e"
fi

step "Aufräumen"
found=0
for f in "$RUN_DIR"/*.cmd; do
    [ -e "$f" ] || continue
    warn "veraltet (seit 1.2.0 .lst): $f"
    found=1
done
if [ -e "$OLD_LOCK_FILE" ]; then
    warn "altes Lock $OLD_LOCK_FILE (seit 2.0.0 $LOCK_FILE) – kann gelöscht werden"
    found=1
fi
[ "$found" -eq 1 ] || info "nichts zu tun"

if [ "$TEST" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    step "Testlauf ($TEST_RUN)"
    # gleicher Aufruf wie im Cronjob; sendet echte Werte an Symcon
    flock -w 120 "$LOCK_FILE" "$RUN_SCRIPT" "$TEST_RUN" >"$RUN_DIR/$TEST_RUN.log" 2>&1 || true
    sed 's/^/   | /' "$RUN_DIR/$TEST_RUN.log"
    if [ ! "$RUN_DIR/$TEST_RUN.sh" -nt "$marker" ]; then
        die "$TEST_RUN.sh wurde nicht neu erzeugt – vcontrold erreichbar? (siehe Log oben)"
    fi
    if grep -q '"\$[CR]\{0,1\}[0-9][0-9]*"' "$RUN_DIR/$TEST_RUN.sh"; then
        die "$TEST_RUN.sh enthält nicht ersetzte Platzhalter."
    fi
    info "$TEST_RUN.sh erzeugt und ausgeführt – Werte in Symcon prüfen"
fi

step "Ergebnis"
if [ "$DRY_RUN" -eq 1 ]; then
    info "$CHANGES Datei(en) unter /etc würden geändert"
else
    info "$CHANGES Datei(en) unter /etc geändert"
fi
if [ "$VCONTROLD_CHANGED" -eq 1 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        warn "Die vcontrold-Konfiguration würde geändert; aktiv wird sie erst nach einem Neustart von vcontrold."
    else
        warn "Die vcontrold-Konfiguration wurde geändert, ist aber erst nach einem Neustart aktiv:"
        info "  flock -w 120 $LOCK_FILE sh -c 'sudo systemctl stop vcontrold; sleep 3; sudo systemctl start vcontrold'"
        info "  (nicht restart: der neue Prozess startet sonst, bevor Port/TTY frei sind, und bricht ab)"
        info "danach testen:"
        info "  flock -w 30 $LOCK_FILE $VCLIENT -h localhost:3002 -c getTempA"
        info "alte Fassung: $VCONTROLD_DST/*.xml.bak"
    fi
fi
