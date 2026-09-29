# NokoCord backlog

Deferred work, with the reasoning and the evidence attached, so the next person
does not have to rediscover it. Entries move out of here when they are done.

## C1.3.5 media-slice verification boundary (2026-09-29)

The calls/Apple Music slice now has deterministic local contracts for call
teardown postconditions, reducer ordering, helper ownership, bounded owner
grace, and conservative position labeling. BrowserEngine owns the live
postcondition callbacks, and the Xcode project embeds the helper alongside the
CLI artifact. Direct compilation of the focused core sources and a runtime
assertion harness pass; `swiftc -typecheck Tools/NokoMusicWatch/main.swift`
also passes.

The normal focused XCTest command remains blocked before test compilation by
the host's non-executable `xcstringstool` and unavailable XCTest framework.
Those are host prerequisites, not source failures. No hardened-runtime or
entitlement change is included.

## Apple Music access without a Developer ID (Chiaki)

**Status:** notification fallback ships; Automation permission and exact
position support remain deferred on the ad-hoc build.

**Symptom.** The bundled `NokoMusicWatch` helper can poll the player, but its
Apple Event to Music returns an empty reply with no error, so nothing is
reported and no permission dialog ever appears. Consequences: a repeated track
never updates the status, the position is only as good as Music's own
notifications, and a song already playing when NokoCord starts stays invisible
until the next track change.

**What was proven (2026-09-27, on macOS 27).**

- The helper is not sandboxed when NokoCord launches it (`container=none`,
  `home=/Users/<user>`), and its Info.plist and entitlements are correct.
- The same binary reads Music perfectly when launched by a process that already
  holds the Automation grant (a terminal used earlier in the session).
- TCC attributes a helper launched by NokoCord to **NokoCord**, and macOS will
  not offer an Automation prompt to an ad-hoc signed app that has the hardened
  runtime — our exact combination. The request is dropped silently.
- Installing the helper outside the app bundle is not possible while NokoCord
  is sandboxed: macOS refuses to launch an app that lives inside a sandbox
  container (`open` fails with `-10810`).

**Proposed change.** Keep the sandbox, drop the hardened runtime from the app,
add `com.apple.security.automation.apple-events`, and let NokoCord read Music
itself on a background queue (reuse the queue design the helper already has).
That removes the helper, the unsandboxed exception the release verifier
documents, and the entire nested-helper attribution problem.

**Why it should also fix downloads.** A hardened ad-hoc app refuses to launch
once anything disturbs its signature, which is almost certainly the "NokoCord
only bounces in the Dock" case that forced the Terminal `codesign` workaround
into the C1.0.0 and C1.1.0 release notes. Without the hardened runtime a
downloaded copy should open with the ordinary "unidentified developer →
Open Anyway" click.

**Trade-off.** The hardened runtime adds anti-dylib-injection and
anti-debugging hardening. The sandbox, which is the boundary that matters for
this app, stays. This is a deliberate posture change and needs the maintainer's
sign-off; the release verifier's hardened-runtime assertion has to change with
it.

**How to test cheaply.** Make the change, launch, and watch for the standard
"control Music" dialog. If a prompt appears, the setup story becomes: download,
Open Anyway, one permission prompt. If no prompt appears, nothing is lost — the
notification-based status stays as it is.

## Xcode/CLI helper parity (resolved in C1.3.5)

`NokoMusicWatch` now has a dedicated target and copy phase in
`NokoCord.xcodeproj`, and the Xcode Debug/Release gate checks for the embedded
`Contents/Helpers/NokoMusicWatch.app`. The CLI build uses the same canonical
identity, deployment target, usage description, helper executable, and reviewed
release manifest. `swiftc -typecheck Tools/NokoMusicWatch/main.swift` remains a
cheap focused check, while the full Xcode build is still an external-host gate.

## Voice calls in the WebView

**Status:** unverified fix in the current build.

Discord made DAVE (end-to-end encryption) mandatory for all calls on
2026-03-01, so a client that cannot do WebRTC Encoded Transform cannot join at
all. WebKit does expose `RTCRtpScriptTransform`, Opus stereo, RED and FEC —
the API surface is not the blocker. What NokoCord was sending was a user agent
with no browser name at all, which Discord reads as an unidentified client and
quietly refuses voice for: "cannot join, and the start-call button does
nothing", with no error.

The app now identifies as Safari, derived from the running system version. That
has not been tested against a real call yet. If voice still fails:

1. Probe `navigator.mediaDevices` inside the page. WebKit hides it when the
   host app does not declare microphone usage, and voice buttons go dead for
   that reason too. A bare WebKit process reports it as absent, so the app's own
   page has to be checked, not a test harness.
2. Test the same call in Safari. Works there → the gap is NokoCord's WebView
   configuration. Fails there too → WebKit cannot do DAVE, and the honest
   options are handing the call off to the Discord app, or a Chromium helper
   (which the project rules currently forbid in production).

## Helper lifetime verification

**Status:** reducer and helper lifecycle guarded in C1.3.5; end-to-end process
verification remains manual on a host with Apple Music and Automation access.

The helper polls and checks its owner on separate serial queues. It now emits a
sequence and event timestamp with every report, sends a bounded heartbeat when
an unchanged error or stopped state persists, rejects unsupported playback
states instead of presenting them as playable, and takes a non-blocking OS
lease so duplicate pollers cannot compete. NokoCord reduces those events with
generation/timestamp checks, explicit playing/paused/stopped/idle states,
surfaces missing/denied/unsupported/stale states, and retries a missing helper
with capped backoff rather than launching it in a tight loop. Helper positions
remain conservatively labeled estimated until the signed-build manual gate is
passed.

The remaining manual check is to quit NokoCord and confirm that
`NokoMusicWatch` exits within roughly 35 seconds, then relaunch NokoCord and
confirm that the helper returns. Exact position should remain marked unavailable
when the helper is missing or Automation is denied.

## Stale installs on the maintainer's machine

`/Applications/NokoCord.app` is still the 2026-09-24 C1.0.0 build while the
working copy lives in `build/`. Anything that launches the installed copy is
running code from before the Apple Music work. Worth deleting or refreshing to
avoid confusing future debugging.
