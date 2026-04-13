#!/bin/bash
# =============================================================================
# config.sh — Zentrale Konfiguration für den Krypto-Depot-Monitor
# =============================================================================
# Diese Datei wird vom Haupt-Skript (monitor.sh) per "source" eingelesen.
# Alle hier definierten Variablen stehen danach im Haupt-Skript zur Verfügung.
# Vorteil: Wir müssen den Code nicht anfassen, wenn sich Werte ändern.
# =============================================================================

# -----------------------------------------------------------------------------
# DEPOT-DEFINITION
# -----------------------------------------------------------------------------
# Hier legen wir fest, welche Kryptowährungen im Depot liegen und wie viele
# Einheiten (Coins) wir davon besitzen.
#
# Wichtig: Die Schlüssel (bitcoin, ethereum) müssen exakt den CoinGecko-IDs
# entsprechen. Die offizielle Liste findet ihr unter:
#   https://api.coingecko.com/api/v3/coins/list
#
# "declare -A" erzeugt ein assoziatives Array (wie ein Dictionary in Python).
# -----------------------------------------------------------------------------
declare -A DEPOT=(
    [bitcoin]=0.5       # 0.5 BTC
    [ethereum]=4.0      # 4.0 ETH
)

# Währung, in der wir die Kurse abrufen (CHF = Schweizer Franken)
CURRENCY="chf"

# -----------------------------------------------------------------------------
# ALARM-KONFIGURATION
# -----------------------------------------------------------------------------
# START_VALUE: Der Wert des Depots zum Zeitpunkt des "Kaufs" in CHF.
# Gegen diesen Wert vergleichen wir den aktuellen Kurswert.
#
# ALARM_THRESHOLD_PERCENT: Ab welchem prozentualen Verlust der Alarm auslöst.
# Beispiel: 15 bedeutet, dass bei einem Wertverlust von >15% Alarm geschlagen wird.
# -----------------------------------------------------------------------------
START_VALUE=50000          # CHF — fiktiver Anschaffungswert des Depots
ALARM_THRESHOLD_PERCENT=15 # Prozent

# -----------------------------------------------------------------------------
# TELEGRAM-KONFIGURATION
# -----------------------------------------------------------------------------
# Bot-Token: von @BotFather auf Telegram
# Chat-ID:   eure persönliche ID (siehe getUpdates-Endpoint)
# HINWEIS: In einer echten Anwendung würdet ihr diese Werte NICHT ins Git
# einchecken, sondern z.B. über Umgebungsvariablen laden.
# -----------------------------------------------------------------------------
TELEGRAM_BOT_TOKEN="HIER_EUER_BOT_TOKEN_EINTRAGEN"
TELEGRAM_CHAT_ID="HIER_EURE_CHAT_ID_EINTRAGEN"

# -----------------------------------------------------------------------------
# SCHWEIZER QR-RECHNUNG — Empfängerdaten
# -----------------------------------------------------------------------------
# Diese Daten erscheinen später auf der QR-Rechnung als Zahlungsempfänger.
# Für das Schulprojekt sind das fiktive Werte.
#
# Die IBAN muss eine gültige Schweizer QR-IBAN sein (Institutskennung
# zwischen 30000 und 31999). Für Testzwecke nutzen wir die Beispiel-IBAN
# aus der offiziellen SIX-Dokumentation.
# -----------------------------------------------------------------------------
QR_IBAN="CH4431999123000889012"          # Test-QR-IBAN (SIX-Beispiel)
QR_CREDITOR_NAME="Max Muster"
QR_CREDITOR_STREET="Musterstrasse 1"
QR_CREDITOR_PLZ="8000"
QR_CREDITOR_CITY="Zürich"
QR_CREDITOR_COUNTRY="CH"

# -----------------------------------------------------------------------------
# DATEI-PFADE
# -----------------------------------------------------------------------------
# Ordner, in dem generierte QR-Rechnungen abgelegt werden.
OUTPUT_DIR="./output"