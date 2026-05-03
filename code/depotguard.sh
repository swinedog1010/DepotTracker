#!/usr/bin/env bash
###############################################################################
#  DepotTracker - depotguard.sh
#  ----------------------------------------------------------------------------
#  Vollautomatisiertes Bash-System zur Ueberwachung eines Krypto-Depots.
#  Projekt: LB3 - 2026 (Philippe & Viggo)
#
#  Ablauf (gemaess Ablaufdiagramm):
#    1. Setup-Pruefung (Ordner, Cronjob)
#    2. CPU-Load pruefen
#    3. Cache pruefen / API-Abfragen
#    4. Depotwert berechnen
#    5. Allzeithoch (ATH) verwalten
#    6. CSV-Historie schreiben
#    7. Bei Unterdeckung: QR-Rechnung erzeugen + E-Mail versenden
#  ----------------------------------------------------------------------------
#  Abhaengigkeiten: curl, awk, base64 (Python via projektlokaler venv)
###############################################################################

# -----------------------------------------------------------------------------
# 1) STRICT MODE
# -----------------------------------------------------------------------------
# -e : Skript bricht bei jedem Fehler ab.
# -u : Verwendung undefinierter Variablen ist ein Fehler.
# -o pipefail : Pipelines schlagen fehl, sobald ein Teilbefehl fehlschlaegt.
set -euo pipefail

# -----------------------------------------------------------------------------
# 2) GLOBALE TRAP-CLEANUP-KONFIGURATION
# -----------------------------------------------------------------------------
# Alle temporaeren Dateien werden in TMP_FILES gesammelt und ausschliesslich
# ueber die cleanup-Funktion entfernt. So gibt es im restlichen Skript KEIN
# manuelles "rm -f", was die Fehlerquote reduziert.
#
# RAMDISK_CRED zeigt - falls credentials.json.gpg verwendet wird - auf die
# in /dev/shm/ entschluesselte Credential-Datei. cleanup() loescht sie
# IMMER, auch bei hartem Crash oder Signalabbruch (Feature 2).
TMP_FILES=""
RAMDISK_CRED=""

cleanup() {
    # Wird durch "trap ... EXIT" beim Verlassen des Skripts immer aufgerufen,
    # egal ob normaler Abschluss, Fehler oder Signalabbruch.
    local f
    for f in $TMP_FILES; do
        [[ -e "$f" ]] && rm -f "$f"
    done

    # --- RAM-Disk: entschluesselte Credentials sofort und restlos loeschen ---
    # Wir nutzen "shred" wenn verfuegbar (mehrfaches Ueberschreiben), sonst
    # ein einfaches rm -f als Fallback. Die Datei darf unter KEINEN
    # Umstaenden auf der Disk zurueckbleiben.
    if [[ -n "$RAMDISK_CRED" && -f "$RAMDISK_CRED" ]]; then
        if command -v shred >/dev/null 2>&1; then
            shred -uz "$RAMDISK_CRED" 2>/dev/null || rm -f "$RAMDISK_CRED"
        else
            rm -f "$RAMDISK_CRED"
        fi
    fi

    # Sicherheitsnetz: alle DepotTracker-Reste in /dev/shm dieses Prozesses
    # wegraeumen, falls sich aus irgendeinem Grund Dateien angesammelt haben
    # (z.B. nach einem fruehen Abbruch noch vor dem Setzen von RAMDISK_CRED).
    if [[ -d /dev/shm && -w /dev/shm ]]; then
        rm -f /dev/shm/depottracker."$$".* 2>/dev/null || true
    fi
}

# Kombi-Trap: cleanup laeuft bei normalem Exit UND bei Signalen. Die
# Exit-Codes folgen der Konvention 128 + Signal-Nummer, damit Cron-Logs
# den Abbruchsgrund sauber dokumentieren.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

# -----------------------------------------------------------------------------
# 3) KONFIGURATION (oben im Skript, KEINE separate config.sh)
# -----------------------------------------------------------------------------

# --- Projektverzeichnis (absolut, unabhaengig vom Aufrufpunkt) ---------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Verzeichnisse ----------------------------------------------------------
OUTPUT_DIR="${SCRIPT_DIR}/output"   # generierte QR-Rechnungen
LOG_DIR="${SCRIPT_DIR}/logs"        # Log-Dateien

# --- Dateien ----------------------------------------------------------------
LOG_FILE="${LOG_DIR}/depotguard.log"
CACHE_FILE="${SCRIPT_DIR}/price_cache.json"
ATH_FILE="${SCRIPT_DIR}/ath.txt"
HISTORY_FILE="${SCRIPT_DIR}/history.csv"
CREDENTIALS_FILE="${SCRIPT_DIR}/credentials.json"
CREDENTIALS_GPG="${SCRIPT_DIR}/credentials.json.gpg"   # GPG-verschluesselte Variante (Feature 2)
RECIPIENT_FILE="${SCRIPT_DIR}/recipient.json"   # Empfaenger-Mail aus Terminal-Setup
MODE_FILE="${SCRIPT_DIR}/mode.json"             # LIVE/SIMULATION/READ-ONLY (Feature 1)
FX_FILE="${SCRIPT_DIR}/fx_cache.json"           # FX-Wechselkurse (Feature 3)
PAPER_DEPOT_FILE="${SCRIPT_DIR}/paper_depot.json" # Simulations-Depot (Feature 1)

# --- RAM-Disk fuer entschluesselte Credentials (Feature 2) ------------------
# Auf Linux-Systemen gibt es /dev/shm als tmpfs-Mount im RAM. Auf Systemen
# ohne /dev/shm (z.B. Git-Bash unter Windows) wird ein normales TMPDIR
# benutzt - mit klar protokolliertem Hinweis, dass dort kein RAM-Schutz
# gegen Disk-Forensik besteht. In beiden Faellen sorgt die cleanup-Trap
# fuer das sofortige Loeschen der Datei beim Skript-Ende.
if [[ -d /dev/shm && -w /dev/shm ]]; then
    RAMDISK_BASE="/dev/shm"
    RAMDISK_AVAILABLE=1
else
    RAMDISK_BASE="${TMPDIR:-/tmp}"
    RAMDISK_AVAILABLE=0
fi

# Optionale GPG-Passphrase: ueber Umgebungsvariable DEPOT_GPG_PASS, oder
# (zweite Wahl) aus einer .gpg_passphrase-Datei mit chmod 600. Beides
# liegt OUTSIDE der GPG-Datei, damit das Repo selbst keine Klartext-
# Passphrase enthaelt. Fehlt beides, fragt gpg interaktiv im Terminal.
GPG_PASSPHRASE_FILE="${SCRIPT_DIR}/.gpg_passphrase"

# --- Schwellenwerte und Zeitlimits ------------------------------------------
CACHE_MAX_AGE=3600        # max. Cache-Alter in Sekunden (60 Minuten)
LOAD_THRESHOLD="2.0"      # CPU-Load-Grenze
LOAD_MAX_RETRIES=5        # max. Wartezyklen bei hoher Last
LOAD_SLEEP=10             # Pause in Sekunden zwischen Last-Pruefungen
THROTTLE_SLEEP=2          # Pause zwischen QR-Rechnung und E-Mail
STEP_DELAY=1              # Pause zwischen Hauptschritten (System-Throttling)
API_RETRIES=3             # Wiederholungen pro Coin bei API-Fehler
API_RETRY_DELAY=5         # Pause zwischen Wiederholungen
API_TIMEOUT=10            # max. Wartezeit pro API-Call in Sekunden
COIN_DELAY=3              # Pause zwischen einzelnen Coin-Abfragen
THRESHOLD_CHF=1000        # Mindestwert des Depots in CHF
LOSS_PERCENT_LIMIT=15     # max. zulaessiger Verlust in % vom ATH

# --- API-Kontingent-Schutz (Local-First + Daily-Limit) ----------------------
# Pro Kalendertag duerfen maximal DAILY_API_LIMIT Online-HTTP-Requests an
# CoinGecko gestellt werden. Der Zaehler liegt in QUOTA_FILE und wird beim
# Datumswechsel automatisch zurueckgesetzt. Tagesaktuelle Snapshots werden
# als depot_YYYY-MM-DD.json abgelegt; existiert die Datei bereits, entfaellt
# der Online-Abruf vollstaendig (Local-First).
DAILY_API_LIMIT=30
QUOTA_FILE="${SCRIPT_DIR}/counter.json"

# --- Depot-Definition (assoziatives Array Coin -> Menge) --------------------
declare -A DEPOT=(
    [bitcoin]=0.5
    [ethereum]=4.0
)

# --- API & Waehrung ---------------------------------------------------------
API_BASE="https://api.coingecko.com/api/v3/simple/price"
FIAT_CURRENCY="chf"

# --- Multi-Currency / FX-API (Feature 3) ------------------------------------
# open.er-api.com liefert kostenlose, key-freie FX-Daten. Wir laden die
# Kurse einmal pro Lauf (mit Tagescache via FX_FILE) und schreiben sie als
# Begleit-Datei zum Snapshot, damit das Dashboard internationale Aequivalente
# (USD, EUR, GBP) anzeigen kann, ohne selbst eine API zu kontaktieren.
FX_API_BASE="https://open.er-api.com/v6/latest"
FX_BASE_CURRENCY="USD"
FX_QUOTE_CURRENCIES="CHF EUR GBP JPY"
FX_CACHE_MAX_AGE=43200    # 12 Stunden - FX bewegt sich kaum, schont das Limit.

# --- Modus (Feature 1) ------------------------------------------------------
# DEPOT_MODE kennt drei Zustaende, die in prompt_for_mode() gesetzt werden:
#   "live"       -> Normales Monitoring mit doppelter Bestaetigung: echte
#                   CoinGecko-Kurse, Alarm + QR-PDF + Mailversand bei
#                   Schwellenunterschreitung.
#   "simulation" -> Paper-Trading: lokales Depot (paper_depot.json) mit
#                   100 CHF Startguthaben, keine echten Trades, kein
#                   Mailversand. Zum risikofreien Testen.
#   "readonly"   -> Nur Dashboard anzeigen: alle Aktionen (Scan, Alarm,
#                   Mail) sind komplett gesperrt.
DEPOT_MODE="live"

# --- E-Mail-Konfiguration ---------------------------------------------------
# EMAIL_RECIPIENT wird zur Laufzeit aus recipient.json geladen (Terminal-Setup
# beim ersten Start). Der Default bleibt leer, damit ein versehentliches
# Versenden ohne Setup nicht moeglich ist.
EMAIL_RECIPIENT=""
EMAIL_SENDER_NAME="DepotTracker Alarm"
EMAIL_SUBJECT="[DepotTracker] Margin Call - Depot unter Schwelle"

# SMTP-Fallback (nur falls "mutt" nicht verfuegbar ist) ----------------------
# SMTP_USER und SMTP_PASS werden zur Laufzeit aus credentials.json geladen
# (siehe load_credentials). Die Datei ist via .gitignore vom Repo
# ausgeschlossen - eine Vorlage liegt in credentials.example.json.
SMTP_SERVER="smtp.gmail.com"
SMTP_PORT="465"
SMTP_USER=""
SMTP_PASS=""

# --- QR-Rechnungs-Empfaenger (fiktiv) ---------------------------------------
QR_IBAN="CH4431999123000889012"
QR_NAME="Max Muster"
QR_STREET="Musterstrasse"
QR_HOUSE="1"
QR_PCODE="8000"
QR_CITY="Zuerich"
QR_COUNTRY="CH"

# --- Cronjob ----------------------------------------------------------------
CRON_SCHEDULE="0 9 * * *"   # taeglich um 09:00 Uhr

# --- Virtuelle Python-Umgebung ---
# Unter Ubuntu (PEP 668 / "externally-managed-environment") darf pip nicht
# mehr direkt ins System-Python schreiben. Daher haelt das Skript eine eigene
# venv vor und ruft Python und pip ausschliesslich ueber VENV_PYTHON / VENV_PIP
# auf - der einzig erlaubte System-Aufruf ist "python3 -m venv".
VENV_DIR="${SCRIPT_DIR}/venv"
VENV_PYTHON="${VENV_DIR}/bin/python3"
VENV_PIP="${VENV_DIR}/bin/pip"
# Windows-Fallback (Git-Bash / MSYS): venv legt die Executables unter Scripts ab.
if [[ ! -x "$VENV_PYTHON" && -x "${VENV_DIR}/Scripts/python.exe" ]]; then
    VENV_PYTHON="${VENV_DIR}/Scripts/python.exe"
    VENV_PIP="${VENV_DIR}/Scripts/pip.exe"
fi

# --- Webserver --------------------------------------------------------------
SERVER_SCRIPT="${SCRIPT_DIR}/server.py"
SERVER_PORT=8000
SERVER_URL="http://localhost:${SERVER_PORT}"

# -----------------------------------------------------------------------------
# 4) FARB-CODES & LOGGING
# -----------------------------------------------------------------------------
# ANSI-Escape-Sequenzen fuer farbige Ausgabe im Terminal.
C_RESET="\033[0m"
C_GREY="\033[0;37m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[0;31m"
C_CYAN="\033[0;36m"

log() {
    # log <LEVEL> <Nachricht>
    # Format: [YYYY-MM-DD HH:MM:SS] [LEVEL] Nachricht
    # Farben werden im Terminal angezeigt, aber nicht in der Logdatei.
    local level="$1"; shift
    local msg="$*"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local color="$C_GREY"
    case "$level" in
        INFO)    color="$C_GREY"   ;;
        SUCCESS) color="$C_GREEN"  ;;
        WARN)    color="$C_YELLOW" ;;
        ERROR|ALARM) color="$C_RED";;
    esac
    # Auf STDOUT mit Farbe, in Datei (falls vorhanden) ohne Farbe.
    printf "%b[%s] [%s] %s%b\n" "$color" "$ts" "$level" "$msg" "$C_RESET"
    if [[ -d "$LOG_DIR" ]]; then
        printf "[%s] [%s] %s\n" "$ts" "$level" "$msg" >> "$LOG_FILE"
    fi
}

# -----------------------------------------------------------------------------
# 4b) PRE-FLIGHT DEPENDENCY-CHECK (Feature 5)
# -----------------------------------------------------------------------------
# Stellt sicher, dass alle benoetigten System-Tools (curl, tar, gpg, jq, awk,
# python3) vor dem Start verfuegbar sind. Fehlt etwas, wird im Terminal
# eine [Y/n]-Abfrage gestellt und - bei Bestaetigung - via apt-get auto-
# matisch nachinstalliert. Auf Nicht-Debian-Systemen gibt es lediglich eine
# klare Hinweis-Meldung, damit der User manuell handeln kann.
preflight_check() {
    # mutt wird primaer fuer den Mailversand genutzt (Fallback Python-SMTP).
    # Per Spec ist es ein Pflicht-Tool und wird daher hier mitgeprueft.
    local req_sys=(curl tar gpg jq awk python3 mutt)
    local missing=()
    local cmd
    for cmd in "${req_sys[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if (( ${#missing[@]} == 0 )); then
        log INFO "Pre-Flight: alle System-Pakete vorhanden (${req_sys[*]})."
        return 0
    fi

    printf "\n%bPre-Flight: fehlende System-Pakete -> %s%b\n" \
           "$C_YELLOW" "${missing[*]}" "$C_RESET"

    # Auf Systemen ohne apt-get (macOS, RHEL ohne dnf etc.) koennen wir
    # nicht selbst installieren - klar dokumentieren und fortfahren.
    if ! command -v apt-get >/dev/null 2>&1; then
        printf "%b  apt-get nicht verfuegbar - bitte manuell installieren:%b\n" \
               "$C_YELLOW" "$C_RESET"
        printf "    %s\n\n" "${missing[*]}"
        return 1
    fi

    # Interaktive [Y/n]-Abfrage. Default auf Y, wenn Enter gedrueckt wird.
    # Falls keine TTY verfuegbar ist (Cron), brechen wir mit klarem Log ab.
    if [[ ! -t 0 && ! -e /dev/tty ]]; then
        log WARN "Keine TTY - automatische Installation nicht moeglich. Bitte interaktiv starten."
        return 1
    fi

    local ans=""
    printf "Sollen die fehlenden Pakete jetzt via apt-get installiert werden? [Y/n] "
    IFS= read -r ans </dev/tty || ans="n"
    ans="${ans:-Y}"
    if [[ ! "$ans" =~ ^[YyJj]$ ]]; then
        log WARN "Pre-Flight: Installation abgelehnt - das Skript kann scheitern."
        return 1
    fi

    # Command -> apt-Paketname mappen, wo sich die Namen unterscheiden.
    local pkgs=()
    for cmd in "${missing[@]}"; do
        case "$cmd" in
            gpg)     pkgs+=("gnupg") ;;
            python3) pkgs+=("python3" "python3-venv") ;;
            mutt)    pkgs+=("mutt") ;;
            *)       pkgs+=("$cmd") ;;
        esac
    done

    local sudo_cmd=""
    if [[ $EUID -ne 0 ]]; then
        if ! command -v sudo >/dev/null 2>&1; then
            log ERROR "Weder root noch sudo - apt-get kann nicht ausgefuehrt werden."
            return 1
        fi
        sudo_cmd="sudo"
    fi

    log INFO "apt-get update + install ${pkgs[*]} (kann ein paar Sekunden dauern) ..."
    DEBIAN_FRONTEND=noninteractive $sudo_cmd apt-get update -y >/dev/null 2>&1 || true
    if DEBIAN_FRONTEND=noninteractive $sudo_cmd apt-get install -y "${pkgs[@]}"; then
        log SUCCESS "Pre-Flight: Pakete installiert (${pkgs[*]})."
    else
        log WARN "apt-get hat einen Fehler gemeldet - bitte manuell pruefen."
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# 4c) MODE-AUSWAHL (Feature 1: Live / Simulation / Read-Only)
# -----------------------------------------------------------------------------
save_mode() {
    # Schreibt die aktuelle Modus-Wahl atomar nach mode.json. Das Frontend
    # liest die Datei via /api/mode und zeigt das passende Badge.
    local m="$1"
    local tmp
    tmp="$(mktemp)"; TMP_FILES="$TMP_FILES $tmp"
    printf '{\n  "mode": "%s",\n  "set_at": "%s"\n}\n' "$m" "$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)" > "$tmp"
    mv "$tmp" "$MODE_FILE"
}

prompt_for_mode() {
    # Fragt VOR der E-Mail-Eingabe nach dem Lauf-Modus. Zwei Optionen:
    #   1 = LIVE       -> Normal-Monitoring mit doppelter Bestaetigung
    #   2 = SIMULATION -> Paper-Trading mit echten Kursen, 100 CHF Startguthaben
    # Default ist LIVE. Bei nicht-interaktiven Laeufen (Cronjob ohne TTY)
    # wird die Abfrage uebersprungen und LIVE beibehalten.
    if [[ ! -t 0 && ! -e /dev/tty ]]; then
        DEPOT_MODE="live"
        save_mode "$DEPOT_MODE"
        log INFO "Keine TTY - bleibe im LIVE-Modus (Cron-Lauf)."
        return 0
    fi

    printf "\n%b┌─ DepotTracker - Modus waehlen ───────────────────────────┐%b\n" "$C_YELLOW" "$C_RESET"
    printf "%b│ [1] LIVE       - Echtes Monitoring (doppelte Bestaetigung)│%b\n" "$C_YELLOW" "$C_RESET"
    printf "%b│ [2] SIMULATION - Paper-Trading mit echten Live-Kursen     │%b\n" "$C_YELLOW" "$C_RESET"
    printf "%b└───────────────────────────────────────────────────────────┘%b\n\n" "$C_YELLOW" "$C_RESET"

    local choice="" attempt
    for attempt in 1 2 3; do
        printf "Auswahl [1/2] (Default: 1): "
        if ! IFS= read -r choice </dev/tty; then
            choice="1"
        fi
        choice="${choice:-1}"
        case "$choice" in
            1|live|LIVE|l|L)       DEPOT_MODE="live"; break ;;
            2|sim|simulation|SIM)  DEPOT_MODE="simulation"; break ;;
            *) printf "%bUngueltig - bitte 1 oder 2 eingeben.%b\n\n" "$C_RED" "$C_RESET"; choice="" ;;
        esac
    done

    [[ -z "$choice" ]] && DEPOT_MODE="live"
    save_mode "$DEPOT_MODE"

    case "$DEPOT_MODE" in
        live)
            # Doppelte Bestaetigung im LIVE-Modus: verhindert versehentliche
            # echte API-Calls und Mail-Versand bei Schulpraesentationen.
            printf "\n%b╔═══════════════════════════════════════════════════════════╗%b\n" "$C_RED" "$C_RESET"
            printf "%b║  ACHTUNG: LIVE-Modus aktiviert!                          ║%b\n" "$C_RED" "$C_RESET"
            printf "%b║  Echte API-Calls und Mail-Versand werden ausgefuehrt.     ║%b\n" "$C_RED" "$C_RESET"
            printf "%b╚═══════════════════════════════════════════════════════════╝%b\n\n" "$C_RED" "$C_RESET"
            local confirm=""
            printf "Fortfahren? Bitte 'ja' eingeben: "
            IFS= read -r confirm </dev/tty || confirm=""
            if [[ "$confirm" != "ja" && "$confirm" != "JA" && "$confirm" != "Ja" ]]; then
                log WARN "LIVE-Modus nicht bestaetigt - wechsle zu SIMULATION."
                DEPOT_MODE="simulation"
                save_mode "$DEPOT_MODE"
            else
                log SUCCESS "Modus: LIVE (doppelt bestaetigt)"
            fi
            ;;
        simulation)
            printf "%b>>> SIMULATIONS-MODUS aktiv - Paper-Trading mit echten Live-Kursen. <<<%b\n\n" "$C_YELLOW" "$C_RESET"
            log SUCCESS "Modus: SIMULATION (Paper-Trading)"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# 5) CREDENTIALS LADEN (credentials.json -> SMTP_USER/SMTP_PASS)
# -----------------------------------------------------------------------------
prompt_for_recipient() {
    # Einziger interaktiver Schritt im Skript: fragt im Terminal nach der
    # EMPFAENGER-Mail. Wird BEI JEDEM Lauf ausgefuehrt - eine eventuell
    # vorhandene recipient.json wird ungeprueft ueberschrieben, damit der
    # Praesentations-Flow ("Lehrer tippt seine Mail ein") nie durch alte Cache-
    # Daten ausgehebelt wird.
    if [[ ! -t 0 && ! -e /dev/tty ]]; then
        log ERROR "Keine TTY verfuegbar - Empfaenger-Abfrage nicht moeglich. Bitte interaktiv starten."
        exit 1
    fi

    printf "\n%b┌─ DepotTracker Setup ─────────────────────────────────────┐%b\n" "$C_YELLOW" "$C_RESET"
    printf "%b│ An welche E-Mail-Adresse soll der Alarm verschickt werden?│%b\n" "$C_YELLOW" "$C_RESET"
    printf "%b│ (Absender-Daten sind fest hinterlegt - du brauchst nur    │%b\n" "$C_YELLOW" "$C_RESET"
    printf "%b│  die Empfaenger-Adresse einzugeben.)                      │%b\n" "$C_YELLOW" "$C_RESET"
    printf "%b└───────────────────────────────────────────────────────────┘%b\n\n" "$C_YELLOW" "$C_RESET"

    local email="" attempt
    for attempt in 1 2 3; do
        printf "Empfaenger-E-Mail: "
        if ! IFS= read -r email </dev/tty; then
            log ERROR "Keine Eingabe erhalten - Setup abgebrochen."
            exit 1
        fi
        # Whitespace trimmen.
        email="${email#"${email%%[![:space:]]*}"}"
        email="${email%"${email##*[![:space:]]}"}"

        if [[ "$email" =~ ^[^[:space:]@\"\'\`\\]+@[^[:space:]@\"\'\`\\]+\.[^[:space:]@\"\'\`\\]{2,}$ ]]; then
            break
        fi
        printf "%bUngueltige E-Mail. Bitte nochmal.%b\n\n" "$C_RED" "$C_RESET"
        email=""
    done

    if [[ -z "$email" ]]; then
        log ERROR "Drei Fehlversuche - Setup abgebrochen."
        exit 1
    fi

    # JSON atomar schreiben. Die validierte E-Mail enthaelt keine
    # JSON-Sonderzeichen (kein ", \, Whitespace), daher kein Escaping noetig.
    local tmp
    tmp="$(mktemp)"; TMP_FILES="$TMP_FILES $tmp"
    printf '{\n  "email": "%s"\n}\n' "$email" > "$tmp"
    mv "$tmp" "$RECIPIENT_FILE"
    log SUCCESS "Empfaenger gespeichert ($email) -> $RECIPIENT_FILE"
}

load_recipient() {
    # Liest die Empfaenger-Mail aus recipient.json in EMAIL_RECIPIENT.
    # Fehlt die Datei oder ist sie leer, bleibt EMAIL_RECIPIENT leer und
    # der Alarm-Pfad ueberspringt den Versand mit klarer Logmeldung.
    if [[ ! -f "$RECIPIENT_FILE" ]]; then
        log WARN "recipient.json fehlt - kein Empfaenger fuer Alarm-Mails."
        return 1
    fi
    EMAIL_RECIPIENT="$("$VENV_PYTHON" - "$RECIPIENT_FILE" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    print((data.get("email") or "").strip())
except Exception:
    sys.exit(1)
PYEOF
    )" || {
        log WARN "recipient.json konnte nicht gelesen werden."
        EMAIL_RECIPIENT=""
        return 1
    }
    if [[ -z "$EMAIL_RECIPIENT" ]]; then
        log WARN "recipient.json enthaelt keine gueltige E-Mail."
        return 1
    fi
    log INFO "Empfaenger geladen: $EMAIL_RECIPIENT"
    return 0
}

ensure_credentials_file() {
    # Legt credentials.json STILL (ohne jede Benutzerinteraktion) an,
    # falls die Datei fehlt - mit den projektweit fest hinterlegten
    # DepotTracker-Zugangsdaten. So laeuft das Skript sowohl im Cronjob
    # als auch bei der Schul-Abgabe komplett ohne Terminal-Prompt durch.
    [[ -f "$CREDENTIALS_FILE" ]] && return 0

    SMTP_USER_INPUT="depottracker@gmail.com" \
    SMTP_PASS_INPUT="ymas qwaw sfde dyfs" \
    "$VENV_PYTHON" - "$CREDENTIALS_FILE" <<'PYEOF'
import json, os, sys, tempfile
target = sys.argv[1]
data = {
    "smtp_user": os.environ["SMTP_USER_INPUT"],
    "smtp_pass": os.environ["SMTP_PASS_INPUT"],
}
d = os.path.dirname(target) or "."
fd, tmp = tempfile.mkstemp(prefix="credentials.", suffix=".tmp", dir=d)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    try:
        os.chmod(tmp, 0o600)   # best effort - unter Windows ohne Wirkung
    except OSError:
        pass
    os.replace(tmp, target)
except Exception as exc:
    if os.path.exists(tmp):
        try: os.unlink(tmp)
        except OSError: pass
    sys.stderr.write(f"credentials.json konnte nicht geschrieben werden: {exc}\n")
    sys.exit(1)
PYEOF

    if [[ -f "$CREDENTIALS_FILE" ]]; then
        log INFO "credentials.json silent angelegt (depottracker@gmail.com)."
        return 0
    fi
    log ERROR "credentials.json konnte nicht angelegt werden."
    return 1
}

decrypt_credentials_to_ramdisk() {
    # GPG-Entschluesselung von credentials.json.gpg in eine RAM-Disk-Datei.
    # Die Pfadkonstruktion folgt dem Schema:
    #     /dev/shm/depottracker.<PID>.cred-<NS-Timestamp>.json
    # damit die cleanup-Trap sicher alle Dateien dieses Prozesses einsammeln
    # kann, falls der Lauf abrupt endet.
    [[ -f "$CREDENTIALS_GPG" ]] || return 1

    if ! command -v gpg >/dev/null 2>&1; then
        log WARN "GPG nicht installiert - kann credentials.json.gpg nicht entschluesseln."
        return 1
    fi

    # Reste aus frueheren Laeufen dieses Prozesses raeumen, damit GPG
    # nicht mit "File ... exists. Overwrite? (y/N)" blockiert.
    rm -f "${RAMDISK_BASE}"/depottracker.$$.cred-*.json 2>/dev/null || true

    local stamp
    stamp="$(date +%s%N 2>/dev/null || date +%s)${RANDOM}"
    local target="${RAMDISK_BASE}/depottracker.$$.cred-${stamp}.json"

    # Passphrase-Quellen in dieser Reihenfolge:
    #   1) DEPOT_GPG_PASS (Umgebungsvariable, z.B. aus systemd-Unit)
    #   2) GPG_PASSPHRASE_FILE (.gpg_passphrase mit chmod 600)
    #   3) interaktiv ueber gpg-agent / pinentry (nur wenn TTY vorhanden)
    local pp_args=(--yes)
    if [[ -n "${DEPOT_GPG_PASS:-}" ]]; then
        pp_args+=(--batch --passphrase "$DEPOT_GPG_PASS" --pinentry-mode loopback)
    elif [[ -f "$GPG_PASSPHRASE_FILE" ]]; then
        pp_args+=(--batch --passphrase-file "$GPG_PASSPHRASE_FILE" --pinentry-mode loopback)
    fi

    if ! gpg "${pp_args[@]}" --quiet --decrypt --output "$target" \
            "$CREDENTIALS_GPG" 2>/dev/null; then
        log ERROR "GPG-Entschluesselung fehlgeschlagen - credentials.json.gpg konnte nicht gelesen werden."
        rm -f "$target" 2>/dev/null || true
        return 1
    fi

    chmod 600 "$target" 2>/dev/null || true
    RAMDISK_CRED="$target"

    if (( RAMDISK_AVAILABLE == 1 )); then
        log SUCCESS "Credentials nach RAM-Disk entschluesselt ($target)"
    else
        log WARN "Kein /dev/shm verfuegbar - Credentials liegen temporaer in $target (KEIN RAM-Schutz)"
    fi
    return 0
}

encrypt_credentials_to_gpg() {
    # Verschluesselt eine Klartext-credentials.json einmalig nach
    # credentials.json.gpg (symmetrisch, AES256). Nach erfolgreicher
    # Verschluesselung wird die Klartext-Datei mit shred/rm geloescht.
    # Dieses Hilfs-Tool ist fuer den Setup-Lauf gedacht und wird vom
    # Hauptpfad NICHT automatisch aufgerufen.
    if [[ ! -f "$CREDENTIALS_FILE" ]]; then
        log ERROR "credentials.json fehlt - nichts zu verschluesseln."
        return 1
    fi
    if ! command -v gpg >/dev/null 2>&1; then
        log ERROR "GPG nicht installiert - Verschluesselung nicht moeglich."
        return 1
    fi

    local pp_args=()
    if [[ -n "${DEPOT_GPG_PASS:-}" ]]; then
        pp_args=(--batch --yes --passphrase "$DEPOT_GPG_PASS" --pinentry-mode loopback)
    elif [[ -f "$GPG_PASSPHRASE_FILE" ]]; then
        pp_args=(--batch --yes --passphrase-file "$GPG_PASSPHRASE_FILE" --pinentry-mode loopback)
    fi

    if ! gpg "${pp_args[@]}" --symmetric --cipher-algo AES256 \
            --output "$CREDENTIALS_GPG" "$CREDENTIALS_FILE"; then
        log ERROR "GPG-Verschluesselung fehlgeschlagen."
        return 1
    fi
    chmod 600 "$CREDENTIALS_GPG" 2>/dev/null || true

    if command -v shred >/dev/null 2>&1; then
        shred -uz "$CREDENTIALS_FILE" 2>/dev/null || rm -f "$CREDENTIALS_FILE"
    else
        rm -f "$CREDENTIALS_FILE"
    fi
    log SUCCESS "credentials.json.gpg erstellt - Klartext-Datei entfernt."
    return 0
}

load_credentials() {
    # Vorzugspfad (Feature 2): wenn credentials.json.gpg existiert, wird die
    # Datei nach RAM-Disk entschluesselt und SMTP_USER/SMTP_PASS dort gelesen.
    # Klartext-credentials.json gilt als Legacy-Fallback fuer Entwicklungs-
    # rechner ohne GPG-Setup.
    local source_file=""
    if [[ -f "$CREDENTIALS_GPG" ]]; then
        if decrypt_credentials_to_ramdisk; then
            source_file="$RAMDISK_CRED"
        else
            log WARN "GPG-Pfad fehlgeschlagen - falle auf Klartext-credentials.json zurueck (sofern vorhanden)."
        fi
    fi

    if [[ -z "$source_file" ]]; then
        if [[ ! -f "$CREDENTIALS_FILE" ]]; then
            if ! ensure_credentials_file; then
                return 1
            fi
        fi
        source_file="$CREDENTIALS_FILE"
    fi

    local out
    if ! out="$("$VENV_PYTHON" - "$source_file" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    print(data.get("smtp_user", "") or "")
    print(data.get("smtp_pass", "") or "")
except Exception:
    sys.exit(1)
PYEOF
    )"; then
        log WARN "credentials.json konnte nicht gelesen werden."
        return 1
    fi

    # Erste Zeile -> User, zweite Zeile -> App-Passwort.
    SMTP_USER="$(printf '%s\n' "$out" | sed -n '1p')"
    SMTP_PASS="$(printf '%s\n' "$out" | sed -n '2p')"

    if [[ -z "$SMTP_USER" || -z "$SMTP_PASS" ]]; then
        log WARN "credentials.json enthaelt leere SMTP-Werte."
        return 1
    fi

    log INFO "SMTP-Credentials aus credentials.json geladen ($SMTP_USER)."
    return 0
}

# -----------------------------------------------------------------------------
# 6) AUTO-SETUP (Ordner & Cronjob)
# -----------------------------------------------------------------------------
auto_setup() {
    # Erstellt benoetigte Ordner (output/, logs/) und richtet beim ersten
    # Lauf einen taeglichen Cronjob ein, damit das Skript automatisch laeuft.
    local first_run=0

    if [[ ! -d "$OUTPUT_DIR" ]]; then
        mkdir -p "$OUTPUT_DIR"
        first_run=1
    fi
    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR"
        first_run=1
    fi

    if [[ $first_run -eq 1 ]]; then
        log INFO "Erster Lauf erkannt - Verzeichnisse wurden erstellt."
    fi

    # --- Defensive Initialisierung von Datendateien ------------------------
    # Sorgt dafuer, dass spaetere Lese-Operationen (z.B. durch das Dashboard
    # oder update_ath) auf garantiert vorhandene, valide Dateien treffen.
    if [[ ! -f "$ATH_FILE" ]]; then
        echo "0" > "$ATH_FILE"
        log INFO "ATH-Datei initialisiert: $ATH_FILE (0)"
    fi
    if [[ ! -f "$HISTORY_FILE" ]]; then
        echo "Datum,Uhrzeit,Gesamtwert_CHF,Status" > "$HISTORY_FILE"
        log INFO "History-Datei initialisiert: $HISTORY_FILE"
    fi

    # --- Cronjob nur einrichten, wenn noch nicht vorhanden ------------------
    # "command -v crontab" prueft, ob crontab ueberhaupt verfuegbar ist
    # (z.B. unter WSL/Windows nicht zwingend gegeben).
    if command -v crontab >/dev/null 2>&1; then
        local cron_cmd="${CRON_SCHEDULE} ${SCRIPT_DIR}/depotguard.sh >> ${LOG_FILE} 2>&1"
        # crontab -l kann mit Exitcode 1 enden, wenn keine crontab existiert.
        local existing
        existing="$(crontab -l 2>/dev/null || true)"
        if ! echo "$existing" | grep -qF "depotguard.sh"; then
            { echo "$existing"; echo "$cron_cmd"; } | crontab -
            log SUCCESS "Cronjob eingerichtet: $cron_cmd"
        fi
    else
        log WARN "crontab nicht verfuegbar - Cronjob-Setup uebersprungen."
    fi
}

# -----------------------------------------------------------------------------
# 6b) PYTHON-VENV (Self-Healing Environment)
# -----------------------------------------------------------------------------
setup_python_env() {
    # Stellt sicher, dass eine projektlokale Python-venv existiert und alle
    # benoetigten Pakete installiert sind. Wird DIREKT NACH dem Setup-Block
    # (auto_setup -> Ordner) aufgerufen, sodass alle nachfolgenden Python-
    # Aufrufe garantiert ueber die venv laufen.

    # --- Virtuelle Python-Umgebung ---
    if [ ! -d "$VENV_DIR" ]; then
        log "INFO" "Erstelle virtuelle Python-Umgebung..."
        # Einziger erlaubter System-Aufruf von python3.
        python3 -m venv "$VENV_DIR"
        # Pfade nach Erstellung neu bestimmen (Linux vs. Windows-Layout).
        if [ -x "${VENV_DIR}/Scripts/python.exe" ]; then
            VENV_PYTHON="${VENV_DIR}/Scripts/python.exe"
            VENV_PIP="${VENV_DIR}/Scripts/pip.exe"
        fi
        log "SUCCESS" "venv erstellt."
    fi

    if ! "$VENV_PYTHON" -c "import qrbill" 2>/dev/null; then
        log "INFO" "Installiere Python-Abhaengigkeiten in venv..."
        "$VENV_PIP" install qrbill svglib reportlab cairosvg
        log "SUCCESS" "Abhaengigkeiten installiert."
    fi
}

# -----------------------------------------------------------------------------
# 7) CPU-LOAD-CHECK
# -----------------------------------------------------------------------------
check_cpu_load() {
    # Liest die 1-Minuten-Load aus /proc/loadavg und pausiert bei Ueberlast.
    # Maximal LOAD_MAX_RETRIES Versuche, danach wird trotzdem fortgesetzt.
    local attempt=1
    local load
    while (( attempt <= LOAD_MAX_RETRIES )); do
        if [[ -r /proc/loadavg ]]; then
            load="$(awk '{print $1}' /proc/loadavg)"
        else
            # Fallback fuer Systeme ohne /proc/loadavg (z.B. macOS).
            load="0.0"
        fi
        # Vergleich als Fliesskommazahl mittels awk (kein bc).
        if awk -v l="$load" -v t="$LOAD_THRESHOLD" 'BEGIN{exit !(l>t)}'; then
            log WARN "CPU-Load $load > $LOAD_THRESHOLD - Pause ${LOAD_SLEEP}s (Versuch ${attempt}/${LOAD_MAX_RETRIES})"
            sleep "$LOAD_SLEEP"
            (( attempt++ ))
        else
            log INFO "CPU-Load OK: $load"
            return 0
        fi
    done
    log WARN "CPU-Load weiterhin hoch - fahre trotzdem fort."
}

# -----------------------------------------------------------------------------
# 8) CACHE-PRUEFUNG
# -----------------------------------------------------------------------------
cache_is_fresh() {
    # Gibt 0 (true) zurueck, wenn der Cache existiert und juenger als
    # CACHE_MAX_AGE Sekunden ist; sonst 1 (false).
    [[ -f "$CACHE_FILE" ]] || return 1
    local now mtime age
    now="$(date +%s)"
    mtime="$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE")"
    age=$(( now - mtime ))
    (( age < CACHE_MAX_AGE ))
}

# -----------------------------------------------------------------------------
# 8b) LOCAL-FIRST CACHE & API-KONTINGENT (counter.json)
# -----------------------------------------------------------------------------
daily_snapshot_path() {
    # Liefert den Pfad zur Tages-Snapshot-Datei "depot_YYYY-MM-DD.json".
    # Datum wird beim Aufruf neu gelesen, sodass auch lange Lauefe ueber
    # Mitternacht hinaus auf den korrekten Tag schreiben.
    printf "%s/depot_%s.json" "$SCRIPT_DIR" "$(date +%Y-%m-%d)"
}

quota_today_count() {
    # Liest den Zaehler aus counter.json. Gibt 0 zurueck, wenn die Datei
    # fehlt, beschaedigt ist oder das Datum nicht heute ist (automatischer
    # Reset bei Tageswechsel).
    if [[ ! -f "$QUOTA_FILE" ]]; then
        echo "0"
        return
    fi
    "$VENV_PYTHON" - "$QUOTA_FILE" <<'PYEOF'
import json, sys
from datetime import date
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    if data.get("date") == str(date.today()):
        print(int(data.get("count", 0)))
    else:
        print(0)
except Exception:
    print(0)
PYEOF
}

quota_available() {
    # Erfolgreich (0), wenn der heutige Zaehler noch unter dem Limit liegt.
    local count
    count="$(quota_today_count)"
    (( count < DAILY_API_LIMIT ))
}

quota_increment() {
    # Erhoeht den Zaehler atomar um 1 und gibt den NEUEN Stand auf STDOUT
    # aus. Bei Datumswechsel wird der Zaehler implizit auf 1 zurueckgesetzt.
    DAILY_API_LIMIT_ENV="$DAILY_API_LIMIT" \
    "$VENV_PYTHON" - "$QUOTA_FILE" <<'PYEOF'
import json, os, sys, tempfile
from datetime import date
target = sys.argv[1]
today = str(date.today())
limit = int(os.environ.get("DAILY_API_LIMIT_ENV", "30"))
data = {"date": today, "count": 0, "limit": limit}
if os.path.isfile(target):
    try:
        with open(target, "r", encoding="utf-8") as f:
            existing = json.load(f)
        if existing.get("date") == today:
            data["count"] = int(existing.get("count", 0))
    except Exception:
        pass
data["count"] += 1
data["limit"] = limit
d = os.path.dirname(target) or "."
fd, tmp = tempfile.mkstemp(prefix="counter.", suffix=".tmp", dir=d)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, target)
except Exception:
    if os.path.exists(tmp):
        try: os.unlink(tmp)
        except OSError: pass
    sys.exit(1)
print(data["count"])
PYEOF
}

# -----------------------------------------------------------------------------
# 9) JSON-PARSING (minimal, nur mit awk)
# -----------------------------------------------------------------------------
extract_price() {
    # extract_price <coin>
    # Extrahiert aus dem Cache den Preis eines Coins in der konfigurierten
    # Fiat-Waehrung. Erwartetes JSON-Format:
    #   {"bitcoin":{"chf":58000.50},"ethereum":{"chf":2300.10}}
    local coin="$1"
    awk -v coin="$coin" -v fiat="$FIAT_CURRENCY" '
        {
            # Entferne Whitespace, geschweifte Klammern und Anfuehrungszeichen.
            gsub(/[ \t\r\n{}"]/, "", $0)
            # Ergebnis sieht z.B. so aus:
            #   bitcoin:chf:58000.50,ethereum:chf:2300.10
            n = split($0, parts, ",")
            for (i = 1; i <= n; i++) {
                if (parts[i] ~ ("^" coin ":" fiat ":")) {
                    split(parts[i], kv, ":")
                    print kv[3]
                    exit
                }
            }
        }
    ' "$CACHE_FILE"
}

# -----------------------------------------------------------------------------
# 10) API-ABFRAGE (mit Retry, atomarem Cache-Update)
# -----------------------------------------------------------------------------
fetch_prices() {
    # Holt fuer alle Coins im DEPOT die aktuellen Preise und schreibt sie
    # in den Cache. Bei API-Fehlern wird der alte Cache als Fallback genutzt.

    local coin
    local tmp; tmp="$(mktemp)"; TMP_FILES="$TMP_FILES $tmp"
    # Aufbau einer Komma-separierten Liste der Coin-IDs.
    local ids=""
    for coin in "${!DEPOT[@]}"; do
        ids="${ids:+$ids,}$coin"
    done

    log INFO "API-Abfrage fuer Coins: $ids"

    # Wir fragen jeden Coin einzeln in einer Schleife ab (gemaess Vorgabe).
    local first=1
    {
        echo -n "{"
        for coin in "${!DEPOT[@]}"; do
            # Pro Request prueft die Kontingent-Logik, ob noch Calls offen
            # sind. Sobald das Tageslimit waehrend eines laufenden fetch
            # erreicht ist, brechen wir kontrolliert ab - und der Fallback
            # in load_prices uebernimmt.
            if ! quota_available; then
                local used; used="$(quota_today_count)"
                log WARN "Tageslimit erreicht (${used}/${DAILY_API_LIMIT}) - fetch_prices abgebrochen."
                rm -f "$tmp"
                return 1
            fi

            local resp; resp="$(mktemp)"; TMP_FILES="$TMP_FILES $resp"
            local ok=0 attempt=1
            while (( attempt <= API_RETRIES )); do
                if curl --retry 3 --retry-delay "$API_RETRY_DELAY" \
                        --retry-connrefused -sf --max-time "$API_TIMEOUT" \
                        "${API_BASE}?ids=${coin}&vs_currencies=${FIAT_CURRENCY}" \
                        -o "$resp"; then
                    # Erfolgreicher HTTP-Request -> Counter erhoehen.
                    quota_increment >/dev/null
                    ok=1
                    break
                else
                    # Auch fehlgeschlagene Versuche zaehlen wir (sie
                    # belasten ebenfalls das CoinGecko-Kontingent).
                    quota_increment >/dev/null || true
                    log WARN "API-Fehler fuer $coin (Versuch ${attempt}/${API_RETRIES})"
                    sleep "$API_RETRY_DELAY"
                    (( attempt++ ))
                fi
            done

            if (( ok == 0 )); then
                log ERROR "API-Abfrage fuer $coin endgueltig fehlgeschlagen."
                # Zwischen-Cache verwerfen, damit wir auf den Gesamt-Fallback
                # zurueckfallen koennen.
                rm -f "$tmp"
                return 1
            fi

            # Extrahiere den Preis aus der Coin-Antwort:
            # Form: {"bitcoin":{"chf":58000.50}}
            local price
            price="$(awk -v coin="$coin" -v fiat="$FIAT_CURRENCY" '
                {
                    gsub(/[ \t\r\n{}"]/, "", $0)
                    n = split($0, parts, ",")
                    for (i=1;i<=n;i++) {
                        if (parts[i] ~ "^" coin ":" fiat ":") {
                            split(parts[i], kv, ":")
                            print kv[3]; exit
                        }
                        # Alternativ-Form: coinfiatPRICE (durch Komma-Wegfall)
                        if (parts[i] ~ ":" fiat ":") {
                            split(parts[i], kv, ":")
                            print kv[3]; exit
                        }
                    }
                }
            ' "$resp")"

            if [[ -z "$price" ]]; then
                log ERROR "Kein Preis fuer $coin in API-Antwort gefunden."
                return 1
            fi

            (( first == 1 )) || echo -n ","
            first=0
            printf '"%s":{"%s":%s}' "$coin" "$FIAT_CURRENCY" "$price"

            # Pause zwischen Coins, um die Free-API zu schonen.
            sleep "$COIN_DELAY"
        done
        echo "}"
    } > "$tmp"

    # Atomarer Cache-Tausch: erst tmp schreiben, dann mv.
    mv "$tmp" "$CACHE_FILE"
    log SUCCESS "Cache aktualisiert: $CACHE_FILE"
    return 0
}

load_prices() {
    # Schutzkette:
    #   1) Local-First   -> existiert depot_YYYY-MM-DD.json fuer HEUTE,
    #                       wird er genutzt und KEIN Online-Call gemacht.
    #   2) API-Kontingent -> haben wir heute bereits DAILY_API_LIMIT Calls
    #                       gemacht, fallen wir auf den letzten Cache zurueck
    #                       oder brechen kontrolliert ab.
    #   3) Cache-Freshness -> price_cache.json juenger als CACHE_MAX_AGE
    #                       erspart einen Online-Call innerhalb des Tages.
    #   4) Online-Abruf   -> mit Throttling (sleep, retries, max_time).
    #   5) Fehler-Fallback -> alter Cache wenn vorhanden, sonst Abbruch.
    local daily
    daily="$(daily_snapshot_path)"

    # 1) Local-First ----------------------------------------------------------
    if [[ -f "$daily" ]]; then
        log INFO "Local-First: heutiger Snapshot gefunden ($daily) - kein Online-Abruf."
        # Snapshot in price_cache.json spiegeln, damit extract_price funktioniert.
        cp "$daily" "$CACHE_FILE"
        return 0
    fi

    # 2) Kontingent-Schutz ----------------------------------------------------
    if ! quota_available; then
        local used
        used="$(quota_today_count)"
        log WARN "Tageslimit erreicht (${used}/${DAILY_API_LIMIT}) - Online-Abruf gesperrt."
        if [[ -f "$CACHE_FILE" ]]; then
            log WARN "Falle auf vorhandenen (ggf. alten) Cache zurueck."
            return 0
        fi
        log ERROR "Tageslimit erreicht UND kein lokaler Cache - kontrollierter Abbruch."
        exit 1
    fi

    # 3) Frische pruefen (zusaetzliche Schonung waehrend des Tages) ----------
    if cache_is_fresh; then
        log INFO "Cache aktuell - keine API-Abfrage noetig."
        # Auch ohne Online-Call einen Tages-Snapshot anlegen, damit
        # nachfolgende Laeufe Local-First greifen koennen.
        cp "$CACHE_FILE" "$daily"
        return 0
    fi

    # 4) Online-Abruf ---------------------------------------------------------
    if fetch_prices; then
        # Tages-Snapshot atomar aus dem frisch geschriebenen Cache ableiten.
        cp "$CACHE_FILE" "$daily"
        log SUCCESS "Tages-Snapshot gespeichert: $daily"
        # Kleine Pause nach erfolgreichem Online-Abruf - System-Throttling.
        sleep "$STEP_DELAY"
        return 0
    fi

    # 5) Fehler-Fallback ------------------------------------------------------
    if [[ -f "$CACHE_FILE" ]]; then
        log WARN "API-Fehler - nutze veralteten Cache (kein neuer Snapshot heute)."
        # Nach API-Fehler eine deutlichere Pause, um nicht in eine schnelle
        # Endlosschleife zu geraten, falls aufrufende Logik sofort wiederkommt.
        sleep "$API_RETRY_DELAY"
        return 0
    fi
    log ERROR "API-Fehler UND kein lokaler Cache - kontrollierter Abbruch."
    exit 1
}

# -----------------------------------------------------------------------------
# 10b) FX-WECHSELKURSE (Feature 3: Multi-Currency)
# -----------------------------------------------------------------------------
fx_cache_is_fresh() {
    # FX bewegt sich kaum; FX_CACHE_MAX_AGE = 12h erspart das Anschlagen
    # gegen das ohnehin schon grosszuegige Limit der API.
    [[ -f "$FX_FILE" ]] || return 1
    local now mtime age
    now="$(date +%s)"
    mtime="$(stat -c %Y "$FX_FILE" 2>/dev/null || stat -f %m "$FX_FILE" 2>/dev/null || echo 0)"
    age=$(( now - mtime ))
    (( age < FX_CACHE_MAX_AGE ))
}

fetch_fx_rates() {
    # Holt USD-basierte Wechselkurse fuer FX_QUOTE_CURRENCIES und schreibt
    # sie atomar nach fx_cache.json. Der Endpunkt benoetigt keinen API-Key
    # und liefert ein flaches JSON {"rates":{"CHF":0.91,...}}.
    if fx_cache_is_fresh; then
        log INFO "FX-Cache aktuell (< ${FX_CACHE_MAX_AGE}s) - keine FX-API-Abfrage."
        return 0
    fi

    local tmp
    tmp="$(mktemp)"; TMP_FILES="$TMP_FILES $tmp"

    if ! curl -sf --max-time "$API_TIMEOUT" \
            "${FX_API_BASE}/${FX_BASE_CURRENCY}" -o "$tmp"; then
        log WARN "FX-API nicht erreichbar - bestehender FX-Cache bleibt unveraendert."
        return 1
    fi

    if ! FX_FILE_OUT="$FX_FILE" \
         FX_BASE="$FX_BASE_CURRENCY" \
         FX_QUOTES="$FX_QUOTE_CURRENCIES" \
         "$VENV_PYTHON" - "$tmp" <<'PYEOF'
import json, os, sys, tempfile
src      = sys.argv[1]
target   = os.environ["FX_FILE_OUT"]
base     = os.environ["FX_BASE"]
quotes   = os.environ["FX_QUOTES"].split()
try:
    with open(src, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as exc:
    sys.stderr.write("FX-API: ungueltiges JSON: %s\n" % exc)
    sys.exit(1)
rates_in = data.get("rates", {}) or data.get("conversion_rates", {}) or {}
out = {
    "base": base,
    "fetched_at": data.get("time_last_update_utc", "") or data.get("time_last_update", ""),
    "rates": {q: float(rates_in[q]) for q in quotes if q in rates_in},
}
d = os.path.dirname(target) or "."
fd, tmpf = tempfile.mkstemp(prefix="fx.", suffix=".tmp", dir=d)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmpf, target)
except Exception as exc:
    if os.path.exists(tmpf):
        try: os.unlink(tmpf)
        except OSError: pass
    sys.stderr.write("FX-Cache schreiben fehlgeschlagen: %s\n" % exc)
    sys.exit(1)
PYEOF
    then
        log WARN "FX-Cache konnte nicht geschrieben werden."
        return 1
    fi
    log SUCCESS "FX-Rates aktualisiert: $FX_FILE"
    return 0
}

fx_rate_for() {
    # fx_rate_for <CODE> -> druckt den Kurs CODE/FX_BASE auf STDOUT.
    # Existiert FX_FILE nicht oder fehlt der Code, wird "" gedruckt.
    local code="$1"
    [[ -f "$FX_FILE" ]] || { echo ""; return; }
    "$VENV_PYTHON" - "$FX_FILE" "$code" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    rate = data.get("rates", {}).get(sys.argv[2], "")
    if rate != "":
        print(float(rate))
except Exception:
    pass
PYEOF
}

# -----------------------------------------------------------------------------
# 10c) PAPER-DEPOT (Feature 1: Simulations-Modus)
# -----------------------------------------------------------------------------
init_paper_depot() {
    # Erstellt paper_depot.json mit 100 CHF Startguthaben, falls die
    # Datei noch nicht existiert. Im Simulations-Modus wird dieses
    # lokale Depot anstelle des echten Depots verwendet.
    if [[ -f "$PAPER_DEPOT_FILE" ]]; then
        log INFO "Paper-Depot geladen: $PAPER_DEPOT_FILE"
        return 0
    fi

    "$VENV_PYTHON" - "$PAPER_DEPOT_FILE" <<'PYEOF'
import json, os, sys, tempfile
from datetime import datetime
target = sys.argv[1]
data = {
    "balance_chf": 100.00,
    "holdings": {},
    "trades": [],
    "created_at": datetime.now().isoformat(),
    "description": "Simulations-Depot mit 100 CHF Startguthaben"
}
d = os.path.dirname(target) or "."
fd, tmp = tempfile.mkstemp(prefix="paper_depot.", suffix=".tmp", dir=d)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, target)
except Exception as exc:
    if os.path.exists(tmp):
        try: os.unlink(tmp)
        except OSError: pass
    sys.stderr.write("paper_depot.json konnte nicht erstellt werden: %s\n" % exc)
    sys.exit(1)
PYEOF

    log SUCCESS "Paper-Depot erstellt: $PAPER_DEPOT_FILE (100.00 CHF)"
}

read_paper_balance() {
    # Liest das aktuelle Guthaben aus paper_depot.json.
    # Gibt den Wert als Dezimalzahl auf STDOUT aus.
    "$VENV_PYTHON" - "$PAPER_DEPOT_FILE" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    print("%.2f" % float(data.get("balance_chf", 0)))
except Exception:
    print("100.00")
PYEOF
}

# -----------------------------------------------------------------------------
# 11) DEPOTWERT BERECHNEN (Fliesskomma via awk)
# -----------------------------------------------------------------------------
calculate_total() {
    # Summiert Kurs * Menge fuer alle Coins im DEPOT und schreibt das
    # Ergebnis (mit zwei Nachkommastellen) auf STDOUT.
    local total="0"
    local coin price amount
    for coin in "${!DEPOT[@]}"; do
        amount="${DEPOT[$coin]}"
        price="$(extract_price "$coin")"
        if [[ -z "$price" ]]; then
            log ERROR "Preis fuer $coin nicht im Cache - Berechnung unmoeglich."
            exit 1
        fi
        log INFO "  $coin: $amount x $price $FIAT_CURRENCY"
        total="$(awk -v t="$total" -v p="$price" -v a="$amount" \
                 'BEGIN{printf "%.6f", t + (p*a)}')"
    done
    awk -v t="$total" 'BEGIN{printf "%.2f", t}'
}

# -----------------------------------------------------------------------------
# 12) ATH (ALLZEITHOCH) VERWALTUNG
# -----------------------------------------------------------------------------
update_ath() {
    # update_ath <aktuellerWert> -> gibt das (ggf. neue) ATH zurueck.
    local current="$1"
    local ath
    if [[ -f "$ATH_FILE" ]]; then
        ath="$(cat "$ATH_FILE")"
    else
        ath="$current"
        echo "$ath" > "$ATH_FILE"
        log INFO "ATH initialisiert: $ath"
    fi
    if awk -v c="$current" -v a="$ath" 'BEGIN{exit !(c>a)}'; then
        ath="$current"
        echo "$ath" > "$ATH_FILE"
        log SUCCESS "Neues Allzeithoch: $ath $FIAT_CURRENCY"
    fi
    echo "$ath"
}

# -----------------------------------------------------------------------------
# 13) CSV-HISTORIE
# -----------------------------------------------------------------------------
append_history() {
    # append_history <Wert> <Status>
    # Haengt eine Zeile an history.csv an. Beim ersten Aufruf wird ein
    # Header geschrieben (Datum,Uhrzeit,Gesamtwert_CHF,Status).
    local value="$1"
    local status="$2"
    if [[ ! -f "$HISTORY_FILE" ]]; then
        echo "Datum,Uhrzeit,Gesamtwert_CHF,Status" > "$HISTORY_FILE"
    fi
    printf "%s,%s,%s,%s\n" "$(date +%Y-%m-%d)" "$(date +%H:%M:%S)" "$value" "$status" \
        >> "$HISTORY_FILE"
}

# -----------------------------------------------------------------------------
# 14) QR-RECHNUNG (Schweizer QR-Bill)
# -----------------------------------------------------------------------------
generate_qr_bill() {
    # generate_qr_bill <Betrag> <Zieldatei.pdf>
    # Erzeugt eine druckfertige Schweizer QR-Rechnung als PDF.
    # qrbill bietet selbst kein PDF-Output, daher der Zweischritt:
    #   1) qrbill schreibt SVG in einen StringIO-Puffer
    #   2) svglib konvertiert das SVG in ein ReportLab-Drawing
    #   3) reportlab.graphics.renderPDF schreibt es als PDF auf die Disk
    # Alle drei Module sind ueber requirements.txt in der venv installiert.
    local amount="$1"
    local target="$2"

    set +e
    "$VENV_PYTHON" - "$amount" "$target" <<'PYEOF'
import io
import sys
from qrbill import QRBill
from svglib.svglib import svg2rlg
from reportlab.graphics import renderPDF

amount = sys.argv[1]
target = sys.argv[2]

# Empfaengerdaten (fiktiv) sind hier hart codiert,
# damit das Bash-Skript die Werte direkt steuern kann.
bill = QRBill(
    account="CH4431999123000889012",
    creditor={
        "name": "Max Muster",
        "street": "Musterstrasse",
        "house_num": "1",
        "pcode": "8000",
        "city": "Zuerich",
        "country": "CH",
    },
    amount=amount,
    currency="CHF",
    reference_number="210000000003139471430009017",
    additional_information="DepotTracker - Margin Call",
    language="de",
)

# Schritt 1: SVG in einen Puffer schreiben (kein Tempfile noetig).
svg_buf = io.StringIO()
bill.as_svg(svg_buf)
svg_bytes = svg_buf.getvalue().encode("utf-8")

# Schritt 2 + 3: SVG -> Drawing -> PDF.
drawing = svg2rlg(io.BytesIO(svg_bytes))
if drawing is None:
    raise RuntimeError("QR-Rechnung konnte nicht in PDF umgewandelt werden.")
renderPDF.drawToFile(drawing, target)
PYEOF
    if [ $? -ne 0 ] || [ ! -f "$target" ]; then
        echo "[ERROR] QR-Rechnung Erstellung fehlgeschlagen. Abbruch."
        exit 1
    fi
    echo "[SUCCESS] QR-Rechnung (PDF) erstellt: $target"
    set -e
}

# -----------------------------------------------------------------------------
# 15) E-MAIL-VERSAND (mutt primaer, Python-SMTP als Fallback)
# -----------------------------------------------------------------------------
send_email() {
    # send_email <PDF-Anhang> <Text-Body-Datei> [<HTML-Body-Datei>]
    # Drittes Argument ist optional - wird es uebergeben, wird die Mail
    # als multipart/alternative versendet (Text + HTML-Variante).
    local attach="$1"
    local body_text="$2"
    local body_html="${3:-}"

    # --- Primaer: mutt -------------------------------------------------------
    # mutt versendet aus Stabilitaetsgruenden nur den Text-Body. Die HTML-
    # Variante wird ausschliesslich vom Python-SMTP-Fallback gerendert.
    if command -v mutt >/dev/null 2>&1; then
        if mutt -s "$EMAIL_SUBJECT" -a "$attach" -- "$EMAIL_RECIPIENT" < "$body_text"; then
            log SUCCESS "E-Mail via mutt versendet an $EMAIL_RECIPIENT"
            return 0
        fi
        log WARN "mutt-Versand fehlgeschlagen - verwende SMTP-Fallback."
    else
        log WARN "mutt nicht installiert - verwende SMTP-Fallback."
    fi

    # --- Fallback: Python smtplib (Gmail via SMTP_SSL auf Port 465) ----------
    # Mit HTML-Body wird die Mail als multipart/alternative aufgebaut, der
    # PDF-Anhang via msg.add_attachment(maintype="application", subtype="pdf").
    SMTP_SERVER="$SMTP_SERVER" SMTP_PORT="$SMTP_PORT" \
    SMTP_USER="$SMTP_USER" SMTP_PASS="$SMTP_PASS" \
    EMAIL_RECIPIENT="$EMAIL_RECIPIENT" \
    EMAIL_SENDER_NAME="$EMAIL_SENDER_NAME" \
    EMAIL_SUBJECT="$EMAIL_SUBJECT" \
    "$VENV_PYTHON" - "$attach" "$body_text" "$body_html" <<'PYEOF'
import os, sys, smtplib, ssl
from email.message import EmailMessage

attach_path = sys.argv[1]
text_path   = sys.argv[2]
html_path   = sys.argv[3] if len(sys.argv) > 3 else ""

msg = EmailMessage()
msg["Subject"] = os.environ["EMAIL_SUBJECT"]
msg["From"]    = f'{os.environ["EMAIL_SENDER_NAME"]} <{os.environ["SMTP_USER"]}>'
msg["To"]      = os.environ["EMAIL_RECIPIENT"]

# 1) Plain-Text als primaerer Body. Pflicht, damit die Nachricht auch
#    in reinen Text-Clients (CLI-Mail-Reader, Spam-Filter-Preview) lesbar
#    bleibt.
with open(text_path, "r", encoding="utf-8") as f:
    msg.set_content(f.read())

# 2) HTML-Variante als alternativer Body (multipart/alternative). Mail-
#    Clients wie Gmail/Outlook zeigen die HTML-Version automatisch an.
if html_path and os.path.isfile(html_path):
    with open(html_path, "r", encoding="utf-8") as f:
        msg.add_alternative(f.read(), subtype="html")

# 3) Anhang. Endung steuert den MIME-Type - PDF ist hier der Standardfall.
with open(attach_path, "rb") as f:
    data = f.read()
fname = os.path.basename(attach_path)
if fname.endswith(".pdf"):
    maintype, subtype = "application", "pdf"
elif fname.endswith(".svg"):
    maintype, subtype = "image", "svg+xml"
elif fname.endswith(".png"):
    maintype, subtype = "image", "png"
else:
    maintype, subtype = "application", "octet-stream"
msg.add_attachment(data, maintype=maintype, subtype=subtype, filename=fname)

ctx = ssl.create_default_context()
with smtplib.SMTP_SSL(os.environ["SMTP_SERVER"], int(os.environ["SMTP_PORT"]), context=ctx) as s:
    s.login(os.environ["SMTP_USER"], os.environ["SMTP_PASS"])
    s.send_message(msg)
print("OK")
PYEOF

    if [[ $? -eq 0 ]]; then
        log SUCCESS "E-Mail via SMTP versendet an $EMAIL_RECIPIENT"
        return 0
    fi
    log ERROR "E-Mail-Versand komplett fehlgeschlagen."
    return 1
}

# -----------------------------------------------------------------------------
# 16) ALARM-WORKFLOW
# -----------------------------------------------------------------------------
handle_alarm() {
    # handle_alarm <aktuellerWert> <ATH> <Verlust> <VerlustProzent>
    local current="$1" ath="$2" loss="$3" loss_pct="$4"

    log ALARM "ALARM ausgeloest - Depotwert: $current $FIAT_CURRENCY (-${loss_pct}% vom ATH ${ath})"

    # Empfaenger-Schutz: ohne EMAIL_RECIPIENT kein Versand, sonst SMTP-Fehler.
    if [[ -z "$EMAIL_RECIPIENT" ]]; then
        log WARN "Kein Empfaenger gesetzt (recipient.json fehlt) - Alarm-Mail uebersprungen."
        return 0
    fi

    # Zieldatei mit Zeitstempel - fuer das Web-Dashboard nachvollziehbar.
    # Format: PDF (druckfertig), generiert ueber svglib + reportlab.
    local stamp; stamp="$(date +%Y%m%d_%H%M%S)"
    local qr_file="${OUTPUT_DIR}/qrbill_${stamp}.pdf"

    # 1) QR-Rechnung erzeugen --------------------------------------------------
    if ! generate_qr_bill "$loss" "$qr_file"; then
        log ERROR "QR-Rechnung konnte nicht erzeugt werden - Versand entfaellt."
        return 1
    fi

    # 2) Throttling vor dem E-Mail-Versand -------------------------------------
    sleep "$THROTTLE_SLEEP"

    # 3) Body-Dateien (temporaer): Plain-Text als Fallback, HTML als Haupt-
    #    Darstellung. Beide werden an send_email gereicht und dort als
    #    multipart/alternative verschickt.
    local body_text body_html
    body_text="$(mktemp)"; TMP_FILES="$TMP_FILES $body_text"
    body_html="$(mktemp)"; TMP_FILES="$TMP_FILES $body_html"

    local fiat_upper="${FIAT_CURRENCY^^}"

    # ---------- Plain-Text-Variante (Fallback fuer Text-Clients) -------------
    cat > "$body_text" <<EOF
DepotTracker - Margin Call
==========================

Hallo,

das DepotTracker-System hat einen Alarm ausgeloest.

  Aktueller Depotwert : ${current} ${fiat_upper}
  Allzeithoch (ATH)   : ${ath} ${fiat_upper}
  Verlust             : ${loss} ${fiat_upper} (${loss_pct} %)
  Schwelle            : ${THRESHOLD_CHF} ${fiat_upper}

Im Anhang finden Sie eine Schweizer QR-Rechnung als PDF
ueber den Differenzbetrag.

Freundliche Gruesse
${EMAIL_SENDER_NAME}

--
DepotTracker - LB3-Projekt 2026
EOF

    # ---------- HTML-Variante mit Inline-CSS (Haupt-Layout) ------------------
    cat > "$body_html" <<EOF
<!DOCTYPE html>
<html lang="de">
<head><meta charset="UTF-8"><title>DepotTracker Alarm</title></head>
<body style="margin:0;padding:0;background:#f4f6fa;font-family:Helvetica,Arial,sans-serif;color:#1a2238;">
  <table width="100%" cellpadding="0" cellspacing="0" border="0">
    <tr><td align="center" style="padding:32px 12px;">
      <table width="560" cellpadding="0" cellspacing="0" border="0" style="background:#ffffff;border-radius:14px;overflow:hidden;box-shadow:0 6px 28px rgba(0,0,0,0.10);">

        <tr><td style="background:linear-gradient(135deg,#ff5566,#ff8a8a);padding:26px 28px;color:#ffffff;">
          <div style="font-size:12px;letter-spacing:1.6px;text-transform:uppercase;opacity:0.9;">DepotTracker &middot; Margin Call</div>
          <div style="font-size:22px;font-weight:700;margin-top:6px;">&#9888;&#65039; Depotwert unter Schwelle</div>
        </td></tr>

        <tr><td style="padding:28px;">
          <p style="margin:0 0 18px;font-size:15px;line-height:1.6;">
            Hallo,<br><br>
            der &uuml;berwachte Depotwert hat die kritische Schwelle <strong>unterschritten</strong>.
            Bitte pr&uuml;fe deine Position umgehend.
          </p>

          <table width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:18px 0;border-collapse:separate;border-spacing:0 6px;">
            <tr><td style="padding:14px 16px;background:#fff1f3;border-left:4px solid #ff5566;border-radius:8px;">
              <div style="font-size:11px;color:#a35761;text-transform:uppercase;letter-spacing:1.2px;">Aktueller Depotwert</div>
              <div style="font-size:22px;font-weight:700;color:#ff5566;margin-top:4px;font-family:'Courier New',monospace;">${current} ${fiat_upper}</div>
            </td></tr>
            <tr><td style="padding:14px 16px;background:#f4f6fa;border-left:4px solid #cdd5e3;border-radius:8px;">
              <div style="font-size:11px;color:#7e8aa3;text-transform:uppercase;letter-spacing:1.2px;">Allzeithoch (ATH)</div>
              <div style="font-size:18px;font-weight:600;color:#1a2238;margin-top:4px;font-family:'Courier New',monospace;">${ath} ${fiat_upper}</div>
            </td></tr>
            <tr><td style="padding:14px 16px;background:#fff1f3;border-left:4px solid #ff5566;border-radius:8px;">
              <div style="font-size:11px;color:#a35761;text-transform:uppercase;letter-spacing:1.2px;">Verlust vom ATH</div>
              <div style="font-size:18px;font-weight:700;color:#ff5566;margin-top:4px;font-family:'Courier New',monospace;">&minus;${loss_pct} %</div>
            </td></tr>
            <tr><td style="padding:14px 16px;background:#f4f6fa;border-left:4px solid #cdd5e3;border-radius:8px;">
              <div style="font-size:11px;color:#7e8aa3;text-transform:uppercase;letter-spacing:1.2px;">Schwellenwert</div>
              <div style="font-size:18px;font-weight:600;color:#1a2238;margin-top:4px;font-family:'Courier New',monospace;">${THRESHOLD_CHF} ${fiat_upper}</div>
            </td></tr>
          </table>

          <div style="background:#fff8e1;border-left:4px solid #f5a623;padding:14px 16px;border-radius:6px;margin-top:18px;">
            <div style="font-size:13px;color:#6e5511;line-height:1.5;">
              &#128206; Im Anhang findest du eine <strong>Schweizer QR-Rechnung als PDF</strong>
              &uuml;ber den Differenzbetrag von <strong>${loss} ${fiat_upper}</strong>.
            </div>
          </div>
        </td></tr>

        <tr><td style="background:#0b0f1a;padding:16px 28px;text-align:center;font-size:12px;color:#7e8aa3;">
          DepotTracker &middot; LB3-Projekt 2026 &middot; Philippe &amp; Viggo
        </td></tr>

      </table>
    </td></tr>
  </table>
</body>
</html>
EOF

    # 4) E-Mail versenden ------------------------------------------------------
    send_email "$qr_file" "$body_text" "$body_html" || true
    log INFO "Alarm verarbeitet."
}

# -----------------------------------------------------------------------------
# 16b) DASHBOARD-LAUNCHER & SUCCESS-BANNER
# -----------------------------------------------------------------------------
print_success_banner() {
    # Gut sichtbarer ASCII-Rahmen, der das Ende des Setups markiert und den
    # Localhost-Link zum Anklicken bereitstellt.
    local url="$SERVER_URL"
    local line="============================================================"
    printf "\n"
    printf "%b%s%b\n" "$C_GREEN" "$line" "$C_RESET"
    printf "%b   Setup erfolgreich! Das Dashboard ist bereit.%b\n" "$C_GREEN" "$C_RESET"
    printf "\n"
    printf "%b   Oeffne dein Dashboard unter:%b\n" "$C_GREEN" "$C_RESET"
    printf "%b   %s%b\n" "$C_GREEN" "$url" "$C_RESET"
    printf "%b%s%b\n" "$C_GREEN" "$line" "$C_RESET"
    printf "\n"
}

is_server_running() {
    # Plattform-unabhaengiger Check, ob bereits ein Prozess auf SERVER_PORT
    # lauscht. Wir nutzen Python (steht durch die venv garantiert bereit),
    # damit die Pruefung sowohl unter Linux als auch unter Windows-Bash
    # zuverlaessig funktioniert.
    "$VENV_PYTHON" - "$SERVER_PORT" <<'PYEOF' >/dev/null 2>&1
import socket, sys
port = int(sys.argv[1])
s = socket.socket()
s.settimeout(1)
try:
    s.connect(("127.0.0.1", port))
    s.close()
except OSError:
    sys.exit(1)
PYEOF
}

kill_existing_server() {
    # Beendet rigoros JEDEN Prozess, der entweder auf SERVER_PORT lauscht
    # oder unser server.py ausfuehrt. So garantieren wir, dass der Lauf
    # immer mit den AKTUELLEN JSON-Daten startet (depot_*.json, recipient.json,
    # counter.json). Mehrere Methoden hintereinander, weil je nach Distri
    # mal das eine, mal das andere Tool verfuegbar ist.
    local killed=0

    # 1) PID-Datei aus letztem Lauf -> gezielt beenden.
    local pid_file="${SCRIPT_DIR}/server.pid"
    if [[ -f "$pid_file" ]]; then
        local old_pid
        old_pid="$(cat "$pid_file" 2>/dev/null || true)"
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            log INFO "Beende alten Server-Prozess (PID $old_pid via server.pid)"
            kill "$old_pid" 2>/dev/null || true
            killed=1
        fi
        rm -f "$pid_file"
    fi

    # 2) fuser -k - SIGKILL fuer alle Prozesse am TCP-Port. Standardmittel
    #    auf Ubuntu/WSL. Stiller Lauf via Redirects, da fuser sonst auf
    #    STDERR raushaut.
    if command -v fuser >/dev/null 2>&1; then
        if fuser -k "${SERVER_PORT}/tcp" >/dev/null 2>&1; then
            log INFO "Restprozesse auf Port ${SERVER_PORT} via fuser -k beendet."
            killed=1
        fi
    fi

    # 3) pkill -f - Sicherheitsnetz fuer Faelle, wo der Prozess auf einem
    #    anderen Port haengt oder fuser nicht installiert ist.
    if command -v pkill >/dev/null 2>&1; then
        if pkill -f "$SERVER_SCRIPT" 2>/dev/null; then
            log INFO "server.py-Prozesse via pkill beendet."
            killed=1
        fi
    fi

    # Wenn etwas geschossen wurde, kurz warten, bis der Port wirklich frei
    # ist - sonst kollidiert der frische Start gleich wieder.
    if (( killed == 1 )); then
        local i
        for i in 1 2 3 4 5; do
            if ! is_server_running; then
                return 0
            fi
            sleep 1
        done
        log WARN "Port ${SERVER_PORT} ist nach Kill noch belegt - frischer Start kann scheitern."
    fi
    return 0
}

start_server_background() {
    # Startet server.py im Hintergrund und legt PID + Logfile ab.
    # Den aktuellen Modus (LIVE / SIMULATION / READ-ONLY) reichen wir per
    # Environment-Variable DEPOT_MODE an den Subprozess weiter (Feature 1).
    # Der Server liest die Variable in read_mode_state() ein und liefert
    # sie via /api/mode an das Frontend.
    local server_log="${LOG_DIR}/server.log"
    local pid_file="${SCRIPT_DIR}/server.pid"
    log INFO "Starte Dashboard im Hintergrund (Modus: $DEPOT_MODE) -> $server_log"
    # nohup koppelt den Prozess vom Terminal ab, damit das Dashboard
    # weiterlaeuft, auch wenn das Skript endet.
    DEPOT_MODE="$DEPOT_MODE" nohup "$VENV_PYTHON" "$SERVER_SCRIPT" >"$server_log" 2>&1 &
    echo $! > "$pid_file"
    # Wartezeit erhoehen (WSL braucht teils 6-8 Sekunden fuer den ersten
    # Socket). 10 Versuche mit 1s Pause = max. 10 Sekunden.
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if is_server_running; then
            return 0
        fi
        sleep 1
    done
    # Server-Prozess laeuft noch? Dann ist er bloss langsam - kein Fehler.
    local started_pid
    started_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$started_pid" ]] && kill -0 "$started_pid" 2>/dev/null; then
        log INFO "Server-Prozess (PID $started_pid) laeuft - Port eventuell noch nicht bereit."
        return 0
    fi
    log WARN "Dashboard konnte nicht gestartet werden - Logs pruefen: $server_log"
    return 1
}

maybe_start_dashboard() {
    # Letzter Schritt im Skript: Dashboard IMMER frisch starten. Alte
    # Server-Prozesse werden zuerst rigoros beendet, damit der neue
    # Server garantiert die aktuellen JSON-Daten ausliest und das
    # Dashboard nicht aus einem veralteten In-Memory-Stand serviert.
    kill_existing_server

    # Server starten - Banner wird IMMER angezeigt, da der Prozess
    # zuverlaessig hochfaehrt (auch wenn der Port-Check noch nicht
    # sofort anschlaegt).
    start_server_background
    print_success_banner
}

# -----------------------------------------------------------------------------
# 17) HAUPT-ABLAUF
# -----------------------------------------------------------------------------
main() {
    # 0) Pre-Flight: System-Tools pruefen (Feature 5).
    preflight_check || true

    # 1) Optionaler Helfer: --encrypt-credentials
    if [[ "${1:-}" == "--encrypt-credentials" ]]; then
        encrypt_credentials_to_gpg
        exit $?
    fi

    auto_setup

    # 2) Modus-Auswahl (Feature 1): LIVE / SIMULATION / READ-ONLY
    prompt_for_mode

    # ------------------------------------------------------------------
    # 3) READ-ONLY-PFAD: Nur Dashboard starten, keine Aktionen.
    # ------------------------------------------------------------------
    # 3b) READ-ONLY war frueher hier - wurde entfernt.
    #     Nur noch LIVE und SIMULATION als Modi.

    # 4) Empfaenger-Mail abfragen (fuer LIVE und SIMULATION).
    prompt_for_recipient

    # 5) Python-Umgebung bereitstellen.
    setup_python_env
    log INFO "=== DepotTracker Lauf gestartet (Modus: ${DEPOT_MODE^^}) ==="

    # 6) Einmalige GPG-Verschluesselung (Feature 2):
    #    Wenn credentials.json (Klartext) existiert aber NOCH KEINE
    #    .gpg-Datei vorhanden ist, wird jetzt automatisch verschluesselt
    #    und das Original geloescht. Das passiert nur EIN einziges Mal.
    if [[ -f "$CREDENTIALS_FILE" && ! -f "$CREDENTIALS_GPG" ]]; then
        if command -v gpg >/dev/null 2>&1; then
            log INFO "Einmalige GPG-Verschluesselung von credentials.json ..."
            if encrypt_credentials_to_gpg; then
                log SUCCESS "credentials.json wurde verschluesselt - Original entfernt."
            else
                log WARN "GPG-Verschluesselung fehlgeschlagen - Klartext bleibt bestehen."
            fi
        else
            log WARN "GPG nicht installiert - credentials.json bleibt unverschluesselt."
        fi
    fi

    # 7) Empfaenger und SMTP-Credentials laden.
    load_recipient || true
    load_credentials || true

    # ------------------------------------------------------------------
    # 8) SIMULATIONS-PFAD (Feature 1): Paper-Trading mit 100 CHF
    # ------------------------------------------------------------------
    if [[ "$DEPOT_MODE" == "simulation" ]]; then
        log INFO "SIMULATIONS-MODUS - Paper-Trading mit lokaler paper_depot.json."

        # FX-Rates fuer Dashboard laden (Feature 3). Fehlertolerant.
        fetch_fx_rates || true

        # Paper-Depot initialisieren oder laden
        init_paper_depot

        local sim_total
        sim_total="$(read_paper_balance)"
        log INFO "Paper-Depot Guthaben: $sim_total CHF"

        append_history "$sim_total" "SIM"

        log INFO "=== DepotTracker SIMULATION-Lauf beendet ==="
        maybe_start_dashboard
        return 0
    fi

    # ------------------------------------------------------------------
    # 9) LIVE-PFAD: Original-Kernlogik
    # ------------------------------------------------------------------
    check_cpu_load
    sleep "$STEP_DELAY"
    load_prices
    sleep "$STEP_DELAY"

    # FX-Rates fuer das Dashboard nachladen (Feature 3).
    fetch_fx_rates || true

    local total ath loss loss_pct status
    total="$(calculate_total)"
    log INFO "Gesamtwert Depot: $total $FIAT_CURRENCY"
    sleep "$STEP_DELAY"

    ath="$(update_ath "$total")"

    loss="$(awk -v a="$ath" -v t="$total" 'BEGIN{v=a-t; if(v<0)v=0; printf "%.2f", v}')"
    loss_pct="$(awk -v a="$ath" -v t="$total" \
                'BEGIN{ if(a<=0){print "0.00"; exit} v=(a-t)/a*100; if(v<0)v=0; printf "%.2f", v}')"

    local alarm=0
    if awk -v t="$total" -v th="$THRESHOLD_CHF" 'BEGIN{exit !(t<th)}'; then
        alarm=1
    fi
    if awk -v p="$loss_pct" -v lim="$LOSS_PERCENT_LIMIT" 'BEGIN{exit !(p>lim)}'; then
        alarm=1
    fi

    if (( alarm == 1 )); then
        status="ALARM"
        append_history "$total" "$status"
        handle_alarm "$total" "$ath" "$loss" "$loss_pct"
    else
        status="OK"
        append_history "$total" "$status"
        log SUCCESS "Status: OK - Depotwert oberhalb aller Schwellen."
    fi

    log INFO "=== DepotTracker Lauf beendet ==="
    maybe_start_dashboard
}

# Einstiegspunkt - nur ausfuehren, wenn Skript direkt aufgerufen wurde.
main "$@"
