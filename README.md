# NokoCord

NokoCord is an unofficial macOS app for Discord with one persistent WebView and
optional local page modifications called Tans. Maomao is maintained by Shiikatan;
Chiaki is independent. NokoCord is not affiliated with Discord.

Maintainer contact: [shiikatan@proton.me](mailto:shiikatan@proton.me).

## Install and update

Maomao M2.0.0 requires Apple Silicon and macOS 26.6 or later. Release downloads
provide a ZIP, DMG and SHA-256 checksums. The ZIP contains `NokoCord.app` and works
with the built-in local updater. Optional Noko-Fetch downloads the latest stable
Maomao ZIP from GitHub only when requested, verifies its published checksum and
uses the same updater. There are no background update checks.

The current build is ad hoc signed and not notarized. After verifying a trusted
copy, macOS may require **System Settings → Privacy & Security → Open Anyway**.
See [Apple's instructions](https://support.apple.com/en-us/102445). This approval
does not mean Apple notarized or checked the app for malware.

## MaoList

MaoList ML1.0.0 is an optional native AniList workspace. Enable it in Settings,
then connect AniList for libraries, progress tracking, list editing and account
features. Public discovery and title details also work without an account.
Personal ratings follow your AniList score format; community averages remain
percentages. Home offers Rows and Covers layouts, and title details include
relations, people, recommendations and reviews.

Use the MaoList logo in Discord, the NokoCord logo in MaoList, or
**Shift–Command–M** to switch workspaces. Loaded pages and pagination are retained
on return. **Control–Command–N** shows or hides NokoBar.

Optional **Prepare MaoList at launch** is off by default and warns about extra
resource use. It prepares main sections and library pages in a finite pass,
subject to API pacing and cache limits. There is no periodic refresh. Disabling
preparation cancels it; disabling MaoList releases its runtime and stops its
network work while preserving the saved connection. Refresh requests newer data.
Previously loaded data can remain available offline with a stale notice; failed
edits are not queued. Disconnect clears credentials and account caches without
deleting your AniList lists.

## Privacy and presence

- Discord handles WebView sign-in and messages. Optional Social SDK authorization
  is separate, uses PKCE, and stores credentials in macOS Keychain by application
  ID. AniList credentials use a separate Keychain service. No analytics or
  telemetry is included.
- MaoList uses AniList's public GraphQL API and bounded response/artwork caches.
  Hidden screens normally stop their reads. Launch preparation attempts a
  noninteractive Keychain read and defers to foreground access if locked.
- Optional Apple Music Presence publishes artist, song, artwork and playback
  timing to Discord. Artwork lookup sends track/artist/album metadata to Apple's
  iTunes Search. After a miss, it uses Last.fm when an application key is configured,
  otherwise MusicBrainz/Cover Art Archive. Backup lookups are cached and rate limited.
  No Last.fm user sign-in, scrobbling, shared secret or MusicKit access is used.
- Home's optional music card reuses Presence samples without extra music polling.
  Hiding the card leaves Discord activity enabled; disabling the Tan cancels
  lookups and clears its activity.
- Tans can modify pages. Install only Tans you trust. Generated apps, browser
  profiles, caches, credentials and diagnostic captures stay outside Git.

## Build and verify

Use Xcode with macOS 26.6 support and the `NokoCord` scheme. Obtain Discord Social
SDK **1.10.19337** from Discord and install its macOS package locally:

```sh
./scripts/install-discord-social-sdk.sh /path/to/discord_social_sdk
xcodebuild -project NokoCord.xcodeproj -scheme NokoCord -configuration Release \
  -destination 'platform=macOS' -derivedDataPath /tmp/NokoCord-build \
  CODE_SIGN_IDENTITY=- build
python3 scripts/verify-release.py /tmp/NokoCord-build/Build/Products/Release/NokoCord.app \
  --edition maomao --ad-hoc-release
```

The SDK is ignored by Git and must include arm64 and x86_64 slices. Public Discord
and AniList client IDs are in `Config/Edition.xcconfig`; no client secret is used.
Their redirects are `http://127.0.0.1/callback` and `nokocord-maolist://oauth`.
Private overrides belong in ignored `Config/Local.xcconfig`. Optional
`NOKO_LASTFM_API_KEY` is embedded in the app's Info.plist; never include a shared
secret or user session token. Without a key, artwork uses the keyless backup.

The verifier checks signatures, bundle identity, helpers, runtime configuration
and shipped-byte privacy patterns. `scripts/package-release.py` creates matching
ZIP/DMG copies and checksums. The main app's reviewed library-validation exception
allows the bundled Discord SDK to load; macOS cannot scope that exception to one
framework. Translator and updater helpers do not receive it.

Run the regression checks with:

```sh
sh scripts/check-maolist-core.sh
sh scripts/check-maolist-lifecycle.sh
sh scripts/check-maomao-app-switcher.sh
sh scripts/check-workspace-toolbar.sh
```

Fixtures use disposable data. Real account actions, OS approval prompts and
visible fullscreen/layout behavior need separate live verification.

## License and attribution

NokoCord-owned code and licensable artwork use [GPL-3.0-only](LICENSE).
Required dependency notices are in `NokoCord/Resources`.
See [BRANDING.md](BRANDING.md) for artwork rights and non-affiliation.
