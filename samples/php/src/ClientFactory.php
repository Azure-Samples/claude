<?php

declare(strict_types=1);

namespace ClaudeSample;

use Anthropic\Client;
use GuzzleHttp\Client as GuzzleClient;
use Psr\Http\Client\ClientExceptionInterface;
use Psr\Http\Client\ClientInterface;
use Psr\Http\Message\RequestInterface;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\UriInterface;

/**
 * Creates the standard Anthropic\Client for any Anthropic-compatible endpoint with exactly one explicit credential.
 *
 * The factory reads no environment variables and imports no cloud-provider code. Left alone, the SDK would look for
 * ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_PROFILE, workload identity variables and profiles on disk, so it
 * is handed a public, non-secret placeholder that only switches that discovery off. A public request middleware then
 * runs on every HTTP attempt (retries and redirect hops included), removes every credential header, and applies the
 * selected credential. The placeholder never leaves the process.
 */
final class ClientFactory
{
    /** Credential-bearing headers. All of them are removed before the selected credential is applied. */
    private const CREDENTIAL_HEADERS = ['authorization', 'x-api-key', 'api-key'];

    /** Public, non-secret value that only stops the SDK from discovering credentials. */
    private const SUPPRESSION_PLACEHOLDER = 'provided-by-request-hook';

    /** The SDK's documented default request timeout (RequestOptions::$timeout); the PHP SDK leaves enforcing it to the PSR-18 client. */
    private const SDK_DEFAULT_TIMEOUT = 600.0;

    private const LOOPBACK_HOSTS = ['localhost', '127.0.0.1', '[::1]'];

    private const VISIBLE_ASCII = '/^[\x21-\x7E]+$/D';

    private const HEADER_NAME = '/^[!#$%&\'*+\-.^_`|~0-9A-Za-z]+$/D';

    private function __construct() {}

    /**
     * @param string $baseUrl HTTPS endpoint (plain HTTP only for loopback hosts) without credentials, query or fragment
     * @param (callable(): string)|null $tokenProvider Returns a bearer token. It runs once per HTTP attempt, so it should be cheap or cache.
     * @param string|null $apiKey A static key; exclusive with $tokenProvider
     * @param string $keyHeader Header that carries $apiKey. `Authorization` sends `Bearer <key>`; any other name sends the raw key.
     * @param string|null $apiVersion `anthropic-version` to send on every request; null keeps the SDK default
     * @param ClientInterface|null $httpClient PSR-18 transport. It must enforce its own timeout and must not follow redirects; defaults to Guzzle.
     * @param float|null $timeout Seconds, for the default transport only (the SDK leaves timeouts to the PSR-18 client); null keeps the SDK's documented 600 seconds
     * @param int|null $maxRetries null keeps the SDK default
     */
    public static function createClient(
        string $baseUrl,
        ?callable $tokenProvider = null,
        ?string $apiKey = null,
        string $keyHeader = 'Authorization',
        ?string $apiVersion = null,
        ?ClientInterface $httpClient = null,
        ?float $timeout = null,
        ?int $maxRetries = null,
    ): Client {
        $origin = self::originOf($baseUrl);
        if (($tokenProvider === null) === ($apiKey === null)) {
            throw new \InvalidArgumentException('Provide exactly one of tokenProvider or apiKey.');
        }
        if (1 !== preg_match(self::HEADER_NAME, $keyHeader)) {
            throw new \InvalidArgumentException('keyHeader must be a valid HTTP header name.');
        }
        if ($apiKey !== null && 1 !== preg_match(self::VISIBLE_ASCII, $apiKey)) {
            throw new \InvalidArgumentException('apiKey must be a non-empty string without whitespace or control characters.');
        }
        if ($apiVersion !== null && 1 !== preg_match(self::VISIBLE_ASCII, $apiVersion)) {
            throw new \InvalidArgumentException('apiVersion must be a non-empty string without whitespace or control characters.');
        }

        $header = $tokenProvider !== null ? 'Authorization' : $keyHeader;
        $authorize = static function (RequestInterface $request, \Closure $next) use ($origin, $tokenProvider, $apiKey, $header, $apiVersion): ResponseInterface {
            self::assertOrigin($request->getUri(), $origin);
            $secret = $tokenProvider !== null ? self::acquireToken($tokenProvider) : (string) $apiKey;
            foreach ([...self::CREDENTIAL_HEADERS, $header] as $name) {
                $request = $request->withoutHeader($name);
            }
            $request = $request->withHeader($header, 0 === strcasecmp($header, 'Authorization') ? 'Bearer '.$secret : $secret);
            if ($apiVersion !== null) {
                $request = $request->withHeader('anthropic-version', $apiVersion);
            }

            return $next($request);
        };

        $requestOptions = [
            'transporter' => $httpClient ?? self::defaultHttpClient($timeout),
            'middleware' => [$authorize],
        ];
        if ($maxRetries !== null) {
            $requestOptions['maxRetries'] = $maxRetries;
        }

        return new Client(
            authToken: self::SUPPRESSION_PLACEHOLDER,
            baseUrl: $baseUrl,
            requestOptions: $requestOptions,
        );
    }

    /** The transport used when none is passed: Guzzle with a request timeout (default: the SDK's) and without redirect following. */
    public static function defaultHttpClient(?float $timeout = null): ClientInterface
    {
        $timeout ??= self::SDK_DEFAULT_TIMEOUT;
        if (!class_exists(GuzzleClient::class)) {
            throw new \LogicException('Pass an $httpClient (PSR-18) with a request timeout and without redirect following, or install guzzlehttp/guzzle.');
        }

        return new GuzzleClient([
            'timeout' => $timeout,
            'connect_timeout' => $timeout,
            'allow_redirects' => false,
            'http_errors' => false,
        ]);
    }

    /** @return array{string, string, int} scheme, host, port */
    private static function originOf(string $baseUrl): array
    {
        $parts = parse_url($baseUrl);
        $scheme = strtolower((string) ($parts['scheme'] ?? ''));
        $host = strtolower((string) ($parts['host'] ?? ''));
        $secure = 'https' === $scheme || ('http' === $scheme && in_array($host, self::LOOPBACK_HOSTS, true));
        if (false === $parts || '' === $host || !$secure || isset($parts['user']) || isset($parts['pass']) || isset($parts['query']) || isset($parts['fragment'])) {
            throw new \InvalidArgumentException('baseUrl must be an HTTPS URL without credentials, query, or fragment.');
        }

        return [$scheme, $host, $parts['port'] ?? ('https' === $scheme ? 443 : 80)];
    }

    /** @param array{string, string, int} $origin */
    private static function assertOrigin(UriInterface $uri, array $origin): void
    {
        $scheme = strtolower($uri->getScheme());
        $port = $uri->getPort() ?? ('https' === $scheme ? 443 : 80);
        if ([$scheme, strtolower($uri->getHost()), $port] !== $origin || '' !== $uri->getUserInfo()) {
            throw new \RuntimeException('Refusing to send credentials to a different origin.');
        }
    }

    private static function acquireToken(callable $tokenProvider): string
    {
        try {
            $token = $tokenProvider();
        } catch (ClientExceptionInterface $e) {
            // A PSR-18 exception would be retried and rewrapped by the SDK as a connection failure.
            throw new \RuntimeException('The token provider failed.', 0, $e);
        }
        if (!is_string($token) || 1 !== preg_match(self::VISIBLE_ASCII, $token)) {
            throw new \RuntimeException('The token provider must return a non-empty string without whitespace or control characters.');
        }

        return $token;
    }
}
