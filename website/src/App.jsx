import { AnimatePresence } from 'framer-motion';
import { usePolling } from './hooks/usePolling';
import Navbar from './components/Navbar';
import Hero from './components/Hero';
import AlarmBanner from './components/AlarmBanner';
import DashboardGrid from './components/DashboardGrid';
import ValueCard from './components/ValueCard';
import ThresholdCard from './components/ThresholdCard';
import AlertCard from './components/AlertCard';
import CoinTable from './components/CoinTable';
import Footer from './components/Footer';
import EmailModal from './components/EmailModal';

export default function App() {
  const { data, loading, error } = usePolling('/data.json', 5000);
  const isAlarm = data?.status === 'ALARM';

  if (loading && !data) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <div className="flex flex-col items-center gap-4">
          <div className="w-10 h-10 border-2 border-gain/30 border-t-gain rounded-full animate-spin" />
          <span className="text-sm text-text-dim">Daten werden geladen...</span>
        </div>
      </div>
    );
  }

  if (error && !data) {
    return (
      <div className="min-h-screen flex items-center justify-center px-6">
        <div className="glass-card p-8 text-center max-w-md">
          <div className="w-12 h-12 rounded-xl bg-loss-dim text-loss flex items-center justify-center mx-auto mb-4">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="w-6 h-6">
              <circle cx="12" cy="12" r="10" /><path d="M15 9l-6 6M9 9l6 6" />
            </svg>
          </div>
          <h2 className="text-lg font-bold mb-2">Verbindungsfehler</h2>
          <p className="text-sm text-text-dim">data.json konnte nicht geladen werden. Stelle sicher, dass der Dev-Server läuft.</p>
          <p className="text-xs text-text-muted mt-2 font-mono">{error}</p>
        </div>
      </div>
    );
  }

  return (
    <div className={`min-h-screen transition-colors duration-700 ${isAlarm ? 'alarm-active' : ''}`}>
      {/* Red vignette in alarm mode */}
      {isAlarm && (
        <div className="fixed inset-0 pointer-events-none z-40
          bg-[radial-gradient(ellipse_at_center,transparent_50%,rgba(255,77,106,0.06)_100%)]" />
      )}

      <Navbar isAlarm={isAlarm} />
      <Hero data={data} isAlarm={isAlarm} />

      <AnimatePresence>
        {isAlarm && <AlarmBanner alarm={data.alarm} />}
      </AnimatePresence>

      <DashboardGrid>
        <ValueCard data={data} />
        <ThresholdCard data={data} isAlarm={isAlarm} />
        <AlertCard data={data} isAlarm={isAlarm} />
      </DashboardGrid>

      <CoinTable coins={data?.coins} />
      <Footer />
      <EmailModal />
    </div>
  );
}
