import { useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';

export default function Navbar({ isAlarm }) {
  const [open, setOpen] = useState(false);

  return (
    <nav
      className={`fixed top-0 left-0 right-0 z-50 h-[72px] transition-colors duration-500
        backdrop-blur-xl border-b
        ${isAlarm ? 'bg-bg/90 border-loss/25' : 'bg-bg/82 border-glass-border'}`}
    >
      <div className="max-w-[1280px] mx-auto h-full flex items-center justify-between px-6">
        {/* Brand */}
        <a href="#" className="flex items-center gap-3">
          <img src="/DepotTracker/logo/logo.png" alt="DepotTracker" className="h-9 w-auto rounded-lg" />
          <span className="text-lg font-bold bg-gradient-to-r from-white to-gain bg-clip-text text-transparent">
            DepotTracker
          </span>
        </a>

        {/* Desktop Links */}
        <ul className="hidden md:flex items-center gap-8">
          {['Dashboard', 'Positionen', 'Alerts'].map((item) => (
            <li key={item}>
              <a
                href={`#${item.toLowerCase()}`}
                className="text-sm font-medium text-text-dim hover:text-white transition-colors relative
                  after:absolute after:left-0 after:bottom-[-4px] after:h-[2px] after:w-0
                  after:bg-gain after:rounded-sm after:transition-all hover:after:w-full"
              >
                {item}
              </a>
            </li>
          ))}
        </ul>

        {/* Status Pill (Desktop) */}
        <div className="hidden md:flex items-center gap-3">
          <motion.div
            animate={isAlarm ? { scale: [1, 1.05, 1] } : {}}
            transition={isAlarm ? { repeat: Infinity, duration: 2 } : {}}
            className={`flex items-center gap-2 text-xs font-semibold px-3 py-1.5 rounded-full
              ${isAlarm ? 'bg-loss-dim text-loss' : 'bg-gain-dim text-gain'}`}
          >
            <span className={`w-2 h-2 rounded-full animate-blink ${isAlarm ? 'bg-loss' : 'bg-gain'}`} />
            {isAlarm ? 'ALARM' : 'System aktiv'}
          </motion.div>
        </div>

        {/* Hamburger */}
        <button
          onClick={() => setOpen(!open)}
          className="md:hidden flex flex-col gap-[5px] p-1.5"
          aria-label="Menu"
        >
          <motion.span
            animate={open ? { rotate: 45, y: 7 } : { rotate: 0, y: 0 }}
            className="block w-[22px] h-[2px] bg-white rounded-sm"
          />
          <motion.span
            animate={open ? { opacity: 0 } : { opacity: 1 }}
            className="block w-[22px] h-[2px] bg-white rounded-sm"
          />
          <motion.span
            animate={open ? { rotate: -45, y: -7 } : { rotate: 0, y: 0 }}
            className="block w-[22px] h-[2px] bg-white rounded-sm"
          />
        </button>
      </div>

      {/* Mobile Menu */}
      <AnimatePresence>
        {open && (
          <motion.div
            initial={{ opacity: 0, y: -10 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -10 }}
            className="md:hidden bg-bg/97 backdrop-blur-xl border-b border-glass-border"
          >
            {['Dashboard', 'Positionen', 'Alerts'].map((item) => (
              <a
                key={item}
                href={`#${item.toLowerCase()}`}
                onClick={() => setOpen(false)}
                className="block px-6 py-4 text-sm text-text-dim hover:text-white border-b border-glass-border transition-colors"
              >
                {item}
              </a>
            ))}
          </motion.div>
        )}
      </AnimatePresence>
    </nav>
  );
}
