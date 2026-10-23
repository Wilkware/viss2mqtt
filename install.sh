#!/usr/bin/env bash
# viss2mqtt – einmalige Einrichtung auf dem Vito-Rechner
#
# Aufruf als der Benutzer, unter dem die Cronjobs laufen sollen (z. B. epc),
# aus dem Git-Checkout heraus:
#   ./install.sh
#
# Stellt eine bestehende root-Installation um und ist mehrfach ausführbar:
#   - viss2mqtt-Einträge aus den Crontabs von root und des Benutzers entfernen
#     (Sicherung unter ~/viss2mqtt-crontab-*.bak)
#   - /opt/viss2mqtt anlegen bzw. dem Benutzer übergeben (inkl. state.json)
#   - altes Lock /tmp/vito.lock entfernen
#   - /var/log/vcontrold für vcontrold anlegen
#   - danach ./deploy.sh --no-pull (verteilt Dateien und /etc/cron.d/viss2mqtt)
# Weitere Optionen werden an deploy.sh durchgereicht.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="/opt/viss2mqtt"
OLD_LOCK_FILE="/tmp/vito.lock"
VCONTROLD_LOG_DIR="/var/log/vcontrold"
RUN_USER="$(id -un)"
RUN_GROUP="$(id -gn)"
STAMP="$(date +%Y%m%d-%H%M%S)"

step() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
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

step "Voraussetzungen"
[ "$(id -u)" -ne 0 ] || die "Nicht als root starten, sondern als der Benutzer, unter dem die Cronjobs laufen sollen."
command -v sudo >/dev/null || die "sudo nicht gefunden."
[ -f "$REPO_DIR/deploy.sh" ] || die "deploy.sh nicht gefunden – install.sh aus dem Git-Checkout starten."
sudo -v
info "Benutzer $RUN_USER:$RUN_GROUP, Checkout $REPO_DIR"

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

step "Laufzeitverzeichnis $RUN_DIR"
sudo mkdir -p "$RUN_DIR"
sudo chown -R "$RUN_USER:$RUN_GROUP" "$RUN_DIR"
info "gehört jetzt $RUN_USER:$RUN_GROUP"

step "vcontrold-Log $VCONTROLD_LOG_DIR"
if [ -d "$VCONTROLD_LOG_DIR" ]; then
    info "vorhanden"
else
    sudo mkdir -p "$VCONTROLD_LOG_DIR"
    sudo chown nobody:dialout "$VCONTROLD_LOG_DIR"
    info "angelegt (nobody:dialout)"
fi

step "Verteilen"
exec bash "$REPO_DIR/deploy.sh" --no-pull "$@"
