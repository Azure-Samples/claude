/**
 * Calls a Claude model through the standard Anthropic SDK.
 *
 *   node src/main.ts                 print the reply text and token usage
 *   node src/main.ts --stream        stream the reply text as it arrives
 *   node src/main.ts "your prompt"   use your own prompt
 *
 * Exits 0 only when the reply has text; thinking-only or empty replies and every
 * error exit nonzero. Errors report the HTTP status and error type but never the
 * credential, endpoint, model name or response body.
 */
import { parseArgs } from 'node:util';

import type Anthropic from '@anthropic-ai/sdk';
import { APIConnectionError, APIConnectionTimeoutError, APIError, APIUserAbortError } from '@anthropic-ai/sdk';

import { ClientAuthError } from './client_auth.ts';
import { ConfigError } from './config_error.ts';
import { configuredClient, loadSettings, type ClientOverrides, type Environment } from './sample_client.ts';

const DEFAULT_PROMPT = 'What are 3 things to visit in Seattle?';
const MAX_TOKENS = 1024;
// Application policy of this sample, not a helper default: the whole call, including SDK retries and
// streaming, ends after 120 seconds. The SDK's own per-attempt timeout and retry defaults are untouched.
const TOTAL_TIMEOUT_MS = 120_000;
const USAGE = 'Usage: node src/main.ts [--stream] [prompt...]';

export interface Output {
  write(text: string): unknown;
}

export interface RunIO {
  stdout: Output;
  stderr: Output;
}

export interface RunOptions extends ClientOverrides {
  /** Deadline for the whole call, including SDK retries and streaming. */
  totalTimeoutMs?: number;
}

interface MessageRequest {
  model: string;
  max_tokens: number;
  messages: Array<{ role: 'user'; content: string }>;
}

export async function run(argv: readonly string[], env: Environment, io: RunIO, options: RunOptions = {}): Promise<number> {
  let command: { stream: boolean; help: boolean; prompt: string };
  try {
    command = parseCommandLine(argv);
  } catch {
    io.stderr.write(`${USAGE}\n`);
    return 2;
  }
  if (command.help) {
    io.stdout.write(`${USAGE}\n`);
    return 0;
  }

  const totalTimeoutMs = options.totalTimeoutMs ?? TOTAL_TIMEOUT_MS;
  const signal = AbortSignal.timeout(totalTimeoutMs);
  try {
    const settings = loadSettings(env);
    const client = configuredClient(settings, options);
    const request: MessageRequest = {
      model: settings.model,
      max_tokens: MAX_TOKENS,
      messages: [{ role: 'user', content: command.prompt }],
    };
    return command.stream ? await streamReply(client, request, signal, io) : await printReply(client, request, signal, io);
  } catch (error) {
    io.stderr.write(`${describeError(error, signal, totalTimeoutMs)}\n`);
    return 1;
  }
}

function parseCommandLine(argv: readonly string[]): { stream: boolean; help: boolean; prompt: string } {
  const { values, positionals } = parseArgs({
    args: [...argv],
    options: { stream: { type: 'boolean' }, help: { type: 'boolean', short: 'h' } },
    allowPositionals: true,
  });
  return {
    stream: values.stream === true,
    help: values.help === true,
    prompt: positionals.join(' ').trim() || DEFAULT_PROMPT,
  };
}

async function printReply(client: Anthropic, request: MessageRequest, signal: AbortSignal, io: RunIO): Promise<number> {
  const message = await client.messages.create(request, { signal });
  let hasText = false;
  for (const block of message.content) {
    if (block.type === 'text' && block.text.trim()) {
      io.stdout.write(`${block.text}\n`);
      hasText = true;
    }
  }
  if (!hasText) return noText(message.stop_reason, io);
  io.stdout.write(`\n[usage] input=${message.usage.input_tokens} output=${message.usage.output_tokens}\n`);
  return 0;
}

async function streamReply(client: Anthropic, request: MessageRequest, signal: AbortSignal, io: RunIO): Promise<number> {
  const stream = client.messages.stream(request, { signal });
  let hasText = false;
  stream.on('text', (delta) => {
    if (delta.trim()) hasText = true;
    io.stdout.write(delta);
  });
  const message = await stream.finalMessage();
  io.stdout.write('\n');
  return hasText ? 0 : noText(message.stop_reason, io);
}

function noText(stopReason: string | null, io: RunIO): number {
  io.stderr.write(`No text response (stop_reason=${stopReason}). Increase max_tokens if the response exhausted its budget.\n`);
  return 1;
}

const HTTP_HINTS: Array<[(status: number) => boolean, string]> = [
  [(status) => status >= 300 && status < 400, 'The endpoint answered with a redirect, which is never followed.'],
  [(status) => status === 401, 'The credential was rejected. Check AUTH_MODE, the token scope or the API key.'],
  [(status) => status === 403, 'The caller is not permitted to use this resource. Check its role assignment or key.'],
  [(status) => status === 404, 'The endpoint path or model name was not found. Check the base URL and model settings.'],
  [(status) => status === 429, 'The request was rate limited. Retry later.'],
  [(status) => status >= 500, 'The service reported an error. Retry later.'],
];

function describeError(error: unknown, signal: AbortSignal, totalTimeoutMs: number): string {
  if (error instanceof ConfigError) return error.message;
  if (error instanceof ClientAuthError) {
    const cause = error.cause instanceof Error ? ` Cause: ${error.cause.name}.` : '';
    const hint = cause ? ' Sign in with the Azure CLI or select another AZURE_TOKEN_CREDENTIALS.' : '';
    return `${error.message}${cause}${hint}`;
  }
  if (error instanceof APIUserAbortError) {
    return signal.aborted ? `Request timed out after ${totalTimeoutMs / 1000} seconds.` : 'Request was cancelled.';
  }
  if (error instanceof APIConnectionTimeoutError) return 'Request timed out.';
  if (error instanceof APIConnectionError) return 'Could not connect to the endpoint.';
  if (error instanceof APIError) {
    const type = (error.error as { error?: { type?: unknown } } | undefined)?.error?.type;
    const label = typeof type === 'string' && /^[a-z_]{1,64}$/.test(type) ? ` (${type})` : '';
    const hint = HTTP_HINTS.find(([matches]) => matches(error.status ?? 0))?.[1];
    return `Request failed with HTTP ${error.status}${label}.${hint ? ` ${hint}` : ''}`;
  }
  return `Unexpected error (${error instanceof Error ? error.name : typeof error}).`;
}

if (import.meta.main) {
  process.exitCode = await run(process.argv.slice(2), process.env, process);
}