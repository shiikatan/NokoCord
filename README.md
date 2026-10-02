# NokoCord

NokoCord is an unofficial macOS app for Discord with one persistent Discord
WebView and optional local page modifications called Tans. Maomao is the macOS
edition maintained by Shiikatan; Chiaki is independent. Install only Tans you trust.
NokoCord is not affiliated with or endorsed by Discord.

## Build and verify

Use Xcode with macOS 26.6 support and build the `NokoCord` scheme. Obtain Discord
Social SDK 1.10.19337 from Discord, then install its macOS package locally:

```sh
./scripts/install-discord-social-sdk.sh /path/to/discord_social_sdk
```

The SDK framework is ignored by Git and must contain both arm64 and x86_64 slices.
Set `NOKO_DISCORD_APPLICATION_ID` in an ignored `Config/Local.xcconfig`, or supply
it as an `xcodebuild` setting. Configure that Discord application as a public
client with the desktop redirect `http://127.0.0.1/callback`. No client secret is
needed. Without a positive application ID, Social SDK operations remain disabled;
the rest of the app builds and runs. A distributed app requires its configured
application ID in the compiled bundle for OAuth and registered artwork assets.

Run `sh scripts/verify.sh` for tests, Debug/Release builds, and bundle checks.
The verification script uses local ad-hoc signatures while keeping hardened
runtime enabled. Its `--allow-ad-hoc` check is source validation only. The
separate `--ad-hoc-release` check validates the hardened signature layout used
for a direct, non-notarized distribution; it does not claim Developer ID trust
or notarization.

Maomao's main app uses the approved
`com.apple.security.cs.disable-library-validation` entitlement to load the
Discord Social SDK in that distribution. This removes the same-Team-ID check
for libraries loaded into the main app process; macOS does not scope the
exception to a particular framework. The Discord SDK is bundled and checked by
the release verifier, and NokoCord is not designed to load external plugins.
The translator and updater helpers do not receive this exception.

An ad-hoc, non-notarized download may be blocked by macOS. Only open a copy from
a source you trust and have verified. After trying to open it, go to **System
Settings > Privacy & Security > Open Anyway**, then confirm the prompt. See
[Apple's instructions for safely opening apps](https://support.apple.com/en-us/102445).
This approval does not mean Apple notarized or checked the app for malware.
Generated apps and private signing configuration do not belong in source control.

## Privacy and presence

Discord handles WebView sign-in and messages. Social SDK authorization is
independent and uses SDK-managed state and PKCE; its tokens remain in macOS
Keychain, separated by application ID. Apple Music Presence is optional and
publishes artist, song, artwork, and playback timing to Discord. Its artwork
resolver queries Apple using track title, artist, and album metadata while
enabled, then uses the registered generic artwork asset on a miss. Album text
is not shown in presence. Disabling the Tan clears its owned activity.

Maomao M1.3 uses a manual ZIP updater. Updater source, test, and build verification
passed; live updater validation remains deferred to M1.3.5.

## License and attribution

NokoCord-owned code and licensable artwork are offered under
[GPL-3.0-only](LICENSE). Required bundled dependency notices are in
`NokoCord/Resources`. See [BRANDING.md](BRANDING.md) for artwork rights and
non-affiliation.
