using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Anthropic;
using Anthropic.Core;
using Anthropic.Exceptions;
using Anthropic.Models.Messages;
using Xunit;

namespace AnthropicStandardSdk.Tests;

/// <summary>
/// Drives the real Anthropic SDK client built by <see cref="ClientFactory"/> against recording
/// transports and loopback servers. No test touches the network beyond loopback.
/// </summary>
public sealed class ClientFactoryTests
{
    private static string TextOf(Message message)
    {
        StringBuilder text = new StringBuilder();
        foreach (ContentBlock block in message.Content)
        {
            if (block.TryPickText(out TextBlock? textBlock))
            {
                text.Append(textBlock.Text);
            }
        }

        return text.ToString();
    }

    [Theory]
    [InlineData(TestClients.NativeUrl)]
    [InlineData(TestClients.FoundryUrl)]
    public async Task Bearer_UsesMessagesPathModelAndRotatingAuthorization(string baseUrl)
    {
        RecordingTransport transport = new RecordingTransport();
        RotatingTokens tokens = new RotatingTokens();
        using AnthropicClient client = TestClients.Bearer(transport, tokens.Provider, baseUrl);

        Message first = await client.Messages.Create(TestClients.Params("my-custom-deployment"));
        await client.Messages.Create(TestClients.Params());

        Assert.Equal("OK", TextOf(first));
        IReadOnlyList<RecordedRequest> requests = transport.Requests;
        Assert.Equal(2, requests.Count);
        Assert.Equal(baseUrl + "/v1/messages", requests[0].Url.AbsoluteUri);
        Assert.Equal("Bearer rotating-token-1", requests[0].Header("Authorization"));
        Assert.Equal("Bearer rotating-token-2", requests[1].Header("Authorization"));
        Assert.False(requests[0].Has("x-api-key"));
        Assert.False(requests[0].Has("api-key"));
        Assert.Equal(await TestClients.SdkDefaultHeaderAsync("X-Stainless-Timeout"), requests[0].Header("X-Stainless-Timeout"));

        JsonElement body = requests[0].BodyJson();
        Assert.Equal("my-custom-deployment", body.GetProperty("model").GetString());
        Assert.Equal(1024, body.GetProperty("max_tokens").GetInt32());
        Assert.False(body.TryGetProperty("stream", out JsonElement _));
        Assert.Equal(TestClients.Model, requests[1].BodyJson().GetProperty("model").GetString());
        Assert.Equal(2, tokens.Calls);
    }

    [Theory]
    [InlineData("x-api-key", "synthetic-resource-key")]
    [InlineData("api-key", "synthetic-resource-key")]
    [InlineData("X-Custom-Key", "synthetic-resource-key")]
    [InlineData("Authorization", "Bearer synthetic-resource-key")]
    public async Task ApiKey_PlacesTheKeyInTheChosenHeaderOnly(string header, string expectedValue)
    {
        RecordingTransport transport = new RecordingTransport();
        using AnthropicClient client = TestClients.ApiKey(transport, header: header);

        await client.Messages.Create(TestClients.Params());

        RecordedRequest request = transport.Single;
        Assert.Equal(expectedValue, request.Header(header));
        foreach (string closedName in new string[] { "Authorization", "x-api-key", "api-key" })
        {
            if (!string.Equals(closedName, header, StringComparison.OrdinalIgnoreCase))
            {
                Assert.False(request.Has(closedName), closedName + " must not be sent");
            }
        }
    }

    [Fact]
    public async Task AChosenHeaderAlreadyOnTheRequestIsReplacedNotAppended()
    {
        RecordingTransport transport = new RecordingTransport();
        using AnthropicClient client = TestClients.ApiKey(transport, header: "X-Custom-Key");
        IAnthropicClient withExtras = client.WithOptions((ClientOptions options) => options with
        {
            ExtraHeaders = new Dictionary<string, string> { ["X-Custom-Key"] = AmbientEnvironment.ExtraApiKey },
        });

        await withExtras.Messages.Create(TestClients.Params());

        RecordedRequest request = transport.Single;
        Assert.Equal("synthetic-resource-key", request.Header("X-Custom-Key"));
        AmbientEnvironment.AssertNoCanaryEgress(request);
    }

    [Fact]
    public async Task ApiKey_DefaultHeaderIsAuthorizationBearer()
    {
        RecordingTransport transport = new RecordingTransport();
        using AnthropicClient client = ClientFactory.Create(new ClientFactoryOptions
        {
            BaseUrl = TestClients.NativeUrl,
            ApiKey = "synthetic-native-key",
            Transport = transport,
        });

        await client.Messages.Create(TestClients.Params());

        Assert.Equal("Bearer synthetic-native-key", transport.Single.Header("Authorization"));
        Assert.False(transport.Single.Has("x-api-key"));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task AmbientNativeCredentials_NeverReachTheWire(bool bearer)
    {
        Assert.Equal(AmbientEnvironment.ApiKey, Environment.GetEnvironmentVariable("ANTHROPIC_API_KEY"));
        Assert.Equal(AmbientEnvironment.AuthToken, Environment.GetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN"));
        RecordingTransport transport = new RecordingTransport();
        using AnthropicClient client = bearer
            ? TestClients.Bearer(transport, new RotatingTokens().Provider)
            : TestClients.ApiKey(transport);

        await client.Messages.Create(TestClients.Params());

        RecordedRequest request = transport.Single;
        AmbientEnvironment.AssertNoCanaryEgress(request);
        Assert.Equal(new Uri(TestClients.FoundryUrl).Host, request.Url.Host);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task SdkBuiltRequest_CarriesNoNativeCredential_BeforeTheLastHookRuns(bool bearer)
    {
        RecordingTransport transport = new RecordingTransport();
        using AnthropicClient client = bearer
            ? TestClients.Bearer(transport, new RotatingTokens().Provider)
            : TestClients.ApiKey(transport);
        List<string> seenBeforeTheHook = new List<string>();
        DelegatingHandler observer = Handler.Create(
            (HttpRequestMessage request, NextHandler next, CancellationToken cancellationToken) =>
            {
                seenBeforeTheHook.Add(request.Headers.ToString());
                return next(request, cancellationToken);
            });
        // Handlers are attached on first use, so an outer observer can still be added to a fresh client.
        IAnthropicClient observed = client.WithOptions(
            (ClientOptions options) => options with { Handlers = [observer, .. options.Handlers] });

        await observed.Messages.Create(TestClients.Params());

        string seen = Assert.Single(seenBeforeTheHook);
        Assert.Contains(AmbientEnvironment.CustomApiKey, seen, StringComparison.Ordinal);
        Assert.DoesNotContain("Authorization", seen, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(AmbientEnvironment.AuthToken, seen, StringComparison.Ordinal);
        Assert.DoesNotContain(AmbientEnvironment.ApiKey, seen, StringComparison.Ordinal);
        AmbientEnvironment.AssertNoCanaryEgress(transport.Single);
    }

    [Fact]
    public async Task Bearer_NeverOptsIntoTheOAuthBeta_AndKeepsOtherHeaders()
    {
        RecordingTransport transport = new RecordingTransport();
        using AnthropicClient client = TestClients.Bearer(transport, new RotatingTokens().Provider);
        IAnthropicClient withExtras = client.WithOptions((ClientOptions options) => options with
        {
            ExtraHeaders = new Dictionary<string, string>
            {
                ["anthropic-beta"] = "files-api-2025-04-14",
                ["Authorization"] = "Bearer " + AmbientEnvironment.ExtraAuthorization,
                ["x-api-key"] = AmbientEnvironment.ExtraApiKey,
                ["X-Request-Source"] = "sample",
            },
        });

        await client.Messages.Create(TestClients.Params());
        await withExtras.Messages.Create(TestClients.Params());

        IReadOnlyList<RecordedRequest> requests = transport.Requests;
        Assert.False(requests[0].Has("anthropic-beta"));
        Assert.Equal("files-api-2025-04-14", requests[1].Header("anthropic-beta"));
        Assert.Equal("sample", requests[1].Header("X-Request-Source"));
        Assert.False(requests[1].Has("x-api-key"));
        Assert.StartsWith("Bearer rotating-token-", requests[1].Header("Authorization"), StringComparison.Ordinal);
        foreach (RecordedRequest request in requests)
        {
            Assert.DoesNotContain("oauth-2025-04-20", request.Everything(), StringComparison.Ordinal);
            AmbientEnvironment.AssertNoCanaryEgress(request);
        }
    }

    [Fact]
    public async Task ApiVersion_NullKeepsTheSdkDefault_AndAValueReplacesIt()
    {
        RecordingTransport baseline = new RecordingTransport();
        using AnthropicClient plain = new AnthropicClient(new ClientOptions
        {
            BaseUrl = TestClients.FoundryUrl,
            ApiKey = "baseline-key",
            HttpClient = new HttpClient(baseline) { Timeout = System.Threading.Timeout.InfiniteTimeSpan },
        });
        await plain.Messages.Create(TestClients.Params());
        string? sdkDefault = baseline.Single.Header("anthropic-version");
        Assert.False(string.IsNullOrEmpty(sdkDefault));

        RecordingTransport untouched = new RecordingTransport();
        using AnthropicClient keepsDefault = TestClients.Bearer(untouched, new RotatingTokens().Provider, apiVersion: null);
        await keepsDefault.Messages.Create(TestClients.Params());

        RecordingTransport configured = new RecordingTransport();
        using AnthropicClient replaces = TestClients.Bearer(configured, new RotatingTokens().Provider, apiVersion: "2023-06-01");
        await replaces.Messages.Create(TestClients.Params());

        Assert.Equal(sdkDefault, untouched.Single.Header("anthropic-version"));
        Assert.Equal("2023-06-01", configured.Single.Header("anthropic-version"));
        Assert.NotEqual("2023-06-01", sdkDefault);
    }

    [Fact]
    public async Task Streaming_UsesTheSameStandardClientAndPerAttemptCredential()
    {
        RecordingTransport transport = new RecordingTransport();
        transport.Enqueue(Responses.Stream("Hel", "lo"));
        RotatingTokens tokens = new RotatingTokens();
        using AnthropicClient client = TestClients.Bearer(transport, tokens.Provider);

        StringBuilder text = new StringBuilder();
        await foreach (RawMessageStreamEvent streamEvent in client.Messages.CreateStreaming(TestClients.Params()))
        {
            if (streamEvent.TryPickContentBlockDelta(out RawContentBlockDeltaEvent? delta)
                && delta.Delta.TryPickText(out TextDelta? textDelta))
            {
                text.Append(textDelta.Text);
            }
        }

        Assert.Equal("Hello", text.ToString());
        RecordedRequest request = transport.Single;
        Assert.True(request.BodyJson().GetProperty("stream").GetBoolean());
        Assert.Equal("Bearer rotating-token-1", request.Header("Authorization"));
        Assert.False(request.Has("anthropic-beta"));
        Assert.Equal(TestClients.FoundryUrl + "/v1/messages", request.Url.AbsoluteUri);
    }

    [Fact]
    public async Task Retry_RequestsAFreshTokenForEveryAttempt()
    {
        RecordingTransport transport = new RecordingTransport();
        HttpResponseMessage unavailable = Responses.Error(HttpStatusCode.InternalServerError, "api_error", "try again");
        unavailable.Headers.TryAddWithoutValidation("Retry-After-Ms", "1");
        transport.Enqueue(unavailable);
        RotatingTokens tokens = new RotatingTokens();
        using AnthropicClient client = TestClients.Bearer(transport, tokens.Provider, maxRetries: null);

        Message message = await client.Messages.Create(TestClients.Params());

        Assert.Equal("OK", TextOf(message));
        IReadOnlyList<RecordedRequest> requests = transport.Requests;
        Assert.Equal(2, requests.Count);
        Assert.Equal("Bearer rotating-token-1", requests[0].Header("Authorization"));
        Assert.Equal("Bearer rotating-token-2", requests[1].Header("Authorization"));
        Assert.Equal("0", requests[0].Header("x-stainless-retry-count"));
        Assert.Equal("1", requests[1].Header("x-stainless-retry-count"));
        Assert.Equal(2, tokens.Calls);
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized, "authentication_error")]
    [InlineData(HttpStatusCode.Forbidden, "permission_error")]
    public async Task AuthFailures_SurfaceTypedStatusWithoutHiddenRetries(HttpStatusCode status, string errorType)
    {
        RecordingTransport transport = new RecordingTransport();
        transport.Enqueue(Responses.Error(status, errorType, "rejected"));
        RotatingTokens tokens = new RotatingTokens();
        using AnthropicClient client = TestClients.Bearer(transport, tokens.Provider, maxRetries: null);

        AnthropicApiException exception = await Assert.ThrowsAnyAsync<AnthropicApiException>(
            () => client.Messages.Create(TestClients.Params()));

        Assert.Equal(status, exception.StatusCode);
        if (status == HttpStatusCode.Unauthorized)
        {
            Assert.IsType<AnthropicUnauthorizedException>(exception);
        }
        else
        {
            Assert.IsType<AnthropicForbiddenException>(exception);
        }

        Assert.Single(transport.Requests);
        Assert.Equal(1, tokens.Calls);
        Assert.DoesNotContain("rotating-token", exception.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ProviderFailure_PropagatesItsTypeWithoutRetriesOrRequests()
    {
        RecordingTransport transport = new RecordingTransport();
        int calls = 0;
        TokenProvider failing = (CancellationToken _) =>
        {
            calls++;
            throw new InvalidOperationException("synthetic provider failure");
        };
        using AnthropicClient client = TestClients.Bearer(transport, failing, maxRetries: null);

        InvalidOperationException exception = await Assert.ThrowsAsync<InvalidOperationException>(
            () => client.Messages.Create(TestClients.Params()));

        Assert.Equal("synthetic provider failure", exception.Message);
        Assert.Equal(1, calls);
        Assert.Empty(transport.Requests);
    }

    [Theory]
    [InlineData("")]
    [InlineData("has space")]
    [InlineData("line\r\nbreak")]
    [InlineData("tab\there")]
    public async Task MalformedTokens_AreRejectedBeforeAnyRequest(string token)
    {
        RecordingTransport transport = new RecordingTransport();
        using AnthropicClient client = TestClients.Bearer(
            transport, (CancellationToken _) => ValueTask.FromResult(token), maxRetries: null);

        InvalidOperationException exception = await Assert.ThrowsAsync<InvalidOperationException>(
            () => client.Messages.Create(TestClients.Params()));

        Assert.Empty(transport.Requests);
        Assert.DoesNotContain("break", exception.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Cancellation_BeforeTheCallSendsNothing()
    {
        RecordingTransport transport = new RecordingTransport();
        RotatingTokens tokens = new RotatingTokens();
        using AnthropicClient client = TestClients.Bearer(transport, tokens.Provider, maxRetries: null);
        using CancellationTokenSource cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => client.Messages.Create(TestClients.Params(), cancellation.Token));

        Assert.Empty(transport.Requests);
        Assert.Equal(0, tokens.Calls);
    }

    [Fact]
    public async Task Cancellation_WhileTheProviderWaitsStopsTheCall()
    {
        RecordingTransport transport = new RecordingTransport();
        TaskCompletionSource waiting = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        TokenProvider slow = async (CancellationToken cancellationToken) =>
        {
            waiting.TrySetResult();
            await Task.Delay(System.Threading.Timeout.Infinite, cancellationToken).ConfigureAwait(false);
            return "unreachable-token";
        };
        using AnthropicClient client = TestClients.Bearer(transport, slow, maxRetries: null);
        using CancellationTokenSource cancellation = new CancellationTokenSource();

        Task<Message> call = client.Messages.Create(TestClients.Params(), cancellation.Token);
        await waiting.Task.WaitAsync(TimeSpan.FromSeconds(10));
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => call);
        Assert.Empty(transport.Requests);
    }

    [Fact]
    public async Task Cancellation_InFlightIsNotRetriedByTheSdk()
    {
        RecordingTransport transport = new RecordingTransport();
        TaskCompletionSource inFlight = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        transport.Enqueue(async (RecordedRequest _, CancellationToken cancellationToken) =>
        {
            inFlight.TrySetResult();
            await Task.Delay(System.Threading.Timeout.Infinite, cancellationToken).ConfigureAwait(false);
            throw new InvalidOperationException("unreachable");
        });
        using AnthropicClient client = TestClients.Bearer(transport, new RotatingTokens().Provider, maxRetries: null);
        using CancellationTokenSource cancellation = new CancellationTokenSource();

        Task<Message> call = client.Messages.Create(TestClients.Params(), cancellation.Token);
        await inFlight.Task.WaitAsync(TimeSpan.FromSeconds(10));
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => call);
        Assert.Single(transport.Requests);
    }

    [Fact]
    public async Task Timeout_KeepsTheSdkDefaultUntilTheCallerSetsOne()
    {
        RecordingTransport implicitTimeout = new RecordingTransport();
        using AnthropicClient keepsDefault = TestClients.Bearer(implicitTimeout, new RotatingTokens().Provider);
        await keepsDefault.Messages.Create(TestClients.Params());

        RecordingTransport explicitTimeout = new RecordingTransport();
        using AnthropicClient overrides = TestClients.Bearer(
            explicitTimeout, new RotatingTokens().Provider, timeout: TimeSpan.FromSeconds(45));
        await overrides.Messages.Create(TestClients.Params());

        string sdkDefault = await TestClients.SdkDefaultHeaderAsync("X-Stainless-Timeout");
        Assert.Equal(sdkDefault, implicitTimeout.Single.Header("X-Stainless-Timeout"));
        Assert.Equal("45", explicitTimeout.Single.Header("X-Stainless-Timeout"));
        Assert.NotEqual("45", sdkDefault);
    }

    [Fact]
    public async Task Timeout_IsAppliedPerCallAndRetriedBySdk()
    {
        RecordingTransport transport = new RecordingTransport();
        Responder hang = async (RecordedRequest _, CancellationToken cancellationToken) =>
        {
            await Task.Delay(System.Threading.Timeout.Infinite, cancellationToken).ConfigureAwait(false);
            throw new InvalidOperationException("unreachable");
        };
        transport.Enqueue(hang);
        transport.Enqueue(hang);
        using AnthropicClient client = TestClients.Bearer(
            transport, new RotatingTokens().Provider, maxRetries: 1, timeout: TimeSpan.FromMilliseconds(150));

        OperationCanceledException exception = await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => client.Messages.Create(TestClients.Params()));

        Assert.IsType<TimeoutException>(exception.InnerException);
        IReadOnlyList<RecordedRequest> requests = transport.Requests;
        Assert.Equal(2, requests.Count);
        Assert.Equal("0.15", requests[0].Header("X-Stainless-Timeout"));
    }

    [Theory]
    [InlineData(HttpStatusCode.MovedPermanently)]
    [InlineData(HttpStatusCode.Found)]
    [InlineData(HttpStatusCode.SeeOther)]
    [InlineData(HttpStatusCode.TemporaryRedirect)]
    [InlineData(HttpStatusCode.PermanentRedirect)]
    public async Task Redirects_AreRefusedWithoutFollowingOrRetrying(HttpStatusCode status)
    {
        RecordingTransport transport = new RecordingTransport();
        transport.Enqueue(Responses.Redirect(status, "https://attacker.example/collect"));
        using AnthropicClient client = TestClients.ApiKey(transport, maxRetries: null);

        InvalidOperationException exception = await Assert.ThrowsAsync<InvalidOperationException>(
            () => client.Messages.Create(TestClients.Params()));

        Assert.Contains("redirect", exception.Message, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("attacker.example", exception.Message, StringComparison.Ordinal);
        Assert.Single(transport.Requests);
    }

    [Fact]
    public async Task DefaultTransport_SendsToLoopbackAndRefusesCrossOriginRedirects()
    {
        using LoopbackServer attacker = new LoopbackServer(
            (string _) => LoopbackServer.Json(Responses.MessageJson("\"stolen\"", 1, 1)));
        int served = 0;
        using LoopbackServer origin = new LoopbackServer(
            (string _) => Interlocked.Increment(ref served) == 1
                ? LoopbackServer.Json(Responses.MessageJson("\"loopback ok\"", 3, 4))
                : LoopbackServer.Raw("307 Temporary Redirect", $"Location: {attacker.BaseUrl}/steal"));

        using AnthropicClient bearer = ClientFactory.Create(new ClientFactoryOptions
        {
            BaseUrl = origin.BaseUrl,
            TokenProvider = new RotatingTokens().Provider,
            MaxRetries = 0,
        });
        Message ok = await bearer.Messages.Create(TestClients.Params());
        Assert.Equal("loopback ok", TextOf(ok));
        string head = Assert.Single(origin.RequestHeads);
        Assert.StartsWith("POST /v1/messages HTTP/1.1", head, StringComparison.Ordinal);
        Assert.Contains("authorization: Bearer rotating-token-1", head, StringComparison.OrdinalIgnoreCase);

        using AnthropicClient keyed = ClientFactory.Create(new ClientFactoryOptions
        {
            BaseUrl = origin.BaseUrl,
            ApiKey = "synthetic-resource-key",
            ApiKeyHeader = "x-api-key",
        });
        InvalidOperationException exception = await Assert.ThrowsAsync<InvalidOperationException>(
            () => keyed.Messages.Create(TestClients.Params()));

        Assert.Contains("redirect", exception.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(2, origin.RequestHeads.Count);
        Assert.Empty(attacker.RequestHeads);
    }

    [Fact]
    public async Task OriginBinding_RefusesRequestsForAnotherOriginBeforeAskingForATokenOrSending()
    {
        RecordingTransport transport = new RecordingTransport();
        RotatingTokens tokens = new RotatingTokens();
        using AnthropicClient client = TestClients.Bearer(transport, tokens.Provider, maxRetries: null);
        IAnthropicClient retargeted = client.WithOptions(
            (ClientOptions options) => options with { BaseUrl = "https://attacker.example" });

        InvalidOperationException exception = await Assert.ThrowsAsync<InvalidOperationException>(
            () => retargeted.Messages.Create(TestClients.Params()));

        Assert.Contains("bound", exception.Message, StringComparison.Ordinal);
        Assert.Empty(transport.Requests);
        Assert.Equal(0, tokens.Calls);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not a url")]
    [InlineData("/relative/path")]
    [InlineData("http://example.com")]
    [InlineData("ftp://example.com")]
    [InlineData("https://user:pass@example.com")]
    [InlineData("https://example.com/path?query=1")]
    [InlineData("https://example.com/path#fragment")]
    public void Create_RejectsUnsafeBaseUrls(string baseUrl)
    {
        Assert.Throws<ArgumentException>(() => ClientFactory.Create(new ClientFactoryOptions
        {
            BaseUrl = baseUrl,
            ApiKey = "synthetic-key",
        }));
    }

    [Theory]
    [InlineData("http://127.0.0.1:5000")]
    [InlineData("http://localhost:5000")]
    [InlineData("http://[::1]:5000")]
    [InlineData("https://example.com")]
    public void Create_AcceptsHttpsAndLoopbackHttp(string baseUrl)
    {
        using AnthropicClient client = ClientFactory.Create(new ClientFactoryOptions
        {
            BaseUrl = baseUrl,
            ApiKey = "synthetic-key",
        });

        Assert.NotNull(client);
    }

    [Fact]
    public void Create_RequiresExactlyOneCredential()
    {
        RotatingTokens tokens = new RotatingTokens();
        Assert.Throws<ArgumentException>(() => ClientFactory.Create(new ClientFactoryOptions
        {
            BaseUrl = TestClients.FoundryUrl,
        }));
        Assert.Throws<ArgumentException>(() => ClientFactory.Create(new ClientFactoryOptions
        {
            BaseUrl = TestClients.FoundryUrl,
            ApiKey = "synthetic-key",
            TokenProvider = tokens.Provider,
        }));
        Assert.Throws<ArgumentNullException>(() => ClientFactory.Create(null!));
    }

    [Theory]
    [InlineData("api-key-with-space ", null, null, null)]
    [InlineData("synthetic-key", "bad header", null, null)]
    [InlineData("synthetic-key", "bad:header", null, null)]
    [InlineData("synthetic-key", "", null, null)]
    [InlineData("synthetic-key", "x-api-key", "bad version", null)]
    [InlineData("synthetic-key", "x-api-key", "", null)]
    [InlineData("synthetic-key", "x-api-key", null, -1)]
    public void Create_RejectsMalformedOptions(string apiKey, string? header, string? apiVersion, int? maxRetries)
    {
        Assert.Throws<ArgumentException>(() => ClientFactory.Create(new ClientFactoryOptions
        {
            BaseUrl = TestClients.FoundryUrl,
            ApiKey = apiKey,
            ApiKeyHeader = header ?? "x-api-key",
            ApiVersion = apiVersion,
            MaxRetries = maxRetries,
        }));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-5)]
    public void Create_RejectsNonPositiveTimeouts(int seconds)
    {
        Assert.Throws<ArgumentException>(() => ClientFactory.Create(new ClientFactoryOptions
        {
            BaseUrl = TestClients.FoundryUrl,
            ApiKey = "synthetic-key",
            Timeout = TimeSpan.FromSeconds(seconds),
        }));
    }
}