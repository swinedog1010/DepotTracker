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
CREDENTIALS_GPG_PATH = os.path.join(SCRIPT_DIR, "credentials.json.gpg")  # Feature 2
RECIPIENT_PATH = os.path.join(SCRIPT_DIR, "recipient.json")   # Empfaenger-Mail (Single Source of Truth)
MODE_PATH = os.path.join(SCRIPT_DIR, "mode.json")             # live/simulation/read-only (Feature 1)
FX_PATH = os.path.join(SCRIPT_DIR, "fx_cache.json")           # FX-Rates (Feature 3)
PAPER_PATH = os.path.join(SCRIPT_DIR, "paper_depot.json")     # Paper-Trading (Feature 1)

# Erlaubte Modi - jede andere Eingabe wird zu read-only normalisiert.
VALID_MODES = ("live", "simulation", "read-only")

# FX (Feature 3): server.py uebernimmt den eigentlichen Abruf, depotguard.sh
# nutzt denselben Cache nur defensiv. open.er-api.com benoetigt keinen Key.
FX_API_URL = "https://open.er-api.com/v6/latest/USD"
FX_CACHE_MAX_AGE_S = 12 * 3600     # 12 Stunden - FX bewegt sich kaum
FX_FETCH_TIMEOUT_S = 8

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


def read_recipient():
    """Liest die Empfaenger-Mail aus recipient.json (vom Terminal-Setup
    in depotguard.sh angelegt). Gibt einen leeren String zurueck, wenn die
    Datei fehlt oder unlesbar ist - der Aufrufer entscheidet dann ueber
    Fehler/Toast."""
    if not os.path.isfile(RECIPIENT_PATH):
        return ""
    try:
        with open(RECIPIENT_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return ""
    if not isinstance(data, dict):
        return ""
    return (data.get("email") or "").strip()


def write_recipient(email):
    """Atomar recipient.json schreiben. Wirft OSError, falls IO scheitert."""
    payload = {"email": email}
    fd, tmp = tempfile.mkstemp(prefix="recipient.", suffix=".tmp", dir=SCRIPT_DIR)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
            f.write("\n")
        try:
            os.chmod(tmp, 0o600)
        except OSError:
            pass
        os.replace(tmp, RECIPIENT_PATH)
    except Exception:
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass
        raise


def read_mode_state():
    """Liest mode.json und normalisiert den Wert auf einen der drei
    erlaubten Modi. Default ist read-only - der sicherste Stand fuer das
    Frontend (deaktiviert alle Schreib-Aktionen)."""
    state = {"mode": "read-only", "set_at": ""}
    if os.path.isfile(MODE_PATH):
        try:
            with open(MODE_PATH, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                mode = (data.get("mode") or "").strip().lower()
                if mode in VALID_MODES:
                    state["mode"] = mode
                state["set_at"] = str(data.get("set_at") or "")
        except (OSError, json.JSONDecodeError):
            pass
    return state


def _read_fx_cache_file():
    """Liest fx_cache.json zurueck. Liefert None, wenn die Datei fehlt
    oder ungueltig ist."""
    if not os.path.isfile(FX_PATH):
        return None
    try:
        with open(FX_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def _fx_cache_is_fresh():
    if not os.path.isfile(FX_PATH):
        return False
    try:
        age = time.time() - os.path.getmtime(FX_PATH)
    except OSError:
        return False
    return age < FX_CACHE_MAX_AGE_S


def _write_fx_cache(rates_in, time_label):
    """Schreibt den FX-Cache atomar."""
    out = {
        "base": "USD",
        "fetched_at": time_label,
        "rates": {k: float(v) for k, v in rates_in.items()
                  if isinstance(v, (int, float))},
    }
    fd, tmp = tempfile.mkstemp(prefix="fx.", suffix=".tmp", dir=SCRIPT_DIR)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.replace(tmp, FX_PATH)
    except Exception:
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass
        raise
    return out


def ensure_fx_cache_fresh():
    """Stellt sicher, dass fx_cache.json juenger als FX_CACHE_MAX_AGE_S ist.
    Ist der Cache veraltet oder leer, wird ein Online-Abruf bei
    open.er-api.com gemacht (USD-Basis, keine API-Key noetig). Bei einem
    Fehler (offline, API down) wird einfach der vorhandene Cache zurueck-
    gegeben und stale=True markiert. So rendert das Frontend immer Daten,
    statt rot zu blinken."""
    if _fx_cache_is_fresh():
        cached = _read_fx_cache_file() or {}
        cached["stale"] = False
        return cached

    # Stale (oder kein) Cache: Abruf versuchen.
    try:
        import urllib.request
        req = urllib.request.Request(FX_API_URL, headers={"User-Agent": "DepotTracker/1.0"})
        with urllib.request.urlopen(req, timeout=FX_FETCH_TIMEOUT_S) as resp:
            raw = resp.read().decode("utf-8")
        data = json.loads(raw)
    except Exception as exc:
        sys.stderr.write("[WARN] FX-API nicht erreichbar: %s\n" % exc)
        cached = _read_fx_cache_file() or {"base": "USD", "fetched_at": "", "rates": {}}
        cached["stale"] = True
        return cached

    rates_in = data.get("rates") or data.get("conversion_rates") or {}
    time_label = (data.get("time_last_update_utc")
                  or data.get("time_last_update")
                  or "")
    try:
        out = _write_fx_cache(rates_in, time_label)
    except Exception as exc:
        sys.stderr.write("[WARN] FX-Cache schreiben fehlgeschlagen: %s\n" % exc)
        cached = _read_fx_cache_file() or {"base": "USD", "fetched_at": "", "rates": {}}
        cached["stale"] = True
        return cached
    out["stale"] = False
    return out


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
        # Read-Only-Sperre (Feature 1): jeder schreibende Endpoint wird
        # geblockt, sobald mode.json den Wert "read-only" hat. Das
        # Frontend deaktiviert die Buttons zwar selbst, aber hier kommt
        # die zweite Verteidigungslinie - falls jemand das UI umgeht.
        current_mode = read_mode_state().get("mode", "read-only")
        if self.path in ("/save_email", "/save_smtp", "/send_test_email"):
            if current_mode == "read-only":
                self._respond_json(
                    423, False,
                    "READ-ONLY-Modus aktiv - Schreib-Operationen sind gesperrt.",
                )
                return
            # Im SIMULATION-Modus erlauben wir das Speichern der Empfaenger-
            # Adresse, sperren aber den echten Mailversand, damit die
            # Lehrer-Demo nie zufaellig eine echte Test-Mail rausschickt.
            if current_mode == "simulation" and self.path == "/send_test_email":
                self._respond_json(
                    409, False,
                    "SIMULATIONS-Modus aktiv - kein Mailversand. In LIVE-Modus wechseln.",
                )
                return

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
        if self.path == "/api/recipient":
            self._handle_get_recipient()
            return
        if self.path == "/api/mode":
            self._handle_get_mode()
            return
        if self.path == "/api/fx":
            self._handle_get_fx()
            return
        if self.path == "/api/paper":
            self._handle_get_paper()
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

    # ---------- /api/recipient ----------------------------------------------
    def _handle_get_recipient(self):
        """Gibt die im Terminal hinterlegte Empfaenger-Mail zurueck.
        Format: {"email": "..."}. Leerer String, wenn noch nicht gesetzt -
        das Frontend kann das nutzen, um das Setup-Modal zu zeigen oder zu
        ueberspringen."""
        email = read_recipient()
        payload = json.dumps({"email": email}, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    # ---------- /api/mode ---------------------------------------------------
    def _handle_get_mode(self):
        """Liefert den aktuellen Lauf-Modus (Feature 1) als JSON.
        Format: {"mode": "live"|"simulation"|"read-only", "set_at": "..."}.

        Ist mode.json nicht vorhanden oder enthaelt sie einen unbekannten
        Wert, antworten wir mit "read-only" - das ist der sicherste Default
        fuer das Frontend (deaktiviert alle Schreib-Buttons). Zusaetzlich
        melden wir, ob fuer credentials.json.gpg eine GPG-Datei existiert
        (Feature 2), damit das Dashboard signalisiert, dass die Credentials
        sicher verschluesselt liegen."""
        payload_obj = read_mode_state()
        # Sichtbares Sicherheits-Indiz fuer das Dashboard.
        payload_obj["credentials_encrypted"] = os.path.isfile(CREDENTIALS_GPG_PATH)
        payload = json.dumps(payload_obj, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    # ---------- /api/fx -----------------------------------------------------
    def _handle_get_fx(self):
        """Liefert die aktuellen Wechselkurse (Feature 3). Im Gegensatz
        zur ersten Iteration ist es jetzt server.py selbst, der den
        Online-Abruf bei open.er-api.com macht - sobald der Cache aelter
        als FX_CACHE_MAX_AGE_S ist, wird ein neuer Abruf gestartet. Der
        Klient bekommt entweder den frisch gezogenen oder den vorhandenen
        Cache zurueck. Im Fehlerfall (offline, API down) liefert der
        Endpoint einen leeren Rates-Block, damit das Frontend nichts
        zerlegt."""
        data = ensure_fx_cache_fresh()
        out = {
            "base": str(data.get("base", "USD")) if isinstance(data, dict) else "USD",
            "fetched_at": str(data.get("fetched_at", "")) if isinstance(data, dict) else "",
            "rates": {},
            "stale": bool(data.get("stale", False)) if isinstance(data, dict) else True,
        }
        if isinstance(data, dict):
            rates = data.get("rates") or {}
            if isinstance(rates, dict):
                out["rates"] = {
                    str(k): float(v) for k, v in rates.items()
                    if isinstance(v, (int, float))
                }
        payload = json.dumps(out, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    # ---------- /api/paper --------------------------------------------------
    def _handle_get_paper(self):
        """Liefert den Stand des Paper-Trading-Depots (Feature 1). Existiert
        paper_depot.json nicht, antworten wir mit leerem Objekt - das ist
        kein Fehler, sondern bedeutet, dass der User noch nie im
        SIMULATION-Modus gestartet hat."""
        out = {
            "starting_balance_chf": 0,
            "balance_chf": 0,
            "history": [],
            "exists": False,
        }
        if os.path.isfile(PAPER_PATH):
            try:
                with open(PAPER_PATH, "r", encoding="utf-8") as f:
                    data = json.load(f)
                if isinstance(data, dict):
                    out["starting_balance_chf"] = float(data.get("starting_balance_chf", 0) or 0)
                    out["balance_chf"] = float(data.get("balance_chf", 0) or 0)
                    hist = data.get("history") or []
                    if isinstance(hist, list):
                        # Nur die letzten 60 Punkte ausliefern - reicht fuer
                        # einen aussagekraeftigen Verlauf, hilt das Frontend schlank.
                        out["history"] = hist[-60:]
                    out["exists"] = True
            except (OSError, json.JSONDecodeError, ValueError):
                pass
        payload = json.dumps(out, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
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
        """Aktualisiert die Empfaenger-Mail in recipient.json. Single
        Source of Truth - depotguard.sh und /send_test_email lesen
        beide aus dieser Datei. Vom Dashboard "Empfaenger aendern"-
        Button genutzt; das Frontend fragt KEINE Absender-Daten mehr ab."""
        data, err = self._read_json()
        if err:
            self._respond_json(400, False, err)
            return

        email, err = self._validate_email(data.get("email"))
        if err:
            self._respond_json(400, False, err)
            return

        try:
            write_recipient(email)
        except OSError as exc:
            self._respond_json(500, False, "Konnte recipient.json nicht schreiben: %s" % exc)
            return

        self._respond_json(200, True)

    # ---------- /save_smtp (deaktiviert) ------------------------------------
    def _handle_save_smtp(self):
        """Absender-Daten sind fest im Backend hinterlegt - das Frontend
        darf sie nicht mehr setzen. Endpoint bleibt nur als Tombstone
        bestehen, damit alte Clients eine eindeutige Antwort bekommen."""
        self._respond_json(
            410, False,
            "Absender-Daten werden nicht mehr ueber das Web-UI gesetzt.",
        )

    # ---------- /send_test_email --------------------------------------------
    def _handle_send_test_email(self):
        """Sendet die Demo-Mail an die in recipient.json hinterlegte
        Adresse. Der Request-Body wird nicht mehr ausgewertet - der
        Empfaenger kommt ausschliesslich aus recipient.json (vom
        Terminal-Setup in depotguard.sh angelegt)."""
        # Request-Body trotzdem lesen, falls Content-Length > 0 ist
        # (alte Clients schicken weiterhin {"email": "..."}). Der Inhalt
        # wird ignoriert - nur Parser-Fehler werden gemeldet.
        if int(self.headers.get("Content-Length", "0") or 0) > 0:
            _, err = self._read_json()
            if err:
                self._respond_json(400, False, err)
                return

        recipient = read_recipient()
        if not recipient:
            self._respond_json(
                412, False,
                "Empfaenger nicht gesetzt - bitte depotguard.sh ausfuehren oder /save_email aufrufen.",
            )
            return
        recipient, err = self._validate_email(recipient)
        if err:
            self._respond_json(500, False, "recipient.json enthaelt ungueltige E-Mail: %s" % err)
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
def _decrypt_gpg_credentials():
    """Entschluesselt credentials.json.gpg in /dev/shm (Feature 2), liest
    den Klartext sofort in den Prozess-RAM und loescht die RAM-Disk-Datei
    SOFORT wieder. Damit liegt der Klartext nirgends auf der Disk und nur
    so lange im RAM, wie der Server-Prozess laeuft.

    Liefert das geparste JSON-Dict zurueck oder None bei Fehler."""
    import shutil
    import subprocess
    import tempfile

    if not shutil.which("gpg"):
        sys.stderr.write(
            "[WARN] gpg nicht installiert - credentials.json.gpg kann nicht entschluesselt werden.\n"
        )
        return None

    # /dev/shm bevorzugen, sonst TMPDIR (mit Hinweis).
    if os.path.isdir("/dev/shm") and os.access("/dev/shm", os.W_OK):
        ramdir = "/dev/shm"
    else:
        ramdir = tempfile.gettempdir()
        sys.stderr.write(
            "[WARN] /dev/shm nicht verfuegbar - Credentials werden temporaer in %s entschluesselt.\n" % ramdir
        )

    fd, target = tempfile.mkstemp(prefix="depottracker.server.cred-", suffix=".json", dir=ramdir)
    os.close(fd)
    try:
        os.chmod(target, 0o600)
    except OSError:
        pass

    # Passphrase-Quellen: env DEPOT_GPG_PASS oder .gpg_passphrase-Datei.
    pass_args = []
    pass_file = os.path.join(SCRIPT_DIR, ".gpg_passphrase")
    env_pass = os.environ.get("DEPOT_GPG_PASS")
    if env_pass:
        pass_args = ["--batch", "--yes", "--passphrase", env_pass, "--pinentry-mode", "loopback"]
    elif os.path.isfile(pass_file):
        pass_args = ["--batch", "--yes", "--passphrase-file", pass_file, "--pinentry-mode", "loopback"]

    try:
        result = subprocess.run(
            ["gpg", *pass_args, "--quiet", "--decrypt",
             "--output", target, CREDENTIALS_GPG_PATH],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=20,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        sys.stderr.write("[WARN] gpg-Aufruf fehlgeschlagen: %s\n" % exc)
        result = None

    data = None
    try:
        if result is not None and result.returncode == 0 and os.path.isfile(target):
            with open(target, "r", encoding="utf-8") as f:
                data = json.load(f)
        else:
            err = result.stderr.decode("utf-8", errors="replace") if result else "kein Resultat"
            sys.stderr.write("[WARN] GPG-Entschluesselung fehlgeschlagen: %s\n" % err.strip())
    except (OSError, json.JSONDecodeError) as exc:
        sys.stderr.write("[WARN] entschluesselte Datei nicht lesbar: %s\n" % exc)
    finally:
        # WICHTIG: RAM-Disk-Datei sofort wieder loeschen, egal ob der
        # Lese-Vorgang erfolgreich war oder nicht. Der Server haelt die
        # Werte ab hier ausschliesslich im Prozess-RAM.
        if os.path.exists(target):
            try:
                os.unlink(target)
            except OSError:
                pass

    return data if isinstance(data, dict) else None


def load_credentials():
    """Vorzugspfad (Feature 2): credentials.json.gpg per GPG nach /dev/shm
    entschluesseln, sofort lesen und temporaere Datei wieder loeschen.
    Faellt auf die Klartext-credentials.json zurueck, falls keine GPG-Datei
    vorhanden ist (Legacy-Pfad fuer Entwicklungsrechner)."""
    global SMTP_USER, SMTP_PASS

    data = None
    if os.path.isfile(CREDENTIALS_GPG_PATH):
        data = _decrypt_gpg_credentials()
        if data is None:
            sys.stderr.write(
                "[WARN] GPG-Pfad fehlgeschlagen - falle auf credentials.json zurueck.\n"
            )

    if data is None:
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
