// Colegio-IA: permite instalar la app en el celular y recibir avisos. No guarda datos del colegio: todo va siempre a la red.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', () => {});
// Avisos (v0.26): comunicados, mensajes, citas y solicitudes de admisión
self.addEventListener('push', e => {
  let d = {}; try { d = e.data ? e.data.json() : {}; } catch { d = { titulo: 'Colegio-IA', cuerpo: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.titulo || 'Colegio-IA', { body: d.cuerpo || '', icon: 'icono-192.png', badge: 'icono-192.png', data: { url: d.url || '/' }, tag: d.tag || undefined }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || '/', self.location.origin).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(l => {
    for (const c of l) if (c.url.startsWith(self.location.origin) && 'focus' in c) { c.navigate(url).catch(() => {}); return c.focus(); }
    return self.clients.openWindow(url);
  }));
});
