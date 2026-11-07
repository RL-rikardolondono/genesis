// Colegio-IA v0.26: envía los avisos en cola (notificaciones push y, para las solicitudes de admisión sin avisos activados, correo).
// Lo ejecuta GitHub Actions cada 10 minutos con el usuario limitado correo_pruebas (solo puede leer la cola y marcarla).
import pg from 'pg';
import webpush from 'web-push';

const APP = 'https://colegio-ia.skynetgenesis.com';
const REMITENTE = process.env.BREVO_REMITENTE || 'colegio@skynetgenesis.com';
const PUB = process.env.VAPID_PUB, PRIV = process.env.VAPID_PRIVADA;
if (!PUB || !PRIV) { console.log('Faltan las llaves VAPID: no se envían avisos push.'); }
else webpush.setVapidDetails('mailto:contacto@skynetgenesis.com', PUB, PRIV);
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

const db = new pg.Client({ connectionString: process.env.NEON_CORREO, ssl: { rejectUnauthorized: false } });
await db.connect();
const { rows } = await db.query('select * from avisos_pendientes()');
console.log(`Avisos en cola: ${rows.length}`);
let enviados = 0;
for (const a of rows) {
  const malos = []; let ok = false;
  if (PUB && PRIV) for (const s of a.subs) {
    try {
      await webpush.sendNotification(s, JSON.stringify({ titulo: a.titulo, cuerpo: a.cuerpo, url: a.url || '/', tag: 'colegio-' + a.id }), { TTL: 86400 });
      ok = true;
    } catch (e) { if (e.statusCode === 404 || e.statusCode === 410) malos.push(s.endpoint); else console.log('push', e.statusCode || e.message); }
  }
  // sin avisos activados: las novedades de una solicitud de admisión van por correo
  if (!ok && a.por_correo && a.correo && process.env.BREVO_API_KEY) {
    const html = `<div style="font-family:Arial,sans-serif;color:#1C2B39;max-width:560px"><h2 style="color:#0B4F8A">${esc(a.titulo)}</h2><p>${esc(a.cuerpo)}</p>
      <p><a href="${APP}${a.url || '/'}" style="background:#14A38B;color:#fff;padding:10px 16px;border-radius:8px;text-decoration:none">Ver en Colegio-IA</a></p>
      <p style="color:#5D6B78;font-size:12px">${esc(a.colegio || '')} · Colegio-IA · SkyNet Genesis · contacto@skynetgenesis.com · WhatsApp 304 437 5758</p></div>`;
    const r = await fetch('https://api.brevo.com/v3/smtp/email', {
      method: 'POST', headers: { 'api-key': process.env.BREVO_API_KEY, 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ sender: { name: a.colegio ? `${a.colegio} · Colegio-IA` : 'Colegio-IA', email: REMITENTE }, to: [{ email: a.correo, name: a.nombre || a.correo }], subject: a.titulo, htmlContent: html }) });
    ok = r.ok; if (!r.ok) console.log('correo', r.status, await r.text());
  }
  // si la persona no tiene ningún equipo con avisos ni le toca correo, se da por atendido (lo verá al entrar a la app)
  const atendido = ok || (!a.subs.length && !(a.por_correo && a.correo));
  await db.query('select avisos_marcar($1, $2, $3)', [[a.id], atendido, malos]);
  if (ok) enviados++;
}
console.log(`Enviados: ${enviados}`);
await db.end();
