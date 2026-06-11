// Foundry account + project + per-family Claude deployments + optional RBAC.
//
// Each of haikuModel / sonnetModel / opusModel is independent. Empty string
// means "skip that family". The three deployments share the same Foundry
// account; the per-family capacity controls TPM allocation.
param location string
param tags object
param accountName string
param projectName string
param suffix string

param haikuModel string
param sonnetModel string
param opusModel string
param haikuCapacity int
param sonnetCapacity int
param opusCapacity int
param modelVersion string

param claudeOrganizationName string
param claudeCountryCode string
param claudeIndustry string
param principalId string
param assignRbac string

var rbacEnabled = toLower(assignRbac) == 'true' && !empty(principalId)
var nameSuffix = take(suffix, 6)

// Pre-compute deployment names so outputs work even when a family is skipped.
var haikuDeploymentNameVar  = empty(haikuModel)  ? '' : '${haikuModel}-${nameSuffix}'
var sonnetDeploymentNameVar = empty(sonnetModel) ? '' : '${sonnetModel}-${nameSuffix}'
var opusDeploymentNameVar   = empty(opusModel)   ? '' : '${opusModel}-${nameSuffix}'

// Built-in role definition ID for the documented least-privilege inference
// role on a Foundry account. See:
//   https://learn.microsoft.com/azure/foundry/foundry-models/how-to/configure-entra-id#for-making-authenticated-api-calls
// `Cognitive Services User` grants exactly the data action this template's
// runtime needs (`Microsoft.CognitiveServices/accounts/MaaS/*`) and nothing
// else. The broader `Foundry User` / `Azure AI Developer` roles also work
// and are documented in README.md for users who deliberately want more.
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource account 'Microsoft.CognitiveServices/accounts@2025-10-01-preview' = {
  name: accountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: accountName
    allowProjectManagement: true
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-10-01-preview' = {
  parent: account
  name: projectName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

// Role assignment is declared BEFORE the model deployments so each
// deployment can dependsOn it. The model-deployment LRO can take
// 30s-20min depending on region and family; chaining the role grant
// first turns that wait into free RBAC propagation time and makes the
// first call after `azd up` succeed without the usual 5-min lag.
// When rbacEnabled is false, the resource is `if(false)` and Bicep
// drops the dependsOn edge automatically.
resource cognitiveServicesUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (rbacEnabled) {
  name: guid(account.id, principalId, cognitiveServicesUserRoleId)
  scope: account
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: principalId
    principalType: 'User'
  }
}

resource haikuDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview' = if (!empty(haikuModel)) {
  parent: account
  name: haikuDeploymentNameVar
  sku: {
    name: 'GlobalStandard'
    capacity: haikuCapacity
  }
  properties: {
    model: {
      format: 'Anthropic'
      name: haikuModel
      version: modelVersion
    }
    modelProviderData: {
      organizationName: claudeOrganizationName
      countryCode: claudeCountryCode
      industry: claudeIndustry
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
    raiPolicyName: 'Microsoft.DefaultV2'
  }
  dependsOn: [
    project
    cognitiveServicesUserAssignment
  ]
}

resource sonnetDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview' = if (!empty(sonnetModel)) {
  parent: account
  name: sonnetDeploymentNameVar
  sku: {
    name: 'GlobalStandard'
    capacity: sonnetCapacity
  }
  properties: {
    model: {
      format: 'Anthropic'
      name: sonnetModel
      version: modelVersion
    }
    modelProviderData: {
      organizationName: claudeOrganizationName
      countryCode: claudeCountryCode
      industry: claudeIndustry
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
    raiPolicyName: 'Microsoft.DefaultV2'
  }
  // Foundry serializes deployments under one account; chain them to avoid
  // 409s on concurrent create. The role assignment is listed too so the
  // first inference call after `azd up` doesn't hit RBAC propagation lag.
  dependsOn: [
    project
    haikuDeployment
    cognitiveServicesUserAssignment
  ]
}

resource opusDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview' = if (!empty(opusModel)) {
  parent: account
  name: opusDeploymentNameVar
  sku: {
    name: 'GlobalStandard'
    capacity: opusCapacity
  }
  properties: {
    model: {
      format: 'Anthropic'
      name: opusModel
      version: modelVersion
    }
    modelProviderData: {
      organizationName: claudeOrganizationName
      countryCode: claudeCountryCode
      industry: claudeIndustry
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
    raiPolicyName: 'Microsoft.DefaultV2'
  }
  dependsOn: [
    project
    sonnetDeployment
    cognitiveServicesUserAssignment
  ]
}

output claudeBaseUrl string = 'https://${account.name}.services.ai.azure.com/anthropic'
output foundryProjectEndpoint string = 'https://${account.name}.services.ai.azure.com/api/projects/${project.name}'
output foundryAccountName string = account.name
output haikuDeploymentName string  = haikuDeploymentNameVar
output sonnetDeploymentName string = sonnetDeploymentNameVar
output opusDeploymentName string   = opusDeploymentNameVar
