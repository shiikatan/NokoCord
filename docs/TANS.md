# Tans — schema and runtime

Discord owns authentication, protocol, messages and media. NokoCord's local
Tans can modify the page under the contract below. There is no secondary
account setup, credential bridge or parallel transport.

## Local package

A folder contains `manifest.json` and simple local filenames referenced by it:

```json
{
  "schemaVersion": 1,
  "id": "local.my-tan",
  "name": "My Tan",
  "version": "1.0.0",
  "description": "A small touch of your own.",
  "authors": ["You"],
  "target": "isolated",
  "entry": "main.js",
  "capabilities": []
}
```

Targets are `css`, `isolated` and `page`. CSS requires `stylesheet` and no JS
entry. Other targets require a `.js` entry and may also supply a stylesheet.
Source is limited to 512 KiB per package, manifest to 16 KiB, storage to 64
packages. Nested paths, symlink entries and unknown schema versions are rejected.
Packages are copied into app storage; imports never overwrite installed code.
No network fetch or remote update occurs. Source/license fields are retained.

JavaScript registers a synchronous lifecycle:

```js
NokoTan.register({
  start() {
    // Add the Tan's own changes.
    return () => { /* Remove those changes and listeners. */ };
  }
});
```

An optional `stop()` method also runs during cleanup. Async starts are unsupported
in schema 1. CSS is removed automatically. JavaScript authors must clean up their
own effects; arbitrary code cannot be automatically reversed. Page modifications
and packages declaring `requiresReload` need a reload when changed. Safe Mode
reloads the same view without any Tan scripts and retains the login data store.
It is also available at launch with `--safe-mode`.

## Trust and native boundary

All imported code requires trust. Isolated worlds separate JavaScript globals,
not the shared DOM. Page-world Tans execute alongside Discord and are not a
strong sandbox. This runtime does not make malicious code safe. Do not import
code that reads credentials, automates account activity or exfiltrates content.

The only native capability is `appearance.read`, available only to isolated
packages that declare it. `NokoTan.appearance()` returns a promise containing
`{appearance: "dark" | "light"}`. Enabling a package grants its declared, supported
capability; replacing its code disables it and requires another enable decision.
There is no token, cookie, storage, filesystem, network, clipboard, message-send
or account API. Requests validate the view, main frame, origin, package identity,
active enable state and capability. Each handler accepts at most 20 requests/sec.
Diagnostics store only bounded package identifiers and lifecycle enums, never
raw JavaScript errors, page text or bridge payloads.

## Developer workflow

Enable Developer Mode in Settings or the in-app Tans Inspector (`⌘T`). Create Tan writes a starter folder at a chosen
location. Edit its files with an editor, then Import Tan. Select an installed Tan
to inspect its version, hash, target and capabilities. Reload from folder replaces
that package only when its ID matches, and leaves it disabled. The console shows
lifecycle events; Discord's context menu exposes Web Inspector in Developer Mode.

## Verification scope

Tests use disposable nonpersistent WebKit instances and synthetic HTML, not a
user's Discord data. They cover CSS/JS insertion and removal, rapid transitions,
Safe Mode, manifest rejection and persistence. The app also provides an in-app
translator for supported Vencord-style source, with explicit Automatic,
Assisted, Native Adapter and Unsupported classifications. This does not imply
universal plugin compatibility. Live Discord behavior and long-session cleanup
require edition-specific validation.

## Managed resources and native payload validation

`start(api)` can use `api.listen(target, type, listener, options)`,
`api.interval(callback, milliseconds)`, `api.timeout(callback, milliseconds)`,
`api.mount(element, parent)` and `api.onCleanup(dispose)`. These register at most
256 owned disposers per Tan. Disable and failed start run all disposers even when
a custom cleanup throws, then drop lifecycle/DOM references. Calls return a
function for early disposal. Timer helpers are optional; bundled Noko-Tans do not
poll at idle. Resources created outside these helpers still need explicit cleanup.

Native bridge messages use exactly `{type: "status", state: "started" | "stopped" |
"failed"}` or `{type: "capability", capability: "appearance.read"}`. Extra fields,
unknown enums and wrong types are rejected. Cached active hashes avoid re-encoding
package source on every message. No raw diagnostic payload is retained.
