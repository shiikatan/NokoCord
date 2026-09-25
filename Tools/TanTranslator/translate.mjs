#!/usr/bin/env node
import { lstat, readdir, readFile, mkdir, writeFile, rename, rm } from 'node:fs/promises';
import { resolve, dirname, join, basename } from 'node:path';
import { randomUUID } from 'node:crypto';
import { translate } from './translator.mjs';

// Deliberately offline. No plugin code, build scripts or dependencies are run.
async function main(args) {
    const options = {};
    for (let i = 0; i < args.length; i += 2) {
        if (!['--input', '--output', '--id', '--entry', '--source', '--author'].includes(args[i]) || !args[i + 1] || options[args[i]]) throw new Error('Invalid arguments');
        options[args[i]] = args[i + 1];
    }
    if (!options['--input'] || !options['--output'] || !options['--id']) throw new Error('Use --input folder --output new-folder --id tan.id [--entry index.ts] [--source HTTPS-URL] [--author name]');
    const root = resolve(options['--input']), output = resolve(options['--output']);
    if ((await lstat(root)).isSymbolicLink() || !(await lstat(root)).isDirectory()) throw new Error('Input must be a regular folder');
    const files = Object.create(null); let total = 0, count = 0;
    async function acquire(folder, relative = '') {
        for (const name of (await readdir(folder)).sort()) {
            if (['.git', 'node_modules', '.DS_Store'].includes(name)) continue;
            if (name === '.env' || name.startsWith('.env.') || /\.(pem|key|p12|pfx)$/i.test(name)) throw new Error('Private configuration or credential files are not accepted');
            const path = join(folder, name), key = relative + name;
            const stat = await lstat(path);
            if (stat.isSymbolicLink()) throw new Error('Source symlinks are not supported');
            if (stat.isDirectory()) {
                if (key.split('/').length > 5) throw new Error('Source nesting limit exceeded');
                await acquire(path, key + '/');
            } else if (stat.isFile()) {
                total += stat.size; count++;
                if (count > 128 || total > 2 * 1024 * 1024) throw new Error('Source limit exceeded');
                files[key] = new TextDecoder('utf-8', { fatal: true }).decode(await readFile(path));
            } else throw new Error('Unsupported source file');
        }
    }
    await acquire(root);
    const entry = options['--entry'] ?? ['index.ts', 'index.tsx', 'index.js', 'index.jsx'].find(p => files[p] !== undefined);
    const result = translate({ files, entry, id: options['--id'], sourceURL: options['--source'], authors: options['--author'] ? [options['--author']] : undefined });
    try { await lstat(output); throw new Error('Output already exists'); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    const parent = dirname(output);
    if (!(await lstat(parent)).isDirectory() || (await lstat(parent)).isSymbolicLink()) throw new Error('Output parent must be a regular directory');
    const temp = join(parent, '.' + basename(output) + '-' + randomUUID());
    await mkdir(temp, { mode: 0o700 });
    try {
        for (const [path, content] of Object.entries(result.outputs)) {
            const destination = join(temp, path);
            await mkdir(dirname(destination), { recursive: true, mode: 0o700 });
            await writeFile(destination, content, { mode: 0o600, flag: 'wx' });
        }
        // Reserve the final destination so a concurrent conversion cannot overwrite it.
        await mkdir(output, { mode: 0o700 });
        try { await rename(temp, output); } catch (error) { await rm(output, { recursive: false }).catch(() => {}); throw error; }
    } finally { await rm(temp, { recursive: true, force: true }); }
    console.log(JSON.stringify({ classification: result.report.classification, installable: result.report.installable, findings: result.report.findings.map(f => f.code) }));
}
main(process.argv.slice(2)).catch(error => {
    // Never dump source, stack traces or absolute local paths into reports/logs.
    console.error(error.code ? 'Source or output could not be accessed.' : error.message);
    process.exitCode = 1;
});
