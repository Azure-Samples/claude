from __future__ import annotations

from contextlib import nullcontext, redirect_stderr, redirect_stdout
from copy import deepcopy
import io
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

from anthropic import APIStatusError
import httpx2 as httpx

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from client_auth import create_client
import message_threads

BETA = "message-threads-2026-08-12"
MESSAGE = {
    "id": "msg_first", "type": "message", "role": "assistant", "model": "test-model",
    "content": [{"type": "text", "text": "OK"}], "stop_reason": "end_turn",
    "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1},
}
FIRST = {"role": "user", "content": message_threads.FIRST_PROMPT}
SECOND = {"role": "user", "content": message_threads.SECOND_PROMPT}


def reply(text: str = "ORCHID-47") -> httpx.Response:
    body = deepcopy(MESSAGE)
    body["id"] = "msg_second"
    body["content"] = [{"type": "text", "text": text}]
    return httpx.Response(200, json=body)


def error(status: int, code: str) -> httpx.Response:
    return httpx.Response(status, json={
        "type": "error",
        "error": {
            "type": "not_found_error" if status == 404 else "invalid_request_error",
            "message": "canary-error-body",
            "details": {"error_code": code},
        },
    })


class MessageThreadsTests(unittest.TestCase):
    def setUp(self) -> None:
        environment = patch.dict(os.environ, {}, clear=True)
        environment.start()
        self.addCleanup(environment.stop)
        self.responses = [httpx.Response(200, json=MESSAGE), reply()]
        self.requests: list[httpx.Request] = []

    def client(self):
        def respond(request: httpx.Request) -> httpx.Response:
            self.requests.append(request)
            return self.responses.pop(0)
        return create_client(
            base_url="https://example.test/anthropic",
            token_provider=lambda: "test-token",
            transport=httpx.MockTransport(respond), max_retries=0,
        )

    def run_main(self) -> tuple[int, str, str]:
        output, stderr = io.StringIO(), io.StringIO()
        with (
            self.client() as client,
            patch.object(message_threads, "configured_client", return_value=nullcontext((client, "test-model"))),
            redirect_stdout(output), redirect_stderr(stderr),
        ):
            result = message_threads.main()
        return result, output.getvalue(), stderr.getvalue()

    def test_create_and_continue_send_only_the_new_turn(self) -> None:
        with self.client() as client:
            result = message_threads.run_threads(client, "test-model")
        self.assertEqual(result.id, "msg_second")
        self.assertEqual(len(self.requests), 2)
        for request in self.requests:
            self.assertEqual(request.method, "POST")
            self.assertEqual(request.url.path, "/anthropic/v1/messages")
            self.assertEqual(request.headers["anthropic-beta"], BETA)
            self.assertEqual(request.headers["authorization"], "Bearer test-token")
            body = json.loads(request.content)
            self.assertEqual(body["model"], "test-model")
            self.assertEqual(body["max_tokens"], 1024)
        first, second = [json.loads(request.content) for request in self.requests]
        self.assertEqual(first["thread"], {"type": "create"})
        self.assertEqual(first["system"], "Keep replies short.")
        self.assertEqual(first["messages"], [FIRST])
        self.assertEqual(second["thread"], {"type": "continue", "previous_message_id": "msg_first"})
        self.assertEqual(second["messages"], [SECOND])
        self.assertNotIn("system", second)
        self.assertNotIn("tools", second)

    def test_expired_thread_replays_the_complete_transcript(self) -> None:
        self.responses.insert(1, error(404, "thread_not_found"))
        with self.client() as client:
            result = message_threads.run_threads(client, "test-model")
        self.assertEqual(result.id, "msg_second")
        self.assertEqual(len(self.requests), 3)
        replay = json.loads(self.requests[2].content)
        self.assertEqual(replay["thread"], {"type": "create"})
        self.assertEqual(replay["system"], "Keep replies short.")
        self.assertEqual(replay["messages"], [
            FIRST, {"role": "assistant", "content": MESSAGE["content"]}, SECOND,
        ])
        self.assertTrue(all(request.headers["anthropic-beta"] == BETA for request in self.requests))

    def test_unrelated_errors_do_not_replay_or_fall_back_unthreaded(self) -> None:
        for status, code in ((404, "model_not_found"), (400, "thread_unsupported_request")):
            with self.subTest(code=code):
                self.requests.clear()
                self.responses = [httpx.Response(200, json=MESSAGE), error(status, code)]
                with self.client() as client, self.assertRaises(APIStatusError):
                    message_threads.run_threads(client, "test-model")
                self.assertEqual(len(self.requests), 2)

    def test_main_prints_text_not_thinking(self) -> None:
        body = deepcopy(MESSAGE)
        body["content"] = [
            {"type": "thinking", "thinking": "not-for-display", "signature": "test"},
            {"type": "text", "text": "ORCHID-47"},
        ]
        self.responses[1] = httpx.Response(200, json=body)
        result, output, stderr = self.run_main()
        self.assertEqual((result, output, stderr), (0, "ORCHID-47\n", ""))

    def test_blank_or_thinking_only_reply_is_a_failure(self) -> None:
        for content in ([], [{"type": "text", "text": " \n "}], [
            {"type": "thinking", "thinking": "not-for-display", "signature": "test"},
        ]):
            with self.subTest(content=content):
                body = deepcopy(MESSAGE)
                body["content"] = content
                self.responses = [httpx.Response(200, json=MESSAGE), httpx.Response(200, json=body)]
                result, output, stderr = self.run_main()
                self.assertEqual((result, output), (1, ""))
                self.assertIn("stop_reason=end_turn", stderr)
                self.assertIn("max_tokens", stderr)
                self.assertNotIn("not-for-display", stderr)

    def test_api_error_reports_status_without_response_body(self) -> None:
        self.responses = [error(400, "invalid_request")]
        result, output, stderr = self.run_main()
        self.assertEqual((result, output), (1, ""))
        self.assertIn("BadRequestError (status 400)", stderr)
        self.assertNotIn("canary-error-body", stderr)

    def test_configuration_error_is_visible(self) -> None:
        stderr = io.StringIO()
        with (
            patch.object(message_threads, "configured_client", side_effect=ValueError("Set CLAUDE_BASE_URL.")),
            redirect_stderr(stderr),
        ):
            self.assertEqual(message_threads.main(), 1)
        self.assertIn("Set CLAUDE_BASE_URL.", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
