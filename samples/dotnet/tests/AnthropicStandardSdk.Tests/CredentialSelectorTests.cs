using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using Azure.Core;
using Azure.Identity;
using Xunit;

namespace AnthropicStandardSdk.Tests;

/// <summary>
/// Credential wiring through the real Azure Identity classes. Fake CLIs and a loopback identity
/// endpoint stand in for the cloud, so no account, login or network is involved.
/// </summary>
[Collection("ProcessEnvironment")]
public sealed class CredentialSelectorTests : IDisposable
{
    private const string TenantId = "00000000-0000-0000-0000-00000000aaaa";
    private const string ClientId = "00000000-0000-0000-0000-00000000bbbb";

    private readonly string _directory =
        Path.Combine(Path.GetTempPath(), "anthropic-sample-tests-" + Guid.NewGuid().ToString("N"));

    private readonly Dictionary<string, string?> _originalEnvironment = new Dictionary<string, string?>();

    private static SampleSettings Settings(string credentialName, string? tenantId = null, string? clientId = null) =>
        new SampleSettings
        {
            Profile = ConfigProfile.Canonical,
            BaseUrl = TestClients.FoundryUrl,
            Model = TestClients.Model,
            AuthMode = AuthMode.Bearer,
            ApiKeyHeader = ClientFactory.DefaultApiKeyHeader,
            TokenScope = SampleSettings.DefaultTokenScope,
            CredentialName = credentialName,
            TenantId = tenantId,
            ClientId = clientId,
        };

    public void Dispose()
    {
        foreach (KeyValuePair<string, string?> original in _originalEnvironment)
        {
            Environment.SetEnvironmentVariable(original.Key, original.Value);
        }

        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, recursive: true);
        }
    }

    [Theory]
    [InlineData("AzureCliCredential", typeof(AzureCliCredential))]
    [InlineData("AzureDeveloperCliCredential", typeof(AzureDeveloperCliCredential))]
    [InlineData("ManagedIdentityCredential", typeof(ManagedIdentityCredential))]
    public void Create_SelectsExactlyTheNamedCredentialClass(string name, Type expected)
    {
        Assert.IsType(expected, CredentialSelector.Create(Settings(name)));
    }

    [Theory]
    [InlineData("DefaultAzureCredential")]
    [InlineData("EnvironmentCredential")]
    [InlineData("")]
    public void Create_RejectsAnyOtherCredentialName(string name)
    {
        Assert.Throws<ConfigurationException>(() => CredentialSelector.Create(Settings(name)));
    }

    [Fact]
    public void CliCredentialOptions_AllowSixtySecondsForTheProcess()
    {
        TimeSpan expected = TimeSpan.FromSeconds(60);

        AzureCliCredentialOptions cli = CredentialSelector.CliOptions(TenantId);
        AzureDeveloperCliCredentialOptions developerCli = CredentialSelector.DeveloperCliOptions(TenantId);

        Assert.Equal(expected, CredentialSelector.CliProcessTimeout);
        Assert.Equal(expected, cli.ProcessTimeout);
        Assert.Equal(expected, developerCli.ProcessTimeout);
        Assert.Equal(TenantId, cli.TenantId);
        Assert.Equal(TenantId, developerCli.TenantId);
    }

    [Theory]
    [InlineData("AzureCliCredential")]
    [InlineData("AzureDeveloperCliCredential")]
    public void CliCredentials_AreConstructedWithASixtySecondProcessTimeout(string name)
    {
        TokenCredential credential = CredentialSelector.Create(Settings(name, TenantId));

        // The credential keeps the timeout it was constructed with in a non-public property.
        PropertyInfo? property = credential.GetType().GetProperty(
            "ProcessTimeout", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
        Assert.True(property is not null, "Azure.Identity no longer exposes ProcessTimeout on " + credential.GetType().Name);
        Assert.Equal(TimeSpan.FromSeconds(60), (TimeSpan)property!.GetValue(credential)!);
    }

    [Fact]
    public async Task AzureCliCredential_ReceivesTheScopeAndTenantFromConfiguration()
    {
        string argumentsFile = InstallFakeCli(
            "az",
            """{"accessToken":"fake-cli-token","expiresOn":"2099-01-01 00:00:00.000000","expires_on":4070908800,"tokenType":"Bearer"}""");
        TokenProvider provider = CredentialSelector.CreateTokenProvider(
            CredentialSelector.Create(Settings("AzureCliCredential", TenantId)),
            SampleSettings.DefaultTokenScope,
            new SecretRedactor());

        string token = await provider(CancellationToken.None);

        Assert.Equal("fake-cli-token", token);
        string arguments = File.ReadAllText(argumentsFile);
        Assert.Contains("get-access-token", arguments, StringComparison.Ordinal);
        Assert.Contains("https://ai.azure.com", arguments, StringComparison.Ordinal);
        Assert.Contains("--tenant " + TenantId, arguments, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AzureDeveloperCliCredential_ReceivesTheScopeAndTenantFromConfiguration()
    {
        string argumentsFile = InstallFakeCli("azd", """{"token":"fake-azd-token","expiresOn":"2099-01-01T00:00:00Z"}""");
        TokenProvider provider = CredentialSelector.CreateTokenProvider(
            CredentialSelector.Create(Settings("AzureDeveloperCliCredential", TenantId)),
            SampleSettings.DefaultTokenScope,
            new SecretRedactor());

        string token = await provider(CancellationToken.None);

        Assert.Equal("fake-azd-token", token);
        string arguments = File.ReadAllText(argumentsFile);
        Assert.Contains("--scope " + SampleSettings.DefaultTokenScope, arguments, StringComparison.Ordinal);
        Assert.Contains("--tenant-id " + TenantId, arguments, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task ManagedIdentityCredential_UsesTheUserAssignedClientIdWhenConfigured(bool userAssigned)
    {
        using LoopbackServer identityEndpoint = new LoopbackServer(
            (string _) => LoopbackServer.Json("""{"access_token":"fake-mi-token","expires_on":"4070908800","resource":"https://ai.azure.com","token_type":"Bearer"}"""));
        SetEnvironment("IDENTITY_ENDPOINT", identityEndpoint.BaseUrl + "/msi/token");
        SetEnvironment("IDENTITY_HEADER", "synthetic-identity-header");
        TokenProvider provider = CredentialSelector.CreateTokenProvider(
            CredentialSelector.Create(Settings("ManagedIdentityCredential", clientId: userAssigned ? ClientId : null)),
            SampleSettings.DefaultTokenScope,
            new SecretRedactor());

        string token = await provider(CancellationToken.None);

        Assert.Equal("fake-mi-token", token);
        string head = Assert.Single(identityEndpoint.RequestHeads);
        Assert.StartsWith("GET /msi/token?api-version=2019-08-01", head, StringComparison.Ordinal);
        Assert.Contains("ai.azure.com", head, StringComparison.Ordinal);
        Assert.Contains("x-identity-header: synthetic-identity-header", head, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(userAssigned, head.Contains("client_id=" + ClientId, StringComparison.Ordinal));
    }

    private void SetEnvironment(string name, string? value)
    {
        if (!_originalEnvironment.ContainsKey(name))
        {
            _originalEnvironment[name] = Environment.GetEnvironmentVariable(name);
        }

        Environment.SetEnvironmentVariable(name, value);
    }

    /// <summary>Puts a fake CLI first on PATH; it records its arguments and prints the given JSON.</summary>
    private string InstallFakeCli(string name, string outputJson)
    {
        Directory.CreateDirectory(_directory);
        string variable = "FAKE_" + name.ToUpperInvariant() + "_ARGUMENTS";
        string argumentsFile = Path.Combine(_directory, name + ".arguments");
        SetEnvironment(variable, argumentsFile);

        if (OperatingSystem.IsWindows())
        {
            File.WriteAllText(
                Path.Combine(_directory, name + ".cmd"),
                $"@echo off\r\necho %* >> \"%{variable}%\"\r\necho {outputJson}\r\n");
        }
        else
        {
            string path = Path.Combine(_directory, name);
            File.WriteAllText(path, $"#!/bin/sh\necho \"$@\" >> \"${variable}\"\necho '{outputJson}'\n");
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }

        SetEnvironment("PATH", _directory + Path.PathSeparator + Environment.GetEnvironmentVariable("PATH"));
        return argumentsFile;
    }
}