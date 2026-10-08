const CACHE_NAME = "satata-xray-ecg-v71";
const APP_SHELL = [
  "./",
  "./index.html",
  "./blood-test.js",
  "./style.css",
  "./manifest.json",
  "./icons/icon-192.png",
  "./icons/icon-512.png"
];

self.addEventListener("install", event => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => cache.addAll(APP_SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys.filter(key => key !== CACHE_NAME).map(key => caches.delete(key))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", event => {
  const request = event.request;
  const url = new URL(request.url);

  // Never cache Supabase API/auth traffic or non-GET requests.
  if (request.method !== "GET" || url.hostname.includes("supabase.co")) return;

  // Always prefer the newest HTML/navigation from Vercel.
  // This prevents an old cached index.html from keeping the app stuck
  // after a deployment.
  if (request.mode === "navigate" || url.pathname.endsWith("/index.html")) {
    event.respondWith(
      fetch(request)
        .then(response => {
          if (response.ok && url.origin === location.origin) {
            const copy = response.clone();
            caches.open(CACHE_NAME).then(cache => cache.put(request, copy));
          }
          return response;
        })
        .catch(() => caches.match(request))
    );
    return;
  }

  event.respondWith(
    caches.match(request).then(cached => {
      const network = fetch(request).then(response => {
        if (response.ok && url.origin === location.origin) {
          const copy = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(request, copy));
        }
        return response;
      }).catch(() => cached);

      return cached || network;
    })
  );
});
