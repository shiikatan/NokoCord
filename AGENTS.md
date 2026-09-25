# NokoCord branch guidance

This checkout is **Maomao**, the stable NokoCord edition maintained by
Shiikatan. Work only on this branch for Maomao changes. Do not merge or
synchronize Chiaki or change the neutral `noko` landing branch as part of
ordinary Maomao work. Do not push or publish without explicit approval for
the exact event.

Production uses one persistent Discord WKWebView. Discord owns authentication,
messages and media. Tans may modify the page under the declared lifecycle and
capability contract; never expose credentials or add a raw-user-token transport.
Do not enable dormant CEF or broker code in production.

Build the current branch with `sh scripts/verify.sh`. Preserve user sessions
and private recovery material. Stage only reviewed build, test, license and
maintenance files. Keep generated reports, local packages and agent process
notes out of the public source.
