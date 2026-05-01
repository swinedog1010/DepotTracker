#!/usr/bin/env python3
# =========================================================================
# DepotTracker - server.py
# -------------------------------------------------------------------------
# Kleiner HTTP-Server, der auf Port 8000 laeuft und sowohl die statischen
# Dateien (HTML, CSS, JS, Bilder) ausliefert als auch die folgenden
# Backend-Endpunkte bereitstellt:
#
#   POST /save_email       - speichert die Empfaenger-E-Mail in depotguard.sh
#   POST /save_smtp        - speichert Gmail-Absender + App-Passwort in
#                            depotguard.sh (SMTP_USER, SMTP_PASS)
#   POST /send_test_email  - verschickt eine HTML-Test-Mail via Gmail-SMTP
#
# Es werden ausschliesslich Module der Python-Standardbibliothek genutzt
# (http.server, smtplib, email, ssl, json, re, ...).
#
# Start:  python server.py
# =========================================================================

from datetime import date
from email.mime.application import MIMEApplication
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.utils import formatdate, formataddr, make_msgid
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import glob
import io
import json
import os
import re
import smtplib
import ssl
import sys
import tempfile
import time

from qrbill import QRBill
from svglib.svglib import svg2rlg
from reportlab.graphics import renderPDF

# -------------------------------------------------------------------------
# Konfiguration
# -------------------------------------------------------------------------
PORT = 8000
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEPOTGUARD_PATH = os.path.join(SCRIPT_DIR, "depotguard.sh")
CREDENTIALS_PATH = os.path.join(SCRIPT_DIR, "credentials.json")

# Local-First / API-Kontingent:
# Tagesaktuelle Snapshots schreibt depotguard.sh nach SCRIPT_DIR/depot_YYYY-MM-DD.json.
# counter.json (gleiches Verzeichnis) haelt den Tageszaehler. Beide Dateien
# werden hier nur GELESEN - der Server stoesst keinen Online-Abruf an.
COUNTER_PATH = os.path.join(SCRIPT_DIR, "counter.json")
DAILY_API_LIMIT = 30
SEND_TEST_EMAIL_THROTTLE_S = 0.75   # System-Throttling bei /send_test_email

# SMTP-Konfiguration. SMTP_USER und SMTP_PASS werden beim Start aus
# credentials.json geladen (siehe load_credentials) und koennen zur
# Laufzeit ueber /save_smtp aktualisiert werden. credentials.json ist
# via .gitignore vom Repo ausgeschlossen - eine Vorlage liegt in
# credentials.example.json.
SMTP_SERVER = "smtp.gmail.com"
SMTP_PORT = 465
SMTP_USER = ""
SMTP_PASS = ""
SENDER_NAME = "DepotTracker"

# Strenge E-Mail-Regex (gleiches Muster wie zuvor in save_email.php).
EMAIL_RE = re.compile(r'^[^\s@"\'`\\]+@[^\s@"\'`\\]+\.[^\s@"\'`\\]{2,}$')

# App-Passwort: 16 alphanumerische Zeichen, optional in Vierergruppen mit
# Leerzeichen (Anzeigeformat von Google).
APP_PASS_RE = re.compile(r'^[A-Za-z0-9 ]+$')

# -------------------------------------------------------------------------
# Demo-Daten fuer die Beispiel-QR-Rechnung (fiktiver Empfaenger).
# -------------------------------------------------------------------------
QR_BILL_ACCOUNT = "CH4431999123000889012"
QR_BILL_CREDITOR = {
    "name": "Max Muster",
    "line1": "Musterstrasse 1",
    "line2": "8000 Zuerich",
    "country": "CH",
}
QR_BILL_AMOUNT = "6320.00"
QR_BILL_CURRENCY = "CHF"
# Gueltige QRR-Referenz (27 Stellen inkl. Pruefziffer) - das verwendete
# IBAN ist eine QR-IBAN (IID 31999) und verlangt zwingend eine QRR-Referenz.
QR_BILL_REFERENCE = "210000000003139471430009017"

# -------------------------------------------------------------------------
# Mail-Inhalt (HTML + Text-Fallback)
# -------------------------------------------------------------------------
HTML_BODY = """<!DOCTYPE html>
<html lang="de">
<head><meta charset="UTF-8"><title>DepotTracker Alarm</title></head>
<body style="margin:0;padding:0;background:#f4f6fa;font-family:Helvetica,Arial,sans-serif;color:#1a2238;">
  <table width="100%" cellpadding="0" cellspacing="0" border="0">
    <tr><td align="center" style="padding:32px 12px;">
      <table width="560" cellpadding="0" cellspacing="0" border="0" style="background:#ffffff;border-radius:14px;overflow:hidden;box-shadow:0 6px 28px rgba(0,0,0,0.10);">

        <tr><td style="background:linear-gradient(135deg,#ff5566,#ff8a8a);padding:26px 28px;color:#ffffff;">
          <div style="font-size:12px;letter-spacing:1.6px;text-transform:uppercase;opacity:0.9;">DepotTracker &middot; Margin Call</div>
          <div style="font-size:22px;font-weight:700;margin-top:6px;">&#9888;&#65039; Depotwert unter Schwelle</div>
        </td></tr>

        <tr><td style="padding:28px;">
          <p style="margin:0 0 18px;font-size:15px;line-height:1.6;">
            Hallo,<br><br>
            der &uuml;berwachte Depotwert hat die kritische Schwelle <strong>unterschritten</strong>.
            Bitte pr&uuml;fe deine Position umgehend.
          </p>

          <table width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:18px 0;border-collapse:separate;border-spacing:0 6px;">
            <tr><td style="padding:14px 16px;background:#fff1f3;border-left:4px solid #ff5566;border-radius:8px;">
              <div style="font-size:11px;color:#a35761;text-transform:uppercase;letter-spacing:1.2px;">Aktueller Depotwert</div>
              <div style="font-size:22px;font-weight:700;color:#ff5566;margin-top:4px;font-family:'Courier New',monospace;">8'500.00 CHF</div>
            </td></tr>
            <tr><td style="padding:14px 16px;background:#f4f6fa;border-left:4px solid #cdd5e3;border-radius:8px;">
              <div style="font-size:11px;color:#7e8aa3;text-transform:uppercase;letter-spacing:1.2px;">Allzeithoch (ATH)</div>
              <div style="font-size:18px;font-weight:600;color:#1a2238;margin-top:4px;font-family:'Courier New',monospace;">14'820.00 CHF</div>
            </td></tr>
            <tr><td style="padding:14px 16px;background:#fff1f3;border-left:4px solid #ff5566;border-radius:8px;">
              <div style="font-size:11px;color:#a35761;text-transform:uppercase;letter-spacing:1.2px;">Verlust vom ATH</div>
              <div style="font-size:18px;font-weight:700;color:#ff5566;margin-top:4px;font-family:'Courier New',monospace;">&minus;42.7 %</div>
            </td></tr>
          </table>

          <div style="background:#fff8e1;border-left:4px solid #f5a623;padding:14px 16px;border-radius:6px;margin-top:18px;">
            <div style="font-size:13px;color:#6e5511;line-height:1.5;">
              &#128206; Im Anhang findest du eine <strong>Schweizer QR-Rechnung</strong>
              (PDF, Demo-Daten) &uuml;ber den Differenzbetrag von <strong>6'320.00 CHF</strong>.
            </div>
          </div>

          <p style="margin:24px 0 0;padding:14px 16px;background:#eef3ff;border-radius:8px;font-size:12px;color:#4f6fa3;line-height:1.5;">
            &#129514; <strong>Demo-E-Mail:</strong> Diese Nachricht wurde manuell &uuml;ber den Test-Button
            im DepotTracker-Dashboard ausgel&ouml;st. Es handelt sich um <strong>keinen echten Alarm</strong>.
          </p>
        </td></tr>

        <tr><td style="background:#0b0f1a;padding:16px 28px;text-align:center;font-size:12px;color:#7e8aa3;">
          DepotTracker &middot; LB3-Projekt 2026 &middot; Philippe &amp; Viggo
        </td></tr>

      </table>
    </td></tr>
  </table>
</body>
</html>"""

TEXT_BODY = """DepotTracker - Margin Call (TEST)
==================================

Hallo,

der ueberwachte Depotwert hat die kritische Schwelle unterschritten.
Bitte pruefe deine Position umgehend.

  Aktueller Depotwert : 8'500.00 CHF
  Allzeithoch (ATH)   : 14'820.00 CHF
  Verlust vom ATH     : -42.7 %

Im Anhang findest du eine Schweizer QR-Rechnung (PDF, Demo-Daten)
ueber den Differenzbetrag von 6'320.00 CHF.

---
Demo-E-Mail: Diese Nachricht wurde manuell ueber den Test-Button
im DepotTracker-Dashboard ausgeloest. Es handelt sich um KEINEN
echten Alarm.

DepotTracker - LB3-Projekt 2026
"""


# =========================================================================
# QR-Rechnung -> PDF
# =========================================================================
def build_qr_bill_pdf():
    """Erzeugt eine Schweizer QR-Rechnung mit den fiktiven Demo-Daten und
    liefert sie als PDF-Bytes zurueck."""
    bill = QRBill(
        account=QR_BILL_ACCOUNT,
        creditor=QR_BILL_CREDITOR,
        amount=QR_BILL_AMOUNT,
        currency=QR_BILL_CURRENCY,
        reference_number=QR_BILL_REFERENCE,
        language="de",
    )

    # qrbill liefert SVG-Text mit XML-Deklaration. svglib akzeptiert nur
    # bytes ohne Unicode-Encoding-Hinweis -> als BytesIO durchreichen.
    svg_buf = io.StringIO()
    bill.as_svg(svg_buf)
    svg_bytes = svg_buf.getvalue().encode("utf-8")

    drawing = svg2rlg(io.BytesIO(svg_bytes))
    if drawing is None:
        raise RuntimeError("QR-Rechnung konnte nicht in PDF umgewandelt werden.")
    return renderPDF.drawToString(drawing)


# =========================================================================
# Local-First Snapshot-Lookup (read-only)
# =========================================================================
def today_snapshot_path():
    """Pfad zur Tages-Snapshot-Datei fuer das HEUTIGE Datum."""
    return os.path.join(SCRIPT_DIR, "depot_%s.json" % date.today().isoformat())


def latest_snapshot_path():
    """Liefert den juengsten verfuegbaren depot_YYYY-MM-DD.json oder None.

    Wird genutzt, wenn fuer heute noch nichts vorliegt (z.B. depotguard.sh
    lief noch nicht heute) - das Dashboard fallback'd dann auf den letzten
    bekannten Stand statt einer leeren Antwort.
    """
    candidates = sorted(glob.glob(os.path.join(SCRIPT_DIR, "depot_*.json")))
    return candidates[-1] if candidates else None


def read_quota_state():
    """Liest counter.json. Setzt count automatisch auf 0, wenn das Datum
    nicht heute ist (Tageswechsel-Reset)."""
    today = date.today().isoformat()
    state = {"date": today, "count": 0, "limit": DAILY_API_LIMIT}
    if not os.path.isfile(COUNTER_PATH):
        return state
    try:
        with open(COUNTER_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return state
    if isinstance(data, dict) and data.get("date") == today:
        state["count"] = int(data.get("count", 0))
        state["limit"] = int(data.get("limit", DAILY_API_LIMIT))
    return state


# =========================================================================
# Request-Handler
# =========================================================================
class DepotTrackerHandler(SimpleHTTPRequestHandler):
    """Liefert statische Dateien (via SimpleHTTPRequestHandler) und
    behandelt zusaetzlich die POST- und API-Endpunkte."""

    # ---------- POST-Routing -------------------------------------------------
    def do_POST(self):
        if self.path == "/save_email":
            self._handle_save_email()
        elif self.path == "/save_smtp":
            self._handle_save_smtp()
        elif self.path == "/send_test_email":
            self._handle_send_test_email()
        else:
            self._respond_json(404, False, "Endpunkt nicht gefunden.")

    # ---------- GET-Routing --------------------------------------------------
    def do_GET(self):
        # API-Endpunkte werden VOR der statischen Auslieferung geprueft,
        # sonst wuerde SimpleHTTPRequestHandler 404 zurueckgeben.
        if self.path == "/api/depot":
            self._handle_get_depot()
            return
        if self.path == "/api/quota":
            self._handle_get_quota()
            return
        super().do_GET()

    # ---------- /api/depot --------------------------------------------------
    def _handle_get_depot(self):
        """Local-First: gibt den heutigen Depot-Snapshot zurueck. Falls
        heute noch keiner geschrieben wurde, faellt der Endpunkt auf den
        letzten verfuegbaren zurueck und markiert das in der Antwort."""
        path = today_snapshot_path()
        stale = False
        if not os.path.isfile(path):
            fallback = latest_snapshot_path()
            if fallback is None:
                self._respond_json(
                    404, False,
                    "Noch kein Snapshot vorhanden - bitte depotguard.sh laufen lassen.",
                )
                return
            path = fallback
            stale = True

        try:
            with open(path, "r", encoding="utf-8") as f:
                content = f.read()
        except OSError as exc:
            self._respond_json(500, False, "Snapshot nicht lesbar: %s" % exc)
            return

        # Snapshot-Body 1:1 weiterreichen (er kommt von depotguard.sh als JSON).
        # Quelle und stale-Flag zusaetzlich als Header, damit das Frontend
        # den Datenstand anzeigen kann, ohne das Body-Schema zu aendern.
        payload = content.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Snapshot-Source", os.path.basename(path))
        self.send_header("X-Snapshot-Stale", "1" if stale else "0")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    # ---------- /api/quota --------------------------------------------------
    def _handle_get_quota(self):
        """Liefert den aktuellen Stand des API-Tageszaehlers (read-only)."""
        state = read_quota_state()
        state["remaining"] = max(0, state["limit"] - state["count"])
        payload = json.dumps(state, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    # ---------- Antwort-Hilfen ----------------------------------------------
    def _respond_json(self, code, success, error=None):
        body = {"success": success}
        if error is not None:
            body["error"] = error
        payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    # ---------- Eingabe-Hilfen ----------------------------------------------
    def _read_json(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None, "Ungueltige Content-Length."
        if length <= 0:
            return None, "Leerer Request-Body."
        # Sanity-Limit gegen oversized payloads.
        if length > 64 * 1024:
            return None, "Request-Body zu gross."
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None, "Ungueltiges JSON."
        if not isinstance(data, dict):
            return None, "JSON-Objekt erwartet."
        return data, None

    def _validate_email(self, value):
        email = (value or "").strip() if isinstance(value, str) else ""
        if not email:
            return None, "E-Mail-Adresse fehlt."
        if len(email) > 254:
            return None, "E-Mail-Adresse zu lang."
        if not EMAIL_RE.match(email):
            return None, "Ungueltige E-Mail-Adresse."
        # Schutz gegen Header-Injection.
        if "\r" in email or "\n" in email:
            return None, "E-Mail enthaelt unzulaessige Zeichen."
        return email, None

    # ---------- /save_email --------------------------------------------------
    def _handle_save_email(self):
        data, err = self._read_json()
        if err:
            self._respond_json(400, False, err)
            return

        email, err = self._validate_email(data.get("email"))
        if err:
            self._respond_json(400, False, err)
            return

        if not os.path.isfile(DEPOTGUARD_PATH):
            self._respond_json(500, False, "depotguard.sh nicht gefunden.")
            return

        try:
            with open(DEPOTGUARD_PATH, "r", encoding="utf-8", newline="") as f:
                contents = f.read()
        except OSError as exc:
            self._respond_json(500, False, "Fehler beim Lesen von depotguard.sh: %s" % exc)
            return

        # Erste Zeile EMAIL_RECIPIENT="..." am Zeilenanfang ersetzen.
        pattern = re.compile(r'^(EMAIL_RECIPIENT=)"[^"]*"\s*$', re.MULTILINE)
        new_contents, count = pattern.subn(r'\1"' + email + '"', contents, count=1)
        if count == 0:
            self._respond_json(
                500, False,
                "Variable EMAIL_RECIPIENT in depotguard.sh nicht gefunden.",
            )
            return

        # Atomar zurueckschreiben (tmp-Datei + os.replace).
        tmp_path = None
        try:
            fd, tmp_path = tempfile.mkstemp(
                prefix="depotguard.", suffix=".tmp", dir=SCRIPT_DIR
            )
            with os.fdopen(fd, "w", encoding="utf-8", newline="") as tmp:
                tmp.write(new_contents)
            try:
                perms = os.stat(DEPOTGUARD_PATH).st_mode & 0o777
                os.chmod(tmp_path, perms)
            except OSError:
                pass
            os.replace(tmp_path, DEPOTGUARD_PATH)
            tmp_path = None
        except OSError as exc:
            if tmp_path and os.path.exists(tmp_path):
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
            self._respond_json(500, False, "Konnte depotguard.sh nicht aktualisieren: %s" % exc)
            return

        self._respond_json(200, True)

    # ---------- /save_smtp ---------------------------------------------------
    def _handle_save_smtp(self):
        data, err = self._read_json()
        if err:
            self._respond_json(400, False, err)
            return

        # Absender-Adresse validieren (gleiche Regel wie Empfaenger).
        smtp_user, err = self._validate_email(data.get("smtp_user"))
        if err:
            self._respond_json(400, False, err)
            return

        # App-Passwort validieren: 16 alphanumerische Zeichen, ggf. mit
        # Leerzeichen formatiert. Whitespace fuer den Vergleich ignorieren.
        raw_pass = data.get("smtp_pass")
        if not isinstance(raw_pass, str) or not raw_pass.strip():
            self._respond_json(400, False, "App-Passwort fehlt.")
            return
        smtp_pass = raw_pass.strip()
        if "\r" in smtp_pass or "\n" in smtp_pass:
            self._respond_json(400, False, "App-Passwort enthaelt unzulaessige Zeichen.")
            return
        if not APP_PASS_RE.match(smtp_pass):
            self._respond_json(400, False, "App-Passwort enthaelt unzulaessige Zeichen.")
            return
        if len(re.sub(r"\s+", "", smtp_pass)) != 16:
            self._respond_json(400, False, "App-Passwort muss 16 Zeichen lang sein.")
            return

        # credentials.json atomar schreiben.
        payload = {"smtp_user": smtp_user, "smtp_pass": smtp_pass}
        tmp_path = None
        try:
            fd, tmp_path = tempfile.mkstemp(
                prefix="credentials.", suffix=".tmp", dir=SCRIPT_DIR
            )
            with os.fdopen(fd, "w", encoding="utf-8") as tmp:
                json.dump(payload, tmp, ensure_ascii=False, indent=2)
                tmp.write("\n")
            # Best-effort 0600 (unter Windows oft ohne Effekt, schadet nicht).
            try:
                os.chmod(tmp_path, 0o600)
            except OSError:
                pass
            os.replace(tmp_path, CREDENTIALS_PATH)
            tmp_path = None
        except OSError as exc:
            if tmp_path and os.path.exists(tmp_path):
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
            self._respond_json(500, False, "Konnte credentials.json nicht schreiben: %s" % exc)
            return

        # Modul-Globals aktualisieren, damit /send_test_email die neuen
        # Daten ohne Server-Neustart nutzt.
        global SMTP_USER, SMTP_PASS
        SMTP_USER = smtp_user
        SMTP_PASS = smtp_pass

        self._respond_json(200, True)

    # ---------- /send_test_email --------------------------------------------
    def _handle_send_test_email(self):
        data, err = self._read_json()
        if err:
            self._respond_json(400, False, err)
            return

        recipient, err = self._validate_email(data.get("email"))
        if err:
            self._respond_json(400, False, err)
            return

        # Beispiel-QR-Rechnung als PDF erzeugen (vor SMTP-Aufbau, damit
        # ein Generator-Fehler den Versand sauber verhindert).
        try:
            qr_pdf_bytes = build_qr_bill_pdf()
        except Exception as exc:  # qrbill / svglib werfen breit gefaecherte Fehler
            self._respond_json(500, False, "QR-Rechnung-Fehler: %s" % exc)
            return

        # System-Throttling: kurze Pause zwischen QR-Build und SMTP-Aufbau,
        # um schnelle Mehrfachklicks im Dashboard nicht direkt nach Gmail
        # weiterzureichen. time.sleep() entlastet zudem den Event-Loop.
        time.sleep(SEND_TEST_EMAIL_THROTTLE_S)

        # MIME-Struktur:
        #   multipart/mixed
        #     |-- multipart/alternative (Text + HTML)
        #     +-- application/pdf       (QR-Rechnung)
        msg = MIMEMultipart("mixed")
        msg["Subject"] = "⚠️ DepotTracker Test-Alarm"
        msg["From"] = formataddr((SENDER_NAME, SMTP_USER))
        msg["To"] = recipient
        msg["Date"] = formatdate(localtime=True)
        msg["Message-ID"] = make_msgid(domain="depottracker.local")

        body = MIMEMultipart("alternative")
        body.attach(MIMEText(TEXT_BODY, "plain", "utf-8"))
        body.attach(MIMEText(HTML_BODY, "html", "utf-8"))
        msg.attach(body)

        pdf_part = MIMEApplication(qr_pdf_bytes, _subtype="pdf")
        pdf_part.add_header(
            "Content-Disposition", "attachment", filename="qr-rechnung.pdf"
        )
        msg.attach(pdf_part)

        try:
            ctx = ssl.create_default_context()
            with smtplib.SMTP_SSL(SMTP_SERVER, SMTP_PORT, context=ctx, timeout=15) as smtp:
                smtp.login(SMTP_USER, SMTP_PASS)
                smtp.sendmail(SMTP_USER, [recipient], msg.as_string())
        except (smtplib.SMTPException, OSError, ssl.SSLError) as exc:
            self._respond_json(502, False, "SMTP-Fehler: %s" % exc)
            return

        self._respond_json(200, True)

    # ---------- Logging kompakt ---------------------------------------------
    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), fmt % args))


# =========================================================================
# Bootstrap: SMTP-Daten aus credentials.json laden
# =========================================================================
def load_credentials():
    """Liest SMTP_USER und SMTP_PASS aus credentials.json. Fehlt die Datei
    oder ist sie unlesbar, bleiben die Defaults leer - /send_test_email
    schlaegt dann mit einer SMTP-Auth-Meldung um, und der Benutzer kann
    die Daten ueber das Modal nachtragen."""
    global SMTP_USER, SMTP_PASS
    if not os.path.isfile(CREDENTIALS_PATH):
        sys.stderr.write(
            "[WARN] credentials.json nicht gefunden - SMTP nicht konfiguriert.\n"
        )
        return
    try:
        with open(CREDENTIALS_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        sys.stderr.write(
            "[WARN] credentials.json konnte nicht gelesen werden: %s\n" % exc
        )
        return
    if isinstance(data, dict):
        SMTP_USER = str(data.get("smtp_user", "") or "")
        SMTP_PASS = str(data.get("smtp_pass", "") or "")


# =========================================================================
# Einstiegspunkt
# =========================================================================
def main():
    # Statische Dateien werden relativ zum Script-Verzeichnis ausgeliefert.
    os.chdir(SCRIPT_DIR)
    load_credentials()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), DepotTrackerHandler)
    print("DepotTracker laeuft auf http://localhost:%d/  (Strg+C zum Beenden)" % PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer wird beendet.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
