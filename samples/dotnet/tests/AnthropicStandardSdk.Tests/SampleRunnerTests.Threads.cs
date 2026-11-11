using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using Xunit;

namespace AnthropicStandardSdk.Tests;

/// <summary>The <c>--threads</c> example: the real SDK thread helper against a recording transport.</summary>
public sealed partial class SampleRunnerTests
{
    private const string ThreadsBeta = "message-threads-2026-08-12";
    private const string RememberPrompt = "Remember the code ORCHID-47. Reply with OK.";
    private const string RecallPrompt = "What code did I ask you to remember? Reply with only the code.";

    private static string ThreadType(RecordedRequest request) =>
        request.BodyJson().TryGetProperty("thread", out JsonElement thread) ? thread.GetProperty("type").GetString()! : "none";

    /// <summary>The request messages as "role: text", whether the SDK sent a string or text blocks.</summary>
    private static string[] Messages(RecordedRequest request) =>
        request.BodyJson().GetProperty("messages").EnumerateArray()
            .Select((JsonElement message) =>
                message.GetProperty("role").GetString() + ": " + MessageText(message.GetProperty("content")))
            .ToArray();

    private static string MessageText(JsonElement content) =>
        content.ValueKind == JsonValueKind.String
            ? content.GetString()!
            : string.Concat(content.EnumerateArray().Select((JsonElement block) => block.GetProperty("text").GetString()));

    [Fact]
    public async Task Threads_CreateThenContinue_SendsOnlyTheNewMessage_WithTheBetaOnBothCalls()
    {
        RecordingTransport transport = new RecordingTransport();
        transport.Enqueue(Responses.Message("OK", id: "msg_first"));
        transport.Enqueue(Responses.Message("ORCHID-47", id: "msg_second"));

        RunResult result = await Run(["--threads"], BearerEnv, transport, new FakeCredential());

        Assert.Equal(0, result.ExitCode);
        Assert.Equal("ORCHID-47\n", result.Output);
        Assert.Equal(string.Empty, result.Error);
        IReadOnlyList<RecordedRequest> requests = transport.Requests;
        Assert.Equal(2, requests.Count);
        foreach (RecordedRequest request in requests)
        {
            JsonElement body = request.BodyJson();
            Assert.Equal(HttpMethod.Post, request.Method);
            Assert.Equal("/anthropic/v1/messages", request.Url.AbsolutePath);
            Assert.Equal(ThreadsBeta, request.Header("anthropic-beta"));
            Assert.StartsWith("Bearer fake-credential-token-", request.Header("Authorization"), StringComparison.Ordinal);
            Assert.False(request.Has("x-api-key"));
            Assert.Equal("claude-sonnet-5-5", body.GetProperty("model").GetString());
            Assert.Equal(1024, body.GetProperty("max_tokens").GetInt32());
            AmbientEnvironment.AssertNoCanaryEgress(request);
        }

        JsonElement create = requests[0].BodyJson();
        Assert.Equal("create", ThreadType(requests[0]));
        Assert.False(create.GetProperty("thread").TryGetProperty("previous_message_id", out JsonElement _));
        Assert.Equal("Keep replies short.", create.GetProperty("system").GetString());
        Assert.Equal(new string[] { "user: " + RememberPrompt }, Messages(requests[0]));

        JsonElement continued = requests[1].BodyJson();
        Assert.Equal("continue", ThreadType(requests[1]));
        Assert.Equal("msg_first", continued.GetProperty("thread").GetProperty("previous_message_id").GetString());
        Assert.Equal(new string[] { "user: " + RecallPrompt }, Messages(requests[1]));
        Assert.False(continued.TryGetProperty("system", out JsonElement _));
        Assert.False(continued.TryGetProperty("tools", out JsonElement _));
        Assert.DoesNotContain("ORCHID-47", requests[1].Body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Threads_ThreadNotFound_ReplaysTheWholeConversationOnce()
    {
        RecordingTransport transport = new RecordingTransport();
        transport.Enqueue(Responses.Message("OK", id: "msg_first"));
        transport.Enqueue(Responses.Error(HttpStatusCode.NotFound, "not_found_error", "thread expired", "thread_not_found"));
        transport.Enqueue(Responses.Message("ORCHID-47", id: "msg_replay"));

        RunResult result = await Run(["--threads"], BearerEnv, transport, new FakeCredential());

        Assert.Equal(0, result.ExitCode);
        Assert.Equal("ORCHID-47\n", result.Output);
        IReadOnlyList<RecordedRequest> requests = transport.Requests;
        Assert.Equal(new string[] { "create", "continue", "create" }, requests.Select(ThreadType).ToArray());
        Assert.All(requests, (RecordedRequest request) => Assert.Equal(ThreadsBeta, request.Header("anthropic-beta")));
        JsonElement replay = requests[2].BodyJson();
        Assert.Equal("Keep replies short.", replay.GetProperty("system").GetString());
        Assert.Equal(
            new string[] { "user: " + RememberPrompt, "assistant: OK", "user: " + RecallPrompt }, Messages(requests[2]));
        Assert.False(replay.GetProperty("thread").TryGetProperty("previous_message_id", out JsonElement _));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("model_not_found")]
    public async Task Threads_Other404_IsNotReplayed_AndFailsWithTheSanitizedError(string? errorCode)
    {
        RecordingTransport transport = new RecordingTransport();
        transport.Enqueue(Responses.Message("OK", id: "msg_first"));
        transport.Enqueue(Responses.Error(
            HttpStatusCode.NotFound, "not_found_error", "no such model for fake-credential-token-2", errorCode));

        RunResult result = await Run(["--threads"], BearerEnv, transport, new FakeCredential());

        Assert.Equal(SampleRunner.ExitFailure, result.ExitCode);
        Assert.Equal(string.Empty, result.Output);
        Assert.Contains("AnthropicNotFoundException (HTTP 404)", result.Error, StringComparison.Ordinal);
        Assert.Contains("[redacted]", result.Error, StringComparison.Ordinal);
        Assert.DoesNotContain("fake-credential-token", result.Error, StringComparison.Ordinal);
        Assert.Equal(new string[] { "create", "continue" }, transport.Requests.Select(ThreadType).ToArray());
    }

    [Fact]
    public async Task Threads_UnsupportedRequest_FailsWithoutAnUnthreadedFallback()
    {
        RecordingTransport transport = new RecordingTransport();
        transport.Enqueue(Responses.Message("OK", id: "msg_first"));
        transport.Enqueue(Responses.Error(
            HttpStatusCode.BadRequest, "invalid_request_error", "too many cache breakpoints", "thread_unsupported_request"));

        RunResult result = await Run(["--threads"], BearerEnv, transport, new FakeCredential());

        Assert.Equal(SampleRunner.ExitFailure, result.ExitCode);
        Assert.Equal(string.Empty, result.Output);
        Assert.Contains("AnthropicBadRequestException (HTTP 400)", result.Error, StringComparison.Ordinal);
        Assert.Equal(new string[] { "create", "continue" }, transport.Requests.Select(ThreadType).ToArray());
    }

    [Theory]
    [InlineData("")]
    [InlineData("  \n ")]
    public async Task Threads_BlankSecondReply_IsAFailure(string text)
    {
        RecordingTransport transport = new RecordingTransport();
        transport.Enqueue(Responses.Message("OK", id: "msg_first"));
        transport.Enqueue(Responses.Message(text, id: "msg_second"));

        RunResult result = await Run(["--threads"], BearerEnv, transport, new FakeCredential());

        Assert.Equal(SampleRunner.ExitFailure, result.ExitCode);
        Assert.Equal(string.Empty, result.Output);
        Assert.Contains("UnusableResponseException", result.Error, StringComparison.Ordinal);
        Assert.Equal(2, transport.Requests.Count);
    }

    [Fact]
    public async Task Threads_ThinkingOnlySecondReply_IsAFailure()
    {
        RecordingTransport transport = new RecordingTransport();
        transport.Enqueue(Responses.Message("OK", id: "msg_first"));
        transport.Enqueue(Responses.ThinkingOnly());

        RunResult result = await Run(["--threads"], BearerEnv, transport, new FakeCredential());

        Assert.Equal(SampleRunner.ExitFailure, result.ExitCode);
        Assert.Equal(string.Empty, result.Output);
        Assert.Contains("UnusableResponseException", result.Error, StringComparison.Ordinal);
        Assert.Contains("ThinkingBlock", result.Error, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("--threads", "--stream")]
    [InlineData("--threads", "some prompt")]
    public async Task Threads_TakesNoPromptAndNoStreamFlag(string first, string second)
    {
        RecordingTransport transport = new RecordingTransport();
        FakeCredential credential = new FakeCredential();

        RunResult result = await Run([first, second], BearerEnv, transport, credential);

        Assert.Equal(SampleRunner.ExitUsage, result.ExitCode);
        Assert.Equal(string.Empty, result.Output);
        Assert.Contains("--threads", result.Error, StringComparison.Ordinal);
        Assert.Empty(transport.Requests);
        Assert.False(credential.Disposed, "no credential may be created for a usage error");
    }

    [Fact]
    public async Task Help_ListsTheThreadsOption()
    {
        RunResult help = await Run(["--help"], string.Empty, new RecordingTransport());

        Assert.Equal(SampleRunner.ExitOk, help.ExitCode);
        Assert.Contains("--threads", help.Output, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task WithoutThreads_NoBetaHeaderOrThreadFieldIsSent(bool stream)
    {
        RecordingTransport transport = new RecordingTransport();
        if (stream)
        {
            transport.Enqueue(Responses.Stream("hi"));
        }

        string[] args = stream ? new string[] { "--stream" } : Array.Empty<string>();
        RunResult result = await Run(args, BearerEnv, transport, new FakeCredential());

        Assert.Equal(0, result.ExitCode);
        RecordedRequest request = transport.Single;
        Assert.False(request.Has("anthropic-beta"));
        Assert.Equal(string.Empty, request.Url.Query);
        Assert.False(request.BodyJson().TryGetProperty("thread", out JsonElement _));
    }
}
