# Discord Social SDK dependency

NokoCord uses Discord Social SDK 1.10.19337 as a local macOS framework. The vendor binary is not committed. Obtain the SDK separately, then run:

```sh
./scripts/install-discord-social-sdk.sh /path/to/discord_social_sdk
```

The script installs the release `discord_partner_sdk.framework` and `License-Notices.txt` at `Vendor/DiscordSocialSDK-1.10.19337/`, which is ignored by Git. The Xcode project refers to that repository-relative location, so it contains no developer-specific SDK path. The framework must include both `arm64` and `x86_64` slices.

The native wrapper constructs `discordpp::Client`, sets the application's ID, and serializes OAuth, token, connection, rich-presence, and callback operations on one queue. Desktop/public-client authorization uses the SDK-generated OAuth state and PKCE verifier, `Authorize`, `GetToken`, `UpdateToken`, then `Connect`. Configure the Discord application as a public client and add the SDK's documented desktop redirect URI `http://127.0.0.1/callback` in the Developer Portal.

Access and refresh tokens are stored together in one macOS Keychain generic-password item. They are not written to preferences, property lists, files, or logs. The SDK callback pump runs while authorization or a connected session needs it. On `Ready`, the account service switches the generic transport to the authenticated session and asks `NokoActivityBridge` to reassert its current desired activity. On reconnecting, activity writes are held until the next `Ready` event. With no saved authorization, the existing desktop RPC behavior remains available.

The app target's `DiscordSocialAccountService` owns restore, refresh-token rotation, reconnect, logout, and Keychain removal. Providers remain unaware of Discord authentication and publish only normalized `NokoActivity` values through `NokoActivityBridge`. The SDK clear method has no completion result; the wrapper's clear completion means the clear request was issued, not acknowledged by Discord.

For a manual first-connection acceptance test, launch the app with `--nokocord-social-auth-smoke`. This uses the same bridge to publish `Playing NokoCord` after authenticated `Ready`; it may open the system browser for Discord consent. Do not use the older `--nokocord-activity-smoke` flag to assess independence from Discord desktop, because that test intentionally exercises the disconnected desktop-RPC path.
