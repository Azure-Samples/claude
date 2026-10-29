import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { inspect } from 'node:util';

import Anthropic, {
  APIConnectionTimeoutError,
  APIError,
  APIUserAbortError,
  AuthenticationError,
  InternalServerError,
  PermissionDeniedError,
  RateLimitError,
} from '@anthropic-ai/sdk';

import { ClientAuthError, createClient } from '../src/client_auth.ts';
import {
  MESSAGE,
  PARAMS,
  assertCleanRequests,
  hang,
  headerText,
  nth,
  respondWith,
  respondWithError,
  respondWithStream,
  sendJSON,
  useCleanEnvironment,
  useServers,
} from './helpers.ts';

const serve = useServers();
useCleanEnvironment();

const AMBIENT_CANARIES = {
  ANTHROPIC_API_KEY: 'ambient-key-canary',
  ANTHROPIC_AUTH_TOKEN: 'ambient-token-canary',
  ANTHROPIC_PROFILE: 'nonexistent-canary-profile',
  ANTHROPIC_BASE_URL: 'https://wrong.example',
  ANTHROPIC_CUSTOM_HEADERS:
    'Authorization: Bearer custom-canary\nx-api-key: key-canary\napi-key: alias-canary\nx-note: kept-header',
};

describe('credentials', () => {
  it('returns the stock SDK client and resolves a fresh token for every request', async () => {
    const server = await serve(respondWith());
    let calls = 0;
    const client = createClient({ baseURL: server.origin, tokenProvider: () => `token-${++calls}`, maxRetries: 0 });

    assert.equal(Object.getPrototypeOf(client), Anthropic.prototype);
    assert.equal(client.credentials, null, 'the SDK credential-provider path must not be used');
    assert.equal(calls, 0, 'the provider is not called until a request is made');

    await client.messages.create(PARAMS);
    await client.messages.create(PARAMS);

    assert.deepEqual(
      server.requests.map((request) => request.headers.authorization),
      ['Bearer token-1', 'Bearer token-2'],
    );
    const request = nth(server.requests, 0);
    assert.equal(request.url, '/v1/messages');
    assert.equal(JSON.parse(request.body).model, 'claude-test');
    assert.equal(request.headers['anthropic-beta'], undefined);
    assertCleanRequests(server.requests);
  });

  it('keeps the base URL path and sends the model unchanged', async () => {
    const server = await serve(respondWith());
    for (const suffix of ['/anthropic', '/anthropic/']) {
      const client = createClient({ baseURL: server.origin + suffix, tokenProvider: () => 'token', maxRetries: 0 });
      await client.messages.create({ ...PARAMS, model: 'my-deployment' });
    }
    assert.deepEqual(server.requests.map((request) => request.url), ['/anthropic/v1/messages', '/anthropic/v1/messages']);
    assert.ok(server.requests.every((request) => JSON.parse(request.body).model === 'my-deployment'));
  });

  it('ignores ambient credentials, profiles, base URL and credential headers, and per-request overrides', async () => {
    Object.assign(process.env, AMBIENT_CANARIES);
    const server = await serve(respondWith());

    // Control: a plain SDK client under the same environment does send the ambient credentials and headers.
    await new Anthropic({ baseURL: server.origin, maxRetries: 0 }).messages.create(PARAMS);
    const control = headerText(nth(server.requests, 0));
    assert.ok(control.includes('ambient-key-canary') || control.includes('key-canary'), 'the canaries must be live');
    server.requests.length = 0;

    const client = createClient({ baseURL: server.origin, tokenProvider: () => 'selected-token', maxRetries: 0 });
    delete process.env['ANTHROPIC_CUSTOM_HEADERS'];

    await client.messages.create(PARAMS, {
      headers: {
        Authorization: 'Bearer request-canary',
        'x-api-key': 'request-key-canary',
        'anthropic-beta': 'a-requested-beta',
        'x-request-note': 'request-header',
      },
    });

    const request = nth(server.requests, 0);
    assert.equal(request.headers.authorization, 'Bearer selected-token');
    assert.equal(request.headers['x-api-key'], undefined);
    assert.equal(request.headers['api-key'], undefined);
    assert.equal(request.headers['anthropic-beta'], 'a-requested-beta');
    assert.equal(request.headers['x-request-note'], 'request-header');
    assert.equal(request.headers['x-note'], 'kept-header', 'non-credential headers are not touched');
    assert.ok(!headerText(request).includes('canary'));
    assertCleanRequests(server.requests);
  });

  it('keeps ambient credentials out of key-header requests too', async () => {
    Object.assign(process.env, AMBIENT_CANARIES);
    const server = await serve(respondWith());
    const client = createClient({ baseURL: server.origin, apiKey: 'selected-key', keyHeader: 'x-api-key', maxRetries: 0 });

    await client.messages.create(PARAMS, { headers: { Authorization: 'Bearer request-canary' } });

    const request = nth(server.requests, 0);
    assert.equal(request.headers['x-api-key'], 'selected-key');
    assert.equal(request.headers.authorization, undefined);
    assert.equal(request.headers['api-key'], undefined);
    assert.ok(!headerText(request).includes('canary'));
    assertCleanRequests(server.requests);
  });

  it('sends a static key in the configured header', async () => {
    const server = await serve(respondWith());
    const cases = [
      [undefined, 'authorization', 'Bearer selected-key'],
      ['Authorization', 'authorization', 'Bearer selected-key'],
      ['x-api-key', 'x-api-key', 'selected-key'],
      ['api-key', 'api-key', 'selected-key'],
    ] as const;
    for (const [keyHeader, header, expected] of cases) {
      const before = server.requests.length;
      const client = createClient({
        baseURL: server.origin,
        apiKey: 'selected-key',
        ...(keyHeader === undefined ? {} : { keyHeader }),
        maxRetries: 0,
      });
      await client.messages.create(PARAMS);
      const request = nth(server.requests, before);
      assert.equal(request.headers[header], expected, `header ${header}`);
      for (const other of ['authorization', 'x-api-key', 'api-key']) {
        if (other !== header) assert.equal(request.headers[other], undefined, `${other} must be absent for ${header}`);
      }
    }
    assertCleanRequests(server.requests);
  });

  it('applies a configured API version and otherwise preserves the SDK default', async () => {
    const server = await serve(respondWith());
    const stock = new Anthropic({ apiKey: 'stock-key', baseURL: server.origin, maxRetries: 0 });
    await stock.messages.create(PARAMS);
    const sdkDefault = nth(server.requests, 0).headers['anthropic-version'];
    assert.ok(sdkDefault);

    await createClient({ baseURL: server.origin, apiKey: 'key', maxRetries: 0 }).messages.create(PARAMS);
    await createClient({ baseURL: server.origin, apiKey: 'key', apiVersion: '2023-06-01', maxRetries: 0 }).messages.create(PARAMS);

    assert.equal(nth(server.requests, 1).headers['anthropic-version'], sdkDefault);
    assert.equal(nth(server.requests, 2).headers['anthropic-version'], '2023-06-01');
  });

  it('preserves user headers and beta headers, and never adds the OAuth beta', async () => {
    const server = await serve(respondWith());
    const client = createClient({ baseURL: server.origin, tokenProvider: () => 'token', maxRetries: 0 })
      .withOptions({ defaultHeaders: { 'x-team': 'platform' } });

    await client.beta.messages.create({ ...PARAMS, betas: ['files-api-2025-04-14'] });
    await client.messages.create(PARAMS, { headers: { 'anthropic-beta': 'prompt-caching-2024-07-31' } });

    const [native, custom] = server.requests;
    assert.equal(nth(server.requests, 0).headers['x-team'], 'platform');
    assert.match(String(native?.headers['anthropic-beta']), /files-api-2025-04-14/);
    assert.equal(custom?.headers['anthropic-beta'], 'prompt-caching-2024-07-31');
    assert.equal(native?.headers.authorization, 'Bearer token');
    assertCleanRequests(server.requests);
  });

  it('reacquires the credential for every SDK retry', async () => {
    const server = await serve((request, response) =>
      server.requests.length < 3
        ? sendJSON(response, 500, { type: 'error', error: { type: 'api_error', message: 'try again' } }, { 'retry-after-ms': '1' })
        : sendJSON(response, 200, MESSAGE),
    );
    let calls = 0;
    const client = createClient({ baseURL: server.origin, tokenProvider: () => `token-${++calls}` });

    await client.messages.create(PARAMS);

    assert.deepEqual(
      server.requests.map((request) => request.headers.authorization),
      ['Bearer token-1', 'Bearer token-2', 'Bearer token-3'],
    );
    assert.deepEqual(server.requests.map((request) => request.headers['x-stainless-retry-count']), ['0', '1', '2']);
  });

  it('accepts a provider that returns a promise', async () => {
    const server = await serve(respondWith());
    const client = createClient({ baseURL: server.origin, tokenProvider: async () => 'async-token', maxRetries: 0 });
    await client.messages.create(PARAMS);
    assert.equal(nth(server.requests, 0).headers.authorization, 'Bearer async-token');
  });
});

describe('configuration', () => {
  it('rejects invalid configuration before any request', () => {
    const base = { baseURL: 'https://example.services.ai.azure.com/anthropic' };
    const invalid: Array<[string, Parameters<typeof createClient>[0]]> = [
      ['no credential', base],
      ['two credentials', { ...base, apiKey: 'key', tokenProvider: () => 'token' }],
      ['plain HTTP', { baseURL: 'http://insecure.example', apiKey: 'key' }],
      ['HTTP on a lookalike host', { baseURL: 'http://localhost.example', apiKey: 'key' }],
      ['embedded credentials', { baseURL: 'https://user:secret@example.com', apiKey: 'key' }],
      ['query string', { baseURL: 'https://example.com/anthropic?x=1', apiKey: 'key' }],
      ['fragment', { baseURL: 'https://example.com/anthropic#x', apiKey: 'key' }],
      ['not a URL', { baseURL: 'not a url', apiKey: 'key' }],
      ['empty key', { ...base, apiKey: '' }],
      ['blank key', { ...base, apiKey: '   ' }],
      ['multi-line key', { ...base, apiKey: 'key\nx-injected: 1' }],
      ['bad header name', { ...base, apiKey: 'key', keyHeader: 'bad header' }],
      ['bad API version', { ...base, apiKey: 'key', apiVersion: 'bad\nversion' }],
      ['zero timeout', { ...base, apiKey: 'key', timeoutMs: 0 }],
      ['provider that is not a function', { ...base, tokenProvider: 'token' as unknown as () => string }],
    ];
    for (const [name, options] of invalid) {
      assert.throws(() => createClient(options), TypeError, name);
    }
  });

  it('accepts HTTPS and loopback HTTP base URLs', () => {
    for (const baseURL of ['https://example.com', 'https://example.com:8443/anthropic', 'http://localhost:1', 'http://127.0.0.1:1', 'http://[::1]:1']) {
      assert.doesNotThrow(() => createClient({ baseURL, apiKey: 'key' }), baseURL);
    }
  });

  it('preserves the SDK retry and timeout defaults unless they are set', () => {
    const stock = new Anthropic({ apiKey: 'key' });
    const client = createClient({ baseURL: 'https://example.com', apiKey: 'key' });
    assert.equal(client.maxRetries, stock.maxRetries);
    assert.equal(client.timeout, stock.timeout);
    const custom = createClient({ baseURL: 'https://example.com', apiKey: 'key', maxRetries: 5, timeoutMs: 5_000 });
    assert.equal(custom.maxRetries, 5);
    assert.equal(custom.timeout, 5_000);
  });

  it('passes manual redirect handling to fetch even when a request asks to follow', async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const client = createClient({
      baseURL: 'https://example.com/anthropic',
      tokenProvider: () => 'token',
      maxRetries: 0,
      fetch: async (url, init) => {
        calls.push({ url: String(url), init: init ?? {} });
        return Response.json(MESSAGE);
      },
    });

    await client.messages.create(PARAMS, { fetchOptions: { redirect: 'follow' } });

    const call = calls[0];
    assert.equal(call?.url, 'https://example.com/anthropic/v1/messages');
    assert.equal(call?.init.redirect, 'manual');
    assert.equal(new Headers(call?.init.headers).get('authorization'), 'Bearer token');
  });
});

describe('origin and redirects', () => {
  it('does not follow redirects and never contacts the redirect target', async () => {
    const other = await serve(respondWith());
    const origin = await serve((_request, response) => {
      response.writeHead(307, { location: `${other.origin}/v1/messages` });
      response.end();
    });
    const clients = [
      createClient({ baseURL: origin.origin, tokenProvider: () => 'selected-token' }),
      createClient({ baseURL: origin.origin, apiKey: 'selected-key', keyHeader: 'x-api-key' }),
    ];

    for (const client of clients) {
      await assert.rejects(client.messages.create(PARAMS), (error) => error instanceof APIError && error.status === 307);
    }

    assert.equal(origin.requests.length, 2, 'a redirect is final, so the SDK does not retry it');
    assert.equal(other.requests.length, 0, 'no credential may reach the redirect target');
  });

  it('does not follow a same-origin redirect either', async () => {
    const server = await serve((request, response) => {
      response.writeHead(308, { location: '/elsewhere' });
      response.end();
    });
    const client = createClient({ baseURL: server.origin, tokenProvider: () => 'token' });
    await assert.rejects(client.messages.create(PARAMS), (error) => error instanceof APIError && error.status === 308);
    assert.equal(server.requests.length, 1);
  });

  it('refuses to send credentials to a different origin from a copied client or an absolute URL', async () => {
    const other = await serve(respondWith());
    const origin = await serve(respondWith());
    const client = createClient({ baseURL: origin.origin, tokenProvider: () => 'selected-token', maxRetries: 0 });

    await assert.rejects(client.withOptions({ baseURL: other.origin }).messages.create(PARAMS), ClientAuthError);
    await assert.rejects(client.post(`${other.origin}/v1/messages`, { body: PARAMS }), ClientAuthError);

    assert.equal(other.requests.length, 0);
    assert.equal(origin.requests.length, 0);
  });
});

describe('failures', () => {
  it('reports a provider failure with its cause and sends no request, without retrying', async () => {
    const server = await serve(respondWith());
    let calls = 0;
    const failure = new Error('credential unavailable');
    const client = createClient({
      baseURL: server.origin,
      tokenProvider: () => {
        calls += 1;
        throw failure;
      },
    });

    await assert.rejects(client.messages.create(PARAMS), (error) => {
      assert.ok(error instanceof ClientAuthError);
      assert.equal(error.cause, failure);
      return true;
    });

    assert.equal(calls, 1);
    assert.equal(server.requests.length, 0);
  });

  it('rejects credentials that are not a nonempty single line', async () => {
    const server = await serve(respondWith());
    for (const value of ['', '   ', 'a\nb', 'a\r\nb', 42 as unknown as string, undefined as unknown as string]) {
      const client = createClient({ baseURL: server.origin, tokenProvider: () => value, maxRetries: 0 });
      await assert.rejects(client.messages.create(PARAMS), ClientAuthError, JSON.stringify(value));
    }
    assert.equal(server.requests.length, 0);
  });

  it('rejects credentials that cannot be an HTTP header value without echoing them', async () => {
    const server = await serve(respondWith());
    const client = createClient({ baseURL: server.origin, tokenProvider: () => 'token-\u2603', maxRetries: 0 });
    await assert.rejects(client.messages.create(PARAMS), (error) => {
      assert.ok(error instanceof ClientAuthError);
      assert.ok(!String(error.message).includes('token-'));
      assert.equal(error.cause, undefined);
      return true;
    });
    assert.equal(server.requests.length, 0);
  });

  it('preserves HTTP statuses and the SDK error classes', async () => {
    const cases = [
      [401, AuthenticationError],
      [403, PermissionDeniedError],
      [429, RateLimitError],
      [500, InternalServerError],
    ] as const;
    for (const [status, errorClass] of cases) {
      const server = await serve(respondWithError(status));
      const client = createClient({ baseURL: server.origin, tokenProvider: () => 'token', maxRetries: 0 });
      await assert.rejects(client.messages.create(PARAMS), (error) => {
        assert.ok(error instanceof errorClass, `status ${status}`);
        assert.equal((error as APIError).status, status);
        return true;
      });
    }
  });

  it('does not retry authentication or permission failures', async () => {
    for (const status of [401, 403]) {
      const server = await serve(respondWithError(status));
      const client = createClient({ baseURL: server.origin, tokenProvider: () => 'token' });
      await assert.rejects(client.messages.create(PARAMS), (error) => error instanceof APIError && error.status === status);
      assert.equal(server.requests.length, 1, `status ${status}`);
    }
  });

  it('times out an attempt that never answers', async () => {
    const server = await serve(hang);
    const client = createClient({ baseURL: server.origin, tokenProvider: () => 'token', maxRetries: 0, timeoutMs: 50 });
    await assert.rejects(client.messages.create(PARAMS), APIConnectionTimeoutError);
    assert.equal(server.requests.length, 1);
  });
});

describe('streaming and cancellation', () => {
  it('streams text through the standard SDK helper', async () => {
    const server = await serve(respondWithStream([['thinking', 'not for display'], ['text', 'OK']]));
    const client = createClient({ baseURL: server.origin, tokenProvider: () => 'stream-token', maxRetries: 0 });

    const stream = client.messages.stream(PARAMS);
    let text = '';
    stream.on('text', (delta) => {
      text += delta;
    });
    const message = await stream.finalMessage();

    assert.equal(text, 'OK');
    assert.equal(message.stop_reason, 'end_turn');
    const request = nth(server.requests, 0);
    assert.equal(request.headers.authorization, 'Bearer stream-token');
    assert.equal(JSON.parse(request.body).stream, true);
    assertCleanRequests(server.requests);
  });

  it('cancels while the credential is being acquired', async () => {
    const server = await serve(respondWith());
    const controller = new AbortController();
    let started!: () => void;
    const providerStarted = new Promise<void>((resolve) => {
      started = resolve;
    });
    const client = createClient({
      baseURL: server.origin,
      tokenProvider: () => {
        started();
        return new Promise<string>(() => {});
      },
      maxRetries: 0,
    });

    const call = client.messages.create(PARAMS, { signal: controller.signal });
    await providerStarted;
    controller.abort();

    await assert.rejects(call, APIUserAbortError);
    assert.equal(server.requests.length, 0);
  });

  it('cancels a request that is in flight', async () => {
    const server = await serve(hang);
    const controller = new AbortController();
    const client = createClient({ baseURL: server.origin, tokenProvider: () => 'token', maxRetries: 0 });

    const call = client.messages.create(PARAMS, { signal: controller.signal });
    while (server.requests.length === 0) await new Promise((resolve) => setTimeout(resolve, 5));
    controller.abort();

    await assert.rejects(call, APIUserAbortError);
  });

  it('honours a signal that is already aborted and a total deadline', async () => {
    const server = await serve(hang);
    let calls = 0;
    const client = createClient({
      baseURL: server.origin,
      tokenProvider: () => `token-${++calls}`,
      maxRetries: 0,
    });

    await assert.rejects(client.messages.create(PARAMS, { signal: AbortSignal.abort() }), APIUserAbortError);
    assert.equal(calls, 0);

    await assert.rejects(client.messages.create(PARAMS, { signal: AbortSignal.timeout(100) }), APIUserAbortError);
    assert.equal(server.requests.length, 1);
  });
});

describe('logging', () => {
  it('keeps the credential out of SDK debug logs for the credential headers', async () => {
    const server = await serve(respondWith());
    const lines: string[] = [];
    const record = (...args: unknown[]) => {
      lines.push(inspect(args, { depth: 8 }));
    };
    const logger = { debug: record, info: record, warn: record, error: record };
    const variants = [
      { tokenProvider: () => 'logged-token-value' },
      { apiKey: 'logged-key-value' },
      { apiKey: 'logged-x-api-key-value', keyHeader: 'x-api-key' },
    ];

    for (const variant of variants) {
      const client = createClient({ baseURL: server.origin, ...variant, maxRetries: 0 }).withOptions({
        logger,
        logLevel: 'debug',
      });
      await client.messages.create(PARAMS);
    }

    const logged = lines.join('\n');
    assert.match(logged, /sending request/, 'the SDK logged the request headers');
    assert.match(logged, /\*\*\*/, 'and redacted the credential headers');
    for (const secret of ['logged-token-value', 'logged-key-value', 'logged-x-api-key-value']) {
      assert.ok(!logged.includes(secret), `${secret} leaked into the SDK log`);
    }
  });
});