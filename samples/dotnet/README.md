# C# sample: standard Anthropic SDK with explicit authentication

One console app that makes a Messages call, or a streaming call with `--stream`, using the **standard**
`AnthropicClient` from the official [`Anthropic`](https://www.nuget.org/packages/Anthropic) package
(13.3.0). Authentication comes from the official
[`Azure.Identity`](https://www.nuget.org/packages/Azure.Identity) package (1.21.0) or from an API key.
There is no `Anthropic.Foundry` package, client subclass, alternate Messages API or custom retry loop.

| File | Role |
|---|---|
| `src/AnthropicStandardSdk/ClientFactory.cs` | Generic helper. Builds the standard client with one explicit credential. Knows no identity library and reads no environment. Copy this one file (it needs only the `Anthropic` package). |
| `src/AnthropicStandardSdk/CredentialSelector.cs` | The only code that uses Azure Identity: selects one credential class and adapts it to the helper's `TokenProvider` callback. |
| `src/AnthropicStandardSdk/SampleSettings.cs`, `SampleRunner.cs`, `Program.cs` | Environment parsing, the Messages/streaming calls, output and exit codes. |
| `tests/AnthropicStandardSdk.Tests` | Offline tests: the real SDK against recording transports and loopback servers. |

## Run

Requires the .NET 8 SDK or later. For the default bearer mode sign in first (`az login`, or `azd auth login`
with `AZURE_TOKEN_CREDENTIALS=AzureDeveloperCliCredential`) in the intended tenant and subscription.

```powershell
# The `azd up` outputs as they are (the legacy profile; bearer authentication by default) ...
$env:CLAUDE_BASE_URL        = "https://<resource>.services.ai.azure.com/anthropic"
$env:CLAUDE_DEPLOYMENT_NAME = "<deployment name>"
# ... or the canonical profile, which must name its authentication mode:
#   $env:ANTHROPIC_BASE_URL = "https://<resource>.services.ai.azure.com/anthropic"
#   $env:ANTHROPIC_MODEL    = "<deployment name>"
#   $env:AUTH_MODE          = "bearer"
dotnet run --project samples/dotnet/src/AnthropicStandardSdk -- "Say hello in one sentence."
dotnet run --project samples/dotnet/src/AnthropicStandardSdk -- --stream "Say hello in one sentence."
```

Output is the response text followed by `usage: input_tokens=N output_tokens=M`. With `--stream` the text is
printed as it arrives. A response without non-blank text (for example thinking blocks only), a stream that
ends before `message_stop`, and every transport, credential or HTTP error exit non-zero and print the typed
cause and HTTP status, never a token or key. Exit codes: `0` success, `1` request failure, `2` configuration
or usage error. Each call uses `max_tokens` 1024 and a 120 second per-call timeout. The timeout is this sample's own
policy, set explicitly in `SampleRunner`; `ClientFactory` keeps the SDK's timeout unless the caller sets `Timeout`.
The SDK's default retries and cancellation behavior are unchanged.

## Configuration

Read by the sample entrypoint only (never by `ClientFactory`). Real keys and IDs belong in the environment or a
secret store, not in tracked files.

**The endpoint variable selects one profile, and the profile decides which model and key variables are read.** The two
families are never mixed, so an endpoint, deployment name or key left in the environment for another tool cannot be
paired with the wrong partner or silently receive an identity token.

| | Canonical profile | Legacy profile (`azd` outputs) |
|---|---|---|
| Selected by | `ANTHROPIC_BASE_URL` is set (it wins when both URLs are set) | only `CLAUDE_BASE_URL` is set |
| Model or deployment | `ANTHROPIC_MODEL` (required) | `CLAUDE_DEPLOYMENT_NAME` (required) |
| Key in `AUTH_MODE=api_key` | `ANTHROPIC_API_KEY` | `CLAUDE_API_KEY` |
| `AUTH_MODE` | must be set: `bearer` or `api_key` | `bearer` unless set to `api_key` |

The other family's variables are ignored, never a fallback. A missing model, key or (canonical) `AUTH_MODE` is a
configuration error, exit `2`, that names the variable.

Both profiles also read:

| Variable | Meaning | Default |
|---|---|---|
| `AZURE_TOKEN_CREDENTIALS` | One credential class: `AzureCliCredential`, `AzureDeveloperCliCredential` or `ManagedIdentityCredential`. Nothing falls back to another credential. | `AzureCliCredential` |
| `AZURE_TENANT_ID` | Tenant for the CLI credentials. | credential default |
| `AZURE_CLIENT_ID` | Client ID of a user-assigned managed identity. | system-assigned |
| `TOKEN_SCOPE` | Scope requested from the credential. | `https://ai.azure.com/.default` |
| `API_KEY_HEADER` | `Authorization` sends `Bearer <key>` (the SDK's own key semantics); any other name, such as `x-api-key`, sends the raw key. | `Authorization` |
| `ANTHROPIC_API_VERSION` | `anthropic-version` header. Unset keeps the SDK default. | unset |

The base URL must be `https` (plain `http` only for loopback test servers) and the model or deployment name is sent
verbatim. `AzureCliCredential` and `AzureDeveloperCliCredential` are built with a 60 second `ProcessTimeout`, so a slow
CLI start is not reported as a failure; `ManagedIdentityCredential` has no such option.
## Use the helper in your own code

```csharp
using AnthropicClient client = ClientFactory.Create(new ClientFactoryOptions
{
    BaseUrl = "https://<resource>.services.ai.azure.com/anthropic",
    // Exactly one credential: a per-attempt bearer callback ...
    TokenProvider = async cancellationToken =>
        (await credential.GetTokenAsync(new TokenRequestContext(["https://ai.azure.com/.default"]), cancellationToken)).Token,
    // ... or ApiKey = key, ApiKeyHeader = "x-api-key" (default header: Authorization).
});

Message message = await client.Messages.Create(new MessageCreateParams { /* standard SDK call */ });
```

`ClientFactory.Create` returns the unmodified SDK client; everything else is the SDK's own API. What it adds:

- **One explicit credential.** `ApiKey` and `AuthToken` are cleared so `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`
  and profile/federation discovery are never used. A public SDK handler that runs last, on every attempt:
  - refuses any request that is not for the configured origin (credentials are bound to it);
  - removes every credential header (`Authorization`, `x-api-key`, `api-key`), then sets only the chosen one, so
    ambient `ANTHROPIC_CUSTOM_HEADERS` or per-client extra headers cannot override it;
  - leaves other headers, such as `anthropic-beta`, untouched.
- **Origin and redirects.** `https` only (loopback `http` for tests), no user info/query/fragment in the base URL.
  The default transport does not follow redirects, and any 301/302/303/307/308 response is refused.
- **Plain token callback.** `TokenProvider` is invoked before every attempt, including SDK retries. The helper adds
  no cache, retry or token logic, and it does not use the SDK's `Credentials` provider path (which always adds the
  Anthropic-native `anthropic-beta: oauth-2025-04-20` header, keeps its own token cache and calls back with
  `forceRefresh` after a 401, none of which `TokenCredential` can honor). Token errors surface with their own type.
- **Ownership.** The caller owns the credential and disposes it; disposing the client disposes only its HTTP resources.

Token cost: the callback runs per request. `ManagedIdentityCredential` caches tokens inside Azure Identity, but a
CLI credential can start a subprocess on each call, so the per-request cost depends on the credential. This sample
reuses one credential instance and adds no cache of its own.

## Test (offline)

The tests use the real SDK against recording transports and loopback servers, with hostile canary values in
`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_PROFILE`,
`ANTHROPIC_CUSTOM_HEADERS` and the federation variables. They need no Azure account, login or model quota.

```powershell
dotnet test samples/dotnet/AnthropicStandardSdk.sln
```

## Known limits

- The SDK reads `ANTHROPIC_CUSTOM_HEADERS` once, statically, and cannot be told to ignore it. Credential header
  names from it are removed, but other custom headers set there are still sent to the bound origin.
- The sample's 120 second timeout (its own policy, see above) bounds each HTTP call, including a whole streamed response,
  not the retries.
- `AzureCliCredential` and `AzureDeveloperCliCredential` need their CLI on `PATH`; use `ManagedIdentityCredential` in
  hosted environments.
- Only the Messages and streaming calls are demonstrated. Other SDK APIs go through the same client and handler.