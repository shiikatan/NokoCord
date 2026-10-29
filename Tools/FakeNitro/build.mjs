import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import ts from '../TanTranslator/node_modules/typescript/lib/typescript.js';

const folder = path.dirname(fileURLToPath(import.meta.url));
const read = name => fs.readFileSync(path.join(folder, name), 'utf8');
const MASK = (1n << 64n) - 1n;
const P1 = 11400714785074694791n, P2 = 14029467366897019727n, P3 = 1609587929392839161n, P4 = 9650029242287828579n, P5 = 2870177450012600261n;
const rot = (n, b) => ((n << BigInt(b)) | (n >> BigInt(64 - b))) & MASK;
const round = (a, b) => rot((a + b * P2) & MASK, 31) * P1 & MASK;
function xxhash64(text) {
  const data = Buffer.from(text), len = data.length; let i = 0, hash;
  if (len >= 32) {
    let a = (P1 + P2) & MASK, b = P2, c = 0n, d = -P1 & MASK;
    while (i <= len - 32) { a = round(a, data.readBigUInt64LE(i)); b = round(b, data.readBigUInt64LE(i + 8)); c = round(c, data.readBigUInt64LE(i + 16)); d = round(d, data.readBigUInt64LE(i + 24)); i += 32; }
    hash = (rot(a, 1) + rot(b, 7) + rot(c, 12) + rot(d, 18)) & MASK;
    for (const value of [a, b, c, d]) hash = ((hash ^ round(0n, value)) * P1 + P4) & MASK;
  } else hash = P5;
  hash = (hash + BigInt(len)) & MASK;
  while (i <= len - 8) { hash = (rot(hash ^ round(0n, data.readBigUInt64LE(i)), 27) * P1 + P4) & MASK; i += 8; }
  if (i <= len - 4) { hash = (rot(hash ^ BigInt(data.readUInt32LE(i)) * P1 & MASK, 23) * P2 + P3) & MASK; i += 4; }
  while (i < len) { hash = rot(hash ^ BigInt(data[i++]) * P5 & MASK, 11) * P1 & MASK; }
  hash ^= hash >> 33n; hash = hash * P2 & MASK; hash ^= hash >> 29n; hash = hash * P3 & MASK; return (hash ^ hash >> 32n) & MASK;
}
if (xxhash64('').toString(16) !== 'ef46db3751d8e999' || xxhash64('hello').toString(16) !== '26c7827d889f6da3') throw new Error('Message-key hash self-check failed');
function intlKey(text) { const bytes = Buffer.alloc(8); bytes.writeBigUInt64LE(xxhash64(text)); return bytes.toString('base64').slice(0, 6); }
let core = read('vendor/FakeNitroCore.ts');
core = core.replace(/^const IS_BYPASSEABLE_INTENTION = .+;$/m, `const IS_BYPASSEABLE_INTENTION = "(" + NK_PATH + ".can('emoji')&&[3,4].includes(fakeNitroIntention))";`);
const keys = new Set([...core.matchAll(/#\{intl::([\w$+/]+)\}/g)].map(match => match[1])); keys.add('EDIT_TEXTAREA_HELP');
const compiled = ts.transpileModule(core, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.None, removeComments: false } }).outputText;
const encoder = '\nconst { GIFEncoder, quantize, applyPalette } = (() => { const exports = {};\n' + read('vendor/gifenc.cjs') + '\nreturn exports; })();\n';
let source = read('prelude.js').replace('/* NOKO_FAKE_NITRO_CORE */', () => 'const INTL_KEYS = ' + JSON.stringify(Object.fromEntries([...keys].map(key => [key, intlKey(key)]))) + ';\n' + compiled)
  .replace('/* NOKO_FAKE_NITRO_CODEC */', () => encoder + read('codec.js')).replace('/* NOKO_FAKE_NITRO_ADAPTER */', () => read('adapter.js').replace('/* NOKO_FAKE_NITRO_UI */', () => read('ui.js')));
new Function('NokoTan', source);
const resource = { manifest: { schemaVersion: 1, id: 'noko.fake-nitro', name: 'FakeNitro', version: '1.0.10',
  description: 'Optional Vencord-inspired emoji/sticker compatibility, local Discord themes, and client quality controls. Reload Discord after installing. Controls are in this Tan’s details.',
  authors: ['shiikatan', 'Vendicated and contributors'], target: 'page', entry: 'main.js', capabilities: [], requiresReload: true,
  source: 'https://github.com/Vendicated/Vencord/tree/main/src/plugins/fakeNitro', license: 'GPL-3.0-only' },
  javascript: source, css: null, origin: 'Noko Original' };
const output = path.resolve(folder, '../../NokoCord/Resources/FakeNitro.tan.json');
fs.writeFileSync(output, JSON.stringify(resource) + '\n');
console.log('Built FakeNitro Tan:', Buffer.byteLength(source), 'bytes; bundled encoder; message hashes:', keys.size);
