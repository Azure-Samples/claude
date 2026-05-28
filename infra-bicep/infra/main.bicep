// ============================================================================
// Microsoft Foundry + Claude — Bicep (azd-driven)
// ----------------------------------------------------------------------------
// IMPORTANT: Deploying this Bicep auto-accepts the Anthropic Marketplace
// offer terms via the `modelProviderData` block on each deployment. Review
// https://www.anthropic.com/legal/commercial-terms and the IMPORTANT note in
// README.md before running `azd up`. Set `claudeOrganizationName`,
// `claudeCountryCode`, `claudeIndustry` to match your real organization.
// ----------------------------------------------------------------------------
// `modelProviderData` is REQUIRED for Claude deployments. `industry`
// MUST be lowercase to match the Foundry portal dropdown.
// `allowProjectManagement = true` is required to create projects under the
// Foundry account.
//
// Per-family deployment mode:
//   Set any of CLAUDE_HAIKU_MODEL / CLAUDE_SONNET_MODEL / CLAUDE_OPUS_MODEL to
//   deploy that family (empty = skip). Each family gets its own capacity var.
//   If all three family vars are empty, falls back to legacy CLAUDE_MODEL_NAME
//   single-deployment behavior.
// ============================================================================
targetScope = 'subscription'

@description('azd environment name. Used for resource group + tagging.')
param environmentName string

@description('Azure region. All three families coexist in eastus2 or swedencentral.')
@allowed([
  'eastus2'
  'swedencentral'
  'westus2'
])
param location string

@description('Object id of the deploying user/SP. Empty disables RBAC.')
param principalId string = ''

@description('Whether to assign Foundry User + Foundry Project Manager (formerly Azure AI User / Project Manager) to principalId. Set to "true" to enable.')
param assignRbac string = 'false'

@description('Short prefix for resource names.')
param baseName string = 'claude'

// --- Per-family model selection (preferred) ---------------------------------
@description('Haiku family model id. Empty = do not deploy haiku.')
param haikuModel string = ''
@description('Sonnet family model id. Empty = do not deploy sonnet.')
param sonnetModel string = ''
@description('Opus family model id. Empty = do not deploy opus.')
param opusModel string = ''

@description('Haiku deployment capacity (TPM / 1000). Default 25 is a low-risk value that fits most subscriptions; raise via `azd env set CLAUDE_HAIKU_CAPACITY <n>` when quota allows.')
param haikuCapacity int = 25
@description('Sonnet deployment capacity (TPM / 1000). Default 25 is a low-risk value that fits most subscriptions; raise via `azd env set CLAUDE_SONNET_CAPACITY <n>` when quota allows.')
param sonnetCapacity int = 25
@description('Opus deployment capacity (TPM / 1000). Default 25 is a low-risk value that fits most subscriptions; raise via `azd env set CLAUDE_OPUS_CAPACITY <n>` when quota allows.')
param opusCapacity int = 25

@description('Model version for each family deployment.')
param modelVersion string = '1'

// --- Legacy single-model fallback -------------------------------------------
// Only used when none of haikuModel / sonnetModel / opusModel are set.
@description('Legacy single-model name. Ignored when any of the per-family vars are set.')
param modelName string = 'claude-sonnet-4-6'
@description('Legacy single-model capacity. Ignored when any of the per-family vars are set.')
param modelCapacity int = 25

// --- modelProviderData ------------------------------------------------------
@description('Organization name surfaced via modelProviderData.')
param claudeOrganizationName string
@description('Two-letter ISO country code.')
@minLength(2)
@maxLength(2)
param claudeCountryCode string = 'US'
@description('Industry — MUST be lowercase to match Foundry portal dropdown.')
@allowed([
  'technology'
  'finance'
  'healthcare'
  'education'
  'retail'
  'manufacturing'
  'government'
  'media'
  'other'
])
param claudeIndustry string = 'technology'

var tags = {
  'azd-env-name': environmentName
}
var suffix = take(uniqueString(subscription().id, environmentName), 8)
var accountName = '${baseName}-foundry-${suffix}'
var projectName = '${baseName}-proj-${suffix}'

// Resolve effective per-family models. If no family vars are set, route the
// legacy modelName into its matching slot for back-compat.
var anyFamilySet = !empty(haikuModel) || !empty(sonnetModel) || !empty(opusModel)
var legacyLower = toLower(modelName)
var legacyIsHaiku  = contains(legacyLower, 'haiku')
var legacyIsSonnet = contains(legacyLower, 'sonnet')
var legacyIsOpus   = contains(legacyLower, 'opus')

var effectiveHaikuModel    = anyFamilySet ? haikuModel  : (legacyIsHaiku  ? modelName : '')
var effectiveSonnetModel   = anyFamilySet ? sonnetModel : (legacyIsSonnet ? modelName : '')
var effectiveOpusModel     = anyFamilySet ? opusModel   : (legacyIsOpus   ? modelName : '')
var effectiveHaikuCapacity  = anyFamilySet ? haikuCapacity  : modelCapacity
var effectiveSonnetCapacity = anyFamilySet ? sonnetCapacity : modelCapacity
var effectiveOpusCapacity   = anyFamilySet ? opusCapacity   : modelCapacity

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

module foundry 'foundry.bicep' = {
  name: 'foundry-deploy'
  scope: rg
  params: {
    location: location
    tags: tags
    accountName: accountName
    projectName: projectName
    suffix: suffix
    haikuModel: effectiveHaikuModel
    sonnetModel: effectiveSonnetModel
    opusModel: effectiveOpusModel
    haikuCapacity: effectiveHaikuCapacity
    sonnetCapacity: effectiveSonnetCapacity
    opusCapacity: effectiveOpusCapacity
    modelVersion: modelVersion
    claudeOrganizationName: claudeOrganizationName
    claudeCountryCode: claudeCountryCode
    claudeIndustry: claudeIndustry
    principalId: principalId
    assignRbac: assignRbac
  }
}

output CLAUDE_BASE_URL string = foundry.outputs.claudeBaseUrl
output FOUNDRY_PROJECT_ENDPOINT string = foundry.outputs.foundryProjectEndpoint
output FOUNDRY_ACCOUNT_NAME string = foundry.outputs.foundryAccountName
output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_LOCATION string = location

// Per-family deployment names. Empty string when that family wasn't deployed.
output CLAUDE_HAIKU_DEPLOYMENT_NAME string  = foundry.outputs.haikuDeploymentName
output CLAUDE_SONNET_DEPLOYMENT_NAME string = foundry.outputs.sonnetDeploymentName
output CLAUDE_OPUS_DEPLOYMENT_NAME string   = foundry.outputs.opusDeploymentName

// Legacy single-deployment-name output. Set to the first non-empty family
// deployment so older configure-claude-code scripts continue to work.
output CLAUDE_DEPLOYMENT_NAME string = !empty(foundry.outputs.sonnetDeploymentName) ? foundry.outputs.sonnetDeploymentName : (!empty(foundry.outputs.opusDeploymentName) ? foundry.outputs.opusDeploymentName : foundry.outputs.haikuDeploymentName)
