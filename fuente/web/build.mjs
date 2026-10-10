// Construye la versión estática en ../docs (GitHub Pages publica esa carpeta).
import { build } from 'esbuild';
import { readFileSync, writeFileSync, mkdirSync, copyFileSync } from 'node:fs';

const out = new URL('../docs/', import.meta.url).pathname;
const v = Date.now().toString(36);
mkdirSync(out, { recursive: true });
await build({ entryPoints: ['src/main.js'], bundle: true, minify: true, format: 'esm', target: ['es2020'], external: ['https://esm.sh/*'], outfile: out + 'app.js', legalComments: 'none' });
copyFileSync('src/app.css', out + 'app.css');
copyFileSync('src/clave.js', out + 'clave.js');
for (const f of ['manifest.webmanifest', 'sw.js', 'icono-192.png', 'icono-512.png']) copyFileSync('src/' + f, out + f);
writeFileSync(out + 'index.html', readFileSync('index.html', 'utf8').replaceAll('__V__', v));
writeFileSync(out + '.nojekyll', '');
console.log('Listo en', out, 'versión', v);
