import { motion } from 'framer-motion';

export default function ThresholdCard({ data, isAlarm }) {
  if (!data) return null;

  const currentLoss = Math.abs(data.lossFromAth);
  const threshold = data.alarmThreshold;
  const fillPercent = Math.min((currentLoss / threshold) * 100, 130);
  const exceeded = currentLoss >= threshold;

  return (
    <motion.div
      initial={{ opacity: 0, y: 30 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.5, delay: 0.2 }}
      whileHover={{ y: -6 }}
      className="glass-card p-7 relative overflow-hidden cursor-default
        hover:shadow-[0_20px_60px_rgba(0,0,0,0.35)] hover:border-white/[0.12] transition-all duration-300"
    >
      {/* Icon */}
      <div className="w-12 h-12 flex items-center justify-center rounded-xl bg-warn-dim text-warn mb-5">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="w-6 h-6">
          <path d="M12 9v4m0 4h.01M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z" />
        </svg>
      </div>

      <p className="text-xs font-medium text-text-dim uppercase tracking-wider mb-2">Verlust-Schwelle</p>

      <h3 className="text-3xl font-extrabold text-warn tracking-tight mb-4">
        {threshold}<span className="text-lg opacity-60 ml-0.5">%</span>
      </h3>

      {/* Threshold Bar */}
      <div className="relative h-2.5 bg-white/[0.06] rounded-full mb-4 overflow-visible">
        <motion.div
          initial={{ width: 0 }}
          animate={{ width: `${Math.min(fillPercent, 100)}%` }}
          transition={{ duration: 1.5, ease: 'easeOut' }}
          className={`h-full rounded-full ${exceeded
            ? 'bg-gradient-to-r from-warn to-loss'
            : 'bg-gradient-to-r from-gain to-warn'
          }`}
        />
        {/* Threshold Marker */}
        <div className="absolute top-[-5px] h-5 w-[3px] bg-loss rounded-sm" style={{ left: '100%', transform: 'translateX(-50%)' }}>
          <span className="absolute top-[-20px] left-1/2 -translate-x-1/2 text-[10px] text-loss font-semibold whitespace-nowrap">
            Grenze
          </span>
        </div>
      </div>

      <p className="text-sm text-text-dim mb-3">
        Aktueller ATH-Verlust: <strong className={exceeded ? 'text-loss' : 'text-warn'}>-{currentLoss.toFixed(1)}%</strong>
      </p>

      <div className={`inline-flex items-center gap-2 text-xs font-semibold px-3 py-1.5 rounded-lg
        ${exceeded ? 'bg-loss-dim text-loss' : 'bg-gain-dim text-gain'}`}>
        <span className={`w-2 h-2 rounded-full animate-blink ${exceeded ? 'bg-loss' : 'bg-gain'}`} />
        {exceeded ? 'Schwelle unterschritten!' : 'Innerhalb der Toleranz'}
      </div>
    </motion.div>
  );
}
