import { motion } from 'framer-motion';

export default function AlarmBanner({ alarm }) {
  return (
    <motion.div
      initial={{ opacity: 0, y: -40 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0, y: -40 }}
      transition={{ type: 'spring', stiffness: 200, damping: 20 }}
      className="mx-6 mb-8 max-w-[1280px] lg:mx-auto"
      id="alerts"
    >
      <div className="relative overflow-hidden rounded-2xl border border-loss/30 bg-gradient-to-r from-loss/[0.08] via-loss/[0.04] to-transparent p-6">
        {/* Animated background pulse */}
        <div className="absolute inset-0 animate-alarm-pulse pointer-events-none" />

        <div className="relative z-10 flex flex-col md:flex-row items-start md:items-center gap-4">
          {/* Warning Icon */}
          <div className="w-12 h-12 rounded-xl bg-loss/20 flex items-center justify-center flex-shrink-0">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="w-6 h-6 text-loss">
              <path d="M12 9v4m0 4h.01M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z" />
            </svg>
          </div>

          <div className="flex-1">
            <h3 className="text-lg font-bold text-loss mb-1">
              Achtung: 15% Verlust-Schwelle unterschritten
            </h3>
            <p className="text-sm text-text-dim leading-relaxed">
              Eine <span className="text-white font-semibold">Schweizer QR-Rechnung</span> wurde automatisch generiert und
              per <span className="text-white font-semibold">Telegram</span> an den hinterlegten Empfänger gesendet.
              Der Ausgleichsbetrag basiert auf der Differenz zum All-Time-High des Depots.
            </p>
          </div>

          {/* Status badges */}
          <div className="flex flex-col gap-2 flex-shrink-0">
            <span className="inline-flex items-center gap-1.5 text-xs font-semibold bg-gain-dim text-gain px-3 py-1.5 rounded-lg">
              <span className="w-1.5 h-1.5 rounded-full bg-gain animate-blink" />
              QR generiert
            </span>
            <span className="inline-flex items-center gap-1.5 text-xs font-semibold bg-gain-dim text-gain px-3 py-1.5 rounded-lg">
              <span className="w-1.5 h-1.5 rounded-full bg-gain animate-blink" />
              Telegram gesendet
            </span>
          </div>
        </div>
      </div>
    </motion.div>
  );
}
