# Java sample: standard Anthropic SDK with explicit authentication

One command-line app that makes a Messages call, or a streaming call with `--stream`, using the **standard**
`AnthropicClient` from the official [`com.anthropic:anthropic-java`](https://central.sonatype.com/artifact/com.anthropic/anthropic-java)
SDK (3.3.0). Authentication comes from the official
[`com.azure:azure-identity`](https://central.sonatype.com/artifact/com.azure/azure-identity) library (1.18.7) or
from an API key. There is no `anthropic-java-foundry` artifact, client subclass, alternate Messages API or custom
retry loop.

| File (under `src/main/java/sample/anthropic`) | Role |
|---|---|
| `ClientFactory.java` | Generic helper. Builds the standard client with one explicit credential. Knows no identity library and reads no environment or system property. Copy this one file (it needs only the Anthropic SDK). |
| `CredentialSelector.java` | The only code that uses Azure Identity: selects one credential class and adapts it to the helper's `Supplier<String>`. |
| `SampleSettings.java`, `SampleRunner.java`, `Main.java` | Environment parsing, the Messages/streaming calls, output and exit codes. |

Tests live in `src/test/java/sample/anthropic` and run offline.

## Run

Requires JDK 17 or later and Maven 3.9 or later. For the default bearer mode sign in first (`az login`, or `azd auth
login` with `AZURE_TOKEN_CREDENTIALS=AzureDeveloperCliCredential`) in the intended tenant and subscription.

```powershell
# The `azd up` outputs as they are (the legacy profile; bearer authentication by default) ...
$env:CLAUDE_BASE_URL        = "https://<resource>.services.ai.azure.com/anthropic"
$env:CLAUDE_DEPLOYMENT_NAME = "<deployment name>"
# ... or the canonical profile, which must name its authentication mode:
#   $env:ANTHROPIC_BASE_URL = "https://<resource>.services.ai.azure.com/anthropic"
#   $env:ANTHROPIC_MODEL    = "<deployment name>"
#   $env:AUTH_MODE          = "bearer"
cd samples/java
mvn -q exec:java "-Dexec.args=Say hello in one sentence."
mvn -q exec:java "-Dexec.args=--stream Say hello in one sentence."
```

Output is the response text followed by `usage: input_tokens=N output_tokens=M`. With `--stream` the text is printed as it
arrives. A response without non-blank text (for example thinking blocks only), a stream that ends before
`message_stop`, and every transport, credential or HTTP error exit non-zero and print the typed cause and HTTP status,
never a token or key. Exit codes: `0` success, `1` request failure, `2` configuration or usage error. Each call uses
`max_tokens` 1024 and a 120 second per-call timeout. The timeout is this sample's own policy, set explicitly in
`SampleRunner`; `ClientFactory` keeps the SDK's timeout unless the caller sets `timeout(...)`. The SDK's default retries
are unchanged.

`mvn exec:java` reports every non-zero exit as `1`. For the exact codes run the class directly:

```powershell
mvn -q dependency:build-classpath "-Dmdep.outputFile=target/classpath.txt"
java -cp "target/classes;$(Get-Content target/classpath.txt -Raw)" sample.anthropic.Main --stream "Say hello"   # use ':' on Linux/macOS
```

## Configuration

Read by the sample entrypoint only (never by `ClientFactory`). Real keys and IDs belong in the environment or a secret
store, not in tracked files.

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
verbatim. `AzureCliCredential` and `AzureDeveloperCliCredential` are built with a 60 second `processTimeout`, so a slow
CLI start is not reported as a failure; `ManagedIdentityCredential` has no such option.
## Use the helper in your own code

```java
AnthropicClient client = ClientFactory.create(ClientFactory.Options.builder()
        .baseUrl("https://<resource>.services.ai.azure.com/anthropic")
        // Exactly one credential: a per-attempt bearer supplier ...
        .tokenSupplier(() -> credential
                .getTokenSync(new TokenRequestContext().addScopes("https://ai.azure.com/.default"))
                .getToken())
        // ... or .apiKey(key).apiKeyHeader("x-api-key") (default header: Authorization).
        // Optional: .tokenExecutor(executor) decides where the supplier runs for client.async() calls.
        .build());
try {
    Message message = client.messages().create(MessageCreateParams.builder() /* standard SDK call */ .build());
} finally {
    client.close();
}
```

`ClientFactory.create` returns the unmodified SDK client; everything else is the SDK's own API. What it adds:

- **One explicit credential.** It never calls `fromEnv()` and never sets the SDK's `apiKey` or `authToken`, so
  `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_PROFILE` and the matching system properties are not used.
  One public SDK `Interceptor`, run on every attempt (retries included):
  - refuses any request that is not for the configured origin (credentials are bound to it);
  - removes every credential header (`Authorization`, `x-api-key`, `api-key`), then sets only the chosen one, using
    `replaceHeaders` because the SDK applies credentials above interceptors;
  - leaves other headers, such as `anthropic-beta`, untouched.
- **Origin and redirects.** `https` only (loopback `http` for tests), no user info/query/fragment in the base URL.
  Redirect following is switched off per request, and any 301/302/303/307/308 response is refused.
- **Plain supplier.** The `Supplier<String>` is invoked before every attempt, including SDK retries. The helper adds no
  cache, retry or token logic; supplier errors surface with their own type and are not retried.
- **Blocking and asynchronous calls.** The interceptor decorates the SDK's public `HttpClient` (`execute`,
  `executeAsync`, `close`), so `client.messages()` and `client.async().messages()`, streaming included, behave as on a
  stock client with the same origin, header and redirect policy. Blocking calls run the supplier on the calling thread.
  Asynchronous calls run it on `tokenExecutor(...)` (default: the JDK's asynchronous pool), so neither the caller nor
  the SDK's callback threads wait for it; give a slow supplier, such as a CLI credential, a dedicated executor.
- **Ownership.** The caller owns the credential and closes it; closing the client releases only its HTTP resources.

The SDK's public `Backend` interface could carry the same logic, but it is a larger surface (base URL, request
preparation, authorization, close) than this one interceptor, and `authToken(String)` takes a fixed value, so
renewal needs a per-request hook either way.

Token cost: the supplier runs per request. `ManagedIdentityCredential` caches tokens inside Azure Identity, but a CLI
credential can start a subprocess on each call, so the per-request cost depends on the credential. This sample reuses
one credential instance and adds no cache of its own.

### Dependency alignment

`anthropic-java` is built against Jackson 2.19 and `azure-core` against 2.18. Left to Maven's nearest-wins rule the
two mix and the SDK fails at runtime with `NoSuchMethodError: JsonProperty.isRequired()`, so `pom.xml` imports the
`jackson-bom` at the Anthropic SDK's version. Keep an equivalent constraint in any project that combines the two
libraries.

## Test (offline)

```powershell
cd samples/java
mvn test
```

The tests use the real SDK (blocking, asynchronous and streaming calls) against a loopback HTTP server, with hostile canary values in `ANTHROPIC_API_KEY`,
`ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_PROFILE`, `ANTHROPIC_CUSTOM_HEADERS`, the
`anthropic.apiKey`/`anthropic.authToken`/`anthropic.baseUrl` system properties and the federation variables
(installed by `pom.xml` for the test JVM). Entrypoint tests also leave the other profile's URL, model and key in the
environment as canaries and assert that none of them is used or sent. Fake `az`/`azd` scripts stand in for the CLIs.
They need no Azure account, login or model quota.

## Known limits

- Interrupting a thread that is already waiting on the socket does not stop the call; it ends at the per-call timeout.
  Interrupting during a retry back-off does stop it, and closing a `StreamResponse` stops a stream. The sample's
  120 second per-call timeout (its own policy, see above) bounds each HTTP call, including a whole streamed response,
  not the retries.
- Cancelling the future that the interceptor returns cancels what it controls: a request that has not been sent, and the
  in-flight SDK future. Whether cancelling a future returned by `client.async()` reaches the interceptor is up to the SDK,
  and a token fetch that has already started is never interrupted.
- Azure Identity logs through SLF4J. With no SLF4J binding on the classpath SLF4J prints a one-time "no-operation
  logger" notice on stderr; add a binding (for example `slf4j-simple`) to see Azure logs.
- `AzureCliCredential` and `AzureDeveloperCliCredential` need their CLI on `PATH`; use `ManagedIdentityCredential` in
  hosted environments.
- Only the Messages and streaming calls are demonstrated. Other SDK APIs go through the same client and interceptor.