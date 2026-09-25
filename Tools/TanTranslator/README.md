# Tan Translator prototype

The shared AST engine powers the developer CLI and the in-app Tan Hub translator.
The native flow uses a bundled JavaScriptCore helper; users do not need Terminal,
Node or separately installed TypeScript. The pinned TypeScript compiler JavaScript
and its Apache 2.0 license are app resources. Imported plugin code is analyzed,
not executed during conversion.

Developer setup and execution:

```sh
cd Tools/TanTranslator
pnpm install --frozen-lockfile --ignore-scripts
node --test
node translate.mjs --input /path/to/plugin --output /path/to/new-folder --id imported.example
```

Optional arguments: `--entry index.tsx`, `--source https://example.invalid/source`,
`--author "Verified author"`. Attribution overrides are explicit developer input,
not inferred ownership. Input acquisition rejects symlinks, private configuration
filenames, binary/non-UTF-8 input, excessive nesting and source over 2 MiB/128 files.
It never runs imported code, package scripts or fetches dependencies from a plugin.
Output cannot overwrite an existing folder.

The TypeScript AST detects `definePlugin`, imports, metadata, lifecycle timing,
CSS/managed styles, native modules, webpack/patch/API requirements and selected
privileged constructs. It emits Automatic / Assisted / Requires Native Adapter /
Unsupported reports. Only the supported static metadata, explicit DOMContentLoaded
lifecycle and self-contained CSS class produces an installable schema-1 folder.
No unsupported behavior is silently removed. Dynamic code/credential access
checks are conservative signals, **not a security proof**.

Every report records file hashes and compiler version. Original source and license
files remain in the conversion folder. Licensing obligations are unchanged.
In-app translations retain source, license and report in a private local archive
alongside the installed package. Archives are not loaded at startup and are removed
on uninstall. Ordinary prebuilt-package imports do not reconstruct missing original
source. Imported code remains disabled until explicitly enabled.

Ten synthetic test groups exercise lifecycle binding, CSS, deterministic output,
attribution, unsupported APIs, parse failures, paths, native dependencies and the
actual CLI. No upstream plugin code is vendored and no real Discord session is used.

The in-app repository picker reads a selected plugin plus root LICENSE and
static author metadata from src/utils/constants.ts. It does not execute that
module or read repository ancestors. Ordinary instance helper methods retain
their identity and binding. Reports retain compiler/version/limitations when
archived.

Next: a real unmodified upstream plugin milestone and verified compatibility
adapters. Default WebpackReady lifecycle timing remains an explicit review gate.
An in-app assisted choice can adapt that startup to DOMContentLoaded; reports
record the change, classification stays Assisted, and other unresolved findings
still block installation. This choice is not proof of live compatibility. Synthetic conversion
is not evidence of general Vencord compatibility.

Sources checked for implementation contracts:
- [Vencord plugin types](https://github.com/Vendicated/Vencord/blob/main/src/utils/types.ts)
- [TypeScript Compiler API](https://github.com/microsoft/TypeScript/wiki/Using-the-Compiler-API)

## Node-free engine integration probe

`engine.mjs` has an injected compiler/hash/UTF-8-size/platform interface; the CLI
and JavaScriptCore target share its conversion logic. `build-jsc.mjs` removes the
module export through a TypeScript AST transform and bundles the pinned compiler:

```sh
node build-jsc.mjs /tmp/NokoTanTranslator.js
swiftc JavaScriptCoreProbe.swift -o /tmp/NokoTanTranslatorProbe
/usr/bin/time -l /tmp/NokoTanTranslatorProbe /tmp/NokoTanTranslator.js
```

Synthetic macOS evidence: cold conversion approximately 0.17 seconds with a
9,129,160-byte runtime and 83,623,936-byte maximum RSS. A 20-context teardown probe
completed in 3.56 seconds; post-conversion RSS samples were 81,888 / 82,880 /
83,152 / 83,280 KiB after 1 / 5 / 10 / 20 conversions. This short probe shows a
plateau for these fixtures, not a general memory bound. JavaScriptCore retains
allocator/code pages after a context is released. Consequently the production
integration uses an on-demand **bundled native helper** that exits after a
conversion, rather than keep this compiler inside the main app process. That
preserves a no-Terminal/no-separate-install product without adding an idle compiler
footprint. The helper inherits the app sandbox, receives bounded source over pipes with an
empty environment, and exits after one request. It exposes only hash and byte-size
functions to the compiler. The parent enforces a 15-second deadline and bounded
output. Source acquisition rejects symlinks, private configuration and over-limit
files. This helper is a resource-lifetime boundary, not a stronger filesystem or
network sandbox than its parent. A synthetic app-bundle sandbox probe succeeds;
the user also confirmed translation, disabled installation, enable and uninstall
in live Discord. Window/picker lifecycle and normal Xcode integration are being
hardened following that test.
