/* Puzzle Pig — © 2026 Shauna Wimberley / CleartrackApps. All rights reserved. */

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
const PP_SW_VERSION = 'pp-v105';
const PP_CACHE = 'puzzle-pig-' + PP_SW_VERSION;
// The app shell we want to keep available offline.
const PP_SHELL = ['./app.html', './index.html', './'];
// v105: how long the shell fetch may hold the navigation open before we fall back to
// the cached copy. respondWith() gates the navigation, so until it settles the browser
// has NO html and the window is blank — a slow (as opposed to failed) network used to
// blank the app for as long as the platform's own request timeout, ~60s on iOS.
const PP_SHELL_TIMEOUT_MS = 3500;

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
    // NETWORK-FIRST WITH A DEADLINE: still prefer the freshest app shell, but never let a
    // slow network hold the navigation open. v72: fetch from a cache-busted URL with
    // no-store so neither the HTTP cache nor any intermediary can hand back a stale
    // app.html on iOS PWAs.
    event.respondWith((async () => {
      const bust = new URL(req.url);
      bust.searchParams.set('sw_fresh', Date.now().toString());

      const network = fetch(bust.toString(), { cache: 'no-store' }).then((fresh) => {
        // Store under the ORIGINAL request key so offline fallback still matches.
        caches.open(PP_CACHE)
          .then((cache) => cache.put(req, fresh.clone()))
          .catch(() => {});
        return fresh;
      });
      // A rejection here is handled below; this keeps it from also surfacing as an
      // unhandled rejection when the cache wins the race.
      network.catch(() => {});

      const cached = await caches.match(req) || await caches.match('./app.html');
      if (!cached) return network;   // first ever load: the network is all we have

      const timeout = new Promise((resolve) => setTimeout(() => resolve(null), PP_SHELL_TIMEOUT_MS));
      try {
        // Serve the cached shell the moment the network overruns; the in-flight fetch
        // above still refreshes the cache, so the next load gets the new build.
        return (await Promise.race([network, timeout])) || cached;
      } catch (_) {
        return cached;
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
