<?php
/* =========================================================================
   DepotTracker - send_test_email.php
   --------------------------------------------------------------------------
   TODO: DEMO BUTTON — vor Abgabe entfernen
   --------------------------------------------------------------------------
   Sendet eine HTML-Test-E-Mail ueber Gmail SMTP (smtp.gmail.com:465, SSL).
   Wird vom Demo-Button im Dashboard via fetch POST aufgerufen.
   --------------------------------------------------------------------------
   Antwortformat:
     Erfolg : {"success": true}
     Fehler : {"success": false, "error": "Fehlertext"}
   ========================================================================= */

header("Content-Type: application/json; charset=utf-8");
header("Cache-Control: no-store");

// -------------------------------------------------------------------------
// SMTP-Zugangsdaten (Gmail App-Passwort).
// HINWEIS: In Produktion in eine separate, nicht versionierte Konfig-Datei
// auslagern. Fuer das LB3-Demo bewusst inline.
// -------------------------------------------------------------------------
const SMTP_SERVER = "smtp.gmail.com";
const SMTP_PORT   = 465;
const SMTP_USER   = "depottracker@gmail.com";
const SMTP_PASS   = "ymas qwaw sfde dyfs";
const SENDER_NAME = "DepotTracker";

// -------------------------------------------------------------------------
// Hilfsfunktion: JSON-Antwort + Abbruch.
// -------------------------------------------------------------------------
function respond(bool $ok, ?string $error = null, int $code = 200): void {
    http_response_code($code);
    $body = ["success" => $ok];
    if ($error !== null) {
        $body["error"] = $error;
    }
    echo json_encode($body, JSON_UNESCAPED_UNICODE);
    exit;
}

// -------------------------------------------------------------------------
// SMTP: Antwort lesen (kann mehrzeilig sein, "250-..." -> weitere Zeile,
// "250 ..." -> letzte Zeile).
// -------------------------------------------------------------------------
function smtp_read($fp): string {
    $data = "";
    while (($line = fgets($fp, 1024)) !== false) {
        $data .= $line;
        // 4. Zeichen ist " " bei letzter Zeile, "-" bei weiteren Zeilen.
        if (isset($line[3]) && $line[3] === " ") {
            break;
        }
    }
    return $data;
}

// -------------------------------------------------------------------------
// SMTP: Kommando senden + erwarteten Statuscode pruefen.
// -------------------------------------------------------------------------
function smtp_cmd($fp, string $cmd, int $expected, string $context): void {
    fwrite($fp, $cmd . "\r\n");
    $resp = smtp_read($fp);
    $code = (int) substr($resp, 0, 3);
    if ($code !== $expected) {
        respond(false, "$context fehlgeschlagen: " . trim($resp), 502);
    }
}

// -------------------------------------------------------------------------
// 1) Methode pruefen.
// -------------------------------------------------------------------------
if (($_SERVER["REQUEST_METHOD"] ?? "") !== "POST") {
    respond(false, "Nur POST erlaubt.", 405);
}

// -------------------------------------------------------------------------
// 2) JSON-Body parsen.
// -------------------------------------------------------------------------
$raw = file_get_contents("php://input");
if ($raw === false || $raw === "") {
    respond(false, "Leerer Request-Body.", 400);
}

$data = json_decode($raw, true);
if (!is_array($data) || !isset($data["email"])) {
    respond(false, "Ungültiges JSON oder Feld 'email' fehlt.", 400);
}

$recipient = trim((string) $data["email"]);

// -------------------------------------------------------------------------
// 3) Empfaenger validieren.
// -------------------------------------------------------------------------
if (!filter_var($recipient, FILTER_VALIDATE_EMAIL)) {
    respond(false, "Ungültige E-Mail-Adresse.", 400);
}
if (strlen($recipient) > 254) {
    respond(false, "E-Mail-Adresse zu lang.", 400);
}
// Schutz gegen Header-Injection: keine Steuerzeichen.
if (preg_match('/[\r\n]/', $recipient)) {
    respond(false, "E-Mail enthält unzulässige Zeichen.", 400);
}

// -------------------------------------------------------------------------
// 4) Mail-Inhalt zusammenbauen (HTML + Text-Fallback).
// -------------------------------------------------------------------------
$subject        = "⚠️ DepotTracker Test-Alarm";
$subjectEncoded = "=?UTF-8?B?" . base64_encode($subject) . "?=";

$htmlBody = <<<HTML
<!DOCTYPE html>
<html lang="de">
<head><meta charset="UTF-8"><title>DepotTracker Alarm</title></head>
<body style="margin:0;padding:0;background:#f4f6fa;font-family:Helvetica,Arial,sans-serif;color:#1a2238;">
  <table width="100%" cellpadding="0" cellspacing="0" border="0">
    <tr><td align="center" style="padding:32px 12px;">
      <table width="560" cellpadding="0" cellspacing="0" border="0" style="background:#ffffff;border-radius:14px;overflow:hidden;box-shadow:0 6px 28px rgba(0,0,0,0.10);">

        <tr><td style="background:linear-gradient(135deg,#ff5566,#ff8a8a);padding:26px 28px;color:#ffffff;">
          <div style="font-size:12px;letter-spacing:1.6px;text-transform:uppercase;opacity:0.9;">DepotTracker &middot; Margin Call</div>
          <div style="font-size:22px;font-weight:700;margin-top:6px;">⚠️ Depotwert unter Schwelle</div>
        </td></tr>

        <tr><td style="padding:28px;">
          <p style="margin:0 0 18px;font-size:15px;line-height:1.6;">
            Hallo,<br><br>
            der überwachte Depotwert hat die kritische Schwelle <strong>unterschritten</strong>.
            Bitte prüfe deine Position umgehend.
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
              📎 Im Echtbetrieb wäre dieser E-Mail eine <strong>Schweizer QR-Rechnung</strong>
              über den Differenzbetrag als Anhang beigefügt.
            </div>
          </div>

          <p style="margin:24px 0 0;padding:14px 16px;background:#eef3ff;border-radius:8px;font-size:12px;color:#4f6fa3;line-height:1.5;">
            🧪 <strong>Demo-E-Mail:</strong> Diese Nachricht wurde manuell über den Test-Button
            im DepotTracker-Dashboard ausgelöst. Es handelt sich um <strong>keinen echten Alarm</strong>.
          </p>
        </td></tr>

        <tr><td style="background:#0b0f1a;padding:16px 28px;text-align:center;font-size:12px;color:#7e8aa3;">
          DepotTracker &middot; LB3-Projekt 2026 &middot; Philippe &amp; Viggo
        </td></tr>

      </table>
    </td></tr>
  </table>
</body>
</html>
HTML;

$textBody = <<<TEXT
DepotTracker - Margin Call (TEST)
==================================

Hallo,

der überwachte Depotwert hat die kritische Schwelle unterschritten.
Bitte prüfe deine Position umgehend.

  Aktueller Depotwert : 8'500.00 CHF
  Allzeithoch (ATH)   : 14'820.00 CHF
  Verlust vom ATH     : -42.7 %

Im Echtbetrieb wäre dieser E-Mail eine Schweizer QR-Rechnung
über den Differenzbetrag als Anhang beigefügt.

---
Demo-E-Mail: Diese Nachricht wurde manuell über den Test-Button
im DepotTracker-Dashboard ausgelöst. Es handelt sich um KEINEN
echten Alarm.

DepotTracker - LB3-Projekt 2026
TEXT;

// -------------------------------------------------------------------------
// 5) Multipart-Message bauen (text/plain + text/html).
// -------------------------------------------------------------------------
$boundary = "depottracker_" . bin2hex(random_bytes(8));
$messageId = "<" . bin2hex(random_bytes(12)) . "@depottracker.local>";

$headers  = "From: " . sprintf('"%s" <%s>', SENDER_NAME, SMTP_USER) . "\r\n";
$headers .= "To: <$recipient>\r\n";
$headers .= "Subject: $subjectEncoded\r\n";
$headers .= "Date: " . date("r") . "\r\n";
$headers .= "Message-ID: $messageId\r\n";
$headers .= "MIME-Version: 1.0\r\n";
$headers .= "Content-Type: multipart/alternative; boundary=\"$boundary\"\r\n";

$body  = "--$boundary\r\n";
$body .= "Content-Type: text/plain; charset=UTF-8\r\n";
$body .= "Content-Transfer-Encoding: 8bit\r\n\r\n";
$body .= $textBody . "\r\n";
$body .= "--$boundary\r\n";
$body .= "Content-Type: text/html; charset=UTF-8\r\n";
$body .= "Content-Transfer-Encoding: 8bit\r\n\r\n";
$body .= $htmlBody . "\r\n";
$body .= "--$boundary--\r\n";

// CRLF normalisieren + RFC-5321-Dot-Stuffing (Zeilen mit "." am Anfang
// muessen verdoppelt werden, sonst wird DATA vorzeitig beendet).
$payload = $headers . "\r\n" . $body;
$payload = preg_replace('/(?<!\r)\n/', "\r\n", $payload);
$payload = preg_replace('/^\./m', '..', $payload);

// -------------------------------------------------------------------------
// 6) SMTP-Konversation (SMTP_SSL auf Port 465).
// -------------------------------------------------------------------------
$errno  = 0;
$errstr = "";
$fp = @stream_socket_client(
    "ssl://" . SMTP_SERVER . ":" . SMTP_PORT,
    $errno,
    $errstr,
    15,
    STREAM_CLIENT_CONNECT
);

if (!$fp) {
    respond(false, "SMTP-Verbindung fehlgeschlagen: $errstr ($errno)", 502);
}
stream_set_timeout($fp, 15);

// 220 Begruessung
$greeting = smtp_read($fp);
if ((int) substr($greeting, 0, 3) !== 220) {
    fclose($fp);
    respond(false, "SMTP-Greeting fehlgeschlagen: " . trim($greeting), 502);
}

// EHLO
smtp_cmd($fp, "EHLO depottracker.local", 250, "EHLO");

// AUTH LOGIN (Base64-Username/Password)
smtp_cmd($fp, "AUTH LOGIN",                  334, "AUTH LOGIN");
smtp_cmd($fp, base64_encode(SMTP_USER),      334, "Username-Authentifizierung");
smtp_cmd($fp, base64_encode(SMTP_PASS),      235, "Passwort-Authentifizierung");

// MAIL FROM / RCPT TO
smtp_cmd($fp, "MAIL FROM:<" . SMTP_USER . ">", 250, "MAIL FROM");
smtp_cmd($fp, "RCPT TO:<$recipient>",          250, "RCPT TO");

// DATA
smtp_cmd($fp, "DATA", 354, "DATA");
fwrite($fp, $payload . "\r\n.\r\n");
$dataResp = smtp_read($fp);
if ((int) substr($dataResp, 0, 3) !== 250) {
    fclose($fp);
    respond(false, "Mail-Übermittlung fehlgeschlagen: " . trim($dataResp), 502);
}

// QUIT (Antwort interessiert nicht mehr).
@fwrite($fp, "QUIT\r\n");
@fclose($fp);

// -------------------------------------------------------------------------
// 7) Erfolg.
// -------------------------------------------------------------------------
respond(true);
