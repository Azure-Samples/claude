from __future__ import annotations

import asyncio
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch

from anthropic import APIConnectionError, APIStatusError, Anthropic, AsyncAnthropic, DEFAULT_TIMEOUT
import httpx2 as httpx

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from client_auth import create_async_client, create_client

MESSAGE = {
    "id": "msg_test", "type": "message", "role": "assistant", "model": "claude-test",
    "content": [{"type": "text", "text": "OK"}], "stop_reason": "end_turn",
    "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1},
}
PARAMS = {"model": "claude-test", "max_tokens": 32, "messages": [{"role": "user", "content": "Hello"}]}
BASE_URL = "https://example.services.ai.azure.com/anthropic"


class ClientAuthTests(unittest.TestCase):
    def setUp(self) -> None:
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.requests: list[httpx.Request] = []

    def respond(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        return httpx.Response(200, json=MESSAGE)

    def test_returns_standard_client_and_resolves_token_for_each_request(self) -> None:
        provider = Mock(side_effect=["first-token", "second-token"])
        with create_client(base_url=BASE_URL, token_provider=provider,
            transport=httpx.MockTransport(self.respond), max_retries=0) as client:
            self.assertIs(type(client), Anthropic)
            provider.assert_not_called()
            client.messages.create(**PARAMS)
            client.messages.create(**PARAMS)
        self.assertEqual([r.headers["authorization"] for r in self.requests],
            ["Bearer first-token", "Bearer second-token"])
        self.assertEqual(str(self.requests[0].url), BASE_URL + "/v1/messages")
        self.assertTrue(all("anthropic-beta" not in request.headers for request in self.requests))

    def test_sdk_timeout_defaults_are_preserved(self) -> None:
        with create_client(base_url=BASE_URL, token_provider=lambda: "test-token",
            transport=httpx.MockTransport(self.respond)) as client:
            self.assertEqual(client.timeout, DEFAULT_TIMEOUT)

    def test_callable_truthiness_does_not_change_the_authentication_scheme(self) -> None:
        class Provider:
            def __bool__(self) -> bool:
                return False
            def __call__(self) -> str:
                return "selected-token"
        with create_client(base_url=BASE_URL, token_provider=Provider(), key_header="x-api-key",
            transport=httpx.MockTransport(self.respond), max_retries=0) as client:
            client.messages.create(**PARAMS)
        self.assertEqual(self.requests[0].headers["authorization"], "Bearer selected-token")
        self.assertNotIn("x-api-key", self.requests[0].headers)

    def test_ambient_and_per_request_credentials_cannot_override_the_provider(self) -> None:
        with (
            patch.dict(os.environ, {
                "ANTHROPIC_API_KEY": "ambient-key-canary",
                "ANTHROPIC_AUTH_TOKEN": "ambient-token-canary",
                "ANTHROPIC_PROFILE": "nonexistent-canary",
                "ANTHROPIC_BASE_URL": "https://wrong.example",
                "ANTHROPIC_CUSTOM_HEADERS": "Authorization: custom-canary\nx-api-key: key-canary\napi-key: alias-canary",
                "ANTHROPIC_FOUNDRY_RESOURCE": "unchanged-cli-resource",
            }),
            create_client(base_url=BASE_URL, token_provider=lambda: "selected-token",
                transport=httpx.MockTransport(self.respond), max_retries=0) as client,
        ):
            client.messages.create(**PARAMS, extra_headers={
                "Authorization": "request-canary", "x-api-key": "request-key-canary",
                "anthropic-beta": "a-requested-beta",
            })
            self.assertEqual(os.environ["ANTHROPIC_FOUNDRY_RESOURCE"], "unchanged-cli-resource")
        request = self.requests[0]
        self.assertEqual(request.headers["authorization"], "Bearer selected-token")
        self.assertNotIn("x-api-key", request.headers)
        self.assertNotIn("api-key", request.headers)
        self.assertEqual(request.headers["anthropic-beta"], "a-requested-beta")
        self.assertNotIn("canary", str(request.headers))

    def test_api_key_header_and_api_version_are_configuration(self) -> None:
        for base_url, header in (("https://api.anthropic.com", "Authorization"), (BASE_URL, "x-api-key")):
            with self.subTest(header=header):
                with create_client(base_url=base_url, api_key="selected-key", key_header=header,
                    api_version="2023-06-01", transport=httpx.MockTransport(self.respond),
                    max_retries=0) as client:
                    client.messages.create(**PARAMS)
                request = self.requests[-1]
                self.assertEqual(request.headers[header],
                    "Bearer selected-key" if header == "Authorization" else "selected-key")
                self.assertEqual(request.headers["anthropic-version"], "2023-06-01")
                self.assertNotIn("provided-by-request-hook", str(request.headers))
                if header == "x-api-key":
                    self.assertNotIn("authorization", request.headers)

    def test_invalid_configuration_fails_before_network(self) -> None:
        invalid = [
            {"base_url": BASE_URL},
            {"base_url": BASE_URL, "api_key": "key", "token_provider": lambda: "token"},
            {"base_url": "http://insecure.example", "api_key": "key"},
            {"base_url": "https://user:pass@example.com", "api_key": "key"},
            {"base_url": BASE_URL, "api_key": ""},
            {"base_url": BASE_URL, "api_key": "key", "key_header": "bad\nheader"},
        ]
        for options in invalid:
            with self.subTest(options={key: value for key, value in options.items() if key != "api_key"}):
                with self.assertRaises(ValueError):
                    create_client(**options)

    def test_redirect_is_not_followed(self) -> None:
        def redirect(request: httpx.Request) -> httpx.Response:
            self.requests.append(request)
            return httpx.Response(307, headers={"location": "https://untrusted.example/v1/messages"})
        with create_client(base_url=BASE_URL, token_provider=lambda: "selected-token",
            transport=httpx.MockTransport(redirect), max_retries=0) as client:
            with self.assertRaises(APIStatusError) as error:
                client.messages.create(**PARAMS)
        self.assertEqual(error.exception.status_code, 307)
        self.assertEqual(len(self.requests), 1)

    def test_copied_client_cannot_retarget_the_credentials(self) -> None:
        with create_client(base_url=BASE_URL, token_provider=lambda: "selected-token",
            transport=httpx.MockTransport(self.respond), max_retries=0) as client:
            with self.assertRaises(APIConnectionError) as error:
                client.with_options(base_url="https://untrusted.example").messages.create(**PARAMS)
        self.assertIsInstance(error.exception.__cause__, ValueError)
        self.assertEqual(self.requests, [])

    def test_provider_failure_has_a_visible_cause_and_no_request(self) -> None:
        def fail() -> str:
            raise RuntimeError("credential unavailable")
        with create_client(base_url=BASE_URL, token_provider=fail,
            transport=httpx.MockTransport(self.respond), max_retries=0) as client:
            with self.assertRaises(APIConnectionError) as error:
                client.messages.create(**PARAMS)
        self.assertIsInstance(error.exception.__cause__, RuntimeError)
        self.assertEqual(self.requests, [])

    def test_http_status_is_preserved(self) -> None:
        for status in (401, 403, 429, 500):
            with self.subTest(status=status):
                with create_client(base_url=BASE_URL, token_provider=lambda: "selected-token",
                    transport=httpx.MockTransport(lambda request: httpx.Response(status,
                        json={"type": "error", "error": {"type": "api_error", "message": "test failure"}})),
                    max_retries=0) as client:
                    with self.assertRaises(APIStatusError) as error:
                        client.messages.create(**PARAMS)
                self.assertEqual(error.exception.status_code, status)

    def test_sdk_retry_acquires_the_current_token(self) -> None:
        def respond(request: httpx.Request) -> httpx.Response:
            self.requests.append(request)
            return httpx.Response(500 if len(self.requests) == 1 else 200, json=MESSAGE)
        provider = Mock(side_effect=["first-token", "second-token"])
        with create_client(base_url=BASE_URL, token_provider=provider,
            transport=httpx.MockTransport(respond), max_retries=1) as client:
            client.messages.create(**PARAMS)
        self.assertEqual([r.headers["authorization"] for r in self.requests],
            ["Bearer first-token", "Bearer second-token"])


class AsyncClientAuthTests(unittest.IsolatedAsyncioTestCase):
    async def test_async_provider_and_standard_client(self) -> None:
        requests: list[httpx.Request] = []
        calls = 0
        async def token() -> str:
            nonlocal calls
            calls += 1
            return f"token-{calls}"
        def respond(request: httpx.Request) -> httpx.Response:
            requests.append(request)
            return httpx.Response(200, json=MESSAGE)
        with patch.dict(os.environ, {}, clear=True):
            async with create_async_client(base_url=BASE_URL, token_provider=token,
                transport=httpx.MockTransport(respond), max_retries=0) as client:
                self.assertIs(type(client), AsyncAnthropic)
                await client.messages.create(**PARAMS)
                await client.messages.create(**PARAMS)
        self.assertEqual([r.headers["authorization"] for r in requests], ["Bearer token-1", "Bearer token-2"])
        self.assertTrue(all("anthropic-beta" not in request.headers for request in requests))

    async def test_cancellation_reaches_async_provider(self) -> None:
        started = asyncio.Event()
        async def token() -> str:
            started.set()
            await asyncio.Event().wait()
            return "unreachable"
        with patch.dict(os.environ, {}, clear=True):
            async with create_async_client(base_url=BASE_URL, token_provider=token,
                transport=httpx.MockTransport(lambda request: httpx.Response(200, json=MESSAGE)),
                max_retries=0) as client:
                task = asyncio.create_task(client.messages.create(**PARAMS))
                await asyncio.wait_for(started.wait(), timeout=5)
                task.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await task


if __name__ == "__main__":
    unittest.main()
