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

// Built-in role definition IDs.
// NOTE: Azure renamed these roles. The GUIDs are stable.
//   53ca6127-... : "Azure AI User" -> "Foundry User" (data-plane access)
//   eadc314b-... : "Azure AI Project Manager" -> "Foundry Project Manager"
var foundryUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'
var foundryProjectManagerRoleId = 'eadc314b-1a2d-4efa-be10-5d325db5065e'

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

// Role assignments are declared BEFORE the model deployments so each
// deployment can dependsOn them. The model-deployment LRO can take
// 30s-20min depending on region and family; chaining the role grants
// first turns that wait into free RBAC propagation time and makes the
// first call after `azd up` succeed without the usual 5-min lag.
// When rbacEnabled is false, both resources are `if(false)` and Bicep
// drops the dependsOn edge automatically.
resource foundryUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (rbacEnabled) {
  name: guid(account.id, principalId, foundryUserRoleId)
  scope: account
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRoleId)
    principalId: principalId
    principalType: 'User'
  }
}

resource foundryProjectManagerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (rbacEnabled) {
  name: guid(account.id, principalId, foundryProjectManagerRoleId)
  scope: account
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryProjectManagerRoleId)
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
    foundryUserAssignment
    foundryProjectManagerAssignment
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
  // 409s on concurrent create. Role assignments are listed too so the
  // first inference call after `azd up` doesn't hit RBAC propagation lag.
  dependsOn: [
    project
    haikuDeployment
    foundryUserAssignment
    foundryProjectManagerAssignment
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
    foundryUserAssignment
    foundryProjectManagerAssignment
  ]
}

output claudeBaseUrl string = 'https://${account.name}.services.ai.azure.com/anthropic'
output foundryProjectEndpoint string = 'https://${account.name}.services.ai.azure.com/api/projects/${project.name}'
output foundryAccountName string = account.name
output haikuDeploymentName string  = haikuDeploymentNameVar
output sonnetDeploymentName string = sonnetDeploymentNameVar
output opusDeploymentName string   = opusDeploymentNameVar
