// Excel (.xlsx) sin librerías externas: escribir libros con varias hojas y leer la primera hoja de un libro.
// Colegio-IA v0.22 (carga de estudiantes desde Excel y descarga de toda la información del colegio).

/* ---------- ZIP mínimo ---------- */
const CRC = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
const crc32 = b => { let c = 0xFFFFFFFF; for (let i = 0; i < b.length; i++) c = CRC[(c ^ b[i]) & 255] ^ (c >>> 8); return (c ^ 0xFFFFFFFF) >>> 0; };
async function deflate(b) {
  if (typeof CompressionStream === 'undefined') return null;
  try { return new Uint8Array(await new Response(new Blob([b]).stream().pipeThrough(new CompressionStream('deflate-raw'))).arrayBuffer()); } catch { return null; }
}
async function inflate(b) { return new Uint8Array(await new Response(new Blob([b]).stream().pipeThrough(new DecompressionStream('deflate-raw'))).arrayBuffer()); }
async function zip(files) { // files: [{name, data: Uint8Array}]
  const enc = new TextEncoder(), partes = [], central = []; let off = 0;
  for (const f of files) {
    const nombre = enc.encode(f.name), crc = crc32(f.data), comp = await deflate(f.data);
    const usa = comp && comp.length < f.data.length, datos = usa ? comp : f.data;
    const h = new DataView(new ArrayBuffer(30));
    h.setUint32(0, 0x04034b50, true); h.setUint16(4, 20, true); h.setUint16(6, 0x0800, true); h.setUint16(8, usa ? 8 : 0, true);
    h.setUint32(14, crc, true); h.setUint32(18, datos.length, true); h.setUint32(22, f.data.length, true); h.setUint16(26, nombre.length, true);
    partes.push(new Uint8Array(h.buffer), nombre, datos);
    const c = new DataView(new ArrayBuffer(46));
    c.setUint32(0, 0x02014b50, true); c.setUint16(4, 20, true); c.setUint16(6, 20, true); c.setUint16(8, 0x0800, true); c.setUint16(10, usa ? 8 : 0, true);
    c.setUint32(16, crc, true); c.setUint32(20, datos.length, true); c.setUint32(24, f.data.length, true); c.setUint16(28, nombre.length, true); c.setUint32(42, off, true);
    central.push(new Uint8Array(c.buffer), nombre);
    off += 30 + nombre.length + datos.length;
  }
  const tam = central.reduce((a, x) => a + x.length, 0), e = new DataView(new ArrayBuffer(22));
  e.setUint32(0, 0x06054b50, true); e.setUint16(8, files.length, true); e.setUint16(10, files.length, true); e.setUint32(12, tam, true); e.setUint32(16, off, true);
  return new Blob([...partes, ...central, new Uint8Array(e.buffer)], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
}
async function unzip(buf) {
  const u = new Uint8Array(buf), v = new DataView(buf), dec = new TextDecoder(); let e = u.length - 22;
  while (e >= 0 && v.getUint32(e, true) !== 0x06054b50) e--;
  if (e < 0) throw new Error('El archivo no es un Excel (.xlsx) válido');
  const n = v.getUint16(e + 10, true); let p = v.getUint32(e + 16, true); const out = {};
  for (let i = 0; i < n; i++) {
    const met = v.getUint16(p + 10, true), tc = v.getUint32(p + 20, true), ln = v.getUint16(p + 28, true), lx = v.getUint16(p + 30, true), lc = v.getUint16(p + 32, true), lo = v.getUint32(p + 42, true);
    const nombre = dec.decode(u.subarray(p + 46, p + 46 + ln));
    const ini = lo + 30 + v.getUint16(lo + 26, true) + v.getUint16(lo + 28, true), d = u.subarray(ini, ini + tc);
    out[nombre] = { met, d };
    p += 46 + ln + lx + lc;
  }
  return { leer: async nm => { const f = out[nm]; if (!f) return null; return dec.decode(f.met === 8 ? await inflate(f.d) : f.d); }, nombres: Object.keys(out) };
}

/* ---------- Escribir .xlsx ---------- */
const xe = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])).replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '');
const colL = i => { let s = ''; i++; while (i) { const m = (i - 1) % 26; s = String.fromCharCode(65 + m) + s; i = Math.floor((i - 1) / 26); } return s; };
function hojaXML(filas) {
  const rs = filas.map((f, r) => `<row r="${r + 1}">${f.map((v, c) => {
    const ref = colL(c) + (r + 1);
    if (typeof v === 'number' && isFinite(v)) return `<c r="${ref}"${r === 0 ? ' s="1"' : ''}><v>${v}</v></c>`;
    return `<c r="${ref}" t="inlineStr"${r === 0 ? ' s="1"' : ''}><is><t xml:space="preserve">${xe(v)}</t></is></c>`;
  }).join('')}</row>`).join('');
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><sheetData>${rs}</sheetData></worksheet>`;
}
// hojas: [{nombre, filas: [[cabecera...], [fila...], ...]}]
export async function escribirXlsx(hojas) {
  const enc = new TextEncoder(), f = (name, s) => ({ name, data: enc.encode(s) });
  const nom = hojas.map((h, i) => (String(h.nombre).replace(/[\\/?*[\]:]/g, ' ').slice(0, 31) || 'Hoja ' + (i + 1)));
  const files = [
    f('[Content_Types].xml', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>${hojas.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join('')}</Types>`),
    f('_rels/.rels', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>`),
    f('xl/workbook.xml', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>${nom.map((n, i) => `<sheet name="${xe(n)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join('')}</sheets></workbook>`),
    f('xl/_rels/workbook.xml.rels', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${hojas.map((_, i) => `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`).join('')}<Relationship Id="rId${hojas.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>`),
    f('xl/styles.xml', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF0B4F8A"/></patternFill></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf/></cellStyleXfs><cellXfs count="2"><xf/><xf fontId="1" fillId="2" applyFont="1" applyFill="1"/></cellXfs></styleSheet>`),
    ...hojas.map((h, i) => f(`xl/worksheets/sheet${i + 1}.xml`, hojaXML(h.filas))),
  ];
  return zip(files);
}

/* ---------- Leer .xlsx (primera hoja) o .csv ---------- */
const xd = s => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&#(\d+);/g, (_, n) => String.fromCharCode(+n)).replace(/&amp;/g, '&');
const colN = l => [...l].reduce((a, c) => a * 26 + c.charCodeAt(0) - 64, 0) - 1;
// Fecha de Excel (número de días desde 1899-12-30) a AAAA-MM-DD
export const fechaExcel = n => { const d = new Date(Date.UTC(1899, 11, 30) + Math.round(+n) * 864e5); return d.toISOString().slice(0, 10); };
export async function leerXlsx(buf) {
  const z = await unzip(buf);
  const ss = await z.leer('xl/sharedStrings.xml'), compartidos = [];
  if (ss) for (const m of ss.matchAll(/<si>([\s\S]*?)<\/si>/g)) compartidos.push(xd([...m[1].matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g)].map(x => x[1]).join('')));
  const wb = await z.leer('xl/workbook.xml'), rels = await z.leer('xl/_rels/workbook.xml.rels');
  let ruta = 'xl/worksheets/sheet1.xml';
  const rid = wb?.match(/<sheet [^>]*r:id="([^"]+)"/)?.[1];
  const tg = rid && rels?.match(new RegExp(`<Relationship [^>]*Id="${rid}"[^>]*Target="([^"]+)"`))?.[1] || rid && rels?.match(new RegExp(`<Relationship [^>]*Target="([^"]+)"[^>]*Id="${rid}"`))?.[1];
  if (tg) ruta = tg.startsWith('/') ? tg.slice(1) : 'xl/' + tg.replace(/^\.\//, '');
  const sh = await z.leer(ruta) || await z.leer(z.nombres.find(n => /worksheets\/sheet\d+\.xml$/.test(n)));
  if (!sh) throw new Error('No se encontró la hoja de cálculo');
  const filas = [];
  for (const r of sh.matchAll(/<row[^>]*>([\s\S]*?)<\/row>/g)) {
    const f = [];
    for (const c of r[1].matchAll(/<c ([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
      const at = c[1], ref = at.match(/r="([A-Z]+)\d+"/)?.[1], t = at.match(/t="([^"]+)"/)?.[1], cuerpo = c[2] || '';
      let v = cuerpo.match(/<v>([\s\S]*?)<\/v>/)?.[1];
      if (t === 's') v = compartidos[+v];
      else if (t === 'inlineStr') v = xd([...cuerpo.matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g)].map(x => x[1]).join(''));
      else if (v != null) v = xd(v);
      f[ref ? colN(ref) : f.length] = v ?? '';
    }
    filas.push(Array.from(f, x => x ?? ''));
  }
  return filas;
}
export function leerCsv(txt) {
  txt = txt.replace(/^﻿/, '');
  const sep = (txt.split('\n')[0].match(/;/g) || []).length > (txt.split('\n')[0].match(/,/g) || []).length ? ';' : ',';
  const filas = []; let f = [], c = '', q = false;
  for (let i = 0; i < txt.length; i++) {
    const ch = txt[i];
    if (q) { if (ch === '"') { if (txt[i + 1] === '"') { c += '"'; i++; } else q = false; } else c += ch; continue; }
    if (ch === '"') q = true; else if (ch === sep) { f.push(c); c = ''; } else if (ch === '\n') { f.push(c.replace(/\r$/, '')); filas.push(f); f = []; c = ''; } else c += ch;
  }
  if (c || f.length) { f.push(c.replace(/\r$/, '')); filas.push(f); }
  return filas;
}
export function descargarBlob(blob, nombre) {
  const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = nombre; document.body.appendChild(a); a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1500);
}
