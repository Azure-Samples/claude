package sample.anthropic;

import static org.junit.jupiter.api.Assertions.assertFalse;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import org.junit.jupiter.api.Test;

/** The generic helper stays generic: no identity library, no environment, no SDK credential slots. */
class HelperBoundaryTest {

    @Test
    void clientFactoryKnowsNoIdentityLibraryAndReadsNoConfiguration() throws IOException {
        String source = Files.readString(Path.of("src/main/java/sample/anthropic/ClientFactory.java"))
                .replaceAll("(?s)/\\*.*?\\*/", "")
                .replaceAll("//[^\\n]*", "");

        List<String> forbidden = List.of(
                "com.azure", "Azure", "Foundry", "System.getenv", "System.getProperty", "fromEnv", ".apiKey(", ".authToken(",
                "configurationProvider", "backend(");
        for (String fragment : forbidden) {
            assertFalse(source.contains(fragment), "ClientFactory must not use: " + fragment);
        }
    }
}