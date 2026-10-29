"""Credential selection and cached, tenant-aware bearer-token acquisition."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from azure.core.credentials import AccessToken, TokenCredential
from azure.identity import (
    AzureCliCredential,
    AzureDeveloperCliCredential,
    ManagedIdentityCredential,
    get_bearer_token_provider,
)


def create_credential(
    source: str, *, tenant_id: str | None = None, client_id: str | None = None
) -> AzureCliCredential | AzureDeveloperCliCredential | ManagedIdentityCredential:
    if source == "AzureCliCredential":
        return AzureCliCredential(tenant_id=tenant_id or "", process_timeout=60)
    if source == "AzureDeveloperCliCredential":
        return AzureDeveloperCliCredential(tenant_id=tenant_id or "", process_timeout=60)
    if source == "ManagedIdentityCredential":
        return ManagedIdentityCredential(client_id=client_id)
    raise ValueError(
        "AZURE_TOKEN_CREDENTIALS must name AzureCliCredential, "
        "AzureDeveloperCliCredential, or ManagedIdentityCredential."
    )


class _TenantCredential:
    def __init__(self, credential: TokenCredential, tenant_id: str) -> None:
        self._credential = credential
        self._tenant_id = tenant_id

    def get_token(self, *scopes: str, **kwargs: Any) -> AccessToken:
        # Forward the selected tenant through the token-provider policy.
        kwargs["tenant_id"] = self._tenant_id
        return self._credential.get_token(*scopes, **kwargs)


def cached_token_provider(
    credential: TokenCredential, scope: str, *, tenant_id: str | None = None
) -> Callable[[], str]:
    if tenant_id:
        return get_bearer_token_provider(
            _TenantCredential(credential, tenant_id), scope
        )
    return get_bearer_token_provider(credential, scope)
