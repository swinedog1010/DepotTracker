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
    # 1. Prüfe, ob die Umgebungsvariable DEPOT_GPG_PASS gesetzt ist (z.B. durch CI/CD oder .bashrc)
    if [[ -n "${DEPOT_GPG_PASS:-}" ]]; then
        # Wenn ja, gib sie auf der Standardausgabe aus
        printf '%s' "$DEPOT_GPG_PASS"
        # Beende die Funktion erfolgreich
        return 0
    fi
    
    # 2. Prüfe, ob die Standard-Passwort-Datei existiert
    if [[ -f "$PASS_FILE_DEFAULT" ]]; then
        # Trimme Zeilenumbrüche (\r\n) aus der Datei und gib den Inhalt aus
        # Dies schützt vor Fehlern, wenn jemand "echo 'pass' > datei" benutzt hat
        tr -d '\r\n' < "$PASS_FILE_DEFAULT"
        # Beende die Funktion erfolgreich
        return 0
    fi
    
    # 3. Interaktiver Fallback: Prüfe ob ein interaktives Terminal (TTY) verfügbar ist
    if [[ -t 0 || -e /dev/tty ]]; then
        local pp
        # Frage den Nutzer nach der Passphrase (Ausgabe auf STDERR, damit sie nicht ins Script gepiped wird)
        printf "GPG-Passphrase fuer Backup: " >&2
        # Lese die Eingabe (ohne sie anzuzeigen: -s für silent)
        IFS= read -rs pp </dev/tty
        # Mache einen Zeilenumbruch auf STDERR nach der Eingabe
        printf "\n" >&2
        # Gib die eingegebene Passphrase auf STDOUT aus
        printf '%s' "$pp"
        # Beende die Funktion erfolgreich
        return 0
    fi
    
    # 4. Wenn alle Methoden fehlschlagen, breche mit einem Fehler ab
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
    # Speichere die Anzahl der zu behaltenden Backups in einer lokalen Variable
    local keep="$1"
    # Initialisiere ein leeres Array für die gefundenen Dateien
    local files=()
    
    # Lies die Ausgabe von 'ls' in einer while-Schleife ein
    # ls -1t sortiert nach Änderungsdatum (mtime), die neuesten Dateien kommen zuerst
    # Fehler von ls (z.B. keine Dateien) werden durch '|| true' ignoriert
    while IFS= read -r f; do
        # Wenn die gelesene Zeile nicht leer ist, füge sie dem Array 'files' hinzu
        [[ -n "$f" ]] && files+=("$f")
    done < <(ls -1t "$BACKUP_DIR"/depottracker_*.tar.gz.gpg 2>/dev/null || true)

    # Ermittle die Gesamtanzahl der gefundenen Backup-Dateien
    local total=${#files[@]}
    
    # Wenn weniger oder genau so viele Backups da sind wie das Limit vorschreibt
    if (( total <= keep )); then
        # Gib eine Info-Meldung aus und beende die Funktion, nichts zu tun
        info "Rotation: $total Backups vorhanden (Limit $keep) - nichts zu loeschen."
        return 0
    fi
    
    local idx
    # Iteriere über alle Dateien, die über das Limit hinausgehen (ab Index 'keep')
    # Da das Array nach 'neueste zuerst' sortiert ist, löschen wir hier die ältesten
    for (( idx = keep; idx < total; idx++ )); do
        # Lösche die Datei (-f unterdrückt Fehlermeldungen falls sie schreibgeschützt ist)
        rm -f "${files[$idx]}"
        # Logge die Löschung
        info "Rotation: ${files[$idx]} entfernt."
    done
}

# -----------------------------------------------------------------------------
# Hauptablauf: tar -> gpg -> rotation
# -----------------------------------------------------------------------------
run_backup() {
    # Prüfe, ob 'tar' installiert ist, falls nicht, brich ab mit Fehler
    command -v tar >/dev/null 2>&1 || fail "tar fehlt - bitte via apt-get install tar nachruesten."
    # Prüfe, ob 'gpg' installiert ist, falls nicht, brich ab mit Fehler
    command -v gpg >/dev/null 2>&1 || fail "gpg fehlt - bitte via apt-get install gnupg nachruesten."

    # Erstelle das Backup-Verzeichnis (falls es noch nicht existiert)
    mkdir -p "$BACKUP_DIR"
    # Setze strikte Rechte (nur der Besitzer darf lesen/schreiben/ausführen)
    chmod 700 "$BACKUP_DIR" 2>/dev/null || true

    # Generiere einen Zeitstempel im Format YYYYMMDD_HHMMSS
    local stamp
    stamp="$(date +%Y%m%d_%H%M%S)"
    # Definiere den Dateinamen für das unverschlüsselte Tar-Archiv
    local archive="${BACKUP_DIR}/depottracker_${stamp}.tar.gz"
    # Definiere den Dateinamen für das final verschlüsselte GPG-Archiv
    local encrypted="${archive}.gpg"

    info "Erstelle tar.gz: $archive"
    # Führe tar aus, um das Projektverzeichnis zu packen und zu komprimieren (-czf)
    # --exclude ignoriert bestimmte Ordner und Dateien, die zu groß oder unwichtig sind
    # -C wechselt ins Elternverzeichnis, um saubere relative Pfade im Archiv zu haben
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
    # Hole die Passphrase aus unserer Helper-Funktion
    local pp
    pp="$(get_passphrase)"
    
    # Pipe die Passphrase in den GPG-Befehl
    # --batch und --yes unterdrücken interaktive Nachfragen
    # --passphrase-fd 0 liest das Passwort aus dem Standard-Input (Pipe)
    # --symmetric und --cipher-algo AES256 nutzt eine sichere symmetrische Verschlüsselung
    if ! printf '%s' "$pp" \
        | gpg --batch --yes --quiet \
              --passphrase-fd 0 --pinentry-mode loopback \
              --symmetric --cipher-algo AES256 \
              --output "$encrypted" "$archive"; then
        # Wenn GPG fehlschlägt, lösche unvollständige Dateien und brich ab
        rm -f "$archive" "$encrypted"
        fail "GPG-Verschluesselung fehlgeschlagen."
    fi
    # Setze auch für die verschlüsselte Datei strikte Zugriffsrechte
    chmod 600 "$encrypted" 2>/dev/null || true

    # Klartext-tar.gz sicher entfernen, damit niemand das unverschlüsselte Backup wiederherstellen kann
    # Wenn 'shred' verfügbar ist, überschreibe die Datei mehrfach (-u = danach löschen, -z = mit Nullen auffüllen)
    if command -v shred >/dev/null 2>&1; then
        shred -uz "$archive" 2>/dev/null || rm -f "$archive"
    else
        # Fallback: normales Löschen
        rm -f "$archive"
    fi

    # Schluessel-Variable leeren, um sie aus dem Speicher zu minimieren
    pp=""

    # Logge den Erfolg
    ok "Backup erstellt: $encrypted"

    # Rufe die Rotationsfunktion auf, um alte Backups zu bereinigen
    rotate_backups "$BACKUP_KEEP"
    # Richte den automatischen Cronjob ein (schlägt leise fehl, falls es Probleme gibt)
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
