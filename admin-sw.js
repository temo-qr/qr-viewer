// Service worker للوحة الأدمن بس (الـ scope متقيّد بـ admin.html، فصفحة العملاء مش بتتأثر).
// مفيش كاش عن قصد: اللوحة لازم تجيب دايمًا آخر نسخة.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', () => {});
