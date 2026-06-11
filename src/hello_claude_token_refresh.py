"""Long-running Claude-on-Foundry sample with automatic Entra ID token refresh.

Use this when your process runs for more than ~1 hour (services, daemons,
long-running batch jobs, notebooks left open). For one-shot scripts, the
plain `Anthropic(auth_token=token, ...)` flow in src/hello_claude.py is
simpler and sufficient.

## Why this exists

The plain `anthropic.Anthropic` client's `auth_token` is a static `str`, so a
captured Entra ID token would start failing with `401 Unauthorized` after
roughly an hour.

Anthropic SDK v0.98+ added a public `credentials=` constructor argument that
takes an `AccessTokenProvider` callable. The SDK wraps it in a `TokenCache`
that calls the provider lazily, caches the result until expiry, and on a 401
invalidates the cache and retries the request once with a fresh token. That
matches exactly what we need to bridge `azure.identity` into the Anthropic
client without subclassing or shimming `auth_token`.
"""

from __future__ import annotations

import os
import sys

from anthropic import Anthropic
from anthropic.lib.credentials import AccessToken
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv


def _entra_credentials_provider(scope: str = "https://ai.azure.com/.default"):
    """Build an Anthropic `AccessTokenProvider` backed by `DefaultAzureCredential`.

    The provider is called by the SDK's `TokenCache` only when there is no
    cached token, when the cached token has expired, or when a 401 forced an
    invalidation. `azure.identity` itself also caches and refreshes tokens
    internally, so this stays cheap on the hot path.
    """
    credential = DefaultAzureCredential()

    def _provider(*, force_refresh: bool = False) -> AccessToken:
        # `force_refresh` is set by TokenCache.invalidate() after a 401.
        # DefaultAzureCredential does not expose a force-refresh knob, but
        # re-calling get_token() is enough: it will mint a new token if the
        # cached one is close to expiry, which is the common 401 cause.
        token = credential.get_token(scope)
        # `expires_on` is unix seconds — the format Anthropic's TokenCache expects.
        return AccessToken(token=token.token, expires_at=token.expires_on)

    return _provider


def main() -> int:
    load_dotenv(".env.local", override=False)
    load_dotenv(".env", override=False)

    base_url = os.environ.get("CLAUDE_BASE_URL")
    deployment = os.environ.get("CLAUDE_DEPLOYMENT_NAME")
    if not base_url or not deployment:
        print("Set CLAUDE_BASE_URL and CLAUDE_DEPLOYMENT_NAME.", file=sys.stderr)
        return 1

    client = Anthropic(
        credentials=_entra_credentials_provider(),
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
