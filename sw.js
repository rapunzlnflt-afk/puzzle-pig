/* Puzzle Pig service worker — v47
 *
 * WHY THIS EXISTS:
 * The app is installed to the iOS/Android home screen as a PWA. Before this SW
 * existed, the app was cached at the HTTP layer and iOS home-screen apps ignore
 * `no-cache` meta tags, so users kept seeing an OLD build even after we shipped
 * fixes. This service worker uses a NETWORK-FIRST strategy for the app shell so
 * the newest build is always fetched when online, with a cached fallback when
 * offline. It also calls skipWaiting()/clients.claim() so a new SW takes over
 * immediately instead of waiting for every tab to close.
 */
const PP_SW_VERSION = 'pp-v51';
const PP_CACHE = 'puzzle-pig-' + PP_SW_VERSION;
// The app shell we want to keep available offline.
const PP_SHELL = ['./app.html', './index.html', './'];

self.addEventListener('install', (event) => {
  // Activate the new SW as soon as it is installed — do not wait.
  self.skipWaiting();
  event.waitUntil(
    caches.open(PP_CACHE).then((cache) => cache.addAll(PP_SHELL).catch(() => {}))
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    // Delete every old Puzzle Pig cache so stale builds cannot resurface.
    const keys = await caches.keys();
    await Promise.all(
      keys.filter((k) => k.startsWith('puzzle-pig-') && k !== PP_CACHE)
          .map((k) => caches.delete(k))
    );
    await self.clients.claim();
  })());
});

self.addEventListener('message', (event) => {
  if (event.data === 'PP_SKIP_WAITING') self.skipWaiting();
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  // Never touch Supabase or any cross-origin API traffic — let it hit the network directly.
  if (url.origin !== self.location.origin) return;

  const isShell = req.mode === 'navigate' ||
                  url.pathname.endsWith('/app.html') ||
                  url.pathname.endsWith('/index.html') ||
                  url.pathname.endsWith('/');

  if (isShell) {
    // NETWORK-FIRST: always try to get the freshest app shell; fall back to cache offline.
    event.respondWith((async () => {
      try {
        const fresh = await fetch(req, { cache: 'no-store' });
        const cache = await caches.open(PP_CACHE);
        cache.put(req, fresh.clone()).catch(() => {});
        return fresh;
      } catch (_) {
        const cached = await caches.match(req);
        return cached || caches.match('./app.html');
      }
    })());
    return;
  }

  // Everything else (fonts, images): cache-first with background refresh.
  event.respondWith((async () => {
    const cached = await caches.match(req);
    if (cached) return cached;
    try {
      const fresh = await fetch(req);
      const cache = await caches.open(PP_CACHE);
      cache.put(req, fresh.clone()).catch(() => {});
      return fresh;
    } catch (_) {
      return cached || Response.error();
    }
  })());
});
