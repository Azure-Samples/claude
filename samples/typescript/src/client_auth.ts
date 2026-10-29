/**
 * Builds a stock `Anthropic` client whose credential is chosen explicitly and
 * resolved for every HTTP attempt.
 *
 * The helper only uses public SDK options: an explicit non-secret placeholder
 * `apiKey` (so the SDK never looks at ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN,
 * ANTHROPIC_PROFILE or a profile on disk) and one `middleware`. The middleware
 * runs for each attempt, including SDK retries, and:
 *   - refuses any request whose origin differs from the configured base URL;
 *   - replaces every credential-bearing header (SDK, ambient and per-request)
 *     with the single selected credential;
 *   - forces `redirect: "manual"`, so a redirect is never followed and the SDK
 *     reports the redirect status as an error.
 * It does not use the SDK's `credentials` provider path, so no OAuth beta
 * header is added and no SDK token cache or 401 refresh is involved.
 */
import Anthropic, { AnthropicError, type ClientOptions, type Middleware } from '@anthropic-ai/sdk';

/** Returns the credential for one HTTP attempt; it is called again for each retry. */
export type CredentialProvider = () => string | Promise<string>;

export interface CreateClientOptions {
  /** Messages API base URL. HTTPS only; plain HTTP is accepted for loopback hosts. */
  baseURL: string;
  /** Bearer-token callback, sent as `Authorization: Bearer <token>`. Pass this or `apiKey`. */
  tokenProvider?: CredentialProvider;
  /** Static API key. Pass this or `tokenProvider`. */
  apiKey?: string;
  /** Header that carries `apiKey`: `Authorization` (sent as `Bearer <key>`) or a raw-key header such as `x-api-key`. */
  keyHeader?: string;
  /** Overrides the SDK's `anthropic-version` header; the SDK default applies when omitted. */
  apiVersion?: string;
  /** SDK retry count; the SDK default applies when omitted. */
  maxRetries?: number;
  /** SDK timeout for one HTTP attempt, in milliseconds; the SDK default applies when omitted. */
  timeoutMs?: number;
  /** Alternate `fetch`, for tests or a custom transport. */
  fetch?: ClientOptions['fetch'];
}

/** Raised before a request is sent when the credential cannot be applied safely. */
export class ClientAuthError extends AnthropicError {
  override name = 'ClientAuthError';
}

/** Sent to the SDK in place of a credential; the middleware always replaces it, so it never reaches the network. */
export const PLACEHOLDER_CREDENTIAL = 'provided-by-request-middleware';

const CREDENTIAL_HEADERS = ['authorization', 'x-api-key', 'api-key'];
const HEADER_NAME = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;
const LOOPBACK_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]']);

export function createClient(options: CreateClientOptions): Anthropic {
  const url = parseBaseURL(options.baseURL);
  const { tokenProvider, apiKey } = options;
  if ((tokenProvider === undefined) === (apiKey === undefined)) {
    throw new TypeError('Provide exactly one of tokenProvider or apiKey.');
  }
  if (tokenProvider !== undefined && typeof tokenProvider !== 'function') {
    throw new TypeError('tokenProvider must be a function.');
  }
  if (apiKey !== undefined && !isSecret(apiKey)) {
    throw new TypeError('apiKey must be a nonempty, single-line string.');
  }
  const keyHeader = options.keyHeader ?? 'Authorization';
  if (!HEADER_NAME.test(keyHeader)) {
    throw new TypeError('keyHeader must be a valid HTTP header name.');
  }
  if (options.apiVersion !== undefined && !/^[\x21-\x7e]+$/.test(options.apiVersion)) {
    throw new TypeError('apiVersion must be a nonempty string of printable ASCII characters.');
  }
  if (options.timeoutMs !== undefined && (!Number.isInteger(options.timeoutMs) || options.timeoutMs <= 0)) {
    throw new TypeError('timeoutMs must be a positive integer.');
  }

  const source: CredentialProvider = tokenProvider ?? (() => apiKey as string);
  const header = tokenProvider !== undefined ? 'Authorization' : keyHeader;
  const bearer = header.toLowerCase() === 'authorization';
  const origin = url.origin;

  const authorize: Middleware = async (request, next) => {
    if (!sameOrigin(request.url, origin)) {
      throw new ClientAuthError('Refusing to send credentials to a different origin.');
    }
    const value = await acquire(source, request.signal);
    const headers = new Headers(request.headers);
    for (const name of CREDENTIAL_HEADERS) headers.delete(name);
    headers.delete(header);
    try {
      headers.set(header, bearer ? `Bearer ${value}` : value);
    } catch {
      // The runtime's own error text can echo the rejected value, so it is not kept.
      throw new ClientAuthError('The credential is not a valid HTTP header value.');
    }
    return next({ ...request, headers, redirect: 'manual' });
  };

  const sdkOptions: ClientOptions = {
    baseURL: options.baseURL,
    apiKey: PLACEHOLDER_CREDENTIAL,
    webhookKey: null,
    middleware: [authorize],
  };
  if (options.maxRetries !== undefined) sdkOptions.maxRetries = options.maxRetries;
  if (options.timeoutMs !== undefined) sdkOptions.timeout = options.timeoutMs;
  if (options.apiVersion !== undefined) sdkOptions.defaultHeaders = { 'anthropic-version': options.apiVersion };
  if (options.fetch !== undefined) sdkOptions.fetch = options.fetch;
  return new Anthropic(sdkOptions);
}

function parseBaseURL(baseURL: string): URL {
  const invalid = () => new TypeError('baseURL must be an HTTPS URL without credentials, query, or fragment.');
  let url: URL;
  try {
    url = new URL(baseURL);
  } catch {
    throw invalid();
  }
  const secure = url.protocol === 'https:' || (url.protocol === 'http:' && LOOPBACK_HOSTS.has(url.hostname));
  if (!secure || !url.hostname || url.username || url.password || url.search || url.hash) throw invalid();
  return url;
}

function sameOrigin(requestURL: string, origin: string): boolean {
  try {
    return new URL(requestURL).origin === origin;
  } catch {
    return false;
  }
}

function isSecret(value: unknown): value is string {
  return typeof value === 'string' && value.trim() !== '' && !/[\r\n]/.test(value);
}

async function acquire(source: CredentialProvider, signal: AbortSignal | null | undefined): Promise<string> {
  let value: unknown;
  try {
    value = await untilAborted(Promise.resolve().then(source), signal);
  } catch (error) {
    // An abort is rethrown as is so the SDK reports it as a cancellation.
    if (signal?.aborted) throw error;
    throw new ClientAuthError('The credential provider failed.', { cause: error });
  }
  if (!isSecret(value)) {
    throw new ClientAuthError('The credential provider must return a nonempty, single-line string.');
  }
  return value;
}

function untilAborted<T>(promise: Promise<T>, signal: AbortSignal | null | undefined): Promise<T> {
  if (!signal) return promise;
  const reason = () => signal.reason ?? new DOMException('This operation was aborted', 'AbortError');
  if (signal.aborted) {
    promise.catch(() => {});
    return Promise.reject(reason());
  }
  return new Promise<T>((resolve, reject) => {
    const abort = () => reject(reason());
    signal.addEventListener('abort', abort, { once: true });
    promise.then(resolve, reject).finally(() => signal.removeEventListener('abort', abort));
  });
}