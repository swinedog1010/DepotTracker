import { useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';

export default function EmailModal() {
  const [open, setOpen] = useState(true);
  const [email, setEmail] = useState('');
  const [status, setStatus] = useState('idle'); // idle | saving | success | error
  const [errorMsg, setErrorMsg] = useState('');

  const handleSave = async (e) => {
    e.preventDefault();
    if (!email) return;

    setStatus('saving');
    setErrorMsg('');

    try {
      const res = await fetch('http://localhost:3001/api/save-email', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email }),
      });

      const data = await res.json();

      if (!res.ok || !data.success) {
        throw new Error(data.error || 'Unbekannter Fehler');
      }

      setStatus('success');
      setTimeout(() => setOpen(false), 1500);
    } catch (err) {
      setStatus('error');
      setErrorMsg(err.message || 'Verbindung zum Server fehlgeschlagen.');
    }
  };

  return (
    <AnimatePresence>
      {open && (
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={{ duration: 0.25 }}
          className="fixed inset-0 z-[60] flex items-center justify-center p-4"
        >
          {/* Backdrop */}
          <div
            className="absolute inset-0 bg-black/60 backdrop-blur-sm"
            onClick={() => status !== 'saving' && setOpen(false)}
          />

          {/* Modal Card */}
          <motion.div
            initial={{ opacity: 0, scale: 0.92, y: 20 }}
            animate={{ opacity: 1, scale: 1, y: 0 }}
            exit={{ opacity: 0, scale: 0.92, y: 20 }}
            transition={{ type: 'spring', stiffness: 300, damping: 25 }}
            className="relative w-full max-w-md glass-card p-8 shadow-2xl"
          >
            {/* Close Button */}
            <button
              onClick={() => setOpen(false)}
              disabled={status === 'saving'}
              className="absolute top-4 right-4 w-8 h-8 flex items-center justify-center rounded-lg
                text-text-dim hover:text-white hover:bg-white/[0.06] transition-colors
                disabled:opacity-30 disabled:cursor-not-allowed"
              aria-label="Schliessen"
            >
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="w-4 h-4">
                <path d="M18 6L6 18M6 6l12 12" />
              </svg>
            </button>

            {/* Success State */}
            {status === 'success' ? (
              <motion.div
                initial={{ opacity: 0, scale: 0.8 }}
                animate={{ opacity: 1, scale: 1 }}
                className="flex flex-col items-center py-6"
              >
                <div className="w-16 h-16 rounded-full bg-gain-dim flex items-center justify-center mb-4">
                  <motion.svg
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="2.5"
                    className="w-8 h-8 text-gain"
                    initial={{ pathLength: 0 }}
                    animate={{ pathLength: 1 }}
                    transition={{ duration: 0.4, delay: 0.1 }}
                  >
                    <motion.path
                      d="M20 6L9 17l-5-5"
                      initial={{ pathLength: 0 }}
                      animate={{ pathLength: 1 }}
                      transition={{ duration: 0.4, delay: 0.1 }}
                    />
                  </motion.svg>
                </div>
                <h3 className="text-lg font-bold text-white mb-1">Gespeichert!</h3>
                <p className="text-sm text-text-dim text-center">
                  E-Mail wurde erfolgreich in config.sh aktualisiert.
                </p>
              </motion.div>
            ) : (
              /* Form State */
              <>
                {/* Header */}
                <div className="flex items-center gap-3 mb-6">
                  <div className="w-10 h-10 rounded-xl bg-accent-dim flex items-center justify-center flex-shrink-0">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" className="w-5 h-5 text-accent">
                      <rect x="2" y="4" width="20" height="16" rx="2" />
                      <path d="M22 4l-10 8L2 4" />
                    </svg>
                  </div>
                  <div>
                    <h2 className="text-lg font-bold text-white">E-Mail konfigurieren</h2>
                    <p className="text-xs text-text-dim">Alarm-Benachrichtigungen werden an diese Adresse gesendet.</p>
                  </div>
                </div>

                {/* Form */}
                <form onSubmit={handleSave}>
                  <label htmlFor="email-input" className="block text-xs font-medium text-text-dim uppercase tracking-wider mb-2">
                    Empfänger E-Mail
                  </label>
                  <input
                    id="email-input"
                    type="email"
                    required
                    placeholder="name@beispiel.ch"
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    disabled={status === 'saving'}
                    className="w-full h-12 px-4 rounded-xl bg-white/[0.04] border border-glass-border
                      text-white text-sm placeholder-text-muted
                      focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/25
                      disabled:opacity-50 disabled:cursor-not-allowed
                      transition-all duration-200"
                    autoFocus
                  />

                  {/* Error Message */}
                  {status === 'error' && (
                    <motion.p
                      initial={{ opacity: 0, y: -5 }}
                      animate={{ opacity: 1, y: 0 }}
                      className="mt-2 text-xs text-loss flex items-center gap-1.5"
                    >
                      <svg viewBox="0 0 16 16" fill="currentColor" className="w-3.5 h-3.5 flex-shrink-0">
                        <path d="M8 1a7 7 0 100 14A7 7 0 008 1zm-.75 4a.75.75 0 011.5 0v3a.75.75 0 01-1.5 0V5zM8 11a1 1 0 100-2 1 1 0 000 2z" />
                      </svg>
                      {errorMsg}
                    </motion.p>
                  )}

                  {/* Actions */}
                  <div className="flex gap-3 mt-6">
                    <button
                      type="button"
                      onClick={() => setOpen(false)}
                      disabled={status === 'saving'}
                      className="flex-1 h-11 rounded-xl text-sm font-medium text-text-dim
                        bg-white/[0.04] border border-glass-border
                        hover:bg-white/[0.07] hover:text-white
                        disabled:opacity-30 disabled:cursor-not-allowed
                        transition-all duration-200"
                    >
                      Abbrechen
                    </button>
                    <button
                      type="submit"
                      disabled={status === 'saving' || !email}
                      className="flex-1 h-11 rounded-xl text-sm font-semibold
                        bg-gradient-to-r from-accent to-gain text-bg
                        hover:shadow-[0_0_24px_rgba(99,102,241,0.3)]
                        disabled:opacity-40 disabled:cursor-not-allowed disabled:hover:shadow-none
                        transition-all duration-200
                        flex items-center justify-center gap-2"
                    >
                      {status === 'saving' ? (
                        <>
                          <div className="w-4 h-4 border-2 border-bg/30 border-t-bg rounded-full animate-spin" />
                          Speichern...
                        </>
                      ) : (
                        'Speichern'
                      )}
                    </button>
                  </div>
                </form>

                {/* Hint */}
                <p className="mt-4 text-[11px] text-text-muted text-center">
                  Wird in <span className="font-mono text-text-dim">scripts/config.sh</span> als <span className="font-mono text-text-dim">EMAIL_RECIPIENT</span> gespeichert.
                </p>
              </>
            )}
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>
  );
}
