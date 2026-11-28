// Service worker Jadwal Les: kerangka aplikasi tersimpan agar cepat terbuka.
// Data (Supabase) tidak pernah disimpan di sini, jadi hasilnya selalu sama dengan versi lain.
const V = 'jadwal-les-v1';
const SHELL = ['./', 'index.html', 'manifest.webmanifest', 'icon-192.png', 'icon-512.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(V).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(ks => Promise.all(ks.filter(k => k !== V).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const r = e.request;
  if (r.method !== 'GET') return;
  const u = new URL(r.url);
  if (u.origin !== location.origin) return;   // Supabase dan layanan lain langsung ke jaringan
  // Halaman utama: jaringan dulu supaya pembaruan langsung terlihat, cadangan dari cache saat offline.
  if (r.mode === 'navigate' || u.pathname.endsWith('/index.html')) {
    e.respondWith(
      fetch(r).then(res => {
        const cp = res.clone();
        caches.open(V).then(c => c.put('index.html', cp));
        return res;
      }).catch(() => caches.match('index.html'))
    );
    return;
  }
  // Ikon dan manifest: cache dulu.
  e.respondWith(
    caches.match(r).then(hit => hit || fetch(r).then(res => {
      const cp = res.clone();
      caches.open(V).then(c => c.put(r, cp));
      return res;
    }))
  );
});
