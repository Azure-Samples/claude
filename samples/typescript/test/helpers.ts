import assert from 'node:assert/strict';
import { createServer, type IncomingHttpHeaders, type ServerResponse } from 'node:http';
import type { AddressInfo } from 'node:net';
import { afterEach, beforeEach } from 'node:test';

export interface RecordedRequest {
  method: string;
  url: string;
  headers: IncomingHttpHeaders;
  body: string;
}

export type Handler = (request: RecordedRequest, response: ServerResponse) => void | Promise<void>;

export interface TestServer {
  origin: string;
  requests: RecordedRequest[];
  close(): Promise<void>;
}

/** Starts a loopback HTTP server that records every request before running the handler. */
export async function startServer(handler: Handler): Promise<TestServer> {
  const requests: RecordedRequest[] = [];
  const server = createServer((request, response) => {
    const chunks: Buffer[] = [];
    request.on('data', (chunk: Buffer) => chunks.push(chunk));
    request.on('end', () => {
      const recorded: RecordedRequest = {
        method: request.method ?? '',
        url: request.url ?? '',
        headers: request.headers,
        body: Buffer.concat(chunks).toString('utf8'),
      };
      requests.push(recorded);
      Promise.resolve(handler(recorded, response)).catch(() => response.destroy());
    });
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address() as AddressInfo;
  return {
    origin: `http://127.0.0.1:${port}`,
    requests,
    close: () =>
      new Promise<void>((resolve) => {
        server.close(() => resolve());
        server.closeAllConnections();
      }),
  };
}

/** Registers servers started in a test so they are closed afterwards. */
export function useServers(): (handler: Handler) => Promise<TestServer> {
  const started: TestServer[] = [];
  afterEach(async () => {
    await Promise.all(started.splice(0).map((server) => server.close()));
  });
  return async (handler) => {
    const server = await startServer(handler);
    started.push(server);
    return server;
  };
}

export const MESSAGE = {
  id: 'msg_test',
  type: 'message',
  role: 'assistant',
  model: 'claude-test',
  content: [{ type: 'text', text: 'OK' }],
  stop_reason: 'end_turn',
  stop_sequence: null,
  usage: { input_tokens: 1, output_tokens: 2 },
};

export const THINKING_BLOCK = { type: 'thinking', thinking: 'not for display', signature: 'sample' };

export const PARAMS = {
  model: 'claude-test',
  max_tokens: 32,
  messages: [{ role: 'user' as const, content: 'Hello' }],
};

export function sendJSON(response: ServerResponse, status: number, body: unknown, headers: Record<string, string> = {}): void {
  response.writeHead(status, { 'content-type': 'application/json', ...headers });
  response.end(JSON.stringify(body));
}

export function respondWith(message: unknown = MESSAGE): Handler {
  return (_request, response) => sendJSON(response, 200, message);
}

export function respondWithError(status: number, headers: Record<string, string> = {}): Handler {
  return (_request, response) =>
    sendJSON(response, status, { type: 'error', error: { type: 'api_error', message: 'test failure' } }, headers);
}

/** Never answers; the connection is closed when the test server is. */
export const hang: Handler = () => {};

/** Builds a Messages API event stream whose content blocks are the given `[type, text]` pairs. */
export function eventStream(blocks: ReadonlyArray<readonly ['text' | 'thinking', string]>): string {
  const events: Array<[string, Record<string, unknown>]> = [
    ['message_start', { message: { ...MESSAGE, content: [], stop_reason: null, usage: { input_tokens: 1, output_tokens: 0 } } }],
  ];
  blocks.forEach(([kind, text], index) => {
    events.push(['content_block_start', { index, content_block: kind === 'text' ? { type: 'text', text: '' } : { type: 'thinking', thinking: '', signature: '' } }]);
    events.push(['content_block_delta', { index, delta: kind === 'text' ? { type: 'text_delta', text } : { type: 'thinking_delta', thinking: text } }]);
    events.push(['content_block_stop', { index }]);
  });
  events.push(['message_delta', { delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 2 } }]);
  events.push(['message_stop', {}]);
  return events.map(([name, data]) => `event: ${name}\ndata: ${JSON.stringify({ type: name, ...data })}\n\n`).join('');
}

export function respondWithStream(blocks: ReadonlyArray<readonly ['text' | 'thinking', string]>): Handler {
  return (_request, response) => {
    response.writeHead(200, { 'content-type': 'text/event-stream' });
    response.end(eventStream(blocks));
  };
}

const AMBIENT_PREFIXES = ['ANTHROPIC_', 'CLAUDE_', 'AZURE_'];
const AMBIENT_NAMES = ['AUTH_MODE', 'API_KEY_HEADER', 'TOKEN_SCOPE'];

/** Gives each test an environment without any variable the SDK or the sample reads, and restores it afterwards. */
export function useCleanEnvironment(): void {
  let saved: NodeJS.ProcessEnv = {};
  beforeEach(() => {
    saved = { ...process.env };
    for (const name of Object.keys(process.env)) {
      if (AMBIENT_NAMES.includes(name) || AMBIENT_PREFIXES.some((prefix) => name.startsWith(prefix))) {
        delete process.env[name];
      }
    }
  });
  afterEach(() => {
    for (const name of Object.keys(process.env)) delete process.env[name];
    Object.assign(process.env, saved);
  });
}

export function nth(requests: readonly RecordedRequest[], index: number): RecordedRequest {
  const request = requests[index];
  assert.ok(request, `expected a request at index ${index}, saw ${requests.length}`);
  return request;
}

export function headerText(request: RecordedRequest): string {
  return JSON.stringify(request.headers);
}

/** Every request must be free of the placeholder credential and of the SDK's OAuth beta. */
export function assertCleanRequests(requests: readonly RecordedRequest[]): void {
  for (const request of requests) {
    const text = headerText(request);
    assert.ok(!text.includes('provided-by-request-middleware'), 'the placeholder credential must never be sent');
    assert.ok(!text.includes('oauth-2025-04-20'), 'the OAuth beta must not be added');
  }
}