# NokoCord

NokoCord is an unofficial macOS app for Discord. It keeps one Discord WebView
for the signed-in session and supports optional local page modifications called
Tans. NokoCord is not affiliated with or endorsed by Discord.

## Editions

- **Maomao** (`maomao`): stable macOS edition maintained by Shiikatan. The
  current source version is M1.2.0.
- **Chiaki** (`chiaki`): independent experimental edition.
- `noko`: neutral landing branch, not an installable edition.

The editions use separate app identifiers and containers, including separate
Discord sessions.

## Build and use

Build with Xcode that supports the macOS 26.6 deployment target.
`sh scripts/verify.sh` runs the Swift tests, Debug and Release builds, and
Release app checks.
The Tan translator's JavaScript tests require Node and can be run with
`node --test Tools/TanTranslator/translator.test.mjs`.

Release packages and checksums are provided through GitHub Releases. Current
Maomao builds are ad-hoc signed, without Apple Developer ID signing or
notarization. macOS Gatekeeper may block a downloaded app, even after Open
Anyway. See the applicable release description before installing.

Discord handles authentication, messages, and media. Page-world Tans run as
trusted page code; install only Tans you trust. NokoCord does not provide a
separate raw-user-token transport.

## License and attribution

NokoCord-owned code and licensable project artwork are offered under
[GPL-3.0-only](LICENSE). The bundled TypeScript runtime retains its own license
and notices in `NokoCord/Resources`. See [BRANDING.md](BRANDING.md) for artwork
provenance and non-affiliation.
