# =============================================================================
# MASTER-PROMPT FÜR CLAUDE CODE — DepotTracker (LB3)
# Projekt von Philippe und Viggo
# =============================================================================
# Kopiere den gesamten Text unterhalb dieser Linie und füge ihn als
# EINEN einzigen Prompt in Claude Code ein.
# =============================================================================

Rolle: Handle als erfahrener Full-Stack-Entwickler, Linux-Systemadministrator und UI/UX-Designer. Du baust ein komplettes, produktionsreifes Projekt von Grund auf.

## PROJEKTÜBERSICHT

Wir bauen "DepotTracker" — ein vollautomatisiertes Bash-System zur Überwachung eines fiktiven Krypto-Depots unter Ubuntu, zusammen mit einer hochmodernen Web-Oberfläche als Dashboard. Das Projekt ist für die Schulabgabe (LB3, 2026).

Das System besteht aus ZWEI Hauptteilen:
1. Ein Bash-Skript (`depotguard.sh`), das alles automatisch erledigt
2. Eine grafisch beeindruckende Webseite (HTML/CSS/JS) als Dashboard + ein kleines Backend-Skript

## TEIL 1: DAS BASH-SKRIPT (`depotguard.sh`)

Erstelle EIN EINZIGES, komplett eigenständiges Bash-Skript namens `depotguard.sh`, das den gesamten folgenden Ablauf abdeckt. Alle Konfigurationswerte (Depot, Schwellenwerte, E-Mail, IBAN etc.) werden als Variablen OBEN im Skript definiert — keine separate config.sh.

### Ablauf (exakt nach unserem Ablaufdiagramm):

```
Start (Cronjob oder manuell)
  → Setup-Prüfung: Erster Lauf?
      JA  → Ordner erstellen (output/, logs/) & Cronjob einrichten
      NEIN → weiter
  → CPU Load prüfen (> 2.0?)
      JA  → Pause 10 Sekunden, dann erneut prüfen
      NEIN → weiter
  → Cache vorhanden und jünger als 60 Min?
      JA  → Kurse aus Cache laden
      NEIN → API-Abfrage in Schleife (für jeden Coin einzeln):
              → curl mit Retry (3 Versuche, je 5s Pause)
              → Pause 3 Sekunden zwischen Coins
              → Daten in Cache speichern (price_cache.json)
  → Berechnung Gesamtwert des Depots
  → Allzeithoch (ATH) aus ath.txt laden oder initialisieren
  → Falls aktueller Wert > ATH → neues ATH speichern
  → CSV-History-Eintrag schreiben (history.csv: Datum, Uhrzeit, Wert)
  → Gesamtwert < Schwelle (z.B. 1000 CHF) ODER Verlust > 15% vom ATH?
      JA  → Log: ALARM
           → QR-Rechnung generieren (Schweizer QR-Bill, als PNG/SVG)
           → Pause 2 Sekunden (Throttling)
           → E-Mail mit QR-Rechnung als Anhang senden
           → Log: Alarm verarbeitet
      NEIN → Log: OK
  → Ende
```

### Technische Anforderungen für das Bash-Skript:

1. **Strict Mode:** `set -euo pipefail` ganz oben.

2. **Trap-Cleanup:** Direkt unter strict mode eine globale Variable `TMP_FILES=""` und eine `cleanup`-Funktion mit `trap cleanup EXIT`. Jede mit `mktemp` erstellte Datei wird sofort an `TMP_FILES` angehängt. KEINE manuellen `rm -f` im restlichen Code.

3. **Farbiges Logging:** Eine `log`-Funktion mit ANSI-Farbcodes:
   - Weiss/Grau für INFO
   - Grün für SUCCESS
   - Gelb für WARN
   - Rot für ERROR/ALARM
   - Format: `[YYYY-MM-DD HH:MM:SS] [LEVEL] Nachricht`

4. **Auto-Setup beim ersten Lauf:**
   - Prüfe ob die nötigen Ordner existieren (output/, logs/)
   - Falls nicht → erstelle sie
   - Prüfe ob ein Cronjob bereits existiert → falls nicht, richte einen täglichen Cronjob ein

5. **CPU-Load-Check:**
   - Lese die 1-Minuten-Load aus `/proc/loadavg`
   - Ist sie > 2.0 → Pause 10 Sekunden, dann erneut prüfen (Schleife)
   - Maximal 5 Versuche, dann trotzdem weiter mit Warnung

6. **Depot-Definition als assoziatives Array:**
   ```
   declare -A DEPOT=(
       [bitcoin]=0.5
       [ethereum]=4.0
   )
   ```

7. **Intelligentes Caching:**
   - Cache-Datei: `price_cache.json`
   - Alter prüfen via `stat -c %Y` vs `date +%s`
   - Max-Alter: 3600 Sekunden (60 Min)
   - Falls Cache gültig → daraus laden, KEIN API-Call

8. **API-Abfrage mit Retry:**
   - CoinGecko Free API: `https://api.coingecko.com/api/v3/simple/price`
   - curl-Flags: `--retry 3 --retry-delay 5 --retry-connrefused -sf --max-time 10`
   - Atomares Cache-Update: erst in tmp-Datei schreiben, dann `mv`
   - Bei totalem Fehlschlag: alten Cache als Fallback nutzen

9. **Berechnung:** Verwende `awk` für Fliesskomma-Arithmetik (NICHT bc, NICHT jq). Parse das JSON manuell mit `grep` und `sed`/`awk`, oder verwende ein minimales JSON-Parsing mit `awk`. Abhängigkeiten laut README: nur `curl`, `awk`, `base64`.

10. **Dynamischer Trailing Stop-Loss:**
    - ATH aus `ath.txt` lesen (eine Dezimalzahl)
    - Falls Datei nicht existiert → mit aktuellem Wert initialisieren
    - Falls aktueller Wert > ATH → Datei überschreiben
    - Verlust = ATH - aktueller Wert
    - Verlustprozent = (Verlust / ATH) * 100
    - Alarm auslösen wenn: Gesamtwert < 1000 CHF ODER Verlustprozent > 15

11. **CSV-Historie:**
    - Datei: `history.csv`
    - Header beim ersten Mal: `Datum,Uhrzeit,Gesamtwert_CHF`
    - Bei jedem Lauf eine Zeile anhängen

12. **QR-Rechnung (Schweizer Standard):**
    - Nutze ein eingebettetes Python-Snippet (Heredoc) mit der Library `qrbill`
    - Falls `qrbill` nicht installiert → versuche `pip3 install qrbill`
    - Erzeuge ein SVG/PNG der QR-Rechnung über den Verlustbetrag
    - Empfängerdaten (fiktiv): QR-IBAN CH4431999123000889012, Max Muster, Musterstrasse 1, 8000 Zürich, CH

13. **E-Mail-Versand:**
    - Primär: `mutt -s "Betreff" -a anhang.pdf -- empfaenger@example.com < body.txt`
    - Fallback: Python-Skript mit `smtplib` und `email`-Modul (als Heredoc)
    - QR-Rechnung MUSS als Anhang mitgesendet werden
    - Konfigurierbare Variablen: EMAIL_RECIPIENT, EMAIL_SENDER_NAME, EMAIL_SUBJECT

14. **Throttling:** Definiere eine Variable `THROTTLE_SLEEP=2` und setze `sleep "$THROTTLE_SLEEP"` zwischen QR-Generierung und E-Mail-Versand.

15. **Kommentierung:** JEDE Funktion und JEDER logische Block muss ausführlich auf Deutsch kommentiert sein. Wir müssen das für die Schule präsentieren und jede Zeile erklären können.

16. **Schweizer Schreibweise:** Verwende konsequent "ss" statt "ß" (z.B. "Strasse" statt "Straße", "Grüsse" statt "Grüße").

---

## TEIL 2: DIE WEBSEITE (Dashboard)

Erstelle eine hochmoderne, grafisch beeindruckende Single-Page-Weboberfläche. Die Webseite besteht aus folgenden Dateien:

### Dateistruktur:
```
DepotTracker/
├── depotguard.sh          # Das Bash-Skript (Teil 1)
├── logo/
│   └── logo.png           # Existiert bereits im Projekt!
├── index.html             # Haupt-Dashboard
├── style.css              # Separates Stylesheet
├── script.js              # Separates JavaScript
├── save_email.php          # Backend für E-Mail-Speicherung (oder .py)
├── output/                # Generierte QR-Rechnungen
├── logs/                  # Log-Dateien
├── history.csv            # Wird vom Bash-Skript geschrieben
├── ath.txt                # Allzeithoch
└── price_cache.json       # Kurs-Cache
```

### Design-Anforderungen:

1. **Gesamtlook:** Dark-Mode als Standard. Professionelles, modernes Finanz-Dashboard (denke an Bloomberg Terminal oder Binance, aber cleaner). Verwende CSS-Variablen für alle Farben.

2. **Logo:**
   - Platziere `logo/logo.png` gut sichtbar oben links im Header/Navigation
   - Definiere `logo/logo.png` ZWINGEND im `<head>` als Favicon: `<link rel="icon" href="logo/logo.png">`

3. **Layout (CSS Grid + Flexbox):**
   - Header mit Logo, Projektname "DepotTracker", und einem Statusindikator (grüner Punkt = OK, roter Punkt = Alarm)
   - Statistik-Karten (Cards): Aktueller Depotwert, Allzeithoch, Verlust in % , Anzahl Alarme
   - Ein grosser Chart-Bereich für die historische Wertentwicklung (aus history.csv simuliert)
   - Eine Tabelle "Letzte Läufe" die vergangene Einträge aus history.csv zeigt (Datum, Uhrzeit, Wert, Status-Badge OK/ALARM)
   - Ein Bereich "Depot-Zusammensetzung" der die Coins und ihre Anteile zeigt

4. **Interaktivität (JavaScript):**
   - Simuliere den Status des Bash-Skripts mit animierten Elementen
   - Erstelle einen interaktiven Chart (z.B. mit Chart.js via CDN oder nativ mit Canvas) der die Wertentwicklung zeigt
   - Status-Badges die zwischen "OK" (grün) und "ALARM" (rot, pulsierend) wechseln
   - Animierte Zahlen die beim Laden hochzählen (Counter-Animation)
   - Ein Fortschrittsbalken der den "nächsten Scan" simuliert
   - Ein Button "Scan jetzt auslösen" der eine Animation zeigt

5. **E-Mail-Pop-up (Modal):**
   - Beim ersten Laden der Seite öffnet sich automatisch ein modernes Modal im Dark-Mode-Stil
   - Das Modal hat ein Eingabefeld für eine E-Mail-Adresse und einen "Speichern"-Button
   - Die Seite im Hintergrund ist abgedunkelt (Overlay) — man muss erst die E-Mail eingeben
   - JavaScript: Bei Klick auf "Speichern" wird die E-Mail per `fetch()` (POST, JSON) an `save_email.php` gesendet
   - Nach Erfolg: Modal schliesst sich, kurze Erfolgsmeldung wird angezeigt (Toast-Notification)
   - Die E-Mail wird in `localStorage` gespeichert, damit das Modal beim nächsten Besuch nicht mehr erscheint

6. **Backend-Skript (`save_email.php`):**
   - Empfängt den POST-Request mit der E-Mail (JSON: `{"email": "..."}}`)
   - Öffnet `depotguard.sh`, sucht die Zeile die mit `EMAIL_RECIPIENT=` beginnt
   - Ersetzt den Wert mit der neuen E-Mail-Adresse
   - Gibt JSON-Antwort zurück: `{"success": true}` oder `{"success": false, "error": "..."}`
   - Validiert die E-Mail-Adresse serverseitig (Regex-Check)
   - Falls PHP nicht gewünscht: erstelle alternativ ein Python-Skript (`save_email.py`) mit `http.server` oder Flask

7. **Code-Qualität:**
   - Sauberes, kommentiertes CSS mit Variablen für alle Farben
   - Modernes JavaScript (ES6+, keine jQuery)
   - Responsives Design (Mobile-freundlich)
   - Alle Kommentare und UI-Texte auf Deutsch, Schweizer Schreibweise ("ss" statt "ß")

---

## WICHTIGE HINWEISE

- Der Ordner `logo/` mit `logo.png` existiert bereits. Erstelle ihn NICHT neu, referenziere ihn nur.
- Das Projekt muss auf Ubuntu lauffähig sein.
- Abhängigkeiten für das Bash-Skript: nur `curl`, `awk`, `base64` (plus `python3` für QR-Rechnung und E-Mail-Fallback).
- Starte mit dem Bash-Skript (`depotguard.sh`), dann die Webseite.
- Kommentiere ALLES ausführlich — wir müssen es in der Schule präsentieren.
- Schreibweise: Schweizerdeutsch-konform, also immer "ss" statt "ß".

Bitte beginne jetzt mit der Umsetzung. Erstelle zuerst `depotguard.sh`, dann `index.html`, `style.css`, `script.js` und `save_email.php`.
