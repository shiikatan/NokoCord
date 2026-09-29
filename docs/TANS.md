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
and packages declaring `requiresReload` need a reload when changed. Safe Mode is
a hard boundary: it reloads the same view with zero Noko user scripts, message
handlers, app bridge handlers, or page hooks while retaining the login data
store. It is also available at launch with `--safe-mode`.

## Trust and native boundary

All imported code requires trust. Isolated worlds separate JavaScript globals,
not the shared DOM. Page-world Tans execute alongside Discord and are not a
strong sandbox. This runtime does not make malicious code safe. Do not import
code that reads credentials, automates account activity or exfiltrates content.
Approval is bound to the complete content hash, target, capability list, and
trust origin. Changed code must be approved again; it cannot inherit consent
from the old identifier. See `TAN_TRUST_MODEL.md` for atomic replacement,
quarantine, rollback, and health-state behavior.

The only supported third-party native capability is `appearance.read`, available
only to isolated packages that declare it. `NokoTan.appearance()` returns a
promise containing `{appearance: "dark" | "light"}`. Requests validate the
document, main frame, origin, package identity, content hash, active approval,
declared capability, payload and rate limit. Page-world Tans cannot invoke
mutating native actions. There is no token, cookie, storage, filesystem,
network, clipboard, message-send or account API. Diagnostics store only bounded
package identifiers and lifecycle categories, never raw JavaScript errors, page
text or bridge payloads.

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
256 owned disposers per Tan and are subject to timer, observer, mount and bridge
budgets. Disable and failed start run all disposers even when a custom cleanup
throws, then drop lifecycle/DOM references. Calls return a function for early
disposal. Timer helpers are optional; bundled Noko-Tans do not poll at idle.
Resources created outside these helpers still need explicit cleanup.

Native bridge messages use exactly `{type: "status", state: "started" | "stopped" |
"failed"}` or `{type: "capability", capability: "appearance.read"}`. Extra fields,
unknown enums and wrong types are rejected. Cached active hashes avoid re-encoding
package source on every message. No raw diagnostic payload is retained.

## C1.3.5 presentation and accessibility fixtures

The capability-free bundled `noko.focus-shield` Tan is presentation-only. It
offers three reversible profiles through an accessible, visible control:

- `screen-share` blurs server and direct-message navigation, activity, message
  content, headers, names, and avatars;
- `meeting` blurs participant/activity surfaces and message identity details;
- `streaming` blurs navigation, message identity, headers, and member surfaces.

The profile is held only in the current page and is removed on Tan cleanup. The
indicator exposes `aria-live`, `aria-pressed`, a labelled profile picker, and a
keyboard-visible focus ring. Focus is returned to the pre-Tan element when the
controls are removed. Reduced-motion media state disables the Tan's transitions
and is also tracked through the lifecycle. Focus Shield does not hide or
reflow Discord content; it only applies scoped presentation styling.

The capability-free `noko.code-workbench` Tan keeps code text in Discord's
existing `pre > code` structure and adds a labelled action group, source-
preserving line-number gutter, copy and collapse buttons, live status text, and
keyboard shortcuts. Copy remains a user-gesture `navigator.clipboard` page
action; there is no native clipboard or app bridge. The Tan skips editable
surfaces, observes only relevant DOM additions/text changes, coalesces work to
animation frames, scans at most 64 candidate blocks per frame, and decorates at
most 256 connected blocks. Detached roots, observers, pending frames, status
timers, generated IDs, attributes, controls, and gutters are restored or
released on cleanup. The collapse control and live status are labelled for
VoiceOver, visible focus, and reduced-motion behavior.

Deterministic fixtures live under `Tests/Fixtures/Tans/`. The fixture contract
covers 1,000 editor/message mutation inputs, one-frame coalescing, Safe Mode's
Noko-free page, dynamic code blocks, editable-surface exclusion, profile
selection, cleanup, and reduced-motion/accessibility markers. Safe Mode still
installs zero Noko scripts and handlers through the runtime boundary, so these
bundled Tans are absent rather than partially active there.

## App-called page hooks

A bundled Noko-Tan may publish a documented page-world hook that the app calls
with data the app has already decided, such as the bundled Apple Music RPC
Tan's presence marker, which the app reads to decide whether the Apple Music
activity should be shown.
A hook carries no native capability, adds no bridge message, must remove itself
during Tan cleanup and is an internal contract between NokoCord and its own
bundled Tans rather than an interface for third-party packages. It grants no
access to credentials, session content or native state.
