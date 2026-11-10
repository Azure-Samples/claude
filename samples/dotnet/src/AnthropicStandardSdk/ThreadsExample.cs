using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Anthropic;
using Anthropic.Helpers.Beta;
using Anthropic.Models.Beta.Messages;

namespace AnthropicStandardSdk;

/// <summary>Message threads (beta), run with <c>--threads</c>: the second turn sends only its new message.</summary>
internal static class ThreadsExample
{
    private const string FirstPrompt = "Remember the code ORCHID-47. Reply with OK.";
    private const string SecondPrompt = "What code did I ask you to remember? Reply with only the code.";
    private const string SystemPrompt = "Keep replies short.";
    private const long MaxTokens = 1024;

    public static async Task RunAsync(
        AnthropicClient client, string model, TextWriter output, CancellationToken cancellationToken)
    {
        BetaMessageThread thread = client.Beta.Messages.Thread(new ThreadCreateParams
        {
            Model = model,
            MaxTokens = MaxTokens,
            System = SystemPrompt,
            Messages = [],
        });

        await thread.Send(new BetaUserMessageParam { Content = FirstPrompt }, cancellationToken).ConfigureAwait(false);
        BetaMessage second = await thread
            .Send(new BetaUserMessageParam { Content = SecondPrompt }, cancellationToken)
            .ConfigureAwait(false);

        output.WriteLine(TextOf(second));
    }

    private static string TextOf(BetaMessage message)
    {
        StringBuilder text = new StringBuilder();
        List<string> blockKinds = new List<string>();
        foreach (BetaContentBlock block in message.Content)
        {
            blockKinds.Add(block.Value?.GetType().Name ?? "unknown");
            if (block.TryPickText(out BetaTextBlock? textBlock))
            {
                text.Append(textBlock.Text);
            }
        }

        if (string.IsNullOrWhiteSpace(text.ToString()))
        {
            throw new UnusableResponseException(
                "The response contained no text (content blocks: " + string.Join(", ", blockKinds) + ").");
        }

        return text.ToString();
    }
}
