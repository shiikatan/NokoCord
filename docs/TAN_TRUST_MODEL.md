# Tan trust and recovery model

Tans are local page enhancements. They are not a second Discord client, a
credential store, an account automation layer, or a network extension.

## Identity

Every installed package has a stable identifier, version, target, declared
capabilities, origin, and content hash. Approval is bound to the complete
content identity, not the identifier alone. A changed JavaScript, stylesheet,
target, capability list, or trust origin is a new approval decision.

The trust record stores the approved hash, target, capabilities, origin,
approval time, health state, failure count, last failure category, and the
last-known-good package reference. Records contain no Discord content,
credentials, tokens, or raw bridge payloads.

## Storage and replacement

Package and trust writes are private, size-bounded, and atomic. A replacement
is staged and validated before activation. The old package remains available as
the previous known-good version until the replacement has passed startup and
runtime checks.

If a write is interrupted, the store chooses the last complete snapshot. If a
replacement fails validation or repeatedly fails at runtime, it is quarantined,
disabled, and reported in the Tan health surface. Restore Previous Version is
explicit and reuses the last-known-good package; it never silently grants trust
to changed code.

## Capability boundary

The current third-party capability set is deliberately minimal. The
appearance.read capability is available only to an isolated Tan that declares
it and passes identity, origin, hash, payload, and rate checks. Page-world Tans
cannot invoke mutating native actions. In particular, this release does not
expose bookmark writes, notifications, media control, arbitrary UI actions,
filesystem access, shell execution, network access, clipboard access, message
sending, or raw session data through a page bridge.

Native capabilities must be added as separate reviewed contracts with an
identity-bound request format, an explicit user-facing permission, rate and
payload limits, and lifecycle cleanup. A convenient callback is not a
capability design.

## Resource limits

The runtime owns and tracks Tan timers, listeners, observers, mounted elements,
bridge requests, package size, and translated-source archives. Disable, reload,
route changes, quarantine, uninstall, and failed startup run cleanup even when
Tan-provided cleanup throws. Quotas protect typing, scrolling, and long-lived
Discord sessions from an accidental or hostile package.

## Health states

The user-facing health surface distinguishes:

- Awaiting approval — content identity changed or a new package is installed;
- Enabled — the package is active on a supported route;
- Disabled — the user turned it off or Safe Mode is active;
- Degraded — one optional feature or selector is unavailable;
- Quarantined — repeated failures disabled the package;
- Reload required — page-world changes need a new Discord document.

Diagnostics are bounded and redacted. They may include package ID, lifecycle
event, category, and time, but never page text, credentials, cookies, raw
JavaScript errors, or bridge payloads.

