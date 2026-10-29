<?php

declare(strict_types=1);

namespace ClaudeSample\Tests;

use Anthropic\Client;
use Anthropic\Core\BaseClient;
use Anthropic\Core\Exceptions\APIConnectionException;
use ClaudeSample\ClientFactory;
use ClaudeSample\Sample;
use GuzzleHttp\Client as GuzzleClient;
use GuzzleHttp\Exception\ConnectException;
use GuzzleHttp\Psr7\Request;
use GuzzleHttp\Psr7\Response;

const SAMPLE_ENV = ['CLAUDE_BASE_URL' => BASE_URL, 'CLAUDE_DEPLOYMENT_NAME' => MODEL];
const CANONICAL_ENV = ['ANTHROPIC_BASE_URL' => BASE_URL, 'ANTHROPIC_MODEL' => MODEL];
const NO_ENDPOINT = 'Error: Set CLAUDE_BASE_URL and CLAUDE_DEPLOYMENT_NAME, or ANTHROPIC_BASE_URL and ANTHROPIC_MODEL. The two sets are never mixed.';
const LEGACY_NEEDS_MODEL = 'Error: CLAUDE_BASE_URL selects the CLAUDE_* settings: also set CLAUDE_DEPLOYMENT_NAME (ANTHROPIC_MODEL is not used with it).';
const CANONICAL_NEEDS_MODEL = 'Error: ANTHROPIC_BASE_URL selects the ANTHROPIC_* settings: also set ANTHROPIC_MODEL (CLAUDE_DEPLOYMENT_NAME is not used with it).';
const LEGACY_NEEDS_KEY = 'Error: Set CLAUDE_API_KEY (ANTHROPIC_API_KEY is not used with CLAUDE_BASE_URL).';
const CANONICAL_NEEDS_KEY = 'Error: Set ANTHROPIC_API_KEY (CLAUDE_API_KEY is not used with ANTHROPIC_BASE_URL).';
const CANONICAL_NEEDS_MODE = 'Error: ANTHROPIC_BASE_URL selects the ANTHROPIC_* settings and requires an explicit AUTH_MODE: set AUTH_MODE=api_key (uses ANTHROPIC_API_KEY) or AUTH_MODE=bearer (uses an Azure CLI token).';

/**
 * @param list<string> $arguments
 * @param array<string, string> $env
 *
 * @return array{int, string, string} exit code, stdout, stderr
 */
function run_sample(array $arguments, array $env, ?Recorder $recorder = null, ?\Closure $cli = null): array
{
    $stdout = fopen('php://memory', 'w+');
    $stderr = fopen('php://memory', 'w+');
    $code = Sample::run($arguments, $env, $stdout, $stderr, $recorder, $cli ?? static fn (): array => [0, '{"accessToken":"entra-test-token"}']);
    rewind($stdout);
    rewind($stderr);

    return [$code, (string) stream_get_contents($stdout), (string) stream_get_contents($stderr)];
}

/** @return array<string, mixed> a response that holds a thinking block ahead of the text */
function thinking_then_text(): array
{
    $body = message_body('OK');
    array_unshift($body['content'], ['type' => 'thinking', 'thinking' => 'not for display', 'signature' => 'sample']);

    return $body;
}

/** @return array<string, mixed> the configuration of the Guzzle transport behind a client */
function transport_config(Client $client): array
{
    $options = (new \ReflectionProperty(BaseClient::class, 'options'))->getValue($client);

    return (new \ReflectionProperty(GuzzleClient::class, 'config'))->getValue($options->transporter);
}

test('the one-shot sample prints the text and usage, never the thinking, and sends one bearer request', function (): void {
    $recorder = new Recorder(static fn (): Response => json_response(thinking_then_text()));
    [$code, $stdout, $stderr] = with_env([], static fn (): array => run_sample([], SAMPLE_ENV, $recorder));
    same(0, $code, "exit code (stderr: $stderr)");
    same("OK\n\n[usage] input=1 output=2\n", $stdout, 'stdout');
    same('', $stderr, 'stderr');
    same(1, count($recorder->requests), 'requests');
    $request = $recorder->requests[0];
    $headers = headers_of($request);
    same('/anthropic/v1/messages', $request->getUri()->getPath(), 'path');
    same('Bearer entra-test-token', $headers['authorization'], 'authorization');
    same(Client::ANTHROPIC_API_VERSION, $headers['anthropic-version'], 'the SDK default API version');
    assert(!isset($headers['anthropic-beta']) && !isset($headers['x-api-key']) && !isset($headers['api-key']), 'bearer only, no OAuth beta');
    $body = json_decode((string) $request->getBody(), true, flags: JSON_THROW_ON_ERROR);
    same(MODEL, $body['model'], 'model');
    same(1024, $body['max_tokens'], 'max_tokens');
    same(Sample::PROMPT, $body['messages'][0]['content'], 'prompt');
});

test('--stream prints the text as it arrives, then usage', function (): void {
    $recorder = new Recorder(static fn (): Response => sse_response(['Seattle has ', 'the Space Needle.'], 11, 13));
    [$code, $stdout, $stderr] = with_env([], static fn (): array => run_sample(['--stream'], SAMPLE_ENV, $recorder));
    same(0, $code, "exit code (stderr: $stderr)");
    same("Seattle has the Space Needle.\n\n[usage] input=11 output=13\n", $stdout, 'stdout');
    $headers = headers_of($recorder->requests[0]);
    same('Bearer entra-test-token', $headers['authorization'], 'authorization');
    assert(str_contains($headers['accept'], 'text/event-stream'), 'a streaming request');
    assert(!isset($headers['anthropic-beta']), 'no OAuth beta');
});

test('API key mode: Authorization by default, API_KEY_HEADER and ANTHROPIC_API_VERSION are optional overrides', function (): void {
    $legacy = SAMPLE_ENV + ['AUTH_MODE' => 'api_key', 'CLAUDE_API_KEY' => 'sample-key'];
    $canonical = CANONICAL_ENV + ['AUTH_MODE' => 'api_key', 'ANTHROPIC_API_KEY' => 'sample-key'];
    $cases = [
        ['legacy: default header', $legacy, 'authorization', 'Bearer sample-key', Client::ANTHROPIC_API_VERSION],
        ['legacy: resource key header', $legacy + ['API_KEY_HEADER' => 'x-api-key'], 'x-api-key', 'sample-key', Client::ANTHROPIC_API_VERSION],
        ['legacy: explicit version', $legacy + ['ANTHROPIC_API_VERSION' => '2023-06-01'], 'authorization', 'Bearer sample-key', '2023-06-01'],
        ['canonical: explicit api_key', $canonical, 'authorization', 'Bearer sample-key', Client::ANTHROPIC_API_VERSION],
        ['canonical: explicit api_key, resource key header', $canonical + ['API_KEY_HEADER' => 'x-api-key'], 'x-api-key', 'sample-key', Client::ANTHROPIC_API_VERSION],
    ];
    foreach ($cases as [$label, $env, $header, $expected, $version]) {
        $recorder = new Recorder();
        $cliCalls = 0;
        [$code, , $stderr] = with_env([], static function () use ($env, $recorder, &$cliCalls): array {
            return run_sample([], $env, $recorder, static function () use (&$cliCalls): array {
                ++$cliCalls;

                return [1, ''];
            });
        });
        same(0, $code, "$label exit code (stderr: $stderr)");
        $headers = headers_of($recorder->requests[0]);
        same($expected, $headers[$header] ?? null, "$label header");
        same($version, $headers['anthropic-version'], "$label version");
        same(0, $cliCalls, "$label must not start the Azure CLI");
        foreach (['authorization', 'x-api-key', 'api-key'] as $other) {
            assert($other === $header || !isset($headers[$other]), "$label: $other must be absent");
        }
    }
});

test('canonical profile (ANTHROPIC_BASE_URL): AUTH_MODE is explicit, and only ANTHROPIC_* values are used', function (): void {
    $recorder = new Recorder();
    $seen = [];
    $env = [
        'ANTHROPIC_BASE_URL' => 'https://other.services.ai.azure.com/anthropic', 'ANTHROPIC_MODEL' => 'preferred-model',
        'AUTH_MODE' => 'bearer', 'TOKEN_SCOPE' => 'api://example/.default', 'AZURE_TENANT_ID' => 'tenant-1.example',
        'CLAUDE_BASE_URL' => 'https://legacy-canary.example/anthropic', 'CLAUDE_DEPLOYMENT_NAME' => 'legacy-model-canary', 'CLAUDE_API_KEY' => 'legacy-key-canary',
    ];
    [$code, , $stderr] = with_env([], static function () use ($env, $recorder, &$seen): array {
        return run_sample([], $env, $recorder, static function (array $arguments) use (&$seen): array {
            $seen = $arguments;

            return [0, '{"accessToken":"entra-test-token"}'];
        });
    });
    same(0, $code, "exit code (stderr: $stderr)");
    same('other.services.ai.azure.com', $recorder->requests[0]->getUri()->getHost(), 'host');
    same('preferred-model', json_decode((string) $recorder->requests[0]->getBody(), true, flags: JSON_THROW_ON_ERROR)['model'], 'model');
    same('Bearer entra-test-token', headers_of($recorder->requests[0])['authorization'], 'authorization');
    same(['account', 'get-access-token', '--scope', 'api://example/.default', '--output', 'json', '--tenant', 'tenant-1.example'], $seen, 'CLI arguments');
    assert(!str_contains(wire_of($recorder->requests[0]), 'canary'), 'no legacy value on the wire');
});

test('mixed families: neither profile ever borrows a model or key from the other', function (): void {
    $ambientAnthropic = ['ANTHROPIC_API_KEY' => 'ambient-anthropic-key-canary', 'ANTHROPIC_MODEL' => 'ambient-model-canary', 'ANTHROPIC_AUTH_TOKEN' => 'ambient-token-canary'];
    $legacyDecoys = ['CLAUDE_BASE_URL' => 'https://legacy-canary.example/anthropic', 'CLAUDE_DEPLOYMENT_NAME' => 'legacy-model-canary', 'CLAUDE_API_KEY' => 'legacy-key-canary'];

    $success = [
        'legacy profile with ambient ANTHROPIC_* values' => [
            SAMPLE_ENV + ['AUTH_MODE' => 'api_key', 'CLAUDE_API_KEY' => 'legacy-selected-key'] + $ambientAnthropic,
            'Bearer legacy-selected-key', MODEL,
        ],
        'canonical profile with every legacy decoy present' => [
            CANONICAL_ENV + ['AUTH_MODE' => 'api_key', 'ANTHROPIC_API_KEY' => 'canonical-selected-key'] + $legacyDecoys,
            'Bearer canonical-selected-key', MODEL,
        ],
        'both URLs set: the explicit canonical profile wins' => [
            ['ANTHROPIC_BASE_URL' => BASE_URL, 'ANTHROPIC_MODEL' => 'canonical-model', 'AUTH_MODE' => 'api_key', 'ANTHROPIC_API_KEY' => 'canonical-selected-key'] + $legacyDecoys,
            'Bearer canonical-selected-key', 'canonical-model',
        ],
    ];
    foreach ($success as $label => [$env, $authorization, $model]) {
        $recorder = new Recorder();
        [$code, , $stderr] = with_env([], static fn (): array => run_sample([], $env, $recorder));
        same(0, $code, "$label: exit code (stderr: $stderr)");
        same($authorization, headers_of($recorder->requests[0])['authorization'], "$label: authorization");
        same($model, json_decode((string) $recorder->requests[0]->getBody(), true, flags: JSON_THROW_ON_ERROR)['model'], "$label: model");
        same('example.services.ai.azure.com', $recorder->requests[0]->getUri()->getHost(), "$label: host");
        assert(!str_contains(wire_of($recorder->requests[0]), 'canary'), "$label: a decoy reached the wire");
    }

    $refused = [
        'ambient native endpoint and model never get an Azure token' => [CANONICAL_ENV + ['AZURE_TENANT_ID' => 'tenant-1.example'], CANONICAL_NEEDS_MODE],
        'canonical api_key never falls back to CLAUDE_API_KEY' => [CANONICAL_ENV + ['AUTH_MODE' => 'api_key', 'CLAUDE_API_KEY' => 'legacy-key-canary'], CANONICAL_NEEDS_KEY],
        'canonical model never falls back to CLAUDE_DEPLOYMENT_NAME' => [['ANTHROPIC_BASE_URL' => BASE_URL, 'ANTHROPIC_API_KEY' => 'k'] + $legacyDecoys, CANONICAL_NEEDS_MODEL],
        'legacy api_key never falls back to ANTHROPIC_API_KEY' => [SAMPLE_ENV + ['AUTH_MODE' => 'api_key', 'ANTHROPIC_API_KEY' => 'ambient-anthropic-key-canary'], LEGACY_NEEDS_KEY],
        'legacy model never falls back to ANTHROPIC_MODEL' => [['CLAUDE_BASE_URL' => BASE_URL] + $ambientAnthropic, LEGACY_NEEDS_MODEL],
    ];
    foreach ($refused as $label => [$env, $expected]) {
        $recorder = new Recorder();
        $cliCalls = 0;
        [$code, $stdout, $stderr] = with_env([], static function () use ($env, $recorder, &$cliCalls): array {
            return run_sample([], $env, $recorder, static function () use (&$cliCalls): array {
                ++$cliCalls;

                return [0, '{"accessToken":"entra-test-token"}'];
            });
        });
        same(1, $code, "$label: exit code");
        same($expected."\n", $stderr, "$label: stderr");
        same('', $stdout, "$label: stdout");
        same(0, count($recorder->requests), "$label: requests");
        same(0, $cliCalls, "$label: the Azure CLI must not start");
    }
});

test('missing-mode canary: the canonical profile without AUTH_MODE sends neither the native key nor an Azure token', function (): void {
    $ambient = [
        'ANTHROPIC_API_KEY' => 'ambient-anthropic-key-canary', 'AZURE_TENANT_ID' => 'tenant-1.example', 'TOKEN_SCOPE' => 'api://example/.default',
        'CLAUDE_BASE_URL' => 'https://legacy-canary.example/anthropic', 'CLAUDE_DEPLOYMENT_NAME' => 'legacy-model-canary', 'CLAUDE_API_KEY' => 'legacy-key-canary',
    ];
    foreach ([CANONICAL_ENV + $ambient, CANONICAL_ENV + ['AUTH_MODE' => ''] + $ambient] as $env) {
        $recorder = new Recorder();
        $cliCalls = 0;
        [$code, $stdout, $stderr] = with_env($ambient, static function () use ($env, $recorder, &$cliCalls): array {
            return run_sample([], $env, $recorder, static function () use (&$cliCalls): array {
                ++$cliCalls;

                return [0, '{"accessToken":"entra-test-token"}'];
            });
        });
        same(1, $code, 'exit code');
        same(CANONICAL_NEEDS_MODE."\n", $stderr, 'stderr');
        same('', $stdout, 'stdout');
        same(0, count($recorder->requests), 'no request, so no native key and no Azure token left the process');
        same(0, $cliCalls, 'the Azure CLI must not start');
        assert(!str_contains($stderr.$stdout, 'canary'), 'the error must not echo any ambient value');
    }
});

test('configuration errors exit 1 with a clear message and make no request', function (): void {
    $cases = [
        'no endpoint at all' => [[], NO_ENDPOINT],
        'a legacy model alone is not an endpoint' => [['CLAUDE_DEPLOYMENT_NAME' => MODEL], NO_ENDPOINT],
        'a canonical model alone is not an endpoint' => [['ANTHROPIC_MODEL' => MODEL], NO_ENDPOINT],
        'legacy endpoint without its model' => [['CLAUDE_BASE_URL' => BASE_URL], LEGACY_NEEDS_MODEL],
        'canonical endpoint without its model' => [['ANTHROPIC_BASE_URL' => BASE_URL], CANONICAL_NEEDS_MODEL],
        'unknown mode' => [SAMPLE_ENV + ['AUTH_MODE' => 'oauth'], 'Error: AUTH_MODE must be bearer or api_key.'],
        'legacy key mode without a key' => [SAMPLE_ENV + ['AUTH_MODE' => 'api_key'], LEGACY_NEEDS_KEY],
        'canonical endpoint without AUTH_MODE' => [CANONICAL_ENV, CANONICAL_NEEDS_MODE],
        'canonical api_key without a key' => [CANONICAL_ENV + ['AUTH_MODE' => 'api_key'], CANONICAL_NEEDS_KEY],
        'plain HTTP endpoint' => [['CLAUDE_BASE_URL' => 'http://insecure.example', 'CLAUDE_DEPLOYMENT_NAME' => MODEL], 'Error: baseUrl must be an HTTPS URL without credentials, query, or fragment.'],
        'unsafe scope' => [SAMPLE_ENV + ['TOKEN_SCOPE' => 'x&y'], 'Error: The token scope may only contain letters, digits and the characters . _ : / -'],
    ];
    foreach ($cases as $label => [$env, $expected]) {
        $recorder = new Recorder();
        [$code, $stdout, $stderr] = with_env([], static fn (): array => run_sample([], $env, $recorder));
        same(1, $code, "$label exit code");
        same($expected."\n", $stderr, "$label stderr");
        same('', $stdout, "$label stdout");
        same(0, count($recorder->requests), "$label requests");
    }
});

test('AZURE_TOKEN_CREDENTIALS: AzureCliCredential is accepted, any other explicit choice is refused, and key mode ignores it', function (): void {
    foreach ([null, 'AzureCliCredential'] as $selector) {
        $recorder = new Recorder();
        $cliCalls = 0;
        $env = SAMPLE_ENV + (null === $selector ? [] : ['AZURE_TOKEN_CREDENTIALS' => $selector]);
        [$code, , $stderr] = with_env([], static function () use ($env, $recorder, &$cliCalls): array {
            return run_sample([], $env, $recorder, static function () use (&$cliCalls): array {
                ++$cliCalls;

                return [0, '{"accessToken":"entra-test-token"}'];
            });
        });
        same(0, $code, 'accepted selector '.var_export($selector, true)." (stderr: $stderr)");
        same(1, $cliCalls, 'the Azure CLI supplies the token');
    }

    $message = static fn (string $shown): string => "Error: AZURE_TOKEN_CREDENTIALS=$shown is not supported: the Azure CLI (AzureCliCredential) is this sample's only built-in token source. Unset it, or pass your own token provider to ClientFactory for other credentials.\n";
    $refused = [
        'ManagedIdentityCredential' => 'ManagedIdentityCredential', 'AzureDeveloperCliCredential' => 'AzureDeveloperCliCredential',
        'DefaultAzureCredential' => 'DefaultAzureCredential', 'WorkloadIdentityCredential' => 'WorkloadIdentityCredential',
        'azureclicredential' => 'azureclicredential', "Azure\nCliCredential" => '(unprintable or too long)',
    ];
    foreach ($refused as $selector => $shown) {
        $recorder = new Recorder();
        $cliCalls = 0;
        $env = SAMPLE_ENV + ['AZURE_TOKEN_CREDENTIALS' => (string) $selector];
        [$code, $stdout, $stderr] = with_env([], static function () use ($env, $recorder, &$cliCalls): array {
            return run_sample([], $env, $recorder, static function () use (&$cliCalls): array {
                ++$cliCalls;

                return [0, '{"accessToken":"entra-test-token"}'];
            });
        });
        same(1, $code, "$shown: exit code");
        same($message($shown), $stderr, "$shown: stderr");
        same('', $stdout, "$shown: stdout");
        same(0, $cliCalls, "$shown: the Azure CLI must not start");
        same(0, count($recorder->requests), "$shown: requests");
    }

    $recorder = new Recorder();
    [$code, , $stderr] = with_env([], static fn (): array => run_sample([], SAMPLE_ENV + ['AUTH_MODE' => 'api_key', 'CLAUDE_API_KEY' => 'sample-key', 'AZURE_TOKEN_CREDENTIALS' => 'ManagedIdentityCredential'], $recorder));
    same(0, $code, "key mode ignores the selector (stderr: $stderr)");
});

test('the sample sets its own 120 second timeout; the factory itself keeps the SDK default', function (): void {
    same(120.0, Sample::REQUEST_TIMEOUT_SECONDS, 'policy constant');
    [$client] = with_env([], static fn (): array => Sample::configure(SAMPLE_ENV, null, static fn (): array => [0, '{"accessToken":"entra-test-token"}']));
    same(120.0, transport_config($client)['timeout'], 'timeout of the sample client');
    same(false, transport_config($client)['allow_redirects'], 'redirects are not followed');
    same(600.0, transport_config(ClientFactory::createClient(baseUrl: BASE_URL, apiKey: 'sample-key'))['timeout'], 'timeout of a factory client');
});

test('a response without text (thinking only) is an error, not a silent success', function (): void {
    $thinkingOnly = message_body();
    $thinkingOnly['content'] = [['type' => 'thinking', 'thinking' => 'not for display', 'signature' => 'sample']];
    $recorder = new Recorder(static fn (): Response => json_response($thinkingOnly));
    [$code, $stdout, $stderr] = with_env([], static fn (): array => run_sample([], SAMPLE_ENV, $recorder));
    same(1, $code, 'exit code');
    same('', $stdout, 'stdout');
    same("Error: No text response (stop_reason=end_turn). Increase max_tokens if the response exhausted its budget.\n", $stderr, 'stderr');

    $events = [
        ['message_start', ['type' => 'message_start', 'message' => ['id' => 'm', 'type' => 'message', 'role' => 'assistant', 'model' => MODEL, 'content' => [], 'stop_reason' => null, 'stop_sequence' => null, 'usage' => ['input_tokens' => 1, 'output_tokens' => 1]]]],
        ['content_block_start', ['type' => 'content_block_start', 'index' => 0, 'content_block' => ['type' => 'thinking', 'thinking' => '', 'signature' => '']]],
        ['content_block_delta', ['type' => 'content_block_delta', 'index' => 0, 'delta' => ['type' => 'thinking_delta', 'thinking' => 'hidden']]],
        ['content_block_stop', ['type' => 'content_block_stop', 'index' => 0]],
        ['message_delta', ['type' => 'message_delta', 'delta' => ['stop_reason' => 'max_tokens', 'stop_sequence' => null], 'usage' => ['output_tokens' => 9]]],
        ['message_stop', ['type' => 'message_stop']],
    ];
    $body = '';
    foreach ($events as [$type, $payload]) {
        $body .= "event: $type\ndata: ".json_encode($payload)."\n\n";
    }
    $recorder = new Recorder(static fn (): Response => new Response(200, ['Content-Type' => 'text/event-stream'], $body));
    [$code, $stdout, $stderr] = with_env([], static fn (): array => run_sample(['--stream'], SAMPLE_ENV, $recorder));
    same(1, $code, 'stream exit code');
    same('', $stdout, 'stream stdout');
    same("Error: No text response (stop_reason=max_tokens). Increase max_tokens if the response exhausted its budget.\n", $stderr, 'stream stderr');
});

test('real API and credential failures exit 1 and never print the token', function (): void {
    $recorder = new Recorder(static fn (): Response => json_response(['type' => 'error', 'error' => ['type' => 'authentication_error', 'message' => 'invalid credential']], 401));
    [$code, $stdout, $stderr] = with_env([], static fn (): array => run_sample([], SAMPLE_ENV, $recorder));
    same(1, $code, 'exit code');
    same('', $stdout, 'stdout');
    assert(str_starts_with($stderr, 'Error: AuthenticationException: '), 'the SDK exception is named');
    assert(str_contains($stderr, '401') && str_contains($stderr, 'invalid credential'), 'the service error is reported');
    assert(!str_contains($stderr, 'entra-test-token'), 'the token must not be printed');

    $recorder = new Recorder(static fn (): Response => json_response(['type' => 'error', 'error' => ['type' => 'api_error', 'message' => 'overloaded']], 500));
    [$code, , $stderr] = with_env([], static fn (): array => run_sample(['--stream'], SAMPLE_ENV, $recorder));
    same(1, $code, 'stream exit code');
    assert(str_starts_with($stderr, 'Error: InternalServerException: '), 'the streaming error is reported too');

    $recorder = new Recorder();
    [$code, $stdout, $stderr] = with_env([], static fn (): array => run_sample([], SAMPLE_ENV, $recorder, static fn (): array => [1, '{"accessToken":"never-printed-token"}']));
    same(1, $code, 'CLI failure exit code');
    same('', $stdout, 'CLI failure stdout');
    same("Error: Azure CLI exited with code 1 while requesting a token for scope https://ai.azure.com/.default. Run \"az login\" and retry, or supply your own token provider.\n", $stderr, 'CLI failure stderr');
    same(0, count($recorder->requests), 'no request without a token');
});

test('a connection failure shows its cause, so a certificate problem is visible and comes with a hint', function (): void {
    $request = new Request('POST', BASE_URL.'/v1/messages');
    $curl = 'cURL error 60: SSL certificate problem: unable to get local issuer certificate (see https://curl.haxx.se/libcurl/c/libcurl-errors.html) for '.BASE_URL.'/v1/messages';
    $lines = explode("\n", rtrim(Sample::describeError(new APIConnectionException($request, new ConnectException($curl, $request))), "\n"));
    same(3, count($lines), 'the error, its cause and the hint');
    same('Error: APIConnectionException: Anthropic API Connection Error', $lines[0], 'top-level line');
    same("  caused by: ConnectException: $curl", $lines[1], 'the transport error');
    assert(str_starts_with($lines[2], 'Hint: ') && str_contains($lines[2], 'curl.cainfo') && str_contains($lines[2], 'openssl.cafile') && str_contains($lines[2], 'README'), 'the hint names both settings and the README');
    assert(!str_contains(strtolower($lines[2]), 'disable'), 'the hint never suggests switching verification off');

    $refused = new ConnectException('cURL error 7: Failed to connect to localhost port 8 after 2 ms: Could not connect to server (see https://curl.haxx.se/libcurl/c/libcurl-errors.html)', $request);
    $text = Sample::describeError(new APIConnectionException($request, $refused));
    assert(str_contains($text, '  caused by: ConnectException: cURL error 7: Failed to connect to localhost port 8 after 2 ms'), 'other causes are shown unchanged');
    assert(!str_contains($text, 'Hint:') && !str_contains($text, '[redacted]'), 'no hint and no redaction for an ordinary failure');
    assert(str_contains(Sample::describeError(new \RuntimeException('failed', 0, new ConnectException('cURL error 77: error setting certificate file: nowhere.pem', $request))), 'Hint: '), 'an unusable CA file gets the hint too');
});

test('error output never contains credentials: exact values, headers, bearer tokens, JWTs, URL userinfo and queries are redacted', function (): void {
    $jwt = 'eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJzYW1wbGUifQ.c2lnbmF0dXJlLXNhbXBsZQ';
    $cases = [
        'Authorization: Bearer opaque-bearer-canary' => ['opaque-bearer-canary'],
        'sent x-api-key: header-key-canary' => ['header-key-canary'],
        'sent api-key=alias-key-canary' => ['alias-key-canary'],
        'Proxy-Authorization: Basic cHJveHktY2FuYXJ5' => ['cHJveHktY2FuYXJ5'],
        'Cookie: session=cookie-canary; theme=dark' => ['cookie-canary'],
        'a loose Bearer loose-bearer-canary here' => ['loose-bearer-canary'],
        "token $jwt in the middle" => [$jwt, 'eyJzdWIi'],
        'key sk-ant-api03-key-canary-123456 rejected' => ['key-canary-123456'],
        'https://user-canary:pass-canary@example.test/a?sig=query-canary#frag-canary' => ['user-canary', 'pass-canary', 'query-canary', 'frag-canary'],
        'the configured exact-secret-canary and the issued issued-token-canary' => ['exact-secret-canary', 'issued-token-canary'],
    ];
    $request = new Request('POST', BASE_URL.'/v1/messages');
    foreach ($cases as $message => $forbidden) {
        $text = Sample::describeError(new APIConnectionException($request, new ConnectException($message, $request)), ['exact-secret-canary', 'issued-token-canary']);
        foreach ($forbidden as $value) {
            assert(!str_contains($text, $value), "'$value' leaked from: $message");
        }
        assert(str_contains($text, '[redacted]'), "nothing was redacted in: $message");
    }
    same("Error: Authorization: [redacted]\n", Sample::describeError(new \RuntimeException('Authorization: Bearer top-level-canary')), 'the top-level message is redacted too');
    same("Error: the key is k\n", Sample::describeError(new \RuntimeException('the key is k'), ['k']), 'values shorter than eight characters are not replaced everywhere');
});

test('error output is bounded: one line per message, a thousand characters at most, five causes at most, no repeats', function (): void {
    $error = null;
    for ($depth = 8; $depth >= 1; --$depth) {
        $error = new \LogicException("cause $depth", 0, $error);
    }
    $lines = explode("\n", rtrim(Sample::describeError(new \LogicException('top', 0, $error)), "\n"));
    same(7, count($lines), 'the error, five causes and the omission note');
    same('Error: LogicException: top', $lines[0], 'top-level line');
    same('  caused by: LogicException: cause 5', $lines[5], 'the fifth cause is the last one shown');
    same('  caused by: (further causes are not shown)', $lines[6], 'omission note');

    same("Error: LogicException: first Error: injected third\n", Sample::describeError(new \LogicException("first\nError: injected\r\nthird")), 'a message cannot add lines');
    $long = Sample::describeError(new \LogicException(str_repeat('x', 5000)));
    same(strlen('Error: ') + 1000 + strlen("...\n"), strlen($long), 'a long message is cut to a thousand characters');
    same("Error: LogicException: same\n", Sample::describeError(new \LogicException('same', 0, new \LogicException('same'))), 'a cause that repeats its parent is not shown again');
});

test('a failed connection exits 1, shows its cause without any credential, and the SDK still retries it', function (): void {
    $request = new Request('POST', BASE_URL.'/v1/messages');
    $recorder = new Recorder(static fn (): Response => throw new ConnectException('cURL error 60: SSL certificate problem: unable to get local issuer certificate for '.BASE_URL.'/v1/messages (token entra-test-token)', $request));
    [$code, $stdout, $stderr] = with_env([], static fn (): array => run_sample([], SAMPLE_ENV, $recorder));
    same(1, $code, 'exit code');
    same('', $stdout, 'stdout');
    assert(str_starts_with($stderr, "Error: APIConnectionException: Anthropic API Connection Error\n  caused by: ConnectException: cURL error 60: SSL certificate problem"), "the cause is shown: $stderr");
    assert(str_contains($stderr, '(token [redacted])') && !str_contains($stderr, 'entra-test-token'), 'the token the provider issued is removed');
    assert(str_contains($stderr, "\nHint: "), 'a certificate failure carries the hint');
    same(3, count($recorder->requests), 'the first attempt and the SDK default of two retries');

    $recorder = new Recorder(static fn (): Response => throw new ConnectException('cURL error 7: refused, key=sample-key-canary-value', $request));
    $env = ['AUTH_MODE' => 'api_key', 'CLAUDE_API_KEY' => 'sample-key-canary-value'] + SAMPLE_ENV;
    [$code, , $stderr] = with_env([], static fn (): array => run_sample(['--stream'], $env, $recorder));
    same(1, $code, 'stream exit code');
    assert(str_contains($stderr, 'caused by: ConnectException: cURL error 7: refused, key=[redacted]') && !str_contains($stderr, 'canary'), 'the configured key is removed');
    assert(!str_contains($stderr, 'Hint:'), 'no certificate hint for a refused connection');
});

test('unknown arguments are a usage error; --help prints usage', function (): void {
    [$code, , $stderr] = run_sample(['--bogus'], SAMPLE_ENV);
    same(2, $code, 'exit code');
    same("Unknown argument: --bogus\nUsage: php main.php [--stream]\n", $stderr, 'stderr');
    [$code, $stdout] = run_sample(['--help'], []);
    same(0, $code, 'help exit code');
    same("Usage: php main.php [--stream]\n", $stdout, 'help output');
});

test('ambient ANTHROPIC_* credentials in the process environment never reach the sample request', function (): void {
    $ambient = [
        'ANTHROPIC_API_KEY' => 'ambient-key-canary', 'ANTHROPIC_AUTH_TOKEN' => 'ambient-token-canary',
        'ANTHROPIC_PROFILE' => 'nonexistent-profile-canary', 'ANTHROPIC_CUSTOM_HEADERS' => "x-api-key: header-canary\napi-key: alias-canary",
    ];
    foreach ([[], ['AUTH_MODE' => 'api_key', 'CLAUDE_API_KEY' => 'sample-key']] as $mode) {
        $recorder = new Recorder();
        [$code, , $stderr] = with_env($ambient, static fn (): array => run_sample([], $mode + SAMPLE_ENV, $recorder));
        same(0, $code, "exit code (stderr: $stderr)");
        assert(!str_contains(wire_of($recorder->requests[0]), 'canary'), 'a canary reached the wire');
    }
});
