# Repository guide for coding agents

`noko` is the neutral landing and documentation branch. Keep it small and free
of application source, build artifacts, and edition-specific implementation.
The application source is in `maomao` and `chiaki`; these branches share one
sanitized historical source commit and evolve independently. There is no
public Base V1 branch or edition. Do not merge one edition into the other
without an explicit, reviewed request.

NokoCord uses Discord Web in one persistent WKWebView. Discord owns the signed-in
session. Local Tans are trusted page-world code and have narrow native access.
Preserve privacy, source attribution, license notices, session isolation, and
the NokoCord name. Read the edition's own `AGENTS.md` and project documents
before changing application behavior.

Do not push or publish this branch, either edition, archives, or packages
without fresh explicit approval for the exact external event.
