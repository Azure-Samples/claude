/** Environment configuration shared by the sample entrypoint. */
import type Anthropic from '@anthropic-ai/sdk';

import { createClient, type CreateClientOptions, type CredentialProvider } from './client_auth.ts';
import { ConfigError } from './config_error.ts';
import { createCredential, createTokenProvider } from './token_provider.ts';

export type Environment = Readonly<Record<string, string | undefined>>;

export const DEFAULT_TOKEN_SCOPE = 'https://ai.azure.com/.default';

/** `anthropic` is the canonical ANTHROPIC_* family, `claude` the legacy CLAUDE_* family. */
export type Profile = 'anthropic' | 'claude';

export type SampleAuth =
  | { mode: 'bearer'; credential: string; tenantId: string | undefined; clientId: string | undefined; scope: string }
  | { mode: 'api_key'; apiKey: string; keyHeader: string };

export interface SampleSettings {
  profile: Profile;
  baseURL: string;
  model: string;
  /** Sent as `anthropic-version` only when ANTHROPIC_API_VERSION is set; otherwise the SDK default applies. */
  apiVersion: string | undefined;
  auth: SampleAuth;
}

export interface ClientOverrides {
  /** Replaces the Microsoft Entra ID token provider. */
  tokenProvider?: CredentialProvider;
  fetch?: CreateClientOptions['fetch'];
  maxRetries?: number;
  timeoutMs?: number;
}

interface ProfileVariables {
  baseURL: string;
  model: string;
  apiKey: string;
  /** The other family's variables, named in errors only; they are never read for this profile. */
  otherModel: string;
  otherKey: string;
  /** The canonical profile never defaults to a token: an ambient URL must not silently receive one. */
  explicitAuthMode: boolean;
}

const PROFILES: Record<Profile, ProfileVariables> = {
  anthropic: {
    baseURL: 'ANTHROPIC_BASE_URL',
    model: 'ANTHROPIC_MODEL',
    apiKey: 'ANTHROPIC_API_KEY',
    otherModel: 'CLAUDE_DEPLOYMENT_NAME',
    otherKey: 'CLAUDE_API_KEY',
    explicitAuthMode: true,
  },
  claude: {
    baseURL: 'CLAUDE_BASE_URL',
    model: 'CLAUDE_DEPLOYMENT_NAME',
    apiKey: 'CLAUDE_API_KEY',
    otherModel: 'ANTHROPIC_MODEL',
    otherKey: 'ANTHROPIC_API_KEY',
    explicitAuthMode: false,
  },
};

/**
 * ANTHROPIC_BASE_URL selects the canonical profile, otherwise CLAUDE_BASE_URL selects the legacy one.
 * The URL, model and key all come from the selected family, so a value from one family is never
 * combined with another family's endpoint.
 */
export function loadSettings(env: Environment): SampleSettings {
  const canonicalURL = env['ANTHROPIC_BASE_URL'];
  const legacyURL = env['CLAUDE_BASE_URL'];
  const profile: Profile | undefined = canonicalURL ? 'anthropic' : legacyURL ? 'claude' : undefined;
  const baseURL = canonicalURL || legacyURL;
  if (profile === undefined || !baseURL) {
    throw new ConfigError('Set ANTHROPIC_BASE_URL, ANTHROPIC_MODEL and AUTH_MODE, or the legacy CLAUDE_BASE_URL and CLAUDE_DEPLOYMENT_NAME.');
  }
  const names = PROFILES[profile];

  const model = env[names.model];
  if (!model) {
    throw new ConfigError(`${names.baseURL} is set, so ${names.model} is required; ${names.otherModel} is not used with it.`);
  }
  const requestedMode = env['AUTH_MODE'];
  if (!requestedMode && names.explicitAuthMode) {
    throw new ConfigError(`${names.baseURL} is set, so AUTH_MODE must be set explicitly to bearer or api_key.`);
  }
  const mode = requestedMode || 'bearer';
  const apiVersion = env['ANTHROPIC_API_VERSION'] || undefined;

  if (mode === 'bearer') {
    return {
      profile,
      baseURL,
      model,
      apiVersion,
      auth: {
        mode,
        credential: env['AZURE_TOKEN_CREDENTIALS'] || 'AzureCliCredential',
        tenantId: env['AZURE_TENANT_ID'] || undefined,
        clientId: env['AZURE_CLIENT_ID'] || undefined,
        scope: env['TOKEN_SCOPE'] || DEFAULT_TOKEN_SCOPE,
      },
    };
  }
  if (mode === 'api_key') {
    const apiKey = env[names.apiKey];
    if (!apiKey) {
      throw new ConfigError(`AUTH_MODE=api_key with ${names.baseURL} requires ${names.apiKey}; ${names.otherKey} is not used with it.`);
    }
    return { profile, baseURL, model, apiVersion, auth: { mode, apiKey, keyHeader: env['API_KEY_HEADER'] || 'Authorization' } };
  }
  throw new ConfigError('AUTH_MODE must be bearer or api_key.');
}

export function configuredClient(settings: SampleSettings, overrides: ClientOverrides = {}): Anthropic {
  const shared: Omit<CreateClientOptions, 'baseURL'> = {};
  if (settings.apiVersion !== undefined) shared.apiVersion = settings.apiVersion;
  if (overrides.fetch !== undefined) shared.fetch = overrides.fetch;
  if (overrides.maxRetries !== undefined) shared.maxRetries = overrides.maxRetries;
  if (overrides.timeoutMs !== undefined) shared.timeoutMs = overrides.timeoutMs;

  const { auth } = settings;
  if (auth.mode === 'api_key') {
    return createClient({ ...shared, baseURL: settings.baseURL, apiKey: auth.apiKey, keyHeader: auth.keyHeader });
  }
  const tokenProvider =
    overrides.tokenProvider ??
    createTokenProvider(createCredential(auth.credential, { tenantId: auth.tenantId, clientId: auth.clientId }), auth.scope);
  return createClient({ ...shared, baseURL: settings.baseURL, tokenProvider });
}