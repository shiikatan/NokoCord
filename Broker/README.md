# NokoCord OAuth broker

This optional stdlib-only service keeps the Discord confidential client secret
off the native app. Run it behind an HTTPS reverse proxy; it binds to
`127.0.0.1` by default and never emits request or token values in logs.

Set `DISCORD_CLIENT_ID`, `DISCORD_CLIENT_SECRET`, and `PUBLIC_BASE_URL` to the
HTTPS origin used by the reverse proxy. `BROKER_PORT` is optional and defaults
to `8765`. The proxy must forward `/authorize` and `/callback` and should
forward `/exchange`, `/refresh`, and `/revoke` only to the native app's trusted
local integration.

The native client generates a random `state` and PKCE verifier. It opens:

```
GET /authorize?state=<native-state>&code_challenge=<base64url(SHA256(verifier))>
```

The broker binds Discord's server state to a Secure, HttpOnly, SameSite=Lax
browser cookie. After the server-side code exchange, it redirects only to
`nokocord://oauth/callback?code=<one-use-ticket>&state=<native-state>`. The
native client sends the ticket and verifier as JSON to `POST /exchange`:

```
{"code":"<ticket>","code_verifier":"<verifier>"}
```

`POST /refresh` accepts `{"refresh_token":"..."}` and `POST /revoke` accepts
`{"token":"..."}`. All OAuth tokens and tickets are transient bounded-memory
values; authorization states and tickets expire after five minutes. There is
no CORS support and outbound HTTP redirects are disabled.

Run tests from the repository root with:

```
python3 -m unittest discover -s Broker -p 'test_*.py'
```

## Deployment boundary

This is a personal authentication service, not a multi-tenant public offering.
It requires your own HTTPS host and Discord Developer application. Register
`https://YOUR-HOST/callback` as the Discord OAuth redirect. Keep the client
secret in the server's protected environment/secret manager; never put it in
NokoCord Settings, source control, shell history, or a desktop configuration.
Start the process using `python3 Broker/oauth_broker.py` on the server.

Forward all five documented routes over TLS to the loopback listener. Disable
proxy access logs (including callback query strings), body logging, caching,
and tracing for these routes; enforce request/body/time/rate limits there too.
Do not rewrite the Secure cookie or Location header. No native client secret
or additional HTTP authentication header is part of the current Mac contract.
The ticket verifier secures exchange; the refresh token authorizes refresh.
Never expose the loopback listener directly over plaintext HTTP.

The broker trusts the actual peer address, not spoofable Forwarded headers.
Behind a proxy, its per-address limit deliberately becomes a shared service
limit (30 requests/minute). Multi-user deployment requires separately reviewed
trusted-proxy rate limiting; do not simply trust X-Forwarded-For. States and
tickets are each capped at 256, address tables at 1024, concurrency at 16.
Restarting the service invalidates pending sign-ins but not tokens already
stored in the Mac Keychain. A real Discord app and deployment are required
for live validation; unit tests use only mocked Discord responses.
