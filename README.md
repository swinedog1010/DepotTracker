# DepotTracker

**LB3-Projekt 2026 - Philippe und Viggo**

## Projektbeschreibung

DepotTracker ist ein vollautomatisiertes System zur Ueberwachung von Krypto-Depots. Das Projekt kombiniert ein Bash-Skript (`depotguard.sh`) fuer den Cronjob-Betrieb auf Ubuntu mit einem Python-basierten Web-Dashboard, das den aktuellen Depotwert visualisiert und den Versand von Test-Alarmen erlaubt.

Sobald ein definierter Schwellenwert unterschritten wird, generiert das System automatisch eine Schweizer QR-Rechnung ueber den Differenzbetrag und versendet sie zusammen mit einer Alarm-E-Mail an die hinterlegte Adresse.

Das Projekt wurde im Rahmen der LB3 entwickelt.

## Hauptfunktionen

- Live-Dashboard mit Depotwert, Allzeithoch und Verlauf-Chart
- Tagliches Cronjob-Skript zur automatischen Ueberwachung
- Schweizer QR-Rechnung als PDF im E-Mail-Anhang
- Konfiguration per zweistufigem Modal direkt im Browser

## Voraussetzungen

- **Python 3** (>= 3.9)
- **pip**
- **Git**
- **Gmail-Konto mit App-Passwort** (siehe Hinweis unten)
- Fuer den Bash-Teil: **Ubuntu / Linux** mit `bash`, `curl`, `awk`

## Installation

```bash
git clone https://github.com/EUER-USERNAME/DepotTracker.git
cd DepotTracker/code
pip install qrbill svglib reportlab cairosvg
python3 server.py
```

Anschliessend im Browser oeffnen: <http://localhost:8000>

Beim ersten Aufruf erscheint ein zweistufiges Modal:

1. **Empfaenger-E-Mail** - die Adresse, an die Alarme verschickt werden.
2. **Gmail-Absender** - eigene Gmail-Adresse plus App-Passwort, ueber die der Versand laeuft.

Beide Werte werden direkt in `depotguard.sh` (`EMAIL_RECIPIENT`, `SMTP_USER`, `SMTP_PASS`) eingetragen und bleiben nur lokal auf deinem System.

## Bash-Skript auf Ubuntu

Nach dem Konfigurieren ueber das Web-Dashboard kann das Bash-Skript manuell oder als Cronjob laufen:

```bash
chmod +x depotguard.sh
./depotguard.sh
```

Beim ersten Lauf richtet das Skript die noetigen Verzeichnisse (`logs/`, `output/`) ein und installiert einen taeglichen Cronjob (09:00 Uhr).

## Gmail App-Passwort

Damit der E-Mail-Versand ueber Gmail funktioniert, ist ein **App-Passwort** erforderlich (kein normales Login-Passwort). Voraussetzung: 2-Faktor-Authentifizierung im Google-Konto ist aktiviert.

Anleitung von Google: <https://support.google.com/accounts/answer/185833>

Das App-Passwort ist 16 Zeichen lang und wird typischerweise in Vierergruppen angezeigt (z.B. `abcd efgh ijkl mnop`).

## Projektstruktur

- `code/depotguard.sh` - Bash-Hauptskript fuer den Cronjob-Betrieb
- `code/server.py` - HTTP-Server (Port 8000) fuer Dashboard + Konfiguration
- `code/index.html`, `code/script.js`, `code/style.css` - Web-Frontend
- `code/logo/` - Bild-Assets
- `MASTER_PROMPT.md`, `ablaufdiagramm.pdf` - Projektdokumentation

---
*LB3-Projekt 2026 - Philippe & Viggo*
