package sample.anthropic;

import com.anthropic.helpers.BetaMessageThread;
import com.anthropic.models.beta.messages.BetaMessage;
import com.anthropic.models.beta.messages.BetaStopReason;
import com.anthropic.models.beta.messages.BetaTextBlock;
import com.anthropic.models.beta.messages.ThreadCreateParams;
import java.io.PrintStream;
import java.util.function.Function;
import java.util.stream.Collectors;

/** Two-turn Message Threads example using the SDK helper. */
public final class MessageThreads {
    private static final long MAX_TOKENS = 1024;
    private static final String SYSTEM_PROMPT = "Keep replies short.";
    private static final String FIRST_PROMPT = "Remember the code ORCHID-47. Reply with OK.";
    private static final String SECOND_PROMPT = "What code did I ask you to remember? Reply with only the code.";
    private static final String USAGE = "usage: MessageThreads (takes no arguments; settings come from the environment)";

    private MessageThreads() {}

    public static void main(String[] args) {
        System.exit(run(args, System::getenv, System.out, System.err, CredentialSelector::create));
    }

    static int run(
            String[] args,
            Function<String, String> environment,
            PrintStream out,
            PrintStream err,
            SampleRunner.CredentialFactory credentialFactory) {
        if (args.length > 0) {
            boolean help = args[0].equals("-h") || args[0].equals("--help");
            (help ? out : err).println(USAGE);
            return help ? SampleRunner.EXIT_OK : SampleRunner.EXIT_USAGE;
        }

        return SampleRunner.execute(environment, err, credentialFactory, (client, settings) -> {
            BetaMessageThread thread = client.beta().messages().thread(ThreadCreateParams.builder()
                    .model(settings.model())
                    .maxTokens(MAX_TOKENS)
                    .system(SYSTEM_PROMPT)
                    .build());
            thread.send(FIRST_PROMPT);
            out.println(textOf(thread.send(SECOND_PROMPT)));
        });
    }

    private static String textOf(BetaMessage reply) {
        String text = reply.content().stream()
                .flatMap(block -> block.text().stream())
                .map(BetaTextBlock::text)
                .collect(Collectors.joining());
        if (text.isBlank()) {
            throw new SampleRunner.UnusableResponseException("The reply contained no text (stop_reason: "
                    + reply.stopReason().map(BetaStopReason::asString).orElse("none") + ").");
        }
        return text;
    }
}