from __future__ import annotations

import contextlib
import importlib
import io
import json
import os
from pathlib import Path
import sys
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import httpx2 as httpx
from azure.core.credentials import AccessToken

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import client_auth
import sample_client
import token_provider
import chat_stream


BASE_URL = "https://example.services.ai.azure.com/anthropic"
DEPLOYMENT = "sample-opus-deployment"
THINKING_BLOCK = {"type": "thinking", "thinking": "not for display", "signature": "sample"}
MESSAGE = {
    "id": "msg_sample", "type": "message", "role": "assistant", "model": DEPLOYMENT,
    "content": [THINKING_BLOCK, {"type": "text", "text": "OK"}],
    "stop_reason": "end_turn", "stop_sequence": None,
    "usage": {"input_tokens": 1, "output_tokens": 2},
}


class TokenProviderTests(unittest.TestCase):
    def test_provider_is_lazy_cached_and_refreshes_before_expiry(self) -> None:
        now = time.time()
        credential = Mock(spec=["get_token"])
        credential.get_token.side_effect = [
            AccessToken("first-test-token", int(now + 3600)),
            AccessToken("refreshed-test-token", int(now + 7200)),
        ]
        provider = token_provider.cached_token_provider(
            credential, "https://ai.azure.com/.default"
        )
        credential.get_token.assert_not_called()
        self.assertEqual(provider(), "first-test-token")
        self.assertEqual(provider(), "first-test-token")
        self.assertEqual(credential.get_token.call_count, 1)
        with patch("time.time", return_value=now + 3590):
            self.assertEqual(provider(), "refreshed-test-token")
        self.assertEqual(credential.get_token.call_count, 2)
        self.assertEqual(
            credential.get_token.call_args.args, ("https://ai.azure.com/.default",)
        )
        self.assertNotIn("tenant_id", credential.get_token.call_args.kwargs)

    def test_explicit_tenant_reaches_the_credential(self) -> None:
        credential = Mock(spec=["get_token"])
        credential.get_token.return_value = AccessToken(
            "tenant-test-token", int(time.time() + 3600)
        )
        provider = token_provider.cached_token_provider(
            credential, "https://ai.azure.com/.default", tenant_id="example-tenant"
        )
        self.assertEqual(provider(), "tenant-test-token")
        self.assertEqual(credential.get_token.call_args.kwargs["tenant_id"], "example-tenant")

    def test_credential_selection_has_no_silent_fallback(self) -> None:
        with patch.object(token_provider, "AzureCliCredential") as cli:
            token_provider.create_credential("AzureCliCredential", tenant_id="example-tenant")
            cli.assert_called_once_with(tenant_id="example-tenant", process_timeout=60)
        with patch.object(token_provider, "AzureDeveloperCliCredential") as azd:
            token_provider.create_credential("AzureDeveloperCliCredential", tenant_id="example-tenant")
            azd.assert_called_once_with(tenant_id="example-tenant", process_timeout=60)
        with patch.object(token_provider, "ManagedIdentityCredential") as identity:
            token_provider.create_credential("ManagedIdentityCredential", client_id="example-client")
            identity.assert_called_once_with(client_id="example-client")
        with self.assertRaisesRegex(ValueError, "AZURE_TOKEN_CREDENTIALS"):
            token_provider.create_credential("typo")

    def test_selected_credential_constructors_work_without_patches(self) -> None:
        for source in ("AzureCliCredential", "AzureDeveloperCliCredential", "ManagedIdentityCredential"):
            with self.subTest(source=source), patch.dict(os.environ, {"AZURE_TOKEN_CREDENTIALS": source}, clear=True):
                with token_provider.create_credential(source) as credential:
                    self.assertIsInstance(credential, getattr(token_provider, source))
        with self.assertRaisesRegex(ValueError, "AZURE_TOKEN_CREDENTIALS"):
            token_provider.create_credential("DefaultAzureCredential")


class SampleTests(unittest.TestCase):
    def _transport(self, requests: list[httpx.Request]) -> httpx.MockTransport:
        def respond(request: httpx.Request) -> httpx.Response:
            requests.append(request)
            return httpx.Response(200, json=MESSAGE)
        return httpx.MockTransport(respond)

    def _environment(self):
        return patch.dict(os.environ, {
            "CLAUDE_BASE_URL": BASE_URL,
            "CLAUDE_DEPLOYMENT_NAME": DEPLOYMENT,
            "CLAUDE_API_KEY": "sample-test-key",
            "ANTHROPIC_FOUNDRY_RESOURCE": "sample-cli-resource",
        }, clear=True)

    def _client_factory(self, requests: list[httpx.Request]):
        return patch.object(
            sample_client, "create_client",
            side_effect=lambda **kwargs: client_auth.create_client(
                **kwargs, transport=self._transport(requests), max_retries=0
            ),
        )

    def test_entra_samples_handle_thinking_without_oauth_beta_headers(self) -> None:
        for name in ("hello_claude", "hello_claude_token_refresh"):
            with self.subTest(sample=name):
                requests: list[httpx.Request] = []
                output = io.StringIO()
                with (
                    self._environment(),
                    patch.object(sample_client, "load_dotenv"),
                    patch.object(sample_client, "create_credential") as credential,
                    patch.object(sample_client, "cached_token_provider", return_value=lambda: "entra-test-token"),
                    self._client_factory(requests),
                    contextlib.redirect_stdout(output),
                ):
                    self.assertEqual(importlib.import_module(name).main(), 0)
                    self.assertEqual(os.environ["ANTHROPIC_FOUNDRY_RESOURCE"], "sample-cli-resource")
                credential.return_value.__exit__.assert_called_once()
                self.assertIn("OK", output.getvalue())
                self.assertIn("[usage] input=1 output=2", output.getvalue())
                self.assertNotIn("not for display", output.getvalue())
                self.assertEqual(len(requests), 1)
                self.assertEqual(requests[0].url.path, "/anthropic/v1/messages")
                self.assertEqual(requests[0].headers["authorization"], "Bearer entra-test-token")
                self.assertNotIn("anthropic-beta", requests[0].headers)
                self.assertNotIn("x-api-key", requests[0].headers)
                self.assertEqual(json.loads(requests[0].content)["model"], DEPLOYMENT)

    def test_api_key_sample_uses_configured_header_and_handles_thinking(self) -> None:
        requests: list[httpx.Request] = []
        output = io.StringIO()
        with (
            self._environment(),
            patch.object(sample_client, "load_dotenv"),
            self._client_factory(requests),
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(importlib.import_module("hello_claude_apikey").main(), 0)
        self.assertIn("OK", output.getvalue())
        self.assertNotIn("not for display", output.getvalue())
        self.assertEqual(requests[0].headers["authorization"], "Bearer sample-test-key")
        self.assertNotIn("x-api-key", requests[0].headers)

    def test_canonical_configuration_can_target_the_native_endpoint(self) -> None:
        requests: list[httpx.Request] = []
        with (
            self._environment(),
            patch.dict(os.environ, {
                "AUTH_MODE": "api_key",
                "ANTHROPIC_BASE_URL": "https://api.anthropic.com",
                "ANTHROPIC_MODEL": "claude-sonnet-5-5",
                "ANTHROPIC_API_KEY": "native-test-key",
                "API_KEY_HEADER": "Authorization",
                "ANTHROPIC_API_VERSION": "2026-10-21",
            }),
            patch.object(sample_client, "load_dotenv"),
            self._client_factory(requests),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(importlib.import_module("hello_claude").main(), 0)
        self.assertEqual(str(requests[0].url), "https://api.anthropic.com/v1/messages")
        self.assertEqual(requests[0].headers["authorization"], "Bearer native-test-key")
        self.assertEqual(requests[0].headers["anthropic-version"], "2026-10-21")

    def test_samples_report_missing_configuration(self) -> None:
        for name in ("hello_claude", "hello_claude_token_refresh", "hello_claude_apikey", "chat_stream"):
            with self.subTest(sample=name):
                error = io.StringIO()
                with (
                    patch.dict(os.environ, {}, clear=True),
                    patch.object(sample_client, "load_dotenv"),
                    contextlib.redirect_stderr(error),
                ):
                    self.assertEqual(importlib.import_module(name).main(), 1)
                self.assertIn("Set CLAUDE_BASE_URL and CLAUDE_DEPLOYMENT_NAME", error.getvalue())

    def test_legacy_endpoint_never_uses_an_ambient_native_key(self) -> None:
        requests: list[httpx.Request] = []
        with (
            self._environment(),
            patch.dict(os.environ, {"AUTH_MODE": "api_key", "ANTHROPIC_API_KEY": "native-canary"}),
            patch.object(sample_client, "load_dotenv"),
            self._client_factory(requests),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(importlib.import_module("hello_claude").main(), 0)
        self.assertEqual(requests[0].headers["authorization"], "Bearer sample-test-key")
        self.assertNotIn("native-canary", str(requests[0].headers))

    def test_canonical_endpoint_never_falls_back_to_a_legacy_key(self) -> None:
        with (
            self._environment(),
            patch.dict(os.environ, {
                "AUTH_MODE": "api_key",
                "ANTHROPIC_BASE_URL": "https://api.anthropic.com",
                "ANTHROPIC_MODEL": "claude-test",
            }),
            patch.object(sample_client, "load_dotenv"),
            self.assertRaisesRegex(ValueError, "ANTHROPIC_API_KEY"),
        ):
            with sample_client.configured_client():
                self.fail("A key from a different profile must not be used.")

    def test_ambient_canonical_endpoint_requires_explicit_authentication(self) -> None:
        with (
            self._environment(),
            patch.dict(os.environ, {
                "ANTHROPIC_BASE_URL": "https://api.anthropic.com",
                "ANTHROPIC_MODEL": "claude-test",
            }),
            patch.object(sample_client, "load_dotenv"),
            patch.object(sample_client, "create_credential") as credential,
            self.assertRaisesRegex(ValueError, "AUTH_MODE"),
        ):
            with sample_client.configured_client():
                self.fail("An ambient endpoint must not receive the default bearer token.")
        credential.assert_not_called()

    def test_dotenv_mode_cannot_authorize_an_ambient_process_endpoint(self) -> None:
        def load_mode(*args, **kwargs) -> None:
            os.environ["AUTH_MODE"] = "bearer"
        with (
            self._environment(),
            patch.dict(os.environ, {
                "ANTHROPIC_BASE_URL": "https://api.anthropic.com",
                "ANTHROPIC_MODEL": "claude-test",
            }),
            patch.object(sample_client, "load_dotenv", side_effect=load_mode),
            patch.object(sample_client, "create_credential") as credential,
            self.assertRaisesRegex(ValueError, "process environment"),
        ):
            with sample_client.configured_client():
                self.fail("A file default must not authorize an ambient process endpoint.")
        credential.assert_not_called()

    def test_empty_canonical_endpoint_does_not_select_that_profile(self) -> None:
        requests: list[httpx.Request] = []
        with (
            self._environment(),
            patch.dict(os.environ, {"AUTH_MODE": "api_key", "ANTHROPIC_BASE_URL": ""}),
            patch.object(sample_client, "load_dotenv"),
            self._client_factory(requests),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(importlib.import_module("hello_claude").main(), 0)
        self.assertEqual(str(requests[0].url), BASE_URL + "/v1/messages")
        self.assertEqual(requests[0].headers["authorization"], "Bearer sample-test-key")

    def test_endpoint_is_validated_before_the_provider_is_warmed(self) -> None:
        provider = Mock(return_value="test-token")
        with (
            self._environment(),
            patch.dict(os.environ, {"CLAUDE_BASE_URL": "http://insecure.example"}),
            patch.object(sample_client, "load_dotenv"),
            patch.object(sample_client, "create_credential"),
            patch.object(sample_client, "cached_token_provider", return_value=provider),
            self.assertRaisesRegex(ValueError, "HTTPS"),
        ):
            with sample_client.configured_client():
                self.fail("An insecure endpoint must not be used.")
        provider.assert_not_called()

    def test_samples_report_thinking_only_responses_instead_of_succeeding(self) -> None:
        for name in ("hello_claude", "hello_claude_token_refresh", "hello_claude_apikey"):
            with self.subTest(sample=name):
                output, error = io.StringIO(), io.StringIO()
                requests: list[httpx.Request] = []
                with (
                    self._environment(),
                    patch.object(sample_client, "load_dotenv"),
                    patch.object(sample_client, "create_credential"),
                    patch.object(sample_client, "cached_token_provider", return_value=lambda: "entra-test-token"),
                    self._client_factory(requests),
                    patch.dict(MESSAGE, {"content": [THINKING_BLOCK], "stop_reason": "max_tokens"}),
                    contextlib.redirect_stdout(output),
                    contextlib.redirect_stderr(error),
                ):
                    self.assertEqual(importlib.import_module(name).main(), 1)
                self.assertIn("No text response", error.getvalue())
                self.assertIn("max_tokens", error.getvalue())
                self.assertNotIn("not for display", output.getvalue())

    def test_streaming_chat_reports_an_empty_text_stream(self) -> None:
        client = Mock()
        client.messages.stream.return_value = contextlib.nullcontext(SimpleNamespace(text_stream=iter(())))
        with (
            patch.object(chat_stream, "configured_client",
                return_value=contextlib.nullcontext((client, DEPLOYMENT))),
            patch("builtins.input", return_value="Hi"),
            contextlib.redirect_stdout(io.StringIO()),
            self.assertRaisesRegex(RuntimeError, "No text response"),
        ):
            chat_stream.main()

    def test_streaming_chat_ignores_thinking_and_sends_conversation(self) -> None:
        events = [
            ("message_start", {"message": MESSAGE | {"content": [], "stop_reason": None}}),
            ("content_block_start", {"index": 0, "content_block": {"type": "thinking", "thinking": ""}}),
            ("content_block_delta", {"index": 0, "delta": {"type": "thinking_delta", "thinking": "not for display"}}),
            ("content_block_stop", {"index": 0}),
            ("content_block_start", {"index": 1, "content_block": {"type": "text", "text": ""}}),
            ("content_block_delta", {"index": 1, "delta": {"type": "text_delta", "text": "OK"}}),
            ("content_block_stop", {"index": 1}),
            ("message_delta", {"delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 2}}),
            ("message_stop", {}),
        ]
        body = "".join(
            f"event: {name}\ndata: {json.dumps({'type': name} | data)}\n\n"
            for name, data in events
        )
        requests: list[httpx.Request] = []

        def respond(request: httpx.Request) -> httpx.Response:
            requests.append(request)
            return httpx.Response(200, headers={"content-type": "text/event-stream"}, text=body)

        output = io.StringIO()
        with (
            patch.dict(os.environ, {}, clear=True),
            client_auth.create_client(
                base_url=BASE_URL, token_provider=lambda: "entra-test-token",
                transport=httpx.MockTransport(respond), max_retries=0,
            ) as client,
            patch.object(chat_stream, "configured_client",
                return_value=contextlib.nullcontext((client, DEPLOYMENT))),
            patch("builtins.input", side_effect=["Hi", "exit"]),
            contextlib.redirect_stdout(output),
        ):
            chat_stream.main()
        self.assertIn("claude> OK", output.getvalue())
        self.assertNotIn("not for display", output.getvalue())
        self.assertEqual(
            json.loads(requests[0].content)["messages"],
            [{"role": "user", "content": "Hi"}],
        )


if __name__ == "__main__":
    unittest.main()
