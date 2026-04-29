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
#  Abhaengigkeiten: curl, awk, base64 (sowie python3 fuer QR-Rechnung/SMTP)
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
TMP_FILES=""

cleanup() {
    # Wird durch "trap ... EXIT" beim Verlassen des Skripts immer aufgerufen,
    # egal ob normaler Abschluss, Fehler oder Signalabbruch.
    local f
    for f in $TMP_FILES; do
        [[ -e "$f" ]] && rm -f "$f"
    done
}
trap cleanup EXIT

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

# --- Schwellenwerte und Zeitlimits ------------------------------------------
CACHE_MAX_AGE=3600        # max. Cache-Alter in Sekunden (60 Minuten)
LOAD_THRESHOLD="2.0"      # CPU-Load-Grenze
LOAD_MAX_RETRIES=5        # max. Wartezyklen bei hoher Last
LOAD_SLEEP=10             # Pause in Sekunden zwischen Last-Pruefungen
THROTTLE_SLEEP=2          # Pause zwischen QR-Rechnung und E-Mail
API_RETRIES=3             # Wiederholungen pro Coin bei API-Fehler
API_RETRY_DELAY=5         # Pause zwischen Wiederholungen
API_TIMEOUT=10            # max. Wartezeit pro API-Call in Sekunden
COIN_DELAY=3              # Pause zwischen einzelnen Coin-Abfragen
THRESHOLD_CHF=1000        # Mindestwert des Depots in CHF
LOSS_PERCENT_LIMIT=15     # max. zulaessiger Verlust in % vom ATH

# --- Depot-Definition (assoziatives Array Coin -> Menge) --------------------
declare -A DEPOT=(
    [bitcoin]=0.5
    [ethereum]=4.0
)

# --- API & Waehrung ---------------------------------------------------------
API_BASE="https://api.coingecko.com/api/v3/simple/price"
FIAT_CURRENCY="chf"

# --- E-Mail-Konfiguration ---------------------------------------------------
EMAIL_RECIPIENT="philippesaxer8@gmail.com"
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

# -----------------------------------------------------------------------------
# 4) FARB-CODES & LOGGING
# -----------------------------------------------------------------------------
# ANSI-Escape-Sequenzen fuer farbige Ausgabe im Terminal.
C_RESET="\033[0m"
C_GREY="\033[0;37m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[0;31m"

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
# 5) CREDENTIALS LADEN (credentials.json -> SMTP_USER/SMTP_PASS)
# -----------------------------------------------------------------------------
load_credentials() {
    # Liest die Gmail-Credentials aus credentials.json. Diese Datei wird
    # ausserhalb von Git gehalten (siehe .gitignore) und entweder manuell
    # aus credentials.example.json erstellt oder ueber das Web-Modal
    # (server.py /save_smtp) befuellt.
    if [[ ! -f "$CREDENTIALS_FILE" ]]; then
        log WARN "credentials.json fehlt - SMTP-Versand nicht moeglich."
        return 1
    fi

    local out
    if ! out="$(python3 - "$CREDENTIALS_FILE" <<'PYEOF'
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
            local resp; resp="$(mktemp)"; TMP_FILES="$TMP_FILES $resp"
            local ok=0 attempt=1
            while (( attempt <= API_RETRIES )); do
                if curl --retry 3 --retry-delay "$API_RETRY_DELAY" \
                        --retry-connrefused -sf --max-time "$API_TIMEOUT" \
                        "${API_BASE}?ids=${coin}&vs_currencies=${FIAT_CURRENCY}" \
                        -o "$resp"; then
                    ok=1
                    break
                else
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
    # Stellt sicher, dass ein gueltiger Cache existiert. Bei API-Fehler wird
    # ein vorhandener (alter) Cache als Fallback akzeptiert.
    if cache_is_fresh; then
        log INFO "Cache aktuell - keine API-Abfrage noetig."
        return 0
    fi

    if fetch_prices; then
        return 0
    fi

    if [[ -f "$CACHE_FILE" ]]; then
        log WARN "API nicht erreichbar - nutze veralteten Cache."
        return 0
    fi
    log ERROR "Keine Kursdaten verfuegbar - Abbruch."
    exit 1
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
    # generate_qr_bill <Betrag> <Zieldatei.svg>
    # Erzeugt ueber ein eingebettetes Python-Snippet mit der Library "qrbill"
    # eine SVG-Datei der Schweizer QR-Rechnung.
    local amount="$1"
    local target="$2"

    # Stellt sicher, dass die Python-Library installiert ist.
    if ! python3 -c "import qrbill" >/dev/null 2>&1; then
        log WARN "Python-Modul 'qrbill' fehlt - versuche pip3 install ..."
        pip3 install --quiet qrbill || {
            log ERROR "qrbill konnte nicht installiert werden."
            return 1
        }
    fi

    python3 - "$amount" "$target" <<'PYEOF'
import sys
from qrbill import QRBill

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
    additional_information="DepotTracker - Margin Call",
)
bill.as_svg(target)
PYEOF

    log SUCCESS "QR-Rechnung erstellt: $target"
}

# -----------------------------------------------------------------------------
# 15) E-MAIL-VERSAND (mutt primaer, Python-SMTP als Fallback)
# -----------------------------------------------------------------------------
send_email() {
    # send_email <Anhang> <Body-Datei>
    local attach="$1"
    local body="$2"

    # --- Primaer: mutt -------------------------------------------------------
    if command -v mutt >/dev/null 2>&1; then
        if mutt -s "$EMAIL_SUBJECT" -a "$attach" -- "$EMAIL_RECIPIENT" < "$body"; then
            log SUCCESS "E-Mail via mutt versendet an $EMAIL_RECIPIENT"
            return 0
        fi
        log WARN "mutt-Versand fehlgeschlagen - verwende SMTP-Fallback."
    else
        log WARN "mutt nicht installiert - verwende SMTP-Fallback."
    fi

    # --- Fallback: Python smtplib (Gmail via SMTP_SSL auf Port 465) ----------
    SMTP_SERVER="$SMTP_SERVER" SMTP_PORT="$SMTP_PORT" \
    SMTP_USER="$SMTP_USER" SMTP_PASS="$SMTP_PASS" \
    EMAIL_RECIPIENT="$EMAIL_RECIPIENT" \
    EMAIL_SENDER_NAME="$EMAIL_SENDER_NAME" \
    EMAIL_SUBJECT="$EMAIL_SUBJECT" \
    python3 - "$attach" "$body" <<'PYEOF'
import os, sys, smtplib, ssl
from email.message import EmailMessage

attach_path = sys.argv[1]
body_path   = sys.argv[2]

msg = EmailMessage()
msg["Subject"] = os.environ["EMAIL_SUBJECT"]
msg["From"]    = f'{os.environ["EMAIL_SENDER_NAME"]} <{os.environ["SMTP_USER"]}>'
msg["To"]      = os.environ["EMAIL_RECIPIENT"]

with open(body_path, "r", encoding="utf-8") as f:
    msg.set_content(f.read())

with open(attach_path, "rb") as f:
    data = f.read()
fname = os.path.basename(attach_path)
# Maintype/Subtype anhand der Endung. SVG/PNG/PDF werden alle unterstuetzt.
if fname.endswith(".svg"):
    maintype, subtype = "image", "svg+xml"
elif fname.endswith(".png"):
    maintype, subtype = "image", "png"
elif fname.endswith(".pdf"):
    maintype, subtype = "application", "pdf"
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

    # Zieldatei mit Zeitstempel - fuer das Web-Dashboard nachvollziehbar.
    local stamp; stamp="$(date +%Y%m%d_%H%M%S)"
    local qr_file="${OUTPUT_DIR}/qrbill_${stamp}.svg"

    # 1) QR-Rechnung erzeugen --------------------------------------------------
    if ! generate_qr_bill "$loss" "$qr_file"; then
        log ERROR "QR-Rechnung konnte nicht erzeugt werden - Versand entfaellt."
        return 1
    fi

    # 2) Throttling vor dem E-Mail-Versand -------------------------------------
    sleep "$THROTTLE_SLEEP"

    # 3) Body-Datei (temporaer) ------------------------------------------------
    local body; body="$(mktemp)"; TMP_FILES="$TMP_FILES $body"
    cat > "$body" <<EOF
Hallo,

das DepotTracker-System hat einen Alarm ausgeloest.

  Aktueller Depotwert : ${current} ${FIAT_CURRENCY^^}
  Allzeithoch (ATH)   : ${ath} ${FIAT_CURRENCY^^}
  Verlust             : ${loss} ${FIAT_CURRENCY^^} (${loss_pct} %)
  Schwelle            : ${THRESHOLD_CHF} ${FIAT_CURRENCY^^}

Im Anhang finden Sie eine Schweizer QR-Rechnung ueber den Differenzbetrag.

Freundliche Gruesse
${EMAIL_SENDER_NAME}
EOF

    # 4) E-Mail versenden ------------------------------------------------------
    send_email "$qr_file" "$body" || true
    log INFO "Alarm verarbeitet."
}

# -----------------------------------------------------------------------------
# 17) HAUPT-ABLAUF
# -----------------------------------------------------------------------------
main() {
    auto_setup
    log INFO "=== DepotTracker Lauf gestartet ==="

    # SMTP-Credentials werden best-effort geladen; fehlende Datei ist kein
    # harter Fehler - der Alarm-Pfad logged dann eine eindeutige Meldung.
    load_credentials || true

    check_cpu_load
    load_prices

    local total ath loss loss_pct status
    total="$(calculate_total)"
    log INFO "Gesamtwert Depot: $total $FIAT_CURRENCY"

    ath="$(update_ath "$total")"

    # Verlust und Verlustprozent (zwei Nachkommastellen).
    loss="$(awk -v a="$ath" -v t="$total" 'BEGIN{v=a-t; if(v<0)v=0; printf "%.2f", v}')"
    loss_pct="$(awk -v a="$ath" -v t="$total" \
                'BEGIN{ if(a<=0){print "0.00"; exit} v=(a-t)/a*100; if(v<0)v=0; printf "%.2f", v}')"

    # Alarm-Bedingungen pruefen.
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
}

# Einstiegspunkt - nur ausfuehren, wenn Skript direkt aufgerufen wurde.
main "$@"
