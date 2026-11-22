// Offline-Service-Worker des Personal Trackers (erzeugt von tool/web_bauen.sh).
// Legt beim Installieren alle Dateien des Builds im Cache ab; danach startet
// die App auch ohne Netz. Daten liegen ohnehin nur lokal (IndexedDB).
'use strict';

const VERSION = '__VERSION__';
const DATEIEN = __DATEIEN__;
const CACHE = `ptv2-${VERSION}`;

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    await cache.addAll(DATEIEN.map((d) => new Request(d, { cache: 'reload' })));
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const name of await caches.keys()) {
      if (name.startsWith('ptv2-') && name !== CACHE) await caches.delete(name);
    }
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET' || new URL(req.url).origin !== self.location.origin) return;
  if (req.mode === 'navigate') {
    // Seite: erst Netz (für Updates), ohne Netz aus dem Cache.
    event.respondWith((async () => {
      try {
        return await fetch(req);
      } catch (_) {
        return (await caches.match('index.html', { ignoreSearch: true })) || Response.error();
      }
    })());
    return;
  }
  event.respondWith((async () => {
    const treffer = await caches.match(req, { ignoreSearch: true });
    return treffer || fetch(req);
  })());
});
