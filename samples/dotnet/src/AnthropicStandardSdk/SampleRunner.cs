using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Anthropic;
using Anthropic.Exceptions;
using Anthropic.Models.Messages;
using Azure.Core;

namespace AnthropicStandardSdk;

/// <summary>Raised when a successful HTTP response cannot count as a result (for example, no text).</summary>
internal sealed class UnusableResponseException : Exception
{
    public UnusableResponseException(string message)
        : base(message)
    {
    }
}

internal static class SampleRunner
{
    public const int ExitOk = 0;
    public const int ExitFailure = 1;
    public const int ExitUsage = 2;

    private const long MaxTokens = 1024;

    // Application policy of this sample, set explicitly on the client; ClientFactory has no timeout default of its own.
    internal static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(120);

    private const string DefaultPrompt = "Say hello in one short sentence.";
    private const string UsageText = "usage: AnthropicStandardSdk [--stream] [prompt...]";

    private static readonly Regex Whitespace = new Regex(@"\s+", RegexOptions.Compiled);

    /// <summary>
    /// Runs one Messages call (or one streaming call with <c>--stream</c>). Environment access,
    /// credential creation and the HTTP transport are parameters so tests can supply recording fakes.
    /// </summary>
    public static async Task<int> RunAsync(
        string[] args,
        Func<string, string?> getEnvironmentVariable,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken,
        HttpMessageHandler? transport = null,
        Func<SampleSettings, TokenCredential>? credentialFactory = null)
    {
        bool stream = false;
        bool optionsEnded = false;
        List<string> promptWords = new List<string>();
        foreach (string arg in args)
        {
            if (!optionsEnded && arg == "--")
            {
                optionsEnded = true;
            }
            else if (!optionsEnded && arg == "--stream")
            {
                stream = true;
            }
            else if (!optionsEnded && (arg == "-h" || arg == "--help"))
            {
                output.WriteLine(UsageText);
                return ExitOk;
            }
            else if (!optionsEnded && arg.StartsWith("--", StringComparison.Ordinal))
            {
                error.WriteLine("error: unknown option " + arg);
                error.WriteLine(UsageText);
                return ExitUsage;
            }
            else
            {
                promptWords.Add(arg);
            }
        }

        string prompt = promptWords.Count > 0 ? string.Join(" ", promptWords) : DefaultPrompt;

        SampleSettings settings;
        try
        {
            settings = SampleSettings.FromEnvironment(getEnvironmentVariable);
        }
        catch (ConfigurationException exception)
        {
            error.WriteLine("error: " + exception.Message);
            return ExitUsage;
        }

        SecretRedactor redactor = new SecretRedactor();
        redactor.Add(settings.ApiKey);
        TokenCredential? credential = null;
        try
        {
            ClientFactoryOptions factoryOptions;
            if (settings.AuthMode == AuthMode.Bearer)
            {
                Func<SampleSettings, TokenCredential> createCredential = credentialFactory ?? CredentialSelector.Create;
                credential = createCredential(settings);
                factoryOptions = new ClientFactoryOptions
                {
                    BaseUrl = settings.BaseUrl,
                    TokenProvider = CredentialSelector.CreateTokenProvider(credential, settings.TokenScope, redactor),
                    ApiVersion = settings.ApiVersion,
                    Timeout = RequestTimeout,
                    Transport = transport,
                };
            }
            else
            {
                factoryOptions = new ClientFactoryOptions
                {
                    BaseUrl = settings.BaseUrl,
                    ApiKey = settings.ApiKey,
                    ApiKeyHeader = settings.ApiKeyHeader,
                    ApiVersion = settings.ApiVersion,
                    Timeout = RequestTimeout,
                    Transport = transport,
                };
            }

            AnthropicClient client;
            try
            {
                client = ClientFactory.Create(factoryOptions);
            }
            catch (ArgumentException exception)
            {
                error.WriteLine("error: " + redactor.Redact(exception.Message));
                return ExitUsage;
            }

            using (client)
            {
                MessageCreateParams parameters = new MessageCreateParams
                {
                    Model = settings.Model,
                    MaxTokens = MaxTokens,
                    Messages = [new UserMessageParam(prompt)],
                };

                if (stream)
                {
                    await WriteStreamAsync(client, parameters, output, cancellationToken).ConfigureAwait(false);
                }
                else
                {
                    await WriteMessageAsync(client, parameters, output, cancellationToken).ConfigureAwait(false);
                }
            }

            return ExitOk;
        }
        catch (Exception exception)
        {
            error.WriteLine("error: " + Describe(exception, redactor));
            return ExitFailure;
        }
        finally
        {
            // The factory does not own the credential, so the caller that created it releases it.
            (credential as IDisposable)?.Dispose();
        }
    }

    private static async Task WriteMessageAsync(
        AnthropicClient client, MessageCreateParams parameters, TextWriter output, CancellationToken cancellationToken)
    {
        Message message = await client.Messages.Create(parameters, cancellationToken).ConfigureAwait(false);

        StringBuilder text = new StringBuilder();
        List<string> blockKinds = new List<string>();
        foreach (ContentBlock block in message.Content)
        {
            blockKinds.Add(block.Value?.GetType().Name ?? "unknown");
            if (block.TryPickText(out TextBlock? textBlock))
            {
                text.Append(textBlock.Text);
            }
        }

        if (string.IsNullOrWhiteSpace(text.ToString()))
        {
            throw new UnusableResponseException(
                "The response contained no text (content blocks: " + string.Join(", ", blockKinds) + ").");
        }

        output.WriteLine(text.ToString());
        output.WriteLine(FormatUsage(message.Usage.InputTokens, message.Usage.OutputTokens));
    }

    private static async Task WriteStreamAsync(
        AnthropicClient client, MessageCreateParams parameters, TextWriter output, CancellationToken cancellationToken)
    {
        long inputTokens = 0;
        long outputTokens = 0;
        bool sawText = false;
        bool sawStop = false;

        await foreach (RawMessageStreamEvent streamEvent in
            client.Messages.CreateStreaming(parameters, cancellationToken).ConfigureAwait(false))
        {
            if (streamEvent.TryPickStart(out RawMessageStartEvent? start))
            {
                inputTokens = start.Message.Usage.InputTokens;
                outputTokens = start.Message.Usage.OutputTokens;
            }
            else if (streamEvent.TryPickContentBlockDelta(out RawContentBlockDeltaEvent? blockDelta)
                && blockDelta.Delta.TryPickText(out TextDelta? textDelta)
                && textDelta.Text.Length > 0)
            {
                output.Write(textDelta.Text);
                sawText |= !string.IsNullOrWhiteSpace(textDelta.Text);
            }
            else if (streamEvent.TryPickDelta(out RawMessageDeltaEvent? messageDelta))
            {
                outputTokens = messageDelta.Usage.OutputTokens;
            }
            else if (streamEvent.TryPickStop(out RawMessageStopEvent? _))
            {
                sawStop = true;
            }
        }

        if (!sawText)
        {
            throw new UnusableResponseException("The stream contained no text.");
        }

        if (!sawStop)
        {
            throw new UnusableResponseException("The stream ended before message_stop.");
        }

        output.WriteLine();
        output.WriteLine(FormatUsage(inputTokens, outputTokens));
    }

    private static string FormatUsage(long inputTokens, long outputTokens) =>
        $"usage: input_tokens={inputTokens} output_tokens={outputTokens}";

    /// <summary>Typed root cause and HTTP status, never credentials.</summary>
    internal static string Describe(Exception exception, SecretRedactor redactor)
    {
        StringBuilder text = new StringBuilder();
        Exception? current = exception;
        for (int depth = 0; current is not null && depth < 4; depth++)
        {
            if (depth > 0)
            {
                text.Append(" <- ");
            }

            text.Append(current.GetType().Name);
            if (current is AnthropicApiException apiException)
            {
                text.Append(" (HTTP ").Append((int)apiException.StatusCode).Append(')');
            }

            string message = Whitespace.Replace(current.Message, " ").Trim();
            if (message.Length > 300)
            {
                message = message.Substring(0, 300) + "...";
            }

            if (message.Length > 0)
            {
                text.Append(": ").Append(message);
            }

            current = current.InnerException;
        }

        return redactor.Redact(text.ToString());
    }
}