using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Azure.Core;
using Azure.Identity;

namespace AnthropicStandardSdk;

/// <summary>
/// The only place that knows Azure Identity: it selects exactly one explicit credential class and
/// adapts it to the generic <see cref="TokenProvider"/>. Nothing here falls back to another
/// credential, and the caller owns (and disposes) the credential.
/// </summary>
internal static class CredentialSelector
{
    /// <summary>How long a CLI credential waits for its CLI process to return a token.</summary>
    internal static readonly TimeSpan CliProcessTimeout = TimeSpan.FromSeconds(60);

    internal static AzureCliCredentialOptions CliOptions(string? tenantId) =>
        new AzureCliCredentialOptions { TenantId = tenantId, ProcessTimeout = CliProcessTimeout };

    internal static AzureDeveloperCliCredentialOptions DeveloperCliOptions(string? tenantId) =>
        new AzureDeveloperCliCredentialOptions { TenantId = tenantId, ProcessTimeout = CliProcessTimeout };

    public static TokenCredential Create(SampleSettings settings)
    {
        switch (settings.CredentialName)
        {
            case "AzureCliCredential":
                return new AzureCliCredential(CliOptions(settings.TenantId));
            case "AzureDeveloperCliCredential":
                return new AzureDeveloperCliCredential(DeveloperCliOptions(settings.TenantId));
            case "ManagedIdentityCredential":
                ManagedIdentityId identity = settings.ClientId is null
                    ? ManagedIdentityId.SystemAssigned
                    : ManagedIdentityId.FromUserAssignedClientId(settings.ClientId);
                return new ManagedIdentityCredential(identity);
            default:
                throw new ConfigurationException(
                    "AZURE_TOKEN_CREDENTIALS must be one of: " + string.Join(", ", SampleSettings.CredentialNames) + ".");
        }
    }

    /// <summary>
    /// Asks the credential for a token on every call. Caching and renewal stay with the credential;
    /// some CLI credentials start a subprocess per call.
    /// </summary>
    public static TokenProvider CreateTokenProvider(TokenCredential credential, string scope, SecretRedactor redactor)
    {
        TokenRequestContext context = new TokenRequestContext(new string[] { scope });
        return async (CancellationToken cancellationToken) =>
        {
            AccessToken token = await credential.GetTokenAsync(context, cancellationToken).ConfigureAwait(false);
            redactor.Add(token.Token);
            return token.Token;
        };
    }
}

/// <summary>Removes known secrets and bearer values from text before it is printed.</summary>
internal sealed class SecretRedactor
{
    private static readonly Regex BearerValue =
        new Regex(@"Bearer\s+[A-Za-z0-9._~+/=-]+", RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private readonly List<string> _secrets = new List<string>();
    private readonly object _gate = new object();

    public void Add(string? secret)
    {
        if (string.IsNullOrEmpty(secret))
        {
            return;
        }

        lock (_gate)
        {
            if (!_secrets.Contains(secret))
            {
                _secrets.Add(secret);
            }
        }
    }

    public string Redact(string text)
    {
        string result = BearerValue.Replace(text, "Bearer [redacted]");
        lock (_gate)
        {
            foreach (string secret in _secrets)
            {
                result = result.Replace(secret, "[redacted]", StringComparison.Ordinal);
            }
        }

        return result;
    }
}