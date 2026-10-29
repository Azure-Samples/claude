package sample.anthropic;

import java.util.List;
import java.util.Locale;
import java.util.function.Function;

/**
 * Environment-driven settings of this sample entrypoint. The reusable {@link ClientFactory} never reads them.
 *
 * <p>The endpoint variable selects one {@link Profile}, and the profile decides which model and key variables are
 * read. URL, model and key are never coalesced across the two families, so an endpoint, deployment name or key left
 * in the environment for another tool cannot be paired with the wrong partner or silently receive an identity token.
 *
 * @param apiVersion null keeps the SDK default {@code anthropic-version}
 */
record SampleSettings(
        Profile profile,
        String baseUrl,
        String model,
        AuthMode authMode,
        String apiKey,
        String apiKeyHeader,
        String apiVersion,
        String tokenScope,
        String credentialName,
        String tenantId,
        String clientId) {

    enum AuthMode {
        BEARER,
        API_KEY
    }

    /** Selected by {@code ANTHROPIC_BASE_URL} (canonical) or by {@code CLAUDE_BASE_URL} alone (legacy). */
    enum Profile {
        CANONICAL,
        LEGACY
    }

    /** Raised for missing or invalid configuration; the sample exits with status 2. */
    static final class ConfigurationException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        ConfigurationException(String message) {
            super(message);
        }
    }

    static final String DEFAULT_TOKEN_SCOPE = "https://ai.azure.com/.default";
    static final String DEFAULT_CREDENTIAL = "AzureCliCredential";
    static final List<String> CREDENTIAL_NAMES =
            List.of("AzureCliCredential", "AzureDeveloperCliCredential", "ManagedIdentityCredential");

    static SampleSettings fromEnvironment(Function<String, String> environment) {
        Profile profile;
        String urlVariable;
        String modelVariable;
        String keyVariable;
        String otherModelVariable;
        String otherKeyVariable;
        String baseUrl = value(environment, "ANTHROPIC_BASE_URL");
        if (baseUrl != null) {
            profile = Profile.CANONICAL;
            urlVariable = "ANTHROPIC_BASE_URL";
            modelVariable = "ANTHROPIC_MODEL";
            keyVariable = "ANTHROPIC_API_KEY";
            otherModelVariable = "CLAUDE_DEPLOYMENT_NAME";
            otherKeyVariable = "CLAUDE_API_KEY";
        } else {
            baseUrl = value(environment, "CLAUDE_BASE_URL");
            if (baseUrl == null) {
                throw new ConfigurationException("Set ANTHROPIC_BASE_URL (or CLAUDE_BASE_URL for the legacy profile).");
            }
            profile = Profile.LEGACY;
            urlVariable = "CLAUDE_BASE_URL";
            modelVariable = "CLAUDE_DEPLOYMENT_NAME";
            keyVariable = "CLAUDE_API_KEY";
            otherModelVariable = "ANTHROPIC_MODEL";
            otherKeyVariable = "ANTHROPIC_API_KEY";
        }

        String model = value(environment, modelVariable);
        if (model == null) {
            throw new ConfigurationException(urlVariable + " selects the " + profile.name().toLowerCase(Locale.ROOT)
                    + " profile, so " + modelVariable + " is required; " + otherModelVariable + " is not used with it.");
        }

        String modeText = value(environment, "AUTH_MODE");
        AuthMode mode;
        if (modeText == null) {
            if (profile == Profile.CANONICAL) {
                throw new ConfigurationException(
                        "ANTHROPIC_BASE_URL selects the canonical profile, so AUTH_MODE must be set to 'bearer' or 'api_key'; "
                                + "this stops an endpoint left in the environment from silently receiving an identity token.");
            }
            mode = AuthMode.BEARER;
        } else if (modeText.equalsIgnoreCase("bearer")) {
            mode = AuthMode.BEARER;
        } else if (modeText.equalsIgnoreCase("api_key")) {
            mode = AuthMode.API_KEY;
        } else {
            throw new ConfigurationException("AUTH_MODE must be 'bearer' or 'api_key'.");
        }

        String apiKey = null;
        String credentialName = value(environment, "AZURE_TOKEN_CREDENTIALS");
        if (credentialName == null) {
            credentialName = DEFAULT_CREDENTIAL;
        }
        if (mode == AuthMode.API_KEY) {
            apiKey = value(environment, keyVariable);
            if (apiKey == null) {
                throw new ConfigurationException("AUTH_MODE=api_key with " + urlVariable + " needs " + keyVariable + "; "
                        + otherKeyVariable + " is not used with it.");
            }
        } else if (!CREDENTIAL_NAMES.contains(credentialName)) {
            throw new ConfigurationException(
                    "AZURE_TOKEN_CREDENTIALS must be one of: " + String.join(", ", CREDENTIAL_NAMES) + ".");
        }

        String apiKeyHeader = value(environment, "API_KEY_HEADER");
        String tokenScope = value(environment, "TOKEN_SCOPE");
        return new SampleSettings(
                profile,
                baseUrl,
                model,
                mode,
                apiKey,
                apiKeyHeader != null ? apiKeyHeader : ClientFactory.DEFAULT_API_KEY_HEADER,
                value(environment, "ANTHROPIC_API_VERSION"),
                tokenScope != null ? tokenScope : DEFAULT_TOKEN_SCOPE,
                credentialName,
                value(environment, "AZURE_TENANT_ID"),
                value(environment, "AZURE_CLIENT_ID"));
    }

    private static String value(Function<String, String> environment, String name) {
        String value = environment.apply(name);
        return value != null && !value.trim().isEmpty() ? value.trim() : null;
    }
}