<?php
/* =========================================================================
   DepotTracker - save_email.php
   --------------------------------------------------------------------------
   Empfaengt einen JSON-POST-Request mit einer E-Mail-Adresse vom Dashboard
   und schreibt diese in die Variable EMAIL_RECIPIENT der Datei depotguard.sh.
   --------------------------------------------------------------------------
   Antwortformat:
     Erfolg : {"success": true}
     Fehler : {"success": false, "error": "Fehlertext"}
   ========================================================================= */

// Antwort immer als JSON mit UTF-8 ausgeben.
header("Content-Type: application/json; charset=utf-8");
header("Cache-Control: no-store");

// -------------------------------------------------------------------------
// Hilfsfunktion: JSON-Antwort + sauberer Abbruch.
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
// 1) Methode pruefen - es werden ausschliesslich POST-Requests akzeptiert.
// -------------------------------------------------------------------------
if (($_SERVER["REQUEST_METHOD"] ?? "") !== "POST") {
    respond(false, "Nur POST erlaubt.", 405);
}

// -------------------------------------------------------------------------
// 2) Body einlesen und JSON dekodieren.
// -------------------------------------------------------------------------
$raw = file_get_contents("php://input");
if ($raw === false || $raw === "") {
    respond(false, "Leerer Request-Body.", 400);
}

$data = json_decode($raw, true);
if (!is_array($data) || !isset($data["email"])) {
    respond(false, "Ungueltiges JSON oder Feld 'email' fehlt.", 400);
}

$email = trim((string) $data["email"]);

// -------------------------------------------------------------------------
// 3) Serverseitige Validierung.
//    a) PHP-Filter (RFC-konform).
//    b) Zusaetzliche Regex als Backup, falls filter_var zu permissiv ist.
//    c) Schutz gegen Injection in die Bash-Datei: keine Steuerzeichen,
//       keine Anfuehrungszeichen, kein Newline.
// -------------------------------------------------------------------------
if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
    respond(false, "Ungueltige E-Mail-Adresse.", 400);
}
if (!preg_match('/^[^\s@"\'`\\\\]+@[^\s@"\'`\\\\]+\.[^\s@"\'`\\\\]{2,}$/', $email)) {
    respond(false, "E-Mail enthaelt unzulaessige Zeichen.", 400);
}
if (strlen($email) > 254) {
    respond(false, "E-Mail-Adresse zu lang.", 400);
}

// -------------------------------------------------------------------------
// 4) Zieldatei (depotguard.sh) bestimmen und einlesen.
//    realpath/__DIR__ verhindert ungewollte Pfad-Traversierung.
// -------------------------------------------------------------------------
$scriptPath = __DIR__ . DIRECTORY_SEPARATOR . "depotguard.sh";
if (!is_file($scriptPath)) {
    respond(false, "depotguard.sh nicht gefunden.", 500);
}
if (!is_readable($scriptPath) || !is_writable($scriptPath)) {
    respond(false, "depotguard.sh ist nicht beschreibbar.", 500);
}

$contents = file_get_contents($scriptPath);
if ($contents === false) {
    respond(false, "Fehler beim Lesen von depotguard.sh.", 500);
}

// -------------------------------------------------------------------------
// 5) Zeile EMAIL_RECIPIENT="..." per Regex ersetzen.
//    - Nur die ERSTE passende Zeile am Zeilenanfang wird angepasst.
//    - Anfuehrungszeichen werden zwingend gesetzt, damit der Wert sicher
//      in Bash interpretiert wird.
// -------------------------------------------------------------------------
$pattern     = '/^(EMAIL_RECIPIENT=)"[^"]*"\s*$/m';
$replacement = '$1"' . $email . '"';

$newContents = preg_replace($pattern, $replacement, $contents, 1, $count);
if ($newContents === null) {
    respond(false, "Regex-Fehler beim Ersetzen.", 500);
}
if ($count === 0) {
    respond(false, "Variable EMAIL_RECIPIENT in depotguard.sh nicht gefunden.", 500);
}

// -------------------------------------------------------------------------
// 6) Atomar zurueckschreiben:
//    - tmp-Datei im selben Verzeichnis schreiben
//    - chmod auf 0644 (oder bestehende Rechte uebernehmen)
//    - rename() ist auf POSIX-Systemen atomar.
// -------------------------------------------------------------------------
$tmpPath = $scriptPath . ".tmp." . bin2hex(random_bytes(4));
if (file_put_contents($tmpPath, $newContents, LOCK_EX) === false) {
    respond(false, "Konnte temporaere Datei nicht schreiben.", 500);
}

// Bestehende Berechtigungen uebernehmen, sonst Default 0755.
$perms = fileperms($scriptPath);
@chmod($tmpPath, $perms !== false ? ($perms & 0777) : 0755);

if (!@rename($tmpPath, $scriptPath)) {
    @unlink($tmpPath);
    respond(false, "Konnte depotguard.sh nicht aktualisieren.", 500);
}

// -------------------------------------------------------------------------
// 7) Erfolg melden.
// -------------------------------------------------------------------------
respond(true);
