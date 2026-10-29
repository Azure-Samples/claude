using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Azure.Core;
using Azure.Identity;
using Xunit;

namespace AnthropicStandardSdk.Tests;

/// <summary>The sample entrypoint end to end: environment, credential wiring, real SDK, output, exit codes.</summary>
public sealed class SampleRunnerTests
{
    private const string Foundry = TestClients.FoundryUrl;

    // ANTHROPIC_BASE_URL selects the canonical profile; CLAUDE_BASE_URL alone selects the legacy one.
    private const string CanonicalEnv = "ANTHROPIC_BASE_URL=" + Foundry + ";ANTHROPIC_MODEL=claude-sonnet-5-5";
    private const string BearerEnv = CanonicalEnv + ";AUTH_MODE=bearer";
    private const string KeyEnv = CanonicalEnv + ";AUTH_MODE=api_key";
    private const string LegacyEnv = "CLAUDE_BASE_URL=" + Foundry + ";CLAUDE_DEPLOYMENT_NAME=legacy-deployment";

    // The other family's values, with canaries that must never be used or sent.
    private const string LegacyCanaries =
        "CLAUDE_BASE_URL=https://legacy-canary.invalid;CLAUDE_DEPLOYMENT_NAME=legacy-model-canary;CLAUDE_API_KEY=legacy-key-canary";

    private const string NativeCanaries = "ANTHROPIC_MODEL=native-model-canary;ANTHROPIC_API_KEY=native-key-canary";

    private static readonly string[] AllFamilyCanaries =
        ["legacy-canary.invalid", "legacy-model-canary", "legacy-key-canary", "native-model-canary", "native-key-canary"];

    private sealed record RunResult(int ExitCode, string Output, string Error);

    private sealed class FakeCredential : TokenCredential, IDisposable
    {
        private int _calls;

        public List<string[]> Scopes { get; } = new List<string[]>();

        public bool Disposed { get; private set; }

        public Exception? Failure { get; init; }

        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            throw new NotSupportedException("The sample requests tokens asynchronously.");

        public override ValueTask<AccessToken> GetTokenAsync(
            TokenRequestContext requestContext, CancellationToken cancellationToken)
        {
            Scopes.Add(requestContext.Scopes);
            if (Failure is not null)
            {
                throw Failure;
            }

            return ValueTask.FromResult(
                new AccessToken("fake-credential-token-" + Interlocked.Increment(ref _calls), DateTimeOffset.UtcNow.AddHours(1)));
        }

        public void Dispose() => Disposed = true;
    }

    private static Func<string, string?> Env(string spec)
    {
        Dictionary<string, string> values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (string pair in spec.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            int separator = pair.IndexOf('=', StringComparison.Ordinal);
            values[pair.Substring(0, separator)] = pair.Substring(separator + 1);
        }

        return (string name) => values.TryGetValue(name, out string? value) ? value : null;
    }

    private static async Task<RunResult> Run(
        string[] args,
        string environment,
        RecordingTransport transport,
        FakeCredential? credential = null,
        CancellationToken cancellationToken = default)
    {
        StringWriter output = new StringWriter();
        StringWriter error = new StringWriter();
        Func<SampleSettings, TokenCredential>? factory = credential is null ? null : (SampleSettings _) => credential;

        int exitCode = await SampleRunner.RunAsync(
            args, Env(environment), output, error, cancellationToken, transport, factory);

        return new RunResult(
            exitCode, output.ToString().Replace("\r\n", "\n"), error.ToString().Replace("\r\n", "\n"));
    }

    private static void AssertNoFamilyCanaries(RecordedRequest request)
    {
        string everything = request.Everything();
        foreach (string canary in AllFamilyCanaries)
        {
            Assert.DoesNotContain(canary, everything, StringComparison.OrdinalIgnoreCase);
        }
    }

    [Fact]
    public async Task LegacyProfile_DefaultsToBearer_UsesItsOwnNames_AndPrintsTextThenUsage()
    {
        RecordingTransport transport = new RecordingTransport();
        FakeCredential credential = new FakeCredential();

        RunResult result = await Run(
            [], "CLAUDE_BASE_URL=" + Foundry + ";CLAUDE_DEPLOYMENT_NAME=my-deployment", transport, credential);

        Assert.Equal(0, result.ExitCode);
        Assert.Equal("OK\nusage: input_tokens=11 output_tokens=5\n", result.Output);
        Assert.Equal(string.Empty, result.Error);
        RecordedRequest request = transport.Single;
        Assert.Equal(Foundry + "/v1/messages", request.Url.AbsoluteUri);
        Assert.Equal("Bearer fake-credential-token-1", request.Header("Authorization"));
        Assert.Equal(await TestClients.SdkDefaultApiVersionAsync(), request.Header("anthropic-version"));
        Assert.Equal("120", request.Header("X-Stainless-Timeout"));
        JsonElement body = request.BodyJson();
        Assert.Equal("my-deployment", body.GetProperty("model").GetString());
        Assert.Equal(1024, body.GetProperty("max_tokens").GetInt32());
        Assert.Equal(new string[] { "https://ai.azure.com/.default" }, Assert.Single(credential.Scopes));
        AmbientEnvironment.AssertNoCanaryEgress(request);
    }

    [Fact]
    public async Task CanonicalProfile_WinsOverLegacy_AndHonorsScopeAndVersionOverrides()
    {
        RecordingTransport transport = new RecordingTransport();
        FakeCredential credential = new FakeCredential();
        string environment =
            "ANTHROPIC_BASE_URL=https://preferred.example/anthropic;CLAUDE_BASE_URL=https://legacy.example/anthropic;"
            + "ANTHROPIC_MODEL=preferred-model;CLAUDE_DEPLOYMENT_NAME=legacy-model;"
            + "TOKEN_SCOPE=api://custom/.default;ANTHROPIC_API_VERSION=2023-06-01;AUTH_MODE=BEARER";

        RunResult result = await Run([], environment, transport, credential);

        Assert.Equal(0, result.ExitCode);
        RecordedRequest request = transport.Single;
        Assert.Equal("https://preferred.example/anthropic/v1/messages", request.Url.AbsoluteUri);
        Assert.Equal("preferred-model", request.BodyJson().GetProperty("model").GetString());
        Assert.Equal("2023-06-01", request.Header("anthropic-version"));
        Assert.NotEqual("2023-06-01", await TestClients.SdkDefaultApiVersionAsync());
        Assert.Equal(new string[] { "api://custom/.default" }, Assert.Single(credential.Scopes));
    }

    [Fact]
    public async Task CanonicalProfile_IgnoresEveryLegacyValue()
    {
        RecordingTransport transport = new RecordingTransport();
        FakeCredential credential = new FakeCredential();

        RunResult result = await Run(
            [], KeyEnv + ";ANTHROPIC_API_KEY=canonical-key;" + LegacyCanaries, transport, credential);

        Assert.Equal(0, result.ExitCode);
        RecordedRequest request = transport.Single;
        Assert.Equal(Foundry + "/v1/messages", request.Url.AbsoluteUri);
        Assert.Equal("claude-sonnet-5-5", request.BodyJson().GetProperty("model").GetString());
        Assert.Equal("Bearer canonical-key", request.Header("Authorization"));
        AssertNoFamilyCanaries(request);
        Assert.Empty(credential.Scopes);
    }

    [Fact]
    public async Task LegacyProfile_IgnoresEveryAmbientNativeValue()
    {
        RecordingTransport transport = new RecordingTransport();

        RunResult result = await Run(
            [], LegacyEnv + ";AUTH_MODE=api_key;CLAUDE_API_KEY=legacy-key;" + NativeCanaries, transport);

        Assert.Equal(0, result.ExitCode);
        RecordedRequest request = transport.Single;
        Assert.Equal("legacy-deployment", request.BodyJson().GetProperty("model").GetString());
        Assert.Equal("Bearer legacy-key", request.Header("Authorization"));
        AssertNoFamilyCanaries(request);
    }

    [Fact]
    public async Task LegacyBearerDefault_NeverUsesAnAmbientNativeKey()
    {
        RecordingTransport transport = new RecordingTransport();
        FakeCredential credential = new FakeCredential();

        RunResult result = await Run([], LegacyEnv + ";" + NativeCanaries, transport, credential);

        Assert.Equal(0, result.ExitCode);
        RecordedRequest request = transport.Single;
        Assert.Equal("Bearer fake-credential-token-1", request.Header("Authorization"));
        Assert.Equal("legacy-deployment", request.BodyJson().GetProperty("model").GetString());
        AssertNoFamilyCanaries(request);
    }

    [Fact]
    public async Task CanonicalBearer_WhenExplicit_IgnoresBothKeyFamilies()
    {
        RecordingTransport transport = new RecordingTransport();
        FakeCredential credential = new FakeCredential();

        RunResult result = await Run(
            [], BearerEnv + ";ANTHROPIC_API_KEY=native-key-canary;CLAUDE_API_KEY=legacy-key-canary", transport, credential);

        Assert.Equal(0, result.ExitCode);
        RecordedRequest request = transport.Single;
        Assert.Equal("Bearer fake-credential-token-1", request.Header("Authorization"));
        AssertNoFamilyCanaries(request);
        Assert.False(request.Has("x-api-key"));
    }

    [Theory]
    [InlineData(CanonicalEnv + ";AUTH_MODE=api_key;ANTHROPIC_API_KEY=canonical-key", "Authorization", "Bearer canonical-key")]
    [InlineData(LegacyEnv + ";AUTH_MODE=api_key;CLAUDE_API_KEY=legacy-key", "Authorization", "Bearer legacy-key")]
    [InlineData(CanonicalEnv + ";AUTH_MODE=api_key;ANTHROPIC_API_KEY=canonical-key;API_KEY_HEADER=x-api-key", "x-api-key", "canonical-key")]
    [InlineData(CanonicalEnv + ";AUTH_MODE=api_key;ANTHROPIC_API_KEY=canonical-key;API_KEY_HEADER=api-key", "api-key", "canonical-key")]
    public async Task ApiKeyMode_PlacesTheKeyInTheConfiguredHeader_WithoutAskingForAToken(
        string environment, string header, string expected)
    {
        RecordingTransport transport = new RecordingTransport();
        FakeCredential credential = new FakeCredential();

        RunResult result = await Run([], environment, transport, credential);

        Assert.Equal(0, result.ExitCode);
        RecordedRequest request = transport.Single;
        Assert.Equal(expected, request.Header(header));
        foreach (string closedName in new string[] { "Authorization", "x-api-key", "api-key" })
        {
            Assert.Equal(
                string.Equals(closedName, header, StringComparison.OrdinalIgnoreCase),
                request.Has(closedName));
        }

        Assert.Equal(await TestClients.SdkDefaultApiVersionAsync(), request.Header("anthropic-version"));
        Assert.Equal("120", request.Header("X-Stainless-Timeout"));
        Assert.Empty(credential.Scopes);
        AmbientEnvironment.AssertNoCanaryEgress(request);
    }

    [Fact]
    public async Task Stream_PrintsTextAsItArrivesThenUsage()
    {
        RecordingTransport transport = new RecordingTransport();
        transport.Enqueue(Responses.Stream("Hel", "lo"));

        RunResult result = await Run(["--stream", "Say", "hi"], BearerEnv, transport, new FakeCredential());

        Assert.Equal(0, result.ExitCode);
        Assert.Equal("Hello\nusage: input_tokens=11 output_tokens=7\n", result.Output);
        Assert.Equal(string.Empty, result.Error);
        RecordedRequest request = transport.Single;
        Assert.True(request.BodyJson().GetProperty("stream").GetBoolean());
        Assert.Contains("Say hi", request.Body, StringComparison.Ordinal);
        Assert.Equal("120", request.Header("X-Stainless-Timeout"));
    }

    [Fact]
    public async Task PromptWordsAreJoined_AndAfterDoubleDashOptionsAreLiteral()
    {
        RecordingTransport transport = new RecordingTransport();

        RunResult result = await Run(["--", "--stream", "is", "text"], BearerEnv, transport, new FakeCredential());

        Assert.Equal(0, result.ExitCode);
        RecordedRequest request = transport.Single;
        Assert.False(request.BodyJson().TryGetProperty("stream", out JsonElement _));
        Assert.Contains("--stream is text", request.Body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ThinkingOnlyResponse_IsAFailure_NotASuccess()
    {
        RecordingTransport transport = new RecordingTransport();
        transport.Enqueue(Responses.ThinkingOnly());

        RunResult result = await Run([], BearerEnv, transport, new FakeCredential());

        Assert.Equal(SampleRunner.ExitFailure, result.ExitCode);
        Assert.Equal(string.Empty, result.Output);
        Assert.Contains("UnusableResponseException", result.Error, StringComparison.Ordinal);
        Assert.Contains("no text", result.Error, StringComparison.Ordinal);
        Assert.Contains("ThinkingBlock", result.Error, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   \n ")]
    public async Task EmptyOrBlankText_IsAFailure(string text)
    {
        RecordingTransport transport = new RecordingTransport();
        transport.Enqueue(Responses.Message(text));

        RunResult result = await Run([], BearerEnv, transport, new FakeCredential());

        Assert.Equal(SampleRunner.ExitFailure, result.ExitCode);
        Assert.Equal(string.Empty, result.Output);
        Assert.Contains("UnusableResponseException", result.Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task StreamWithoutTextOrWithoutMessageStop_IsAFailure()
    {
        RecordingTransport silent = new RecordingTransport();
        silent.Enqueue(Responses.Stream(string.Empty));
        RunResult noText = await Run(["--stream"], BearerEnv, silent, new FakeCredential());

        RecordingTransport truncated = new RecordingTransport();
        truncated.Enqueue(Responses.TruncatedStream("partial"));
        RunResult cutOff = await Run(["--stream"], BearerEnv, truncated, new FakeCredential());

        Assert.Equal(SampleRunner.ExitFailure, noText.ExitCode);
        Assert.Contains("no text", noText.Error, StringComparison.Ordinal);
        Assert.Equal(SampleRunner.ExitFailure, cutOff.ExitCode);
        Assert.Contains("before message_stop", cutOff.Error, StringComparison.Ordinal);
        Assert.DoesNotContain("usage:", cutOff.Output, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized, "AnthropicUnauthorizedException (HTTP 401)")]
    [InlineData(HttpStatusCode.Forbidden, "AnthropicForbiddenException (HTTP 403)")]
    public async Task AuthRejection_ShowsTypedStatus_AndNeverTheToken(HttpStatusCode status, string expected)
    {
        RecordingTransport transport = new RecordingTransport();
        transport.Enqueue(Responses.Error(
            status, "authentication_error", "denied for Bearer fake-credential-token-1 and fake-credential-token-1"));

        RunResult result = await Run([], BearerEnv, transport, new FakeCredential());

        Assert.Equal(SampleRunner.ExitFailure, result.ExitCode);
        Assert.Equal(string.Empty, result.Output);
        Assert.Contains(expected, result.Error, StringComparison.Ordinal);
        Assert.Contains("[redacted]", result.Error, StringComparison.Ordinal);
        Assert.DoesNotContain("fake-credential-token", result.Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ApiKeyIsRedactedFromServerErrors()
    {
        RecordingTransport transport = new RecordingTransport();
        transport.Enqueue(Responses.Error(HttpStatusCode.Unauthorized, "authentication_error", "bad key super-secret-key-value"));

        RunResult result = await Run([], KeyEnv + ";ANTHROPIC_API_KEY=super-secret-key-value", transport);

        Assert.Equal(SampleRunner.ExitFailure, result.ExitCode);
        Assert.Contains("[redacted]", result.Error, StringComparison.Ordinal);
        Assert.DoesNotContain("super-secret-key-value", result.Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task CredentialFailure_ShowsItsTypeAndSendsNothing()
    {
        RecordingTransport transport = new RecordingTransport();
        FakeCredential credential = new FakeCredential
        {
            Failure = new CredentialUnavailableException("synthetic CLI is not signed in"),
        };

        RunResult result = await Run([], BearerEnv, transport, credential);

        Assert.Equal(SampleRunner.ExitFailure, result.ExitCode);
        Assert.Contains("CredentialUnavailableException: synthetic CLI is not signed in", result.Error, StringComparison.Ordinal);
        Assert.Empty(transport.Requests);
    }

    [Fact]
    public async Task TheCallerDisposesTheCredential_OnSuccessAndOnFailure()
    {
        FakeCredential succeeded = new FakeCredential();
        await Run([], BearerEnv, new RecordingTransport(), succeeded);

        FakeCredential failed = new FakeCredential();
        RecordingTransport rejecting = new RecordingTransport();
        rejecting.Enqueue(Responses.Error(HttpStatusCode.Forbidden, "permission_error", "no"));
        await Run([], BearerEnv, rejecting, failed);

        Assert.True(succeeded.Disposed);
        Assert.True(failed.Disposed);
    }

    [Theory]
    [InlineData("ANTHROPIC_MODEL=m", "ANTHROPIC_BASE_URL")]
    [InlineData("ANTHROPIC_BASE_URL=https://x.example;AUTH_MODE=bearer", "ANTHROPIC_MODEL")]
    [InlineData(CanonicalEnv + ";AUTH_MODE=oauth", "AUTH_MODE")]
    [InlineData(KeyEnv, "ANTHROPIC_API_KEY")]
    [InlineData(BearerEnv + ";AZURE_TOKEN_CREDENTIALS=DefaultAzureCredential", "AZURE_TOKEN_CREDENTIALS")]
    [InlineData("ANTHROPIC_BASE_URL=http://example.com;ANTHROPIC_MODEL=m;AUTH_MODE=api_key;ANTHROPIC_API_KEY=k", "https")]
    public async Task InvalidConfiguration_ExitsWithUsageStatusAndSendsNothing(string environment, string expected)
    {
        RecordingTransport transport = new RecordingTransport();

        RunResult result = await Run([], environment, transport, new FakeCredential());

        Assert.Equal(SampleRunner.ExitUsage, result.ExitCode);
        Assert.Equal(string.Empty, result.Output);
        Assert.Contains(expected, result.Error, StringComparison.Ordinal);
        Assert.Empty(transport.Requests);
    }

    [Theory]
    // The canonical URL needs the canonical model and key: the legacy names are never a fallback.
    [InlineData("ANTHROPIC_BASE_URL=" + Foundry + ";CLAUDE_DEPLOYMENT_NAME=legacy-model;AUTH_MODE=bearer", "ANTHROPIC_MODEL")]
    [InlineData(CanonicalEnv + ";AUTH_MODE=api_key;CLAUDE_API_KEY=legacy-key", "ANTHROPIC_API_KEY")]
    // The canonical profile never defaults to an identity token, even when legacy values are also present.
    [InlineData(CanonicalEnv + ";ANTHROPIC_API_KEY=native-key;CLAUDE_API_KEY=legacy-key", "AUTH_MODE")]
    [InlineData(CanonicalEnv + ";" + LegacyEnv, "AUTH_MODE")]
    // A legacy-only URL needs the legacy model and key: ambient native names are never a fallback.
    [InlineData("CLAUDE_BASE_URL=" + Foundry + ";ANTHROPIC_MODEL=native-model", "CLAUDE_DEPLOYMENT_NAME")]
    [InlineData(LegacyEnv + ";AUTH_MODE=api_key;ANTHROPIC_API_KEY=native-key", "CLAUDE_API_KEY")]
    public async Task ProfilesAreNeverMixed_AndTheErrorSaysWhichVariableIsMissing(string environment, string expected)
    {
        RecordingTransport transport = new RecordingTransport();
        FakeCredential credential = new FakeCredential();

        RunResult result = await Run([], environment, transport, credential);

        Assert.Equal(SampleRunner.ExitUsage, result.ExitCode);
        Assert.Equal(string.Empty, result.Output);
        Assert.Contains(expected, result.Error, StringComparison.Ordinal);
        Assert.Empty(transport.Requests);
        Assert.Empty(credential.Scopes);
        Assert.False(credential.Disposed, "no credential may be created for an invalid configuration");
    }

    [Fact]
    public async Task HelpAndUnknownOptions()
    {
        RunResult help = await Run(["--help"], string.Empty, new RecordingTransport());
        RunResult unknown = await Run(["--verbose"], BearerEnv, new RecordingTransport());

        Assert.Equal(SampleRunner.ExitOk, help.ExitCode);
        Assert.Contains("usage:", help.Output, StringComparison.Ordinal);
        Assert.Equal(SampleRunner.ExitUsage, unknown.ExitCode);
        Assert.Contains("unknown option --verbose", unknown.Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Cancellation_StopsTheCallAndReportsAFailure()
    {
        RecordingTransport transport = new RecordingTransport();
        TaskCompletionSource inFlight = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        transport.Enqueue(async (RecordedRequest _, CancellationToken cancellationToken) =>
        {
            inFlight.TrySetResult();
            await Task.Delay(System.Threading.Timeout.Infinite, cancellationToken).ConfigureAwait(false);
            throw new InvalidOperationException("unreachable");
        });
        using CancellationTokenSource cancellation = new CancellationTokenSource();

        Task<RunResult> run = Run([], BearerEnv, transport, new FakeCredential(), cancellation.Token);
        await inFlight.Task.WaitAsync(TimeSpan.FromSeconds(10));
        cancellation.Cancel();
        RunResult result = await run;

        Assert.Equal(SampleRunner.ExitFailure, result.ExitCode);
        Assert.Contains("CanceledException", result.Error, StringComparison.Ordinal);
        Assert.Single(transport.Requests);
    }
}