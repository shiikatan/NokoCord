# Discord Social SDK dependency

NokoCord uses Discord Social SDK 1.10.19337 as a local macOS framework. The vendor binary is not committed. Obtain the SDK separately, then run:

```sh
./scripts/install-discord-social-sdk.sh /path/to/discord_social_sdk
```

The script installs the release `discord_partner_sdk.framework` and `License-Notices.txt` at `Vendor/DiscordSocialSDK-1.10.19337/`, which is ignored by Git. The Xcode project refers to that repository-relative location, so it contains no developer-specific SDK path. The framework must include both `arm64` and `x86_64` slices.

The native wrapper constructs `discordpp::Client`, sets the application's ID, and supports rich-presence updates, clears, and `discordpp::RunCallbacks()`. It does not call `Connect()` or start OAuth. SDK operations run on one serial queue. The app owns the callback pump and should call `runCallbacks()` periodically for update results to arrive. The SDK clear method has no completion result; the wrapper's clear completion means the clear request was issued, not acknowledged by Discord.
