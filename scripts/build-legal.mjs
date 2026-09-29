// Genera los textos legales para la app (src/legal/generated.ts) y el sitio web (docs/).
// Fuente única: legal/terminos.md, legal/privacidad.md y legal/sitio.json.
// Uso: node scripts/build-legal.mjs
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const site = JSON.parse(readFileSync(join(root, 'legal/sitio.json'), 'utf8'));

/** Markdown mínimo → bloques { type: h1|h2|p|li|oli, text } */
function parse(md) {
  const blocks = [];
  let para = [];
  const flush = () => {
    if (para.length) blocks.push({ type: 'p', text: para.join(' ') });
    para = [];
  };
  for (const raw of md.split('\n')) {
    const line = raw.trim();
    if (!line) { flush(); continue; }
    let m;
    if ((m = line.match(/^# (.*)/))) { flush(); blocks.push({ type: 'h1', text: m[1] }); }
    else if ((m = line.match(/^## (.*)/))) { flush(); blocks.push({ type: 'h2', text: m[1] }); }
    else if ((m = line.match(/^- (.*)/))) { flush(); blocks.push({ type: 'li', text: m[1] }); }
    else if ((m = line.match(/^(\d+)\. (.*)/))) { flush(); blocks.push({ type: 'oli', text: m[2], n: Number(m[1]) }); }
    else para.push(line);
  }
  flush();
  return blocks;
}

const docs = {
  terminos: parse(readFileSync(join(root, 'legal/terminos.md'), 'utf8')),
  privacidad: parse(readFileSync(join(root, 'legal/privacidad.md'), 'utf8')),
};
const version = (readFileSync(join(root, 'legal/terminos.md'), 'utf8').match(/Versión (\d{4}-\d{2}-\d{2})/) ?? [])[1];
if (!version) throw new Error('No encontré "Versión AAAA-MM-DD" en legal/terminos.md');

// ---------------------------------------------------------------- App
mkdirSync(join(root, 'src/legal'), { recursive: true });
writeFileSync(
  join(root, 'src/legal/generated.ts'),
  `// ARCHIVO GENERADO por scripts/build-legal.mjs — no editar a mano. Edita legal/*.md.\n` +
    `export type LegalBlock = { type: 'h1' | 'h2' | 'p' | 'li' | 'oli'; text: string; n?: number };\n` +
    `export const TERMS_VERSION = ${JSON.stringify(version)};\n` +
    `export const SUPPORT_EMAIL = ${JSON.stringify(site.supportEmail)};\n` +
    `export const LEGAL_DOCS: Record<'terminos' | 'privacidad', LegalBlock[]> = ${JSON.stringify(docs, null, 2)};\n`,
);

// ---------------------------------------------------------------- Web (GitHub Pages)
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const inline = (s) => esc(s).replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');

function blocksToHtml(blocks) {
  let html = '';
  let list = null;
  for (const b of blocks) {
    const want = b.type === 'li' ? 'ul' : b.type === 'oli' ? 'ol' : null;
    if (list && list !== want) { html += `</${list}>`; list = null; }
    if (want && !list) { html += `<${want}>`; list = want; }
    if (b.type === 'h1') html += `<h1>${inline(b.text)}</h1>`;
    else if (b.type === 'h2') html += `<h2>${inline(b.text)}</h2>`;
    else if (b.type === 'p') html += `<p>${inline(b.text)}</p>`;
    else html += `<li>${inline(b.text)}</li>`;
  }
  if (list) html += `</${list}>`;
  return html;
}

const page = (title, body) => `<!doctype html>
<html lang="es-CL">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)} · RUÉ</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:wght@600;700&family=DM+Sans:wght@400;500&display=swap" rel="stylesheet">
<style>
:root{--asphalt:#101114;--carbon:#181A1F;--line:#2A2D34;--bone:#F5F3EE;--graphite:#868A93;--lime:#D7FF3F}
*{box-sizing:border-box}
body{margin:0;background:var(--asphalt);color:var(--bone);font:16px/1.6 'DM Sans',system-ui,sans-serif}
main{max-width:760px;margin:0 auto;padding:32px 16px 80px}
header{display:flex;justify-content:space-between;align-items:center;padding:16px;max-width:760px;margin:0 auto}
.logo{font:700 26px 'Bricolage Grotesque',sans-serif;color:var(--bone);text-decoration:none;letter-spacing:-.5px}
.logo span{color:var(--lime)}
nav a{color:var(--graphite);margin-left:16px;text-decoration:none;font-size:14px}
nav a:hover{color:var(--bone)}
h1,h2{font-family:'Bricolage Grotesque',sans-serif;letter-spacing:-.4px}
h1{font-size:34px;line-height:1.15}
h2{font-size:21px;margin-top:36px}
p,li{color:#d9d7d2}
a{color:var(--lime)}
.card{background:var(--carbon);border:1px solid var(--line);border-radius:18px;padding:20px;margin:20px 0}
.cta{display:inline-block;background:var(--lime);color:var(--asphalt);padding:14px 24px;border-radius:999px;font-weight:600;text-decoration:none}
footer{color:var(--graphite);font-size:13px;text-align:center;padding:40px 16px}
</style>
</head>
<body>
<header><a class="logo" href="index.html">RU<span>É</span></a><nav><a href="terminos.html">Términos</a><a href="privacidad.html">Privacidad</a><a href="soporte.html">Soporte</a></nav></header>
<main>${body}</main>
<footer>© ${new Date().getFullYear()} ${esc(site.company)} · RUÉ</footer>
</body>
</html>
`;

mkdirSync(join(root, 'docs'), { recursive: true });
writeFileSync(join(root, 'docs/terminos.html'), page('Términos y Condiciones', blocksToHtml(docs.terminos)));
writeFileSync(join(root, 'docs/privacidad.html'), page('Política de Privacidad', blocksToHtml(docs.privacidad)));
writeFileSync(
  join(root, 'docs/index.html'),
  page(
    'Haz producir lo que tienes parado',
    `<h1>Haz producir lo que tienes parado.</h1>
<p>RUÉ conecta a quienes tienen autos, motos, camionetas, vans, furgones y camiones sin usar con personas y empresas que los necesitan por días o semanas.</p>
<div class="card"><h2>¿Necesitas un vehículo?</h2><p>Busca por tipo, comuna y fechas. Arrienda directo a su dueño, con pago seguro por Mercado Pago.</p></div>
<div class="card"><h2>¿Tienes uno parado?</h2><p>Publícalo gratis, define tu precio y recibe solicitudes. Tú decides a quién se lo arriendas.</p></div>
<p><a class="cta" href="soporte.html">Contáctanos</a></p>`,
  ),
);
writeFileSync(
  join(root, 'docs/soporte.html'),
  page(
    'Soporte',
    `<h1>Soporte</h1>
<p>¿Tienes un problema con una reserva, un pago o tu cuenta? Escríbenos y te respondemos lo antes posible.</p>
<div class="card"><p><strong>Correo:</strong> <a href="mailto:${esc(site.supportEmail)}">${esc(site.supportEmail)}</a></p>
<p>Incluye el correo de tu cuenta y, si se trata de una reserva, las fechas y el vehículo.</p></div>
<p><a href="eliminar-cuenta.html">¿Quieres eliminar tu cuenta?</a></p>`,
  ),
);
writeFileSync(
  join(root, 'docs/eliminar-cuenta.html'),
  page(
    'Eliminar tu cuenta',
    `<h1>Eliminar tu cuenta de RUÉ</h1>
<h2>Desde la app (inmediato)</h2>
<ol><li>Abre RUÉ e inicia sesión.</li><li>Ve a <strong>Perfil</strong>.</li><li>Toca <strong>Eliminar cuenta</strong> y confirma.</li></ol>
<h2>Por correo</h2>
<p>Si ya no tienes la app, escribe a <a href="mailto:${esc(site.privacyEmail)}?subject=Eliminar%20mi%20cuenta">${esc(site.privacyEmail)}</a> desde el correo de tu cuenta con el asunto “Eliminar mi cuenta”. Lo procesamos en un máximo de 30 días.</p>
<h2>Qué se elimina</h2>
<ul><li>Tu perfil, RUT, teléfono, dirección, documentos de verificación, datos bancarios, avisos y dispositivos registrados.</li><li>Tus vehículos sin reservas. Los que tienen historial quedan pausados y sin descripción.</li></ul>
<h2>Qué se conserva</h2>
<p>El registro anonimizado de reservas y pagos, por obligaciones legales y tributarias, durante el plazo que exige la ley.</p>
<p>No puedes eliminar la cuenta mientras tengas reservas pagadas o en curso.</p>`,
  ),
);
console.log(`Textos legales generados (versión ${version}).`);
