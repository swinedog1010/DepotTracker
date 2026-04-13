import { motion } from 'framer-motion';

function formatCHF(value) {
  const parts = value.toLocaleString('de-CH', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).split('.');
  return { main: parts[0], cents: parts[1] };
}

export default function ValueCard({ data }) {
  if (!data) return null;
  const { main, cents } = formatCHF(data.totalValue);
  const positive = data.percentChange >= 0;

  return (
    <motion.div
      initial={{ opacity: 0, y: 30 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.5, delay: 0.1 }}
      whileHover={{ y: -6 }}
      className="glass-card p-7 relative overflow-hidden group cursor-default
        hover:shadow-[0_20px_60px_rgba(0,0,0,0.35)] hover:border-white/[0.12] transition-all duration-300"
    >
      {/* Icon */}
      <div className="w-12 h-12 flex items-center justify-center rounded-xl bg-gain-dim text-gain mb-5">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="w-6 h-6">
          <path d="M12 2v20M17 5H9.5a3.5 3.5 0 000 7h5a3.5 3.5 0 010 7H6" />
        </svg>
      </div>

      <p className="text-xs font-medium text-text-dim uppercase tracking-wider mb-2">Aktueller Depotwert</p>

      <h3 className="text-3xl font-extrabold text-white tracking-tight mb-3">
        CHF {main}<span className="text-lg opacity-50 font-semibold">.{cents}</span>
      </h3>

      <div className={`inline-flex items-center gap-1.5 text-sm font-semibold px-2.5 py-1 rounded-lg
        ${positive ? 'bg-gain-dim text-gain' : 'bg-loss-dim text-loss'}`}>
        <svg viewBox="0 0 20 20" fill="currentColor" className={`w-3.5 h-3.5 ${positive ? '' : 'rotate-180'}`}>
          <path d="M10 3l7 7h-4v7H7v-7H3l7-7z" />
        </svg>
        {positive ? '+' : ''}{data.percentChange}% heute
      </div>

      {/* Sparkline */}
      <div className="mt-5 opacity-60 group-hover:opacity-80 transition-opacity">
        <svg viewBox="0 0 120 40" className="w-full h-10">
          <polyline
            points="0,35 10,30 20,28 30,25 40,27 50,20 60,22 70,15 80,18 90,10 100,12 110,8 120,5"
            fill="none"
            stroke={positive ? '#00f0a0' : '#ff4d6a'}
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      </div>
    </motion.div>
  );
}
