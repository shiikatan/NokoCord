import ts from 'typescript';
import { readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const destination = process.argv[2];
if (!destination) throw new Error('Provide an output filename');
const compiler = await readFile(require.resolve('typescript'), 'utf8');
const engine = await readFile(new URL('./engine.mjs', import.meta.url), 'utf8');
const parsed = ts.createSourceFile('engine.js', engine, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
const transform = ts.transform(parsed, [context => root => {
    const visit = node => {
        if (ts.isFunctionDeclaration(node)) return ts.factory.updateFunctionDeclaration(node,
            node.modifiers?.filter(m => m.kind !== ts.SyntaxKind.ExportKeyword), node.asteriskToken, node.name,
            node.typeParameters, node.parameters, node.type, node.body);
        return ts.visitEachChild(node, visit, context);
    };
    return ts.visitNode(root, visit);
}]);
const printed = ts.createPrinter().printFile(transform.transformed[0]);
transform.dispose();
const transformed = ts.transpileModule(printed, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.None }
}).outputText;
// The production host supplies only string hashing/UTF-8 length. No filesystem,
// network, process, user-session or general native object is exposed to this context.
const glue = `\nglobalThis.nokoTranslate = createTranslator({ts, sha256:nokoSHA256, utf8Size:nokoUTF8Size,
 isBuiltin: name => ${JSON.stringify(require('node:module').builtinModules)}.includes(name)});\n`;
await writeFile(destination, compiler + '\n' + transformed + glue);
