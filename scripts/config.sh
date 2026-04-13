#!/bin/bash
# =============================================================================
# config.sh — Zentrale Konfiguration für den Krypto-Depot-Monitor
# =============================================================================
# Wird vom Haupt-Skript (monitor.sh) per "source" eingelesen. Alle hier
# definierten Variablen stehen danach global im Haupt-Skript zur Verfügung.
# =============================================================================

# -----------------------------------------------------------------------------
# DEPOT-DEFINITION
# -----------------------------------------------------------------------------
# Schlüssel müssen exakt den CoinGecko-IDs entsprechen (siehe /coins/list).
# "declare -A" erzeugt ein assoziatives Array (Key-Value, wie ein Python-Dict).
# -----------------------------------------------------------------------------
declare -A DEPOT=(
    [bitcoin]=0.5       # 0.5 BTC
    [ethereum]=4.0      # 4.0 ETH
)

# Zielwährung für die Kurse (CHF = Schweizer Franken)
CURRENCY="chf"

# -----------------------------------------------------------------------------
# ALARM-KONFIGURATION (Trailing Stop-Loss)
# -----------------------------------------------------------------------------
# Es gibt KEINEN statischen Startwert mehr! Stattdessen arbeiten wir mit einem
# dynamischen Allzeithoch (ATH = All-Time-High), das in ath.txt gespeichert
# wird und vom Skript bei Bedarf aktualisiert wird.
#
# Der prozentuale Verlust wird immer RELATIV zum ATH berechnet. Damit haben
# wir einen "Trailing Stop-Loss": steigt das Depot auf ein neues Hoch, zieht
# die Alarmschwelle automatisch mit nach oben.
# -----------------------------------------------------------------------------
ALARM_THRESHOLD_PERCENT=15   # Alarm ab >15 % Verlust gegenüber dem ATH

# -----------------------------------------------------------------------------
# CACHE-KONFIGURATION
# -----------------------------------------------------------------------------
# Um die CoinGecko-API (die ein Rate-Limit hat) zu schonen, cachen wir die
# Antwort lokal in einer JSON-Datei. Ist die Datei jünger als CACHE_MAX_AGE
# Sekunden, wird sie wiederverwendet — sonst frisch geholt.
# -----------------------------------------------------------------------------
CACHE_MAX_AGE=3600           # 60 Minuten in Sekunden

# -----------------------------------------------------------------------------
# RETRY-KONFIGURATION (für curl)
# -----------------------------------------------------------------------------
# Falls das Netzwerk kurz nicht erreichbar ist, versucht curl es mehrfach.
#   CURL_RETRIES      = Anzahl Wiederholungen bei Netzwerkfehlern
#   CURL_RETRY_DELAY  = Pause (Sek.) zwischen den Versuchen
#   CURL_TIMEOUT      = Max. Dauer eines einzelnen Versuchs
# -----------------------------------------------------------------------------
CURL_RETRIES=3
CURL_RETRY_DELAY=5
CURL_TIMEOUT=10

# -----------------------------------------------------------------------------
# THROTTLING (Ressourcenschonung)
# -----------------------------------------------------------------------------
# Kurze Pausen zwischen ressourcenintensiven Schritten (API-Call,
# QR-Generierung, E-Mail-Versand). So vermeiden wir Lastspitzen und geben
# externen Diensten "Luft".
# -----------------------------------------------------------------------------
THROTTLE_SLEEP=2             # Sekunden Pause zwischen den Hauptschritten

# -----------------------------------------------------------------------------
# E-MAIL-KONFIGURATION
# -----------------------------------------------------------------------------
# Der Versand erfolgt über 'mutt' (primär) oder ein Python-Fallback. Auf den
# meisten Systemen muss 'mutt' vorab mit einem funktionierenden SMTP-Setup
# konfiguriert sein (~/.muttrc), damit der Versand klappt.
# -----------------------------------------------------------------------------
EMAIL_RECIPIENT="empfaenger@example.com"
EMAIL_SENDER_NAME="Krypto-Depot-Monitor"
EMAIL_SUBJECT="⚠️  Alarm: Depotwert gefallen"

# -----------------------------------------------------------------------------
# SCHWEIZER QR-RECHNUNG — Empfängerdaten (fiktiv für das Schulprojekt)
# -----------------------------------------------------------------------------
# QR-IBAN: spezielle IBAN-Form mit Institutskennung 30000–31999.
# Hier die offizielle Test-IBAN aus der SIX-Dokumentation.
# -----------------------------------------------------------------------------
QR_IBAN="CH4431999123000889012"
QR_CREDITOR_NAME="Max Muster"
QR_CREDITOR_STREET="Musterstrasse 1"
QR_CREDITOR_PLZ="8000"
QR_CREDITOR_CITY="Zürich"
QR_CREDITOR_COUNTRY="CH"

# -----------------------------------------------------------------------------
# DATEI-PFADE
# -----------------------------------------------------------------------------
# Zentral definiert, damit alle Skripte die gleichen Orte nutzen.
# -----------------------------------------------------------------------------
OUTPUT_DIR="./output"              # Generierte QR-Rechnungen
CACHE_FILE="./price_cache.json"    # Kurs-Cache
ATH_FILE="./ath.txt"               # Allzeithoch-Speicher
HISTORY_FILE="./history.csv"       # Zeitreihe aller Durchläufe

# -----------------------------------------------------------------------------
# ANSI-FARBCODES (für das Terminal)
# -----------------------------------------------------------------------------
# Diese Escape-Sequenzen färben den Text in der Konsole. "\033[" ist das
# Steuerzeichen (ESC [), gefolgt von Farbcode und "m". "0m" setzt zurück.
#
# Hinweis: Wir definieren sie zentral, damit sie nicht überall im Code
# als "magic strings" auftauchen. In der log()-Funktion nutzen wir sie.
# -----------------------------------------------------------------------------
COLOR_RESET="\033[0m"
COLOR_INFO="\033[0;37m"     # weiss/grau — normale Prozessmeldungen
COLOR_SUCCESS="\033[0;32m"  # grün      — Erfolgsmeldungen
COLOR_WARN="\033[0;33m"     # gelb      — Warnungen
COLOR_ERROR="\033[0;31m"    # rot       — Fehler und Alarme
COLOR_BOLD="\033[1m"        # Fettdruck