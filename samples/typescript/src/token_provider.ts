/** Explicit Microsoft Entra ID credential selection and bearer-token acquisition. */
import {
  AzureCliCredential,
  AzureDeveloperCliCredential,
  ManagedIdentityCredential,
  getBearerTokenProvider,
  type TokenCredential,
} from '@azure/identity';

import { ConfigError } from './config_error.ts';

export const CREDENTIAL_CHOICES = ['AzureCliCredential', 'AzureDeveloperCliCredential', 'ManagedIdentityCredential'] as const;

/** Both CLI credentials start a process for each token request; this leaves room for a cold start under load. */
export const CLI_PROCESS_TIMEOUT_MS = 60_000;

export interface CliCredentialOptions {
  tenantId?: string;
  processTimeoutInMs?: number;
}

export interface CredentialConstructors {
  AzureCliCredential: new (options?: CliCredentialOptions) => TokenCredential;
  AzureDeveloperCliCredential: new (options?: CliCredentialOptions) => TokenCredential;
  ManagedIdentityCredential: new (options?: { clientId?: string }) => TokenCredential;
}

export interface CredentialIds {
  tenantId?: string | undefined;
  clientId?: string | undefined;
}

const AZURE_IDENTITY_CREDENTIALS: CredentialConstructors = {
  AzureCliCredential,
  AzureDeveloperCliCredential,
  ManagedIdentityCredential,
};

const cliOptions = (tenantId: string | undefined): CliCredentialOptions =>
  tenantId ? { tenantId, processTimeoutInMs: CLI_PROCESS_TIMEOUT_MS } : { processTimeoutInMs: CLI_PROCESS_TIMEOUT_MS };

/**
 * Builds exactly the credential named by AZURE_TOKEN_CREDENTIALS, with no fallback chain.
 * The tenant applies to the two CLI credentials, which also get a process timeout, and the
 * client ID to the managed identity.
 */
export function createCredential(
  source: string,
  ids: CredentialIds = {},
  constructors: CredentialConstructors = AZURE_IDENTITY_CREDENTIALS,
): TokenCredential {
  switch (source) {
    case 'AzureCliCredential':
      return new constructors.AzureCliCredential(cliOptions(ids.tenantId));
    case 'AzureDeveloperCliCredential':
      return new constructors.AzureDeveloperCliCredential(cliOptions(ids.tenantId));
    case 'ManagedIdentityCredential':
      return new constructors.ManagedIdentityCredential(ids.clientId ? { clientId: ids.clientId } : {});
    default:
      throw new ConfigError(`AZURE_TOKEN_CREDENTIALS must be ${CREDENTIAL_CHOICES.join(', ')}.`);
  }
}

/**
 * The official helper: its callback keeps the token it received and asks the credential
 * for a new one shortly before it expires (it is built on the @azure/core-rest-pipeline
 * token cycler), so a long-running caller does not run the credential on every request.
 */
export function createTokenProvider(credential: TokenCredential, scope: string): () => Promise<string> {
  return getBearerTokenProvider(credential, scope);
}