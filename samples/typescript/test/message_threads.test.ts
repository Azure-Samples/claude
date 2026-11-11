import assert from 'node:assert/strict';
import { it } from 'node:test';

import { FIRST_PROMPT, SECOND_PROMPT, run } from '../src/message_threads.ts';
import { MESSAGE, THINKING_BLOCK, hang, sendJSON, useCleanEnvironment, useServers } from './helpers.ts';

const serve = useServers();
useCleanEnvironment();
const BETA = 'message-threads-2026-08-12';
const first = { role: 'user', content: FIRST_PROMPT };
const second = { role: 'user', content: SECOND_PROMPT };

function output() {
  const result = { stdout: '', stderr: '' };
  return {
    result,
    io: {
      stdout: { write: (text: string) => { result.stdout += text; } },
      stderr: { write: (text: string) => { result.stderr += text; } },
    },
  };
}

it('creates then continues with only the new message and the beta on both calls', async () => {
  const server = await serve((_request, response) => sendJSON(response, 200, {
    ...MESSAGE, id: `msg_${server.requests.length}`,
    content: server.requests.length === 1 ? MESSAGE.content : [THINKING_BLOCK, { type: 'text', text: 'ORCHID-47' }],
  }));
  const { io, result } = output();
  const code = await run([], {
    CLAUDE_BASE_URL: `${server.origin}/anthropic`, CLAUDE_DEPLOYMENT_NAME: 'test-model',
  }, io, { tokenProvider: () => 'test-token', maxRetries: 0 });
  assert.equal(code, 0);
  assert.deepEqual(result, { stdout: 'ORCHID-47\n', stderr: '' });
  assert.equal(server.requests.length, 2);
  for (const request of server.requests) {
    assert.equal(request.method, 'POST');
    assert.equal(request.url.split('?')[0], '/anthropic/v1/messages');
    assert.equal(request.headers['anthropic-beta'], BETA);
    assert.equal(request.headers['authorization'], 'Bearer test-token');
    const body = JSON.parse(request.body);
    assert.equal(body.model, 'test-model');
    assert.equal(body.max_tokens, 1024);
  }
  const bodies = server.requests.map((request) => JSON.parse(request.body));
  assert.deepEqual(bodies[0].thread, { type: 'create' });
  assert.equal(bodies[0].system, 'Keep replies short.');
  assert.deepEqual(bodies[0].messages, [first]);
  assert.deepEqual(bodies[1].thread, { type: 'continue', previous_message_id: 'msg_1' });
  assert.deepEqual(bodies[1].messages, [second]);
  assert.ok(!('system' in bodies[1]));
  assert.ok(!('tools' in bodies[1]));
});

it('replays the complete conversation only for thread_not_found', async () => {
  const server = await serve((_request, response) => {
    if (server.requests.length === 2) {
      sendJSON(response, 404, { type: 'error', error: {
        type: 'not_found_error', message: 'expired', details: { error_code: 'thread_not_found' },
      } });
    } else {
      sendJSON(response, 200, MESSAGE);
    }
  });
  const { io } = output();
  assert.equal(await run([], {
    CLAUDE_BASE_URL: server.origin, CLAUDE_DEPLOYMENT_NAME: 'test-model',
  }, io, { tokenProvider: () => 'test-token', maxRetries: 0 }), 0);
  assert.equal(server.requests.length, 3);
  const replay = JSON.parse(server.requests[2]!.body);
  assert.deepEqual(replay.thread, { type: 'create' });
  assert.equal(replay.system, 'Keep replies short.');
  assert.deepEqual(replay.messages, [first, { role: 'assistant', content: MESSAGE.content }, second]);
  assert.ok(server.requests.every((request) => request.headers['anthropic-beta'] === BETA));
});

it('surfaces unrelated 404s and unsupported requests without unthreaded fallback', async () => {
  for (const [status, errorCode] of [[404, 'model_not_found'], [400, 'thread_unsupported_request']] as const) {
    const server = await serve((_request, response) => sendJSON(response,
      server.requests.length === 1 ? 200 : status,
      server.requests.length === 1 ? MESSAGE : { type: 'error', error: {
        type: status === 404 ? 'not_found_error' : 'invalid_request_error',
        message: 'canary-error-body', details: { error_code: errorCode },
      } }));
    const { io, result } = output();
    assert.equal(await run([], {
      CLAUDE_BASE_URL: server.origin, CLAUDE_DEPLOYMENT_NAME: 'test-model',
    }, io, { tokenProvider: () => 'test-token', maxRetries: 0 }), 1);
    assert.equal(server.requests.length, 2);
    assert.equal(result.stdout, '');
    assert.ok(result.stderr.includes(`HTTP ${status}`));
    assert.ok(!result.stderr.includes('canary-error-body'));
  }
});

it('rejects blank and thinking-only replies', async () => {
  for (const content of [[], [{ type: 'text', text: ' \n ' }], [THINKING_BLOCK]]) {
    const server = await serve((_request, response) => sendJSON(response, 200, {
      ...MESSAGE, content: server.requests.length === 1 ? MESSAGE.content : content,
    }));
    const { io, result } = output();
    assert.equal(await run([], {
      CLAUDE_BASE_URL: server.origin, CLAUDE_DEPLOYMENT_NAME: 'test-model',
    }, io, { tokenProvider: () => 'test-token', maxRetries: 0 }), 1);
    assert.equal(result.stdout, '');
    assert.ok(result.stderr.includes('No text response'));
  }
});

it('honors the deadline, configuration errors and command usage', async () => {
  const server = await serve(hang);
  const { io, result } = output();
  assert.equal(await run([], {
    CLAUDE_BASE_URL: server.origin, CLAUDE_DEPLOYMENT_NAME: 'test-model',
  }, io, { tokenProvider: () => 'test-token', maxRetries: 0, totalTimeoutMs: 50 }), 1);
  assert.ok(result.stderr.includes('timed out'));
  assert.equal(await run([], {}, output().io), 1);
  assert.equal(await run(['--stream'], {}, output().io), 2);
  assert.equal(await run(['--help'], {}, output().io), 0);
});
