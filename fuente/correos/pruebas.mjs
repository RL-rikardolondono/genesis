// Colegio-IA: correo diario a los colegios en prueba gratis (lo ejecuta GitHub Actions cada mañana).
// Variables (secretos del repositorio): NEON_CORREO (conexión del usuario limitado correo_pruebas), BREVO_API_KEY.
// Opcionales: BREVO_REMITENTE (correo verificado en Brevo; por defecto contacto@skynetgenesis.com), PRUEBA=1 (no envía, solo muestra).
import pg from 'pg';

const APP = 'https://colegio-ia.skynetgenesis.com/';
const WA = 'https://wa.me/573044375758?text=' + encodeURIComponent('Hola. Estoy probando Colegio-IA y quiero ayuda.');
const REMITENTE = process.env.BREVO_REMITENTE || 'contacto@skynetgenesis.com';
const cop = n => '$' + Number(n || 0).toLocaleString('es-CO');
const fecha = f => new Date(f + 'T12:00:00Z').toLocaleDateString('es-CO', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC' });
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

function correo(c) {
  const nombre = (c.rector || '').split(' ')[0] || 'rector(a)';
  const asunto = c.dias === 0 ? `Terminó la prueba gratis de ${c.colegio} en Colegio-IA`
    : c.dias === 1 ? `Hoy es el último día de prueba gratis de ${c.colegio}`
    : `Le quedan ${c.dias} días de prueba gratis en Colegio-IA`;
  const intro = c.dias === 0
    ? `La prueba gratis de <strong>${esc(c.colegio)}</strong> terminó hoy. <strong>Toda la información que registró está guardada.</strong> Para seguir usándola, pague el primer mes en línea y el acceso se abre apenas Bold confirme el pago.`
    : c.dias === 1
      ? `Hoy es el último día de la prueba gratis de <strong>${esc(c.colegio)}</strong>. Si paga hoy el primer mes, el colegio sigue trabajando sin interrupciones.`
      : `A <strong>${esc(c.colegio)}</strong> le quedan <strong>${c.dias} días</strong> de prueba gratis (hasta el ${fecha(c.prueba_hasta)}).`;
  const consejo = c.dias >= 10 ? 'Si aún no lo ha hecho, revise los cursos, matricule a los estudiantes e invite a sus docentes desde "Usuarios y accesos".'
    : c.dias >= 4 ? 'Es un buen momento para invitar a las familias: verán comunicados, calificaciones, horario y el campus virtual desde su celular.'
    : 'Para no perder el ritmo, pague el primer mes desde "Inicio › Su suscripción" con tarjeta, PSE, Nequi o Bancolombia.';
  const html = `<div style="font-family:Arial,Helvetica,sans-serif;color:#1C2B39;max-width:560px;margin:auto">
    <div style="background:#0B4F8A;color:#fff;padding:16px 20px;border-radius:10px 10px 0 0;font-size:20px;font-weight:bold">Colegio-IA</div>
    <div style="border:1px solid #DCE5EE;border-top:0;padding:20px;border-radius:0 0 10px 10px">
      <p>Hola, ${esc(nombre)}:</p><p>${intro}</p>
      <p>${consejo}</p>
      <p>Plan elegido: hasta ${c.plan_max} estudiantes, <strong>${cop(c.valor_mes)} al mes</strong>, con todos los módulos y usuarios ilimitados.</p>
      <p style="margin:22px 0"><a href="${APP}" style="background:#14A38B;color:#fff;padding:12px 20px;border-radius:6px;text-decoration:none;font-weight:bold">Entrar a Colegio-IA</a>
      &nbsp; <a href="${WA}" style="background:#1F8A4C;color:#fff;padding:12px 20px;border-radius:6px;text-decoration:none;font-weight:bold">Hablar con un asesor</a></p>
      <p style="color:#5D6B78;font-size:13px">SkyNet Genesis · contacto@skynetgenesis.com · WhatsApp 304 437 5758</p></div></div>`;
  return { asunto, html };
}

const db = new pg.Client({ connectionString: process.env.NEON_CORREO, ssl: { rejectUnauthorized: false } });
await db.connect();
const { rows } = await db.query('select * from public.pruebas_para_correo()');
console.log(`Colegios con correo hoy: ${rows.length}`);
let ok = 0;
for (const c of rows) {
  const { asunto, html } = correo(c);
  if (process.env.PRUEBA === '1') { console.log('PRUEBA →', c.email, '|', asunto); continue; }
  const r = await fetch('https://api.brevo.com/v3/smtp/email', {
    method: 'POST', headers: { 'api-key': process.env.BREVO_API_KEY, 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify({ sender: { name: 'Colegio-IA · SkyNet Genesis', email: REMITENTE }, to: [{ email: c.email, name: c.rector || c.colegio }], subject: asunto, htmlContent: html }),
  });
  if (r.ok) { await db.query('select public.prueba_correo_enviado($1)', [c.colegio_id]); ok++; console.log('Enviado a', c.colegio); }
  else console.log('Brevo no envió el correo de', c.colegio, '→', r.status, (await r.text()).slice(0, 200));
}
await db.end();
console.log(`Correos enviados: ${ok} de ${rows.length}`);
if (rows.length && !ok && process.env.PRUEBA !== '1') process.exit(1);
