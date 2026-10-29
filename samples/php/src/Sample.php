<?php

declare(strict_types=1);

namespace ClaudeSample;

use Anthropic\Client;
use Anthropic\Messages\RawContentBlockDeltaEvent;
use Anthropic\Messages\RawMessageDeltaEvent;
use Anthropic\Messages\RawMessageStartEvent;
use Anthropic\Messages\TextBlock;
use Anthropic\Messages\TextDelta;
use Psr\Http\Client\ClientInterface;

/**
 * The command-line sample: one Messages call, printed whole or streamed (--stream).
 *
 * All configuration comes from the environment passed to run(), in one of two profiles that never borrow from each other:
 * ANTHROPIC_BASE_URL selects the canonical profile (ANTHROPIC_MODEL, ANTHROPIC_API_KEY; AUTH_MODE must be set
 * explicitly), otherwise CLAUDE_BASE_URL selects the legacy one (CLAUDE_DEPLOYMENT_NAME, CLAUDE_API_KEY; AUTH_MODE
 * defaults to bearer). The bearer credential is an Azure CLI token, a local-development fallback.
 */
final class Sample
{
    public const PROMPT = 'What are 3 things to visit in Seattle?';

    public const MAX_TOKENS = 1024;

    public const DEFAULT_TOKEN_SCOPE = 'https://ai.azure.com/.default';

    /** Application policy of this sample, passed to the factory explicitly: the factory itself keeps the SDK default. */
    public const REQUEST_TIMEOUT_SECONDS = 120.0;

    private const USAGE = "Usage: php main.php [--stream]\n";

    /** Variables whose values are credentials: they are removed from error output. */
    private const KEY_VARIABLES = ['ANTHROPIC_API_KEY', 'CLAUDE_API_KEY', 'ANTHROPIC_AUTH_TOKEN'];

    private const MAX_CAUSES = 5;

    private const MAX_MESSAGE_LENGTH = 1000;

    /** Shorter values are too likely to be ordinary words to be replaced wherever they appear. */
    private const MIN_SECRET_LENGTH = 8;

    private const TLS_FAILURE = '/cURL error (?:60|77)\b|SSL certificate problem/i';

    private const TLS_HINT = "Hint: PHP could not verify the server's TLS certificate. Point curl.cainfo and openssl.cafile (in php.ini, or as php -d curl.cainfo=<file> -d openssl.cafile=<file>) at a trusted CA bundle; see \"TLS certificates\" in the README.\n";

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
        $stream = false;
        foreach ($arguments as $argument) {
            if ('--stream' === $argument) {
                $stream = true;
            } elseif ('-h' === $argument || '--help' === $argument) {
                fwrite($stdout, self::USAGE);

                return 0;
            } else {
                fwrite($stderr, sprintf("Unknown argument: %s\n%s", $argument, self::USAGE));

                return 2;
            }
        }

        $issued = new \ArrayObject();
        try {
            [$client, $model] = self::configure($env, $httpClient, $runCli, $issued);
            if ($stream) {
                self::stream($client, $model, $stdout);
            } else {
                self::message($client, $model, $stdout);
            }
        } catch (\Throwable $error) {
            $configured = array_filter(array_map(static fn (string $name): mixed => $env[$name] ?? null, self::KEY_VARIABLES), 'is_string');
            fwrite($stderr, self::describeError($error, [...$configured, ...$issued->getArrayCopy()]));

            return 1;
        }

        return 0;
    }

    /**
     * The text printed for a failure: the error, then each underlying cause. The transport error behind a connection
     * failure (a rejected server certificate, a refused connection) is visible only there. Credentials and token-like
     * strings are replaced by [redacted], and every message is cut to one line of bounded length.
     *
     * @param list<string> $secrets exact values to remove from every message
     */
    public static function describeError(\Throwable $error, array $secrets = []): string
    {
        $own = $error instanceof \InvalidArgumentException || $error instanceof \RuntimeException;
        $entries = [self::redact(($own ? '' : self::shortName($error).': ').$error->getMessage(), $secrets)];
        $cause = $error->getPrevious();
        for ($depth = 0; $cause !== null && $depth < self::MAX_CAUSES; ++$depth, $cause = $cause->getPrevious()) {
            $entry = self::redact(self::shortName($cause).': '.$cause->getMessage(), $secrets);
            if ($entry !== end($entries)) {
                $entries[] = $entry;
            }
        }
        if ($cause !== null) {
            $entries[] = '(further causes are not shown)';
        }

        $tls = 1 === preg_match(self::TLS_FAILURE, implode("\n", $entries));
        $text = 'Error: '.array_shift($entries)."\n";
        foreach ($entries as $entry) {
            $text .= '  caused by: '.$entry."\n";
        }

        return $tls ? $text.self::TLS_HINT : $text;
    }

    /**
     * Builds the client and returns it with the model name.
     *
     * ANTHROPIC_BASE_URL selects the canonical profile: ANTHROPIC_MODEL and, for an API key, ANTHROPIC_API_KEY. AUTH_MODE
     * must be set explicitly (api_key or bearer), so an ambient native endpoint and key can never silently receive an
     * Azure token, nor an ambient Azure setup a native key. Otherwise CLAUDE_BASE_URL selects the legacy profile:
     * CLAUDE_DEPLOYMENT_NAME and CLAUDE_API_KEY, with AUTH_MODE defaulting to bearer. A profile never falls back to the
     * other one's model or key, so a secret can never be paired with the endpoint of the other family.
     *
     * @param array<string, string> $env
     * @param (callable(list<string>): array{int, string})|null $runCli
     * @param \ArrayObject<int, string>|null $issued receives every bearer token the provider returns, so error output can remove it
     *
     * @return array{Client, string}
     */
    public static function configure(array $env, ?ClientInterface $httpClient = null, ?callable $runCli = null, ?\ArrayObject $issued = null): array
    {
        $canonical = self::setting($env, 'ANTHROPIC_BASE_URL') !== null;
        if ($canonical) {
            [$baseUrl, $model, $keyName, $defaultMode] = [self::setting($env, 'ANTHROPIC_BASE_URL'), self::setting($env, 'ANTHROPIC_MODEL'), 'ANTHROPIC_API_KEY', null];
            $missingModel = 'ANTHROPIC_BASE_URL selects the ANTHROPIC_* settings: also set ANTHROPIC_MODEL (CLAUDE_DEPLOYMENT_NAME is not used with it).';
            $missingKey = 'Set ANTHROPIC_API_KEY (CLAUDE_API_KEY is not used with ANTHROPIC_BASE_URL).';
        } else {
            [$baseUrl, $model, $keyName, $defaultMode] = [self::setting($env, 'CLAUDE_BASE_URL'), self::setting($env, 'CLAUDE_DEPLOYMENT_NAME'), 'CLAUDE_API_KEY', 'bearer'];
            $missingModel = 'CLAUDE_BASE_URL selects the CLAUDE_* settings: also set CLAUDE_DEPLOYMENT_NAME (ANTHROPIC_MODEL is not used with it).';
            $missingKey = 'Set CLAUDE_API_KEY (ANTHROPIC_API_KEY is not used with CLAUDE_BASE_URL).';
        }
        if ($baseUrl === null) {
            throw new \InvalidArgumentException('Set CLAUDE_BASE_URL and CLAUDE_DEPLOYMENT_NAME, or ANTHROPIC_BASE_URL and ANTHROPIC_MODEL. The two sets are never mixed.');
        }
        if ($model === null) {
            throw new \InvalidArgumentException($missingModel);
        }

        $mode = self::setting($env, 'AUTH_MODE') ?? $defaultMode;
        if ($mode === null) {
            throw new \InvalidArgumentException('ANTHROPIC_BASE_URL selects the ANTHROPIC_* settings and requires an explicit AUTH_MODE: set AUTH_MODE=api_key (uses ANTHROPIC_API_KEY) or AUTH_MODE=bearer (uses an Azure CLI token).');
        }
        $tokenProvider = null;
        $apiKey = null;
        if ('bearer' === $mode) {
            // The selector is shared with the other language samples. Only the Azure CLI is built in here, so any other
            // explicit choice is refused rather than silently answered with the CLI.
            $selector = self::setting($env, 'AZURE_TOKEN_CREDENTIALS');
            if ($selector !== null && 'AzureCliCredential' !== $selector) {
                throw new \InvalidArgumentException(sprintf(
                    'AZURE_TOKEN_CREDENTIALS=%s is not supported: the Azure CLI (AzureCliCredential) is this sample\'s only built-in token source. Unset it, or pass your own token provider to ClientFactory for other credentials.',
                    1 === preg_match('/^[A-Za-z0-9_.-]{1,64}$/D', $selector) ? $selector : '(unprintable or too long)',
                ));
            }
            $tokenProvider = CliTokenProvider::provider(
                self::setting($env, 'TOKEN_SCOPE') ?? self::DEFAULT_TOKEN_SCOPE,
                self::setting($env, 'AZURE_TENANT_ID'),
                $runCli,
            );
            if ($issued !== null) {
                $provider = $tokenProvider;
                $tokenProvider = static function () use ($provider, $issued): string {
                    $token = $provider();
                    $issued[] = $token;

                    return $token;
                };
            }
        } elseif ('api_key' === $mode) {
            $apiKey = self::setting($env, $keyName) ?? throw new \InvalidArgumentException($missingKey);
        } else {
            throw new \InvalidArgumentException('AUTH_MODE must be bearer or api_key.');
        }

        $client = ClientFactory::createClient(
            baseUrl: $baseUrl,
            tokenProvider: $tokenProvider,
            apiKey: $apiKey,
            keyHeader: self::setting($env, 'API_KEY_HEADER') ?? 'Authorization',
            apiVersion: self::setting($env, 'ANTHROPIC_API_VERSION'),
            httpClient: $httpClient,
            timeout: self::REQUEST_TIMEOUT_SECONDS,
        );

        return [$client, $model];
    }

    /** @param resource $stdout */
    private static function message(Client $client, string $model, $stdout): void
    {
        $message = $client->messages->create(
            maxTokens: self::MAX_TOKENS,
            messages: [['role' => 'user', 'content' => self::PROMPT]],
            model: $model,
        );

        $printed = false;
        foreach ($message->content as $block) {
            if ($block instanceof TextBlock && '' !== trim($block->text)) {
                fwrite($stdout, $block->text."\n");
                $printed = true;
            }
        }
        if (!$printed) {
            throw new \RuntimeException(self::noText($message->stopReason));
        }
        fwrite($stdout, sprintf("\n[usage] input=%d output=%d\n", $message->usage->inputTokens, $message->usage->outputTokens));
    }

    /** @param resource $stdout */
    private static function stream(Client $client, string $model, $stdout): void
    {
        $events = $client->messages->createStream(
            maxTokens: self::MAX_TOKENS,
            messages: [['role' => 'user', 'content' => self::PROMPT]],
            model: $model,
        );

        $printed = false;
        $input = 0;
        $output = 0;
        $stopReason = null;
        foreach ($events as $event) {
            if ($event instanceof RawMessageStartEvent) {
                $input = $event->message->usage->inputTokens;
                $output = $event->message->usage->outputTokens;
            } elseif ($event instanceof RawContentBlockDeltaEvent && $event->delta instanceof TextDelta) {
                fwrite($stdout, $event->delta->text);
                fflush($stdout);
                $printed = $printed || '' !== trim($event->delta->text);
            } elseif ($event instanceof RawMessageDeltaEvent) {
                $input = $event->usage->inputTokens ?? $input;
                $output = $event->usage->outputTokens;
                $stopReason = $event->delta->stopReason;
            }
        }
        if (!$printed) {
            throw new \RuntimeException(self::noText($stopReason));
        }
        fwrite($stdout, sprintf("\n\n[usage] input=%d output=%d\n", $input, $output));
    }

    private static function shortName(\Throwable $error): string
    {
        return (new \ReflectionClass($error))->getShortName();
    }

    /** @param list<string> $secrets */
    private static function redact(string $text, array $secrets): string
    {
        foreach ($secrets as $secret) {
            if (strlen($secret) >= self::MIN_SECRET_LENGTH) {
                $text = str_replace($secret, '[redacted]', $text);
            }
        }
        $patterns = [
            '~(?<=://)[^/@\s]*@~' => '[redacted]@',
            '~(\bhttps?://[^\s?#]*)[?#]\S*~i' => '$1?[redacted]',
            '~\b(authorization|proxy-authorization|x-api-key|api-key|cookie)(["\']?\s*[:=]\s*["\']?)(?:(?:bearer|basic)\s+)?[^\s"\',;]+~i' => '$1$2[redacted]',
            '~\b(bearer|basic)\s+[A-Za-z0-9._\~+/=-]{6,}~i' => '$1 [redacted]',
            '~\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]*)?~' => '[redacted]',
            '~\bsk-ant-[A-Za-z0-9_-]+~' => '[redacted]',
            '~[\x00-\x1F\x7F]+~' => ' ',
        ];
        $text = preg_replace(array_keys($patterns), array_values($patterns), $text);
        if ($text === null) {
            return '(message hidden: it could not be checked for credentials)';
        }
        $text = trim($text);

        return strlen($text) > self::MAX_MESSAGE_LENGTH ? substr($text, 0, self::MAX_MESSAGE_LENGTH).'...' : $text;
    }

    private static function noText(?string $stopReason): string
    {
        return sprintf('No text response (stop_reason=%s). Increase max_tokens if the response exhausted its budget.', $stopReason ?? 'none');
    }

    /** @param array<string, string> $env the first of $names that is set and not empty */
    private static function setting(array $env, string ...$names): ?string
    {
        foreach ($names as $name) {
            if (isset($env[$name]) && '' !== $env[$name]) {
                return $env[$name];
            }
        }

        return null;
    }
}
