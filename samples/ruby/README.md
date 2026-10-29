# Claude on Microsoft Foundry: Ruby

Calls a Claude deployment through the **standard** Anthropic Ruby SDK client (`Anthropic::Client`, the `anthropic` gem `~> 2.3.0`). It has no Foundry-specific client or subclass: the endpoint, the model (deployment) name and the credential are plain configuration.

| File | Purpose |
|---|---|
| `main.rb` | Entry point: one Messages call, printed whole or streamed (`--stream`). |
| `lib/claude_sample/sample.rb` | Reads the environment, builds the client, prints the text and usage. |
| `lib/claude_sample/client_factory.rb` | The generic helper. `ClaudeSample::ClientFactory.create_client` returns the standard client with exactly one explicit credential. It reads no environment variables and imports no cloud-provider code. |
| `lib/claude_sample/cli_token_provider.rb` | Token provider for local development: a command-line fallback that runs `az account get-access-token`. |
| `Gemfile`, `Gemfile.lock` | `anthropic ~> 2.3.0`, plus Minitest 5.x in the `test` group. The lock is portable (see Install). |
| `test/` | Offline Minitest tests: no cloud, no credentials. |

## Prerequisites

- Ruby 3.2 or later (the SDK's floor) and Bundler.
- For `AUTH_MODE=bearer` (the legacy profile's default), the [Azure CLI](https://learn.microsoft.com/cli/azure/) signed in to the tenant that owns the deployment (`az login`).
- A deployment of a Claude model in Microsoft Foundry, and its endpoint URL.

## Install

```sh
cd samples/ruby
bundle install
```

The Gemfile has one runtime dependency, `anthropic`: the SDK uses Ruby's bundled `net/http`, so no other HTTP library is needed. Minitest 5.x sits in the `test` group; it is 5.x because Minitest 6 depends on the `prism` gem, a native extension that needs a compiler on Rubies that do not ship it.

`Gemfile.lock` is checked in and meant to work unchanged on every supported Ruby (3.2 to 4.0) and platform. It was generated on the oldest supported Ruby, so its versions install on all of them; every gem in it is pure Ruby, so it lists the `ruby` platform plus `x64-mingw-ucrt` (RubyInstaller on Windows), and it has no `RUBY VERSION` or `BUNDLED WITH` section, so a different Ruby patch release does not rewrite it and Bundler does not download an older Bundler to match it. `bundle install` leaves it as it is; `BUNDLE_FROZEN=true bundle install` fails on any drift.

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
# PowerShell, from samples/ruby
Get-Content ..\..\.env.local | ForEach-Object { if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { Set-Item "env:$($Matches[1])" $Matches[2].Trim('"') } }
```

```sh
# bash
set -a; . ../../.env.local; set +a
```

## Run

```sh
bundle exec ruby main.rb            # one Messages call
bundle exec ruby main.rb --stream   # the same request, streamed as it is generated
```

`ruby main.rb` works too: `main.rb` loads `bundler/setup` itself. Both modes print only the text, then the token usage (the sample waits up to 120 seconds per request):

```text
<the model's answer>

[usage] input=<n> output=<n>
```

Thinking blocks are not printed. A response without any text fails with a message and a non-zero exit status instead of reporting success; so do API errors, credential failures and bad configuration (exit status 1; an unknown argument exits with 2).

## Authentication

**`AUTH_MODE=bearer` is a local-development fallback** (the legacy profile's default; the canonical profile needs it set explicitly). The sample runs `az account get-access-token --scope <TOKEN_SCOPE> --output json` (adding `--tenant <AZURE_TENANT_ID>` when set) for every token request and sends the returned `accessToken` as `Authorization: Bearer`. The Azure CLI owns token caching and renewal; the sample keeps no cache. The price is one CLI process per HTTP attempt, which takes seconds on a typical machine.

- The command is a fixed argument list, never shell text. Every argument must match `[A-Za-z0-9._:/-]+`, so quotes, spaces and shell or `cmd.exe` metacharacters are rejected before anything starts.
- On Windows the CLI is usually a batch file (`az.cmd` or `az.bat`). The sample finds it on `PATH` (honoring `PATHEXT`, absolute entries only) and starts it as `cmd.exe /d /c az.cmd ...` from its own directory with that fixed argument list.
- Each CLI process has a finite allowance of 60 seconds (a cold start under load can exceed the 10 seconds some identity libraries allow). When it runs out, the process, and on Windows its children, is stopped and the sample fails with a timeout error. It never falls back to another credential.
- A non-zero exit status, output that is not a JSON object, or a missing or empty `accessToken` raises a clear error. The error never contains the CLI's output, and the token is never printed, logged or written to a file.

**For production, pass your own token provider.** `create_client` accepts any callable that returns the current token as a string, for example one backed by your identity library (managed identity, workload identity, and so on). No officially supported Microsoft Azure Identity library for Ruby was identified when this sample was written, and the sample neither depends on nor endorses a third-party one. Because the provider runs on every HTTP attempt, it should be cheap or cache internally.

**`AUTH_MODE=api_key`** sends a static key in the header named by `API_KEY_HEADER`. Use it for development and testing.

## What the helper guarantees

`ClientFactory.create_client` returns a plain `Anthropic::Client` and uses only public SDK features (the `middleware:` option):

- **Exactly one credential.** The SDK is given a public, non-secret placeholder token, solely to stop it from discovering `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_PROFILE`, federation variables or profiles on disk. A middleware that runs on every HTTP attempt (retries and redirect hops included) removes `authorization`, `x-api-key` and `api-key`, whatever put them there (including `ANTHROPIC_CUSTOM_HEADERS` and per-request `extra_headers`), and applies the selected credential. The placeholder never reaches the wire. All other headers, including `anthropic-beta` values you pass, are preserved.
- **No OAuth beta.** A plain bearer token is sent without `anthropic-beta: oauth-2025-04-20`.
- **One origin.** The base URL must be HTTPS (loopback may use HTTP) and may not carry credentials, a query or a fragment. A redirect to a different scheme, host or port is refused before any credential is produced.
- **SDK defaults kept.** The factory adds no retry, refresh or cache of its own, and sets no retry count or timeout unless you pass `max_retries:` or `timeout:`. The SDK's retries (2) and its 600 second request timeout apply. `anthropic-version` is the SDK's default unless you pass `api_version:`.
- **The sample's own policy.** `Sample` passes `timeout: 120.0` (`ClaudeSample::Sample::REQUEST_TIMEOUT_SECONDS`) so a stuck request ends after two minutes. That is an application choice made visibly in `lib/claude_sample/sample.rb`, not something the factory does for you.

```ruby
require_relative "lib/claude_sample/client_factory"

client = ClaudeSample::ClientFactory.create_client(
  base_url: "https://<resource>.services.ai.azure.com/anthropic",
  token_provider: -> { identity.current_access_token }
)
message = client.messages.create(
  max_tokens: 1024, messages: [{role: "user", content: "Hello"}], model: "<deployment>"
)
```

## Tests

```sh
bundle install
bundle exec ruby test/run.rb     # ruby test/run.rb works as well
```

The tests use Minitest 5.x from the Gemfile's `test` group (installed by `bundle install`, with no load-path tricks). They run offline. A real HTTP server on a loopback port stands in for the endpoint, so the SDK's own `Net::HTTP` transport produces the bytes under test:

- the request the SDK sends: the Foundry-style and native paths and the model, a rotating bearer token, a resource key in `x-api-key` and the native `Authorization` key, the API version, no OAuth beta, canaries for `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_PROFILE`, `ANTHROPIC_BASE_URL` and `ANTHROPIC_CUSTOM_HEADERS` (with a control showing the SDK defaults would send them), streaming, HTTP error statuses, retries that fetch a fresh token, redirects, and the transport timeout;
- the token provider (`CliTokenProvider`), with a fake process runner and with a fixture `az` (a `.cmd` on Windows, a shell script elsewhere) that is really launched;
- the entry point, including mixed-family canaries (decoy `ANTHROPIC_*` and `CLAUDE_*` values must never be paired with the other profile's endpoint, model or key) and the 120 second policy.

Nothing leaves your machine.

## Troubleshooting

- `Azure CLI exited with code N ...`: run `az login`, and `az account get-access-token --scope https://ai.azure.com/.default --output none` to see the CLI's own message.
- `Could not find gem 'anthropic'` (or `minitest`): run `bundle install` in this directory.
- `ANTHROPIC_BASE_URL selects the ANTHROPIC_* settings and requires an explicit AUTH_MODE ...`: the canonical profile has no default mode; set `AUTH_MODE=api_key` (and `ANTHROPIC_API_KEY`) or `AUTH_MODE=bearer`.
- `Azure CLI did not finish within its 60 second allowance ...`: run `az account get-access-token --output none` by hand to see why; the first run after an install or reboot is the slowest.
- A 401 or 403 from the service is reported as is (`AuthenticationError`, `PermissionDeniedError`); the sample never retries it with another credential.
