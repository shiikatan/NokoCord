# NokoCord

NokoCord is an unofficial native macOS shell for Discord. It uses one persistent
Discord Web view for the signed-in session, with local Tans for optional page
modifications. NokoCord is not affiliated with or endorsed by Discord.

## Choose an edition

- **Maomao** (`maomao` branch): stable edition, public version **M1.0.0**,
  maintained by Shiikatan.
- **Chiaki** (`chiaki` branch): experimental edition, public version **C1.0.0**,
  maintained by Millx.

This is the **Maomao** source branch. It began from the same curated source
foundation as Chiaki and evolves independently. Work in one edition is not
synchronized into the other. The `noko` branch is the neutral landing point,
not an installable public edition.

Both editions display as **NokoCord**. Their bundle identifiers and app
containers differ, so preferences, installed Tans and Discord sessions are
separate.

## Build and verify

Requires Xcode with the macOS 26.6 deployment SDK or newer. From an edition
branch, run `sh scripts/verify.sh`. It runs Swift and broker tests, Debug and
locally signed Release builds, and an exact Release app check. The translator's
JavaScript fixture suite can be run with a compatible Node runtime using
`node --test Tools/TanTranslator/translator.test.mjs`; normal app use does not
require Node or Terminal.

Local signing is not Developer ID signing or notarization. See the edition's
release notes for remaining hardware, media and signing limits.

## Architecture and trust

Discord owns authentication, messages and media. NokoCord does not extract
credentials or run a second user-token transport. Local Tans can inject JS/CSS
under a typed lifecycle and narrow native bridge. Page-world Tans are trusted
code, not a sandbox for hostile plugins. See [the Tan contract](docs/TANS.md)
and [the translator workflow](Tools/TanTranslator/README.md).

## Source and notices

NokoCord-owned code and any licensable project-artwork rights are offered under
[GPL-3.0-only](LICENSE). The bundled TypeScript runtime retains its Apache-2.0
license and third-party notices in `NokoCord/Resources`. See [BRANDING.md](BRANDING.md)
for artwork provenance and non-affiliation. Source archives should be made from
committed tracked files with `scripts/prepare-public-source.py`, then reviewed
as exact artifacts before any publication.
