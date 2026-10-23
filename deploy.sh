#!/usr/bin/env bash
# viss2mqtt – Dateien aus dem Git-Checkout auf dem Vito-Rechner verteilen
#
# Aufruf als der Benutzer, unter dem die Cronjobs laufen (nicht als root).
# sudo wird nur für Dateien unter /etc aufgerufen.
#
#   ./deploy.sh              git pull, prüfen, verteilen, Testlauf
#   ./deploy.sh --dry-run    nur anzeigen, was sich ändern würde
#   ./deploy.sh --no-pull    ohne git pull
#   ./deploy.sh --no-test    ohne Testlauf
#
# Verteilt werden:
#   *.lst, *.tpl          -> /opt/viss2mqtt/
#   viss2mqtt.cron        -> /etc/cron.d/viss2mqtt
#   etc/vcontrold/*.xml   -> /etc/vcontrold/ (mit .bak, Neustart nur als Hinweis)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="/opt/viss2mqtt"
LOCK_FILE="$RUN_DIR/vito.lock"
OLD_LOCK_FILE="/tmp/vito.lock"
CRON_SRC="$REPO_DIR/viss2mqtt.cron"
CRON_DST="/etc/cron.d/viss2mqtt"
VCONTROLD_SRC="$REPO_DIR/etc/vcontrold"
VCONTROLD_DST="/etc/vcontrold"
VCONTROLD_FILES=(vcontrold.xml vito.xml)
VCLIENT="/usr/local/bin/vclient"
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
usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# Kopiert $1 nach $2, wenn sich der Inhalt unterscheidet.
# $3: leer = als aktueller Benutzer, "sudo" = als root, "sudo-bak" = als root mit Sicherung $2.bak
# Setzt UPDATED=1, wenn kopiert wurde (bei --dry-run: kopiert würde).
install_file() {
    local src="$1" dst="$2" mode="${3:-}"
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
    case "$mode" in
        sudo-bak)
            if [ -f "$dst" ]; then
                sudo cp -p "$dst" "$dst.bak"
            fi
            sudo install -m 0644 -o root -g root "$src" "$dst"
            ;;
        sudo)
            sudo install -m 0644 -o root -g root "$src" "$dst"
            ;;
        *)
            install -m 0644 "$src" "$dst"
            ;;
    esac
    info "aktualisiert  $dst"
}

# Prüft eine Befehlsliste und ihr Template auf die bekannten Stolperfallen.
check_run() {
    local run="$1"
    local lst="$REPO_DIR/$run.lst" tpl="$REPO_DIR/$run.tpl"
    local content tail_blanks cmd n_cmds n_tpl
    local -a cmds

    [ -f "$lst" ] || die "$lst fehlt."
    [ -f "$tpl" ] || die "$tpl fehlt."
    if [ "$(cat "$lst" "$tpl" | tr -dc '\r' | wc -c)" -gt 0 ]; then
        die "$run.lst oder $run.tpl enthält CRLF-Zeilenenden."
    fi

    # vclient -f schneidet ohne Zeilenumbruch das letzte Zeichen des letzten Befehls ab
    content="$(
        cat "$lst"
        printf x
    )"
    content="${content%x}"
    tail_blanks="${content##*[![:blank:]]}"
    content="${content%"$tail_blanks"}"
    [[ "$content" == *$'\n' ]] || die "$run.lst: nach dem letzten Befehl fehlt der Zeilenumbruch."

    mapfile -t cmds < <(grep -v '^[[:space:]]*$' "$lst" | tr -d '[:blank:]')
    n_cmds="${#cmds[@]}"
    n_tpl="$(grep -o '"\$C[0-9][0-9]*"' "$tpl" | sort -u | wc -l)"
    [ "$n_cmds" -eq "$n_tpl" ] || die "$run.lst hat $n_cmds Befehle, $run.tpl erwartet $n_tpl."

    # vcontrold kennt nur Befehle, die in vito.xml stehen
    for cmd in "${cmds[@]}"; do
        grep -q "<command name=\"$cmd\"" "$VCONTROLD_SRC/vito.xml" ||
            die "$run.lst: Befehl $cmd ist in vito.xml nicht definiert."
    done
    info "$run.lst: $n_cmds Befehle, passt zu $run.tpl und vito.xml"
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
[ -x "$VCLIENT" ] || die "$VCLIENT nicht gefunden."
command -v flock >/dev/null || die "flock nicht gefunden (Paket util-linux)."
command -v python3 >/dev/null || die "python3 nicht gefunden."
if [ ! -d "$RUN_DIR" ] || [ ! -w "$RUN_DIR" ]; then
    # im Trockenlauf reicht Lesen, damit er auch vor install.sh funktioniert
    [ "$DRY_RUN" -eq 1 ] || die "$RUN_DIR fehlt oder ist für $RUN_USER nicht beschreibbar – zuerst ./install.sh ausführen."
    warn "$RUN_DIR fehlt oder ist für $RUN_USER nicht beschreibbar – vor dem echten Lauf ./install.sh ausführen."
fi
python3 - <<'EOF' || die "paho-mqtt ab Version 2.0 ist für $RUN_USER nicht verfügbar."
import sys
import paho.mqtt
sys.exit(0 if int(paho.mqtt.__version__.split(".")[0]) >= 2 else 1)
EOF
info "Benutzer $RUN_USER, Checkout $REPO_DIR, Laufzeit $RUN_DIR"
[ "$DRY_RUN" -eq 0 ] || info "Trockenlauf: es wird nichts geändert"

if [ "$PULL" -eq 1 ]; then
    step "Git"
    if ! git -C "$REPO_DIR" diff --quiet || ! git -C "$REPO_DIR" diff --cached --quiet; then
        die "Lokale Änderungen im Checkout $REPO_DIR (git status) – bitte erst klären."
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        git -C "$REPO_DIR" fetch --quiet
        info "Neue Commits (noch nicht geholt, der Vergleich unten nutzt den aktuellen Stand):"
        git -C "$REPO_DIR" log --oneline 'HEAD..@{u}' | sed 's/^/     /'
    else
        before="$(git -C "$REPO_DIR" rev-parse HEAD)"
        git -C "$REPO_DIR" pull --ff-only --quiet
        after="$(git -C "$REPO_DIR" rev-parse HEAD)"
        if [ "$before" != "$after" ]; then
            git -C "$REPO_DIR" log --oneline "$before..$after" | sed 's/^/   /'
            # deploy.sh selbst kann sich geändert haben -> neue Fassung starten
            exec bash "$REPO_DIR/deploy.sh" --no-pull "${ARGS[@]}"
        fi
        info "bereits aktuell"
    fi
fi
info "Stand: $(git -C "$REPO_DIR" describe --tags --always --dirty)"

step "Prüfen"
for run in "${RUNS[@]}"; do
    check_run "$run"
done
python3 - "${VCONTROLD_FILES[@]/#/$VCONTROLD_SRC/}" <<'EOF' || die "vcontrold-Konfiguration ist kein gültiges XML."
import sys
import xml.etree.ElementTree as ET
for path in sys.argv[1:]:
    ET.parse(path)
EOF
info "vcontrold.xml, vito.xml: gültiges XML"
grep -q '@USER@' "$CRON_SRC" || die "viss2mqtt.cron enthält keinen Platzhalter @USER@."
info "viss2mqtt.cron: ok"

step "Laufzeitdateien ($RUN_DIR)"
if [ "$DRY_RUN" -eq 0 ]; then
    # Lock wie die Cronjobs, damit kein Lauf halb alte, halb neue Dateien liest
    exec 9>>"$LOCK_FILE"
    info "warte auf Lock $LOCK_FILE ..."
    flock -w 120 9 || die "Lock $LOCK_FILE nicht erhalten."
fi
for run in "${RUNS[@]}"; do
    install_file "$REPO_DIR/$run.lst" "$RUN_DIR/$run.lst"
    install_file "$REPO_DIR/$run.tpl" "$RUN_DIR/$run.tpl"
done
if [ "$DRY_RUN" -eq 0 ]; then
    exec 9>&-
fi

step "vcontrold-Konfiguration ($VCONTROLD_DST)"
for f in "${VCONTROLD_FILES[@]}"; do
    install_file "$VCONTROLD_SRC/$f" "$VCONTROLD_DST/$f" sudo-bak
    if [ "$UPDATED" -eq 1 ]; then
        VCONTROLD_CHANGED=1
    fi
done
[ -d /var/log/vcontrold ] || warn "/var/log/vcontrold fehlt – vcontrold kann nicht loggen (siehe install.sh)."

step "Cron ($CRON_DST)"
cron_tmp="$(mktemp)"
trap 'rm -f "$cron_tmp"' EXIT
sed "s/@USER@/$RUN_USER/g" "$CRON_SRC" >"$cron_tmp"
install_file "$cron_tmp" "$CRON_DST" sudo
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
    marker="$(mktemp)"
    trap 'rm -f "$cron_tmp" "$marker"' EXIT
    # gleicher Aufruf wie im Cronjob; sendet echte Werte an Symcon
    flock -w 120 "$LOCK_FILE" "$VCLIENT" -v \
        -f "$RUN_DIR/$TEST_RUN.lst" -t "$RUN_DIR/$TEST_RUN.tpl" -x "$RUN_DIR/$TEST_RUN.sh" \
        >"$RUN_DIR/$TEST_RUN.log" 2>&1 || true
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
    info "$CHANGES Datei(en) würden geändert"
else
    info "$CHANGES Datei(en) geändert"
fi
if [ "$VCONTROLD_CHANGED" -eq 1 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        warn "Die vcontrold-Konfiguration würde geändert; aktiv wird sie erst nach einem Neustart von vcontrold."
    else
        warn "Die vcontrold-Konfiguration wurde geändert, ist aber erst nach einem Neustart aktiv:"
        info "  flock -w 120 $LOCK_FILE sudo systemctl restart vcontrold"
        info "danach testen:"
        info "  flock -w 30 $LOCK_FILE $VCLIENT -h localhost:3002 -c getTempA"
        info "alte Fassung: $VCONTROLD_DST/*.xml.bak"
    fi
fi
