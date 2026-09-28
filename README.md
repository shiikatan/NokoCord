# NokoCord

NokoCord is an unofficial macOS app for Discord. It keeps one Discord WebView
for the signed-in session and supports optional local page modifications called
Tans. NokoCord is not affiliated with or endorsed by Discord.

Maomao (`maomao`) is the stable macOS edition; Chiaki (`chiaki`) is independent.
The editions use separate app identifiers and Discord sessions.

Build the `NokoCord` scheme in Xcode with support for macOS 26.6. Run
`sh scripts/verify.sh` for tests, builds, and bundle checks. There is currently
no public Maomao binary release.

Discord handles sign-in and messages in its WebView. Install only Tans you trust.

## License and attribution

NokoCord-owned code and licensable artwork are offered under
[GPL-3.0-only](LICENSE). Bundled TypeScript notices are in `NokoCord/Resources`.
See [BRANDING.md](BRANDING.md) for artwork rights and non-affiliation.
