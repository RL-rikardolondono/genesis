import { createClient } from 'https://esm.sh/@neondatabase/neon-js@0.7.0-beta';
import { AUTH_URL, DATA_URL, VERSION } from './config.js';

const db = createClient({ auth: { url: AUTH_URL }, dataApi: { url: DATA_URL } });

/* =====================================================================
   Utilidades
   ===================================================================== */
const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const hoy = () => { const d = new Date(); return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0'); };
const fmtF = f => { if (!f) return ''; const [y, m, d] = String(f).slice(0, 10).split('-'); return `${d}/${m}/${y}`; };
const cop = n => '$' + Number(n || 0).toLocaleString('es-CO');
const MES_N = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
const mesTxt = f => { if (!f) return ''; const [y, m] = String(f).slice(0, 7).split('-'); return `${MES_N[+m - 1]} de ${y}`; };
const opt = (v, l, s) => `<option value="${esc(v)}" ${String(v) === String(s) ? 'selected' : ''}>${esc(l)}</option>`;
const head = (t, sub, extra) => `<div class="head"><div><h1>${t}</h1>${sub ? `<p class="muted">${sub}</p>` : ''}</div>${extra || ''}</div>`;
const store = {
  get(k) { try { return localStorage.getItem('micolegia:' + k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem('micolegia:' + k, v); } catch { } },
  del(k) { try { localStorage.removeItem('micolegia:' + k); } catch { } },
};

// Ventanas propias de confirmación (el navegador puede bloquear confirm/prompt)
function dialogo(html) {
  return new Promise(res => {
    let d = document.getElementById('dlg');
    if (!d) { d = document.createElement('div'); d.id = 'dlg'; d.className = 'dlg'; document.body.appendChild(d); }
    d.innerHTML = `<div class="dlg-box" role="dialog" aria-modal="true">${html}</div>`; d.hidden = false;
    d._res = v => { d.hidden = true; d.innerHTML = ''; res(v); };
    (d.querySelector('textarea') || d.querySelector('.btn:not(.ghost)'))?.focus();
  });
}
function dlgFin(v) { document.getElementById('dlg')?._res?.(v); }
const confirmar = (msg, si = 'Sí, continuar') => dialogo(`<p>${esc(msg)}</p><div class="modal-foot"><button class="btn ghost" type="button" onclick="dlgFin(false)">Cancelar</button><button class="btn" type="button" onclick="dlgFin(true)">${esc(si)}</button></div>`);
const pedirTexto = (msg, ph = '') => dialogo(`<p>${esc(msg)}</p><textarea id="dlgT" rows="3" placeholder="${esc(ph)}" style="width:100%"></textarea><div class="modal-foot"><button class="btn ghost" type="button" onclick="dlgFin(null)">Cancelar</button><button class="btn" type="button" onclick="dlgFin(document.getElementById('dlgT').value.trim())">Aceptar</button></div>`);
function toast(m) { const t = $('#toast'); t.textContent = m; t.classList.add('on'); clearTimeout(toast.t); toast.t = setTimeout(() => t.classList.remove('on'), 4500); }
function openModal(t, html) { $('#mt').textContent = t; $('#mb').innerHTML = html; $('#modal').hidden = false; const f = $('#mb input,#mb select,#mb textarea,#mb button'); if (f) f.focus(); }
function closeModal() { $('#modal').hidden = true; }
document.addEventListener('keydown', e => { if (e.key === 'Escape' && !$('#modal').hidden) closeModal(); });
let lastDocs = '', lastTitulo = '';
function showDocs(html, titulo, archivo) {
  if (isDoc() && modo === 'colegio') return toast('Los documentos los generan coordinación, secretaría y rectoría');
  html = conPie(html); lastDocs = html; lastTitulo = archivo || titulo || ''; openModal(titulo || 'Vista previa', `<div class="toolbar"><button class="btn" type="button" onclick="printDocs()">Imprimir o guardar en PDF</button></div>${html}`); }
function printDocs() {
  if (isDoc() && modo === 'colegio') return;
  $('#print').innerHTML = conPie(lastDocs);
  const t0 = document.title; if (lastTitulo) document.title = lastTitulo.replace(/[\\/:*?"<>|]/g, '');
  window.print(); setTimeout(() => { document.title = t0; }, 1500);
}

function msg(e) {
  if (!e) return 'Ocurrió un error inesperado';
  const m = e.message || String(e);
  if (e.code === '42501' || /row-level security|permission denied/i.test(m)) return 'No tiene permiso para esta acción';
  if (e.code === '23505' || /duplicate key/i.test(m)) return 'Ya existe un registro con esos datos';
  if (e.code === '23503') return 'El registro está relacionado con otros datos y no se puede eliminar';
  if (/Failed to fetch|NetworkError/i.test(m)) return 'Sin conexión. Revise su conexión a internet e intente de nuevo';
  if (/JWT|AuthRequired/i.test(m)) return 'Su sesión expiró. Vuelva a iniciar sesión';
  if (e.code === '23514' || /check constraint/i.test(m)) return 'Algún dato no es válido. Revise los valores escritos (números, fechas o textos demasiado largos)';
  if (e.code === '23502' || /not-null/i.test(m)) return 'Falta un dato obligatorio';
  if (e.code === '22P02' || /invalid input syntax/i.test(m)) return 'Hay un dato con un formato que no es válido';
  if (/^[\x00-\x7F]+$/.test(m) && /\b(the|violates|relation|column|function|error|failed|null)\b/i.test(m)) return 'No se pudo completar la acción. Intente de nuevo; si continúa, comuníquese con soporte';
  return m;
}
async function q(p) { const { data, error } = await p; if (error) throw error; return data; }
async function all(make) { // lee todas las filas en bloques de 1000
  const out = []; for (let i = 0; ; i += 1000) { const d = await q(make().range(i, i + 999)); out.push(...d); if (d.length < 1000) return out; }
}
const chunks = (a, n) => { const r = []; for (let i = 0; i < a.length; i += n) r.push(a.slice(i, i + n)); return r; };
async function guard(fn, okMsg) { try { const r = await fn(); if (okMsg) toast(okMsg); return r; } catch (e) { console.error(e); toast(msg(e)); return undefined; } }

/* =====================================================================
   Estado
   ===================================================================== */
const DIR = ['rector', 'coordinador', 'secretaria'];
const ROL_DESC = { rector: 'Ve y administra todo: matrícula, calificaciones, pagos, usuarios, parametrización y cierre del año.',
  coordinador: 'Parte académica y de convivencia: calificaciones, asistencia, boletines, observador, horario y comunicados.',
  secretaria: 'Matrícula, fichas de estudiantes, certificados, libros reglamentarios y pagos.', tesoreria: 'Pagos, cartera, recibos y paz y salvo.',
  docente: 'Sus cursos: califica, toma asistencia, escribe observaciones y envía comunicados a sus grupos.',
  acudiente: 'Información de sus hijos: comunicados, horario, excusas, estado de cuenta, calificaciones y boletines.',
  estudiante: 'Su campus virtual (clases, tareas y cuestionarios), gemas, horario, comunicados y calificaciones.' };
const ROL_TXT = { rector: 'Rector(a)', coordinador: 'Coordinador(a)', secretaria: 'Secretaría', tesoreria: 'Tesorería', docente: 'Docente', acudiente: 'Acudiente', estudiante: 'Estudiante' };
const PAGOS_ROLES = ['rector', 'secretaria', 'tesoreria'];
const NIVELES = { preescolar: 'Preescolar', primaria: 'Primaria', secundaria: 'Básica secundaria', media: 'Media' };
const PRE_VAL = { Superior: 96, Alto: 85, 'Básico': 70, Bajo: 50 };
const DESC = { Superior: 'Alcanza de manera excepcional los logros propuestos para la dimensión.', Alto: 'Alcanza satisfactoriamente los logros propuestos.', 'Básico': 'Alcanza los logros mínimos con apoyo ocasional.', Bajo: 'Requiere acompañamiento para alcanzar los logros propuestos.' };

let me = null;            // usuario autenticado
let superadmin = false;
let ctxs = [];            // membresías del usuario
let ctx = null;           // membresía activa
let modo = 'colegio';     // 'colegio' | 'plataforma'
let view = 'inicio';
let S = null;             // datos del colegio activo
const sel = { g: '', a: '', p: 0, fecha: '', fg: '', q: '' };

function resetS() {
  S = { k: null, grupos: [], asigs: [], ests: [], misGrupos: [], misAsig: {}, miembros: null, dg: [], acud: null,
        notas: {}, asis: {}, obs: {}, logros: {}, loadedG: new Set(), susc: null,
        acts: [], nact: {}, rec: {}, asisC: {}, coms: null, lect: {}, dirGrupos: [] };
}
const isDir = () => ctx && DIR.includes(ctx.rol);
const isDoc = () => ctx && ctx.rol === 'docente';
const isFam = () => ctx && (ctx.rol === 'acudiente' || ctx.rol === 'estudiante');
const isTes = () => ctx && ctx.rol === 'tesoreria';
const manejaPagos = () => ctx && PAGOS_ROLES.includes(ctx.rol);
const isAcud = () => ctx && ctx.rol === 'acudiente';
const est = id => S.ests.find(e => e.id === id);
const grupo = id => S.grupos.find(g => g.id === id);
const nom = e => `${e.nombres} ${e.apellidos}`;
const asigsDe = g => S.asigs.filter(a => a.nivel === g.nivel && (!a.grados?.length || a.grados.includes(g.grado))).sort((a, b) => a.orden - b.orden);
// Asignaturas que puede calificar el usuario: el docente solo las asignadas (null = todas las del grupo)
const asigsVis = g => { const m = isDoc() ? S.misAsig[g.id] : null; return m ? asigsDe(g).filter(a => m.includes(a.id)) : asigsDe(g); };
// Enlace de WhatsApp: número colombiano de 10 dígitos recibe el indicativo 57
function waLink(tel, txt) { let d = String(tel || '').replace(/\D/g, ''); if (d.length === 10) d = '57' + d; return `https://wa.me/${d}?text=${encodeURIComponent(txt)}`; }
const waBtn = (tel, txt, l = 'Enviar por WhatsApp') => `<a class="btn wa" href="${esc(waLink(tel, txt))}" target="_blank" rel="noopener">${l}</a>`;
const estsDe = gid => S.ests.filter(e => e.grupo_id === gid && e.estado === 'Activo').sort((a, b) => a.apellidos.localeCompare(b.apellidos, 'es'));
const periodos = () => S.k.periodos || [];
const escala = () => S.k.escala || [];
function gruposVis() {
  if (isDir()) return S.grupos;
  if (isDoc()) return S.grupos.filter(g => S.misGrupos.includes(g.id) || S.dirGrupos.includes(g.id));
  return [];
}
const propio = () => isFam() ? ctx.estudiante_id : null;

/* ---------- Cálculos académicos ---------- */
function notaRaw(e, a, p) { const v = S.notas[`${e}|${a}|${p}`]; return v == null ? null : +v; }
// Nota efectiva: si hay recuperación con nota, vale la mayor (Decreto 1290)
function nota(e, a, p) { const v = notaRaw(e, a, p), r = S.rec[`${e}|${a}|${p}`]; return r?.nota != null && (v == null || +r.nota > v) ? +r.nota : v; }
function defin(e, a, hasta) { let s = 0, w = 0; periodos().forEach(p => { if (hasta && p.n > hasta) return; const v = nota(e, a, p.n); if (v != null) { s += v * p.peso; w += p.peso; } }); return w ? Math.round(s / w) : null; }
function desem(v, esc) { if (v == null) return ''; const r = Math.round(+v); const x = [...(esc || escala())].sort((a, b) => b.min - a.min).find(s => r >= +s.min); return x ? x.d : 'Bajo'; }
// Escala de 0 a 100 en números enteros (decisión de Ricardo, 18 oct 2026)
const N = v => v == null ? '' : String(Math.round(+v));
function leerNota(raw) {
  const t = String(raw ?? '').trim().replace(',', '.');
  if (t === '') return { v: null };
  const n = Number(t);
  if (!isFinite(n) || n < 0 || n > 100) return { err: 'Escriba un número entero de 0 a 100' };
  return { v: Math.round(n) };
}
const NOTA_ATTR = 'type="number" inputmode="numeric" step="1" min="0" max="100"';
const chip = v => v == null ? '<span class="muted">Sin calificación</span>' : `<span class="d d-${desem(v)}">${N(v)} ${desem(v)}</span>`;
const porClase = () => !!S.k?.asistencia_por_clase;
function fallas(eid) { let n = 0; Object.entries(porClase() ? S.asisC : S.asis).forEach(([k, v]) => { if (k.split('|')[1] === eid && v === 'A') n++; }); return n; }
function fallasAsig(eid, aid) { let n = 0; Object.entries(S.asisC).forEach(([k, v]) => { const [, e, a] = k.split('|'); if (e === eid && a === aid && v === 'A') n++; }); return n; }
function promedio(eid, hasta) { const g = grupo(est(eid).grupo_id); const v = asigsDe(g).map(a => defin(eid, a.id, hasta)).filter(x => x != null); return v.length ? v.reduce((a, b) => a + b, 0) / v.length : null; }
function perdidas(eid) { const g = grupo(est(eid).grupo_id); if (!g || g.nivel === 'preescolar') return []; return asigsDe(g).filter(a => { const v = defin(eid, a.id); return v != null && desem(v) === 'Bajo'; }); }

/* =====================================================================
   Carga de datos
   ===================================================================== */
async function cargarColegio(intento = 0) {
  resetS();
  const c = ctx.colegio_id;
  const [k, grupos, asigs, ests] = await Promise.all([
    q(db.from('colegios').select('*').eq('id', c).single()),
    all(() => db.from('grupos').select('*').eq('colegio_id', c).order('grado').order('nombre')),
    all(() => db.from('asignaturas').select('*').eq('colegio_id', c).order('nivel').order('orden')),
    all(() => db.from('estudiantes').select('*').eq('colegio_id', c).order('apellidos').order('nombres').order('id')),
  ]);
  // Tras un rato sin uso, Neon puede tardar en responder la primera consulta: se reintenta.
  // Recién creado un perfil o renovada la demostración, la base puede tardar un momento en mostrar los cursos: se reintenta
  if (!k && intento < 4) { await new Promise(r => setTimeout(r, 1200)); return cargarColegio(intento + 1); }
  if (k && !grupos.length && intento < 3) {
    const r = await q(db.rpc('estado_colegio', { p_colegio: c })).catch(() => null);
    if (k.demo || +r?.activos > 0) { await new Promise(r2 => setTimeout(r2, 1500)); return cargarColegio(intento + 1); }
  }
  if (!k) throw new Error('No se pudo cargar el colegio. Intente de nuevo en unos segundos.');
  Object.assign(S, { k, grupos, asigs, ests });
  if (isDoc()) {
    const dg = await q(db.from('docente_grupos').select('grupo_id,asignatura_id').eq('miembro_id', ctx.id));
    S.misGrupos = [...new Set(dg.map(x => x.grupo_id))];
    S.misGrupos.forEach(g => { const l = dg.filter(x => x.grupo_id === g); S.misAsig[g] = l.some(x => !x.asignatura_id) ? null : l.map(x => x.asignatura_id); });
    S.dirGrupos = grupos.filter(g => g.director_miembro_id === ctx.id).map(g => g.id);
  }
  S.estado = await q(db.rpc('estado_colegio', { p_colegio: c })).catch(() => null);
  if (isFam()) { await cargarComs().catch(() => {}); S.fam = await q(db.rpc('mi_situacion_familia', { p_colegio: c })).catch(() => []); }
  if (isFam() || atiende() || manejaPagos()) await cargarNovedades();
}
async function cargarGrupo(gid, force) {
  if (!gid || (S.loadedG.has(gid) && !force)) return;
  const ids = S.ests.filter(e => e.grupo_id === gid).map(e => e.id);
  for (const part of chunks(ids, 60)) {
    const [ns, as, os] = await Promise.all([
      all(() => db.from('notas').select('estudiante_id,asignatura_id,periodo,valor').eq('anio', S.k.anio).in('estudiante_id', part).order('estudiante_id').order('asignatura_id').order('periodo')),
      all(() => db.from('asistencia').select('estudiante_id,fecha,estado').gte('fecha', `${S.k.anio}-01-01`).lte('fecha', `${S.k.anio}-12-31`).in('estudiante_id', part).order('estudiante_id').order('fecha')),
      all(() => db.from('observaciones').select('estudiante_id,periodo,texto').eq('anio', S.k.anio).in('estudiante_id', part).order('estudiante_id').order('periodo')),
    ]);
    ns.forEach(n => S.notas[`${n.estudiante_id}|${n.asignatura_id}|${n.periodo}`] = +n.valor);
    as.forEach(a => S.asis[`${a.fecha}|${a.estudiante_id}`] = a.estado);
    os.forEach(o => S.obs[`${o.estudiante_id}|${o.periodo}`] = o.texto);
    const [na, rc, ac] = await Promise.all([
      all(() => db.from('notas_act').select('actividad_id,estudiante_id,valor').in('estudiante_id', part).order('actividad_id').order('estudiante_id')).catch(() => []),
      all(() => db.from('recuperaciones').select('*').eq('anio', S.k.anio).in('estudiante_id', part).order('estudiante_id').order('asignatura_id').order('periodo')).catch(() => []),
      porClase() ? all(() => db.from('asistencia_clase').select('estudiante_id,asignatura_id,fecha,estado').gte('fecha', `${S.k.anio}-01-01`).lte('fecha', `${S.k.anio}-12-31`).in('estudiante_id', part).order('estudiante_id').order('fecha').order('asignatura_id')).catch(() => []) : [],
    ]);
    na.forEach(n => S.nact[`${n.actividad_id}|${n.estudiante_id}`] = +n.valor);
    rc.forEach(r => S.rec[`${r.estudiante_id}|${r.asignatura_id}|${r.periodo}`] = r);
    ac.forEach(a => S.asisC[`${a.fecha}|${a.estudiante_id}|${a.asignatura_id}`] = a.estado);
  }
  const acts = await all(() => db.from('actividades').select('*').eq('grupo_id', gid).eq('anio', S.k.anio).order('orden').order('creado_en')).catch(() => []);
  S.acts = S.acts.filter(x => x.grupo_id !== gid).concat(acts);
  const lg = await all(() => db.from('logros').select('asignatura_id,periodo,texto').eq('grupo_id', gid).eq('anio', S.k.anio).order('asignatura_id').order('periodo'));
  lg.forEach(x => S.logros[`${gid}|${x.asignatura_id}|${x.periodo}`] = x.texto);
  S.loadedG.add(gid);
}
async function cargarMiembros() {
  S.miembros = await all(() => db.from('miembros').select('*').eq('colegio_id', ctx.colegio_id).order('rol').order('nombre').order('id'));
  S.dg = await all(() => db.from('docente_grupos').select('*').eq('colegio_id', ctx.colegio_id).order('id'));
}

/* =====================================================================
   Acceso: iniciar sesión, crear cuenta, activar código
   ===================================================================== */
const SG_ICONO = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" aria-hidden="true"><rect x="4" y="4" width="192" height="192" rx="46" fill="#1E3A4C"/><g stroke="#FFFFFF" stroke-linecap="round"><polygon points="100,42 150.2,71 150.2,129 100,158 49.8,129 49.8,71" fill="none" stroke-opacity=".35" stroke-width="4"/><path d="M100 100L100 42M100 100L150.2 71M100 100L150.2 129M100 100L100 158M100 100L49.8 129M100 100L49.8 71" stroke-width="6"/></g><g fill="#FFFFFF"><circle cx="150.2" cy="71" r="10"/><circle cx="150.2" cy="129" r="10"/><circle cx="100" cy="158" r="10"/><circle cx="49.8" cy="129" r="10"/><circle cx="49.8" cy="71" r="10"/></g><circle cx="100" cy="42" r="13" fill="#E0A21A"/><circle cx="100" cy="100" r="20" fill="#E0A21A"/></svg>';
const SG_CORREO = 'contacto@skynetgenesis.com';
const sgFirma = (oscuro) => `<a class="sg-firma${oscuro ? ' oscuro' : ''}" href="https://skynetgenesis.com" target="_blank" rel="noopener"><span class="sg-ico">${SG_ICONO}</span><span>Una aplicación de<br><b class="sg-a">SKYNET</b> <b class="sg-b">GENESIS</b></span></a>`;
const SG_PIE = `<div class="pie-sg">${SG_ICONO}<span>Documento generado con Colegio-IA · <b>SkyNet Genesis</b> · ${SG_CORREO} · WhatsApp 304 437 5758</span></div>`;
const conPie = html => String(html).replace(/(<section class="doc[^"]*">[\s\S]*?)(<\/section>)/g, (m, a, b) => a.includes('pie-sg') ? m : a + SG_PIE + b);
const brand = `<div class="brand"><span class="brand-mark" aria-hidden="true"></span><span class="brand-txt"><span class="brand-name">Colegio-IA</span><span class="brand-sub">Instituciones Educativas</span></span></div>`;
let authMode = 'login';
function authScreen(extra) {
  document.body.classList.add('is-auth');
  $('#app').hidden = true; $('#auth').hidden = false;
  let body = '';
  if (authMode === 'login') body = `<h2>Iniciar sesión</h2>
    <form onsubmit="event.preventDefault();doLogin()">
      <label class="field"><span>Correo electrónico</span><input id="lEmail" type="email" autocomplete="username" required></label>
      <label class="field"><span>Contraseña</span><span class="pw"><input id="lPass" type="password" autocomplete="current-password" required>${ojo('lPass')}</span></label>
      <p class="err" id="aErr" role="alert"></p>
      <button class="btn" type="submit">Entrar</button>
    </form>
    <p class="muted" style="margin-top:14px">¿Primera vez? El colegio le entregó un código de activación. <button class="linkbtn" type="button" onclick="setAuth('registro')">Cree su cuenta</button></p>
    <div class="demo-box"><strong>¿Quiere conocer Colegio-IA?</strong><br><span class="muted">Pruebe gratis el colegio de demostración como directivo, docente, acudiente o estudiante.</span><br><button class="btn wa" type="button" onclick="quiereDemo()">Probar la demostración</button></div>`;
  if (authMode === 'registro') body = `<h2>${store.get('demo') ? 'Cree su cuenta para probar Colegio-IA' : 'Crear cuenta'}</h2>
    <p class="muted">${store.get('demo') ? 'Use su correo y una contraseña. No necesita código: después elige con qué perfil entrar al colegio de demostración.' : 'Use el mismo correo que registró el colegio. Después escribirá su código de activación.'}</p>
    <form onsubmit="event.preventDefault();doRegistro()">
      <label class="field"><span>Nombre y apellido</span><input id="rNom" autocomplete="name" required placeholder="Ejemplo: María Gómez"></label>
      <label class="field"><span>Correo electrónico</span><input id="rEmail" type="email" autocomplete="username" required></label>
      <label class="field"><span>Contraseña (mínimo 10 caracteres, con letras y números)</span><span class="pw"><input id="rPass" type="password" minlength="10" autocomplete="new-password" required>${ojo('rPass')}</span></label>
      <label class="field"><span>Repita la contraseña</span><span class="pw"><input id="rPass2" type="password" minlength="10" autocomplete="new-password" required>${ojo('rPass2')}</span></label>
      <p class="err" id="aErr" role="alert"></p>
      <button class="btn" type="submit">Crear cuenta</button>
    </form>
    <p class="muted" style="margin-top:14px">¿Ya tiene cuenta? <button class="linkbtn" type="button" onclick="setAuth('login')">Inicia sesión</button></p>`;
  const demoSel = `<div class="demo-box"><strong>Colegio de demostración</strong><br><span class="muted">Explore Colegio-IA con datos de ejemplo. Elija con qué perfil quiere entrar:</span>
      <div class="toolbar" style="margin:8px 0 0;justify-content:center"><button class="btn sm" type="button" onclick="entrarDemo('rector')">Rector(a)</button><button class="btn sm" type="button" onclick="entrarDemo('coordinador')">Coordinador(a)</button><button class="btn sm" type="button" onclick="entrarDemo('docente')">Docente</button><button class="btn sm" type="button" onclick="entrarDemo('acudiente')">Acudiente</button><button class="btn sm" type="button" onclick="entrarDemo('estudiante')">Estudiante</button></div></div>`;
  if (authMode === 'activar' && store.get('demo') && !ctxs.length) body = `<h2>Bienvenido(a)${me?.name ? ', ' + esc(me.name.split(' ')[0]) : ''}</h2>${demoSel}
    <p class="muted" style="margin-top:14px">¿El colegio le entregó un código? <button class="linkbtn" type="button" onclick="store.del('demo');setAuth('activar')">Escribir código de activación</button> · <button class="linkbtn" type="button" onclick="doLogout()">Cerrar sesión</button></p>`;
  else if (authMode === 'activar') body = `<h2>Active su acceso</h2>
    <p>Hola${me?.name ? ', ' + esc(me.name.split(' ')[0]) : ''}. Escriba el código de activación que le entregó el colegio.</p>
    ${extra || ''}
    <form onsubmit="event.preventDefault();doActivar()">
      <label class="field"><span>Código de activación</span><input id="aCod" autocomplete="one-time-code" style="text-transform:uppercase;letter-spacing:.1em" required></label>
      <p class="err" id="aErr" role="alert"></p>
      <button class="btn" type="submit">Activar</button>
    </form>
    ${demoSel}
    <p class="muted" style="margin-top:14px">Sesión: ${esc(me?.email || '')}.
      ${ctxs.length ? `<button class="linkbtn" type="button" onclick="volverApp()">Volver</button> ·` : ''}
      ${superadmin ? `<button class="linkbtn" type="button" onclick="irPlataforma()">Superadministrador</button> ·` : ''}
      <button class="linkbtn" type="button" onclick="doLogout()">Cerrar sesión</button></p>`;
  $('#auth').innerHTML = `<div class="auth-box">${brand}${body}<div class="auth-sg">${sgFirma()}</div></div>`;
  const f = $('#auth input'); if (f) f.focus();
}
function setAuth(m) { authMode = m; authScreen(); }
function quiereDemo() { store.set('demo', '1'); setAuth('registro'); }
async function entrarDemo(rol) {
  authErr('');
  await busy('#auth .demo-box .btn', async () => {
    try {
      $('#auth .demo-box').insertAdjacentHTML('beforeend', '<p class="muted" id="demoEsp">Preparando el colegio de demostración…</p>');
      const id = await q(db.rpc('entrar_demo', { p_rol: rol }));
      store.del('demo'); store.set('ctx', id); try { sessionStorage.removeItem('genesis:ir'); } catch {}
      authMode = 'login'; await arrancar();
    } catch (e) { $('#demoEsp')?.remove(); toast(msg(e)); }
  });
}
function authErr(t) { const e = $('#aErr'); if (e) e.textContent = t; }
function authMsg(e) {
  const c = (e?.code || '').toUpperCase(), m = e?.message || '';
  if (c.includes('INVALID_EMAIL_OR_PASSWORD') || /invalid (email|password)/i.test(m)) return 'Correo o contraseña incorrectos';
  if (c.includes('USER_ALREADY_EXISTS') || /already exists/i.test(m)) return 'Ya existe una cuenta con ese correo. Inicia sesión';
  if (c.includes('PASSWORD_TOO_SHORT')) return 'La contraseña debe tener al menos 8 caracteres';
  if (c.includes('INVALID_EMAIL')) return 'El correo no es válido';
  return msg(e);
}
async function busy(btnSel, fn) { const b = $(btnSel); if (b) { b.disabled = true; b.dataset.t = b.textContent; b.textContent = 'Un momento…'; } try { return await fn(); } finally { if (b) { b.disabled = false; b.textContent = b.dataset.t; } } }
async function doLogin() {
  authErr('');
  await busy('#auth .btn', async () => {
    try {
      const { error } = await db.auth.signIn.email({ email: $('#lEmail').value.trim(), password: $('#lPass').value });
      if (error) return authErr(authMsg(error));
      await arrancar();
    } catch (e) { authErr(authMsg(e)); }
  });
}
// Reglas de registro (revisión 18 oct 2026): nombre y apellido reales y contraseña de al menos 10 caracteres que no sea fácil de adivinar
function errNombre(n) {
  const p = n.trim().split(/\s+/).filter(x => x.length >= 2);
  if (p.length < 2 || n.trim().length < 6) return 'Escriba su nombre y su apellido';
  if (/\d/.test(n) || /(.)\1\1/i.test(n.replace(/\s/g, ''))) return 'Escriba su nombre real, sin números ni letras repetidas';
  return '';
}
function errClave(c, email) {
  if (c.length < 10) return 'La contraseña debe tener al menos 10 caracteres';
  if (!/[a-zñ]/i.test(c) || !/\d/.test(c)) return 'La contraseña debe tener letras y números';
  if (/^(.)\1+$/.test(c) || /(.)\1\1\1/.test(c)) return 'La contraseña no puede repetir el mismo carácter tantas veces';
  const sec = '0123456789 abcdefghijklmnopqrstuvwxyz qwertyuiopasdfghjklzxcvbnm', t = c.toLowerCase();
  for (let i = 0; i + 5 <= t.length; i++) { const w = t.slice(i, i + 5); if (sec.includes(w) || sec.includes([...w].reverse().join(''))) return 'La contraseña no puede tener secuencias como 12345 o abcde'; }
  if (email && t.includes(email.split('@')[0].toLowerCase())) return 'La contraseña no debe contener su correo';
  return '';
}
const ojo = id => `<button type="button" class="ojo" aria-label="Mostrar u ocultar la contraseña" onclick="const i=document.getElementById('${id}');i.type=i.type==='password'?'text':'password';this.textContent=i.type==='password'?'👁':'🙈'">👁</button>`;
async function doRegistro() {
  authErr('');
  const eN = errNombre($('#rNom').value); if (eN) return authErr(eN);
  const eC = errClave($('#rPass').value, $('#rEmail').value); if (eC) return authErr(eC);
  if ($('#rPass').value !== $('#rPass2').value) return authErr('Las contraseñas no coinciden');
  await busy('#auth .btn', async () => {
    try {
      const { error } = await db.auth.signUp.email({ name: $('#rNom').value.trim(), email: $('#rEmail').value.trim(), password: $('#rPass').value });
      if (error) return authErr(authMsg(error));
      authMode = 'activar'; await arrancar();
    } catch (e) { authErr(authMsg(e)); }
  });
}
async function doActivar() {
  authErr('');
  await busy('#auth .btn', async () => {
    try {
      const r = await q(db.rpc('activar_cuenta', { p_codigo: $('#aCod').value }));
      toast(`Acceso activado: ${ROL_TXT[r.rol]} en ${r.colegio}`);
      authMode = 'login'; await arrancar();
    } catch (e) { authErr(msg(e)); }
  });
}
async function doLogout() { try { await db.auth.signOut(); } catch { } me = null; ctx = null; ctxs = []; superadmin = false; store.del('ctx'); authMode = 'login'; authScreen(); }
function volverApp() { authMode = 'login'; if (ctx) { mostrarApp(); render(); } }

/* =====================================================================
   Arranque
   ===================================================================== */
async function arrancar() {
  let sess = null;
  try { const r = await db.auth.getSession(); sess = r?.data; } catch (e) { console.warn(e); }
  if (!sess?.user) { me = null; authMode = authMode === 'registro' ? 'registro' : 'login'; return authScreen(); }
  me = sess.user;
  superadmin = !!(await guard(() => q(db.rpc('soy_superadmin'))));
  ctxs = (await guard(() => all(() => db.from('miembros')
    .select('id,rol,colegio_id,estudiante_id,nombre,activo,colegios(nombre,ciudad),estudiantes(nombres,apellidos)')
    .eq('user_id', me.id).eq('activo', true).order('id')))) || [];
  ctxs = ctxs.filter(m => m.colegios);
  if (!ctxs.length) {
    if (superadmin && authMode !== 'activar') return irPlataforma();
    authMode = 'activar'; return authScreen();
  }
  if (authMode === 'activar') return authScreen();
  const saved = store.get('ctx');
  ctx = ctxs.find(m => m.id === saved) || ctxs[0];
  await entrarContexto(ctx.id);
}
function ctxLabel(m) {
  const base = `${m.colegios.nombre} · ${ROL_TXT[m.rol]}`;
  return m.estudiantes ? `${base} de ${m.estudiantes.nombres}` : base;
}
let cargaN = 0; // evita que una carga vieja pise a una más reciente
async function entrarContexto(id) {
  ctx = ctxs.find(m => m.id === id); if (!ctx) return;
  const n = ++cargaN;
  store.set('ctx', ctx.id); modo = 'colegio'; view = 'inicio'; Object.assign(sel, { g: '', a: '', p: 0, fecha: '', fg: '', q: '', panio: 0 });
  mostrarApp(); $('#view').innerHTML = '<div class="loading">Cargando datos del colegio…</div>';
  if (!superadmin) {
    const est = await q(db.rpc('estado_colegio', { p_colegio: ctx.colegio_id })).catch(() => null);
    if (n !== cargaN) return;
    if (est?.cobro === 'cerrada') { S.estado = est; return pantallaCerrada(); }
  }
  try { await cargarColegio(); } catch (e) { if (n !== cargaN) return; $('#view').innerHTML = `<div class="panel empty">${esc(msg(e))}</div>`; return; }
  if (n !== cargaN) return;
  let ir = 'inicio';
  try { ir = sessionStorage.getItem('genesis:ir') || 'inicio'; } catch {}
  if (!VIEWS.some(x => x.id === ir && x.ok())) ir = 'inicio';
  prepararAtras();
  await go(ir);
}
function irColegio() { entrarContexto((ctx || ctxs[0]).id); }
async function irPlataforma() { modo = 'plataforma'; view = 'plataforma'; mostrarApp(); await go('plataforma'); }
function mostrarApp() { $('#auth').hidden = true; $('#app').hidden = false; }

/* =====================================================================
   Navegación
   ===================================================================== */
const VIEWS = [
  { id: 'inicio', label: 'Inicio', ok: () => true, prep: prepInicio, fn: vInicio },
  { id: 'config', label: 'Parametrización', ok: () => isDir() || isTes(), prep: prepConfig, fn: vConfig },
  { id: 'estudiantes', label: 'Estudiantes y matrícula', ok: isDir, prep: prepEstudiantes, fn: vEstudiantes },
  { id: 'notas', label: 'Calificaciones', ok: () => isDir() || isDoc(), prep: prepGrupoSel, fn: vNotas },
  { id: 'asistencia', label: 'Asistencia', ok: () => isDir() || isDoc(), prep: prepGrupoSel, fn: vAsistencia },
  { id: 'boletines', label: 'Boletines', ok: () => !isTes(), prep: async () => { await prepGrupoSel(); if (propio()) await cargarFotoEst([propio()]); S.ret = new Set(isDir() && sel.g ? (await q(db.rpc('retenidos_grupo', { p_grupo: sel.g })).catch(() => [])).map(x => x.retenidos_grupo || x) : []); }, fn: vBoletines },
  { id: 'observador', label: 'Observador', ok: () => isDir() || isDoc() || isFam(), prep: prepObservador, fn: vObservador },
  { id: 'piar', label: 'PIAR e inclusión', ok: () => isDir() || isDoc() || isAcud(), prep: prepPiar, fn: vPiar },
  { id: 'comunicados', label: 'Comunicados', ok: () => true, prep: prepComunicados, fn: vComunicados, badge: () => isFam() ? noLeidos() : 0 },
  { id: 'mensajes', label: 'Mensajes', ok: () => isAcud() || atiende(), prep: prepMensajes, fn: vMensajes, badge: () => S.nov?.msg || 0 },
  { id: 'citas', label: 'Citas', ok: () => isAcud() || atiende(), prep: prepCitas, fn: vCitas, badge: () => S.nov?.citasPend || 0 },
  { id: 'autorizaciones', label: 'Autorizaciones', ok: () => isAcud() || isDir() || isDoc(), prep: prepAutorizaciones, fn: vAutorizaciones, badge: () => S.nov?.aut?.length || 0 },
  { id: 'cronograma', label: 'Cronograma', ok: () => true, prep: prepCronograma, fn: vCronograma },
  { id: 'galeria', label: 'Fotos de la semana', ok: () => !isTes(), prep: prepGaleria, fn: vGaleria },
  { id: 'horario', label: 'Horario', ok: () => isDir() || isDoc() || isFam(), prep: prepHorario, fn: vHorario },
  { id: 'excusas', label: 'Excusas', ok: () => isDir() || isDoc() || isAcud(), prep: prepExcusas, fn: vExcusas },
  { id: 'familia', label: 'Carnet y contactos', ok: isFam, prep: prepFamilia, fn: vFamilia },
  { id: 'contactos', label: 'Contactos y recogida', ok: () => isDir() || isDoc(), prep: prepContactos, fn: vContactos },
  { id: 'utiles', label: 'Lista de útiles', ok: () => !isTes(), prep: prepUtiles, fn: vUtiles },
  { id: 'tienda', label: 'Tienda del colegio', ok: () => isAcud() && !!S.k?.tienda_activa, prep: prepTienda, fn: vTienda, badge: () => S.nov?.pedidos || 0 },
  { id: 'campus', label: 'Campus virtual', ok: verCampus, prep: prepCampus, fn: vCampus, badge: () => isFam() ? S.camPend || 0 : 0 },
  { id: 'gemas', label: 'Gemas y ranking', ok: () => gemasOn() && verCampus(), prep: prepGemas, fn: vGemas },
  { id: 'academico', label: 'Informes académicos', ok: () => isDir() || (isDoc() && S.dirGrupos.length > 0), prep: prepAcademico, fn: vAcademico },
  { id: 'pagos', label: 'Pagos y cartera', ok: manejaPagos, prep: prepPagos, fn: vPagos },
  { id: 'cuenta', label: 'Estado de cuenta', ok: isAcud, prep: prepCuenta, fn: vCuenta },
  { id: 'pedidos', label: 'Tienda y pedidos', ok: manejaPagos, prep: prepPedidos, fn: vPedidos, badge: () => S.nov?.pedidosStaff || 0 },
  { id: 'usuarios', label: 'Usuarios y accesos', ok: isDir, prep: cargarMiembros, fn: vUsuarios },
];
// Menú lateral por secciones (regla general: nada de listas largas grises)
const MENU = [
  { t: '', ids: ['inicio'] },
  { t: 'Académico', c: 'azul', ids: ['notas', 'asistencia', 'boletines', 'observador', 'piar', 'academico', 'horario', 'utiles'] },
  { t: 'Campus virtual', c: 'violeta', ids: ['campus', 'gemas'] },
  { t: 'Comunicación', c: 'verde', ids: ['comunicados', 'mensajes', 'citas', 'autorizaciones', 'cronograma', 'galeria'] },
  { t: 'Estudiantes y familias', c: 'teal', ids: ['estudiantes', 'familia', 'contactos', 'excusas'] },
  { t: 'Pagos y tienda', c: 'ambar', ids: ['pagos', 'cuenta', 'tienda', 'pedidos'] },
  { t: 'Administración', c: 'gris', ids: ['config', 'usuarios'] },
];
const ICO = { campus: '💻', gemas: '💎', inicio: '🏠', notas: '✏️', asistencia: '✅', boletines: '📄', observador: '📝', piar: '🧩', academico: '📊', horario: '🕒', utiles: '🎒', comunicados: '📢', mensajes: '💬', citas: '📅', autorizaciones: '✍️', cronograma: '🗓️', galeria: '📷', estudiantes: '🎓', familia: '🪪', contactos: '📇', excusas: '📩', pagos: '💰', cuenta: '💳', tienda: '🛍️', pedidos: '📦', config: '⚙️', usuarios: '👥' };
// Familias con pagos pendientes: solo inicio, comunicados y estado de cuenta (decisión del 18 oct 2026)
const PERMITIDAS_MOROSO = ['inicio', 'comunicados', 'cuenta'];
// El estudiante con pagos pendientes queda bloqueado por completo (solo ve el aviso del inicio)
const restringida = id => modo === 'colegio' && isFam() && !alDia() && (isEst() ? id !== 'inicio' : !PERMITIDAS_MOROSO.includes(id));
const visible = v => v.ok() && !restringida(v.id);
let menuCerr = {}; try { menuCerr = JSON.parse(localStorage.getItem('micolegia:menu') || '{}'); } catch {}
function toggleSec(t) { menuCerr[t] = !menuCerr[t]; try { localStorage.setItem('micolegia:menu', JSON.stringify(menuCerr)); } catch {} renderSide(); }
function menuHTML() {
  return MENU.map(sec => {
    const vs = sec.ids.map(id => VIEWS.find(v => v.id === id)).filter(v => v && visible(v)); if (!vs.length) return '';
    const activa = vs.some(v => v.id === view), cerr = sec.t && menuCerr[sec.t] && !activa;
    const bad = vs.reduce((a, v) => a + (v.badge ? +v.badge() || 0 : 0), 0);
    const items = vs.map(v => `<button type="button" class="nav-it" ${v.id === view ? 'aria-current="page"' : ''} onclick="go('${v.id}')"><span class="nav-ico" aria-hidden="true">${ICO[v.id] || '•'}</span><span class="nav-tx">${v.label}</span>${v.badge && v.badge() ? `<span class="badge">${v.badge()}</span>` : ''}</button>`).join('');
    return sec.t ? `<div class="nav-sec sec-${sec.c}"><button type="button" class="nav-h" aria-expanded="${!cerr}" onclick="toggleSec('${sec.t}')"><span>${sec.t}</span>${cerr && bad ? `<span class="badge">${bad}</span>` : ''}<span class="nav-fl" aria-hidden="true">${cerr ? '▸' : '▾'}</span></button>${cerr ? '' : `<div class="nav-g">${items}</div>`}</div>` : items;
  }).join('');
}
const VIEW_PLAT = { id: 'plataforma', label: 'Colegios', prep: prepPlataforma, fn: vPlataforma };

function barraDemo() {
  const roles = [['rector', 'Rector(a)'], ['coordinador', 'Coordinador(a)'], ['docente', 'Docente'], ['acudiente', 'Acudiente'], ['estudiante', 'Estudiante']];
  return `<div class="note demo-bar"><strong>Colegio de demostración.</strong> Los datos son de ejemplo y se restauran cada día. Usted está como <strong>${ROL_TXT[ctx.rol]}</strong>: ${ROL_DESC[ctx.rol] || ''}
    <div class="toolbar" style="margin:8px 0 0"><span class="muted">Cambiar de perfil:</span>${roles.filter(([r]) => r !== ctx.rol).map(([r, l]) => `<button class="btn ghost sm" type="button" onclick="cambiarPerfilDemo('${r}')">${l}</button>`).join('')}</div></div>`;
}
async function cambiarPerfilDemo(rol) {
  const m = ctxs.find(x => x.colegio_id === ctx.colegio_id && x.rol === rol);
  try { sessionStorage.setItem('genesis:ir', 'inicio'); } catch {}
  if (m) return entrarContexto(m.id);
  $('#view').innerHTML = '<div class="loading">Preparando el perfil…</div>';
  const id = await guard(() => q(db.rpc('entrar_demo', { p_rol: rol })));
  if (id) { store.set('ctx', id); await arrancar(); } else render();
}
// Familias: hijos del mismo colegio y si están al día
const hermanos = () => ctxs.filter(m => m.colegio_id === ctx.colegio_id && (m.rol === 'acudiente' || m.rol === 'estudiante') && m.estudiante_id);
const alDia = (eid = propio()) => (S.fam || []).find(x => x.estudiante_id === eid)?.al_dia !== false;
function barraHijos() {
  const h = hermanos(); if (h.length < 2) return '';
  return `<div class="hijos" role="tablist" aria-label="Sus hijos"><span class="muted">${ctx.rol === 'estudiante' ? 'Perfil' : 'Sus hijos'}:</span>${h.map(m => `<button type="button" role="tab" aria-selected="${m.id === ctx.id}" onclick="entrarContexto('${m.id}')">${esc(m.estudiantes?.nombres || 'Estudiante')}</button>`).join('')}</div>`;
}
function avisoRestringido() {
  if (isEst()) return `<div class="panel restringido"><h2>Su acceso está suspendido en este momento</h2>
    <p>Pídale a su acudiente que se comunique con la secretaría del colegio. Apenas se resuelva, podrá volver a entrar a su campus virtual.</p></div>`;
  return `<div class="panel restringido"><h2>El acceso de la familia está limitado en este momento</h2>
    <p>Para más información, comuníquese con la secretaría del colegio.</p>
    <p class="muted">Mientras tanto puede consultar el estado de cuenta y los comunicados del colegio.</p>
    <div class="toolbar"><button class="btn" type="button" onclick="go('cuenta')">Ver estado de cuenta</button><button class="btn ghost" type="button" onclick="go('comunicados')">Ver comunicados</button></div></div>`;
}
function quien() { return `${ROL_TXT[ctx.rol]}: ${ctx.nombre}`; }
function renderSide() {
  const side = $('#nav');
  if (modo === 'plataforma') {
    $('#ctxBox').innerHTML = `<div class="who">Superadministrador</div>`;
    side.innerHTML = `<button type="button" aria-current="page">Colegios${platComps.length ? `<span class="badge">${platComps.length}</span>` : ''}</button>`;
  } else {
    $('#ctxBox').innerHTML = ctxs.length > 1
      ? `<label class="role"><span class="muted" style="font-size:.85rem">Colegio y perfil</span><select class="ctx" onchange="entrarContexto(this.value)">${ctxs.map(m => opt(m.id, ctxLabel(m), ctx.id)).join('')}</select></label>`
      : `<div class="who">${S?.k?.logo ? `<img src="${S.k.logo}" alt="" style="max-height:48px;max-width:120px;display:block;margin-bottom:6px">` : ''}<strong>${esc(ctx.colegios.nombre)}</strong><br><span class="rol-chip rol-${ctx.rol}">${ROL_TXT[ctx.rol]}</span> ${esc(ctx.nombre || '')}</div>`;
    side.innerHTML = menuHTML();
  }
  $('#foot').innerHTML = `${esc(me?.email || '')}<br>
    ${modo === 'plataforma' && ctxs.length ? `<button class="btn ghost sm" type="button" onclick="irColegio()">Ir a mi colegio</button>` : ''}
    ${modo === 'colegio' && superadmin ? `<button class="btn ghost sm" type="button" onclick="irPlataforma()">Superadministrador</button>` : ''}
    <button class="btn ghost sm" type="button" onclick="setAuth('activar')">Agregar otro código</button>
    <button class="btn ghost sm" type="button" onclick="doLogout()">Cerrar sesión</button>
    <div style="margin-top:10px">${sgFirma()}</div><div style="margin-top:6px">Colegio-IA v${VERSION}</div>`;
}
// Barra superior fija en todas las pantallas: volver al inicio, ver y cambiar de perfil, y salir
function barraSup() {
  const per = ctx.estudiantes && isFam() ? `${ROL_TXT[ctx.rol]}${isEst() ? ':' : ' de'} ${esc(est(propio())?.nombres || ctx.estudiantes.nombres)}` : ROL_TXT[ctx.rol];
  return `<div class="topbar tb-rol-${ctx.rol}">
    ${view !== 'inicio' ? `<button class="btn ghost sm tb-volver" type="button" onclick="volver()" title="Volver a la pantalla anterior">← Volver</button>` : ''}
    <button class="btn ghost sm" type="button" onclick="go('inicio')" ${view === 'inicio' ? 'aria-current="page"' : ''}>Inicio</button>
    ${isFam() || atiende() || manejaPagos() ? `<button class="btn ghost sm tb-avisos" type="button" onclick="verAvisos()" title="Avisos" aria-label="Avisos"><span aria-hidden="true">🔔</span>${totalNov() ? `<span class="badge">${totalNov()}</span>` : ''}</button>` : ''}
    <button class="btn ghost sm tb-perfil" type="button" onclick="elegirPerfil()" title="Cambiar de perfil o de colegio"><span class="muted tb-l">Usted está como</span> <span class="rol-chip rol-${ctx.rol}">${per}</span><span class="tb-l">${S?.k?.demo ? ' <span class="tag">Demostración</span>' : ''}</span> <span aria-hidden="true">▾</span></button>
    <button class="btn ghost sm tb-salir" type="button" onclick="salirApp()"><span class="tb-l">${S?.k?.demo ? 'Salir de la demostración' : 'Cerrar sesión'}</span><span class="tb-s">Salir</span></button></div>`;
}
function elegirPerfil() {
  const demo = S?.k?.demo, rolesDemo = [['rector', 'Rector(a)'], ['coordinador', 'Coordinador(a)'], ['docente', 'Docente'], ['acudiente', 'Acudiente']];
  const ORD = Object.keys(ROL_TXT), propios = ctxs.slice().sort((a, b) => a.colegios.nombre.localeCompare(b.colegios.nombre) || ORD.indexOf(a.rol) - ORD.indexOf(b.rol) || (a.estudiantes?.nombres || '').localeCompare(b.estudiantes?.nombres || ''));
  const faltan = demo ? rolesDemo.filter(([r]) => !ctxs.some(m => m.colegio_id === ctx.colegio_id && m.rol === r)) : [];
  openModal('Cambiar de perfil', `<p class="muted">Elija con qué perfil quiere trabajar. Puede volver a cambiarlo cuando quiera desde la barra de arriba.</p>
    <div class="perfiles">${propios.map(m => `<button type="button" class="perfil ${m.id === ctx.id ? 'act' : ''}" onclick="closeModal();entrarContexto('${m.id}')"><strong>${esc(ROL_TXT[m.rol])}${m.estudiantes ? ' de ' + esc(m.estudiantes.nombres) : ''}</strong><span>${esc(m.colegios.nombre)}${m.id === ctx.id ? ' · perfil actual' : ''}</span></button>`).join('')}
      ${faltan.map(([r, l]) => `<button type="button" class="perfil" onclick="closeModal();cambiarPerfilDemo('${r}')"><strong>${l}</strong><span>Colegio de demostración</span></button>`).join('')}
      ${superadmin ? `<button type="button" class="perfil" onclick="closeModal();irPlataforma()"><strong>Superadministrador</strong><span>Panel de la plataforma Colegio-IA</span></button>` : ''}</div>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal();setAuth('activar')">Tengo un código de otro colegio</button><button class="btn ghost" type="button" onclick="closeModal();salirApp()">${demo ? 'Salir de la demostración' : 'Cerrar sesión'}</button></div>`);
}
async function salirApp() {
  if (S?.k?.demo) { const real = ctxs.find(m => m.colegio_id !== ctx.colegio_id); return real ? entrarContexto(real.id) : setAuth('activar'); }
  if (await confirmar('¿Cerrar sesión?')) doLogout();
}
function render() {
  renderSide();
  const v = modo === 'plataforma' ? VIEW_PLAT : (VIEWS.find(x => x.id === view && visible(x)) || VIEWS[0]);
  try { $('#view').innerHTML = v.fn(); } catch (e) { console.error(e); $('#view').innerHTML = `<div class="panel empty">${esc(msg(e))}</div>`; }
  if (modo === 'colegio' && S?.k?.demo && view === 'inicio') $('#view').insertAdjacentHTML('afterbegin', barraDemo());
  if (modo === 'colegio' && isFam()) $('#view').insertAdjacentHTML('afterbegin', barraHijos());
  if (modo === 'colegio' && S?.estado?.cobro === 'aviso' && (isDir() || isTes())) $('#view').insertAdjacentHTML('afterbegin', avisoCobro());
  if (modo === 'colegio' && ctx) $('#view').insertAdjacentHTML('afterbegin', barraSup());
  if (v.id === 'estudiantes') drawEst();
}
/* ---------- Sesión: evita mostrar datos vacíos cuando la sesión venció ---------- */
const VENCE_MS = 10 * 60 * 1000;
let ultimaActividad = Date.now();
const sesionVieja = () => Date.now() - ultimaActividad > VENCE_MS;
function recargarEn(v) { try { sessionStorage.setItem('genesis:ir', v || view); } catch {} location.reload(); }
// Al volver después de un rato no se recarga la página (eso obligaba a iniciar sesión otra vez en algunos celulares):
// se confirma la sesión y se actualizan los datos de la pantalla. Solo si la sesión ya no existe se vuelve a la entrada.
async function sesionViva() { try { const r = await db.auth.getSession(); return !!r?.data?.user; } catch { return false; } }
document.addEventListener('visibilitychange', async () => {
  if (document.hidden || !ctx || !sesionVieja()) return;
  if (!(await sesionViva())) return recargarEn(view);
  ultimaActividad = Date.now(); if (modo === 'colegio') { navAtras = true; go(view); }
});
setInterval(async () => {
  if (document.hidden || !ctx || sesionVieja()) return;
  try { await db.auth.getSession(); ultimaActividad = Date.now(); } catch {}
}, 4 * 60 * 1000);
// Botón "atrás" del celular o del navegador: cierra la ventana abierta o vuelve a la pantalla anterior, sin salir de la app
let navAtras = false;
// En la primera pantalla hay una entrada "base": al llegar a ella se avisa y solo un segundo "atrás" seguido sale de la app.
let atrasBase = 0, baseLista = false;
function prepararAtras() {
  if (baseLista) return; baseLista = true;
  history.replaceState({ v: '__base' }, ''); history.pushState({ v: view }, '');
}
window.addEventListener('popstate', e => {
  if (!$('#modal').hidden) { closeModal(); history.pushState({ v: view }, ''); return; }
  const side = document.querySelector('.side.open'); if (side) { side.classList.remove('open'); history.pushState({ v: view }, ''); return; }
  if (e.state?.v === '__base') {
    if (Date.now() - atrasBase < 2500) { history.back(); return; }
    atrasBase = Date.now(); history.pushState({ v: view }, '');
    if (modo === 'colegio' && ctx && view !== 'inicio') { navAtras = true; go('inicio'); history.replaceState({ v: 'inicio' }, ''); }
    else toast('Oprima "atrás" otra vez para salir de Colegio-IA');
    return;
  }
  if (modo !== 'colegio' || !ctx) return;
  const v = e.state?.v || 'inicio';
  if (v !== view) { navAtras = true; go(v); }
  if (!e.state) history.pushState({ v: 'inicio' }, '');
});
const pila = [];
function volver() { pila.pop(); const v = pila.pop() || 'inicio'; navAtras = true; go(v); }
async function go(v) {
  if (ctx && sesionVieja() && !(await sesionViva())) return recargarEn(v);
  if (modo === 'colegio' && pila[pila.length - 1] !== v) { pila.push(v); if (pila.length > 30) pila.shift(); }
  ultimaActividad = Date.now();
  if (modo === 'colegio') { if (!navAtras && history.state?.v !== v) history.pushState({ v }, ''); navAtras = false; }
  if (modo === 'colegio') { view = v; try { sessionStorage.setItem('genesis:ir', v); } catch {} }
  document.querySelector('.side')?.classList.remove('open');
  const def = modo === 'plataforma' ? VIEW_PLAT : VIEWS.find(x => x.id === v);
  renderSide();
  $('#view').innerHTML = '<div class="loading">Cargando…</div>';
  if (def?.prep) await guard(def.prep);
  render(); window.scrollTo(0, 0);
}
async function refrescar(prep) { await guard(prep || (() => cargarGrupo(sel.g, true))); render(); }

/* =====================================================================
   Inicio
   ===================================================================== */
let resumen = null;
async function prepInicio() {
  resumen = null;
  if (isTes()) { await prepPagos(); await cargarNovedades(); return; }
  if (isDir()) {
    resumen = await q(db.rpc('resumen_colegio', { p_colegio: ctx.colegio_id }))
      .catch(async () => { await new Promise(r => setTimeout(r, 1500)); return q(db.rpc('resumen_colegio', { p_colegio: ctx.colegio_id })); });
    S.susc = await q(db.rpc('mi_suscripcion', { p_colegio: ctx.colegio_id })).catch(() => null);
  }
  if (isDoc()) { for (const g of gruposVis()) await cargarGrupo(g.id); }
  if (isFam()) { const e = est(propio()); if (e) await cargarGrupo(e.grupo_id).catch(() => {}); await prepCampusInicio(); }
  if (isFam() || atiende() || manejaPagos()) await cargarNovedades();
}
function vInicio() {
  const pa = S.k.periodo_actual;
  if (isTes()) {
    const c = cartera || [], venc = c.reduce((a, x) => a + +x.saldo_vencido, 0), pag = c.reduce((a, x) => a + +x.pagado, 0);
    return head(`Buen día, ${esc(ctx.nombre.split(' ')[0])}`, `${esc(S.k.nombre)}. Cartera del año ${S.k.anio}.`) +
      `<div class="stats"><div class="stat"><div class="n">${cop(pag)}</div><div class="l">Recaudado en el año</div></div>
       <div class="stat"><div class="n">${cop(venc)}</div><div class="l">Saldo vencido</div></div>
       <div class="stat"><div class="n">${c.filter(x => +x.saldo_vencido > 0).length}</div><div class="l">Estudiantes en mora</div></div></div>
       <div class="toolbar"><button class="btn" type="button" onclick="go('pagos')">Ir a pagos y cartera</button><button class="btn ghost" type="button" onclick="go('pedidos')">Tienda y pedidos${S.nov?.pedidosStaff ? ` (${S.nov.pedidosStaff} por atender)` : ''}</button></div>`;
  }
  if (isFam() && !alDia()) return head(`Hola, ${esc((ctx.nombre || '').split(' ')[0])}`, esc(S.k.nombre)) + avisoRestringido() + redesHTML();
  if (isDir()) {
    const r = resumen || {}; const pct = r.esperadas ? Math.round(r.registradas / r.esperadas * 100) : 0;
    return head(`Buen día, ${esc(ctx.nombre.split(' ')[0])}`, `${esc(S.k.nombre)}. Año lectivo ${S.k.anio}, periodo ${pa} en curso.`) +
      `<div class="stats">
        <div class="stat"><div class="n">${r.activos ?? 0}</div><div class="l">Estudiantes activos</div></div>
        <div class="stat"><div class="n">${r.grupos ?? 0}</div><div class="l">Grupos</div></div>
        <div class="stat"><div class="n">${pct}%</div><div class="l">Calificaciones del periodo ${pa} registradas</div><div class="bar"><i style="width:${pct}%"></i></div></div>
        <div class="stat"><div class="n">${r.piar ?? 0}</div><div class="l">Estudiantes con PIAR</div></div>
      </div>
      ${avisoCierre()}
      ${!S.grupos.length ? `<div class="note"><strong>Primeros pasos.</strong> 1) Revise los datos del colegio en Parametrización. 2) Cree los grupos. 3) Matricula estudiantes. 4) Invita a docentes y acudientes desde Usuarios y accesos.</div>` : ''}
      <div class="cols">
        <section class="panel"><h2>Estudiantes en riesgo académico</h2>
          ${r.riesgo?.length ? `<ul class="list">${r.riesgo.map(x => `<li><strong>${esc(x.nombre)}</strong>, ${esc(x.grupo)}<br><span class="muted">En bajo: ${x.asignaturas.map(esc).join(', ')}</span></li>`).join('')}</ul>` : `<p class="muted">Ningún estudiante alcanza ${S.k.max_perdidas} o más asignaturas en bajo.</p>`}
        </section>
        <section class="panel"><h2>Su suscripción</h2>${panelSuscripcion(r)}        </section>
      </div>`;
  }
  if (isDoc()) {
    const gs = gruposVis();
    return head(`Hola, ${esc(ctx.nombre.split(' ')[0])}`, `Periodo ${pa} en curso. ${gs.length ? 'Estos son sus grupos.' : ''}`) + avisoCierre() +
      (gs.length ? `<div class="cols">${gs.map(g => {
        const es = estsDe(g.id), as = asigsVis(g); let t = 0, r = 0; es.forEach(e => as.forEach(a => { t++; if (nota(e.id, a.id, pa) != null) r++; })); const pc = t ? Math.round(r / t * 100) : 0;
        return `<section class="panel"><h2>${esc(g.nombre)}</h2><p class="muted">${es.length} estudiantes, ${as.length} ${g.nivel === 'preescolar' ? 'dimensiones' : 'asignaturas'}</p>
          <p>Calificaciones del periodo ${pa}: ${r} de ${t}</p><div class="bar"><i style="width:${pc}%"></i></div>
          <div class="toolbar" style="margin-top:14px"><button class="btn sm" type="button" onclick="sel.g='${g.id}';sel.a='';go('notas')">Registrar calificaciones</button><button class="btn ghost sm" type="button" onclick="sel.g='${g.id}';go('asistencia')">Tomar asistencia</button></div></section>`;
      }).join('')}</div>` : '<div class="panel empty">Aún no tiene grupos asignados. Pida a coordinación que se los asigne.</div>') + redesHTML();
  }
  const e = est(propio());
  if (!e) return head('Inicio') + '<div class="panel empty">No encontramos la información del estudiante.</div>';
  const g = grupo(e.grupo_id);
  if (!g) return head(`Hola`, '') + '<div class="panel empty">El estudiante aún no tiene grupo asignado.</div>';
  const pr = promedio(e.id), pe = perdidas(e.id);
  return head(ctx.rol === 'acudiente' ? `Seguimiento de ${esc(e.nombres)}` : `Hola, ${esc(e.nombres)}`, `${esc(g.nombre)}. Director(a) de grupo: ${esc(g.director_nombre || 'sin asignar')}.`) + hoyFamilia() + campusInicioHTML() +
    `<div class="stats">
      <div class="stat"><div class="n">${g.nivel === 'preescolar' ? 'Cualitativa' : pr == null ? '—' : N(pr)}</div><div class="l">${g.nivel === 'preescolar' ? 'Valoración por dimensiones' : 'Promedio acumulado' + (pr == null ? '' : ', ' + desem(pr))}</div></div>
      <div class="stat"><div class="n">${pe.length}</div><div class="l">Asignaturas en bajo</div></div>
      <div class="stat"><div class="n">${fallas(e.id)}</div><div class="l">${porClase() ? 'Fallas (horas de clase)' : 'Fallas registradas'} · <button class="linkbtn" type="button" onclick="detalleFallas('${e.id}')">Ver fechas</button></div></div>
    </div>
    ${noLeidos() ? `<div class="note">Tiene <strong>${noLeidos()}</strong> ${noLeidos() === 1 ? 'comunicado sin leer' : 'comunicados sin leer'}. <button class="linkbtn" type="button" onclick="go('comunicados')">Ver comunicados</button></div>` : ''}

    <section class="panel"><h2>Calificaciones por ${g.nivel === 'preescolar' ? 'dimensión' : 'asignatura'}</h2><div class="tbl"><table><thead><tr><th>${g.nivel === 'preescolar' ? 'Dimensión' : 'Asignatura'}</th><th>Acumulado</th><th></th></tr></thead><tbody>
    ${asigsDe(g).map(a => { const d = defin(e.id, a.id); return `<tr><td>${esc(a.nombre)}${porClase() && fallasAsig(e.id, a.id) ? ` <span class="muted">(${fallasAsig(e.id, a.id)} fallas)</span>` : ''}</td><td>${g.nivel === 'preescolar' ? (d == null ? '<span class="muted">Sin valorar</span>' : desem(d)) : chip(d)}</td><td><button class="linkbtn" type="button" onclick="detalleAsig('${a.id}')">Ver detalle</button></td></tr>`; }).join('')}</tbody></table></div>
    <div class="toolbar" style="margin-top:12px"><button class="btn sm" type="button" onclick="go('boletines')">Ver boletín</button></div></section>${redesHTML()}`;
}

/* =====================================================================
   Estudiantes y matrícula (directivos)
   ===================================================================== */
async function prepEstudiantes() {
  contEst = {};
  await cargarMiembros();
  S.acud = await all(() => db.from('acudientes').select('*').eq('colegio_id', ctx.colegio_id).order('orden'));
}
const acudDe = eid => (S.acud || []).filter(a => a.estudiante_id === eid).sort((a, b) => a.orden - b.orden);
function vEstudiantes() {
  const act = S.ests.filter(e => e.estado === 'Activo');
  return head('Estudiantes y matrícula', 'Matricula, consulta y retira estudiantes. Cada matrícula recibe folio automático.',
    `<div class="toolbar" style="margin:0"><button class="btn ghost" type="button" onclick="exportarEstudiantes()" ${S.ests.length ? '' : 'disabled'}>Exportar a Excel</button><button class="btn ghost" type="button" onclick="libroMatricula()" ${S.ests.length ? '' : 'disabled'}>Libro de matrícula</button><button class="btn" type="button" onclick="formEst()" ${S.grupos.length ? '' : 'disabled title="Primero crea los grupos en Parametrización"'}>Matricular estudiante</button></div>`) +
    (S.grupos.length ? '' : '<div class="note">Antes de matricular, crea los grupos en <button class="linkbtn" type="button" onclick="go(\'config\')">Parametrización</button>.</div>') +
    `<div class="panel"><div class="toolbar">
      <label class="field"><span>Grupo</span><select onchange="sel.fg=this.value;drawEst()"><option value="">Todos</option>${S.grupos.map(g => opt(g.id, g.nombre, sel.fg)).join('')}</select></label>
      <label class="field"><span>Estado</span><select onchange="sel.fe=this.value;drawEst()">${['Activo', 'Retirado', 'Graduado', ''].map(x => opt(x, x || 'Todos', sel.fe ?? 'Activo')).join('')}</select></label>
      <label class="field"><span>Buscar</span><input type="search" value="${esc(sel.q)}" placeholder="Nombre o documento" oninput="sel.q=this.value;drawEst()"></label>
      <span class="muted" style="margin-left:auto">${act.length} activos</span></div>
      <div class="tbl" id="estTbl"></div></div>`;
}
function familiaDe(eid) { return (S.miembros || []).filter(m => m.estudiante_id === eid); }
function drawEst() {
  const qq = sel.q.toLowerCase().trim(), fe = sel.fe ?? 'Activo';
  const l = S.ests.filter(e => (!sel.fg || e.grupo_id === sel.fg) && (!fe || e.estado === fe) && (!qq || nom(e).toLowerCase().includes(qq) || e.doc.includes(qq))).sort((a, b) => a.folio - b.folio);
  $('#estTbl').innerHTML = l.length ? `<table><thead><tr><th>Folio</th><th>Estudiante</th><th>Documento</th><th>Grupo</th><th>Acudiente</th><th>Accesos</th><th>Estado</th><th></th></tr></thead><tbody>
  ${l.map(e => {
    const fam = familiaDe(e.id), a1 = acudDe(e.id)[0];
    return `<tr class="${e.estado === 'Activo' ? '' : 'dim'}"><td>${e.folio}</td><td><strong>${esc(e.apellidos)}</strong> ${esc(e.nombres)} ${e.piar ? '<span class="tag piar">PIAR</span>' : ''}${e.recomendaciones_medicas ? ' <span class="tag t2" title="' + esc(e.recomendaciones_medicas) + '">Salud</span>' : ''}${e.estado === 'Activo' && !e.autoriza_datos ? ' <span class="tag t3" title="Falta la autorización de tratamiento de datos (Ley 1581)">Sin autorización de datos</span>' : ''}</td><td>${e.tipo_doc} ${esc(e.doc)}</td><td>${esc(grupo(e.grupo_id)?.nombre || '—')}</td>
    <td>${esc(a1?.nombres || e.acudiente_nombre || '')}<br><span class="muted">${esc(a1?.telefono || e.acudiente_tel || '')}</span></td>
    <td>${fam.map(m => `<span class="tag" title="${esc(m.email)}">${ROL_TXT[m.rol]}${m.user_id ? '' : ' pendiente'}</span>`).join(' ')} <button class="btn ghost sm" type="button" onclick="formFamilia('${e.id}')">Invitar</button></td>
    <td>${e.estado}${e.fecha_retiro ? `<br><span class="muted">${fmtF(e.fecha_retiro)}</span>` : ''}</td>
    <td><select class="acc" aria-label="Acciones" onchange="accionEst('${e.id}',this.value);this.value=''"><option value="">Acciones…</option>
      <option value="editar">Editar ficha</option><option value="hoja">Hoja de matrícula</option><option value="constancia">Constancia de estudio</option>
      <option value="certificado">Constancia con calificaciones</option><option value="anteriores">Certificados de años anteriores</option>${e.estado === 'Activo' ? '<option value="retirar">Registrar retiro</option>' : '<option value="reactivar">Reactivar</option>'}</select></td></tr>`;
  }).join('')}</tbody></table>` : '<div class="empty">No hay estudiantes con ese filtro.</div>';
}
async function accionEst(id, a) {
  if (a === 'editar') return formEst(id);
  if (['hoja', 'constancia', 'certificado'].includes(a) && !(await guard(async () => { await prepDocsEst([id], a === 'hoja'); return true; }))) return;
  if (a === 'hoja') return showDocs(hojaMatricula(id), 'Hoja de matrícula', nomArchivo('Hoja de matrícula', est(id)));
  if (a === 'constancia') return showDocs(constancia(id), 'Constancia de estudio', nomArchivo('Constancia de estudio', est(id)));
  if (a === 'certificado') { const e = est(id); await guard(() => cargarGrupo(e.grupo_id)); return showDocs(certificado(id), 'Constancia con calificaciones', nomArchivo('Constancia con calificaciones', est(id))); }
  if (a === 'anteriores') return certAnteriores(id);
  if (a === 'retirar') return formRetiro(id);
  if (a === 'reactivar') return reactivar(id);
}

/* ---------- Ficha de matrícula (datos del SIMAT) ---------- */
const TIPOS_DOC = ['RC', 'NUIP', 'TI', 'CC', 'CE', 'PPT', 'PEP'];
const LISTAS = {
  sexo: ['', 'Femenino', 'Masculino'], rh: ['', 'O+', 'O-', 'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-'],
  zona: ['', 'Urbana', 'Rural'], estrato: ['', '1', '2', '3', '4', '5', '6', 'Sin estrato'],
  jornada: ['Mañana', 'Tarde', 'Única', 'Completa', 'Nocturna', 'Fin de semana'],
  situacion: ['Nuevo', 'Antiguo', 'Promovido', 'Repitente', 'Transferido'],
  etnia: ['No aplica', 'Afrocolombiano', 'Indígena', 'Raizal', 'Palenquero', 'Rom (gitano)'],
  discapacidad: ['No aplica', 'Física', 'Auditiva', 'Visual', 'Sordoceguera', 'Intelectual', 'Psicosocial', 'Múltiple', 'Trastorno del espectro autista', 'Otra'],
  capacidades: ['No aplica', 'Capacidades excepcionales', 'Talento excepcional'],
  parentesco: ['Madre', 'Padre', 'Abuela', 'Abuelo', 'Tía', 'Tío', 'Hermana', 'Hermano', 'Tutor legal', 'Otro'],
};
const fIn = (id, l, v, extra = '') => `<label class="field"><span>${l}</span><input id="${id}" value="${esc(v ?? '')}" ${extra}></label>`;
const fSel = (id, l, lista, v) => `<label class="field"><span>${l}</span><select id="${id}">${lista.map(x => opt(x, x || '—', v ?? '')).join('')}</select></label>`;
const fTa = (id, l, v, ph = '') => `<label class="field full"><span>${l}</span><textarea id="${id}" placeholder="${esc(ph)}">${esc(v ?? '')}</textarea></label>`;
function filaAcud(a, i) {
  return `<fieldset class="acud" data-id="${a.id || ''}" style="border:1px solid var(--line);border-radius:8px;padding:10px 12px;margin:0 0 10px">
    <legend style="padding:0 6px;font-weight:700">Acudiente ${i + 1}</legend><div class="formgrid">
    <label class="field"><span>Parentesco</span><select class="aPar">${LISTAS.parentesco.map(x => opt(x, x, a.parentesco || (i ? 'Padre' : 'Madre'))).join('')}</select></label>
    <label class="field"><span>Nombres y apellidos</span><input class="aNom" value="${esc(a.nombres || '')}"></label>
    <label class="field"><span>Tipo de documento</span><select class="aTd">${['CC', 'CE', 'PPT', 'PEP', 'Pasaporte'].map(x => opt(x, x, a.tipo_doc || 'CC')).join('')}</select></label>
    <label class="field"><span>Número de documento</span><input class="aDoc" inputmode="numeric" value="${esc(a.doc || '')}"></label>
    <label class="field"><span>Teléfono</span><input class="aTel" inputmode="tel" value="${esc(a.telefono || '')}"></label>
    <label class="field"><span>Correo electrónico</span><input class="aEmail" type="email" value="${esc(a.email || '')}"></label>
    <label class="field"><span>Dirección</span><input class="aDir" value="${esc(a.direccion || '')}"></label>
    <label class="field"><span>Ocupación</span><input class="aOcu" value="${esc(a.ocupacion || '')}"></label>
    <label class="field chk"><input type="checkbox" class="aResp" ${a.responsable_pago ? 'checked' : ''}> Responsable de pagos</label>
    </div></fieldset>`;
}
function formEst(id) {
  const e = id ? est(id) : { tipo_doc: 'TI', grupo_id: sel.fg || S.grupos[0]?.id, jornada: 'Mañana', situacion: 'Nuevo', pais_origen: 'Colombia', fecha_matricula: hoy(), piar: false };
  const ac = id ? acudDe(id) : [];
  if (id && !ac.length && e.acudiente_nombre) ac.push({ nombres: e.acudiente_nombre, telefono: e.acudiente_tel || '', responsable_pago: true });
  while (ac.length < 2) ac.push({});
  openModal(id ? `Ficha de ${nom(e)}` : 'Matricular estudiante', `
    <h3>Datos del estudiante</h3><div class="formgrid">
      ${fIn('fNom', 'Nombres', e.nombres)}${fIn('fApe', 'Apellidos', e.apellidos)}
      <label class="field"><span>Tipo de documento</span><select id="fTd">${TIPOS_DOC.map(t => opt(t, t, e.tipo_doc)).join('')}</select></label>
      ${fIn('fDoc', 'Número de documento', e.doc, 'inputmode="numeric"')}${fIn('fExp', 'Lugar de expedición', e.lugar_expedicion)}
      ${fIn('fNac', 'Fecha de nacimiento', e.fnac, 'type="date"')}${fIn('fLNac', 'Lugar de nacimiento', e.lugar_nacimiento)}
      ${fSel('fSexo', 'Sexo', LISTAS.sexo, e.sexo)}${fIn('fPais', 'País de origen', e.pais_origen)}
      ${fIn('fDir', 'Dirección de residencia', e.direccion)}${fIn('fBar', 'Barrio', e.barrio)}${fIn('fMun', 'Municipio', e.municipio)}
      ${fSel('fZona', 'Zona', LISTAS.zona, e.zona)}${fSel('fEstr', 'Estrato', LISTAS.estrato, e.estrato)}
      ${fIn('fTel', 'Teléfono del estudiante', e.telefono, 'inputmode="tel"')}${fIn('fEmail', 'Correo del estudiante', e.email, 'type="email"')}
      ${fSel('fEtnia', 'Grupo étnico', LISTAS.etnia, e.etnia || 'No aplica')}
      <label class="field chk"><input id="fVict" type="checkbox" ${e.victima_conflicto ? 'checked' : ''}> Víctima del conflicto armado</label>
    </div>
    <h3 style="margin-top:14px">Salud e inclusión</h3><div class="formgrid">
      ${fIn('fEps', 'EPS o entidad de salud', e.eps)}${fSel('fRh', 'Grupo sanguíneo y RH', LISTAS.rh, e.rh)}${fIn('fSis', 'SISBÉN (grupo)', e.sisben)}
      ${fSel('fDisc', 'Discapacidad', LISTAS.discapacidad, e.discapacidad || 'No aplica')}${fSel('fCap', 'Capacidades o talentos excepcionales', LISTAS.capacidades, e.capacidades_excepcionales || 'No aplica')}
      ${fTa('fCond', 'Condición especial', e.condicion_especial, 'Diagnóstico o condición que requiera apoyos. Solo lo ven directivos y docentes del grupo.')}
      <label class="field full chk"><input id="fPiar" type="checkbox" ${e.piar ? 'checked' : ''}> Requiere PIAR (Decreto 1421 de 2017)</label>
      ${fTa('fMed', 'Recomendaciones médicas especiales', e.recomendaciones_medicas, 'Alergias, medicamentos, restricciones, qué hacer en caso de emergencia.')}
    </div>
    <h3 style="margin-top:14px">Matrícula</h3><div class="formgrid">
      <label class="field"><span>Curso</span><select id="fGr">${S.grupos.map(g => opt(g.id, g.nombre, e.grupo_id)).join('')}</select></label>
      ${fSel('fJor', 'Jornada', LISTAS.jornada, e.jornada)}${fSel('fSit', 'Situación', LISTAS.situacion, e.situacion)}
      ${fIn('fFMat', 'Fecha de matrícula', e.fecha_matricula, 'type="date"')}${fIn('fProc', 'Institución de procedencia', e.institucion_procedencia)}
    </div>
    <h3 style="margin-top:14px">Acudientes</h3><div id="acudBox">${ac.map(filaAcud).join('')}</div>
    <button class="btn ghost sm" type="button" onclick="agregarAcud()">Agregar otro acudiente</button>
    <h3 style="margin-top:14px">Autorización de datos personales</h3>
    <p class="muted" style="margin:0 0 8px">Ley 1581 de 2012 y Decreto 1377 de 2013. El acudiente debe firmar esta autorización en la hoja de matrícula.</p>
    <div class="formgrid">
      <label class="field full chk"><input id="fAut" type="checkbox" ${e.autoriza_datos ? 'checked' : ''}> El acudiente autoriza el tratamiento de los datos personales del estudiante, incluidos los datos de salud, para fines académicos, administrativos y de bienestar.</label>
      <label class="field full chk"><input id="fImg" type="checkbox" ${e.autoriza_imagen ? 'checked' : ''}> Autoriza el uso de la imagen del estudiante en fotos y videos institucionales.</label>
      ${fIn('fAutPor', 'Nombre de quien autoriza', e.autoriza_por || ac[0]?.nombres || '')}${fIn('fAutFec', 'Fecha de la autorización', e.autoriza_fecha || hoy(), 'type="date"')}
    </div>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" onclick="guardarEst('${id || ''}')">${id ? 'Guardar cambios' : 'Matricular'}</button></div>`);
}
function agregarAcud() { const b = $('#acudBox'); b.insertAdjacentHTML('beforeend', filaAcud({}, b.children.length)); }
const vv = id => { const el = $('#' + id); return el ? (el.type === 'checkbox' ? el.checked : el.value.trim()) : null; };
async function guardarEst(id) {
  const d = {
    nombres: vv('fNom'), apellidos: vv('fApe'), tipo_doc: vv('fTd'), doc: vv('fDoc'), lugar_expedicion: vv('fExp'), fnac: vv('fNac') || null,
    lugar_nacimiento: vv('fLNac'), sexo: vv('fSexo'), pais_origen: vv('fPais'), direccion: vv('fDir'), barrio: vv('fBar'), municipio: vv('fMun'),
    zona: vv('fZona'), estrato: vv('fEstr'), telefono: vv('fTel'), email: vv('fEmail'), etnia: vv('fEtnia'), victima_conflicto: vv('fVict'),
    eps: vv('fEps'), rh: vv('fRh'), sisben: vv('fSis'), discapacidad: vv('fDisc'), capacidades_excepcionales: vv('fCap'),
    condicion_especial: vv('fCond'), piar: vv('fPiar'), recomendaciones_medicas: vv('fMed'),
    grupo_id: vv('fGr'), jornada: vv('fJor'), situacion: vv('fSit'), fecha_matricula: vv('fFMat') || null, institucion_procedencia: vv('fProc'),
    autoriza_datos: vv('fAut'), autoriza_imagen: vv('fImg'), autoriza_por: vv('fAutPor'), autoriza_fecha: vv('fAutFec') || null,
  };
  if (!d.nombres || !d.apellidos || !d.doc) return toast('Escriba nombres, apellidos y documento del estudiante');
  const acs = [...document.querySelectorAll('#acudBox .acud')].map((f, i) => ({
    id: f.dataset.id || null, orden: i + 1, parentesco: f.querySelector('.aPar').value, nombres: f.querySelector('.aNom').value.trim(),
    tipo_doc: f.querySelector('.aTd').value, doc: f.querySelector('.aDoc').value.trim(), telefono: f.querySelector('.aTel').value.trim(),
    email: f.querySelector('.aEmail').value.trim(), direccion: f.querySelector('.aDir').value.trim(), ocupacion: f.querySelector('.aOcu').value.trim(),
    responsable_pago: f.querySelector('.aResp').checked }));
  if (!acs.some(a => a.nombres)) return toast('Registre al menos un acudiente');
  const a1 = acs.find(a => a.nombres);
  d.acudiente_nombre = a1.nombres; d.acudiente_tel = a1.telefono;
  const r = await guard(async () => {
    const e = id ? await q(db.from('estudiantes').update(d).eq('id', id).select().single())
                 : await q(db.from('estudiantes').insert({ ...d, colegio_id: ctx.colegio_id }).select().single());
    for (const a of acs) {
      const { id: aid, ...datos } = a;
      if (!a.nombres) { if (aid) await q(db.from('acudientes').delete().eq('id', aid)); continue; }
      if (aid) await q(db.from('acudientes').update(datos).eq('id', aid));
      else await q(db.from('acudientes').insert({ ...datos, estudiante_id: e.id, colegio_id: ctx.colegio_id }));
    }
    return e;
  }, id ? 'Ficha actualizada' : 'Estudiante matriculado');
  if (!r) return;
  if (id) Object.assign(est(id), r); else S.ests.push(r);
  S.acud = await all(() => db.from('acudientes').select('*').eq('colegio_id', ctx.colegio_id).order('orden'));
  closeModal(); render();
}
function formRetiro(id) {
  const e = est(id);
  openModal(`Retiro de ${nom(e)}`, `<p>Desde el mes siguiente a la fecha de retiro el sistema deja de generarle cobros. Su historial y sus pagos se conservan.</p>
    <div class="formgrid">${fIn('rFec', 'Fecha de retiro', hoy(), 'type="date"')}
    <label class="field"><span>Motivo</span><select id="rMot">${['Traslado a otra institución', 'Cambio de ciudad', 'Motivos económicos', 'Motivos de salud', 'Deserción', 'Decisión de la familia', 'Otro'].map(x => opt(x, x)).join('')}</select></label>
    ${fTa('rObs', 'Observaciones', '')}</div>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn warn" type="button" onclick="guardarRetiro('${id}')">Registrar retiro</button></div>`);
}
async function guardarRetiro(id) {
  const obs = vv('rObs');
  const d = { estado: 'Retirado', fecha_retiro: vv('rFec') || hoy(), motivo_retiro: vv('rMot') + (obs ? `. ${obs}` : '') };
  const r = await guard(() => q(db.from('estudiantes').update(d).eq('id', id).select().single()), 'Retiro registrado');
  if (r) { Object.assign(est(id), r); closeModal(); drawEst(); }
}
async function reactivar(id) {
  if (!await confirmar('¿Reactivar la matrícula de este estudiante? Se volverán a generar sus cobros.')) return;
  const r = await guard(() => q(db.from('estudiantes').update({ estado: 'Activo', fecha_retiro: null, motivo_retiro: null }).eq('id', id).select().single()), 'Estudiante reactivado');
  if (r) { Object.assign(est(id), r); drawEst(); }
}
async function toggleRetiro(id) { const e = est(id); return e.estado === 'Activo' ? formRetiro(id) : reactivar(id); }

function formFamilia(eid) {
  const e = est(eid), fam = familiaDe(eid);
  openModal(`Accesos de ${nom(e)}`, `
    ${fam.length ? `<ul class="list">${fam.map(m => filaAcceso(m)).join('')}</ul>` : '<p class="muted">Aún no hay accesos para este estudiante.</p>'}
    <h3 style="margin-top:16px">Invitar</h3>
    <div class="formgrid">
      <label class="field"><span>Perfil</span><select id="iRol">${opt('acudiente', 'Acudiente')}${opt('estudiante', 'Estudiante')}</select></label>
      <label class="field"><span>Nombre</span><input id="iNom" value="${esc(e.acudiente_nombre || '')}"></label>
      <label class="field"><span>Correo electrónico</span><input id="iEmail" type="email"></label>
    </div>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cerrar</button><button class="btn" type="button" onclick="invitar('${eid}')">Crear invitación</button></div>`);
}
async function invitar(eid) {
  const d = { colegio_id: ctx.colegio_id, rol: eid ? $('#iRol').value : $('#uRol').value, nombre: (eid ? $('#iNom') : $('#uNom')).value.trim(), email: (eid ? $('#iEmail') : $('#uEmail')).value.trim(), estudiante_id: eid || null };
  if (!d.nombre || !/^\S+@\S+\.\S+$/.test(d.email)) return toast('Escriba el nombre y un correo válido');
  const m = await guard(() => q(db.from('miembros').insert(d).select().single()), 'Invitación creada');
  if (!m) return;
  S.miembros.push(m);
  openModal('Invitación lista', `<p>Entrega este mensaje a <strong>${esc(m.nombre)}</strong> por WhatsApp o correo:</p>
    <textarea id="invTxt" readonly style="min-height:150px">${esc(textoInvitacion(m))}</textarea>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal();render()">Cerrar</button><button class="btn ghost" type="button" onclick="copiar('#invTxt')">Copiar mensaje</button>${waBtn(telDe(m), textoInvitacion(m))}</div>`);
}
// Teléfono para WhatsApp: el del acudiente con el mismo nombre, o el primero del estudiante
function telDe(m) {
  if (!m.estudiante_id) return '';
  const l = (S.acud || []).filter(a => a.estudiante_id === m.estudiante_id);
  const a = l.find(x => (x.nombres || '').toLowerCase() === (m.nombre || '').toLowerCase()) || l[0];
  return a?.telefono || est(m.estudiante_id)?.acudiente_tel || '';
}
function textoInvitacion(m) {
  const url = location.origin + location.pathname;
  return `Hola, ${m.nombre}. ${S.k.nombre} le da acceso a Colegio-IA como ${ROL_TXT[m.rol].toLowerCase()}.\n\n1. Entre a ${url}\n2. Elija "Cree su cuenta" y regístrese con este correo: ${m.email}\n3. Escriba el código de activación: ${m.codigo}\n\nEl código es personal; no lo compartas.`;
}
async function copiar(s) { const t = $(s); try { await navigator.clipboard.writeText(t.value); toast('Mensaje copiado'); } catch { t.select(); document.execCommand('copy'); toast('Mensaje copiado'); } }
const ROLES_DIRECTIVOS = ['rector', 'coordinador', 'secretaria', 'tesoreria'];
// Solo el rector(a) maneja usuarios directivos; coordinación y secretaría manejan docentes y familias
const puedeManejar = m => esRector() || !ROLES_DIRECTIVOS.includes(m.rol);
function filaAcceso(m, extra) {
  return `<li style="display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap;align-items:center">
    <span><strong>${esc(m.nombre)}</strong> <span class="tag">${ROL_TXT[m.rol]}</span> ${m.activo ? '' : '<span class="tag t3">Inactivo</span>'}<br>
    <span class="muted">${esc(m.email)} · ${m.user_id ? 'Cuenta activa' : `Pendiente, código <span class="code">${esc(m.codigo)}</span>`}</span>${extra || ''}</span>
    <span style="white-space:nowrap">${!puedeManejar(m) ? '<span class="muted">Solo el rector(a) lo modifica</span>' : `${m.user_id ? '' : `<button class="btn ghost sm" type="button" onclick="verInvitacion('${m.id}')">Mensaje</button> `}<button class="btn ghost sm" type="button" onclick="nuevoCodigo('${m.id}')">Nuevo código</button> ${m.user_id === me?.id ? '' : `<button class="btn ghost sm" type="button" onclick="toggleMiembro('${m.id}')">${m.activo ? 'Desactivar' : 'Activar'}</button>`}`}</span></li>`;
}
function verInvitacion(id) {
  const m = S.miembros.find(x => x.id === id);
  openModal('Invitación', `<textarea id="invTxt" readonly style="min-height:150px">${esc(textoInvitacion(m))}</textarea>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cerrar</button><button class="btn ghost" type="button" onclick="copiar('#invTxt')">Copiar mensaje</button>${waBtn(telDe(m), textoInvitacion(m))}</div>`);
}
async function nuevoCodigo(id) {
  const m = S.miembros.find(x => x.id === id);
  if (m.user_id && !await confirmar(`${m.nombre} ya activó su cuenta. Un código nuevo desvincula su acceso actual hasta que lo vuelva a activar. ¿Continuar?`)) return;
  const c = await guard(() => q(db.rpc('regenerar_codigo', { p_miembro: id })), 'Código nuevo generado');
  if (c) { m.codigo = c; m.user_id = null; verInvitacion(id); }
}
async function toggleMiembro(id) {
  const m = S.miembros.find(x => x.id === id);
  if (m.user_id === me.id && m.activo) return toast('No puede desactivar su propio acceso');
  const r = await guard(() => q(db.from('miembros').update({ activo: !m.activo }).eq('id', id).select().single()), m.activo ? 'Acceso desactivado' : 'Acceso activado');
  if (r) { Object.assign(m, r); closeModal(); render(); }
}

/* =====================================================================
   Usuarios y accesos (directivos)
   ===================================================================== */
function vUsuarios() {
  const staff = S.miembros.filter(m => !m.estudiante_id);
  const fam = S.miembros.filter(m => m.estudiante_id);
  return head('Usuarios y accesos', 'Invita a directivos y docentes. Las familias se invitan desde Estudiantes y matrícula.', `<button class="btn" type="button" onclick="formUsuario()">Invitar usuario</button>`) +
    `<div class="panel"><h2>Directivos y docentes</h2>${staff.length ? `<ul class="list">${staff.map(m => filaAcceso(m, m.rol === 'docente' ? `<br><span class="muted">Grupos: ${[...new Set(S.dg.filter(d => d.miembro_id === m.id).map(d => d.grupo_id))].map(g => `${esc(grupo(g)?.nombre)} (${esc(asigsDocTxt(m.id, g))})`).join('; ') || 'ninguno'}</span> <button class="linkbtn" type="button" onclick="formGruposDoc('${m.id}')">Asignar grupos y asignaturas</button>` : '')).join('')}</ul>` : '<p class="muted">Sin usuarios.</p>'}</div>
    <div class="panel"><h2>Familias y estudiantes</h2><p>${fam.filter(m => m.user_id).length} cuentas activas y ${fam.filter(m => !m.user_id).length} invitaciones pendientes.</p></div>`;
}
function formUsuario() {
  openModal('Invitar usuario', `<div class="formgrid">
    <label class="field"><span>Perfil</span><select id="uRol">${(esRector() ? ['docente', 'coordinador', 'secretaria', 'tesoreria', 'rector'] : ['docente']).map(r => opt(r, ROL_TXT[r])).join('')}</select></label>
    <label class="field"><span>Nombre completo</span><input id="uNom"></label>
    <label class="field"><span>Correo electrónico</span><input id="uEmail" type="email"></label></div>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" onclick="invitar(null)">Crear invitación</button></div>`);
}
function asigsDocTxt(mid, gid) {
  const l = S.dg.filter(d => d.miembro_id === mid && d.grupo_id === gid);
  if (l.some(d => !d.asignatura_id)) return 'todas';
  return l.map(d => S.asigs.find(a => a.id === d.asignatura_id)?.nombre).filter(Boolean).join(', ');
}
function formGruposDoc(mid) {
  const m = S.miembros.find(x => x.id === mid), mios = S.dg.filter(d => d.miembro_id === mid);
  const tiene = (g, a) => mios.some(d => d.grupo_id === g && (a ? d.asignatura_id === a : !d.asignatura_id));
  openModal(`Grupos y asignaturas de ${m.nombre}`, S.grupos.length ? `<p class="muted">Marque "Todas" si el docente dicta todas las asignaturas del grupo, o elija solo las que dicta.</p>
    ${S.grupos.map(g => `<fieldset style="border:1px solid var(--line);border-radius:8px;padding:8px 12px;margin:0 0 10px"><legend style="padding:0 6px;font-weight:700">${esc(g.nombre)}</legend>
      <div class="toolbar" style="gap:6px 14px"><label class="chk"><input type="checkbox" class="gAll" data-g="${g.id}" ${tiene(g.id) ? 'checked' : ''}> Todas</label>
      ${asigsDe(g).map(a => `<label class="chk"><input type="checkbox" class="gAsig" data-g="${g.id}" value="${a.id}" ${tiene(g.id, a.id) ? 'checked' : ''}> ${esc(a.nombre)}</label>`).join('')}</div></fieldset>`).join('')}
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" onclick="guardarGruposDoc('${mid}')">Guardar</button></div>` : '<p class="muted">Primero crea grupos en Parametrización.</p>');
}
async function guardarGruposDoc(mid) {
  const filas = [];
  S.grupos.forEach(g => {
    if (document.querySelector(`.gAll[data-g="${g.id}"]`)?.checked) filas.push({ miembro_id: mid, grupo_id: g.id, asignatura_id: null, colegio_id: ctx.colegio_id });
    else document.querySelectorAll(`.gAsig[data-g="${g.id}"]:checked`).forEach(c => filas.push({ miembro_id: mid, grupo_id: g.id, asignatura_id: c.value, colegio_id: ctx.colegio_id }));
  });
  const ok = await guard(async () => {
    await q(db.from('docente_grupos').delete().eq('miembro_id', mid));
    if (filas.length) await q(db.from('docente_grupos').insert(filas));
    return true;
  }, 'Asignación guardada');
  if (ok) { await cargarMiembros(); closeModal(); render(); }
}

/* =====================================================================
   Calificaciones
   ===================================================================== */
async function prepGrupoSel() {
  if (isFam()) { const e = est(propio()); if (e) await cargarGrupo(e.grupo_id); return; }
  const gs = gruposVis(); if (!gs.length) return;
  if (!sel.g || !gs.find(g => g.id === sel.g)) sel.g = gs[0].id;
  await cargarGrupo(sel.g);
}
async function cambiarGrupo(g) { sel.g = g; sel.a = ''; $('#view').innerHTML = '<div class="loading">Cargando…</div>'; await guard(() => cargarGrupo(g)); render(); }
const perOpts = s => periodos().map(p => opt(p.n, 'Periodo ' + p.n, s)).join('');
function sinGrupos() { return `<div class="panel empty">${isDir() ? 'Aún no hay grupos. Créalos en Parametrización.' : 'No tiene grupos asignados.'}</div>`; }
const cierreDe = p => periodos().find(x => x.n === +p)?.cierre || '';
const cerrado = p => !isDir() && !!cierreDe(p) && hoy() > cierreDe(p);
const selGrupoHTML = gs => `<label class="field"><span>Grupo</span><select onchange="cambiarGrupo(this.value)">${gs.map(x => opt(x.id, x.nombre, sel.g)).join('')}</select></label>`;
const actsDe = (g, a, p) => S.acts.filter(x => x.grupo_id === g && x.asignatura_id === a && x.periodo === +p).sort((x, y) => x.orden - y.orden || String(x.creado_en).localeCompare(String(y.creado_en)));
function calcActs(eid, acts) {
  // Promedio simple de las actividades calificadas, sin porcentajes
  let n = 0, t = 0;
  acts.forEach(a => { const v = S.nact[`${a.id}|${eid}`]; if (v == null) return; t += +v; n++; });
  return n ? Math.round(t / n) : null;
}
function vNotas() {
  const gs = gruposVis(); if (!gs.length) return head('Calificaciones') + sinGrupos();
  const g = grupo(sel.g); if (!sel.p) sel.p = S.k.periodo_actual;
  if (isDoc() && !S.misGrupos.includes(g.id)) {
    return head('Calificaciones', 'Usted es director(a) de este grupo: puede consultar todas las calificaciones. Cada docente registra las de su asignatura.') +
      `<div class="panel"><div class="toolbar">${selGrupoHTML(gs)}<label class="field"><span>Periodo</span><select onchange="sel.p=+this.value;render()">${perOpts(sel.p)}</select></label></div>${planillaHTML(g, sel.p)}</div>`;
  }
  const as = asigsVis(g); if (!as.length) return head('Calificaciones') + `<div class="panel empty">${isDoc() ? 'No tiene asignaturas asignadas en este grupo.' : 'No hay asignaturas para este nivel. Agrégalas en Parametrización.'}</div>`;
  if (!as.find(a => a.id === sel.a)) sel.a = as[0].id;
  const pre = g.nivel === 'preescolar', es = estsDe(g.id); const reg = es.filter(e => notaRaw(e.id, sel.a, sel.p) != null).length;
  const cerr = cerrado(sel.p), dis = cerr ? 'disabled' : '', ci = cierreDe(sel.p);
  const acts = pre ? [] : actsDe(g.id, sel.a, sel.p), conAct = !pre && (acts.length > 0 || sel.modoAct);
  const aviso = cerr ? `<div class="note">El periodo ${sel.p} se cerró el ${fmtF(ci)}. Si necesita corregir una calificación, solicítelo a coordinación.</div>`
    : ci ? `<p class="muted" style="margin:0 0 8px">Fecha límite para registrar calificaciones del periodo ${sel.p}: <strong>${fmtF(ci)}</strong>.</p>` : '';
  const modoBtns = pre ? '' : `<div class="seg" role="group" aria-label="Forma de calificar"><button type="button" aria-pressed="${!conAct}" onclick="sel.modoAct=false;render()" ${acts.length ? 'disabled title="Hay actividades creadas: la calificación del periodo se calcula con ellas"' : ''}>Calificación directa</button><button type="button" aria-pressed="${conAct}" onclick="sel.modoAct=true;render()">Por actividades</button></div>`;
  let tabla = '';
  if (!es.length) tabla = '<div class="empty">Este grupo no tiene estudiantes activos.</div>';
  else if (conAct) {
    tabla = `<div class="toolbar"><button class="btn sm" type="button" onclick="formActividad()" ${dis}>+ Agregar actividad</button>
      <span class="muted">Cree las actividades que quiera (talleres, tareas, evaluaciones). La calificación del periodo es el <strong>promedio</strong> de las actividades calificadas, sin porcentajes.</span></div>
    ${acts.length ? `<div class="tbl"><table class="planilla"><thead><tr><th>Estudiante</th>${acts.map(a => `<th><button class="linkbtn" type="button" onclick="formActividad('${a.id}')" title="${a.campus ? 'Viene del campus virtual' : 'Cambiar nombre o fecha'}">${a.campus ? '💻 ' : ''}${esc(a.nombre)}</button>${a.fecha ? `<br><span class="muted">${fmtF(a.fecha).slice(0, 5)}</span>` : ''}${a.campus ? '<br><span class="muted" style="font-size:.8rem">Del campus</span>' : dis ? '' : `<br><button class="linkbtn malo" type="button" onclick="borrarActividad('${a.id}')" title="Borrar esta actividad">Borrar</button>`}</th>`).join('')}<th>Periodo ${sel.p}</th><th>Acumulado</th><th>Estado</th><th></th></tr></thead><tbody>
    ${es.map(e => `<tr><td>${esc(e.apellidos)} ${esc(e.nombres)}</td>${acts.map(a => { const v = S.nact[`${a.id}|${e.id}`]; return `<td><input class="actnota" ${NOTA_ATTR} value="${N(v)}" aria-label="${esc(a.nombre)} de ${esc(nom(e))}" onchange="setNotaAct('${a.id}','${e.id}',this)" ${a.campus ? 'disabled title="Se califica en el campus virtual"' : dis}></td>`; }).join('')}
      <td id="pn-${e.id}">${chip(notaRaw(e.id, sel.a, sel.p))}</td><td id="ac-${e.id}">${chip(defin(e.id, sel.a))}</td><td id="st-${e.id}">${estadoCal(e.id)}</td><td>${recBtn(e.id)}</td></tr>`).join('')}</tbody></table></div>` : ''}`;
  } else {
    const ps = periodos(), txt = x => x == null ? '—' : pre ? desem(x) : N(x);
    tabla = `<div class="tbl"><table class="califs"><thead><tr><th>Estudiante</th>${ps.map(p => `<th class="num ${p.n === sel.p ? 'actual' : ''}">${p.n === sel.p ? `Periodo ${p.n}<br><small>calificando</small>` : `P${p.n}`}</th>`).join('')}<th class="num">${pre ? '' : 'Acumulado'}</th><th>Estado</th>${pre ? '' : '<th></th>'}</tr></thead><tbody>
    ${es.map(e => {
      const v = notaRaw(e.id, sel.a, sel.p);
      const cell = pre ? `<select aria-label="Desempeño de ${esc(nom(e))}" onchange="setNotaPre('${e.id}',this)" ${dis}><option value="">Sin valorar</option>${Object.keys(PRE_VAL).map(d => opt(d, d, v == null ? '' : desem(v))).join('')}</select>`
        : `<input ${NOTA_ATTR} value="${N(v)}" aria-label="Calificación de ${esc(nom(e))}" onchange="setNota('${e.id}',this)" ${dis}>`;
      return `<tr><td>${esc(e.apellidos)} ${esc(e.nombres)} ${e.piar ? '<span class="tag piar">PIAR</span>' : ''}</td>${ps.map(p => p.n === sel.p ? `<td class="num actual">${cell}</td>` : `<td class="num">${txt(nota(e.id, sel.a, p.n))}</td>`).join('')}<td class="num" id="ac-${e.id}">${pre ? '' : chip(defin(e.id, sel.a))}</td><td id="st-${e.id}">${estadoCal(e.id)}</td>${pre ? '' : `<td>${recBtn(e.id)}</td>`}</tr>`;
    }).join('')}</tbody></table></div>`;
  }
  return head('Calificaciones', pre ? 'Preescolar se valora de forma cualitativa por dimensiones.' : 'Escala de 0 a 100, sin decimales. Cada calificación se guarda sola al salir de la casilla.') +
    `<div class="panel"><div class="toolbar">${selGrupoHTML(gs)}
      <label class="field"><span>${pre ? 'Dimensión' : 'Asignatura'}</span><select onchange="sel.a=this.value;render()">${as.map(a => opt(a.id, a.nombre, sel.a)).join('')}</select></label>
      <label class="field periodo-sel"><span>Periodo que está calificando</span><select onchange="sel.p=+this.value;render();toast('Mostrando las calificaciones del periodo '+sel.p)">${perOpts(sel.p)}</select></label>
      ${modoBtns}
      <span class="muted" style="margin-left:auto"><strong id="regN">${reg}</strong> de ${es.length} con calificación en el periodo ${sel.p}</span></div>
    ${aviso}${tabla}</div>
    <section class="panel logros-box"><h2>Logros del periodo ${sel.p}</h2>
      <p class="muted">Los logros describen lo que el estudiante debe alcanzar en ${pre ? 'la dimensión' : 'la asignatura'} durante el periodo. Escriba uno por línea: aparecen en el boletín de todos los estudiantes del curso.</p>
      <textarea id="logroTxt" rows="3" placeholder="Ejemplo: Resuelve problemas de suma y resta con números hasta 1.000." ${dis}>${esc(S.logros[`${sel.g}|${sel.a}|${sel.p}`] || '')}</textarea>
      ${dis ? '' : `<div class="toolbar" style="margin-top:8px"><button class="btn" type="button" id="logroBtn" onclick="setLogro()">Guardar logros</button><span class="ok" id="logroOk"></span></div>`}</section>`;
}
const horaAhora = () => new Date().toLocaleTimeString('es-CO', { hour: 'numeric', minute: '2-digit' });
const guardadasHoy = {};
function estadoCal(eid) {
  const v = notaRaw(eid, sel.a, sel.p), h = guardadasHoy[`${eid}|${sel.a}|${sel.p}`];
  return v == null ? '<span class="muted">Pendiente</span>' : `<span class="ok">✓ Guardada${h ? ' ' + h : ''}</span>`;
}
function marcarGuardada(eid) {
  const k = `${eid}|${sel.a}|${sel.p}`; if (notaRaw(eid, sel.a, sel.p) != null) guardadasHoy[k] = horaAhora(); else delete guardadasHoy[k];
  const st = $('#st-' + eid); if (st) st.innerHTML = estadoCal(eid);
  const ac = $('#ac-' + eid); if (ac && grupo(sel.g)?.nivel !== 'preescolar') ac.innerHTML = chip(defin(eid, sel.a));
  const rn = $('#regN'); if (rn) rn.textContent = estsDe(sel.g).filter(e => notaRaw(e.id, sel.a, sel.p) != null).length;
}
function recBtn(eid) {
  const r = S.rec[`${eid}|${sel.a}|${sel.p}`], v = notaRaw(eid, sel.a, sel.p);
  if (r) return `<button class="btn ghost sm" type="button" onclick="formRecup('${eid}')">Recuperación${r.nota != null ? ' ' + N(r.nota) : ': pendiente'}</button>`;
  return v != null && desem(v) === 'Bajo' ? `<button class="btn ghost sm" type="button" onclick="formRecup('${eid}')">Plan de recuperación</button>` : '';
}
async function setNotaAct(aid, eid, el) {
  const k = `${aid}|${eid}`, prev = S.nact[k], ln = leerNota(el.value);
  if (ln.err) { toast(ln.err); el.value = N(prev); return; }
  const v = ln.v;
  el.disabled = true;
  const ok = await guard(async () => {
    if (v == null) await q(db.from('notas_act').delete().eq('actividad_id', aid).eq('estudiante_id', eid));
    else await q(db.from('notas_act').upsert({ actividad_id: aid, estudiante_id: eid, colegio_id: ctx.colegio_id, valor: v }, { onConflict: 'actividad_id,estudiante_id' }));
    if (v == null) delete S.nact[k]; else S.nact[k] = v;
    const fin = calcActs(eid, actsDe(sel.g, sel.a, sel.p));
    if (fin !== notaRaw(eid, sel.a, sel.p)) await guardarNota(eid, fin);
    return true;
  });
  el.disabled = false;
  if (!ok) { el.value = N(prev); return; }
  el.value = N(v);
  const pn = $('#pn-' + eid); if (pn) pn.innerHTML = chip(notaRaw(eid, sel.a, sel.p));
  marcarGuardada(eid);
}
async function recalcularPeriodo() {
  const acts = actsDe(sel.g, sel.a, sel.p);
  for (const e of estsDe(sel.g)) { const fin = acts.length ? calcActs(e.id, acts) : notaRaw(e.id, sel.a, sel.p); if (fin !== notaRaw(e.id, sel.a, sel.p)) await guardarNota(e.id, fin); }
}
function formActividad(id) {
  const a = id ? S.acts.find(x => x.id === id) : { nombre: '', peso: '', fecha: hoy() };
  const cerr = cerrado(sel.p);
  openModal(id ? 'Editar actividad' : 'Nueva actividad', `<div class="formgrid">${fIn('aNom', 'Nombre de la actividad', a.nombre, 'maxlength="80" placeholder="Ejemplo: Taller 1, Evaluación escrita"')}
    ${fIn('aFec', 'Fecha', a.fecha || '', 'type="date"')}</div><p class="muted">La calificación del periodo será el promedio de todas las actividades calificadas.</p>
    ${a.campus ? '<div class="note">💻 Esta actividad viene del campus virtual: se califica allí y se borra desde el campus.</div>' : ''}
    <div class="modal-foot">${id && !cerr && !a.campus ? `<button class="btn ghost" type="button" onclick="borrarActividad('${id}')">Borrar actividad</button>` : ''}<button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button>${cerr ? '' : `<button class="btn" type="button" id="aBtn" onclick="guardarActividad('${id || ''}')">Guardar</button>`}</div>`);
}
async function guardarActividad(id) {
  const d = { nombre: vv('aNom'), fecha: vv('aFec') || null };
  if (!d.nombre) return toast('Escriba el nombre de la actividad');
  if (!id && actsDe(sel.g, sel.a, sel.p).some(x => x.nombre.toLowerCase() === d.nombre.toLowerCase())) return toast('Ya existe una actividad con ese nombre en este periodo');
  const r = await busy('#aBtn', () => guard(async () => {
    const x = id ? await q(db.from('actividades').update(d).eq('id', id).select().single())
      : await q(db.from('actividades').insert({ ...d, colegio_id: ctx.colegio_id, grupo_id: sel.g, asignatura_id: sel.a, anio: S.k.anio, periodo: sel.p, orden: actsDe(sel.g, sel.a, sel.p).length + 1 }).select().single());
    S.acts = S.acts.filter(a => a.id !== x.id).concat(x);
    await recalcularPeriodo(); return x;
  }, 'Actividad guardada'));
  if (r) { sel.modoAct = true; closeModal(); render(); }
}
async function borrarActividad(id) {
  const a = S.acts.find(x => x.id === id);
  if (!(await confirmar(`¿Borrar la actividad "${a?.nombre || ''}"? Se borrarán sus calificaciones y se recalculará la calificación del periodo.`, 'Borrar actividad'))) return;
  const ok = await guard(async () => {
    await q(db.from('actividades').delete().eq('id', id));
    S.acts = S.acts.filter(a => a.id !== id); Object.keys(S.nact).forEach(k => { if (k.startsWith(id + '|')) delete S.nact[k]; });
    await recalcularPeriodo(); return true;
  }, 'Actividad eliminada');
  if (ok) { closeModal(); render(); }
}
/* ---------- Recuperaciones (Decreto 1290) ---------- */
function formRecup(eid) {
  const r = S.rec[`${eid}|${sel.a}|${sel.p}`] || {}, a = S.asigs.find(x => x.id === sel.a), v = notaRaw(eid, sel.a, sel.p);
  openModal(`Recuperación: ${nom(est(eid))}`, `<p class="muted">${esc(a?.nombre || '')}, periodo ${sel.p}. Calificación del periodo: ${v == null ? 'sin calificación' : N(v)}. Si la calificación de recuperación es mayor, reemplaza la del periodo en el boletín y en los promedios.</p>
    <div class="formgrid">${fTa('rPlan', 'Plan de recuperación (actividades, temas, compromisos)', r.plan, 'Ejemplo: Taller de fracciones y sustentación oral.')}
    ${fIn('rFec', 'Fecha de presentación', r.fecha || '', 'type="date"')}${fIn('rNota', 'Calificación obtenida, de 0 a 100 (deje vacío si aún no la presenta)', r.nota == null ? '' : N(r.nota), NOTA_ATTR)}</div>
    ${r.registrado_por ? `<p class="muted">Registró: ${esc(r.registrado_por)}</p>` : ''}
    <div class="modal-foot">${r.id ? `<button class="btn ghost" type="button" onclick="borrarRecup('${eid}')">Eliminar</button>` : ''}<button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" onclick="guardarRecup('${eid}')">Guardar</button></div>`);
}
async function guardarRecup(eid) {
  const plan = vv('rPlan'), raw = vv('rNota'); if (!plan) return toast('Escriba el plan de recuperación');
  const ln = leerNota(raw); if (ln.err) return toast(ln.err); const n = ln.v;
  const r = await guard(() => q(db.from('recuperaciones').upsert({ colegio_id: ctx.colegio_id, estudiante_id: eid, asignatura_id: sel.a, anio: S.k.anio, periodo: sel.p, plan, fecha: vv('rFec') || null, nota: n }, { onConflict: 'estudiante_id,asignatura_id,anio,periodo' }).select().single()), 'Recuperación guardada');
  if (r) { S.rec[`${eid}|${sel.a}|${sel.p}`] = r; closeModal(); render(); }
}
async function borrarRecup(eid) {
  const ok = await guard(async () => { await q(db.from('recuperaciones').delete().eq('estudiante_id', eid).eq('asignatura_id', sel.a).eq('anio', S.k.anio).eq('periodo', sel.p)); return true; }, 'Recuperación eliminada');
  if (ok) { delete S.rec[`${eid}|${sel.a}|${sel.p}`]; closeModal(); render(); }
}
/* ---------- Planilla consolidada ---------- */
const abrev = n0 => { let n = n0.replace(/^Dimensi[oó]n\s+/i, '').replace(/^Educaci[oó]n\s+/i, 'Ed. ').replace(/^Ciencias\s+/i, 'C. '); n = n.charAt(0).toUpperCase() + n.slice(1); return n.length > 16 ? n.slice(0, 15) + '.' : n; };
function planillaHTML(g, p) {
  const as = asigsDe(g), es = estsDe(g.id), pre = g.nivel === 'preescolar';
  if (!es.length) return '<div class="empty">Este grupo no tiene estudiantes activos.</div>';
  const val = (e, a) => p === 'acum' ? defin(e, a) : nota(e, a, p);
  const celda = v => `<td>${v == null ? '—' : pre ? desem(v) : `<span class="${desem(v) === 'Bajo' ? 'd d-Bajo' : ''}">${N(v)}</span>`}</td>`;
  return `<div class="tbl"><table class="planilla"><thead><tr><th>Estudiante</th>${as.map(a => `<th title="${esc(a.nombre)}">${esc(abrev(a.nombre))}</th>`).join('')}${pre ? '' : '<th>Prom.</th><th>En bajo</th>'}</tr></thead><tbody>
    ${es.map(e => { const vs = as.map(a => val(e.id, a.id)), ok = vs.filter(x => x != null), pr = ok.length ? ok.reduce((a, b) => a + b, 0) / ok.length : null;
      return `<tr><td>${esc(e.apellidos)} ${esc(e.nombres)}</td>${vs.map(celda).join('')}${pre ? '' : `<td><strong>${pr == null ? '—' : N(pr)}</strong></td><td>${ok.filter(x => desem(x) === 'Bajo').length || ''}</td>`}</tr>`; }).join('')}
    </tbody></table></div>`;
}
async function guardarNota(eid, v) {
  const k = `${eid}|${sel.a}|${sel.p}`;
  if (v == null) await q(db.from('notas').delete().eq('estudiante_id', eid).eq('asignatura_id', sel.a).eq('anio', S.k.anio).eq('periodo', sel.p));
  else await q(db.from('notas').upsert({ colegio_id: ctx.colegio_id, estudiante_id: eid, asignatura_id: sel.a, anio: S.k.anio, periodo: sel.p, valor: v }, { onConflict: 'estudiante_id,asignatura_id,anio,periodo' }));
  if (v == null) delete S.notas[k]; else S.notas[k] = v;
}
async function setNota(eid, el) {
  const prev = notaRaw(eid, sel.a, sel.p), ln = leerNota(el.value);
  if (ln.err) { toast(ln.err); el.value = N(prev); return; }
  const v = ln.v;
  el.disabled = true;
  const ok = await guard(async () => { await guardarNota(eid, v); return true; });
  el.disabled = false;
  if (!ok) { el.value = N(prev); return; }
  el.value = N(v); marcarGuardada(eid);
  
}
async function setLogro() {
  const t = $('#logroTxt').value.trim(), k = `${sel.g}|${sel.a}|${sel.p}`;
  const ok = await busy('#logroBtn', () => guard(async () => {
    if (!t) await q(db.from('logros').delete().eq('grupo_id', sel.g).eq('asignatura_id', sel.a).eq('anio', S.k.anio).eq('periodo', sel.p));
    else await q(db.from('logros').upsert({ colegio_id: ctx.colegio_id, grupo_id: sel.g, asignatura_id: sel.a, anio: S.k.anio, periodo: sel.p, texto: t }, { onConflict: 'grupo_id,asignatura_id,anio,periodo' }));
    return true;
  }, 'Logros guardados'));
  if (ok) { if (t) S.logros[k] = t; else delete S.logros[k]; const o = $('#logroOk'); if (o) o.textContent = '✓ Guardados ' + horaAhora(); }
}
async function setNotaPre(eid, el) { const d = el.value; const ok = await guard(async () => { await guardarNota(eid, d ? PRE_VAL[d] : null); return true; }, d ? `Guardada: ${est(eid).nombres} ${d} en el periodo ${sel.p}` : 'Valoración borrada'); if (!ok) render(); else marcarGuardada(eid); }

/* =====================================================================
   Asistencia
   ===================================================================== */
function vAsistencia() {
  const gs = gruposVis(); if (!gs.length) return head('Asistencia') + sinGrupos();
  if (!sel.fecha) sel.fecha = hoy();
  const g = grupo(sel.g), es = estsDe(sel.g), pc = porClase();
  const L = { P: 'Presente', A: 'Ausente', T: 'Tarde', E: 'Excusa' };
  let as = [], soloVer = false;
  if (pc) { as = asigsVis(g); if (isDoc() && !S.misGrupos.includes(g.id)) soloVer = true; if (!as.find(a => a.id === sel.a)) sel.a = as[0]?.id || ''; }
  const key = eid => pc ? `${sel.fecha}|${eid}|${sel.a}` : `${sel.fecha}|${eid}`;
  const mapa = pc ? S.asisC : S.asis;
  const c = { P: 0, A: 0, T: 0, E: 0 }; es.forEach(e => c[mapa[key(e.id)] || 'P']++);
  return head('Asistencia', pc ? 'Asistencia por clase: cada docente la toma en su asignatura. Todos inician como presentes.' : 'Todos inician como presentes. Marque solo las novedades: cada cambio se guarda solo y verá "✓ Guardado" al lado.') +
    `<div class="panel"><div class="toolbar">${selGrupoHTML(gs)}
      ${pc ? `<label class="field"><span>Asignatura</span><select onchange="sel.a=this.value;render()">${as.map(a => opt(a.id, a.nombre, sel.a)).join('')}</select></label>` : ''}
      <label class="field"><span>Fecha</span><input type="date" value="${sel.fecha}" max="${hoy()}" onchange="sel.fecha=this.value;render()"></label>
      <span class="muted" style="margin-left:auto">Presentes ${c.P}, ausentes ${c.A}, tarde ${c.T}, con excusa ${c.E}</span></div>
    ${soloVer ? '<div class="note">Como director(a) de grupo puede consultar la asistencia; cada docente la registra en su clase.</div>' : ''}
    <div class="ley-asis">${Object.keys(L).map(x => `<span class="as-${x}"><b>${x}</b> ${L[x]}${x === 'E' ? ' (justificada)' : ''}</span>`).join('')}</div>
    ${es.length ? `<div class="tbl"><table><thead><tr><th>Estudiante</th><th>Asistencia</th><th>${pc ? 'Fallas en la asignatura' : 'Fallas en el año'}</th><th></th></tr></thead><tbody>
    ${es.map(e => { const v = mapa[key(e.id)] || 'P', gh = asisGuardada[key(e.id)]; return `<tr><td>${esc(e.apellidos)} ${esc(e.nombres)}</td><td><div class="seg seg-asis" role="group" aria-label="Asistencia de ${esc(nom(e))}">${Object.keys(L).map(x => `<button type="button" class="as-${x}" title="${L[x]}" aria-pressed="${v === x}" onclick="setAsis('${e.id}','${x}')" ${soloVer ? 'disabled' : ''}>${x}</button>`).join('')}</div></td><td>${pc ? fallasAsig(e.id, sel.a) : fallas(e.id)}</td><td>${gh ? `<span class="ok">✓ Guardado ${gh}</span>` : ''}</td></tr>`; }).join('')}
    </tbody></table></div>` : '<div class="empty">Este grupo no tiene estudiantes activos.</div>'}</div>`;
}
const asisGuardada = {};
async function setAsis(eid, v) {
  const pc = porClase(), k = pc ? `${sel.fecha}|${eid}|${sel.a}` : `${sel.fecha}|${eid}`, t = pc ? 'asistencia_clase' : 'asistencia';
  const ok = await guard(async () => {
    let d = db.from(t).delete().eq('estudiante_id', eid).eq('fecha', sel.fecha); if (pc) d = d.eq('asignatura_id', sel.a);
    if (v === 'P') await q(d);
    else await q(db.from(t).upsert({ colegio_id: ctx.colegio_id, estudiante_id: eid, fecha: sel.fecha, estado: v, ...(pc ? { asignatura_id: sel.a } : {}) }, { onConflict: pc ? 'estudiante_id,asignatura_id,fecha' : 'estudiante_id,fecha' }));
    return true;
  });
  const m = pc ? S.asisC : S.asis;
  if (ok) { if (v === 'P') delete m[k]; else m[k] = v; asisGuardada[k] = horaAhora(); render(); }
}

/* =====================================================================
   Documentos y boletines
   ===================================================================== */
function docHead(t, sub) {
  const k = S.k;
  return `<header class="dh"><div style="display:flex;gap:12px;align-items:flex-start">${k.logo ? `<img src="${k.logo}" alt="" style="max-height:70px;max-width:90px">` : ''}<div><div class="dh-inst">${esc(k.nombre)}</div><div class="dh-meta">${esc(k.resolucion || '')}${k.dane ? `<br>Código DANE ${esc(k.dane)}` : ''}${k.nit ? `, NIT ${esc(k.nit)}` : ''}<br>${esc([k.direccion, k.ciudad].filter(Boolean).join(', '))}${k.telefono ? ` · Tel. ${esc(k.telefono)}` : ''}${k.web ? `<br>${esc(k.web)}` : ''}${k.lema ? `<br><em>${esc(k.lema)}</em>` : ''}</div></div></div><div class="dh-t"><strong>${t}</strong><br>${sub || ''}</div></header>`;
}
const firmas = (...f) => `<div class="firmas">${f.map(([c, n]) => `<div>${/^Rector/.test(c) && S.k?.firma_rector ? `<img class="firma-img" src="${S.k.firma_rector}" alt="Firma">` : ''}<span class="firma-l">${esc(n || '')}<br>${c}</span></div>`).join('')}</div>`;
const dato = (l, v) => `<div><span>${l}</span>${esc(v ?? '') || '—'}</div>`;
const fechaLarga = f => { const d = new Date((f || hoy()) + 'T12:00:00'); return d.toLocaleDateString('es-CO', { day: 'numeric', month: 'long', year: 'numeric' }); };

// Foto del estudiante y contactos registrados por la familia, para los documentos del colegio
let contEst = {};
const fotoDoc = eid => fotoEst[eid] ? `<img class="dfoto" src="${fotoEst[eid]}" alt="Foto">` : '';
async function prepDocsEst(ids, conContactos) {
  await cargarFotoEst(ids);
  if (!conContactos) return;
  const faltan = ids.filter(id => !(id in contEst));
  faltan.forEach(id => contEst[id] = []);
  for (const part of chunks(faltan, 80)) (await all(() => db.from('contactos_est').select('*').in('estudiante_id', part).order('estudiante_id').order('creado_en').order('id'))).forEach(c => contEst[c.estudiante_id].push(c));
}
function hojaMatricula(eid) {
  const e = est(eid), g = grupo(e.grupo_id), ac = acudDe(eid);
  const ce = (contEst[eid] || []).filter(c => c.activo !== false);
  return `<section class="doc compacta">${docHead('Hoja de matrícula', `Año lectivo ${S.k.anio}<br>Folio ${e.folio} · Matrícula ${esc(e.matricula || '')}`)}
  ${fotoDoc(eid)}<h3 style="color:#0B4F8A;margin:0 0 6px">Datos del estudiante</h3>
  <div class="dgrid">${dato('Apellidos', e.apellidos)}${dato('Nombres', e.nombres)}${dato('Documento', `${e.tipo_doc} ${e.doc}`)}
    ${dato('Lugar de expedición', e.lugar_expedicion)}${dato('Fecha de nacimiento', fmtF(e.fnac))}${dato('Lugar de nacimiento', e.lugar_nacimiento)}
    ${dato('Sexo', e.sexo)}${dato('País de origen', e.pais_origen)}${dato('Grupo étnico', e.etnia)}
    ${dato('Dirección', e.direccion)}${dato('Barrio', e.barrio)}${dato('Municipio', e.municipio)}
    ${dato('Zona', e.zona)}${dato('Estrato', e.estrato)}${dato('Teléfono', e.telefono)}
    ${dato('Correo', e.email)}${dato('Víctima del conflicto', e.victima_conflicto ? 'Sí' : 'No')}${dato('SISBÉN', e.sisben)}</div>
  <h3 style="color:#0B4F8A;margin:8px 0 6px">Salud e inclusión</h3>
  <div class="dgrid">${dato('EPS', e.eps)}${dato('RH', e.rh)}${dato('Discapacidad', e.discapacidad)}${dato('Capacidades excepcionales', e.capacidades_excepcionales)}${dato('Requiere PIAR', e.piar ? 'Sí' : 'No')}</div>
  <div class="dobs"><span>Condición especial</span><p>${esc(e.condicion_especial || 'Ninguna registrada.')}</p></div>
  <div class="dobs"><span>Recomendaciones médicas especiales</span><p>${esc(e.recomendaciones_medicas || 'Ninguna registrada.')}</p></div>
  <h3 style="color:#0B4F8A;margin:12px 0 6px">Matrícula</h3>
  <div class="dgrid">${dato('Curso', g?.nombre)}${dato('Jornada', e.jornada)}${dato('Situación', e.situacion)}${dato('Fecha de matrícula', fmtF(e.fecha_matricula))}${dato('Institución de procedencia', e.institucion_procedencia)}${dato('Estado', e.estado + (e.fecha_retiro ? ` (${fmtF(e.fecha_retiro)})` : ''))}</div>
  <h3 style="color:#0B4F8A;margin:8px 0 6px">Acudientes</h3>
  ${ac.length ? `<table><thead><tr><th>Parentesco</th><th>Nombre</th><th>Documento</th><th>Teléfono</th><th>Correo</th><th>Dirección</th><th>Ocupación</th></tr></thead><tbody>${ac.map(a => `<tr><td>${esc(a.parentesco)}${a.responsable_pago ? ' (resp. pagos)' : ''}</td><td>${esc(a.nombres)}</td><td>${esc(a.tipo_doc || '')} ${esc(a.doc || '')}</td><td>${esc(a.telefono || '')}</td><td>${esc(a.email || '')}</td><td>${esc(a.direccion || '')}</td><td>${esc(a.ocupacion || '')}</td></tr>`).join('')}</tbody></table>` : '<p>Sin acudientes registrados.</p>'}
  ${ce.length ? `<h3 style="color:#0B4F8A;margin:8px 0 6px">Contactos registrados por la familia</h3>
  <table><thead><tr><th>Tipo</th><th>Nombre</th><th>Parentesco</th><th>Teléfono</th><th>Documento</th></tr></thead><tbody>${ce.map(c => `<tr><td>${c.tipo === 'emergencia' ? 'Emergencia' : 'Autorizado(a) para recoger'}</td><td>${esc(c.nombre)}</td><td>${esc(c.parentesco || '')}</td><td>${esc(c.telefono || '')}</td><td>${esc(c.doc || '')}</td></tr>`).join('')}</tbody></table>` : ''}
  <div class="dobs"><span>Autorización de tratamiento de datos personales</span><p>${esc(textoAutorizacion(e, ac))}</p>
    <p style="margin-top:6px">Tratamiento de datos: <strong>${e.autoriza_datos ? 'Autorizado' : 'No autorizado'}</strong> · Uso de imagen: <strong>${e.autoriza_imagen ? 'Autorizado' : 'No autorizado'}</strong>${e.autoriza_fecha ? ` · Fecha: ${fmtF(e.autoriza_fecha)}` : ''}</p></div>
  ${e.motivo_retiro ? `<div class="dobs"><span>Retiro</span><p>${esc(fmtF(e.fecha_retiro))}: ${esc(e.motivo_retiro)}</p></div>` : ''}
  ${firmas(['Rector(a)', S.k.rector_nombre], ['Secretaría académica', S.k.secretaria_nombre], ['Acudiente', ac[0]?.nombres || ''])}</section>`;
}
function textoAutorizacion(e, ac) {
  const quien = e.autoriza_por || ac?.[0]?.nombres || 'El acudiente';
  return `En cumplimiento de la Ley 1581 de 2012 y el Decreto 1377 de 2013, ${quien}, en calidad de acudiente de ${nom(e)}, autoriza a ${S.k.nombre} como responsable del tratamiento para recolectar, almacenar, usar y actualizar los datos personales del estudiante y de su familia, incluidos los datos sensibles de salud, con fines exclusivamente académicos, administrativos, de inclusión y de bienestar. Los datos no se entregarán a terceros salvo obligación legal (por ejemplo, el reporte al SIMAT). El titular puede conocer, actualizar, rectificar y solicitar la supresión de sus datos ante la secretaría académica.${S.k.politica_datos ? ' Política de tratamiento de datos: ' + S.k.politica_datos : ''}`;
}
async function libroMatricula() {
  const l = S.ests.filter(e => e.estado !== 'Graduado').sort((a, b) => a.folio - b.folio);
  toast('Preparando el libro de matrícula…');
  if (!(await guard(async () => { await prepDocsEst(l.map(e => e.id), true); return true; }))) return;
  const indice = `<section class="doc">${docHead('Libro de matrícula', `Año lectivo ${S.k.anio}`)}<table><thead><tr><th>Folio</th><th>Matrícula</th><th>Estudiante</th><th>Documento</th><th>Curso</th><th>Estado</th></tr></thead><tbody>
    ${l.map(e => `<tr><td>${e.folio}</td><td>${esc(e.matricula || '')}</td><td>${esc(e.apellidos)} ${esc(e.nombres)}</td><td>${e.tipo_doc} ${esc(e.doc)}</td><td>${esc(grupo(e.grupo_id)?.nombre || '')}</td><td>${e.estado}</td></tr>`).join('')}</tbody></table>
    ${firmas(['Rector(a)', S.k.rector_nombre], ['Secretaría académica', S.k.secretaria_nombre])}</section>`;
  showDocs(indice + l.map(e => hojaMatricula(e.id)).join(''), 'Libro de matrícula', `Libro de matrícula ${S.k.anio}`);
}
function constancia(eid) {
  const e = est(eid), g = grupo(e.grupo_id);
  const estado = e.estado === 'Activo' ? `se encuentra matriculado(a) y cursa actualmente el grado <strong>${esc(g?.nombre || '')}</strong>, jornada ${esc((e.jornada || '').toLowerCase())}, en el año lectivo ${S.k.anio}`
    : e.estado === 'Retirado' ? `estuvo matriculado(a) en el grado <strong>${esc(g?.nombre || '')}</strong> durante el año lectivo ${S.k.anio} y se retiró el ${fechaLarga(e.fecha_retiro)}`
    : `culminó sus estudios en esta institución`;
  return `<section class="doc">${docHead('Constancia de estudio', `Año lectivo ${S.k.anio}`)}${fotoDoc(eid)}
  <p style="margin-top:18px">El suscrito rector(a) y la secretaría académica de <strong>${esc(S.k.nombre)}</strong> hacen constar que <strong>${esc(nom(e))}</strong>, identificado(a) con ${e.tipo_doc} ${esc(e.doc)}, ${estado}, con matrícula No. ${esc(e.matricula || '')}, folio ${e.folio}.</p>
  <p>Se expide a solicitud del interesado en ${esc(S.k.ciudad || '')}, el ${fechaLarga()}.</p>
  ${firmas(['Rector(a)', S.k.rector_nombre], ['Secretaría académica', S.k.secretaria_nombre])}</section>`;
}
function certificado(eid) {
  const e = est(eid), g = grupo(e.grupo_id); if (!g) return constancia(eid);
  const as = asigsDe(g), pre = g.nivel === 'preescolar', pa = S.k.periodo_actual;
  return `<section class="doc">${docHead('Constancia de estudio con calificaciones', `Año lectivo ${S.k.anio}`)}${fotoDoc(eid)}
  <p style="margin-top:14px">El suscrito rector(a) de <strong>${esc(S.k.nombre)}</strong> hace constar que <strong>${esc(nom(e))}</strong>, identificado(a) con ${e.tipo_doc} ${esc(e.doc)}, ${e.estado === 'Activo' ? 'cursa' : 'cursó'} el grado <strong>${esc(g.nombre)}</strong> en el año lectivo ${S.k.anio}, con las siguientes valoraciones acumuladas a la fecha:</p>
  <table><thead><tr><th>${pre ? 'Dimensión' : 'Asignatura'}</th><th>IH</th>${pre ? '' : periodos().filter(p => p.n <= pa).map(p => `<th>P${p.n}</th>`).join('')}<th>Valoración</th><th>Desempeño</th></tr></thead><tbody>
  ${as.map(a => { const v = defin(eid, a.id); return `<tr><td>${esc(a.nombre)}</td><td>${a.ih}</td>${pre ? '' : periodos().filter(p => p.n <= pa).map(p => { const x = nota(eid, a.id, p.n); return `<td>${x == null ? '—' : N(x)}</td>`; }).join('')}<td>${v == null || pre ? '—' : N(v)}</td><td>${v == null ? 'Sin valorar' : desem(v)}</td></tr>`; }).join('')}</tbody></table>
  <p class="dnote">Escala institucional: ${escala().map(s => `${s.d} de ${N(s.min)} a ${N(s.max)}`).join(', ')}. Decreto 1290 de 2009.</p>
  <p>Se expide a solicitud del interesado en ${esc(S.k.ciudad || '')}, el ${fechaLarga()}.</p>
  ${firmas(['Rector(a)', S.k.rector_nombre], ['Secretaría académica', S.k.secretaria_nombre])}</section>`;
}

function boletinHTML(eid, per) {
  const e = est(eid), g = grupo(e.grupo_id); if (!g) return '';
  const as = asigsDe(g), pre = g.nivel === 'preescolar', ps = periodos().filter(p => p.n <= per), pr = promedio(eid, per);
  const body = pre ? `<table><thead><tr><th>Dimensión</th><th>Desempeño</th><th>Descripción</th></tr></thead><tbody>${as.map(a => { const v = nota(eid, a.id, per), d = desem(v); const lo = S.logros[`${g.id}|${a.id}|${per}`]; return `<tr><td>${esc(a.nombre)}</td><td>${v == null ? 'Sin valorar' : d}</td><td>${lo ? logroLista(lo) + (v == null ? '' : `<span class="logro">${DESC[d] || ''}</span>`) : (v == null ? '' : DESC[d] || '')}</td></tr>`; }).join('')}</tbody></table>`
    : `<table><thead><tr><th>Asignatura</th><th>IH</th>${ps.map(p => `<th>P${p.n}</th>`).join('')}<th>Acum.</th><th>Desempeño</th></tr></thead><tbody>${as.map(a => { const d = defin(eid, a.id, per), lo = S.logros[`${g.id}|${a.id}|${per}`]; return `<tr><td>${esc(a.nombre)}${logroLista(lo)}</td><td>${a.ih}</td>${ps.map(p => { const v = nota(eid, a.id, p.n), r = S.rec[`${eid}|${a.id}|${p.n}`]; return `<td>${v == null ? '—' : N(v)}${r?.nota != null && v === +r.nota ? '<sup>R</sup>' : ''}</td>`; }).join('')}<td><strong>${d == null ? '—' : N(d)}</strong></td><td>${d == null ? '' : desem(d)}</td></tr>`; }).join('')}</tbody></table>`;
  return `<section class="doc">${docHead('Informe académico', `Periodo ${per} de ${periodos().length}, año ${S.k.anio}`)}
  ${fotoDoc(eid)}<div class="dgrid"><div><span>Estudiante</span>${esc(nom(e))}</div><div><span>Documento</span>${e.tipo_doc} ${esc(e.doc)}</div><div><span>Grado y grupo</span>${esc(g.nombre)}</div>
  <div><span>Director(a) de grupo</span>${esc(g.director_nombre || '')}</div><div><span>${porClase() ? 'Fallas (horas de clase)' : 'Fallas a la fecha'}</span>${fallas(eid)}</div>${pre ? '' : `<div><span>Promedio acumulado</span>${pr == null ? '—' : N(pr) + ' ' + desem(pr)}</div>`}</div>
  ${body}
  ${!pre && Object.keys(S.rec).some(k => k.startsWith(eid + '|') && S.rec[k].nota != null) ? '<p class="dnote"><sup>R</sup> Calificación obtenida en actividad de recuperación (Decreto 1290 de 2009).</p>' : ''}
  ${e.piar ? '<p class="dnote">Estudiante valorado con ajustes razonables según su Plan Individual de Ajustes Razonables (PIAR), Decreto 1421 de 2017.</p>' : ''}
  <div class="dobs"><span>Observaciones</span><p>${esc(S.obs[eid + '|' + per] || 'Sin observaciones para este periodo.')}</p></div>
  ${pre ? '<p class="dnote">En el nivel de preescolar la evaluación es cualitativa y no se reprueba el grado.</p>' : `<p class="dnote">Escala institucional: ${escala().map(s => `${s.d} de ${N(s.min)} a ${N(s.max)}`).join(', ')}. Equivalencia con la escala nacional del Decreto 1290 de 2009.</p>`}
  ${firmas(['Rector(a)', S.k.rector_nombre], ['Director(a) de grupo', g.director_nombre])}</section>`;
}
function vBoletines() {
  if (!sel.p) sel.p = S.k.periodo_actual;
  if (propio()) {
    const eid = propio(); if (!est(eid) || !grupo(est(eid).grupo_id)) return head('Boletín') + '<div class="panel empty">El estudiante aún no tiene grupo asignado.</div>';
    return head('Boletín', 'Consulta e imprime el informe de cada periodo.', `<div class="toolbar" style="margin:0"><label class="field"><span>Periodo</span><select onchange="sel.p=+this.value;render()">${perOpts(sel.p)}</select></label><button class="btn" type="button" onclick="imprimirBoletin('${eid}')">Imprimir</button></div>`) + boletinHTML(eid, sel.p);
  }
  const gs = gruposVis(); if (!gs.length) return head('Boletines') + sinGrupos();
  const es = estsDe(sel.g), ret = S.ret || new Set(), nRet = es.filter(e => ret.has(e.id)).length;
  return head('Boletines', isDoc() ? 'Escriba la observación de cada estudiante para el boletín. Los boletines los generan y entregan coordinación y rectoría.' : 'Escriba la observación de cada estudiante y genere los informes del periodo.', isDoc() ? '' : `<button class="btn" type="button" onclick="boletinesGrupo()" ${es.length > nRet ? '' : 'disabled'}>Generar boletines del grupo</button>`) +
    (nRet ? `<div class="note">${nRet} ${nRet === 1 ? 'boletín está retenido' : 'boletines están retenidos'} por pagos pendientes: no se incluyen al generar los del grupo. Se liberan solos cuando la familia se pone al día.</div>` : '') +
    `<div class="panel"><div class="toolbar">
      <label class="field"><span>Grupo</span><select onchange="cambiarGrupo(this.value)">${gs.map(x => opt(x.id, x.nombre, sel.g)).join('')}</select></label>
      <label class="field"><span>Periodo</span><select onchange="sel.p=+this.value;render()">${perOpts(sel.p)}</select></label></div>
    ${es.length ? `<ul class="list">${es.map(e => `<li><div style="display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap;margin-bottom:6px"><strong>${esc(e.apellidos)} ${esc(e.nombres)} ${e.piar ? '<span class="tag piar">PIAR</span>' : ''} ${ret.has(e.id) ? '<span class="tag t3">Retenido</span>' : ''}</strong>${isDoc() || ret.has(e.id) ? '' : `<button class="btn ghost sm" type="button" onclick="verBoletin('${e.id}')">Ver boletín</button>`}</div>
      <label class="field"><span>Observación del periodo ${sel.p} (se guarda sola al salir de la casilla) <span class="ok" id="obok-${e.id}"></span></span><textarea id="ob-${e.id}" onchange="setObs('${e.id}',this)">${esc(S.obs[e.id + '|' + sel.p] || '')}</textarea></label>
      <select class="acc" aria-label="Agregar frase frecuente" onchange="agregarFrase('${e.id}',this.value);this.value=''"><option value="">Agregar frase frecuente…</option>${BANCO_OBS.map((f, i) => `<option value="${i}">${esc(f.length > 70 ? f.slice(0, 70) + '…' : f)}</option>`).join('')}</select></li>`).join('')}</ul>` : '<div class="empty">Este grupo no tiene estudiantes activos.</div>'}</div>`;
}
const nomArchivo = (t, e) => `${t} ${e ? e.apellidos + ' ' + e.nombres : ''} ${S.k.anio}`.replace(/\s+/g, ' ').trim();
async function verBoletin(eid) { await guard(() => cargarFotoEst([eid])); showDocs(boletinHTML(eid, sel.p), 'Boletín', nomArchivo(`Boletín P${sel.p}`, est(eid))); }
async function imprimirBoletin(eid) { await guard(() => cargarFotoEst([eid])); lastDocs = boletinHTML(eid, sel.p); lastTitulo = nomArchivo(`Boletín P${sel.p}`, est(eid)); printDocs(); }
async function boletinesGrupo() { const l = estsDe(sel.g).filter(e => !(S.ret || new Set()).has(e.id)); await guard(() => cargarFotoEst(l.map(e => e.id))); showDocs(l.map(e => boletinHTML(e.id, sel.p)).join(''), 'Boletines del grupo', `Boletines P${sel.p} ${grupo(sel.g)?.nombre || ''} ${S.k.anio}`); }
async function setObs(eid, el) {
  const t = el.value.trim(), p = sel.p;
  const ok = await guard(async () => {
    if (!t) await q(db.from('observaciones').delete().eq('estudiante_id', eid).eq('anio', S.k.anio).eq('periodo', p));
    else await q(db.from('observaciones').upsert({ colegio_id: ctx.colegio_id, estudiante_id: eid, anio: S.k.anio, periodo: p, texto: t }, { onConflict: 'estudiante_id,anio,periodo' }));
    return true;
  }, 'Observación guardada');
  if (ok) { if (t) S.obs[`${eid}|${p}`] = t; else delete S.obs[`${eid}|${p}`]; const o = $('#obok-' + eid); if (o) o.textContent = '✓ Guardada ' + horaAhora(); }
}

/* =====================================================================
   Parametrización
   ===================================================================== */
let costos = null, conceptos = [];
async function prepConfig() {
  if (!isTes() && !(sel.ptab)) sel.ptab = 'inst';
  if (isTes()) sel.ptab = 'costos';
  if (sel.ptab === 'costos') await cargarCostos();
  if (sel.ptab === 'cierre') await prepCierre();
  if (sel.ptab === 'grupos' && isDir()) await cargarMiembros();
  if (sel.ptab === 'logros') { if (!sel.lg || !grupo(sel.lg)) sel.lg = S.grupos[0]?.id || ''; if (!sel.lp) sel.lp = S.k.periodo_actual; if (sel.lg) await cargarGrupo(sel.lg, true); }
}
async function cargarCostos() {
  const a = S.k.anio;
  costos = (await q(db.from('costos_anio').select('*').eq('colegio_id', ctx.colegio_id).eq('anio', a)))[0] || { anio: a };
  conceptos = await q(db.from('conceptos').select('*').eq('colegio_id', ctx.colegio_id).eq('anio', a).order('orden').order('nombre'));
}
const PTABS = { inst: 'Institución', periodos: 'Periodos y escala', grupos: 'Cursos', plan: 'Plan de estudios', logros: 'Logros', campus: 'Campus y gemas', costos: 'Costos del año', cierre: 'Cierre de año' };
async function irPtab(t) { sel.ptab = t; await go('config'); }
function vConfig() {
  const tabs = isTes() ? ['costos'] : Object.keys(PTABS);
  const t = sel.ptab || tabs[0];
  const cuerpo = { inst: paramInst, periodos: paramPeriodos, grupos: paramGrupos, plan: planTabs, logros: paramLogros, campus: paramCampus, costos: paramCostos, cierre: paramCierre }[t]();
  return head('Parametrización', 'Datos del colegio y reglas del año lectivo.') +
    `<div class="tabs" role="tablist">${tabs.map(k => `<button type="button" role="tab" aria-selected="${k === t}" onclick="irPtab('${k}')">${PTABS[k]}</button>`).join('')}</div>${cuerpo}`;
}
const esRector = () => ctx.rol === 'rector';
/* ---------- Logros del colegio por curso, asignatura y periodo ---------- */
function paramLogros() {
  if (!S.grupos.length) return '<div class="panel empty">Primero cree los cursos.</div>';
  const g = grupo(sel.lg) || S.grupos[0], p = sel.lp || S.k.periodo_actual, pre = g.nivel === 'preescolar';
  const otros = S.grupos.filter(x => x.grado === g.grado && x.id !== g.id);
  return `<div class="panel"><h2>Logros del periodo</h2>
    <p class="muted">Escriba los logros que el colegio espera en cada ${pre ? 'dimensión' : 'asignatura'}. Un logro por línea. Aparecen en el boletín de cada estudiante; los docentes también pueden ajustarlos desde Calificaciones.</p>
    <div class="toolbar"><label class="field"><span>Curso</span><select onchange="sel.lg=this.value;irPtab('logros')">${S.grupos.map(x => opt(x.id, x.nombre, g.id)).join('')}</select></label>
      <label class="field"><span>Periodo</span><select onchange="sel.lp=+this.value;render()">${perOpts(p)}</select></label></div>
    <div class="formgrid">${asigsDe(g).map(a => `<label class="field full"><span>${esc(a.nombre)}</span><textarea class="lgTxt" data-a="${a.id}" placeholder="Ejemplo: Reconoce y escribe números hasta 1.000.">${esc(S.logros[`${g.id}|${a.id}|${p}`] || '')}</textarea></label>`).join('')}</div>
    ${otros.length ? `<label class="chk" style="margin-top:10px"><input type="checkbox" id="lgOtros"> Aplicar también a ${otros.map(x => esc(x.nombre)).join(', ')}</label>` : ''}
    <div class="toolbar guardar-fijo"><button class="btn" type="button" onclick="guardarLogros()">Guardar logros del periodo ${p}</button></div></div>`;
}
async function guardarLogros() {
  const g = grupo(sel.lg) || S.grupos[0], p = sel.lp || S.k.periodo_actual;
  const destinos = [g, ...($('#lgOtros')?.checked ? S.grupos.filter(x => x.grado === g.grado && x.id !== g.id) : [])];
  const items = [...document.querySelectorAll('.lgTxt')].map(t => ({ a: t.dataset.a, txt: t.value.trim() }));
  const ok = await guard(async () => {
    for (const d of destinos) {
      const up = items.filter(i => i.txt).map(i => ({ colegio_id: ctx.colegio_id, grupo_id: d.id, asignatura_id: i.a, anio: S.k.anio, periodo: p, texto: i.txt }));
      const del = items.filter(i => !i.txt).map(i => i.a);
      if (up.length) await q(db.from('logros').upsert(up, { onConflict: 'grupo_id,asignatura_id,anio,periodo' }));
      if (del.length) await q(db.from('logros').delete().eq('grupo_id', d.id).eq('anio', S.k.anio).eq('periodo', p).in('asignatura_id', del));
      items.forEach(i => { const k = `${d.id}|${i.a}|${p}`; if (i.txt) S.logros[k] = i.txt; else delete S.logros[k]; });
    }
    return true;
  }, destinos.length > 1 ? `Logros guardados en ${destinos.length} cursos` : 'Logros guardados');
  if (ok) destinos.slice(1).forEach(d => S.loadedG.delete(d.id));
}
const logroLista = t => t ? `<ul class="logro">${t.split('\n').map(x => x.trim()).filter(Boolean).map(x => `<li>${esc(x)}</li>`).join('')}</ul>` : '';
function paramInst() {
  const k = S.k, r = esRector();
  const f = (id, l, v, t) => `<label class="field"><span>${l}</span><input id="${id}" ${t ? `type="${t}"` : ''} value="${esc(v ?? '')}" ${r ? '' : 'disabled'}></label>`;
  return (r ? '' : '<div class="note">Solo el rector o la rectora pueden cambiar estos datos.</div>') +
    `<div class="panel"><h2>Datos institucionales</h2><div class="formgrid">${f('iN', 'Nombre', k.nombre)}${f('iNit', 'NIT', k.nit)}${f('iDane', 'Código DANE', k.dane)}${f('iRes', 'Licencia de funcionamiento o resolución', k.resolucion)}${f('iCiu', 'Ciudad', k.ciudad)}${f('iDir', 'Dirección', k.direccion)}${f('iTel', 'Teléfono', k.telefono)}${f('iWeb', 'Página web', k.web)}${f('iLema', 'Lema o mensaje institucional', k.lema)}${f('iRec', 'Rector(a) que firma', k.rector_nombre)}${f('iSec', 'Secretaría académica', k.secretaria_nombre)}
      <label class="field full"><span>Política de tratamiento de datos (enlace o texto breve, aparece en la hoja de matrícula)</span><textarea id="iPol" ${r ? '' : 'disabled'}>${esc(k.politica_datos || '')}</textarea></label></div>
      ${r ? '<div class="toolbar guardar-fijo"><button class="btn" type="button" onclick="guardarInst()">Guardar datos</button></div>' : ''}</div>
    <div class="panel"><h2>Logo institucional</h2>
      <div style="display:flex;gap:18px;align-items:center;flex-wrap:wrap">
        <div style="width:120px;height:120px;border:1px dashed var(--line);border-radius:8px;display:grid;place-items:center;background:#fff">${k.logo ? `<img src="${k.logo}" alt="Logo" style="max-width:110px;max-height:110px">` : '<span class="muted" style="font-size:.85rem">Sin logo</span>'}</div>
        ${r ? `<div><p class="muted" style="margin:0 0 8px">Imagen PNG o JPG. Aparece en boletines, constancias y hojas de matrícula.</p>
        <label class="btn ghost" style="display:inline-block">Subir logo<input type="file" accept="image/png,image/jpeg,image/webp" hidden onchange="subirLogo(this)"></label>
        ${k.logo ? '<button class="btn ghost" type="button" onclick="quitarLogo()">Quitar</button>' : ''}</div>` : ''}
      </div></div>
    <div class="panel"><h2>Firma del rector(a)</h2><p class="muted">Foto o escaneo de la firma sobre papel blanco. Aparece en boletines, constancias y certificados.</p>
      <div style="display:flex;gap:18px;align-items:center;flex-wrap:wrap"><div style="width:200px;height:90px;border:1px dashed var(--line);border-radius:8px;display:grid;place-items:center;background:#fff">${k.firma_rector ? `<img src="${k.firma_rector}" alt="Firma" style="max-width:190px;max-height:80px">` : '<span class="muted" style="font-size:.85rem">Sin firma</span>'}</div>
      ${r ? `<label class="btn ghost">Subir firma<input type="file" accept="image/*" hidden onchange="subirFirma(this)"></label>${k.firma_rector ? '<button class="btn ghost" type="button" onclick="guardarColegio({firma_rector:null},\'Firma quitada\')">Quitar</button>' : ''}` : ''}</div></div>
    ${panelAtencion(r)}${panelRedes()}`;
}
async function subirFirma(input) { const f = input.files[0]; if (!f) return; const img = await guard(() => leerImagen(f, 500)); if (img) await guardarColegio({ firma_rector: img }, 'Firma guardada'); }
function panelAtencion(r) {
  const a = atn(), dis = r ? '' : 'disabled';
  return `<div class="panel"><h2>Horario de atención a padres</h2><p class="muted">Las familias solo podrán pedir citas en estos días y horas, desde un calendario.</p>
    <div class="cuotas">${[1, 2, 3, 4, 5, 6].map(d => `<label class="chk"><input type="checkbox" class="atD" value="${d}" ${a.dias.includes(d) ? 'checked' : ''} ${dis}> ${DSEM[d][0].toUpperCase() + DSEM[d].slice(1)}</label>`).join('')}</div>
    <div class="formgrid" style="margin-top:8px">${fIn('atDe', 'Desde', a.desde, `type="time" ${dis}`)}${fIn('atHa', 'Hasta', a.hasta, `type="time" ${dis}`)}</div>
    ${r ? '<div class="toolbar" style="margin-top:10px"><button class="btn" type="button" onclick="guardarAtencion()">Guardar horario de atención</button></div>' : ''}</div>`;
}
async function guardarAtencion() {
  const d = { dias: [...document.querySelectorAll('.atD:checked')].map(x => +x.value), desde: vv('atDe'), hasta: vv('atHa') };
  if (!d.dias.length) return toast('Marque al menos un día de atención');
  if (!d.desde || !d.hasta || d.hasta <= d.desde) return toast('La hora final debe ser posterior a la inicial');
  await guardarColegio({ atencion: d }, 'Horario de atención guardado');
}
async function guardarColegio(d, okMsg) {
  const r = await guard(() => q(db.from('colegios').update(d).eq('id', S.k.id).select().single()), okMsg);
  if (r) { S.k = r; ctx.colegios.nombre = r.nombre; render(); }
  return r;
}
async function guardarInst() {
  const d = { nombre: vv('iN'), nit: vv('iNit'), dane: vv('iDane'), resolucion: vv('iRes'), ciudad: vv('iCiu'), direccion: vv('iDir'), telefono: vv('iTel'),
    web: vv('iWeb'), lema: vv('iLema'), rector_nombre: vv('iRec'), secretaria_nombre: vv('iSec'), politica_datos: vv('iPol') };
  if (!d.nombre) return toast('El nombre del colegio es obligatorio');
  if (d.web) { const u = normUrl(d.web); if (!u) return toast('La página web no parece válida. Escríbala como colegio.edu.co'); d.web = u; }
  await guardarColegio(d, 'Datos guardados');
}
function subirLogo(input) {
  const f = input.files[0]; if (!f) return;
  const img = new Image(), url = URL.createObjectURL(f);
  img.onload = async () => {
    const max = 360, k = Math.min(1, max / Math.max(img.width, img.height));
    const c = document.createElement('canvas'); c.width = Math.round(img.width * k); c.height = Math.round(img.height * k);
    c.getContext('2d').drawImage(img, 0, 0, c.width, c.height); URL.revokeObjectURL(url);
    let data = c.toDataURL('image/png');
    if (data.length > 380000) data = c.toDataURL('image/jpeg', 0.85);
    await guardarColegio({ logo: data }, 'Logo actualizado');
  };
  img.onerror = () => toast('No se pudo leer la imagen');
  img.src = url;
}
async function quitarLogo() { await guardarColegio({ logo: null }, 'Logo eliminado'); }

const filaPer = (p, dis) => `<div class="toolbar perRow" data-n="${p.n}" style="margin-bottom:6px"><strong style="min-width:80px">Periodo ${p.n}</strong>
  <label class="field"><span>Porcentaje (%)</span><input type="number" id="pw${p.n}" min="0" max="100" value="${p.peso}" ${dis}></label>
  <label class="field"><span>Inicia</span><input type="date" id="pi${p.n}" value="${p.inicio || ''}" ${dis}></label>
  <label class="field"><span>Termina</span><input type="date" id="pf${p.n}" value="${p.fin || ''}" ${dis}></label>
  <label class="field"><span>Cierre de calificaciones</span><input type="date" id="pc${p.n}" value="${p.cierre || ''}" ${dis}></label></div>`;
function paramPeriodos() {
  const k = S.k, r = esRector(), ps = periodos(), es = escala();
  const dis = r ? '' : 'disabled';
  return (r ? '' : '<div class="note">Solo el rector o la rectora pueden cambiar el SIEE.</div>') +
    `<div class="panel"><h2>Periodos y calendario académico</h2><p class="muted">El año lectivo va de enero a diciembre. Elija cuántos periodos tiene, el porcentaje de cada uno (deben sumar 100%) y sus fechas. Después de la fecha de <strong>cierre de calificaciones</strong> los docentes ya no pueden modificar las calificaciones de ese periodo; los directivos sí.</p>
      <div class="toolbar"><label class="field"><span>Número de periodos</span><select id="nPer" ${dis} onchange="cambiarNumPeriodos(+this.value)">${[1, 2, 3, 4, 5, 6].map(n => opt(n, n, ps.length)).join('')}</select></label>
      <label class="field"><span>Periodo en curso</span><select id="pAct" ${dis}>${perOpts(k.periodo_actual)}</select></label></div>
      <div id="perBox">${ps.map(p => filaPer(p, dis)).join('')}</div></div>
    <div class="panel"><h2>Escala de valoración</h2><div class="toolbar">${es.map((s, i) => `<label class="field"><span>${esc(s.d)} desde</span><input ${NOTA_ATTR} id="es${i}" value="${N(s.min)}" ${dis}></label>`).join('')}
      <label class="field"><span>Asignaturas en bajo para no promover</span><input type="number" min="1" max="10" id="mxP" value="${k.max_perdidas}" ${dis}></label></div>
      ${r ? '<div class="toolbar guardar-fijo"><button class="btn" type="button" onclick="guardarPeriodos()">Guardar periodos y escala</button></div>' : ''}</div>
    <div class="panel"><h2>Asistencia</h2><label class="chk"><input type="checkbox" id="asPC" ${k.asistencia_por_clase ? 'checked' : ''} ${dis} onchange="setPorClase(this.checked)"> Tomar asistencia por clase (cada docente en su asignatura). Si no se marca, la asistencia es diaria por grupo.</label></div>`;
}
function cambiarNumPeriodos(n) {
  const base = Math.floor(100 / n), resto = 100 - base * n, pa = Math.min(+$('#pAct').value || 1, n);
  const old = periodos();
  $('#perBox').innerHTML = Array.from({ length: n }, (_, i) => filaPer({ ...(old[i] || {}), n: i + 1, peso: base + (i === n - 1 ? resto : 0) }, '')).join('');
  $('#pAct').innerHTML = Array.from({ length: n }, (_, i) => opt(i + 1, 'Periodo ' + (i + 1), pa)).join('');
}
async function guardarPeriodos() {
  if (+$('#nPer').value !== periodos().length && !(await confirmar(`Va a cambiar el número de periodos de ${periodos().length} a ${$('#nPer').value}. Esto cambia el boletín y los promedios del año; las calificaciones ya registradas de periodos que desaparezcan dejarán de contar. ¿Continuar?`, 'Sí, cambiar periodos'))) return;
  const n = +$('#nPer').value, pw = Array.from({ length: n }, (_, i) => +$('#pw' + (i + 1)).value || 0);
  if (pw.reduce((a, b) => a + b, 0) !== 100) return toast('Los porcentajes de los periodos deben sumar 100');
  const fechas = Array.from({ length: n }, (_, i) => ({ inicio: $('#pi' + (i + 1)).value || '', fin: $('#pf' + (i + 1)).value || '', cierre: $('#pc' + (i + 1)).value || '' }));
  if (fechas.some(f => f.inicio && f.fin && f.fin < f.inicio)) return toast('La fecha de terminación no puede ser anterior a la de inicio');
  const es = escala(), mins = es.map((s, i) => Math.round(+$('#es' + i).value));
  if (mins[0] !== 0 || mins.some((m, i) => i && m <= mins[i - 1]) || mins[mins.length - 1] > 100) return toast('La escala va de 0 a 100: Bajo empieza en 0 y cada nivel debe empezar más arriba que el anterior');
  await guardarColegio({
    periodos: pw.map((peso, i) => ({ n: i + 1, peso, ...fechas[i] })), periodo_actual: Math.min(+$('#pAct').value || 1, n), max_perdidas: +$('#mxP').value || 1,
    escala: es.map((s, i) => ({ d: s.d, min: mins[i], max: i < es.length - 1 ? mins[i + 1] - 1 : 100 })),
  }, 'Periodos y escala guardados');
}
function paramGrupos() {
  return `<div class="panel"><div class="head" style="margin-bottom:10px"><h2 style="margin:0">Cursos</h2><button class="btn sm" type="button" onclick="formGrupo()">Nuevo curso</button></div>
      ${S.grupos.length ? `<div class="tbl"><table><thead><tr><th>Curso</th><th>Grado</th><th>Nivel</th><th>Director(a)</th><th>Estudiantes</th><th></th></tr></thead><tbody>${S.grupos.map(g => `<tr><td><strong>${esc(g.nombre)}</strong></td><td>${gradoTxt(g.grado)}</td><td>${NIVELES[g.nivel]}</td><td>${esc(g.director_nombre || '—')}</td><td>${estsDe(g.id).length}</td><td style="white-space:nowrap"><button class="btn ghost sm" type="button" onclick="formGrupo('${g.id}')">Editar</button> <button class="btn ghost sm" type="button" onclick="borrarGrupo('${g.id}')">Eliminar</button></td></tr>`).join('')}</tbody></table></div>` : '<p class="muted">Aún no hay cursos.</p>'}</div>`;
}

/* ---------- Costos del año ---------- */
const TIPOS_COSTO = { matricula: 'Matrícula', pension: 'Pensión', seguro: 'Seguro', carnet: 'Carnet', otro: 'Otro' };
const MESES = ['', 'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio', 'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre'];
function panelMediosPago() {
  const k = S.k, ro = !esRector();
  const chk = (id, l, v) => `<label class="chk"><input type="checkbox" id="${id}" ${v ? 'checked' : ''} ${ro ? 'disabled' : ''}> ${l}</label>`;
  return `<div class="panel"><h2>Cómo pueden pagar las familias</h2><p class="muted">Marque los medios que recibe el colegio. Las familias solo ven los que estén marcados, en su estado de cuenta. En todos los casos el acceso de la familia se habilita solo cuando el pago queda registrado.</p>
    <div class="formgrid">
      <div class="field full">${chk('mpEf', '<strong>Efectivo en la caja del colegio</strong>: la tesorería registra el pago y entrega el recibo.', k.pago_efectivo)}</div>
      ${fIn('mpEfTxt', 'Lugar y horario de la caja', k.pago_efectivo_texto || '', `placeholder="Ejemplo: Tesorería, lunes a viernes de 7:00 a. m. a 12:00 m." ${ro ? 'disabled' : ''}`)}
      <div class="field full">${chk('mpLl', '<strong>Llave Bre-B</strong>: la familia paga, oprime "Ya pagué" y sube el comprobante; la tesorería confirma que el dinero llegó.', k.pago_llave)}</div>
      ${fIn('mpLlV', 'Llave Bre-B (número, celular o correo)', k.pago_llave_valor || '', ro ? 'disabled' : '')}${fIn('mpLlT', 'Titular', k.pago_llave_titular || k.nombre, ro ? 'disabled' : '')}
      <div class="field full">${chk('mpBo', '<strong>Bold (tarjeta, PSE, Nequi)</strong>: pago en línea. Cuando Colegio-IA quede conectado con Bold, el pago se registra solo, sin intervención de la tesorería.', k.pago_bold)}</div>
      ${fIn('mpBoU', 'Enlace de pago de Bold del colegio', k.pago_bold_url || '', `placeholder="https://" ${ro ? 'disabled' : ''}`)}
      <div class="field full" style="margin-top:6px">${chk('mpRes', '<strong>Familias con pagos pendientes:</strong> mientras tengan cuotas sin pagar, solo ven comunicados, horario, excusas y estado de cuenta (no calificaciones, boletines, observador ni PIAR).', k.restringir_morosos)}</div>
    </div>
    ${ro ? '<p class="muted">Solo el rector o la rectora pueden cambiar los medios de pago.</p>' : '<div class="toolbar guardar-fijo"><button class="btn" type="button" onclick="guardarMediosPago()">Guardar medios de pago</button></div>'}</div>`;
}
async function guardarMediosPago() {
  const d = { pago_efectivo: $('#mpEf').checked, pago_efectivo_texto: vv('mpEfTxt') || null, pago_llave: $('#mpLl').checked, pago_llave_valor: vv('mpLlV') || null, pago_llave_titular: vv('mpLlT') || null,
    pago_bold: $('#mpBo').checked, pago_bold_url: vv('mpBoU') || null, restringir_morosos: $('#mpRes').checked };
  if (d.pago_llave && !d.pago_llave_valor) return toast('Escriba la llave o el número de cuenta');
  if (d.pago_bold_url) { const u = normUrl(d.pago_bold_url); if (!u) return toast('Ese enlace de Bold no parece válido. Cópielo tal como se lo da Bold, por ejemplo checkout.bold.co/payment/...'); d.pago_bold_url = u; }
  if (d.pago_bold && !d.pago_bold_url) return toast('Pegue el enlace de pago que le da Bold');
  if (!d.pago_efectivo && !d.pago_llave && !d.pago_bold) return toast('Marque al menos un medio de pago');
  await guardarColegio(d, 'Medios de pago guardados');
}
function paramCostos() {
  const c = costos || {};
  const gradosUsados = [...new Set(S.grupos.map(g => g.grado))].sort((a, b) => a - b);
  return `<div class="panel"><h2>Resolución de costos ${S.k.anio}</h2><p class="muted">Tarifas autorizadas por la Secretaría de Educación para el año lectivo.</p>
    <div class="formgrid">${fIn('cRes', 'Número de resolución', c.resolucion)}${fIn('cFec', 'Fecha de la resolución', c.fecha_resolucion, 'type="date"')}${fIn('cEnt', 'Entidad que la expide', c.entidad || 'Secretaría de Educación')}${fTa('cObs', 'Observaciones', c.observaciones)}</div>
    <div class="toolbar guardar-fijo"><button class="btn" type="button" onclick="guardarResolucion()">Guardar resolución</button></div></div>
  ${panelMediosPago()}
  <div class="panel"><h2>Día límite de pago</h2><p class="muted">Cada cuota mensual se considera vencida después de este día de su mes.</p>
    <div class="toolbar"><label class="field"><span>Pagar hasta el día</span><select id="cDia">${Array.from({ length: 28 }, (_, i) => opt(i + 1, i + 1, S.k.dia_limite_pago || 5)).join('')}</select></label>
    <button class="btn" type="button" onclick="guardarDiaLimite()">Guardar</button></div></div>
  <div class="panel"><div class="head" style="margin-bottom:10px"><div><h2 style="margin:0">Conceptos de cobro ${S.k.anio}</h2><p class="muted" style="margin:4px 0 0">Los cobros mensuales se generan solo en los meses marcados. Si un grado tiene tarifa distinta, escríbala en "Valor por grado".</p></div><button class="btn sm" type="button" onclick="formConcepto()">Nuevo concepto</button></div>
    ${conceptos.length ? `<div class="tbl"><table><thead><tr><th>Concepto</th><th>Tipo</th><th>Cobro</th><th>Valor</th><th>Por grado</th><th>Estado</th><th></th></tr></thead><tbody>
    ${conceptos.map(x => `<tr class="${x.activo ? '' : 'dim'}"><td><strong>${esc(x.nombre)}</strong></td><td>${TIPOS_COSTO[x.tipo]}</td><td>${x.periodicidad === 'mensual' ? `Mensual: ${x.meses.map(m => MESES[m].slice(0, 3)).join(', ')} (${x.meses.length} cuotas)` : `Único en ${MESES[x.mes_cobro]}`}</td><td>${cop(x.valor)}</td>
      <td>${Object.keys(x.valores_grado || {}).length ? Object.entries(x.valores_grado).map(([g, v]) => `${gradoTxt(+g)}: ${cop(v)}`).join('<br>') : '<span class="muted">Igual para todos</span>'}</td><td>${x.activo ? 'Activo' : 'Inactivo'}</td>
      <td style="white-space:nowrap"><button class="btn ghost sm" type="button" onclick="formConcepto('${x.id}')">Editar</button></td></tr>`).join('')}</tbody></table></div>` : '<p class="muted">Aún no hay conceptos para este año.</p>'}
    ${gradosUsados.length ? '' : '<p class="muted">Cree primero los cursos para poder fijar valores por grado.</p>'}</div>`;
}
async function guardarDiaLimite() { await guardarColegio({ dia_limite_pago: +$('#cDia').value }, 'Día límite guardado'); }
async function guardarResolucion() {
  const d = { colegio_id: ctx.colegio_id, anio: S.k.anio, resolucion: vv('cRes'), fecha_resolucion: vv('cFec') || null, entidad: vv('cEnt'), observaciones: vv('cObs') };
  const r = await guard(() => q(db.from('costos_anio').upsert(d, { onConflict: 'colegio_id,anio' }).select().single()), 'Resolución guardada');
  if (r) costos = r;
}
function formConcepto(id) {
  const x = id ? conceptos.find(c => c.id === id) : { nombre: '', tipo: 'otro', periodicidad: 'unico', valor: 0, valores_grado: {}, mes_cobro: 2, meses: [2, 3, 4, 5, 6, 7, 8, 9, 10, 11], activo: true };
  const grados = [...new Set(S.grupos.map(g => g.grado))].sort((a, b) => a - b);
  openModal(id ? 'Editar concepto' : 'Nuevo concepto', `<div class="formgrid">
    ${fIn('kNom', 'Nombre', x.nombre)}
    <label class="field"><span>Tipo</span><select id="kTipo">${Object.entries(TIPOS_COSTO).map(([v, l]) => opt(v, l, x.tipo)).join('')}</select></label>
    <label class="field"><span>Se cobra</span><select id="kPer" onchange="document.getElementById('kMeses').hidden=this.value!=='mensual';document.getElementById('kMesU').hidden=this.value==='mensual'">${opt('unico', 'Una sola vez', x.periodicidad)}${opt('mensual', 'Cada mes (cuotas)', x.periodicidad)}</select></label>
    ${fIn('kVal', 'Valor general', x.valor, 'type="number" min="0" step="1000"')}
    <label class="field" id="kMesU" ${x.periodicidad === 'mensual' ? 'hidden' : ''}><span>Mes de cobro</span><select id="kMes">${MESES.slice(1).map((m, i) => opt(i + 1, m, x.mes_cobro)).join('')}</select></label>
    <label class="field chk"><input id="kAct" type="checkbox" ${x.activo ? 'checked' : ''}> Activo</label></div>
    <div id="kMeses" ${x.periodicidad === 'mensual' ? '' : 'hidden'}><h3 style="margin-top:12px">Meses en que se cobra</h3><div class="toolbar">${MESES.slice(1).map((m, i) => `<label class="chk"><input type="checkbox" class="kMesChk" value="${i + 1}" ${x.meses.includes(i + 1) ? 'checked' : ''}> ${m.slice(0, 3)}</label>`).join('')}</div></div>
    ${grados.length ? `<h3 style="margin-top:12px">Valor por grado (opcional)</h3><p class="muted">Déjelo vacío para usar el valor general.</p><div class="formgrid">${grados.map(g => `<label class="field"><span>${gradoTxt(g)}</span><input type="number" min="0" step="1000" class="kGr" data-g="${g}" value="${x.valores_grado?.[g] ?? ''}"></label>`).join('')}</div>` : ''}
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" onclick="guardarConcepto('${id || ''}')">Guardar</button></div>`);
}
async function guardarConcepto(id) {
  const vg = {}; document.querySelectorAll('.kGr').forEach(i => { if (i.value !== '') vg[i.dataset.g] = +i.value; });
  const d = { nombre: vv('kNom'), tipo: vv('kTipo'), periodicidad: vv('kPer'), valor: +vv('kVal') || 0, valores_grado: vg, mes_cobro: +vv('kMes') || 2,
    meses: [...document.querySelectorAll('.kMesChk:checked')].map(i => +i.value), activo: vv('kAct') };
  if (!d.nombre) return toast('Escriba el nombre del concepto');
  if (d.periodicidad === 'mensual' && !d.meses.length) return toast('Marque al menos un mes de cobro');
  const r = await guard(() => id ? q(db.from('conceptos').update(d).eq('id', id).select().single())
    : q(db.from('conceptos').insert({ ...d, colegio_id: ctx.colegio_id, anio: S.k.anio, orden: conceptos.length + 1 }).select().single()), 'Concepto guardado');
  if (r) { await cargarCostos(); closeModal(); render(); }
}

/* ---------- Cierre de año y promoción ---------- */
let cierre = [];
async function prepCierre() {
  for (const g of S.grupos) await cargarGrupo(g.id);
  cierre = S.ests.filter(e => e.estado === 'Activo').map(e => {
    const g = grupo(e.grupo_id), sig = S.grupos.filter(x => x.grado === (g?.grado ?? 0) + 1);
    const res = g?.grado === 11 ? (perdidas(e.id).length > S.k.max_perdidas ? 'No promovido' : 'Graduado')
      : (g?.nivel !== 'preescolar' && perdidas(e.id).length > S.k.max_perdidas ? 'No promovido' : 'Promovido');
    return { id: e.id, resultado: res, destino: res === 'Promovido' ? (sig[0]?.id || '') : res === 'No promovido' ? e.grupo_id : '' };
  });
}
function paramCierre() {
  if (!esRector()) return '<div class="panel">Solo el rector o la rectora pueden cerrar el año lectivo.</div>';
  const porG = S.grupos.map(g => ({ g, es: estsDe(g.id) })).filter(x => x.es.length);
  const sinCurso = sinCursoSiguiente();
  return (sinCurso.length ? `<div class="note bloqueo"><strong>Hay ${sinCurso.length} estudiante(s) promovido(s) sin curso del grado siguiente</strong> (${[...new Set(sinCurso.map(c => grupo(est(c.id)?.grupo_id)?.nombre))].map(esc).join(', ')}). Si cierra así, seguirían en el mismo curso. Cree primero el curso del grado siguiente en <button class="linkbtn" type="button" onclick="irPtab('grupos')">Cursos</button> o elija el curso de destino en la tabla.</div>` : '') + `<div class="note">Al cerrar el año ${S.k.anio}: cada estudiante queda en su nuevo curso, el sistema guarda su resultado en el historial, el año pasa a ${S.k.anio + 1} y se copian los costos como punto de partida. Esta acción no se puede deshacer. Revise la propuesta: el sistema sugiere "No promovido" cuando hay más de ${S.k.max_perdidas} asignaturas en bajo.</div>
  ${porG.map(({ g, es }) => `<div class="panel"><h2>${esc(g.nombre)}</h2><div class="tbl"><table><thead><tr><th>Estudiante</th><th>En bajo</th><th>Resultado</th><th>Curso ${S.k.anio + 1}</th></tr></thead><tbody>
    ${es.map(e => { const c = cierre.find(x => x.id === e.id) || { resultado: 'Promovido', destino: '' }; return `<tr><td>${esc(e.apellidos)} ${esc(e.nombres)}</td><td>${perdidas(e.id).length}</td>
      <td><select onchange="setCierre('${e.id}','resultado',this.value)">${['Promovido', 'No promovido', 'Graduado'].map(r => opt(r, r, c.resultado)).join('')}</select></td>
      <td>${c.resultado === 'Graduado' ? '<span class="muted">Egresa</span>' : `<select onchange="setCierre('${e.id}','destino',this.value)"><option value="">Mismo curso</option>${S.grupos.map(x => opt(x.id, x.nombre, c.destino)).join('')}</select>`}</td></tr>`; }).join('')}
  </tbody></table></div></div>`).join('')}
  ${porG.length ? `<div class="toolbar"><button class="btn warn" type="button" onclick="confirmarCierre()">Cerrar el año ${S.k.anio}</button></div>` : '<div class="panel empty">No hay estudiantes activos.</div>'}`;
}
function setCierre(id, k, v) { const c = cierre.find(x => x.id === id); if (!c) return; c[k] = v; render(); }
// Promovidos que quedarían en el mismo curso porque no existe el curso del grado siguiente
function sinCursoSiguiente() { return cierre.filter(c => c.resultado === 'Promovido' && (!c.destino || c.destino === est(c.id)?.grupo_id)); }
async function confirmarCierre() {
  const n = cierre.length, hoyD = new Date();
  if (hoyD.getFullYear() === S.k.anio && hoyD.getMonth() < 11 && !await confirmar(`El año lectivo ${S.k.anio} termina el 31 de diciembre y aún no estamos en diciembre. ¿Desea cerrarlo de todas formas?`)) return;
  const sc = sinCursoSiguiente().length;
  if (sc && !await confirmar(`${sc} estudiante(s) promovido(s) quedarían en el mismo curso porque no hay curso del grado siguiente. ¿Desea cerrar el año de todas formas?`)) return;
  if (!await confirmar(`Se cerrará el año ${S.k.anio} para ${n} estudiantes y el colegio pasará al año ${S.k.anio + 1}. ¿Continuar?`)) return;
  const dec = cierre.map(c => ({ estudiante_id: c.id, resultado: c.resultado, grupo_destino: c.destino || '' }));
  const r = await guard(() => q(db.rpc('cerrar_anio', { p_colegio: ctx.colegio_id, p_decisiones: dec })));
  if (r) { sel.ptab = 'inst'; cierre = []; try { sessionStorage.setItem('genesis:ir', 'inicio'); } catch {} toast(`Año cerrado. Bienvenido al año ${r.nuevo_anio}`); await entrarContexto(ctx.id); }
}

const GRADOS = { '-2': 'Prejardín', '-1': 'Jardín', '0': 'Transición', 1: 'Primero', 2: 'Segundo', 3: 'Tercero', 4: 'Cuarto', 5: 'Quinto', 6: 'Sexto', 7: 'Séptimo', 8: 'Octavo', 9: 'Noveno', 10: 'Décimo', 11: 'Undécimo' };
const gradoTxt = g => GRADOS[g] ?? g;
const nivelDe = g => g <= 0 ? 'preescolar' : g <= 5 ? 'primaria' : g <= 9 ? 'secundaria' : 'media';
// Listas preestablecidas: dimensiones de preescolar y áreas obligatorias de la Ley 115 de 1994 (art. 23 y 31)
const PRESET_ASIG = {
  preescolar: ['Dimensión comunicativa', 'Dimensión cognitiva', 'Dimensión corporal', 'Dimensión socioafectiva', 'Dimensión estética', 'Dimensión ética', 'Dimensión espiritual'],
  primaria: ['Ciencias naturales y educación ambiental', 'Ciencias sociales', 'Educación artística y cultural', 'Educación ética y en valores humanos', 'Educación física, recreación y deportes', 'Educación religiosa', 'Lengua castellana', 'Inglés', 'Matemáticas', 'Tecnología e informática'],
};
PRESET_ASIG.secundaria = PRESET_ASIG.primaria;
PRESET_ASIG.media = [...PRESET_ASIG.primaria, 'Química', 'Física', 'Filosofía', 'Ciencias económicas y políticas'];
const GRADOS_NIVEL = { preescolar: [-2, -1, 0], primaria: [1, 2, 3, 4, 5], secundaria: [6, 7, 8, 9], media: [10, 11] };
const gradosTxt = a => a.grados?.length ? a.grados.slice().sort((x, y) => x - y).map(gradoTxt).join(', ') : 'Todos los grados del nivel';
function planHTML(n) {
  const as = S.asigs.filter(a => a.nivel === n).sort((a, b) => a.orden - b.orden), tipo = n === 'preescolar' ? 'dimensión' : 'asignatura';
  const ya = new Set(as.map(a => a.nombre.toLowerCase()));
  return `<div class="tbl"><table><thead><tr><th>Nombre</th><th>Horas por semana</th><th>Grados</th><th>Orden</th><th></th></tr></thead><tbody>
    ${as.map(a => `<tr><td><input value="${esc(a.nombre)}" maxlength="80" onchange="editAsig('${a.id}',{nombre:this.value.trim()})"></td><td><input type="number" min="0" max="40" value="${a.ih}" style="width:70px" onchange="editAsig('${a.id}',{ih:+this.value},this)"></td>
      <td><button class="linkbtn" type="button" onclick="formGradosAsig('${a.id}')">${esc(gradosTxt(a))}</button></td><td><input type="number" value="${a.orden}" style="width:60px" onchange="editAsig('${a.id}',{orden:+this.value})"></td><td><button class="btn ghost sm" type="button" onclick="borrarAsig('${a.id}')">Eliminar</button></td></tr>`).join('') || `<tr><td colspan="5" class="muted">Aún no hay ${tipo === 'dimensión' ? 'dimensiones' : 'asignaturas'} en este nivel.</td></tr>`}
  </tbody></table></div>
  <div class="panel sub"><h3>Agregar ${tipo}</h3><div class="formgrid">
    <label class="field"><span>Elija de la lista${n === 'preescolar' ? ' (dimensiones del preescolar)' : ' (áreas obligatorias, Ley 115)'}</span><select id="naSel" onchange="document.getElementById('naNom').value=this.value"><option value="">Otra (escríbala abajo)…</option>${PRESET_ASIG[n].filter(x => !ya.has(x.toLowerCase())).map(x => opt(x, x)).join('')}</select></label>
    ${fIn('naNom', 'Nombre', '', 'maxlength="80"')}${fIn('naIh', 'Horas por semana (0 a 40)', 1, 'type="number" min="0" max="40"')}
    <div class="field full"><span>Grados donde se dicta (si no marca ninguno, en todos los del nivel)</span><div class="cuotas">${GRADOS_NIVEL[n].map(g => `<label class="chk"><input type="checkbox" class="naG" value="${g}"> ${gradoTxt(g)}</label>`).join('')}</div></div></div>
    <div class="toolbar" style="margin-top:10px"><button class="btn" type="button" id="naBtn" onclick="nuevaAsig('${n}')">Agregar ${tipo}</button></div></div>`;
}
function planTabs() {
  const n = sel.nivel || 'primaria';
  return `<div class="panel"><h2>Plan de estudios</h2><p class="muted">Asignaturas (o dimensiones en preescolar) por nivel, con sus horas semanales. Puede indicar en qué grados se dicta cada una: por ejemplo, una asignatura solo para Quinto.</p>
    <div class="tabs" role="tablist">${Object.entries(NIVELES).map(([k, l]) => `<button type="button" role="tab" aria-selected="${n === k}" onclick="sel.nivel='${k}';render()">${l}</button>`).join('')}</div>${planHTML(n)}</div>`;
}
// Avisos de sensatez: nombres que no corresponden al nivel
function rarezaAsig(n, nombre) {
  const t = nombre.toLowerCase();
  if (n === 'preescolar' && /álgebra|algebra|cálculo|calculo|trigonom|física|fisica|química|quimica|filosof|geometría analítica|estadística/.test(t)) return `"${nombre}" no es habitual en preescolar, donde se trabaja por dimensiones del desarrollo.`;
  if ((n === 'secundaria' || n === 'media') && /pre ?escritura|pre ?matem|aprestamiento|dimensión|dimension|pre ?lectura/.test(t)) return `"${nombre}" es propia del preescolar, no de ${NIVELES[n].toLowerCase()}.`;
  if (n === 'primaria' && /cálculo|calculo|trigonom|física nuclear|química orgánica|filosof/.test(t)) return `"${nombre}" no es habitual en primaria.`;
  return '';
}
async function formGradosAsig(id) {
  const a = S.asigs.find(x => x.id === id);
  openModal(`Grados de ${a.nombre}`, `<p class="muted">Marque los grados donde se dicta. Si no marca ninguno, se dicta en todos los grados del nivel.</p>
    <div class="cuotas">${GRADOS_NIVEL[a.nivel].map(g => `<label class="chk"><input type="checkbox" class="gaG" value="${g}" ${a.grados?.includes(g) ? 'checked' : ''}> ${gradoTxt(g)}</label>`).join('')}</div>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" onclick="guardarGradosAsig('${id}')">Guardar</button></div>`);
}
async function guardarGradosAsig(id) {
  const grados = [...document.querySelectorAll('.gaG:checked')].map(x => +x.value);
  const r = await guard(() => q(db.from('asignaturas').update({ grados }).eq('id', id).select().single()), 'Grados guardados');
  if (r) { Object.assign(S.asigs.find(a => a.id === id), r); closeModal(); render(); }
}
function docentesSel(g) {
  const ds = (S.miembros || []).filter(m => m.rol === 'docente' && m.activo);
  if (!ds.length) return `<p class="muted full">Para elegir el director(a) de grupo, primero invite a los docentes en <strong>Usuarios y accesos</strong>. Luego lo elige aquí de la lista.</p>`;
  return `<label class="field"><span>Director(a) de grupo</span><select id="gDirM"><option value="">Sin asignar</option>${ds.map(m => opt(m.id, m.nombre, g.director_miembro_id || '')).join('')}</select></label>`;
}
function formGrupo(id) {
  const g = id ? grupo(id) : { nombre: '', grado: 1, director_nombre: '' };
  openModal(id ? 'Editar grupo' : 'Nuevo grupo', `<div class="formgrid">
    <label class="field"><span>Grado</span><select id="gGr">${Object.entries(GRADOS).sort((a, b) => a[0] - b[0]).map(([v, l]) => opt(v, l, g.grado)).join('')}</select></label>
    <label class="field"><span>Nombre del grupo</span><input id="gNom" value="${esc(g.nombre)}" placeholder="Por ejemplo: Tercero A"></label>
    ${docentesSel(g)}</div>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" onclick="guardarGrupo('${id || ''}')">Guardar</button></div>`);
}
async function guardarGrupo(id) {
  const grado = +$('#gGr').value;
  const dm = $('#gDirM')?.value || null, doc = (S.miembros || []).find(m => m.id === dm);
  const d = { grado, nivel: nivelDe(grado), nombre: $('#gNom').value.trim() || gradoTxt(grado), director_nombre: doc ? doc.nombre : (id ? grupo(id)?.director_nombre || '' : ''), director_miembro_id: doc ? doc.id : null };
  if (!/[a-záéíóúñ]/i.test(d.nombre)) return toast('Escriba el nombre del curso, por ejemplo Séptimo A');
  const r = await guard(() => id ? q(db.from('grupos').update(d).eq('id', id).select().single()) : q(db.from('grupos').insert({ ...d, colegio_id: ctx.colegio_id }).select().single()), 'Grupo guardado');
  if (!r) return;
  if (id) Object.assign(grupo(id), r); else S.grupos.push(r);
  S.grupos.sort((a, b) => a.grado - b.grado || a.nombre.localeCompare(b.nombre, 'es'));
  closeModal(); render();
}
async function borrarGrupo(id) {
  if (S.ests.some(e => e.grupo_id === id)) return toast('El grupo tiene estudiantes. Muévelos a otro grupo antes de eliminarlo');
  if (!await confirmar('¿Eliminar este grupo?')) return;
  const ok = await guard(async () => { await q(db.from('grupos').delete().eq('id', id)); return true; }, 'Grupo eliminado');
  if (ok) { S.grupos = S.grupos.filter(g => g.id !== id); render(); }
}
async function editAsig(id, d, el) {
  if ('ih' in d && !(d.ih >= 0 && d.ih <= 40)) { toast('Las horas por semana van de 0 a 40'); if (el) el.value = S.asigs.find(a => a.id === id)?.ih ?? 1; return; }
  if ('nombre' in d && d.nombre.length < 3) return toast('Escriba el nombre completo');
  const r = await guard(() => q(db.from('asignaturas').update(d).eq('id', id).select().single()), 'Guardado');
  if (r) Object.assign(S.asigs.find(a => a.id === id), r);
}
async function nuevaAsig(n) {
  const nombre = $('#naNom').value.trim(); if (nombre.length < 3) return toast('Elija de la lista o escriba el nombre');
  const ih = +$('#naIh').value; if (!(ih >= 0 && ih <= 40)) return toast('Las horas por semana van de 0 a 40');
  if (S.asigs.some(a => a.nivel === n && a.nombre.toLowerCase() === nombre.toLowerCase())) return toast('Ya existe con ese nombre en este nivel');
  const raro = rarezaAsig(n, nombre); if (raro && !(await confirmar(raro + ' ¿Desea agregarla de todas formas?', 'Sí, agregar'))) return;
  const grados = [...document.querySelectorAll('.naG:checked')].map(x => +x.value);
  const codigo = nombre.normalize('NFD').replace(/[^a-zA-Z]/g, '').slice(0, 6).toLowerCase() + Math.random().toString(36).slice(2, 5);
  const orden = Math.max(0, ...S.asigs.filter(a => a.nivel === n).map(a => a.orden)) + 1;
  const r = await guard(() => q(db.from('asignaturas').insert({ colegio_id: ctx.colegio_id, nivel: n, codigo, nombre, ih, orden, grados }).select().single()), 'Agregada');
  if (r) { S.asigs.push(r); render(); }
}
async function borrarAsig(id) {
  if (!await confirmar('Se eliminarán también las calificaciones registradas en esta asignatura. ¿Continuar?')) return;
  const ok = await guard(async () => { await q(db.from('asignaturas').delete().eq('id', id)); return true; }, 'Eliminada');
  if (ok) { S.asigs = S.asigs.filter(a => a.id !== id); render(); }
}

/* =====================================================================
   Pagos y cartera (rector, secretaría, tesorería)
   ===================================================================== */
let cartera = [];
async function prepPagos() {
  const [c, a] = await Promise.all([
    q(db.rpc('cartera', { p_colegio: ctx.colegio_id, p_anio: anioCartera() })),
    all(() => db.from('acudientes').select('estudiante_id,nombres,telefono,responsable_pago,orden').eq('colegio_id', ctx.colegio_id).order('estudiante_id').order('orden')),
  ]);
  cartera = c; S.acud = a;
  comps = await all(() => db.from('comprobantes').select('id,estudiante_id,fecha,valor,medio,referencia,nota,estado,respuesta,enviado_por,revisado_por,creado_en').eq('colegio_id', ctx.colegio_id).eq('estado', 'Pendiente').order('creado_en')).catch(() => []);
}
function avisoMora(x) {
  const l = (S.acud || []).filter(a => a.estudiante_id === x.estudiante_id), a = l.find(y => y.responsable_pago) || l[0];
  const txt = `Hola${a?.nombres ? ', ' + a.nombres.split(' ')[0] : ''}. ${S.k.nombre} le recuerda que ${x.nombre} tiene un saldo vencido de ${cop(x.saldo_vencido)} a la fecha. Puede consultar el detalle en Colegio-IA: ${location.origin + location.pathname}. Si ya realizó el pago, por favor envíenos el comprobante. Gracias.`;
  const tel = a?.telefono || est(x.estudiante_id)?.acudiente_tel;
  return tel ? waBtn(tel, txt, 'WhatsApp') : '';
}
const anioCartera = () => sel.panio || S.k.anio;
async function cambiarAnioCartera(v) { sel.panio = +v === S.k.anio ? 0 : +v; sel.pg = ''; await refrescar(prepPagos); }
function vPagos() {
  const qq = (sel.pq || '').toLowerCase().trim(), fg = sel.pg || '', solo = sel.pmora || false;
  const l = cartera.filter(x => (!fg || x.grupo === fg) && (!qq || x.nombre.toLowerCase().includes(qq)) && (!solo || +x.saldo_vencido > 0));
  const tot = k => cartera.reduce((a, x) => a + +x[k], 0);
  return head('Pagos y cartera', `Año ${anioCartera()}. Cada pago queda registrado con el nombre de quien lo recibió.`,
    `<div class="toolbar" style="margin:0"><button class="btn ghost" type="button" onclick="exportarCartera()">Exportar a Excel</button><button class="btn ghost" type="button" onclick="imprimirCartera()">Imprimir cartera</button></div>`) + panelComprobantes() +
    `<div class="stats"><div class="stat"><div class="n">${cop(tot('pagado'))}</div><div class="l">Recaudado</div></div>
      <div class="stat"><div class="n">${cop(tot('saldo_vencido'))}</div><div class="l">Saldo vencido</div></div>
      <div class="stat"><div class="n">${cop(tot('saldo_total'))}</div><div class="l">Saldo total del año</div></div>
      <div class="stat"><div class="n">${cartera.filter(x => +x.saldo_vencido > 0).length}</div><div class="l">Estudiantes en mora</div></div></div>
    <div class="panel"><div class="toolbar">
      <label class="field"><span>Año</span><select onchange="cambiarAnioCartera(this.value)">${[0, 1, 2, 3].map(i => S.k.anio - i).filter(a => a >= new Date(S.k.creado_en || Date.now()).getFullYear()).map(a => opt(a, a, anioCartera())).join('')}</select></label>
      <label class="field"><span>Curso</span><select onchange="sel.pg=this.value;render()"><option value="">Todos</option>${[...new Set(cartera.map(x => x.grupo).filter(Boolean))].map(g => opt(g, g, fg)).join('')}</select></label>
      <label class="field"><span>Buscar</span><input type="search" value="${esc(sel.pq || '')}" placeholder="Nombre" onchange="sel.pq=this.value;render()"></label>
      <label class="chk"><input type="checkbox" ${solo ? 'checked' : ''} onchange="sel.pmora=this.checked;render()"> Solo con saldo vencido</label></div>
    ${l.length ? `<div class="tbl"><table><thead><tr><th>Estudiante</th><th>Curso</th><th>Cobrado</th><th>Pagado</th><th>Vencido</th><th>Saldo del año</th><th></th></tr></thead><tbody>
      ${l.map(x => `<tr class="${x.estado === 'Activo' ? '' : 'dim'}"><td><strong>${esc(x.nombre)}</strong>${x.estado !== 'Activo' ? ` <span class="tag">${x.estado}</span>` : ''}</td><td>${esc(x.grupo || '—')}</td><td>${cop(x.cobrado)}</td><td>${cop(x.pagado)}</td>
        <td>${+x.saldo_vencido > 0 ? `<strong style="color:var(--red)">${cop(x.saldo_vencido)}</strong>` : cop(0)}</td><td>${cop(x.saldo_total)}</td>
        <td style="white-space:nowrap"><button class="btn sm" type="button" onclick="abrirCuenta('${x.estudiante_id}', ${anioCartera()})">Ver y registrar pago</button> ${+x.saldo_vencido > 0 ? avisoMora(x) : ''}</td></tr>`).join('')}</tbody></table></div>` : `<div class="empty">${conceptosVacios()}</div>`}</div>`;
}
const conceptosVacios = () => cartera.length ? 'No hay estudiantes con ese filtro.' : 'Aún no hay estudiantes o costos. Configure los costos del año en Parametrización.';
let cuenta = { eid: null, anio: 0, filas: [], pagos: [], prevFilas: [] };
// Estado de cuenta de un año; si es el año en curso, también trae lo que quedó debiendo del año anterior
async function cargarCuenta(eid, anio = S.k.anio) {
  const [filas, pagos, prevFilas] = await Promise.all([
    q(db.rpc('estado_cuenta', { p_estudiante: eid, p_anio: anio })),
    q(db.from('pagos').select('*').eq('estudiante_id', eid).eq('anio', anio).order('fecha', { ascending: false }).order('recibo', { ascending: false })),
    anio === S.k.anio ? deudasAnteriores(eid) : [],
  ]);
  cuenta = { eid, anio, filas, pagos, prevFilas };
}
// Saldos pendientes de los años anteriores (hasta 5 años atrás, desde el año en que el colegio empezó en Colegio-IA)
async function deudasAnteriores(eid) {
  const desde = Math.max(S.k.anio - 5, new Date(S.k.creado_en || Date.now()).getFullYear());
  const anios = []; for (let a = S.k.anio - 1; a >= desde; a--) anios.push(a);
  const res = await Promise.all(anios.map(a => q(db.rpc('estado_cuenta', { p_estudiante: eid, p_anio: a })).then(l => l.filter(x => +x.saldo > 0).map(x => ({ ...x, vencido: true, anioCobro: a }))).catch(() => [])));
  return res.flat().sort((x, y) => x.anioCobro - y.anioCobro || x.mes - y.mes);
}
const aniosConDeuda = () => [...new Set(cuenta.prevFilas.map(x => x.anioCobro))];
const saldoPrevio = () => cuenta.prevFilas.reduce((a, x) => a + +x.saldo, 0);
async function abrirCuenta(eid, anio) {
  const ok = await guard(async () => { await cargarCuenta(eid, anio || S.k.anio); return true; });
  if (ok) modalCuenta();
}
function tablaCuenta(conCheck) {
  // La familia ve lo pagado y lo pendiente a hoy; no se le muestran las cuotas futuras (no presionar)
  const f = isFam() ? cuenta.filas.filter(x => x.vencido || +x.pagado > 0) : cuenta.filas;
  return f.length ? `<div class="tbl"><table><thead><tr>${conCheck ? '<th></th>' : ''}<th>Concepto</th><th>Mes</th><th>Valor</th><th>Pagado</th><th>Saldo</th></tr></thead><tbody>
    ${f.map((x, i) => `<tr>${conCheck ? `<td>${+x.saldo > 0 ? `<input type="checkbox" class="cuotaChk" value="${i}" aria-label="Pagar ${esc(x.concepto)} ${MESES[x.mes]}">` : ''}</td>` : ''}
      <td>${esc(x.concepto)}</td><td>${MESES[x.mes]}</td><td>${cop(x.valor)}</td><td>${cop(x.pagado)}</td>
      <td>${+x.saldo > 0 ? `<strong style="color:${x.vencido ? 'var(--red)' : 'inherit'}">${cop(x.saldo)}</strong>${x.vencido ? ` <span class="tag t3">${isFam() ? 'Pendiente por pagar' : 'Vencido'}</span>` : ''}` : '<span class="tag">Pagado</span>'}</td></tr>`).join('')}
    </tbody></table></div>` : '<p class="muted">No hay cobros para este estudiante en el año.</p>';
}
const nomConcepto = x => { const c = conceptos.find(k => k.id === x.concepto_id) || cuenta.filas.find(k => k.concepto_id === x.concepto_id); return `${c?.nombre || c?.concepto || 'Pago'}${x.mes ? ' ' + MESES[x.mes] : ''}`; };
function recibos() {
  const m = new Map();
  cuenta.pagos.forEach(p => { if (!m.has(p.recibo)) m.set(p.recibo, []); m.get(p.recibo).push(p); });
  return [...m.entries()].map(([n, l]) => ({ n, l, p: l[0], total: l.reduce((a, x) => a + +x.valor, 0) }));
}
function tablaPagos(conAcciones) {
  const rs = recibos();
  return rs.length ? `<div class="tbl"><table><thead><tr><th>Recibo</th><th>Fecha</th><th>Conceptos</th><th>Valor</th><th>Medio</th><th>Registró</th>${conAcciones ? '<th></th>' : ''}</tr></thead><tbody>
    ${rs.map(({ n, l, p, total }) => `<tr class="${p.anulado ? 'dim' : ''}"><td>${n}</td><td>${fmtF(p.fecha)}</td><td>${l.map(x => `${esc(nomConcepto(x))}${l.length > 1 ? ` <span class="muted">${cop(x.valor)}</span>` : ''}`).join('<br>')}</td><td>${cop(total)}</td><td>${esc(p.medio || '')}${p.referencia ? `<br><span class="muted">${esc(p.referencia)}</span>` : ''}</td>
      <td>${esc(p.registrado_nombre || '')}<br><span class="muted">${new Date(p.registrado_en).toLocaleString('es-CO')}</span>${p.anulado ? `<br><span class="tag t3">Anulado por ${esc(p.anulado_por || '')}</span> <span class="muted">${esc(p.anulado_motivo || '')}</span>` : ''}</td>
      ${conAcciones ? `<td style="white-space:nowrap">${p.anulado ? '' : `<button class="btn ghost sm" type="button" onclick="reciboPago(${n})">Recibo</button> <button class="btn ghost sm" type="button" onclick="anularPago(${n})">Anular</button>`}</td>` : ''}</tr>`).join('')}
    </tbody></table></div>` : '<p class="muted">Aún no hay pagos registrados.</p>';
}
function modalCuenta() {
  const e = est(cuenta.eid), saldo = cuenta.filas.reduce((a, x) => a + +x.saldo, 0), venc = cuenta.filas.filter(x => x.vencido).reduce((a, x) => a + +x.saldo, 0);
  const previo = saldoPrevio(), otro = cuenta.anio !== S.k.anio;
  openModal(`Estado de cuenta ${cuenta.anio}: ${nom(e)}`, `${previo > 0 ? `<div class="note bloqueo">Tiene saldos pendientes de años anteriores por <strong>${cop(previo)}</strong>: ${aniosConDeuda().map(a => `${a}: ${cop(cuenta.prevFilas.filter(x => x.anioCobro === a).reduce((s, x) => s + +x.saldo, 0))} <button class="linkbtn" type="button" onclick="abrirCuenta('${cuenta.eid}', ${a})">ver y registrar pago</button>`).join(' · ')}</div>` : ''}
    ${otro ? `<div class="note">Está viendo el año <strong>${cuenta.anio}</strong>. Los pagos que registre aquí se aplican a ese año. <button class="linkbtn" type="button" onclick="abrirCuenta('${cuenta.eid}')">Volver a ${S.k.anio}</button></div>` : ''}<p class="muted">${esc(grupo(e.grupo_id)?.nombre || '')} · Debe a la fecha: <strong style="color:${venc ? 'var(--red)' : 'inherit'}">${cop(venc)}</strong> · Saldo del año: <strong>${cop(saldo)}</strong>${e.estado !== 'Activo' ? ` · ${e.estado}${e.fecha_retiro ? ' el ' + fmtF(e.fecha_retiro) : ''}` : ''}</p>
    <h3>Registrar pago</h3>
    <p class="muted">Escriba el valor que le entregan. Colegio-IA lo aplica solo, empezando por las cuotas más antiguas.</p>
    <div class="formgrid">${fIn('pVal', 'Valor recibido', '', 'type="number" min="1" oninput="previewPago()"')}${fIn('pFec', 'Fecha', hoy(), 'type="date"')}
      <label class="field"><span>Medio de pago</span><select id="pMed">${['Efectivo', 'Transferencia', 'Consignación', 'Tarjeta', 'Nequi', 'Daviplata', 'PSE', 'Otro'].map(x => opt(x, x)).join('')}</select></label>
      ${fIn('pRef', 'Referencia o comprobante (opcional)', '')}</div>
    <div id="pPrev" class="muted" style="margin-top:8px"></div>
    <div class="toolbar" style="margin-top:10px"><button class="btn" type="button" id="pBtn" onclick="registrarPago()">Registrar pago</button>
      <button class="btn ghost" type="button" onclick="pazYSalvo('${cuenta.eid}')">${venc ? 'Constancia de deuda' : 'Paz y salvo'}</button></div>
    <h3 style="margin-top:14px">Cobros del año</h3>${tablaCuenta(false)}
    <h3 style="margin-top:14px">Pagos del año</h3>${tablaPagos(true)}`);
}
// Reparte un valor entre las cuotas pendientes, de la más antigua a la más reciente
function repartirPago(valor) {
  const pend = cuenta.filas.filter(x => +x.saldo > 0).slice().sort((a, b) => (b.vencido - a.vencido) || (a.mes - b.mes));
  const out = []; let resto = valor;
  for (const x of pend) { if (resto <= 0) break; const v = Math.min(resto, +x.saldo); out.push({ x, v }); resto -= v; }
  return { out, resto };
}
function previewPago() {
  const v = +vv('pVal') || 0, el = $('#pPrev'); if (!el) return;
  if (v <= 0) { el.innerHTML = ''; return; }
  const { out, resto } = repartirPago(v);
  el.innerHTML = out.length ? `Se aplicará a: ${out.map(({ x, v }) => `${esc(x.concepto)} ${MESES[x.mes] || ''} ${cop(v)}${v < +x.saldo ? ' (abono)' : ''}`).join(', ')}.${resto > 0 ? ` <strong style="color:var(--red)">Sobran ${cop(resto)}: el valor supera lo que debe en el año.</strong>` : ''}` : 'No hay cuotas pendientes.';
}
async function registrarPago() {
  const valor = Math.round(+vv('pVal') || 0);
  if (valor <= 0) return toast('Escriba el valor recibido');
  const { out, resto } = repartirPago(valor);
  if (!out.length) return toast('Este estudiante no tiene cuotas pendientes');
  if (resto > 0) return toast(`El valor supera el saldo del año en ${cop(resto)}`);
  const base = { estudiante_id: cuenta.eid, colegio_id: ctx.colegio_id, anio: cuenta.anio || S.k.anio, fecha: vv('pFec') || hoy(), medio: vv('pMed'), referencia: vv('pRef') };
  const lote = crypto.randomUUID();
  const r = await guard(() => q(db.from('pagos').insert(out.map(({ x, v }) => ({ ...base, lote, concepto_id: x.concepto_id, mes: x.mes, valor: v }))).select('recibo')));
  if (r) { toast(`Pago de ${cop(valor)} registrado. Recibo No. ${r[0].recibo}`); await cargarCuenta(cuenta.eid, cuenta.anio); await prepPagos(); render(); modalCuenta(); reciboPago(r[0].recibo); }
}
async function anularPago(n) {
  const motivo = await pedirTexto(`Motivo de la anulación del recibo No. ${n} (queda registrado):`);
  if (!motivo) return;
  const ok = await guard(() => q(db.from('pagos').update({ anulado: true, anulado_motivo: motivo }).eq('colegio_id', S.k.id).eq('recibo', n).eq('anulado', false)), `Recibo No. ${n} anulado`);
  if (ok !== undefined) { await cargarCuenta(cuenta.eid, cuenta.anio); await prepPagos(); render(); modalCuenta(); }
}
function reciboPago(n) {
  const r = recibos().find(x => x.n === n); if (!r) return;
  const p = r.p, e = est(p.estudiante_id);
  showDocs(`<section class="doc">${docHead(`Recibo de pago No. ${n}`, fmtF(p.fecha))}
    <div class="dgrid">${dato('Estudiante', nom(e))}${dato('Documento', `${e.tipo_doc} ${e.doc}`)}${dato('Curso', grupo(e.grupo_id)?.nombre)}
    ${dato('Medio de pago', p.medio + (p.referencia ? ` (${p.referencia})` : ''))}${dato('Año', p.anio)}${dato('Total pagado', cop(r.total))}</div>
    <table><thead><tr><th>Concepto</th><th style="text-align:right">Valor</th></tr></thead><tbody>
    ${r.l.map(x => `<tr><td>${esc(nomConcepto(x))}</td><td style="text-align:right">${cop(x.valor)}</td></tr>`).join('')}
    <tr><td><strong>Total</strong></td><td style="text-align:right"><strong>${cop(r.total)}</strong></td></tr></tbody></table>
    <p class="dnote">Recibido por ${esc(p.registrado_nombre || '')} el ${new Date(p.registrado_en).toLocaleString('es-CO')}${costos?.resolucion ? `. Tarifas autorizadas mediante ${esc(costos.resolucion)}` : ''}.</p>
    ${firmas(['Recibido por', p.registrado_nombre])}</section>`, 'Recibo');
}
function imprimirCartera() {
  const l = cartera.filter(x => +x.saldo_total > 0);
  showDocs(`<section class="doc">${docHead('Informe de cartera', `Año ${anioCartera()}<br>Corte ${fmtF(hoy())}`)}
    <table><thead><tr><th>Estudiante</th><th>Curso</th><th>Cobrado</th><th>Pagado</th><th>Vencido</th><th>Saldo</th></tr></thead><tbody>
    ${l.map(x => `<tr><td>${esc(x.nombre)}</td><td>${esc(x.grupo || '')}</td><td>${cop(x.cobrado)}</td><td>${cop(x.pagado)}</td><td>${cop(x.saldo_vencido)}</td><td>${cop(x.saldo_total)}</td></tr>`).join('')}
    </tbody></table>${firmas(['Tesorería', ''], ['Rector(a)', S.k.rector_nombre])}</section>`, 'Cartera');
}

/* ---------- Estado de cuenta para el acudiente ---------- */
async function prepCuenta() {
  const h = hermanos();
  S.cuentaHijos = h.length > 1 ? await Promise.all(h.map(async m => { const f = await q(db.rpc('estado_cuenta', { p_estudiante: m.estudiante_id, p_anio: S.k.anio })).catch(() => []); return { m, venc: f.filter(x => x.vencido).reduce((a, x) => a + +x.saldo, 0), total: f.reduce((a, x) => a + +x.saldo, 0) }; })) : [];
  await cargarCuenta(propio()); comps = await all(() => db.from('comprobantes').select('id,estudiante_id,fecha,valor,medio,referencia,nota,estado,respuesta,creado_en').eq('estudiante_id', propio()).order('creado_en', { ascending: false })).catch(() => []); }
function vCuenta() {
  const e = est(propio()); if (!e) return head('Estado de cuenta') + '<div class="panel empty">No encontramos la información del estudiante.</div>';
  const venc = cuenta.filas.filter(x => x.vencido).reduce((a, x) => a + +x.saldo, 0), total = cuenta.filas.reduce((a, x) => a + +x.saldo, 0);
  const previo = saldoPrevio();
  return head(`Estado de cuenta de ${esc(e.nombres)}`, `Año ${S.k.anio}. Si ya pagó, envíe el comprobante en esta misma página.`) +
    (previo > 0 ? `<div class="note bloqueo">Tiene saldos pendientes de años anteriores por <strong>${cop(previo)}</strong>: ${aniosConDeuda().map(a => `${a}: ${cop(cuenta.prevFilas.filter(x => x.anioCobro === a).reduce((s, x) => s + +x.saldo, 0))}`).join(', ')}. Comuníquese con la tesorería del colegio.</div>` : '') +
    `<div class="stats"><div class="stat"><div class="n" style="color:${venc ? 'var(--red)' : 'var(--teal-d)'}">${cop(venc)}</div><div class="l">${venc ? 'Pendiente por pagar a hoy' : 'Está al día'}</div></div>
      <div class="stat"><div class="n">${cop(cuenta.filas.reduce((a, x) => a + +x.pagado, 0))}</div><div class="l">Pagado en el año</div></div>
      ${(() => { const px = cuenta.filas.find(x => !x.vencido && +x.saldo > 0); return px ? `<div class="stat"><div class="n">${cop(px.saldo)}</div><div class="l">Próxima cuota: ${esc(px.concepto)}${px.mes ? ' de ' + MESES[px.mes].toLowerCase() : ''}</div></div>` : ''; })()}</div>
    ${(S.cuentaHijos || []).length > 1 ? `<div class="panel"><h2>Todos sus hijos</h2><div class="tbl"><table><thead><tr><th>Estudiante</th><th>Pendiente por pagar a hoy</th><th></th></tr></thead><tbody>
      ${S.cuentaHijos.map(x => `<tr><td><strong>${esc(x.m.estudiantes?.nombres || '')} ${esc(x.m.estudiantes?.apellidos || '')}</strong></td><td>${x.venc > 0 ? `<strong style="color:var(--red)">${cop(x.venc)}</strong>` : '<span class="ok">Al día</span>'}</td>
        <td>${x.m.id === ctx.id ? '<span class="tag">Viendo</span>' : `<button class="btn ghost sm" type="button" onclick="entrarContexto('${x.m.id}')">Ver detalle</button>`}</td></tr>`).join('')}
      <tr><td><strong>Total</strong></td><td><strong>${cop(S.cuentaHijos.reduce((a, x) => a + x.venc, 0))}</strong></td><td></td></tr></tbody></table></div></div>` : ''}
    <div class="panel"><h2>Cobros</h2>${tablaCuenta(false)}</div>${panelPagarFam(venc)}<div class="panel"><h2>Pagos realizados</h2>${tablaPagos(false)}</div>`;
}

/* =====================================================================
   Observador del estudiante (convivencia, académico, compromisos)
   ===================================================================== */
const TIPOS_OBS = ['Felicitación', 'Positiva', 'Convivencia', 'Académica', 'Compromiso', 'Citación a acudiente'];
let obsv = [];
async function prepObservador() {
  if (isFam()) { obsv = await all(() => db.from('observador').select('*').eq('estudiante_id', propio()).eq('anio', S.k.anio).order('fecha', { ascending: false })); return; }
  const gs = gruposVis(); if (!gs.length) { obsv = []; return; }
  if (!sel.g || !gs.find(g => g.id === sel.g)) sel.g = gs[0].id;
  const ids = estsDe(sel.g).map(e => e.id); obsv = [];
  for (const part of chunks(ids, 60)) obsv.push(...await all(() => db.from('observador').select('*').eq('anio', S.k.anio).in('estudiante_id', part).order('fecha', { ascending: false })));
}
const obsDe = eid => obsv.filter(o => o.estudiante_id === eid);
const tagObs = t => `<span class="tag ${t === 'Felicitación' ? 'felic' : t === 'Positiva' ? 'piar' : t === 'Convivencia' || t === 'Citación a acudiente' ? 't3' : 't2'}">${t === 'Felicitación' ? '⭐ ' : ''}${esc(t)}</span>`;
function filaObs(o, editable) {
  const puede = editable && (isDir() || o.creado_por === me?.id);
  return `<li><div style="display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap"><span><strong>${fmtF(o.fecha)}</strong> ${tagObs(o.tipo)} <span class="muted">por ${esc(o.autor_nombre || '')}</span></span>
    ${puede ? `<button class="btn ghost sm" type="button" onclick="borrarObs('${o.id}')">Eliminar</button>` : ''}</div>
    <p style="margin:6px 0 0">${esc(o.descripcion)}</p>
    ${o.compromiso ? `<p class="muted" style="margin:4px 0 0"><strong>Compromiso:</strong> ${esc(o.compromiso)}</p>` : ''}
    ${puede ? `<label class="field" style="margin-top:6px"><span>Seguimiento</span><textarea onchange="setSegObs('${o.id}',this)">${esc(o.seguimiento || '')}</textarea></label>` : (o.seguimiento ? `<p class="muted" style="margin:4px 0 0"><strong>Seguimiento:</strong> ${esc(o.seguimiento)}</p>` : '')}</li>`;
}
function vObservador() {
  if (isFam()) {
    const e = est(propio());
    return head(`Observador de ${esc(e?.nombres || '')}`, `Anotaciones del año ${S.k.anio} registradas por el colegio.`, obsv.length ? `<button class="btn" type="button" onclick="verObservador('${propio()}')">Ver e imprimir</button>` : '') +
      `<div class="panel">${obsv.length ? `<ul class="list">${obsv.map(o => filaObs(o, false)).join('')}</ul>` : '<p class="muted">No hay anotaciones este año.</p>'}</div>`;
  }
  const gs = gruposVis(); if (!gs.length) return head('Observador') + sinGrupos();
  if (sel.oe && est(sel.oe)) {
    const e = est(sel.oe), l = obsDe(e.id);
    return head(`Observador de ${esc(nom(e))}`, `${esc(grupo(e.grupo_id)?.nombre || '')}. Año ${S.k.anio}.`,
      `<div class="toolbar" style="margin:0"><button class="btn ghost" type="button" onclick="sel.oe='';render()">Volver</button>${isDoc() ? '' : `<button class="btn ghost" type="button" onclick="verObservador('${e.id}')">Ver e imprimir</button>`}</div>`) +
      `<div class="panel"><h2>Nueva anotación</h2><div class="formgrid">
        ${fIn('oFec', 'Fecha', hoy(), 'type="date"')}
        <label class="field"><span>Tipo</span><select id="oTipo">${TIPOS_OBS.map(t => opt(t, t === 'Felicitación' ? '⭐ Felicitación (destaque algo positivo)' : t, 'Felicitación')).join('')}</select></label>
        ${fTa('oDesc', 'Descripción de la situación', '', 'Qué ocurrió, cuándo y dónde. Escriba hechos, sin juicios.')}
        ${fTa('oComp', 'Compromiso o acción acordada (opcional)', '')}</div>
        <div class="toolbar" style="margin-top:10px"><button class="btn" type="button" onclick="guardarObs('${e.id}')">Guardar anotación</button></div></div>
      <div class="panel"><h2>Anotaciones del año (${l.length})</h2>${l.length ? `<ul class="list">${l.map(o => filaObs(o, true)).join('')}</ul>` : '<p class="muted">Sin anotaciones.</p>'}</div>`;
  }
  const es = estsDe(sel.g);
  return head('Observador del estudiante', 'Registro de convivencia, desempeño y compromisos. El acudiente puede consultarlo.') +
    `<div class="panel"><div class="toolbar"><label class="field"><span>Grupo</span><select onchange="sel.g=this.value;sel.oe='';go('observador')">${gs.map(x => opt(x.id, x.nombre, sel.g)).join('')}</select></label></div>
    ${es.length ? `<div class="tbl"><table><thead><tr><th>Estudiante</th><th>Anotaciones</th><th>Última</th><th></th></tr></thead><tbody>${es.map(e => { const l = obsDe(e.id); return `<tr><td>${esc(e.apellidos)} ${esc(e.nombres)}</td><td>${l.length}${l.some(o => o.tipo === 'Convivencia' || o.tipo === 'Citación a acudiente') ? ` <span class="tag t3">${l.filter(o => o.tipo === 'Convivencia' || o.tipo === 'Citación a acudiente').length} de convivencia</span>` : ''}</td><td>${l[0] ? fmtF(l[0].fecha) + ' ' + tagObs(l[0].tipo) : '—'}</td><td><button class="btn sm" type="button" onclick="abrirObs('${e.id}')">Abrir</button></td></tr>`; }).join('')}</tbody></table></div>` : '<div class="empty">Este grupo no tiene estudiantes activos.</div>'}</div>`;
}
function abrirObs(eid) { sel.oe = eid; render(); window.scrollTo(0, 0); }
async function guardarObs(eid) {
  const d = { estudiante_id: eid, colegio_id: ctx.colegio_id, anio: S.k.anio, fecha: vv('oFec') || hoy(), tipo: vv('oTipo'), descripcion: vv('oDesc'), compromiso: vv('oComp') || null };
  if (!d.descripcion) return toast('Escriba la descripción de la situación');
  const r = await guard(() => q(db.from('observador').insert(d).select().single()), 'Anotación guardada');
  if (r) { obsv.unshift(r); obsv.sort((a, b) => b.fecha.localeCompare(a.fecha)); render(); }
}
async function setSegObs(id, el) {
  const r = await guard(() => q(db.from('observador').update({ seguimiento: el.value.trim() || null }).eq('id', id).select().single()), 'Seguimiento guardado');
  if (r) Object.assign(obsv.find(o => o.id === id), r);
}
async function borrarObs(id) {
  if (!await confirmar('¿Eliminar esta anotación del observador?')) return;
  const ok = await guard(async () => { await q(db.from('observador').delete().eq('id', id)); return true; }, 'Anotación eliminada');
  if (ok) { obsv = obsv.filter(o => o.id !== id); render(); }
}
function observadorHTML(eid) {
  const e = est(eid), g = grupo(e.grupo_id), l = obsDe(eid).slice().sort((a, b) => a.fecha.localeCompare(b.fecha));
  return `<section class="doc">${docHead('Observador del estudiante', `Año lectivo ${S.k.anio}`)}
  <div class="dgrid">${dato('Estudiante', nom(e))}${dato('Documento', `${e.tipo_doc} ${e.doc}`)}${dato('Curso', g?.nombre)}${dato('Director(a) de grupo', g?.director_nombre)}${dato('Acudiente', e.acudiente_nombre)}${dato('Anotaciones', String(l.length))}</div>
  ${l.length ? `<table><thead><tr><th>Fecha</th><th>Tipo</th><th>Descripción</th><th>Compromiso y seguimiento</th><th>Registró</th></tr></thead><tbody>
  ${l.map(o => `<tr><td>${fmtF(o.fecha)}</td><td>${esc(o.tipo)}</td><td>${esc(o.descripcion)}</td><td>${esc(o.compromiso || '')}${o.seguimiento ? `<br><em>${esc(o.seguimiento)}</em>` : ''}</td><td>${esc(o.autor_nombre || '')}</td></tr>`).join('')}</tbody></table>` : '<p>Sin anotaciones en el año.</p>'}
  <p class="dnote">Registro conforme al Manual de Convivencia institucional y la Ley 1620 de 2013.</p>
  ${firmas(['Director(a) de grupo', g?.director_nombre], ['Coordinación o rectoría', S.k.rector_nombre], ['Acudiente', e.acudiente_nombre])}</section>`;
}
function verObservador(eid) { showDocs(observadorHTML(eid), 'Observador'); }

/* =====================================================================
   PIAR (Decreto 1421 de 2017)
   ===================================================================== */
let piars = {};
async function prepPiar() {
  const ids = isAcud() ? [propio()] : S.ests.filter(e => e.piar && e.estado === 'Activo' && (isDir() || S.misGrupos.includes(e.grupo_id))).map(e => e.id);
  piars = {};
  if (ids.length) (await q(db.from('piar').select('*').eq('anio', S.k.anio).in('estudiante_id', ids))).forEach(p => piars[p.estudiante_id] = p.datos);
}
const GUIA_PIAR = `<section class="panel guide"><h2>Guía para construir el PIAR</h2><ol>
  <li>Elabórelo durante el primer trimestre del año, a partir de la valoración pedagógica del estudiante.</li>
  <li>Describa fortalezas, intereses y las barreras que limitan su aprendizaje y participación.</li>
  <li>Defina ajustes razonables por asignatura: en los objetivos, en la forma de enseñar y en la forma de evaluar.</li>
  <li>Acuerde los compromisos con la familia y firme el acta de acuerdo.</li>
  <li>Haga seguimiento cada periodo y actualícelo cada año.</li></ol>
  <p class="muted" style="margin-top:8px">Referencia: Decreto 1421 de 2017.</p></section>`;
function vPiar() {
  if (isAcud()) {
    const e = est(propio());
    return head(`PIAR de ${esc(e?.nombres || '')}`, 'Plan Individual de Ajustes Razonables acordado con el colegio.') +
      (piars[e?.id] ? `${isDoc() ? '' : `<div class="toolbar"><button class="btn" type="button" onclick="showDocs(piarHTML('${e.id}'),'PIAR')">Ver e imprimir</button></div>`}${piarHTML(e.id)}` : '<div class="panel empty">No hay un PIAR registrado para este año.</div>');
  }
  if (sel.piarE && est(sel.piarE)) return piarEditor(sel.piarE);
  const l = S.ests.filter(e => e.piar && e.estado === 'Activo' && (isDir() || S.misGrupos.includes(e.grupo_id)));
  return head('PIAR e inclusión', 'Estudiantes marcados con "Requiere PIAR" en su ficha de matrícula.') +
    `<div class="cols"><section class="panel"><h2>Estudiantes con PIAR</h2>${l.length ? `<ul class="list">${l.map(e => `<li style="display:flex;justify-content:space-between;gap:10px;align-items:center;flex-wrap:wrap"><span><strong>${esc(nom(e))}</strong><br><span class="muted">${esc(grupo(e.grupo_id)?.nombre || '')}${e.condicion_especial ? ' · ' + esc(e.condicion_especial) : ''} · ${piars[e.id] ? (piars[e.id].acta ? 'con acta de acuerdo firmada' : 'en construcción') : 'sin iniciar'}</span></span><button class="btn sm" type="button" onclick="abrirPiar('${e.id}')">${piars[e.id] ? 'Abrir PIAR' : 'Iniciar PIAR'}</button></li>`).join('')}</ul>` : '<p class="muted">No hay estudiantes marcados. Márquelos desde la ficha de matrícula.</p>'}</section>${GUIA_PIAR}</div>`;
}
async function abrirPiar(eid) { sel.piarE = eid; const e = est(eid); await guard(() => cargarGrupo(e.grupo_id)); render(); }
function piarEditor(eid) {
  const e = est(eid), g = grupo(e.grupo_id), p = piars[eid] || { fecha: hoy(), elabora: '', fortalezas: '', intereses: '', barreras: '', apoyos: '', familia: '', ajustes: {}, seguimiento: {}, acta: false };
  const ta = (id, l, v, ph) => `<label class="field full"><span>${l}</span><textarea id="${id}" placeholder="${ph || ''}">${esc(v || '')}</textarea></label>`;
  return head(`PIAR de ${esc(e.nombres)}`, `${esc(g?.nombre || '')}. ${e.condicion_especial ? 'Condición: ' + esc(e.condicion_especial) + '. ' : ''}Los cambios se guardan con el botón al final.`,
    `<div class="toolbar" style="margin:0"><button class="btn ghost" type="button" onclick="sel.piarE='';render()">Volver</button><button class="btn ghost" type="button" onclick="guardarPiar('${eid}',true)">Vista de impresión</button></div>`) +
  `<div class="panel"><h2>Caracterización</h2><div class="formgrid">${fIn('pF', 'Fecha de elaboración', p.fecha, 'type="date"')}${fIn('pEl', 'Elaborado por', p.elabora)}
    ${ta('pFo', 'Fortalezas', p.fortalezas, 'Qué hace bien, cómo aprende mejor.')}${ta('pIn', 'Intereses', p.intereses)}${ta('pBa', 'Barreras para el aprendizaje y la participación', p.barreras)}</div></div>
  <div class="panel"><h2>Ajustes razonables por ${g?.nivel === 'preescolar' ? 'dimensión' : 'asignatura'}</h2><div class="formgrid">${(g ? asigsDe(g) : []).map(a => ta('aj-' + a.id, esc(a.nombre), (p.ajustes || {})[a.id], 'Objetivos, didáctica y evaluación ajustados.')).join('')}</div></div>
  <div class="panel"><h2>Apoyos y compromisos</h2><div class="formgrid">${ta('pAp', 'Apoyos requeridos', p.apoyos)}${ta('pFa', 'Compromisos de la familia', p.familia)}</div></div>
  <div class="panel"><h2>Seguimiento por periodo</h2><div class="formgrid">${periodos().map(x => ta('sg-' + x.n, 'Periodo ' + x.n, (p.seguimiento || {})[x.n])).join('')}</div>
    <label class="field chk" style="margin-top:12px"><input id="pAc" type="checkbox" ${p.acta ? 'checked' : ''}> Acta de acuerdo firmada con la familia</label>
    <div class="toolbar" style="margin-top:14px"><button class="btn" type="button" onclick="guardarPiar('${eid}')">Guardar PIAR</button></div></div>`;
}
async function guardarPiar(eid, ver) {
  const g = grupo(est(eid).grupo_id), aj = {}, sg = {};
  (g ? asigsDe(g) : []).forEach(a => aj[a.id] = $('#aj-' + a.id).value.trim()); periodos().forEach(x => sg[x.n] = $('#sg-' + x.n).value.trim());
  const datos = { fecha: vv('pF'), elabora: vv('pEl'), fortalezas: vv('pFo'), intereses: vv('pIn'), barreras: vv('pBa'), apoyos: vv('pAp'), familia: vv('pFa'), ajustes: aj, seguimiento: sg, acta: vv('pAc') };
  const ok = await guard(() => q(db.from('piar').upsert({ colegio_id: ctx.colegio_id, estudiante_id: eid, anio: S.k.anio, datos }, { onConflict: 'estudiante_id,anio' })), 'PIAR guardado');
  if (ok !== undefined) { piars[eid] = datos; if (ver) showDocs(piarHTML(eid), 'PIAR'); }
}
function piarHTML(eid) {
  const e = est(eid), g = grupo(e.grupo_id), p = piars[eid]; if (!p) return '';
  const blk = (t, v) => `<div class="dobs"><span>${t}</span><p>${esc(v || 'Sin información registrada.')}</p></div>`;
  return `<section class="doc">${docHead('Plan Individual de Ajustes Razonables', `PIAR, Decreto 1421 de 2017<br>Año ${S.k.anio}`)}
  <div class="dgrid">${dato('Estudiante', nom(e))}${dato('Documento', `${e.tipo_doc} ${e.doc}`)}${dato('Grado', g?.nombre)}${dato('Fecha de elaboración', fmtF(p.fecha))}${dato('Elaborado por', p.elabora)}${dato('Acta de acuerdo', p.acta ? 'Firmada' : 'Pendiente')}</div>
  ${blk('Condición', e.condicion_especial)}${blk('Fortalezas', p.fortalezas)}${blk('Intereses', p.intereses)}${blk('Barreras para el aprendizaje y la participación', p.barreras)}
  <h3 style="margin-top:14px;color:#0B4F8A">Ajustes razonables</h3><table><thead><tr><th>Área</th><th>Ajustes</th></tr></thead><tbody>${(g ? asigsDe(g) : []).filter(a => (p.ajustes || {})[a.id]).map(a => `<tr><td>${esc(a.nombre)}</td><td>${esc(p.ajustes[a.id])}</td></tr>`).join('') || '<tr><td colspan="2">Sin ajustes registrados.</td></tr>'}</tbody></table>
  ${blk('Apoyos requeridos', p.apoyos)}${blk('Compromisos de la familia', p.familia)}
  <h3 style="margin-top:14px;color:#0B4F8A">Seguimiento</h3><table><tbody>${periodos().map(x => `<tr><td>Periodo ${x.n}</td><td>${esc((p.seguimiento || {})[x.n] || '—')}</td></tr>`).join('')}</tbody></table>
  ${firmas(['Rector(a)', S.k.rector_nombre], ['Docente', ''], ['Acudiente', acudDe(eid)[0]?.nombres || e.acudiente_nombre || ''])}</section>`;
}

/* =====================================================================
   Panel de la plataforma (administración de Colegio-IA)
   ===================================================================== */
/* =====================================================================
   Suscripción de Colegio-IA: aviso, pago en línea con Bold y acceso cerrado por pago
   ===================================================================== */
const SOPORTE_TEL = '3044375758';
const valorDeuda = e => (e?.valor_mes || 0) * Math.max(1, e?.meses_debe || 1);
const waSoporte = (e, l = 'WhatsApp de soporte') => waBtn(e?.whatsapp || SOPORTE_TEL, `Hola. Soy de ${ctx?.colegios?.nombre || 'un colegio'} y necesito ayuda con el pago de la suscripción de Colegio-IA.`, l);
async function copiarTexto(t) { try { await navigator.clipboard.writeText(t); toast('Copiado'); } catch { toast(t); } }
function avisoCobro() {
  const e = S.estado, d = e.dias;
  return `<div class="note bloqueo"><strong>Pago de Colegio-IA pendiente: ${d === 1 ? 'mañana' : `en ${d} días`} se suspende el acceso.</strong> La suscripción está pagada hasta el ${fechaLarga(e.pagado_hasta)}. Si el pago no se confirma, el día 10 se suspende el acceso de todo el colegio (docentes y familias incluidos).
    <div class="toolbar" style="margin:8px 0 0">${isDir() || isTes() ? '<button class="btn" type="button" onclick="pagarSuscripcion()">Pagar ahora</button>' : ''}${waSoporte(e)}</div></div>`;
}
function panelSuscripcion(r) {
  const x = S.susc; if (!x) return `<p>Paquete para ${r.activos ?? 0} estudiantes activos.</p>`;
  if (x.demo) return '<p><span class="tag">Colegio de demostración</span> Sin cobro.</p>';
  const tag = { activa: x.meses_pendientes > 0 ? '<span class="tag t2">Mes en curso por pagar</span>' : '<span class="tag">Al día</span>', aviso: '<span class="tag t3">Pago vencido: aviso de suspensión</span>', cerrada: '<span class="tag t3">Cerrada por pago</span>' }[x.cobro] || '';
  return `<p>Plan hasta <strong>${x.plan_max} estudiantes</strong>: <strong>${cop(x.valor)} al mes</strong>. Incluye todos los módulos y usuarios ilimitados para docentes, familias y directivos.</p>
    <p>Estudiantes activos: <strong>${x.activos} de ${x.plan_max}</strong>${x.activos >= x.plan_max ? ' <span class="tag t3">Plan completo: para matricular más, solicite la ampliación</span>' : ''}</p>
    <p>${tag} Pagado hasta el <strong>${fechaLarga(x.pagado_hasta)}</strong>.</p>
    <p class="muted">Cada mes se paga por anticipado. Si el mes no se ha pagado, el día 5 se cierra el acceso del colegio hasta que se confirme el pago.</p>
    <div class="toolbar"><button class="btn" type="button" onclick="pagarSuscripcion()">Pagar suscripción</button></div>
    ${x.ultimos?.length ? `<h3>Pagos recibidos</h3><div class="tbl"><table><tbody>${x.ultimos.map(p => `<tr><td>${mesTxt(p.mes)}</td><td>${cop(p.valor)}</td><td>${esc(p.medio || '')}</td><td><button class="btn ghost sm" type="button" onclick="reciboSusc('${p.id}')">Recibo</button></td></tr>`).join('')}</tbody></table></div>` : ''}`;
}
async function pagarSuscripcion() {
  const e = S.estado = await q(db.rpc('estado_colegio', { p_colegio: ctx.colegio_id })).catch(() => S.estado);
  if (!e) return toast('No se pudo consultar el estado de la suscripción');
  const meses = Math.max(1, e.meses_debe || 1), valor = valorDeuda(e);
  // El colegio le paga a SkyNet Genesis solo en línea con Bold; el pago se registra automáticamente
  openModal('Pagar la suscripción de Colegio-IA', `<p>Valor a pagar: <strong>${cop(valor)}</strong> (${meses} ${meses === 1 ? 'mes' : 'meses'} del plan hasta ${e.plan_max} estudiantes). Pagado hasta el ${fechaLarga(e.pagado_hasta)}.</p>
    <p><button class="btn" type="button" onclick="pagarBoldSusc(this)">Pagar en línea con Bold</button></p>
      <p class="muted">Tarjeta, PSE, Nequi o Bancolombia. El pago se registra automáticamente: apenas Bold lo apruebe (puede tardar unos minutos), la suscripción queda al día y el recibo aparece en Parametrización. No necesita enviar comprobantes.</p>
    <div class="modal-foot">${waSoporte(e)}<button class="btn ghost" type="button" onclick="closeModal()">Cerrar</button></div>`);
}
// Pago de la suscripción con Bold (conversación "Pagos automáticos Bold", 10 oct 2026).
// El firmador propio de skynetgenesis.com arma la orden; Bold avisa a bold-webhook.php, que llama a bold_pago_aprobado en Neon.
// No volver al enlace fijo bold_url.
async function pagarBoldSusc(btn) {
  const e = S.estado || {}, m = Math.max(1, Math.min(12, e.meses_debe || 1)), pm = e.plan_max || 0;
  const pl = pm <= 100 ? 'g100' : pm <= 250 ? 'g250' : pm <= 500 ? 'g500' : pm <= 1000 ? 'g1000' : null;
  if (!pl) return toast('Para planes de más de 1.000 estudiantes escríbanos por WhatsApp');
  if (btn) { btn.disabled = true; btn.textContent = 'Abriendo Bold…'; }
  try {
    const qs = new URLSearchParams({ plan: 'genesis:' + pl, empresa: ctx.colegio_id, meses: String(m), org: (ctx.colegios?.nombre || '').slice(0, 40), volver: location.origin + '/' });
    const r = await fetch('https://skynetgenesis.com/bold-firma.php?' + qs.toString(), { cache: 'no-store' }), d = await r.json();
    if (!r.ok || !d.ok) throw new Error(d.error || 'firma');
    if (!window.BoldCheckout) await new Promise((ok, ko) => { const sc = document.createElement('script'); sc.src = 'https://checkout.bold.co/library/boldPaymentButton.js'; sc.onload = ok; sc.onerror = ko; document.head.appendChild(sc); });
    new window.BoldCheckout({ orderId: d.orderId, currency: d.currency, amount: String(d.amount), apiKey: d.apiKey, integritySignature: d.signature, description: d.description, redirectionUrl: d.redirectionUrl }).open();
  } catch { toast('No se pudo abrir el pago con Bold. Intente de nuevo o escríbanos por WhatsApp.'); }
  finally { if (btn) { btn.disabled = false; btn.textContent = 'Pagar en línea con Bold'; } }
}
function pantallaCerrada() {
  modo = 'cerrado'; mostrarApp(); const e = S.estado || {};
  $('#ctxBox').innerHTML = ctxs.length > 1
    ? `<label class="role"><span class="muted" style="font-size:.85rem">Colegio y perfil</span><select class="ctx" onchange="entrarContexto(this.value)">${ctxs.map(m => opt(m.id, ctxLabel(m), ctx.id)).join('')}</select></label>`
    : `<div class="who"><strong>${esc(ctx.colegios.nombre)}</strong><br>${esc(quien())}</div>`;
  $('#nav').innerHTML = '';
  $('#foot').innerHTML = `${esc(me?.email || '')}<br><button class="btn ghost sm" type="button" onclick="doLogout()">Cerrar sesión</button><div style="margin-top:10px">${sgFirma()}</div>`;
  $('#view').innerHTML = `<div class="panel cerrado"><h1>Acceso suspendido por falta de pago</h1>
    <p>La suscripción de Colegio-IA de <strong>${esc(ctx.colegios.nombre)}</strong> está pagada hasta el ${fechaLarga(e.pagado_hasta)}. Como el pago del mes no se registró, desde el día 5 el acceso de todo el colegio está cerrado.</p>
    <p><strong>La información del colegio está completa y segura.</strong> El acceso se restablece en cuanto se confirme el pago.</p>
    ${e.directivo ? `<p>Valor a pagar: <strong>${cop(valorDeuda(e))}</strong>. El pago se hace en línea con Bold y el acceso se restablece automáticamente.</p><div class="toolbar"><button class="btn" type="button" onclick="pagarSuscripcion()">Pagar ahora</button></div>`
      : '<p>Comuníquese con la rectoría del colegio.</p>'}
    <div class="toolbar" style="margin-top:12px">${waSoporte(e)}<button class="btn ghost" type="button" onclick="location.reload()">Ya se confirmó el pago: entrar</button></div></div>`;
}
function reciboSusc(id) {
  const p = (S.susc?.ultimos || []).find(x => x.id === id); if (!p) return;
  showDocs(`<section class="doc"><header class="dh"><div><div class="dh-inst">SkyNet Genesis</div><div class="dh-meta">contacto@skynetgenesis.com · WhatsApp 304 437 5758</div></div><div class="dh-t"><strong>Recibo de pago</strong><br>${fmtF(p.fecha)}</div></header>
    <div class="dgrid">${dato('Cliente', S.k.nombre)}${dato('NIT', S.k.nit)}${dato('Servicio', 'Suscripción de Colegio-IA, gestión escolar')}${dato('Periodo', mesTxt(p.mes))}${dato('Medio de pago', (p.medio || '') + (p.referencia ? ` (${p.referencia})` : ''))}${dato('Valor', cop(p.valor))}</div>
    <p class="dnote">Recibimos a satisfacción el pago de la suscripción del periodo indicado.</p></section>`, 'Recibo de suscripción', `Recibo Colegio-IA ${mesTxt(p.mes)}`);
}

let plat = [];
let visitas = [];
let platComps = [], platCfg = {};
async function prepPlataforma() { plat = await q(db.rpc('plataforma_resumen')); platComps = await q(db.from('plataforma_comprobantes').select('id,colegio_id,meses,valor,referencia,enviado_por,creado_en').eq('estado', 'Pendiente').order('creado_en')).catch(() => []); platCfg = (await q(db.from('plataforma_config').select('*').eq('id', 1)).catch(() => []))[0] || {}; visitas = await q(db.from('demo_visitas').select('*').order('fecha', { ascending: false }).range(0, 99)).catch(() => []); }
function vPlataforma() {
  const total = plat.filter(c => c.activo && !c.demo).reduce((s, c) => s + c.valor_mensual, 0);
  return head('Colegios', 'Alta de colegios, estudiantes activos y valor mensual de cada suscripción.', `<button class="btn" type="button" onclick="formColegio()">Nuevo colegio</button>`) +
    `<div class="stats"><div class="stat"><div class="n">${plat.filter(c => c.activo).length}</div><div class="l">Colegios activos</div></div>
      <div class="stat"><div class="n">${plat.reduce((s, c) => s + c.estudiantes_activos, 0)}</div><div class="l">Estudiantes activos</div></div>
      <div class="stat"><div class="n">${cop(total)}</div><div class="l">Facturación mensual estimada</div></div></div>
    <div class="panel">${plat.length ? `<div class="tbl"><table><thead><tr><th>Colegio</th><th>Ciudad</th><th>Año</th><th>Estudiantes / plan</th><th>Valor mensual</th><th>Desde</th><th>Pagado hasta</th><th>Estado de pago</th><th>Acceso</th><th></th></tr></thead><tbody>
      ${plat.map(c => `<tr class="${c.activo ? '' : 'dim'}"><td><strong>${esc(c.nombre)}</strong></td><td>${esc(c.ciudad || '')}</td><td>${c.anio}</td><td>${c.estudiantes_activos} de ${c.plan_max ?? '—'}${c.demo ? ' <span class="tag">Demo</span>' : ''}</td><td>${c.demo ? '<span class="muted">Sin cobro</span>' : cop(c.valor_mensual)}</td><td>${fmtF(c.creado_en)}</td>
        <td>${c.demo ? '<span class="muted">No aplica</span>' : `${fmtF(c.pagado_hasta)} <button class="linkbtn" type="button" onclick="formPagadoHasta('${c.colegio_id}')">Cambiar</button>`}</td><td>${c.demo ? '' : estadoCobroTag(c)}${c.comprobante_id ? ` <button class="btn sm" type="button" onclick="revisarCompPlat('${c.comprobante_id}')">Revisar comprobante</button>` : ''}</td>
        <td>${c.activo ? 'Activo' : 'Suspendido'}</td><td style="white-space:nowrap"><button class="btn sm" type="button" onclick="formPagoSusc('${c.colegio_id}')">Registrar pago</button> <button class="btn ghost sm" type="button" onclick="formPlanColegio('${c.colegio_id}')">Plan</button> <button class="btn ghost sm" type="button" onclick="toggleColegio('${c.colegio_id}',${!c.activo})">${c.activo ? 'Suspender' : 'Reactivar'}</button></td></tr>`).join('')}</tbody></table></div>` : '<div class="empty">Aún no hay colegios. Cree el primero.</div>'}</div>
    ${panelCompsPlat()}${panelCfgPlat()}
    <div class="panel"><h2>Personas que probaron la demostración</h2>${visitas.length ? `<div class="tbl"><table><thead><tr><th>Fecha</th><th>Nombre</th><th>Correo</th><th>Perfil</th></tr></thead><tbody>${visitas.map(v => `<tr><td>${fechaHora(v.fecha)}</td><td>${esc(v.nombre || '')}</td><td>${esc(v.email || '')}</td><td>${{ coordinador: 'Directivo', docente: 'Docente', acudiente: 'Acudiente' }[v.rol] || esc(v.rol)}</td></tr>`).join('')}</tbody></table></div>` : '<p class="muted">Aún nadie ha probado la demostración. Comparta el enlace de Colegio-IA y pídales que pulsen "Probar la demostración".</p>'}</div>
    <p class="muted">Planes: hasta 100 estudiantes $120.000; hasta 250, $220.000; hasta 500, $350.000; hasta 1.000, $550.000 al mes; más de 1.000, $40.000 adicionales por cada 100. Cada colegio puede matricular hasta el tope de su plan. Cada mes se paga por anticipado: si el mes no se ha pagado, el día 5 se cierra el acceso del colegio hasta confirmar el pago. Al registrar un pago o cambiar la fecha de «Pagado hasta», el acceso se restablece de inmediato.</p>`;
}
const estadoCobroTag = c => c.cobro === 'cerrada' ? '<span class="tag t3">Cerrada por pago</span>' : c.cobro === 'aviso' ? `<span class="tag t2">Aviso: ${c.dias} ${c.dias === 1 ? 'día' : 'días'}</span>` : c.cobro === 'suspendido' ? '<span class="tag">Suspendido</span>' : '<span class="tag">Activa</span>';
function panelCompsPlat() {
  if (!platComps.length) return '';
  return `<div class="panel"><h2>Comprobantes de pago por revisar <span class="badge">${platComps.length}</span></h2><div class="tbl"><table><thead><tr><th>Colegio</th><th>Enviado</th><th>Valor</th><th>Meses</th><th>Referencia</th><th></th></tr></thead><tbody>
    ${platComps.map(x => `<tr><td><strong>${esc(plat.find(c => c.colegio_id === x.colegio_id)?.nombre || '')}</strong><br><span class="muted">${esc(x.enviado_por || '')}</span></td><td>${fechaHora(x.creado_en)}</td><td>${cop(x.valor)}</td><td>${x.meses}</td><td>${esc(x.referencia || '')}</td>
      <td style="white-space:nowrap"><button class="btn sm" type="button" onclick="revisarCompPlat('${x.id}')">Revisar</button></td></tr>`).join('')}</tbody></table></div></div>`;
}
async function revisarCompPlat(id) {
  const x = platComps.find(c => c.id === id); if (!x) return toast('El comprobante ya fue revisado');
  const im = await guard(() => q(db.from('plataforma_comprobantes').select('imagen').eq('id', id).single()));
  const c = plat.find(k => k.colegio_id === x.colegio_id);
  openModal(`Comprobante: ${c?.nombre || ''}`, `<p>Valor: <strong>${cop(x.valor)}</strong> por ${x.meses} ${x.meses === 1 ? 'mes' : 'meses'} · Referencia: ${esc(x.referencia || '—')} · Enviado por ${esc(x.enviado_por || '')} el ${fechaHora(x.creado_en)}.</p>
    <p class="muted">Verifique en su banco que el dinero llegó. Al confirmar, la suscripción avanza ${x.meses} ${x.meses === 1 ? 'mes' : 'meses'} desde el ${fmtF(c?.pagado_hasta)}, el acceso se restablece y el colegio puede descargar su recibo. La foto se borra al decidir.</p>
    ${im?.imagen ? `<img src="${im.imagen}" alt="Comprobante" style="max-width:100%;border:1px solid var(--line);border-radius:6px">` : '<p class="muted">Sin foto adjunta.</p>'}
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="decidirCompPlat('${id}', false)">Rechazar</button><button class="btn" type="button" onclick="decidirCompPlat('${id}', true)">Confirmar pago</button></div>`);
}
async function decidirCompPlat(id, aprobar) {
  const resp = aprobar ? null : await pedirTexto('Motivo del rechazo (el colegio lo verá):');
  if (!aprobar && !resp) return;
  const r = await guard(() => q(db.rpc('plataforma_revisar_comprobante', { p_id: id, p_aprobar: aprobar, p_respuesta: resp })), aprobar ? 'Pago confirmado: el colegio quedó al día' : 'Comprobante rechazado');
  if (r) { closeModal(); await guard(prepPlataforma); render(); }
}
function formPagadoHasta(id) {
  const c = plat.find(x => x.colegio_id === id);
  openModal(`Pagado hasta: ${c.nombre}`, `<p class="muted">Al cambiar la fecha, el acceso del colegio se ajusta de inmediato: activo si la fecha es futura; cerrado desde el día 5 del mes siguiente a esa fecha.</p>
    <div class="formgrid">${fIn('phFec', 'Pagado hasta', c.pagado_hasta || hoy(), 'type="date"')}</div>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" onclick="guardarPagadoHasta('${id}')">Guardar</button></div>`);
}
async function guardarPagadoHasta(id) {
  const f = vv('phFec'); if (!f) return toast('Elija la fecha');
  const ok = await guard(async () => { await q(db.rpc('plataforma_pagado_hasta', { p_colegio: id, p_fecha: f })); return true; }, 'Fecha guardada');
  if (ok) { closeModal(); await guard(prepPlataforma); render(); }
}
function panelCfgPlat() {
  return `<div class="panel"><h2>Datos de pago que ven los colegios</h2><p class="muted">Los colegios le pagan la suscripción únicamente en línea con Bold. El botón usa el firmador de skynetgenesis.com y el pago se aplica solo.</p><div class="formgrid">${fIn('cfWa', 'WhatsApp de soporte', platCfg.whatsapp || SOPORTE_TEL)}</div>
    <div class="toolbar" style="margin-top:10px"><button class="btn" type="button" onclick="guardarCfgPlat()">Guardar datos de pago</button></div></div>`;
}
async function guardarCfgPlat() {
  const d = { llave: null, titular: null, whatsapp: vv('cfWa') || SOPORTE_TEL, actualizado_en: new Date().toISOString() };
  const ok = await guard(async () => { await q(db.from('plataforma_config').update(d).eq('id', 1)); return true; }, 'Datos de pago guardados');
  if (ok) { await guard(prepPlataforma); render(); }
}
function formColegio() {
  openModal('Nuevo colegio', `<div class="formgrid">
    <label class="field"><span>Nombre del colegio</span><input id="cNom"></label>
    <label class="field"><span>Ciudad</span><input id="cCiu"></label>
    <label class="field"><span>Rector(a)</span><input id="cRec"></label>
    <label class="field"><span>Correo del rector(a)</span><input id="cEmail" type="email"></label>
    <label class="field"><span>Teléfono del rector(a), para WhatsApp</span><input id="cTel" inputmode="tel"></label>
    <label class="field"><span>Año lectivo inicial</span><select id="cAnio">${[0, 1].map(i => { const y = new Date().getFullYear() + i; return opt(y, y + (i ? ' (si el colegio inicia con Colegio-IA el próximo año)' : ' (en curso)'), new Date().getFullYear()); }).join('')}</select></label></div>
    <p class="muted">El año lectivo va del 1 de enero al 31 de diciembre.</p>
    <p class="muted">Se crea el colegio con el plan de estudios base y una invitación para el rector(a).</p>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" onclick="crearColegio()">Crear colegio</button></div>`);
}
async function crearColegio() {
  const d = { p_nombre: $('#cNom').value.trim(), p_ciudad: $('#cCiu').value.trim(), p_rector_nombre: $('#cRec').value.trim(), p_rector_email: $('#cEmail').value.trim(), p_anio: +$('#cAnio').value };
  const tel = $('#cTel').value.trim();
  if (!d.p_nombre || !d.p_rector_nombre || !/^\S+@\S+\.\S+$/.test(d.p_rector_email)) return toast('Completa nombre del colegio, rector(a) y un correo válido');
  const r = await guard(() => q(db.rpc('crear_colegio', d)), 'Colegio creado');
  if (!r) return;
  const url = location.origin + location.pathname;
  const txt = `Hola, ${d.p_rector_nombre}. Bienvenido(a) a Colegio-IA.\n\n1. Entre a ${url}\n2. Elija "Cree su cuenta" y regístrese con este correo: ${d.p_rector_email.toLowerCase()}\n3. Escriba el código de activación: ${r.codigo}\n\nEl colegio queda listo para el año lectivo ${r.anio}. Desde su cuenta podrá configurar el colegio, crear grupos, matricular estudiantes e invitar a su equipo.`;
  await guard(prepPlataforma);
  openModal('Colegio creado', `<p>Envíe este mensaje al rector(a):</p><textarea id="invTxt" readonly style="min-height:170px">${esc(txt)}</textarea>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal();render()">Cerrar</button><button class="btn ghost" type="button" onclick="copiar('#invTxt')">Copiar mensaje</button>${waBtn(tel, txt)}</div>`);
}
const PLANES = [100, 250, 500, 1000];
const precioPlan = n => n <= 100 ? 120000 : n <= 250 ? 220000 : n <= 500 ? 350000 : n <= 1000 ? 550000 : 550000 + Math.ceil((n - 1000) / 100) * 40000;
function formPlanColegio(id) {
  const c = plat.find(x => x.colegio_id === id), p = c.plan_max || 100, otro = !PLANES.includes(p);
  openModal(`Plan: ${c.nombre}`, `<p class="muted">Estudiantes activos hoy: <strong>${c.estudiantes_activos}</strong>. El colegio no podrá matricular por encima del tope del plan.</p>
    <div class="formgrid"><label class="field"><span>Plan</span><select id="plSel" onchange="document.getElementById('plOtroBox').hidden=this.value!=='otro'">${PLANES.map(n => opt(n, `Hasta ${n.toLocaleString('es-CO')} estudiantes: ${cop(precioPlan(n))}`, otro ? '' : p)).join('')}${opt('otro', 'Más de 1.000 estudiantes', otro ? 'otro' : '')}</select></label>
      <label class="field" id="plOtroBox" ${otro ? '' : 'hidden'}><span>Tope de estudiantes</span><input id="plOtro" type="number" min="1001" step="100" value="${otro ? p : 1100}"></label>
      <label class="chk full"><input type="checkbox" id="plDemo" ${c.demo ? 'checked' : ''}> Colegio de demostración (sin cobro y sin bloqueo)</label></div>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" onclick="guardarPlanColegio('${id}')">Guardar plan</button></div>`);
}
async function guardarPlanColegio(id) {
  const v = $('#plSel').value, n = v === 'otro' ? +$('#plOtro').value : +v;
  if (!n || n < 1) return toast('Escriba el tope de estudiantes');
  const ok = await guard(async () => { await q(db.rpc('plataforma_plan', { p_colegio: id, p_plan: n, p_demo: $('#plDemo').checked })); return true; }, 'Plan guardado');
  if (ok) { closeModal(); await guard(prepPlataforma); render(); }
}
function formPagoSusc(id) {
  const c = plat.find(x => x.colegio_id === id);
  const sig = new Date((c.pagado_hasta ? c.pagado_hasta.slice(0, 7) : String(c.creado_en).slice(0, 7)) + '-15T12:00:00');
  if (c.pagado_hasta) sig.setMonth(sig.getMonth() + 1);
  const mes = `${sig.getFullYear()}-${String(sig.getMonth() + 1).padStart(2, '0')}`;
  openModal(`Pago de suscripción: ${c.nombre}`, `<div class="formgrid">
    ${fIn('sMes', 'Mes que paga', mes, 'type="month"')}${fIn('sVal', 'Valor', c.valor_mensual, 'type="number" min="1" step="1000"')}
    ${fIn('sFec', 'Fecha de pago', hoy(), 'type="date"')}
    <label class="field"><span>Medio de pago</span><select id="sMed">${['Transferencia', 'Consignación', 'Nequi', 'Daviplata', 'Efectivo', 'Otro'].map(x => opt(x, x)).join('')}</select></label>
    ${fIn('sRef', 'Referencia', '')}</div>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" onclick="guardarPagoSusc('${id}')">Registrar pago</button></div>`);
}
async function guardarPagoSusc(id) {
  const m = vv('sMes'); if (!/^\d{4}-\d{2}$/.test(m || '')) return toast('Elija el mes que paga');
  const d = { colegio_id: id, mes: m + '-01', valor: +vv('sVal') || 0, fecha: vv('sFec') || hoy(), medio: vv('sMed'), referencia: vv('sRef') };
  if (d.valor <= 0) return toast('Escriba el valor pagado');
  const ok = await guard(() => q(db.from('plataforma_pagos').insert(d)), `Pago de ${mesTxt(d.mes)} registrado`);
  if (ok !== undefined) { await guard(prepPlataforma); closeModal(); render(); }
}
async function toggleColegio(id, activo) {
  if (!activo && !await confirmar('Mientras esté suspendido, nadie del colegio podrá ingresar. Los datos se conservan. ¿Suspender?')) return;
  const ok = await guard(async () => { await q(db.rpc('plataforma_activar_colegio', { p_colegio: id, p_activo: activo })); return true; }, activo ? 'Colegio reactivado' : 'Colegio suspendido');
  if (ok) { await guard(prepPlataforma); render(); }
}

/* =====================================================================
   Utilidades de los paquetes de mejora
   ===================================================================== */
async function setPorClase(v) { const r = await guardarColegio({ asistencia_por_clase: v }, v ? 'Asistencia por clase activada' : 'Asistencia diaria activada'); if (r) S.loadedG.clear(); }
const BANCO_OBS = [
  'Felicitaciones por su excelente desempeño académico y su compromiso en clase.',
  'Muestra interés y participa activamente en las actividades propuestas.',
  'Es respetuoso(a) con sus compañeros y docentes; contribuye a la sana convivencia.',
  'Debe mejorar la puntualidad en la entrega de tareas y trabajos.',
  'Se recomienda reforzar en casa los hábitos de estudio y la lectura diaria.',
  'Requiere mayor concentración y atención durante las explicaciones.',
  'Presenta dificultades en algunas asignaturas; se recomienda acompañamiento familiar y asistir a las actividades de recuperación.',
  'Ha mostrado avances significativos con respecto al periodo anterior. ¡Siga así!',
  'Debe traer completos sus útiles y materiales de trabajo.',
  'Se destaca por su liderazgo, creatividad y trabajo en equipo.',
  'Es importante mejorar la asistencia; las fallas afectan su proceso de aprendizaje.',
  'Se invita al acudiente a acercarse a la institución para dialogar sobre el proceso del estudiante.',
];
function agregarFrase(eid, i) {
  const ta = $('#ob-' + eid), f = BANCO_OBS[+i]; if (!ta || !f) return;
  ta.value = (ta.value.trim() ? ta.value.trim() + ' ' : '') + f; setObs(eid, ta);
}
function descargarCSV(nombre, filas) {
  const c = v => { const t = v == null ? '' : String(v); return /[;"\n\r]/.test(t) ? '"' + t.replace(/"/g, '""') + '"' : t; };
  filas = [...filas, [], [`Generado con Colegio-IA · SkyNet Genesis · ${SG_CORREO} · WhatsApp 304 437 5758`]];
  const txt = '﻿' + filas.map(f => f.map(c).join(';')).join('\r\n');
  const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([txt], { type: 'text/csv;charset=utf-8' }));
  a.download = nombre.replace(/[^\wáéíóúñÁÉÍÓÚÑ .-]/g, '') + '.csv'; document.body.appendChild(a); a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 500);
  toast('Archivo descargado. Ábralo con Excel');
}
function exportarEstudiantes() {
  const maxA = Math.max(1, ...S.ests.map(e => acudDe(e.id).length));
  const cab = ['Folio', 'Matrícula', 'Apellidos', 'Nombres', 'Tipo doc.', 'Documento', 'Fecha nacimiento', 'Grupo', 'Jornada', 'Estado', 'EPS', 'RH', 'Dirección', 'Teléfono', 'PIAR', 'Autoriza datos'];
  for (let i = 1; i <= maxA; i++) cab.push(`Acudiente ${i}`, `Parentesco ${i}`, `Teléfono ${i}`, `Correo ${i}`);
  const filas = S.ests.slice().sort((a, b) => (a.folio || 0) - (b.folio || 0)).map(e => {
    const f = [e.folio, e.matricula, e.apellidos, e.nombres, e.tipo_doc, e.doc, fmtF(e.fnac), grupo(e.grupo_id)?.nombre || '', e.jornada, e.estado, e.eps, e.rh, e.direccion, e.telefono, e.piar ? 'Sí' : 'No', e.autoriza_datos ? 'Sí' : 'No'];
    const ac = acudDe(e.id); if (!ac.length && e.acudiente_nombre) ac.push({ nombres: e.acudiente_nombre, telefono: e.acudiente_tel });
    for (let i = 0; i < maxA; i++) { const a = ac[i] || {}; f.push(a.nombres, a.parentesco, a.telefono, a.email); }
    return f;
  });
  descargarCSV(`Estudiantes ${S.k.nombre} ${S.k.anio}`, [cab, ...filas]);
}
function exportarCartera() {
  descargarCSV(`Cartera ${anioCartera()} corte ${hoy()}`, [['Estudiante', 'Curso', 'Estado', 'Cobrado', 'Pagado', 'Saldo vencido', 'Saldo del año'],
    ...cartera.map(x => [x.nombre, x.grupo, x.estado, +x.cobrado, +x.pagado, +x.saldo_vencido, +x.saldo_total])]);
}
function exportarPlanilla() {
  const g = grupo(sel.ag), p = sel.app || S.k.periodo_actual, as = asigsDe(g);
  const val = (e, a) => p === 'acum' ? defin(e, a) : nota(e, a, p);
  descargarCSV(`Planilla ${g.nombre} ${p === 'acum' ? 'acumulado' : 'periodo ' + p} ${S.k.anio}`, [['Estudiante', ...as.map(a => a.nombre), 'Promedio'],
    ...estsDe(g.id).map(e => { const vs = as.map(a => val(e.id, a.id)), ok = vs.filter(x => x != null); return [`${e.apellidos} ${e.nombres}`, ...vs.map(v => N(v)), ok.length ? N(ok.reduce((a, b) => a + b, 0) / ok.length) : '']; })]);
}
// Reduce una foto a JPEG liviano para guardarla en la base de datos
function leerImagen(file, max = 1100) {
  return new Promise((ok, mal) => {
    if (!file) return ok(null);
    if (!/^image\//.test(file.type)) return mal(new Error('Adjunte una foto o imagen (JPG o PNG)'));
    const img = new Image(), url = URL.createObjectURL(file);
    img.onload = () => {
      let lado = max, cal = 0.62, out = '';
      for (let i = 0; i < 8; i++) {
        const k = Math.min(1, lado / Math.max(img.width, img.height)), c = document.createElement('canvas');
        c.width = Math.round(img.width * k); c.height = Math.round(img.height * k);
        c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
        out = c.toDataURL('image/jpeg', cal); if (out.length < 140000) break;
        lado *= 0.85; cal = Math.max(0.45, cal - 0.05);
      }
      URL.revokeObjectURL(url); out.length < 240000 ? ok(out) : mal(new Error('La imagen es muy grande'));
    };
    img.onerror = () => mal(new Error('No se pudo leer la imagen'));
    img.src = url;
  });
}
const diasEntre = (a, b) => Math.round((new Date(b + 'T12:00:00') - new Date(a + 'T12:00:00')) / 864e5);
function avisoCierre() {
  const pa = S.k.periodo_actual, ci = cierreDe(pa); if (!ci) return '';
  const d = diasEntre(hoy(), ci);
  if (d >= 0) return `<div class="note">Cierre de calificaciones del periodo ${pa}: <strong>${fechaLarga(ci)}</strong> (${d === 0 ? 'es hoy' : d === 1 ? 'falta 1 día' : `faltan ${d} días`}).${isDir() ? ' <button class="linkbtn" type="button" onclick="sel.atab=\'avance\';go(\'academico\')">Ver avance por docente</button>' : ''}</div>`;
  return isDir() ? `<div class="note">El periodo ${pa} cerró el ${fechaLarga(ci)}. Cuando termine de revisar, cambie el periodo en curso en <button class="linkbtn" type="button" onclick="irPtab('periodos')">Parametrización</button>.</div>` : `<div class="note">El periodo ${pa} cerró el ${fechaLarga(ci)}.</div>`;
}
const EST_TXT = { A: 'Ausente', T: 'Llegó tarde', E: 'Excusa justificada' };
function detalleFallas(eid) {
  const l = [];
  if (porClase()) Object.entries(S.asisC).forEach(([k, v]) => { const [f, e, a] = k.split('|'); if (e === eid) l.push({ f, t: EST_TXT[v], a: S.asigs.find(x => x.id === a)?.nombre || '' }); });
  else Object.entries(S.asis).forEach(([k, v]) => { const [f, e] = k.split('|'); if (e === eid) l.push({ f, t: EST_TXT[v] }); });
  l.sort((x, y) => y.f.localeCompare(x.f));
  openModal(`Asistencia de ${est(eid).nombres}`, l.length ? `<div class="tbl"><table><thead><tr><th>Fecha</th>${porClase() ? '<th>Clase</th>' : ''}<th>Novedad</th></tr></thead><tbody>${l.map(x => `<tr><td>${fmtF(x.f)}</td>${porClase() ? `<td>${esc(x.a)}</td>` : ''}<td>${x.t}</td></tr>`).join('')}</tbody></table></div>
    ${isAcud() ? '<p class="muted">Si su hijo(a) faltó por un motivo justificado, envíe la excusa desde la sección <button class="linkbtn" type="button" onclick="closeModal();go(\'excusas\')">Excusas</button>.</p>' : ''}` : '<p class="muted">No hay fallas ni llegadas tarde registradas este año.</p>');
}
function detalleAsig(aid) {
  const e = est(propio()), g = grupo(e.grupo_id), a = S.asigs.find(x => x.id === aid), pre = g.nivel === 'preescolar';
  const html = periodos().filter(p => p.n <= S.k.periodo_actual).map(p => {
    const v = nota(e.id, aid, p.n), acts = actsDe(g.id, aid, p.n), r = S.rec[`${e.id}|${aid}|${p.n}`], lo = S.logros[`${g.id}|${aid}|${p.n}`];
    return `<div class="item" style="margin-bottom:10px"><h3>Periodo ${p.n}: ${pre ? (v == null ? 'Sin valorar' : desem(v)) : chip(v)}</h3>
      ${lo ? `<div class="meta">Logros</div>${logroLista(lo)}` : ''}
      ${acts.length ? `<div class="tbl"><table><thead><tr><th>Actividad</th><th>Calificación</th></tr></thead><tbody>${acts.map(x => { const n = S.nact[`${x.id}|${e.id}`]; return `<tr><td>${esc(x.nombre)}${x.fecha ? ` <span class="muted">${fmtF(x.fecha)}</span>` : ''}</td><td>${n == null ? '<span class="muted">Pendiente</span>' : N(n)}</td></tr>`; }).join('')}</tbody></table></div>` : ''}
      ${r ? `<p><strong>Plan de recuperación:</strong> ${esc(r.plan)}${r.fecha ? ` (fecha: ${fmtF(r.fecha)})` : ''}${r.nota != null ? `. Calificación obtenida: ${N(r.nota)}` : ''}</p>` : ''}
      ${porClase() ? `<p class="muted">Fallas en la asignatura: ${fallasAsig(e.id, aid)}</p>` : ''}</div>`;
  }).join('');
  openModal(a.nombre, html || '<p class="muted">Aún no hay información.</p>');
}

/* =====================================================================
   Comunicados y circulares con confirmación de lectura
   ===================================================================== */
const TIPOS_COM = ['Circular', 'Citación', 'Recordatorio', 'Evento'];
const COM_COLS = 'id,colegio_id,tipo,titulo,cuerpo,destino,grupo_id,estudiante_id,fecha_evento,requiere_confirmacion,creado_por,autor_nombre,creado_en,con_imagen';
let lectAll = {};
async function cargarComs() {
  S.coms = await all(() => db.from('comunicados').select(COM_COLS).eq('colegio_id', ctx.colegio_id).order('creado_en', { ascending: false }));
  S.lect = {}; lectAll = {};
  if (isFam()) (await q(db.from('lecturas').select('comunicado_id').eq('user_id', me.id))).forEach(x => S.lect[x.comunicado_id] = true);
  else for (const part of chunks(S.coms.map(c => c.id), 80)) (await all(() => db.from('lecturas').select('comunicado_id,user_id,nombre,leido_en').in('comunicado_id', part).order('comunicado_id').order('user_id'))).forEach(x => (lectAll[x.comunicado_id] ||= []).push(x));
}
const comsMios = () => (S.coms || []).filter(c => !isFam() || c.destino !== 'estudiante' || c.estudiante_id === propio()).filter(c => !isFam() || c.destino !== 'grupo' || c.grupo_id === est(propio())?.grupo_id);
const noLeidos = () => isFam() ? comsMios().filter(c => !S.lect[c.id]).length : 0;
async function prepComunicados() {
  await cargarComs();
  if (isDir()) { await cargarMiembros().catch(() => {}); S.acud = await all(() => db.from('acudientes').select('estudiante_id,nombres,telefono,orden,responsable_pago').eq('colegio_id', ctx.colegio_id).order('estudiante_id').order('orden')).catch(() => S.acud); }
  if (isFam()) { // los que no piden confirmación se marcan leídos al abrir
    const auto = comsMios().filter(c => !c.requiere_confirmacion && !S.lect[c.id]);
    if (auto.length) { await q(db.from('lecturas').upsert(auto.map(c => ({ comunicado_id: c.id, user_id: me.id, nombre: ctx.nombre })), { onConflict: 'comunicado_id,user_id', ignoreDuplicates: true })).catch(() => {}); auto.forEach(c => S.lect[c.id] = 'nuevo'); }
  }
}
const destinoTxt = c => c.destino === 'todos' ? 'Toda la comunidad' : c.destino === 'grupo' ? `Curso ${grupo(c.grupo_id)?.nombre || ''}` : `Familia de ${est(c.estudiante_id) ? nom(est(c.estudiante_id)) : 'un estudiante'}`;
const fechaHora = t => new Date(t).toLocaleString('es-CO', { day: 'numeric', month: 'short', year: 'numeric', hour: 'numeric', minute: '2-digit' });
const puedeComunicar = () => isDir() || isDoc();
function agendaHTML() {
  const h = hoy(), items = [];
  (S.coms || []).forEach(c => { if (c.fecha_evento && c.fecha_evento.slice(0, 10) >= h && (!isFam() || comsMios().includes(c))) items.push({ f: c.fecha_evento.slice(0, 10), t: `${c.tipo}: ${c.titulo}`, h: fechaHora(c.fecha_evento) }); });
  periodos().forEach(p => {
    if (p.cierre && p.cierre >= h && !isFam()) items.push({ f: p.cierre, t: `Cierre de calificaciones del periodo ${p.n}` });
    if (p.fin && p.fin >= h) items.push({ f: p.fin, t: `Termina el periodo ${p.n}` });
    if (p.inicio && p.inicio >= h) items.push({ f: p.inicio, t: `Inicia el periodo ${p.n}` });
  });
  items.sort((a, b) => a.f.localeCompare(b.f));
  return items.length ? `<section class="panel"><h2>Próximas fechas</h2><ul class="list">${items.slice(0, 8).map(x => `<li><strong>${x.h || fechaLarga(x.f)}</strong> · ${esc(x.t)}</li>`).join('')}</ul></section>` : '';
}
function vComunicados() {
  setTimeout(() => cargarImgs('comunicados', 'imagen', 'img.foto-com'), 0);
  const l = isFam() ? comsMios() : (S.coms || []).filter(c => isDir() || isTes() || c.destino === 'todos' || gruposVis().some(g => g.id === c.grupo_id || g.id === est(c.estudiante_id)?.grupo_id));
  return head('Comunicados', isFam() ? 'Circulares, citaciones y avisos del colegio. Confirme la lectura de los que lo solicitan.' : 'Envíe circulares, citaciones y recordatorios, y vea quién los ha leído.',
    puedeComunicar() ? '<button class="btn" type="button" onclick="formComunicado()">Nuevo comunicado</button>' : '') + agendaHTML() +
    (l.length ? `<div class="card-list">${l.map(c => {
      const leido = S.lect[c.id], lects = lectAll[c.id] || [], mio = isDir() || c.creado_por === me.id;
      return `<article class="item ${isFam() && (!leido || leido === 'nuevo') ? 'unread' : ''}"><div style="display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap"><h3>${esc(c.titulo)}</h3><span class="tag ${c.tipo === 'Citación' ? 't3' : c.tipo === 'Evento' ? 't2' : ''}">${c.tipo}</span></div>
        <div class="meta">${fechaHora(c.creado_en)} · ${esc(c.autor_nombre || '')}${isFam() ? '' : ' · ' + esc(destinoTxt(c))}</div>
        ${c.fecha_evento ? `<p><strong>Fecha:</strong> ${fechaHora(c.fecha_evento)}</p>` : ''}
        <p style="white-space:pre-wrap">${esc(c.cuerpo)}</p>
        ${c.con_imagen && Date.now() - new Date(c.creado_en) < 15 * 864e5 ? `<div class="foto-box com-foto"><img class="foto-com" data-id="${c.id}" alt="Foto del comunicado" onclick="verFotoEl(this)"></div>` : ''}
        <div class="toolbar" style="margin:6px 0 0">${isFam()
          ? (leido ? `<span class="ok">Leído</span>` : `<button class="btn sm" type="button" onclick="marcarLeido('${c.id}')">Confirmar que lo leí</button>`)
          : `<span class="muted">Leído por ${lects.length}</span> <button class="btn ghost sm" type="button" onclick="verLecturas('${c.id}')">Ver quién leyó</button>
             <button class="btn ghost sm" type="button" onclick="copiarCom('${c.id}')">Copiar para WhatsApp</button>${c.destino === 'estudiante' ? waCom(c) : ''}
             ${mio ? `<button class="btn ghost sm" type="button" onclick="borrarComunicado('${c.id}')">Eliminar</button>` : ''}`}</div></article>`;
    }).join('')}</div>` : '<div class="panel empty">Aún no hay comunicados.</div>');
}
function textoCom(c) { return `*${S.k.nombre}*\n${c.tipo}: ${c.titulo}\n\n${c.cuerpo}${c.fecha_evento ? `\n\nFecha: ${fechaHora(c.fecha_evento)}` : ''}\n\nConfirme la lectura en Colegio-IA: ${location.origin + location.pathname}`; }
function waCom(c) {
  const a = (S.acud || []).filter(x => x.estudiante_id === c.estudiante_id).sort((x, y) => x.orden - y.orden)[0];
  const tel = a?.telefono || est(c.estudiante_id)?.acudiente_tel; return tel ? waBtn(tel, textoCom(c), 'WhatsApp al acudiente') : '';
}
async function copiarCom(id) {
  const t = textoCom(S.coms.find(c => c.id === id));
  try { await navigator.clipboard.writeText(t); toast('Texto copiado. Péguelo en el grupo de WhatsApp'); } catch { openModal('Copiar texto', `<textarea id="cpT" style="width:100%;min-height:200px">${esc(t)}</textarea><div class="modal-foot"><button class="btn" type="button" onclick="copiar('#cpT')">Copiar</button></div>`); }
}
function formComunicado(tipo0 = 'Circular') {
  const gs = isDir() ? S.grupos : gruposVis();
  if (!gs.length && !isDir()) return toast('No tiene grupos asignados');
  openModal('Nuevo comunicado', `<div class="formgrid">
    <label class="field"><span>Tipo</span><select id="cTipo" onchange="document.getElementById('cFevBox').hidden=!['Citación','Evento'].includes(this.value)">${TIPOS_COM.map(t => opt(t, t, tipo0)).join('')}</select></label>
    <label class="field"><span>Para</span><select id="cDest" onchange="destCom()">${isDir() ? opt('todos', 'Toda la comunidad', 'todos') : ''}${opt('grupo', 'Un curso')}${opt('estudiante', 'La familia de un estudiante')}</select></label>
    <label class="field" id="cGBox" ${isDir() ? 'hidden' : ''}><span>Curso</span><select id="cGrupo" onchange="destCom()">${gs.map(g => opt(g.id, g.nombre, sel.g)).join('')}</select></label>
    <label class="field" id="cEBox" hidden><span>Estudiante</span><select id="cEst"></select></label>
    ${fIn('cTit', 'Título', '', 'maxlength="120"')}
    <label class="field" id="cFevBox" ${['Citación', 'Evento'].includes(tipo0) ? '' : 'hidden'}><span>Fecha y hora</span><input id="cFev" type="datetime-local"></label>
    ${fTa('cCue', 'Mensaje', '', 'Escriba el comunicado…')}
    <label class="field full"><span>Foto (opcional): afiche, invitación o imagen del evento. Se borra sola a los 15 días</span><input type="file" id="cImg" accept="image/*"></label>
    <label class="chk full"><input type="checkbox" id="cConf" checked> Pedir confirmación de lectura a las familias</label></div>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" id="cEnv" onclick="guardarComunicado()">Enviar</button></div>`);
  destCom();
}
function destCom() {
  const d = $('#cDest').value; $('#cGBox').hidden = d === 'todos'; $('#cEBox').hidden = d !== 'estudiante';
  if (d === 'estudiante') $('#cEst').innerHTML = estsDe($('#cGrupo').value).map(e => opt(e.id, `${e.apellidos} ${e.nombres}`)).join('');
}
async function guardarComunicado() {
  const d = $('#cDest').value, fev = $('#cFev').value;
  const c = { colegio_id: ctx.colegio_id, tipo: $('#cTipo').value, titulo: vv('cTit'), cuerpo: vv('cCue'), destino: d,
    grupo_id: d === 'todos' ? null : $('#cGrupo').value, estudiante_id: d === 'estudiante' ? $('#cEst').value || null : null,
    fecha_evento: fev && !$('#cFevBox').hidden ? new Date(fev).toISOString() : null, requiere_confirmacion: $('#cConf').checked };
  if (!c.titulo || !c.cuerpo) return toast('Escriba el título y el mensaje');
  if (d === 'estudiante' && !c.estudiante_id) return toast('Elija el estudiante');
  if (d === 'estudiante') c.grupo_id = null;
  if (c.tipo === 'Evento' && !c.fecha_evento) return toast('Escriba la fecha y hora del evento');
  const r = await busy('#cEnv', () => guard(async () => { c.imagen = await leerImagen($('#cImg')?.files[0]); return q(db.from('comunicados').insert(c).select(COM_COLS).single()); }, 'Comunicado enviado'));
  if (r) { if (c.imagen) imgCache[r.id] = c.imagen; S.coms.unshift(r); closeModal(); render(); }
}
async function marcarLeido(id) {
  const ok = await guard(async () => { await q(db.from('lecturas').upsert({ comunicado_id: id, user_id: me.id, nombre: ctx.nombre }, { onConflict: 'comunicado_id,user_id', ignoreDuplicates: true })); return true; }, 'Gracias, lectura confirmada');
  if (ok) { S.lect[id] = true; render(); }
}
function verLecturas(id) {
  const c = S.coms.find(x => x.id === id), l = (lectAll[id] || []).slice().sort((a, b) => a.leido_en.localeCompare(b.leido_en));
  let pend = '';
  if (S.miembros) {
    const ok = new Set(l.map(x => x.user_id));
    const dest = S.miembros.filter(m => m.activo && m.user_id && m.estudiante_id && (c.destino === 'todos' || (c.destino === 'grupo' && est(m.estudiante_id)?.grupo_id === c.grupo_id) || (c.destino === 'estudiante' && m.estudiante_id === c.estudiante_id)) && !ok.has(m.user_id));
    pend = `<h3 style="margin-top:14px">Sin leer (${dest.length})</h3>${dest.length ? `<ul class="list">${dest.map(m => `<li>${esc(m.nombre)} <span class="muted">${ROL_TXT[m.rol]} de ${esc(est(m.estudiante_id)?.nombres || '')}</span></li>`).join('')}</ul>` : '<p class="muted">Todas las familias con cuenta activa lo leyeron.</p>'}`;
  }
  openModal(`Lecturas: ${c.titulo}`, `<h3>Leído (${l.length})</h3>${l.length ? `<ul class="list">${l.map(x => `<li>${esc(x.nombre || 'Usuario')} <span class="muted">${fechaHora(x.leido_en)}</span></li>`).join('')}</ul>` : '<p class="muted">Nadie lo ha leído todavía.</p>'}${pend}`);
}
async function borrarComunicado(id) {
  if (!await confirmar('¿Eliminar este comunicado? Las familias ya no lo verán.')) return;
  const ok = await guard(async () => { await q(db.from('comunicados').delete().eq('id', id)); return true; }, 'Comunicado eliminado');
  if (ok) { S.coms = S.coms.filter(c => c.id !== id); render(); }
}

/* =====================================================================
   Etapa 2: fotos de la semana, carnet digital, contactos de emergencia,
   personas autorizadas para recoger, cronograma y redes sociales
   ===================================================================== */
const DIAS_SEM = ['', 'Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo'];
const isoDow = f => { const d = new Date(f + 'T12:00:00').getDay(); return d === 0 ? 7 : d; };
const sumarDias = (f, n) => { const d = new Date(f + 'T12:00:00'); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); };
const lunesDe = f => sumarDias(f, 1 - isoDow(f));
const esPersonal = () => isDir() || isDoc() || isTes();
const gruposGaleria = () => isFam() ? [grupo(est(propio())?.grupo_id)].filter(Boolean) : isDir() ? S.grupos : gruposVis();

// Carga perezosa de imágenes guardadas en la base (solo las que están en pantalla)
const imgCache = {};
async function cargarImgs(tabla, campo, sel_) {
  const els = [...document.querySelectorAll(sel_)].filter(x => !x.src);
  const faltan = els.map(x => x.dataset.id).filter(id => !(id in imgCache));
  for (const part of chunks([...new Set(faltan)], 12)) {
    const l = await q(db.from(tabla).select(`id,${campo}`).in('id', part)).catch(() => []);
    l.forEach(x => imgCache[x.id] = x[campo] || '');
  }
  els.forEach(x => { if (imgCache[x.dataset.id]) x.src = imgCache[x.dataset.id]; else x.closest('.foto-box')?.remove(); });
}
function verFoto(src, pie = '') { openModal('Foto', `<img src="${src}" alt="${esc(pie)}" style="width:100%;border-radius:8px">${pie ? `<p>${esc(pie)}</p>` : ''}`); }
function verFotoEl(el) { if (el.src) verFoto(el.src, el.alt); }

/* ---------- Fotos de la semana (galería de clase) ---------- */
let fotos = [];
async function prepGaleria() {
  const gs = gruposGaleria();
  if (!gs.some(g => g.id === sel.gal)) sel.gal = gs[0]?.id || '';
  const lun = lunesDe(hoy());
  if (!sel.gdia || sel.gdia < lun || sel.gdia > hoy()) sel.gdia = hoy();
  fotos = sel.gal ? await all(() => db.from('fotos_clase').select('id,grupo_id,fecha,pie,autor_nombre,creado_por,creado_en').eq('grupo_id', sel.gal).gte('fecha', lun).order('creado_en').order('id')) : [];
}
function vGaleria() {
  const gs = gruposGaleria(), g = grupo(sel.gal), lun = lunesDe(hoy()), h = hoy();
  const puede = isDir() || (isDoc() && gruposVis().some(x => x.id === sel.gal));
  if (!gs.length) return head('Fotos de la semana') + '<div class="panel empty">No hay cursos para mostrar.</div>';
  const delDia = fotos.filter(f => f.fecha === sel.gdia);
  setTimeout(() => cargarImgs('fotos_clase', 'imagen', 'img.foto-cl'), 0);
  return head('Fotos de la semana', isFam() ? `Lo que hizo ${esc(est(propio())?.nombres || 'su hijo(a)')} en clase esta semana.` : 'Comparta con las familias las actividades del día. Cada curso ve solo sus fotos.') +
    `<div class="panel">${gs.length > 1 ? `<div class="toolbar"><label class="field"><span>Curso</span><select onchange="sel.gal=this.value;go('galeria')">${gs.map(x => opt(x.id, x.nombre, sel.gal)).join('')}</select></label></div>` : ''}
      <div class="tabs" role="tablist">${[1, 2, 3, 4, 5, 6, 7].map(n => { const f = sumarDias(lun, n - 1), c = fotos.filter(x => x.fecha === f).length; if (f > h && !c) return ''; return `<button type="button" role="tab" aria-selected="${f === sel.gdia}" onclick="sel.gdia='${f}';render()">${DIAS_SEM[n]}${c ? ` <span class="badge">${c}</span>` : ''}</button>`; }).join('')}</div>
      <p class="muted">${fechaLarga(sel.gdia)} · ${esc(g?.nombre || '')}. Las fotos se borran automáticamente al terminar la semana (domingo a medianoche).</p>
      ${puede && sel.gdia <= h ? `<div class="toolbar"><label class="btn" id="galBtn">Subir fotos del ${sel.gdia === h ? 'día de hoy' : DIAS_SEM[isoDow(sel.gdia)].toLowerCase()}<input type="file" accept="image/*" multiple hidden onchange="subirFotosClase(this)"></label><span class="muted">Hasta 8 fotos por curso cada día. Sirven para que las familias vean las actividades y para que quien faltó vea el tablero y los cuadernos.</span></div>` : ''}
      ${delDia.length ? `<div class="galeria">${delDia.map(f => `<figure class="foto-box"><img class="foto-cl" data-id="${f.id}" alt="${esc(f.pie || 'Foto de clase')}" onclick="verFotoEl(this)">
        <figcaption>${f.pie ? esc(f.pie) + '<br>' : ''}<span class="muted">${esc(f.autor_nombre || '')}</span>${f.creado_por === me.id || isDir() ? ` <button class="linkbtn" type="button" onclick="borrarFotoClase('${f.id}')">Borrar</button>` : ''}</figcaption></figure>`).join('')}</div>`
        : `<p class="empty">${sel.gdia === h ? 'Aún no hay fotos de hoy.' : 'No hubo fotos este día.'}</p>`}</div>`;
}
async function subirFotosClase(input) {
  const files = [...input.files]; if (!files.length) return;
  const pie = files.length === 1 ? (await pedirTexto('Escriba una frase para la foto (opcional):') || '').slice(0, 200) : '';
  let n = 0;
  await busy('#galBtn', async () => {
    for (const f of files) {
      const r = await guard(async () => { const imagen = await leerImagen(f, 900); return q(db.from('fotos_clase').insert({ grupo_id: sel.gal, imagen, pie: pie || null, fecha: sel.gdia }).select('id').single()); });
      if (!r) break; n++;
    }
  });
  if (n) { toast(n === 1 ? 'Foto publicada' : `${n} fotos publicadas`); await go('galeria'); }
}
async function borrarFotoClase(id) {
  if (!await confirmar('¿Borrar esta foto?')) return;
  const ok = await guard(async () => { await q(db.from('fotos_clase').delete().eq('id', id)); return true; }, 'Foto borrada');
  if (ok) { fotos = fotos.filter(f => f.id !== id); render(); }
}

/* ---------- Carnet digital y contactos (familia) ---------- */
let contactos = [], fotoEst = {};
async function cargarFotoEst(ids) {
  for (const part of chunks(ids.filter(id => !(id in fotoEst)), 40)) {
    const l = await q(db.from('fotos_est').select('estudiante_id,foto').in('estudiante_id', part)).catch(() => []);
    part.forEach(id => fotoEst[id] = ''); l.forEach(x => fotoEst[x.estudiante_id] = x.foto);
  }
}
async function prepFamilia() {
  const e = propio(); if (!e) return;
  await cargarFotoEst([e]);
  contactos = await q(db.from('contactos_est').select('*').eq('estudiante_id', e).order('creado_en'));
}
function carnetHTML(eid) {
  const e = est(eid), g = grupo(e?.grupo_id), k = S.k, f = fotoEst[eid];
  return `<div class="carnet">
    <div class="carnet-top">${k.logo ? `<img src="${k.logo}" alt="">` : ''}<div><strong>${esc(k.nombre)}</strong><span>Carnet estudiantil ${k.anio}</span></div></div>
    <div class="carnet-body"><div class="carnet-foto">${f ? `<img src="${f}" alt="Foto de ${esc(e.nombres)}">` : '<span>Sin foto</span>'}</div>
      <div class="carnet-datos"><div class="carnet-nom">${esc(e.nombres)}<br>${esc(e.apellidos)}</div>
        <div>${esc(e.tipo_doc)} ${esc(e.doc)}</div><div>Curso: <strong>${esc(g?.nombre || '—')}</strong></div>
        <div class="carnet-est">${e.estado === 'Activo' ? 'Estudiante activo' : esc(e.estado)}</div></div></div>
    <div class="carnet-pie">${esc([k.ciudad, k.telefono ? 'Tel. ' + k.telefono : ''].filter(Boolean).join(' · '))}</div></div>`;
}
const TIPO_CONT = { emergencia: 'Contactos de emergencia', recoger: 'Personas autorizadas para recoger' };
// Las personas retiradas no se borran: quedan en el historial con fecha y quién las retiró (respaldo del colegio)
function listaContactos(l, tipo, borrar) {
  const xs = l.filter(c => c.tipo === tipo && c.activo !== false), ret = l.filter(c => c.tipo === tipo && c.activo === false);
  const desde = c => `<span class="muted" style="font-size:.85rem">Registrado el ${fmtF(c.creado_en)}${c.creado_nombre ? ' por ' + esc(c.creado_nombre) : ''}</span>`;
  return (xs.length ? `<ul class="list">${xs.map(c => `<li><strong>${esc(c.nombre)}</strong>${c.parentesco ? ` <span class="muted">(${esc(c.parentesco)})</span>` : ''}<br>${c.telefono ? `<a href="tel:${esc(c.telefono)}">${esc(c.telefono)}</a>` : ''}${c.doc ? ` · Doc. ${esc(c.doc)}` : ''}${borrar ? ` <button class="linkbtn" type="button" onclick="borrarContacto('${c.id}')">Retirar</button>` : ''}<br>${desde(c)}</li>`).join('')}</ul>`
    : `<p class="muted">${tipo === 'emergencia' ? 'No hay contactos de emergencia registrados.' : 'No hay personas autorizadas registradas.'}</p>`) +
    (ret.length ? `<details class="hist"><summary>Historial: ${ret.length} ${ret.length === 1 ? 'persona retirada' : 'personas retiradas'}</summary><ul class="list">${ret.map(c => `<li class="dim"><strong>${esc(c.nombre)}</strong>${c.parentesco ? ` (${esc(c.parentesco)})` : ''}${c.doc ? ` · Doc. ${esc(c.doc)}` : ''}<br><span class="muted" style="font-size:.85rem">Autorizado(a) del ${fmtF(c.creado_en)} al ${fmtF(c.retirado_en)}${c.retirado_nombre ? '; retirado(a) por ' + esc(c.retirado_nombre) : ''}</span></li>`).join('')}</ul></details>` : '');
}
function vFamilia() {
  const e = est(propio()); if (!e) return head('Carnet y contactos') + '<div class="panel empty">No encontramos la información del estudiante.</div>';
  const acud = isAcud();
  return head(`Carnet y contactos de ${esc(e.nombres)}`, 'El carnet digital sirve para identificar al estudiante. Los contactos los ve el colegio en caso de emergencia o a la hora de la salida.') +
    `<div class="cols"><section class="panel"><h2>Carnet digital</h2>${carnetHTML(e.id)}
      <div class="toolbar" style="margin-top:12px">${acud ? `<label class="btn ghost" id="fotoBtn">${fotoEst[e.id] ? 'Cambiar foto' : 'Subir foto'}<input type="file" accept="image/*" hidden onchange="subirFotoEst('${e.id}',this)"></label>` : ''}<button class="btn ghost" type="button" onclick="imprimirCarnet('${e.id}')">Descargar carnet</button></div>
      ${acud ? '<p class="muted">Use una foto tipo documento: de frente, con fondo claro y buena luz.</p>' : ''}</section>
    <section class="panel"><h2>${TIPO_CONT.emergencia}</h2>${listaContactos(contactos, 'emergencia', acud)}
      <h2 style="margin-top:18px">${TIPO_CONT.recoger}</h2><p class="muted">Solo estas personas pueden recoger a ${esc(e.nombres)} en el colegio. Deben presentar su documento.</p>${listaContactos(contactos, 'recoger', acud)}
      ${acud ? `<div class="toolbar" style="margin-top:12px"><button class="btn sm" type="button" onclick="formContacto('emergencia')">Agregar contacto de emergencia</button><button class="btn sm ghost" type="button" onclick="formContacto('recoger')">Agregar persona autorizada</button></div>` : ''}</section></div>`;
}
async function subirFotoEst(eid, input) {
  const f = input.files[0]; if (!f) return;
  await busy('#fotoBtn', async () => {
    const r = await guard(async () => { const foto = await leerImagen(f, 300); await q(db.from('fotos_est').upsert({ estudiante_id: eid, foto }, { onConflict: 'estudiante_id' })); return foto; }, 'Foto guardada');
    if (r) { fotoEst[eid] = r; render(); }
  });
}
function imprimirCarnet(eid) {
  showDocs(`<section class="doc"><div style="display:flex;justify-content:center;padding:20px 0">${carnetHTML(eid)}</div></section>`, 'Carnet estudiantil', nomArchivo('Carnet', est(eid)));
}
function formContacto(tipo) {
  openModal(tipo === 'emergencia' ? 'Contacto de emergencia' : 'Persona autorizada para recoger', `<div class="formgrid">
    ${fIn('ctN', 'Nombre completo', '', 'maxlength="120"')}${fIn('ctP', 'Parentesco', '', 'maxlength="60" placeholder="Ejemplo: abuela, tío, vecino"')}
    ${fIn('ctT', 'Teléfono celular', '', 'type="tel" maxlength="30"')}${tipo === 'recoger' ? fIn('ctD', 'Número de documento', '', 'maxlength="30"') : ''}</div>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" onclick="guardarContacto('${tipo}')">Guardar</button></div>`);
}
async function guardarContacto(tipo) {
  const d = { estudiante_id: propio(), tipo, nombre: vv('ctN'), parentesco: vv('ctP') || null, telefono: vv('ctT') || null, doc: tipo === 'recoger' ? vv('ctD') || null : null };
  if (d.nombre.length < 3) return toast('Escriba el nombre completo');
  if (!d.telefono) return toast('Escriba el teléfono');
  if (tipo === 'recoger' && !d.doc) return toast('Escriba el número de documento');
  const r = await guard(() => q(db.from('contactos_est').insert(d).select().single()), 'Guardado');
  if (r) { contactos.push(r); closeModal(); render(); }
}
async function borrarContacto(id) {
  if (!await confirmar('¿Retirar a esta persona? Desde ahora no aparecerá como autorizada, pero queda en el historial con la fecha de hoy.', 'Sí, retirar')) return;
  const ok = await guard(async () => { await q(db.rpc('retirar_contacto', { p_id: id })); return true; }, 'Persona retirada. Queda en el historial');
  if (ok) { const c = contactos.find(x => x.id === id); if (c) Object.assign(c, { activo: false, retirado_en: new Date().toISOString(), retirado_nombre: ctx.nombre }); render(); }
}

/* ---------- Contactos y recogida (personal del colegio) ---------- */
let contactosG = [];
async function prepContactos() {
  const gs = isDir() ? S.grupos : gruposVis();
  if (!gs.some(g => g.id === sel.cg)) sel.cg = gs[0]?.id || '';
  if (!sel.cg) { contactosG = []; return; }
  await cargarGrupo(sel.cg);
  const ids = estsDe(sel.cg).map(e => e.id);
  contactosG = [];
  for (const part of chunks(ids, 80)) contactosG.push(...await all(() => db.from('contactos_est').select('*').in('estudiante_id', part).order('estudiante_id').order('creado_en').order('id')));
}
function vContactos() {
  const gs = isDir() ? S.grupos : gruposVis();
  if (!gs.length) return head('Contactos y recogida') + '<div class="panel empty">No tiene cursos asignados.</div>';
  const es = estsDe(sel.cg);
  return head('Contactos y recogida', 'Contactos de emergencia y personas autorizadas para recoger a cada estudiante. Los registra la familia desde su cuenta.') +
    `<div class="panel"><div class="toolbar"><label class="field"><span>Curso</span><select onchange="sel.cg=this.value;go('contactos')">${gs.map(g => opt(g.id, g.nombre, sel.cg)).join('')}</select></label>
      <label class="field"><span>Buscar</span><input type="search" placeholder="Nombre del estudiante" oninput="filtrarFilas(this.value)"></label></div>
      <div class="tbl"><table><thead><tr><th>Estudiante</th><th>Emergencia</th><th>Autorizados para recoger</th><th></th></tr></thead><tbody>
      ${es.map(e => { const l = contactosG.filter(c => c.estudiante_id === e.id && c.activo !== false), em = l.filter(c => c.tipo === 'emergencia'), rc = l.filter(c => c.tipo === 'recoger'), nr = contactosG.filter(c => c.estudiante_id === e.id && c.activo === false && c.tipo === 'recoger');
        return `<tr class="fila-busca" data-n="${esc(nom(e).toLowerCase())}"><td><strong>${esc(e.apellidos)}</strong> ${esc(e.nombres)}</td>
          <td>${em.length ? em.map(c => `${esc(c.nombre)}${c.parentesco ? ` <span class="muted">(${esc(c.parentesco)})</span>` : ''}<br>${c.telefono ? `<a href="tel:${esc(c.telefono)}">${esc(c.telefono)}</a>` : ''}`).join('<hr>') : '<span class="muted">Sin registrar</span>'}</td>
          <td>${rc.length ? rc.map(c => `${esc(c.nombre)}${c.parentesco ? ` <span class="muted">(${esc(c.parentesco)})</span>` : ''}<br><span class="muted">Doc. ${esc(c.doc || '—')}</span>`).join('<hr>') : '<span class="muted">Sin registrar</span>'}${nr.length ? `<details class="hist"><summary>${nr.length} retirado(s)</summary>${nr.map(c => `<div class="dim">${esc(c.nombre)} · ${fmtF(c.creado_en)} al ${fmtF(c.retirado_en)}</div>`).join('')}</details>` : ''}</td>
          <td><button class="btn ghost sm" type="button" onclick="verCarnet('${e.id}')">Carnet</button></td></tr>`; }).join('')}</tbody></table></div></div>`;
}
function filtrarFilas(t) { const x = t.toLowerCase().trim(); document.querySelectorAll('.fila-busca').forEach(r => r.hidden = !!x && !r.dataset.n.includes(x)); }
async function verCarnet(eid) {
  await guard(() => cargarFotoEst([eid]));
  const puede = isDir() || ctx.rol === 'secretaria';
  openModal('Carnet estudiantil', `<div style="display:flex;justify-content:center">${carnetHTML(eid)}</div>
    <div class="modal-foot">${puede ? `<label class="btn ghost" id="fotoBtn">${fotoEst[eid] ? 'Cambiar foto' : 'Subir foto'}<input type="file" accept="image/*" hidden onchange="subirFotoEstModal('${eid}',this)"></label>` : ''}${isDoc() ? '' : `<button class="btn" type="button" onclick="imprimirCarnet('${eid}')">Descargar carnet</button>`}</div>`);
}
async function subirFotoEstModal(eid, input) {
  const f = input.files[0]; if (!f) return;
  const r = await guard(async () => { const foto = await leerImagen(f, 300); await q(db.from('fotos_est').upsert({ estudiante_id: eid, foto }, { onConflict: 'estudiante_id' })); return foto; }, 'Foto guardada');
  if (r) { fotoEst[eid] = r; verCarnet(eid); }
}

/* ---------- Cronograma del colegio ---------- */
async function prepCronograma() { await cargarComs(); }
function eventosCrono() {
  const items = [], vis = isFam() ? comsMios() : (S.coms || []).filter(c => isDir() || isTes() || c.destino === 'todos' || gruposVis().some(g => g.id === c.grupo_id || g.id === est(c.estudiante_id)?.grupo_id));
  vis.forEach(c => { if (c.fecha_evento) items.push({ f: new Date(c.fecha_evento).toLocaleDateString('en-CA', { timeZone: 'America/Bogota' }), hora: new Date(c.fecha_evento).toLocaleTimeString('es-CO', { hour: 'numeric', minute: '2-digit' }), t: c.titulo, tipo: c.tipo, d: c.destino === 'todos' ? '' : destinoTxt(c) }); });
  periodos().forEach(p => {
    if (p.inicio) items.push({ f: p.inicio, t: `Inicia el periodo ${p.n}`, tipo: 'Académico' });
    if (p.fin) items.push({ f: p.fin, t: `Termina el periodo ${p.n}`, tipo: 'Académico' });
    if (p.cierre && !isFam()) items.push({ f: p.cierre, t: `Cierre de calificaciones del periodo ${p.n}`, tipo: 'Académico' });
  });
  return items.sort((a, b) => a.f.localeCompare(b.f) || (a.hora || '').localeCompare(b.hora || ''));
}
function vCronograma() {
  const h = hoy(), todos = eventosCrono(), l = sel.cpas ? todos : todos.filter(x => x.f >= h);
  const meses = {}; l.forEach(x => (meses[x.f.slice(0, 7)] ||= []).push(x));
  return head('Cronograma', 'Fechas importantes del año: eventos, citaciones, reuniones y periodos académicos.', puedeComunicar() ? `<button class="btn" type="button" onclick="formComunicado('Evento')">Nuevo evento</button>` : '') +
    `<div class="panel"><label class="chk"><input type="checkbox" ${sel.cpas ? 'checked' : ''} onchange="sel.cpas=this.checked;render()"> Mostrar también las fechas pasadas</label>
    ${Object.keys(meses).length ? Object.entries(meses).map(([m, xs]) => `<h2 style="margin-top:16px">${(t => t[0].toUpperCase() + t.slice(1))(new Date(m + '-15T12:00:00').toLocaleDateString('es-CO', { month: 'long', year: 'numeric' }))}</h2>
      <ul class="list crono">${xs.map(x => `<li class="${x.f < h ? 'dim' : ''}"><span class="crono-f"><strong>${new Date(x.f + 'T12:00:00').getDate()}</strong>${DIAS_SEM[isoDow(x.f)].slice(0, 3)}</span><div><strong>${esc(x.t)}</strong> <span class="tag ${x.tipo === 'Citación' ? 't3' : x.tipo === 'Evento' ? 't2' : ''}">${esc(x.tipo)}</span><br><span class="muted">${x.hora ? x.hora : ''}${x.d ? (x.hora ? ' · ' : '') + esc(x.d) : ''}</span></div></li>`).join('')}</ul>`).join('')
      : '<p class="empty">No hay fechas próximas. Los eventos y citaciones con fecha aparecen aquí automáticamente.</p>'}</div>`;
}

/* ---------- Redes sociales del colegio ---------- */
const REDES = [['red_facebook', 'Facebook'], ['red_instagram', 'Instagram'], ['red_youtube', 'YouTube'], ['red_tiktok', 'TikTok']];
const urlSegura = u => /^https:\/\/[^\s"'<>]+$/.test(u || '') ? u : '';
// Acepta el enlace como lo pegue la persona (con o sin https://) y lo deja en https://
function normUrl(v) {
  let t = String(v || '').trim(); if (!t) return '';
  t = t.replace(/^http:\/\//i, 'https://'); if (!/^https:\/\//i.test(t)) t = 'https://' + t.replace(/^\/+/, '');
  try { const u = new URL(t); return /\./.test(u.hostname) && !/[\s"'<>]/.test(t) ? u.href : null; } catch { return null; }
}
function redesHTML() {
  const k = S.k, l = REDES.filter(([c]) => urlSegura(k[c])).map(([c, n]) => `<a class="btn ghost sm" href="${esc(k[c])}" target="_blank" rel="noopener">${n}</a>`);
  if (urlSegura(k.web)) l.push(`<a class="btn ghost sm" href="${esc(k.web)}" target="_blank" rel="noopener">Página web</a>`);
  return l.length ? `<section class="panel redes"><h2>Síganos</h2><div class="toolbar" style="margin:0">${l.join('')}</div></section>` : '';
}
function panelRedes() {
  const r = esRector(), k = S.k;
  return `<div class="panel"><h2>Redes sociales</h2><p class="muted">Aparecen en el inicio de las familias y del personal. Pegue el enlace completo de cada red (empieza por https://).</p>
    <div class="formgrid">${REDES.map(([c, n]) => fIn('rs_' + c, n, k[c] || '', `placeholder="https://" ${r ? '' : 'disabled'}`)).join('')}</div>
    ${r ? '<div class="toolbar" style="margin-top:12px"><button class="btn" type="button" onclick="guardarRedes()">Guardar redes</button></div>' : ''}</div>`;
}
async function guardarRedes() {
  const d = {};
  for (const [c, n] of REDES) { const v = vv('rs_' + c), u = v ? normUrl(v) : ''; if (u === null) return toast(`El enlace de ${n} no parece válido. Cópielo desde la barra de direcciones`); d[c] = u || null; }
  await guardarColegio(d, 'Redes guardadas');
}

/* =====================================================================
   Etapa 2B: campana de avisos, "Hoy" para las familias, mensajes privados,
   autorizaciones y citas
   ===================================================================== */
function llenarEsts(id, gid) { const el = document.getElementById(id); if (el) el.innerHTML = estsDe(gid).map(e => opt(e.id, `${e.apellidos} ${e.nombres}`)).join(''); }
const atiende = () => ctx && ['rector', 'coordinador', 'docente'].includes(ctx.rol);
const fechaHoraCorta = t => new Date(t).toLocaleString('es-CO', { weekday: 'short', day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' });
const aplicaAut = (a, eid) => a.destino === 'todos' || a.grupo_id === est(eid)?.grupo_id;
const autAbierta = a => !a.fecha_limite || a.fecha_limite >= hoy();

/* ---------- Novedades (campana) ---------- */
async function cargarNovedades() {
  const n = { msg: 0, aut: [], citasPend: 0, citasProx: [], fotosHoy: 0, horarioHoy: [], pedidos: 0, pedidosStaff: 0, pedCambios: [] };
  try {
    if (isFam()) {
      const e = propio(); if (!e) { S.nov = n; return; }
      const [m, au, ra, ci] = await Promise.all([
        q(db.from('mensajes').select('id').eq('estudiante_id', e).eq('de_familia', false).is('leido_en', null).limit(200)),
        q(db.from('autorizaciones').select('id,titulo,detalle,fecha_evento,fecha_limite,destino,grupo_id,autor_nombre,creado_en').eq('colegio_id', ctx.colegio_id).order('creado_en', { ascending: false }).limit(60)),
        q(db.from('respuestas_aut').select('autorizacion_id,autoriza').eq('estudiante_id', e)),
        q(db.from('citas').select('id,fecha,estado,modalidad,personal_id,motivo').eq('estudiante_id', e).in('estado', ['Solicitada', 'Confirmada']).order('creado_en')),
      ]);
      n.msg = isAcud() ? m.length : 0;   // el estudiante no usa mensajes ni citas (son de la familia)
      const resp = new Set(ra.map(r => r.autorizacion_id));
      if (isAcud()) n.aut = au.filter(a => aplicaAut(a, e) && autAbierta(a) && !resp.has(a.id));
      n.citasProx = isAcud() ? ci.filter(c => c.estado === 'Confirmada' && c.fecha && c.fecha.slice(0, 10) >= hoy()) : [];
      if (isAcud() && S.k?.tienda_activa) { n.pedCambios = await q(db.from('pedidos').select('id,numero,estado').eq('estudiante_id', e).eq('visto_familia', false).limit(20)).catch(() => []); n.pedidos = n.pedCambios.length; }
      const g = est(e)?.grupo_id;
      if (g) {
        const [fo, ho] = await Promise.all([
          q(db.from('fotos_clase').select('id').eq('grupo_id', g).eq('fecha', hoy()).limit(20)).catch(() => []),
          q(db.from('horario').select('*').eq('grupo_id', g).order('id')).catch(() => []),
        ]);
        n.fotosHoy = fo.length; n.horarioHoy = ho.filter(h => h.dia === isoDow(hoy())).sort((a, b) => a.bloque - b.bloque);
      }
    } else if (atiende()) {
      const [m, ci] = await Promise.all([
        q(db.from('mensajes').select('id').eq('personal_id', ctx.id).eq('de_familia', true).is('leido_en', null).limit(500)),
        q(db.from('citas').select('id,fecha,estado,estudiante_id,motivo,modalidad').eq('personal_id', ctx.id).in('estado', ['Solicitada', 'Confirmada']).order('creado_en')),
      ]);
      n.msg = m.length; n.citasPend = ci.filter(c => c.estado === 'Solicitada').length;
      n.citasProx = ci.filter(c => c.estado === 'Confirmada' && c.fecha && c.fecha.slice(0, 10) >= hoy());
    }
    if (manejaPagos()) n.pedidosStaff = (await q(db.from('pedidos').select('id').eq('colegio_id', ctx.colegio_id).in('estado', ['Por confirmar', 'Pagado']).limit(500)).catch(() => [])).length;
  } catch (e) { console.warn(e); }
  S.nov = n;
}
function totalNov() {
  if (isEst() && !alDia()) return 0;
  const n = S.nov || {}; let t = (n.msg || 0) + (n.aut?.length || 0) + (n.citasPend || 0) + (n.pedidos || 0) + (n.pedidosStaff || 0) + (n.citasProx || []).filter(c => c.fecha.slice(0, 10) <= sumarDias(hoy(), 1)).length;
  if (isFam()) t += noLeidos() + (S.camPend || 0);
  return t;
}
function verAvisos() {
  if (isEst() && !alDia()) return openModal('Avisos', '<p class="muted">No tiene avisos.</p>');
  const n = S.nov || {}, items = [];
  const it = (txt, vista, extra = '') => items.push(`<button type="button" class="perfil" onclick="closeModal();${extra}go('${vista}')"><strong>${txt}</strong></button>`);
  if (isFam() && noLeidos()) it(`${noLeidos()} ${noLeidos() === 1 ? 'comunicado sin leer' : 'comunicados sin leer'}`, 'comunicados');
  if (isFam() && S.camPend && verCampus() && alDia()) it(`${S.camPend} ${S.camPend === 1 ? 'actividad pendiente' : 'actividades pendientes'} en el campus virtual`, 'campus');
  if (n.msg) it(`${n.msg} ${n.msg === 1 ? 'mensaje nuevo' : 'mensajes nuevos'}`, 'mensajes');
  if (n.aut?.length) it(`${n.aut.length} ${n.aut.length === 1 ? 'autorización por responder' : 'autorizaciones por responder'}`, 'autorizaciones');
  if (n.citasPend) it(`${n.citasPend} ${n.citasPend === 1 ? 'solicitud de cita por responder' : 'solicitudes de cita por responder'}`, 'citas');
  (n.citasProx || []).filter(c => c.fecha.slice(0, 10) <= sumarDias(hoy(), 1)).forEach(c => it(`Cita ${c.fecha.slice(0, 10) === hoy() ? 'hoy' : 'mañana'}: ${fechaHoraCorta(c.fecha)}`, 'citas'));
  (n.pedCambios || []).forEach(p => it(`Su pedido No. ${p.numero}: ${p.estado.toLowerCase()}`, 'tienda'));
  if (n.pedidosStaff) it(`${n.pedidosStaff} ${n.pedidosStaff === 1 ? 'pedido de la tienda por atender' : 'pedidos de la tienda por atender'}`, 'pedidos', "sel.ttab='pedidos';sel.pfil='atender';");
  openModal('Avisos', items.length ? `<div class="perfiles">${items.join('')}</div>` : '<p class="muted">No tiene avisos pendientes. Aquí le aparecerán los mensajes nuevos, las autorizaciones por responder y las citas próximas.</p>');
}

/* ---------- "Hoy" para la familia (arriba del inicio) ---------- */
function hoyFamilia() {
  const e = est(propio()); if (!e) return '';
  const n = S.nov || {}, h = hoy(), aviso = [];
  const a = S.asis?.[`${h}|${e.id}`];
  if (a === 'A' && isAcud()) aviso.push(`<div class="note bloqueo"><strong>Hoy ${esc(e.nombres)} no asistió al colegio.</strong> Si faltó por un motivo justificado, envíe la excusa. <button class="btn sm" type="button" onclick="go('excusas')">Enviar excusa</button></div>`);
  else if (a === 'T') aviso.push(`<div class="note"><strong>Hoy ${esc(e.nombres)} llegó tarde al colegio.</strong></div>`);
  const eventos = (S.coms ? comsMios() : []).filter(c => c.fecha_evento && c.fecha_evento.slice(0, 10) >= h && c.fecha_evento.slice(0, 10) <= sumarDias(h, 7));
  const fil = [];
  if (noLeidos()) fil.push(`<li><button class="linkbtn" type="button" onclick="go('comunicados')">${noLeidos()} ${noLeidos() === 1 ? 'comunicado sin leer' : 'comunicados sin leer'}</button></li>`);
  if (n.msg) fil.push(`<li><button class="linkbtn" type="button" onclick="go('mensajes')">${n.msg} ${n.msg === 1 ? 'mensaje nuevo del colegio' : 'mensajes nuevos del colegio'}</button></li>`);
  if (n.aut?.length) fil.push(`<li><button class="linkbtn" type="button" onclick="go('autorizaciones')">${n.aut.length} ${n.aut.length === 1 ? 'autorización por responder' : 'autorizaciones por responder'}</button></li>`);
  (n.citasProx || []).forEach(c => fil.push(`<li><button class="linkbtn" type="button" onclick="go('citas')">Cita: ${fechaHoraCorta(c.fecha)} (${esc(c.modalidad)})</button></li>`));
  eventos.forEach(c => fil.push(`<li><button class="linkbtn" type="button" onclick="go('cronograma')">${esc(c.tipo)}: ${esc(c.titulo)} · ${fechaHoraCorta(c.fecha_evento)}</button></li>`));
  (n.pedCambios || []).forEach(p => fil.push(`<li><button class="linkbtn" type="button" onclick="go('tienda')">Su pedido No. ${p.numero} de la tienda: ${esc(p.estado.toLowerCase())}</button></li>`));
  if (n.fotosHoy) fil.push(`<li><button class="linkbtn" type="button" onclick="sel.gdia='${h}';go('galeria')">${n.fotosHoy} ${n.fotosHoy === 1 ? 'foto nueva' : 'fotos nuevas'} de la clase de hoy</button></li>`);
  const clases = (n.horarioHoy || []).map(x => `${x.hora ? esc(x.hora) + ' · ' : ''}${esc(nomAsig(x.asignatura_id) || '')}`).filter(t => t.trim());
  return `${aviso.join('')}<section class="panel hoy"><h2>Hoy, ${fechaLarga(h)}</h2>
    <div class="cols"><div><h3>Pendientes y novedades</h3>${fil.length ? `<ul class="list">${fil.join('')}</ul>` : '<p class="muted">No hay novedades por ahora.</p>'}</div>
    <div><h3>Clases de hoy</h3>${clases.length ? `<ul class="list">${clases.map(c => `<li>${c}</li>`).join('')}</ul>` : `<p class="muted">${isoDow(h) >= 6 ? 'Hoy no hay clases.' : 'El colegio aún no ha publicado el horario.'}</p>`}</div></div>
    ${isAcud() ? `<div class="toolbar" style="margin-top:10px"><button class="btn sm" type="button" onclick="go('mensajes')">Escribir al colegio</button><button class="btn ghost sm" type="button" onclick="go('citas')">Pedir una cita</button></div>` : ''}</section>`;
}

/* ---------- Mensajes privados ---------- */
let msjs = [], contactos2 = [];
async function prepMensajes() {
  if (isFam()) {
    const e = propio();
    [msjs, contactos2] = await Promise.all([
      all(() => db.from('mensajes').select('*').eq('estudiante_id', e).order('creado_en').order('id')),
      q(db.rpc('contactos_colegio', { p_estudiante: e })).catch(() => []),
    ]);
    if (!sel.hilo || !contactos2.some(c => c.id === sel.hilo)) sel.hilo = (msjs.length ? msjs[msjs.length - 1].personal_id : '') || '';
  } else {
    msjs = await all(() => db.from('mensajes').select('*').eq('personal_id', ctx.id).order('creado_en').order('id'));
    if (sel.hilo && !est(sel.hilo)) sel.hilo = '';
  }
  if (sel.hilo) await leerHilo();
}
async function leerHilo() {
  const [e, p] = isFam() ? [propio(), sel.hilo] : [sel.hilo, ctx.id];
  const sin = msjs.filter(m => m.estudiante_id === e && m.personal_id === p && !m.leido_en && m.de_familia === !isFam());
  if (!sin.length) return;
  await q(db.rpc('leer_mensajes', { p_estudiante: e, p_personal: p })).catch(() => {});
  sin.forEach(m => m.leido_en = new Date().toISOString());
  if (S.nov) S.nov.msg = Math.max(0, (S.nov.msg || 0) - sin.length);
}
function hilosPersonal() {
  const map = new Map();
  msjs.forEach(m => { const h = map.get(m.estudiante_id) || { eid: m.estudiante_id, ult: m, sin: 0 }; h.ult = m; if (m.de_familia && !m.leido_en) h.sin++; map.set(m.estudiante_id, h); });
  return [...map.values()].sort((a, b) => b.ult.creado_en.localeCompare(a.ult.creado_en));
}
const ROL_CONT = c => c.director ? 'Director(a) de grupo' : c.rol === 'docente' ? 'Docente' + (c.asignaturas ? ' de ' + c.asignaturas : '') : ROL_TXT[c.rol];
function vMensajes() {
  const fam = isFam();
  if (fam && !isAcud()) return head('Mensajes') + '<div class="panel empty">Los mensajes con el colegio los maneja el acudiente.</div>';
  if (!fam && !atiende()) return head('Mensajes') + '<div class="panel empty">Esta sección es para rectoría, coordinación y docentes.</div>';
  let lista, titulo = '', hilo = [];
  if (fam) {
    lista = contactos2.map(c => { const sin = msjs.filter(m => m.personal_id === c.id && !m.de_familia && !m.leido_en).length;
      return `<button type="button" class="hilo ${c.id === sel.hilo ? 'act' : ''}" onclick="abrirHilo('${c.id}')"><strong>${esc(c.nombre)}</strong>${sin ? ` <span class="badge">${sin}</span>` : ''}<span>${esc(ROL_CONT(c))}</span></button>`; }).join('');
    const c = contactos2.find(x => x.id === sel.hilo); if (c) { titulo = `${esc(c.nombre)} · ${esc(ROL_CONT(c))}`; hilo = msjs.filter(m => m.personal_id === c.id); }
  } else {
    const hs = hilosPersonal();
    lista = hs.map(h => { const e = est(h.eid); return `<button type="button" class="hilo ${h.eid === sel.hilo ? 'act' : ''}" onclick="abrirHilo('${h.eid}')"><strong>Familia de ${esc(e ? nom(e) : 'un estudiante')}</strong>${h.sin ? ` <span class="badge">${h.sin}</span>` : ''}<span>${esc(grupo(e?.grupo_id)?.nombre || '')} · ${fechaHoraCorta(h.ult.creado_en)}</span></button>`; }).join('');
    const e = est(sel.hilo); if (e) { titulo = `Familia de ${esc(nom(e))} · ${esc(grupo(e.grupo_id)?.nombre || '')}`; hilo = msjs.filter(m => m.estudiante_id === e.id); }
  }
  const sinLista = fam ? '<p class="muted">Aún no hay docentes asignados al curso.</p>' : '<p class="muted">Aún no tiene conversaciones. Use "Nuevo mensaje" para escribirle a una familia.</p>';
  setTimeout(() => { const b = $('#hiloMsjs'); if (b) b.scrollTop = b.scrollHeight; }, 0);
  return head('Mensajes', fam ? 'Escríbale directamente al director de grupo, a los docentes o a coordinación. Solo usted y esa persona ven la conversación.' : 'Conversaciones privadas con las familias. Solo usted y la familia ven cada conversación.',
    fam ? '' : '<button class="btn" type="button" onclick="nuevoMensaje()">Nuevo mensaje</button>') +
    `<div class="mensajes ${sel.hilo ? 'con-hilo' : ''}"><aside class="panel hilos">${lista || sinLista}</aside>
      <section class="panel conv">${titulo ? `<div class="conv-head"><button class="btn ghost sm volver-hilos" type="button" onclick="sel.hilo='';render()">← Conversaciones</button><h2>${titulo}</h2></div>
        <div class="burbujas" id="hiloMsjs">${hilo.length ? hilo.map(m => { const mio = fam ? m.de_familia : !m.de_familia; return `<div class="burbuja ${mio ? 'mia' : ''}"><p>${esc(m.texto)}</p><span>${esc(mio ? 'Usted' : m.autor_nombre || '')} · ${fechaHoraCorta(m.creado_en)}${mio && m.leido_en ? ' · Leído' : ''}</span></div>`; }).join('') : '<p class="muted">Aún no hay mensajes. Escriba el primero.</p>'}</div>
        <div class="enviar"><textarea id="msjTxt" maxlength="2000" placeholder="Escriba su mensaje…"></textarea><button class="btn" type="button" id="msjBtn" onclick="enviarMensaje()">Enviar</button></div>
        <p class="muted" style="font-size:.85rem;margin:6px 0 0">Para algo urgente, comuníquese con el colegio por teléfono.</p>`
      : '<p class="empty">Elija una conversación.</p>'}</section></div>`;
}
async function abrirHilo(id) { sel.hilo = id; await guard(leerHilo); render(); }
async function enviarMensaje() {
  const t = vv('msjTxt'); if (!t) return toast('Escriba el mensaje');
  const d = isFam() ? { estudiante_id: propio(), personal_id: sel.hilo, texto: t } : { estudiante_id: sel.hilo, personal_id: ctx.id, texto: t };
  await busy('#msjBtn', async () => {
    const r = await guard(() => q(db.from('mensajes').insert(d).select().single()));
    if (r) { msjs.push(r); render(); }
  });
}
function nuevoMensaje() {
  const gs = isDir() ? S.grupos : gruposVis(); if (!gs.length) return toast('No tiene cursos asignados');
  openModal('Nuevo mensaje a una familia', `<div class="formgrid"><label class="field"><span>Curso</span><select id="nmG" onchange="llenarEsts('nmE',this.value)">${gs.map(g => opt(g.id, g.nombre)).join('')}</select></label>
    <label class="field"><span>Estudiante</span><select id="nmE">${estsDe(gs[0].id).map(e => opt(e.id, `${e.apellidos} ${e.nombres}`)).join('')}</select></label></div>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" onclick="const e=document.getElementById('nmE').value;if(!e)return;closeModal();sel.hilo=e;render()">Abrir conversación</button></div>`);
}

/* ---------- Autorizaciones ---------- */
let auts = [], resps = [];
async function prepAutorizaciones() {
  auts = await all(() => db.from('autorizaciones').select('*').eq('colegio_id', ctx.colegio_id).order('creado_en', { ascending: false }).order('id'));
  if (isFam()) resps = await q(db.from('respuestas_aut').select('*').eq('estudiante_id', propio()));
  else {
    const ids = auts.map(a => a.id); resps = [];
    for (const part of chunks(ids, 60)) resps.push(...await all(() => db.from('respuestas_aut').select('*').in('autorizacion_id', part).order('autorizacion_id').order('estudiante_id')));
  }
}
function vAutorizaciones() {
  if (isFam()) {
    const e = propio(), l = auts.filter(a => aplicaAut(a, e));
    return head('Autorizaciones', `Permisos que el colegio le pide para ${esc(est(e)?.nombres || 'su hijo(a)')}: salidas pedagógicas, eventos, uso de imagen. Responda Sí o No.`) +
      (l.length ? `<div class="card-list">${l.map(a => { const r = resps.find(x => x.autorizacion_id === a.id), ab = autAbierta(a);
        return `<article class="item ${!r && ab ? 'unread' : ''}"><h3>${esc(a.titulo)}</h3><div class="meta">${esc(a.autor_nombre || '')} · ${fechaHora(a.creado_en)}${a.fecha_evento ? ` · Fecha: ${fechaLarga(a.fecha_evento)}` : ''}${a.fecha_limite ? ` · Responder hasta: ${fechaLarga(a.fecha_limite)}` : ''}</div>
          <p style="white-space:pre-wrap">${esc(a.detalle)}</p>
          ${r ? `<p><span class="tag ${r.autoriza ? '' : 't3'}">${r.autoriza ? 'Usted autorizó' : 'Usted no autorizó'}</span> <span class="muted">${fechaHora(r.respondido_en)}</span></p>` : ''}
          ${isAcud() && ab ? `<div class="toolbar" style="margin:6px 0 0"><button class="btn sm" type="button" onclick="responderAut('${a.id}', true)">${r ? 'Cambiar a: Sí autorizo' : 'Sí autorizo'}</button><button class="btn ghost sm" type="button" onclick="responderAut('${a.id}', false)">${r ? 'Cambiar a: No autorizo' : 'No autorizo'}</button></div>` : (!ab && !r ? '<p class="muted">El plazo para responder venció.</p>' : '')}</article>`; }).join('')}</div>`
      : '<div class="panel empty">No hay autorizaciones por ahora.</div>');
  }
  const puede = isDir() || isDoc();
  const vis = auts.filter(a => isDir() || isTes() || a.destino === 'todos' || gruposVis().some(g => g.id === a.grupo_id));
  return head('Autorizaciones', 'Pida a las familias autorización para salidas pedagógicas, eventos o uso de imagen, y vea quién respondió.', puede ? '<button class="btn" type="button" onclick="formAutorizacion()">Nueva autorización</button>' : '') +
    (vis.length ? `<div class="card-list">${vis.map(a => { const es = S.ests.filter(e => e.estado === 'Activo' && (a.destino === 'todos' || e.grupo_id === a.grupo_id)), rs = resps.filter(r => r.autorizacion_id === a.id);
      const si = rs.filter(r => r.autoriza).length, no = rs.filter(r => !r.autoriza).length;
      return `<article class="item"><div style="display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap"><h3>${esc(a.titulo)}</h3><span class="tag">${a.destino === 'todos' ? 'Todo el colegio' : esc(grupo(a.grupo_id)?.nombre || '')}</span></div>
        <div class="meta">${esc(a.autor_nombre || '')} · ${fechaHora(a.creado_en)}${a.fecha_evento ? ` · Fecha: ${fechaLarga(a.fecha_evento)}` : ''}${a.fecha_limite ? ` · Responder hasta: ${fechaLarga(a.fecha_limite)}` : ''}</div>
        <p><span class="ok">${si} autorizaron</span> · <span class="malo">${no} no autorizaron</span> · <span class="muted">${Math.max(0, es.length - si - no)} sin responder</span></p>
        <div class="toolbar" style="margin:6px 0 0"><button class="btn ghost sm" type="button" onclick="detalleAut('${a.id}')">Ver respuestas</button>${isDir() || a.creado_por === me.id ? `<button class="btn ghost sm" type="button" onclick="borrarAut('${a.id}')">Eliminar</button>` : ''}</div></article>`; }).join('')}</div>`
    : '<div class="panel empty">Aún no hay autorizaciones.</div>');
}
function formAutorizacion() {
  const gs = isDir() ? S.grupos : gruposVis();
  openModal('Nueva autorización', `<div class="formgrid">
    <label class="field"><span>Para</span><select id="auD" onchange="document.getElementById('auGB').hidden=this.value==='todos'">${isDir() ? opt('todos', 'Todo el colegio', 'todos') : ''}${opt('grupo', 'Un curso', isDir() ? '' : 'grupo')}</select></label>
    <label class="field" id="auGB" ${isDir() ? 'hidden' : ''}><span>Curso</span><select id="auG">${gs.map(g => opt(g.id, g.nombre)).join('')}</select></label>
    ${fIn('auT', 'Título', '', 'maxlength="150" placeholder="Ejemplo: Salida pedagógica al acuario"')}
    ${fIn('auF', 'Fecha de la actividad (opcional)', '', 'type="date"')}${fIn('auL', 'Responder hasta (opcional)', '', 'type="date"')}
    ${fTa('auX', 'Detalle', '', 'Lugar, horario, transporte, costo, qué deben llevar…')}</div>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" id="auBtn" onclick="guardarAut()">Enviar a las familias</button></div>`);
}
async function guardarAut() {
  const d = $('#auD').value, a = { colegio_id: ctx.colegio_id, destino: d, grupo_id: d === 'grupo' ? $('#auG').value : null, titulo: vv('auT'), detalle: vv('auX'), fecha_evento: vv('auF') || null, fecha_limite: vv('auL') || null };
  if (a.titulo.length < 3 || !a.detalle) return toast('Escriba el título y el detalle');
  if (a.fecha_limite && a.fecha_limite < hoy()) return toast('La fecha límite no puede ser anterior a hoy');
  const r = await busy('#auBtn', () => guard(() => q(db.from('autorizaciones').insert(a).select().single()), 'Autorización enviada'));
  if (r) { auts.unshift(r); closeModal(); render(); }
}
async function responderAut(id, si) {
  const r = await guard(() => q(db.from('respuestas_aut').upsert({ autorizacion_id: id, estudiante_id: propio(), autoriza: si }, { onConflict: 'autorizacion_id,estudiante_id' }).select().single()), si ? 'Gracias, quedó autorizado' : 'Gracias, quedó registrada su respuesta');
  if (r) { resps = resps.filter(x => x.autorizacion_id !== id).concat(r); if (S.nov) S.nov.aut = (S.nov.aut || []).filter(a => a.id !== id); render(); }
}
function detalleAut(id) {
  const a = auts.find(x => x.id === id), es = S.ests.filter(e => e.estado === 'Activo' && (a.destino === 'todos' || e.grupo_id === a.grupo_id)).sort((x, y) => (grupo(x.grupo_id)?.nombre || '').localeCompare(grupo(y.grupo_id)?.nombre || '') || nom(x).localeCompare(nom(y)));
  const rs = resps.filter(r => r.autorizacion_id === id);
  const fila = e => { const r = rs.find(x => x.estudiante_id === e.id); return `<tr><td>${esc(e.apellidos)} ${esc(e.nombres)}</td><td>${esc(grupo(e.grupo_id)?.nombre || '')}</td><td>${r ? (r.autoriza ? 'Sí autoriza' : 'No autoriza') : 'Sin responder'}</td><td>${r ? esc(r.nombre || '') + '<br>' + fechaHora(r.respondido_en) : ''}</td></tr>`; };
  lastDocs = `<section class="doc">${docHead('Autorización: ' + esc(a.titulo), a.fecha_evento ? fechaLarga(a.fecha_evento) : '')}<p style="white-space:pre-wrap">${esc(a.detalle)}</p><table><thead><tr><th>Estudiante</th><th>Curso</th><th>Respuesta</th><th>Quién respondió</th></tr></thead><tbody>${es.map(fila).join('')}</tbody></table></section>`;
  showDocs(lastDocs, 'Respuestas de la autorización', `Autorizacion ${a.titulo}`);
}
async function borrarAut(id) {
  if (!await confirmar('¿Eliminar esta autorización y sus respuestas?')) return;
  const ok = await guard(async () => { await q(db.from('autorizaciones').delete().eq('id', id)); return true; }, 'Autorización eliminada');
  if (ok) { auts = auts.filter(a => a.id !== id); render(); }
}

/* ---------- Citas ---------- */
let citas = [];
const ESTADO_CITA = { Solicitada: 't2', Confirmada: '', Cancelada: 't3', Realizada: '' };
async function prepCitas() {
  if (isFam()) {
    [citas, contactos2] = await Promise.all([
      all(() => db.from('citas').select('*').eq('estudiante_id', propio()).order('creado_en', { ascending: false }).order('id')),
      q(db.rpc('contactos_colegio', { p_estudiante: propio() })).catch(() => []),
    ]);
  } else {
    if (isDir()) await cargarMiembros().catch(() => {});
    const base = () => db.from('citas').select('*').order('creado_en', { ascending: false }).order('id');
    citas = await all(() => sel.citTodas && isDir() ? base().eq('colegio_id', ctx.colegio_id) : base().eq('personal_id', ctx.id));
  }
}
const nomPersonal = id => (contactos2.find(c => c.id === id) || (S.miembros || []).find(m => m.id === id))?.nombre || (id === ctx.id ? ctx.nombre : '');
function vCitas() {
  const fam = isFam();
  if (fam && !isAcud()) return head('Citas') + '<div class="panel empty">Las citas con el colegio las maneja el acudiente.</div>';
  const act = citas.filter(c => ['Solicitada', 'Confirmada'].includes(c.estado)), pas = citas.filter(c => !['Solicitada', 'Confirmada'].includes(c.estado));
  const card = c => { const e = est(c.estudiante_id), mia = !fam && c.personal_id === ctx.id;
    return `<article class="item ${c.estado === 'Solicitada' && mia ? 'unread' : ''}"><div style="display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap"><h3>${fam ? esc(nomPersonal(c.personal_id) || 'Colegio') : 'Familia de ' + esc(e ? nom(e) : '')}</h3><span class="tag ${ESTADO_CITA[c.estado]}">${c.estado}</span></div>
      <div class="meta">${c.fecha ? fechaHoraCorta(c.fecha) + ' · ' : ''}${esc(c.modalidad)}${!fam ? ` · ${esc(grupo(e?.grupo_id)?.nombre || '')}` : ''}${!fam && !mia ? ` · Con ${esc(nomPersonal(c.personal_id))}` : ''} · ${c.pedida_por === 'familia' ? 'Pedida por la familia' : 'Programada por el colegio'}</div>
      <p><strong>Motivo:</strong> ${esc(c.motivo)}</p>${c.fecha_propuesta && c.estado === 'Solicitada' ? `<p class="muted">Fecha propuesta por la familia: ${fechaHoraCorta(c.fecha_propuesta)}</p>` : c.preferencia ? `<p class="muted">Horario que prefiere la familia: ${esc(c.preferencia)}</p>` : ''}${c.respuesta ? `<p><strong>Nota del colegio:</strong> ${esc(c.respuesta)}</p>` : ''}
      ${['Solicitada', 'Confirmada'].includes(c.estado) ? `<div class="toolbar" style="margin:6px 0 0">${mia ? `<button class="btn sm" type="button" onclick="formConfirmarCita('${c.id}')">${c.estado === 'Solicitada' ? 'Confirmar fecha' : 'Cambiar fecha'}</button>${c.estado === 'Confirmada' && c.fecha && c.fecha.slice(0, 10) <= hoy() ? `<button class="btn ghost sm" type="button" onclick="estadoCita('${c.id}','Realizada')">Marcar realizada</button>` : ''}` : ''}${mia || (fam && isAcud()) ? `<button class="btn ghost sm" type="button" onclick="estadoCita('${c.id}','Cancelada')">Cancelar cita</button>` : ''}</div>` : ''}</article>`; };
  return head('Citas', fam ? 'Pida una cita con el director de grupo, un docente o coordinación. El colegio le confirma la fecha y la hora.' : 'Solicitudes de cita de las familias y citas que usted programa.',
    fam ? '<button class="btn" type="button" onclick="formCita()">Pedir una cita</button>' : (atiende() ? '<button class="btn" type="button" onclick="formCita()">Programar una cita</button>' : '')) +
    (!fam && isDir() ? `<div class="panel"><label class="chk"><input type="checkbox" ${sel.citTodas ? 'checked' : ''} onchange="sel.citTodas=this.checked;go('citas')"> Ver las citas de todo el colegio</label></div>` : '') +
    `<h2>Próximas y pendientes</h2>${act.length ? `<div class="card-list">${act.map(card).join('')}</div>` : '<div class="panel empty">No hay citas pendientes.</div>'}
    ${pas.length ? `<h2 style="margin-top:18px">Anteriores</h2><div class="card-list">${pas.slice(0, 30).map(card).join('')}</div>` : ''}`;
}
// Horario de atención a padres (Parametrización → Institución)
const DSEM = ['', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'];
const atn = () => S.k.atencion || { dias: [1, 2, 3, 4, 5], desde: '07:00', hasta: '12:00' };
const atnTxt = () => { const a = atn(), d = a.dias.slice().sort(); const seg = d.length && d.every((x, i) => !i || x === d[i - 1] + 1) && d.length > 2 ? `${DSEM[d[0]]} a ${DSEM[d[d.length - 1]]}` : d.map(x => DSEM[x]).join(', '); return `${seg}, de ${a.desde} a ${a.hasta}`; };
function franjasAtn() { const a = atn(), out = []; let [h, m] = a.desde.split(':').map(Number); const [hh, mm] = a.hasta.split(':').map(Number); while (h * 60 + m < hh * 60 + mm) { out.push(`${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`); m += 30; if (m >= 60) { h++; m -= 60; } } return out; }
const hora12 = t => { const [h, m] = t.split(':').map(Number); return `${((h + 11) % 12) + 1}:${String(m).padStart(2, '0')} ${h < 12 ? 'a. m.' : 'p. m.'}`; };
function revisarDiaCita(el) { const ok = !el.value || atn().dias.includes(isoDow(el.value)); $('#ciAviso').textContent = ok ? '' : `Ese día el colegio no atiende a padres. Horario de atención: ${atnTxt()}.`; }
function formCita() {
  const fam = isFam(), gs = isDir() ? S.grupos : gruposVis();
  if (fam && !contactos2.length) return toast('Aún no hay docentes asignados al curso');
  if (!fam && !gs.length) return toast('No tiene cursos asignados');
  openModal(fam ? 'Pedir una cita' : 'Programar una cita con una familia', `<div class="formgrid">
    ${fam ? `<label class="field"><span>Con quién</span><select id="ciP">${contactos2.map(c => opt(c.id, `${c.nombre} · ${ROL_CONT(c)}`)).join('')}</select></label>`
      : `<label class="field"><span>Curso</span><select id="ciG" onchange="llenarEsts('ciE',this.value)">${gs.map(g => opt(g.id, g.nombre)).join('')}</select></label>
         <label class="field"><span>Estudiante</span><select id="ciE">${estsDe(gs[0].id).map(e => opt(e.id, `${e.apellidos} ${e.nombres}`)).join('')}</select></label>
         <label class="field"><span>Fecha y hora</span><input id="ciF" type="datetime-local"></label>`}
    <label class="field"><span>Modalidad</span><select id="ciM">${['Presencial', 'Virtual', 'Llamada'].map(m => opt(m, m, 'Presencial')).join('')}</select></label>
    ${fTa('ciX', 'Motivo', '', fam ? 'Cuéntele al colegio de qué quiere hablar' : 'Motivo de la cita')}
    ${fam ? `<div class="field full"><span>¿Cuándo le queda bien? El colegio atiende a padres los ${atnTxt()}.</span></div>
       <label class="field"><span>Día</span><input id="ciD" type="date" min="${sumarDias(hoy(), 1)}" max="${sumarDias(hoy(), 60)}" onchange="revisarDiaCita(this)"></label>
       <label class="field"><span>Hora</span><select id="ciH">${franjasAtn().map(t => opt(t, hora12(t))).join('')}</select></label>
       <p class="err full" id="ciAviso"></p>` : fIn('ciR', 'Indicaciones para la familia (opcional)', '', 'maxlength="500" placeholder="Ejemplo: sala de profesores, traer el cuaderno"')}</div>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" id="ciBtn" onclick="guardarCita()">${fam ? 'Enviar solicitud' : 'Programar y avisar'}</button></div>`);
}
async function guardarCita() {
  const fam = isFam(), d = { motivo: vv('ciX'), modalidad: $('#ciM').value };
  if (d.motivo.length < 3) return toast('Escriba el motivo');
  if (fam) {
    const dia = $('#ciD').value; if (!dia) return toast('Elija el día de la cita');
    if (!atn().dias.includes(isoDow(dia))) return toast(`Ese día no hay atención a padres. Horario: ${atnTxt()}`);
    Object.assign(d, { estudiante_id: propio(), personal_id: $('#ciP').value, fecha_propuesta: new Date(`${dia}T${$('#ciH').value}:00-05:00`).toISOString() });
  }
  else {
    const f = $('#ciF').value; if (!f) return toast('Escriba la fecha y hora');
    if (new Date(f) < new Date()) return toast('La fecha ya pasó');
    Object.assign(d, { estudiante_id: $('#ciE').value, personal_id: ctx.id, fecha: new Date(f).toISOString(), respuesta: vv('ciR') || null });
  }
  const r = await busy('#ciBtn', () => guard(() => q(db.from('citas').insert(d).select().single()), fam ? 'Solicitud enviada. El colegio le confirmará la fecha.' : 'Cita programada. La familia la verá en su cuenta.'));
  if (r) { citas.unshift(r); closeModal(); render(); }
}
function formConfirmarCita(id) {
  const c = citas.find(x => x.id === id), e = est(c.estudiante_id);
  const fx = c.fecha || c.fecha_propuesta, loc = fx ? new Date(new Date(fx).getTime() - new Date().getTimezoneOffset() * 6e4).toISOString().slice(0, 16) : '';
  openModal(`Cita con la familia de ${e ? nom(e) : ''}`, `<p><strong>Motivo:</strong> ${esc(c.motivo)}</p>${c.fecha_propuesta ? `<p class="muted">La familia propuso: <strong>${fechaHoraCorta(c.fecha_propuesta)}</strong>. Puede confirmarla o cambiarla.</p>` : c.preferencia ? `<p class="muted">Prefiere: ${esc(c.preferencia)}</p>` : ''}
    <div class="formgrid"><label class="field"><span>Fecha y hora</span><input id="ccF" type="datetime-local" value="${loc}"></label>
    <label class="field"><span>Modalidad</span><select id="ccM">${['Presencial', 'Virtual', 'Llamada'].map(m => opt(m, m, c.modalidad)).join('')}</select></label>
    ${fIn('ccR', 'Indicaciones para la familia (opcional)', c.respuesta || '', 'maxlength="500"')}</div>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" id="ccBtn" onclick="confirmarCita('${id}')">Confirmar cita</button></div>`);
}
async function confirmarCita(id) {
  const f = $('#ccF').value; if (!f) return toast('Escriba la fecha y hora');
  if (new Date(f) < new Date()) return toast('La fecha ya pasó');
  const r = await busy('#ccBtn', () => guard(() => q(db.from('citas').update({ estado: 'Confirmada', fecha: new Date(f).toISOString(), modalidad: $('#ccM').value, respuesta: vv('ccR') || null }).eq('id', id).select().single()), 'Cita confirmada. La familia la verá en su cuenta.'));
  if (r) { citas = citas.map(c => c.id === id ? r : c); closeModal(); await cargarNovedades(); render(); }
}
async function estadoCita(id, estado) {
  if (estado === 'Cancelada' && !await confirmar('¿Cancelar esta cita?')) return;
  const r = await guard(() => q(db.from('citas').update({ estado }).eq('id', id).select().single()), estado === 'Cancelada' ? 'Cita cancelada' : 'Cita marcada como realizada');
  if (r) { citas = citas.map(c => c.id === id ? r : c); await cargarNovedades(); render(); }
}

/* =====================================================================
   Horario de clases
   ===================================================================== */
const nomAsig = id => S.asigs.find(a => a.id === id)?.nombre || '';
const DIAS = ['', 'Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado'];
let horario = [];
async function prepHorario() {
  if (isDir()) await cargarMiembros().catch(() => {});
  if (isFam()) { const e = est(propio()); sel.hg = e?.grupo_id || ''; }
  else { const gs = gruposVis(); if (!sel.hg || !(gs.find(g => g.id === sel.hg) || sel.hg === 'mio')) sel.hg = isDoc() ? 'mio' : gs[0]?.id || ''; }
  horario = !sel.hg ? [] : sel.hg === 'mio' ? await all(() => db.from('horario').select('*').eq('colegio_id', ctx.colegio_id).order('id')) : await all(() => db.from('horario').select('*').eq('grupo_id', sel.hg).order('id'));
}
function gridHorario(l, celda) {
  const sab = l.some(x => x.dia === 6), nb = Math.max(0, ...l.map(x => x.bloque));
  if (!nb) return '<div class="empty">Aún no hay horario registrado.</div>';
  const dias = [1, 2, 3, 4, 5].concat(sab ? [6] : []);
  return `<div class="tbl"><table class="planilla"><thead><tr><th>Hora</th>${dias.map(d => `<th>${DIAS[d]}</th>`).join('')}</tr></thead><tbody>
    ${Array.from({ length: nb }, (_, i) => i + 1).map(b => { const fila = l.filter(x => x.bloque === b); return `<tr><td><strong>${b}</strong>${fila.find(x => x.hora)?.hora ? `<br><span class="muted">${esc(fila.find(x => x.hora).hora)}</span>` : ''}</td>${dias.map(d => `<td>${fila.filter(x => x.dia === d).map(celda).join('<br>') || ''}</td>`).join('')}</tr>`; }).join('')}
  </tbody></table></div>`;
}
function vHorario() {
  const gs = isFam() ? [] : gruposVis();
  if (!isFam() && !gs.length) return head('Horario') + sinGrupos();
  if (sel.hEdit && isDir()) return editorHorario();
  const mio = sel.hg === 'mio', mn = (ctx.nombre || '').toLowerCase().trim();
  const l = mio ? horario.filter(x => (x.docente || '').toLowerCase().trim() === mn) : horario;
  const celda = x => `<strong>${esc(nomAsig(x.asignatura_id) || '—')}</strong>${mio ? `<br><span class="muted">${esc(grupo(x.grupo_id)?.nombre || '')}</span>` : x.docente ? `<br><span class="muted">${esc(x.docente)}</span>` : ''}`;
  return head('Horario de clases', isFam() ? esc(grupo(sel.hg)?.nombre || '') : 'Horario semanal por curso.', isDir() && sel.hg ? '<button class="btn" type="button" onclick="sel.hEdit=true;render()">Editar horario</button>' : '') +
    (isFam() ? '' : `<div class="panel"><div class="toolbar"><label class="field"><span>Ver</span><select onchange="sel.hg=this.value;go('horario')">${isDoc() ? opt('mio', 'Mi horario', sel.hg) : ''}${gs.map(g => opt(g.id, g.nombre, sel.hg)).join('')}</select></label></div></div>`) +
    `<div class="panel">${gridHorario(l, celda)}${mio && !l.length && horario.length ? '<p class="muted">Su nombre no aparece en el horario de ningún curso. Pida a coordinación que lo asigne.</p>' : ''}</div>`;
}
function editorHorario() {
  const g = grupo(sel.hg), as = asigsDe(g), docs = (S.miembros || []).filter(m => m.rol === 'docente' && m.activo).map(m => m.nombre);
  const nb = sel.hNb || Math.max(6, ...horario.map(x => x.bloque)), sab = sel.hSab ?? horario.some(x => x.dia === 6);
  const dias = [1, 2, 3, 4, 5].concat(sab ? [6] : []);
  const c = (d, b) => horario.find(x => x.dia === d && x.bloque === b) || {};
  return head(`Editar horario: ${esc(g.nombre)}`, 'Elija la asignatura y el docente de cada hora. Deje en blanco los descansos o las horas libres.') +
    `<div class="panel"><div class="toolbar"><label class="field"><span>Horas de clase por día</span><select onchange="sel.hNb=+this.value;render()">${[4, 5, 6, 7, 8, 9, 10, 11, 12].map(n => opt(n, n, nb)).join('')}</select></label>
      <label class="chk"><input type="checkbox" ${sab ? 'checked' : ''} onchange="sel.hSab=this.checked;render()"> Incluir sábado</label></div>
    <div class="tbl"><table class="planilla"><thead><tr><th>Hora</th>${dias.map(d => `<th>${DIAS[d]}</th>`).join('')}</tr></thead><tbody>
    ${Array.from({ length: nb }, (_, i) => i + 1).map(b => `<tr><td><strong>${b}</strong><br><input class="hHora" data-b="${b}" style="width:110px" placeholder="7:00 a 7:50" value="${esc(horario.find(x => x.bloque === b && x.hora)?.hora || '')}"></td>
      ${dias.map(d => { const x = c(d, b); return `<td><select class="hAs" data-d="${d}" data-b="${b}"><option value="">—</option>${as.map(a => opt(a.id, a.nombre, x.asignatura_id || '')).join('')}</select><br>
        <select class="hDoc" data-d="${d}" data-b="${b}"><option value="">Docente…</option>${[...new Set(docs.concat(x.docente ? [x.docente] : []))].map(n => opt(n, n, x.docente || '')).join('')}</select></td>`; }).join('')}</tr>`).join('')}
    </tbody></table></div>
    <div class="toolbar" style="margin-top:12px"><button class="btn ghost" type="button" onclick="sel.hEdit=false;render()">Cancelar</button><button class="btn" type="button" onclick="guardarHorario()">Guardar horario</button></div></div>`;
}
async function guardarHorario() {
  const horas = {}; document.querySelectorAll('.hHora').forEach(i => horas[i.dataset.b] = i.value.trim());
  const filas = [...document.querySelectorAll('.hAs')].map(s => { const doc = document.querySelector(`.hDoc[data-d="${s.dataset.d}"][data-b="${s.dataset.b}"]`).value;
    return { colegio_id: ctx.colegio_id, grupo_id: sel.hg, dia: +s.dataset.d, bloque: +s.dataset.b, hora: horas[s.dataset.b] || null, asignatura_id: s.value || null, docente: doc || null }; })
    .filter(x => x.asignatura_id || x.docente);
  const ok = await guard(async () => { await q(db.from('horario').delete().eq('grupo_id', sel.hg)); if (filas.length) await q(db.from('horario').insert(filas)); return true; }, 'Horario guardado');
  if (ok) { sel.hEdit = false; sel.hNb = 0; sel.hSab = undefined; await go('horario'); }
}

/* =====================================================================
   Excusas de inasistencia
   ===================================================================== */
let excusas = [];
const COLS_EXC = 'id,estudiante_id,desde,hasta,motivo,estado,respuesta,enviada_por,revisada_por,creado_en';
async function prepExcusas() {
  if (isFam()) { excusas = await all(() => db.from('excusas').select(COLS_EXC).eq('estudiante_id', propio()).order('creado_en', { ascending: false })); return; }
  excusas = await all(() => db.from('excusas').select(COLS_EXC).eq('colegio_id', ctx.colegio_id).order('creado_en', { ascending: false }));
}
const tagExc = s => `<span class="tag ${s === 'Aprobada' ? '' : s === 'Rechazada' ? 't3' : 't2'}">${s}</span>`;
function filaExc(x, staff) {
  const e = est(x.estudiante_id);
  return `<article class="item ${x.estado === 'Pendiente' && staff ? 'unread' : ''}"><div style="display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap"><h3>${staff ? esc(e ? `${nom(e)} · ${grupo(e.grupo_id)?.nombre || ''}` : '') : (x.desde === x.hasta ? fechaLarga(x.desde) : `Del ${fmtF(x.desde)} al ${fmtF(x.hasta)}`)}</h3>${tagExc(x.estado)}</div>
    <div class="meta">${staff ? (x.desde === x.hasta ? fechaLarga(x.desde) : `Del ${fmtF(x.desde)} al ${fmtF(x.hasta)}`) + ' · ' : ''}Enviada por ${esc(x.enviada_por || 'el colegio')} el ${fechaHora(x.creado_en)}</div>
    <p style="white-space:pre-wrap">${esc(x.motivo)}</p>
    ${x.respuesta ? `<p class="muted">Respuesta: ${esc(x.respuesta)}</p>` : ''}${x.revisada_por ? `<p class="muted">Revisó: ${esc(x.revisada_por)}</p>` : ''}
    <div class="toolbar" style="margin:6px 0 0"><button class="btn ghost sm" type="button" onclick="verSoporte('${x.id}')">Ver soporte</button>
    ${staff && x.estado === 'Pendiente' ? `<button class="btn sm" type="button" onclick="revisarExcusa('${x.id}','Aprobada')">Aprobar</button><button class="btn ghost sm" type="button" onclick="revisarExcusa('${x.id}','Rechazada')">Rechazar</button>` : ''}</div></article>`;
}
function vExcusas() {
  if (isFam()) {
    const e = est(propio());
    return head('Excusas', `Envíe la excusa cuando ${esc(e?.nombres || 'el estudiante')} falte a clase. Puede adjuntar una foto de la incapacidad o del soporte.`) +
      `<div class="panel"><h2>Nueva excusa</h2><div class="formgrid">${fIn('xDes', 'Desde', hoy(), 'type="date"')}${fIn('xHas', 'Hasta', hoy(), 'type="date"')}
        ${fTa('xMot', 'Motivo', '', 'Ejemplo: cita médica, incapacidad, calamidad familiar…')}
        <label class="field full"><span>Soporte (opcional): foto de la incapacidad o constancia</span><input type="file" id="xSop" accept="image/*"></label></div>
        <div class="toolbar" style="margin-top:12px"><button class="btn" type="button" id="xBtn" onclick="enviarExcusa()">Enviar excusa</button></div></div>` +
      (excusas.length ? `<h2>Excusas enviadas</h2><div class="card-list">${excusas.map(x => filaExc(x)).join('')}</div>` : '');
  }
  const vis = excusas.filter(x => isDir() || gruposVis().some(g => g.id === est(x.estudiante_id)?.grupo_id));
  const pen = vis.filter(x => x.estado === 'Pendiente'), rev = vis.filter(x => x.estado !== 'Pendiente').slice(0, 30);
  return head('Excusas', 'Excusas enviadas por las familias desde su cuenta, o registradas aquí cuando las traen en papel. Al aprobar una excusa, las fallas de esas fechas quedan justificadas.', '<button class="btn" type="button" onclick="formExcusaStaff()">Registrar excusa</button>') +
    (pen.length ? `<h2>Por revisar (${pen.length})</h2><div class="card-list">${pen.map(x => filaExc(x, true)).join('')}</div>` : '<div class="panel empty">No hay excusas por revisar.</div>') +
    (rev.length ? `<h2 style="margin-top:20px">Revisadas</h2><div class="card-list">${rev.map(x => filaExc(x, true)).join('')}</div>` : '');
}
async function enviarExcusa() {
  const d = { estudiante_id: propio(), colegio_id: ctx.colegio_id, desde: vv('xDes'), hasta: vv('xHas'), motivo: vv('xMot') };
  if (!d.desde || !d.hasta || !d.motivo) return toast('Complete las fechas y el motivo');
  if (d.hasta < d.desde) return toast('La fecha final no puede ser anterior a la inicial');
  await busy('#xBtn', async () => {
    const r = await guard(async () => { d.soporte = await leerImagen($('#xSop').files[0]); return q(db.from('excusas').insert(d).select(COLS_EXC).single()); }, 'Excusa enviada al colegio');
    if (r) { excusas.unshift(r); render(); }
  });
}
async function verSoporte(id) {
  const r = await guard(() => q(db.from('excusas').select('soporte').eq('id', id).single()));
  if (r === undefined) return;
  if (!r?.soporte) { const x = excusas.find(y => y.id === id); return toast(x?.estado === 'Aprobada' ? 'La foto del soporte se borró al aprobar la excusa, para ahorrar espacio' : x?.estado === 'Rechazada' ? 'Esta excusa no tiene foto (las fotos de excusas rechazadas se borran a los 30 días)' : 'Esta excusa no tiene soporte adjunto'); }
  openModal('Soporte de la excusa', `<img src="${r.soporte}" alt="Soporte" style="max-width:100%">`);
}
function formExcusaStaff() {
  const gs = gruposVis(); if (!gs.length) return toast('No tiene grupos asignados');
  const g0 = sel.g && gs.find(g => g.id === sel.g) ? sel.g : gs[0].id;
  openModal('Registrar excusa', `<div class="formgrid">
    <label class="field"><span>Curso</span><select id="xG" onchange="document.getElementById('xE').innerHTML=this.selectedOptions[0].dataset.e">${gs.map(g => `<option value="${g.id}" ${g.id === g0 ? 'selected' : ''} data-e="${esc(estsDe(g.id).map(e => opt(e.id, `${e.apellidos} ${e.nombres}`)).join(''))}">${esc(g.nombre)}</option>`).join('')}</select></label>
    <label class="field"><span>Estudiante</span><select id="xE">${estsDe(g0).map(e => opt(e.id, `${e.apellidos} ${e.nombres}`)).join('')}</select></label>
    ${fIn('xDes', 'Desde', hoy(), 'type="date"')}${fIn('xHas', 'Hasta', hoy(), 'type="date"')}
    ${fTa('xMot', 'Motivo', '', 'Ejemplo: incapacidad médica presentada por el acudiente')}
    <label class="field full"><span>Foto del soporte (opcional; se borra cuando la excusa se aprueba)</span><input type="file" id="xSop" accept="image/*"></label>
    <label class="chk full"><input type="checkbox" id="xApr" checked> Aprobar de una vez y justificar las fallas</label></div>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" id="xBtn2" onclick="guardarExcusaStaff()">Guardar</button></div>`);
}
async function guardarExcusaStaff() {
  const d = { estudiante_id: $('#xE').value, colegio_id: ctx.colegio_id, desde: vv('xDes'), hasta: vv('xHas'), motivo: vv('xMot') };
  if (!d.estudiante_id || !d.desde || !d.hasta || !d.motivo) return toast('Complete el estudiante, las fechas y el motivo');
  if (d.hasta < d.desde) return toast('La fecha final no puede ser anterior a la inicial');
  const aprobar = $('#xApr').checked;
  await busy('#xBtn2', async () => {
    const r = await guard(async () => { d.soporte = await leerImagen($('#xSop').files[0]); return q(db.from('excusas').insert(d).select(COLS_EXC).single()); }, 'Excusa registrada');
    if (!r) return;
    excusas.unshift(r); closeModal();
    if (aprobar) await revisarExcusa(r.id, 'Aprobada'); else render();
  });
}
function diasHabiles(a, b) { const l = []; const d = new Date(a + 'T12:00:00'), f = new Date(b + 'T12:00:00'); while (d <= f && l.length < 62) { const w = d.getDay(); if (w >= 1 && w <= 5) l.push(d.toISOString().slice(0, 10)); d.setDate(d.getDate() + 1); } return l; }
async function revisarExcusa(id, estado) {
  const x = excusas.find(y => y.id === id);
  const respuesta = estado === 'Rechazada' ? await pedirTexto('Motivo del rechazo (la familia lo verá):') : '';
  if (estado === 'Rechazada' && !respuesta) return;
  const r = await guard(async () => {
    const u = await q(db.from('excusas').update({ estado, respuesta: respuesta || null }).eq('id', id).select(COLS_EXC).single());
    if (estado === 'Aprobada') {
      const dias = diasHabiles(x.desde, x.hasta);
      if (porClase()) await q(db.from('asistencia_clase').update({ estado: 'E' }).eq('estudiante_id', x.estudiante_id).gte('fecha', x.desde).lte('fecha', x.hasta).eq('estado', 'A'));
      else if (dias.length) await q(db.from('asistencia').upsert(dias.map(f => ({ colegio_id: ctx.colegio_id, estudiante_id: x.estudiante_id, fecha: f, estado: 'E' })), { onConflict: 'estudiante_id,fecha' }));
      const g = est(x.estudiante_id)?.grupo_id; if (g) S.loadedG.delete(g);
    }
    return u;
  }, estado === 'Aprobada' ? 'Excusa aprobada; la asistencia quedó justificada y la foto del soporte se borró' : 'Excusa rechazada');
  if (r) { Object.assign(x, r); render(); }
}

/* =====================================================================
   Comprobantes de pago y paz y salvo
   ===================================================================== */
let comps = [];
const tagComp = s => `<span class="tag ${s === 'Confirmado' ? '' : s === 'Rechazado' ? 't3' : 't2'}">${s}</span>`;
function panelComprobantes() {
  if (!comps.length) return '';
  return `<div class="panel"><h2>Comprobantes enviados por las familias <span class="badge">${comps.length}</span></h2>
    <div class="tbl"><table><thead><tr><th>Estudiante</th><th>Fecha</th><th>Valor</th><th>Medio</th><th>Enviado por</th><th></th></tr></thead><tbody>
    ${comps.map(c => { const e = est(c.estudiante_id); return `<tr><td><strong>${esc(e ? nom(e) : '')}</strong><br><span class="muted">${esc(grupo(e?.grupo_id)?.nombre || '')}</span></td><td>${fmtF(c.fecha)}</td><td>${cop(c.valor)}</td>
      <td>${esc(c.medio || '')}${c.referencia ? `<br><span class="muted">${esc(c.referencia)}</span>` : ''}${c.nota ? `<br><span class="muted">${esc(c.nota)}</span>` : ''}</td><td>${esc(c.enviado_por || '')}</td>
      <td style="white-space:nowrap"><button class="btn ghost sm" type="button" onclick="verComprobante('${c.id}')">Ver</button> <button class="btn sm" type="button" onclick="confirmarComp('${c.id}')">Confirmar y registrar</button> <button class="btn ghost sm" type="button" onclick="rechazarComp('${c.id}')">Rechazar</button></td></tr>`; }).join('')}
    </tbody></table></div></div>`;
}
async function verComprobante(id) {
  const r = await guard(() => q(db.from('comprobantes').select('imagen').eq('id', id).single()));
  if (r === undefined) return;
  if (!r?.imagen) return toast('El comprobante no tiene imagen adjunta');
  openModal('Comprobante de pago', `<img src="${r.imagen}" alt="Comprobante" style="max-width:100%">`);
}
async function confirmarComp(id) {
  const c = comps.find(x => x.id === id);
  const ok = await guard(async () => { await q(db.from('comprobantes').update({ estado: 'Confirmado' }).eq('id', id)); return true; });
  if (!ok) return;
  comps = comps.filter(x => x.id !== id);
  await abrirCuenta(c.estudiante_id);
  const set = (s, v) => { const el = $(s); if (el && v) el.value = v; };
  set('#pFec', c.fecha); set('#pRef', c.referencia || 'Comprobante enviado por la familia'); set('#pVal', String(c.valor)); previewPago();
  if ([...($('#pMed')?.options || [])].some(o => o.value === c.medio)) set('#pMed', c.medio);
  toast(`Comprobante de ${cop(c.valor)} confirmado (la foto se borró). Revise y pulse Registrar pago`);
}
async function rechazarComp(id) {
  const m = await pedirTexto('Motivo del rechazo (la familia lo verá):'); if (!m) return;
  const ok = await guard(async () => { await q(db.from('comprobantes').update({ estado: 'Rechazado', respuesta: m }).eq('id', id)); return true; }, 'Comprobante rechazado');
  if (ok) { comps = comps.filter(x => x.id !== id); render(); }
}
const MEDIOS = ['Transferencia', 'Consignación', 'Nequi', 'Daviplata', 'PSE', 'Efectivo', 'Otro'];
// Medios con los que la familia puede enviar comprobante: solo los que el colegio recibe
const mediosComprobante = () => [S.k.pago_llave && S.k.pago_llave_valor ? 'Llave Bre-B' : null, S.k.pago_bold && S.k.pago_bold_url ? 'Bold (en línea)' : null].filter(Boolean);
function panelPagarFam(venc) {
  if (!isAcud()) return '';
  const k = S.k, llave = k.pago_llave && k.pago_llave_valor;
  return `<div class="panel"><h2>Cómo pagar</h2>${venc > 0 ? `<p>Valor pendiente por pagar a hoy: <strong>${cop(venc)}</strong>.</p>` : ''}
    <div class="medios">
      ${k.pago_bold && k.pago_bold_url ? `<div class="medio"><h3>En línea con Bold</h3><p class="muted">Tarjeta, PSE o Nequi.</p><a class="btn" href="${esc(k.pago_bold_url)}" target="_blank" rel="noopener">Pagar en línea</a></div>` : ''}
      ${llave ? `<div class="medio"><h3>Con llave Bre-B</h3><p>Llave Bre-B: <strong class="code">${esc(k.pago_llave_valor)}</strong> <button class="btn ghost sm" type="button" onclick="copiarTexto('${esc(k.pago_llave_valor)}')">Copiar</button>${k.pago_llave_titular ? `<br><span class="muted">A nombre de ${esc(k.pago_llave_titular)}</span>` : ''}</p><p class="muted">Después de pagar, oprima "Ya pagué" abajo y adjunte el comprobante.</p></div>` : ''}
      ${k.pago_efectivo ? `<div class="medio"><h3>En efectivo en el colegio</h3><p class="muted">${esc(k.pago_efectivo_texto || 'En la tesorería del colegio.')} Le entregan el recibo en el momento.</p></div>` : ''}
    </div></div>
  ${mediosComprobante().length ? `<div class="panel"><h2>Ya pagué</h2><p class="muted">Si pagó con ${mediosComprobante().join(' o ').toLowerCase().replace('llave bre-b', 'llave Bre-B')}, envíe aquí el comprobante. Cuando el colegio confirme que el dinero llegó, el pago queda registrado y le llega el recibo. Puede pagar una cuota completa o hacer un abono.</p>
    <div class="formgrid">${fIn('cVal', 'Valor pagado (puede ser un abono)', venc || '', 'type="number" min="1" oninput="this.dataset.manual=1"')}${fIn('cFec', 'Fecha del pago', hoy(), 'type="date"')}
      <label class="field"><span>Medio de pago</span><select id="cMed">${mediosComprobante().map(m => opt(m, m)).join('')}</select></label>${fIn('cRef', 'Número de referencia o aprobación', '')}
      <div class="field full"><span>¿Qué cuotas pagó? Marque las que corresponden a este pago</span>${cuotasFam().length ? `<div class="cuotas">${cuotasFam().map((x, i) => `<label class="chk"><input type="checkbox" class="cCuota" value="${i}" onchange="sumarCuotas()"${x.vencido ? ' checked' : ''}> ${esc(x.concepto)}${x.mes ? ' ' + MESES[x.mes] : ''} ${x.anioCobro || cuenta.anio} <span class="muted">${cop(x.saldo)}</span></label>`).join('')}</div>` : '<p class="muted">No tiene cuotas pendientes.</p>'}</div>
      <label class="field"><span>Foto o captura del comprobante (se borra al confirmarse; quedan el valor y la referencia)</span><input type="file" id="cImg" accept="image/*"></label></div>
    <div class="toolbar" style="margin-top:12px"><button class="btn" type="button" id="cBtn" onclick="enviarComprobante()">Ya pagué: enviar comprobante</button>
      <button class="btn ghost" type="button" onclick="pazYSalvo('${propio()}')">${venc > 0 ? 'Ver constancia de lo que se debe' : 'Descargar paz y salvo'}</button></div>
    ${comps.length ? `<h3 style="margin-top:14px">Comprobantes enviados</h3><div class="tbl"><table><thead><tr><th>Fecha</th><th>Valor</th><th>Medio</th><th>Estado</th></tr></thead><tbody>
      ${comps.map(c => `<tr><td>${fmtF(c.fecha)}</td><td>${cop(c.valor)}</td><td>${esc(c.medio || '')}${c.referencia ? ` <span class="muted">${esc(c.referencia)}</span>` : ''}</td><td>${tagComp(c.estado)}${c.respuesta ? `<br><span class="muted">${esc(c.respuesta)}</span>` : ''}</td></tr>`).join('')}</tbody></table></div>` : ''}</div>` : ''}`;
}
// Cuotas pendientes de la familia (años anteriores primero, luego las del año); de aquí sale la nota del comprobante
const cuotasFam = () => [...cuenta.prevFilas, ...cuenta.filas.filter(x => +x.saldo > 0)];
const cuotasMarcadas = () => [...document.querySelectorAll('.cCuota:checked')].map(c => cuotasFam()[+c.value]).filter(Boolean);
function sumarCuotas() { const el = $('#cVal'); if (el && !el.dataset.manual) el.value = cuotasMarcadas().reduce((a, x) => a + +x.saldo, 0) || ''; }
async function enviarComprobante() {
  const marc = cuotasMarcadas();
  const suma = marc.reduce((a, x) => a + +x.saldo, 0), val = +vv('cVal') || 0;
  const nota = (val > 0 && val < suma ? 'Abono a: ' : '') + marc.map(x => `${x.concepto}${x.mes ? ' ' + MESES[x.mes] : ''} ${x.anioCobro || cuenta.anio}`).join(', ');
  const d = { estudiante_id: propio(), colegio_id: ctx.colegio_id, valor: +vv('cVal') || 0, fecha: vv('cFec') || hoy(), medio: vv('cMed'), referencia: vv('cRef'), nota };
  if (cuotasFam().length && !marc.length) return toast('Marque qué cuotas pagó');
  if (d.valor <= 0) return toast('Escriba el valor pagado');
  if (!$('#cImg').files[0] && !d.referencia) return toast('Adjunte la foto del comprobante o escriba la referencia');
  await busy('#cBtn', async () => {
    const r = await guard(async () => { d.imagen = await leerImagen($('#cImg').files[0]); return q(db.from('comprobantes').insert(d).select('id,estudiante_id,fecha,valor,medio,referencia,nota,estado,respuesta,creado_en').single()); }, 'Comprobante enviado. Tesorería lo revisará');
    if (r) { comps.unshift(r); render(); }
  });
}
function pazYSalvo(eid) {
  if (cuenta.eid !== eid) return toast('Abra primero el estado de cuenta');
  const e = est(eid), vencidas = [...cuenta.prevFilas, ...cuenta.filas.filter(x => x.vencido && +x.saldo > 0)];
  const venc = vencidas.reduce((a, x) => a + +x.saldo, 0);
  const quien = `el(la) estudiante <strong>${esc(nom(e))}</strong>, identificado(a) con ${e.tipo_doc} ${esc(e.doc)}, del curso <strong>${esc(grupo(e.grupo_id)?.nombre || '')}</strong>`;
  const cuerpo = venc > 0
    ? `<p style="margin-top:18px">La tesorería de <strong>${esc(S.k.nombre)}</strong> informa que ${quien}, presenta a la fecha un <strong>saldo vencido de ${cop(venc)}</strong>, así:</p>
       <table><thead><tr><th>Concepto</th><th>Mes</th><th style="text-align:right">Saldo vencido</th></tr></thead><tbody>${vencidas.map(x => `<tr><td>${esc(x.concepto)}</td><td>${MESES[x.mes] || ''}${x.anioCobro ? ' ' + x.anioCobro : ''}</td><td style="text-align:right">${cop(x.saldo)}</td></tr>`).join('')}
       <tr><td colspan="2"><strong>Total adeudado a la fecha</strong></td><td style="text-align:right"><strong>${cop(venc)}</strong></td></tr></tbody></table>
       <p>El paz y salvo se expide una vez se cancele el saldo vencido.</p>`
    : `<p style="margin-top:18px">La tesorería de <strong>${esc(S.k.nombre)}</strong> certifica que ${quien}, se encuentra a <strong>paz y salvo</strong> por todo concepto vencido a la fecha. Deuda a la fecha: <strong>${cop(0)}</strong>.</p>`;
  showDocs(`<section class="doc">${docHead(venc > 0 ? 'Constancia de saldo pendiente' : 'Paz y salvo', `Año lectivo ${cuenta.anio || S.k.anio}<br>Corte ${fmtF(hoy())}`)}${cuerpo}
    <p>Se expide en ${esc(S.k.ciudad || '')}, el ${fechaLarga()}.</p>
    ${firmas(['Tesorería', ''], ['Rector(a)', S.k.rector_nombre])}</section>`, venc > 0 ? 'Constancia de saldo pendiente' : 'Paz y salvo', nomArchivo(venc > 0 ? 'Constancia de saldo' : 'Paz y salvo', e));
}

/* =====================================================================
   Certificados de años anteriores (historial del cierre de año)
   ===================================================================== */
async function certAnteriores(eid) {
  const h = await guard(() => q(db.from('historial').select('*').eq('estudiante_id', eid).order('anio')));
  if (!h) return;
  openModal(`Años anteriores: ${nom(est(eid))}`, h.length ? `<ul class="list">${h.map(x => `<li style="display:flex;justify-content:space-between;gap:10px;align-items:center"><span><strong>${x.anio}</strong> · ${esc(x.grupo_nombre || gradoTxt(x.grado))} · ${x.resultado}</span><button class="btn sm" type="button" onclick="certAnio('${eid}',${x.anio})">Certificado</button></li>`).join('')}</ul>`
    : '<p class="muted">Aún no hay años anteriores registrados. Se registran automáticamente al hacer el cierre de año en Parametrización.</p>');
}
async function certAnio(eid, anio) {
  const r = await guard(async () => {
    const [h] = await q(db.from('historial').select('*').eq('estudiante_id', eid).eq('anio', anio));
    const ns = await q(db.from('notas').select('asignatura_id,periodo,valor').eq('estudiante_id', eid).eq('anio', anio));
    const rc = await q(db.from('recuperaciones').select('asignatura_id,periodo,nota').eq('estudiante_id', eid).eq('anio', anio)).catch(() => []);
    const [cfg] = await q(db.from('anios_cerrados').select('periodos,escala').eq('colegio_id', ctx.colegio_id).eq('anio', anio)).catch(() => []);
    return { h, ns, rc, cfg };
  });
  if (!r?.h) return;
  // periodos y escala tal como estaban ese año (si el colegio los cambió después, el certificado no cambia)
  const { h, ns, rc } = r, e = est(eid), pre = h.nivel === 'preescolar', pers = r.cfg?.periodos?.length ? r.cfg.periodos : periodos(), escAnio = r.cfg?.escala?.length ? r.cfg.escala : escala();
  const as = S.asigs.filter(a => a.nivel === h.nivel).sort((a, b) => a.orden - b.orden);
  const def = aid => { let s = 0, w = 0; pers.forEach(p => { const n = ns.find(x => x.asignatura_id === aid && x.periodo === p.n), x = rc.find(y => y.asignatura_id === aid && y.periodo === p.n); let v = n ? +n.valor : null; if (x?.nota != null && (v == null || +x.nota > v)) v = +x.nota; if (v != null) { s += v * p.peso; w += p.peso; } }); return w ? Math.round(s / w) : null; };
  const filas = as.map(a => ({ a, v: def(a.id) })).filter(x => x.v != null);
  showDocs(`<section class="doc">${docHead('Certificado de estudios', `Año lectivo ${anio}`)}
    <p style="margin-top:14px">El suscrito rector(a) de <strong>${esc(S.k.nombre)}</strong> certifica que <strong>${esc(nom(e))}</strong>, identificado(a) con ${e.tipo_doc} ${esc(e.doc)}, cursó en esta institución el grado <strong>${esc(gradoTxt(h.grado))}</strong>${h.grupo_nombre ? ` (${esc(h.grupo_nombre)})` : ''} durante el año lectivo ${anio}, con resultado <strong>${h.resultado.toLowerCase()}</strong>, y obtuvo las siguientes valoraciones finales:</p>
    <table><thead><tr><th>${pre ? 'Dimensión' : 'Asignatura'}</th><th>IH</th>${pre ? '' : '<th>Valoración</th>'}<th>Desempeño</th></tr></thead><tbody>
    ${filas.length ? filas.map(({ a, v }) => `<tr><td>${esc(a.nombre)}</td><td>${a.ih}</td>${pre ? '' : `<td>${N(v)}</td>`}<td>${desem(v, escAnio)}</td></tr>`).join('') : `<tr><td colspan="4">No hay calificaciones registradas en Colegio-IA para ese año.</td></tr>`}</tbody></table>
    <p class="dnote">Escala institucional: ${escAnio.map(s => `${s.d} de ${N(s.min)} a ${N(s.max)}`).join(', ')}. Decreto 1290 de 2009.</p>
    <p>Se expide a solicitud del interesado en ${esc(S.k.ciudad || '')}, el ${fechaLarga()}.</p>
    ${firmas(['Rector(a)', S.k.rector_nombre], ['Secretaría académica', S.k.secretaria_nombre])}</section>`, `Certificado ${anio}`, nomArchivo(`Certificado ${anio}`, e));
}

/* =====================================================================
   Seguimiento académico: planilla, estadísticas, avance y cambios
   ===================================================================== */
const ATABS = { planilla: 'Planilla consolidada', estadisticas: 'Estadísticas', graficos: 'Gráficos y cruces', avance: 'Avance de calificaciones', cambios: 'Cambios de calificaciones' };
let acad = { p: 0, notas: [], log: [] };
async function prepAcademico() {
  const tabs = isDir() ? Object.keys(ATABS) : ['planilla'];
  if (!tabs.includes(sel.atab)) sel.atab = 'planilla';
  if (!sel.app) sel.app = S.k.periodo_actual;
  if (sel.atab === 'planilla') {
    const gs = isDir() ? S.grupos : S.grupos.filter(g => S.dirGrupos.includes(g.id));
    if (!sel.ag || !gs.find(g => g.id === sel.ag)) sel.ag = gs[0]?.id || '';
    if (sel.ag) await cargarGrupo(sel.ag);
  }
  if (sel.atab === 'estadisticas' && !sel.appElegido) { const pp = await periodoConDatos(S.k.periodo_actual); sel.app = pp; acad.aviso = pp !== S.k.periodo_actual ? `El periodo ${S.k.periodo_actual} aún no tiene calificaciones: se muestra el periodo ${pp}.` : ''; }
  if (sel.atab === 'estadisticas' || sel.atab === 'avance') {
    const p = sel.app === 'acum' ? S.k.periodo_actual : sel.app;
    acad.p = p; acad.notas = await all(() => db.from('notas').select('estudiante_id,asignatura_id,valor').eq('colegio_id', ctx.colegio_id).eq('anio', S.k.anio).eq('periodo', p).order('estudiante_id').order('asignatura_id'));
    if (sel.atab === 'avance') await cargarMiembros();
  }
  if (sel.atab === 'graficos') await prepGraficos();
  if (sel.atab === 'cambios') acad.log = await q(db.from('notas_log').select('*').eq('colegio_id', ctx.colegio_id).order('fecha', { ascending: false }).range(0, 399));
}
function vAcademico() {
  const tabs = isDir() ? Object.keys(ATABS) : ['planilla'], t = sel.atab;
  const cuerpo = { planilla: acPlanilla, estadisticas: acEstadisticas, graficos: acGraficos, avance: acAvance, cambios: acCambios }[t]();
  return head('Informes académicos', isDir() ? 'Para directivos: planilla consolidada por curso, estadísticas de estudiantes en bajo, gráficos que cruzan calificaciones, fallas y convivencia, cuánto lleva calificado cada docente antes del cierre y quién cambió una calificación.' : 'Calificaciones de su grupo como director(a).') +
    (tabs.length > 1 ? `<div class="tabs" role="tablist">${tabs.map(k => `<button type="button" role="tab" aria-selected="${k === t}" onclick="sel.atab='${k}';go('academico')">${ATABS[k]}</button>`).join('')}</div>` : '') + cuerpo;
}
const selPerAc = (acum = true) => `${acad.aviso && !sel.appElegido ? `<div class="note full">${acad.aviso}</div>` : ''}<label class="field"><span>Periodo</span><select onchange="sel.appElegido=1;sel.app=this.value==='acum'?'acum':+this.value;go('academico')">${perOpts(sel.app)}${acum ? opt('acum', 'Acumulado del año', sel.app) : ''}</select></label>`;
function acPlanilla() {
  const gs = isDir() ? S.grupos : S.grupos.filter(g => S.dirGrupos.includes(g.id));
  if (!gs.length) return '<div class="panel empty">Aún no hay cursos.</div>';
  const g = grupo(sel.ag);
  return `<div class="panel"><div class="toolbar"><label class="field"><span>Curso</span><select onchange="sel.ag=this.value;go('academico')">${gs.map(x => opt(x.id, x.nombre, sel.ag)).join('')}</select></label>${selPerAc()}
    ${isDoc() ? '' : `<button class="btn ghost" type="button" style="margin-left:auto" onclick="exportarPlanilla()">Exportar a Excel</button><button class="btn ghost" type="button" onclick="showDocs(planillaDoc(),'Planilla')">Imprimir</button>`}</div>
    ${planillaHTML(g, sel.app)}<p class="muted" style="margin-top:8px">Las calificaciones en rojo están en desempeño bajo. Pase el cursor sobre la abreviatura para ver el nombre completo de la asignatura.</p></div>`;
}
function planillaDoc() { const g = grupo(sel.ag); return `<section class="doc">${docHead(`Planilla consolidada: ${esc(g.nombre)}`, sel.app === 'acum' ? `Acumulado ${S.k.anio}` : `Periodo ${sel.app}, año ${S.k.anio}`)}${planillaHTML(g, sel.app)}</section>`; }
function statsDe(lista) { const v = lista.map(n => +n.valor), b = v.filter(x => desem(x) === 'Bajo').length; return { n: v.length, bajo: b, pct: v.length ? Math.round(b / v.length * 100) : 0, prom: v.length ? v.reduce((a, c) => a + c, 0) / v.length : null }; }
function acEstadisticas() {
  const ns = acad.notas;
  const grupos = S.grupos.filter(g => g.nivel !== 'preescolar').map(g => {
    const ids = new Set(estsDe(g.id).map(e => e.id)), l = ns.filter(n => ids.has(n.estudiante_id)), esperadas = ids.size * asigsDe(g).length;
    return { g, ...statsDe(l), esperadas, ids };
  });
  const pares = [];
  grupos.forEach(({ g, ids }) => asigsDe(g).forEach(a => { const l = ns.filter(n => n.asignatura_id === a.id && ids.has(n.estudiante_id)); if (l.length) pares.push({ g, a, ...statsDe(l) }); }));
  pares.sort((x, y) => y.pct - x.pct || y.bajo - x.bajo);
  const porAsig = {}; pares.forEach(p => { const k = p.a.nombre; porAsig[k] ||= { n: 0, bajo: 0 }; porAsig[k].n += p.n; porAsig[k].bajo += p.bajo; });
  const asigOrden = Object.entries(porAsig).map(([k, v]) => ({ k, ...v, pct: Math.round(v.bajo / v.n * 100) })).sort((a, b) => b.pct - a.pct);
  const bar = pct => `<div class="bar" style="min-width:90px"><i style="width:${pct}%;background:${pct >= 30 ? 'var(--red)' : pct >= 15 ? 'var(--pencil)' : 'var(--green)'}"></i></div>`;
  return `<div class="panel"><div class="toolbar">${selPerAc(false)}<span class="muted" style="margin-left:auto">${ns.length} calificaciones registradas en el periodo ${acad.p}</span></div></div>
    <div class="cols"><section class="panel"><h2>Por curso</h2><div class="tbl"><table><thead><tr><th>Curso</th><th>Registradas</th><th>Promedio</th><th>En bajo</th><th></th></tr></thead><tbody>
      ${grupos.map(x => `<tr><td>${esc(x.g.nombre)}</td><td>${x.esperadas ? Math.round(x.n / x.esperadas * 100) : 0}%</td><td>${x.prom == null ? '—' : N(x.prom)}</td><td>${x.bajo} (${x.pct}%)</td><td>${bar(x.pct)}</td></tr>`).join('') || '<tr><td colspan="5">Sin datos</td></tr>'}</tbody></table></div></section>
    <section class="panel"><h2>Por asignatura (todo el colegio)</h2><div class="tbl"><table><thead><tr><th>Asignatura</th><th>Calificaciones</th><th>En bajo</th><th></th></tr></thead><tbody>
      ${asigOrden.map(x => `<tr><td>${esc(x.k)}</td><td>${x.n}</td><td>${x.bajo} (${x.pct}%)</td><td>${bar(x.pct)}</td></tr>`).join('') || '<tr><td colspan="4">Sin datos</td></tr>'}</tbody></table></div></section></div>
    <section class="panel"><h2>Cursos y asignaturas con mayor pérdida</h2><div class="tbl"><table><thead><tr><th>Curso</th><th>Asignatura</th><th>Promedio</th><th>En bajo</th><th></th></tr></thead><tbody>
      ${pares.filter(p => p.bajo).slice(0, 15).map(p => `<tr><td>${esc(p.g.nombre)}</td><td>${esc(p.a.nombre)}</td><td>${N(p.prom)}</td><td>${p.bajo} de ${p.n} (${p.pct}%)</td><td>${bar(p.pct)}</td></tr>`).join('') || '<tr><td colspan="5">Ninguna asignatura tiene estudiantes en bajo en este periodo.</td></tr>'}</tbody></table></div></section>`;
}
function acAvance() {
  const ns = new Set(acad.notas.map(n => `${n.estudiante_id}|${n.asignatura_id}`)), ci = cierreDe(acad.p);
  const docs = (S.miembros || []).filter(m => m.rol === 'docente' && m.activo).map(m => {
    let esp = 0, reg = 0; const falt = [];
    (S.dg || []).filter(d => d.miembro_id === m.id).forEach(d => {
      const g = grupo(d.grupo_id); if (!g) return;
      const as = d.asignatura_id ? asigsDe(g).filter(a => a.id === d.asignatura_id) : asigsDe(g);
      as.forEach(a => { const es = estsDe(g.id); let r = 0; es.forEach(e => { esp++; if (ns.has(`${e.id}|${a.id}`)) { reg++; r++; } }); if (r < es.length) falt.push(`${g.nombre} ${a.nombre} (${es.length - r})`); });
    });
    return { m, esp, reg, pct: esp ? Math.round(reg / esp * 100) : 100, falt };
  }).sort((a, b) => a.pct - b.pct);
  return `<div class="panel"><div class="toolbar">${selPerAc(false)}${ci ? `<span class="muted" style="margin-left:auto">Cierre de calificaciones: ${fmtF(ci)}</span>` : ''}</div>
    ${docs.length ? `<div class="tbl"><table><thead><tr><th>Docente</th><th>Avance</th><th>Pendientes</th><th></th></tr></thead><tbody>
    ${docs.map(x => `<tr><td><strong>${esc(x.m.nombre)}</strong><br><span class="muted">${esc(x.m.email)}</span></td><td style="min-width:140px">${x.reg} de ${x.esp} (${x.pct}%)<div class="bar"><i style="width:${x.pct}%"></i></div></td>
      <td>${x.esp === 0 ? '<span class="muted">Sin grupos asignados</span>' : x.falt.length ? esc(x.falt.join(', ')) : '<span class="ok">Completo</span>'}</td>
      <td>${x.falt.length ? `<button class="btn ghost sm" type="button" onclick="recordarDoc('${x.m.id}')">Copiar recordatorio</button>` : ''}</td></tr>`).join('')}</tbody></table></div>` : '<p class="muted">No hay docentes registrados.</p>'}</div>`;
}
async function recordarDoc(mid) {
  const m = S.miembros.find(x => x.id === mid), ci = cierreDe(acad.p);
  const t = `Hola, ${m.nombre.split(' ')[0]}. Le recordamos registrar en Colegio-IA las calificaciones pendientes del periodo ${acad.p}${ci ? ` antes del ${fechaLarga(ci)}` : ''}: ${location.origin + location.pathname}. Gracias.`;
  try { await navigator.clipboard.writeText(t); toast('Recordatorio copiado. Péguelo en WhatsApp o en un correo'); } catch { openModal('Recordatorio', `<textarea id="cpT" style="width:100%;min-height:120px">${esc(t)}</textarea><div class="modal-foot"><button class="btn" type="button" onclick="copiar('#cpT')">Copiar</button></div>`); }
}
function acCambios() {
  const l = acad.log.filter(x => !sel.acq || (est(x.estudiante_id) && nom(est(x.estudiante_id)).toLowerCase().includes(sel.acq.toLowerCase())) || (x.nombre || '').toLowerCase().includes(sel.acq.toLowerCase()));
  const v = n => n == null ? '—' : N(n);
  return `<div class="panel"><p class="muted">Cada vez que alguien registra, cambia o borra una calificación del periodo queda aquí, con la fecha y el nombre de quien lo hizo. Se muestran los últimos 400 movimientos.</p>
    <div class="toolbar"><label class="field"><span>Buscar estudiante o usuario</span><input type="search" value="${esc(sel.acq || '')}" onchange="sel.acq=this.value;render()"></label></div>
    ${l.length ? `<div class="tbl"><table><thead><tr><th>Fecha</th><th>Usuario</th><th>Estudiante</th><th>Asignatura</th><th>Periodo</th><th>Antes</th><th>Después</th></tr></thead><tbody>
    ${l.map(x => { const e = est(x.estudiante_id); return `<tr><td>${fechaHora(x.fecha)}</td><td>${esc(x.nombre || '')}</td><td>${esc(e ? nom(e) : '')}</td><td>${esc(nomAsig(x.asignatura_id))}</td><td>${x.periodo}${x.anio !== S.k.anio ? ` (${x.anio})` : ''}</td><td>${v(x.antes)}</td><td>${x.despues == null ? '<span class="tag t3">Borrada</span>' : `<strong>${v(x.despues)}</strong>`}</td></tr>`; }).join('')}
    </tbody></table></div>` : '<p class="muted">Aún no hay cambios registrados.</p>'}</div>`;
}

/* =====================================================================
   Etapa 3: tienda del colegio, pedidos, lista de útiles y gráficos
   ===================================================================== */
const CATS = ['Uniformes', 'Libros y textos', 'Agendas y útiles', 'Stickers y marcación', 'Ruta escolar', 'Alimentación', 'Refuerzos y cursos', 'Derechos de grado', 'Eventos y salidas', 'Otros'];
const EST_PED = ['Por pagar', 'Por confirmar', 'Pagado', 'Listo para entregar', 'Entregado', 'Cancelado'];
const MEDIO_PED = { efectivo: 'Efectivo en el colegio', llave: 'Llave Bre-B', bold: 'En línea con Bold' };
const PROD_COLS = 'id,colegio_id,categoria,nombre,descripcion,precio,opciones,grados,con_imagen,activo,orden';
const PED_COLS = 'id,numero,estudiante_id,estado,medio,total,nota,referencia,con_comprobante,respuesta,visto_familia,creado_nombre,atendido_nombre,creado_en,actualizado_en,pagado_en,entregado_en';
const opcionesDe = p => String(p.opciones || '').split(',').map(x => x.trim()).filter(Boolean);
const medioOk = m => { const k = S.k; return m === 'efectivo' ? k.pago_efectivo : m === 'llave' ? !!(k.pago_llave && k.pago_llave_valor) : !!(k.pago_bold && k.pago_bold_url); };
const mediosTienda = () => ['efectivo', 'llave', 'bold'].filter(medioOk);
function tagPed(e) {
  const c = { 'Por pagar': 't2', 'Por confirmar': 't2', Pagado: 'piar', 'Listo para entregar': 'piar', Entregado: '', Cancelado: 't3' }[e] ?? '';
  return `<span class="tag ${c}">${esc(e)}</span>`;
}
let productos = [], pedidos = [], pedItems = {}, carrito = [];
async function cargarItems(ids) {
  pedItems = {};
  for (const part of chunks(ids, 60)) {
    const l = await q(db.from('pedido_items').select('pedido_id,nombre,categoria,opcion,cantidad,precio,subtotal').in('pedido_id', part).order('pedido_id').order('nombre'));
    l.forEach(x => (pedItems[x.pedido_id] ||= []).push(x));
  }
}
const itemsTxt = id => (pedItems[id] || []).map(x => `${x.cantidad} × ${x.nombre}${x.opcion ? ` (${x.opcion})` : ''}`).join(', ');

/* ---------- Tienda para la familia ---------- */
let carritoDe = '';
async function prepTienda() {
  const e = propio();
  if (carritoDe !== e) { carrito = []; carritoDe = e; }
  const [pr, pe] = await Promise.all([
    q(db.from('productos').select(PROD_COLS).eq('colegio_id', ctx.colegio_id).eq('activo', true).order('orden').order('nombre')),
    q(db.from('pedidos').select(PED_COLS).eq('estudiante_id', e).order('creado_en', { ascending: false }).limit(40)),
  ]);
  const g = grupo(est(e)?.grupo_id)?.grado;
  productos = pr.filter(p => !p.grados?.length || p.grados.includes(g));
  pedidos = pe; await cargarItems(pe.map(p => p.id));
  if (pe.some(p => !p.visto_familia)) { await q(db.rpc('pedidos_vistos', { p_estudiante: e })).catch(() => {}); if (S.nov) S.nov.pedidos = 0; }
  carrito = carrito.filter(c => productos.some(p => p.id === c.producto));
  if (!CATS.includes(sel.tcat)) sel.tcat = '';
}
function vTienda() {
  const e = est(propio());
  if (!S.k.tienda_activa) return head('Tienda del colegio') + '<div class="panel empty">La tienda del colegio no está disponible en este momento.</div>';
  if (sel.pedOk) return resultadoPedido();
  const cats = CATS.filter(c => productos.some(p => p.categoria === c));
  const lista = productos.filter(p => !sel.tcat || p.categoria === sel.tcat);
  setTimeout(() => cargarImgs('productos', 'imagen', 'img.prod-img'), 0);
  const abiertos = pedidos.filter(p => !['Entregado', 'Cancelado'].includes(p.estado));
  return head('Tienda del colegio', `Compre para ${esc(e?.nombres || 'su hijo(a)')} lo que ofrece el colegio. Agregue los artículos a su pedido y páguelo con el medio que prefiera.`) +
    (S.k.tienda_texto ? `<div class="note">${esc(S.k.tienda_texto)}</div>` : '') +
    (abiertos.length ? `<div class="note">Tiene ${abiertos.length} ${abiertos.length === 1 ? 'pedido en curso' : 'pedidos en curso'}. <button class="linkbtn" type="button" onclick="document.getElementById('misPed').scrollIntoView()">Ver mis pedidos</button></div>` : '') +
    `<div class="tienda"><div>
      ${cats.length > 1 ? `<div class="tabs" role="tablist"><button type="button" role="tab" aria-selected="${!sel.tcat}" onclick="sel.tcat='';render()">Todo</button>${cats.map(c => `<button type="button" role="tab" aria-selected="${sel.tcat === c}" onclick="sel.tcat='${c}';render()">${esc(c)}</button>`).join('')}</div>` : ''}
      ${lista.length ? `<div class="productos">${lista.map(tarjetaProd).join('')}</div>` : '<div class="panel empty">El colegio aún no tiene artículos en la tienda para este grado.</div>'}
    </div>${panelPedido()}</div>
    <section class="panel" id="misPed"><h2>Mis pedidos</h2>${pedidos.length ? tablaPedidosFam() : '<p class="muted">Aún no ha hecho pedidos.</p>'}</section>`;
}
function tarjetaProd(p) {
  const ops = opcionesDe(p);
  return `<article class="prod">${p.con_imagen ? `<div class="foto-box"><img class="prod-img" data-id="${p.id}" alt="${esc(p.nombre)}" onclick="verFotoEl(this)"></div>` : `<div class="prod-sin" aria-hidden="true">${esc(p.categoria)}</div>`}
    <div class="prod-b"><span class="muted" style="font-size:.8rem">${esc(p.categoria)}</span><h3>${esc(p.nombre)}</h3>${p.descripcion ? `<p class="muted">${esc(p.descripcion)}</p>` : ''}
      <div class="precio">${cop(p.precio)}</div>
      <div class="prod-f">${ops.length ? `<label class="field"><span>Talla u opción</span><select id="op_${p.id}"><option value="">Elija…</option>${ops.map(o => opt(o, o)).join('')}</select></label>` : ''}
        <label class="field"><span>Cantidad</span><input id="ca_${p.id}" type="number" min="1" max="20" value="1"></label></div>
      <button class="btn sm" type="button" onclick="agregarCarrito('${p.id}')">Agregar al pedido</button></div></article>`;
}
function agregarCarrito(id) {
  const p = productos.find(x => x.id === id); if (!p) return;
  const opcion = $('#op_' + id)?.value || '', cantidad = Math.round(+($('#ca_' + id)?.value || 1));
  if (opcionesDe(p).length && !opcion) return toast('Elija la talla u opción');
  if (!(cantidad >= 1 && cantidad <= 20)) return toast('La cantidad debe estar entre 1 y 20');
  const ya = carrito.find(c => c.producto === id && c.opcion === opcion);
  if (ya) ya.cantidad = Math.min(20, ya.cantidad + cantidad); else {
    if (carrito.length >= 15) return toast('Un pedido puede tener hasta 15 artículos distintos');
    carrito.push({ producto: id, opcion, cantidad });
  }
  toast(`Agregado: ${p.nombre}`); render();
}
function quitarCarrito(i) { carrito.splice(i, 1); render(); }
function cambiarCant(i, v) { const n = Math.round(+v); if (n >= 1 && n <= 20) carrito[i].cantidad = n; render(); }
const totalCarrito = () => carrito.reduce((a, c) => a + (productos.find(p => p.id === c.producto)?.precio || 0) * c.cantidad, 0);
function panelPedido() {
  const ms = mediosTienda();
  if (!sel.tmed || !ms.includes(sel.tmed)) sel.tmed = ms[0] || '';
  return `<aside class="panel su-pedido"><h2>Su pedido</h2>
    ${carrito.length ? `<ul class="lineas">${carrito.map((c, i) => { const p = productos.find(x => x.id === c.producto); return `<li><div><strong>${esc(p.nombre)}</strong>${c.opcion ? ` <span class="muted">(${esc(c.opcion)})</span>` : ''}<br>
        <span class="muted">${cop(p.precio)} c/u</span></div><div class="ln-d"><input type="number" min="1" max="20" value="${c.cantidad}" aria-label="Cantidad" onchange="cambiarCant(${i},this.value)"><strong>${cop(p.precio * c.cantidad)}</strong>
        <button class="linkbtn" type="button" onclick="quitarCarrito(${i})">Quitar</button></div></li>`; }).join('')}</ul>
      <div class="total"><span>Total</span><strong>${cop(totalCarrito())}</strong></div>
      ${ms.length ? `<div class="field"><span>¿Cómo va a pagar?</span>${ms.map(m => `<label class="chk"><input type="radio" name="tmed" value="${m}" ${sel.tmed === m ? 'checked' : ''} onchange="sel.tmed=this.value"> ${MEDIO_PED[m]}</label>`).join('')}</div>
        <label class="field"><span>Nota para el colegio (opcional)</span><input id="tNota" maxlength="300" placeholder="Ejemplo: entregar a la mamá en la salida"></label>
        <button class="btn" type="button" id="tBtn" style="width:100%;margin-top:10px" onclick="hacerPedido()">Hacer pedido por ${cop(totalCarrito())}</button>`
        : '<p class="muted">El colegio aún no ha configurado cómo recibir los pagos. Comuníquese con la secretaría.</p>'}`
      : '<p class="muted">Su pedido está vacío. Elija los artículos y oprima "Agregar al pedido".</p>'}</aside>`;
}
async function hacerPedido() {
  if (!carrito.length) return toast('Su pedido está vacío');
  if (!sel.tmed) return toast('Elija cómo va a pagar');
  const nota = vv('tNota');
  await busy('#tBtn', async () => {
    const id = await guard(() => q(db.rpc('crear_pedido', { p_estudiante: propio(), p_items: carrito, p_medio: sel.tmed, p_nota: nota || null })));
    if (id) { carrito = []; sel.pedOk = id; await go('tienda'); }
  });
}
function instruccionesPago(p) {
  const k = S.k;
  if (p.medio === 'efectivo') return `<p>Pague <strong>${cop(p.total)}</strong> en efectivo en el colegio${k.pago_efectivo_texto ? `: ${esc(k.pago_efectivo_texto)}` : ''}. Diga el número del pedido: <strong>${p.numero}</strong>. Allí registran el pago y le avisamos por aquí.</p>`;
  if (p.medio === 'llave') return `<p>Transfiera <strong>${cop(p.total)}</strong> a la llave Bre-B <strong class="code">${esc(k.pago_llave_valor)}</strong> <button class="btn ghost sm" type="button" onclick="copiarTexto('${esc(k.pago_llave_valor)}')">Copiar</button>${k.pago_llave_titular ? ` <span class="muted">a nombre de ${esc(k.pago_llave_titular)}</span>` : ''}. Después oprima <strong>"Ya pagué"</strong> y adjunte el comprobante.</p>`;
  return `<p>Pague <strong>${cop(p.total)}</strong> en línea con el enlace de pago del colegio. Escriba el valor exacto del pedido. Después oprima <strong>"Ya pagué"</strong> y adjunte el comprobante.</p><p><a class="btn" href="${esc(k.pago_bold_url)}" target="_blank" rel="noopener">Pagar en línea con Bold</a></p>`;
}
function resultadoPedido() {
  const p = pedidos.find(x => x.id === sel.pedOk);
  if (!p) { sel.pedOk = ''; return vTienda(); }
  return head(`Pedido No. ${p.numero} recibido`, 'El colegio ya puede verlo. Le avisamos aquí cada vez que cambie de estado.') +
    `<div class="panel"><h2>Lo que pidió</h2><ul class="list">${(pedItems[p.id] || []).map(x => `<li>${x.cantidad} × ${esc(x.nombre)}${x.opcion ? ` (${esc(x.opcion)})` : ''} <span class="muted">${cop(x.subtotal)}</span></li>`).join('')}</ul>
      <p><strong>Total: ${cop(p.total)}</strong></p><h2>Cómo pagar</h2>${instruccionesPago(p)}
      <div class="toolbar" style="margin-top:12px">${p.medio !== 'efectivo' ? `<button class="btn" type="button" onclick="formComprobantePed('${p.id}')">Ya pagué: enviar comprobante</button>` : ''}
        <button class="btn ghost" type="button" onclick="sel.pedOk='';render()">Seguir comprando</button><button class="btn ghost" type="button" onclick="sel.pedOk='';render();setTimeout(()=>document.getElementById('misPed')?.scrollIntoView(),50)">Ver mis pedidos</button></div></div>`;
}
function tablaPedidosFam() {
  return `<div class="tbl"><table><thead><tr><th>No.</th><th>Fecha</th><th>Artículos</th><th>Total</th><th>Estado</th><th></th></tr></thead><tbody>
    ${pedidos.map(p => `<tr><td>${p.numero}</td><td>${fmtF(p.creado_en)}</td><td>${esc(itemsTxt(p.id))}${p.nota ? `<br><span class="muted">Nota: ${esc(p.nota)}</span>` : ''}</td><td>${cop(p.total)}<br><span class="muted">${MEDIO_PED[p.medio]}</span></td>
      <td>${tagPed(p.estado)}${p.respuesta ? `<br><span class="muted">${esc(p.respuesta)}</span>` : ''}${p.estado === 'Por confirmar' ? '<br><span class="muted">El colegio está revisando su comprobante.</span>' : ''}</td>
      <td><div class="toolbar">${p.estado === 'Por pagar' ? `<button class="btn sm" type="button" onclick="sel.pedOk='${p.id}';render()">Cómo pagar</button>` : ''}
        ${p.estado === 'Por pagar' && p.medio !== 'efectivo' ? `<button class="btn ghost sm" type="button" onclick="formComprobantePed('${p.id}')">Ya pagué</button>` : ''}
        ${['Pagado', 'Listo para entregar', 'Entregado'].includes(p.estado) ? `<button class="btn ghost sm" type="button" onclick="reciboPedido('${p.id}')">Comprobante</button>` : ''}
        ${['Por pagar', 'Por confirmar'].includes(p.estado) ? `<button class="linkbtn" type="button" onclick="cancelarPedidoFam('${p.id}')">Cancelar</button>` : ''}</div></td></tr>`).join('')}</tbody></table></div>`;
}
function formComprobantePed(id) {
  const p = pedidos.find(x => x.id === id);
  openModal(`Ya pagué el pedido No. ${p.numero}`, `<p>Total del pedido: <strong>${cop(p.total)}</strong> (${MEDIO_PED[p.medio]}).</p><div class="formgrid">
    ${fIn('pcRef', 'Número de referencia o aprobación', p.referencia || '', 'maxlength="60"')}
    <label class="field"><span>Foto o captura del comprobante</span><input type="file" id="pcImg" accept="image/*"></label></div>
    <p class="muted">La foto se borra cuando el colegio confirma el pago; quedan el valor y la referencia.</p>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" id="pcBtn" onclick="enviarComprobantePed('${id}')">Enviar comprobante</button></div>`);
}
async function enviarComprobantePed(id) {
  const ref = vv('pcRef'), f = $('#pcImg').files[0];
  if (!f && !ref) return toast('Adjunte la foto del comprobante o escriba la referencia');
  await busy('#pcBtn', async () => {
    const ok = await guard(async () => { const img = await leerImagen(f); await q(db.rpc('comprobante_pedido', { p_pedido: id, p_imagen: img, p_referencia: ref || null })); return true; }, 'Comprobante enviado. El colegio lo revisará');
    if (ok) { closeModal(); sel.pedOk = ''; await go('tienda'); }
  });
}
async function cancelarPedidoFam(id) {
  const p = pedidos.find(x => x.id === id);
  if (!await confirmar(`¿Cancelar el pedido No. ${p.numero}?`)) return;
  const ok = await guard(async () => { await q(db.rpc('estado_pedido', { p_pedido: id, p_estado: 'Cancelado' })); return true; }, 'Pedido cancelado');
  if (ok) { sel.pedOk = ''; await go('tienda'); }
}
function reciboPedido(id) {
  const p = pedidos.find(x => x.id === id), e = est(p.estudiante_id);
  showDocs(`<section class="doc">${docHead(`Comprobante de pedido No. ${p.numero}`, fmtF(p.creado_en))}
    <div class="dgrid">${dato('Estudiante', e ? nom(e) : '')}${dato('Curso', e ? grupo(e.grupo_id)?.nombre : '')}${dato('Pedido por', p.creado_nombre)}
    ${dato('Medio de pago', MEDIO_PED[p.medio] + (p.referencia ? ` (${p.referencia})` : ''))}${dato('Pago confirmado', p.pagado_en ? fmtF(p.pagado_en) : '')}${dato('Estado', p.estado + (p.entregado_en ? ` el ${fmtF(p.entregado_en)}` : ''))}</div>
    <table><thead><tr><th>Artículo</th><th>Cantidad</th><th style="text-align:right">Valor unitario</th><th style="text-align:right">Subtotal</th></tr></thead><tbody>
    ${(pedItems[p.id] || []).map(x => `<tr><td>${esc(x.nombre)}${x.opcion ? ` (${esc(x.opcion)})` : ''}</td><td>${x.cantidad}</td><td style="text-align:right">${cop(x.precio)}</td><td style="text-align:right">${cop(x.subtotal)}</td></tr>`).join('')}
    <tr><td colspan="3"><strong>Total</strong></td><td style="text-align:right"><strong>${cop(p.total)}</strong></td></tr></tbody></table>
    ${p.atendido_nombre ? `<p class="dnote">Atendido por ${esc(p.atendido_nombre)}.</p>` : ''}</section>`, 'Comprobante de pedido', `Pedido ${p.numero}`);
}

/* ---------- Tienda y pedidos para el colegio ---------- */
const TTABS = { pedidos: 'Pedidos', productos: 'Artículos', ajustes: 'Configuración' };
async function prepPedidos() {
  if (!TTABS[sel.ttab]) sel.ttab = 'pedidos';
  if (sel.ttab === 'pedidos') {
    if (!sel.pfil) sel.pfil = 'atender';
    let qy = () => db.from('pedidos').select(PED_COLS).eq('colegio_id', ctx.colegio_id);
    const f = sel.pfil;
    const mk = f === 'atender' ? () => qy().in('estado', ['Por pagar', 'Por confirmar', 'Pagado', 'Listo para entregar'])
      : f === 'todos' ? () => qy().gte('creado_en', sumarDias(hoy(), -120)) : () => qy().eq('estado', f).gte('creado_en', sumarDias(hoy(), -365));
    pedidos = await all(() => mk().order('creado_en', { ascending: false }).order('id'));
    await cargarItems(pedidos.map(p => p.id));
  }
  if (sel.ttab === 'productos') productos = await q(db.from('productos').select(PROD_COLS).eq('colegio_id', ctx.colegio_id).order('orden').order('nombre'));
}
function vPedidos() {
  const t = sel.ttab;
  const cuerpo = { pedidos: tabPedidos, productos: tabProductos, ajustes: tabAjustesTienda }[t]();
  return head('Tienda y pedidos', 'Artículos que el colegio vende a las familias (uniformes, libros, agendas, ruta, alimentación, refuerzos, derechos de grado, eventos), pedidos y su entrega.') +
    (!S.k.tienda_activa ? `<div class="note">La tienda está <strong>apagada</strong>: las familias no la ven. ${esRector() ? `<button class="linkbtn" type="button" onclick="sel.ttab='ajustes';go('pedidos')">Encenderla</button>` : 'El rector o la rectora pueden encenderla.'}</div>` : '') +
    `<div class="tabs" role="tablist">${Object.keys(TTABS).map(k => `<button type="button" role="tab" aria-selected="${k === t}" onclick="sel.ttab='${k}';go('pedidos')">${TTABS[k]}</button>`).join('')}</div>${cuerpo}`;
}
const filtroPedTxt = { atender: 'Por atender', todos: 'Todos (últimos 4 meses)' };
function tabPedidos() {
  const qq = (sel.pq || '').toLowerCase();
  const l = pedidos.filter(p => { if (!qq) return true; const e = est(p.estudiante_id); return String(p.numero) === qq || (e && nom(e).toLowerCase().includes(qq)); });
  const cnt = s => pedidos.filter(p => p.estado === s).length;
  return `${sel.pfil === 'atender' ? `<div class="stats"><div class="stat"><div class="n">${cnt('Por confirmar')}</div><div class="l">Comprobantes por confirmar</div></div>
      <div class="stat"><div class="n">${cnt('Pagado')}</div><div class="l">Pagados por preparar</div></div><div class="stat"><div class="n">${cnt('Listo para entregar')}</div><div class="l">Listos para entregar</div></div>
      <div class="stat"><div class="n">${cnt('Por pagar')}</div><div class="l">Esperando el pago</div></div></div>` : ''}
    <div class="panel"><div class="toolbar"><label class="field"><span>Ver</span><select onchange="sel.pfil=this.value;go('pedidos')">${[['atender', filtroPedTxt.atender], ...EST_PED.map(s => [s, s]), ['todos', filtroPedTxt.todos]].map(([v, x]) => opt(v, x, sel.pfil)).join('')}</select></label>
      <label class="field"><span>Buscar estudiante o número</span><input type="search" value="${esc(sel.pq || '')}" onchange="sel.pq=this.value;render()"></label>
      <button class="btn ghost" type="button" style="margin-left:auto" onclick="listaPreparar()">Lista para preparar</button></div>
    ${l.length ? `<div class="tbl"><table><thead><tr><th>No.</th><th>Fecha</th><th>Estudiante</th><th>Artículos</th><th>Total</th><th>Estado</th><th></th></tr></thead><tbody>
      ${l.map(p => { const e = est(p.estudiante_id); return `<tr><td>${p.numero}</td><td>${fmtF(p.creado_en)}</td><td><strong>${esc(e ? nom(e) : '')}</strong><br><span class="muted">${esc(e ? grupo(e.grupo_id)?.nombre || '' : '')}</span></td>
        <td>${esc(itemsTxt(p.id))}${p.nota ? `<br><span class="muted">Nota: ${esc(p.nota)}</span>` : ''}</td><td>${cop(p.total)}<br><span class="muted">${MEDIO_PED[p.medio]}</span></td><td>${tagPed(p.estado)}</td>
        <td><button class="btn sm" type="button" onclick="verPedido('${p.id}')">Atender</button></td></tr>`; }).join('')}</tbody></table></div>` : '<p class="empty">No hay pedidos en esta lista.</p>'}</div>`;
}
function verPedido(id) {
  const p = pedidos.find(x => x.id === id), e = est(p.estudiante_id);
  const b = (estado, l, cls = '') => `<button class="btn ${cls}" type="button" onclick="cambiarEstadoPed('${id}','${estado}')">${l}</button>`;
  const acciones = {
    'Por pagar': b('Pagado', p.medio === 'efectivo' ? 'Recibí el pago' : 'Confirmar pago') + b('Cancelado', 'Cancelar pedido', 'ghost'),
    'Por confirmar': b('Pagado', 'El dinero llegó: confirmar pago') + b('Por pagar', 'Rechazar comprobante', 'ghost') + b('Cancelado', 'Cancelar pedido', 'ghost'),
    Pagado: b('Listo para entregar', 'Marcar listo para entregar') + b('Entregado', 'Marcar entregado', 'ghost') + b('Cancelado', 'Cancelar pedido', 'ghost'),
    'Listo para entregar': b('Entregado', 'Marcar entregado') + b('Cancelado', 'Cancelar pedido', 'ghost'),
  }[p.estado] || '';
  openModal(`Pedido No. ${p.numero}`, `<div class="dgrid">${dato('Estudiante', e ? nom(e) : '')}${dato('Curso', e ? grupo(e.grupo_id)?.nombre : '')}${dato('Pedido por', p.creado_nombre)}${dato('Fecha', fechaHora(p.creado_en))}${dato('Medio de pago', MEDIO_PED[p.medio])}${dato('Referencia', p.referencia)}</div>
    <div class="tbl" style="margin-top:10px"><table><thead><tr><th>Artículo</th><th>Cant.</th><th>Subtotal</th></tr></thead><tbody>${(pedItems[p.id] || []).map(x => `<tr><td>${esc(x.nombre)}${x.opcion ? ` (${esc(x.opcion)})` : ''}</td><td>${x.cantidad}</td><td>${cop(x.subtotal)}</td></tr>`).join('')}
      <tr><td colspan="2"><strong>Total</strong></td><td><strong>${cop(p.total)}</strong></td></tr></tbody></table></div>
    ${p.nota ? `<p><strong>Nota de la familia:</strong> ${esc(p.nota)}</p>` : ''}${p.respuesta ? `<p class="muted">Última respuesta: ${esc(p.respuesta)}</p>` : ''}
    <p>Estado: ${tagPed(p.estado)}${p.atendido_nombre ? ` <span class="muted">· ${esc(p.atendido_nombre)}</span>` : ''}</p>
    ${p.con_comprobante ? `<div class="foto-box"><img class="cmp-ped" data-id="${p.id}" alt="Comprobante" style="max-width:100%;border-radius:8px" onclick="verFotoEl(this)"></div>` : ''}
    ${acciones ? `<label class="field full"><span>Mensaje para la familia (obligatorio al rechazar o al cancelar un pedido pagado)</span><input id="peResp" maxlength="300"></label>
      <div class="modal-foot" style="flex-wrap:wrap">${acciones}</div>` : '<div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cerrar</button></div>'}`);
  if (p.con_comprobante) cargarImgs('pedidos', 'comprobante', 'img.cmp-ped');
}
async function cambiarEstadoPed(id, estado) {
  const resp = vv('peResp'), p = pedidos.find(x => x.id === id);
  if (estado === 'Por pagar' && !resp) return toast('Escriba el motivo para la familia');
  if (estado === 'Cancelado' && ['Pagado', 'Listo para entregar'].includes(p?.estado) && !resp) return toast('El pedido ya está pagado: escriba el motivo de la cancelación');
  if (estado === 'Cancelado' && !await confirmar('¿Cancelar este pedido? La familia verá el mensaje que escribió.')) return;
  const ok = await guard(async () => { await q(db.rpc('estado_pedido', { p_pedido: id, p_estado: estado, p_respuesta: resp || null })); return true; }, `Pedido: ${estado.toLowerCase()}`);
  if (ok) { delete imgCache[id]; closeModal(); await cargarNovedades(); await go('pedidos'); }
}
function listaPreparar() {
  const l = pedidos.filter(p => p.estado === 'Pagado');
  if (!l.length) return toast('No hay pedidos pagados por preparar en esta lista');
  const tot = {};
  l.forEach(p => (pedItems[p.id] || []).forEach(x => { const k = `${x.nombre}${x.opcion ? ` (${x.opcion})` : ''}`; tot[k] = (tot[k] || 0) + x.cantidad; }));
  const filas = l.map(p => ({ p, e: est(p.estudiante_id) })).sort((a, b) => (grupo(a.e?.grupo_id)?.nombre || '').localeCompare(grupo(b.e?.grupo_id)?.nombre || '', 'es') || (a.e?.apellidos || '').localeCompare(b.e?.apellidos || '', 'es'));
  showDocs(`<section class="doc">${docHead('Pedidos pagados por preparar', `Corte ${fmtF(hoy())}`)}
    <h3>Total por artículo</h3><table><thead><tr><th>Artículo</th><th>Cantidad</th></tr></thead><tbody>${Object.entries(tot).sort((a, b) => a[0].localeCompare(b[0], 'es')).map(([k, v]) => `<tr><td>${esc(k)}</td><td>${v}</td></tr>`).join('')}</tbody></table>
    <h3>Por estudiante</h3><table><thead><tr><th>No.</th><th>Curso</th><th>Estudiante</th><th>Artículos</th><th>Entregado</th></tr></thead><tbody>
    ${filas.map(({ p, e }) => `<tr><td>${p.numero}</td><td>${esc(e ? grupo(e.grupo_id)?.nombre || '' : '')}</td><td>${esc(e ? nom(e) : '')}</td><td>${esc(itemsTxt(p.id))}${p.nota ? `<br><em>${esc(p.nota)}</em>` : ''}</td><td></td></tr>`).join('')}</tbody></table></section>`, 'Lista para preparar');
}
function tabProductos() {
  setTimeout(() => cargarImgs('productos', 'imagen', 'img.prod-mini'), 0);
  return `<div class="panel"><div class="toolbar"><button class="btn" type="button" onclick="formProducto()">Agregar artículo</button><span class="muted">Las familias solo ven los artículos activos y, si marca grados, solo los de su grado.</span></div>
    ${productos.length ? `<div class="tbl"><table><thead><tr><th></th><th>Artículo</th><th>Categoría</th><th>Precio</th><th>Tallas u opciones</th><th>Grados</th><th>Estado</th><th></th></tr></thead><tbody>
    ${productos.map(p => `<tr class="${p.activo ? '' : 'dim'}"><td>${p.con_imagen ? `<span class="foto-box"><img class="prod-mini" data-id="${p.id}" alt=""></span>` : ''}</td><td><strong>${esc(p.nombre)}</strong>${p.descripcion ? `<br><span class="muted">${esc(p.descripcion)}</span>` : ''}</td><td>${esc(p.categoria)}</td><td>${cop(p.precio)}</td>
      <td>${esc(opcionesDe(p).join(', ')) || '—'}</td><td>${p.grados?.length ? esc(p.grados.map(gradoTxt).join(', ')) : 'Todos'}</td><td>${p.activo ? '<span class="tag piar">Activo</span>' : '<span class="tag">Oculto</span>'}</td>
      <td><div class="toolbar"><button class="btn ghost sm" type="button" onclick="formProducto('${p.id}')">Editar</button><button class="linkbtn" type="button" onclick="borrarProducto('${p.id}')">Borrar</button></div></td></tr>`).join('')}</tbody></table></div>`
      : '<p class="empty">Aún no hay artículos. Agregue el primero: uniforme, agenda, libro, ruta, alimentación, refuerzo, derechos de grado o una salida.</p>'}</div>`;
}
function formProducto(id) {
  const p = productos.find(x => x.id === id) || { categoria: 'Uniformes', activo: true, grados: [], orden: productos.length + 1 };
  const grados = [...new Set(S.grupos.map(g => g.grado))].sort((a, b) => a - b);
  openModal(id ? 'Editar artículo' : 'Agregar artículo', `<div class="formgrid">
    <label class="field"><span>Categoría</span><select id="prCat">${CATS.map(c => opt(c, c, p.categoria)).join('')}</select></label>
    ${fIn('prNom', 'Nombre', p.nombre, 'maxlength="120"')}${fIn('prPre', 'Precio (pesos)', p.precio || '', 'type="number" min="1"')}
    ${fIn('prOp', 'Tallas u opciones, separadas por coma (opcional)', p.opciones || '', 'maxlength="300" placeholder="Ejemplo: 6, 8, 10, 12, S, M"')}
    ${fTa('prDes', 'Descripción (opcional)', p.descripcion || '', 'Qué incluye, fechas, horarios…')}
    <div class="field full"><span>Para qué grados (si no marca ninguno, lo ven todos)</span><div class="cuotas">${grados.map(g => `<label class="chk"><input type="checkbox" class="prG" value="${g}" ${p.grados?.includes(g) ? 'checked' : ''}> ${gradoTxt(g)}</label>`).join('')}</div></div>
    <label class="field"><span>Foto (opcional, se guarda liviana)</span><input type="file" id="prImg" accept="image/*"></label>
    ${fIn('prOrd', 'Orden en la tienda', p.orden ?? 0, 'type="number"')}
    <div class="field full"><label class="chk"><input type="checkbox" id="prAct" ${p.activo ? 'checked' : ''}> Activo (visible para las familias)</label>${p.con_imagen ? `<label class="chk"><input type="checkbox" id="prSinImg"> Quitar la foto actual</label>` : ''}</div></div>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" id="prBtn" onclick="guardarProducto('${id || ''}')">Guardar</button></div>`);
}
async function guardarProducto(id) {
  const d = { categoria: vv('prCat'), nombre: vv('prNom'), precio: Math.round(+vv('prPre') || 0), opciones: vv('prOp') || null, descripcion: vv('prDes') || null,
    grados: [...document.querySelectorAll('.prG:checked')].map(x => +x.value), orden: Math.round(+vv('prOrd') || 0), activo: $('#prAct').checked };
  if ((d.nombre || '').length < 3) return toast('Escriba el nombre del artículo');
  if (!(d.precio > 0)) return toast('Escriba el precio');
  await busy('#prBtn', async () => {
    const ok = await guard(async () => {
      const f = $('#prImg').files[0];
      if (f) d.imagen = await leerImagen(f, 600); else if ($('#prSinImg')?.checked) d.imagen = null;
      if (id) await q(db.from('productos').update(d).eq('id', id)); else await q(db.from('productos').insert({ ...d, colegio_id: ctx.colegio_id }));
      return true;
    }, 'Artículo guardado');
    if (ok) { if (id) delete imgCache[id]; closeModal(); await go('pedidos'); }
  });
}
async function borrarProducto(id) {
  const p = productos.find(x => x.id === id);
  if (!await confirmar(`¿Borrar "${p.nombre}"? Los pedidos que ya lo incluyen no cambian. Si solo quiere dejar de venderlo, edítelo y desmarque "Activo".`)) return;
  const ok = await guard(async () => { await q(db.from('productos').delete().eq('id', id)); return true; }, 'Artículo borrado');
  if (ok) await go('pedidos');
}
function tabAjustesTienda() {
  const k = S.k, ro = !esRector(), ms = mediosTienda();
  return `<div class="panel"><h2>Tienda del colegio</h2><div class="formgrid">
    <div class="field full"><label class="chk"><input type="checkbox" id="tiAct" ${k.tienda_activa ? 'checked' : ''} ${ro ? 'disabled' : ''}> <strong>Tienda encendida</strong>: los acudientes ven la tienda y pueden hacer pedidos.</label></div>
    ${fTa('tiTxt', 'Información de entrega para las familias (opcional)', k.tienda_texto || '', 'Ejemplo: los pedidos pagados se entregan en la secretaría de lunes a viernes de 7:00 a 12:00.')}</div>
    <p class="muted">Medios de pago de la tienda: los mismos del estado de cuenta (${ms.length ? ms.map(m => MEDIO_PED[m]).join(', ') : 'ninguno configurado'}). Se cambian en Parametrización → Costos del año.</p>
    ${ro ? '<p class="muted">Solo el rector o la rectora pueden cambiar esta configuración.</p>' : `<div class="toolbar" style="margin-top:12px"><button class="btn" type="button" onclick="guardarTienda()">Guardar</button>${isDir() ? `<button class="btn ghost" type="button" onclick="sel.ptab='costos';go('config')">Ir a los medios de pago</button>` : ''}</div>`}</div>`;
}
async function guardarTienda() {
  const d = { tienda_activa: $('#tiAct').checked, tienda_texto: vv('tiTxt') || null };
  if (d.tienda_activa && !mediosTienda().length) return toast('Primero configure al menos un medio de pago en Parametrización → Costos del año');
  if (await guardarColegio(d, d.tienda_activa ? 'Tienda encendida' : 'Tienda apagada')) { renderSide(); render(); }
}

/* ---------- Lista de útiles por grado ---------- */
let utiles = [];
async function prepUtiles() {
  utiles = await q(db.from('utiles').select('*').eq('colegio_id', ctx.colegio_id).eq('anio', S.k.anio).order('grado'));
  const grados = gradosUtiles();
  if (isFam()) sel.ugr = grupo(est(propio())?.grupo_id)?.grado;
  else if (!grados.includes(sel.ugr)) sel.ugr = grados[0];
}
const gradosUtiles = () => [...new Set((isDoc() ? gruposVis() : S.grupos).map(g => g.grado))].sort((a, b) => a - b);
function utilesDoc(u, g) {
  return `<section class="doc">${docHead(`Lista de útiles escolares`, `${esc(gradoTxt(g))} · Año ${S.k.anio}`)}
    <ol class="utiles-l">${(u?.lista || '').split('\n').map(x => x.trim()).filter(Boolean).map(x => `<li>${esc(x)}</li>`).join('')}</ol>${u?.nota ? `<p class="dnote">${esc(u.nota)}</p>` : ''}</section>`;
}
function vUtiles() {
  const g = sel.ugr, u = utiles.find(x => x.grado === g), grados = gradosUtiles();
  if (g == null) return head('Lista de útiles') + '<div class="panel empty">No hay cursos para mostrar.</div>';
  const items = (u?.lista || '').split('\n').map(x => x.trim()).filter(Boolean);
  const puede = isDir();
  return head('Lista de útiles', isFam() ? `Útiles de ${esc(gradoTxt(g))} para el año ${S.k.anio}.` : `Lista de útiles por grado para el año ${S.k.anio}. Las familias ven la del grado de su hijo(a).`) +
    `<div class="panel">${!isFam() && grados.length > 1 ? `<div class="toolbar"><label class="field"><span>Grado</span><select onchange="sel.ugr=+this.value;render()">${grados.map(x => opt(x, `${gradoTxt(x)}${utiles.some(y => y.grado === x && y.lista.trim()) ? '' : ' (sin lista)'}`, g)).join('')}</select></label></div>` : ''}
      ${puede ? `<div class="formgrid">${fTa('utL', 'Útiles: escriba uno por línea', u?.lista || '', '1 cuaderno cuadriculado de 100 hojas')}${fTa('utN', 'Nota para las familias (opcional)', u?.nota || '', 'Ejemplo: marque todo con el nombre; se recibe la primera semana.')}</div>
        <div class="toolbar" style="margin-top:12px"><button class="btn" type="button" id="utBtn" onclick="guardarUtiles()">Guardar lista</button>${items.length ? `<button class="btn ghost" type="button" onclick="verUtiles()">Imprimir</button>` : ''}
        ${utiles.some(x => x.grado !== g && x.lista.trim()) ? `<label class="field"><span>Copiar la lista de</span><select onchange="copiarUtiles(this.value)"><option value="">Elija un grado…</option>${utiles.filter(x => x.grado !== g && x.lista.trim()).map(x => opt(x.grado, gradoTxt(x.grado))).join('')}</select></label>` : ''}</div>
        ${u?.actualizado_nombre ? `<p class="muted">Actualizada por ${esc(u.actualizado_nombre)} el ${fmtF(u.actualizado_en)}.</p>` : ''}`
      : items.length ? `<ol class="utiles-l">${items.map(x => `<li>${esc(x)}</li>`).join('')}</ol>${u.nota ? `<p class="note">${esc(u.nota)}</p>` : ''}
        <div class="toolbar">${isDoc() ? '' : `<button class="btn ghost" type="button" onclick="verUtiles()">Imprimir o guardar en PDF</button>`}${isAcud() && S.k.tienda_activa ? `<button class="btn" type="button" onclick="go('tienda')">Ver la tienda del colegio</button>` : ''}</div>`
      : '<p class="empty">El colegio aún no ha publicado la lista de útiles de este grado.</p>'}</div>`;
}
function verUtiles() { const g = sel.ugr; showDocs(utilesDoc(utiles.find(x => x.grado === g), g), 'Lista de útiles', `Lista de útiles ${gradoTxt(g)} ${S.k.anio}`); }
function copiarUtiles(gr) { const u = utiles.find(x => x.grado === +gr); if (!u) return; $('#utL').value = u.lista; $('#utN').value = u.nota || ''; toast(`Copiada la lista de ${gradoTxt(+gr)}. Revísela y guarde`); }
async function guardarUtiles() {
  const d = { colegio_id: ctx.colegio_id, anio: S.k.anio, grado: sel.ugr, lista: vv('utL').split('\n').map(x => x.trim()).filter(Boolean).join('\n'), nota: vv('utN') || null };
  if (d.lista.length > 6000) return toast('La lista es muy larga');
  await busy('#utBtn', async () => {
    const r = await guard(() => q(db.from('utiles').upsert(d, { onConflict: 'colegio_id,anio,grado' }).select().single()), 'Lista guardada');
    if (r) { utiles = utiles.filter(x => x.grado !== r.grado).concat(r); render(); }
  });
}

/* ---------- Gráficos que cruzan variables (Informes académicos) ---------- */
const notaTope = () => 100;
const VARS = { prom: 'Promedio del periodo', bajo: 'Asignaturas en bajo', fallas: 'Fallas en el año', conv: 'Anotaciones de convivencia' };
async function periodoConDatos(p) {
  // Si el periodo aún no tiene calificaciones, se abre el último que sí tenga (y se avisa)
  for (let x = p; x >= 1; x--) { const r = await q(db.from('notas').select('periodo').eq('colegio_id', ctx.colegio_id).eq('anio', S.k.anio).eq('periodo', x).limit(1)).catch(() => []); if (r.length) return x; }
  return p;
}
async function prepGraficos() {
  if (!sel.appElegido) { const pp = await periodoConDatos(S.k.periodo_actual); if (pp !== S.k.periodo_actual) { sel.app = pp; acad.aviso = `El periodo ${S.k.periodo_actual} aún no tiene calificaciones: se muestra el periodo ${pp}.`; } else acad.aviso = ''; }
  const p = sel.app === 'acum' ? S.k.periodo_actual : sel.app; acad.p = p;
  const c = ctx.colegio_id, a = S.k.anio;
  const [ns, as, ob] = await Promise.all([
    all(() => db.from('notas').select('estudiante_id,asignatura_id,valor').eq('colegio_id', c).eq('anio', a).eq('periodo', p).order('estudiante_id').order('asignatura_id')),
    all(() => (porClase() ? db.from('asistencia_clase').select('estudiante_id,fecha,asignatura_id') : db.from('asistencia').select('estudiante_id,fecha')).eq('colegio_id', c).eq('estado', 'A').gte('fecha', `${a}-01-01`).lte('fecha', `${a}-12-31`).order('estudiante_id').order('fecha')),
    all(() => db.from('observador').select('id,estudiante_id,tipo').eq('colegio_id', c).eq('anio', a).order('id')),
  ]);
  acad.notas = ns;
  const fa = {}, cv = {};
  as.forEach(x => fa[x.estudiante_id] = (fa[x.estudiante_id] || 0) + 1);
  ob.filter(o => o.tipo === 'Convivencia' || o.tipo === 'Citación a acudiente').forEach(o => cv[o.estudiante_id] = (cv[o.estudiante_id] || 0) + 1);
  const porEst = {};
  ns.forEach(n => (porEst[n.estudiante_id] ||= []).push(+n.valor));
  acad.filas = S.ests.filter(e => e.estado === 'Activo' && grupo(e.grupo_id) && grupo(e.grupo_id).nivel !== 'preescolar').map(e => {
    const v = porEst[e.id] || [];
    return { e, g: grupo(e.grupo_id), prom: v.length ? v.reduce((s, x) => s + x, 0) / v.length : null, bajo: v.filter(x => desem(x) === 'Bajo').length, fallas: fa[e.id] || 0, conv: cv[e.id] || 0, n: v.length };
  });
}
function correlacion(xs, ys) {
  const n = xs.length; if (n < 5) return null;
  const mx = xs.reduce((a, b) => a + b, 0) / n, my = ys.reduce((a, b) => a + b, 0) / n;
  let sxy = 0, sx = 0, sy = 0; for (let i = 0; i < n; i++) { const dx = xs[i] - mx, dy = ys[i] - my; sxy += dx * dy; sx += dx * dx; sy += dy * dy; }
  return sx && sy ? sxy / Math.sqrt(sx * sy) : null;
}
function lecturaR(r, vx, vy) {
  if (r == null) return 'No hay suficientes datos para comparar (se necesitan al menos 5 estudiantes con datos).';
  const f = Math.abs(r) >= 0.6 ? 'fuerte' : Math.abs(r) >= 0.3 ? 'moderada' : 'débil o nula';
  const sentido = r > 0 ? `cuando sube "${VARS[vx].toLowerCase()}" también tiende a subir "${VARS[vy].toLowerCase()}"` : `cuando sube "${VARS[vx].toLowerCase()}" tiende a bajar "${VARS[vy].toLowerCase()}"`;
  return `Relación ${f} (coeficiente ${r.toFixed(2)})${Math.abs(r) >= 0.3 ? `: ${sentido}` : ': las dos variables no se mueven juntas de forma clara'}. Una relación no prueba que una cosa cause la otra; sirve para decidir a quién acompañar primero.`;
}
function dispersionSVG(pts, vx, vy) {
  const W = 640, H = 360, L = 52, B = 40, T = 14, R = 16;
  const xs = pts.map(p => p.x), ys = pts.map(p => p.y);
  const rango = (v, k) => { let lo = Math.min(...v), hi = Math.max(...v); if (k === 'prom') { lo = Math.min(lo, escala().length ? Math.min(...escala().map(s => s.min)) : 1); hi = Math.max(hi, notaTope()); } else { lo = 0; hi = Math.max(hi, 4); } if (hi === lo) hi = lo + 1; return [lo, hi]; };
  const [x0, x1] = rango(xs, vx), [y0, y1] = rango(ys, vy);
  const sx = v => L + (v - x0) / (x1 - x0) * (W - L - R), sy = v => H - B - (v - y0) / (y1 - y0) * (H - B - T);
  const ticks = (a, b, k) => { if (k !== 'prom') { const st = Math.max(1, Math.ceil((b - a) / 5)); const r = []; for (let v = a; v <= b + 1e-9; v += st) r.push(v); return r; } const st = (b - a) / 5; return Array.from({ length: 6 }, (_, i) => a + st * i); };
  const fmt = (v, k) => Math.round(v);
  const color = p => p.alerta ? 'var(--red)' : 'var(--pen)';
  const jit = (i, k) => k === 'prom' ? 0 : ((i * 37) % 9 - 4) * 0.035 * (k === 'x' ? (x1 - x0) / 10 : (y1 - y0) / 10);
  return `<svg class="graf" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(VARS[vx])} frente a ${esc(VARS[vy])}">
    ${ticks(y0, y1, vy).map(v => `<line x1="${L}" x2="${W - R}" y1="${sy(v)}" y2="${sy(v)}" class="g-grid"/><text x="${L - 6}" y="${sy(v) + 4}" text-anchor="end" class="g-t">${fmt(v, vy)}</text>`).join('')}
    ${ticks(x0, x1, vx).map(v => `<text x="${sx(v)}" y="${H - B + 16}" text-anchor="middle" class="g-t">${fmt(v, vx)}</text>`).join('')}
    <line x1="${L}" x2="${W - R}" y1="${H - B}" y2="${H - B}" class="g-ax"/><line x1="${L}" x2="${L}" y1="${T}" y2="${H - B}" class="g-ax"/>
    <text x="${(L + W - R) / 2}" y="${H - 4}" text-anchor="middle" class="g-l">${esc(VARS[vx])}</text>
    <text transform="translate(14 ${(T + H - B) / 2}) rotate(-90)" text-anchor="middle" class="g-l">${esc(VARS[vy])}</text>
    ${pts.map((p, i) => `<circle cx="${sx(p.x + (vx === 'prom' ? 0 : jit(i, 'x')))}" cy="${sy(p.y + (vy === 'prom' ? 0 : jit(i + 3, 'y')))}" r="5" fill="${color(p)}" fill-opacity=".7"><title>${esc(nom(p.e))} (${esc(p.g.nombre)}): ${esc(VARS[vx])} ${fmt(p.x, vx)}, ${esc(VARS[vy])} ${fmt(p.y, vy)}</title></circle>`).join('')}
  </svg>`;
}
function barrasSVG(filas) {
  const W = 640, fila = 26, L = 150, R = 70, H = filas.length * fila + 10, max = Math.max(notaTope(), ...filas.map(f => f.v));
  return `<svg class="graf" viewBox="0 0 ${W} ${H}" role="img" aria-label="Promedio por curso">${filas.map((f, i) => { const w = f.v / max * (W - L - R), y = i * fila + 4;
    return `<text x="${L - 8}" y="${y + 15}" text-anchor="end" class="g-t">${esc(f.l)}</text><rect x="${L}" y="${y}" width="${Math.max(2, w)}" height="18" rx="3" fill="${desem(f.v) === 'Bajo' ? 'var(--red)' : 'var(--pencil)'}"/><text x="${L + w + 6}" y="${y + 15}" class="g-t">${N(f.v)}${f.extra ? ` · ${f.extra}` : ''}</text>`; }).join('')}</svg>`;
}
function acGraficos() {
  const vx = VARS[sel.gvx] ? sel.gvx : (sel.gvx = 'fallas'), vy = VARS[sel.gvy] ? sel.gvy : (sel.gvy = 'prom');
  const filas = (acad.filas || []).filter(f => !sel.ggr || f.g.id === sel.ggr);
  const academica = k => k === 'prom' || k === 'bajo';
  const pts = filas.filter(f => (!academica(vx) && !academica(vy)) || f.n > 0).filter(f => (vx !== 'prom' || f.prom != null) && (vy !== 'prom' || f.prom != null)).map(f => ({ ...f, x: f[vx], y: f[vy], alerta: f.bajo >= (S.k.max_perdidas || 3) }));
  const r = vx === vy ? null : correlacion(pts.map(p => p.x), pts.map(p => p.y));
  const cursos = S.grupos.filter(g => g.nivel !== 'preescolar').map(g => { const l = (acad.filas || []).filter(f => f.g.id === g.id && f.prom != null); return { g, l }; }).filter(x => x.l.length);
  const barras = cursos.map(({ g, l }) => ({ l: g.nombre, v: l.reduce((s, f) => s + f.prom, 0) / l.length, extra: `${l.filter(f => f.bajo > 0).length} con alguna en bajo` }));
  // Mapa de calor curso × asignatura
  const asigsAll = [...new Map(S.grupos.filter(g => g.nivel !== 'preescolar').flatMap(g => asigsDe(g)).map(a => [a.nombre, a])).values()];
  const prCelda = (g, nomA) => { const a = asigsDe(g).find(x => x.nombre === nomA); if (!a) return null; const ids = new Set(estsDe(g.id).map(e => e.id)); const v = acad.notas.filter(n => n.asignatura_id === a.id && ids.has(n.estudiante_id)).map(n => +n.valor); return v.length ? v.reduce((s, x) => s + x, 0) / v.length : null; };
  const celda = v => v == null ? '<td class="muted">—</td>' : `<td class="hm hm-${desem(v)}">${N(v)}</td>`;
  const riesgo = (acad.filas || []).filter(f => (f.bajo >= (S.k.max_perdidas || 3) ? 1 : 0) + (f.fallas >= 10 ? 1 : 0) + (f.conv >= 2 ? 1 : 0) >= 2).sort((a, b) => b.bajo - a.bajo || b.fallas - a.fallas);
  const selV = (id, v) => `<select onchange="sel.${id}=this.value;render()">${Object.entries(VARS).map(([k, l]) => opt(k, l, v)).join('')}</select>`;
  return `<div class="panel"><div class="toolbar">${selPerAc(false)}<label class="field"><span>Curso</span><select onchange="sel.ggr=this.value;render()"><option value="">Todo el colegio</option>${cursos.map(({ g }) => opt(g.id, g.nombre, sel.ggr)).join('')}</select></label>
      <button class="btn ghost" type="button" style="margin-left:auto" onclick="imprimirGraficos()">Imprimir</button></div></div>
    <section class="panel"><h2>Cruce de dos variables</h2><div class="toolbar"><label class="field"><span>Eje horizontal</span>${selV('gvx', vx)}</label><label class="field"><span>Eje vertical</span>${selV('gvy', vy)}</label></div>
      ${pts.length ? dispersionSVG(pts, vx, vy) : `<p class="empty">Aún no hay calificaciones en el periodo ${acad.p}. Elija otro periodo o cruce fallas con convivencia.</p>`}
      <p class="muted">Cada punto es un estudiante (pase el cursor o toque para ver quién es). En rojo, los que tienen ${S.k.max_perdidas || 3} o más asignaturas en bajo.</p>
      ${vx !== vy && pts.length ? `<p class="note">${lecturaR(r, vx, vy)}</p>` : ''}</section>
    <section class="panel"><h2>Estudiantes que coinciden en dos o más alertas</h2><p class="muted">Alertas: ${S.k.max_perdidas || 3} o más asignaturas en bajo, 10 o más fallas en el año, 2 o más anotaciones de convivencia.</p>
      ${riesgo.length ? `<div class="tbl"><table><thead><tr><th>Estudiante</th><th>Curso</th><th>En bajo</th><th>Fallas</th><th>Convivencia</th></tr></thead><tbody>${riesgo.map(f => `<tr><td>${esc(nom(f.e))}</td><td>${esc(f.g.nombre)}</td><td>${f.bajo}</td><td>${f.fallas}</td><td>${f.conv}</td></tr>`).join('')}</tbody></table></div>` : '<p class="muted">Ningún estudiante coincide en dos alertas.</p>'}</section>
    <section class="panel"><h2>Promedio por curso</h2>${barras.length ? barrasSVG(barras) : '<p class="empty">Sin datos.</p>'}</section>
    <section class="panel"><h2>Promedio por curso y asignatura</h2><p class="muted">Los colores siguen la escala de desempeño del colegio. Muestra dónde se concentran las dificultades.</p>
      ${cursos.length ? `<div class="tbl"><table class="heat"><thead><tr><th>Curso</th>${asigsAll.map(a => `<th title="${esc(a.nombre)}">${esc(abrev(a.nombre))}</th>`).join('')}</tr></thead><tbody>
        ${cursos.map(({ g }) => `<tr><td><strong>${esc(g.nombre)}</strong></td>${asigsAll.map(a => celda(prCelda(g, a.nombre))).join('')}</tr>`).join('')}</tbody></table></div>` : '<p class="empty">Sin datos.</p>'}</section>`;
}
function imprimirGraficos() {
  const html = $('#view').innerHTML.split('<section class="panel">').slice(1).map(s => '<div>' + s.replace(/<\/section>[\s\S]*$/, '') + '</div>').join('');
  showDocs(`<section class="doc">${docHead('Gráficos y cruces de variables', `Periodo ${acad.p}, año ${S.k.anio}${sel.ggr ? ' · ' + esc(grupo(sel.ggr)?.nombre || '') : ''}`)}<div class="doc-graf">${html.replace(/<div class="toolbar">[\s\S]*?<\/div>/g, '').replace(/<select[\s\S]*?<\/select>/g, '')}</div></section>`, 'Gráficos', `Graficos periodo ${acad.p}`);
}

/* =====================================================================
   Campus virtual (entrega 2, como el de AcademIA) y gemas
   ===================================================================== */
const isEst = () => ctx && ctx.rol === 'estudiante';
const campusOn = () => !!S?.k?.campus_activo;
const campusGrado = g => !!g && campusOn() && (!(S.k.campus_grados || []).length || S.k.campus_grados.includes(g.grado));
const gemasOn = () => S?.k?.gemas_activas !== false;
function verCampus() {
  if (!campusOn()) return false;
  if (isDir()) return true;
  if (isDoc()) return gruposVis().some(campusGrado);
  if (isFam()) { const e = est(propio()); return campusGrado(e && grupo(e.grupo_id)); }
  return false;
}
const TIPO_IT = { recurso: ['📄', 'Recurso o lectura'], video: ['🎬', 'Video'], clase: ['🎥', 'Clase en vivo'], tarea: ['📝', 'Tarea'], cuestionario: ['❓', 'Cuestionario'] };
const RANGOS = [[0, 'Semilla', '🌱'], [50, 'Cuarzo', '💠'], [150, 'Amatista', '🟣'], [350, 'Esmeralda', '💚'], [700, 'Rubí', '❤️'], [1200, 'Zafiro', '🔷'], [2000, 'Diamante', '💎'], [3500, 'Leyenda', '👑']];
function rango(t) {
  let i = 0; RANGOS.forEach((r, k) => { if (t >= r[0]) i = k; });
  const sig = RANGOS[i + 1];
  return { n: RANGOS[i][1], ico: RANGOS[i][2], sig: sig ? sig[1] : null, sigIco: sig ? sig[2] : '', faltan: sig ? sig[0] - t : 0, pct: sig ? Math.round((t - RANGOS[i][0]) / (sig[0] - RANGOS[i][0]) * 100) : 100 };
}
const MOTIVO_G = { entrada: 'Entró al campus', racha: 'Cinco días seguidos', recurso: 'Abrió un recurso', tarea: 'Entregó una tarea', cuestionario: 'Respondió un cuestionario', excelente: 'Calificación excelente', felicitacion: 'Felicitación del observador', positiva: 'Anotación positiva', participacion: 'Participación en clase' };
const fechaHoraTxt = f => f ? new Date(f).toLocaleString('es-CO', { weekday: 'short', day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit', timeZone: 'America/Bogota' }) : '';
const aLocal = f => { if (!f) return ''; const d = new Date(new Date(f).getTime() - 5 * 3600e3); return d.toISOString().slice(0, 16); };   // hora de Colombia para el campo de fecha
const deLocal = v => v ? v + ':00-05:00' : null;
const vencido = it => it.fecha && new Date(it.fecha) < new Date();

// ---------- Carga de datos ----------
const CAM = { uns: [], its: [], ent: {}, vis: new Set(), cnt: {}, pend: [], gem: null };
async function cargarCampusFam() {
  const e = est(propio()); if (!e || !campusGrado(grupo(e.grupo_id)) || !alDia()) { CAM.uns = []; CAM.its = []; CAM.pend = []; S.camPend = 0; return; }
  CAM.uns = await q(db.from('campus_unidades').select('*').eq('grupo_id', e.grupo_id).eq('anio', S.k.anio).order('periodo').order('orden').order('creado_en'));
  CAM.its = CAM.uns.length ? await q(db.from('campus_items').select('*').in('unidad_id', CAM.uns.map(u => u.id)).order('orden').order('creado_en')) : [];
  const ids = CAM.its.map(i => i.id);
  const [en, vi] = ids.length ? await Promise.all([
    q(db.from('campus_entregas').select('*').eq('estudiante_id', e.id).in('item_id', ids)),
    q(db.from('campus_vistos').select('item_id').eq('estudiante_id', e.id).in('item_id', ids))]) : [[], []];
  CAM.ent = {}; en.forEach(x => CAM.ent[x.item_id] = x); CAM.vis = new Set(vi.map(x => x.item_id));
  CAM.pend = CAM.its.filter(i => ['tarea', 'cuestionario'].includes(i.tipo) && pendienteFam(i)).sort((a, b) => String(a.fecha || '9').localeCompare(String(b.fecha || '9')));
  S.camPend = CAM.pend.filter(i => !vencido(i)).length;
}
function pendienteFam(i) {
  const x = CAM.ent[i.id];
  if (i.tipo === 'tarea') return !x;
  if (i.tipo === 'cuestionario') return !x && i.n_preg > 0;
  return false;
}
async function cargarCampusStaff() {
  const g = grupo(sel.cg); if (!g) return;
  CAM.uns = await q(db.from('campus_unidades').select('*').eq('grupo_id', g.id).eq('asignatura_id', sel.ca).eq('anio', S.k.anio).order('orden').order('creado_en'));
  CAM.its = CAM.uns.length ? await q(db.from('campus_items').select('*').in('unidad_id', CAM.uns.map(u => u.id)).order('orden').order('creado_en')) : [];
  const ids = CAM.its.map(i => i.id); CAM.cnt = {};
  if (ids.length) {
    const [en, vi] = await Promise.all([all(() => db.from('campus_entregas').select('item_id,estado').in('item_id', ids).order('id')), all(() => db.from('campus_vistos').select('item_id').in('item_id', ids).order('item_id').order('estudiante_id'))]);
    en.forEach(x => { const c = CAM.cnt[x.item_id] ||= { ent: 0, cal: 0, vis: 0 }; c.ent++; if (x.estado === 'Calificada') c.cal++; });
    vi.forEach(x => { (CAM.cnt[x.item_id] ||= { ent: 0, cal: 0, vis: 0 }).vis++; });
  }
}
async function prepCampus() {
  if (isFam()) { await cargarCampusFam(); if (!sel.cp) sel.cp = S.k.periodo_actual; return; }
  const gs = gruposVis().filter(campusGrado); if (!gs.length) return;
  if (!sel.cg || !gs.find(g => g.id === sel.cg)) sel.cg = gs[0].id;
  const as = asigsVis(grupo(sel.cg)); if (!as.find(a => a.id === sel.ca)) sel.ca = as[0]?.id || '';
  if (!sel.cp) sel.cp = S.k.periodo_actual;
  await cargarCampusStaff();
}
async function campusSel(k, v) { sel[k] = k === 'cp' ? +v : v; if (k === 'cg') sel.ca = ''; $('#view').innerHTML = '<div class="loading">Cargando…</div>'; await guard(prepCampus); render(); }

// ---------- Pantalla del campus ----------
function vCampus() {
  if (!campusOn()) return head('Campus virtual') + '<div class="panel empty">El campus virtual no está activo en el colegio.</div>';
  return isFam() ? vCampusFam() : vCampusStaff();
}
function estadoItemFam(i) {
  const x = CAM.ent[i.id];
  if (i.tipo === 'tarea') return x?.estado === 'Calificada' ? `<span class="tag ok-t">Calificada: ${N(x.nota)}</span>` : x ? '<span class="tag ent-t">Entregada</span>' : vencido(i) ? '<span class="tag t3">Fecha vencida</span>' : '<span class="tag t2">Por entregar</span>';
  if (i.tipo === 'cuestionario') return x ? `<span class="tag ok-t">Calificación: ${N(x.nota)}</span>` : vencido(i) ? '<span class="tag t3">Cerrado</span>' : i.n_preg ? '<span class="tag t2">Por responder</span>' : '<span class="tag">En preparación</span>';
  return CAM.vis.has(i.id) ? '<span class="tag ok-t">✓ Visto</span>' : '<span class="tag nuevo-t">Nuevo</span>';
}
function itemFamHTML(i, conAsig) {
  const [ico, tl] = TIPO_IT[i.tipo], u = CAM.uns.find(x => x.id === i.unidad_id), a = S.asigs.find(x => x.id === u?.asignatura_id);
  const meta = [conAsig && a ? esc(a.nombre) : '', tl, i.fecha ? (i.tipo === 'clase' ? 'Clase: ' : 'Hasta: ') + fechaHoraTxt(i.fecha) : ''].filter(Boolean).join(' · ');
  const btn = i.tipo === 'tarea' ? 'Ver tarea' : i.tipo === 'cuestionario' ? (CAM.ent[i.id] ? 'Ver resultado' : 'Responder') : i.tipo === 'clase' ? 'Entrar a la clase' : 'Abrir';
  return `<li class="cam-it"><span class="cam-ico" aria-hidden="true">${ico}</span><div class="cam-tx"><strong>${esc(i.titulo)}</strong><br><span class="muted">${meta}</span></div>
    <div class="cam-ac">${estadoItemFam(i)}<button class="btn sm" type="button" onclick="abrirItem('${i.id}')">${btn}</button></div></li>`;
}
function vCampusFam() {
  const e = est(propio()), g = grupo(e?.grupo_id);
  if (!e || !g) return head('Campus virtual') + '<div class="panel empty">El estudiante aún no tiene curso asignado.</div>';
  if (!campusGrado(g)) return head('Campus virtual') + `<div class="panel empty">El campus virtual todavía no está activo para ${esc(gradoTxt(g.grado))}.</div>`;
  const asIds = [...new Set(CAM.uns.map(u => u.asignatura_id))], as = asigsDe(g).filter(a => asIds.includes(a.id));
  if (!sel.cfa || !as.find(a => a.id === sel.cfa)) sel.cfa = 'todas';
  const pend = CAM.pend.filter(i => !vencido(i)), clases = CAM.its.filter(i => i.tipo === 'clase' && i.fecha && new Date(i.fecha) > new Date(Date.now() - 2 * 3600e3)).sort((a, b) => a.fecha.localeCompare(b.fecha)).slice(0, 3);
  const uns = CAM.uns.filter(u => u.periodo === +sel.cp && (sel.cfa === 'todas' || u.asignatura_id === sel.cfa));
  const quien = isEst() ? 'usted' : esc(e.nombres);
  return head(isEst() ? `Mi campus virtual` : `Campus virtual de ${esc(e.nombres)}`, `${esc(g.nombre)} · Clases, recursos, tareas y evaluaciones de cada asignatura.`) +
    (gemasOn() ? `<div class="note gem-note">💎 Cada vez que ${quien} entra, abre un recurso, entrega una tarea o responde un cuestionario gana gemas. <button class="linkbtn" type="button" onclick="go('gemas')">Ver gemas y top del curso</button></div>` : '') +
    `<div class="cols"><section class="panel"><h2>Pendientes${pend.length ? ` (${pend.length})` : ''}</h2>${pend.length ? `<ul class="list cam-list">${pend.slice(0, 6).map(i => itemFamHTML(i, true)).join('')}</ul>` : '<p class="muted">¡Al día! No hay tareas ni cuestionarios por hacer.</p>'}</section>
      <section class="panel"><h2>Próximas clases en vivo</h2>${clases.length ? `<ul class="list cam-list">${clases.map(i => itemFamHTML(i, true)).join('')}</ul>` : '<p class="muted">No hay clases en vivo programadas.</p>'}</section></div>
    <div class="panel"><div class="toolbar"><label class="field"><span>Asignatura</span><select onchange="sel.cfa=this.value;render()">${opt('todas', 'Todas las asignaturas', sel.cfa)}${as.map(a => opt(a.id, a.nombre, sel.cfa)).join('')}</select></label>
      <label class="field"><span>Periodo</span><select onchange="sel.cp=+this.value;render()">${perOpts(sel.cp)}</select></label></div>
      ${uns.length ? uns.map(u => { const its = CAM.its.filter(i => i.unidad_id === u.id), a = S.asigs.find(x => x.id === u.asignatura_id);
        return `<section class="cam-unidad"><h3><span class="tag">${esc(a?.nombre || '')}</span> ${esc(u.titulo)}</h3>${u.descripcion ? `<p class="muted">${esc(u.descripcion)}</p>` : ''}
          ${its.length ? `<ul class="list cam-list">${its.map(i => itemFamHTML(i)).join('')}</ul>` : '<p class="muted">Esta unidad aún no tiene contenidos.</p>'}</section>`; }).join('')
      : `<p class="empty">No hay unidades publicadas en el periodo ${sel.cp}${sel.cfa !== 'todas' ? ' para esta asignatura' : ''}.</p>`}</div>`;
}
async function gemasToast(n, por) { if (n > 0 && gemasOn()) toast(`+${n} gemas 💎 ${por || ''}`.trim()); }
async function abrirItem(id) {
  const i = CAM.its.find(x => x.id === id); if (!i) return;
  if (i.tipo === 'tarea') return formTareaFam(i);
  if (i.tipo === 'cuestionario') return abrirCuestionario(i);
  const w = i.url ? window.open(i.url, '_blank', 'noopener') : null;
  if (!i.url || !w) openModal(i.titulo, `${i.fecha ? `<p><strong>${i.tipo === 'clase' ? 'Fecha de la clase' : 'Fecha'}:</strong> ${fechaHoraTxt(i.fecha)}</p>` : ''}${i.texto ? `<p style="white-space:pre-wrap">${esc(i.texto)}</p>` : ''}
    ${i.url ? `<p><a class="btn" href="${esc(i.url)}" target="_blank" rel="noopener">Abrir enlace</a></p>` : ''}<div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cerrar</button></div>`);
  const n = await guard(() => q(db.rpc('campus_abrir', { p_item: id, p_est: propio() })));
  if (n !== undefined) { CAM.vis.add(id); gemasToast(n, 'por abrir el recurso'); if (view === 'campus') render(); }
}
function formTareaFam(i) {
  const x = CAM.ent[i.id], cal = x?.estado === 'Calificada';
  openModal(i.titulo, `${i.fecha ? `<p><strong>Fecha límite:</strong> ${fechaHoraTxt(i.fecha)}${vencido(i) && !x ? ' <span class="tag t3">Vencida: todavía puede entregarla, quedará como tardía</span>' : ''}</p>` : ''}
    ${i.texto ? `<div class="note" style="white-space:pre-wrap">${esc(i.texto)}</div>` : ''}${i.url ? `<p><a href="${esc(i.url)}" target="_blank" rel="noopener">Material de apoyo</a></p>` : ''}
    ${cal ? `<div class="panel"><h3>Calificación: ${chip(x.nota)}</h3>${x.comentario ? `<p><strong>Comentario del docente:</strong> ${esc(x.comentario)}</p>` : ''}<p class="muted">Entregada el ${fechaHoraTxt(x.entregado_en) || '—'}</p></div>` :
    `${x ? `<p class="ok">✓ Entregada el ${fechaHoraTxt(x.entregado_en)}. Puede corregirla mientras el docente no la califique.</p>` : ''}
    <label class="field full"><span>Su respuesta</span><textarea id="tTx" rows="6" maxlength="4000" placeholder="Escriba aquí su respuesta">${esc(x?.texto || '')}</textarea></label>
    ${fIn('tUrl', 'Enlace a su trabajo (opcional: Google Drive, foto, documento)', x?.url || '', 'maxlength="500" placeholder="https://"')}`}
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cerrar</button>${cal ? '' : `<button class="btn" type="button" id="tBtn" onclick="entregarTarea('${i.id}')">${x ? 'Guardar cambios' : 'Entregar tarea'}</button>`}</div>`);
}
async function entregarTarea(id) {
  const t = vv('tTx'), u = vv('tUrl');
  if (!t && !u) return toast('Escriba su respuesta o pegue el enlace de su trabajo');
  let url = u; if (u) { url = normUrl(u); if (!url) return toast('El enlace no parece válido. Cópielo completo desde el navegador'); }
  const n = await busy('#tBtn', () => guard(() => q(db.rpc('campus_entregar', { p_item: id, p_est: propio(), p_texto: t, p_url: url }))));
  if (n === undefined) return;
  closeModal(); toast(n > 0 && gemasOn() ? `Tarea entregada. +${n} gemas 💎` : 'Tarea guardada');
  await guard(cargarCampusFam); render();
}
let quiz = null;
async function abrirCuestionario(i) {
  const d = await guard(() => q(db.rpc('campus_cuestionario', { p_item: i.id, p_est: propio() }))); if (!d) return;
  quiz = { i, d };
  const quedan = d.intentos - d.usados, cerrado = vencido(i);
  const info = `${i.texto ? `<div class="note" style="white-space:pre-wrap">${esc(i.texto)}</div>` : ''}<p class="muted">${d.preguntas.length} preguntas · ${d.intentos === 1 ? 'un intento' : d.intentos + ' intentos (queda la mejor calificación)'}${i.fecha ? ' · hasta ' + fechaHoraTxt(i.fecha) : ''}</p>`;
  if (d.usados && (quedan <= 0 || cerrado)) return openModal(i.titulo, `${info}<div class="panel"><h3>Su calificación: ${chip(d.nota)}</h3><p class="muted">${quedan <= 0 ? 'Ya usó todos los intentos.' : 'El cuestionario ya cerró.'}</p></div><div class="modal-foot"><button class="btn" type="button" onclick="closeModal()">Cerrar</button></div>`);
  if (cerrado) return openModal(i.titulo, `${info}<p class="empty">El cuestionario cerró el ${fechaHoraTxt(i.fecha)}.</p><div class="modal-foot"><button class="btn" type="button" onclick="closeModal()">Cerrar</button></div>`);
  if (!d.preguntas.length) return openModal(i.titulo, `${info}<p class="empty">El docente aún está preparando las preguntas.</p><div class="modal-foot"><button class="btn" type="button" onclick="closeModal()">Cerrar</button></div>`);
  openModal(i.titulo, `${info}${d.usados ? `<p>Su mejor calificación hasta ahora: ${chip(d.nota)}. Le ${quedan === 1 ? 'queda 1 intento' : 'quedan ' + quedan + ' intentos'}.</p>` : ''}
    <ol class="quiz">${d.preguntas.map((p, k) => `<li class="qz"><p><strong>${esc(p.q)}</strong> <span class="muted">(${p.pts} ${p.pts === 1 ? 'punto' : 'puntos'})</span></p>${preguntaHTML(p, k)}</li>`).join('')}</ol>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" id="qBtn" onclick="enviarCuestionario()">Enviar respuestas</button></div>`);
}
function preguntaHTML(p, k) {
  if (p.t === 'om') return `<div class="qz-op">${p.o.map((o, j) => `<label class="chk"><input type="radio" name="qz${k}" value="${j}"> ${esc(o)}</label>`).join('')}</div>`;
  if (p.t === 'vf') return `<div class="qz-op"><label class="chk"><input type="radio" name="qz${k}" value="true"> Verdadero</label><label class="chk"><input type="radio" name="qz${k}" value="false"> Falso</label></div>`;
  if (p.t === 'corta') return `<input id="qz${k}" maxlength="200" placeholder="Escriba su respuesta" style="width:100%">`;
  return `<table class="qz-emp"><tbody>${p.izq.map((l, j) => `<tr><td>${esc(l)}</td><td><select id="qz${k}_${j}"><option value="">Elija…</option>${p.der.map(r => opt(r, r)).join('')}</select></td></tr>`).join('')}</tbody></table>`;
}
async function enviarCuestionario() {
  const ps = quiz.d.preguntas; let vacias = 0;
  const resp = ps.map((p, k) => {
    if (p.t === 'om') { const r = document.querySelector(`input[name="qz${k}"]:checked`); if (!r) vacias++; return r ? +r.value : null; }
    if (p.t === 'vf') { const r = document.querySelector(`input[name="qz${k}"]:checked`); if (!r) vacias++; return r ? r.value === 'true' : null; }
    if (p.t === 'corta') { const v = $('#qz' + k).value.trim(); if (!v) vacias++; return v || null; }
    const r = p.izq.map((_, j) => $(`#qz${k}_${j}`).value); if (r.some(x => !x)) vacias++; return r;
  });
  if (vacias && !(await confirmar(`Tiene ${vacias === 1 ? 'una pregunta' : vacias + ' preguntas'} sin responder. ¿Enviar de todas formas?`, 'Enviar'))) return;
  const r = await busy('#qBtn', () => guard(() => q(db.rpc('campus_responder', { p_item: quiz.i.id, p_est: propio(), p_resp: resp }))));
  if (!r) return;
  openModal(quiz.i.titulo, `<div class="cam-res"><div class="cam-nota">${N(r.nota)}</div><p><strong>${r.correctas} de ${r.total}</strong> preguntas correctas · ${desem(r.nota)}</p>
    ${r.mejor > r.nota ? `<p class="muted">Se conserva su mejor calificación: ${N(r.mejor)}.</p>` : ''}${r.gemas && gemasOn() ? `<p class="gem-win">+${r.gemas} gemas 💎</p>` : ''}
    <ol class="qz-det">${r.detalle.map((ok, k) => `<li class="${ok ? 'ok' : 'err'}">${ok ? '✓' : '✗'} ${esc(ps[k].q)}</li>`).join('')}</ol>
    ${r.quedan ? `<p class="muted">Le ${r.quedan === 1 ? 'queda 1 intento' : 'quedan ' + r.quedan + ' intentos'} para mejorar.</p>` : ''}</div>
    <div class="modal-foot"><button class="btn" type="button" onclick="closeModal()">Listo</button></div>`);
  await guard(cargarCampusFam); render();
}

// ---------- Campus del docente y directivos ----------
function vCampusStaff() {
  const gs = gruposVis().filter(campusGrado);
  if (!gs.length) return head('Campus virtual') + `<div class="panel empty">${isDir() ? 'El campus está activo, pero ningún curso está en los grados habilitados. Revíselo en Parametrización › Campus y gemas.' : 'Ninguno de sus cursos tiene el campus virtual activo.'}</div>`;
  const g = grupo(sel.cg), as = asigsVis(g), a = as.find(x => x.id === sel.ca);
  const edita = isDir() || (isDoc() && S.misGrupos.includes(g.id) && (!S.misAsig[g.id] || S.misAsig[g.id].includes(sel.ca)));
  const uns = CAM.uns.filter(u => u.periodo === +sel.cp), nEst = estsDe(g.id).length;
  return head('Campus virtual', 'Arme cada unidad con recursos, videos, clases en vivo, tareas y cuestionarios. Las calificaciones de tareas y cuestionarios pasan solas a Calificaciones como actividades del periodo.') +
    `<div class="panel"><div class="toolbar"><label class="field"><span>Curso</span><select onchange="campusSel('cg',this.value)">${gs.map(x => opt(x.id, x.nombre, sel.cg)).join('')}</select></label>
      <label class="field"><span>${g.nivel === 'preescolar' ? 'Dimensión' : 'Asignatura'}</span><select onchange="campusSel('ca',this.value)">${as.map(x => opt(x.id, x.nombre, sel.ca)).join('')}</select></label>
      <label class="field"><span>Periodo</span><select onchange="sel.cp=+this.value;render()">${perOpts(sel.cp)}</select></label>
      ${edita ? `<button class="btn" type="button" style="margin-left:auto" onclick="formUnidad()">+ Nueva unidad</button>` : ''}</div>
      ${!a ? '<p class="empty">No hay asignaturas para este curso.</p>' : uns.length ? uns.map(u => unidadStaffHTML(u, edita, nEst)).join('')
        : `<div class="empty">Aún no hay unidades en el periodo ${sel.cp}.${edita ? ' Oprima <strong>+ Nueva unidad</strong> y luego agregue sus contenidos.' : ''}</div>`}</div>
    ${edita ? `<div class="note"><strong>¿Cómo funciona?</strong> 1) Cree una unidad. 2) Agregue contenidos: recursos y videos (con su enlace), clases en vivo (enlace de Meet, Zoom o Teams), tareas y cuestionarios.
      3) Los estudiantes de ${esc(g.nombre)} los ven en su campus y ganan gemas al participar. 4) Califique las tareas en <em>Entregas</em>; los cuestionarios se califican solos.</div>` : ''}`;
}
function unidadStaffHTML(u, edita, nEst) {
  const its = CAM.its.filter(i => i.unidad_id === u.id);
  return `<section class="cam-unidad"><div class="cam-uh"><h3>${esc(u.titulo)} ${u.visible ? '' : '<span class="tag">Oculta para los estudiantes</span>'}</h3>
    ${edita ? `<div class="toolbar"><button class="btn sm" type="button" onclick="elegirTipo('${u.id}')">+ Agregar contenido</button><button class="btn ghost sm" type="button" onclick="formUnidad('${u.id}')">Editar unidad</button></div>` : ''}</div>
    ${u.descripcion ? `<p class="muted">${esc(u.descripcion)}</p>` : ''}
    ${its.length ? `<ul class="list cam-list">${its.map(i => { const [ico, tl] = TIPO_IT[i.tipo], c = CAM.cnt[i.id] || { ent: 0, cal: 0, vis: 0 };
      const cuenta = i.tipo === 'tarea' ? `Entregas: ${c.ent} de ${nEst} · Calificadas: ${c.cal}` : i.tipo === 'cuestionario' ? `${i.n_preg} preguntas · Respondieron: ${c.ent} de ${nEst}` : `Lo abrieron: ${c.vis} de ${nEst}`;
      return `<li class="cam-it"><span class="cam-ico" aria-hidden="true">${ico}</span><div class="cam-tx"><strong>${esc(i.titulo)}</strong> ${i.visible ? '' : '<span class="tag">Oculto</span>'} ${i.calificable ? '<span class="tag piar">Cuenta para calificaciones</span>' : ''}
        <br><span class="muted">${tl}${i.fecha ? ' · ' + (i.tipo === 'clase' ? 'Clase: ' : 'Hasta: ') + fechaHoraTxt(i.fecha) : ''} · ${cuenta}</span>${i.tipo === 'cuestionario' && !i.n_preg ? '<br><span class="err" style="font-weight:400">Sin preguntas: los estudiantes aún no pueden responder.</span>' : ''}</div>
        <div class="cam-ac">${i.tipo === 'cuestionario' && edita ? `<button class="btn sm" type="button" onclick="editorPreguntas('${i.id}')">Preguntas</button>` : ''}
          ${['tarea', 'cuestionario'].includes(i.tipo) ? `<button class="btn ${i.tipo === 'tarea' ? 'sm' : 'ghost sm'}" type="button" onclick="verEntregas('${i.id}')">${i.tipo === 'tarea' ? 'Entregas' : 'Resultados'}</button>` : ''}
          ${i.url && !['tarea', 'cuestionario'].includes(i.tipo) ? `<a class="btn ghost sm" href="${esc(i.url)}" target="_blank" rel="noopener">Abrir</a>` : ''}
          ${edita ? `<button class="btn ghost sm" type="button" onclick="formItem('${u.id}','${i.tipo}','${i.id}')">Editar</button>` : ''}</div></li>`; }).join('')}</ul>`
      : '<p class="muted">Sin contenidos todavía.</p>'}</section>`;
}
function formUnidad(id) {
  const u = id ? CAM.uns.find(x => x.id === id) : { titulo: `Unidad ${CAM.uns.filter(x => x.periodo === +sel.cp).length + 1}: `, descripcion: '', visible: true };
  openModal(id ? 'Editar unidad' : 'Nueva unidad', `<div class="formgrid">${fIn('uTit', 'Título de la unidad', u.titulo, 'maxlength="120"')}</div>
    ${fTa('uDes', 'Descripción (opcional)', u.descripcion, 'Qué se trabajará en esta unidad')}
    <label class="chk"><input type="checkbox" id="uVis" ${u.visible ? 'checked' : ''}> Visible para los estudiantes</label>
    <p class="muted">La unidad queda en el periodo ${sel.cp} de ${esc(S.asigs.find(a => a.id === sel.ca)?.nombre || '')}, ${esc(grupo(sel.cg)?.nombre || '')}.</p>
    <div class="modal-foot">${id ? `<button class="btn ghost" type="button" onclick="borrarUnidad('${id}')">Borrar unidad</button>` : ''}<button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" id="uBtn" onclick="guardarUnidad('${id || ''}')">Guardar</button></div>`);
}
async function guardarUnidad(id) {
  const d = { titulo: vv('uTit'), descripcion: vv('uDes') || null, visible: $('#uVis').checked };
  if (d.titulo.replace(/^Unidad \d+:\s*$/, '').length < 3) return toast('Escriba el título de la unidad');
  const r = await busy('#uBtn', () => guard(() => id ? q(db.from('campus_unidades').update(d).eq('id', id).select().single())
    : q(db.from('campus_unidades').insert({ ...d, grupo_id: sel.cg, asignatura_id: sel.ca, periodo: +sel.cp, colegio_id: ctx.colegio_id, anio: S.k.anio, orden: CAM.uns.length + 1 }).select().single()), id ? 'Unidad guardada' : 'Unidad creada. Ahora agregue sus contenidos'));
  if (!r) return; closeModal(); await guard(cargarCampusStaff); render();
}
async function borrarUnidad(id) {
  const n = CAM.its.filter(i => i.unidad_id === id).length;
  if (!(await confirmar(n ? `La unidad tiene ${n} contenidos. Se borrarán con sus entregas y las calificaciones que pasaron a Calificaciones. ¿Borrar la unidad?` : '¿Borrar la unidad?', 'Sí, borrar'))) return;
  if (await guard(() => q(db.from('campus_unidades').delete().eq('id', id)), 'Unidad borrada') !== undefined) { closeModal(); await guard(cargarCampusStaff); render(); }
}
function elegirTipo(uid) {
  const ayuda = { recurso: 'Lectura, guía, documento o página web (enlace).', video: 'Enlace de YouTube u otro sitio de videos.', clase: 'Enlace de Meet, Zoom o Teams con fecha y hora.', tarea: 'El estudiante escribe su respuesta o envía un enlace. Usted la califica.', cuestionario: 'Preguntas de opción múltiple, verdadero o falso, emparejamiento o respuesta corta. Se califica solo.' };
  openModal('Agregar contenido', `<div class="tipos-cam">${Object.entries(TIPO_IT).map(([t, [ico, l]]) => `<button type="button" class="tipo-cam" onclick="formItem('${uid}','${t}')"><span>${ico}</span><strong>${l}</strong><small>${ayuda[t]}</small></button>`).join('')}</div>
    <div class="modal-foot"><button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button></div>`);
}
function formItem(uid, tipo, id) {
  const i = id ? CAM.its.find(x => x.id === id) : { titulo: '', texto: '', url: '', fecha: null, calificable: true, intentos: 1, visible: true };
  const [ico, tl] = TIPO_IT[tipo], conFecha = ['clase', 'tarea', 'cuestionario'].includes(tipo), cal = ['tarea', 'cuestionario'].includes(tipo);
  const lUrl = { recurso: 'Enlace del recurso (opcional si escribe el texto)', video: 'Enlace del video', clase: 'Enlace de la reunión (Meet, Zoom, Teams)', tarea: 'Material de apoyo (enlace, opcional)', cuestionario: 'Material de apoyo (enlace, opcional)' }[tipo];
  openModal(`${ico} ${id ? 'Editar' : 'Nuevo'}: ${tl.toLowerCase()}`, `<div class="formgrid">${fIn('iTit', 'Título', i.titulo, 'maxlength="120"')}
      ${conFecha ? fIn('iFec', tipo === 'clase' ? 'Fecha y hora de la clase' : 'Fecha y hora límite (opcional)', aLocal(i.fecha), 'type="datetime-local"') : ''}
      ${fIn('iUrl', lUrl, i.url, 'maxlength="500" placeholder="https://"')}
      ${tipo === 'cuestionario' ? `<label class="field"><span>Intentos permitidos</span><select id="iInt">${[1, 2, 3].map(n => opt(n, n === 1 ? '1 intento' : n + ' intentos (queda la mejor)', i.intentos)).join('')}</select></label>` : ''}</div>
    ${fTa('iTxt', tipo === 'tarea' || tipo === 'cuestionario' ? 'Instrucciones para el estudiante' : 'Descripción o texto (opcional)', i.texto, '')}
    ${cal ? `<label class="chk"><input type="checkbox" id="iCal" ${i.calificable ? 'checked' : ''}> Cuenta para calificaciones (crea una actividad del periodo ${sel.cp} en Calificaciones)</label><br>` : ''}
    <label class="chk"><input type="checkbox" id="iVis" ${i.visible ? 'checked' : ''}> Visible para los estudiantes</label>
    ${id && i.calificable ? '<p class="muted">Si quita "Cuenta para calificaciones", se borra su actividad en Calificaciones y se recalcula la calificación del periodo.</p>' : ''}
    <div class="modal-foot">${id ? `<button class="btn ghost" type="button" onclick="borrarItem('${id}')">Borrar</button>` : ''}<button class="btn ghost" type="button" onclick="closeModal()">Cancelar</button><button class="btn" type="button" id="iBtn" onclick="guardarItem('${uid}','${tipo}','${id || ''}')">${tipo === 'cuestionario' && !id ? 'Guardar y escribir preguntas' : 'Guardar'}</button></div>`);
}
async function guardarItem(uid, tipo, id) {
  const d = { titulo: vv('iTit'), texto: vv('iTxt') || null, visible: $('#iVis').checked };
  if (d.titulo.length < 3) return toast('Escriba el título');
  const u = vv('iUrl');
  if (u) { d.url = normUrl(u); if (!d.url) return toast('El enlace no parece válido. Cópielo completo desde el navegador'); } else d.url = null;
  if (tipo === 'video' && !d.url) return toast('Pegue el enlace del video');
  if (tipo === 'recurso' && !d.url && !d.texto) return toast('Pegue el enlace o escriba el texto del recurso');
  if ($('#iFec')) { d.fecha = deLocal(vv('iFec')); if (tipo === 'clase' && !d.fecha) return toast('Escriba la fecha y la hora de la clase'); }
  if ($('#iCal')) d.calificable = $('#iCal').checked;
  if ($('#iInt')) d.intentos = +$('#iInt').value;
  if (id) {
    const o = CAM.its.find(x => x.id === id);
    if (o.calificable && d.calificable === false && CAM.cnt[id]?.cal && !(await confirmar('Este contenido ya tiene calificaciones. Si deja de contar, se borran de Calificaciones y se recalcula el periodo. ¿Continuar?', 'Sí, continuar'))) return;
  }
  const r = await busy('#iBtn', () => guard(() => id ? q(db.from('campus_items').update(d).eq('id', id).select().single())
    : q(db.from('campus_items').insert({ ...d, unidad_id: uid, tipo, colegio_id: ctx.colegio_id, orden: CAM.its.filter(x => x.unidad_id === uid).length + 1 }).select().single()), 'Guardado'));
  if (!r) return; closeModal(); await guard(cargarCampusStaff);
  S.loadedG.delete(sel.cg);
  if (tipo === 'cuestionario' && !id) return editorPreguntas(r.id);
  render();
}
async function borrarItem(id) {
  const i = CAM.its.find(x => x.id === id), c = CAM.cnt[id];
  if (!(await confirmar(`¿Borrar "${i.titulo}"?${c?.ent ? ` Tiene ${c.ent} entregas o respuestas que también se borrarán${i.calificable ? ', y su calificación sale de Calificaciones' : ''}.` : ''}`, 'Sí, borrar'))) return;
  if (await guard(() => q(db.from('campus_items').delete().eq('id', id)), 'Borrado') !== undefined) { closeModal(); S.loadedG.delete(sel.cg); await guard(cargarCampusStaff); render(); }
}
// ---------- Editor de preguntas ----------
let QE = { id: '', ps: [] };
const TIPO_P = { om: 'Opción múltiple', vf: 'Verdadero o falso', emp: 'Emparejamiento', corta: 'Respuesta corta' };
async function editorPreguntas(id) {
  const r = await guard(() => q(db.from('campus_preguntas').select('preguntas').eq('item_id', id))); if (r === undefined) return;
  QE = { id, ps: JSON.parse(JSON.stringify(r[0]?.preguntas || [])) };
  pintarEditor();
}
function pintarEditor() {
  const i = CAM.its.find(x => x.id === QE.id), tot = QE.ps.reduce((a, p) => a + (+p.pts || 0), 0);
  openModal(`Preguntas: ${i?.titulo || ''}`, `<p class="muted">Escriba cada pregunta, marque la respuesta correcta y asigne sus puntos. La calificación se calcula sobre 100: si suma ${tot || 'X'} puntos, cada punto vale ${tot ? (100 / tot).toLocaleString('es-CO', { maximumFractionDigits: 1 }) : '—'}.</p>
    ${CAM.cnt[QE.id]?.ent ? '<div class="note">Ya hay estudiantes que respondieron. Si cambia las respuestas correctas, sus calificaciones ya registradas no cambian.</div>' : ''}
    <ol class="qe-list">${QE.ps.map((p, k) => preguntaEditHTML(p, k)).join('')}</ol>
    ${QE.ps.length ? '' : '<p class="empty">Aún no hay preguntas. Elija el tipo de la primera:</p>'}
    <div class="toolbar">${Object.entries(TIPO_P).map(([t, l]) => `<button class="btn ghost sm" type="button" onclick="agregarPregunta('${t}')">+ ${l}</button>`).join('')}</div>
    <div class="modal-foot guardar-fijo"><span class="muted" style="margin-right:auto">${QE.ps.length} preguntas · ${tot} puntos</span><button class="btn ghost" type="button" onclick="closeModal()">Cerrar sin guardar</button><button class="btn" type="button" id="qeBtn" onclick="guardarPreguntas()">Guardar preguntas</button></div>`);
}
function preguntaEditHTML(p, k) {
  let cuerpo = '';
  if (p.t === 'om') cuerpo = `<p class="muted" style="margin:6px 0">Escriba las opciones y marque la correcta:</p>${(p.o || []).map((o, j) => `<div class="qe-op"><label class="chk" title="Marcar como correcta"><input type="radio" name="qc${k}" value="${j}" ${+p.c === j ? 'checked' : ''}> Correcta</label><input class="qe-o" data-k="${k}" value="${esc(o)}" maxlength="200" placeholder="Opción ${j + 1}"></div>`).join('')}
    ${(p.o || []).length < 6 ? `<button class="linkbtn" type="button" onclick="masOpcion(${k})">+ Agregar opción</button>` : ''}`;
  if (p.t === 'vf') cuerpo = `<div class="qz-op"><label class="chk"><input type="radio" name="qc${k}" value="true" ${p.c === true ? 'checked' : ''}> Es verdadera</label><label class="chk"><input type="radio" name="qc${k}" value="false" ${p.c === false ? 'checked' : ''}> Es falsa</label></div>`;
  if (p.t === 'corta') cuerpo = `${fIn('qa' + k, 'Respuestas aceptadas (separe con punto y coma; no importan mayúsculas ni tildes)', (p.c || []).join('; '), 'maxlength="300"')}`;
  if (p.t === 'emp') cuerpo = `<p class="muted" style="margin:6px 0">Escriba cada pareja. Al estudiante le aparecen las de la derecha en desorden.</p>${(p.p || []).map((x, j) => `<div class="qe-par"><input class="qe-l" data-k="${k}" value="${esc(x[0])}" maxlength="120" placeholder="Izquierda ${j + 1}"><span>↔</span><input class="qe-r" data-k="${k}" value="${esc(x[1])}" maxlength="120" placeholder="Derecha ${j + 1}"></div>`).join('')}
    ${(p.p || []).length < 8 ? `<button class="linkbtn" type="button" onclick="masOpcion(${k})">+ Agregar pareja</button>` : ''}`;
  return `<li class="qe"><div class="qe-h"><span class="tag">${TIPO_P[p.t]}</span><label class="field qe-pts"><span>Puntos</span><input id="qp${k}" type="number" min="1" max="100" value="${esc(p.pts ?? 10)}"></label>
    <button class="linkbtn" type="button" onclick="quitarPregunta(${k})">Quitar</button></div>
    <label class="field full"><span>${p.t === 'vf' ? 'Afirmación' : 'Pregunta'}</span><textarea id="qq${k}" rows="2" maxlength="600">${esc(p.q || '')}</textarea></label>${cuerpo}</li>`;
}
function leerEditor() {
  QE.ps = QE.ps.map((p, k) => {
    const n = { t: p.t, q: ($('#qq' + k)?.value || '').trim(), pts: +($('#qp' + k)?.value || 0) };
    const c = document.querySelector(`input[name="qc${k}"]:checked`);
    if (p.t === 'om') { n.o = [...document.querySelectorAll(`.qe-o[data-k="${k}"]`)].map(x => x.value); n.c = c ? +c.value : null; }
    if (p.t === 'vf') n.c = c ? c.value === 'true' : null;
    if (p.t === 'corta') n.c = ($('#qa' + k)?.value || '').split(';').map(x => x.trim()).filter(Boolean);
    if (p.t === 'emp') { const l = [...document.querySelectorAll(`.qe-l[data-k="${k}"]`)], r = [...document.querySelectorAll(`.qe-r[data-k="${k}"]`)]; n.p = l.map((x, j) => [x.value, r[j].value]); }
    return n;
  });
}
function agregarPregunta(t) {
  leerEditor();
  QE.ps.push({ t, q: '', pts: 10, o: t === 'om' ? ['', '', '', ''] : undefined, c: t === 'corta' ? [] : null, p: t === 'emp' ? [['', ''], ['', ''], ['', '']] : undefined });
  pintarEditor(); setTimeout(() => $('#qq' + (QE.ps.length - 1))?.focus(), 30);
}
function quitarPregunta(k) { leerEditor(); QE.ps.splice(k, 1); pintarEditor(); }
function masOpcion(k) { leerEditor(); const p = QE.ps[k]; if (p.t === 'om') p.o.push(''); else p.p.push(['', '']); pintarEditor(); }
async function guardarPreguntas() {
  leerEditor();
  for (const [k, p] of QE.ps.entries()) {
    const n = k + 1;
    if (!p.q) return toast(`Escriba el enunciado de la pregunta ${n}`);
    if (!(p.pts >= 1 && p.pts <= 100)) return toast(`Los puntos de la pregunta ${n} deben estar entre 1 y 100`);
    if (p.t === 'om') { const llenas = p.o.filter(x => x.trim()).length; if (llenas < 2) return toast(`La pregunta ${n} necesita al menos 2 opciones`); if (p.c == null || !p.o[p.c]?.trim()) return toast(`Marque la opción correcta de la pregunta ${n}`); }
    if (p.t === 'vf' && p.c == null) return toast(`Marque si la afirmación ${n} es verdadera o falsa`);
    if (p.t === 'corta' && !p.c.length) return toast(`Escriba la respuesta aceptada de la pregunta ${n}`);
    if (p.t === 'emp' && p.p.filter(x => x[0].trim() && x[1].trim()).length < 2) return toast(`La pregunta ${n} necesita al menos 2 parejas completas`);
  }
  // la opción correcta se reubica si hay opciones vacías antes de ella
  const envio = QE.ps.map(p => { if (p.t !== 'om') return p; const o = []; let c = null; p.o.forEach((x, j) => { if (x.trim()) { if (j === p.c) c = o.length; o.push(x.trim()); } }); return { ...p, o, c }; });
  const r = await busy('#qeBtn', () => guard(() => q(db.rpc('campus_guardar_preguntas', { p_item: QE.id, p_preg: envio })), 'Preguntas guardadas'));
  if (r === undefined) return; closeModal(); await guard(cargarCampusStaff); render();
}
// ---------- Entregas y calificación ----------
let ENT = { id: '', l: [] };
async function verEntregas(id) {
  const i = CAM.its.find(x => x.id === id), g = grupo(sel.cg);
  const l = await guard(() => q(db.from('campus_entregas').select('*').eq('item_id', id))); if (!l) return;
  ENT = { id, l };
  const edita = isDir() || (isDoc() && S.misGrupos.includes(g.id));
  const fila = e => { const x = l.find(y => y.estudiante_id === e.id);
    const resp = i.tipo === 'tarea' ? (x?.texto || x?.url ? `${x.texto ? `<details><summary>${esc(x.texto.slice(0, 60))}${x.texto.length > 60 ? '…' : ''}</summary><p style="white-space:pre-wrap">${esc(x.texto)}</p></details>` : ''}${x.url ? `<a href="${esc(x.url)}" target="_blank" rel="noopener">Abrir trabajo</a>` : ''}` : '<span class="muted">No ha entregado</span>')
      : x?.intentos ? `${x.intentos} ${x.intentos === 1 ? 'intento' : 'intentos'}` : '<span class="muted">No ha respondido</span>';
    const tarde = i.fecha && x?.entregado_en && new Date(x.entregado_en) > new Date(i.fecha);
    return `<tr><td>${esc(e.apellidos)} ${esc(e.nombres)}${x?.entregado_en ? `<br><span class="muted" style="font-size:.85rem">${fechaHoraTxt(x.entregado_en)}${tarde ? ' · <span class="err" style="font-weight:400">tardía</span>' : ''}</span>` : ''}</td><td>${resp}</td>
      <td><input class="actnota" ${NOTA_ATTR} id="en-${e.id}" value="${N(x?.nota)}" ${edita ? '' : 'disabled'} aria-label="Calificación de ${esc(nom(e))}"></td>
      <td><input id="ec-${e.id}" value="${esc(x?.comentario || '')}" maxlength="1000" placeholder="Comentario" ${edita ? '' : 'disabled'}></td>
      <td>${edita ? `<button class="btn ghost sm" type="button" onclick="calificarEntrega('${e.id}',this)">Guardar</button>` : ''}<span class="ok" id="eo-${e.id}"></span></td></tr>`; };
  openModal(`${i.tipo === 'tarea' ? 'Entregas' : 'Resultados'}: ${i.titulo}`, `<p class="muted">${i.tipo === 'cuestionario' ? 'La calificación de los cuestionarios es automática (sobre 100). Puede corregirla si es necesario.' : 'Escriba la calificación de 0 a 100 y un comentario; el estudiante y su familia los ven en el campus.'}
      ${i.calificable ? ' La calificación pasa a Calificaciones como actividad del periodo.' : ' Este contenido no cuenta para calificaciones.'}</p>
    <div class="tbl"><table><thead><tr><th>Estudiante</th><th>${i.tipo === 'tarea' ? 'Entrega' : 'Respuestas'}</th><th>Calificación</th><th>Comentario</th><th></th></tr></thead><tbody>${estsDe(g.id).map(fila).join('')}</tbody></table></div>
    <div class="modal-foot"><button class="btn" type="button" onclick="closeModal();render()">Cerrar</button></div>`);
}
async function calificarEntrega(eid, btn) {
  const ln = leerNota($('#en-' + eid).value); if (ln.err) return toast(ln.err);
  btn.disabled = true;
  const r = await guard(() => q(db.rpc('campus_calificar', { p_item: ENT.id, p_est: eid, p_nota: ln.v, p_coment: $('#ec-' + eid).value })));
  btn.disabled = false;
  if (r === undefined) return;
  $('#eo-' + eid).textContent = ' ✓ Guardada'; S.loadedG.delete(sel.cg);
  await guard(cargarCampusStaff);
}

// ---------- Gemas ----------
async function prepGemas() {
  if (isFam()) { CAM.gem = await q(db.rpc('gemas_resumen', { p_est: propio() })); return; }
  const gs = gruposVis().filter(campusGrado); if (!gs.length) return;
  if (!sel.gg || !gs.find(g => g.id === sel.gg)) sel.gg = gs[0].id;
  CAM.gemG = await q(db.rpc('gemas_grupo', { p_grupo: sel.gg }));
}
function vGemas() {
  if (!gemasOn()) return head('Gemas') + '<div class="panel empty">Las gemas están apagadas en el colegio.</div>';
  const como = `<section class="panel"><h2>Cómo se ganan</h2><ul class="list gem-como">
    <li>💻 Entrar al campus cada día <strong>+3</strong> · cinco días seguidos <strong>+10</strong></li><li>📄 Abrir un recurso, video o clase <strong>+2</strong></li>
    <li>📝 Entregar una tarea a tiempo <strong>+10</strong> (tarde <strong>+5</strong>)</li><li>❓ Responder un cuestionario <strong>+5</strong> y hasta <strong>+10</strong> más según la calificación</li>
    <li>🏆 Calificación de 92 o más <strong>+10</strong></li><li>⭐ Felicitación en el observador <strong>+15</strong> · anotación positiva <strong>+5</strong> · participación en clase <strong>+5</strong></li></ul>
    <p class="muted">Rangos: ${RANGOS.map(r => `${r[2]} ${r[1]} (${r[0]})`).join(' · ')}</p></section>`;
  if (isFam()) {
    const d = CAM.gem || { total: 0, semana: 0, top: [], ultimas: [] }, r = rango(d.total), e = est(propio());
    return head(isEst() ? 'Mis gemas' : `Gemas de ${esc(e?.nombres || '')}`, 'Las gemas premian la constancia y la participación en el campus virtual.') +
      `<div class="gem-hero"><div class="gem-ico">${r.ico}</div><div><div class="gem-n">${d.total.toLocaleString('es-CO')} gemas</div><div class="gem-r">Rango <strong>${r.n}</strong>${r.sig ? ` · le faltan ${r.faltan} para ${r.sigIco} ${r.sig}` : ' · ¡el rango más alto!'}</div>
        <div class="bar gem-bar"><i style="width:${r.pct}%"></i></div><div class="muted">Esta semana: +${d.semana} · Puesto ${d.puesto} de ${d.de} en el curso</div></div></div>
      <div class="cols"><section class="panel"><h2>🏆 Top del curso</h2><ol class="gem-top">${d.top.map((x, k) => `<li class="${x.yo ? 'yo' : ''}"><span class="gem-pos">${['🥇', '🥈', '🥉'][k] || k + 1}</span><span>${esc(x.n)}${x.yo ? ' (' + (isEst() ? 'usted' : esc(e?.nombres || '')) + ')' : ''}</span><span class="gem-v">${rango(x.g).ico} ${x.g}</span></li>`).join('')}</ol></section>
        <section class="panel"><h2>Últimas gemas</h2>${d.ultimas.length ? `<ul class="list">${d.ultimas.map(x => `<li>+${x.c} 💎 ${esc(MOTIVO_G[x.m] || x.m)} <span class="muted">· ${fechaHoraTxt(x.f)}</span></li>`).join('')}</ul>` : '<p class="muted">Aún no hay gemas. ¡Entre al campus y empiece a ganarlas!</p>'}</section></div>${como}`;
  }
  const gs = gruposVis().filter(campusGrado);
  if (!gs.length) return head('Gemas del curso') + '<div class="panel empty">Ninguno de sus cursos tiene el campus virtual activo.</div>';
  const l = (CAM.gemG || []).map(x => ({ ...x, e: est(x.estudiante_id) })).filter(x => x.e);
  return head('Gemas del curso', 'Ranking de participación. Reconozca la participación en clase con 5 gemas (una vez al día por estudiante).') +
    `<div class="panel"><div class="toolbar"><label class="field"><span>Curso</span><select onchange="sel.gg=this.value;go('gemas')">${gs.map(x => opt(x.id, x.nombre, sel.gg)).join('')}</select></label></div>
    <div class="tbl"><table><thead><tr><th>#</th><th>Estudiante</th><th>Rango</th><th class="num">Gemas</th><th class="num">Esta semana</th><th></th></tr></thead><tbody>
    ${l.map((x, k) => { const r = rango(x.total); return `<tr><td>${['🥇', '🥈', '🥉'][k] || k + 1}</td><td>${esc(x.e.apellidos)} ${esc(x.e.nombres)}</td><td>${r.ico} ${r.n}</td><td class="num"><strong>${x.total}</strong></td><td class="num">+${x.semana}</td>
      <td><button class="btn ghost sm" type="button" onclick="darParticipacion('${x.estudiante_id}',this)">⭐ Participación +5</button></td></tr>`; }).join('')}</tbody></table></div></div>${como}`;
}
async function darParticipacion(eid, btn) {
  btn.disabled = true;
  const n = await guard(() => q(db.rpc('gemas_participacion', { p_est: eid })));
  if (n === undefined) { btn.disabled = false; return; }
  toast(n ? `+5 gemas para ${est(eid)?.nombres || 'el estudiante'}` : 'Hoy ya reconoció la participación de este estudiante');
  if (n) { CAM.gemG = await q(db.rpc('gemas_grupo', { p_grupo: sel.gg })).catch(() => CAM.gemG); render(); }
}
// Tarjeta del campus y gemas en el inicio de la familia y del estudiante
function campusInicioHTML() {
  const e = est(propio()); if (!e || !campusGrado(grupo(e.grupo_id))) return '';
  const pend = CAM.pend.filter(i => !vencido(i)), r = CAM.gem ? rango(CAM.gem.total) : null;
  return `<div class="cols"><section class="panel cam-ini"><h2>💻 Campus virtual</h2>${pend.length ? `<p><strong>${pend.length}</strong> ${pend.length === 1 ? 'actividad pendiente' : 'actividades pendientes'}:</p><ul class="list cam-list">${pend.slice(0, 3).map(i => itemFamHTML(i, true)).join('')}</ul>` : '<p class="muted">¡Al día! No hay tareas ni cuestionarios por hacer.</p>'}
      <div class="toolbar"><button class="btn sm" type="button" onclick="go('campus')">Entrar al campus</button></div></section>
    ${gemasOn() && r ? `<section class="panel gem-mini"><h2>💎 Gemas</h2><div class="gem-hero sm"><div class="gem-ico">${r.ico}</div><div><div class="gem-n">${CAM.gem.total.toLocaleString('es-CO')}</div><div class="gem-r">Rango <strong>${r.n}</strong> · puesto ${CAM.gem.puesto} de ${CAM.gem.de}</div><div class="bar gem-bar"><i style="width:${r.pct}%"></i></div></div></div>
      <div class="toolbar"><button class="btn ghost sm" type="button" onclick="go('gemas')">Ver top del curso</button></div></section>` : ''}</div>`;
}
async function prepCampusInicio() {
  const e = est(propio()); if (!e || !campusGrado(grupo(e.grupo_id)) || !alDia()) return;
  await cargarCampusFam().catch(() => {});
  if (gemasOn()) {
    const n = await q(db.rpc('gemas_entrada', { p_est: e.id })).catch(() => 0);
    if (n > 0) setTimeout(() => toast(`+${n} gemas 💎 por entrar hoy${n > 3 ? ' (¡cinco días seguidos!)' : ''}`), 600);
    CAM.gem = await q(db.rpc('gemas_resumen', { p_est: e.id })).catch(() => null);
  }
}
// ---------- Parametrización: campus y gemas ----------
function paramCampus() {
  const k = S.k, r = isDir(), dis = r ? '' : 'disabled', grados = [...new Set(S.grupos.map(g => g.grado))].sort((a, b) => a - b), sg = k.campus_grados || [];
  return `<div class="panel"><h2>Campus virtual</h2><p class="muted">Cada docente arma sus unidades con recursos, videos, clases en vivo, tareas y cuestionarios. Los estudiantes y sus familias entran desde Colegio-IA; quien tiene pagos pendientes no puede usarlo.</p>
    <label class="chk"><input type="checkbox" id="cAct" ${k.campus_activo ? 'checked' : ''} ${dis}> Campus virtual activo</label>
    <p style="margin:12px 0 4px"><strong>Grados con campus</strong> <span class="muted">(si no marca ninguno, funciona en todos)</span></p>
    <div class="cuotas">${grados.map(g => `<label class="chk"><input type="checkbox" class="cGr" value="${g}" ${sg.includes(g) ? 'checked' : ''} ${dis}> ${esc(gradoTxt(g))}</label>`).join('') || '<span class="muted">Primero cree los cursos.</span>'}</div>
    <label class="chk" style="margin-top:12px"><input type="checkbox" id="cGem" ${k.gemas_activas !== false ? 'checked' : ''} ${dis}> Gemas, rangos y top del curso (gamificación)</label>
    ${r ? '<div class="toolbar guardar-fijo"><button class="btn" type="button" onclick="guardarCampusCfg()">Guardar</button></div>' : ''}</div>`;
}
async function guardarCampusCfg() {
  await guardarColegio({ campus_activo: $('#cAct').checked, campus_grados: [...document.querySelectorAll('.cGr:checked')].map(x => +x.value), gemas_activas: $('#cGem').checked }, 'Campus y gemas guardados');
  renderSide();
}

/* =====================================================================
   Exponer funciones usadas en el HTML y arrancar
   ===================================================================== */
Object.assign(window, { abrirItem, entregarTarea, enviarCuestionario, campusSel, formUnidad, guardarUnidad, borrarUnidad, elegirTipo, formItem, guardarItem, borrarItem, editorPreguntas, agregarPregunta, quitarPregunta, masOpcion, guardarPreguntas, verEntregas, calificarEntrega, darParticipacion, guardarCampusCfg,
  subirFirma, guardarColegio, guardarAtencion, revisarDiaCita, formGradosAsig, guardarGradosAsig, toggleSec, volver, dlgFin, agregarCarrito, quitarCarrito, cambiarCant, hacerPedido, formComprobantePed, enviarComprobantePed, cancelarPedidoFam, reciboPedido, verPedido, cambiarEstadoPed, listaPreparar, formProducto, guardarProducto, borrarProducto, guardarTienda, verUtiles, copiarUtiles, guardarUtiles, imprimirGraficos,
  llenarEsts, verAvisos, abrirHilo, enviarMensaje, nuevoMensaje, formAutorizacion, guardarAut, responderAut, detalleAut, borrarAut, formCita, guardarCita, formConfirmarCita, confirmarCita, estadoCita, elegirPerfil, salirApp, verFotoEl, subirFotosClase, borrarFotoClase, subirFotoEst, imprimirCarnet, formContacto, guardarContacto, borrarContacto, filtrarFilas, verCarnet, subirFotoEstModal, guardarRedes, quiereDemo, entrarDemo, store, setPorClase, agregarFrase, exportarEstudiantes, exportarCartera, exportarPlanilla, detalleFallas, detalleAsig,
  formActividad, guardarActividad, borrarActividad, setNotaAct, formRecup, guardarRecup, borrarRecup,
  formComunicado, destCom, guardarComunicado, marcarLeido, verLecturas, borrarComunicado, copiarCom,
  guardarHorario, verBoletin, formExcusaStaff, guardarExcusaStaff, guardarPlanColegio, formPlanColegio, previewPago, enviarExcusa, verSoporte, revisarExcusa,
  verComprobante, confirmarComp, rechazarComp, enviarComprobante, sumarCuotas, pazYSalvo, certAnteriores, certAnio,
  planillaDoc, recordarDoc, guardarDiaLimite, guardarLogros, setLogro, formPagoSusc, guardarPagoSusc, abrirObs, guardarObs, borrarObs, setSegObs, observadorHTML, verObservador,
  sel, go, render, refrescar, closeModal, showDocs, printDocs, boletinHTML, copiar,
  setAuth, doLogin, doRegistro, doActivar, doLogout, volverApp, irPlataforma, entrarContexto,
  drawEst, formEst, guardarEst, toggleRetiro, formFamilia, invitar, verInvitacion, nuevoCodigo, toggleMiembro,
  formUsuario, formGruposDoc, guardarGruposDoc, cambiarGrupo, setNota, setNotaPre, setAsis, setObs,
  imprimirBoletin, boletinesGrupo, formGrupo, guardarGrupo, borrarGrupo, editAsig, nuevaAsig, borrarAsig,
  formColegio, crearColegio, toggleColegio, irColegio,
  accionEst, agregarAcud, guardarRetiro, libroMatricula, irPtab, guardarInst, subirLogo, quitarLogo, cambiarNumPeriodos, guardarPeriodos,
  guardarResolucion, formConcepto, guardarConcepto, setCierre, confirmarCierre, abrirCuenta, registrarPago, anularPago, reciboPago,
  imprimirCartera, guardarMediosPago, cambiarAnioCartera, cambiarPerfilDemo, pagarSuscripcion, pagarBoldSusc, copiarTexto, reciboSusc, revisarCompPlat, decidirCompPlat, formPagadoHasta, guardarPagadoHasta, guardarCfgPlat, abrirPiar, guardarPiar, piarHTML, formRetiro,
});
resetS();
arrancar();
