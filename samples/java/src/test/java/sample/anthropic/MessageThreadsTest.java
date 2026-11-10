package sample.anthropic;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.azure.core.credential.AccessToken;
import com.azure.core.credential.TokenCredential;
import com.azure.core.credential.TokenRequestContext;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpExchange;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
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

/** The thread example end to end: the real SDK helper against a loopback server that records every request. */
class MessageThreadsTest {
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final String BETA = "message-threads-2026-08-12";
    private static final String FIRST = "user: Remember the code ORCHID-47. Reply with OK.";
    private static final String SECOND = "user: What code did I ask you to remember? Reply with only the code.";

    private record RunResult(int exitCode, String output, String error) {}

    private static final class FakeCredential implements TokenCredential, AutoCloseable {
        private final AtomicInteger calls = new AtomicInteger();
        boolean closed;

        @Override
        public Mono<AccessToken> getToken(TokenRequestContext context) {
            return Mono.fromSupplier(this::token);
        }

        @Override
        public AccessToken getTokenSync(TokenRequestContext context) {
            return token();
        }

        private AccessToken token() {
            return new AccessToken("thread-token-" + calls.incrementAndGet(), OffsetDateTime.now().plusHours(1));
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
        int exitCode = MessageThreads.run(
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

    private static RunResult run(RecordingServer server) {
        return run(new String[0], keyEnv(server), new FakeCredential());
    }

    private static String keyEnv(RecordingServer server) {
        return "ANTHROPIC_BASE_URL=" + server.baseUrl() + ";ANTHROPIC_MODEL=claude-sonnet-5-5;AUTH_MODE=api_key;"
                + "ANTHROPIC_API_KEY=thread-test-key";
    }

    private static String bearerEnv(RecordingServer server) {
        return "ANTHROPIC_BASE_URL=" + server.baseUrl() + ";ANTHROPIC_MODEL=claude-sonnet-5-5;AUTH_MODE=bearer";
    }

    private static void reply(HttpExchange exchange, String id, String text) throws IOException {
        Responses.json(exchange, 200, Responses.messageJson(Responses.quote(text), 11, 5).replace("msg_test", id));
    }

    private static void threadError(HttpExchange exchange, int status, String type, String errorCode) throws IOException {
        Responses.json(exchange, status, "{\"type\":\"error\",\"error\":{\"type\":\"" + type + "\",\"message\":\"synthetic\","
                + "\"details\":{\"error_code\":\"" + errorCode + "\"}}}");
    }

    private static JsonNode body(Recorded request) throws IOException {
        return JSON.readTree(request.body());
    }

    /** One "role: text" entry per message, whether its content is a string or a list of text blocks. */
    private static List<String> messages(JsonNode body) {
        List<String> messages = new ArrayList<>();
        for (JsonNode message : body.get("messages")) {
            JsonNode content = message.get("content");
            StringBuilder text = new StringBuilder();
            if (content.isTextual()) {
                text.append(content.asText());
            } else {
                content.forEach(block -> text.append(block.get("text").asText()));
            }
            messages.add(message.get("role").asText() + ": " + text);
        }
        return messages;
    }

    private static void assertThreadRequest(Recorded request) {
        assertEquals("POST", request.method());
        assertTrue(request.path().startsWith("/v1/messages"), request.path());
        assertEquals(BETA, request.header("anthropic-beta"));
        request.assertNoCanaryEgress();
    }

    @Test
    void createsTheThreadThenContinuesWithOnlyTheNewMessage() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            server.enqueue((exchange, request) -> reply(exchange, "msg_first", "OK"));
            server.enqueue((exchange, request) -> reply(exchange, "msg_second", "ORCHID-47"));

            RunResult result = run(server);

            assertEquals(0, result.exitCode(), result.error());
            assertEquals("ORCHID-47\n", result.output());
            assertEquals("", result.error());
            List<Recorded> requests = server.requests();
            assertEquals(2, requests.size());
            requests.forEach(MessageThreadsTest::assertThreadRequest);

            JsonNode create = body(requests.get(0));
            assertEquals(JSON.readTree("{\"type\":\"create\"}"), create.get("thread"));
            assertEquals("claude-sonnet-5-5", create.get("model").asText());
            assertEquals(1024, create.get("max_tokens").asLong());
            assertEquals("Keep replies short.", create.get("system").asText());
            assertEquals(List.of(FIRST), messages(create));

            JsonNode proceed = body(requests.get(1));
            assertEquals(
                    JSON.readTree("{\"type\":\"continue\",\"previous_message_id\":\"msg_first\"}"), proceed.get("thread"));
            assertEquals(create.get("model"), proceed.get("model"));
            assertEquals(create.get("max_tokens"), proceed.get("max_tokens"));
            assertEquals(List.of(SECOND), messages(proceed));
            assertFalse(proceed.has("system"), "system must be left out, even as null");
            assertFalse(proceed.has("tools"), "tools must be left out, even as null");
        }
    }

    @ParameterizedTest
    @CsvSource({
        "404,not_found_error,thread_not_found",
        "400,invalid_request_error,thread_already_continued",
        "400,invalid_request_error,thread_continue_in_flight"
    })
    void replaysTheWholeConversationOnceWhenTheThreadCannotBeContinued(int status, String type, String errorCode)
            throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            server.enqueue((exchange, request) -> reply(exchange, "msg_first", "OK"));
            server.enqueue((exchange, request) -> threadError(exchange, status, type, errorCode));
            server.enqueue((exchange, request) -> reply(exchange, "msg_third", "ORCHID-47"));

            RunResult result = run(server);

            assertEquals(0, result.exitCode(), result.error());
            assertEquals("ORCHID-47\n", result.output());
            List<Recorded> requests = server.requests();
            assertEquals(3, requests.size());
            requests.forEach(MessageThreadsTest::assertThreadRequest);

            JsonNode rejected = body(requests.get(1));
            assertEquals("continue", rejected.get("thread").get("type").asText());
            assertEquals(List.of(SECOND), messages(rejected));

            JsonNode replay = body(requests.get(2));
            assertEquals(JSON.readTree("{\"type\":\"create\"}"), replay.get("thread"));
            assertEquals("Keep replies short.", replay.get("system").asText());
            assertEquals(List.of(FIRST, "assistant: OK", SECOND), messages(replay));
        }
    }

    @Test
    void aReplayThatIsNotFoundAgainIsReportedNotRepeated() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            server.enqueue((exchange, request) -> reply(exchange, "msg_first", "OK"));
            server.enqueue((exchange, request) -> threadError(exchange, 404, "not_found_error", "thread_not_found"));
            server.enqueue((exchange, request) -> threadError(exchange, 404, "not_found_error", "thread_not_found"));

            RunResult result = run(server);

            assertEquals(SampleRunner.EXIT_FAILURE, result.exitCode());
            assertEquals("", result.output());
            assertTrue(result.error().contains("NotFoundException (HTTP 404)"), result.error());
            assertEquals(3, server.requests().size());
        }
    }

    // A missing thread is told apart by error.details.error_code, never by the status alone.
    @ParameterizedTest
    @CsvSource({"0,thread_not_found", "1,model_not_found", "1,"})
    void anotherNotFoundIsReportedNotReplayed(int failing, String errorCode) throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            if (failing == 1) {
                server.enqueue((exchange, request) -> reply(exchange, "msg_first", "OK"));
            }
            server.enqueue((exchange, request) -> {
                if (errorCode == null) {
                    Responses.error(exchange, 404, "not_found_error", "model: nope");
                } else {
                    threadError(exchange, 404, "not_found_error", errorCode);
                }
            });

            RunResult result = run(server);

            assertEquals(SampleRunner.EXIT_FAILURE, result.exitCode());
            assertEquals("", result.output());
            assertTrue(result.error().contains("NotFoundException (HTTP 404)"), result.error());
            assertEquals(failing + 1, server.requests().size());
        }
    }

    @Test
    void anUnsupportedThreadRequestIsAnErrorNotAnUnthreadedFallback() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            server.enqueue((exchange, request) -> reply(exchange, "msg_first", "OK"));
            server.enqueue((exchange, request) ->
                    threadError(exchange, 400, "invalid_request_error", "thread_unsupported_request"));

            RunResult result = run(server);

            assertEquals(SampleRunner.EXIT_FAILURE, result.exitCode());
            assertEquals("", result.output());
            assertTrue(result.error().contains("BadRequestException (HTTP 400)"), result.error());
            assertEquals(2, server.requests().size());
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {"", "   "})
    void aSecondReplyWithoutTextIsAFailure(String text) throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            server.enqueue((exchange, request) -> reply(exchange, "msg_first", "OK"));
            server.enqueue((exchange, request) -> reply(exchange, "msg_second", text));

            RunResult result = run(server);

            assertEquals(SampleRunner.EXIT_FAILURE, result.exitCode());
            assertEquals("", result.output());
            assertTrue(result.error().contains("UnusableResponseException"), result.error());
            assertTrue(result.error().contains("no text (stop_reason: end_turn)"), result.error());
        }
    }

    @Test
    void everyTurnCarriesItsOwnBearerToken() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            FakeCredential credential = new FakeCredential();

            RunResult result = run(new String[0], bearerEnv(server), credential);

            assertEquals(0, result.exitCode(), result.error());
            List<Recorded> requests = server.requests();
            assertEquals(2, requests.size());
            for (int turn = 0; turn < 2; turn++) {
                Recorded request = requests.get(turn);
                assertThreadRequest(request);
                assertEquals("Bearer " + "thread-token-" + (turn + 1), request.header("Authorization"));
                assertFalse(request.has("x-api-key"));
            }
            assertTrue(credential.closed);
        }
    }

    @Test
    void rejectedCredentialsAreReportedWithoutTheToken() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            server.enqueue((exchange, request) ->
                    Responses.error(exchange, 401, "authentication_error", "denied for thread-token-1"));

            RunResult result = run(new String[0], bearerEnv(server), new FakeCredential());

            assertEquals(SampleRunner.EXIT_FAILURE, result.exitCode());
            assertEquals("", result.output());
            assertTrue(result.error().contains("UnauthorizedException (HTTP 401)"), result.error());
            assertTrue(result.error().contains("[redacted]"), result.error());
            assertFalse(result.error().contains("thread-token"), result.error());
            assertEquals(1, server.requests().size());
        }
    }

    @Test
    void invalidConfigurationAndArgumentsSendNothing() throws Exception {
        try (RecordingServer server = new RecordingServer()) {
            RunResult noModel = run(
                    new String[0], "ANTHROPIC_BASE_URL=" + server.baseUrl() + ";AUTH_MODE=bearer", new FakeCredential());
            RunResult argument = run(new String[] {"hello"}, keyEnv(server), new FakeCredential());
            RunResult help = run(new String[] {"--help"}, "", new FakeCredential());

            assertEquals(SampleRunner.EXIT_USAGE, noModel.exitCode());
            assertTrue(noModel.error().contains("ANTHROPIC_MODEL"), noModel.error());
            assertEquals(SampleRunner.EXIT_USAGE, argument.exitCode());
            assertTrue(argument.error().contains("usage: MessageThreads"), argument.error());
            assertEquals(SampleRunner.EXIT_OK, help.exitCode());
            assertTrue(help.output().contains("usage: MessageThreads"), help.output());
            assertTrue(server.requests().isEmpty());
        }
    }
}