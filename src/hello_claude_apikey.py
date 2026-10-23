"""Quick API-key test against the deployed Claude model.

Useful when the deployer lacks a data-plane role on the Foundry account
(e.g. `Cognitive Services User`) for Entra ID auth. For production, prefer
the Entra ID flow in src/hello_claude.py.

AnthropicFoundry sends the Foundry API-key headers. The generic Anthropic
client's API-key authentication changed in SDK 2.x and is not interchangeable.
"""

from __future__ import annotations

import os
import sys

from dotenv import load_dotenv

from claude_auth import create_foundry_client


def main() -> int:
    load_dotenv(".env.local", override=False)
    load_dotenv(".env", override=False)

    base_url = os.environ.get("CLAUDE_BASE_URL")
    deployment = os.environ.get("CLAUDE_DEPLOYMENT_NAME")
    api_key = os.environ.get("CLAUDE_API_KEY")

    if not (base_url and deployment and api_key):
        print(
            "Set CLAUDE_BASE_URL, CLAUDE_DEPLOYMENT_NAME, CLAUDE_API_KEY.",
            file=sys.stderr,
        )
        return 1

    client = create_foundry_client(base_url, api_key=api_key)
    msg = client.messages.create(
        model=deployment,
        max_tokens=512,
        messages=[{"role": "user", "content": "What are 3 things to visit in Seattle?"}],
    )
    has_text = False
    for block in msg.content:
        if block.type == "text" and block.text.strip():
            print(block.text)
            has_text = True
    if not has_text:
        print(
            f"No text response (stop_reason={msg.stop_reason}). "
            "Increase max_tokens if the response exhausted its budget.",
            file=sys.stderr,
        )
        return 1
    print(f"\n[usage] input={msg.usage.input_tokens} output={msg.usage.output_tokens}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
