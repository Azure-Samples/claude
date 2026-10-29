package sample.anthropic;

/** Entrypoint: {@code mvn -q exec:java -Dexec.args="[--stream] [prompt...]"}. */
public final class Main {
    private Main() {}

    public static void main(String[] args) {
        System.exit(SampleRunner.run(args, System::getenv, System.out, System.err, CredentialSelector::create));
    }
}