using System;
using System.Threading;
using System.Threading.Tasks;

namespace AnthropicStandardSdk;

internal static class Program
{
    private static async Task<int> Main(string[] args)
    {
        using CancellationTokenSource cancellation = new CancellationTokenSource();
        ConsoleCancelEventHandler onCancel = (object? sender, ConsoleCancelEventArgs eventArgs) =>
        {
            eventArgs.Cancel = true;
            cancellation.Cancel();
        };

        Console.CancelKeyPress += onCancel;
        try
        {
            return await SampleRunner
                .RunAsync(args, Environment.GetEnvironmentVariable, Console.Out, Console.Error, cancellation.Token)
                .ConfigureAwait(false);
        }
        finally
        {
            Console.CancelKeyPress -= onCancel;
        }
    }
}