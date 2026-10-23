"""Cached, tenant-aware Entra ID token provider for the Foundry SDK client."""

from __future__ import annotations

import os
from collections.abc import Callable
from typing import Any

from anthropic import AnthropicFoundry
from azure.core.credentials import AccessToken
from azure.identity import DefaultAzureCredential, get_bearer_token_provider


class _TenantCredential:
    def __init__(self, credential: DefaultAzureCredential, tenant_id: str) -> None:
        self._credential = credential
        self._tenant_id = tenant_id

    def get_token(self, *scopes: str, **kwargs: Any) -> AccessToken:
        # DefaultAzureCredential does not pass AZURE_TENANT_ID to its CLI legs.
        kwargs["tenant_id"] = self._tenant_id
        return self._credential.get_token(*scopes, **kwargs)


def entra_token_provider() -> Callable[[], str]:
    credential = DefaultAzureCredential()
    tenant_id = os.environ.get("AZURE_TENANT_ID")
    if tenant_id:
        return get_bearer_token_provider(
            _TenantCredential(credential, tenant_id), "https://ai.azure.com/.default"
        )
    return get_bearer_token_provider(credential, "https://ai.azure.com/.default")


def create_foundry_client(
    base_url: str, *, api_key: str | None = None
) -> AnthropicFoundry:
    # The explicit SDK URL wins over the CLI resource alias in this process.
    os.environ.pop("ANTHROPIC_FOUNDRY_RESOURCE", None)
    if api_key is not None:
        return AnthropicFoundry(base_url=base_url, api_key=api_key)
    return AnthropicFoundry(
        base_url=base_url, azure_ad_token_provider=entra_token_provider()
    )
