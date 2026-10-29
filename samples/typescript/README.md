# TypeScript sample: standard Anthropic SDK with explicit authentication

Calls a Claude model with the stock `@anthropic-ai/sdk` client. The credential is chosen explicitly and
resolved again for every HTTP attempt: a Microsoft Entra ID bearer token (default) or an API key. There is
no SDK subclass and no provider-specific SDK package; `createClient` returns a plain `Anthropic` client, so
`messages.create`, `messages.stream`, retries and cancellation work as documented by the SDK.

| File | Purpose |
| --- | --- |
| `src/client_auth.ts` | Generic helper: `createClient(...)` builds the client (no Azure code, no environment access). |
| `src/token_provider.ts` | Selects one Azure Identity credential and wraps it with `getBearerTokenProvider`. |
| `src/sample_client.ts` | Reads the environment and builds the client for the sample. |
| `src/main.ts` | Command-line entrypoint. |
| `test/` | Offline tests: the real SDK against loopback mock servers, run with Node's built-in test runner. |

## Requirements

Node.js 24 or later. The `.ts` files run directly with Node's built-in type stripping, so there is no build
step. Tested with Node.js 24.22 and 26.13, `@anthropic-ai/sdk` 1.1.0 and `@azure/identity` 4.14.0. The SDK source
this sample relies on (the client's credential and header handling, `middleware`, the error classes and the stream
helper) is unchanged in SDK 1.3.0, but 1.3.0 itself has not been tested.

## Run

```powershell
cd samples\typescript
npm ci

$env:ANTHROPIC_BASE_URL = "https://<resource>.services.ai.azure.com/anthropic"   # or https://api.anthropic.com
$env:ANTHROPIC_MODEL = "<model or deployment name>"
$env:AUTH_MODE = "bearer"     # required with ANTHROPIC_BASE_URL: bearer or api_key
az login                      # the default credential is the Azure CLI

npm start                     # prints the reply text and token usage
npm start -- --stream         # streams the reply text as it arrives
npm start -- "Your prompt"    # any other prompt
```

```bash
cd samples/typescript && npm ci
export ANTHROPIC_BASE_URL="https://<resource>.services.ai.azure.com/anthropic"
export ANTHROPIC_MODEL="<model or deployment name>"
export AUTH_MODE=bearer
npm start
```

The starter kit's legacy variables work too: `CLAUDE_BASE_URL` and `CLAUDE_DEPLOYMENT_NAME` (see Configuration).

To reuse the starter kit's `.env.local`, let Node read it: `node --env-file=../../.env.local src/main.ts`.
Variables already set in the shell take precedence.

The command exits 0 only when the reply contains text. A reply with only thinking, an empty reply, a
configuration problem or any request error exits nonzero. Errors report the HTTP status and error type, never
the credential, the endpoint, the model name or the response body.

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
## What `createClient` guarantees

```ts
import { createClient } from './src/client_auth.ts';

const client = createClient({ baseURL, tokenProvider: () => getToken() });   // Authorization: Bearer <token>
const keyed = createClient({ baseURL, apiKey, keyHeader: 'x-api-key' });     // or a static key
```

- **One explicit credential.** `tokenProvider` is called for every HTTP attempt, including each SDK retry, so a
  renewed token is picked up. A static `apiKey` goes in `keyHeader` (`Authorization` by default).
- **No ambient credentials.** The SDK is given a non-secret placeholder key, so it never reads
  `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_PROFILE` or a profile on disk. A public `middleware`
  then replaces every credential header (`authorization`, `x-api-key`, `api-key` and the selected header) before
  each attempt, so credentials from `ANTHROPIC_CUSTOM_HEADERS`, default headers or per-request headers cannot
  reach the wire. The placeholder is never sent. Other headers, including `anthropic-beta`, are untouched.
- **No OAuth beta.** The SDK's `credentials` provider path, which adds `anthropic-beta: oauth-2025-04-20` and its
  own token cache, is not used (`client.credentials` is `null`). The helper has no cache and no retry of its own.
- **Bound to one origin.** The HTTPS base URL (loopback HTTP for local mocks) fixes the origin. A request to
  another origin, for example through `withOptions({ baseURL })` or an absolute URL, fails with `ClientAuthError`
  before anything is sent. Redirects are never followed (`redirect: 'manual'`): the SDK reports the 3xx status
  as an error and the redirect target is never contacted.
- **SDK behaviour is preserved.** The helper leaves the SDK's retry and timeout defaults alone (`maxRetries` and
  `timeoutMs` are applied only when you pass them). `AbortSignal` cancellation (also while a token is being
  acquired), status errors (`AuthenticationError`, `PermissionDeniedError`, ...) and streaming are the SDK's.
- **The 120 second limit is the sample's policy, not the helper's.** `src/main.ts` ends the whole call, including
  retries and streaming, after 120 seconds (`TOTAL_TIMEOUT_MS`, applied with `AbortSignal.timeout`) and sends
  `max_tokens` 1024.

Keep in mind:

- Middleware you add after this helper runs closer to the network and can still add headers, and
  `withOptions({ middleware })` would replace the helper's. Do not add credentials there.
- The SDK treats an error whose message or cause mentions a timeout as a request timeout and retries it, so a
  credential provider that fails with such a message is retried and can surface as `APIConnectionTimeoutError`.
- The SDK's debug logging (`ANTHROPIC_LOG=debug`) redacts a fixed list of header names (`authorization`,
  `x-api-key`, `api-key`, ...). With any other `keyHeader`, keep debug logging off.

## Tokens and caching

`getBearerTokenProvider` from `@azure/identity` is built on the `@azure/core-rest-pipeline` token cycler: it keeps
the token it received and requests a new one shortly before the credential's reported expiry (two minutes by
default), so the provider is cheap to call for every attempt. That caching comes from the helper, not from the
credential classes; for example `AzureCliCredential` runs `az account get-access-token` each time it is asked.
The tests check this behaviour with a fake credential. `createCredential` passes `AZURE_TENANT_ID` only to the
two CLI credentials and `AZURE_CLIENT_ID` only to `ManagedIdentityCredential`. The two CLI credentials also get a
60 second process timeout (`processTimeoutInMs`). `@azure/identity` sets none by default and aborting the request
does not stop a running `az` or `azd` process, so the timeout is what ends a hung one, and 60 seconds leaves room
for a slow cold start under load.

## Tests

```powershell
npm run build       # tsc: type-checks src/ and emits plain JavaScript to dist/ (node dist/main.js runs it)
npm test            # type-checks src/ and test/, then runs node --test; no network, no credentials
npm run typecheck   # tsc --noEmit (strict, erasable syntax only); npm test runs it first
```

The tests cover native and `/anthropic` paths, a fresh token for every request and retry, ambient credential and
header canaries (with a control proving the canaries are live), the selected key header and API version, no
OAuth beta, user header and beta pass-through, streaming, 401/403/429/500 statuses, cancellation and timeouts,
cross-origin and redirect safety, variable-family pairing (mixed `ANTHROPIC_*` and `CLAUDE_*` canaries),
credential selection and the command-line exit codes.