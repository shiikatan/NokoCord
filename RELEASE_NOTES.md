# NokoCord — Chiaki Edition C1.1.0

Chiaki is the experimental, rapid NokoCord edition maintained by Millx. It
keeps its own app container and Discord session, separate from Maomao.
Experiments and releases may happen about 1–2 days apart when active; behavior
can change or be unstable, and there is no support or update promise.

## What is new in C1.1.0

- Apple Music Rich Presence, owned by the bundled `noko.apple-music` Tan: the
  artist, song and album appear on your Discord profile with a live progress
  bar, and the Tan's on/off state decides whether the feature runs at all.
- Album artwork fetched from album-scoped Last.fm lookups with iTunes and
  Deezer fallbacks, plus the artist's photo as the small image. Every image is
  resolved into Discord's media proxy before it is sent, because raw URLs and
  undefined asset keys never render.
- `NokoMusicWatch`, a small bundled helper that reads Apple Music every five
  seconds from outside the app sandbox. Repeats, seeks, pauses and stops are
  things the player never announces; the helper is what keeps the status in
  sync. It runs only while the Apple Music Tan is enabled and quits with the
  app.
- Voice capture fixes: joining a voice channel no longer parks microphone
  capture behind an invisible page, and hibernation no longer pauses live
  WebRTC audio.
- The decorative Discord Social SDK loader and the unreachable desktop IPC
  client were removed.

One persistent Discord Web view, Home/Tan Hub, optional local Tans, the in-app
Tan translator, Safe Mode, downloads, settings and privacy controls are
unchanged. Discord owns account sign-in, messages and media. Page-world Tans
are trusted code; install only Tans you trust. Universal Vencord compatibility
is outside this release's scope.

## Requirements, downloads and permissions

Use the Chiaki DMG or ZIP from the GitHub release with the matching SHA-256
checksum file. The app is named `NokoCord.app` and identifies itself as
Chiaki C1.1.0 in About. The bundle identifier is
`com.shiikatan.nokocord.chiaki`. macOS 26.6 or newer is required.

Apple Music Rich Presence is off until you enable the `noko.apple-music` Tan.
The first time it reads the player, macOS asks for permission to control
Music; that prompt is the helper reading the current track and position.
Nothing leaves the machine except the Discord activity you asked for.

There is still no built-in updater, so updates are a manual download. This
build is locally signed with the app sandbox and hardened runtime, but has no
Developer ID signature and is not notarized. Do not describe it as notarized.

Known validation limits: long active sessions, sleep/wake, actual Dock reopen,
real-world voice calls, and every accessibility appearance combination have
not been exhaustively checked. Discord WebContent memory varied during a
15-minute signed-in idle sample; that sample neither established nor ruled out
a leak. See [the source license](LICENSE), [third-party notices](NokoCord/Resources),
and [branding notice](BRANDING.md).
