# NokoCord branch guidance

This checkout is **Chiaki**, the experimental NokoCord edition maintained by
Millx. Work only on this branch for Chiaki changes. Do not merge or
synchronize Maomao or change the neutral `noko` landing branch as part of
ordinary Chiaki work. Do not push or publish without explicit approval for
the exact event.

Production uses one persistent Discord WKWebView. Discord owns authentication,
messages and media. Tans may modify the page under the declared lifecycle and
capability contract; never expose credentials or add a raw-user-token transport.
Do not enable dormant CEF or broker code in production.

C1.3.0 is a reliability and trust release. Safe Mode must inject no Noko
scripts or bridge handlers. Feature integrations must fail open when Discord
compatibility probes cannot prove their required anchors. Third-party
page-world Tans must not receive mutating native actions; new native behavior
requires a named, reviewed capability. Tans must bind consent to their content
hash and capability set, support atomic replacement and retain a recoverable
previous version.

Every C1.3.0 workstream must update its tests and relevant documentation, and
must check off `docs/C1.3.0_CHECKLIST.md`. Keep implementation commits
disjoint and buildable where possible. The release design and acceptance gates
live in `docs/superpowers/specs/2026-09-28-c1.3.0-design.md`.

Build the current branch with `sh scripts/verify.sh`. Preserve user sessions
and private recovery material. Stage only reviewed build, test, license and
maintenance files. Keep generated reports, local packages and agent process
notes out of the public source.

A direct maintainer request to make or create a Chiaki release authorizes the
intended release commit, annotated Chiaki tag, branch/tag push and GitHub
Release assets described by the release checklist. Do not publish unrelated
branches, editions, credentials or external services. If the request names
only a tag or branch push, do not create a GitHub Release page or upload
artifacts unless that publication is also requested.
