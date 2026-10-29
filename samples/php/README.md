# Claude on Microsoft Foundry: PHP

Calls a Claude deployment through the **standard** Anthropic PHP SDK client (`Anthropic\Client`, `anthropic-ai/sdk` `~1.3.0`). It does not use the SDK's `Anthropic\Foundry` namespace and does not subclass the client: the endpoint, the model (deployment) name and the credential are plain configuration.

| File | Purpose |
|---|---|
| `main.php` | Entry point: one Messages call, printed whole or streamed (`--stream`). |
| `src/Sample.php` | Reads the environment, builds the client, prints the text and usage. |
| `src/ClientFactory.php` | The generic helper. `ClientFactory::createClient()` returns the standard client with exactly one explicit credential. It reads no environment variables and imports no cloud-provider code. |
| `src/CliTokenProvider.php` | Token provider for local development: a command-line fallback that runs `az account get-access-token`. |
| `tests/` | Offline tests: no cloud, no credentials. |

## Prerequisites

- PHP 8.1 or later (the SDK's floor) and [Composer](https://getcomposer.org/) 2.
- A CA bundle that PHP's cURL can use. PHP for Windows has none configured, so set one up once (see [TLS certificates](#tls-certificates)); Linux and macOS builds normally use the system store without any setting.
- For `AUTH_MODE=bearer` (the legacy profile's default), the [Azure CLI](https://learn.microsoft.com/cli/azure/) signed in to the tenant that owns the deployment (`az login`).
- A deployment of a Claude model in Microsoft Foundry, and its endpoint URL.

## Install

```sh
cd samples/php
composer install
```

`composer.json` requires `anthropic-ai/sdk` and `guzzlehttp/guzzle`. The SDK needs a PSR-18 HTTP client; Guzzle is the one the SDK itself recommends.

## TLS certificates

The default transport is Guzzle on PHP's cURL extension. It verifies the endpoint's certificate against the CA bundle named by `curl.cainfo` in `php.ini`, and PHP's OpenSSL functions use `openssl.cafile`. PHP for Windows leaves both empty, so the first call can fail with `cURL error 60: SSL certificate problem: unable to get local issuer certificate`. Never switch verification off; give PHP a CA bundle you trust instead:

1. Get a bundle. The Mozilla bundle that the curl project publishes as `cacert.pem` ([curl.se/docs/caextract.html](https://curl.se/docs/caextract.html)) is the usual choice: check it against the SHA-256 checksum published next to it, and keep it outside this repository. Behind a proxy that inspects TLS, use your organization's bundle instead; it has to contain the proxy's root certificate.
2. Point both settings at it, in the `php.ini` that `php --ini` reports as loaded:

   ```ini
   curl.cainfo = "<path to>\cacert.pem"
   openssl.cafile = "<path to>\cacert.pem"
   ```

   or for a single run, without editing `php.ini`:

   ```powershell
   php -d "curl.cainfo=<path to>\cacert.pem" -d "openssl.cafile=<path to>\cacert.pem" main.php
   ```

Nothing in this sample touches TLS verification: it is Guzzle's default (on), or whatever the PSR-18 client you pass to `ClientFactory::createClient()` does.

## Configure

The endpoint, model and key come from one of two profiles that **never borrow from each other**, so a secret can never be paired with the endpoint of the other family:

| | Canonical profile | Legacy profile |
|---|---|---|
| Selected when | `ANTHROPIC_BASE_URL` is set (it wins when both URLs are set) | only `CLAUDE_BASE_URL` is set |
| Endpoint | `ANTHROPIC_BASE_URL` | `CLAUDE_BASE_URL` |
| Model or deployment | `ANTHROPIC_MODEL` (required) | `CLAUDE_DEPLOYMENT_NAME` (required) |
| Key for `AUTH_MODE=api_key` | `ANTHROPIC_API_KEY` only | `CLAUDE_API_KEY` only |
| `AUTH_MODE` when unset | **error**: set `AUTH_MODE=api_key` or `AUTH_MODE=bearer` explicitly | `bearer` |

A missing model, key or (canonical profile) `AUTH_MODE` is an error that names what it needs; the sample never falls back to the other profile's value. Because the canonical profile has no default mode, an ambient native `ANTHROPIC_BASE_URL` and `ANTHROPIC_MODEL` can neither silently receive an Azure token nor silently pick up a native key: you choose `api_key` (uses `ANTHROPIC_API_KEY`) or `bearer` (uses an Azure CLI token) on purpose. An ambient `ANTHROPIC_API_KEY` is ignored when `CLAUDE_BASE_URL` selects the legacy profile.

These settings are shared by both profiles:

| Variable | Default | Purpose |
|---|---|---|
| `AUTH_MODE` | legacy: `bearer`; canonical: none, must be set | `bearer`: a Microsoft Entra ID token from the Azure CLI. `api_key`: a static key. |
| `API_KEY_HEADER` | `Authorization` | Header that carries the key. `Authorization` sends `Bearer <key>`, the current SDK's native behavior; any other name (for example `x-api-key`) sends the raw key. |
| `ANTHROPIC_API_VERSION` | unset | Unset keeps the SDK's default `anthropic-version`. Set it to override (for example `2023-06-01`). |
| `TOKEN_SCOPE` | `https://ai.azure.com/.default` | Scope requested from the Azure CLI. |
| `AZURE_TENANT_ID` | unset | Adds `--tenant` to the Azure CLI call. |
| `AZURE_TOKEN_CREDENTIALS` | unset | Credential selector shared with the other language samples. Only `AzureCliCredential` (also the default) is implemented here: any other value (`ManagedIdentityCredential`, `AzureDeveloperCliCredential`, `DefaultAzureCredential`, a typo) is rejected with an error instead of being ignored or answered with the CLI. Ignored in `api_key` mode. For managed identity, workload identity, `azd` or any other credential, pass your own token provider. |

The endpoint must be HTTPS; plain HTTP is accepted for loopback hosts. To load the values that `azd env get-values > .env.local` wrote at the repository root (legacy `CLAUDE_*` names):

```powershell
# PowerShell, from samples/php
Get-Content ..\..\.env.local | ForEach-Object { if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { Set-Item "env:$($Matches[1])" $Matches[2].Trim('"') } }
```

```sh
# bash
set -a; . ../../.env.local; set +a
```

## Run

```sh
php main.php            # one Messages call
php main.php --stream   # the same request, streamed as it is generated
```

Both modes print only the text, then the token usage (the sample waits up to 120 seconds per request):

```text
<the model's answer>

[usage] input=<n> output=<n>
```

Thinking blocks are not printed. A response without any text fails with a message and a non-zero exit status instead of reporting success; so do API errors, credential failures and bad configuration (exit status 1; an unknown argument exits with 2). A failure prints `Error: ...` and then one `  caused by: ...` line per underlying error (for example the transport error behind an `APIConnectionException`), with credentials and token-like strings replaced by `[redacted]`.

## Authentication

**`AUTH_MODE=bearer` is a local-development fallback** (the legacy profile's default; the canonical profile needs it set explicitly). The sample runs `az account get-access-token --scope <TOKEN_SCOPE> --output json` (adding `--tenant <AZURE_TENANT_ID>` when set) for every token request and sends the returned `accessToken` as `Authorization: Bearer`. The Azure CLI owns token caching and renewal; the sample keeps no cache. The price is one CLI process per HTTP attempt, which takes seconds on a typical machine.

- The command is a fixed argument list, never shell text. Every argument must match `[A-Za-z0-9._:/-]+`, so quotes, spaces and shell or `cmd.exe` metacharacters are rejected before anything starts.
- On Windows the CLI is usually a batch file (`az.cmd` or `az.bat`). The sample finds it on `PATH` (honoring `PATHEXT`, absolute entries only) and starts it as `cmd.exe /d /c az.cmd ...` from its own directory with that fixed argument list.
- Each CLI process has a finite allowance of 60 seconds (a cold start under load can exceed the 10 seconds some identity libraries allow). When it runs out, the process, and on Windows its children, is stopped and the sample fails with a timeout error. It never falls back to another credential.
- A non-zero exit status, output that is not a JSON object, or a missing or empty `accessToken` raises a clear error. The error never contains the CLI's output, and the token is never printed, logged or written to a file.

**For production, pass your own token provider.** `ClientFactory::createClient()` accepts any `callable(): string` that returns the current token, for example one backed by your identity library (managed identity, workload identity, and so on). No officially supported Microsoft Azure Identity library for PHP was identified when this sample was written, and the sample neither depends on nor endorses a third-party one. Because the provider runs on every HTTP attempt, it should be cheap or cache internally.

**`AUTH_MODE=api_key`** sends a static key in the header named by `API_KEY_HEADER`. Use it for development and testing.

## What the helper guarantees

`ClientFactory::createClient()` returns a plain `Anthropic\Client` and uses only public SDK features (a request middleware and a PSR-18 transport option):

- **Exactly one credential.** The SDK is given a public, non-secret placeholder token, solely to stop it from discovering `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_PROFILE`, workload identity variables or profiles on disk. A middleware that runs on every HTTP attempt (retries and redirect hops included) removes `Authorization`, `x-api-key` and `api-key`, whatever put them there (including `ANTHROPIC_CUSTOM_HEADERS` and per-request headers), and applies the selected credential. The placeholder never reaches the wire. All other headers, including `anthropic-beta` values you pass, are preserved.
- **No OAuth beta.** A plain bearer token is sent without `anthropic-beta: oauth-2025-04-20`.
- **One origin.** The base URL must be HTTPS (loopback may use HTTP) and may not carry credentials, a query or a fragment. A redirect to a different scheme, host or port is refused before any credential is produced.
- **SDK defaults kept.** The factory adds no retry, refresh or cache of its own, and sets no retry count or timeout unless you pass `maxRetries:` or `timeout:`. The SDK's retries (2) and its documented 600 second request timeout apply; because the PHP SDK leaves timeouts to the PSR-18 client, the default Guzzle transport is created with that value and does not follow redirects. `anthropic-version` is the SDK's default unless you pass `apiVersion:`.
- **The sample's own policy.** `Sample` passes `timeout: 120` (`Sample::REQUEST_TIMEOUT_SECONDS`) so a stuck request ends after two minutes. That is an application choice made visibly in `src/Sample.php`, not something the factory does for you.

```php
use ClaudeSample\ClientFactory;

$client = ClientFactory::createClient(
    baseUrl: 'https://<resource>.services.ai.azure.com/anthropic',
    tokenProvider: static fn (): string => $identity->currentAccessToken(),
);
$message = $client->messages->create(
    maxTokens: 1024,
    messages: [['role' => 'user', 'content' => 'Hello']],
    model: '<deployment>',
);
```

## Tests

```sh
composer test
# which runs: php -d zend.assertions=1 -d assert.exception=1 tests/run.php
```

The suite uses PHP's built-in `assert()` (the runner refuses to start with assertions off, which would pass silently) and needs no framework. It runs offline:

- a recording PSR-18 transport checks the request the SDK builds: the Foundry-style and native paths and the model, a rotating bearer token, a resource key in `x-api-key` and the native `Authorization` key, the API version, no OAuth beta, canaries for `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_PROFILE`, `ANTHROPIC_BASE_URL` and `ANTHROPIC_CUSTOM_HEADERS` (with a control showing the SDK defaults would send them), streaming, HTTP error statuses, retries that fetch a fresh token, and redirects;
- the token provider (`CliTokenProvider`) is tested with a fake process runner and with a fixture `az` (a `.cmd` on Windows, a shell script elsewhere) that is really launched;
- the entry point is tested end to end, including mixed-family canaries (decoy `ANTHROPIC_*` and `CLAUDE_*` values must never be paired with the other profile's endpoint, model or key) and the 120 second policy; the error output (the cause chain behind a connection failure, credential redaction, the certificate hint) is tested with synthetic failures and with a real refused connection; a few tests talk to PHP's built-in web server on a loopback port through the default Guzzle transport (credential headers on a real socket, redirects, streaming and the timeout). Nothing leaves your machine.

## Troubleshooting

- `Run "composer install" in this directory first.`: install the dependencies.
- `ANTHROPIC_BASE_URL selects the ANTHROPIC_* settings and requires an explicit AUTH_MODE ...`: the canonical profile has no default mode; set `AUTH_MODE=api_key` (and `ANTHROPIC_API_KEY`) or `AUTH_MODE=bearer`.
- `Azure CLI exited with code N ...`: run `az login`, and `az account get-access-token --scope https://ai.azure.com/.default --output none` to see the CLI's own message.
- `Error: APIConnectionException: Anthropic API Connection Error`: the `caused by:` line under it names the real problem. `cURL error 60` or `SSL certificate problem` (also `cURL error 77`) means PHP has no usable CA bundle, and the sample adds a `Hint:` line: see [TLS certificates](#tls-certificates). `cURL error 6`, `7` and `28` are a host that does not resolve, a refused connection and a timeout: check the endpoint URL and the network.
- A connection failure can take tens of seconds to be reported: the SDK retries it twice, and in `bearer` mode every attempt asks the Azure CLI for a token again.
- `Azure CLI did not finish within its 60 second allowance ...`: run `az account get-access-token --output none` by hand to see why; the first run after an install or reboot is the slowest.
- A 401 or 403 from the service is reported as is (`AuthenticationException`, `PermissionDeniedException`); the sample never retries it with another credential.
