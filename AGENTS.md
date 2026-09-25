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

Build the current branch with `sh scripts/verify.sh`. Preserve user sessions
and private recovery material. Stage only reviewed build, test, license and
maintenance files. Keep generated reports, local packages and agent process
notes out of the public source.
