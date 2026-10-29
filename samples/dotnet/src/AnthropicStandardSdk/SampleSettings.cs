using System;

namespace AnthropicStandardSdk;

internal enum AuthMode
{
    Bearer,
    ApiKey,
}

/// <summary>
/// Which family of environment variables a run uses. Families are never mixed: the URL decides, and the
/// model and key then come only from that family.
/// </summary>
internal enum ConfigProfile
{
    /// <summary>Selected by <c>ANTHROPIC_BASE_URL</c>; uses <c>ANTHROPIC_MODEL</c> and <c>ANTHROPIC_API_KEY</c>.</summary>
    Canonical,

    /// <summary>Selected by <c>CLAUDE_BASE_URL</c> alone; uses <c>CLAUDE_DEPLOYMENT_NAME</c> and <c>CLAUDE_API_KEY</c>.</summary>
    Legacy,
}

/// <summary>Raised for missing or invalid configuration; the sample exits with status 2.</summary>
internal sealed class ConfigurationException : Exception
{
    public ConfigurationException(string message)
        : base(message)
    {
    }
}

/// <summary>
/// Environment-driven settings of this sample entrypoint. The reusable <see cref="ClientFactory"/>
/// never reads them.
/// </summary>
internal sealed class SampleSettings
{
    public const string DefaultTokenScope = "https://ai.azure.com/.default";
    public const string DefaultApiKeyHeader = ClientFactory.DefaultApiKeyHeader;
    public const string DefaultCredential = "AzureCliCredential";

    public static readonly string[] CredentialNames =
        ["AzureCliCredential", "AzureDeveloperCliCredential", "ManagedIdentityCredential"];

    public required ConfigProfile Profile { get; init; }

    public required string BaseUrl { get; init; }

    public required string Model { get; init; }

    public required AuthMode AuthMode { get; init; }

    public string? ApiKey { get; init; }

    public required string ApiKeyHeader { get; init; }

    /// <summary>Null keeps the SDK default <c>anthropic-version</c>.</summary>
    public string? ApiVersion { get; init; }

    public required string TokenScope { get; init; }

    public required string CredentialName { get; init; }

    public string? TenantId { get; init; }

    public string? ClientId { get; init; }

    public static SampleSettings FromEnvironment(Func<string, string?> getEnvironmentVariable)
    {
        // The endpoint selects the whole profile. URL, model and key are never coalesced across the two
        // families, so a native endpoint left in the environment cannot be paired with another family's
        // deployment name or key, and the other family's values are ignored rather than used as fallbacks.
        ConfigProfile profile;
        string urlVariable;
        string modelVariable;
        string keyVariable;
        string otherModelVariable;
        string otherKeyVariable;
        string? baseUrl = First(getEnvironmentVariable, "ANTHROPIC_BASE_URL");
        if (baseUrl is not null)
        {
            profile = ConfigProfile.Canonical;
            urlVariable = "ANTHROPIC_BASE_URL";
            modelVariable = "ANTHROPIC_MODEL";
            keyVariable = "ANTHROPIC_API_KEY";
            otherModelVariable = "CLAUDE_DEPLOYMENT_NAME";
            otherKeyVariable = "CLAUDE_API_KEY";
        }
        else
        {
            baseUrl = First(getEnvironmentVariable, "CLAUDE_BASE_URL");
            if (baseUrl is null)
            {
                throw new ConfigurationException(
                    "Set ANTHROPIC_BASE_URL (or CLAUDE_BASE_URL for the legacy profile).");
            }

            profile = ConfigProfile.Legacy;
            urlVariable = "CLAUDE_BASE_URL";
            modelVariable = "CLAUDE_DEPLOYMENT_NAME";
            keyVariable = "CLAUDE_API_KEY";
            otherModelVariable = "ANTHROPIC_MODEL";
            otherKeyVariable = "ANTHROPIC_API_KEY";
        }

        string model = First(getEnvironmentVariable, modelVariable)
            ?? throw new ConfigurationException(
                $"{urlVariable} selects the {profile.ToString().ToLowerInvariant()} profile, so {modelVariable} is required; "
                + $"{otherModelVariable} is not used with it.");

        string? modeText = First(getEnvironmentVariable, "AUTH_MODE");
        AuthMode mode;
        if (modeText is null)
        {
            if (profile == ConfigProfile.Canonical)
            {
                throw new ConfigurationException(
                    "ANTHROPIC_BASE_URL selects the canonical profile, so AUTH_MODE must be set to 'bearer' or 'api_key'; "
                    + "this stops an endpoint left in the environment from silently receiving an identity token.");
            }

            mode = AuthMode.Bearer;
        }
        else if (string.Equals(modeText, "bearer", StringComparison.OrdinalIgnoreCase))
        {
            mode = AuthMode.Bearer;
        }
        else if (string.Equals(modeText, "api_key", StringComparison.OrdinalIgnoreCase))
        {
            mode = AuthMode.ApiKey;
        }
        else
        {
            throw new ConfigurationException("AUTH_MODE must be 'bearer' or 'api_key'.");
        }

        string? apiKey = null;
        string credentialName = First(getEnvironmentVariable, "AZURE_TOKEN_CREDENTIALS") ?? DefaultCredential;
        if (mode == AuthMode.ApiKey)
        {
            apiKey = First(getEnvironmentVariable, keyVariable)
                ?? throw new ConfigurationException(
                    $"AUTH_MODE=api_key with {urlVariable} needs {keyVariable}; {otherKeyVariable} is not used with it.");
        }
        else if (Array.IndexOf(CredentialNames, credentialName) < 0)
        {
            throw new ConfigurationException(
                "AZURE_TOKEN_CREDENTIALS must be one of: " + string.Join(", ", CredentialNames) + ".");
        }

        return new SampleSettings
        {
            Profile = profile,
            BaseUrl = baseUrl,
            Model = model,
            AuthMode = mode,
            ApiKey = apiKey,
            ApiKeyHeader = First(getEnvironmentVariable, "API_KEY_HEADER") ?? DefaultApiKeyHeader,
            ApiVersion = First(getEnvironmentVariable, "ANTHROPIC_API_VERSION"),
            TokenScope = First(getEnvironmentVariable, "TOKEN_SCOPE") ?? DefaultTokenScope,
            CredentialName = credentialName,
            TenantId = First(getEnvironmentVariable, "AZURE_TENANT_ID"),
            ClientId = First(getEnvironmentVariable, "AZURE_CLIENT_ID"),
        };
    }

    private static string? First(Func<string, string?> getEnvironmentVariable, string name)
    {
        string? value = getEnvironmentVariable(name)?.Trim();
        return string.IsNullOrEmpty(value) ? null : value;
    }
}