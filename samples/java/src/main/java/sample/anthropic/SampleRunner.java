package sample.anthropic;

import com.anthropic.client.AnthropicClient;
import com.anthropic.core.http.StreamResponse;
import com.anthropic.errors.AnthropicServiceException;
import com.anthropic.models.messages.ContentBlock;
import com.anthropic.models.messages.Message;
import com.anthropic.models.messages.MessageCreateParams;
import com.anthropic.models.messages.RawContentBlockDelta;
import com.anthropic.models.messages.RawMessageStreamEvent;
import com.azure.core.credential.TokenCredential;
import java.io.PrintStream;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Function;
import java.util.function.Supplier;
import java.util.regex.Pattern;

/** One Messages call, or one streaming call with {@code --stream}, plus output and exit codes. */
public final class SampleRunner {
    public static final int EXIT_OK = 0;
    public static final int EXIT_FAILURE = 1;
    public static final int EXIT_USAGE = 2;

    private static final long MAX_TOKENS = 1024;

    /** Application policy of this sample, set explicitly on the client; ClientFactory has no timeout default of its own. */
    static final Duration REQUEST_TIMEOUT = Duration.ofSeconds(120);

    private static final String DEFAULT_PROMPT = "Say hello in one short sentence.";
    private static final String USAGE = "usage: Main [--stream] [prompt...]";
    private static final Pattern WHITESPACE = Pattern.compile("\\s+");

    private SampleRunner() {}

    /** Creates the one credential the sample uses; tests substitute a fake. */
    @FunctionalInterface
    interface CredentialFactory {
        TokenCredential create(SampleSettings settings);
    }

    /** Raised when a successful HTTP response cannot count as a result (for example, no text). */
    static final class UnusableResponseException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        UnusableResponseException(String message) {
            super(message);
        }
    }

    static int run(
            String[] args,
            Function<String, String> environment,
            PrintStream out,
            PrintStream err,
            CredentialFactory credentialFactory) {
        boolean stream = false;
        boolean optionsEnded = false;
        List<String> promptWords = new ArrayList<>();
        for (String arg : args) {
            if (!optionsEnded && arg.equals("--")) {
                optionsEnded = true;
            } else if (!optionsEnded && arg.equals("--stream")) {
                stream = true;
            } else if (!optionsEnded && (arg.equals("-h") || arg.equals("--help"))) {
                out.println(USAGE);
                return EXIT_OK;
            } else if (!optionsEnded && arg.startsWith("--")) {
                err.println("error: unknown option " + arg);
                err.println(USAGE);
                return EXIT_USAGE;
            } else {
                promptWords.add(arg);
            }
        }
        String prompt = promptWords.isEmpty() ? DEFAULT_PROMPT : String.join(" ", promptWords);

        SampleSettings settings;
        try {
            settings = SampleSettings.fromEnvironment(environment);
        } catch (SampleSettings.ConfigurationException e) {
            err.println("error: " + e.getMessage());
            return EXIT_USAGE;
        }

        SecretRedactor redactor = new SecretRedactor();
        redactor.add(settings.apiKey());
        TokenCredential credential = null;
        try {
            ClientFactory.Options.Builder options = ClientFactory.Options.builder()
                    .baseUrl(settings.baseUrl())
                    .apiVersion(settings.apiVersion())
                    .timeout(REQUEST_TIMEOUT);
            if (settings.authMode() == SampleSettings.AuthMode.BEARER) {
                credential = credentialFactory.create(settings);
                Supplier<String> tokens = CredentialSelector.tokenSupplier(credential, settings.tokenScope(), redactor);
                options.tokenSupplier(tokens);
            } else {
                options.apiKey(settings.apiKey()).apiKeyHeader(settings.apiKeyHeader());
            }

            AnthropicClient client;
            try {
                client = ClientFactory.create(options.build());
            } catch (IllegalArgumentException e) {
                err.println("error: " + redactor.redact(String.valueOf(e.getMessage())));
                return EXIT_USAGE;
            }

            // The SDK client is deliberately not AutoCloseable, so release it explicitly.
            try {
                MessageCreateParams params = MessageCreateParams.builder()
                        .model(settings.model())
                        .maxTokens(MAX_TOKENS)
                        .addUserMessage(prompt)
                        .build();
                if (stream) {
                    writeStream(client, params, out);
                } else {
                    writeMessage(client, params, out);
                }
            } finally {
                client.close();
            }
            return EXIT_OK;
        } catch (Exception e) {
            if (e instanceof InterruptedException) {
                Thread.currentThread().interrupt();
            }
            err.println("error: " + describe(e, redactor));
            return EXIT_FAILURE;
        } finally {
            // The factory does not own the credential, so the caller that created it releases it.
            closeQuietly(credential);
        }
    }

    private static void writeMessage(AnthropicClient client, MessageCreateParams params, PrintStream out) {
        Message message = client.messages().create(params);

        StringBuilder text = new StringBuilder();
        List<String> blockKinds = new ArrayList<>();
        for (ContentBlock block : message.content()) {
            blockKinds.add(kindOf(block));
            block.text().ifPresent(textBlock -> text.append(textBlock.text()));
        }

        if (text.toString().trim().isEmpty()) {
            throw new UnusableResponseException(
                    "The response contained no text (content blocks: " + String.join(", ", blockKinds) + ").");
        }

        out.println(text);
        out.println(formatUsage(message.usage().inputTokens(), message.usage().outputTokens()));
    }

    private static void writeStream(AnthropicClient client, MessageCreateParams params, PrintStream out) {
        long inputTokens = 0;
        long outputTokens = 0;
        boolean sawText = false;
        boolean sawStop = false;

        try (StreamResponse<RawMessageStreamEvent> stream = client.messages().createStreaming(params)) {
            for (RawMessageStreamEvent event : stream) {
                if (event.isMessageStart()) {
                    inputTokens = event.asMessageStart().message().usage().inputTokens();
                    outputTokens = event.asMessageStart().message().usage().outputTokens();
                } else if (event.isContentBlockDelta()) {
                    RawContentBlockDelta delta = event.asContentBlockDelta().delta();
                    if (delta.isText() && !delta.asText().text().isEmpty()) {
                        String piece = delta.asText().text();
                        out.print(piece);
                        out.flush();
                        sawText |= !piece.trim().isEmpty();
                    }
                } else if (event.isMessageDelta()) {
                    outputTokens = event.asMessageDelta().usage().outputTokens();
                } else if (event.isMessageStop()) {
                    sawStop = true;
                }
            }
        }

        if (!sawText) {
            throw new UnusableResponseException("The stream contained no text.");
        }
        if (!sawStop) {
            throw new UnusableResponseException("The stream ended before message_stop.");
        }

        out.println();
        out.println(formatUsage(inputTokens, outputTokens));
    }

    private static String kindOf(ContentBlock block) {
        if (block.isText()) {
            return "text";
        } else if (block.isThinking()) {
            return "thinking";
        } else if (block.isRedactedThinking()) {
            return "redacted_thinking";
        } else if (block.isToolUse()) {
            return "tool_use";
        }
        return "other";
    }

    private static String formatUsage(long inputTokens, long outputTokens) {
        return "usage: input_tokens=" + inputTokens + " output_tokens=" + outputTokens;
    }

    /** Typed root cause and HTTP status, never credentials. */
    static String describe(Throwable failure, SecretRedactor redactor) {
        StringBuilder text = new StringBuilder();
        Throwable current = failure;
        for (int depth = 0; current != null && depth < 4; depth++) {
            if (depth > 0) {
                text.append(" <- ");
            }
            text.append(current.getClass().getSimpleName());
            if (current instanceof AnthropicServiceException) {
                text.append(" (HTTP ").append(((AnthropicServiceException) current).statusCode()).append(')');
            }

            String message = WHITESPACE.matcher(String.valueOf(current.getMessage())).replaceAll(" ").trim();
            if (message.length() > 300) {
                message = message.substring(0, 300) + "...";
            }
            if (!message.isEmpty() && !message.equals("null")) {
                text.append(": ").append(message);
            }

            current = current.getCause() == current ? null : current.getCause();
        }
        return redactor.redact(text.toString());
    }

    private static void closeQuietly(Object resource) {
        if (resource instanceof AutoCloseable) {
            try {
                ((AutoCloseable) resource).close();
            } catch (Exception ignored) {
                // Nothing useful to report: the call has already succeeded or failed.
            }
        }
    }
}