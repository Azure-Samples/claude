"""Quick API-key test against the deployed Claude model.

Useful when the deployer lacks the 'Azure AI User' data-plane role for Entra ID
auth. For production, prefer the Entra ID flow in src/hello_claude.py.

Note: this uses the plain `Anthropic` client. For API-key auth, the Foundry
endpoint accepts the standard `x-api-key` header, so nothing Foundry-specific
is needed here.
"""

from __future__ import annotations

import os
import sys

from anthropic import Anthropic
from dotenv import load_dotenv


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

    client = Anthropic(api_key=api_key, base_url=base_url)
    msg = client.messages.create(
        model=deployment,
        max_tokens=512,
        messages=[{"role": "user", "content": "What are 3 things to visit in Seattle?"}],
    )
    for block in msg.content:
        print(block.text)
    print(f"\n[usage] input={msg.usage.input_tokens} output={msg.usage.output_tokens}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
