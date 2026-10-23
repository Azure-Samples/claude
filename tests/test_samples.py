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
from anthropic import AnthropicFoundry
from azure.core.credentials import AccessToken

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import claude_auth
import chat_stream


BASE_URL = "https://example.services.ai.azure.com/anthropic"
DEPLOYMENT = "sample-opus-deployment"
THINKING_BLOCK = {"type": "thinking", "thinking": "not for display", "signature": "sample"}
MESSAGE = {
    "id": "msg_sample",
    "type": "message",
    "role": "assistant",
    "model": DEPLOYMENT,
    "content": [
        THINKING_BLOCK,
        {"type": "text", "text": "OK"},
    ],
    "stop_reason": "end_turn",
    "stop_sequence": None,
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
        with (
            patch.dict(os.environ, {}, clear=True),
            patch.object(claude_auth, "DefaultAzureCredential", return_value=credential),
        ):
            provider = claude_auth.entra_token_provider()
            credential.get_token.assert_not_called()
            self.assertEqual(provider(), "first-test-token")
            self.assertEqual(provider(), "first-test-token")
            self.assertEqual(credential.get_token.call_count, 1)
            # Stay before expiry while allowing Azure Core's refresh jitter.
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
        with (
            patch.dict(os.environ, {"AZURE_TENANT_ID": "example-tenant"}, clear=True),
            patch.object(claude_auth, "DefaultAzureCredential", return_value=credential),
        ):
            provider = claude_auth.entra_token_provider()
            self.assertEqual(provider(), "tenant-test-token")
        self.assertEqual(
            credential.get_token.call_args.kwargs["tenant_id"], "example-tenant"
        )


class SampleTests(unittest.TestCase):
    def _client(self, requests: list[httpx.Request], **kwargs) -> AnthropicFoundry:
        def respond(request: httpx.Request) -> httpx.Response:
            requests.append(request)
            return httpx.Response(200, json=MESSAGE)

        return AnthropicFoundry(
            **kwargs,
            http_client=httpx.Client(transport=httpx.MockTransport(respond)),
            max_retries=0,
        )

    def test_entra_samples_handle_thinking_without_oauth_beta_headers(self) -> None:
        for name in ("hello_claude", "hello_claude_token_refresh"):
            with self.subTest(sample=name):
                module = importlib.import_module(name)
                requests: list[httpx.Request] = []
                output = io.StringIO()
                with (
                    patch.dict(
                        os.environ,
                        {
                            "CLAUDE_BASE_URL": BASE_URL,
                            "CLAUDE_DEPLOYMENT_NAME": DEPLOYMENT,
                            "ANTHROPIC_FOUNDRY_RESOURCE": "sample-cli-resource",
                        },
                        clear=True,
                    ),
                    patch.object(module, "load_dotenv"),
                    patch.object(
                        claude_auth, "entra_token_provider",
                        return_value=lambda: "entra-test-token"
                    ),
                    patch.object(
                        claude_auth,
                        "AnthropicFoundry",
                        side_effect=lambda **kwargs: self._client(requests, **kwargs),
                    ),
                    contextlib.redirect_stdout(output),
                ):
                    self.assertEqual(module.main(), 0)
                self.assertIn("OK", output.getvalue())
                self.assertIn("[usage] input=1 output=2", output.getvalue())
                self.assertNotIn("not for display", output.getvalue())
                self.assertEqual(len(requests), 1)
                request = requests[0]
                self.assertEqual(request.url.path, "/anthropic/v1/messages")
                self.assertEqual(request.headers["authorization"], "Bearer entra-test-token")
                self.assertNotIn("anthropic-beta", request.headers)
                self.assertNotIn("x-api-key", request.headers)
                self.assertEqual(json.loads(request.content)["model"], DEPLOYMENT)

    def test_api_key_sample_uses_foundry_headers_and_handles_thinking(self) -> None:
        module = importlib.import_module("hello_claude_apikey")
        requests: list[httpx.Request] = []
        output = io.StringIO()
        with (
            patch.dict(
                os.environ,
                {
                    "CLAUDE_BASE_URL": BASE_URL,
                    "CLAUDE_DEPLOYMENT_NAME": DEPLOYMENT,
                    "CLAUDE_API_KEY": "sample-test-key",
                    "ANTHROPIC_FOUNDRY_RESOURCE": "sample-cli-resource",
                },
                clear=True,
            ),
            patch.object(module, "load_dotenv"),
            patch.object(
                claude_auth,
                "AnthropicFoundry",
                side_effect=lambda **kwargs: self._client(requests, **kwargs),
            ),
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(module.main(), 0)
        self.assertIn("OK", output.getvalue())
        self.assertNotIn("not for display", output.getvalue())
        self.assertEqual(requests[0].headers["x-api-key"], "sample-test-key")
        self.assertEqual(requests[0].headers["api-key"], "sample-test-key")
        self.assertNotIn("authorization", requests[0].headers)

    def test_streaming_client_uses_explicit_url_after_cli_activation(self) -> None:
        requests: list[httpx.Request] = []
        with (
            patch.dict(
                os.environ,
                {
                    "CLAUDE_BASE_URL": BASE_URL,
                    "CLAUDE_DEPLOYMENT_NAME": DEPLOYMENT,
                    "ANTHROPIC_FOUNDRY_RESOURCE": "sample-cli-resource",
                },
                clear=True,
            ),
            patch.object(chat_stream, "load_dotenv"),
            patch.object(
                claude_auth, "entra_token_provider", return_value=lambda: "entra-test-token"
            ),
            patch.object(
                claude_auth,
                "AnthropicFoundry",
                side_effect=lambda **kwargs: self._client(requests, **kwargs),
            ),
        ):
            client, deployment = chat_stream.build_client()
            with client:
                client.messages.create(
                    model=deployment, max_tokens=16,
                    messages=[{"role": "user", "content": "Hi"}],
                )
        self.assertEqual(str(requests[0].url), BASE_URL + "/v1/messages")

    def test_samples_report_missing_configuration(self) -> None:
        for name in ("hello_claude", "hello_claude_token_refresh", "hello_claude_apikey"):
            with self.subTest(sample=name):
                module = importlib.import_module(name)
                error = io.StringIO()
                with (
                    patch.dict(os.environ, {}, clear=True),
                    patch.object(module, "load_dotenv"),
                    contextlib.redirect_stderr(error),
                ):
                    self.assertEqual(module.main(), 1)
                expected = (
                    "Set CLAUDE_BASE_URL, CLAUDE_DEPLOYMENT_NAME"
                    if name == "hello_claude_apikey"
                    else "Set CLAUDE_BASE_URL and CLAUDE_DEPLOYMENT_NAME"
                )
                self.assertIn(expected, error.getvalue())

    def test_samples_report_thinking_only_responses_instead_of_succeeding(self) -> None:
        for name in ("hello_claude", "hello_claude_token_refresh", "hello_claude_apikey"):
            with self.subTest(sample=name):
                module = importlib.import_module(name)
                output, error = io.StringIO(), io.StringIO()
                requests: list[httpx.Request] = []
                with (
                    patch.dict(
                        os.environ,
                        {
                            "CLAUDE_BASE_URL": BASE_URL,
                            "CLAUDE_DEPLOYMENT_NAME": DEPLOYMENT,
                            "CLAUDE_API_KEY": "sample-test-key",
                        },
                        clear=True,
                    ),
                    patch.object(module, "load_dotenv"),
                    patch.object(
                        claude_auth, "entra_token_provider",
                        return_value=lambda: "entra-test-token",
                    ),
                    patch.object(
                        claude_auth, "AnthropicFoundry",
                        side_effect=lambda **kwargs: self._client(requests, **kwargs),
                    ),
                    patch.dict(MESSAGE, {
                        "content": [THINKING_BLOCK], "stop_reason": "max_tokens",
                    }),
                    contextlib.redirect_stdout(output),
                    contextlib.redirect_stderr(error),
                ):
                    self.assertEqual(module.main(), 1)
                self.assertIn("No text response", error.getvalue())
                self.assertIn("max_tokens", error.getvalue())
                self.assertNotIn("not for display", output.getvalue())

    def test_streaming_chat_reports_an_empty_text_stream(self) -> None:
        client = Mock()
        client.messages.stream.return_value = contextlib.nullcontext(
            SimpleNamespace(text_stream=iter(()))
        )
        with (
            patch.object(chat_stream, "build_client", return_value=(client, DEPLOYMENT)),
            patch("builtins.input", return_value="Hi"),
            contextlib.redirect_stdout(io.StringIO()),
            self.assertRaisesRegex(RuntimeError, "No text response"),
        ):
            chat_stream.main()

    def test_streaming_chat_ignores_thinking_and_sends_conversation(self) -> None:
        events = [
            ("message_start", {"message": MESSAGE | {"content": [], "stop_reason": None}}),
            ("content_block_start", {
                "index": 0, "content_block": {"type": "thinking", "thinking": ""}
            }),
            ("content_block_delta", {
                "index": 0, "delta": {"type": "thinking_delta", "thinking": "not for display"}
            }),
            ("content_block_stop", {"index": 0}),
            ("content_block_start", {
                "index": 1, "content_block": {"type": "text", "text": ""}
            }),
            ("content_block_delta", {
                "index": 1, "delta": {"type": "text_delta", "text": "OK"}
            }),
            ("content_block_stop", {"index": 1}),
            ("message_delta", {
                "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                "usage": {"output_tokens": 2},
            }),
            ("message_stop", {}),
        ]
        body = "".join(
            f"event: {name}\ndata: {json.dumps({'type': name} | data)}\n\n"
            for name, data in events
        )
        requests: list[httpx.Request] = []

        def respond(request: httpx.Request) -> httpx.Response:
            requests.append(request)
            return httpx.Response(
                200, headers={"content-type": "text/event-stream"}, text=body
            )

        output = io.StringIO()
        with (
            patch.dict(os.environ, {}, clear=True),
            AnthropicFoundry(
                base_url=BASE_URL,
                azure_ad_token_provider=lambda: "entra-test-token",
                http_client=httpx.Client(transport=httpx.MockTransport(respond)),
                max_retries=0,
            ) as client,
            patch.object(chat_stream, "build_client", return_value=(client, DEPLOYMENT)),
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
