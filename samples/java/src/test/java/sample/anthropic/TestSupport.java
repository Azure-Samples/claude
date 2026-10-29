package sample.anthropic;

import com.anthropic.client.AnthropicClient;
import com.anthropic.client.okhttp.AnthropicOkHttpClient;
import com.anthropic.models.messages.MessageCreateParams;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.Queue;
import java.util.TreeMap;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Supplier;

/** The hostile ambient configuration that surefire installs for the whole test JVM (see pom.xml). */
final class AmbientEnvironment {
    static final String API_KEY = "canary-ambient-api-key";
    static final String AUTH_TOKEN = "canary-ambient-auth-token";
    static final String BASE_HOST = "canary-ambient-base.invalid";
    static final String PROFILE = "canary-ambient-profile";
    static final String IDENTITY_TOKEN = "canary-ambient-identity-token";
    static final String CUSTOM_API_KEY = "canary-ambient-custom-x-api-key";
    static final String CUSTOM_API_KEY_ALTERNATE = "canary-ambient-custom-api-key";
    static final String PROPERTY_API_KEY = "canary-ambient-property-api-key";
    static final String PROPERTY_AUTH_TOKEN = "canary-ambient-property-auth-token";
    static final String PROPERTY_BASE_HOST = "canary-ambient-property-base.invalid";
    static final String EXTRA_AUTHORIZATION = "canary-extra-authorization";
    static final String EXTRA_API_KEY = "canary-extra-key";

    static final List<String> ALL_CANARIES = List.of(
            API_KEY, AUTH_TOKEN, BASE_HOST, PROFILE, IDENTITY_TOKEN, CUSTOM_API_KEY, CUSTOM_API_KEY_ALTERNATE,
            PROPERTY_API_KEY, PROPERTY_AUTH_TOKEN, PROPERTY_BASE_HOST, EXTRA_AUTHORIZATION, EXTRA_API_KEY);

    private AmbientEnvironment() {}

    /** Fails unless the canaries are really present, so a missing surefire setup cannot make tests vacuous. */
    static void assertInstalled() {
        check(API_KEY, System.getenv("ANTHROPIC_API_KEY"));
        check(AUTH_TOKEN, System.getenv("ANTHROPIC_AUTH_TOKEN"));
        check(PROPERTY_API_KEY, System.getProperty("anthropic.apiKey"));
        check(PROPERTY_AUTH_TOKEN, System.getProperty("anthropic.authToken"));
    }

    private static void check(String expected, String actual) {
        if (!expected.equals(actual)) {
            throw new AssertionError("Ambient canary missing; run the tests through Maven (surefire sets them).");
        }
    }
}

/** One request as the server saw it. */
record Recorded(String method, String path, Map<String, List<String>> headers, String body) {
    boolean has(String name) {
        return headers.containsKey(name);
    }

    String header(String name) {
        List<String> values = headers.get(name);
        return values == null ? null : String.join(", ", values);
    }

    String everything() {
        StringBuilder text = new StringBuilder(method).append(' ').append(path).append('\n');
        headers.forEach((name, values) -> text.append(name).append(": ").append(String.join(", ", values)).append('\n'));
        return text.append(body).toString();
    }

    void assertNoCanaryEgress() {
        String everything = everything();
        for (String canary : AmbientEnvironment.ALL_CANARIES) {
            if (everything.toLowerCase().contains(canary)) {
                throw new AssertionError("Canary reached the wire: " + canary);
            }
        }
    }
}

/** A real HTTP server on the loopback interface that records every request the SDK sends. */
final class RecordingServer implements AutoCloseable {
    @FunctionalInterface
    interface Responder {
        void respond(HttpExchange exchange, Recorded request) throws Exception;
    }

    private final HttpServer server;
    private final ExecutorService executor = Executors.newCachedThreadPool();
    private final List<Recorded> requests = new CopyOnWriteArrayList<>();
    private final Queue<Responder> responders = new ConcurrentLinkedQueue<>();

    RecordingServer() throws IOException {
        server = HttpServer.create(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 0);
        server.createContext("/", this::handle);
        server.setExecutor(executor);
        server.start();
    }

    String baseUrl() {
        return "http://127.0.0.1:" + server.getAddress().getPort();
    }

    List<Recorded> requests() {
        return List.copyOf(requests);
    }

    Recorded single() {
        List<Recorded> all = requests();
        if (all.size() != 1) {
            throw new AssertionError("Expected exactly one request but saw " + all.size());
        }
        return all.get(0);
    }

    void enqueue(Responder responder) {
        responders.add(responder);
    }

    @Override
    public void close() {
        server.stop(0);
        executor.shutdownNow();
    }

    private void handle(HttpExchange exchange) throws IOException {
        byte[] body = exchange.getRequestBody().readAllBytes();
        Map<String, List<String>> headers = new TreeMap<>(String.CASE_INSENSITIVE_ORDER);
        exchange.getRequestHeaders().forEach((name, values) -> headers.put(name, List.copyOf(values)));
        Recorded recorded = new Recorded(
                exchange.getRequestMethod(),
                exchange.getRequestURI().toString(),
                headers,
                new String(body, StandardCharsets.UTF_8));
        requests.add(recorded);

        Responder responder = responders.poll();
        try {
            if (responder == null) {
                Responses.message(exchange, "OK", 11, 5);
            } else {
                responder.respond(exchange, recorded);
            }
        } catch (IOException e) {
            throw e;
        } catch (Exception e) {
            throw new IOException(e);
        } finally {
            exchange.close();
        }
    }
}

/** Canned service responses. */
final class Responses {
    private Responses() {}

    static String messageJson(String textJson, long inputTokens, long outputTokens) {
        return "{\"id\":\"msg_test\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"test-model\","
                + "\"content\":[{\"type\":\"text\",\"text\":" + textJson + "}],"
                + "\"stop_reason\":\"end_turn\",\"stop_sequence\":null,"
                + "\"usage\":{\"input_tokens\":" + inputTokens + ",\"output_tokens\":" + outputTokens + "}}";
    }

    static void message(HttpExchange exchange, String text, long inputTokens, long outputTokens) throws IOException {
        json(exchange, 200, messageJson(quote(text), inputTokens, outputTokens));
    }

    static void thinkingOnly(HttpExchange exchange) throws IOException {
        json(exchange, 200, "{\"id\":\"msg_test\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"test-model\","
                + "\"content\":[{\"type\":\"thinking\",\"thinking\":\"pondering\",\"signature\":\"sig\"}],"
                + "\"stop_reason\":\"max_tokens\",\"stop_sequence\":null,"
                + "\"usage\":{\"input_tokens\":11,\"output_tokens\":1024}}");
    }

    static void error(HttpExchange exchange, int status, String type, String message) throws IOException {
        json(exchange, status, "{\"type\":\"error\",\"error\":{\"type\":\"" + type + "\",\"message\":\"" + message + "\"}}");
    }

    static void redirect(HttpExchange exchange, int status, String location) throws IOException {
        exchange.getResponseHeaders().add("Location", location);
        exchange.sendResponseHeaders(status, -1);
    }

    static void json(HttpExchange exchange, int status, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().add("Content-Type", "application/json");
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream out = exchange.getResponseBody()) {
            out.write(bytes);
        }
    }

    /** A server-sent-event stream with one text delta per argument. */
    static void stream(HttpExchange exchange, String... textDeltas) throws IOException {
        streamEvents(exchange, true, textDeltas);
    }

    /** Like {@link #stream} but the connection ends before message_stop. */
    static void truncatedStream(HttpExchange exchange, String... textDeltas) throws IOException {
        streamEvents(exchange, false, textDeltas);
    }

    static String messageStartEvent() {
        return event("message_start", "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_stream\",\"type\":\"message\","
                + "\"role\":\"assistant\",\"model\":\"test-model\",\"content\":[],\"stop_reason\":null,"
                + "\"stop_sequence\":null,\"usage\":{\"input_tokens\":11,\"output_tokens\":1}}}");
    }

    private static void streamEvents(HttpExchange exchange, boolean includeStop, String[] textDeltas) throws IOException {
        StringBuilder sse = new StringBuilder(messageStartEvent());
        sse.append(event("content_block_start",
                "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"));
        for (String delta : textDeltas) {
            sse.append(event("content_block_delta", "{\"type\":\"content_block_delta\",\"index\":0,"
                    + "\"delta\":{\"type\":\"text_delta\",\"text\":" + quote(delta) + "}}"));
        }
        sse.append(event("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}"));
        sse.append(event("message_delta", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\","
                + "\"stop_sequence\":null},\"usage\":{\"output_tokens\":7}}"));
        if (includeStop) {
            sse.append(event("message_stop", "{\"type\":\"message_stop\"}"));
        }

        byte[] bytes = sse.toString().getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().add("Content-Type", "text/event-stream");
        exchange.sendResponseHeaders(200, bytes.length);
        try (OutputStream out = exchange.getResponseBody()) {
            out.write(bytes);
        }
    }

    static String event(String name, String data) {
        return "event: " + name + "\ndata: " + data + "\n\n";
    }

    static String quote(String text) {
        StringBuilder quoted = new StringBuilder("\"");
        for (char c : text.toCharArray()) {
            switch (c) {
                case '"' -> quoted.append("\\\"");
                case '\\' -> quoted.append("\\\\");
                case '\n' -> quoted.append("\\n");
                case '\r' -> quoted.append("\\r");
                case '\t' -> quoted.append("\\t");
                default -> quoted.append(c);
            }
        }
        return quoted.append('"').toString();
    }
}

/** A token supplier that hands out a different token per call, like a renewing credential. */
final class RotatingTokens {
    private final AtomicInteger calls = new AtomicInteger();

    int calls() {
        return calls.get();
    }

    Supplier<String> supplier() {
        return () -> "rotating-token-" + calls.incrementAndGet();
    }
}

final class TestClients {
    static final String MODEL = "claude-sonnet-5-5";

    private TestClients() {}

    static AnthropicClient bearer(RecordingServer server, Supplier<String> tokens) {
        return bearer(server, tokens, "", null, 0, null);
    }

    /** Pass null for {@code maxRetries} or {@code timeout} to keep the factory/SDK defaults. */
    static AnthropicClient bearer(
            RecordingServer server, Supplier<String> tokens, String path, String apiVersion, Integer maxRetries,
            Duration timeout) {
        ClientFactory.Options.Builder options = ClientFactory.Options.builder()
                .baseUrl(server.baseUrl() + path)
                .tokenSupplier(tokens)
                .apiVersion(apiVersion);
        if (maxRetries != null) {
            options.maxRetries(maxRetries);
        }
        if (timeout != null) {
            options.timeout(timeout);
        }
        return ClientFactory.create(options.build());
    }

    static AnthropicClient apiKey(RecordingServer server, String key, String header, Integer maxRetries) {
        ClientFactory.Options.Builder options = ClientFactory.Options.builder()
                .baseUrl(server.baseUrl())
                .apiKey(key)
                .apiKeyHeader(header);
        if (maxRetries != null) {
            options.maxRetries(maxRetries);
        }
        return ClientFactory.create(options.build());
    }

    /** The {@code anthropic-version} an unconfigured standard SDK client sends. */
    static String sdkDefaultApiVersion() throws Exception {
        return sdkDefaultHeader("anthropic-version");
    }

    /** A header an unconfigured standard SDK client sends for {@link #params()}. */
    static String sdkDefaultHeader(String name) throws Exception {
        try (RecordingServer baseline = new RecordingServer()) {
            AnthropicClient plain = AnthropicOkHttpClient.builder().baseUrl(baseline.baseUrl()).apiKey("baseline-key").build();
            plain.messages().create(params());
            plain.close();
            return baseline.single().header(name);
        }
    }

    static MessageCreateParams params() {
        return params(MODEL);
    }

    static MessageCreateParams params(String model) {
        return MessageCreateParams.builder().model(model).maxTokens(1024L).addUserMessage("Hello").build();
    }
}