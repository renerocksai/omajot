// omajot service worker. The build stamps the version and the asset list below.
//
// App shell: cache-first, refreshed in the background, so the app opens
// offline. Attachments (/api/blobs/*) are immutable: cache-first forever.
// Everything else under /api/ (batches, events, whoami) is never cached.
const VERSION = '3b7d09a6803d'
const SHELL = 'omajot-shell-' + VERSION
const BLOBS = 'omajot-blobs'
const ASSETS = ["./","app.js","app.css","manifest.webmanifest","icons/icon-180.png","icons/icon-192.png","icons/icon-512.png","icons/icon-maskable-512.png","icons/icon.svg","core.wasm"]

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(SHELL).then((c) => c.addAll(ASSETS.map((a) => new Request(a, { cache: 'reload' })))))
  self.skipWaiting()
})

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) if (key.startsWith('omajot-shell-') && key !== SHELL) await caches.delete(key)
    await self.clients.claim()
  })())
})

self.addEventListener('fetch', (event) => {
  const req = event.request
  if (req.method !== 'GET') return
  const url = new URL(req.url)
  if (url.origin !== location.origin) return
  const scope = new URL(self.registration.scope).pathname
  const path = url.pathname.slice(scope.length - 1)

  if (path.startsWith('/api/blobs/')) {
    event.respondWith((async () => {
      const cache = await caches.open(BLOBS)
      const hit = await cache.match(req)
      if (hit) return hit
      const res = await fetch(req)
      if (res.ok) cache.put(req, res.clone())
      return res
    })())
    return
  }
  if (path.startsWith('/api/')) return // live data, never cached

  event.respondWith((async () => {
    const cache = await caches.open(SHELL)
    const key = req.mode === 'navigate' ? new URL('./', self.registration.scope).href : req
    const hit = await cache.match(key, { ignoreSearch: true })
    const refresh = fetch(req).then((res) => {
      if (res.ok && req.mode !== 'navigate') cache.put(req, res.clone())
      return res
    }).catch(() => null)
    if (hit) {
      event.waitUntil(refresh)
      return hit
    }
    return (await refresh) || new Response('offline', { status: 503 })
  })())
})
