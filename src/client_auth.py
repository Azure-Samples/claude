"""Construct standard SDK clients with explicit, renewable authentication."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
import re
from urllib.parse import urlsplit

from anthropic import Anthropic, AsyncAnthropic, DefaultAsyncHttpxClient, DefaultHttpxClient
import httpx2 as httpx


_CREDENTIAL_HEADERS = ("authorization", "x-api-key", "api-key")
_HEADER_NAME = re.compile(r"[!#$%&'*+\-.^_`|~0-9A-Za-z]+\Z")


def _validate(
    base_url: str,
    token_provider: object,
    api_key: str | None,
    key_header: str,
) -> tuple[str, str, int]:
    url = urlsplit(base_url)
    if (
        not url.hostname
        or url.username
        or url.password
        or url.query
        or url.fragment
        or (
            url.scheme != "https"
            and not (
                url.scheme == "http"
                and url.hostname in ("localhost", "127.0.0.1", "::1")
            )
        )
    ):
        raise ValueError("base_url must be an HTTPS URL without credentials, query, or fragment.")
    if (token_provider is None) == (api_key is None):
        raise ValueError("Provide exactly one of token_provider or api_key.")
    if token_provider is not None and not callable(token_provider):
        raise TypeError("token_provider must be callable.")
    if not _HEADER_NAME.fullmatch(key_header):
        raise ValueError("key_header must be a valid HTTP header name.")
    if api_key is not None:
        _validate_secret(api_key)
    return url.scheme, url.hostname, url.port or (443 if url.scheme == "https" else 80)


def _validate_secret(value: str) -> None:
    if not isinstance(value, str) or not value.strip() or "\r" in value or "\n" in value:
        raise ValueError("The credential provider must return a nonempty, single-line string.")


def _authorize(
    request: httpx.Request,
    origin: tuple[str, str, int],
    value: str,
    header: str,
) -> None:
    request_origin = (
        request.url.scheme,
        request.url.host,
        request.url.port or (443 if request.url.scheme == "https" else 80),
    )
    if request_origin != origin:
        raise ValueError("Refusing to send credentials to a different origin.")
    _validate_secret(value)
    for name in (*_CREDENTIAL_HEADERS, header):
        request.headers.pop(name, None)
    request.headers[header] = f"Bearer {value}" if header.lower() == "authorization" else value


def create_client(
    *,
    base_url: str,
    token_provider: Callable[[], str] | None = None,
    api_key: str | None = None,
    key_header: str = "Authorization",
    api_version: str | None = None,
    transport: httpx.BaseTransport | None = None,
    max_retries: int = 2,
) -> Anthropic:
    origin = _validate(base_url, token_provider, api_key, key_header)

    def authorize(request: httpx.Request) -> None:
        value = token_provider() if token_provider is not None else api_key
        if value is None:
            raise ValueError("A credential is required.")
        _authorize(request, origin, value, "Authorization" if token_provider is not None else key_header)

    http_client = DefaultHttpxClient(
        transport=transport,
        follow_redirects=False,
        event_hooks={"request": [authorize]},
    )
    # Explicit credentials suppress SDK discovery; the public hook sets the real header.
    return Anthropic(
        base_url=base_url,
        auth_token="provided-by-request-hook",
        default_headers={"anthropic-version": api_version} if api_version else None,
        http_client=http_client,
        max_retries=max_retries,
    )


def create_async_client(
    *,
    base_url: str,
    token_provider: Callable[[], Awaitable[str]] | None = None,
    api_key: str | None = None,
    key_header: str = "Authorization",
    api_version: str | None = None,
    transport: httpx.AsyncBaseTransport | None = None,
    max_retries: int = 2,
) -> AsyncAnthropic:
    origin = _validate(base_url, token_provider, api_key, key_header)

    async def authorize(request: httpx.Request) -> None:
        value = await token_provider() if token_provider is not None else api_key
        if value is None:
            raise ValueError("A credential is required.")
        _authorize(request, origin, value, "Authorization" if token_provider is not None else key_header)

    http_client = DefaultAsyncHttpxClient(
        transport=transport,
        follow_redirects=False,
        event_hooks={"request": [authorize]},
    )
    return AsyncAnthropic(
        base_url=base_url,
        auth_token="provided-by-request-hook",
        default_headers={"anthropic-version": api_version} if api_version else None,
        http_client=http_client,
        max_retries=max_retries,
    )
