import base64
import hashlib
import http.client
import json
import os
import threading
import urllib.parse
import unittest
from unittest.mock import Mock, patch

from oauth_broker import Broker, BrokerConfig, BrokerHTTPServer, DiscordOAuth, HttpResponse, OAuthError, MAX_BODY


class FakeTransport:
    def __init__(self):
        self.calls = []
        self.response = HttpResponse(200, {}, b'{"access_token":"access","refresh_token":"refresh","token_type":"Bearer"}')

    def post(self, url, data, headers):
        self.calls.append((url, dict(data), dict(headers)))
        return self.response


class Clock:
    def __init__(self): self.value = 100.0
    def __call__(self): return self.value


class OAuthBrokerTests(unittest.TestCase):
    def test_dispatch_failure_releases_concurrency_slot_exactly_once(self):
        config = BrokerConfig(client_id="client", client_secret="secret", public_base_url="https://example.com")
        server = BrokerHTTPServer(("127.0.0.1", 0), Broker(config))
        try:
            request = Mock()
            with patch.object(server, "get_request", return_value=(request, ("127.0.0.1", 1234))), \
                 patch("oauth_broker.ThreadingHTTPServer.process_request", side_effect=RuntimeError("dispatch failed")):
                server._handle_request_noblock()
            for _ in range(config.max_concurrent):
                self.assertTrue(server._slots.acquire(blocking=False))
            self.assertFalse(server._slots.acquire(blocking=False))
            request.close.assert_called_once()
        finally:
            server.server_close()

    def setUp(self):
        self.config = BrokerConfig("client", "secret", "https://broker.example")
        self.transport = FakeTransport()
        self.oauth = DiscordOAuth(self.config, self.transport)
        self.clock = Clock()
        self.broker = Broker(self.config, self.oauth, self.clock)

    def test_authorization_and_ticket_pkce_one_use(self):
        verifier = "v" * 43
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        location = self.broker.start_authorization("native-state", challenge, "browser-session")
        self.assertIn("scope=identify+guilds", location)
        server_state = location.split("state=", 1)[1]
        ticket, state = self.broker.callback(server_state, "discord-code", "browser-session")
        self.assertEqual("native-state", state)
        self.assertEqual({"access_token": "access", "refresh_token": "refresh", "token_type": "Bearer"}, self.broker.exchange(ticket, verifier))
        with self.assertRaises(OAuthError):
            self.broker.exchange(ticket, verifier)

    def test_wrong_cookie_and_verifier_do_not_leak_or_consume_ticket(self):
        verifier = "v" * 43
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        location = self.broker.start_authorization("state", challenge, "session")
        server_state = location.split("state=", 1)[1]
        with self.assertRaises(OAuthError):
            self.broker.callback(server_state, "code", "wrong-session")
        # A wrong browser cookie cannot consume a valid pending authorization.
        ticket, _ = self.broker.callback(server_state, "code", "session")
        with self.assertRaises(OAuthError):
            self.broker.exchange(ticket, "wrong")
        self.assertEqual("access", self.broker.exchange(ticket, verifier)["access_token"])

    def test_expiry_capacity_and_refresh_revoke_contract(self):
        short = BrokerConfig("client", "secret", "https://broker.example", state_ttl=2, ticket_ttl=2, max_states=1, max_tickets=1)
        broker = Broker(short, self.oauth, self.clock)
        challenge = "c" * 43
        first = broker.start_authorization("s", challenge, "x")
        with self.assertRaises(OAuthError): broker.start_authorization("s2", challenge, "x")
        self.clock.value += 3
        with self.assertRaises(OAuthError): broker.callback(first.split("state=", 1)[1], "code", "x")
        self.assertEqual("access", self.oauth.refresh("refresh")["access_token"])
        self.oauth.revoke("access")
        self.assertEqual("access", self.transport.calls[-1][1]["token"])
        self.assertEqual("secret", self.transport.calls[-1][1]["client_secret"])

    def test_https_origin_validation(self):
        old = os.environ.copy()
        try:
            os.environ.update({"DISCORD_CLIENT_ID": "id", "DISCORD_CLIENT_SECRET": "secret", "PUBLIC_BASE_URL": "http://localhost"})
            with self.assertRaises(ValueError): BrokerConfig.from_env()
            os.environ["PUBLIC_BASE_URL"] = "https://localhost/path"
            with self.assertRaises(ValueError): BrokerConfig.from_env()
        finally:
            os.environ.clear(); os.environ.update(old)

    def test_local_http_contract_cookie_ticket_replay_and_body_limit(self):
        verifier = "v" * 43
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        try:
            server = BrokerHTTPServer(("127.0.0.1", 0), self.broker)
        except PermissionError:
            self.skipTest("sandbox disallows local socket binding")
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            host, port = server.server_address
            connection = http.client.HTTPConnection(host, port, timeout=2)
            connection.request("GET", "/authorize?" + urllib.parse.urlencode({"state": "native", "code_challenge": challenge}))
            response = connection.getresponse()
            self.assertEqual(302, response.status)
            cookie = response.getheader("Set-Cookie")
            location = response.getheader("Location")
            server_state = urllib.parse.parse_qs(urllib.parse.urlsplit(location).query)["state"][0]
            connection.close()
            connection = http.client.HTTPConnection(host, port, timeout=2)
            connection.request("GET", "/callback?" + urllib.parse.urlencode({"state": server_state, "code": "discord-code"}), headers={"Cookie": cookie.split(";", 1)[0]})
            response = connection.getresponse()
            self.assertEqual(302, response.status)
            ticket = urllib.parse.parse_qs(urllib.parse.urlsplit(response.getheader("Location")).query)["code"][0]
            connection.close()
            connection = http.client.HTTPConnection(host, port, timeout=2)
            body = json.dumps({"code": ticket, "code_verifier": verifier})
            connection.request("POST", "/exchange", body=body, headers={"Content-Type": "application/json", "Content-Length": str(len(body))})
            response = connection.getresponse(); response.read()
            self.assertEqual(200, response.status)
            connection.close()
            connection = http.client.HTTPConnection(host, port, timeout=2)
            connection.request("POST", "/exchange", body=body, headers={"Content-Type": "application/json"})
            response = connection.getresponse(); response.read()
            self.assertEqual(400, response.status)
            connection.close()
            connection = http.client.HTTPConnection(host, port, timeout=2)
            connection.request("POST", "/exchange", body="x" * (MAX_BODY + 1), headers={"Content-Type": "application/json", "Content-Length": str(MAX_BODY + 1)})
            response = connection.getresponse(); response.read()
            self.assertEqual(400, response.status)
            connection.close()
            connection = http.client.HTTPConnection(host, port, timeout=2)
            connection.request("POST", "/exchange", body="{}", headers={"Content-Type": "text/plain", "Content-Length": "2"})
            response = connection.getresponse(); response.read()
            self.assertEqual(400, response.status)
            connection.close()
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=2)

    def test_invalid_grant_maps_to_unauthorized_and_network_error_is_generic(self):
        self.transport.response = HttpResponse(400, {}, b'{"error":"invalid_grant"}')
        with self.assertRaises(OAuthError) as raised:
            self.oauth.exchange_code("code")
        self.assertEqual(401, raised.exception.status)

        class Broken:
            def post(self, *args): raise OSError("secret should not escape")
        with self.assertRaises(OAuthError) as raised:
            DiscordOAuth(self.config, Broken()).refresh("refresh")
        self.assertEqual(502, raised.exception.status)

    def test_upstream_rate_limit_is_bounded_and_cools_down_client(self):
        self.transport.response = HttpResponse(429, {"Retry-After": "999999"}, b"rate limited")
        with self.assertRaises(OAuthError) as raised:
            self.oauth.exchange_code("code")
        self.assertEqual(429, raised.exception.status)
        self.assertEqual(86400, raised.exception.retry_after)
        address = "127.0.0.1"
        self.broker.cooldown(address, raised.exception.retry_after)
        self.assertFalse(self.broker.allowed(address))
        self.clock.value += 86401
        self.assertTrue(self.broker.allowed(address))

    def test_fractional_and_case_insensitive_retry_after_never_rounds_down(self):
        error = DiscordOAuth._upstream_error(HttpResponse(429, {"retry-after": "1.25"}, b"{}"))
        self.assertEqual(2, error.retry_after)
        error = DiscordOAuth._upstream_error(HttpResponse(429, {}, b'{"retry_after":2.5}'))
        self.assertEqual(3, error.retry_after)
        error = DiscordOAuth._upstream_error(HttpResponse(429, {"Retry-After": "NaN"}, b"{}"))
        self.assertEqual(60, error.retry_after)


if __name__ == "__main__": unittest.main()
