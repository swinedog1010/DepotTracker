#!/bin/bash
# =============================================================================
# monitor.sh — Krypto-Depot-Monitor (Haupt-Skript)
# =============================================================================
# Dieses Skript:
#   1) Ruft aktuelle Kryptokurse von der CoinGecko-API ab
#   2) Berechnet den aktuellen Gesamtwert des Depots
#   3) Vergleicht mit dem Startwert und schlägt ggf. Alarm
#   4) Erzeugt bei Alarm eine Schweizer QR-Rechnung (Schritt 2)
#   5) Sendet Rechnung + Warnmeldung per Telegram (Schritt 3)
#
# Aufruf:  ./monitor.sh
# =============================================================================

# -----------------------------------------------------------------------------
# BASH STRICT MODE — Fehler früh erkennen
# -----------------------------------------------------------------------------
# set -e  : Skript bricht ab, sobald ein Befehl fehlschlägt
# set -u  : unbekannte Variablen führen zum Abbruch (Tippfehler-Schutz)
# set -o pipefail : in einer Pipe zählt auch ein Fehler vor dem letzten Befehl
# -----------------------------------------------------------------------------
set -euo pipefail

# -----------------------------------------------------------------------------
# KONFIGURATION EINLESEN
# -----------------------------------------------------------------------------
# "source" lädt die Variablen aus config.sh in die aktuelle Shell.
# $(dirname "$0") sorgt dafür, dass wir config.sh auch finden, wenn das
# Skript aus einem anderen Verzeichnis aufgerufen wird.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

# -----------------------------------------------------------------------------
# HILFSFUNKTION: Logging mit Zeitstempel
# -----------------------------------------------------------------------------
# Gibt eine Nachricht mit Datum/Uhrzeit auf der Konsole aus.
# Nützlich, um den Ablauf später nachvollziehen zu können.
# -----------------------------------------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# -----------------------------------------------------------------------------
# HILFSFUNKTION: Prüfen, ob nötige Kommandos verfügbar sind
# -----------------------------------------------------------------------------
# Bricht mit Fehlermeldung ab, falls ein benötigtes Tool fehlt.
# -----------------------------------------------------------------------------
check_dependencies() {
    local missing=0
    for cmd in curl jq bc python3; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "FEHLER: '$cmd' ist nicht installiert." >&2
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        echo "Bitte installiert die fehlenden Pakete (siehe README)." >&2
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# FUNKTION: Kurse von CoinGecko abrufen
# -----------------------------------------------------------------------------
# CoinGecko-Endpoint "simple/price" liefert für eine Liste von Coin-IDs die
# aktuellen Preise in beliebigen Fiatwährungen. Beispiel-URL:
#
#   https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=chf
#
# Antwort (JSON):
#   { "bitcoin": {"chf": 58234.12}, "ethereum": {"chf": 3102.55} }
#
# Rückgabe der Funktion: Das rohe JSON (wird später mit jq geparst).
# -----------------------------------------------------------------------------
fetch_prices() {
    # Alle Coin-IDs aus dem DEPOT-Array auslesen und zu "bitcoin,ethereum" zusammenbauen.
    # ${!DEPOT[@]} liefert die Schlüssel des assoziativen Arrays.
    local ids
    ids=$(IFS=,; echo "${!DEPOT[*]}")

    local url="https://api.coingecko.com/api/v3/simple/price?ids=${ids}&vs_currencies=${CURRENCY}"

    log "Rufe Kurse ab: $url" >&2   # >&2 = auf stderr, damit stdout "sauber" bleibt

    # curl-Optionen:
    #   -s : silent (keine Fortschrittsanzeige)
    #   -f : bei HTTP-Fehler (4xx/5xx) mit Fehler abbrechen
    #   --max-time 10 : Timeout nach 10 Sekunden
    curl -sf --max-time 10 "$url"
}

# -----------------------------------------------------------------------------
# FUNKTION: Gesamtwert des Depots berechnen
# -----------------------------------------------------------------------------
# Eingabe: JSON-String von CoinGecko (als Parameter $1)
# Ausgabe: Gesamtwert in CHF (Dezimalzahl, z.B. "48234.56")
#
# Für jede Coin im Depot:
#   - Preis aus dem JSON mit jq auslesen
#   - Preis × gehaltene Menge rechnen (mit bc für Fliesskomma)
#   - Alles aufsummieren
# -----------------------------------------------------------------------------
calculate_total_value() {
    local json="$1"
    local total="0"

    # Wir gehen durch jeden Coin im Depot:
    for coin in "${!DEPOT[@]}"; do
        local amount="${DEPOT[$coin]}"

        # jq-Aufruf: aus {"bitcoin":{"chf":58234.12}} den Wert für .bitcoin.chf ziehen.
        # --arg coin "$coin" übergibt die Variable sicher an jq (vermeidet Injection).
        local price
        price=$(echo "$json" | jq -r --arg coin "$coin" --arg cur "$CURRENCY" \
                '.[$coin][$cur]')

        # Sanity-Check: falls jq "null" liefert (Coin nicht gefunden), abbrechen.
        if [[ "$price" == "null" || -z "$price" ]]; then
            echo "FEHLER: Kein Preis für '$coin' erhalten." >&2
            exit 1
        fi

        log "  $coin: $amount × $price $CURRENCY" >&2

        # bc rechnet mit Fliesskomma. scale=2 = 2 Nachkommastellen.
        # Die Variable "total" wird in jedem Durchlauf überschrieben.
        total=$(echo "scale=2; $total + ($price * $amount)" | bc -l)
    done

    # Ergebnis auf stdout ausgeben (wird vom Aufrufer per $(...) eingefangen)
    echo "$total"
}

# -----------------------------------------------------------------------------
# FUNKTION: Alarm prüfen
# -----------------------------------------------------------------------------
# Vergleicht den aktuellen Wert mit dem Startwert.
# Rückgabe (Exit-Code):
#   0 = Alles ok (kein Alarm)
#   1 = Alarm! Verlust überschreitet Schwellwert
#
# Zusätzlich setzt die Funktion die globale Variable LOSS_AMOUNT auf den
# Verlustbetrag in CHF, damit wir ihn später für die QR-Rechnung nutzen können.
# -----------------------------------------------------------------------------
LOSS_AMOUNT="0"  # wird später ggf. überschrieben

check_alarm() {
    local current_value="$1"

    # Verlust in CHF:  Startwert - aktueller Wert
    # (positive Zahl = Verlust, negative Zahl = Gewinn)
    local loss
    loss=$(echo "scale=2; $START_VALUE - $current_value" | bc -l)

    # Verlust in Prozent:  (Verlust / Startwert) * 100
    local loss_percent
    loss_percent=$(echo "scale=2; ($loss / $START_VALUE) * 100" | bc -l)

    log "Startwert:      $START_VALUE $CURRENCY"
    log "Aktueller Wert: $current_value $CURRENCY"
    log "Verlust:        $loss $CURRENCY ($loss_percent %)"

    # Vergleich mit bc, weil Bash selbst keine Fliesskommazahlen vergleichen kann.
    # "bc" liefert "1" wenn wahr, "0" wenn falsch.
    local is_alarm
    is_alarm=$(echo "$loss_percent > $ALARM_THRESHOLD_PERCENT" | bc -l)

    if [[ "$is_alarm" -eq 1 ]]; then
        LOSS_AMOUNT="$loss"
        log "⚠️  ALARM: Verlust überschreitet ${ALARM_THRESHOLD_PERCENT}%!"
        return 1
    else
        log "✅ Kein Alarm — Depot innerhalb des Toleranzbereichs."
        return 0
    fi
}

# -----------------------------------------------------------------------------
# PLATZHALTER — werden in Schritt 2 und 3 gefüllt
# -----------------------------------------------------------------------------
generate_qr_invoice() {
    log "TODO (Schritt 2): QR-Rechnung über $LOSS_AMOUNT $CURRENCY erzeugen"
    # Hier rufen wir später qr_invoice.py auf
}

send_telegram_notification() {
    log "TODO (Schritt 3): Telegram-Benachrichtigung senden"
    # Hier rufen wir später die Telegram Bot API auf
}

# =============================================================================
# HAUPT-PROGRAMM
# =============================================================================
main() {
    log "=== Krypto-Depot-Monitor gestartet ==="

    check_dependencies

    # Kurse holen
    local json
    json=$(fetch_prices)

    # Gesamtwert berechnen
    local total_value
    total_value=$(calculate_total_value "$json")

    # Alarm prüfen. "|| true" verhindert, dass set -e das Skript beendet,
    # wenn check_alarm mit Exit-Code 1 zurückkehrt.
    if ! check_alarm "$total_value"; then
        generate_qr_invoice
        send_telegram_notification
    fi

    log "=== Fertig ==="
}

# Skript ausführen (Funktion am Ende aufrufen, damit alle Funktionen
# vorher definiert sind).
main "$@"