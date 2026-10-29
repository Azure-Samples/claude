package sample.anthropic;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.azure.core.credential.TokenCredential;
import java.io.IOException;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.function.Supplier;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;

/**
 * Credential wiring through the real Azure Identity classes. Fake CLIs (found through the PATH that surefire
 * sets) stand in for the cloud, so no account, login or network is involved.
 */
class CredentialSelectorTest {
    private static final String TENANT_ID = "00000000-0000-0000-0000-00000000aaaa";
    private static final Path FAKE_CLI_DIRECTORY = Path.of("target", "fake-cli").toAbsolutePath();

    private static SampleSettings settings(String credentialName, String tenantId, String clientId) {
        return new SampleSettings(
                SampleSettings.Profile.CANONICAL,
                "https://example.com",
                TestClients.MODEL,
                SampleSettings.AuthMode.BEARER,
                null,
                ClientFactory.DEFAULT_API_KEY_HEADER,
                null,
                SampleSettings.DEFAULT_TOKEN_SCOPE,
                credentialName,
                tenantId,
                clientId);
    }

    @ParameterizedTest
    @CsvSource({
        "AzureCliCredential,com.azure.identity.AzureCliCredential",
        "AzureDeveloperCliCredential,com.azure.identity.AzureDeveloperCliCredential",
        "ManagedIdentityCredential,com.azure.identity.ManagedIdentityCredential"
    })
    void createSelectsExactlyTheNamedCredentialClass(String name, Class<?> expected) {
        TokenCredential credential = CredentialSelector.create(settings(name, null, null));

        assertEquals(expected, credential.getClass());
    }

    @ParameterizedTest
    @ValueSource(strings = {"DefaultAzureCredential", "EnvironmentCredential", ""})
    void createRejectsAnyOtherCredentialName(String name) {
        assertThrows(SampleSettings.ConfigurationException.class,
                () -> CredentialSelector.create(settings(name, null, null)));
    }

    @ParameterizedTest
    @ValueSource(strings = {"AzureCliCredential", "AzureDeveloperCliCredential"})
    void cliCredentialsAreConstructedWithASixtySecondProcessTimeout(String name) throws ReflectiveOperationException {
        TokenCredential credential = CredentialSelector.create(settings(name, TENANT_ID, null));

        // The credential keeps the timeout it was built with in the options of its identity client.
        Field field = credential.getClass().getDeclaredField("identityClient");
        field.setAccessible(true);
        Object client = field.get(credential);
        Method getOptions = client.getClass().getMethod("getIdentityClientOptions");
        getOptions.setAccessible(true);
        Object options = getOptions.invoke(client);
        Method getTimeout = options.getClass().getMethod("getCredentialProcessTimeout");
        getTimeout.setAccessible(true);

        assertEquals(Duration.ofSeconds(60), getTimeout.invoke(options));
        assertEquals(CredentialSelector.CLI_PROCESS_TIMEOUT, getTimeout.invoke(options));
    }

    @Test
    void azureCliCredentialReceivesTheScopeAndTenantFromConfiguration() throws IOException {
        Path arguments = installFakeCli(
                "az",
                "{\"accessToken\":\"fake-cli-token\",\"expiresOn\":\"2099-01-01 00:00:00.000000\","
                        + "\"expires_on\":4070908800,\"tokenType\":\"Bearer\"}");
        Supplier<String> supplier = CredentialSelector.tokenSupplier(
                CredentialSelector.create(settings("AzureCliCredential", TENANT_ID, null)),
                SampleSettings.DEFAULT_TOKEN_SCOPE,
                new SecretRedactor());

        assertEquals("fake-cli-token", supplier.get());

        String recorded = Files.readString(arguments);
        assertTrue(recorded.contains("get-access-token"), recorded);
        assertTrue(recorded.contains("https://ai.azure.com"), recorded);
        assertTrue(recorded.contains("--tenant " + TENANT_ID), recorded);
    }

    @Test
    void azureDeveloperCliCredentialReceivesTheScopeAndTenantFromConfiguration() throws IOException {
        Path arguments = installFakeCli("azd", "{\"token\":\"fake-azd-token\",\"expiresOn\":\"2099-01-01T00:00:00Z\"}");
        Supplier<String> supplier = CredentialSelector.tokenSupplier(
                CredentialSelector.create(settings("AzureDeveloperCliCredential", TENANT_ID, null)),
                SampleSettings.DEFAULT_TOKEN_SCOPE,
                new SecretRedactor());

        assertEquals("fake-azd-token", supplier.get());

        String recorded = Files.readString(arguments);
        assertTrue(recorded.contains("--scope " + SampleSettings.DEFAULT_TOKEN_SCOPE), recorded);
        assertTrue(recorded.contains("--tenant-id " + TENANT_ID), recorded);
    }

    /** Writes a fake CLI into the directory surefire put first on PATH; it records its arguments. */
    private static Path installFakeCli(String name, String outputJson) throws IOException {
        Files.createDirectories(FAKE_CLI_DIRECTORY);
        Path arguments = FAKE_CLI_DIRECTORY.resolve(name + ".arguments");
        Files.deleteIfExists(arguments);

        if (System.getProperty("os.name").toLowerCase().contains("win")) {
            Files.writeString(
                    FAKE_CLI_DIRECTORY.resolve(name + ".cmd"),
                    "@echo off\r\necho %* >> \"" + arguments + "\"\r\necho " + outputJson + "\r\n",
                    StandardCharsets.UTF_8);
        } else {
            Path script = FAKE_CLI_DIRECTORY.resolve(name);
            Files.writeString(
                    script,
                    "#!/bin/sh\necho \"$@\" >> '" + arguments + "'\necho '" + outputJson + "'\n",
                    StandardCharsets.UTF_8);
            if (!script.toFile().setExecutable(true)) {
                throw new IOException("Could not make the fake CLI executable: " + script);
            }
        }
        return arguments;
    }
}