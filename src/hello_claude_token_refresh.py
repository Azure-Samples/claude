"""Long-running Claude-on-Foundry sample with automatic Entra ID token refresh.

Use this pattern for services, daemons, long-running batch jobs, and
notebooks. AnthropicFoundry invokes an Azure Identity token provider on
each request. The provider caches the token and refreshes it before expiry.
The one-shot and streaming samples use the same authentication path.
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
    if not base_url or not deployment:
        print("Set CLAUDE_BASE_URL and CLAUDE_DEPLOYMENT_NAME.", file=sys.stderr)
        return 1

    client = create_foundry_client(base_url)

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
