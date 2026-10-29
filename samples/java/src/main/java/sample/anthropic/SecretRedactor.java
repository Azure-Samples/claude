package sample.anthropic;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Pattern;

/** Removes known secrets and bearer values from text before it is printed. */
final class SecretRedactor {
    private static final Pattern BEARER_VALUE = Pattern.compile("Bearer\\s+[A-Za-z0-9._~+/=-]+", Pattern.CASE_INSENSITIVE);

    private final List<String> secrets = new ArrayList<>();

    synchronized void add(String secret) {
        if (secret != null && !secret.isEmpty() && !secrets.contains(secret)) {
            secrets.add(secret);
        }
    }

    synchronized String redact(String text) {
        String result = BEARER_VALUE.matcher(text).replaceAll("Bearer [redacted]");
        for (String secret : secrets) {
            result = result.replace(secret, "[redacted]");
        }
        return result;
    }
}