using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using Anthropic;
using Anthropic.Core;
using Anthropic.Credentials;
using Xunit;

namespace AnthropicStandardSdk.Tests;

/// <summary>
/// Records how the unmodified Anthropic 13.3.0 client behaves with the hostile ambient environment.
/// They explain why <see cref="ClientFactory"/> clears both credential slots and installs its own last
/// handler instead of using the SDK credential options. If one fails after an SDK upgrade, revisit
/// the helper and its documentation.
/// </summary>
public sealed class SdkBehaviorProbeTests
{
    private static HttpClient Http(RecordingTransport transport) =>
        new HttpClient(transport) { Timeout = System.Threading.Timeout.InfiniteTimeSpan };

    [Fact]
    public async Task StandardApiKey_IsAuthorizationBearer_NotTheXApiKeyHeader()
    {
        RecordingTransport transport = new RecordingTransport();
        using AnthropicClient client = new AnthropicClient(new ClientOptions
        {
            BaseUrl = TestClients.FoundryUrl,
            ApiKey = "synthetic-key",
            HttpClient = Http(transport),
            MaxRetries = 0,
        });

        await client.Messages.Create(TestClients.Params());

        RecordedRequest request = transport.Single;
        Assert.Equal("Bearer synthetic-key", request.Header("Authorization"));
        Assert.DoesNotContain("synthetic-key", request.Header("x-api-key") ?? string.Empty, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ClearingOnlyApiKey_LeavesTheAmbientAuthTokenInPlace()
    {
        RecordingTransport transport = new RecordingTransport();
        using AnthropicClient client = new AnthropicClient(new ClientOptions
        {
            BaseUrl = TestClients.FoundryUrl,
            ApiKey = null,
            HttpClient = Http(transport),
            MaxRetries = 0,
        });

        await client.Messages.Create(TestClients.Params());

        Assert.Equal("Bearer " + AmbientEnvironment.AuthToken, transport.Single.Header("Authorization"));
    }

    [Fact]
    public async Task ClearingBothSlots_StopsAmbientKeysAndTokens_ButNotAmbientCustomHeaders()
    {
        RecordingTransport transport = new RecordingTransport();
        using AnthropicClient client = new AnthropicClient(new ClientOptions
        {
            BaseUrl = TestClients.FoundryUrl,
            ApiKey = null,
            AuthToken = null,
            HttpClient = Http(transport),
            MaxRetries = 0,
        });

        await client.Messages.Create(TestClients.Params());

        RecordedRequest request = transport.Single;
        Assert.False(request.Has("Authorization"));
        Assert.Equal(AmbientEnvironment.CustomApiKey, request.Header("x-api-key"));
        Assert.Equal(AmbientEnvironment.CustomApiKeyAlternate, request.Header("api-key"));
    }

    [Fact]
    public async Task CredentialsProvider_AddsTheNativeOAuthBetaToEveryRequest_AndForcesARefreshAfter401()
    {
        RecordingTransport transport = new RecordingTransport();
        transport.Enqueue(Responses.Error(HttpStatusCode.Unauthorized, "authentication_error", "expired"));
        RenewingProvider provider = new RenewingProvider();
        using AnthropicClient client = new AnthropicClient(new ClientOptions
        {
            BaseUrl = TestClients.FoundryUrl,
            Credentials = provider,
            HttpClient = Http(transport),
            MaxRetries = 0,
        });

        await client.Messages.Create(TestClients.Params());

        System.Collections.Generic.IReadOnlyList<RecordedRequest> requests = transport.Requests;
        Assert.Equal(2, requests.Count);
        Assert.Equal("Bearer provider-token-1", requests[0].Header("Authorization"));
        Assert.Equal("Bearer provider-token-2", requests[1].Header("Authorization"));
        Assert.All(requests, (RecordedRequest request) =>
            Assert.Contains("oauth-2025-04-20", request.Header("anthropic-beta"), StringComparison.Ordinal));
        Assert.Equal(new bool[] { false, true }, provider.ForceRefreshFlags);
    }

    private sealed class RenewingProvider : IAccessTokenProvider
    {
        private int _calls;

        public System.Collections.Generic.List<bool> ForceRefreshFlags { get; } = new System.Collections.Generic.List<bool>();

        public ValueTask<Anthropic.Credentials.AccessToken> GetTokenAsync(
            bool forceRefresh = false, CancellationToken cancellationToken = default)
        {
            ForceRefreshFlags.Add(forceRefresh);
            long expiresAt = DateTimeOffset.UtcNow.AddMinutes(10).ToUnixTimeSeconds();
            return ValueTask.FromResult(
                new Anthropic.Credentials.AccessToken("provider-token-" + Interlocked.Increment(ref _calls), expiresAt));
        }

        public void Dispose()
        {
        }
    }
}