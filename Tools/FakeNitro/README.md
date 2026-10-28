# FakeNitro Tan build

Optional, page-world Discord compatibility Tan adapted from Vencord FakeNitro.
A Discord reload is required after installing or changing its module hooks.
Run `node Tools/FakeNitro/build.mjs` from the repository root after installing
the existing pinned TypeScript build dependency in Tools/TanTranslator.
The generated resource is shipped; no code is downloaded while using the Tan.

Upstream: https://github.com/Vendicated/Vencord/tree/main/src/plugins/fakeNitro
Vendicated and contributors, GPL-3.0-or-later; see vendor/Vencord-LICENSE.
GIF encoder: gifenc 1.0.3 by Matt DesLauriers, MIT; see vendor/gifenc-LICENSE.md.
APNG parsing/compositing is a bounded NokoCord implementation informed by
Vencord's MIT apng-canvas adaptation (David Mzareulyan).

This modifies client behavior; it does not grant a Discord subscription or
change server-enforced upload limits, boosts, or account status. Other clients
may see links or GIF attachments instead of native emoji/sticker objects.
