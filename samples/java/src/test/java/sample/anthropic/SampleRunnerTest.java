package sample.anthropic;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.azure.core.credential.AccessToken;
import com.azure.core.credential.TokenCredential;
import com.azure.core.credential.TokenRequestContext;
import com.azure.identity.CredentialUnavailableException;
import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Function;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;
import reactor.core.publisher.Mono;

/** The sample entrypoint end to end: environment, credential wiring, real SDK, output, exit codes. */
class SampleRunnerTest {

    private record RunResult(int exitCode, String output, String error) {}

    private static final class FakeCredential implements TokenCredential, AutoCloseable {
        private final AtomicInteger calls = new AtomicInteger();
        final List<List<String>> scopes = new ArrayList<>();
        RuntimeException failure;
        boolean closed;

        @Override
        public Mono<AccessToken> getToken(TokenRequestContext context) {
            return Mono.fromSupplier(() -> token(context));
        }

        @Override
        public AccessToken getTokenSync(TokenRequestContext context) {
            return token(context);
        }

        private AccessToken token(TokenRequestContext context) {
            scopes.add(List.copyOf(context.getScopes()));
            if (failure != null) {
                throw failure;
            }
            return new AccessToken("fake-credential-token-" + calls.incrementAndGet(), OffsetDateTime.now().plusHours(1));
        }

        @Override
        public void close() {
            closed = true;
        }
    }

    private static Function<String, String> env(String spec) {
        Map<String, String> values = new HashMap<>();
        for (String pair : spec.split(";")) {
            if (!pair.isEmpty()) {
                int separator = pair.indexOf('=');
                values.put(pair.substring(0, separator), pair.substring(separator + 1));
            }
        }
        return values::get;
    }

    private static RunResult run(String[] args, String environment, FakeCredential credential) {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        ByteArrayOutputStream error = new ByteArrayOutputStream();
        int exitCode = SampleRunner.run(
                args,
                env(environment),
                new PrintStream(output, true, StandardCharsets.UTF_8),
                new PrintStream(error, true, StandardCharsets.UTF_8),
                settings -> credential);
        return new RunResult(
                exitCode,
                output.toString(StandardCharsets.UTF_8).replace("\r\n", "\n"),
                error.toString(StandardCharsets.UTF_8).replace("\r\n", "\n"));
    }

    // ANTHROPIC_BASE_URL selects the canonical profile; CLAUDE_BASE_URL alone selects the legacy one.
    private static String canonicalEnv(RecordingServer server) {
        return "ANTHROPIC_BASE_URL=" + server.baseUrl() + ";ANTHROPIC_MODEL=claude-sonnet-5-5";
    }

    private static String bearerEnv(RecordingServer server) {
        return canonicalEnv(server) + ";AUTH_MODE=bearer";
    }

    private static String keyEnv(RecordingServer server) {
        return canonicalEnv(server) + ";AUTH_MODE=api_key";
    }

    private static String legacyEnv(RecordingServer server) {
        return "CLAUDE_BASE_URL=" + server.baseUrl() + ";CLAUDE_DEPLOYMENT_NAME=legacy-deployment";
    }

    // The other family's values, with canaries that must never be used or sent.
    private static final String LEGACY_CANARIES = "CLAUDE_BASE_URL=https://legacy-canary.invalid;"
            + "CLAUDE_DEPLOYMENT_NAME=legacy-model-canary;CLAUDE_API_KEY=legacy-key-canary";

    private static final String NATIVE_CANARIES = "ANTHROPIC_MODEL=native-model-canary;ANTHROPIC_API_KEY=native-key-canary";

    private static final List<String> FAMILY_CANARIES = List.of(
            "legacy-canary.invalid", "legacy-model-canary", "legacy-key-canary", "native-model-canary", "native-key-canary");

    private static void assertNoFamilyCanaries(Recorded request) {
        String everything = request.everything().toLowerCase();
        for (String canary : FAMILY_CANARIES) {
            assertFalse(everything.contains(canary), "family canary reached the wire: " + canary);
        }
    }

    @Test
    void legacyProfileDefaultsToBearerUsesItsOwnNamesAndPrintsTextThenUsage() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            FakeCredential credential = new FakeCredential();

            RunResult result = run(
                    new String[0],
                    "CLAUDE_BASE_URL=" + server.baseUrl() + ";CLAUDE_DEPLOYMENT_NAME=my-deployment",
                    credential);

            assertEquals(0, result.exitCode());
            assertEquals("OK\nusage: input_tokens=11 output_tokens=5\n", result.output());
            assertEquals("", result.error());
            Recorded request = server.single();
            assertEquals("/v1/messages", request.path());
            assertEquals("Bearer fake-credential-token-1", request.header("Authorization"));
            assertEquals(TestClients.sdkDefaultApiVersion(), request.header("anthropic-version"));
            assertEquals("120", request.header("X-Stainless-Timeout"));
            assertTrue(request.body().contains("\"model\":\"my-deployment\""), request.body());
            assertTrue(request.body().contains("\"max_tokens\":1024"), request.body());
            assertEquals(List.of(List.of("https://ai.azure.com/.default")), credential.scopes);
            request.assertNoCanaryEgress();
        }
    }

    @Test
    void canonicalProfileWinsOverLegacyAndHonorsScopeAndVersionOverrides() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            FakeCredential credential = new FakeCredential();
            String environment = "ANTHROPIC_BASE_URL=" + server.baseUrl() + ";CLAUDE_BASE_URL=https://legacy.example/anthropic;"
                    + "ANTHROPIC_MODEL=preferred-model;CLAUDE_DEPLOYMENT_NAME=legacy-model;"
                    + "TOKEN_SCOPE=api://custom/.default;ANTHROPIC_API_VERSION=2023-06-01;AUTH_MODE=BEARER";

            RunResult result = run(new String[0], environment, credential);

            assertEquals(0, result.exitCode(), result.error());
            Recorded request = server.single();
            assertTrue(request.body().contains("\"model\":\"preferred-model\""), request.body());
            assertEquals("2023-06-01", request.header("anthropic-version"));
            assertNotEquals("2023-06-01", TestClients.sdkDefaultApiVersion());
            assertEquals(List.of(List.of("api://custom/.default")), credential.scopes);
        }
    }

    @Test
    void canonicalProfileIgnoresEveryLegacyValue() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            FakeCredential credential = new FakeCredential();

            RunResult result =
                    run(new String[0], keyEnv(server) + ";ANTHROPIC_API_KEY=canonical-key;" + LEGACY_CANARIES, credential);

            assertEquals(0, result.exitCode(), result.error());
            Recorded request = server.single();
            assertTrue(request.body().contains("\"model\":\"claude-sonnet-5-5\""), request.body());
            assertEquals("Bearer canonical-key", request.header("Authorization"));
            assertNoFamilyCanaries(request);
            assertTrue(credential.scopes.isEmpty());
        }
    }

    @Test
    void legacyProfileIgnoresEveryAmbientNativeValue() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            RunResult result = run(
                    new String[0],
                    legacyEnv(server) + ";AUTH_MODE=api_key;CLAUDE_API_KEY=legacy-key;" + NATIVE_CANARIES,
                    new FakeCredential());

            assertEquals(0, result.exitCode(), result.error());
            Recorded request = server.single();
            assertTrue(request.body().contains("\"model\":\"legacy-deployment\""), request.body());
            assertEquals("Bearer legacy-key", request.header("Authorization"));
            assertNoFamilyCanaries(request);
        }
    }

    @Test
    void legacyBearerDefaultNeverUsesAnAmbientNativeKey() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            FakeCredential credential = new FakeCredential();

            RunResult result = run(new String[0], legacyEnv(server) + ";" + NATIVE_CANARIES, credential);

            assertEquals(0, result.exitCode(), result.error());
            Recorded request = server.single();
            assertEquals("Bearer fake-credential-token-1", request.header("Authorization"));
            assertTrue(request.body().contains("\"model\":\"legacy-deployment\""), request.body());
            assertNoFamilyCanaries(request);
            assertEquals(1, credential.scopes.size());
        }
    }

    @Test
    void canonicalBearerWhenExplicitIgnoresBothKeyFamilies() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            FakeCredential credential = new FakeCredential();

            RunResult result = run(
                    new String[0],
                    bearerEnv(server) + ";ANTHROPIC_API_KEY=native-key-canary;CLAUDE_API_KEY=legacy-key-canary",
                    credential);

            assertEquals(0, result.exitCode(), result.error());
            Recorded request = server.single();
            assertEquals("Bearer fake-credential-token-1", request.header("Authorization"));
            assertNoFamilyCanaries(request);
            assertFalse(request.has("x-api-key"));
        }
    }

    @ParameterizedTest
    @CsvSource(delimiter = '|', value = {
        "canonical|;ANTHROPIC_API_KEY=canonical-key|Authorization|Bearer canonical-key",
        "legacy|;CLAUDE_API_KEY=legacy-key|Authorization|Bearer legacy-key",
        "canonical|;ANTHROPIC_API_KEY=canonical-key;API_KEY_HEADER=x-api-key|x-api-key|canonical-key",
        "canonical|;ANTHROPIC_API_KEY=canonical-key;API_KEY_HEADER=api-key|api-key|canonical-key",
        "legacy|;CLAUDE_API_KEY=legacy-key;API_KEY_HEADER=x-api-key|x-api-key|legacy-key"
    })
    void apiKeyModePlacesTheKeyInTheConfiguredHeaderWithoutAskingForAToken(
            String profile, String extra, String header, String expected) throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            FakeCredential credential = new FakeCredential();
            String base = profile.equals("legacy") ? legacyEnv(server) + ";AUTH_MODE=api_key" : keyEnv(server);

            RunResult result = run(new String[0], base + extra, credential);

            assertEquals(0, result.exitCode(), result.error());
            Recorded request = server.single();
            assertEquals(expected, request.header(header));
            for (String closedName : List.of("Authorization", "x-api-key", "api-key")) {
                assertEquals(closedName.equalsIgnoreCase(header), request.has(closedName), closedName);
            }
            assertEquals(TestClients.sdkDefaultApiVersion(), request.header("anthropic-version"));
            assertTrue(credential.scopes.isEmpty());
            request.assertNoCanaryEgress();
        }
    }

    @Test
    void streamPrintsTextAsItArrivesThenUsage() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            server.enqueue((exchange, request) -> Responses.stream(exchange, "Hel", "lo"));

            RunResult result = run(new String[] {"--stream", "Say", "hi"}, bearerEnv(server), new FakeCredential());

            assertEquals(0, result.exitCode(), result.error());
            assertEquals("Hello\nusage: input_tokens=11 output_tokens=7\n", result.output());
            assertEquals("", result.error());
            assertTrue(server.single().body().contains("\"stream\":true"));
            assertTrue(server.single().body().contains("Say hi"));
        }
    }

    @Test
    void promptWordsAreJoinedAndAfterDoubleDashOptionsAreLiteral() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            RunResult result = run(new String[] {"--", "--stream", "is", "text"}, bearerEnv(server), new FakeCredential());

            assertEquals(0, result.exitCode(), result.error());
            assertFalse(server.single().body().contains("\"stream\""));
            assertTrue(server.single().body().contains("--stream is text"), server.single().body());
        }
    }

    @Test
    void thinkingOnlyResponseIsAFailureNotASuccess() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            server.enqueue((exchange, request) -> Responses.thinkingOnly(exchange));

            RunResult result = run(new String[0], bearerEnv(server), new FakeCredential());

            assertEquals(SampleRunner.EXIT_FAILURE, result.exitCode());
            assertEquals("", result.output());
            assertTrue(result.error().contains("UnusableResponseException"), result.error());
            assertTrue(result.error().contains("no text"), result.error());
            assertTrue(result.error().contains("thinking"), result.error());
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {"", "   \\n "})
    void emptyOrBlankTextIsAFailure(String text) throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            server.enqueue((exchange, request) -> Responses.message(exchange, text.replace("\\n", "\n"), 11, 5));

            RunResult result = run(new String[0], bearerEnv(server), new FakeCredential());

            assertEquals(SampleRunner.EXIT_FAILURE, result.exitCode());
            assertEquals("", result.output());
            assertTrue(result.error().contains("UnusableResponseException"), result.error());
        }
    }

    @Test
    void streamWithoutTextOrWithoutMessageStopIsAFailure() throws Exception {
        try (RecordingServer silent = new RecordingServer(); RecordingServer truncated = new RecordingServer()) {
            silent.enqueue((exchange, request) -> Responses.stream(exchange, ""));
            truncated.enqueue((exchange, request) -> Responses.truncatedStream(exchange, "partial"));

            RunResult noText = run(new String[] {"--stream"}, bearerEnv(silent), new FakeCredential());
            RunResult cutOff = run(new String[] {"--stream"}, bearerEnv(truncated), new FakeCredential());

            assertEquals(SampleRunner.EXIT_FAILURE, noText.exitCode());
            assertTrue(noText.error().contains("no text"), noText.error());
            assertEquals(SampleRunner.EXIT_FAILURE, cutOff.exitCode());
            assertTrue(cutOff.error().contains("before message_stop"), cutOff.error());
            assertFalse(cutOff.output().contains("usage:"));
        }
    }

    @ParameterizedTest
    @CsvSource({"401,UnauthorizedException (HTTP 401)", "403,PermissionDeniedException (HTTP 403)"})
    void authRejectionShowsTypedStatusAndNeverTheToken(int status, String expected) throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            server.enqueue((exchange, request) -> Responses.error(
                    exchange, status, "authentication_error", "denied for Bearer fake-credential-token-1 and fake-credential-token-1"));

            RunResult result = run(new String[0], bearerEnv(server), new FakeCredential());

            assertEquals(SampleRunner.EXIT_FAILURE, result.exitCode());
            assertEquals("", result.output());
            assertTrue(result.error().contains(expected), result.error());
            assertTrue(result.error().contains("[redacted]"), result.error());
            assertFalse(result.error().contains("fake-credential-token"), result.error());
        }
    }

    @Test
    void apiKeyIsRedactedFromServerErrors() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            server.enqueue((exchange, request) ->
                    Responses.error(exchange, 401, "authentication_error", "bad key super-secret-key-value"));

            RunResult result = run(new String[0], keyEnv(server) + ";ANTHROPIC_API_KEY=super-secret-key-value", new FakeCredential());

            assertEquals(SampleRunner.EXIT_FAILURE, result.exitCode());
            assertTrue(result.error().contains("[redacted]"), result.error());
            assertFalse(result.error().contains("super-secret-key-value"), result.error());
        }
    }

    @Test
    void credentialFailureShowsItsTypeAndSendsNothing() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            FakeCredential credential = new FakeCredential();
            credential.failure = new CredentialUnavailableException("synthetic CLI is not signed in");

            RunResult result = run(new String[0], bearerEnv(server), credential);

            assertEquals(SampleRunner.EXIT_FAILURE, result.exitCode());
            assertTrue(
                    result.error().contains("CredentialUnavailableException: synthetic CLI is not signed in"), result.error());
            assertTrue(server.requests().isEmpty());
        }
    }

    @Test
    void theCallerClosesTheCredentialOnSuccessAndOnFailure() throws Exception {
        try (RecordingServer server = new RecordingServer(); RecordingServer rejecting = new RecordingServer()) {
            FakeCredential succeeded = new FakeCredential();
            FakeCredential failed = new FakeCredential();
            rejecting.enqueue((exchange, request) -> Responses.error(exchange, 403, "permission_error", "no"));

            run(new String[0], bearerEnv(server), succeeded);
            run(new String[0], bearerEnv(rejecting), failed);

            assertTrue(succeeded.closed);
            assertTrue(failed.closed);
        }
    }

    @ParameterizedTest
    @CsvSource(delimiter = '|', value = {
        "ANTHROPIC_MODEL=m|ANTHROPIC_BASE_URL",
        "ANTHROPIC_BASE_URL=https://x.example;AUTH_MODE=bearer|ANTHROPIC_MODEL",
        "ANTHROPIC_BASE_URL=https://x.example;ANTHROPIC_MODEL=m;AUTH_MODE=oauth|AUTH_MODE",
        "ANTHROPIC_BASE_URL=https://x.example;ANTHROPIC_MODEL=m;AUTH_MODE=api_key|ANTHROPIC_API_KEY",
        "ANTHROPIC_BASE_URL=https://x.example;ANTHROPIC_MODEL=m;AUTH_MODE=bearer;AZURE_TOKEN_CREDENTIALS=DefaultAzureCredential|AZURE_TOKEN_CREDENTIALS",
        "ANTHROPIC_BASE_URL=http://example.com;ANTHROPIC_MODEL=m;AUTH_MODE=api_key;ANTHROPIC_API_KEY=k|https"
    })
    void invalidConfigurationExitsWithUsageStatus(String environment, String expected) {
        FakeCredential credential = new FakeCredential();

        RunResult result = run(new String[0], environment, credential);

        assertEquals(SampleRunner.EXIT_USAGE, result.exitCode());
        assertEquals("", result.output());
        assertTrue(result.error().contains(expected), result.error());
    }

    @ParameterizedTest
    @CsvSource(delimiter = '|', value = {
        // The canonical URL needs the canonical model and key: the legacy names are never a fallback.
        "ANTHROPIC_BASE_URL={URL};CLAUDE_DEPLOYMENT_NAME=legacy-model;AUTH_MODE=bearer|ANTHROPIC_MODEL",
        "ANTHROPIC_BASE_URL={URL};ANTHROPIC_MODEL=m;AUTH_MODE=api_key;CLAUDE_API_KEY=legacy-key|ANTHROPIC_API_KEY",
        // The canonical profile never defaults to an identity token, even when legacy values are also present.
        "ANTHROPIC_BASE_URL={URL};ANTHROPIC_MODEL=m;ANTHROPIC_API_KEY=native-key;CLAUDE_API_KEY=legacy-key|AUTH_MODE",
        "ANTHROPIC_BASE_URL={URL};ANTHROPIC_MODEL=m;CLAUDE_BASE_URL={URL};CLAUDE_DEPLOYMENT_NAME=legacy-deployment|AUTH_MODE",
        // A legacy-only URL needs the legacy model and key: ambient native names are never a fallback.
        "CLAUDE_BASE_URL={URL};ANTHROPIC_MODEL=native-model|CLAUDE_DEPLOYMENT_NAME",
        "CLAUDE_BASE_URL={URL};CLAUDE_DEPLOYMENT_NAME=legacy-deployment;AUTH_MODE=api_key;ANTHROPIC_API_KEY=native-key|CLAUDE_API_KEY"
    })
    void profilesAreNeverMixedAndTheErrorNamesTheMissingVariable(String environment, String expected) throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            FakeCredential credential = new FakeCredential();

            RunResult result = run(new String[0], environment.replace("{URL}", server.baseUrl()), credential);

            assertEquals(SampleRunner.EXIT_USAGE, result.exitCode());
            assertEquals("", result.output());
            assertTrue(result.error().contains(expected), result.error());
            assertTrue(server.requests().isEmpty());
            assertTrue(credential.scopes.isEmpty());
            assertFalse(credential.closed, "no credential may be created for an invalid configuration");
        }
    }

    @Test
    void helpAndUnknownOptions() {
        RunResult help = run(new String[] {"--help"}, "", new FakeCredential());
        RunResult unknown = run(new String[] {"--verbose"}, "ANTHROPIC_BASE_URL=https://x.example;ANTHROPIC_MODEL=m", new FakeCredential());

        assertEquals(SampleRunner.EXIT_OK, help.exitCode());
        assertTrue(help.output().contains("usage:"));
        assertEquals(SampleRunner.EXIT_USAGE, unknown.exitCode());
        assertTrue(unknown.error().contains("unknown option --verbose"), unknown.error());
    }
}