# NokoCord — Chiaki Edition C1.3.5

Chiaki is the experimental, rapid NokoCord edition maintained by Millx. It
keeps its own app container and Discord session, separate from Maomao.
Experiments and releases may happen about 1–2 days apart when active; behavior
can change or be unstable, and there is no support or update promise.

## What is new in C1.3.5

C1.3.5 is the confidence-and-recovery follow-up for the one-WebView Discord
workspace:

- Compatibility Center and probe v2 report feature-scoped, bounded DOM and
  browser-capability facts with sanitized reasons. Unsupported routes remain
  ordinary Discord pages, and named hashed fallbacks are visible as reduced
  compatibility rather than hidden selector guesses.
- Tan trust records now retain target, trust origin, enabled state, failure
  category/time, hash-bound approval and a recoverable previous package. Tan
  Hub, Inspector and details expose trust diffs, page-world warnings, quotas,
  quarantine, restore, Safe Mode and redacted diagnostic actions.
- Call teardown is postcondition-based: a page leave request is not treated as
  complete until Discord's call surface has gone away and native capture is
  cleared. Navigation remains guarded while either side is pending.
- Apple Music now has monotonic playback reduction, explicit helper health,
  bounded reconnect backoff, single-helper ownership and bounded owner
  lifetime. Helper positions remain labelled estimated until a signed-build
  manual gate proves exact-position support.
- Focus Shield and Code Workbench add capability-free presentation and code
  reading improvements with visible controls, keyboard and VoiceOver labels,
  reduced-motion handling, bounded mutation work and cleanup fixtures.
- SwiftPM, Xcode and the CLI build now share canonical metadata and resources;
  Xcode declares and embeds the Apple Music helper, and CI runs the full
  Xcode/XCTest plus deterministic package/checksum/extraction gates.

The shipping-style CLI build, signed artifact verifier, metadata/parity tests,
broker tests, translator tests, helper type check and Tan fixture tests pass on
the implementation host. Full SwiftPM/XCTest and Xcode verification remain
blocked on that host because it has Command Line Tools but no full Xcode.

## Known validation boundaries for C1.3.5

The two-user live-call gate, Apple Music Automation permission and helper
quit/relaunch behavior, sleep/wake, VoiceOver pass, and the sixty-minute
performance sample still require manual validation on a full macOS/Xcode host
with Discord and Apple Music access. C1.3.5 does not claim a native Discord call
transport, raw-token transport, or exact Apple Music position support.

## Previous release: C1.3.0

C1.3.0 is a reliability and trust release for the one-WebView Discord
workspace:

- Safe Mode is a real zero-Noko boundary: it removes Noko scripts and message
  handlers while preserving the Discord session data store. Route changes now
  expose an explicit compatibility state and pause Noko page work on login,
  settings, OAuth and other unsupported Discord surfaces.
- Tan approvals are bound to the exact package hash, target and capabilities.
  Runtime messages carry a per-document nonce and package identity; isolated
  `appearance.read` remains the only native Tan capability. Timer, listener,
  mounted-element and bridge quotas are enforced, and repeated failures move a
  Tan into quarantine with recovery controls.
- Tan Hub, Inspector and details now show approval, health, failure,
  quarantine and reload-required states, including redacted diagnostics and
  recovery actions.
- Call status is evidence-based: the app combines WebKit capture with the
  verified Discord origin, media permissions, media-device availability,
  encoded-transform support and semantic Discord call controls. Capture alone
  never claims that a Discord call is connected, and the HUD exposes the
  readiness evidence.
- Apple Music playback now uses generation- and timestamp-aware state
  reduction, helper health states and bounded reconnect backoff. Exact
  position updates remain unavailable on this ad-hoc hardened build until macOS
  grants Automation access; the UI and docs keep that limitation explicit.
- New capability-free bundled Tans: Focus Shield for screen sharing and Code
  Workbench with scoped code-block language labels, line numbers, collapse and
  user-gesture copy controls.
- Release metadata is canonicalized, the native build and helper plists share
  it, and the shipped app can be packaged as a deterministic ZIP with a
  matching SHA-256 checksum.

The CLI native build and signed artifact verifier pass on the release host.
The full `scripts/verify.sh` gate remains host-dependent: this host's Swift
resource build cannot launch its missing/non-executable `xcstringstool`, so the
XCTest/Xcode portions are recorded as unavailable rather than represented as
passing.

## Known validation boundaries for C1.3.0

Voice calls, sleep/wake, long idle sessions and the two-user live-call gate
still require manual validation on a host with Discord access. C1.3.0 does
not claim a native Discord call transport, raw-token transport or exact Apple
Music position support.

## Previous release: C1.2.0

C1.2.0 kept the persistent Discord workspace safer and more predictable during
everyday use.

### What was new in C1.2.0

This release focuses on making the persistent Discord workspace safer and more
predictable during everyday use:

- The command palette, Tans, bookmarks, tutorial, notices and download
  controls now share one overlay host across Home and Discord, so keyboard
  actions remain available when switching surfaces.
- Active-call navigation is guarded: Home cannot hide a live call, and
  disconnect uses Discord's own page control before local capture is stopped.
- Settings now exposes notification preferences and local media diagnostics.
  Notification authorization is explicit, and denied access links back to
  macOS Settings for recovery.
- Tans now confirm original-code installation and explain the trust boundary;
  install failures, reload-needed states and successful enables are reported
  distinctly.
- Downloads and media lightbox actions now show progress and failures, avoid
  overwriting same-named files, support keyboard access, and expose Finder and
  completed-download controls.
- Bookmarks now surface persistence failures, support undo/restore, confirm
  destructive actions and avoid reporting success when a save did not finish.
- Accessibility labels, reduced-motion handling, corrected shortcut guidance
  and clearer recovery messages round out the main workspace flows.

### Included from C1.1.6

- **Fixed: NokoCord refused to open on macOS 26.** The binaries were built
  without a deployment target, so macOS saw an app that required 27.0 even
  though it declares support for 26.0, and answered with "Cannot use NokoCord
  with this version of macOS". C1.1.0 and C1.1.5 both shipped that way; if the
  download would not open for you, this is why. All three binaries — the app and
  both helpers — now build against an explicit macOS 26.0 target, and both
  Info.plists declare the same, so the plist and the binary finally agree.

Everything from C1.1.5 is included: the album appears once rather than twice in
the listening activity, the browser identifies itself so Discord offers voice
instead of refusing it, the music helper's lifetime is handled on separate
queues, and it reports why it cannot read the player instead of going quiet.

### Known limitation: Apple Music access

The helper reads Apple Music over Apple Events, and macOS currently declines
that request for this build **without showing a permission dialog**. macOS
attributes the request to NokoCord, and it will not offer an Automation prompt
to an app that is both ad-hoc signed and hardened, which is how this release is
signed. A Developer ID signature removes the obstacle; so does a planned change
that keeps the sandbox, drops the hardened runtime, and lets NokoCord read the
player itself. Both are tracked in `docs/BACKLOG.md`.

Until then: the status follows Apple Music's own notifications, so ordinary
listening looks right, but a repeated track does not update it, seeking does not
re-sync it, and a song already playing when NokoCord starts appears only at the
next track change.

### Requirements, downloads and permissions

Use the Chiaki DMG or ZIP from the GitHub release with the matching SHA-256
checksum file. The app is named `NokoCord.app` and identifies itself as
Chiaki C1.2.0 in About. The bundle identifier is
`com.shiikatan.nokocord.chiaki`.

**Requirements: macOS 26.0 or newer, on Apple Silicon.** This build contains an
arm64 executable only; Intel Macs cannot run it.

Apple Music Rich Presence is off until you enable the `noko.apple-music` Tan.
It only ever reads the player, and nothing leaves the machine except the
Discord activity you asked for.

There is still no built-in updater, so updates are a manual download. This
build is locally signed with the app sandbox and hardened runtime, but has no
Developer ID signature and is not notarized. Do not describe it as notarized.

Known validation limits: voice calls have not been tested end to end, long
active sessions, sleep/wake, actual Dock reopen, and every accessibility
appearance combination have not been exhaustively checked. Discord WebContent
memory varied during a 15-minute signed-in idle sample; that sample neither
established nor ruled out a leak. See [the source license](LICENSE),
[third-party notices](NokoCord/Resources), and [branding notice](BRANDING.md).
