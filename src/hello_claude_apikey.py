"""Quick API-key test against the deployed Claude model.

Useful when the deployer lacks a data-plane role on the Foundry account
(e.g. `Cognitive Services User`) for Entra ID auth. For production, prefer
the Entra ID flow in src/hello_claude.py.

The standard client uses an explicitly configured API-key header.
API_KEY_HEADER defaults to the current native SDK's bearer-key semantics.
"""

from __future__ import annotations

import sys

from sample_client import configured_client


def main() -> int:
    try:
        with configured_client(auth_mode="api_key") as (client, deployment):
            msg = client.messages.create(
                model=deployment,
                max_tokens=1024,
                messages=[{"role": "user", "content": "What are 3 things to visit in Seattle?"}],
            )
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
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
