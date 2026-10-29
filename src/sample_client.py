"""Environment configuration shared by the Python sample entrypoints."""

from __future__ import annotations

from collections.abc import Generator
from contextlib import ExitStack, contextmanager
import os

from anthropic import Anthropic
from dotenv import load_dotenv

from client_auth import create_client
from token_provider import cached_token_provider, create_credential


@contextmanager
def configured_client(
    *, auth_mode: str | None = None
) -> Generator[tuple[Anthropic, str], None, None]:
    process_endpoint = bool(os.environ.get("ANTHROPIC_BASE_URL"))
    process_auth_mode = os.environ.get("AUTH_MODE")
    load_dotenv(".env.local", override=False)
    load_dotenv(".env", override=False)
    canonical = bool(os.environ.get("ANTHROPIC_BASE_URL"))
    base_url = os.environ.get("ANTHROPIC_BASE_URL" if canonical else "CLAUDE_BASE_URL")
    model = os.environ.get("ANTHROPIC_MODEL" if canonical else "CLAUDE_DEPLOYMENT_NAME")
    if not base_url or not model:
        raise ValueError("Set CLAUDE_BASE_URL and CLAUDE_DEPLOYMENT_NAME (or ANTHROPIC_BASE_URL and ANTHROPIC_MODEL).")
    if process_endpoint and process_auth_mode is None:
        raise ValueError("Set AUTH_MODE in the process environment with ANTHROPIC_BASE_URL.")
    mode = auth_mode or os.environ.get("AUTH_MODE")
    if canonical and mode is None:
        raise ValueError("Set AUTH_MODE explicitly when using ANTHROPIC_BASE_URL.")
    if mode is None:
        mode = "bearer"
    with ExitStack() as resources:
        provider = None
        key = None
        if mode == "bearer":
            tenant = os.environ.get("AZURE_TENANT_ID")
            credential = resources.enter_context(create_credential(
                os.environ.get("AZURE_TOKEN_CREDENTIALS", "AzureCliCredential"),
                tenant_id=tenant,
                client_id=os.environ.get("AZURE_CLIENT_ID"),
            ))
            provider = cached_token_provider(
                credential, os.environ.get("TOKEN_SCOPE", "https://ai.azure.com/.default"),
                tenant_id=tenant,
            )
        elif mode == "api_key":
            key_name = "ANTHROPIC_API_KEY" if canonical else "CLAUDE_API_KEY"
            key = os.environ.get(key_name)
            if not key:
                raise ValueError(f"Set {key_name} for the selected endpoint profile.")
        else:
            raise ValueError("AUTH_MODE must be bearer or api_key.")
        client = resources.enter_context(create_client(
            base_url=base_url,
            token_provider=provider,
            api_key=key,
            key_header=os.environ.get("API_KEY_HEADER", "Authorization"),
            api_version=os.environ.get("ANTHROPIC_API_VERSION"),
        ))
        if provider is not None:
            provider()
        yield client, model
