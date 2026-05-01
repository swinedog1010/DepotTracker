#!/usr/bin/env bash
###############################################################################
#  DepotTracker - setup.sh
#  ----------------------------------------------------------------------------
#  Einmaliges Setup-Skript fuer WSL / Ubuntu. Bringt das Projekt von "frisch
#  geklont" in den Zustand "lauffaehig":
#
#    1. System-Abhaengigkeiten via apt installieren
#       (libcairo2-dev, pkg-config, python3-dev, python3-venv)
#    2. Saubere Python-venv unter code/venv/ neu aufbauen
#    3. pip aktualisieren und code/requirements.txt installieren
#    4. code/depotguard.sh ausfuehrbar machen
#
#  Aufruf:
#    chmod +x setup.sh
#    ./setup.sh
#
#  Idempotent: kann jederzeit erneut ausgefuehrt werden, um die venv
#  vollstaendig zurueckzusetzen.
###############################################################################

set -euo pipefail

# -----------------------------------------------------------------------------
# Pfade ermitteln (absolut, unabhaengig vom Aufrufpunkt)
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_DIR="${SCRIPT_DIR}/code"
VENV_DIR="${CODE_DIR}/venv"
REQUIREMENTS="${CODE_DIR}/requirements.txt"
DEPOTGUARD="${CODE_DIR}/depotguard.sh"

# -----------------------------------------------------------------------------
# Farbiges Logging (rein optisch)
# -----------------------------------------------------------------------------
C_RESET="\033[0m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[0;31m"
C_CYAN="\033[0;36m"

log()  { printf "%b[INFO]%b    %s\n"    "$C_CYAN"   "$C_RESET" "$*"; }
ok()   { printf "%b[OK]%b      %s\n"    "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%b[WARN]%b    %s\n"    "$C_YELLOW" "$C_RESET" "$*"; }
fail() { printf "%b[FEHLER]%b  %s\n" "$C_RED"   "$C_RESET" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Vorbedingungen
# -----------------------------------------------------------------------------
[[ -d "$CODE_DIR" ]] \
    || fail "Verzeichnis 'code/' nicht gefunden unter $CODE_DIR"
[[ -f "$REQUIREMENTS" ]] \
    || fail "code/requirements.txt fehlt - Setup kann keine Pakete installieren."

# -----------------------------------------------------------------------------
# 1) System-Abhaengigkeiten via apt
# -----------------------------------------------------------------------------
# libcairo2-dev + pkg-config + python3-dev werden gebraucht, damit pycairo
# bzw. cffi (von cairosvg/svglib) sauber kompiliert. python3-venv stellt
# unter Ubuntu/Debian das "venv"-Modul bereit (auf manchen Minimal-Images
# ist es nicht in python3 enthalten).
APT_PACKAGES=(libcairo2-dev pkg-config python3-dev python3-venv)

log "Installiere System-Pakete: ${APT_PACKAGES[*]}"
if ! command -v apt-get >/dev/null 2>&1; then
    fail "apt-get nicht gefunden - dieses Setup ist fuer Debian/Ubuntu/WSL gedacht."
fi

# Wenn das Skript nicht als root laeuft, brauchen wir sudo.
SUDO=""
if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
        fail "Weder root-Rechte noch sudo verfuegbar - apt install nicht moeglich."
    fi
    SUDO="sudo"
fi

# DEBIAN_FRONTEND=noninteractive verhindert, dass apt Konfig-Dialoge oeffnet.
DEBIAN_FRONTEND=noninteractive $SUDO apt-get update -y
DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "${APT_PACKAGES[@]}"
ok "System-Pakete installiert."

# -----------------------------------------------------------------------------
# 2) Python-venv unter code/venv/ vollstaendig neu erstellen
# -----------------------------------------------------------------------------
if [[ -d "$VENV_DIR" ]]; then
    log "Loesche bestehende venv unter $VENV_DIR"
    rm -rf "$VENV_DIR"
fi

log "Erstelle neue venv: $VENV_DIR"
python3 -m venv "$VENV_DIR"
ok "venv erstellt."

# Python/pip-Pfade in der venv (Linux-Layout - auf WSL/Ubuntu garantiert).
VENV_PYTHON="${VENV_DIR}/bin/python3"
VENV_PIP="${VENV_DIR}/bin/pip"

[[ -x "$VENV_PYTHON" ]] || fail "venv-Python nicht ausfuehrbar: $VENV_PYTHON"
[[ -x "$VENV_PIP"    ]] || fail "venv-pip nicht ausfuehrbar: $VENV_PIP"

# -----------------------------------------------------------------------------
# 3) pip upgraden + Pakete aus requirements.txt installieren
# -----------------------------------------------------------------------------
log "Upgrade pip in venv"
"$VENV_PYTHON" -m pip install --upgrade pip

log "Installiere Python-Pakete aus $REQUIREMENTS"
"$VENV_PIP" install -r "$REQUIREMENTS"
ok "Python-Abhaengigkeiten installiert."

# -----------------------------------------------------------------------------
# 4) Ausfuehrrechte fuer depotguard.sh
# -----------------------------------------------------------------------------
if [[ -f "$DEPOTGUARD" ]]; then
    chmod +x "$DEPOTGUARD"
    ok "Ausfuehrrechte gesetzt: $DEPOTGUARD"
else
    warn "depotguard.sh nicht gefunden ($DEPOTGUARD) - chmod uebersprungen."
fi

# -----------------------------------------------------------------------------
# Abschluss
# -----------------------------------------------------------------------------
echo
ok "Setup abgeschlossen."
echo
printf "Naechste Schritte:\n"
printf "  1. Trage deine Gmail-Daten in code/credentials.json ein\n"
printf "     (Vorlage: code/credentials.example.json, Anleitung in README.md).\n"
printf "  2. Starte den Tracker:    cd code && ./depotguard.sh\n"
printf "  3. Dashboard im Browser:  http://localhost:8000\n"
echo
