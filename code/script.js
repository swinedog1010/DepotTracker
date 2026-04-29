/* =========================================================================
   DepotTracker - script.js
   --------------------------------------------------------------------------
   Steuert das Dashboard: Modal, Counter-Animationen, Status-Indikator,
   Chart, Tabelle "Letzte Laeufe", Fortschrittsbalken und Scan-Button.
   Saemtliche Texte und Kommentare in Schweizer Schreibweise (ss statt ß).
   ========================================================================= */

(() => {
    "use strict";

    /* ---------------------------------------------------------------------
       1) UTILS
       --------------------------------------------------------------------- */

    /**
     * Validiert eine E-Mail-Adresse mit einer einfachen Regex.
     * Strenge Pruefung erfolgt zusaetzlich serverseitig in save_email.php.
     */
    const isValidEmail = (value) =>
        /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(String(value).trim());

    /**
     * Formatiert eine Zahl als CHF-Wert mit Schweizer Schreibweise
     * (Tausender-Apostroph, zwei Nachkommastellen).
     */
    const formatCHF = (value) =>
        Number(value).toLocaleString("de-CH", {
            minimumFractionDigits: 2,
            maximumFractionDigits: 2,
        });

    /**
     * Hilfsfunktion: Wartezeit als Promise (fuer await sleep(...)).
     */
    const sleep = (ms) => new Promise((res) => setTimeout(res, ms));

    /* ---------------------------------------------------------------------
       2) TOAST-NOTIFICATIONS
       --------------------------------------------------------------------- */
    const toastContainer = document.getElementById("toast-container");

    function showToast(message, type = "success", duration = 3500) {
        // Erstellt einen kurzlebigen Hinweis oben rechts.
        const toast = document.createElement("div");
        toast.className = `toast toast-${type}`;
        toast.textContent = message;
        toastContainer.appendChild(toast);

        // Animation in zwei Frames anstossen, damit die CSS-Transition greift.
        requestAnimationFrame(() => toast.classList.add("show"));

        setTimeout(() => {
            toast.classList.remove("show");
            setTimeout(() => toast.remove(), 320);
        }, duration);
    }

    /* ---------------------------------------------------------------------
       3) MODAL: ZWEISTUFIGER WIZARD
          Schritt 1 - Empfaenger-Adresse
          Schritt 2 - Gmail-Absender + App-Passwort
       --------------------------------------------------------------------- */
    const modal         = document.getElementById("email-modal");
    const modalTitle    = document.getElementById("modal-title");
    const modalSubtitle = document.getElementById("modal-subtitle");

    const emailForm   = document.getElementById("email-form");
    const emailInput  = document.getElementById("email-input");
    const emailError  = document.getElementById("email-error");
    const emailSubmit = document.getElementById("email-submit");

    const smtpForm      = document.getElementById("smtp-form");
    const smtpUserInput = document.getElementById("smtp-user-input");
    const smtpPassInput = document.getElementById("smtp-pass-input");
    const smtpError     = document.getElementById("smtp-error");
    const smtpSubmit    = document.getElementById("smtp-submit");
    const smtpSkipBtn   = document.getElementById("smtp-skip");

    const STORAGE_KEY        = "depottracker.email";
    const STORAGE_SMTP_FLAG  = "depottracker.smtp_configured";

    // Validiert ein Gmail App-Passwort: 16 alphanumerische Zeichen, ggf.
    // mit Leerzeichen formatiert (z.B. "abcd efgh ijkl mnop").
    const isValidAppPassword = (value) => {
        const stripped = String(value).replace(/\s+/g, "");
        return /^[A-Za-z0-9]{16}$/.test(stripped);
    };

    function setStep(n) {
        // Schaltet zwischen Schritt 1 und 2 um und passt Titel/Untertitel an.
        const isStep1 = n === 1;
        emailForm.hidden = !isStep1;
        smtpForm.hidden  =  isStep1;

        if (isStep1) {
            modalTitle.textContent    = "Empfänger hinterlegen";
            modalSubtitle.textContent =
                "Du erhältst automatisch eine E-Mail mit einer Schweizer " +
                "QR-Rechnung, sobald dein Depotwert die kritische Schwelle " +
                "unterschreitet.";
        } else {
            modalTitle.textContent    = "Gmail-Absender konfigurieren";
            modalSubtitle.textContent =
                "Trage deine Gmail-Adresse und dein App-Passwort ein. " +
                "Die Daten werden lokal in depotguard.sh gespeichert und " +
                "ausschliesslich für den Versand genutzt.";

            // Skip-Button nur sichtbar, wenn SMTP bereits konfiguriert ist.
            const alreadyConfigured =
                localStorage.getItem(STORAGE_SMTP_FLAG) === "1";
            smtpSkipBtn.hidden = !alreadyConfigured;
        }

        setTimeout(
            () => (isStep1 ? emailInput : smtpUserInput).focus(),
            220
        );
    }

    function openModal() {
        // Beim erneuten Oeffnen ("E-Mail aendern") gespeicherte Adresse vorbefuellen.
        const saved = localStorage.getItem(STORAGE_KEY);
        if (saved) emailInput.value = saved;
        emailError.hidden = true;
        smtpError.hidden  = true;
        // App-Passwort nie vorbefuellen.
        smtpPassInput.value = "";
        setStep(1);
        modal.classList.add("is-open");
        modal.setAttribute("aria-hidden", "false");
    }

    function closeModal() {
        modal.classList.remove("is-open");
        modal.setAttribute("aria-hidden", "true");
    }

    // Beim ersten Besuch oeffnet sich das Modal automatisch.
    function maybeOpenModal() {
        const saved = localStorage.getItem(STORAGE_KEY);
        if (!saved) {
            openModal();
        }
    }

    // ---------- Schritt 1: Empfaenger-Adresse ---------------------------------
    emailForm.addEventListener("submit", async (event) => {
        event.preventDefault();
        const value = emailInput.value.trim();

        if (!isValidEmail(value)) {
            emailError.hidden = false;
            emailInput.focus();
            return;
        }
        emailError.hidden = true;
        emailSubmit.disabled = true;
        emailSubmit.textContent = "Speichere ...";

        try {
            const res = await fetch("/save_email", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ email: value }),
            });

            const ct = res.headers.get("content-type") || "";
            const data = ct.includes("application/json")
                ? await res.json()
                : { success: res.ok };

            if (!res.ok || !data.success) {
                throw new Error(data.error || "Server-Fehler");
            }

            localStorage.setItem(STORAGE_KEY, value);
            showToast("Empfänger gespeichert.", "success");
            // Statt Modal zu schliessen: weiter zu Schritt 2.
            setStep(2);
        } catch (err) {
            console.warn("/save_email nicht erreichbar:", err);
            // Lokal speichern, aber trotzdem zu Schritt 2 weiter.
            localStorage.setItem(STORAGE_KEY, value);
            showToast("Empfänger lokal gespeichert (Server offline).", "error");
            setStep(2);
        } finally {
            emailSubmit.disabled = false;
            emailSubmit.textContent = "Weiter";
        }
    });

    // ---------- Schritt 2: Gmail-Absender + App-Passwort ----------------------
    smtpForm.addEventListener("submit", async (event) => {
        event.preventDefault();
        const user = smtpUserInput.value.trim();
        const pass = smtpPassInput.value;

        if (!isValidEmail(user) || !isValidAppPassword(pass)) {
            smtpError.hidden = false;
            (isValidEmail(user) ? smtpPassInput : smtpUserInput).focus();
            return;
        }
        smtpError.hidden = true;
        smtpSubmit.disabled = true;
        smtpSubmit.textContent = "Speichere ...";

        try {
            const res = await fetch("/save_smtp", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ smtp_user: user, smtp_pass: pass }),
            });

            const ct = res.headers.get("content-type") || "";
            const data = ct.includes("application/json")
                ? await res.json()
                : { success: res.ok };

            if (!res.ok || !data.success) {
                throw new Error(data.error || "Server-Fehler");
            }

            localStorage.setItem(STORAGE_SMTP_FLAG, "1");
            // Klartext-Passwort nicht im Memory belassen.
            smtpPassInput.value = "";
            closeModal();
            showToast("SMTP-Daten gespeichert!", "success");
        } catch (err) {
            console.error("/save_smtp fehlgeschlagen:", err);
            smtpError.textContent =
                "Konnte SMTP-Daten nicht speichern: " + (err.message || err);
            smtpError.hidden = false;
        } finally {
            smtpSubmit.disabled = false;
            smtpSubmit.textContent = "Speichern";
        }
    });

    // "Überspringen" - nur sichtbar, wenn SMTP bereits konfiguriert ist.
    smtpSkipBtn.addEventListener("click", () => {
        smtpPassInput.value = "";
        closeModal();
    });

    // "E-Mail aendern"-Button im Footer: oeffnet das Modal erneut.
    const changeEmailBtn = document.getElementById("change-email-btn");
    if (changeEmailBtn) {
        changeEmailBtn.addEventListener("click", openModal);
    }

    /* ---------------------------------------------------------------------
       4) COUNTER-ANIMATIONEN (Karten zaehlen beim Laden hoch)
       --------------------------------------------------------------------- */
    function animateCounter(el) {
        const target = parseFloat(el.dataset.target);
        const suffix = el.dataset.suffix || "";
        const decimals = String(target).includes(".") ? 2 : 0;
        const duration = 1200;
        const start = performance.now();

        function step(now) {
            const t = Math.min(1, (now - start) / duration);
            // Ease-Out-Quad fuer ein angenehmes Verlangsamen am Ende.
            const eased = 1 - (1 - t) * (1 - t);
            const value = target * eased;
            const formatted = decimals === 2
                ? value.toLocaleString("de-CH", {
                      minimumFractionDigits: 2,
                      maximumFractionDigits: 2,
                  })
                : Math.round(value).toLocaleString("de-CH");
            el.textContent = formatted + suffix;
            if (t < 1) requestAnimationFrame(step);
        }
        requestAnimationFrame(step);
    }

    document.querySelectorAll("[data-counter]").forEach(animateCounter);

    /* ---------------------------------------------------------------------
       5) UHRZEIT IM HEADER
       --------------------------------------------------------------------- */
    const headerTime = document.getElementById("header-time");
    function tickClock() {
        const now = new Date();
        headerTime.textContent = now.toLocaleTimeString("de-CH", {
            hour:   "2-digit",
            minute: "2-digit",
            second: "2-digit",
        });
    }
    tickClock();
    setInterval(tickClock, 1000);

    /* ---------------------------------------------------------------------
       6) STATUS-INDIKATOR (alle 15s zwischen OK/ALARM wechseln zur Demo)
       --------------------------------------------------------------------- */
    const statusDot   = document.getElementById("status-dot");
    const statusLabel = document.getElementById("status-label");

    function setStatus(ok) {
        statusDot.classList.toggle("status-ok",    ok);
        statusDot.classList.toggle("status-alarm", !ok);
        statusLabel.textContent = ok ? "System OK" : "Alarm aktiv";
    }
    setStatus(true);
    // Demo-Wechsel: alle 30 Sekunden, damit beide Zustaende sichtbar sind.
    setInterval(() => setStatus(Math.random() > 0.25), 30_000);

    /* ---------------------------------------------------------------------
       7) HISTORIEN-DATEN (simuliert; entspricht spaeter history.csv)
       --------------------------------------------------------------------- */
    function generateHistory(days) {
        // Simuliert Datenpunkte: Random-Walk um einen Trend.
        const data = [];
        const labels = [];
        let value = 12000 + Math.random() * 2000;
        const now = new Date();
        for (let i = days - 1; i >= 0; i--) {
            const d = new Date(now);
            d.setDate(now.getDate() - i);
            // Random-Walk + leichter Aufwaertstrend.
            value += (Math.random() - 0.45) * 350;
            value = Math.max(8000, value);
            data.push(Number(value.toFixed(2)));
            labels.push(
                d.toLocaleDateString("de-CH", { day: "2-digit", month: "2-digit" })
            );
        }
        return { labels, data };
    }

    /* ---------------------------------------------------------------------
       8) CHART (Chart.js)
       --------------------------------------------------------------------- */
    let chart;

    function buildChart(range) {
        const { labels, data } = generateHistory(range);
        const ctx = document.getElementById("history-chart").getContext("2d");

        // Verlauf als sanfter Farbverlauf unterhalb der Linie.
        const gradient = ctx.createLinearGradient(0, 0, 0, 320);
        gradient.addColorStop(0, "rgba(79,140,255,0.45)");
        gradient.addColorStop(1, "rgba(79,140,255,0.00)");

        if (chart) chart.destroy();

        chart = new Chart(ctx, {
            type: "line",
            data: {
                labels,
                datasets: [{
                    label: "Depotwert (CHF)",
                    data,
                    borderColor: "#79b3ff",
                    backgroundColor: gradient,
                    borderWidth: 2,
                    pointRadius: 0,
                    pointHoverRadius: 6,
                    fill: true,
                    tension: 0.32,
                }],
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                interaction: { intersect: false, mode: "index" },
                plugins: {
                    legend: { display: false },
                    tooltip: {
                        backgroundColor: "#0b0f1a",
                        borderColor: "rgba(255,255,255,0.12)",
                        borderWidth: 1,
                        titleColor: "#f2f5fb",
                        bodyColor: "#cdd5e3",
                        padding: 12,
                        callbacks: {
                            label: (ctx) => ` ${formatCHF(ctx.parsed.y)} CHF`,
                        },
                    },
                },
                scales: {
                    x: {
                        grid: { color: "rgba(255,255,255,0.04)" },
                        ticks: { color: "#7e8aa3", maxRotation: 0 },
                    },
                    y: {
                        grid: { color: "rgba(255,255,255,0.04)" },
                        ticks: {
                            color: "#7e8aa3",
                            callback: (v) => formatCHF(v),
                        },
                    },
                },
            },
        });
    }

    // Chart wird erst initialisiert, wenn Chart.js geladen ist (defer).
    window.addEventListener("DOMContentLoaded", () => {
        if (typeof Chart === "undefined") {
            console.warn("Chart.js nicht verfuegbar - Diagramm wird uebersprungen.");
        } else {
            buildChart(7);
        }
        renderRunsTable();
        maybeOpenModal();
    });

    // Zeitraum-Chips umschalten (7T / 30T / 90T).
    document.querySelectorAll(".chip[data-range]").forEach((chip) => {
        chip.addEventListener("click", () => {
            document
                .querySelectorAll(".chip[data-range]")
                .forEach((c) => c.classList.remove("chip-active"));
            chip.classList.add("chip-active");
            buildChart(parseInt(chip.dataset.range, 10));
        });
    });

    /* ---------------------------------------------------------------------
       9) TABELLE "LETZTE LAEUFE"
       --------------------------------------------------------------------- */
    function renderRunsTable() {
        const body = document.getElementById("runs-body");
        const { labels, data } = generateHistory(8);

        // Tabellenzeilen in umgekehrter Reihenfolge (neueste oben).
        const rows = labels.map((lbl, i) => ({
            label: lbl,
            value: data[i],
            prev:  i > 0 ? data[i - 1] : data[i],
        })).reverse();

        body.innerHTML = rows.map((row) => {
            const change = ((row.value - row.prev) / row.prev) * 100;
            const isAlarm = row.value < 11000 || change < -3;
            const status = isAlarm ? "ALARM" : "OK";
            const badge  = isAlarm ? "badge-alarm" : "badge-ok";
            const arrow  = change >= 0 ? "▲" : "▼";
            const trendCls = change >= 0 ? "trend-up" : "trend-down";

            // Uhrzeit pseudo-zufaellig, aber stabil je Zeile (nur Demo).
            const hour = (9 + (rows.length - rows.indexOf(row))) % 24;
            const time = `${String(hour).padStart(2, "0")}:00:00`;

            return `
                <tr>
                    <td>${row.label}</td>
                    <td>${time}</td>
                    <td>${formatCHF(row.value)}</td>
                    <td class="${trendCls}">${arrow} ${change.toFixed(2)} %</td>
                    <td><span class="badge ${badge}">${status}</span></td>
                </tr>
            `;
        }).join("");
    }

    /* ---------------------------------------------------------------------
       10) NAECHSTER SCAN: FORTSCHRITTSBALKEN
       --------------------------------------------------------------------- */
    const progressFill = document.getElementById("scan-progress");
    const nextScanEta  = document.getElementById("next-scan-eta");

    const SCAN_INTERVAL_S = 300;       // 5 Minuten als Demo-Zyklus
    let   scanStart       = Date.now();

    function updateProgress() {
        const elapsed = (Date.now() - scanStart) / 1000;
        const ratio   = Math.min(1, elapsed / SCAN_INTERVAL_S);
        progressFill.style.width = (ratio * 100).toFixed(2) + "%";

        const remaining = Math.max(0, SCAN_INTERVAL_S - elapsed);
        const m = Math.floor(remaining / 60);
        const s = Math.floor(remaining % 60);
        nextScanEta.textContent =
            `in ${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;

        if (ratio >= 1) scanStart = Date.now();   // Reset
    }
    updateProgress();
    setInterval(updateProgress, 1000);

    /* ---------------------------------------------------------------------
       11) "SCAN JETZT AUSLOESEN"-BUTTON
       --------------------------------------------------------------------- */
    const scanBtn = document.getElementById("scan-now-btn");

    scanBtn.addEventListener("click", async () => {
        scanBtn.disabled = true;
        const icon = scanBtn.querySelector(".btn-icon");
        icon.classList.add("spin");
        const original = scanBtn.lastChild.textContent;
        scanBtn.lastChild.textContent = " Scan läuft ...";

        // Simulation: 2.4 Sekunden "scannen", dann Erfolg.
        await sleep(2400);

        // Tabelle neu rendern (frische Random-Daten als sichtbares Feedback).
        renderRunsTable();
        if (chart) {
            const active = document.querySelector(".chip-active");
            buildChart(parseInt(active.dataset.range, 10));
        }
        // Fortschritt zuruecksetzen.
        scanStart = Date.now();

        icon.classList.remove("spin");
        scanBtn.lastChild.textContent = original;
        scanBtn.disabled = false;

        showToast("Scan abgeschlossen - Daten aktualisiert.", "success");
    });

    /* ---------------------------------------------------------------------
       12) DEMO-BUTTON: TEST-MAIL VERSAND
       TODO: DEMO BUTTON — vor Abgabe entfernen
       --------------------------------------------------------------------- */
    const demoEmailBtn = document.getElementById("demo-email-btn");
    const demoBtnIcon  = document.getElementById("demo-btn-icon");
    const demoBtnLabel = document.getElementById("demo-btn-label");

    if (demoEmailBtn) {
        demoEmailBtn.addEventListener("click", async () => {
            const saved = localStorage.getItem(STORAGE_KEY);

            // Keine Adresse hinterlegt -> Modal oeffnen, statt zu senden.
            if (!saved) {
                showToast("Bitte zuerst eine E-Mail-Adresse hinterlegen.", "error");
                openModal();
                return;
            }

            // Lade-Animation: Icon dreht sich, Label aendert sich.
            demoEmailBtn.disabled = true;
            demoBtnIcon.textContent = "⏳";
            demoBtnIcon.classList.add("spin");
            demoBtnLabel.textContent = "Sende Test-Mail ...";

            try {
                const res = await fetch("/send_test_email", {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ email: saved }),
                });

                const ct = res.headers.get("content-type") || "";
                const data = ct.includes("application/json")
                    ? await res.json()
                    : { success: false, error: `HTTP ${res.status}` };

                if (!res.ok || !data.success) {
                    throw new Error(data.error || `HTTP ${res.status}`);
                }

                showToast("Test-Mail gesendet! Prüfe dein Postfach.", "success");
            } catch (err) {
                console.error("Demo-Mail-Versand fehlgeschlagen:", err);
                showToast("Fehler beim Senden: " + (err.message || err), "error");
            } finally {
                demoEmailBtn.disabled = false;
                demoBtnIcon.classList.remove("spin");
                demoBtnIcon.textContent = "🧪";
                demoBtnLabel.textContent = "Demo: Test-Mail senden";
            }
        });
    }
})();
