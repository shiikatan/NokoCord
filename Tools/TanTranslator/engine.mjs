export function createTranslator({ ts, sha256, utf8Size, isBuiltin }) {
const digest = sha256;
const literal = node => node && (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) ? node.text : null;
const nameOf = node => node && (ts.isIdentifier(node) || ts.isStringLiteral(node)) ? node.text : null;
const metadata = new Set(['name', 'description', 'authors', 'tags', 'searchTerms']);
const adapters = new Set(['settings', 'options', 'commands', 'contextMenus', 'flux', 'dependencies', 'patches', 'settingsAboutComponent', 'toolboxActions', 'userProfileBadge', 'chatBarButton', 'messagePopoverButton', 'onMessageClick', 'onBeforeMessageSend', 'onBeforeMessageEdit', 'renderMessageAccessory', 'renderMessageDecoration', 'renderMemberListDecorator']);
const nativeNames = new Set(['VencordNative', 'VesktopNative', 'DiscordNative', 'discordDesktop', 'vesktop', 'process', 'Buffer', '__dirname', '__filename', 'require']);
const restrictedNames = new Set(['localStorage', 'sessionStorage', 'cookie', 'getToken', 'getAuthToken', 'Authorization']);

/** Static conversion only: imported code is never evaluated by this tool. */
function translate({ files, entry = 'index.ts', id, sourceURL, authors: authorOverride, lifecycleTiming }) {
    if (lifecycleTiming !== undefined && lifecycleTiming !== 'document-ready') throw new Error('Invalid lifecycle adaptation');
    if (!/^[a-z0-9][a-z0-9.-]{2,79}$/.test(id ?? '') || id.includes('..') || id.endsWith('.')) throw new Error('Invalid Tan ID');
    if (sourceURL) {
        const url = new URL(sourceURL);
        if (url.protocol !== 'https:' || url.username || url.password || url.search) throw new Error('Origin must be an HTTPS URL without credentials or query');
    }
    const paths = Object.keys(files);
    if (paths.length > 128 || paths.some(p => !/^[A-Za-z0-9_. /-]+$/.test(p) || p.startsWith('/') || p.split('/').some(c => !c || c === '.' || c === '..')) || Object.values(files).some(v => typeof v !== 'string') || Object.values(files).reduce((n, v) => n + utf8Size(v), 0) > 2 * 1024 * 1024) throw new Error('Invalid or oversized source set');
    const source = files[entry];
    if (typeof source !== 'string') throw new Error('Missing entry');
    const ast = ts.createSourceFile(entry, source, ts.ScriptTarget.Latest, true, entry.endsWith('tsx') || entry.endsWith('jsx') ? ts.ScriptKind.TSX : ts.ScriptKind.TS);
    const findings = [];
    const add = (code, category = 'Assisted') => { if (!findings.some(f => f.code === code)) findings.push({ code, category }); };
    const inventory = Object.keys(files).sort().map(path => ({ path, sha256: digest(files[path]) }));
    const licenseFiles = Object.keys(files).filter(path => /^(?:_repository\/)?(license|copying)(\.[a-z0-9-]+)?$/i.test(path));
    if (!licenseFiles.length) add('license-file-required');
    if (ast.parseDiagnostics.length) add('parse-error', 'Unsupported');
    if (Object.keys(files).some(path => /(^|\/)native\.[cm]?[jt]sx?$/.test(path))) add('native-module', 'Requires Native Adapter');
    if (/\.(desktop|web)\.[jt]sx?$/.test(entry)) add('target-specific-entry');
    const css = [], cssBindings = new Map();
    let defineName = null, startAtName = null, devsName = null, definition = null, exportNode = null;
    const removedImports = new Set();
    for (const statement of ast.statements) {
        if (ts.isImportDeclaration(statement)) {
            const module = literal(statement.moduleSpecifier);
            if (module === '@utils/types' && statement.importClause?.name) {
                defineName = statement.importClause.name.text; removedImports.add(statement);
                const bindings = statement.importClause.namedBindings;
                if (bindings) {
                    if (ts.isNamedImports(bindings) && bindings.elements.length === 1 && (bindings.elements[0].propertyName?.text ?? bindings.elements[0].name.text) === 'StartAt') startAtName = bindings.elements[0].name.text;
                    else add('utils-types-import-adapter');
                }
            } else if (module === '@utils/constants' && !statement.importClause?.name &&
                ts.isNamedImports(statement.importClause?.namedBindings ?? {}) && statement.importClause.namedBindings.elements.length === 1 &&
                (statement.importClause.namedBindings.elements[0].propertyName?.text ?? statement.importClause.namedBindings.elements[0].name.text) === 'Devs') {
                devsName = statement.importClause.namedBindings.elements[0].name.text;
                removedImports.add(statement);
            } else if (module?.startsWith('./') && /^\.\/[A-Za-z0-9_-][A-Za-z0-9._-]*\.css(?:\?managed)?$/.test(module)) {
                const path = module.slice(2).replace(/\?managed$/, '');
                if (files[path] === undefined) { add('missing-css', 'Unsupported'); continue; }
                if (/url\s*\(|@import/i.test(files[path])) add('css-resource-resolution');
                if (statement.importClause) {
                    if (!statement.importClause.name || statement.importClause.namedBindings || !module.endsWith('?managed')) add('css-binding-shape');
                    else cssBindings.set(statement.importClause.name.text, files[path]);
                } else css.push(files[path]);
                removedImports.add(statement);
            } else if (module === 'electron' || module?.startsWith('node:') || isBuiltin(module ?? '')) add('native-import', 'Requires Native Adapter');
            else if (module?.startsWith('@webpack')) add('webpack-adapter');
            else if (module?.startsWith('@api/')) add('vencord-api-adapter');
            else if (!statement.importClause?.isTypeOnly) add('unmapped-import');
            else removedImports.add(statement);
        }
    }
    for (const statement of ast.statements) {
        if (ts.isExportAssignment(statement)) {
            const call = statement.expression;
            if (definition || statement.isExportEquals || !ts.isCallExpression(call) || !ts.isIdentifier(call.expression) || call.expression.text !== defineName || call.arguments.length !== 1 || !ts.isObjectLiteralExpression(call.arguments[0])) add('define-plugin-shape', 'Unsupported');
            else { definition = call.arguments[0]; exportNode = statement; }
        } else if (!ts.isImportDeclaration(statement) && !ts.isVariableStatement(statement) && !ts.isFunctionDeclaration(statement) && !ts.isInterfaceDeclaration(statement) && !ts.isTypeAliasDeclaration(statement) && !ts.isEmptyStatement(statement)) {
            add('top-level-statement');
        }
        if (statement.modifiers?.some(m => m.kind === ts.SyntaxKind.ExportKeyword)) add('additional-export');
    }
    if (!definition) add('missing-define-plugin', 'Unsupported');
    const properties = new Map();
    const helperMethods = new Set();
    for (const property of definition?.properties ?? []) {
        const name = nameOf(property.name);
        if (!name || properties.has(name)) { add('dynamic-or-duplicate-property'); continue; }
        properties.set(name, property);
        if (adapters.has(name)) add(name === 'patches' ? 'module-patches-require-adapter' : `plugin-${name}-requires-adapter`);
        else if (!metadata.has(name) && !['start', 'stop', 'managedStyle', 'startAt'].includes(name)) {
            // Preserve ordinary instance methods, including their `this` binding.
            // Framework hooks above still require explicit adapters.
            if (ts.isMethodDeclaration(property) && !['__proto__', 'constructor', 'prototype'].includes(name)) helperMethods.add(name);
            else add('unmapped-plugin-property');
        }
        if (['start', 'stop'].includes(name)) {
            const fn = ts.isMethodDeclaration(property) ? property : property.initializer;
            if (!fn || !(ts.isMethodDeclaration(fn) || ts.isFunctionExpression(fn) || ts.isArrowFunction(fn)) || fn.parameters.length) add('lifecycle-shape');
            if (fn?.modifiers?.some(m => m.kind === ts.SyntaxKind.AsyncKeyword) || fn?.asteriskToken) add('async-lifecycle');
        }
    }
    let timingAdapted = false;
    if (properties.has('start') || properties.has('stop')) {
        const timing = properties.get('startAt')?.initializer;
        const explicitTiming = timing && ts.isPropertyAccessExpression(timing) && ts.isIdentifier(timing.expression) && timing.expression.text === startAtName ? timing.name.text : null;
        if (explicitTiming !== 'DOMContentLoaded') {
            if (lifecycleTiming === 'document-ready' && (!timing || explicitTiming === 'WebpackReady')) {
                timingAdapted = true;
                add('lifecycle-timing-adapted');
            } else add('lifecycle-timing-needs-review');
        }
    }
    const pluginName = literal(properties.get('name')?.initializer);
    const description = literal(properties.get('description')?.initializer);
    if (!pluginName || pluginName.length > 80 || description === null || description.length > 1000) add('static-metadata-required');
    let authors = authorOverride;
    const repositoryAuthors = new Map();
    if (devsName && typeof files['_repository/constants.ts'] === 'string') {
        const constants = ts.createSourceFile('constants.ts', files['_repository/constants.ts'], ts.ScriptTarget.Latest, true);
        const declarations = constants.statements.filter(ts.isVariableStatement).flatMap(s => [...s.declarationList.declarations])
            .filter(d => ts.isIdentifier(d.name) && d.name.text === 'Devs');
        if (!constants.parseDiagnostics.length && declarations.length === 1) {
            let value = declarations[0].initializer;
            if (value && ts.isCallExpression(value) && ts.isPropertyAccessExpression(value.expression) &&
                ts.isIdentifier(value.expression.expression) && value.expression.expression.text === 'Object' &&
                value.expression.name.text === 'freeze' && value.arguments.length === 1) value = value.arguments[0];
            while (value && (ts.isSatisfiesExpression(value) || ts.isAsExpression(value) || ts.isParenthesizedExpression(value))) value = value.expression;
            if (value && ts.isObjectLiteralExpression(value) && value.properties.every(p => ts.isPropertyAssignment(p) && nameOf(p.name) && ts.isObjectLiteralExpression(p.initializer))) {
                for (const member of value.properties) {
                    if (member.initializer.properties.some(p => !ts.isPropertyAssignment(p) || !['name', 'id', 'badge'].includes(nameOf(p.name)) ||
                        !(literal(p.initializer) !== null || ts.isBigIntLiteral(p.initializer) || ts.isNumericLiteral(p.initializer) ||
                          [ts.SyntaxKind.TrueKeyword, ts.SyntaxKind.FalseKeyword].includes(p.initializer.kind)))) continue;
                    const names = member.initializer.properties.filter(p => ts.isPropertyAssignment(p) && nameOf(p.name) === 'name');
                    const key = nameOf(member.name);
                    const author = names.length === 1 ? literal(names[0].initializer) : null;
                    if (repositoryAuthors.has(key)) repositoryAuthors.set(key, null);
                    else repositoryAuthors.set(key, author);
                }
            }
        }
    }
    if (!authors) {
        const node = properties.get('authors')?.initializer;
        authors = ts.isArrayLiteralExpression(node ?? {}) ? node.elements.map(author => {
            if (ts.isPropertyAccessExpression(author) && ts.isIdentifier(author.expression) && author.expression.text === devsName) {
                return repositoryAuthors.get(author.name.text) ?? null;
            }
            if (!ts.isObjectLiteralExpression(author)) return null;
            const property = author.properties.find(p => nameOf(p.name) === 'name');
            return literal(property?.initializer);
        }) : [];
    }
    if (!Array.isArray(authors) || !authors.length || authors.length > 8 || authors.some(a => typeof a !== 'string' || !a.length || a.length > 100)) add('author-attribution-required');
    const managed = properties.get('managedStyle')?.initializer;
    if (managed) {
        if (ts.isIdentifier(managed) && cssBindings.has(managed.text)) { css.push(cssBindings.get(managed.text)); cssBindings.delete(managed.text); }
        else if (literal(managed) !== null) css.push(literal(managed));
        else add('managed-style-shape');
    }
    if (cssBindings.size) add('unused-managed-style-binding');
    if (css.some(text => /url\s*\(|@import/i.test(text))) add('css-resource-resolution');
    function visit(node) {
        if (devsName && ts.isIdentifier(node) && node.text === devsName) {
            let parent = node;
            while (parent && parent !== properties.get('authors') && !removedImports.has(parent) && parent !== ast) parent = parent.parent;
            if (parent === ast) add('runtime-author-metadata-adapter');
        }
        // Dynamic execution can be passed as a callback or assigned to an alias,
        // not just invoked directly (for example, promise.then(eval)).
        if ((ts.isIdentifier(node) && ['eval', 'Function'].includes(node.text)) ||
            (ts.isElementAccessExpression(node) && ['eval', 'Function'].includes(literal(node.argumentExpression)))) add('dynamic-code', 'Unsupported');
        if (ts.isIdentifier(node) && ['fetch', 'WebSocket', 'XMLHttpRequest', 'sendBeacon'].includes(node.text)) add('network-behavior-review');
        if (ts.isPropertyAccessExpression(node) && node.expression.kind === ts.SyntaxKind.ThisKeyword && ['authors', 'tags', 'searchTerms'].includes(node.name.text)) add('runtime-metadata-adapter');
        if (ts.isIdentifier(node) && node.text === '__nokoImportedPlugin') add('reserved-identifier', 'Unsupported');
        if (ts.isIdentifier(node) && ['Vencord', 'webpackChunkdiscord_app'].includes(node.text)) add('runtime-global-adapter');
        if (ts.isIdentifier(node) && nativeNames.has(node.text)) add('native-global', 'Requires Native Adapter');
        if ((ts.isIdentifier(node) || ts.isStringLiteral(node)) && restrictedNames.has(node.text)) add('credential-or-storage-access', 'Unsupported');
        if (ts.isCallExpression(node) && (node.expression.kind === ts.SyntaxKind.ImportKeyword || (ts.isIdentifier(node.expression) && ['eval', 'Function'].includes(node.expression.text)))) add('dynamic-code', 'Unsupported');
        if (ts.isNewExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === 'Function') add('dynamic-code', 'Unsupported');
        if (ts.isJsxElement(node) || ts.isJsxSelfClosingElement(node) || ts.isJsxFragment(node)) add('jsx-runtime-adapter');
        ts.forEachChild(node, visit);
    }
    visit(ast);
    const rank = { Automatic: 0, Assisted: 1, 'Requires Native Adapter': 2, Unsupported: 3 };
    let classification = findings.reduce((c, f) => rank[f.category] > rank[c] ? f.category : c, 'Automatic');
    const outputs = {};
    if (classification === 'Automatic' || (timingAdapted && findings.every(f => f.code === 'lifecycle-timing-adapted'))) {
        const factory = ts.factory;
        const retained = definition.properties.filter(p => ['name', 'description', 'start', 'stop'].includes(nameOf(p.name)) || helperMethods.has(nameOf(p.name)));
        const plugin = factory.createVariableStatement(undefined, factory.createVariableDeclarationList([
            factory.createVariableDeclaration('__nokoImportedPlugin', undefined, undefined, factory.createObjectLiteralExpression(retained, true))
        ], ts.NodeFlags.Const));
        const statements = ast.statements.filter(s => s !== exportNode && !removedImports.has(s));
        statements.push(plugin);
        const modified = factory.updateSourceFile(ast, statements);
        const printed = ts.createPrinter({ newLine: ts.NewLineKind.LineFeed }).printFile(modified);
        const compiled = ts.transpileModule(printed, { fileName: entry, compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.None, removeComments: false, sourceMap: false }, reportDiagnostics: true });
        if (compiled.diagnostics?.some(d => d.category === ts.DiagnosticCategory.Error)) {
            add('transpile-error', 'Unsupported'); classification = 'Unsupported';
        } else {
            outputs['main.js'] = compiled.outputText + '\nNokoTan.register({\n  start() { __nokoImportedPlugin.start?.(); },\n  stop() { __nokoImportedPlugin.stop?.(); }\n});\n';
            if (css.length) outputs['style.css'] = css.join('\n');
            outputs['manifest.json'] = JSON.stringify({ schemaVersion: 1, id, name: pluginName, description, authors, version: '0.1.0', target: 'isolated', entry: 'main.js', ...(css.length ? { stylesheet: 'style.css' } : {}), capabilities: [], requiresReload: false, ...(sourceURL ? { source: sourceURL } : {}) }, null, 2) + '\n';
        }
    }
    if (utf8Size(outputs['main.js'] ?? '') + utf8Size(outputs['style.css'] ?? '') > 512 * 1024) {
        add('output-size-limit', 'Unsupported'); classification = 'Unsupported';
        delete outputs['main.js']; delete outputs['style.css']; delete outputs['manifest.json'];
    }
    const report = { schemaVersion: 1, translatorVersion: '0.1.0', compiler: `TypeScript ${ts.version}`, classification, installable: Boolean(outputs['manifest.json']), entry, ...(timingAdapted ? { adaptations: ['Startup timing explicitly changed from WebpackReady to DOMContentLoaded.'] } : {}), source: sourceURL ?? 'Local source', files: inventory, licenses: licenseFiles.sort(), findings, limitations: ['Static compatibility analysis is not a security audit.', 'Only explicit DOMContentLoaded lifecycle timing is converted automatically.', 'Real Discord behavior requires explicit runtime validation.', 'Original licensing obligations remain unchanged.'] };
    outputs['conversion-report.json'] = JSON.stringify(report, null, 2) + '\n';
    outputs['CONVERSION.md'] = `# Tan conversion\n\nClassification: **${classification}**\n\n${report.installable ? 'An importable package was generated. Import leaves it disabled.' : 'No importable package was emitted. Required behavior has not been silently dropped.'}\n\n` + findings.map(f => `- ${f.code}: ${f.category}\n`).join('') + '\n' + (report.adaptations ?? []).map(x => `- ${x}\n`).join('') + report.limitations.map(x => `- ${x}\n`).join('');
    for (const [path, content] of Object.entries(files)) outputs[`original/${path}`] = content;
    for (const license of licenseFiles) outputs[license] = files[license];
    return { report, outputs };
}

return translate;
}
