"""Long-running Claude-on-Foundry sample with automatic Entra ID token refresh.

Use this when your process runs for more than ~1 hour (services, daemons,
long-running batch jobs, notebooks left open). For one-shot scripts, the
plain `Anthropic(auth_token=token, ...)` flow in src/hello_claude.py is
simpler and sufficient.

## Why this exists

The plain `anthropic.Anthropic` client only accepts `auth_token: str | None`,
so a captured Entra ID token will start failing with `401 Unauthorized` after
roughly an hour.

The Anthropic SDK reads `self.auth_token` via a property on every request, so
we subclass `Anthropic` and turn it into a property that calls the Entra
token provider, giving free per-request token refresh.
"""

from __future__ import annotations

import os
import sys
from typing import Callable

from anthropic import Anthropic
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from dotenv import load_dotenv


class AnthropicIdentity(Anthropic):
    """Plain Anthropic client that pulls a fresh Entra ID token per request."""

    def __init__(
        self,
        *,
        azure_ad_token_provider: Callable[[], str],
        base_url: str,
        **kwargs,
    ) -> None:
        self._azure_ad_token_provider = azure_ad_token_provider
        # `auth_token` must be non-None so the parent's auth-header builder
        # emits the `Authorization` header. The actual token comes from our
        # property override below.
        super().__init__(auth_token="placeholder", base_url=base_url, **kwargs)

    @property
    def auth_token(self) -> str:  # type: ignore[override]
        return self._azure_ad_token_provider()

    @auth_token.setter
    def auth_token(self, _value: str | None) -> None:
        # Silently ignore the parent's `self.auth_token = ...` assignment;
        # the provider is the source of truth.
        pass


def main() -> int:
    load_dotenv(".env.local", override=False)
    load_dotenv(".env", override=False)

    base_url = os.environ.get("CLAUDE_BASE_URL")
    deployment = os.environ.get("CLAUDE_DEPLOYMENT_NAME")
    if not base_url or not deployment:
        print("Set CLAUDE_BASE_URL and CLAUDE_DEPLOYMENT_NAME.", file=sys.stderr)
        return 1

    token_provider = get_bearer_token_provider(
        DefaultAzureCredential(), "https://ai.azure.com/.default"
    )

    client = AnthropicIdentity(
        azure_ad_token_provider=token_provider,
        base_url=base_url,
    )

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
