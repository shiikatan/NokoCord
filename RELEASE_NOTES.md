# NokoCord — Maomao Edition M1.0.0

Maomao is the stable, polished NokoCord edition maintained by Shiikatan. It
keeps its own app container and Discord session, separate from Chiaki. Ordinary
updates may be about 1–2 weeks apart when active; this is not a support or
update promise.

The release provides a native Mac shell around one persistent Discord Web
view, Home/Tan Hub, optional local Tans, an in-app Tan translator, Safe Mode,
downloads, settings, and privacy controls. Discord owns account sign-in,
messages, and media. Page-world Tans are trusted code; install only Tans you
trust. Universal Vencord compatibility is outside this release's scope.

Use the Maomao DMG or ZIP from the GitHub release with the matching SHA-256
checksum file. The app is named `NokoCord.app` and identifies itself as
Maomao M1.0.0 in About. The bundle identifier is
`com.shiikatan.nokocord.maomao`. macOS 26.6 or newer is required.

The initial release has no built-in updater. Future updates require a manual
download. This build is locally signed with the app sandbox and hardened
runtime, but has no Developer ID signature or Apple notarization. Do not
describe it as notarized.

Known validation limits: long active sessions, sleep/wake, actual Dock reopen,
media calls, and every accessibility appearance combination have not been
exhaustively checked. Discord WebContent memory varied during a 15-minute
signed-in idle sample; that sample neither established nor ruled out a leak.
See [the source license](LICENSE), [third-party notices](NokoCord/Resources),
and [branding notice](BRANDING.md).
