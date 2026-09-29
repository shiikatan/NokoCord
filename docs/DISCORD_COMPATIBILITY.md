# Discord compatibility contract

NokoCord treats Discord's authenticated WKWebView as the source of truth. The
app may add bounded presentation and diagnostics, but it must not replace
Discord's session, transport, message store, or media stack.

## Route boundary

Page integrations are eligible only on the Discord application surfaces:

- /app
- /channels
- /channels/<guild>/<channel>

Login, registration, OAuth, invites, settings, error pages, downloads, and
unknown routes are protected surfaces. NokoCord removes live Tan work there and
the injected app script returns before it registers listeners or changes the
page. A route that cannot be classified is treated as unsupported.

Synthetic fixture origins may opt into the same contract for deterministic
tests; that exception is not a production origin allowlist.

## Compatibility probe v2

`DiscordCompatibilityService.probeScript(for:)` is a single bounded page probe
for one document generation. It returns only typed facts:

- semantic anchor observations: `present`, `missing`, `wrongType`, or
  `notChecked`;
- browser capability observations for media devices, real-time communication,
  notifications, and custom events;
- the probe version, document generation, ready-state fact, timeout bit, and
  bounded capture time; and
- named fallback IDs, never raw selectors.

The facts are limited to an 8 KiB encoded payload and the reducer accepts only
probe version 2. It never accepts page text, form values, media, storage,
cookies, tokens, account identifiers, JavaScript exception strings, or arbitrary
page-provided reasons. `DiscordCompatibilityReason.userMessage` is the only
ordinary-user explanation surface and contains fixed, sanitized copy.

The reducer keeps feature decisions independent:

| Feature | Required anchors | Required browser facts |
| --- | --- | --- |
| navigation | navigation root, channel list | none |
| messages | message list, message row | none |
| composer | composer | none |
| media | attachment control | media devices |
| calls | call surface | media devices, real-time communication |
| notifications | notification region | notification API |
| activity | activity dispatch | custom events |

`healthy` means all required facts are present. A missing or wrong-type required
anchor makes only that feature `unsupported`; a named hashed fallback makes only
that feature `degraded`. An incomplete result, document that is still loading,
or timed-out result remains `unknown`. Discord's own surface stays available in
all of these cases.

### Generation, timeout, and fallback rules

The service exposes a 750 ms caller budget and the page script has a shorter
200 ms internal scan deadline. The caller must discard a result whose generation
does not match the current document; the pure reducer returns `nil` for that
stale result. A timeout is recorded as a sanitized `probeTimedOut` diagnostic,
not as proof that Discord is incompatible.

Hashed-class selectors are explicit, named fallback entries. The current
metadata is:

| ID | Feature / anchor | Selector SHA-256 |
| --- | --- | --- |
| `messages.legacy-row-class` | messages / message row | `a03bc5acfb3bae90fe120c74d382e1cac35961663a5b44b4ed6c407ba3be1880` |
| `composer.legacy-textarea-class` | composer / composer | `3eae7e33e10c5dce975cc7bde34d69ee535ba1260a284ba5c983e2dcf87dac81` |
| `calls.legacy-panel-class` | calls / call surface | `a662803618d677920afb2470064c2993866edfbffcba0dfe03f160968b259412` |

The raw selector is private to the generated probe source. Probe facts and
diagnostics carry only the ID, owning feature, anchor, hash, and fixed warning.
`Tests/Fixtures/Compatibility/selector-drift.html` proves the message fallback
path; `missing-anchor.html` proves feature-scoped failure; and `supported.html`
provides the semantic-anchor baseline.

## Safe Mode

Safe Mode is a hard runtime boundary, not just an empty enabled-Tan list. It
installs:

- zero Noko user scripts;
- zero Noko message handlers;
- zero app bridge handlers;
- zero page-world hooks.

Existing enabled IDs remain stored so leaving Safe Mode does not erase user
choices. Returning to normal mode requires a new document before integrations
are installed. The Discord website data store is retained, so Safe Mode does
not log the user out.

## Runtime budgets

Observers inspect added subtrees and coalesce work to an animation frame. They
must skip editor mutations, cap the number of roots processed in one frame, and
release on disable, route change, reload, logout, or WebView replacement. Async
work carries the document generation and must abandon its result when that
generation is no longer current.

Webpack/module discovery is cached only for the current document generation.
It is discarded on navigation and never used as proof that a feature is
available on a new Discord build.

## User recovery

The Inspector explains when the current Discord surface is protected or a
feature is degraded. Recovery actions are limited to returning to an eligible
Discord route, reloading the current document, disabling the affected Tan, or
starting Safe Mode. NokoCord must not silently reload an authenticated page to
make an optional feature work.
