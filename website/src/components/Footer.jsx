export default function Footer() {
  return (
    <footer className="border-t border-glass-border py-10 px-6">
      <div className="max-w-[1280px] mx-auto flex flex-col md:flex-row items-center justify-between gap-4">
        <div className="flex items-center gap-3">
          <img src="/DepotTracker/logo/logo.png" alt="DepotTracker" className="h-7 rounded-md" />
          <span className="text-sm text-text-dim">DepotTracker — Schulprojekt 2026</span>
        </div>
        <div className="flex gap-6">
          <a href="#" className="text-xs text-text-muted hover:text-gain transition-colors">Datenschutz</a>
          <a href="#" className="text-xs text-text-muted hover:text-gain transition-colors">Impressum</a>
          <a href="https://github.com" target="_blank" rel="noopener noreferrer" className="text-xs text-text-muted hover:text-gain transition-colors">GitHub</a>
        </div>
      </div>
    </footer>
  );
}
