"""Minimal Claude-on-Foundry sample using the Claude SDK with Entra ID.

Reads configuration from environment (or .env / .env.local):
    CLAUDE_BASE_URL          e.g. https://<resource>.services.ai.azure.com/anthropic
    CLAUDE_DEPLOYMENT_NAME   the Foundry deployment name (NOT the model id)

Auth: Microsoft Entra ID via an explicitly selected credential. Run `az login`
first, or select AzureDeveloperCliCredential after `azd auth login`.
Tokens are cached and refreshed before expiry.
Set AZURE_TENANT_ID when the deployment lives in a non-default tenant.
"""

from __future__ import annotations

import sys

from sample_client import configured_client


def main() -> int:
    try:
        with configured_client() as (client, deployment):
            message = client.messages.create(
                model=deployment,
                max_tokens=1024,
                messages=[
                    {"role": "user", "content": "What are 3 things to visit in Seattle?"}
                ],
            )
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1

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
