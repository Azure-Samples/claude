"""Streaming chat loop against a Claude deployment in Microsoft Foundry.

The Entra ID token provider caches tokens and refreshes them before expiry,
including during long-running chat sessions.
"""

from __future__ import annotations

import sys

from anthropic import Anthropic
from anthropic.types import MessageParam

from sample_client import configured_client


SYSTEM_PROMPT = (
    "You are a concise, helpful assistant running on Microsoft Foundry."
)


def _chat(client: Anthropic, deployment: str) -> None:
    history: list[MessageParam] = []
    print(f"Connected to {deployment}. Type 'exit' to quit.\n")
    while True:
        try:
            user = input("you> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if not user:
            continue
        if user.lower() in {"exit", "quit"}:
            return

        history.append({"role": "user", "content": user})
        print("claude> ", end="", flush=True)
        assistant_text = ""
        with client.messages.stream(
            model=deployment,
            max_tokens=1024,
            system=SYSTEM_PROMPT,
            messages=history,
        ) as stream:
            for text in stream.text_stream:
                assistant_text += text
                print(text, end="", flush=True)
        print()
        print()
        if not assistant_text.strip():
            raise RuntimeError(
                "No text response. Increase max_tokens if the response exhausted its budget."
            )
        history.append({"role": "assistant", "content": assistant_text})


def main() -> int:
    try:
        with configured_client() as (client, deployment):
            _chat(client, deployment)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
