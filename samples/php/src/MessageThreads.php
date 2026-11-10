<?php

declare(strict_types=1);

namespace ClaudeSample;

use Anthropic\Beta\Messages\BetaTextBlock;
use Anthropic\Client;
use Anthropic\Lib\Threads\UnsupportedRequestBehavior;
use Psr\Http\Client\ClientInterface;

final class MessageThreads
{
    public const SYSTEM = 'Keep replies short.';

    public const FIRST_PROMPT = 'Remember the code ORCHID-47. Reply with OK.';

    public const SECOND_PROMPT = 'What code did I ask you to remember? Reply with only the code.';

    private const USAGE = "Usage: php message_threads.php\n";

    private function __construct() {}

    /**
     * @param list<string> $arguments command-line arguments after the script name
     * @param array<string, string> $env
     * @param resource $stdout
     * @param resource $stderr
     * @param ClientInterface|null $httpClient PSR-18 transport override (tests)
     * @param (callable(list<string>): array{int, string})|null $runCli Azure CLI process override (tests)
     */
    public static function run(array $arguments, array $env, $stdout, $stderr, ?ClientInterface $httpClient = null, ?callable $runCli = null): int
    {
        foreach ($arguments as $argument) {
            if ('-h' === $argument || '--help' === $argument) {
                fwrite($stdout, self::USAGE);

                return 0;
            }
            fwrite($stderr, sprintf("Unknown argument: %s\n%s", $argument, self::USAGE));

            return 2;
        }

        $issued = new \ArrayObject();
        try {
            [$client, $model] = Sample::configure($env, $httpClient, $runCli, $issued);
            self::converse($client, $model, $stdout);
        } catch (\Throwable $error) {
            $configured = array_filter(array_map(static fn (string $name): mixed => $env[$name] ?? null, Sample::KEY_VARIABLES), 'is_string');
            fwrite($stderr, Sample::describeError($error, [...$configured, ...$issued->getArrayCopy()]));

            return 1;
        }

        return 0;
    }

    /**
     * @param resource $stdout
     *
     * @return string the text that was printed
     */
    public static function converse(Client $client, string $model, $stdout): string
    {
        $thread = $client->beta->messages->thread(
            maxTokens: Sample::MAX_TOKENS,
            model: $model,
            system: self::SYSTEM,
            unsupportedRequestBehavior: UnsupportedRequestBehavior::ERROR,
        );
        $thread->send(['role' => 'user', 'content' => self::FIRST_PROMPT]);
        $reply = $thread->send(['role' => 'user', 'content' => self::SECOND_PROMPT]);

        $blocks = [];
        foreach ($reply->content as $block) {
            if ($block instanceof BetaTextBlock && '' !== trim($block->text)) {
                $blocks[] = $block->text;
            }
        }
        if ([] === $blocks) {
            throw new \RuntimeException(Sample::noText($reply->stopReason));
        }
        $text = implode("\n", $blocks);
        fwrite($stdout, $text."\n");

        return $text;
    }
}