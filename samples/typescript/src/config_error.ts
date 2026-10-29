/** A problem with the sample's environment configuration; the message names only variables, never values. */
export class ConfigError extends Error {
  override name = 'ConfigError';
}