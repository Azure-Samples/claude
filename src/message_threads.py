"""Two-turn Message Threads beta using the standard SDK helper."""

from __future__ import annotations

import sys

from anthropic import APIError, APIStatusError, Anthropic
from anthropic.types.beta import BetaMessage

from sample_client import configured_client

FIRST_PROMPT = "Remember the code ORCHID-47. Reply with OK."
SECOND_PROMPT = "What code did I ask you to remember? Reply with only the code."


def run_threads(client: Anthropic, deployment: str) -> BetaMessage:
    thread = client.beta.messages.thread(
        model=deployment, max_tokens=1024, system="Keep replies short."
    )
    thread.send({"role": "user", "content": FIRST_PROMPT})
    return thread.send({"role": "user", "content": SECOND_PROMPT})


def main() -> int:
    try:
        with configured_client() as (client, deployment):
            message = run_threads(client, deployment)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    except APIError as error:
        status = f" (status {error.status_code})" if isinstance(error, APIStatusError) else ""
        print(f"API request failed: {type(error).__name__}{status}", file=sys.stderr)
        return 1

    texts = [
        block.text for block in message.content
        if block.type == "text" and block.text.strip()
    ]
    if not texts:
        print(
            f"No text response (stop_reason={message.stop_reason}). "
            "Increase max_tokens if the response exhausted its budget.",
            file=sys.stderr,
        )
        return 1
    for text in texts:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
