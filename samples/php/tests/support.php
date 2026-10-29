<?php

declare(strict_types=1);

namespace ClaudeSample\Tests;

use GuzzleHttp\Psr7\Response;
use Psr\Http\Client\ClientInterface;
use Psr\Http\Message\RequestInterface;
use Psr\Http\Message\ResponseInterface;

const BASE_URL = 'https://example.services.ai.azure.com/anthropic';
const MODEL = 'sample-deployment';

final class Suite
{
    /** @var list<array{string, \Closure}> */
    private static array $tests = [];

    public static function add(string $name, \Closure $body): void
    {
        self::$tests[] = [$name, $body];
    }

    public static function run(): int
    {
        $failed = 0;
        foreach (self::$tests as [$name, $body]) {
            try {
                $body();
                echo "PASS  $name\n";
            } catch (\Throwable $error) {
                ++$failed;
                echo "FAIL  $name\n      ".get_class($error).': '.$error->getMessage()."\n";
            }
        }
        printf("\n%d tests, %d failed\n", count(self::$tests), $failed);

        return 0 === $failed && [] !== self::$tests ? 0 : 1;
    }
}

function test(string $name, \Closure $body): void
{
    Suite::add($name, $body);
}

function same(mixed $expected, mixed $actual, string $what): void
{
    if ($expected !== $actual) {
        throw new \AssertionError(sprintf('%s: expected %s, got %s', $what, var_export($expected, true), var_export($actual, true)));
    }
}

/** Records every request and answers through $responder(request, call number). */
final class Recorder implements ClientInterface
{
    /** @var list<RequestInterface> */
    public array $requests = [];

    /** @var \Closure(RequestInterface, int): ResponseInterface */
    private \Closure $responder;

    public function __construct(?\Closure $responder = null)
    {
        $this->responder = $responder ?? static fn (): ResponseInterface => json_response(message_body());
    }

    public function sendRequest(RequestInterface $request): ResponseInterface
    {
        $this->requests[] = $request;

        return ($this->responder)($request, count($this->requests));
    }
}

/** @return array<string, mixed> */
function message_body(string $text = 'OK'): array
{
    return [
        'id' => 'msg_test', 'type' => 'message', 'role' => 'assistant', 'model' => MODEL,
        'content' => [['type' => 'text', 'text' => $text]],
        'stop_reason' => 'end_turn', 'stop_sequence' => null,
        'usage' => ['input_tokens' => 1, 'output_tokens' => 2],
    ];
}

/**
 * @param array<string, mixed> $body
 * @param array<string, string> $headers
 */
function json_response(array $body, int $status = 200, array $headers = []): Response
{
    return new Response($status, ['Content-Type' => 'application/json', ...$headers], json_encode($body, JSON_THROW_ON_ERROR));
}

/** @param list<string> $chunks */
function sse_response(array $chunks, int $input = 5, int $output = 7): Response
{
    $events = [
        ['message_start', ['type' => 'message_start', 'message' => [
            'id' => 'msg_stream', 'type' => 'message', 'role' => 'assistant', 'model' => MODEL, 'content' => [],
            'stop_reason' => null, 'stop_sequence' => null, 'usage' => ['input_tokens' => $input, 'output_tokens' => 1],
        ]]],
        ['content_block_start', ['type' => 'content_block_start', 'index' => 0, 'content_block' => ['type' => 'text', 'text' => '']]],
    ];
    foreach ($chunks as $chunk) {
        $events[] = ['content_block_delta', ['type' => 'content_block_delta', 'index' => 0, 'delta' => ['type' => 'text_delta', 'text' => $chunk]]];
    }
    $events[] = ['content_block_stop', ['type' => 'content_block_stop', 'index' => 0]];
    $events[] = ['message_delta', ['type' => 'message_delta', 'delta' => ['stop_reason' => 'end_turn', 'stop_sequence' => null], 'usage' => ['output_tokens' => $output]]];
    $events[] = ['message_stop', ['type' => 'message_stop']];

    $body = '';
    foreach ($events as [$type, $payload]) {
        $body .= "event: $type\ndata: ".json_encode($payload, JSON_THROW_ON_ERROR)."\n\n";
    }

    return new Response(200, ['Content-Type' => 'text/event-stream'], $body);
}

/** @return array<string, string> lower-cased header name => joined values */
function headers_of(RequestInterface $request): array
{
    $headers = [];
    foreach ($request->getHeaders() as $name => $values) {
        $headers[strtolower((string) $name)] = implode(', ', $values);
    }

    return $headers;
}

/** Everything a request shows on the wire, for canary searches. */
function wire_of(RequestInterface $request): string
{
    return json_encode([headers_of($request), (string) $request->getUri(), (string) $request->getBody()], JSON_THROW_ON_ERROR);
}

/**
 * Runs $body with exactly the ANTHROPIC_*, CLAUDE_*, AZURE_*, AUTH_MODE, API_KEY_HEADER, TOKEN_SCOPE and FAKE_AZ_*
 * variables in $set, and restores the previous values afterwards. The SDK reads both $_ENV and getenv().
 *
 * @param array<string, string> $set
 */
function with_env(array $set, \Closure $body): mixed
{
    $managed = '/^(?:ANTHROPIC_|CLAUDE_|AZURE_|FAKE_AZ_|AUTH_MODE$|API_KEY_HEADER$|TOKEN_SCOPE$)/';
    $names = array_unique([...array_keys($set), ...array_keys(getenv()), ...array_keys($_ENV)]);
    $names = array_values(array_filter(array_map('strval', $names), static fn (string $name): bool => 1 === preg_match($managed, $name) || array_key_exists($name, $set)));

    $saved = [];
    foreach ($names as $name) {
        $saved[$name] = [getenv($name), array_key_exists($name, $_ENV), $_ENV[$name] ?? null];
        putenv($name);
        unset($_ENV[$name]);
    }
    $set += ['ANTHROPIC_CONFIG_DIR' => __DIR__.DIRECTORY_SEPARATOR.'no-profile-here'];
    foreach ($set as $name => $value) {
        putenv("$name=$value");
        $_ENV[$name] = $value;
    }
    try {
        return $body();
    } finally {
        foreach (array_unique([...array_keys($set), ...$names]) as $name) {
            putenv((string) $name);
            unset($_ENV[$name]);
        }
        foreach ($saved as $name => [$value, $hadEnv, $envValue]) {
            if (false !== $value) {
                putenv("$name=$value");
            }
            if ($hadEnv) {
                $_ENV[$name] = $envValue;
            }
        }
    }
}
