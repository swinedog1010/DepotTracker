#!/usr/bin/env bash
###############################################################################
#  DepotTracker - setup.sh  (vollstaendige Pre-Flight-Routine, Feature 5)
#  ----------------------------------------------------------------------------
#  Bringt das Projekt von "frisch geklont" in den Zustand "lauffaehig":
#
#    1. Pre-Flight: prueft gpg, curl, jq, tar, mutt sowie die Build-Tools
#       libcairo2-dev/pkg-config/python3-dev/python3-venv. Jede fehlende
#       Komponente wird PER EINZELNER [Y/n]-Rueckfrage installiert
#       (Default: Y) - es gibt keinen stillen Massen-Install.
#    2. Saubere Python-venv unter ./venv/ neu aufbauen.
#    3. pip aktualisieren und ./requirements.txt installieren.
#    4. ./depotguard.sh und ./backup.sh ausfuehrbar machen.
#
#  Aufruf:
#    chmod +x setup.sh
#    ./setup.sh                  # interaktive Pre-Flight
#    ./setup.sh --yes            # alle Prompts mit Y beantworten
#    ./setup.sh --skip-system    # Python-Teil ohne apt ausfuehren
#
#  Idempotent: kann jederzeit erneut ausgefuehrt werden.
###############################################################################

set -euo pipefail

# -----------------------------------------------------------------------------
# Pfade ermitteln (absolut, unabhaengig vom Aufrufpunkt). setup.sh liegt im
# selben Ordner wie depotguard.sh / requirements.txt - SCRIPT_DIR IST also
# bereits das Code-Verzeichnis.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_DIR="${SCRIPT_DIR}"
VENV_DIR="${CODE_DIR}/venv"
REQUIREMENTS="${CODE_DIR}/requirements.txt"
DEPOTGUARD="${CODE_DIR}/depotguard.sh"
BACKUP_SH="${CODE_DIR}/backup.sh"

# -----------------------------------------------------------------------------
# CLI-Flags
# -----------------------------------------------------------------------------
ASSUME_YES=0
SKIP_SYSTEM=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes)         ASSUME_YES=1 ;;
        --skip-system)    SKIP_SYSTEM=1 ;;
        -h|--help)
            sed -n '2,22p' "$0" | sed 's/^# *//'
            exit 0 ;;
        *)
            printf "Unbekanntes Argument: %s (siehe --help)\n" "$arg" >&2
            exit 1 ;;
    esac
done

# -----------------------------------------------------------------------------
# Farbiges Logging
# -----------------------------------------------------------------------------
C_RESET="\033[0m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[0;31m"
C_CYAN="\033[0;36m"

log()  { printf "%b[INFO]%b    %s\n"   "$C_CYAN"   "$C_RESET" "$*"; }
ok()   { printf "%b[OK]%b      %s\n"   "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%b[WARN]%b    %s\n"   "$C_YELLOW" "$C_RESET" "$*"; }
fail() { printf "%b[FEHLER]%b  %s\n"   "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Vorbedingungen
# -----------------------------------------------------------------------------
[[ -f "$REQUIREMENTS" ]] \
    || fail "requirements.txt fehlt unter $REQUIREMENTS - Setup im falschen Verzeichnis ausgefuehrt?"
[[ -f "$DEPOTGUARD" ]] \
    || fail "depotguard.sh fehlt unter $DEPOTGUARD - Setup im falschen Verzeichnis ausgefuehrt?"

# -----------------------------------------------------------------------------
# [Y/n]-Helper. Default: Y. ASSUME_YES=1 ueberspringt jede Abfrage.
# Ohne TTY (Cron, CI) wird ebenfalls automatisch mit Y beantwortet, damit
# nicht-interaktive Setups durchlaufen.
# -----------------------------------------------------------------------------
ask_yes_no() {
    local question="$1"
    if (( ASSUME_YES == 1 )); then
        printf "%s [Y/n] (auto-yes)\n" "$question"
        return 0
    fi
    if [[ ! -t 0 && ! -e /dev/tty ]]; then
        printf "%s [Y/n] (no TTY, default Y)\n" "$question"
        return 0
    fi
    local ans=""
    printf "%s [Y/n] " "$question"
    IFS= read -r ans </dev/tty || ans="Y"
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[YyJj]$ ]]
}

# -----------------------------------------------------------------------------
# Pre-Flight: System-Tools (Feature 5)
# -----------------------------------------------------------------------------
# Jeder Eintrag ist "command:apt-paket". Default-Mapping: command == package.
# python3 ist bewusst NICHT hier, weil wir auch python3-venv brauchen und
# das separat behandeln (siehe BUILD_PACKAGES weiter unten).
declare -A TOOL_PKGS=(
    [gpg]="gnupg"
    [curl]="curl"
    [jq]="jq"
    [tar]="tar"
    [mutt]="mutt"
)
TOOL_ORDER=(gpg curl jq tar mutt)

# Build-Pakete fuer cairosvg/svglib + venv. Diese pruefen wir nicht ueber
# command-Existenz, sondern ueber dpkg-query, weil libcairo2-dev keine
# Binary mitbringt.
BUILD_PACKAGES=(libcairo2-dev pkg-config python3-dev python3-venv)

# -----------------------------------------------------------------------------
# Helper: prueft, ob apt-get + sudo (oder root) verfuegbar sind.
# -----------------------------------------------------------------------------
APT_AVAILABLE=0
SUDO=""
if command -v apt-get >/dev/null 2>&1; then
    APT_AVAILABLE=1
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            APT_AVAILABLE=0
        fi
    fi
fi

apt_install() {
    # apt_install <pkg> [<pkg>...]
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "$@"
}

dpkg_installed() {
    # dpkg_installed <pkg> -> 0 wenn installiert
    dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null \
        | grep -q "install ok installed"
}

# -----------------------------------------------------------------------------
# Phase 1: Tool-Check (gpg, curl, jq, tar, mutt)
# -----------------------------------------------------------------------------
echo
log "Pre-Flight: pruefe System-Tools (gpg, curl, jq, tar, mutt) ..."
MISSING_TOOLS=()
for tool in "${TOOL_ORDER[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
        ok "  $tool: vorhanden"
    else
        warn "  $tool: FEHLT"
        MISSING_TOOLS+=("$tool")
    fi
done

if (( ${#MISSING_TOOLS[@]} > 0 )); then
    if (( SKIP_SYSTEM == 1 )); then
        warn "--skip-system gesetzt - System-Pakete werden NICHT installiert."
    elif (( APT_AVAILABLE == 0 )); then
        warn "apt-get oder sudo fehlen - bitte folgende Pakete manuell installieren:"
        for tool in "${MISSING_TOOLS[@]}"; do
            printf "    - %s (%s)\n" "$tool" "${TOOL_PKGS[$tool]}"
        done
    else
        for tool in "${MISSING_TOOLS[@]}"; do
            local_pkg="${TOOL_PKGS[$tool]}"
            if ask_yes_no "Soll '$tool' (Paket: $local_pkg) jetzt installiert werden?"; then
                apt_install "$local_pkg"
                ok "  installiert: $local_pkg"
            else
                warn "  uebersprungen: $tool - depotguard.sh kann spaeter scheitern."
            fi
        done
    fi
else
    ok "Alle Tools vorhanden."
fi

# -----------------------------------------------------------------------------
# Phase 2: Build-Pakete fuer Python-Pakete (libcairo2, etc.)
# -----------------------------------------------------------------------------
echo
log "Pre-Flight: pruefe Build-Pakete (libcairo2-dev, pkg-config, python3-dev, python3-venv) ..."
MISSING_BUILD=()
if (( APT_AVAILABLE == 1 )); then
    for pkg in "${BUILD_PACKAGES[@]}"; do
        if dpkg_installed "$pkg"; then
            ok "  $pkg: vorhanden"
        else
            warn "  $pkg: FEHLT"
            MISSING_BUILD+=("$pkg")
        fi
    done

    if (( ${#MISSING_BUILD[@]} > 0 )) && (( SKIP_SYSTEM == 0 )); then
        if ask_yes_no "Sollen die fehlenden Build-Pakete (${MISSING_BUILD[*]}) jetzt installiert werden?"; then
            apt_install "${MISSING_BUILD[@]}"
            ok "Build-Pakete installiert."
        else
            warn "Build-Pakete uebersprungen - svglib/cairosvg pip-Install kann scheitern."
        fi
    fi
else
    warn "apt-get nicht verfuegbar - Build-Pakete werden nicht geprueft."
fi

# -----------------------------------------------------------------------------
# Phase 3: Python-venv neu erstellen
# -----------------------------------------------------------------------------
echo
if [[ -d "$VENV_DIR" ]]; then
    if ask_yes_no "venv unter $VENV_DIR existiert bereits - neu aufbauen?"; then
        log "Loesche bestehende venv unter $VENV_DIR"
        rm -rf "$VENV_DIR"
    else
        log "Bestehende venv wird beibehalten."
    fi
fi

if [[ ! -d "$VENV_DIR" ]]; then
    log "Erstelle neue venv: $VENV_DIR"
    python3 -m venv "$VENV_DIR"
    ok "venv erstellt."
fi

# Python/pip-Pfade (Linux-Layout)
VENV_PYTHON="${VENV_DIR}/bin/python3"
VENV_PIP="${VENV_DIR}/bin/pip"
[[ -x "$VENV_PYTHON" ]] || fail "venv-Python nicht ausfuehrbar: $VENV_PYTHON"
[[ -x "$VENV_PIP"    ]] || fail "venv-pip nicht ausfuehrbar: $VENV_PIP"

# -----------------------------------------------------------------------------
# Phase 4: pip + requirements
# -----------------------------------------------------------------------------
echo
log "Upgrade pip in venv"
"$VENV_PYTHON" -m pip install --upgrade pip

log "Installiere Python-Pakete aus $REQUIREMENTS"
"$VENV_PIP" install -r "$REQUIREMENTS"
ok "Python-Abhaengigkeiten installiert."

# -----------------------------------------------------------------------------
# Phase 5: Ausfuehrrechte
# -----------------------------------------------------------------------------
echo
for f in "$DEPOTGUARD" "$BACKUP_SH"; do
    if [[ -f "$f" ]]; then
        chmod +x "$f"
        ok "Ausfuehrrechte gesetzt: $f"
    fi
done

# -----------------------------------------------------------------------------
# Abschluss
# -----------------------------------------------------------------------------
echo
ok "Setup abgeschlossen."
echo
printf "Naechste Schritte:\n"
printf "  1. Trage deine Gmail-Daten in credentials.json ein\n"
printf "     (Vorlage: credentials.example.json, Anleitung in README.md).\n"
printf "  2. (Empfohlen) Verschluessle die Datei einmalig mit GPG:\n"
printf "        ./depotguard.sh --encrypt-credentials\n"
printf "     Danach existiert nur noch credentials.json.gpg; zur Laufzeit\n"
printf "     wird der Klartext nur in /dev/shm entschluesselt.\n"
printf "  3. Starte den Tracker:    ./depotguard.sh\n"
printf "     Modus-Auswahl im Terminal: [1] LIVE  [2] SIMULATION  [3] READ-ONLY\n"
printf "  4. Dashboard im Browser:  http://localhost:8000\n"
printf "  5. Backups einrichten:    ./backup.sh --install-cron\n"
echo
