"""Small, dependency-free OAuth broker for NokoCord.

The broker is intentionally a local, narrowly scoped service.  It keeps client
credentials and OAuth tokens in bounded, short-lived process memory only.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import math
from email.utils import parsedate_to_datetime
import os
import secrets
import threading
import time
import urllib.parse
import urllib.error
import urllib.request
from collections import deque
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable, Mapping, Optional


MAX_BODY = 64 * 1024
MAX_RESPONSE = 256 * 1024
DEFAULT_TTL = 300.0
DISCORD_AUTHORIZE = "https://discord.com/oauth2/authorize"
DISCORD_TOKEN = "https://discord.com/api/v10/oauth2/token"
DISCORD_REVOKE = "https://discord.com/api/v10/oauth2/token/revoke"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _token_like(value: object, maximum: int = 512) -> bool:
    return isinstance(value, str) and 1 <= len(value) <= maximum and all(0x20 <= ord(char) < 0x7f for char in value)


def _base64url_like(value: object, maximum: int = 512) -> bool:
    return isinstance(value, str) and 1 <= len(value) <= maximum and all(("A" <= char <= "Z") or ("a" <= char <= "z") or ("0" <= char <= "9") or char in "-_" for char in value)


def _pkce_challenge(value: object) -> bool:
    return _base64url_like(value, 43) and len(value) == 43


def _pkce_verifier(value: object) -> bool:
    return isinstance(value, str) and 43 <= len(value) <= 128 and all(char.isascii() and (char.isalnum() or char in "-._~") for char in value)


@dataclass(frozen=True)
class BrokerConfig:
    client_id: str
    client_secret: str
    public_base_url: str
    state_ttl: float = DEFAULT_TTL
    ticket_ttl: float = DEFAULT_TTL
    max_states: int = 256
    max_tickets: int = 256
    rate_limit: int = 30
    rate_window: float = 60.0
    max_concurrent: int = 16
    max_addresses: int = 1024

    @classmethod
    def from_env(cls) -> "BrokerConfig":
        client_id = os.environ.get("DISCORD_CLIENT_ID", "")
        secret = os.environ.get("DISCORD_CLIENT_SECRET", "")
        base = os.environ.get("PUBLIC_BASE_URL", "").rstrip("/")
        parsed = urllib.parse.urlsplit(base)
        if not client_id or not secret or parsed.scheme != "https" or not parsed.netloc:
            raise ValueError("DISCORD_CLIENT_ID, DISCORD_CLIENT_SECRET and HTTPS PUBLIC_BASE_URL are required")
        if parsed.path not in ("", "/") or parsed.query or parsed.fragment or parsed.username or parsed.password:
            raise ValueError("PUBLIC_BASE_URL must be an HTTPS origin without credentials/query/path")
        return cls(client_id, secret, base)

    @property
    def redirect_uri(self) -> str:
        return self.public_base_url + "/callback"


@dataclass(frozen=True)
class HttpResponse:
    status: int
    headers: Mapping[str, str]
    body: bytes


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class UrllibTransport:
    """POST transport with redirects disabled and strict timeout/body limits."""

    def __init__(self, timeout: float = 10.0):
        self.timeout = timeout
        self._opener = urllib.request.build_opener(NoRedirect())

    def post(self, url: str, data: Mapping[str, str], headers: Mapping[str, str]) -> HttpResponse:
        encoded = urllib.parse.urlencode(data).encode("ascii")
        request = urllib.request.Request(url, encoded, headers=dict(headers), method="POST")
        try:
            with self._opener.open(request, timeout=self.timeout) as response:
                body = response.read(MAX_RESPONSE + 1)
                return HttpResponse(response.status, dict(response.headers.items()), body)
        except urllib.error.HTTPError as error:
            body = error.read(MAX_RESPONSE + 1)
            return HttpResponse(error.code, dict(error.headers.items()), body)


class OAuthError(Exception):
    def __init__(self, message="request failed", status=HTTPStatus.BAD_REQUEST, retry_after=None):
        super().__init__(message)
        self.status = int(status)
        self.retry_after = retry_after


class DiscordOAuth:
    def __init__(self, config: BrokerConfig, transport=None):
        self.config = config
        self.transport = transport or UrllibTransport()

    def exchange_code(self, code: str) -> dict:
        response = self._post(DISCORD_TOKEN, {
            "client_id": self.config.client_id,
            "client_secret": self.config.client_secret,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": self.config.redirect_uri,
        })
        return self._json_success(response)

    def refresh(self, refresh_token: str) -> dict:
        response = self._post(DISCORD_TOKEN, {
            "client_id": self.config.client_id,
            "client_secret": self.config.client_secret,
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
        })
        return self._json_success(response)

    def revoke(self, token: str) -> None:
        response = self._post(DISCORD_REVOKE, {
            "client_id": self.config.client_id,
            "client_secret": self.config.client_secret,
            "token": token,
        })
        if response.status < 200 or response.status >= 300:
            raise self._upstream_error(response)

    def _post(self, url, data):
        try:
            return self.transport.post(url, data, {"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json", "User-Agent": "NokoCordOAuthBroker/1.0"})
        except (OSError, TimeoutError, urllib.error.URLError):
            raise OAuthError("upstream unavailable", HTTPStatus.BAD_GATEWAY)

    @staticmethod
    def _upstream_error(response: HttpResponse) -> OAuthError:
        retry = None
        if response.status == 429:
            raw = next((value for key, value in response.headers.items() if key.lower() == "retry-after"), None)
            try:
                delay = float(raw)
            except (TypeError, ValueError):
                try:
                    delay = parsedate_to_datetime(raw).timestamp() - time.time() if raw else None
                except (TypeError, ValueError, OverflowError):
                    delay = None
                if delay is None:
                    try:
                        body = json.loads(response.body[:MAX_RESPONSE].decode("utf-8"))
                        delay = float(body.get("retry_after", 60)) if isinstance(body, dict) else 60
                    except (TypeError, ValueError, UnicodeDecodeError):
                        delay = 60
            retry = max(1, min(86400, math.ceil(delay))) if math.isfinite(delay) else 60
            return OAuthError("upstream rate limited", HTTPStatus.TOO_MANY_REQUESTS, retry)
        if response.status == 400:
            try:
                body = json.loads(response.body[:MAX_RESPONSE].decode("utf-8"))
                if isinstance(body, dict) and body.get("error") == "invalid_grant":
                    return OAuthError("invalid grant", HTTPStatus.UNAUTHORIZED)
            except (ValueError, UnicodeDecodeError):
                pass
        return OAuthError("upstream request failed", HTTPStatus.BAD_GATEWAY)

    @staticmethod
    def _json_success(response: HttpResponse) -> dict:
        if response.status < 200 or response.status >= 300 or len(response.body) > MAX_RESPONSE:
            raise DiscordOAuth._upstream_error(response)
        try:
            value = json.loads(response.body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise OAuthError("upstream request failed", HTTPStatus.BAD_GATEWAY)
        if not isinstance(value, dict):
            raise OAuthError("upstream request failed", HTTPStatus.BAD_GATEWAY)
        return value


class Broker:
    def __init__(self, config: BrokerConfig, oauth: DiscordOAuth | None = None, clock: Callable[[], float] = time.monotonic):
        self.config = config
        self.oauth = oauth or DiscordOAuth(config)
        self.clock = clock
        self._lock = threading.RLock()
        self._states = {}
        self._tickets = {}
        self._rate = {}
        self._cooldowns = {}

    def _prune(self, now: float) -> None:
        for table in (self._states, self._tickets):
            for key, item in list(table.items()):
                if item["expires"] <= now:
                    del table[key]
        for address, times in list(self._rate.items()):
            while times and times[0] <= now - self.config.rate_window:
                times.popleft()
            if not times:
                del self._rate[address]
        for address, until in list(self._cooldowns.items()):
            if until <= now:
                del self._cooldowns[address]

    def allowed(self, address: str) -> bool:
        now = self.clock()
        with self._lock:
            self._prune(now)
            if self._cooldowns.get(address, 0) > now:
                return False
            if address not in self._rate and len(self._rate) >= self.config.max_addresses:
                return False
            times = self._rate.setdefault(address, deque())
            if len(times) >= self.config.rate_limit:
                return False
            times.append(now)
            return True

    def cooldown(self, address: str, seconds: int) -> None:
        with self._lock:
            if address not in self._cooldowns and len(self._cooldowns) >= self.config.max_addresses:
                return
            self._cooldowns[address] = max(self._cooldowns.get(address, 0), self.clock() + min(86400, max(1, seconds)))

    def retry_after(self, address: str) -> int | None:
        with self._lock:
            remaining = self._cooldowns.get(address, 0) - self.clock()
            return max(1, min(86400, int(remaining + 0.999))) if remaining > 0 else None

    def start_authorization(self, native_state: str, challenge: str, session: str) -> str:
        if not _base64url_like(native_state, 512) or not _pkce_challenge(challenge) or not _base64url_like(session, 128):
            raise ValueError("invalid request")
        server_state = b64url(secrets.token_bytes(32))
        now = self.clock()
        with self._lock:
            self._prune(now)
            if len(self._states) >= self.config.max_states:
                raise OAuthError("capacity exceeded")
            self._states[server_state] = {"native_state": native_state, "challenge": challenge, "session": session, "expires": now + self.config.state_ttl}
        query = urllib.parse.urlencode({
            "client_id": self.config.client_id,
            "redirect_uri": self.config.redirect_uri,
            "response_type": "code",
            "scope": "identify guilds",
            "state": server_state,
        })
        return DISCORD_AUTHORIZE + "?" + query

    def callback(self, server_state: str, code: str, session: str) -> tuple[str, str]:
        now = self.clock()
        with self._lock:
            self._prune(now)
            item = self._states.get(server_state)
            if not item or not hmac.compare_digest(item["session"], session) or not _token_like(code, 2048):
                raise OAuthError("invalid callback")
            # Consume only after both browser binding and request validation pass.
            del self._states[server_state]
        if not item:
            raise OAuthError("invalid callback")
        token = self.oauth.exchange_code(code)
        ticket = b64url(secrets.token_bytes(32))
        with self._lock:
            self._prune(self.clock())
            if len(self._tickets) >= self.config.max_tickets:
                raise OAuthError("capacity exceeded")
            self._tickets[ticket] = {"challenge": item["challenge"], "token": token, "expires": self.clock() + self.config.ticket_ttl}
        return ticket, item["native_state"]

    def exchange(self, ticket: str, verifier: str) -> dict:
        if not _token_like(ticket, 128) or not _pkce_verifier(verifier):
            raise OAuthError("invalid exchange")
        challenge = b64url(hashlib.sha256(verifier.encode("ascii", "strict")).digest())
        now = self.clock()
        with self._lock:
            self._prune(now)
            item = self._tickets.get(ticket)
            if not item or not hmac.compare_digest(item["challenge"], challenge):
                raise OAuthError("invalid exchange")
            del self._tickets[ticket]
            return item["token"]


def _json_body(handler: BaseHTTPRequestHandler) -> dict:
    if handler.headers.get("Transfer-Encoding"):
        raise ValueError("invalid body")
    content_types = handler.headers.get_all("Content-Type", [])
    if len(content_types) != 1 or content_types[0].split(";", 1)[0].strip().lower() != "application/json":
        raise ValueError("invalid body")
    lengths = handler.headers.get_all("Content-Length", [])
    if len(lengths) != 1:
        raise ValueError("invalid body")
    raw_length = lengths[0]
    try:
        length = int(raw_length)
    except ValueError:
        raise ValueError("invalid body")
    if length < 0 or length > MAX_BODY:
        raise ValueError("invalid body")
    raw = handler.rfile.read(length)
    if len(raw) != length:
        raise ValueError("invalid body")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise ValueError("invalid body")
    if not isinstance(value, dict):
        raise ValueError("invalid body")
    return value


class BrokerHandler(BaseHTTPRequestHandler):
    server_version = "NokoCordOAuth/1"
    protocol_version = "HTTP/1.1"

    @property
    def broker(self) -> Broker:
        return self.server.broker  # type: ignore[attr-defined]

    def log_message(self, format, *args):
        return

    def _headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")

    def _error(self, status=HTTPStatus.BAD_REQUEST, retry_after=None, close=False):
        body = b'{"error":"request failed"}'
        self.send_response(status)
        self._headers()
        self.send_header("Content-Type", "application/json")
        if retry_after is not None:
            self.send_header("Retry-After", str(max(1, min(86400, int(retry_after)))))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if close:
            self.close_connection = True
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _exception(self, error, close=False):
        status = getattr(error, "status", HTTPStatus.BAD_REQUEST)
        retry = getattr(error, "retry_after", None)
        if status == HTTPStatus.TOO_MANY_REQUESTS and retry:
            self.broker.cooldown(self.client_address[0], retry)
        self._error(status, retry, close)

    def _json(self, value, status=HTTPStatus.OK):
        body = json.dumps(value, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self._headers()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self.broker.allowed(self.client_address[0]):
            return self._error(HTTPStatus.TOO_MANY_REQUESTS, self.broker.retry_after(self.client_address[0]) or 1)
        parsed = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(parsed.query, strict_parsing=False)
        try:
            if any(len(values) != 1 for values in query.values()):
                raise ValueError("invalid query")
            if parsed.path == "/authorize":
                native = query.get("state", [""])[0]
                challenge = query.get("code_challenge", [""])[0]
                session = b64url(secrets.token_bytes(32))
                location = self.broker.start_authorization(native, challenge, session)
                self.send_response(HTTPStatus.FOUND)
                self._headers()
                self.send_header("Location", location)
                self.send_header("Set-Cookie", f"nokocord_oauth={session}; Path=/; Max-Age=300; Secure; HttpOnly; SameSite=Lax")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if parsed.path == "/callback":
                server_state = query.get("state", [""])[0]
                code = query.get("code", [""])[0]
                cookies = self.headers.get("Cookie", "")
                session = ""
                for part in cookies.split(";"):
                    key, sep, value = part.strip().partition("=")
                    if sep and key == "nokocord_oauth":
                        session = value
                ticket, native_state = self.broker.callback(server_state, code, session)
                location = "nokocord://oauth/callback?" + urllib.parse.urlencode({"code": ticket, "state": native_state})
                self.send_response(HTTPStatus.FOUND)
                self._headers()
                self.send_header("Location", location)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self._error(HTTPStatus.NOT_FOUND)
        except Exception as error:
            self._exception(error)

    def do_POST(self):
        if not self.broker.allowed(self.client_address[0]):
            return self._error(HTTPStatus.TOO_MANY_REQUESTS, self.broker.retry_after(self.client_address[0]) or 1, close=True)
        try:
            payload = _json_body(self)
            path = urllib.parse.urlsplit(self.path).path
            if path == "/exchange":
                value = self.broker.exchange(payload.get("code", ""), payload.get("code_verifier", ""))
                return self._json(value)
            if path == "/refresh" and _token_like(payload.get("refresh_token")):
                return self._json(self.broker.oauth.refresh(payload["refresh_token"]))
            if path == "/revoke" and _token_like(payload.get("token")):
                self.broker.oauth.revoke(payload["token"])
                self.send_response(HTTPStatus.NO_CONTENT)
                self._headers()
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            raise ValueError("invalid request")
        except Exception as error:
            self._exception(error, close=True)


class BrokerHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, broker: Broker):
        super().__init__(address, BrokerHandler)
        self.broker = broker
        self._slots = threading.BoundedSemaphore(broker.config.max_concurrent)
        self._last_prune = broker.clock()

    def get_request(self):
        request, client_address = super().get_request()
        request.settimeout(10.0)
        return request, client_address

    def handle_error(self, request, client_address):
        # Client disconnects and timeout races are expected for a local HTTP
        # endpoint. Never print request data, exception text, or credentials.
        return

    def service_actions(self):
        now = self.broker.clock()
        if now - self._last_prune >= 5:
            with self.broker._lock:
                self.broker._prune(now)
            self._last_prune = now

    def process_request(self, request, client_address):
        if not self._slots.acquire(blocking=False):
            request.close()
            return
        # BaseServer calls shutdown_request if dispatch raises; that path owns
        # releasing the slot just as the normal worker completion does.
        super().process_request(request, client_address)

    def shutdown_request(self, request):
        try:
            super().shutdown_request(request)
        finally:
            self._slots.release()


def main() -> None:
    config = BrokerConfig.from_env()
    server = BrokerHTTPServer(("127.0.0.1", int(os.environ.get("BROKER_PORT", "8765"))), Broker(config))
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
