# NokoCord — Chiaki Edition C1.0.0

Chiaki is the experimental, rapid NokoCord edition maintained by Millx. It
keeps its own app container and Discord session, separate from Maomao.
Experiments and releases may happen about 1–2 days apart when active; behavior
can change or be unstable, and there is no support or update promise.

The initial release begins with the same NokoCord functionality as Maomao:
one persistent Discord Web view, Home/Tan Hub, optional local Tans, an in-app
Tan translator, Safe Mode, downloads, settings, and privacy controls. Discord
owns account sign-in, messages, and media. Page-world Tans are trusted code;
install only Tans you trust. Universal Vencord compatibility is outside this
release's scope.

Use the Chiaki DMG or ZIP from the GitHub release with the matching SHA-256
checksum file. The app is named `NokoCord.app` and identifies itself as
Chiaki C1.0.0 in About. The bundle identifier is
`com.shiikatan.nokocord.chiaki`. macOS 26.6 or newer is required.

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
