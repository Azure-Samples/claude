<?php

declare(strict_types=1);

namespace ClaudeSample\Tests;

use Anthropic\Client;
use Anthropic\Core\Exceptions\AnthropicException;
use Anthropic\Core\Exceptions\APIStatusException;
use Anthropic\Core\Exceptions\AuthenticationException;
use Anthropic\Core\Exceptions\InternalServerException;
use Anthropic\Core\Exceptions\PermissionDeniedException;
use Anthropic\Core\Exceptions\RateLimitException;
use Anthropic\Messages\Message;
use Anthropic\Messages\RawContentBlockDeltaEvent;
use Anthropic\Messages\TextDelta;
use ClaudeSample\ClientFactory;
use GuzzleHttp\Client as GuzzleClient;
use GuzzleHttp\Psr7\Response;
use Psr\Http\Message\RequestInterface;

/** @param array<string, mixed> $options named createClient() arguments that replace the defaults */
function make(Recorder $recorder, array $options = []): Client
{
    return ClientFactory::createClient(...[
        'baseUrl' => BASE_URL,
        'tokenProvider' => static fn (): string => 'selected-token',
        'httpClient' => $recorder,
        'maxRetries' => 0,
        ...$options,
    ]);
}

/** @param array<string, mixed> $requestOptions */
function send(Client $client, array $requestOptions = []): Message
{
    return $client->messages->create(
        maxTokens: 32,
        messages: [['role' => 'user', 'content' => 'Hello']],
        model: MODEL,
        requestOptions: [] === $requestOptions ? null : $requestOptions,
    );
}

function authorization_of(RequestInterface $request): string
{
    return headers_of($request)['authorization'] ?? '(none)';
}

test('returns the standard SDK client and resolves the token per request, not at creation', function (): void {
    $calls = 0;
    $recorder = new Recorder();
    $client = make($recorder, ['tokenProvider' => static function () use (&$calls): string {
        return ['first-token', 'second-token'][$calls++];
    }]);
    same(Client::class, get_class($client), 'client class');
    same(0, $calls, 'provider calls at creation');
    same('OK', send($client)->content[0]->text, 'response text');
    send($client);
    same(2, $calls, 'provider calls');
    same(['Bearer first-token', 'Bearer second-token'], array_map(authorization_of(...), $recorder->requests), 'authorization per request');
    foreach ($recorder->requests as $request) {
        $headers = headers_of($request);
        assert(!isset($headers['anthropic-beta']), 'a generic bearer must not carry the OAuth beta');
        assert(!isset($headers['x-api-key']) && !isset($headers['api-key']), 'only one credential header');
        assert(!str_contains(wire_of($request), 'provided-by-request-hook'), 'the suppression placeholder stays off the wire');
    }
});

test('sends the model and the native or Foundry-style path', function (): void {
    $cases = ['https://api.anthropic.com' => '/v1/messages', BASE_URL => '/anthropic/v1/messages'];
    foreach ($cases as $base => $path) {
        $recorder = new Recorder();
        send(make($recorder, ['baseUrl' => $base]));
        same($base.'/v1/messages', (string) $recorder->requests[0]->getUri(), "URL for $base");
        same($path, $recorder->requests[0]->getUri()->getPath(), "path for $base");
        $body = json_decode((string) $recorder->requests[0]->getBody(), true, flags: JSON_THROW_ON_ERROR);
        same(MODEL, $body['model'], 'model');
        same(32, $body['max_tokens'], 'max_tokens');
    }
});

test('ambient credentials, profile, base URL and custom headers cannot reach the wire', function (): void {
    $ambient = [
        'ANTHROPIC_API_KEY' => 'ambient-key-canary',
        'ANTHROPIC_AUTH_TOKEN' => 'ambient-token-canary',
        'ANTHROPIC_PROFILE' => 'nonexistent-profile-canary',
        'ANTHROPIC_BASE_URL' => 'https://wrong.example',
        'ANTHROPIC_CUSTOM_HEADERS' => "Authorization: custom-canary\nx-api-key: key-canary\napi-key: alias-canary",
        'ANTHROPIC_FOUNDRY_RESOURCE' => 'unchanged-cli-resource',
    ];
    with_env($ambient, static function (): void {
        $recorder = new Recorder();
        send(make($recorder), ['extraHeaders' => [
            'Authorization' => 'request-canary',
            'x-api-key' => 'request-key-canary',
            'anthropic-beta' => 'a-requested-beta',
        ]]);
        $request = $recorder->requests[0];
        $headers = headers_of($request);
        same('Bearer selected-token', $headers['authorization'], 'authorization');
        assert(!isset($headers['x-api-key']) && !isset($headers['api-key']), 'no other credential header');
        same('a-requested-beta', $headers['anthropic-beta'], 'the requested beta is preserved and nothing is added');
        same(BASE_URL.'/v1/messages', (string) $request->getUri(), 'the explicit base URL wins over ANTHROPIC_BASE_URL');
        assert(!str_contains(wire_of($request), 'canary'), 'no ambient or per-request canary on the wire');
        same('unchanged-cli-resource', getenv('ANTHROPIC_FOUNDRY_RESOURCE'), 'the factory does not touch the environment');
    });
});

test('control: the same ambient values do reach the wire from an unconfigured SDK client', function (): void {
    with_env([
        'ANTHROPIC_API_KEY' => 'ambient-key-canary',
        'ANTHROPIC_CUSTOM_HEADERS' => "x-api-key: header-canary\napi-key: alias-canary",
    ], static function (): void {
        $recorder = new Recorder();
        send(new Client(baseUrl: BASE_URL, requestOptions: ['transporter' => $recorder, 'maxRetries' => 0]));
        $wire = wire_of($recorder->requests[0]);
        foreach (['ambient-key-canary', 'header-canary', 'alias-canary'] as $canary) {
            assert(str_contains($wire, $canary), "the SDK defaults leak $canary, so the canary test is meaningful");
        }
    });
    with_env(['ANTHROPIC_PROFILE' => 'nonexistent-profile-canary'], static function (): void {
        try {
            new Client(baseUrl: BASE_URL, requestOptions: ['transporter' => new Recorder()]);
        } catch (AnthropicException) {
            ClientFactory::createClient(baseUrl: BASE_URL, apiKey: 'selected-key', httpClient: new Recorder());

            return;
        }
        throw new \AssertionError('the SDK did not look for the profile named by ANTHROPIC_PROFILE');
    });
});

test('API key header is configuration: Authorization by default, any other header name verbatim', function (): void {
    $cases = [
        [BASE_URL, null, 'authorization', 'Bearer selected-key'],
        ['https://api.anthropic.com', 'Authorization', 'authorization', 'Bearer selected-key'],
        [BASE_URL, 'x-api-key', 'x-api-key', 'selected-key'],
        [BASE_URL, 'api-key', 'api-key', 'selected-key'],
    ];
    foreach ($cases as [$base, $header, $name, $expected]) {
        $recorder = new Recorder();
        $options = ['baseUrl' => $base, 'tokenProvider' => null, 'apiKey' => 'selected-key'];
        send(make($recorder, null === $header ? $options : $options + ['keyHeader' => $header]));
        $headers = headers_of($recorder->requests[0]);
        same($expected, $headers[$name] ?? null, "$name for ".($header ?? 'the default header'));
        foreach (['authorization', 'x-api-key', 'api-key'] as $other) {
            assert($other === $name || !isset($headers[$other]), "$other must be absent");
        }
        assert(!isset($headers['anthropic-beta']), 'no OAuth beta');
        assert(!str_contains(wire_of($recorder->requests[0]), 'provided-by-request-hook'), 'placeholder stays off the wire');
    }
});

test('anthropic-version is the SDK default unless configured', function (): void {
    $recorder = new Recorder();
    send(make($recorder));
    same(Client::ANTHROPIC_API_VERSION, headers_of($recorder->requests[0])['anthropic-version'], 'default version');

    $recorder = new Recorder();
    send(make($recorder, ['apiVersion' => '2023-06-01']), ['extraHeaders' => ['anthropic-version' => 'request-version']]);
    same('2023-06-01', headers_of($recorder->requests[0])['anthropic-version'], 'configured version');
});

test('invalid configuration fails before any network use', function (): void {
    $invalid = [
        'neither credential' => ['tokenProvider' => null],
        'both credentials' => ['apiKey' => 'key'],
        'plain HTTP' => ['baseUrl' => 'http://insecure.example'],
        'credentials in the URL' => ['baseUrl' => 'https://user:secret@example.com'],
        'query in the URL' => ['baseUrl' => BASE_URL.'?x=1'],
        'fragment in the URL' => ['baseUrl' => BASE_URL.'#x'],
        'unsupported scheme' => ['baseUrl' => 'ftp://example.com'],
        'no host' => ['baseUrl' => 'https://'],
        'empty URL' => ['baseUrl' => ''],
        'empty key' => ['tokenProvider' => null, 'apiKey' => ''],
        'multi-line key' => ['tokenProvider' => null, 'apiKey' => "key\nvalue"],
        'spaced key' => ['tokenProvider' => null, 'apiKey' => 'key value'],
        'bad header name' => ['tokenProvider' => null, 'apiKey' => 'key', 'keyHeader' => "bad\nheader"],
        'empty header name' => ['tokenProvider' => null, 'apiKey' => 'key', 'keyHeader' => ''],
        'bad version' => ['apiVersion' => "2023\n06"],
    ];
    foreach ($invalid as $label => $options) {
        $recorder = new Recorder();
        try {
            make($recorder, $options);
        } catch (\InvalidArgumentException) {
            same(0, count($recorder->requests), "$label sent a request");

            continue;
        }
        throw new \AssertionError("$label was accepted");
    }
    foreach (['http://127.0.0.1:8080', 'http://localhost', 'http://[::1]:8080', 'https://example.com:8443/anthropic'] as $accepted) {
        make(new Recorder(), ['baseUrl' => $accepted]);
    }
});

test('a same-origin redirect is followed and re-authorized', function (): void {
    $issued = 0;
    $recorder = new Recorder(static fn (RequestInterface $request, int $call): Response => 1 === $call
        ? new Response(307, ['Location' => '/anthropic/v1/messages-moved'])
        : json_response(message_body()));
    send(make($recorder, ['tokenProvider' => static function () use (&$issued): string {
        return 'token-'.(++$issued);
    }]));
    same(['Bearer token-1', 'Bearer token-2'], array_map(authorization_of(...), $recorder->requests), 'authorization per hop');
    same('/anthropic/v1/messages-moved', $recorder->requests[1]->getUri()->getPath(), 'redirect target');
});

test('a cross-origin redirect is refused before any credential is produced or sent', function (): void {
    $targets = [
        'https://untrusted.example/v1/messages',
        'http://example.services.ai.azure.com/anthropic/v1/messages',
        'https://example.services.ai.azure.com:8443/anthropic/v1/messages',
    ];
    foreach ($targets as $target) {
        $issued = 0;
        $recorder = new Recorder(static fn (): Response => new Response(302, ['Location' => $target]));
        $client = make($recorder, ['tokenProvider' => static function () use (&$issued): string {
            return 'token-'.(++$issued);
        }]);
        try {
            send($client);
        } catch (\RuntimeException $error) {
            same('Refusing to send credentials to a different origin.', $error->getMessage(), 'message');
            same(1, count($recorder->requests), "only the original origin is contacted for $target");
            same(1, $issued, "no token is produced for the refused hop to $target");

            continue;
        }
        throw new \AssertionError("redirect to $target was followed");
    }
});

test('a provider failure surfaces unchanged and no request is sent', function (): void {
    $failure = new \RuntimeException('credential unavailable');
    $recorder = new Recorder();
    $client = make($recorder, ['tokenProvider' => static function () use ($failure): string {
        throw $failure;
    }]);
    try {
        send($client);
    } catch (\RuntimeException $caught) {
        same($failure, $caught, 'exception');
        same(0, count($recorder->requests), 'requests');

        return;
    }
    throw new \AssertionError('the provider failure was swallowed');
});

test('a token that is empty, multi-line or not a string is rejected without being echoed', function (): void {
    foreach (['', "line\nbreak", 'has space', 42, null] as $bad) {
        $recorder = new Recorder();
        $client = make($recorder, ['tokenProvider' => static fn () => $bad]);
        try {
            send($client);
        } catch (\RuntimeException $error) {
            same('The token provider must return a non-empty string without whitespace or control characters.', $error->getMessage(), 'message');
            same(0, count($recorder->requests), 'requests');

            continue;
        }
        throw new \AssertionError('an invalid token was sent');
    }
});

test('HTTP error statuses surface as SDK exceptions that do not contain the credential', function (): void {
    $expected = [
        401 => AuthenticationException::class,
        403 => PermissionDeniedException::class,
        429 => RateLimitException::class,
        500 => InternalServerException::class,
    ];
    foreach ($expected as $status => $class) {
        $recorder = new Recorder(static fn (): Response => json_response(
            ['type' => 'error', 'error' => ['type' => 'api_error', 'message' => 'test failure']],
            $status,
        ));
        try {
            send(make($recorder));
        } catch (APIStatusException $error) {
            same($class, get_class($error), "exception class for $status");
            same($status, $error->status, 'status');
            assert(!str_contains($error->getMessage(), 'selected-token'), 'the credential must not appear in the error');

            continue;
        }
        throw new \AssertionError("status $status was reported as success");
    }
});

test('an SDK retry acquires a fresh token', function (): void {
    $issued = 0;
    $recorder = new Recorder(static fn (RequestInterface $request, int $call): Response => 1 === $call
        ? json_response(['type' => 'error', 'error' => ['type' => 'api_error', 'message' => 'try again']], 500, ['retry-after-ms' => '1'])
        : json_response(message_body()));
    send(make($recorder, ['maxRetries' => 1, 'tokenProvider' => static function () use (&$issued): string {
        return 'token-'.(++$issued);
    }]));
    same(['Bearer token-1', 'Bearer token-2'], array_map(authorization_of(...), $recorder->requests), 'authorization per attempt');
});

test('streaming goes through the same credential hook', function (): void {
    $recorder = new Recorder(static fn (): Response => sse_response(['Hel', 'lo']));
    $text = '';
    $events = make($recorder)->messages->createStream(maxTokens: 32, messages: [['role' => 'user', 'content' => 'Hello']], model: MODEL);
    foreach ($events as $event) {
        if ($event instanceof RawContentBlockDeltaEvent && $event->delta instanceof TextDelta) {
            $text .= $event->delta->text;
        }
    }
    same('Hello', $text, 'streamed text');
    $headers = headers_of($recorder->requests[0]);
    same('Bearer selected-token', $headers['authorization'], 'authorization');
    assert(str_contains($headers['accept'], 'text/event-stream'), 'a streaming request');
    assert(!isset($headers['anthropic-beta']), 'no OAuth beta');
});

test('the default transport keeps the SDK timeout unless one is given, and does not follow redirects', function (): void {
    foreach ([[null, 600.0], [30.0, 30.0]] as [$requested, $expected]) {
        $http = null === $requested ? ClientFactory::defaultHttpClient() : ClientFactory::defaultHttpClient($requested);
        assert($http instanceof GuzzleClient, 'the default transport is Guzzle');
        $config = (new \ReflectionProperty(GuzzleClient::class, 'config'))->getValue($http);
        same($expected, $config['timeout'], 'timeout');
        same($expected, $config['connect_timeout'], 'connect timeout');
        same(false, $config['allow_redirects'], 'allow_redirects');
        same(false, $config['http_errors'], 'http_errors');
    }
});
