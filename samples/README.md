# Portable Anthropic SDK samples

Each language uses its standard Anthropic SDK client. Generic client/authentication helpers handle construction only: no alternate Messages API, SDK subclass, custom retry loop, or platform-specific client package.

| Language | Instructions | Token acquisition |
|---|---|---|
| Python | [Root quickstart](../README.md#python-sdk) | Official Azure Identity SDK and cached bearer-token provider |
| TypeScript | [typescript](typescript/README.md) | Official `@azure/identity` |
| C# | [dotnet](dotnet/README.md) | Official `Azure.Identity` |
| Go | [go](go/README.md) | Official `azidentity` |
| Java | [java](java/README.md) | Official `com.azure:azure-identity` |
| PHP | [php](php/README.md) | Caller-supplied callback; Azure CLI local fallback |
| Ruby | [ruby](ruby/README.md) | Caller-supplied callback; Azure CLI local fallback |

PHP/Ruby's CLI fallback is explicit because no current official Azure Identity SDK was identified for those languages. It is not a production managed-identity implementation. Supply an appropriate renewable-token callback in hosted applications.

## Configuration

Python loads the gitignored root `.env.local`; the other entrypoints read process environment variables. Export the selected `azd` environment before running them. Never put real keys, tokens, tenant IDs or subscription IDs in checked-in configuration.

| Variable | Meaning | Starter default |
|---|---|---|
| `ANTHROPIC_BASE_URL` | Selects the canonical endpoint/model/key profile; otherwise use the legacy `CLAUDE_*` profile | Required |
| `ANTHROPIC_MODEL` | Canonical model; legacy profile uses `CLAUDE_DEPLOYMENT_NAME` | Required |
| `AUTH_MODE` | `bearer` or `api_key`; select explicitly with the canonical endpoint profile | `bearer` for the legacy azd profile |
| `AZURE_TOKEN_CREDENTIALS` | Explicit credential class: `AzureCliCredential`, `AzureDeveloperCliCredential`, or `ManagedIdentityCredential` | `AzureCliCredential` |
| `AZURE_TENANT_ID` | Tenant for local credential/token requests | Credential default |
| `AZURE_CLIENT_ID` | User-assigned managed identity client ID | Credential default |
| `TOKEN_SCOPE` | Scope requested by the identity integration | `https://ai.azure.com/.default` |
| `ANTHROPIC_API_KEY` | Key for the canonical profile; legacy profile uses only `CLAUDE_API_KEY` | No default |
| `API_KEY_HEADER` | `Authorization` for native SDK bearer-key semantics, or a raw key header such as `x-api-key` | `Authorization` |
| `ANTHROPIC_API_VERSION` | Optional `anthropic-version` override | Native SDK default |

Credential selection belongs to sample setup, not the generic client helper. Use a deterministic managed identity in production; no sample silently switches credentials after a failure.

Endpoint, model and key are resolved as a single profile, never mixed across the two variable families. For example, an ambient native `ANTHROPIC_API_KEY` cannot replace a Foundry `CLAUDE_API_KEY`. A canonical endpoint requires an explicit authentication mode so an ambient native URL cannot silently receive the legacy profile's default Entra token. When exporting `ANTHROPIC_BASE_URL` in the process environment, export `AUTH_MODE` there too; a Python dotenv-file default cannot authorize an ambient process endpoint.

A local bearer run needs `az login` in the intended tenant/subscription. Where supported, select `AzureDeveloperCliCredential` instead if you authenticated with `azd auth login`. The PHP/Ruby fallback specifically requires Azure CLI.

The credential-class selector applies to the five official Azure Identity SDK integrations. PHP/Ruby's local entrypoints support only the CLI selector and reject other explicit selections; hosted applications must supply their own renewable-token callback.

The Python setup allows up to 60 seconds for cold CLI/azd credential-process startup, without falling back to another identity. The generic HTTP client preserves the SDK's own network timeout defaults.

## Native provider versus Microsoft Foundry

For Foundry, use the `CLAUDE_BASE_URL` and `CLAUDE_DEPLOYMENT_NAME` emitted by `azd up`. Bearer authentication uses Azure Identity. The native SDK bearer-key header and API version also worked in live tests; the older documented `x-api-key` / `2023-06-01` shape remains available through explicit overrides.

For the native Anthropic endpoint, supply an Anthropic account key through the environment/secret store, then change configuration:

```powershell
$env:AUTH_MODE = "api_key"
$env:ANTHROPIC_BASE_URL = "https://api.anthropic.com"
$env:ANTHROPIC_MODEL = "claude-sonnet-5-5"
# Set ANTHROPIC_API_KEY through your secret store or process environment.
```

The current native SDK generation uses bearer-style API-key authentication; a Foundry resource key is not an Anthropic account key. Endpoint-specific deployment names and service features are not made interchangeable by a helper. Only configuration changes; client types and Messages/streaming calls stay the same.

A fresh Haiku 5.5 deployment accepted both `2023-06-01` and `2026-10-21`, both resource-key header shapes, and an incidental native OAuth beta header. These are observations against that deployment, not a claim of a published conformance guarantee for every model, region or native-provider feature.

## What the helper owns

- Explicit credential selection and final authentication-header placement.
- Origin binding and redirect restrictions so a copied or redirected request cannot send credentials to an unrelated service.
- Configurable API-key header and API version.
- A renewable-token callback on every attempt, without opting into Anthropic-native OAuth or federation flows.

The SDK still owns HTTP requests, serialization, streaming, status errors and retries. The identity library or CLI owns token acquisition/renewal. Some CLI credentials run a subprocess when asked for a token; do not assume every identity implementation has the same cache.

The Python factory uses an explicit non-secret SDK credential to disable ambient discovery, then a public request hook replaces it before transmission. Regression tests ensure it never reaches the transport, other requested beta headers are preserved, and environment/per-request credential canaries cannot override the selected credential.

## Validation

Use each language's README for its offline test command. Those tests use real SDKs with recording transports and require no Azure account or model quota. Each sample also supports a real Messages call and a streaming path against a deployment.

Cloud provisioning remains the existing `azd up` workflow in one selected IaC variant. Claude Code CLI configuration is separate and still uses its built-in Foundry mode.

The migration was live-tested against a freshly provisioned Haiku 5.5 version 2 deployment in `eastus2`: all seven languages passed Messages, SSE streaming and resource-key authentication with native SDK defaults. Python, TypeScript, C#, Go and Java also passed a configuration-only switch between Azure CLI and Azure Developer CLI credentials. Native Anthropic endpoint routing is covered by offline recording transports; no native-account live test is claimed.

The TypeScript sample is pinned to the tested SDK 1.1.0 because the configured package feed did not provide 1.3.0 and direct public-registry access failed TLS negotiation in the test environment. Relevant 1.3.0 source was compared, but that package version was not executed. Other runtime/version details are in the language READMEs.

## Upstream requests

These are focused requests to reduce or retire the sample-local authentication glue, not requests for another platform-specific client:

| Area | Issue |
|---|---|
| Python bearer-callable ergonomics and neutral authentication | [anthropics/anthropic-sdk-python#2044](https://github.com/anthropics/anthropic-sdk-python/issues/2044) |
| TypeScript standard-client recipe and explicit authentication policy | [anthropics/anthropic-sdk-typescript#1289](https://github.com/anthropics/anthropic-sdk-typescript/issues/1289) |
| C# external bearer credentials | [anthropics/anthropic-sdk-csharp#321](https://github.com/anthropics/anthropic-sdk-csharp/issues/321) |
| Go context-aware bearer-token option | [anthropics/anthropic-sdk-go#485](https://github.com/anthropics/anthropic-sdk-go/issues/485) |
| Java standard-client token-supplier integration | [anthropics/anthropic-sdk-java#432](https://github.com/anthropics/anthropic-sdk-java/issues/432) |
| PHP neutral external bearer providers | [anthropics/anthropic-sdk-php#110](https://github.com/anthropics/anthropic-sdk-php/issues/110) |
| Ruby neutral external bearer providers | [anthropics/anthropic-sdk-ruby#271](https://github.com/anthropics/anthropic-sdk-ruby/issues/271) |
| Foundry's documented native-SDK compatibility contract | [Azure/azure-rest-api-specs#47738](https://github.com/Azure/azure-rest-api-specs/issues/47738) |

The service request records the successful protocol observations above and asks for a documented conformance guarantee. It does not claim that the tested service rejected native headers or API versions.
