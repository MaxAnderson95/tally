const cacheName = 'tally-offline-v1'

self.addEventListener('install', event => {
  event.waitUntil(caches.open(cacheName).then(cache => cache.add('/offline.html')).then(() => self.skipWaiting()))
})

self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(
    keys.filter(key => key.startsWith('tally-offline-') && key !== cacheName).map(key => caches.delete(key))
  )).then(() => self.clients.claim()))
})

self.addEventListener('fetch', event => {
  const url = new URL(event.request.url)
  // Only document launches get a fallback. Readings and reset commands always reach the Mac.
  if (event.request.method !== 'GET' || event.request.mode !== 'navigate' ||
      url.origin !== self.location.origin || !['/', '/index.html'].includes(url.pathname)) return

  event.respondWith((async () => {
    try {
      const response = await fetch(event.request, { signal: AbortSignal.timeout(10_000) })
      if (response.ok) return response
      return await caches.match('/offline.html') ?? response
    } catch {
      return await caches.match('/offline.html') ?? Response.error()
    }
  })())
})
