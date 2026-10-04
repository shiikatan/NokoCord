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
The public NokoCord Discord Application ID is configured in `Config/Edition.xcconfig`.
No client secret is required. For a separate Discord application, override
`NOKO_DISCORD_APPLICATION_ID` in an ignored `Config/Local.xcconfig` or as an
`xcodebuild` setting, and configure it as a public client with the desktop
redirect `http://127.0.0.1/callback`. Credentials are scoped to that application ID.
A distributed app requires a positive application ID for OAuth and registered
artwork assets.

Build a local validation app without creating distribution archives:

```sh
xcodebuild -project NokoCord.xcodeproj -scheme NokoCord -configuration Release \
  -destination 'platform=macOS' -derivedDataPath /tmp/NokoCord-build \
  CODE_SIGN_IDENTITY=- build
python3 scripts/verify-release.py /tmp/NokoCord-build/Build/Products/Release/NokoCord.app \
  --edition maomao --ad-hoc-release
```

The release verifier checks the hardened ad-hoc signature layout, bundle
identity, embedded helpers, required resources, and shipped-byte privacy
patterns. It does not claim Developer ID trust or notarization.
`scripts/package-release.py` creates matching ZIP/DMG copies and SHA-256 checksums
from a verified Release app. The updater accepts a ZIP containing `NokoCord.app`.

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

Maomao M1.5.0 keeps local ZIP updates as the primary update method. Noko-Fetch
optionally downloads the latest stable Maomao ZIP from GitHub Releases when you
request it, verifies its published SHA-256, and uses the same updater. There are
no background update checks. Same-version Clean Reinstall remains a local ZIP
action. Credentials remain in Keychain across normal updates.

## License and attribution

NokoCord-owned code and licensable artwork are offered under
[GPL-3.0-only](LICENSE). Required bundled dependency notices are in
`NokoCord/Resources`. See [BRANDING.md](BRANDING.md) for artwork rights and
non-affiliation.
