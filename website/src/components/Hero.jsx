import { motion } from 'framer-motion';

function formatCHF(value) {
  return value.toLocaleString('de-CH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

export default function Hero({ data, isAlarm }) {
  if (!data) return null;

  return (
    <section className="relative pt-[120px] pb-16 px-6 max-w-[1280px] mx-auto" id="dashboard">
      {/* Background Glow */}
      <div
        className={`absolute top-[-100px] left-1/2 -translate-x-1/2 w-[700px] h-[700px] rounded-full
          animate-pulse-glow pointer-events-none transition-all duration-1000
          ${isAlarm
            ? 'bg-[radial-gradient(circle,rgba(255,77,106,0.12)_0%,transparent_70%)]'
            : 'bg-[radial-gradient(circle,rgba(0,240,160,0.10)_0%,transparent_70%)]'
          }`}
      />

      <div className="relative z-10 flex flex-col lg:flex-row items-start gap-12">
        {/* Left: Text */}
        <div className="flex-1">
          <motion.p
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.5 }}
            className={`inline-block text-xs font-semibold tracking-widest uppercase px-3.5 py-1.5 rounded-full mb-5
              ${isAlarm ? 'bg-loss-dim text-loss' : 'bg-gain-dim text-gain'}`}
          >
            Krypto & Aktien Monitoring
          </motion.p>

          <motion.h1
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.5, delay: 0.1 }}
            className="text-4xl md:text-5xl lg:text-[3.5rem] font-extrabold leading-[1.1] tracking-tight mb-5"
          >
            <span className="text-white">CHF {formatCHF(data.totalValue)}</span>
            <br />
            <span className={`bg-clip-text text-transparent bg-gradient-to-r
              ${isAlarm ? 'from-loss to-warn' : 'from-gain to-[#00c9ff]'}`}>
              Gesamtdepotwert
            </span>
          </motion.h1>

          <motion.div
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.5, delay: 0.2 }}
            className="flex items-center gap-4 mb-8"
          >
            <div className={`flex items-center gap-2 text-sm font-semibold px-3 py-1.5 rounded-lg
              ${data.percentChange >= 0 ? 'bg-gain-dim text-gain' : 'bg-loss-dim text-loss'}`}>
              <svg viewBox="0 0 20 20" fill="currentColor" className={`w-4 h-4 ${data.percentChange >= 0 ? '' : 'rotate-180'}`}>
                <path d="M10 3l7 7h-4v7H7v-7H3l7-7z" />
              </svg>
              {data.percentChange >= 0 ? '+' : ''}{data.percentChange}% heute
            </div>
            <span className="text-sm text-text-dim">
              ATH-Abstand: {data.lossFromAth}%
            </span>
          </motion.div>

          <motion.p
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.5, delay: 0.3 }}
            className="text-text-dim text-base max-w-lg mb-10 leading-relaxed"
          >
            Automatische Depot-Absicherung mit Echtzeit-Monitoring.
            Bei 15% Verlust wird sofort eine Schweizer QR-Rechnung generiert und per Telegram versendet.
          </motion.p>

          {/* Stats Row */}
          <motion.div
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.5, delay: 0.4 }}
            className="flex gap-8 pt-6 border-t border-glass-border"
          >
            <div>
              <span className="block text-xl font-bold text-white">{data.coins.length}</span>
              <span className="text-xs text-text-dim">Positionen</span>
            </div>
            <div>
              <span className="block text-xl font-bold text-white">{data.alarmThreshold}%</span>
              <span className="text-xs text-text-dim">Schwelle</span>
            </div>
            <div>
              <span className="block text-xl font-bold text-white">&lt; 2s</span>
              <span className="text-xs text-text-dim">Reaktionszeit</span>
            </div>
          </motion.div>
        </div>

        {/* Right: Chart Visual */}
        <motion.div
          initial={{ opacity: 0, scale: 0.95 }}
          animate={{ opacity: 1, scale: 1 }}
          transition={{ duration: 0.6, delay: 0.3 }}
          className="flex-1 w-full max-w-lg"
        >
          <div className="glass-card p-6 relative overflow-hidden">
            <div className="flex items-center justify-between mb-4">
              <span className="text-sm font-medium text-text-dim">Portfolio Verlauf</span>
              <span className={`text-sm font-bold px-2.5 py-1 rounded-md
                ${data.percentChange >= 0 ? 'bg-gain-dim text-gain' : 'bg-loss-dim text-loss'}`}>
                {data.percentChange >= 0 ? '+' : ''}{data.percentChange}%
              </span>
            </div>
            <svg viewBox="0 0 400 180" className="w-full">
              <defs>
                <linearGradient id="chartGrad" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="0%" stopColor={isAlarm ? '#ff4d6a' : '#00f0a0'} stopOpacity="0.35" />
                  <stop offset="100%" stopColor={isAlarm ? '#ff4d6a' : '#00f0a0'} stopOpacity="0" />
                </linearGradient>
              </defs>
              <motion.path
                d="M0,140 C30,135 50,120 80,110 C110,100 130,85 160,90 C190,95 210,70 240,55 C270,40 300,50 330,35 C360,20 380,25 400,15"
                fill="none"
                stroke={isAlarm ? '#ff4d6a' : '#00f0a0'}
                strokeWidth="2.5"
                initial={{ pathLength: 0 }}
                animate={{ pathLength: 1 }}
                transition={{ duration: 2, ease: 'easeInOut' }}
              />
              <path
                d="M0,140 C30,135 50,120 80,110 C110,100 130,85 160,90 C190,95 210,70 240,55 C270,40 300,50 330,35 C360,20 380,25 400,15 L400,180 L0,180 Z"
                fill="url(#chartGrad)"
                opacity="0.6"
              />
            </svg>
            {/* Coin pills */}
            <div className="flex gap-2 mt-4">
              {data.coins.map((coin) => (
                <span key={coin.id} className="text-xs font-medium text-text-dim bg-glass-bg border border-glass-border px-2.5 py-1 rounded-md">
                  {coin.symbol}
                </span>
              ))}
            </div>
          </div>
        </motion.div>
      </div>
    </section>
  );
}
