{{flutter_js}}
{{flutter_build_config}}

// Ohne Flutters (inzwischen abgeschalteten) Service Worker laden; für den
// Offline-Betrieb registrieren wir unseren eigenen (offline_sw.js, erzeugt
// von tool/web_bauen.sh mit der vollständigen Dateiliste).
_flutter.loader.load();

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('offline_sw.js').catch((e) => console.warn('Offline-Modus nicht verfügbar:', e));
  });
}
