package sample.anthropic;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNotSame;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.anthropic.client.AnthropicClient;
import com.anthropic.client.okhttp.AnthropicOkHttpClient;
import com.anthropic.core.RequestOptions;
import com.anthropic.core.http.AsyncStreamResponse;
import com.anthropic.core.http.Headers;
import com.anthropic.core.http.HttpClient;
import com.anthropic.core.http.HttpMethod;
import com.anthropic.core.http.HttpRequest;
import com.anthropic.core.http.HttpResponse;
import com.anthropic.core.http.StreamResponse;
import com.anthropic.errors.AnthropicIoException;
import com.anthropic.errors.AnthropicServiceException;
import com.anthropic.errors.PermissionDeniedException;
import com.anthropic.errors.UnauthorizedException;
import com.anthropic.models.messages.Message;
import com.anthropic.models.messages.MessageCreateParams;
import com.anthropic.models.messages.RawMessageStreamEvent;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.time.Duration;
import java.util.Iterator;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executor;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Supplier;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;

/**
 * Drives the real Anthropic SDK client built by {@link ClientFactory} against a real HTTP server on the
 * loopback interface. No test touches the network beyond loopback.
 */
class ClientFactoryTest {

    private static String textOf(Message message) {
        StringBuilder text = new StringBuilder();
        message.content().forEach(block -> block.text().ifPresent(textBlock -> text.append(textBlock.text())));
        return text.toString();
    }

    @ParameterizedTest
    @ValueSource(strings = {"", "/anthropic"})
    void bearerUsesMessagesPathModelAndRotatingAuthorization(String path) throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            RotatingTokens tokens = new RotatingTokens();
            AnthropicClient client = TestClients.bearer(server, tokens.supplier(), path, null, 0, null);

            Message first = client.messages().create(TestClients.params("my-custom-deployment"));
            client.messages().create(TestClients.params());
            client.close();

            assertEquals("OK", textOf(first));
            List<Recorded> requests = server.requests();
            assertEquals(2, requests.size());
            assertEquals(path + "/v1/messages", requests.get(0).path());
            assertEquals("Bearer rotating-token-1", requests.get(0).header("Authorization"));
            assertEquals("Bearer rotating-token-2", requests.get(1).header("Authorization"));
            assertFalse(requests.get(0).has("x-api-key"));
            assertFalse(requests.get(0).has("api-key"));
            assertEquals(TestClients.sdkDefaultHeader("X-Stainless-Timeout"), requests.get(0).header("X-Stainless-Timeout"));
            assertTrue(requests.get(0).body().contains("\"model\":\"my-custom-deployment\""), requests.get(0).body());
            assertTrue(requests.get(0).body().contains("\"max_tokens\":1024"), requests.get(0).body());
            assertFalse(requests.get(0).body().contains("\"stream\""));
            assertEquals(2, tokens.calls());
        }
    }

    @ParameterizedTest
    @CsvSource({
        "x-api-key,synthetic-resource-key",
        "api-key,synthetic-resource-key",
        "X-Custom-Key,synthetic-resource-key",
        "Authorization,Bearer synthetic-resource-key"
    })
    void apiKeyPlacesTheKeyInTheChosenHeaderOnly(String header, String expectedValue) throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            AnthropicClient client = TestClients.apiKey(server, "synthetic-resource-key", header, 0);
            client.messages().create(TestClients.params());
            client.close();

            Recorded request = server.single();
            assertEquals(expectedValue, request.header(header));
            for (String closedName : List.of("Authorization", "x-api-key", "api-key")) {
                if (!closedName.equalsIgnoreCase(header)) {
                    assertFalse(request.has(closedName), closedName + " must not be sent");
                }
            }
        }
    }

    @Test
    void aChosenHeaderAlreadyOnTheRequestIsReplacedNotAppended() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            AnthropicClient client = TestClients.apiKey(server, "synthetic-resource-key", "X-Custom-Key", 0);
            MessageCreateParams params = MessageCreateParams.builder()
                    .model(TestClients.MODEL)
                    .maxTokens(1024L)
                    .addUserMessage("Hello")
                    .putAdditionalHeader("X-Custom-Key", AmbientEnvironment.EXTRA_API_KEY)
                    .build();
            client.messages().create(params);
            client.close();

            assertEquals("synthetic-resource-key", server.single().header("X-Custom-Key"));
            server.single().assertNoCanaryEgress();
        }
    }

    @Test
    void apiKeyDefaultHeaderIsAuthorizationBearer() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            AnthropicClient client = ClientFactory.create(
                    ClientFactory.Options.builder().baseUrl(server.baseUrl()).apiKey("synthetic-native-key").build());
            client.messages().create(TestClients.params());
            client.close();

            assertEquals("Bearer synthetic-native-key", server.single().header("Authorization"));
            assertFalse(server.single().has("x-api-key"));
        }
    }

    @ParameterizedTest
    @ValueSource(booleans = {true, false})
    void ambientNativeCredentialsNeverReachTheWire(boolean bearer) throws Exception {
        AmbientEnvironment.assertInstalled();
        try (RecordingServer server = new RecordingServer()) {
            AnthropicClient client = bearer
                    ? TestClients.bearer(server, new RotatingTokens().supplier())
                    : TestClients.apiKey(server, "synthetic-resource-key", "x-api-key", 0);
            client.messages().create(TestClients.params());
            client.close();

            Recorded request = server.single();
            request.assertNoCanaryEgress();
            assertEquals("127.0.0.1", request.header("Host").split(":")[0]);
        }
    }

    @Test
    void perRequestHeadersKeepBetasAndLoseCredentials() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            AnthropicClient client = TestClients.bearer(server, new RotatingTokens().supplier());
            client.messages().create(TestClients.params());
            MessageCreateParams extras = MessageCreateParams.builder()
                    .model(TestClients.MODEL)
                    .maxTokens(1024L)
                    .addUserMessage("Hello")
                    .putAdditionalHeader("anthropic-beta", "files-api-2025-04-14")
                    .putAdditionalHeader("Authorization", "Bearer " + AmbientEnvironment.EXTRA_AUTHORIZATION)
                    .putAdditionalHeader("x-api-key", AmbientEnvironment.EXTRA_API_KEY)
                    .putAdditionalHeader("X-Request-Source", "sample")
                    .build();
            client.messages().create(extras);
            client.close();

            List<Recorded> requests = server.requests();
            assertFalse(requests.get(0).has("anthropic-beta"));
            assertEquals("files-api-2025-04-14", requests.get(1).header("anthropic-beta"));
            assertEquals("sample", requests.get(1).header("X-Request-Source"));
            assertFalse(requests.get(1).has("x-api-key"));
            assertEquals("Bearer rotating-token-2", requests.get(1).header("Authorization"));
            for (Recorded request : requests) {
                assertFalse(request.everything().contains("oauth-2025-04-20"));
                request.assertNoCanaryEgress();
            }
        }
    }

    @Test
    void apiVersionNullKeepsTheSdkDefaultAndAValueReplacesIt() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            AnthropicClient plain = AnthropicOkHttpClient.builder().baseUrl(server.baseUrl()).apiKey("baseline-key").build();
            plain.messages().create(TestClients.params());
            plain.close();
            String sdkDefault = server.requests().get(0).header("anthropic-version");
            assertNotNull(sdkDefault);

            AnthropicClient keepsDefault = TestClients.bearer(server, new RotatingTokens().supplier(), "", null, 0, null);
            keepsDefault.messages().create(TestClients.params());
            keepsDefault.close();
            AnthropicClient replaces = TestClients.bearer(server, new RotatingTokens().supplier(), "", "2023-06-01", 0, null);
            replaces.messages().create(TestClients.params());
            replaces.close();

            assertEquals(sdkDefault, server.requests().get(1).header("anthropic-version"));
            assertEquals("2023-06-01", server.requests().get(2).header("anthropic-version"));
            assertNotEquals("2023-06-01", sdkDefault);
        }
    }

    @Test
    void streamingUsesTheSameStandardClientAndPerAttemptCredential() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            server.enqueue((exchange, request) -> Responses.stream(exchange, "Hel", "lo"));
            RotatingTokens tokens = new RotatingTokens();
            AnthropicClient client = TestClients.bearer(server, tokens.supplier());

            StringBuilder text = new StringBuilder();
            try (StreamResponse<RawMessageStreamEvent> stream = client.messages().createStreaming(TestClients.params())) {
                for (RawMessageStreamEvent event : stream) {
                    if (event.isContentBlockDelta() && event.asContentBlockDelta().delta().isText()) {
                        text.append(event.asContentBlockDelta().delta().asText().text());
                    }
                }
            }
            client.close();

            assertEquals("Hello", text.toString());
            Recorded request = server.single();
            assertTrue(request.body().contains("\"stream\":true"), request.body());
            assertEquals("Bearer rotating-token-1", request.header("Authorization"));
            assertFalse(request.has("anthropic-beta"));
            assertEquals("/v1/messages", request.path());
        }
    }

    @Test
    void retryRequestsAFreshTokenForEveryAttempt() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            server.enqueue((exchange, request) -> {
                exchange.getResponseHeaders().add("Retry-After-Ms", "1");
                Responses.error(exchange, 500, "api_error", "try again");
            });
            RotatingTokens tokens = new RotatingTokens();
            AnthropicClient client = TestClients.bearer(server, tokens.supplier(), "", null, null, null);

            Message message = client.messages().create(TestClients.params());
            client.close();

            assertEquals("OK", textOf(message));
            List<Recorded> requests = server.requests();
            assertEquals(2, requests.size());
            assertEquals("Bearer rotating-token-1", requests.get(0).header("Authorization"));
            assertEquals("Bearer rotating-token-2", requests.get(1).header("Authorization"));
            assertEquals("0", requests.get(0).header("x-stainless-retry-count"));
            assertEquals("1", requests.get(1).header("x-stainless-retry-count"));
            assertEquals(2, tokens.calls());
        }
    }

    @ParameterizedTest
    @CsvSource({"401,authentication_error", "403,permission_error"})
    void authFailuresSurfaceTypedStatusWithoutHiddenRetries(int status, String errorType) throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            server.enqueue((exchange, request) -> Responses.error(exchange, status, errorType, "rejected"));
            RotatingTokens tokens = new RotatingTokens();
            AnthropicClient client = TestClients.bearer(server, tokens.supplier(), "", null, null, null);

            AnthropicServiceException failure = assertThrows(
                    AnthropicServiceException.class, () -> client.messages().create(TestClients.params()));
            client.close();

            assertEquals(status, failure.statusCode());
            Class<? extends AnthropicServiceException> expected =
                    status == 401 ? UnauthorizedException.class : PermissionDeniedException.class;
            assertInstanceOf(expected, failure);
            assertEquals(1, server.requests().size());
            assertEquals(1, tokens.calls());
            assertFalse(String.valueOf(failure.getMessage()).contains("rotating-token"));
        }
    }

    @Test
    void supplierFailurePropagatesItsTypeWithoutRetriesOrRequests() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            AtomicInteger calls = new AtomicInteger();
            Supplier<String> failing = () -> {
                calls.incrementAndGet();
                throw new UnsupportedOperationException("synthetic supplier failure");
            };
            AnthropicClient client = TestClients.bearer(server, failing, "", null, null, null);

            UnsupportedOperationException failure = assertThrows(
                    UnsupportedOperationException.class, () -> client.messages().create(TestClients.params()));
            client.close();

            assertEquals("synthetic supplier failure", failure.getMessage());
            assertEquals(1, calls.get());
            assertTrue(server.requests().isEmpty());
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {"", "has space", "line\r\nbreak", "tab\there"})
    void malformedTokensAreRejectedBeforeAnyRequest(String token) throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            AnthropicClient client = TestClients.bearer(server, () -> token, "", null, null, null);

            IllegalStateException failure = assertThrows(
                    IllegalStateException.class, () -> client.messages().create(TestClients.params()));
            client.close();

            assertTrue(server.requests().isEmpty());
            assertFalse(failure.getMessage().contains("break"));
        }
    }

    @ParameterizedTest
    @ValueSource(ints = {301, 302, 303, 307, 308})
    void redirectsAreRefusedWithoutFollowingOrRetrying(int status) throws Exception {
        try (RecordingServer attacker = new RecordingServer(); RecordingServer origin = new RecordingServer()) {
            origin.enqueue((exchange, request) -> Responses.redirect(exchange, status, attacker.baseUrl() + "/steal"));
            AnthropicClient client = TestClients.apiKey(origin, "synthetic-resource-key", "x-api-key", null);

            IllegalStateException failure = assertThrows(
                    IllegalStateException.class, () -> client.messages().create(TestClients.params()));
            client.close();

            assertTrue(failure.getMessage().toLowerCase().contains("redirect"), failure.getMessage());
            assertFalse(failure.getMessage().contains(attacker.baseUrl()));
            assertEquals(1, origin.requests().size());
            assertTrue(attacker.requests().isEmpty());
        }
    }

    @Test
    void originBindingRefusesRequestsForAnotherOriginBeforeAskingForATokenOrSending() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            RotatingTokens tokens = new RotatingTokens();
            AnthropicClient client = TestClients.bearer(server, tokens.supplier(), "", null, null, null);
            AnthropicClient retargeted = client.withOptions(options -> options.baseUrl("https://attacker.example"));

            IllegalStateException failure = assertThrows(
                    IllegalStateException.class, () -> retargeted.messages().create(TestClients.params()));
            client.close();

            assertTrue(failure.getMessage().contains("bound"), failure.getMessage());
            assertTrue(server.requests().isEmpty());
            assertEquals(0, tokens.calls());
        }
    }

    @Test
    void timeoutKeepsTheSdkDefaultUntilTheCallerSetsOne() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            AnthropicClient keepsDefault = TestClients.bearer(server, new RotatingTokens().supplier(), "", null, 0, null);
            keepsDefault.messages().create(TestClients.params());
            keepsDefault.close();
            AnthropicClient overrides =
                    TestClients.bearer(server, new RotatingTokens().supplier(), "", null, 0, Duration.ofSeconds(45));
            overrides.messages().create(TestClients.params());
            overrides.close();

            String sdkDefault = TestClients.sdkDefaultHeader("X-Stainless-Timeout");
            assertEquals(sdkDefault, server.requests().get(0).header("X-Stainless-Timeout"));
            assertEquals("45", server.requests().get(1).header("X-Stainless-Timeout"));
            assertNotEquals("45", sdkDefault);
        }
    }

    @Test
    void asyncMessagesUseTheStandardClientAndAFreshBearerToken() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            RotatingTokens tokens = new RotatingTokens();
            AnthropicClient client = TestClients.bearer(server, tokens.supplier());

            Message message = client.async().messages()
                    .create(TestClients.params("my-custom-deployment"))
                    .get(10, TimeUnit.SECONDS);
            client.close();

            assertEquals("OK", textOf(message));
            Recorded request = server.single();
            assertEquals("/v1/messages", request.path());
            assertEquals("Bearer rotating-token-1", request.header("Authorization"));
            assertFalse(request.has("x-api-key"));
            assertFalse(request.has("api-key"));
            assertFalse(request.has("anthropic-beta"));
            assertTrue(request.body().contains("\"model\":\"my-custom-deployment\""), request.body());
            assertEquals(1, tokens.calls());
            request.assertNoCanaryEgress();
        }
    }

    @ParameterizedTest
    @CsvSource({"x-api-key,synthetic-resource-key", "Authorization,Bearer synthetic-resource-key"})
    void asyncApiKeyIsPlacedInTheChosenHeaderOnly(String header, String expectedValue) throws Exception {
        AmbientEnvironment.assertInstalled();
        try (RecordingServer server = new RecordingServer()) {
            AnthropicClient client = TestClients.apiKey(server, "synthetic-resource-key", header, 0);

            client.async().messages().create(TestClients.params()).get(10, TimeUnit.SECONDS);
            client.close();

            Recorded request = server.single();
            assertEquals(expectedValue, request.header(header));
            for (String closedName : List.of("Authorization", "x-api-key", "api-key")) {
                assertEquals(closedName.equalsIgnoreCase(header), request.has(closedName), closedName);
            }
            request.assertNoCanaryEgress();
        }
    }

    @Test
    void asyncPerRequestHeadersKeepBetasAndLoseCredentials() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            AnthropicClient client = TestClients.bearer(server, new RotatingTokens().supplier());
            MessageCreateParams extras = MessageCreateParams.builder()
                    .model(TestClients.MODEL)
                    .maxTokens(1024L)
                    .addUserMessage("Hello")
                    .putAdditionalHeader("anthropic-beta", "files-api-2025-04-14")
                    .putAdditionalHeader("Authorization", "Bearer " + AmbientEnvironment.EXTRA_AUTHORIZATION)
                    .putAdditionalHeader("x-api-key", AmbientEnvironment.EXTRA_API_KEY)
                    .putAdditionalHeader("X-Request-Source", "sample")
                    .build();

            client.async().messages().create(extras).get(10, TimeUnit.SECONDS);
            client.close();

            Recorded request = server.single();
            assertEquals("files-api-2025-04-14", request.header("anthropic-beta"));
            assertEquals("sample", request.header("X-Request-Source"));
            assertFalse(request.has("x-api-key"));
            assertEquals("Bearer rotating-token-1", request.header("Authorization"));
            assertFalse(request.everything().contains("oauth-2025-04-20"));
            request.assertNoCanaryEgress();
        }
    }

    @Test
    void asyncStreamingUsesTheSameStandardClientAndAFreshTokenPerAttempt() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            server.enqueue((exchange, request) -> Responses.stream(exchange, "Hel", "lo"));
            RotatingTokens tokens = new RotatingTokens();
            AnthropicClient client = TestClients.bearer(server, tokens.supplier());

            StringBuilder text = new StringBuilder();
            AsyncStreamResponse<RawMessageStreamEvent> stream =
                    client.async().messages().createStreaming(TestClients.params());
            stream.subscribe(event -> {
                if (event.isContentBlockDelta() && event.asContentBlockDelta().delta().isText()) {
                    text.append(event.asContentBlockDelta().delta().asText().text());
                }
            });
            stream.onCompleteFuture().get(10, TimeUnit.SECONDS);
            client.close();

            assertEquals("Hello", text.toString());
            Recorded request = server.single();
            assertTrue(request.body().contains("\"stream\":true"), request.body());
            assertEquals("Bearer rotating-token-1", request.header("Authorization"));
            assertFalse(request.has("anthropic-beta"));
            assertEquals(1, tokens.calls());
        }
    }

    @Test
    void asyncRetryRequestsAFreshTokenForEveryAttempt() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            server.enqueue((exchange, request) -> {
                exchange.getResponseHeaders().add("Retry-After-Ms", "1");
                Responses.error(exchange, 500, "api_error", "try again");
            });
            RotatingTokens tokens = new RotatingTokens();
            AnthropicClient client = TestClients.bearer(server, tokens.supplier(), "", null, null, null);

            Message message = client.async().messages().create(TestClients.params()).get(10, TimeUnit.SECONDS);
            client.close();

            assertEquals("OK", textOf(message));
            List<Recorded> requests = server.requests();
            assertEquals(2, requests.size());
            assertEquals("Bearer rotating-token-1", requests.get(0).header("Authorization"));
            assertEquals("Bearer rotating-token-2", requests.get(1).header("Authorization"));
            assertEquals("0", requests.get(0).header("x-stainless-retry-count"));
            assertEquals("1", requests.get(1).header("x-stainless-retry-count"));
            assertEquals(2, tokens.calls());
        }
    }

    @ParameterizedTest
    @CsvSource({"401,authentication_error", "403,permission_error"})
    void asyncAuthFailuresSurfaceTypedStatusWithoutHiddenRetries(int status, String errorType) throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            server.enqueue((exchange, request) -> Responses.error(exchange, status, errorType, "rejected"));
            RotatingTokens tokens = new RotatingTokens();
            AnthropicClient client = TestClients.bearer(server, tokens.supplier(), "", null, null, null);

            ExecutionException failure = assertThrows(
                    ExecutionException.class,
                    () -> client.async().messages().create(TestClients.params()).get(10, TimeUnit.SECONDS));
            client.close();

            Class<? extends AnthropicServiceException> expected =
                    status == 401 ? UnauthorizedException.class : PermissionDeniedException.class;
            assertInstanceOf(expected, failure.getCause());
            assertEquals(status, ((AnthropicServiceException) failure.getCause()).statusCode());
            assertEquals(1, server.requests().size());
            assertEquals(1, tokens.calls());
        }
    }

    @Test
    void asyncSupplierFailurePropagatesItsTypeWithoutRetriesOrRequests() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            AtomicInteger calls = new AtomicInteger();
            Supplier<String> failing = () -> {
                calls.incrementAndGet();
                throw new UnsupportedOperationException("synthetic supplier failure");
            };
            AnthropicClient client = TestClients.bearer(server, failing, "", null, null, null);

            ExecutionException failure = assertThrows(
                    ExecutionException.class,
                    () -> client.async().messages().create(TestClients.params()).get(10, TimeUnit.SECONDS));
            client.close();

            assertInstanceOf(UnsupportedOperationException.class, failure.getCause());
            assertEquals("synthetic supplier failure", failure.getCause().getMessage());
            assertEquals(1, calls.get());
            assertTrue(server.requests().isEmpty());
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {"", "has space", "line\r\nbreak", "tab\there"})
    void asyncMalformedTokensAreRejectedBeforeAnyRequest(String token) throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            AnthropicClient client = TestClients.bearer(server, () -> token, "", null, null, null);

            ExecutionException failure = assertThrows(
                    ExecutionException.class,
                    () -> client.async().messages().create(TestClients.params()).get(10, TimeUnit.SECONDS));
            client.close();

            assertInstanceOf(IllegalStateException.class, failure.getCause());
            assertTrue(server.requests().isEmpty());
            assertFalse(failure.getCause().getMessage().contains("break"));
        }
    }

    @ParameterizedTest
    @ValueSource(ints = {301, 302, 303, 307, 308})
    void asyncRedirectsAreRefusedWithoutFollowingOrRetrying(int status) throws Exception {
        try (RecordingServer elsewhere = new RecordingServer(); RecordingServer origin = new RecordingServer()) {
            origin.enqueue((exchange, request) -> Responses.redirect(exchange, status, elsewhere.baseUrl() + "/other"));
            AnthropicClient client = TestClients.apiKey(origin, "synthetic-resource-key", "x-api-key", null);

            ExecutionException failure = assertThrows(
                    ExecutionException.class,
                    () -> client.async().messages().create(TestClients.params()).get(10, TimeUnit.SECONDS));
            client.close();

            assertInstanceOf(IllegalStateException.class, failure.getCause());
            assertTrue(failure.getCause().getMessage().toLowerCase().contains("redirect"), failure.getCause().getMessage());
            assertFalse(failure.getCause().getMessage().contains(elsewhere.baseUrl()));
            assertEquals(1, origin.requests().size());
            assertTrue(elsewhere.requests().isEmpty());
        }
    }

    @Test
    void asyncOriginBindingRefusesAnotherOriginBeforeAskingForATokenOrSending() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            RotatingTokens tokens = new RotatingTokens();
            AnthropicClient client = TestClients.bearer(server, tokens.supplier(), "", null, null, null);
            AnthropicClient retargeted = client.withOptions(options -> options.baseUrl("https://other.example"));

            ExecutionException failure = assertThrows(
                    ExecutionException.class,
                    () -> retargeted.async().messages().create(TestClients.params()).get(10, TimeUnit.SECONDS));
            client.close();

            assertInstanceOf(IllegalStateException.class, failure.getCause());
            assertTrue(failure.getCause().getMessage().contains("bound"), failure.getCause().getMessage());
            assertTrue(server.requests().isEmpty());
            assertEquals(0, tokens.calls());
        }
    }

    @Test
    void asyncTokenFetchRunsOffTheCallerThreadSoTheCallerIsNotBlocked() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            CountDownLatch release = new CountDownLatch(1);
            AtomicReference<Thread> supplierThread = new AtomicReference<>();
            Supplier<String> slow = () -> {
                supplierThread.set(Thread.currentThread());
                try {
                    release.await(30, TimeUnit.SECONDS);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
                return "slow-token";
            };
            AnthropicClient client = TestClients.bearer(server, slow, "", null, null, null);

            CompletableFuture<Message> pending = client.async().messages().create(TestClients.params());

            assertFalse(pending.isDone());
            assertTrue(server.requests().isEmpty());
            release.countDown();
            Message message = pending.get(10, TimeUnit.SECONDS);
            client.close();

            assertEquals("OK", textOf(message));
            assertNotSame(Thread.currentThread(), supplierThread.get());
            assertEquals("Bearer slow-token", server.single().header("Authorization"));
        }
    }

    @Test
    void asyncTokenFetchUsesTheConfiguredExecutorAndBlockingCallsNeverDo() throws Exception {
        ExecutorService executor = Executors.newSingleThreadExecutor(task -> new Thread(task, "token-executor-test"));
        try (RecordingServer server = new RecordingServer()) {
            AtomicReference<Thread> supplierThread = new AtomicReference<>();
            Supplier<String> supplier = () -> {
                supplierThread.set(Thread.currentThread());
                return "executor-token";
            };
            AnthropicClient client = ClientFactory.create(ClientFactory.Options.builder()
                    .baseUrl(server.baseUrl())
                    .tokenSupplier(supplier)
                    .tokenExecutor(executor)
                    .build());

            client.async().messages().create(TestClients.params()).get(10, TimeUnit.SECONDS);
            assertEquals("token-executor-test", supplierThread.get().getName());
            assertEquals("Bearer executor-token", server.requests().get(0).header("Authorization"));

            client.messages().create(TestClients.params());
            assertSame(Thread.currentThread(), supplierThread.get());
            client.close();
        } finally {
            executor.shutdownNow();
        }
    }

    @Test
    void cancellingBeforeTheTokenArrivesSendsNothing() throws Exception {
        ExecutorService executor = Executors.newSingleThreadExecutor();
        try {
            CountDownLatch started = new CountDownLatch(1);
            CountDownLatch release = new CountDownLatch(1);
            FakeHttpClient next = new FakeHttpClient();
            HttpClient decorated = decorate(next, () -> {
                started.countDown();
                try {
                    release.await(30, TimeUnit.SECONDS);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
                return "late-token";
            }, executor);

            CompletableFuture<HttpResponse> call = decorated.executeAsync(messagesRequest(), RequestOptions.none());
            assertTrue(started.await(10, TimeUnit.SECONDS));
            call.cancel(true);
            release.countDown();
            executor.submit(() -> { }).get(10, TimeUnit.SECONDS); // runs only after the token task has finished

            assertTrue(call.isCancelled());
            assertTrue(next.sent.isEmpty());
        } finally {
            executor.shutdownNow();
        }
    }

    @Test
    void cancellingAfterTheRequestWasSentCancelsTheInFlightCall() {
        FakeHttpClient next = new FakeHttpClient();
        HttpClient decorated = decorate(next, () -> "token", Runnable::run);

        CompletableFuture<HttpResponse> call = decorated.executeAsync(messagesRequest(), RequestOptions.none());
        assertEquals(1, next.sent.size());
        call.cancel(true);

        assertTrue(next.inFlight.isCancelled());
    }

    @Test
    void anInFlightFailureSurfacesWithItsOwnType() {
        FakeHttpClient next = new FakeHttpClient();
        HttpClient decorated = decorate(next, () -> "token", Runnable::run);
        CompletableFuture<HttpResponse> call = decorated.executeAsync(messagesRequest(), RequestOptions.none());
        IOException failure = new IOException("synthetic transport failure");

        next.inFlight.completeExceptionally(failure);

        ExecutionException thrown = assertThrows(ExecutionException.class, () -> call.get(10, TimeUnit.SECONDS));
        assertSame(failure, thrown.getCause());
    }

    @Test
    void aRedirectResponseIsClosedAndRefusedWhileOtherResponsesPassThrough() throws Exception {
        FakeHttpClient redirecting = new FakeHttpClient();
        FakeResponse redirect = new FakeResponse(307);
        CompletableFuture<HttpResponse> refused =
                decorate(redirecting, () -> "token", Runnable::run).executeAsync(messagesRequest(), RequestOptions.none());
        redirecting.inFlight.complete(redirect);

        ExecutionException thrown = assertThrows(ExecutionException.class, () -> refused.get(10, TimeUnit.SECONDS));
        assertInstanceOf(IllegalStateException.class, thrown.getCause());
        assertTrue(redirect.closed);

        FakeHttpClient answering = new FakeHttpClient();
        FakeResponse ok = new FakeResponse(200);
        CompletableFuture<HttpResponse> accepted =
                decorate(answering, () -> "token", Runnable::run).executeAsync(messagesRequest(), RequestOptions.none());
        answering.inFlight.complete(ok);

        assertSame(ok, accepted.get(10, TimeUnit.SECONDS));
        assertFalse(ok.closed);
    }

    @Test
    void closeDelegatesToTheWrappedClient() {
        FakeHttpClient next = new FakeHttpClient();

        decorate(next, () -> "token", Runnable::run).close();

        assertTrue(next.closed);
    }

    private static HttpClient decorate(HttpClient next, Supplier<String> tokens, Executor executor) {
        String baseUrl = "http://127.0.0.1:9";
        ClientFactory.Options options = ClientFactory.Options.builder()
                .baseUrl(baseUrl)
                .tokenSupplier(tokens)
                .tokenExecutor(executor)
                .build();
        return ClientFactory.interceptor(URI.create(baseUrl), options).intercept(next);
    }

    private static HttpRequest messagesRequest() {
        return HttpRequest.builder()
                .method(HttpMethod.POST)
                .baseUrl("http://127.0.0.1:9")
                .addPathSegments("v1", "messages")
                .build();
    }

    /** An SDK HttpClient whose asynchronous call stays pending until the test completes it. */
    private static final class FakeHttpClient implements HttpClient {
        final CompletableFuture<HttpResponse> inFlight = new CompletableFuture<>();
        final List<HttpRequest> sent = new CopyOnWriteArrayList<>();
        volatile boolean closed;

        @Override
        public HttpResponse execute(HttpRequest request, RequestOptions requestOptions) {
            throw new UnsupportedOperationException("only the asynchronous path is used");
        }

        @Override
        public CompletableFuture<HttpResponse> executeAsync(HttpRequest request, RequestOptions requestOptions) {
            sent.add(request);
            return inFlight;
        }

        @Override
        public void close() {
            closed = true;
        }
    }

    private static final class FakeResponse implements HttpResponse {
        private final int status;
        volatile boolean closed;

        FakeResponse(int status) {
            this.status = status;
        }

        @Override
        public int statusCode() {
            return status;
        }

        @Override
        public Headers headers() {
            return Headers.builder().build();
        }

        @Override
        public InputStream body() {
            return InputStream.nullInputStream();
        }

        @Override
        public void close() {
            closed = true;
        }
    }

    @Test
    void timeoutIsAppliedPerCallAndRetriedBySdk() throws Exception {
        CountDownLatch release = new CountDownLatch(1);
        try (RecordingServer server = new RecordingServer()) {
            RecordingServer.Responder stall = (exchange, request) -> release.await(30, TimeUnit.SECONDS);
            server.enqueue(stall);
            server.enqueue(stall);
            AnthropicClient client = TestClients.bearer(
                    server, new RotatingTokens().supplier(), "", null, 1, Duration.ofMillis(300));

            AnthropicIoException failure = assertThrows(
                    AnthropicIoException.class, () -> client.messages().create(TestClients.params()));
            release.countDown();
            client.close();

            assertNotNull(failure);
            assertEquals(2, server.requests().size());
        } finally {
            release.countDown();
        }
    }

    @Test
    void retryBackoffRemainsInterruptible() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            server.enqueue((exchange, request) -> {
                exchange.getResponseHeaders().add("Retry-After-Ms", "60000");
                Responses.error(exchange, 503, "overloaded_error", "busy");
            });
            AnthropicClient client = TestClients.bearer(server, new RotatingTokens().supplier(), "", null, null, null);
            AtomicReference<Throwable> outcome = new AtomicReference<>();
            Thread caller = new Thread(() -> {
                try {
                    client.messages().create(TestClients.params());
                } catch (Throwable t) {
                    outcome.set(t);
                }
            });

            caller.start();
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
            while (server.requests().isEmpty() && System.nanoTime() < deadline) {
                Thread.sleep(10);
            }
            Thread.sleep(200);
            caller.interrupt();
            caller.join(TimeUnit.SECONDS.toMillis(10));
            client.close();

            assertFalse(caller.isAlive(), "the interrupted call must return");
            assertInstanceOf(InterruptedException.class, outcome.get());
            assertEquals(1, server.requests().size());
        }
    }

    @Test
    void closingAStreamStopsItWithoutRetrying() throws Exception {
        CountDownLatch release = new CountDownLatch(1);
        try (RecordingServer server = new RecordingServer()) {
            server.enqueue((exchange, request) -> {
                exchange.getResponseHeaders().add("Content-Type", "text/event-stream");
                exchange.sendResponseHeaders(200, 0);
                exchange.getResponseBody().write(Responses.messageStartEvent().getBytes(java.nio.charset.StandardCharsets.UTF_8));
                exchange.getResponseBody().flush();
                release.await(30, TimeUnit.SECONDS);
            });
            AnthropicClient client = TestClients.bearer(server, new RotatingTokens().supplier(), "", null, null, null);

            long start = System.nanoTime();
            try (StreamResponse<RawMessageStreamEvent> stream = client.messages().createStreaming(TestClients.params())) {
                Iterator<RawMessageStreamEvent> events = stream.iterator();
                assertTrue(events.next().isMessageStart());
            }
            long elapsedMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start);
            release.countDown();
            client.close();

            assertTrue(elapsedMillis < 10_000, "closing the stream must not wait for the server");
            assertEquals(1, server.requests().size());
        } finally {
            release.countDown();
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {
        "", "not a url", "/relative/path", "http://example.com", "ftp://example.com",
        "https://user:pass@example.com", "https://example.com/path?query=1", "https://example.com/path#fragment"
    })
    void createRejectsUnsafeBaseUrls(String baseUrl) {
        assertThrows(IllegalArgumentException.class, () -> ClientFactory.create(
                ClientFactory.Options.builder().baseUrl(baseUrl).apiKey("synthetic-key").build()));
    }

    @ParameterizedTest
    @ValueSource(strings = {"http://127.0.0.1:5000", "http://localhost:5000", "http://[::1]:5000", "https://example.com"})
    void createAcceptsHttpsAndLoopbackHttp(String baseUrl) {
        AnthropicClient client = ClientFactory.create(
                ClientFactory.Options.builder().baseUrl(baseUrl).apiKey("synthetic-key").build());
        assertNotNull(client);
        client.close();
    }

    @Test
    void createRequiresExactlyOneCredential() {
        assertThrows(IllegalArgumentException.class, () -> ClientFactory.create(
                ClientFactory.Options.builder().baseUrl("https://example.com").build()));
        assertThrows(IllegalArgumentException.class, () -> ClientFactory.create(
                ClientFactory.Options.builder()
                        .baseUrl("https://example.com")
                        .apiKey("synthetic-key")
                        .tokenSupplier(() -> "token")
                        .build()));
        assertThrows(IllegalArgumentException.class, () -> ClientFactory.create(null));
    }

    @ParameterizedTest
    @CsvSource(value = {
        "'api-key-with-space ',x-api-key,,", "synthetic-key,'bad header',,", "synthetic-key,'bad:header',,",
        "synthetic-key,'',,", "synthetic-key,x-api-key,'bad version',", "synthetic-key,x-api-key,'',",
        "synthetic-key,x-api-key,,-1"
    })
    void createRejectsMalformedOptions(String apiKey, String header, String apiVersion, Integer maxRetries) {
        ClientFactory.Options.Builder options = ClientFactory.Options.builder()
                .baseUrl("https://example.com")
                .apiKey(apiKey)
                .apiKeyHeader(header)
                .apiVersion(apiVersion);
        if (maxRetries != null) {
            options.maxRetries(maxRetries);
        }
        assertThrows(IllegalArgumentException.class, () -> ClientFactory.create(options.build()));
    }

    @ParameterizedTest
    @ValueSource(longs = {0, -5})
    void createRejectsNonPositiveTimeouts(long seconds) {
        assertThrows(IllegalArgumentException.class, () -> ClientFactory.create(
                ClientFactory.Options.builder()
                        .baseUrl("https://example.com")
                        .apiKey("synthetic-key")
                        .timeout(Duration.ofSeconds(seconds))
                        .build()));
    }
}