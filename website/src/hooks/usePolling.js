import { useState, useEffect, useCallback } from 'react';

export function usePolling(url, intervalMs = 5000) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const fetchData = useCallback(async () => {
    try {
      // Fix für GitHub Pages: Passt den Pfad automatisch an, 
      // damit die Datei im Unterordner gefunden wird.
      let safeUrl = url;
      if (safeUrl === '/data.json' || safeUrl === 'data.json') {
        safeUrl = '/DepotTracker/data.json';
      }

      // Der Timestamp (?t=...) verhindert zusätzlich, dass der Browser alte Daten im Cache behält
      const res = await fetch(`${safeUrl}?t=${Date.now()}`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const json = await res.json();
      setData(json);
      setError(null);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, [url]);

  useEffect(() => {
    fetchData();
    const id = setInterval(fetchData, intervalMs);
    return () => clearInterval(id);
  }, [fetchData, intervalMs]);

  return { data, loading, error };
}