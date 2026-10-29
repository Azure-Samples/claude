using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Anthropic;
using Anthropic.Core;
using Anthropic.Models.Messages;

namespace AnthropicStandardSdk.Tests;

/// <summary>
/// Hostile ambient environment for the whole test process. It is installed before any SDK type is
/// touched (the SDK reads some of these once, statically), so every test proves that none of it
/// reaches the wire.
/// </summary>
internal static class AmbientEnvironment
{
    public const string ApiKey = "canary-ambient-api-key";
    public const string AuthToken = "canary-ambient-auth-token";
    public const string BaseHost = "canary-ambient-base.invalid";
    public const string Profile = "canary-ambient-profile";
    public const string IdentityToken = "canary-ambient-identity-token";
    public const string CustomApiKey = "canary-ambient-custom-x-api-key";
    public const string CustomApiKeyAlternate = "canary-ambient-custom-api-key";
    public const string ExtraAuthorization = "canary-extra-authorization";
    public const string ExtraApiKey = "canary-extra-key";

    public static readonly string[] AllCanaries =
    [
        ApiKey, AuthToken, BaseHost, Profile, IdentityToken, CustomApiKey, CustomApiKeyAlternate, ExtraAuthorization, ExtraApiKey,
    ];

#pragma warning disable CA2255 // The ambient environment must exist before any test or SDK type runs.
    [ModuleInitializer]
    internal static void Initialize()
    {
        Environment.SetEnvironmentVariable("ANTHROPIC_API_KEY", ApiKey);
        Environment.SetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", AuthToken);
        Environment.SetEnvironmentVariable("ANTHROPIC_BASE_URL", "https://" + BaseHost);
        Environment.SetEnvironmentVariable("ANTHROPIC_PROFILE", Profile);
        Environment.SetEnvironmentVariable("ANTHROPIC_CONFIG_DIR", Path.Combine(Path.GetTempPath(), Profile));
        Environment.SetEnvironmentVariable("ANTHROPIC_IDENTITY_TOKEN", IdentityToken);
        Environment.SetEnvironmentVariable("ANTHROPIC_FEDERATION_RULE_ID", "canary-ambient-rule");
        Environment.SetEnvironmentVariable("ANTHROPIC_ORGANIZATION_ID", "canary-ambient-organization");
        // The SDK refuses to build a request that has both a custom Authorization header and its own
        // credential, so the ambient custom headers use the other two credential header names;
        // Authorization injection is covered through ExtraHeaders instead.
        Environment.SetEnvironmentVariable(
            "ANTHROPIC_CUSTOM_HEADERS", $"x-api-key: {CustomApiKey}\napi-key: {CustomApiKeyAlternate}");
    }
#pragma warning restore CA2255

    public static void AssertNoCanaryEgress(RecordedRequest request)
    {
        string everything = request.Everything();
        foreach (string canary in AllCanaries)
        {
            Xunit.Assert.DoesNotContain(canary, everything, StringComparison.OrdinalIgnoreCase);
        }
    }
}

internal sealed class RecordedRequest
{
    public required HttpMethod Method { get; init; }

    public required Uri Url { get; init; }

    public required IReadOnlyDictionary<string, string> Headers { get; init; }

    public required string Body { get; init; }

    public bool Has(string name) => Headers.ContainsKey(name);

    public string? Header(string name) => Headers.TryGetValue(name, out string? value) ? value : null;

    public string Everything()
    {
        StringBuilder text = new StringBuilder();
        text.Append(Method).Append(' ').Append(Url).Append('\n');
        foreach (KeyValuePair<string, string> header in Headers)
        {
            text.Append(header.Key).Append(": ").Append(header.Value).Append('\n');
        }

        return text.Append(Body).ToString();
    }

    public JsonElement BodyJson()
    {
        using JsonDocument document = JsonDocument.Parse(Body);
        return document.RootElement.Clone();
    }
}

internal delegate Task<HttpResponseMessage> Responder(RecordedRequest request, CancellationToken cancellationToken);

/// <summary>The lowest transport the real SDK talks to; records every request that reaches it.</summary>
internal sealed class RecordingTransport : HttpMessageHandler
{
    private readonly object _gate = new object();
    private readonly Queue<Responder> _responders = new Queue<Responder>();
    private readonly List<RecordedRequest> _requests = new List<RecordedRequest>();

    public IReadOnlyList<RecordedRequest> Requests
    {
        get
        {
            lock (_gate)
            {
                return _requests.ToArray();
            }
        }
    }

    public RecordedRequest Single
    {
        get
        {
            IReadOnlyList<RecordedRequest> requests = Requests;
            Xunit.Assert.Single(requests);
            return requests[0];
        }
    }

    public void Enqueue(HttpResponseMessage response) =>
        Enqueue((RecordedRequest _, CancellationToken _) => Task.FromResult(response));

    public void Enqueue(Responder responder)
    {
        lock (_gate)
        {
            _responders.Enqueue(responder);
        }
    }

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Dictionary<string, string> headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (KeyValuePair<string, IEnumerable<string>> header in request.Headers)
        {
            headers[header.Key] = string.Join(", ", header.Value);
        }

        if (request.Content is not null)
        {
            foreach (KeyValuePair<string, IEnumerable<string>> header in request.Content.Headers)
            {
                headers[header.Key] = string.Join(", ", header.Value);
            }
        }

        string body = request.Content is null
            ? string.Empty
            : await request.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        RecordedRequest recorded = new RecordedRequest
        {
            Method = request.Method,
            Url = request.RequestUri!,
            Headers = headers,
            Body = body,
        };

        Responder? responder = null;
        lock (_gate)
        {
            _requests.Add(recorded);
            if (_responders.Count > 0)
            {
                responder = _responders.Dequeue();
            }
        }

        return responder is null
            ? Responses.Message()
            : await responder(recorded, cancellationToken).ConfigureAwait(false);
    }
}

internal static class Responses
{
    public static HttpResponseMessage Message(string text = "OK", long inputTokens = 11, long outputTokens = 5) =>
        Json(HttpStatusCode.OK, MessageJson(JsonSerializer.Serialize(text), inputTokens, outputTokens));

    public static HttpResponseMessage ThinkingOnly() =>
        Json(HttpStatusCode.OK, """
            {"id":"msg_test","type":"message","role":"assistant","model":"test-model",
             "content":[{"type":"thinking","thinking":"pondering","signature":"sig"}],
             "stop_reason":"max_tokens","stop_sequence":null,"usage":{"input_tokens":11,"output_tokens":1024}}
            """);

    public static HttpResponseMessage Error(HttpStatusCode status, string type, string message) =>
        Json(status, $$$"""{"type":"error","error":{"type":"{{{type}}}","message":"{{{message}}}"}}""");

    public static HttpResponseMessage Redirect(HttpStatusCode status, string location)
    {
        HttpResponseMessage response = new HttpResponseMessage(status);
        response.Headers.TryAddWithoutValidation("Location", location);
        return response;
    }

    /// <summary>A server-sent-event stream with one text delta per argument.</summary>
    public static HttpResponseMessage Stream(params string[] textDeltas) => BuildStream(true, textDeltas);

    /// <summary>Like <see cref="Stream"/> but the connection ends before message_stop.</summary>
    public static HttpResponseMessage TruncatedStream(params string[] textDeltas) => BuildStream(false, textDeltas);

    private static HttpResponseMessage BuildStream(bool includeStop, string[] textDeltas)
    {
        StringBuilder sse = new StringBuilder();
        sse.Append(Event("message_start", """
            {"type":"message_start","message":{"id":"msg_stream","type":"message","role":"assistant","model":"test-model","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":11,"output_tokens":1}}}
            """));
        sse.Append(Event("content_block_start", """{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"""));
        foreach (string delta in textDeltas)
        {
            sse.Append(Event(
                "content_block_delta",
                $$$"""{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":{{{JsonSerializer.Serialize(delta)}}}}}"""));
        }

        sse.Append(Event("content_block_stop", """{"type":"content_block_stop","index":0}"""));
        sse.Append(Event("message_delta", """{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":7}}"""));
        if (includeStop)
        {
            sse.Append(Event("message_stop", """{"type":"message_stop"}"""));
        }

        return new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(sse.ToString(), Encoding.UTF8, "text/event-stream"),
        };
    }

    public static string MessageJson(string textLiteral, long inputTokens, long outputTokens) =>
        $$$"""
        {"id":"msg_test","type":"message","role":"assistant","model":"test-model",
         "content":[{"type":"text","text":{{{textLiteral}}}}],
         "stop_reason":"end_turn","stop_sequence":null,
         "usage":{"input_tokens":{{{inputTokens}}},"output_tokens":{{{outputTokens}}}}}
        """;

    private static string Event(string name, string data) => $"event: {name}\ndata: {data.Trim()}\n\n";

    private static HttpResponseMessage Json(HttpStatusCode status, string json) =>
        new HttpResponseMessage(status) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
}

/// <summary>A token provider that hands out a different token per call, like a renewing credential.</summary>
internal sealed class RotatingTokens
{
    private int _calls;

    public int Calls => Volatile.Read(ref _calls);

    public TokenProvider Provider => (CancellationToken cancellationToken) =>
    {
        cancellationToken.ThrowIfCancellationRequested();
        return ValueTask.FromResult("rotating-token-" + Interlocked.Increment(ref _calls));
    };
}

internal static class TestClients
{
    public const string FoundryUrl = "https://example-resource.services.ai.azure.com/anthropic";
    public const string NativeUrl = "https://api.anthropic.com";
    public const string Model = "claude-sonnet-5-5";

    public static AnthropicClient Bearer(
        RecordingTransport transport,
        TokenProvider provider,
        string baseUrl = FoundryUrl,
        string? apiVersion = null,
        int? maxRetries = 0,
        TimeSpan? timeout = null) =>
        ClientFactory.Create(new ClientFactoryOptions
        {
            BaseUrl = baseUrl,
            TokenProvider = provider,
            ApiVersion = apiVersion,
            MaxRetries = maxRetries,
            Timeout = timeout,
            Transport = transport,
        });

    public static AnthropicClient ApiKey(
        RecordingTransport transport,
        string key = "synthetic-resource-key",
        string header = "x-api-key",
        string baseUrl = FoundryUrl,
        string? apiVersion = null,
        int? maxRetries = 0) =>
        ClientFactory.Create(new ClientFactoryOptions
        {
            BaseUrl = baseUrl,
            ApiKey = key,
            ApiKeyHeader = header,
            ApiVersion = apiVersion,
            MaxRetries = maxRetries,
            Transport = transport,
        });

    /// <summary>The <c>anthropic-version</c> an unconfigured standard SDK client sends.</summary>
    public static Task<string> SdkDefaultApiVersionAsync() => SdkDefaultHeaderAsync("anthropic-version");

    /// <summary>A header an unconfigured standard SDK client sends for <see cref="Params"/>.</summary>
    public static async Task<string> SdkDefaultHeaderAsync(string name)
    {
        RecordingTransport baseline = new RecordingTransport();
        using AnthropicClient plain = new AnthropicClient(new ClientOptions
        {
            BaseUrl = FoundryUrl,
            ApiKey = "baseline-key",
            HttpClient = new HttpClient(baseline) { Timeout = System.Threading.Timeout.InfiniteTimeSpan },
            MaxRetries = 0,
        });
        await plain.Messages.Create(Params()).ConfigureAwait(false);
        return baseline.Single.Header(name)!;
    }

    public static MessageCreateParams Params(string model = Model) => new MessageCreateParams
    {
        Model = model,
        MaxTokens = 1024,
        Messages = [new UserMessageParam("Hello")],
    };
}

/// <summary>A minimal real HTTP server on the loopback interface; one response per connection.</summary>
internal sealed class LoopbackServer : IDisposable
{
    private readonly TcpListener _listener;
    private readonly CancellationTokenSource _stop = new CancellationTokenSource();
    private readonly Func<string, byte[]> _respond;
    private readonly object _gate = new object();
    private readonly List<string> _requestHeads = new List<string>();
    private readonly Task _loop;

    public LoopbackServer(Func<string, byte[]> respond)
    {
        _respond = respond;
        _listener = new TcpListener(IPAddress.Loopback, 0);
        _listener.Start();
        Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        _loop = Task.Run(AcceptLoopAsync);
    }

    public int Port { get; }

    public string BaseUrl => $"http://127.0.0.1:{Port}";

    public IReadOnlyList<string> RequestHeads
    {
        get
        {
            lock (_gate)
            {
                return _requestHeads.ToArray();
            }
        }
    }

    public static byte[] Raw(string statusLine, params string[] headers)
    {
        StringBuilder text = new StringBuilder();
        text.Append("HTTP/1.1 ").Append(statusLine).Append("\r\n");
        foreach (string header in headers)
        {
            text.Append(header).Append("\r\n");
        }

        text.Append("Content-Length: 0\r\nConnection: close\r\n\r\n");
        return Encoding.ASCII.GetBytes(text.ToString());
    }

    public static byte[] Json(string json)
    {
        byte[] body = Encoding.UTF8.GetBytes(json);
        string head = $"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n";
        byte[] headBytes = Encoding.ASCII.GetBytes(head);
        byte[] all = new byte[headBytes.Length + body.Length];
        headBytes.CopyTo(all, 0);
        body.CopyTo(all, headBytes.Length);
        return all;
    }

    public void Dispose()
    {
        _stop.Cancel();
        _listener.Stop();
        try
        {
            _loop.Wait(TimeSpan.FromSeconds(5));
        }
        catch (AggregateException)
        {
        }

        _stop.Dispose();
    }

    private async Task AcceptLoopAsync()
    {
        while (!_stop.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await _listener.AcceptTcpClientAsync(_stop.Token).ConfigureAwait(false);
            }
            catch (Exception exception) when (exception is OperationCanceledException or SocketException or ObjectDisposedException)
            {
                return;
            }

            _ = Task.Run(() => HandleAsync(client));
        }
    }

    private async Task HandleAsync(TcpClient client)
    {
        using (client)
        {
            try
            {
                NetworkStream stream = client.GetStream();
                MemoryStream received = new MemoryStream();
                byte[] buffer = new byte[4096];
                int headEnd = -1;
                while (headEnd < 0)
                {
                    int read = await stream.ReadAsync(buffer, _stop.Token).ConfigureAwait(false);
                    if (read == 0)
                    {
                        return;
                    }

                    received.Write(buffer, 0, read);
                    headEnd = IndexOfHeadEnd(received.GetBuffer(), (int)received.Length);
                }

                string head = Encoding.ASCII.GetString(received.GetBuffer(), 0, headEnd);
                int contentLength = ContentLength(head);
                while (received.Length < headEnd + 4 + contentLength)
                {
                    int read = await stream.ReadAsync(buffer, _stop.Token).ConfigureAwait(false);
                    if (read == 0)
                    {
                        break;
                    }

                    received.Write(buffer, 0, read);
                }

                lock (_gate)
                {
                    _requestHeads.Add(head);
                }

                byte[] response = _respond(head);
                await stream.WriteAsync(response, _stop.Token).ConfigureAwait(false);
                await stream.FlushAsync(_stop.Token).ConfigureAwait(false);
            }
            catch (Exception exception) when (exception is IOException or SocketException or OperationCanceledException or ObjectDisposedException)
            {
            }
        }
    }

    private static int IndexOfHeadEnd(byte[] data, int length)
    {
        for (int i = 0; i + 3 < length; i++)
        {
            if (data[i] == '\r' && data[i + 1] == '\n' && data[i + 2] == '\r' && data[i + 3] == '\n')
            {
                return i;
            }
        }

        return -1;
    }

    private static int ContentLength(string head)
    {
        foreach (string line in head.Split("\r\n"))
        {
            if (line.StartsWith("content-length:", StringComparison.OrdinalIgnoreCase))
            {
                return int.Parse(line.Substring("content-length:".Length).Trim(), System.Globalization.CultureInfo.InvariantCulture);
            }
        }

        return 0;
    }
}