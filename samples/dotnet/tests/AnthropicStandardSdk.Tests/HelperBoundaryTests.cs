using System;
using System.IO;
using System.Text.RegularExpressions;
using Xunit;

namespace AnthropicStandardSdk.Tests;

/// <summary>The generic helper stays generic: no identity library, no environment, no SDK credential provider.</summary>
public sealed class HelperBoundaryTests
{
    private static string SourceWithoutComments()
    {
        DirectoryInfo? directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            string candidate = Path.Combine(directory.FullName, "src", "AnthropicStandardSdk", "ClientFactory.cs");
            if (File.Exists(candidate))
            {
                string source = File.ReadAllText(candidate);
                source = Regex.Replace(source, @"/\*.*?\*/", string.Empty, RegexOptions.Singleline);
                return Regex.Replace(source, @"//.*$", string.Empty, RegexOptions.Multiline);
            }

            directory = directory.Parent;
        }

        throw new FileNotFoundException("ClientFactory.cs was not found above the test output directory.");
    }

    [Theory]
    [InlineData("Azure")]
    [InlineData("Foundry")]
    [InlineData("Environment.")]
    [InlineData("GetEnvironmentVariable")]
    [InlineData("Anthropic.Credentials")]
    [InlineData("IAccessTokenProvider")]
    [InlineData("TokenCache")]
    [InlineData("Credentials =")]
    public void ClientFactory_DoesNotUse(string fragment)
    {
        Assert.DoesNotContain(fragment, SourceWithoutComments(), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("ApiKey = null,")]
    [InlineData("AuthToken = null,")]
    [InlineData("AllowAutoRedirect = false,")]
    public void ClientFactory_KeepsItsIsolationInvariants(string fragment)
    {
        Assert.Contains(fragment, SourceWithoutComments(), StringComparison.Ordinal);
    }
}