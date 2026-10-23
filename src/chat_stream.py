"""Streaming chat loop against a Claude deployment in Microsoft Foundry.

The Entra ID token provider caches tokens and refreshes them before expiry,
including during long-running chat sessions.
"""

from __future__ import annotations

import os
import sys

from anthropic import AnthropicFoundry
from anthropic.types import MessageParam
from dotenv import load_dotenv

from claude_auth import create_foundry_client


SYSTEM_PROMPT = (
    "You are a concise, helpful assistant running on Microsoft Foundry."
)


def build_client() -> tuple[AnthropicFoundry, str]:
    load_dotenv(".env.local", override=False)
    load_dotenv(".env", override=False)

    base_url = os.environ.get("CLAUDE_BASE_URL")
    deployment = os.environ.get("CLAUDE_DEPLOYMENT_NAME")
    if not base_url or not deployment:
        print(
            "Set CLAUDE_BASE_URL and CLAUDE_DEPLOYMENT_NAME (see .env.sample).",
            file=sys.stderr,
        )
        sys.exit(1)

    return create_foundry_client(base_url), deployment


def main() -> None:
    client, deployment = build_client()
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
        print("\n")
        if not assistant_text.strip():
            raise RuntimeError(
                "No text response. Increase max_tokens if the response exhausted its budget."
            )
        history.append({"role": "assistant", "content": assistant_text})


if __name__ == "__main__":
    main()
