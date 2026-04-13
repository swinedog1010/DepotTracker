# DepotTracker

**Projekt von Philippe & Viggo**

## Projektbeschreibung
Auto-DepotGuard ist ein vollautomatisiertes Bash-System zur Überwachung von Wertschriften- und Kryptodepots unter Ubuntu. Das Skript stellt sicher, dass ein definierter Depotwert (Schwelle) nicht unterschritten wird, und leitet bei Bedarf automatisch Massnahmen ein.

Das Projekt wurde im Rahmen der LB3 entwickelt und kombiniert verschiedene fortgeschrittene Scripting-Konzepte in einer einzigen, robusten Lösung.

## Hauptfunktionen
- **Automatisches Setup:** Das Skript erstellt bei der ersten Ausführung selbstständig alle benötigten Verzeichnisse und richtet einen Cronjob für die tägliche Ausführung ein.
- **Intelligentes Caching:** Um API-Limits zu schonen, werden Kurse lokal zwischengespeichert. Online-Abfragen finden nur statt, wenn die Daten veraltet sind.
- **System-Ressourcenmanagement:** Vor jeder Ausführung wird die aktuelle Systemlast (CPU Load) geprüft. Bei hoher Auslastung pausiert das Skript automatisch.
- **Schweizer Standard Integration:** Bei einer Unterdeckung generiert das System automatisch eine Schweizer QR-Rechnung über den Differenzbetrag.
- **Automatisierte Kommunikation:** Der Benutzer wird im Krisenfall (Margin Call) sofort per E-Mail inklusive der QR-Rechnung im Anhang informiert.

## Technische Details
- **Sprache:** Bash (Shell Script)
- **Umgebung:** Ubuntu / Linux
- **Voraussetzungen:** `curl`, `awk`, `base64`
- **Features:** Arrays, Schleifen, Funktionen, Error-Handling, Logging.

## Installation & Start
1. Das Skript `depotguard.sh` auf den Laptop kopieren.
2. Ausführrechte vergeben: `chmod +x depotguard.sh`
3. Einmalig manuell starten: `./depotguard.sh`
4. Den Rest erledigt das System vollautomatisch über den installierten Cronjob.

---
*Erstellt für die LB3 - 2026*
