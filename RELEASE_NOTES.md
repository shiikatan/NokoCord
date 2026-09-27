# NokoCord — Chiaki Edition C1.1.5

Chiaki is the experimental, rapid NokoCord edition maintained by Millx. It
keeps its own app container and Discord session, separate from Maomao.
Experiments and releases may happen about 1–2 days apart when active; behavior
can change or be unstable, and there is no support or update promise.

## What is new in C1.1.5

- The album no longer appears twice in the listening activity. It was on both
  the state line and the artwork's tooltip; it is now on the state line only.
- NokoCord names itself in the user agent, derived from the running system
  version. Discord previously saw a browser with no name at all and refused
  voice outright — calls could not be joined and the start-call button did
  nothing, with no error shown.
- `NokoMusicWatch` polls the player and checks whether NokoCord is still running
  on separate queues, so a stalled Apple Event can no longer leave the helper
  behind after the app quits. NokoCord also asks for a helper again whenever
  nothing has reported for twenty seconds.
- The helper reports *why* it cannot read the player instead of going quiet,
  which is what made the following limitation take so long to find.

## Known limitation: Apple Music access

The helper reads Apple Music over Apple Events, and macOS currently declines
that request for this build without showing a dialog. The reason is understood:
macOS attributes the request to NokoCord, and it will not offer an Automation
permission prompt to an app that is ad-hoc signed *and* has the hardened
runtime, which is exactly how this release is signed. A Developer ID signature
would remove the obstacle; so would a planned change that keeps the sandbox,
drops the hardened runtime, and lets NokoCord read the player itself. Both are
tracked in `docs/BACKLOG.md`.

In practice, until that changes: the status follows track changes through the
notifications Apple Music posts, so it looks right for normal listening, but a
repeated track does not update it, seeking does not re-sync it, and a song that
was already playing when NokoCord starts appears only once the next track
change happens.

## Requirements, downloads and permissions

Use the Chiaki DMG or ZIP from the GitHub release with the matching SHA-256
checksum file. The app is named `NokoCord.app` and identifies itself as
Chiaki C1.1.5 in About. The bundle identifier is
`com.shiikatan.nokocord.chiaki`. macOS 26.0 or newer is required.

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
