#!/usr/bin/env bash
###############################################################################
#  DepotTracker - backup.sh
#  ----------------------------------------------------------------------------
#  Erstellt ein verschluesseltes Wochen-Backup des gesamten Projekt-
#  verzeichnisses und legt es in einem dedizierten Backup-Ordner ab.
#
#  Schritte:
#    1. tar.gz des Projekts erzeugen (ohne flatternde Daten wie venv/, logs/)
#    2. Symmetrische GPG-Verschluesselung (AES256)
#    3. Klartext-tar.gz sicher loeschen (shred wenn verfuegbar, sonst rm)
#    4. Cronjob "Sonntag 03:00" beim ersten Lauf einrichten (idempotent)
#    5. Rotation: nur die letzten BACKUP_KEEP Backups behalten
#
#  Aufruf:
#    ./backup.sh                # einmaliges Backup
#    ./backup.sh --install-cron # nur Cron-Eintrag einrichten/pruefen
#    ./backup.sh --list         # vorhandene Backups auflisten
#
#  Passphrase-Quellen (in dieser Reihenfolge):
#    1) Umgebungsvariable DEPOT_GPG_PASS
#    2) ~/.depottracker/backup.pass (chmod 600)
#    3) interaktive Eingabe (nur mit TTY)
###############################################################################

set -euo pipefail

# -----------------------------------------------------------------------------
# Pfade und Konfiguration
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# backup.sh liegt seit dem Aufraeumen unter code/. Das Wurzelverzeichnis,
# das wir als tar.gz sichern wollen, ist genau eine Ebene darueber - z.B.
# .../DepotTracker. Wir resolven es absolut, damit auch Cron- und CI-
# Aufrufe (mit anderem CWD) den richtigen Ordner sichern.
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_DIR="${DEPOT_BACKUP_DIR:-${HOME}/depottracker_backups}"
BACKUP_KEEP="${DEPOT_BACKUP_KEEP:-8}"     # ~ 2 Monate bei woechentlichem Lauf
PASS_FILE_DEFAULT="${HOME}/.depottracker/backup.pass"
LOG_FILE="${BACKUP_DIR}/backup.log"

# Cron: jeden Sonntag um 03:00 Uhr
CRON_SCHEDULE="0 3 * * 0"

# -----------------------------------------------------------------------------
# Farbiges Logging (wird zusaetzlich in $LOG_FILE persistiert)
# -----------------------------------------------------------------------------
C_RESET="\033[0m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[0;31m"
C_CYAN="\033[0;36m"

log_to_file() {
    [[ -d "$BACKUP_DIR" ]] || return 0
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}
info()  { printf "%b[INFO]%b    %s\n"   "$C_CYAN"   "$C_RESET" "$*"; log_to_file "[INFO]    $*"; }
ok()    { printf "%b[OK]%b      %s\n"   "$C_GREEN"  "$C_RESET" "$*"; log_to_file "[OK]      $*"; }
warn()  { printf "%b[WARN]%b    %s\n"   "$C_YELLOW" "$C_RESET" "$*"; log_to_file "[WARN]    $*"; }
fail()  { printf "%b[FEHLER]%b  %s\n"   "$C_RED"    "$C_RESET" "$*" >&2; log_to_file "[FEHLER] $*"; exit 1; }

# -----------------------------------------------------------------------------
# Passphrase ermitteln (Env > Datei > interaktiv)
# -----------------------------------------------------------------------------
get_passphrase() {
    if [[ -n "${DEPOT_GPG_PASS:-}" ]]; then
        printf '%s' "$DEPOT_GPG_PASS"
        return 0
    fi
    if [[ -f "$PASS_FILE_DEFAULT" ]]; then
        # Trim Whitespace, falls jemand "echo > pass" benutzt hat.
        tr -d '\r\n' < "$PASS_FILE_DEFAULT"
        return 0
    fi
    if [[ -t 0 || -e /dev/tty ]]; then
        local pp
        printf "GPG-Passphrase fuer Backup: " >&2
        IFS= read -rs pp </dev/tty
        printf "\n" >&2
        printf '%s' "$pp"
        return 0
    fi
    fail "Keine Passphrase gefunden (DEPOT_GPG_PASS / $PASS_FILE_DEFAULT / TTY)."
}

# -----------------------------------------------------------------------------
# Cronjob einrichten (idempotent)
# -----------------------------------------------------------------------------
install_cron() {
    if ! command -v crontab >/dev/null 2>&1; then
        warn "crontab nicht verfuegbar - Cron-Setup uebersprungen."
        return 1
    fi
    # SCRIPT_DIR (nicht PROJECT_ROOT) - backup.sh liegt unter code/.
    local cron_cmd="${CRON_SCHEDULE} ${SCRIPT_DIR}/backup.sh >> ${BACKUP_DIR}/backup.log 2>&1"
    local existing
    existing="$(crontab -l 2>/dev/null || true)"
    if echo "$existing" | grep -qF "${SCRIPT_DIR}/backup.sh"; then
        info "Cronjob fuer backup.sh bereits aktiv."
        return 0
    fi
    { echo "$existing"; echo "$cron_cmd"; } | crontab -
    ok "Cronjob eingerichtet: $cron_cmd"
}

# -----------------------------------------------------------------------------
# Backup-Liste anzeigen
# -----------------------------------------------------------------------------
list_backups() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        info "Noch keine Backups vorhanden ($BACKUP_DIR)."
        return 0
    fi
    info "Backups in $BACKUP_DIR:"
    ls -lh "$BACKUP_DIR"/depottracker_*.tar.gz.gpg 2>/dev/null \
        | awk '{ printf "  %s  %s  %s\n", $5, $6" "$7" "$8, $9 }' \
        || warn "Keine .tar.gz.gpg-Dateien gefunden."
}

# -----------------------------------------------------------------------------
# Rotation: aelteste Backups loeschen, bis nur BACKUP_KEEP uebrig sind
# -----------------------------------------------------------------------------
rotate_backups() {
    local keep="$1"
    local files=()
    # ls -1t sortiert nach mtime, neueste zuerst.
    while IFS= read -r f; do
        [[ -n "$f" ]] && files+=("$f")
    done < <(ls -1t "$BACKUP_DIR"/depottracker_*.tar.gz.gpg 2>/dev/null || true)

    local total=${#files[@]}
    if (( total <= keep )); then
        info "Rotation: $total Backups vorhanden (Limit $keep) - nichts zu loeschen."
        return 0
    fi
    local idx
    for (( idx = keep; idx < total; idx++ )); do
        rm -f "${files[$idx]}"
        info "Rotation: ${files[$idx]} entfernt."
    done
}

# -----------------------------------------------------------------------------
# Hauptablauf: tar -> gpg -> rotation
# -----------------------------------------------------------------------------
run_backup() {
    command -v tar >/dev/null 2>&1 || fail "tar fehlt - bitte via apt-get install tar nachruesten."
    command -v gpg >/dev/null 2>&1 || fail "gpg fehlt - bitte via apt-get install gnupg nachruesten."

    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR" 2>/dev/null || true

    local stamp
    stamp="$(date +%Y%m%d_%H%M%S)"
    local archive="${BACKUP_DIR}/depottracker_${stamp}.tar.gz"
    local encrypted="${archive}.gpg"

    info "Erstelle tar.gz: $archive"
    # Wir snapshot'en das gesamte Projekt-Wurzelverzeichnis. Excludes:
    #   - venv/, __pycache__/, logs/, output/, server.pid: regenerierbar
    #   - .git/: gehoert nicht in Off-Site-Backups (Origin ist GitHub)
    #   - alte Backups selbst, falls jemand BACKUP_DIR ins Projekt legt
    tar \
        --exclude="*/venv" \
        --exclude="*/__pycache__" \
        --exclude="*/logs" \
        --exclude="*/output" \
        --exclude="*/.git" \
        --exclude="depottracker_*.tar.gz*" \
        --exclude="*.tar.gz.gpg" \
        -czf "$archive" -C "$(dirname "$PROJECT_ROOT")" "$(basename "$PROJECT_ROOT")"

    info "Verschluessle Backup mit GPG (AES256) -> $encrypted"
    local pp
    pp="$(get_passphrase)"
    if ! printf '%s' "$pp" \
        | gpg --batch --yes --quiet \
              --passphrase-fd 0 --pinentry-mode loopback \
              --symmetric --cipher-algo AES256 \
              --output "$encrypted" "$archive"; then
        rm -f "$archive" "$encrypted"
        fail "GPG-Verschluesselung fehlgeschlagen."
    fi
    chmod 600 "$encrypted" 2>/dev/null || true

    # Klartext-tar.gz sicher entfernen.
    if command -v shred >/dev/null 2>&1; then
        shred -uz "$archive" 2>/dev/null || rm -f "$archive"
    else
        rm -f "$archive"
    fi

    # Schluessel-Variable und Heap-Reste minimieren.
    pp=""

    ok "Backup erstellt: $encrypted"

    rotate_backups "$BACKUP_KEEP"
    install_cron || true
}

# -----------------------------------------------------------------------------
# CLI-Dispatcher
# -----------------------------------------------------------------------------
case "${1:-}" in
    --install-cron)
        mkdir -p "$BACKUP_DIR"
        install_cron
        ;;
    --list)
        list_backups
        ;;
    -h|--help)
        cat <<USAGE
DepotTracker backup.sh

Aufrufe:
  $0                  Erzeugt ein neues, GPG-verschluesseltes Backup.
  $0 --install-cron   Richtet ausschliesslich den Cronjob ein.
  $0 --list           Listet vorhandene Backups in ${BACKUP_DIR} auf.

Umgebungsvariablen:
  DEPOT_GPG_PASS      Passphrase fuer die symmetrische Verschluesselung.
  DEPOT_BACKUP_DIR    Zielordner (Default: ${BACKUP_DIR}).
  DEPOT_BACKUP_KEEP   Wieviele Backups behalten (Default: 8).
USAGE
        ;;
    "")
        run_backup
        ;;
    *)
        fail "Unbekanntes Argument: $1 (siehe --help)"
        ;;
esac
