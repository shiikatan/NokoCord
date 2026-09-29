# NokoCord — Chiaki Edition C1.2.0

Chiaki is the experimental, rapid NokoCord edition maintained by Millx. It
keeps its own app container and Discord session, separate from Maomao.
Experiments and releases may happen about 1–2 days apart when active; behavior
can change or be unstable, and there is no support or update promise.

## What is new in C1.2.0

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

## Included from C1.1.6

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

## Known limitation: Apple Music access

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

## Requirements, downloads and permissions

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
