// Genesis: permite instalar la app en el celular. No guarda datos del colegio: todo va siempre a la red.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', () => {});
