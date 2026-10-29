package sample.anthropic;

import com.azure.core.credential.AccessToken;
import com.azure.core.credential.TokenCredential;
import com.azure.core.credential.TokenRequestContext;
import com.azure.identity.AzureCliCredentialBuilder;
import com.azure.identity.AzureDeveloperCliCredentialBuilder;
import com.azure.identity.ManagedIdentityCredentialBuilder;
import java.time.Duration;
import java.util.function.Supplier;

/**
 * The only place that knows Azure Identity: it selects exactly one explicit credential class and adapts it to
 * the generic token supplier. Nothing here falls back to another credential, and the caller owns (and closes)
 * the credential.
 */
final class CredentialSelector {
    /** How long a CLI credential waits for its CLI process to return a token. */
    static final Duration CLI_PROCESS_TIMEOUT = Duration.ofSeconds(60);

    private CredentialSelector() {}

    static TokenCredential create(SampleSettings settings) {
        switch (settings.credentialName()) {
            case "AzureCliCredential": {
                AzureCliCredentialBuilder builder = new AzureCliCredentialBuilder().processTimeout(CLI_PROCESS_TIMEOUT);
                if (settings.tenantId() != null) {
                    builder.tenantId(settings.tenantId());
                }
                return builder.build();
            }
            case "AzureDeveloperCliCredential": {
                AzureDeveloperCliCredentialBuilder builder =
                        new AzureDeveloperCliCredentialBuilder().processTimeout(CLI_PROCESS_TIMEOUT);
                if (settings.tenantId() != null) {
                    builder.tenantId(settings.tenantId());
                }
                return builder.build();
            }
            case "ManagedIdentityCredential": {
                ManagedIdentityCredentialBuilder builder = new ManagedIdentityCredentialBuilder();
                if (settings.clientId() != null) {
                    builder.clientId(settings.clientId());
                }
                return builder.build();
            }
            default:
                throw new SampleSettings.ConfigurationException("AZURE_TOKEN_CREDENTIALS must be one of: "
                        + String.join(", ", SampleSettings.CREDENTIAL_NAMES) + ".");
        }
    }

    /**
     * Asks the credential for a token on every call. Caching and renewal stay with the credential; some CLI
     * credentials start a subprocess per call.
     */
    static Supplier<String> tokenSupplier(TokenCredential credential, String scope, SecretRedactor redactor) {
        TokenRequestContext context = new TokenRequestContext().addScopes(scope);
        return () -> {
            AccessToken token = credential.getTokenSync(context);
            redactor.add(token.getToken());
            return token.getToken();
        };
    }
}