import { motion } from 'framer-motion';

function formatCHF(value) {
  return value.toLocaleString('de-CH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

const coinIcons = {
  bitcoin: (
    <svg viewBox="0 0 24 24" fill="currentColor" className="w-5 h-5 text-[#f7931a]">
      <path d="M12 2a10 10 0 100 20 10 10 0 000-20zm1.5 14.75V18h-1v-1.2c-.83-.07-1.68-.32-2.17-.63l.38-1.46c.53.28 1.28.56 2.08.56.7 0 1.17-.26 1.17-.7 0-.42-.38-.68-1.33-.97-1.37-.42-2.3-1.02-2.3-2.17 0-1.04.73-1.87 2-2.13V8h1v1.17c.83.07 1.4.28 1.82.5l-.36 1.42c-.32-.17-.9-.46-1.75-.46-.78 0-1.07.32-1.07.65 0 .38.42.62 1.5.97 1.52.47 2.14 1.13 2.14 2.2 0 1.07-.76 1.95-2.11 2.2z" />
    </svg>
  ),
  ethereum: (
    <svg viewBox="0 0 24 24" fill="currentColor" className="w-5 h-5 text-[#627eea]">
      <path d="M12 2l-7 11.5L12 17l7-3.5L12 2zm-7 12.5L12 22l7-7.5L12 18l-7-3.5z" />
    </svg>
  ),
};

export default function CoinTable({ coins }) {
  if (!coins || coins.length === 0) return null;

  return (
    <section className="px-6 pb-20 max-w-[1280px] mx-auto" id="positionen">
      <div className="mb-8">
        <h2 className="text-2xl font-bold tracking-tight">Positionen</h2>
        <p className="text-sm text-text-dim mt-1">Einzelübersicht aller getrackten Assets</p>
      </div>

      {/* Desktop Table */}
      <div className="hidden md:block glass-card overflow-hidden">
        <table className="w-full">
          <thead>
            <tr className="border-b border-glass-border">
              <th className="text-left text-xs font-medium text-text-dim uppercase tracking-wider px-6 py-4">Asset</th>
              <th className="text-right text-xs font-medium text-text-dim uppercase tracking-wider px-6 py-4">Menge</th>
              <th className="text-right text-xs font-medium text-text-dim uppercase tracking-wider px-6 py-4">Kurs</th>
              <th className="text-right text-xs font-medium text-text-dim uppercase tracking-wider px-6 py-4">Wert</th>
              <th className="text-right text-xs font-medium text-text-dim uppercase tracking-wider px-6 py-4">24h</th>
            </tr>
          </thead>
          <tbody>
            {coins.map((coin, i) => (
              <motion.tr
                key={coin.id}
                initial={{ opacity: 0, x: -20 }}
                animate={{ opacity: 1, x: 0 }}
                transition={{ duration: 0.4, delay: 0.1 * i }}
                className="border-b border-glass-border last:border-0 hover:bg-white/[0.02] transition-colors"
              >
                <td className="px-6 py-4">
                  <div className="flex items-center gap-3">
                    <div className="w-8 h-8 rounded-lg bg-glass-bg flex items-center justify-center">
                      {coinIcons[coin.id] || <span className="text-xs font-bold">{coin.symbol[0]}</span>}
                    </div>
                    <div>
                      <span className="font-semibold text-sm text-white">{coin.name}</span>
                      <span className="block text-xs text-text-muted">{coin.symbol}</span>
                    </div>
                  </div>
                </td>
                <td className="px-6 py-4 text-right text-sm font-medium">{coin.amount}</td>
                <td className="px-6 py-4 text-right text-sm font-medium">CHF {formatCHF(coin.pricePerUnit)}</td>
                <td className="px-6 py-4 text-right text-sm font-semibold text-white">CHF {formatCHF(coin.totalValue)}</td>
                <td className="px-6 py-4 text-right">
                  <span className={`text-sm font-semibold ${coin.change24h >= 0 ? 'text-gain' : 'text-loss'}`}>
                    {coin.change24h >= 0 ? '+' : ''}{coin.change24h}%
                  </span>
                </td>
              </motion.tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* Mobile Cards */}
      <div className="md:hidden flex flex-col gap-4">
        {coins.map((coin, i) => (
          <motion.div
            key={coin.id}
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.4, delay: 0.1 * i }}
            className="glass-card p-5"
          >
            <div className="flex items-center justify-between mb-3">
              <div className="flex items-center gap-3">
                <div className="w-9 h-9 rounded-lg bg-glass-bg flex items-center justify-center">
                  {coinIcons[coin.id] || <span className="text-xs font-bold">{coin.symbol[0]}</span>}
                </div>
                <div>
                  <span className="font-semibold text-sm text-white">{coin.name}</span>
                  <span className="block text-xs text-text-muted">{coin.symbol}</span>
                </div>
              </div>
              <span className={`text-sm font-semibold ${coin.change24h >= 0 ? 'text-gain' : 'text-loss'}`}>
                {coin.change24h >= 0 ? '+' : ''}{coin.change24h}%
              </span>
            </div>
            <div className="grid grid-cols-3 gap-3 pt-3 border-t border-glass-border">
              <div>
                <span className="block text-xs text-text-muted">Menge</span>
                <span className="text-sm font-medium">{coin.amount}</span>
              </div>
              <div>
                <span className="block text-xs text-text-muted">Kurs</span>
                <span className="text-sm font-medium">CHF {formatCHF(coin.pricePerUnit)}</span>
              </div>
              <div>
                <span className="block text-xs text-text-muted">Wert</span>
                <span className="text-sm font-semibold text-white">CHF {formatCHF(coin.totalValue)}</span>
              </div>
            </div>
          </motion.div>
        ))}
      </div>
    </section>
  );
}
