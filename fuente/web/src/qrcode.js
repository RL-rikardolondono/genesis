// qrcode.js — Codificador QR propio (ISO/IEC 18004), modo byte UTF-8, versiones 1 a 10.
// Uso: qrSvg(texto, { ecc, escala, margen, color }) devuelve un SVG; qrMatriz(texto, ecc) la matriz.

// Tabla de bloques por versión y nivel: [EC por bloque, bloques grupo 1, datos g1, bloques g2, datos g2]
const BLOQUES = {
  L: [null, [7,1,19,0,0], [10,1,34,0,0], [15,1,55,0,0], [20,1,80,0,0], [26,1,108,0,0],
      [18,2,68,0,0], [20,2,78,0,0], [24,2,97,0,0], [30,2,116,0,0], [18,2,68,2,69]],
  M: [null, [10,1,16,0,0], [16,1,28,0,0], [26,1,44,0,0], [18,2,32,0,0], [24,2,43,0,0],
      [16,4,27,0,0], [18,4,31,0,0], [22,2,38,2,39], [22,3,36,2,37], [26,4,43,1,44]],
  Q: [null, [13,1,13,0,0], [22,1,22,0,0], [18,2,17,0,0], [26,2,24,0,0], [18,2,15,2,16],
      [24,4,19,0,0], [18,2,14,4,15], [22,4,18,2,19], [20,4,16,4,17], [24,6,19,2,20]],
  H: [null, [17,1,9,0,0], [28,1,16,0,0], [22,2,13,0,0], [16,4,9,0,0], [22,2,11,2,12],
      [28,4,15,0,0], [26,4,13,1,14], [26,4,14,2,15], [24,4,12,4,13], [28,6,15,2,16]],
};

// Bits del nivel de corrección en la información de formato
const BITS_ECC = { L: 1, M: 0, Q: 3, H: 2 };

// Centros de los patrones de alineación por versión
const ALINEACION = [null, [], [6,18], [6,22], [6,26], [6,30], [6,34],
  [6,22,38], [6,24,42], [6,26,46], [6,28,50]];

const VERSION_MAX = 10;

// ---------- Aritmética en GF(256) con polinomio primitivo 0x11D ----------
const EXP = new Uint8Array(512);
const LOG = new Uint8Array(256);
(() => {
  let x = 1;
  for (let i = 0; i < 255; i++) {
    EXP[i] = x;
    LOG[x] = i;
    x <<= 1;
    if (x & 0x100) x ^= 0x11D;
  }
  for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
})();

function gfMul(a, b) {
  return a === 0 || b === 0 ? 0 : EXP[LOG[a] + LOG[b]];
}

// Polinomio generador de grado n: producto de (x - α^i), i = 0..n-1 (coeficientes de mayor a menor)
function generador(n) {
  let g = [1];
  for (let i = 0; i < n; i++) {
    const r = new Array(g.length + 1).fill(0);
    for (let j = 0; j < g.length; j++) {
      r[j] ^= g[j];
      r[j + 1] ^= gfMul(g[j], EXP[i]);
    }
    g = r;
  }
  return g;
}

// Residuo de Reed–Solomon: devuelve los n códigos de corrección del bloque
function reedSolomon(datos, n) {
  const g = generador(n);
  const res = new Array(n).fill(0);
  for (const d of datos) {
    const factor = d ^ res.shift();
    res.push(0);
    for (let i = 0; i < n; i++) res[i] ^= gfMul(g[i + 1], factor);
  }
  return res;
}

// ---------- Construcción del flujo de datos ----------
function capacidadDatos(version, ecc) {
  const [, b1, d1, b2, d2] = BLOQUES[ecc][version];
  return b1 * d1 + b2 * d2;
}

function elegirVersion(nBytes, ecc) {
  for (let v = 1; v <= VERSION_MAX; v++) {
    const bitsConteo = v < 10 ? 8 : 16;
    const necesarios = 4 + bitsConteo + nBytes * 8;
    if (necesarios <= capacidadDatos(v, ecc) * 8) return v;
  }
  throw new Error(
    `El texto es demasiado largo para el código QR (${nBytes} bytes). ` +
    `El máximo con nivel de corrección ${ecc} es ${capacidadDatos(VERSION_MAX, ecc) - 3} bytes.`);
}

// Arma los códigos de datos: modo byte, longitud, datos, terminador y relleno
function codigosDatos(bytes, version, ecc) {
  const capacidad = capacidadDatos(version, ecc);
  const bits = [];
  const poner = (valor, n) => { for (let i = n - 1; i >= 0; i--) bits.push((valor >>> i) & 1); };
  poner(0b0100, 4);
  poner(bytes.length, version < 10 ? 8 : 16);
  for (const b of bytes) poner(b, 8);
  poner(0, Math.min(4, capacidad * 8 - bits.length));
  while (bits.length % 8) bits.push(0);
  const salida = [];
  for (let i = 0; i < bits.length; i += 8) {
    let b = 0;
    for (let j = 0; j < 8; j++) b = (b << 1) | bits[i + j];
    salida.push(b);
  }
  for (let relleno = 0xEC; salida.length < capacidad; relleno ^= 0xEC ^ 0x11) salida.push(relleno);
  return salida;
}

// Divide en bloques, calcula Reed–Solomon e intercala datos y corrección
function intercalar(datos, version, ecc) {
  const [nEc, b1, d1, b2, d2] = BLOQUES[ecc][version];
  const bloques = [];
  let pos = 0;
  for (let i = 0; i < b1 + b2; i++) {
    const largo = i < b1 ? d1 : d2;
    const bloque = datos.slice(pos, pos + largo);
    pos += largo;
    bloques.push({ datos: bloque, ec: reedSolomon(bloque, nEc) });
  }
  const salida = [];
  const maxDatos = Math.max(d1, d2);
  for (let i = 0; i < maxDatos; i++) {
    for (const b of bloques) if (i < b.datos.length) salida.push(b.datos[i]);
  }
  for (let i = 0; i < nEc; i++) for (const b of bloques) salida.push(b.ec[i]);
  return salida;
}

// ---------- Matriz ----------
// Residuo BCH: valor << grado(gen) módulo gen
function bch(valor, gen) {
  const grado = Math.floor(Math.log2(gen));
  let r = valor << grado;
  while (r >= (1 << grado)) r ^= gen << (Math.floor(Math.log2(r)) - grado);
  return (valor << grado) | r;
}

function crearBase(version) {
  const n = version * 4 + 17;
  const m = Array.from({ length: n }, () => new Array(n).fill(false));
  const fija = Array.from({ length: n }, () => new Array(n).fill(false));
  const poner = (f, c, oscuro) => {
    if (f < 0 || c < 0 || f >= n || c >= n) return;
    m[f][c] = oscuro;
    fija[f][c] = true;
  };

  // Patrones de búsqueda (7x7) con su separador blanco
  for (const [fo, co] of [[0, 0], [0, n - 7], [n - 7, 0]]) {
    for (let df = -1; df <= 7; df++) {
      for (let dc = -1; dc <= 7; dc++) {
        const borde = df === 0 || df === 6 || dc === 0 || dc === 6;
        const centro = df >= 2 && df <= 4 && dc >= 2 && dc <= 4;
        const dentro = df >= 0 && df <= 6 && dc >= 0 && dc <= 6;
        poner(fo + df, co + dc, dentro && (borde || centro));
      }
    }
  }

  // Patrones de sincronización (fila 6 y columna 6)
  for (let i = 8; i < n - 8; i++) {
    poner(6, i, i % 2 === 0);
    poner(i, 6, i % 2 === 0);
  }

  // Patrones de alineación (5x5), excepto donde chocan con los de búsqueda
  const centros = ALINEACION[version];
  const ult = centros[centros.length - 1];
  for (const f of centros) {
    for (const c of centros) {
      if ((f === 6 && c === 6) || (f === 6 && c === ult) || (f === ult && c === 6)) continue;
      for (let df = -2; df <= 2; df++) {
        for (let dc = -2; dc <= 2; dc++) {
          poner(f + df, c + dc, Math.max(Math.abs(df), Math.abs(dc)) !== 1);
        }
      }
    }
  }

  // Reserva de las zonas de formato y módulo oscuro fijo
  for (let i = 0; i < 9; i++) {
    if (i !== 6) { poner(8, i, false); poner(i, 8, false); } // no pisar la sincronización
    if (i < 8) { poner(8, n - 1 - i, false); poner(n - 1 - i, 8, false); }
  }
  poner(n - 8, 8, true);

  // Información de versión (v7 en adelante): BCH(18,6)
  if (version >= 7) {
    const bits = bch(version, 0x1F25);
    for (let i = 0; i < 18; i++) {
      const oscuro = ((bits >>> i) & 1) === 1;
      const a = n - 11 + (i % 3), b = Math.floor(i / 3);
      poner(b, a, oscuro);
      poner(a, b, oscuro);
    }
  }
  return { m, fija, n };
}

// Coloca los bits en zigzag desde la esquina inferior derecha
function colocarDatos(m, fija, n, codigos) {
  let k = 0;
  const total = codigos.length * 8;
  let subiendo = true;
  for (let c = n - 1; c >= 1; c -= 2) {
    if (c === 6) c = 5; // se salta la columna de sincronización
    for (let i = 0; i < n; i++) {
      const f = subiendo ? n - 1 - i : i;
      for (const cc of [c, c - 1]) {
        if (fija[f][cc]) continue;
        // Los bits sobrantes (residuo) quedan en blanco
        m[f][cc] = k < total && ((codigos[k >>> 3] >>> (7 - (k & 7))) & 1) === 1;
        k++;
      }
    }
    subiendo = !subiendo;
  }
}

const MASCARAS = [
  (f, c) => (f + c) % 2 === 0,
  (f) => f % 2 === 0,
  (f, c) => c % 3 === 0,
  (f, c) => (f + c) % 3 === 0,
  (f, c) => (Math.floor(f / 2) + Math.floor(c / 3)) % 2 === 0,
  (f, c) => ((f * c) % 2) + ((f * c) % 3) === 0,
  (f, c) => (((f * c) % 2) + ((f * c) % 3)) % 2 === 0,
  (f, c) => (((f + c) % 2) + ((f * c) % 3)) % 2 === 0,
];

function aplicarMascara(m, fija, n, k) {
  for (let f = 0; f < n; f++)
    for (let c = 0; c < n; c++)
      if (!fija[f][c] && MASCARAS[k](f, c)) m[f][c] = !m[f][c];
}

// Escribe la información de formato (dos copias): BCH(15,5) con máscara 0x5412
function escribirFormato(m, n, ecc, mascara) {
  const bits = bch((BITS_ECC[ecc] << 3) | mascara, 0x537) ^ 0x5412;
  const bit = (i) => ((bits >>> i) & 1) === 1;
  for (let i = 0; i <= 5; i++) m[i][8] = bit(i);
  m[7][8] = bit(6);
  m[8][8] = bit(7);
  m[8][7] = bit(8);
  for (let i = 9; i < 15; i++) m[8][14 - i] = bit(i);
  for (let i = 0; i < 8; i++) m[8][n - 1 - i] = bit(i);
  for (let i = 8; i < 15; i++) m[n - 15 + i][8] = bit(i);
  m[n - 8][8] = true;
}

// Penalización según las cuatro reglas del estándar
function penalizacion(m, n) {
  let p = 0;
  const leer = (a, b, porFila) => (porFila ? m[a][b] : m[b][a]);
  const patron1 = [1,0,1,1,1,0,1,0,0,0,0], patron2 = [0,0,0,0,1,0,1,1,1,0,1];
  for (const porFila of [true, false]) {
    for (let a = 0; a < n; a++) {
      // Regla 1: rachas de 5 o más módulos iguales
      let racha = 1;
      for (let b = 1; b < n; b++) {
        if (leer(a, b, porFila) === leer(a, b - 1, porFila)) racha++;
        else { if (racha >= 5) p += racha - 2; racha = 1; }
      }
      if (racha >= 5) p += racha - 2;
      // Regla 3: patrones parecidos al de búsqueda (1:1:3:1:1 con 4 blancos)
      for (let b = 0; b + 11 <= n; b++) {
        let ok1 = true, ok2 = true;
        for (let k = 0; k < 11; k++) {
          const v = leer(a, b + k, porFila) ? 1 : 0;
          if (v !== patron1[k]) ok1 = false;
          if (v !== patron2[k]) ok2 = false;
        }
        if (ok1) p += 40;
        if (ok2) p += 40;
      }
    }
  }
  // Regla 2: bloques 2x2 del mismo color
  let oscuros = 0;
  for (let f = 0; f < n; f++) {
    for (let c = 0; c < n; c++) {
      if (m[f][c]) oscuros++;
      if (f < n - 1 && c < n - 1) {
        const v = m[f][c];
        if (m[f][c + 1] === v && m[f + 1][c] === v && m[f + 1][c + 1] === v) p += 3;
      }
    }
  }
  // Regla 4: proporción de módulos oscuros respecto al 50 %
  p += Math.floor(Math.abs((oscuros * 100) / (n * n) - 50) / 5) * 10;
  return p;
}

// ---------- API pública ----------
export function qrMatriz(text, ecc = 'M') {
  ecc = String(ecc).toUpperCase();
  if (!BLOQUES[ecc]) throw new Error(`Nivel de corrección inválido: "${ecc}". Use L, M, Q o H.`);
  const bytes = Array.from(new TextEncoder().encode(String(text)));
  const version = elegirVersion(bytes.length, ecc);
  const codigos = intercalar(codigosDatos(bytes, version, ecc), version, ecc);
  const { m, fija, n } = crearBase(version);
  colocarDatos(m, fija, n, codigos);

  // Probar las 8 máscaras y quedarse con la de menor penalización
  let mejor = 0, menor = Infinity;
  for (let k = 0; k < 8; k++) {
    aplicarMascara(m, fija, n, k);
    escribirFormato(m, n, ecc, k);
    const p = penalizacion(m, n);
    if (p < menor) { menor = p; mejor = k; }
    aplicarMascara(m, fija, n, k); // deshacer (XOR)
  }
  aplicarMascara(m, fija, n, mejor);
  escribirFormato(m, n, ecc, mejor);
  return m;
}

export function qrSvg(text, { ecc = 'M', escala = 4, margen = 4, color = '#000' } = {}) {
  const m = qrMatriz(text, ecc);
  const n = m.length;
  const lado = n + margen * 2;
  let d = '';
  for (let f = 0; f < n; f++)
    for (let c = 0; c < n; c++)
      if (m[f][c]) d += `M${c + margen} ${f + margen}h1v1h-1z`;
  const px = lado * escala;
  const colorSeguro = String(color).replace(/[^#\w(),.%\s-]/g, '');
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${px}" height="${px}" ` +
    `viewBox="0 0 ${lado} ${lado}" shape-rendering="crispEdges">` +
    `<rect width="${lado}" height="${lado}" fill="#fff"/>` +
    `<path d="${d}" fill="${colorSeguro}"/></svg>`;
}
