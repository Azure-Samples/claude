using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using Anthropic;
using Anthropic.Core;

namespace AnthropicStandardSdk;

/// <summary>
/// Returns the bearer token for ONE request attempt.
/// </summary>
/// <remarks>
/// <see cref="ClientFactory"/> calls this before every attempt, including SDK retries, and never
/// caches the result. Expiry, refresh and caching belong to the supplier (for example an identity
/// library credential). The caller owns the supplier and whatever it wraps; disposing the client does
/// not dispose them.
/// </remarks>
public delegate ValueTask<string> TokenProvider(CancellationToken cancellationToken);

/// <summary>Settings for <see cref="ClientFactory.Create"/>. Configure exactly one credential.</summary>
public sealed class ClientFactoryOptions
{
    /// <summary>
    /// Absolute service endpoint, for example <c>https://api.anthropic.com</c>. Must be https, except
    /// that plain http is accepted for loopback test servers. The credential is bound to this origin.
    /// </summary>
    public required string BaseUrl { get; init; }

    /// <summary>Per-attempt bearer token, sent as <c>Authorization: Bearer</c>.</summary>
    public TokenProvider? TokenProvider { get; init; }

    /// <summary>Static key, placed in <see cref="ApiKeyHeader"/>.</summary>
    public string? ApiKey { get; init; }

    /// <summary>
    /// Header that carries <see cref="ApiKey"/>. <c>Authorization</c> (the default) sends
    /// <c>Bearer &lt;key&gt;</c>; any other name, such as <c>x-api-key</c>, sends the raw key.
    /// </summary>
    public string ApiKeyHeader { get; init; } = ClientFactory.DefaultApiKeyHeader;

    /// <summary>Value for <c>anthropic-version</c>. When null the SDK default is left untouched.</summary>
    public string? ApiVersion { get; init; }

    /// <summary>
    /// Maximum time for one HTTP call, not including SDK retries. When null the SDK default is kept
    /// (the SDK sizes it per call from <c>max_tokens</c>); the helper never picks a timeout of its own.
    /// </summary>
    public TimeSpan? Timeout { get; init; }

    /// <summary>SDK retry count. When null the SDK default is kept.</summary>
    public int? MaxRetries { get; init; }

    /// <summary>
    /// Replaces the default transport (which never follows redirects). The client disposes it. Meant
    /// for tests; a replacement transport must not follow redirects either.
    /// </summary>
    public HttpMessageHandler? Transport { get; init; }
}

/// <summary>
/// Builds the standard <see cref="AnthropicClient"/> with one explicitly chosen credential. It adds no
/// client subclass and no Messages API of its own; calls, streaming, status errors and retries stay
/// with the SDK.
/// </summary>
/// <remarks>
/// The factory neither reads environment variables nor knows any identity library. It clears every
/// SDK credential slot (so ambient keys, tokens and profiles are not discovered) and registers one
/// public SDK handler that runs last. Per attempt that handler refuses a request that is not bound
/// for the configured origin, removes every credential header
/// (<c>Authorization</c>, <c>x-api-key</c>, <c>api-key</c>), sets the chosen one, and refuses
/// redirect responses. Other headers, such as <c>anthropic-beta</c>, are left as they are.
/// </remarks>
public static class ClientFactory
{
    /// <summary>The header used for an API key when none is chosen: <c>Authorization: Bearer</c>.</summary>
    public const string DefaultApiKeyHeader = "Authorization";

    private static readonly string[] CredentialHeaderNames = ["Authorization", "x-api-key", "api-key"];

    /// <summary>Creates the client. The caller disposes it.</summary>
    /// <exception cref="ArgumentException">The options are missing, ambiguous or unsafe.</exception>
    public static AnthropicClient Create(ClientFactoryOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);

        Uri baseUri = ParseBaseUrl(options.BaseUrl);

        if ((options.TokenProvider is null) == (options.ApiKey is null))
        {
            throw new ArgumentException(
                "Configure exactly one credential: set either TokenProvider or ApiKey.",
                nameof(options));
        }

        if (options.ApiKey is not null && !IsCredentialValue(options.ApiKey))
        {
            throw new ArgumentException("ApiKey is empty or contains whitespace or control characters.", nameof(options));
        }

        if (!IsHeaderName(options.ApiKeyHeader))
        {
            throw new ArgumentException("ApiKeyHeader is not a valid HTTP header name.", nameof(options));
        }

        if (options.ApiVersion is not null && !IsCredentialValue(options.ApiVersion))
        {
            throw new ArgumentException("ApiVersion is empty or contains whitespace or control characters.", nameof(options));
        }

        if (options.Timeout is { } timeout && timeout <= TimeSpan.Zero)
        {
            throw new ArgumentException("Timeout must be positive.", nameof(options));
        }

        if (options.MaxRetries is < 0)
        {
            throw new ArgumentException("MaxRetries must not be negative.", nameof(options));
        }

        RequestAuthorizer authorizer = new RequestAuthorizer(
            baseUri, options.TokenProvider, options.ApiKey, options.ApiKeyHeader, options.ApiVersion);

        HttpMessageHandler transport = options.Transport ?? new HttpClientHandler
        {
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.All,
        };

        // The SDK applies its own per-call timeout, so the HttpClient one must not cut calls short.
        HttpClient httpClient = new HttpClient(transport, disposeHandler: true)
        {
            Timeout = System.Threading.Timeout.InfiniteTimeSpan,
        };

        ClientOptions clientOptions = new ClientOptions
        {
            BaseUrl = baseUri.GetLeftPart(UriPartial.Path),
            // Clearing both slots stops ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN and profile or
            // federation discovery; the handler below supplies the only credential.
            ApiKey = null,
            AuthToken = null,
            HttpClient = httpClient,
            Handlers = [Handler.Create(authorizer.SendAsync)],
            Timeout = options.Timeout,
            MaxRetries = options.MaxRetries,
        };

        return new AnthropicClient(clientOptions);
    }

    private static Uri ParseBaseUrl(string? baseUrl)
    {
        if (!Uri.TryCreate(baseUrl, UriKind.Absolute, out Uri? uri))
        {
            throw new ArgumentException("BaseUrl must be an absolute URL.", nameof(baseUrl));
        }

        bool isHttps = uri.Scheme == Uri.UriSchemeHttps;
        bool isLoopbackHttp = uri.Scheme == Uri.UriSchemeHttp && uri.IsLoopback;
        if (!isHttps && !isLoopbackHttp)
        {
            throw new ArgumentException(
                "BaseUrl must use https; plain http is accepted only for loopback test servers.", nameof(baseUrl));
        }

        if (uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0)
        {
            throw new ArgumentException("BaseUrl must not contain user info, a query or a fragment.", nameof(baseUrl));
        }

        return uri;
    }

    private static bool IsCredentialValue(string value)
    {
        if (value.Length == 0)
        {
            return false;
        }

        foreach (char c in value)
        {
            if (c <= ' ' || c >= '\u007f')
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsHeaderName(string name)
    {
        if (name.Length == 0)
        {
            return false;
        }

        foreach (char c in name)
        {
            bool isToken = char.IsAsciiLetterOrDigit(c) || "!#$%&'*+-.^_`|~".Contains(c, StringComparison.Ordinal);
            if (!isToken)
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsRedirect(HttpStatusCode status) =>
        status is HttpStatusCode.MovedPermanently
            or HttpStatusCode.Found
            or HttpStatusCode.SeeOther
            or HttpStatusCode.TemporaryRedirect
            or HttpStatusCode.PermanentRedirect;

    private sealed class RequestAuthorizer
    {
        private readonly Uri _boundOrigin;
        private readonly TokenProvider? _tokenProvider;
        private readonly string? _apiKey;
        private readonly string _apiKeyHeader;
        private readonly string? _apiVersion;

        public RequestAuthorizer(
            Uri boundOrigin, TokenProvider? tokenProvider, string? apiKey, string apiKeyHeader, string? apiVersion)
        {
            _boundOrigin = boundOrigin;
            _tokenProvider = tokenProvider;
            _apiKey = apiKey;
            _apiKeyHeader = apiKeyHeader;
            _apiVersion = apiVersion;
        }

        public async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, NextHandler next, CancellationToken cancellationToken)
        {
            // Checked before the supplier runs so a request for another origin never costs a token.
            EnsureBoundOrigin(request.RequestUri);

            string headerName;
            string headerValue;
            if (_tokenProvider is not null)
            {
                string token = await _tokenProvider(cancellationToken).ConfigureAwait(false);
                if (!IsCredentialValue(token))
                {
                    throw new InvalidOperationException(
                        "The token provider returned an empty token or one with whitespace or control characters.");
                }

                headerName = "Authorization";
                headerValue = "Bearer " + token;
            }
            else
            {
                headerName = _apiKeyHeader;
                headerValue = string.Equals(_apiKeyHeader, "Authorization", StringComparison.OrdinalIgnoreCase)
                    ? "Bearer " + _apiKey
                    : _apiKey!;
            }

            foreach (string name in CredentialHeaderNames)
            {
                request.Headers.Remove(name);
            }

            request.Headers.Remove(headerName);
            if (!request.Headers.TryAddWithoutValidation(headerName, headerValue))
            {
                throw new InvalidOperationException("The credential header could not be set.");
            }

            if (_apiVersion is not null)
            {
                request.Headers.Remove("anthropic-version");
                request.Headers.TryAddWithoutValidation("anthropic-version", _apiVersion);
            }

            HttpResponseMessage response = await next(request, cancellationToken).ConfigureAwait(false);
            if (IsRedirect(response.StatusCode))
            {
                int status = (int)response.StatusCode;
                response.Dispose();
                throw new InvalidOperationException(
                    $"Refused an HTTP {status} redirect: credentials are bound to {_boundOrigin.GetLeftPart(UriPartial.Authority)} and redirects are not followed.");
            }

            return response;
        }

        private void EnsureBoundOrigin(Uri? requestUri)
        {
            bool sameOrigin = requestUri is not null
                && requestUri.IsAbsoluteUri
                && string.Equals(requestUri.Scheme, _boundOrigin.Scheme, StringComparison.OrdinalIgnoreCase)
                && string.Equals(requestUri.IdnHost, _boundOrigin.IdnHost, StringComparison.OrdinalIgnoreCase)
                && requestUri.Port == _boundOrigin.Port;
            if (!sameOrigin)
            {
                throw new InvalidOperationException(
                    $"Refused a request outside {_boundOrigin.GetLeftPart(UriPartial.Authority)}; credentials are bound to that origin.");
            }
        }
    }
}