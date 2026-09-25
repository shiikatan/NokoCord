import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { translate } from './translator.mjs';
const base = `import definePlugin, { StartAt } from '@utils/types';
export default definePlugin({name:'Fixture',description:'Synthetic fixture',authors:[{name:'Fixture author',id:1n}],startAt:StartAt.DOMContentLoaded,
start(){globalThis.marker = (globalThis.marker ?? 0) + 1; this.active = this.name === 'Fixture';},stop(){globalThis.marker -= this.active ? 1 : 0;}});`;
const convert = (source = base, extra = {}, options = {}) => translate({ files: { 'index.ts': source, LICENSE: 'Synthetic test fixture license', ...extra }, id: 'fixture.test', ...options });

test('AST conversion preserves lifecycle binding, provenance and deterministic output', () => {
    const result = convert();
    assert.equal(result.report.classification, 'Automatic');
    assert.deepEqual(result, convert());
    assert.equal(result.outputs['original/index.ts'], base);
    assert.equal(result.outputs.LICENSE, 'Synthetic test fixture license');
    assert.match(result.report.files[0].sha256, /^[0-9a-f]{64}$/);
    const manifest = JSON.parse(result.outputs['manifest.json']);
    assert.equal(manifest.target, 'isolated'); assert.deepEqual(manifest.capabilities, []);
    assert.equal(manifest.enabled, undefined);
    let lifecycle;
    const context = vm.createContext({ NokoTan: { register: value => { lifecycle = value; } } });
    vm.runInContext(result.outputs['main.js'], context);
    lifecycle.start(); assert.equal(context.marker, 1);
    lifecycle.stop(); assert.equal(context.marker, 0);
});

test('side-effect CSS and managed stylesheet conversion', () => {
    const source = `import './one.css'; import css from './two.css?managed';\n` + base.replace('startAt:StartAt.DOMContentLoaded,', 'managedStyle:css,startAt:StartAt.DOMContentLoaded,');
    const result = convert(source, { 'one.css': '.one {color:red}', 'two.css': '.two {color:blue}' });
    assert.equal(result.report.classification, 'Automatic');
    assert.match(result.outputs['style.css'], /\.one/); assert.match(result.outputs['style.css'], /\.two/);
    assert.equal(JSON.parse(result.outputs['manifest.json']).stylesheet, 'style.css');
});

test('unsupported dependencies never silently produce an importable package', () => {
    for (const [source, extra, classification] of [
        [`import { x } from '@webpack';\n${base}`, {}, 'Assisted'],
        [base.replace('startAt:', 'patches: [], startAt:'), {}, 'Assisted'],
        [`import fs from 'node:fs';\n${base}`, {}, 'Requires Native Adapter'],
        [`import http from 'http';\n${base}`, {}, 'Requires Native Adapter'],
        [base.replace('globalThis.marker =', 'fetch("https://example.invalid");globalThis.marker ='), {}, 'Assisted'],
        [base, { 'native.ts': 'export const fixture = 1;' }, 'Requires Native Adapter'],
        [`import x from './helper';\n${base}`, {}, 'Assisted'],
        [base.replace("this.active = this.name === 'Fixture'", 'localStorage.getItem("fixture")'), {}, 'Unsupported'],
        [base.replace("this.active = this.name === 'Fixture'", 'eval("1")'), {}, 'Unsupported'],
        [base.replace("this.active = this.name === 'Fixture'", 'Promise.resolve("1").then(eval)'), {}, 'Unsupported'],
        [base.replace("this.active = this.name === 'Fixture'", 'const run = eval; run("1")'), {}, 'Unsupported'],
        [base.replace("this.active = this.name === 'Fixture'", 'Promise.resolve("1").then(globalThis["eval"])'), {}, 'Unsupported'],
        [base.replace("this.active = this.name === 'Fixture'", 'new Function("return 1")'), {}, 'Unsupported'],
    ]) {
        const result = convert(source, extra);
        assert.equal(result.report.classification, classification);
        assert.equal(result.report.installable, false);
        assert.equal(result.outputs['manifest.json'], undefined);
        assert.equal(result.outputs['original/index.ts'], source);
    }
});

test('classification keeps reviewable behavior assisted and escalates mixed findings by highest risk', () => {
    const cases = [
        [base.replace('globalThis.marker =', 'new WebSocket("wss://example.invalid");globalThis.marker ='), 'Assisted', 'network-behavior-review'],
        [base.replace('globalThis.marker =', 'console.log("fixture");globalThis.marker ='), 'Automatic', null],
        [`import { helper } from 'some-package';\n${base}`, 'Assisted', 'unmapped-import'],
        [`import fs from 'node:fs';\n${base.replace('globalThis.marker =', 'fetch("https://example.invalid");globalThis.marker =')}`, 'Requires Native Adapter', 'native-import'],
        [base.replace('globalThis.marker =', 'localStorage.getItem("fixture"); fetch("https://example.invalid"); globalThis.marker ='), 'Unsupported', 'credential-or-storage-access'],
    ];
    for (const [source, classification, finding] of cases) {
        const result = convert(source);
        assert.equal(result.report.classification, classification, source);
        assert.equal(result.report.installable, classification === 'Automatic');
        if (finding) assert.ok(result.report.findings.some(item => item.code === finding), finding);
        assert.equal(result.outputs['manifest.json'] !== undefined, classification === 'Automatic');
    }
});

test('missing licensing, unresolved authors and default lifecycle timing require review', () => {
    const noLicense = translate({ files: { 'index.ts': base }, id: 'fixture.test' });
    assert.ok(noLicense.report.findings.some(f => f.code === 'license-file-required'));
    for (const source of [base.replace("[{name:'Fixture author',id:1n}]", '[Devs.Unknown]'), base.replace('startAt:StartAt.DOMContentLoaded,', '')]) {
        assert.equal(convert(source).report.classification, 'Assisted');
    }
});

test('malformed source, dynamic metadata, unknown properties and asynchronous lifecycle are reported', () => {
    assert.equal(convert('export default definePlugin({').report.classification, 'Unsupported');
    for (const source of [base.replace("name:'Fixture'", 'name:computed'), base.replace('startAt:', 'settings: {}, startAt:'), base.replace('start(){', 'async start(){')]) {
        assert.equal(convert(source).report.installable, false);
    }
});

test('path traversal, origin credentials and oversized source are rejected', () => {
    assert.throws(() => convert(base, { '../escape.ts': 'x' }));
    assert.throws(() => convert(base, {}, { sourceURL: 'https://user:secret@example.invalid/source' }));
    assert.throws(() => convert(base, { 'large.txt': 'x'.repeat(2 * 1024 * 1024) }));
});

test('CLI emits a local package and refuses overwrites or symlinked source', async () => {
    const { mkdtemp, mkdir, writeFile, readFile, symlink, rm } = await import('node:fs/promises');
    const { tmpdir } = await import('node:os');
    const { join } = await import('node:path');
    const { spawnSync } = await import('node:child_process');
    const root = await mkdtemp(join(tmpdir(), 'noko-translator-test-'));
    try {
        const input = join(root, 'input'), output = join(root, 'output');
        await mkdir(input); await writeFile(join(input, 'index.ts'), base); await writeFile(join(input, 'LICENSE'), 'Synthetic fixture license');
        const { fileURLToPath } = await import('node:url');
        const args = [fileURLToPath(new URL('./translate.mjs', import.meta.url)), '--input', input, '--output', output, '--id', 'fixture.cli'];
        const first = spawnSync(process.execPath, args, { encoding: 'utf8' });
        assert.equal(first.status, 0, first.stderr);
        assert.equal(JSON.parse(await readFile(join(output, 'manifest.json'), 'utf8')).id, 'fixture.cli');
        assert.equal(await readFile(join(output, 'original/index.ts'), 'utf8'), base);
        const second = spawnSync(process.execPath, args, { encoding: 'utf8' });
        assert.notEqual(second.status, 0); assert.match(second.stderr, /Output already exists/);
        await symlink(join(input, 'index.ts'), join(input, 'linked.ts'));
        const linked = spawnSync(process.execPath, args, { encoding: 'utf8' });
        assert.notEqual(linked.status, 0); assert.match(linked.stderr, /symlinks/);
    } finally { await rm(root, { recursive: true, force: true }); }
});

test('repository license and literal author metadata are preserved without executing constants', () => {
    const source = `import { Devs as Authors } from '@utils/constants'; import definePlugin from '@utils/types';
export default definePlugin({name:'Repository fixture',description:'Static style fixture',authors:[Authors.Fixture],managedStyle:'.fixture { color: red; }'});`;
    const files = { 'index.ts': source, '_repository/LICENSE': 'Synthetic repository license',
        '_repository/constants.ts': `throw new Error('must never execute'); export const Devs = Object.freeze({Fixture:{name:'Fixture author',id:0n}} satisfies Record<string, unknown>);` };
    const result = translate({files, id:'fixture.repository'});
    assert.equal(result.report.classification, 'Automatic');
    assert.deepEqual(JSON.parse(result.outputs['manifest.json']).authors, ['Fixture author']);
    assert.deepEqual(result.report.licenses, ['_repository/LICENSE']);
    assert.equal(result.outputs['original/_repository/constants.ts'], files['_repository/constants.ts']);
    assert.equal(result.outputs['_repository/LICENSE'], files['_repository/LICENSE']);
    assert.doesNotMatch(result.outputs['main.js'], /must never execute|Authors/);
    for (const constants of [
        'export const Devs = Object.freeze({Fixture:{name:compute(),id:0n}});',
        "export const Devs = Object.freeze({Fixture:{name:'First',name:'Second',id:0n}});",
        "export const Devs = Object.freeze({Fixture:{name:'First',id:0n},...unknown});"
    ]) assert.equal(translate({files:{...files,'_repository/constants.ts':constants},id:'fixture.repository'}).report.installable, false);
    assert.equal(translate({files:{...files,'index.ts':source.replace('managedStyle:', 'start(){console.log(Authors.Fixture);},managedStyle:')},id:'fixture.repository'}).report.installable, false);
});

 test('instance helper methods retain identity and binding across lifecycle cleanup', () => {
    const source = base.replace('start(){globalThis.marker', 'event(value){ this.count = value; },start(){this.event(3); globalThis.savedHandler = this.event; globalThis.marker');
    const result = convert(source);
    assert.equal(result.report.installable, true);
    let lifecycle;
    const context = vm.createContext({NokoTan:{register:value => {lifecycle = value;}}});
    vm.runInContext(result.outputs['main.js'], context);
    lifecycle.start();
    assert.equal(vm.runInContext('__nokoImportedPlugin.count', context), 3);
    assert.equal(vm.runInContext('__nokoImportedPlugin.event === savedHandler', context), true);
    lifecycle.stop();
    assert.equal(context.marker, 0);
    assert.equal(convert(base.replace('start(){', 'onMessageClick(){},start(){')).report.installable, false);
    assert.equal(convert(base.replace('start(){', 'get event(){return 1;},start(){')).report.installable, false);
});

test('document-ready adaptation is explicit, recorded, and cannot bypass other compatibility gaps', () => {
    const source = base.replace('startAt:StartAt.DOMContentLoaded,', '');
    assert.equal(convert(source).report.installable, false);
    const converted = convert(source, {}, {lifecycleTiming:'document-ready'});
    assert.equal(converted.report.classification, 'Assisted');
    assert.equal(converted.report.installable, true);
    assert.deepEqual(converted.report.adaptations, ['Startup timing explicitly changed from WebpackReady to DOMContentLoaded.']);
    assert.equal(converted.outputs['original/index.ts'], source);
    assert.match(converted.outputs['CONVERSION.md'], /explicitly changed from WebpackReady to DOMContentLoaded/);
    for (const unsupported of [source.replace('start(){','settings:{},start(){'), source.replace('start(){','startAt:StartAt.Init,start(){')]) {
        assert.equal(convert(unsupported, {}, {lifecycleTiming:'document-ready'}).report.installable, false);
    }
    assert.throws(() => convert(source, {}, {lifecycleTiming:'unknown'}));
});
