# DepotTracker

**LB3-Projekt 2026 - Philippe und Viggo**

## Projektbeschreibung

DepotTracker ist ein vollautomatisiertes System zur Ueberwachung von Krypto-Depots. Das Projekt kombiniert ein Bash-Skript (`code/depotguard.sh`) fuer den Cronjob-Betrieb auf Ubuntu mit einem Python-basierten Web-Dashboard (`code/server.py`), das den aktuellen Depotwert visualisiert und den Versand von Test-Alarmen erlaubt.

Sobald ein definierter Schwellenwert unterschritten wird, generiert das System automatisch eine Schweizer QR-Rechnung ueber den Differenzbetrag und versendet sie zusammen mit einer Alarm-E-Mail an die hinterlegte Adresse.

## Hauptfunktionen

- Live-Dashboard mit Depotwert, Allzeithoch und Verlauf-Chart
- Tagliches Cronjob-Skript zur automatischen Ueberwachung
- Local-First Cache + tagliches API-Limit (max. 30 Online-Abrufe/Tag) gegen Quota-Probleme
- Schweizer QR-Rechnung als PDF im E-Mail-Anhang
- Konfiguration per zweistufigem Modal direkt im Browser

## Voraussetzungen

- **Windows 10/11 mit WSL 2** (Ubuntu 22.04 oder neuer empfohlen) **oder** natives Ubuntu/Debian
- **Python 3.9+** (auf Ubuntu 22.04 vorinstalliert)
- **Git**
- **Gmail-Konto mit aktiver 2-Faktor-Authentifizierung** (fuer das App-Passwort, siehe unten)

---

## Schritt-fuer-Schritt-Anleitung (WSL / Ubuntu)

### 1. WSL einrichten (nur Windows-Nutzer)

In einer **PowerShell** als Administrator:

```powershell
wsl --install -d Ubuntu
```

Nach dem Reboot Ubuntu starten und Benutzer/Passwort anlegen. Alle weiteren Schritte erfolgen im **Ubuntu-Terminal** (WSL).

### 2. Repository klonen

```bash
cd ~
git clone https://github.com/EUER-USERNAME/DepotTracker.git
cd DepotTracker
```

### 3. Setup ausfuehren

Das mitgelieferte `setup.sh` installiert alle System-Pakete (`libcairo2-dev`, `pkg-config`, `python3-dev`, `python3-venv`), legt die Python-`venv` unter `code/venv/` neu an, installiert alle Pakete aus `code/requirements.txt` und macht `code/depotguard.sh` ausfuehrbar.

```bash
chmod +x setup.sh
./setup.sh
```

Das Setup fragt einmal nach deinem `sudo`-Passwort (fuer `apt install`).

### 4. Gmail-Zugangsdaten eintragen

Erstelle ein Google App-Passwort (siehe Abschnitt [Gmail App-Passwort](#gmail-app-passwort)) und trage es in `code/credentials.json` ein - das exakte Format steht weiter unten unter [credentials.json - Format](#credentialsjson---format).

> Alternativ kannst du die Datei beim ersten Lauf von `depotguard.sh` interaktiv im Terminal anlegen lassen oder spaeter im Web-Dashboard ueber das Konfigurations-Modal befuellen.

### 5. DepotTracker starten

```bash
cd code
./depotguard.sh
```

Beim ersten Lauf:

- legt das Skript die Verzeichnisse `logs/` und `output/` an,
- richtet einen Cronjob fuer 09:00 Uhr ein (sofern `crontab` verfuegbar),
- fragt am Ende, ob auch das Web-Dashboard gestartet werden soll.

Das Dashboard ist anschliessend unter <http://localhost:8000> erreichbar.

> WSL-Tipp: Die URL kannst du direkt in deinem Windows-Browser oeffnen - WSL leitet `localhost` automatisch ans Windows-Hostsystem weiter.

---

## Gmail App-Passwort

Damit der E-Mail-Versand ueber Gmail funktioniert, ist ein **App-Passwort** erforderlich (kein normales Login-Passwort). Voraussetzung: 2-Faktor-Authentifizierung im Google-Konto ist aktiviert.

**So erstellst du das App-Passwort:**

1. Oeffne <https://myaccount.google.com/apppasswords>
2. Logge dich mit deinem Google-Konto ein (2FA muss aktiv sein - sonst zeigt Google die Seite nicht an).
3. Gib einen beliebigen Namen ein, z.B. `DepotTracker`, und klicke auf **Erstellen**.
4. Google zeigt ein **16-stelliges Passwort** in vier Vierergruppen an, z.B. `abcd efgh ijkl mnop`.
5. Kopiere dieses Passwort - es wird **nur einmal** angezeigt.

Trage Adresse und Passwort anschliessend in `code/credentials.json` ein (Format siehe naechster Abschnitt).

### credentials.json - Format

Die Datei liegt unter `code/credentials.json` und hat **exakt** folgende Struktur:

```json
{
  "smtp_user": "deine.adresse@gmail.com",
  "smtp_pass": "abcd efgh ijkl mnop"
}
```

Felder:

| Feld         | Inhalt                                                                  |
| ------------ | ----------------------------------------------------------------------- |
| `smtp_user`  | Deine Gmail-Adresse (vollstaendig, inkl. `@gmail.com`)                  |
| `smtp_pass`  | Das 16-stellige App-Passwort - mit oder ohne Leerzeichen, beides erlaubt |

> Wichtig:
> - Die Datei wird via `.gitignore` vom Repository ausgeschlossen und bleibt nur lokal.
> - Eine Vorlage findest du in `code/credentials.example.json`.
> - Setze die Dateirechte restriktiv (`chmod 600 code/credentials.json`), damit das Passwort nicht von anderen Benutzern lesbar ist.

---

## Fehlerbehebung

### `pip install` schlaegt mit `pycairo`-Fehler ab

Beim Installieren von `cairosvg` / `svglib` versucht pip im Hintergrund auch `pycairo` zu kompilieren. Das schlaegt mit Meldungen wie

```
Package cairo was not found in the pkg-config search path.
No package 'cairo' found
ERROR: Failed building wheel for pycairo
```

fehl, wenn die **System-Bibliothek** `libcairo2-dev` fehlt. Auf WSL/Ubuntu loest du das mit:

```bash
sudo apt update
sudo apt install -y libcairo2-dev pkg-config python3-dev
```

Anschliessend `setup.sh` erneut ausfuehren - es legt die `venv` automatisch neu an. Das Setup-Skript installiert genau diese Pakete bereits selbst, nur falls du die Installation manuell ausgefuehrt hast, brauchst du den Schritt nochmal.

### `externally-managed-environment` beim direkten `pip install`

Aktuelle Ubuntu-/Debian-Versionen (PEP 668) verbieten `pip` direkt ins System-Python zu schreiben. Loesung: **immer `setup.sh` benutzen** - das installiert in die projektlokale `code/venv/`.

### `python3 -m venv` schlaegt fehl mit `ensurepip is not available`

Das Paket `python3-venv` fehlt:

```bash
sudo apt install -y python3-venv
```

### `depotguard.sh: Permission denied`

Ausfuehrrechte setzen:

```bash
chmod +x code/depotguard.sh
```

`setup.sh` macht das automatisch - falls du das Skript ohne Setup ausgefuehrt hast, hol das mit obigem Befehl nach.

### `bash: ./depotguard.sh: /usr/bin/env: 'bash\r': Datei oder Verzeichnis nicht gefunden`

Windows-Zeilenenden (CRLF). Auf der WSL-Seite einmal:

```bash
sudo apt install -y dos2unix
dos2unix code/depotguard.sh setup.sh
```

### Dashboard zeigt `404 /api/depot`

`depotguard.sh` wurde an dem Tag noch nicht ausgefuehrt - es existiert noch keine Datei `code/depot_YYYY-MM-DD.json`. Einmal `./depotguard.sh` laufen lassen, dann den Browser neu laden.

---

## Projektstruktur

```
DepotTracker/
├── setup.sh                    # einmaliges Setup-Skript (apt + venv + pip)
├── README.md                   # diese Datei
├── MASTER_PROMPT.md            # Projektdokumentation
├── ablaufdiagramm.pdf
└── code/
    ├── depotguard.sh           # Bash-Hauptskript fuer den Cronjob
    ├── server.py               # HTTP-Server (Port 8000) fuer Dashboard + API
    ├── requirements.txt        # Python-Abhaengigkeiten
    ├── credentials.example.json
    ├── credentials.json        # (lokal, via .gitignore ausgeschlossen)
    ├── index.html              # Dashboard-UI
    ├── script.js
    ├── style.css
    ├── logo/                   # Bild-Assets
    └── venv/                   # Python-venv (von setup.sh angelegt, .gitignore)
```

Erzeugte Laufzeit-Dateien (alle via `.gitignore` ausgeschlossen):

| Datei                          | Zweck                                                       |
| ------------------------------ | ----------------------------------------------------------- |
| `code/ath.txt`                 | Allzeithoch des Depots                                      |
| `code/history.csv`             | CSV-Historie aller Laeufe                                   |
| `code/price_cache.json`        | Letzte CoinGecko-Antwort (Roh-Cache fuer den aktuellen Lauf) |
| `code/depot_YYYY-MM-DD.json`   | Tages-Snapshot (Local-First Quelle fuer Dashboard und Cron) |
| `code/counter.json`            | API-Tageszaehler (Limit: 30 Calls/Tag)                      |
| `code/logs/`                   | Log-Dateien                                                 |
| `code/output/`                 | Generierte QR-Rechnungen (SVG)                              |

---

*LB3-Projekt 2026 - Philippe & Viggo*
