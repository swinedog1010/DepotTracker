import { motion } from 'framer-motion';

function formatCHF(value) {
  return value.toLocaleString('de-CH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function formatTimestamp(ts) {
  if (!ts) return '—';
  const d = new Date(ts);
  return d.toLocaleString('de-CH', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

export default function AlertCard({ data, isAlarm }) {
  if (!data) return null;
  const alarm = data.alarm;

  return (
    <motion.div
      initial={{ opacity: 0, y: 30 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.5, delay: 0.3 }}
      whileHover={{ y: -6 }}
      className={`glass-card p-7 relative overflow-hidden cursor-default transition-all duration-500
        md:col-span-2 lg:col-span-1
        hover:shadow-[0_20px_60px_rgba(0,0,0,0.35)]
        ${isAlarm
          ? 'border-loss/25 bg-gradient-to-br from-loss/[0.06] to-transparent hover:border-loss/40'
          : 'hover:border-white/[0.12]'
        }`}
    >
      {/* Pulse Overlay (alarm only) */}
      {isAlarm && (
        <div className="absolute inset-0 rounded-2xl animate-alarm-pulse pointer-events-none" />
      )}

      {/* Badge */}
      {isAlarm && (
        <motion.span
          initial={{ scale: 0 }}
          animate={{ scale: 1 }}
          transition={{ type: 'spring', stiffness: 300, damping: 15 }}
          className="absolute top-5 right-5 text-[10px] font-bold tracking-wider bg-loss text-white px-3 py-1 rounded-md"
        >
          AUSGELÖST
        </motion.span>
      )}

      {/* Icon */}
      <div className={`w-12 h-12 flex items-center justify-center rounded-xl mb-5
        ${isAlarm ? 'bg-loss-dim text-loss' : 'bg-glass-bg text-text-dim'}`}>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="w-6 h-6">
          <rect x="3" y="3" width="7" height="7" /><rect x="14" y="3" width="7" height="7" />
          <rect x="3" y="14" width="7" height="7" /><rect x="14" y="14" width="4" height="4" />
          <path d="M21 14h-3v7h7v-3h-4z" />
        </svg>
      </div>

      <p className="text-xs font-medium text-text-dim uppercase tracking-wider mb-2">Schweizer QR-Rechnung</p>

      {isAlarm ? (
        <>
          <h3 className="text-3xl font-extrabold text-loss tracking-tight mb-4">
            CHF {formatCHF(alarm.lossAmount)}
          </h3>

          {/* Details Grid */}
          <div className="flex flex-col gap-2.5 p-4 bg-white/[0.02] rounded-xl border border-glass-border mb-4">
            <div className="flex justify-between items-center">
              <span className="text-xs text-text-dim">Status</span>
              <span className="text-xs font-semibold text-gain">Generiert & gesendet</span>
            </div>
            <div className="flex justify-between items-center">
              <span className="text-xs text-text-dim">Kanal</span>
              <span className="text-xs font-semibold flex items-center gap-1.5">
                <svg viewBox="0 0 24 24" fill="currentColor" className="w-3.5 h-3.5 text-[#29b6f6]">
                  <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm4.64 6.8l-1.6 7.53c-.12.54-.44.67-.89.42l-2.45-1.8-1.18 1.14c-.13.13-.24.24-.5.24l.18-2.48 4.56-4.12c.2-.18-.04-.27-.3-.1L8.3 13.38l-2.38-.74c-.52-.16-.53-.52.1-.77l9.3-3.59c.43-.16.82.1.67.77z" />
                </svg>
                Telegram
              </span>
            </div>
            <div className="flex justify-between items-center">
              <span className="text-xs text-text-dim">Zeitstempel</span>
              <span className="text-xs font-semibold">{formatTimestamp(alarm.timestamp)}</span>
            </div>
          </div>

          {/* QR Preview */}
          <div className="flex items-center gap-4 p-4 bg-white/[0.03] rounded-xl border border-dashed border-loss/25">
            <div className="w-16 h-16 bg-white rounded-lg p-1.5 flex-shrink-0 relative">
              <div className="grid grid-cols-7 gap-[2px] w-full h-full">
                {Array.from({ length: 49 }).map((_, i) => (
                  <span key={i} className={`rounded-[1px] ${(i % 3 === 0 || i % 5 === 0) ? 'bg-bg' : 'bg-transparent'}`} />
                ))}
              </div>
              <span className="absolute inset-0 flex items-center justify-center text-loss font-black text-sm">+</span>
            </div>
            <p className="text-xs text-text-dim leading-relaxed">
              QR-Rechnung nach ISO 20022 generiert und via Telegram zugestellt.
            </p>
          </div>
        </>
      ) : (
        <div className="flex flex-col items-center justify-center py-8 text-center">
          <div className="w-16 h-16 rounded-full bg-gain-dim flex items-center justify-center mb-4">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="w-8 h-8 text-gain">
              <path d="M20 6L9 17l-5-5" />
            </svg>
          </div>
          <p className="text-sm font-medium text-text-dim">Kein Alarm aktiv</p>
          <p className="text-xs text-text-muted mt-1">Das Depot befindet sich innerhalb der Toleranz.</p>
        </div>
      )}
    </motion.div>
  );
}
