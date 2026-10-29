import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import type { AccessToken, TokenCredential } from '@azure/identity';
import { AzureCliCredential, AzureDeveloperCliCredential, ManagedIdentityCredential } from '@azure/identity';

import { ConfigError } from '../src/config_error.ts';
import { run, type RunIO, type RunOptions } from '../src/main.ts';
import { DEFAULT_TOKEN_SCOPE, loadSettings, type Environment } from '../src/sample_client.ts';
import {
  CLI_PROCESS_TIMEOUT_MS,
  CREDENTIAL_CHOICES,
  createCredential,
  createTokenProvider,
  type CredentialConstructors,
} from '../src/token_provider.ts';
import {
  MESSAGE,
  THINKING_BLOCK,
  hang,
  startServer,
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

const CANONICAL = { ANTHROPIC_BASE_URL: 'https://example.services.ai.azure.com/anthropic', ANTHROPIC_MODEL: 'sample-deployment' };
const LEGACY = { CLAUDE_BASE_URL: 'https://legacy.example', CLAUDE_DEPLOYMENT_NAME: 'legacy-deployment' };

describe('loadSettings', () => {
  it('selects the canonical profile and requires an explicit AUTH_MODE, so an ambient URL never gets a token by default', () => {
    assert.throws(() => loadSettings(CANONICAL), {
      name: 'ConfigError',
      message: 'ANTHROPIC_BASE_URL is set, so AUTH_MODE must be set explicitly to bearer or api_key.',
    });
    assert.deepEqual(loadSettings({ ...CANONICAL, AUTH_MODE: 'bearer' }), {
      profile: 'anthropic',
      baseURL: CANONICAL.ANTHROPIC_BASE_URL,
      model: 'sample-deployment',
      apiVersion: undefined,
      auth: {
        mode: 'bearer',
        credential: 'AzureCliCredential',
        tenantId: undefined,
        clientId: undefined,
        scope: DEFAULT_TOKEN_SCOPE,
      },
    });
    assert.equal(DEFAULT_TOKEN_SCOPE, 'https://ai.azure.com/.default');
  });

  it('selects the legacy profile when only CLAUDE_BASE_URL is set, and that profile defaults to bearer', () => {
    const settings = loadSettings(LEGACY);
    assert.equal(settings.profile, 'claude');
    assert.equal(settings.baseURL, 'https://legacy.example');
    assert.equal(settings.model, 'legacy-deployment');
    assert.equal(settings.auth.mode, 'bearer');
    assert.equal(settings.apiVersion, undefined);
  });

  it('lets a complete canonical profile override the legacy one entirely', () => {
    const settings = loadSettings({
      ...LEGACY,
      ...CANONICAL,
      AUTH_MODE: 'api_key',
      ANTHROPIC_API_KEY: 'native-key',
      CLAUDE_API_KEY: 'legacy-key',
    });
    assert.deepEqual(settings, {
      profile: 'anthropic',
      baseURL: CANONICAL.ANTHROPIC_BASE_URL,
      model: 'sample-deployment',
      apiVersion: undefined,
      auth: { mode: 'api_key', apiKey: 'native-key', keyHeader: 'Authorization' },
    });
  });

  it('reads the bearer settings', () => {
    const { auth } = loadSettings({
      ...CANONICAL,
      AUTH_MODE: 'bearer',
      AZURE_TOKEN_CREDENTIALS: 'ManagedIdentityCredential',
      AZURE_TENANT_ID: 'example-tenant',
      AZURE_CLIENT_ID: 'example-client',
      TOKEN_SCOPE: 'https://example.test/.default',
    });
    assert.deepEqual(auth, {
      mode: 'bearer',
      credential: 'ManagedIdentityCredential',
      tenantId: 'example-tenant',
      clientId: 'example-client',
      scope: 'https://example.test/.default',
    });
  });

  it('defaults the API key header to Authorization and reads the key of the selected family only', () => {
    assert.deepEqual(loadSettings({ ...LEGACY, AUTH_MODE: 'api_key', CLAUDE_API_KEY: 'legacy-key' }).auth, {
      mode: 'api_key',
      apiKey: 'legacy-key',
      keyHeader: 'Authorization',
    });
    const configured = loadSettings({
      ...CANONICAL,
      AUTH_MODE: 'api_key',
      ANTHROPIC_API_KEY: 'native-key',
      API_KEY_HEADER: 'x-api-key',
      ANTHROPIC_API_VERSION: '2023-06-01',
    });
    assert.deepEqual(configured.auth, { mode: 'api_key', apiKey: 'native-key', keyHeader: 'x-api-key' });
    assert.equal(configured.apiVersion, '2023-06-01');
  });

  it('never combines a URL with the model or key of the other family', () => {
    const url = 'https://example.test';
    const cases: Array<[string, Environment, RegExp]> = [
      [
        'canonical URL, legacy model',
        { ANTHROPIC_BASE_URL: url, AUTH_MODE: 'bearer', CLAUDE_DEPLOYMENT_NAME: 'legacy-deployment' },
        /^ANTHROPIC_BASE_URL is set, so ANTHROPIC_MODEL is required; CLAUDE_DEPLOYMENT_NAME is not used with it\.$/,
      ],
      [
        'canonical URL, legacy key',
        { ANTHROPIC_BASE_URL: url, ANTHROPIC_MODEL: 'native-model', AUTH_MODE: 'api_key', CLAUDE_API_KEY: 'legacy-key-canary' },
        /^AUTH_MODE=api_key with ANTHROPIC_BASE_URL requires ANTHROPIC_API_KEY; CLAUDE_API_KEY is not used with it\.$/,
      ],
      [
        'legacy URL, canonical model',
        { CLAUDE_BASE_URL: url, AUTH_MODE: 'bearer', ANTHROPIC_MODEL: 'native-model' },
        /^CLAUDE_BASE_URL is set, so CLAUDE_DEPLOYMENT_NAME is required; ANTHROPIC_MODEL is not used with it\.$/,
      ],
      [
        'legacy URL, canonical key',
        { ...LEGACY, AUTH_MODE: 'api_key', ANTHROPIC_API_KEY: 'native-key-canary' },
        /^AUTH_MODE=api_key with CLAUDE_BASE_URL requires CLAUDE_API_KEY; ANTHROPIC_API_KEY is not used with it\.$/,
      ],
    ];
    for (const [name, env, message] of cases) {
      assert.throws(() => loadSettings(env), { name: 'ConfigError', message }, name);
    }
  });

  it('reports missing or invalid configuration without echoing values', () => {
    assert.throws(() => loadSettings({}), {
      name: 'ConfigError',
      message: 'Set ANTHROPIC_BASE_URL, ANTHROPIC_MODEL and AUTH_MODE, or the legacy CLAUDE_BASE_URL and CLAUDE_DEPLOYMENT_NAME.',
    });
    assert.throws(() => loadSettings({ ANTHROPIC_MODEL: 'native-model', CLAUDE_DEPLOYMENT_NAME: 'legacy' }), ConfigError);
    for (const family of [CANONICAL, LEGACY]) {
      assert.throws(() => loadSettings({ ...family, AUTH_MODE: 'basic' }), { message: 'AUTH_MODE must be bearer or api_key.' });
    }
  });
});
describe('credential selection', () => {
  function recordingConstructors() {
    const calls: Array<{ name: string; options: unknown }> = [];
    const make = (name: string) =>
      class implements TokenCredential {
        constructor(options?: unknown) {
          calls.push({ name, options });
        }
        async getToken(): Promise<AccessToken | null> {
          return null;
        }
      };
    const constructors: CredentialConstructors = {
      AzureCliCredential: make('AzureCliCredential'),
      AzureDeveloperCliCredential: make('AzureDeveloperCliCredential'),
      ManagedIdentityCredential: make('ManagedIdentityCredential'),
    };
    return { calls, constructors };
  }

  it('builds exactly the named credential and passes each identity to the credential that uses it', () => {
    const ids = { tenantId: 'example-tenant', clientId: 'example-client' };
    const { calls, constructors } = recordingConstructors();

    createCredential('AzureCliCredential', ids, constructors);
    createCredential('AzureDeveloperCliCredential', ids, constructors);
    createCredential('ManagedIdentityCredential', ids, constructors);
    createCredential('AzureCliCredential', {}, constructors);
    createCredential('ManagedIdentityCredential', {}, constructors);

    assert.deepEqual(calls, [
      { name: 'AzureCliCredential', options: { tenantId: 'example-tenant', processTimeoutInMs: 60_000 } },
      { name: 'AzureDeveloperCliCredential', options: { tenantId: 'example-tenant', processTimeoutInMs: 60_000 } },
      { name: 'ManagedIdentityCredential', options: { clientId: 'example-client' } },
      { name: 'AzureCliCredential', options: { processTimeoutInMs: 60_000 } },
      { name: 'ManagedIdentityCredential', options: {} },
    ]);
    assert.equal(CLI_PROCESS_TIMEOUT_MS, 60_000);
  });

  it('has no fallback: other names fail and name the setting', () => {
    const { calls, constructors } = recordingConstructors();
    for (const source of ['DefaultAzureCredential', 'typo', 'azureclicredential', '']) {
      assert.throws(() => createCredential(source, {}, constructors), { name: 'ConfigError', message: /AZURE_TOKEN_CREDENTIALS/ }, source);
    }
    assert.deepEqual(calls, []);
    assert.deepEqual([...CREDENTIAL_CHOICES], ['AzureCliCredential', 'AzureDeveloperCliCredential', 'ManagedIdentityCredential']);
  });

  it('constructs the real Azure Identity credentials without contacting anything', () => {
    assert.ok(createCredential('AzureCliCredential', { tenantId: 'example-tenant' }) instanceof AzureCliCredential);
    assert.ok(createCredential('AzureDeveloperCliCredential') instanceof AzureDeveloperCliCredential);
    assert.ok(createCredential('ManagedIdentityCredential', { clientId: 'example-client' }) instanceof ManagedIdentityCredential);
  });

  it('gives the real CLI credentials the process timeout', () => {
    // The pinned @azure/identity keeps processTimeoutInMs in a private `timeout` field of each CLI credential.
    const timeoutOf = (credential: unknown) => (credential as { timeout?: number }).timeout;
    assert.equal(timeoutOf(createCredential('AzureCliCredential')), 60_000);
    assert.equal(timeoutOf(createCredential('AzureDeveloperCliCredential', { tenantId: 'example-tenant' })), 60_000);
  });
});

describe('token provider', () => {
  function fakeCredential(expiresInMs: number[]) {
    const requests: Array<string | string[]> = [];
    const credential: TokenCredential = {
      async getToken(scopes) {
        requests.push(scopes);
        const index = requests.length;
        return { token: `token-${index}`, expiresOnTimestamp: Date.now() + (expiresInMs[index - 1] ?? 3_600_000) };
      },
    };
    return { credential, requests };
  }

  it('is lazy, requests the scope, and reuses the token until it nears expiry', async () => {
    const { credential, requests } = fakeCredential([3_600_000]);
    const provider = createTokenProvider(credential, DEFAULT_TOKEN_SCOPE);
    assert.equal(requests.length, 0);

    assert.equal(await provider(), 'token-1');
    assert.equal(await provider(), 'token-1');

    assert.equal(requests.length, 1);
    assert.deepEqual(requests[0], [DEFAULT_TOKEN_SCOPE]);
  });

  it('asks the credential for a new token before the current one expires', async () => {
    const { credential, requests } = fakeCredential([30_000, 3_600_000]);
    const provider = createTokenProvider(credential, DEFAULT_TOKEN_SCOPE);

    assert.equal(await provider(), 'token-1');
    assert.equal(await provider(), 'token-1', 'the still-valid token is returned while the refresh runs');
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(await provider(), 'token-2');
    assert.equal(requests.length, 2);
  });
});

const execFileAsync = promisify(execFile);
const MAIN = fileURLToPath(new URL('../src/main.ts', import.meta.url));

async function runProcess(args: string[], env: Record<string, string>) {
  try {
    const { stdout, stderr } = await execFileAsync(process.execPath, [MAIN, ...args], {
      env: { ...process.env, ...env },
      timeout: 30_000,
    });
    return { code: 0, stdout, stderr };
  } catch (error) {
    const failure = error as { code?: unknown; stdout?: string; stderr?: string };
    return { code: typeof failure.code === 'number' ? failure.code : -1, stdout: failure.stdout ?? '', stderr: failure.stderr ?? '' };
  }
}

function capture() {
  let out = '';
  let err = '';
  const io: RunIO = {
    stdout: { write: (text) => (out += text) },
    stderr: { write: (text) => (err += text) },
  };
  return { io, stdout: () => out, stderr: () => err };
}

const PROMPT = 'What are 3 things to visit in Seattle?';
const TEXT_MESSAGE = { ...MESSAGE, content: [THINKING_BLOCK, { type: 'text', text: 'OK' }] };
const THINKING_ONLY = { ...MESSAGE, content: [THINKING_BLOCK], stop_reason: 'max_tokens' };

async function sampleEnvironment(server: { origin: string }, extra: Environment = {}): Promise<Environment> {
  return {
    ANTHROPIC_BASE_URL: `${server.origin}/anthropic`,
    ANTHROPIC_MODEL: 'sample-deployment',
    AUTH_MODE: 'api_key',
    ANTHROPIC_API_KEY: 'sample-key',
    ...extra,
  };
}

describe('main', () => {
  it('prints the reply text and usage, not the thinking, using the SDK defaults', async () => {
    const server = await serve(respondWith(TEXT_MESSAGE));
    const output = capture();

    assert.equal(await run([], await sampleEnvironment(server), output.io), 0);

    assert.equal(output.stdout(), 'OK\n\n[usage] input=1 output=2\n');
    assert.equal(output.stderr(), '');
    const request = nth(server.requests, 0);
    assert.equal(request.url, '/anthropic/v1/messages');
    assert.equal(request.headers.authorization, 'Bearer sample-key');
    assert.equal(request.headers['x-api-key'], undefined);
    assert.equal(request.headers['anthropic-beta'], undefined);
    assert.match(String(request.headers['anthropic-version']), /^\d{4}-\d{2}-\d{2}$/);
    assert.deepEqual(JSON.parse(request.body), {
      model: 'sample-deployment',
      max_tokens: 1024,
      messages: [{ role: 'user', content: PROMPT }],
    });
  });

  it('honours API_KEY_HEADER and ANTHROPIC_API_VERSION', async () => {
    const server = await serve(respondWith(TEXT_MESSAGE));
    const env = await sampleEnvironment(server, { API_KEY_HEADER: 'x-api-key', ANTHROPIC_API_VERSION: '2023-06-01' });

    assert.equal(await run([], env, capture().io), 0);

    const request = nth(server.requests, 0);
    assert.equal(request.headers['x-api-key'], 'sample-key');
    assert.equal(request.headers.authorization, undefined);
    assert.equal(request.headers['anthropic-version'], '2023-06-01');
  });

  it('reads the legacy variable names', async () => {
    const server = await serve(respondWith(TEXT_MESSAGE));
    const env = {
      CLAUDE_BASE_URL: server.origin,
      CLAUDE_DEPLOYMENT_NAME: 'legacy-deployment',
      AUTH_MODE: 'api_key',
      CLAUDE_API_KEY: 'legacy-key',
    };

    assert.equal(await run([], env, capture().io), 0);

    const request = nth(server.requests, 0);
    assert.equal(request.url, '/v1/messages');
    assert.equal(request.headers.authorization, 'Bearer legacy-key');
    assert.equal(JSON.parse(request.body).model, 'legacy-deployment');
  });

  it('authenticates with a bearer token for every attempt and never uses ambient credentials', async () => {
    Object.assign(process.env, {
      ANTHROPIC_API_KEY: 'ambient-key-canary',
      ANTHROPIC_AUTH_TOKEN: 'ambient-token-canary',
      ANTHROPIC_PROFILE: 'nonexistent-canary-profile',
      ANTHROPIC_CUSTOM_HEADERS: 'x-api-key: header-canary',
    });
    const server = await serve((_request, response) =>
      server.requests.length < 2
        ? sendJSON(response, 500, { type: 'error', error: { type: 'api_error', message: 'again' } }, { 'retry-after-ms': '1' })
        : sendJSON(response, 200, TEXT_MESSAGE),
    );
    let calls = 0;
    const env = { ANTHROPIC_BASE_URL: server.origin, ANTHROPIC_MODEL: 'sample-deployment', AUTH_MODE: 'bearer' };

    assert.equal(await run([], env, capture().io, { tokenProvider: () => `entra-test-token-${++calls}` }), 0);

    assert.deepEqual(
      server.requests.map((request) => request.headers.authorization),
      ['Bearer entra-test-token-1', 'Bearer entra-test-token-2'],
    );
    for (const request of server.requests) {
      assert.equal(request.headers['x-api-key'], undefined);
      assert.equal(request.headers['anthropic-beta'], undefined);
      assert.ok(!JSON.stringify(request.headers).includes('canary'));
    }
  });

  it('streams only the text and uses a custom prompt', async () => {
    const server = await serve(respondWithStream([['thinking', 'not for display'], ['text', 'Hello'], ['text', ' there']]));
    const output = capture();

    assert.equal(await run(['--stream', 'Say', 'hi'], await sampleEnvironment(server), output.io), 0);

    assert.equal(output.stdout(), 'Hello there\n');
    const body = JSON.parse(nth(server.requests, 0).body);
    assert.equal(body.stream, true);
    assert.equal(body.max_tokens, 1024);
    assert.deepEqual(body.messages, [{ role: 'user', content: 'Say hi' }]);
  });

  it('exits nonzero when the reply has no text', async () => {
    const empty = { ...MESSAGE, content: [], stop_reason: 'end_turn' };
    const blank = { ...MESSAGE, content: [{ type: 'text', text: '  \n' }] };
    for (const [name, message] of [['thinking only', THINKING_ONLY], ['empty', empty], ['blank text', blank]] as const) {
      const server = await serve(respondWith(message));
      const output = capture();
      assert.equal(await run([], await sampleEnvironment(server), output.io), 1, name);
      assert.match(output.stderr(), /No text response \(stop_reason=/, name);
      assert.ok(!output.stdout().includes('not for display'), name);
      assert.ok(!output.stdout().includes('[usage]'), name);
    }
    const server = await serve(respondWith(THINKING_ONLY));
    const output = capture();
    await run([], await sampleEnvironment(server), output.io);
    assert.match(output.stderr(), /max_tokens/);
  });

  it('exits nonzero when a stream has no text', async () => {
    const server = await serve(respondWithStream([['thinking', 'not for display']]));
    const output = capture();

    assert.equal(await run(['--stream'], await sampleEnvironment(server), output.io), 1);

    assert.match(output.stderr(), /No text response/);
    assert.ok(!output.stdout().includes('not for display'));
  });

  it('reports HTTP failures without echoing the credential, endpoint, model or response body', async () => {
    for (const stream of [false, true]) {
      for (const status of [401, 403, 404, 429, 500]) {
        const server = await serve(respondWithError(status));
        const output = capture();
        const code = await run(stream ? ['--stream'] : [], await sampleEnvironment(server), output.io, { maxRetries: 0 });

        assert.equal(code, 1);
        assert.match(output.stderr(), new RegExp(`HTTP ${status} \\(api_error\\)`));
        for (const secret of ['sample-key', server.origin, new URL(server.origin).host, 'sample-deployment', 'test failure']) {
          assert.ok(!output.stderr().includes(secret), `${secret} leaked for ${status}`);
        }
        assert.equal(output.stdout(), '', 'no reply text on failure');
      }
    }
  });

  it('reports a redirect as an error and does not follow it', async () => {
    const other = await serve(respondWith(TEXT_MESSAGE));
    const server = await serve((_request, response) => {
      response.writeHead(307, { location: `${other.origin}/v1/messages` });
      response.end();
    });
    const output = capture();

    assert.equal(await run([], await sampleEnvironment(server), output.io), 1);

    assert.match(output.stderr(), /HTTP 307/);
    assert.equal(other.requests.length, 0);
  });

  it('reports a credential failure without the provider message', async () => {
    const server = await serve(respondWith(TEXT_MESSAGE));
    const output = capture();
    const env = { ANTHROPIC_BASE_URL: server.origin, ANTHROPIC_MODEL: 'sample-deployment', AUTH_MODE: 'bearer' };
    const failing: RunOptions = {
      tokenProvider: () => {
        throw new Error('tenant details that must not be printed');
      },
    };

    assert.equal(await run([], env, output.io, failing), 1);

    assert.match(output.stderr(), /credential provider failed/);
    assert.match(output.stderr(), /Cause: Error/);
    assert.ok(!output.stderr().includes('tenant details'));
    assert.equal(server.requests.length, 0);
  });

  it('reports an unreachable endpoint without naming it', async () => {
    const closed = await startServer(respondWith());
    const env = await sampleEnvironment(closed);
    await closed.close();
    const output = capture();

    assert.equal(await run([], env, output.io, { maxRetries: 0 }), 1);

    assert.equal(output.stderr(), 'Could not connect to the endpoint.\n');
  });

  it('reports a credential failure the same way while streaming', async () => {
    const server = await serve(respondWith(TEXT_MESSAGE));
    const output = capture();
    const env = { ANTHROPIC_BASE_URL: server.origin, ANTHROPIC_MODEL: 'sample-deployment', AUTH_MODE: 'bearer' };
    const failing: RunOptions = {
      tokenProvider: () => {
        throw new Error('tenant details that must not be printed');
      },
    };

    assert.equal(await run(['--stream'], env, output.io, failing), 1);

    assert.match(output.stderr(), /credential provider failed/);
    assert.ok(!output.stderr().includes('tenant details'));
    assert.equal(server.requests.length, 0);
  });

  it('exits nonzero on a missing configuration without contacting anything', async () => {
    const output = capture();
    assert.equal(await run([], {}, output.io), 1);
    assert.match(output.stderr(), /^Set ANTHROPIC_BASE_URL, ANTHROPIC_MODEL and AUTH_MODE, or the legacy CLAUDE_BASE_URL and CLAUDE_DEPLOYMENT_NAME\.\n$/);
    assert.equal(output.stdout(), '');
  });

  it('bounds the whole call with a total deadline', async () => {
    const server = await serve(hang);
    const output = capture();

    assert.equal(await run([], await sampleEnvironment(server), output.io, { totalTimeoutMs: 100 }), 1);

    assert.match(output.stderr(), /timed out after 0\.1 seconds/);
    assert.ok(!output.stderr().includes(server.origin));
  });

  it('prints usage for --help and exits 2 for unknown options', async () => {
    const help = capture();
    assert.equal(await run(['--help'], {}, help.io), 0);
    assert.match(help.stdout(), /Usage: node src\/main\.ts/);

    const unknown = capture();
    assert.equal(await run(['--nope'], {}, unknown.io), 2);
    assert.match(unknown.stderr(), /Usage: node src\/main\.ts/);
  });

  it('runs as a command: exit codes and output of the real entrypoint', async () => {
    const ok = await serve(respondWith(TEXT_MESSAGE));
    const streamed = await serve(respondWithStream([['text', 'Hello']]));
    const denied = await serve(respondWithError(401));
    const env = (server: { origin: string }) => ({
      ANTHROPIC_BASE_URL: server.origin,
      ANTHROPIC_MODEL: 'sample-deployment',
      AUTH_MODE: 'api_key',
      ANTHROPIC_API_KEY: 'sample-key',
    });

    const plain = await runProcess([], env(ok));
    assert.deepEqual(plain, { code: 0, stdout: 'OK\n\n[usage] input=1 output=2\n', stderr: '' });

    const stream = await runProcess(['--stream'], env(streamed));
    assert.deepEqual(stream, { code: 0, stdout: 'Hello\n', stderr: '' });

    const failure = await runProcess([], env(denied));
    assert.equal(failure.code, 1);
    assert.equal(failure.stdout, '');
    assert.match(failure.stderr, /HTTP 401/);
    assert.ok(!failure.stderr.includes('sample-key'));

    assert.equal((await runProcess([], {})).code, 1);
    assert.equal((await runProcess(['--bogus'], {})).code, 2);
  });

  it('never sends a credential from one variable family to the endpoint of the other', async () => {
    const native = await serve(respondWith(TEXT_MESSAGE));
    const legacy = await serve(respondWith(TEXT_MESSAGE));
    const cases: Array<[string, Environment, RegExp]> = [
      [
        'canonical URL, legacy model and key',
        { ANTHROPIC_BASE_URL: native.origin, AUTH_MODE: 'api_key', CLAUDE_DEPLOYMENT_NAME: 'legacy-model', CLAUDE_API_KEY: 'legacy-key-canary' },
        /ANTHROPIC_MODEL is required/,
      ],
      [
        'canonical URL and model, legacy key',
        { ANTHROPIC_BASE_URL: native.origin, ANTHROPIC_MODEL: 'native-model', AUTH_MODE: 'api_key', CLAUDE_API_KEY: 'legacy-key-canary' },
        /requires ANTHROPIC_API_KEY/,
      ],
      [
        'legacy URL and model, canonical key',
        { CLAUDE_BASE_URL: legacy.origin, CLAUDE_DEPLOYMENT_NAME: 'legacy-model', AUTH_MODE: 'api_key', ANTHROPIC_API_KEY: 'native-key-canary' },
        /requires CLAUDE_API_KEY/,
      ],
      [
        'legacy URL, canonical model and key',
        { CLAUDE_BASE_URL: legacy.origin, ANTHROPIC_MODEL: 'native-model', AUTH_MODE: 'api_key', ANTHROPIC_API_KEY: 'native-key-canary' },
        /CLAUDE_DEPLOYMENT_NAME is required/,
      ],
    ];

    for (const [name, env, expected] of cases) {
      const output = capture();
      assert.equal(await run([], env, output.io), 1, name);
      assert.match(output.stderr(), expected, name);
      assert.ok(!output.stderr().includes('canary'), name);
    }

    assert.equal(native.requests.length + legacy.requests.length, 0, 'nothing may be sent');
  });

  it('uses only the selected family when both are complete', async () => {
    const native = await serve(respondWith(TEXT_MESSAGE));
    const legacy = await serve(respondWith(TEXT_MESSAGE));
    const both = {
      ANTHROPIC_BASE_URL: `${native.origin}/anthropic`,
      ANTHROPIC_MODEL: 'native-model',
      ANTHROPIC_API_KEY: 'native-key',
      CLAUDE_BASE_URL: legacy.origin,
      CLAUDE_DEPLOYMENT_NAME: 'legacy-model',
      CLAUDE_API_KEY: 'legacy-key',
      AUTH_MODE: 'api_key',
    };

    assert.equal(await run([], both, capture().io), 0);
    const { ANTHROPIC_BASE_URL: _url, ANTHROPIC_MODEL: _model, ...legacyOnly } = both;
    assert.equal(await run([], legacyOnly, capture().io), 0, 'an ambient ANTHROPIC_API_KEY must not matter');

    const request = nth(native.requests, 0);
    assert.equal(request.url, '/anthropic/v1/messages');
    assert.equal(request.headers.authorization, 'Bearer native-key');
    assert.equal(JSON.parse(request.body).model, 'native-model');
    const fallback = nth(legacy.requests, 0);
    assert.equal(fallback.headers.authorization, 'Bearer legacy-key');
    assert.equal(JSON.parse(fallback.body).model, 'legacy-model');
    assert.equal(native.requests.length, 1);
    assert.equal(legacy.requests.length, 1);
    for (const sent of [request, fallback]) assert.ok(!JSON.stringify(sent.headers).includes('canary'));
  });

  it('gives a token to a canonical URL only when bearer is chosen explicitly', async () => {
    const server = await serve(respondWith(TEXT_MESSAGE));
    let calls = 0;
    const options: RunOptions = { tokenProvider: () => `entra-test-token-${++calls}` };
    const canonical = { ANTHROPIC_BASE_URL: server.origin, ANTHROPIC_MODEL: 'sample-deployment' };

    const implicit = capture();
    assert.equal(await run([], canonical, implicit.io, options), 1);
    assert.match(implicit.stderr(), /AUTH_MODE must be set explicitly/);
    assert.equal(calls, 0, 'no token may be acquired');
    assert.equal(server.requests.length, 0, 'nothing may be sent');

    assert.equal(await run([], { ...canonical, AUTH_MODE: 'bearer' }, capture().io, options), 0);
    assert.equal(nth(server.requests, 0).headers.authorization, 'Bearer entra-test-token-1');

    const legacy = { CLAUDE_BASE_URL: server.origin, CLAUDE_DEPLOYMENT_NAME: 'legacy-deployment' };
    assert.equal(await run([], legacy, capture().io, options), 0, 'the legacy profile keeps bearer as its default');
    assert.equal(nth(server.requests, 1).headers.authorization, 'Bearer entra-test-token-2');
  });

  it('does not modify the process environment', async () => {
    const server = await serve(respondWith(TEXT_MESSAGE));
    process.env['ANTHROPIC_FOUNDRY_RESOURCE'] = 'unchanged-resource';
    const before = JSON.stringify(process.env);

    await run([], await sampleEnvironment(server), capture().io);

    assert.equal(JSON.stringify(process.env), before);
  });
});