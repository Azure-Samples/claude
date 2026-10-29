# Go sample: standard Anthropic SDK with explicit authentication

Calls a Claude model with the stock `github.com/anthropics/anthropic-sdk-go/v2` client. The credential is
chosen explicitly and resolved again for every HTTP attempt: a Microsoft Entra ID bearer token (default) or an
API key. There is no provider-specific SDK package; `clientauth.CreateClient` returns a plain
`anthropic.Client`, so `Messages.New`, `Messages.NewStreaming`, retries and context cancellation work as
documented by the SDK.

| Path | Purpose |
| --- | --- |
| `clientauth/client_auth.go` | Generic helper: `CreateClient(Options)` builds the client (no Azure code, no environment access). |
| `credential.go` | Selects one Azure Identity credential and turns it into a token provider. |
| `settings.go`, `sample_client.go` | Read the environment and build the client for the sample. |
| `main.go` | Command-line entrypoint. |
| `*_test.go`, `internal/testserver` | Offline tests: the real SDK against loopback servers, with the standard `testing` package. |

## Requirements

Go 1.25 or later. Tested with Go 1.27, `anthropic-sdk-go/v2` v2.4.0, `azidentity` v1.15.0 and `azcore` v1.23.3.

## Run

```powershell
cd samples\go

$env:ANTHROPIC_BASE_URL = "https://<resource>.services.ai.azure.com/anthropic"   # or https://api.anthropic.com
$env:ANTHROPIC_MODEL = "<model or deployment name>"
$env:AUTH_MODE = "bearer"     # required with ANTHROPIC_BASE_URL: bearer or api_key
az login                      # the default credential is the Azure CLI

go run .                      # prints the reply text and token usage
go run . -stream              # streams the reply text as it arrives
go run . "Your prompt"        # any other prompt (flags go before the prompt)
```

```bash
cd samples/go
export ANTHROPIC_BASE_URL="https://<resource>.services.ai.azure.com/anthropic"
export ANTHROPIC_MODEL="<model or deployment name>"
export AUTH_MODE=bearer
go run .
```

The starter kit's legacy variables work too: `CLAUDE_BASE_URL` and `CLAUDE_DEPLOYMENT_NAME` (see Configuration).

The command exits 0 only when the reply contains text. A reply with only thinking, an empty reply, a
configuration problem or any request error exits nonzero (2 for a command-line usage error). Errors report the
HTTP status and error type, never the credential, the endpoint, the model name or the response body.

## Configuration

The sample reads one of two variable families and never mixes them, so a URL, a model and a key from different
families cannot be combined: an ambient `ANTHROPIC_BASE_URL` for the native API cannot receive an Azure token, and
an ambient first-party `ANTHROPIC_API_KEY` cannot be sent to another endpoint.

| | Canonical profile | Legacy profile (starter kit) |
| --- | --- | --- |
| Selected by | `ANTHROPIC_BASE_URL`; it wins when both base URLs are set | `CLAUDE_BASE_URL`, when `ANTHROPIC_BASE_URL` is unset |
| Model | `ANTHROPIC_MODEL`, required | `CLAUDE_DEPLOYMENT_NAME`, required |
| `AUTH_MODE` | must be set explicitly: `bearer` or `api_key` | `bearer` when unset, or `api_key` |
| Key for `api_key` | `ANTHROPIC_API_KEY` only | `CLAUDE_API_KEY` only |

A missing model or key is an error that names the variable the selected profile needs; the other family's
variables are never a fallback.

These settings apply to both profiles:

| Variable | Default | Meaning |
| --- | --- | --- |
| `AZURE_TOKEN_CREDENTIALS` | `AzureCliCredential` | `AzureCliCredential`, `AzureDeveloperCliCredential` or `ManagedIdentityCredential`. Exactly one is used; there is no fallback chain. |
| `AZURE_TENANT_ID` | unset | Tenant for the two CLI credentials. |
| `AZURE_CLIENT_ID` | unset | Client ID of a user-assigned managed identity. |
| `TOKEN_SCOPE` | `https://ai.azure.com/.default` | Scope requested for the bearer token. |
| `API_KEY_HEADER` | `Authorization` | `Authorization` sends `Bearer <key>`, the SDK's own scheme. `x-api-key` (or another header name) sends the raw key. |
| `ANTHROPIC_API_VERSION` | unset | Sets `anthropic-version`. When unset the SDK's own value is used. |

The base URL must be HTTPS; plain HTTP is accepted for loopback hosts.
## What `clientauth.CreateClient` guarantees

```go
client, err := clientauth.CreateClient(clientauth.Options{
	BaseURL:       baseURL,
	TokenProvider: func(ctx context.Context) (string, error) { return token(ctx) }, // Authorization: Bearer <token>
	// or: APIKey: key, KeyHeader: "x-api-key",
})
message, err := client.Messages.New(ctx, params)
```

- **One explicit credential.** `TokenProvider` is called for every HTTP attempt, including each SDK retry, with
  that attempt's context, so a renewed token is picked up and cancellation reaches the provider. A static
  `APIKey` goes in `KeyHeader` (`Authorization` by default).
- **No ambient credentials.** `option.WithoutEnvironmentDefaults` stops the SDK from reading
  `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_PROFILE`, a profile on disk, `ANTHROPIC_BASE_URL` and
  `ANTHROPIC_CUSTOM_HEADERS`. A public middleware, registered last so that it is closest to the network, then
  replaces every credential header (`Authorization`, `X-Api-Key`, `Api-Key` and the selected header) before each
  attempt, so credentials from per-call options cannot reach the wire. Other headers, including
  `anthropic-beta`, are untouched.
- **No OAuth beta.** The SDK's credential-provider options, which add `anthropic-beta: oauth-2025-04-20` and keep
  their own token cache, are not used. The helper has no cache and no retry of its own.
- **Bound to one origin.** The HTTPS base URL (loopback HTTP for local mocks) fixes the origin. A request to
  another origin, for example `option.WithBaseURL` on a call or an absolute URL, fails with
  `ErrDifferentOrigin` before the provider is called or anything is sent. The helper's HTTP client refuses
  redirects (`ErrRedirectRefused`); a redirect target is never contacted. A client you supply through
  `Options.HTTPClient` keeps its transport but gets this redirect policy.
- **SDK behaviour is preserved.** The helper leaves the SDK's retry and timeout defaults alone (`MaxRetries` and
  `RequestTimeout` are applied only when set, and the HTTP client it installs keeps the SDK default client's
  10 minute response-header timeout). Context cancellation and deadlines, `*anthropic.Error` statuses and
  streaming are the SDK's.
- **The 120 second limit is the sample's policy, not the helper's.** `main.go` ends the whole call, including
  retries and streaming, after 120 seconds (`totalTimeout`, applied with `context.WithTimeout`) and sends
  `MaxTokens` 1024.

Keep in mind:

- The SDK treats an error returned by the helper's middleware (a failing provider, an invalid credential value,
  a different origin) as a transport error and retries it, so a failing provider is called up to
  `MaxRetries + 1` times (three by default) before the call fails. Set `MaxRetries` to 0 to fail fast. A refused
  redirect is final and is not retried.
- Do not pass `option.WithHTTPClient` or your own middleware that adds credentials to individual calls: a
  per-call HTTP client replaces the redirect policy, and middleware added later runs closer to the network than
  the helper's.

## Tokens and caching

`tokenProvider` in `credential.go` calls `GetToken` on every attempt and adds no cache or retry. What that costs
depends on the credential: `ManagedIdentityCredential` keeps the tokens it receives and refreshes them before
they expire, while `AzureCliCredential` and `AzureDeveloperCliCredential` run `az` or `azd` each time they are
asked, so every HTTP attempt with a CLI credential starts a short-lived process in the calling process. That
cost is accepted here for simplicity. `createCredential` passes `AZURE_TENANT_ID` only to the two CLI
credentials and `AZURE_CLIENT_ID` only to `ManagedIdentityCredential`.

`azidentity` offers no process-timeout option for the two CLI credentials. It bounds the `az` or `azd` call at 10
seconds only when the context it receives has no deadline; the sample's 120 second deadline is on that context, so
it applies instead. A caller that uses the helper with a context that has no deadline gets the 10 second default
and can add its own deadline.

## Tests

```powershell
go vet ./...
go test ./...       # the SDK against loopback servers; no network, no credentials
```

The tests cover native and `/anthropic` paths, a fresh token for every request and retry, ambient credential and
header canaries (with a control proving the canaries are live), the selected key header and API version, no
OAuth beta, user header and beta pass-through, streaming, 401/403/429/500 statuses, cancellation and timeouts,
cross-origin and redirect safety, variable-family pairing (mixed `ANTHROPIC_*` and `CLAUDE_*` canaries),
credential selection and the command's exit codes (the test binary starts
itself as the command).