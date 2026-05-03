/* =========================================================================
   DepotTracker - script.js
   --------------------------------------------------------------------------
   Steuert das Dashboard: Modal, Counter-Animationen, Status-Indikator,
   Chart, Tabelle "Letzte Laeufe", Fortschrittsbalken, Scan-Button,
   Modus-Badges (LIVE/SIMULATION/READ-ONLY), Waehrungs-Umschalter
   (Feature 3) und Read-Only-Sperrung.
   Saemtliche Texte und Kommentare in Schweizer Schreibweise (ss, kein Eszett).
   ========================================================================= */

(() => {
    "use strict";

    /* ---------------------------------------------------------------------
       1) UTILS
       --------------------------------------------------------------------- */
    const isValidEmail = (value) =>
        /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(String(value).trim());

    const formatNumber = (value, decimals = 2) =>
        Number(value).toLocaleString("de-CH", {
            minimumFractionDigits: decimals,
            maximumFractionDigits: decimals,
        });

    const formatCHF = (value) => formatNumber(value, 2);

    const sleep = (ms) => new Promise((res) => setTimeout(res, ms));

    /* ---------------------------------------------------------------------
       2) GLOBALER STATE
       --------------------------------------------------------------------- */
    let currentCurrency = "CHF";
    let fxRates = {};           // z.B. { CHF: 0.78, EUR: 0.85, GBP: 0.74 }
    let currentMode = null;     // "live" | "simulation" | "readonly"

    /* ---------------------------------------------------------------------
       3) TOAST-NOTIFICATIONS
       --------------------------------------------------------------------- */
    const toastContainer = document.getElementById("toast-container");

    function showToast(message, type = "success", duration = 3500) {
        const toast = document.createElement("div");
        toast.className = `toast toast-${type}`;
        toast.textContent = message;
        toastContainer.appendChild(toast);
        requestAnimationFrame(() => toast.classList.add("show"));
        setTimeout(() => {
            toast.classList.remove("show");
            setTimeout(() => toast.remove(), 320);
        }, duration);
    }

    /* ---------------------------------------------------------------------
       4) MODAL: EMPFAENGER-MAIL HINTERLEGEN
       --------------------------------------------------------------------- */
    const modal       = document.getElementById("email-modal");
    const emailForm   = document.getElementById("email-form");
    const emailInput  = document.getElementById("email-input");
    const emailError  = document.getElementById("email-error");
    const emailSubmit = document.getElementById("email-submit");

    const STORAGE_KEY = "depottracker.email";

    function openModal(prefill) {
        const saved = prefill || localStorage.getItem(STORAGE_KEY) || "";
        if (saved) emailInput.value = saved;
        emailError.hidden = true;
        modal.classList.add("is-open");
        modal.setAttribute("aria-hidden", "false");
        setTimeout(() => emailInput.focus(), 220);
    }

    function closeModal() {
        modal.classList.remove("is-open");
        modal.setAttribute("aria-hidden", "true");
    }

    async function maybeOpenModal() {
        try {
            const res = await fetch("/api/recipient", { cache: "no-store" });
            if (res.ok) {
                const data = await res.json();
                if (data && data.email) {
                    localStorage.setItem(STORAGE_KEY, data.email);
                    return;
                }
            }
        } catch (err) {
            console.warn("/api/recipient nicht erreichbar:", err);
        }
        if (!localStorage.getItem(STORAGE_KEY)) {
            openModal();
        }
    }

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
            closeModal();
            showToast("Empfaenger gespeichert.", "success");
        } catch (err) {
            console.warn("/save_email nicht erreichbar:", err);
            localStorage.setItem(STORAGE_KEY, value);
            closeModal();
            showToast("Empfaenger lokal gespeichert (Server offline).", "error");
        } finally {
            emailSubmit.disabled = false;
            emailSubmit.textContent = "Speichern";
        }
    });

    const changeEmailBtn = document.getElementById("change-email-btn");
    if (changeEmailBtn) {
        changeEmailBtn.addEventListener("click", () => openModal());
    }

    /* ---------------------------------------------------------------------
       5) MODUS-BADGE (Feature 1): LIVE / SIMULATION
          + GPG-Indikator (Feature 2)
       --------------------------------------------------------------------- */
    const modeBadge = document.getElementById("mode-badge");
    const modeLabel = document.getElementById("mode-label");
    const encBadge  = document.getElementById("enc-badge");
    const demoEmailSection = document.getElementById("demo-email-section");
    const VALID_MODES = ["live", "simulation"];
    const MODE_LABELS = { "live": "LIVE", "simulation": "SIMULATION" };

    async function refreshMode() {
        try {
            const res = await fetch("/api/mode", { cache: "no-store" });
            if (!res.ok) return;
            const data = await res.json();
            const raw = (data && data.mode) || "live";
            const mode = VALID_MODES.includes(raw) ? raw : "live";

            if (mode !== currentMode) {
                modeBadge.classList.remove("mode-live", "mode-simulation");
                modeBadge.classList.add("mode-" + mode);
                modeLabel.textContent = MODE_LABELS[mode];

                // Test-Mail-Button nur in SIMULATION sichtbar
                if (demoEmailSection) {
                    demoEmailSection.hidden = (mode !== "simulation");
                }

                if (currentMode !== null) {
                    showToast("Modus gewechselt: " + MODE_LABELS[mode], "success");
                }
                currentMode = mode;
            }

            if (encBadge) {
                encBadge.hidden = !data.credentials_encrypted;
            }
        } catch (err) {
            // Stille Toleranz
        }
    }

    /* ---------------------------------------------------------------------
       6) WAEHRUNGS-UMSCHALTER (Feature 3: Multi-Currency)
          Liest /api/fx und rechnet alle CHF-Werte dynamisch um.
          Basis-Waehrung der FX-API ist USD. rates.CHF = "wieviel CHF
          kostet 1 USD". Umrechnung: targetValue = chfValue / rates.CHF * rates.TARGET
       --------------------------------------------------------------------- */

    function convertFromCHF(chfValue, targetCurrency) {
        if (targetCurrency === "CHF") return chfValue;
        const chfPerUsd = fxRates.CHF;
        const targetPerUsd = fxRates[targetCurrency];
        if (!chfPerUsd || chfPerUsd <= 0 || !targetPerUsd) return null;
        return (chfValue / chfPerUsd) * targetPerUsd;
    }

    function updateAllValues() {
        // Aktualisiere alle Karten-Werte mit der gewaehlten Waehrung
        document.querySelectorAll("[data-base-chf]").forEach((el) => {
            const baseCHF = parseFloat(el.dataset.baseChf);
            if (!Number.isFinite(baseCHF)) return;
            const converted = convertFromCHF(baseCHF, currentCurrency);
            if (converted === null) return;
            el.textContent = formatNumber(converted) + " " + currentCurrency;
            el.dataset.target = converted.toFixed(2);
            el.dataset.suffix = " " + currentCurrency;
        });

        // Tabellen-Header aktualisieren
        const tableCurrencyEl = document.getElementById("table-currency");
        if (tableCurrencyEl) tableCurrencyEl.textContent = currentCurrency;
    }

    async function refreshFx() {
        try {
            const res = await fetch("/api/fx", { cache: "no-store" });
            if (!res.ok) return;
            const data = await res.json();
            if (data && data.rates) {
                fxRates = data.rates;
                // USD ist die Basiswaehrung der API (= 1.0) und fehlt
                // deshalb im rates-Objekt. Explizit setzen.
                fxRates.USD = 1;
                if (!fxRates.CHF) fxRates.CHF = 1;
                updateAllValues();
            }
        } catch (err) {
            // Stille Toleranz - FX ist eine Zusatzanzeige
        }
    }

    // Currency-Chips Event-Listener
    document.querySelectorAll(".chip[data-currency]").forEach((chip) => {
        chip.addEventListener("click", () => {
            document.querySelectorAll(".chip[data-currency]")
                .forEach((c) => c.classList.remove("chip-active"));
            chip.classList.add("chip-active");
            currentCurrency = chip.dataset.currency;
            updateAllValues();
            // Tabelle und Chart mit neuer Waehrung neu rendern
            renderRunsTable();
            if (chart) {
                const active = document.querySelector(".chip[data-range].chip-active");
                if (active) buildChart(parseInt(active.dataset.range, 10));
            }
        });
    });

    /* ---------------------------------------------------------------------
       7) COUNTER-ANIMATIONEN
       --------------------------------------------------------------------- */
    function animateCounter(el) {
        const target = parseFloat(el.dataset.target);
        const suffix = el.dataset.suffix || "";
        const decimals = String(target).includes(".") ? 2 : 0;
        const duration = 1200;
        const start = performance.now();

        function step(now) {
            const t = Math.min(1, (now - start) / duration);
            const eased = 1 - (1 - t) * (1 - t);
            const value = target * eased;
            const formatted = decimals === 2
                ? formatNumber(value)
                : Math.round(value).toLocaleString("de-CH");
            el.textContent = formatted + suffix;
            if (t < 1) requestAnimationFrame(step);
        }
        requestAnimationFrame(step);
    }

    document.querySelectorAll("[data-counter]").forEach(animateCounter);

    /* ---------------------------------------------------------------------
       8) UHRZEIT IM HEADER
       --------------------------------------------------------------------- */
    const headerTime = document.getElementById("header-time");
    function tickClock() {
        const now = new Date();
        headerTime.textContent = now.toLocaleTimeString("de-CH", {
            hour: "2-digit", minute: "2-digit", second: "2-digit",
        });
    }
    tickClock();
    setInterval(tickClock, 1000);

    /* ---------------------------------------------------------------------
       9) STATUS-INDIKATOR
       --------------------------------------------------------------------- */
    const statusDot   = document.getElementById("status-dot");
    const statusLabel = document.getElementById("status-label");

    function setStatus(ok) {
        statusDot.classList.toggle("status-ok", ok);
        statusDot.classList.toggle("status-alarm", !ok);
        statusLabel.textContent = ok ? "System OK" : "Alarm aktiv";
    }
    setStatus(true);
    setInterval(() => setStatus(Math.random() > 0.25), 30_000);

    /* ---------------------------------------------------------------------
       10) HISTORIEN-DATEN (simuliert)
       --------------------------------------------------------------------- */
    function generateHistory(days) {
        const data = [];
        const labels = [];
        let value = 12000 + Math.random() * 2000;
        const now = new Date();
        for (let i = days - 1; i >= 0; i--) {
            const d = new Date(now);
            d.setDate(now.getDate() - i);
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
       11) CHART (Chart.js)
       --------------------------------------------------------------------- */
    let chart;

    function buildChart(range) {
        const { labels, data: rawData } = generateHistory(range);
        // Daten in aktive Waehrung umrechnen
        const data = rawData.map((v) => {
            const c = convertFromCHF(v, currentCurrency);
            return c !== null ? Number(c.toFixed(2)) : v;
        });

        const ctx = document.getElementById("history-chart").getContext("2d");
        const gradient = ctx.createLinearGradient(0, 0, 0, 320);
        gradient.addColorStop(0, "rgba(79,140,255,0.45)");
        gradient.addColorStop(1, "rgba(79,140,255,0.00)");

        if (chart) chart.destroy();

        chart = new Chart(ctx, {
            type: "line",
            data: {
                labels,
                datasets: [{
                    label: "Depotwert (" + currentCurrency + ")",
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
                            label: (ctx) => ` ${formatNumber(ctx.parsed.y)} ${currentCurrency}`,
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
                            callback: (v) => formatNumber(v),
                        },
                    },
                },
            },
        });
    }

    window.addEventListener("DOMContentLoaded", () => {
        if (typeof Chart === "undefined") {
            console.warn("Chart.js nicht verfuegbar - Diagramm wird uebersprungen.");
        } else {
            buildChart(7);
        }
        renderRunsTable();
        maybeOpenModal();
        refreshMode();
        refreshFx();
        setInterval(refreshMode, 5_000);
        setInterval(refreshFx, 300_000);
    });

    // Zeitraum-Chips
    document.querySelectorAll(".chip[data-range]").forEach((chip) => {
        chip.addEventListener("click", () => {
            document.querySelectorAll(".chip[data-range]")
                .forEach((c) => c.classList.remove("chip-active"));
            chip.classList.add("chip-active");
            buildChart(parseInt(chip.dataset.range, 10));
        });
    });

    /* ---------------------------------------------------------------------
       12) TABELLE "LETZTE LAEUFE"
       --------------------------------------------------------------------- */
    function renderRunsTable() {
        const body = document.getElementById("runs-body");
        const { labels, data } = generateHistory(8);

        const rows = labels.map((lbl, i) => ({
            label: lbl,
            value: data[i],
            prev: i > 0 ? data[i - 1] : data[i],
        })).reverse();

        body.innerHTML = rows.map((row) => {
            // Werte in aktive Waehrung umrechnen
            const val = convertFromCHF(row.value, currentCurrency) || row.value;
            const prev = convertFromCHF(row.prev, currentCurrency) || row.prev;
            const change = ((val - prev) / prev) * 100;
            const isAlarm = row.value < 11000 || change < -3;
            const status = isAlarm ? "ALARM" : "OK";
            const badge = isAlarm ? "badge-alarm" : "badge-ok";
            const arrow = change >= 0 ? "\u25B2" : "\u25BC";
            const trendCls = change >= 0 ? "trend-up" : "trend-down";
            const hour = (9 + (rows.length - rows.indexOf(row))) % 24;
            const time = `${String(hour).padStart(2, "0")}:00:00`;

            return `
                <tr>
                    <td>${row.label}</td>
                    <td>${time}</td>
                    <td>${formatNumber(val)}</td>
                    <td class="${trendCls}">${arrow} ${change.toFixed(2)} %</td>
                    <td><span class="badge ${badge}">${status}</span></td>
                </tr>
            `;
        }).join("");
    }

    /* ---------------------------------------------------------------------
       13) NAECHSTER SCAN: FORTSCHRITTSBALKEN
       --------------------------------------------------------------------- */
    const progressFill = document.getElementById("scan-progress");
    const nextScanEta  = document.getElementById("next-scan-eta");
    const SCAN_INTERVAL_S = 300;
    let scanStart = Date.now();

    function updateProgress() {
        const elapsed = (Date.now() - scanStart) / 1000;
        const ratio = Math.min(1, elapsed / SCAN_INTERVAL_S);
        progressFill.style.width = (ratio * 100).toFixed(2) + "%";
        const remaining = Math.max(0, SCAN_INTERVAL_S - elapsed);
        const m = Math.floor(remaining / 60);
        const s = Math.floor(remaining % 60);
        nextScanEta.textContent =
            `in ${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
        if (ratio >= 1) scanStart = Date.now();
    }
    updateProgress();
    setInterval(updateProgress, 1000);

    /* ---------------------------------------------------------------------
       14) "SCAN JETZT AUSLOESEN"-BUTTON
       --------------------------------------------------------------------- */
    const scanBtn = document.getElementById("scan-now-btn");

    scanBtn.addEventListener("click", async () => {
        scanBtn.disabled = true;
        const icon = scanBtn.querySelector(".btn-icon");
        icon.classList.add("spin");
        const original = scanBtn.lastChild.textContent;
        scanBtn.lastChild.textContent = " Scan laeuft ...";

        await sleep(2400);
        renderRunsTable();
        if (chart) {
            const active = document.querySelector(".chip[data-range].chip-active");
            if (active) buildChart(parseInt(active.dataset.range, 10));
        }
        scanStart = Date.now();
        icon.classList.remove("spin");
        scanBtn.lastChild.textContent = original;
        scanBtn.disabled = false;
        showToast("Scan abgeschlossen - Daten aktualisiert.", "success");
    });

    /* ---------------------------------------------------------------------
       15) TEST-MAIL-BUTTON
       --------------------------------------------------------------------- */
    const demoEmailBtn = document.getElementById("demo-email-btn");
    const demoBtnIcon  = document.getElementById("demo-btn-icon");
    const demoBtnLabel = document.getElementById("demo-btn-label");

    if (demoEmailBtn) {
        demoEmailBtn.addEventListener("click", async () => {
            const saved = localStorage.getItem(STORAGE_KEY);
            if (!saved) {
                showToast("Bitte zuerst eine E-Mail-Adresse hinterlegen.", "error");
                openModal();
                return;
            }

            demoEmailBtn.disabled = true;
            demoBtnIcon.textContent = "\u23F3";
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
                showToast("Test-Mail gesendet! Pruefe dein Postfach.", "success");
            } catch (err) {
                console.error("Test-Mail-Versand fehlgeschlagen:", err);
                showToast("Fehler beim Senden: " + (err.message || err), "error");
            } finally {
                demoEmailBtn.disabled = false;
                demoBtnIcon.classList.remove("spin");
                demoBtnIcon.textContent = "\uD83E\uDDEA";
                demoBtnLabel.textContent = "Test-Mail senden";
            }
        });
    }

    /* ---------------------------------------------------------------------
       16) SIMULATIONS-TRADING (Feature 1)
           Live-Kurse alle 3 Sekunden aktualisieren, Kaufen/Verkaufen,
           Portfolio-Wert berechnen, Trade-Historie anzeigen.
       --------------------------------------------------------------------- */
    const simPanel     = document.getElementById("sim-panel");
    const simPriceBtc  = document.getElementById("sim-price-btc");
    const simPriceEth  = document.getElementById("sim-price-eth");
    const simChangeBtc = document.getElementById("sim-change-btc");
    const simChangeEth = document.getElementById("sim-change-eth");
    const simBalance   = document.getElementById("sim-balance");
    const simPortfolio = document.getElementById("sim-portfolio");
    const simHoldBtc   = document.getElementById("sim-hold-btc");
    const simHoldEth   = document.getElementById("sim-hold-eth");
    const simAmount    = document.getElementById("sim-amount");
    const simTradesBody = document.getElementById("sim-trades-body");

    let lastSimPrices = {};
    let simInterval = null;

    function showSimPanel(show) {
        if (simPanel) simPanel.hidden = !show;
    }

    async function refreshSimPrices() {
        try {
            const res = await fetch("/api/sim/prices", { cache: "no-store" });
            if (!res.ok) return;
            const data = await res.json();

            // Kurse anzeigen
            if (data.prices) {
                const btcPrice = data.prices.bitcoin || 0;
                const ethPrice = data.prices.ethereum || 0;

                // Aenderungen berechnen
                if (lastSimPrices.bitcoin) {
                    const btcDelta = ((btcPrice - lastSimPrices.bitcoin) / lastSimPrices.bitcoin * 100);
                    simChangeBtc.textContent = (btcDelta >= 0 ? "\u25B2 +" : "\u25BC ") + btcDelta.toFixed(2) + " %";
                    simChangeBtc.style.color = btcDelta >= 0 ? "var(--success)" : "var(--danger)";
                }
                if (lastSimPrices.ethereum) {
                    const ethDelta = ((ethPrice - lastSimPrices.ethereum) / lastSimPrices.ethereum * 100);
                    simChangeEth.textContent = (ethDelta >= 0 ? "\u25B2 +" : "\u25BC ") + ethDelta.toFixed(2) + " %";
                    simChangeEth.style.color = ethDelta >= 0 ? "var(--success)" : "var(--danger)";
                }

                simPriceBtc.textContent = formatNumber(btcPrice) + " CHF";
                simPriceEth.textContent = formatNumber(ethPrice) + " CHF";
                lastSimPrices = data.prices;
            }

            // Portfolio-Uebersicht
            simBalance.textContent = formatNumber(data.balance_chf || 0) + " CHF";
            simPortfolio.textContent = formatNumber(data.portfolio_value || 0) + " CHF";

            // P/L Farbe
            const pv = data.portfolio_value || 0;
            simPortfolio.style.color = pv >= 100 ? "var(--success)" : "var(--danger)";

            // Holdings
            const btcHold = data.holdings?.bitcoin?.amount || 0;
            const ethHold = data.holdings?.ethereum?.amount || 0;
            simHoldBtc.textContent = btcHold > 0 ? btcHold.toFixed(6) + " BTC" : "0";
            simHoldEth.textContent = ethHold > 0 ? ethHold.toFixed(6) + " ETH" : "0";

        } catch (err) {
            // Stille Toleranz
        }
    }

    async function executeTrade(action, coin) {
        const amountStr = simAmount?.value || "10";
        const amount = parseFloat(amountStr);
        if (!Number.isFinite(amount) || amount <= 0) {
            showToast("Bitte einen gueltigen Betrag eingeben.", "error");
            return;
        }

        // Buttons waehrend Trade deaktivieren
        document.querySelectorAll(".btn-sim-buy, .btn-sim-sell")
            .forEach(b => b.disabled = true);

        try {
            const res = await fetch("/api/paper/trade", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ action, coin, amount_chf: amount }),
            });
            const data = await res.json();
            if (!res.ok || !data.success) {
                throw new Error(data.error || "Trade fehlgeschlagen");
            }
            showToast(data.message, "success");
            // Sofort aktualisieren
            await refreshSimPrices();
            renderTradeHistory(data.depot?.trades || []);
        } catch (err) {
            showToast(err.message || "Trade-Fehler", "error");
        } finally {
            document.querySelectorAll(".btn-sim-buy, .btn-sim-sell")
                .forEach(b => b.disabled = false);
        }
    }

    function renderTradeHistory(trades) {
        if (!simTradesBody) return;
        const rows = [...trades].reverse().slice(0, 20);
        simTradesBody.innerHTML = rows.map(t => {
            const time = new Date(t.timestamp).toLocaleTimeString("de-CH", {
                hour: "2-digit", minute: "2-digit", second: "2-digit"
            });
            const label = t.coin === "bitcoin" ? "BTC" : "ETH";
            const actionBadge = t.action === "buy"
                ? '<span class="badge badge-ok">KAUF</span>'
                : '<span class="badge badge-alarm">VERKAUF</span>';
            return `<tr>
                <td>${time}</td>
                <td>${actionBadge}</td>
                <td>${label}</td>
                <td>${t.coin_amount?.toFixed(6) || "—"}</td>
                <td>${formatNumber(t.price_chf)}</td>
                <td>${formatNumber(t.total_chf)}</td>
            </tr>`;
        }).join("");
    }

    // Trade-Buttons Event-Listener
    ["sim-buy-btc", "sim-sell-btc", "sim-buy-eth", "sim-sell-eth"].forEach(id => {
        const btn = document.getElementById(id);
        if (!btn) return;
        const [, action, coin] = id.split("-");
        const coinMap = { btc: "bitcoin", eth: "ethereum" };
        btn.addEventListener("click", () => executeTrade(action, coinMap[coin]));
    });

    // Simulation starten/stoppen bei Modus-Wechsel
    function startSimulation() {
        showSimPanel(true);
        refreshSimPrices();
        // Bestehende Trade-Historie laden
        fetch("/api/paper", { cache: "no-store" })
            .then(r => r.ok ? r.json() : null)
            .then(d => { if (d?.trades) renderTradeHistory(d.trades); })
            .catch(() => {});
        if (!simInterval) {
            simInterval = setInterval(refreshSimPrices, 3000);
        }
    }

    function stopSimulation() {
        showSimPanel(false);
        if (simInterval) {
            clearInterval(simInterval);
            simInterval = null;
        }
    }

    // Mode-Watcher: Simulation starten wenn Modus wechselt
    const _origRefreshMode = refreshMode;
    refreshMode = async function() {
        await _origRefreshMode();
        if (currentMode === "simulation") {
            startSimulation();
        } else {
            stopSimulation();
        }
    };
})();
