<?php

declare(strict_types=1);

namespace ClaudeSample\Tests;

use Anthropic\Client;
use Anthropic\Core\Exceptions\APIConnectionException;
use Anthropic\Messages\Message;
use Anthropic\Messages\RawContentBlockDeltaEvent;
use Anthropic\Messages\TextDelta;
use ClaudeSample\ClientFactory;
use ClaudeSample\Sample;

/** PHP's built-in web server on a loopback port: a real socket and the default Guzzle transport. */
final class TestServer
{
    private static mixed $process = null;

    private static int $port = 0;

    public static function port(): int
    {
        if (null === self::$process) {
            self::start();
        }

        return self::$port;
    }

    private static function start(): void
    {
        $probe = stream_socket_server('tcp://127.0.0.1:0', $code, $message);
        if (false === $probe) {
            throw new \RuntimeException("No loopback port is available: $message");
        }
        self::$port = (int) substr((string) strrchr((string) stream_socket_get_name($probe, false), ':'), 1);
        fclose($probe);

        $null = 'Windows' === PHP_OS_FAMILY ? 'NUL' : '/dev/null';
        $process = proc_open(
            [PHP_BINARY, '-S', '127.0.0.1:'.self::$port, '-t', __DIR__.DIRECTORY_SEPARATOR.'server', __DIR__.DIRECTORY_SEPARATOR.'server'.DIRECTORY_SEPARATOR.'router.php'],
            [0 => ['pipe', 'r'], 1 => ['file', $null, 'w'], 2 => ['file', $null, 'w']],
            $pipes,
        );
        if (!is_resource($process)) {
            throw new \RuntimeException('The test web server could not be started.');
        }
        self::$process = $process;
        register_shutdown_function(static function () use ($process, $pipes): void {
            proc_terminate($process);
            fclose($pipes[0]);
            proc_close($process);
        });

        for ($attempt = 0; $attempt < 100; ++$attempt) {
            $connection = @fsockopen('127.0.0.1', self::$port, $errno, $error, 0.2);
            if (false !== $connection) {
                fclose($connection);

                return;
            }
            usleep(100_000);
        }
        throw new \RuntimeException('The test web server did not become ready.');
    }
}

/** @return array<string, string> the request headers the server received */
function echoed(Message $message): array
{
    return json_decode($message->content[0]->text, true, flags: JSON_THROW_ON_ERROR);
}

function loopback(string $path, array $options = []): Client
{
    return ClientFactory::createClient(...[
        'baseUrl' => 'http://127.0.0.1:'.TestServer::port().$path,
        'tokenProvider' => static fn (): string => 'e2e-token',
        'maxRetries' => 0,
        ...$options,
    ]);
}

test('end to end: the server receives one bearer credential, no OAuth beta, and no ambient canary', function (): void {
    $ambient = [
        'ANTHROPIC_API_KEY' => 'ambient-key-canary', 'ANTHROPIC_AUTH_TOKEN' => 'ambient-token-canary',
        'ANTHROPIC_CUSTOM_HEADERS' => "x-api-key: header-canary\napi-key: alias-canary",
    ];
    $headers = with_env($ambient, static fn (): array => echoed(send(loopback('/echo'))));
    same('Bearer e2e-token', $headers['authorization'], 'authorization');
    assert(!isset($headers['x-api-key']) && !isset($headers['api-key']), 'only one credential header');
    assert(!isset($headers['anthropic-beta']), 'no OAuth beta');
    assert(!str_contains(json_encode($headers), 'canary') && !str_contains(json_encode($headers), 'provided-by-request-hook'), 'no canary or placeholder');
    same(Client::ANTHROPIC_API_VERSION, $headers['anthropic-version'], 'default API version');
    assert(str_starts_with($headers['host'], '127.0.0.1:'), 'host header');
});

test('end to end: an API key travels in the selected header only', function (): void {
    $headers = echoed(send(loopback('/echo', ['tokenProvider' => null, 'apiKey' => 'e2e-key', 'keyHeader' => 'x-api-key', 'apiVersion' => '2023-06-01'])));
    same('e2e-key', $headers['x-api-key'], 'x-api-key');
    assert(!isset($headers['authorization']) && !isset($headers['api-key']), 'only one credential header');
    same('2023-06-01', $headers['anthropic-version'], 'explicit version');
});

test('end to end: streaming over the default transport carries the same credential', function (): void {
    $text = '';
    $events = loopback('/stream')->messages->createStream(maxTokens: 32, messages: [['role' => 'user', 'content' => 'Hello']], model: MODEL);
    foreach ($events as $event) {
        if ($event instanceof RawContentBlockDeltaEvent && $event->delta instanceof TextDelta) {
            $text .= $event->delta->text;
        }
    }
    $headers = json_decode($text, true, flags: JSON_THROW_ON_ERROR);
    same('Bearer e2e-token', $headers['authorization'], 'authorization');
    assert(str_contains($headers['accept'], 'text/event-stream'), 'a streaming request');
});

test('end to end: the default transport does not follow redirects; same-origin hops are re-authorized by the SDK', function (): void {
    $issued = 0;
    $provider = static function () use (&$issued): string {
        return 'e2e-token-'.(++$issued);
    };
    $headers = echoed(send(loopback('/redirect-same', ['tokenProvider' => $provider])));
    same('Bearer e2e-token-2', $headers['authorization'], 'the redirected hop carries a fresh token');
    same(2, $issued, 'tokens issued');
});

test('end to end: a cross-origin redirect is refused and the second origin is never contacted', function (): void {
    $issued = 0;
    $provider = static function () use (&$issued): string {
        return 'e2e-token-'.(++$issued);
    };
    try {
        send(loopback('/redirect-cross', ['tokenProvider' => $provider]));
    } catch (\RuntimeException $error) {
        same('Refusing to send credentials to a different origin.', $error->getMessage(), 'message');
        same(1, $issued, 'no token for the refused hop');

        return;
    }
    throw new \AssertionError('the cross-origin redirect was followed');
});

test('end to end: the transport timeout is enforced', function (): void {
    $started = microtime(true);
    try {
        send(loopback('/slow', ['timeout' => 1.0]));
    } catch (APIConnectionException) {
        assert(microtime(true) - $started < 2.9, 'the request must end at the 1 second timeout, not when the server answers');

        return;
    }
    throw new \AssertionError('a slow server did not time out');
});

test('end to end: a refused connection shows the real transport error as its cause, without the credential', function (): void {
    $probe = stream_socket_server('tcp://127.0.0.1:0');
    $port = (int) substr((string) strrchr((string) stream_socket_get_name($probe, false), ':'), 1);
    fclose($probe);

    $client = ClientFactory::createClient(baseUrl: "http://127.0.0.1:$port", apiKey: 'e2e-key-canary-value', maxRetries: 0);
    try {
        send($client);
    } catch (APIConnectionException $error) {
        $text = Sample::describeError($error, ['e2e-key-canary-value']);
        assert(str_starts_with($text, "Error: APIConnectionException: Anthropic API Connection Error\n  caused by: ConnectException: cURL error 7"), "the cURL error is shown: $text");
        assert(!str_contains($text, 'canary') && !str_contains($text, 'Hint:'), 'no credential and no certificate hint');

        return;
    }
    throw new \AssertionError('a refused connection did not fail');
});
