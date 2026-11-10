<?php

declare(strict_types=1);

namespace ClaudeSample\Tests;

use Anthropic\Client;
use ClaudeSample\MessageThreads;
use ClaudeSample\Sample;
use GuzzleHttp\Exception\ConnectException;
use GuzzleHttp\Psr7\Request;
use GuzzleHttp\Psr7\Response;
use Psr\Http\Message\RequestInterface;
use Psr\Http\Message\ResponseInterface;

const THREADS_BETA = 'message-threads-2026-08-12';

/**
 * @param list<string> $arguments
 * @param array<string, string> $env
 *
 * @return array{int, string, string} exit code, stdout, stderr
 */
function run_threads(array $arguments, array $env, ?Recorder $recorder = null): array
{
    $stdout = fopen('php://memory', 'w+');
    $stderr = fopen('php://memory', 'w+');
    $code = MessageThreads::run($arguments, $env, $stdout, $stderr, $recorder, static fn (): array => [0, '{"accessToken":"entra-test-token"}']);
    rewind($stdout);
    rewind($stderr);

    return [$code, (string) stream_get_contents($stdout), (string) stream_get_contents($stderr)];
}

/** @return array<string, mixed> a reply with an id of its own, which a continue can name */
function thread_reply(string $id, string $text = 'OK'): array
{
    return [...message_body($text), 'id' => $id];
}

function thread_error(int $status, string $type, ?string $code = null, string $message = 'The request was rejected.'): Response
{
    $error = ['type' => $type, 'message' => $message];
    if (null !== $code) {
        $error['details'] = ['error_code' => $code];
    }

    return json_response(['type' => 'error', 'error' => $error], $status);
}

/** Answers the n-th request with the n-th response. A request beyond the script fails the test. */
function scripted(ResponseInterface ...$script): Recorder
{
    return new Recorder(static fn (RequestInterface $request, int $call): ResponseInterface => $script[$call - 1] ?? throw new \LogicException("Unexpected request $call."));
}

/** @return array<string, mixed> the JSON body of the request at $index (from 0) */
function body_of(Recorder $recorder, int $index): array
{
    return json_decode((string) $recorder->requests[$index]->getBody(), true, flags: JSON_THROW_ON_ERROR);
}

/**
 * @param array<string, mixed> $body
 *
 * @return list<string> the top-level field names, sorted
 */
function fields_of(array $body): array
{
    $names = array_keys($body);
    sort($names);

    return $names;
}

test('message threads: the first turn creates the thread, the second continues it with only its new message', function (): void {
    with_env([], static function (): void {
        $recorder = scripted(json_response(thread_reply('msg_first')), json_response(thread_reply('msg_second', 'ORCHID-47')), json_response(message_body()));
        $client = make($recorder);
        $stdout = fopen('php://memory', 'w+');

        same('ORCHID-47', MessageThreads::converse($client, MODEL, $stdout), 'returned text');
        rewind($stdout);
        same("ORCHID-47\n", stream_get_contents($stdout), 'printed text');
        same(2, count($recorder->requests), 'one request per turn');
        foreach ($recorder->requests as $turn => $request) {
            $headers = headers_of($request);
            same('POST', $request->getMethod(), "turn $turn: method");
            same('/anthropic/v1/messages', $request->getUri()->getPath(), "turn $turn: path");
            same(THREADS_BETA, $headers['anthropic-beta'] ?? null, "turn $turn: beta");
            same('Bearer selected-token', $headers['authorization'] ?? null, "turn $turn: credential");
            same(Client::ANTHROPIC_API_VERSION, $headers['anthropic-version'] ?? null, "turn $turn: API version");
            assert(!isset($headers['x-api-key']) && !isset($headers['api-key']), "turn $turn: one credential header only");
            same(MODEL, body_of($recorder, $turn)['model'], "turn $turn: model");
            same(Sample::MAX_TOKENS, body_of($recorder, $turn)['max_tokens'], "turn $turn: max_tokens");
        }

        $first = body_of($recorder, 0);
        same(['max_tokens', 'messages', 'model', 'system', 'thread'], fields_of($first), 'create request fields');
        same(['type' => 'create'], $first['thread'], 'create');
        same(MessageThreads::SYSTEM, $first['system'], 'system');
        same([['role' => 'user', 'content' => MessageThreads::FIRST_PROMPT]], $first['messages'], 'first turn messages');

        $second = body_of($recorder, 1);
        same(['max_tokens', 'messages', 'model', 'thread'], fields_of($second), 'a continue has no system and no tools, not even null');
        same(['type' => 'continue', 'previous_message_id' => 'msg_first'], $second['thread'], 'continue from the first reply');
        same([['role' => 'user', 'content' => MessageThreads::SECOND_PROMPT]], $second['messages'], 'only the new message');

        send($client);
        assert(!isset(headers_of($recorder->requests[2])['anthropic-beta']), 'the beta belongs to the thread requests, not to the client');
    });
});

test('message threads: a 404 thread_not_found is replayed once as a new thread with the whole conversation', function (): void {
    with_env([], static function (): void {
        $recorder = scripted(
            json_response(thread_reply('msg_first')),
            thread_error(404, 'not_found_error', 'thread_not_found'),
            json_response(thread_reply('msg_replayed', 'ORCHID-47')),
        );
        $stdout = fopen('php://memory', 'w+');

        same('ORCHID-47', MessageThreads::converse(make($recorder), MODEL, $stdout), 'returned text');
        same(3, count($recorder->requests), 'create, rejected continue, replay');
        foreach ($recorder->requests as $call => $request) {
            same(THREADS_BETA, headers_of($request)['anthropic-beta'] ?? null, "request $call: beta");
        }
        same(['type' => 'continue', 'previous_message_id' => 'msg_first'], body_of($recorder, 1)['thread'], 'the rejected request');

        $replay = body_of($recorder, 2);
        same(['max_tokens', 'messages', 'model', 'system', 'thread'], fields_of($replay), 'the replay is a create request');
        same(['type' => 'create'], $replay['thread'], 'create');
        same(MessageThreads::SYSTEM, $replay['system'], 'system');
        same([
            ['role' => 'user', 'content' => MessageThreads::FIRST_PROMPT],
            ['role' => 'assistant', 'content' => [['type' => 'text', 'text' => 'OK']]],
            ['role' => 'user', 'content' => MessageThreads::SECOND_PROMPT],
        ], $replay['messages'], 'the whole conversation');
    });

    $recorder = scripted(
        json_response(thread_reply('msg_first')),
        thread_error(404, 'not_found_error', 'thread_not_found'),
        thread_error(404, 'not_found_error', 'thread_not_found'),
    );
    [$code, $stdout, $stderr] = with_env([], static fn (): array => run_threads([], SAMPLE_ENV, $recorder));
    same(1, $code, 'a second thread_not_found: exit code');
    same('', $stdout, 'a second thread_not_found: stdout');
    assert(str_starts_with($stderr, 'Error: NotFoundException: '), "a second thread_not_found is reported: $stderr");
    same(3, count($recorder->requests), 'the replay is not repeated');
});

test('message threads: any other 404 is an error and is not replayed', function (): void {
    $cases = [
        'a model that does not exist' => thread_error(404, 'not_found_error', message: 'model: no-such-deployment'),
        'another error code' => thread_error(404, 'not_found_error', 'model_not_found'),
        'thread_not_found in the message only' => thread_error(404, 'not_found_error', message: 'thread_not_found'),
    ];
    foreach ($cases as $label => $notFound) {
        $recorder = scripted(json_response(thread_reply('msg_first')), $notFound);
        [$code, $stdout, $stderr] = with_env([], static fn (): array => run_threads([], SAMPLE_ENV, $recorder));
        same(1, $code, "$label: exit code");
        same('', $stdout, "$label: stdout");
        assert(str_starts_with($stderr, 'Error: NotFoundException: '), "$label: the API error is reported: $stderr");
        same(2, count($recorder->requests), "$label: no replay");
    }
});

test('message threads: a request the API cannot thread fails and is never sent again without a thread', function (): void {
    $unsupported = static fn (): Response => thread_error(400, 'invalid_request_error', 'thread_unsupported_request');
    foreach (['the first turn' => [$unsupported()], 'the second turn' => [json_response(thread_reply('msg_first')), $unsupported()]] as $label => $script) {
        $recorder = scripted(...$script);
        [$code, $stdout, $stderr] = with_env([], static fn (): array => run_threads([], SAMPLE_ENV, $recorder));
        same(1, $code, "$label: exit code");
        same('', $stdout, "$label: stdout");
        assert(str_starts_with($stderr, 'Error: BadRequestException: '), "$label: the API error is reported: $stderr");
        same(count($script), count($recorder->requests), "$label: no further request");
        foreach (array_keys($recorder->requests) as $call) {
            assert(isset(body_of($recorder, $call)['thread']), "$label: request $call carries a thread");
        }
    }
});

test('message threads: a second reply without text is an error, not a silent success', function (): void {
    $thinkingOnly = thread_reply('msg_second');
    $thinkingOnly['content'] = [['type' => 'thinking', 'thinking' => 'not for display', 'signature' => 'sample']];
    foreach (['thinking only' => $thinkingOnly, 'blank text' => thread_reply('msg_second', " \n")] as $label => $second) {
        $recorder = scripted(json_response(thread_reply('msg_first')), json_response($second));
        [$code, $stdout, $stderr] = with_env([], static fn (): array => run_threads([], SAMPLE_ENV, $recorder));
        same(1, $code, "$label: exit code");
        same('', $stdout, "$label: stdout");
        same("Error: No text response (stop_reason=end_turn). Increase max_tokens if the response exhausted its budget.\n", $stderr, "$label: stderr");
    }
});

test('message threads: the entry point sends the configured credential, API version and model on both turns', function (): void {
    $cases = [
        'legacy profile, bearer from the Azure CLI' => [SAMPLE_ENV, 'authorization', 'Bearer entra-test-token', Client::ANTHROPIC_API_VERSION, MODEL],
        'legacy profile, key header and API version' => [
            SAMPLE_ENV + ['AUTH_MODE' => 'api_key', 'CLAUDE_API_KEY' => 'sample-key', 'API_KEY_HEADER' => 'x-api-key', 'ANTHROPIC_API_VERSION' => '2023-06-01'],
            'x-api-key', 'sample-key', '2023-06-01', MODEL,
        ],
        'canonical profile and its own model' => [
            ['ANTHROPIC_BASE_URL' => BASE_URL, 'ANTHROPIC_MODEL' => 'canonical-model', 'AUTH_MODE' => 'api_key', 'ANTHROPIC_API_KEY' => 'sample-key', 'API_KEY_HEADER' => 'x-api-key'],
            'x-api-key', 'sample-key', Client::ANTHROPIC_API_VERSION, 'canonical-model',
        ],
    ];
    foreach ($cases as $label => [$env, $header, $credential, $version, $model]) {
        $recorder = scripted(json_response(thread_reply('msg_first')), json_response(thread_reply('msg_second', 'ORCHID-47')));
        [$code, $stdout, $stderr] = with_env([], static fn (): array => run_threads([], $env, $recorder));
        same(0, $code, "$label: exit code (stderr: $stderr)");
        same("ORCHID-47\n", $stdout, "$label: stdout");
        same('', $stderr, "$label: stderr");
        same(2, count($recorder->requests), "$label: requests");
        foreach ($recorder->requests as $turn => $request) {
            $headers = headers_of($request);
            same($credential, $headers[$header] ?? null, "$label, turn $turn: credential");
            same($version, $headers['anthropic-version'] ?? null, "$label, turn $turn: API version");
            same(THREADS_BETA, $headers['anthropic-beta'] ?? null, "$label, turn $turn: beta");
            same($model, body_of($recorder, $turn)['model'], "$label, turn $turn: model");
            foreach (['authorization', 'x-api-key', 'api-key'] as $other) {
                assert($other === $header || !isset($headers[$other]), "$label, turn $turn: $other must be absent");
            }
        }
        same('continue', body_of($recorder, 1)['thread']['type'], "$label: the second turn continues the thread");
    }
});

test('message threads: a failure shows its cause without any credential', function (): void {
    $request = new Request('POST', BASE_URL.'/v1/messages');
    $cases = [
        'bearer token' => [SAMPLE_ENV, 'entra-test-token'],
        'api key' => [SAMPLE_ENV + ['AUTH_MODE' => 'api_key', 'CLAUDE_API_KEY' => 'sample-key-canary-value'], 'sample-key-canary-value'],
    ];
    foreach ($cases as $label => [$env, $secret]) {
        $recorder = new Recorder(static fn (RequestInterface $sent, int $call): ResponseInterface => 1 === $call
            ? json_response(thread_reply('msg_first'))
            : throw new ConnectException("cURL error 7: refused ($secret)", $request));
        [$code, $stdout, $stderr] = with_env([], static fn (): array => run_threads([], $env, $recorder));
        same(1, $code, "$label: exit code");
        same('', $stdout, "$label: stdout");
        assert(str_starts_with($stderr, "Error: APIConnectionException: Anthropic API Connection Error\n  caused by: ConnectException: cURL error 7: refused ([redacted])"), "$label: the cause is shown: $stderr");
        assert(!str_contains($stderr, $secret), "$label: the credential must not be printed");
        same(4, count($recorder->requests), "$label: the first turn, then the second turn and the SDK's two retries");
    }
});

test('message threads: usage, unknown arguments and configuration errors are reported like main.php', function (): void {
    [$code, $stdout, $stderr] = run_threads(['--help'], []);
    same(0, $code, 'help exit code');
    same("Usage: php message_threads.php\n", $stdout, 'help output');
    same('', $stderr, 'help stderr');

    $recorder = new Recorder();
    [$code, $stdout, $stderr] = run_threads(['--stream'], SAMPLE_ENV, $recorder);
    same(2, $code, 'unknown argument: exit code');
    same('', $stdout, 'unknown argument: stdout');
    same("Unknown argument: --stream\nUsage: php message_threads.php\n", $stderr, 'unknown argument: stderr');
    same(0, count($recorder->requests), 'unknown argument: requests');

    $recorder = new Recorder();
    [$code, $stdout, $stderr] = with_env([], static fn (): array => run_threads([], [], $recorder));
    same(1, $code, 'no endpoint: exit code');
    same('', $stdout, 'no endpoint: stdout');
    same(NO_ENDPOINT."\n", $stderr, 'no endpoint: stderr');
    same(0, count($recorder->requests), 'no endpoint: requests');
});