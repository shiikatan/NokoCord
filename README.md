# NokoCord

NokoCord is an unofficial macOS app for Discord with one persistent WebView and
optional local page modifications called Tans. Maomao is maintained by Shiikatan;
Chiaki is independent. NokoCord is not affiliated with Discord.

Maintainer contact: [shiikatan@proton.me](mailto:shiikatan@proton.me).

## Install and update

Maomao M2.6.0 requires Apple Silicon and macOS 26.6 or later. Release downloads
provide a ZIP, DMG and SHA-256 checksums. The ZIP contains `NokoCord.app` and works
with the built-in local updater. Optional Noko-Fetch downloads the latest stable
Maomao ZIP from GitHub only when requested, verifies its published checksum and
uses the same updater. There are no background update checks.

The current build is ad hoc signed and not notarized. After verifying a trusted
copy, macOS may require **System Settings → Privacy & Security → Open Anyway**.
See [Apple's instructions](https://support.apple.com/en-us/102445). This approval
does not mean Apple notarized or checked the app for malware.

## MaoList

MaoList ML2.5.0 is an optional native AniList workspace. Enable it in Settings,
then connect AniList for libraries, progress tracking, list editing and account
features. Public discovery and title details also work without an account.
Personal ratings follow your AniList score format; community averages remain
percentages. Home offers Rows and Covers layouts, and title details include
relations, people, recommendations and reviews.

Use the MaoList logo in Discord, the NokoCord logo in MaoList, or
**Control–Command–M** to switch workspaces. Loaded pages and pagination are retained
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
- General → App icon selects a native NokoCord or MaoList icon. Changing it
  uses a verified signed icon variant and relaunches the app; user data is kept.
  Only current-version switching differences are cached, not duplicate apps.
- Optional Apple Music Presence publishes your selected text, artwork and timing
  to Discord. Settings → Apple Music → Customize Rich Presence controls all three lines,
  the member-list showcase, album cover, artist photo badge and paused activity.
  The heading remains Listening to Apple Music. Custom text supports `{song}`,
  `{artist}` and `{album}`.
- The editor's sample card uses Eclipse by Pink Floyd; it never replaces actual
  playback. Its nameplate template previews the chosen member-list text without
  reading your Discord profile. Display changes save automatically.
- Artwork lookup sends track/artist/album metadata to Apple's iTunes Search.
  After a miss, Deezer receives album/artist details, then song/artist details if
  needed to match another release of the same song. Optional artist photos send
  the artist name to Deezer. Requests use no API key or user account; they are
  cached and rate limited. No scrobbling or MusicKit access is used.
- Home's optional music card reuses Presence samples without extra music polling.
  Hiding the card leaves Discord activity enabled; disabling the Tan cancels
  lookups and clears its activity.
- Tans can modify pages. Install only Tans you trust. Generated apps, browser
  profiles, caches, credentials and diagnostic captures stay outside Git.

The Discord header app button normally opens MaoList. Settings → Discord →
Navigation can change it to Home / Tans, including with Noko-Bar
hidden. Control–Command–M switches between Discord and MaoList.

Screen-sharing resolution and frame-rate controls are built into NokoCord and
work without a Tan, within Discord’s normal account limits. Requested output
still depends on WebKit, your device, and the receiving connection.

## Optional FakeNitro Tan

Install **FakeNitro** from Home’s Noko-Tans, then reload Discord. Open its
settings from **Home → Tans → FakeNitro**. It converts custom
emoji and stickers that Discord cannot send natively into media links, renders
matching links locally, and prepares animated stickers as GIF upload previews.
Native-permitted items keep their normal behavior. Optional local Discord themes,
in-app home icons, stream-quality choices and soundboard availability use guarded client hooks;
individual features remain inactive when a Discord update changes those hooks.

This does not grant a subscription, boosts, larger uploads, or server entitlements.
Other clients may see links or GIF attachments. Settings and local theme choices
stay on the device; the Tan does not read authentication tokens or make custom
authenticated message requests. Media conversion is local and bounded. It uses
the normal Discord upload preview for the final send.

Based on [Vencord FakeNitro](https://github.com/Vendicated/Vencord/tree/main/src/plugins/fakeNitro).
Source, build instructions and dependency notices are in `Tools/FakeNitro` and
`NokoCord/Resources/FakeNitro-NOTICE.txt`.

## Build and verify

Use Xcode with macOS 26.6 support and the `NokoCord` scheme. Obtain Discord Social
SDK **1.10.19337** from Discord and install its macOS package locally:

```sh
./scripts/install-discord-social-sdk.sh /path/to/discord_social_sdk
xcodebuild -project NokoCord.xcodeproj -scheme NokoCord -configuration Release \
  -destination 'platform=macOS' -derivedDataPath /tmp/NokoCord-build \
  CODE_SIGN_IDENTITY=- build
python3 scripts/build-icon-variants.py \
  /tmp/NokoCord-build/Build/Products/Release/NokoCord.app /tmp/NokoCord-icons
```

Use the signed app variants and matching small icon-switch package produced in
the output folder when preparing a release. Keep both updater ZIPs and the icon
package in that release's SHA-256 checksum list.

The SDK is ignored by Git and must include arm64 and x86_64 slices. Public Discord
and AniList client IDs are in `Config/Edition.xcconfig`; no client secret is used.
Their redirects are `http://127.0.0.1/callback` and `nokocord-maolist://oauth`.
Private overrides belong in ignored `Config/Local.xcconfig` and must never be
included in distribution source. Artwork lookup needs no private API key.

The app uses ad hoc signing for local builds. Its library-validation exception
allows the bundled Discord SDK to load; translator and updater helpers do not
receive that exception.

To regenerate the bundled translator after editing its engine, install the pinned
TypeScript dependency in `Tools/TanTranslator` and run:

```sh
node Tools/TanTranslator/build-jsc.mjs NokoCord/Resources/TanTranslatorRuntime.js
```

## License and attribution

NokoCord-owned code and licensable artwork use [GPL-3.0-only](LICENSE).
Required dependency notices are in `NokoCord/Resources`.
See [BRANDING.md](BRANDING.md) for artwork rights and non-affiliation.
