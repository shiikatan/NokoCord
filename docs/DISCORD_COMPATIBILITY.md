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

## Compatibility snapshot

The runtime keeps a bounded snapshot for one document generation. It records
the route, probe version, and feature states for navigation, messages,
composer, media, calls, notifications, and activity. Supported routes begin
with an `unknown` feature state; feature-specific diagnostics, such as the
call-readiness probe, must supply evidence before a feature claims readiness.
States are:

- unknown: the surface has not been probed yet;
- healthy: the required semantic anchors and browser prerequisites are present;
- degraded: the feature can offer a reduced behavior;
- unsupported: the feature is gated for this route or missing a required
  prerequisite.

Probes must inspect only presence, type, and capability facts. They must not
collect message text, account identifiers, cookies, tokens, or media content.

Probe failures fail open: the affected Noko feature stops or reports a recovery
action while Discord navigation and messaging remain available. C1.3.0's
compatibility service provides the route boundary and snapshot contract; it does
not claim that every Discord feature anchor has been proven on every future
Discord build.

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
