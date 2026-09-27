# Tan Translator maintenance

The in-app translator uses the static AST engine in this directory and a
bundled JavaScriptCore helper. The checked-in runtime is
`NokoCord/Resources/TanTranslatorRuntime.js`; the TypeScript compiler version
is pinned in `pnpm-lock.yaml`.

To verify translator changes from the repository root:

```sh
cd Tools/TanTranslator
pnpm install --frozen-lockfile --ignore-scripts
node --test
```

The helper analyzes imported source without executing it. It reports unsupported
constructs rather than silently converting them. The bundled compiler license
and third-party notices are in `NokoCord/Resources`.
