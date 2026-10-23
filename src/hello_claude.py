"""Minimal Claude-on-Foundry sample using the Claude SDK with Entra ID.

Reads configuration from environment (or .env / .env.local):
    CLAUDE_BASE_URL          e.g. https://<resource>.services.ai.azure.com/anthropic
    CLAUDE_DEPLOYMENT_NAME   the Foundry deployment name (NOT the model id)

Auth: Microsoft Entra ID via DefaultAzureCredential. Run `az login` or
`azd auth login` first. Tokens are cached and refreshed before expiry.
Set AZURE_TENANT_ID when the deployment lives in a non-default tenant.
"""

from __future__ import annotations

import os
import sys

from dotenv import load_dotenv

from claude_auth import create_foundry_client


def main() -> int:
    # Load .env.local first (developer overrides), then .env
    load_dotenv(".env.local", override=False)
    load_dotenv(".env", override=False)

    base_url = os.environ.get("CLAUDE_BASE_URL")
    deployment = os.environ.get("CLAUDE_DEPLOYMENT_NAME")

    if not base_url or not deployment:
        print(
            "Set CLAUDE_BASE_URL and CLAUDE_DEPLOYMENT_NAME (see .env.sample).",
            file=sys.stderr,
        )
        return 1

    client = create_foundry_client(base_url)

    message = client.messages.create(
        model=deployment,
        max_tokens=1024,
        messages=[
            {"role": "user", "content": "What are 3 things to visit in Seattle?"}
        ],
    )

    has_text = False
    for block in message.content:
        if block.type == "text" and block.text.strip():
            print(block.text)
            has_text = True
    if not has_text:
        print(
            f"No text response (stop_reason={message.stop_reason}). "
            "Increase max_tokens if the response exhausted its budget.",
            file=sys.stderr,
        )
        return 1

    print(f"\n[usage] input={message.usage.input_tokens} output={message.usage.output_tokens}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
