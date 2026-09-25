# NokoCord

NokoCord is an unofficial native macOS shell for Discord. It keeps one
persistent Discord Web session and supports optional local page modifications
called Tans. NokoCord is not affiliated with or endorsed by Discord.

## Editions

| Edition | Purpose | Maintainer | Source |
| --- | --- | --- | --- |
| Maomao | Stable, polished; ordinary updates may be about 1–2 weeks apart | Shiikatan | [maomao branch](https://github.com/shiikatan/NokoCord/tree/maomao) |
| Chiaki | Experimental, rapid; changes may be unstable | Millx | [chiaki branch](https://github.com/shiikatan/NokoCord/tree/chiaki) |

Both editions use the NokoCord name. They have separate bundle identifiers,
containers, preferences, installed Tans, and Discord sessions. Choose the
edition that matches the experience you want. Find published packages and
checksums on the [Releases page](https://github.com/shiikatan/NokoCord/releases).
The edition source branches remain available separately.

Those cadences describe each maintainer's approach, not a support or update
promise. Initial releases have no built-in updater; install future releases
manually. This personal project has no guaranteed support or update schedule.

## Philosophy and cautions

NokoCord lets Discord own authentication, account data, messages, and media.
It adds a Mac shell and explicit local customization. Page-world Tans are
trusted code; only install code you trust. NokoCord does not extract user tokens
or claim to provide a separate Discord account service. Local signing is not
Apple notarization. See each edition's source and release notes for its exact
status and limitations.

The project is offered under [GPL-3.0-only](LICENSE) for rights its
contributors can license. Third-party components keep their own notices in the
edition source. [Branding and non-affiliation details](BRANDING.md) apply to
both editions.

## Repository structure

This `noko` branch is a neutral documentation landing page. It contains no app
source and is not an edition or a shared application base. The `maomao` and
`chiaki` branches begin at the same sanitized source commit, which remains
their historical ancestor without a permanent public branch name. Subsequent
edition work is independent; changes do not automatically flow between them.
There is no public Base V1 branch or edition.
