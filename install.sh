#!/usr/bin/env bash
# viss2mqtt – einmalige Einrichtung auf dem Vito-Rechner
#
# Voraussetzung: Das Repo ist nach /opt/viss2mqtt geklont und gehört dem
# Benutzer, unter dem die Cronjobs laufen sollen (z. B. epc).
#   /opt/viss2mqtt/install.sh [--state DATEI] [--keep-vcontrold] [Optionen für deploy.sh]
#
# Mehrfach ausführbar:
#   - mit --keep-vcontrold: die vorhandene /etc/vcontrold/{vcontrold,vito}.xml
#     nach local/etc/vcontrold/ übernehmen, damit deploy.sh sie nicht durch die
#     Standarddateien ersetzt (vorhandene Dateien in local/ bleiben unverändert)
#   - viss2mqtt-Einträge aus den Crontabs von root und des Benutzers entfernen
#     (Sicherung unter ~/viss2mqtt-crontab-*.bak)
#   - altes Lock /tmp/vito.lock entfernen
#   - state.json übernehmen, falls noch keine da ist: aus --state DATEI oder
#     aus der neuesten Sicherung /opt/viss2mqtt.bak-*/state.json
#   - /var/log/vcontrold für vcontrold anlegen
#   - danach ./deploy.sh --no-pull (verteilt Konfiguration und /etc/cron.d/viss2mqtt)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="/opt/viss2mqtt"
STATE_FILE="$RUN_DIR/state.json"
OLD_LOCK_FILE="/tmp/vito.lock"
VCONTROLD_LOG_DIR="/var/log/vcontrold"
RUN_USER="$(id -un)"
STAMP="$(date +%Y%m%d-%H%M%S)"
STATE_SRC=""
VCONTROLD_DIR="/etc/vcontrold"
LOCAL_VCONTROLD_DIR="$RUN_DIR/local/etc/vcontrold"
VCONTROLD_FILES=(vcontrold.xml vito.xml)
KEEP_VCONTROLD=0
DEPLOY_ARGS=()

step() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   WARNUNG: %s\n' "$*" >&2; }
die() {
    printf '\nFEHLER: %s\n' "$*" >&2
    exit 1
}

# Entfernt alle viss2mqtt-Zeilen aus einer Crontab. $1 = Benutzer, $2 = "sudo" für fremde Crontab
remove_cron_entries() {
    local user="$1" priv="${2:-}" current kept backup
    local -a cmd=(crontab)
    if [ "$priv" = "sudo" ]; then
        cmd=(sudo crontab -u "$user")
    fi

    current="$("${cmd[@]}" -l 2>/dev/null || true)"
    if [ "$(grep -c '^[^#]*viss2mqtt' <<<"$current" || true)" -eq 0 ]; then
        info "Crontab $user: keine viss2mqtt-Einträge"
        return 0
    fi
    backup="$HOME/viss2mqtt-crontab-$user-$STAMP.bak"
    printf '%s\n' "$current" >"$backup"
    kept="$(grep -v '^[^#]*viss2mqtt' <<<"$current" || true)"
    printf '%s\n' "$kept" | "${cmd[@]}" -
    info "Crontab $user: Einträge entfernt (Sicherung $backup):"
    grep '^[^#]*viss2mqtt' <<<"$current" | sed 's/^/     /'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --state)
            [ $# -ge 2 ] || die "--state braucht eine Datei."
            STATE_SRC="$2"
            shift
            ;;
        --keep-vcontrold) KEEP_VCONTROLD=1 ;;
        *) DEPLOY_ARGS+=("$1") ;;
    esac
    shift
done

step "Voraussetzungen"
[ "$(id -u)" -ne 0 ] || die "Nicht als root starten, sondern als der Benutzer, unter dem die Cronjobs laufen sollen."
[ "$REPO_DIR" = "$RUN_DIR" ] || die "install.sh liegt in $REPO_DIR – das Repo muss nach $RUN_DIR geklont sein."
[ -w "$RUN_DIR" ] || die "$RUN_DIR ist für $RUN_USER nicht beschreibbar (sudo chown -R $RUN_USER: $RUN_DIR)."
command -v sudo >/dev/null || die "sudo nicht gefunden."
# sudo -v fragt nach dem Passwort, sobald nicht alle sudoers-Regeln NOPASSWD haben
sudo -n true 2>/dev/null || sudo -v
info "Benutzer $RUN_USER, Checkout $REPO_DIR"

step "Alte Cronjobs"
remove_cron_entries root sudo
remove_cron_entries "$RUN_USER"
if [ -e "$OLD_LOCK_FILE" ]; then
    # einen gerade laufenden alten Job noch zu Ende laufen lassen
    info "warte auf laufenden Job ($OLD_LOCK_FILE) ..."
    sudo flock -w 120 "$OLD_LOCK_FILE" true || die "Lock $OLD_LOCK_FILE nicht erhalten."
    sudo rm -f "$OLD_LOCK_FILE"
    info "altes Lock entfernt"
fi

step "Zählerstände ($STATE_FILE)"
if [ -z "$STATE_SRC" ]; then
    STATE_SRC="$(ls -1d "$RUN_DIR".bak-*/state.json 2>/dev/null | sort | tail -n 1 || true)"
fi
if [ -f "$STATE_FILE" ]; then
    info "vorhanden, bleibt unverändert"
elif [ -n "$STATE_SRC" ]; then
    sudo cat "$STATE_SRC" >"$STATE_FILE"
    info "übernommen aus $STATE_SRC"
else
    info "keine Sicherung gefunden – der erste Wert jedes Zählers wird ungeprüft übernommen"
fi

step "vcontrold-Log $VCONTROLD_LOG_DIR"
if [ -d "$VCONTROLD_LOG_DIR" ]; then
    info "vorhanden"
else
    sudo mkdir -p "$VCONTROLD_LOG_DIR"
    sudo chown nobody:dialout "$VCONTROLD_LOG_DIR"
    info "angelegt (nobody:dialout)"
fi

step "Eigene vcontrold-Konfiguration ($LOCAL_VCONTROLD_DIR)"
if [ "$KEEP_VCONTROLD" -eq 1 ]; then
    mkdir -p "$LOCAL_VCONTROLD_DIR"
    for f in "${VCONTROLD_FILES[@]}"; do
        src="$VCONTROLD_DIR/$f"
        dst="$LOCAL_VCONTROLD_DIR/$f"
        if [ -f "$dst" ]; then
            info "vorhanden, bleibt unverändert: $dst"
        elif ! sudo test -f "$src"; then
            warn "$src fehlt – es gilt die Standarddatei aus dem Repository."
        elif sudo cmp -s "$src" "$REPO_DIR/etc/vcontrold/$f"; then
            warn "$src entspricht der Standarddatei – nicht übernommen. Wurde sie schon überschrieben? Eigene Fassung ggf. aus $src.bak nach $dst kopieren."
        else
            sudo cat "$src" >"$dst"
            info "übernommen: $src -> $dst"
        fi
    done
else
    info "nicht angefordert (--keep-vcontrold)"
fi

step "Verteilen"
exec bash "$REPO_DIR/deploy.sh" --no-pull ${DEPLOY_ARGS[@]+"${DEPLOY_ARGS[@]}"}
