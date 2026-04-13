#!/bin/bash
# =============================================================================
# monitor.sh — Krypto-Depot-Monitor (Haupt-Skript)
# =============================================================================
# Neue Features in dieser Version:
#   • Intelligentes Caching (Datei-basiert, 60-Min-TTL)
#   • Retry-Mechanismus für curl bei Netzwerkproblemen
#   • Dynamischer Trailing Stop-Loss über Allzeithoch (ath.txt)
#   • CSV-Historie in history.csv
#   • E-Mail-Benachrichtigung mit QR-Rechnung als Anhang (statt Telegram)
#   • Farbige Terminal-Ausgabe via ANSI-Codes
#   • Throttling-Pausen zwischen Hauptschritten
#
# Aufruf: ./monitor.sh
# =============================================================================

# -----------------------------------------------------------------------------
# BASH STRICT MODE — Fehler früh erkennen
#   -e             : Abbruch bei Fehler
#   -u             : Abbruch bei unbekannter Variable
#   -o pipefail    : Fehler in Pipes nicht schlucken
# -----------------------------------------------------------------------------
set -euo pipefail

# -----------------------------------------------------------------------------
# AUFRÄUM-MECHANISMUS (TRAP)
# -----------------------------------------------------------------------------
# Idee: Wir sammeln jede mit 'mktemp' erzeugte Datei in einer globalen
# Variable TMP_FILES. Am Skript-Ende ruft 'trap ... EXIT' automatisch die
# cleanup-Funktion auf, die alle gesammelten Dateien löscht.
#
# Vorteil gegenüber manuellem 'rm -f' an jeder Stelle:
#   • Auch bei einem Absturz (set -e, Exception, Ctrl-C) wird aufgeräumt.
#   • Der normale Code-Pfad muss sich nicht um Cleanup kümmern → weniger
#     Boilerplate, weniger Stellen an denen man rm vergessen kann.
#   • Single Source of Truth: die Liste der Temp-Dateien lebt an einem Ort.
#
# Wichtig: Die globale Variable MUSS vor dem 'trap'-Aufruf existieren,
# sonst würde 'set -u' beim ersten EXIT-Trap aus Versehen crashen.
# -----------------------------------------------------------------------------
TMP_FILES=""

cleanup() {
    # Exit-Code des letzten Befehls merken, damit wir ihn am Ende an die
    # Shell zurückgeben und das Skript-Ergebnis nicht durch Cleanup-Aktionen
    # verfälschen. ($? ist der Exit-Code des Befehls, der den Trap ausgelöst hat.)
    local exit_code=$?

    # Über die gesammelten Pfade iterieren und löschen.
    # Die unquoted Expansion von $TMP_FILES ist hier gewollt: wir wollen
    # am Leerzeichen splitten. mktemp liefert Pfade ohne Leerzeichen.
    if [[ -n "$TMP_FILES" ]]; then
        for f in $TMP_FILES; do
            # -f = keine Fehlermeldung, falls Datei schon weg ist.
            # 2>/dev/null = falls die Datei nicht (mehr) existiert oder
            # keine Löschrechte bestehen, keinen Fehler werfen.
            rm -f "$f" 2>/dev/null || true
        done
    fi

    # Wichtig: Original-Exit-Code durchreichen.
    exit "$exit_code"
}

# EXIT fängt normalen UND abnormalen Ausstieg (Fehler, Signal) ab.
# Dadurch reicht ein einziger Trap für alle Szenarien.
trap cleanup EXIT

# -----------------------------------------------------------------------------
# KONFIGURATION EINLESEN
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

# =============================================================================
# HILFSFUNKTIONEN
# =============================================================================

# -----------------------------------------------------------------------------
# log — Farbige Ausgabe mit Zeitstempel
# -----------------------------------------------------------------------------
# Erster Parameter: Level (INFO | SUCCESS | WARN | ERROR)
# Restliche Parameter: die eigentliche Nachricht
#
# Beispiel:  log INFO "Rufe API ab..."
#            log ERROR "Cache konnte nicht gelesen werden"
#
# "echo -e" aktiviert die Interpretation der Escape-Sequenzen (\033[...).
# Fehler gehen bewusst nach stderr (>&2), damit sie sich z.B. beim
# Weiterverarbeiten mit Pipes von normaler Ausgabe trennen lassen.
# -----------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    local color
    case "$level" in
        INFO)    color="$COLOR_INFO"    ;;
        SUCCESS) color="$COLOR_SUCCESS" ;;
        WARN)    color="$COLOR_WARN"    ;;
        ERROR)   color="$COLOR_ERROR"   ;;
        *)       color="$COLOR_INFO"    ;;
    esac

    # Format: [Zeit] [LEVEL] Nachricht — alles in der passenden Farbe.
    if [[ "$level" == "ERROR" ]]; then
        echo -e "${color}[${timestamp}] [${level}] ${message}${COLOR_RESET}" >&2
    else
        echo -e "${color}[${timestamp}] [${level}] ${message}${COLOR_RESET}"
    fi
}

# -----------------------------------------------------------------------------
# check_dependencies — Prüft, ob alle Kommandozeilen-Tools verfügbar sind
# -----------------------------------------------------------------------------
check_dependencies() {
    local missing=0
    # 'mutt' ist nur empfehlenswert, aber nicht zwingend (wir haben Python-Fallback)
    for cmd in curl jq bc python3; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log ERROR "Benötigtes Kommando '$cmd' nicht gefunden."
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        log ERROR "Bitte fehlende Pakete installieren (siehe README)."
        exit 1
    fi
    log SUCCESS "Alle Abhängigkeiten verfügbar."
}

# =============================================================================
# KURSABFRAGE MIT CACHE
# =============================================================================

# -----------------------------------------------------------------------------
# is_cache_valid — Prüft, ob der Cache existiert und noch frisch ist
# -----------------------------------------------------------------------------
# Rückgabe (Exit-Code):
#   0 = Cache ist gültig (Datei existiert UND jünger als CACHE_MAX_AGE)
#   1 = Cache ungültig oder fehlend → neu laden
#
# Technik:  'stat -c %Y <datei>' liefert den Unix-Timestamp der letzten
# Änderung. Das aktuelle Alter = jetzt - letzte_Änderung.
# -----------------------------------------------------------------------------
is_cache_valid() {
    # Datei existiert nicht → ungültig
    if [[ ! -f "$CACHE_FILE" ]]; then
        return 1
    fi

    local now file_mtime age
    now=$(date +%s)
    file_mtime=$(stat -c %Y "$CACHE_FILE")
    age=$(( now - file_mtime ))

    if [[ $age -lt $CACHE_MAX_AGE ]]; then
        log INFO "Cache ist noch gültig (Alter: ${age}s < ${CACHE_MAX_AGE}s)."
        return 0
    else
        log INFO "Cache ist veraltet (Alter: ${age}s ≥ ${CACHE_MAX_AGE}s)."
        return 1
    fi
}

# -----------------------------------------------------------------------------
# fetch_prices_from_api — Holt frische Kurse von CoinGecko
# -----------------------------------------------------------------------------
# Nutzt curls eingebaute Retry-Mechanik:
#   --retry N                      : bis zu N Wiederholungen
#   --retry-delay S                : feste Pause zwischen Versuchen
#   --retry-connrefused            : auch bei "connection refused" retryen
#   -f (fail) : Bricht bei HTTP-Fehler 4xx/5xx mit Exit-Code != 0 ab,
#               damit set -e greift.
#
# Nach erfolgreichem Abruf wird die Antwort in CACHE_FILE gespeichert.
# -----------------------------------------------------------------------------
fetch_prices_from_api() {
    local ids url
    # Coin-IDs aus DEPOT zu Komma-Liste zusammenbauen: "bitcoin,ethereum"
    ids=$(IFS=,; echo "${!DEPOT[*]}")
    url="https://api.coingecko.com/api/v3/simple/price?ids=${ids}&vs_currencies=${CURRENCY}"

    log INFO "Rufe Kurse von CoinGecko ab (bis zu ${CURL_RETRIES} Versuche)..."

    # Wir schreiben in eine temporäre Datei und verschieben erst nach Erfolg
    # in die Cache-Datei. So bleibt der alte Cache intakt, falls der Request
    # mittendrin fehlschlägt (atomares Update).
    #
    # Die Temp-Datei wird sofort bei TMP_FILES registriert, damit der EXIT-Trap
    # sie auch im Fehlerfall sicher aufräumt. (Bei Erfolg wird sie durch 'mv'
    # zur Cache-Datei verschoben — dann greift der rm-Versuch im Cleanup ins
    # Leere, was dank '-f' und '|| true' harmlos ist.)
    local tmp_file
    tmp_file=$(mktemp)
    TMP_FILES="$TMP_FILES $tmp_file"

    if curl -sf \
            --retry "$CURL_RETRIES" \
            --retry-delay "$CURL_RETRY_DELAY" \
            --retry-connrefused \
            --max-time "$CURL_TIMEOUT" \
            "$url" -o "$tmp_file"; then
        mv "$tmp_file" "$CACHE_FILE"
        log SUCCESS "Kurse erfolgreich abgerufen und gecacht."
    else
        log ERROR "API-Abruf nach ${CURL_RETRIES} Versuchen fehlgeschlagen."
        # tmp_file muss hier NICHT manuell gelöscht werden — der EXIT-Trap
        # erledigt das automatisch, auch wenn wir gleich per exit 1 abbrechen.
        # Falls ein alter Cache existiert, nutzen wir ihn notfalls als Fallback.
        if [[ -f "$CACHE_FILE" ]]; then
            log WARN "Nutze veralteten Cache als Notfall-Fallback."
        else
            exit 1
        fi
    fi
}

# -----------------------------------------------------------------------------
# load_prices — Einstiegspunkt: entscheidet Cache vs. frischer Abruf
# -----------------------------------------------------------------------------
# Gibt das rohe JSON auf stdout aus (wird vom Aufrufer mit $(...) aufgefangen).
# -----------------------------------------------------------------------------
load_prices() {
    if ! is_cache_valid; then
        fetch_prices_from_api
    else
        log INFO "Verwende Kurse aus lokalem Cache: $CACHE_FILE"
    fi
    cat "$CACHE_FILE"
}

# =============================================================================
# BERECHNUNG
# =============================================================================

# -----------------------------------------------------------------------------
# calculate_total_value — Gesamtwert des Depots aus JSON berechnen
# -----------------------------------------------------------------------------
# Input:  JSON-String (Parameter $1)
# Output: Gesamtwert in CHF (Dezimalzahl) auf stdout
# -----------------------------------------------------------------------------
calculate_total_value() {
    local json="$1"
    local total="0"

    for coin in "${!DEPOT[@]}"; do
        local amount="${DEPOT[$coin]}"
        local price
        # --arg übergibt die Variablen sicher an jq (keine Injection möglich).
        price=$(echo "$json" | jq -r --arg coin "$coin" --arg cur "$CURRENCY" \
                '.[$coin][$cur]')

        if [[ "$price" == "null" || -z "$price" ]]; then
            log ERROR "Kein Preis für '$coin' im JSON gefunden."
            exit 1
        fi

        log INFO "  $coin: $amount × $price $CURRENCY"
        total=$(echo "scale=2; $total + ($price * $amount)" | bc -l)
    done

    echo "$total"
}

# =============================================================================
# ALLZEITHOCH (TRAILING STOP-LOSS)
# =============================================================================

# -----------------------------------------------------------------------------
# read_or_init_ath — Lädt ATH aus Datei oder initialisiert es
# -----------------------------------------------------------------------------
# Erster Parameter: aktueller Depotwert (wird nur genutzt, falls ATH noch
# nicht existiert — dann ist der aktuelle Wert gleichzeitig das erste ATH).
#
# Gibt das ATH auf stdout aus.
# -----------------------------------------------------------------------------
read_or_init_ath() {
    local current_value="$1"

    if [[ ! -f "$ATH_FILE" ]]; then
        log WARN "ATH-Datei fehlt — initialisiere mit aktuellem Wert ($current_value)."
        echo "$current_value" > "$ATH_FILE"
    fi

    # tr -d entfernt Leerzeichen/Newlines, damit bc damit rechnen kann.
    cat "$ATH_FILE" | tr -d '[:space:]'
}

# -----------------------------------------------------------------------------
# update_ath_if_higher — Überschreibt ath.txt, falls neuer Rekord
# -----------------------------------------------------------------------------
# Vergleicht mit bc, da Bash keine Fliesskommazahlen vergleichen kann.
# -----------------------------------------------------------------------------
update_ath_if_higher() {
    local current_value="$1"
    local old_ath="$2"

    local is_new_high
    is_new_high=$(echo "$current_value > $old_ath" | bc -l)

    if [[ "$is_new_high" -eq 1 ]]; then
        echo "$current_value" > "$ATH_FILE"
        log SUCCESS "🚀 Neues Allzeithoch! $old_ath → $current_value $CURRENCY"
    fi
}

# =============================================================================
# ALARM-PRÜFUNG
# =============================================================================

# Globale Variable, die vom Alarm-Check gesetzt wird, damit die
# QR-Generierung nachher den exakten Ausgleichsbetrag kennt.
LOSS_AMOUNT="0"

# -----------------------------------------------------------------------------
# check_alarm — Vergleicht aktuellen Wert mit ATH
# -----------------------------------------------------------------------------
# Rückgabe:
#   0 = kein Alarm
#   1 = Alarm (LOSS_AMOUNT wird gesetzt)
# -----------------------------------------------------------------------------
check_alarm() {
    local current_value="$1"
    local ath="$2"

    # Verlust in CHF = ATH - aktueller Wert
    local loss loss_percent
    loss=$(echo "scale=2; $ath - $current_value" | bc -l)
    loss_percent=$(echo "scale=2; ($loss / $ath) * 100" | bc -l)

    log INFO "Allzeithoch:    $ath $CURRENCY"
    log INFO "Aktueller Wert: $current_value $CURRENCY"
    log INFO "Verlust:        $loss $CURRENCY (${loss_percent} %)"

    local is_alarm
    is_alarm=$(echo "$loss_percent > $ALARM_THRESHOLD_PERCENT" | bc -l)

    if [[ "$is_alarm" -eq 1 ]]; then
        LOSS_AMOUNT="$loss"
        log ERROR "⚠️  ALARM: Verlust überschreitet ${ALARM_THRESHOLD_PERCENT}%!"
        return 1
    else
        log SUCCESS "✅ Kein Alarm — Depot innerhalb des Toleranzbereichs."
        return 0
    fi
}

# =============================================================================
# CSV-HISTORIE
# =============================================================================

# -----------------------------------------------------------------------------
# append_history — Fügt eine Zeile in history.csv ein
# -----------------------------------------------------------------------------
# Format: Datum, Uhrzeit, Gesamtwert in CHF
# Header wird nur einmal geschrieben, beim ersten Lauf.
# -----------------------------------------------------------------------------
append_history() {
    local total_value="$1"

    if [[ ! -f "$HISTORY_FILE" ]]; then
        log INFO "Erstelle neue Historien-Datei: $HISTORY_FILE"
        echo "Datum,Uhrzeit,Gesamtwert_CHF" > "$HISTORY_FILE"
    fi

    local date_part time_part
    date_part=$(date '+%Y-%m-%d')
    time_part=$(date '+%H:%M:%S')

    echo "${date_part},${time_part},${total_value}" >> "$HISTORY_FILE"
    log INFO "History-Eintrag ergänzt: ${date_part} ${time_part} → ${total_value} CHF"
}

# =============================================================================
# PLATZHALTER — werden in den nächsten Schritten befüllt
# =============================================================================

# -----------------------------------------------------------------------------
# generate_qr_invoice — Ruft das Python-Hilfsskript auf
# -----------------------------------------------------------------------------
# Wird in Schritt 2 (QR-Rechnung) vollständig implementiert. Setzt dann die
# globale Variable QR_FILE_PATH, damit die E-Mail-Funktion sie anhängen kann.
# -----------------------------------------------------------------------------
QR_FILE_PATH=""

generate_qr_invoice() {
    log WARN "TODO (Schritt 2): QR-Rechnung über $LOSS_AMOUNT $CURRENCY erzeugen."
    # Beispiel-Vorbereitung (auskommentiert — aktivieren wir in Schritt 2):
    # mkdir -p "$OUTPUT_DIR"
    # QR_FILE_PATH="$OUTPUT_DIR/qr_invoice_$(date +%Y%m%d_%H%M%S).pdf"
    # python3 "$SCRIPT_DIR/qr_invoice.py" \
    #     --amount "$LOSS_AMOUNT" \
    #     --iban "$QR_IBAN" \
    #     --name "$QR_CREDITOR_NAME" \
    #     --street "$QR_CREDITOR_STREET" \
    #     --plz "$QR_CREDITOR_PLZ" \
    #     --city "$QR_CREDITOR_CITY" \
    #     --country "$QR_CREDITOR_COUNTRY" \
    #     --output "$QR_FILE_PATH"
}

# -----------------------------------------------------------------------------
# send_email_notification — Sendet Alarm-E-Mail mit QR-Anhang
# -----------------------------------------------------------------------------
# Strategie:
#   1) Falls 'mutt' installiert ist → nativ mit -a für Anhang nutzen
#      Beispiel: mutt -s "Betreff" -a anhang.pdf -- empfaenger@example.com < body.txt
#
#   2) Sonst Python-Fallback: kleines Inline-Skript baut eine MIME-Mail
#      und verschickt sie über localhost:25 (setzt laufenden MTA voraus).
#
# Der QR-Code wird ZWINGEND als Anhang mitgesendet. Falls QR_FILE_PATH leer
# ist (weil QR-Generierung fehlschlug), brechen wir mit Fehler ab.
# -----------------------------------------------------------------------------
send_email_notification() {
    log INFO "Bereite E-Mail-Versand vor..."

    # Vorbedingung: Es muss einen QR-Anhang geben (wird in Schritt 2 aktiv).
    if [[ -z "$QR_FILE_PATH" || ! -f "$QR_FILE_PATH" ]]; then
        log WARN "Kein QR-Anhang vorhanden (Schritt 2 noch nicht aktiv) — skippe E-Mail."
        return 0
    fi

    # Body-Text für die E-Mail zusammenbauen.
    # Auch diese Temp-Datei registrieren wir am Trap — das manuelle rm am Ende
    # der Funktion ist damit überflüssig.
    local body_file
    body_file=$(mktemp)
    TMP_FILES="$TMP_FILES $body_file"
    cat > "$body_file" <<EOF
Achtung: Depotwert gefallen!

Das überwachte Krypto-Depot hat die definierte Verlustschwelle von
${ALARM_THRESHOLD_PERCENT}% gegenüber dem Allzeithoch überschritten.

Ausgleichsbetrag: ${LOSS_AMOUNT} ${CURRENCY^^}

Im Anhang findest du eine Schweizer QR-Rechnung über genau diesen Betrag,
um das Depot wieder auszugleichen.

— ${EMAIL_SENDER_NAME}
EOF

    # Pfad 1: mutt (bevorzugt)
    if command -v mutt >/dev/null 2>&1; then
        log INFO "Versende via mutt..."
        mutt -s "$EMAIL_SUBJECT" \
             -a "$QR_FILE_PATH" \
             -- "$EMAIL_RECIPIENT" < "$body_file"
        log SUCCESS "E-Mail erfolgreich via mutt versendet."

    # Pfad 2: Python-Fallback mit dem Standard-email-Modul
    else
        log WARN "'mutt' nicht gefunden — nutze Python-Fallback."
        python3 - <<PYEOF
import smtplib, ssl, os
from email.message import EmailMessage
from pathlib import Path

msg = EmailMessage()
msg["Subject"] = "$EMAIL_SUBJECT"
msg["From"]    = "$EMAIL_SENDER_NAME <no-reply@localhost>"
msg["To"]      = "$EMAIL_RECIPIENT"
msg.set_content(Path("$body_file").read_text())

# QR-Rechnung als Anhang hinzufügen
attachment = Path("$QR_FILE_PATH")
msg.add_attachment(
    attachment.read_bytes(),
    maintype="application",
    subtype="octet-stream",
    filename=attachment.name,
)

# Versand über lokalen MTA (Port 25). Für echten Versand müsstet ihr
# hier euren SMTP-Server (z.B. smtp.gmail.com) mit Auth eintragen.
with smtplib.SMTP("localhost", 25) as s:
    s.send_message(msg)
print("E-Mail via Python-Fallback versendet.")
PYEOF
        log SUCCESS "E-Mail via Python-Fallback versendet."
    fi

    # body_file wird NICHT manuell gelöscht — darum kümmert sich der EXIT-Trap.
}

# =============================================================================
# HAUPT-PROGRAMM
# =============================================================================
main() {
    log INFO "${COLOR_BOLD}=== Krypto-Depot-Monitor gestartet ===${COLOR_RESET}"

    check_dependencies

    # --- Schritt A: Kurse laden (Cache oder API) ---
    local json
    json=$(load_prices)
    sleep "$THROTTLE_SLEEP"   # Ressourcen schonen vor nächstem Block

    # --- Schritt B: Gesamtwert berechnen ---
    local total_value
    total_value=$(calculate_total_value "$json")
    log INFO "Gesamtwert: ${COLOR_BOLD}${total_value} ${CURRENCY^^}${COLOR_RESET}"

    # --- Schritt C: CSV-Historie aktualisieren ---
    append_history "$total_value"

    # --- Schritt D: Allzeithoch laden und ggf. aktualisieren ---
    local ath
    ath=$(read_or_init_ath "$total_value")
    update_ath_if_higher "$total_value" "$ath"
    # ATH nach dem Update erneut lesen (falls es sich geändert hat — ist aber
    # für den Alarm-Check nicht nötig, da ein neues ATH Verlust = 0 bedeutet).
    ath=$(read_or_init_ath "$total_value")

    # --- Schritt E: Alarm-Check ---
    # "|| true" verhindert, dass set -e hier abbricht, wenn check_alarm
    # mit Exit 1 zurückkehrt.
    if ! check_alarm "$total_value" "$ath"; then
        sleep "$THROTTLE_SLEEP"    # Pause vor QR-Generierung
        generate_qr_invoice
        sleep "$THROTTLE_SLEEP"    # Pause vor E-Mail-Versand
        send_email_notification
    fi

    log SUCCESS "${COLOR_BOLD}=== Fertig ===${COLOR_RESET}"
}

main "$@"