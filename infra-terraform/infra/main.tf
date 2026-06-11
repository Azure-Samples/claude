# ============================================================================
# Microsoft Foundry + Claude — Terraform (azd-driven)
# ----------------------------------------------------------------------------
# IMPORTANT: Applying this Terraform auto-accepts the Anthropic Marketplace
# offer terms via the `modelProviderData` block on each deployment. Review
# https://www.anthropic.com/legal/commercial-terms and the IMPORTANT note in
# README.md before running `azd up`. Set `claude_organization_name`,
# `claude_country_code`, `claude_industry` to match your real organization.
# ----------------------------------------------------------------------------
# - Foundry account is created via `azapi_resource` so we can set
#   `allowProjectManagement = true` (required for child projects, not yet
#   exposed by `azurerm_cognitive_account`).
# - Claude deployments are also `azapi_resource` because `modelProviderData`
#   isn't yet exposed by `azurerm_cognitive_deployment` (issue #31140).
# - Per-family deployment mode: set any of haiku_model / sonnet_model /
#   opus_model to deploy that family (empty = skip). All three families
#   share one Foundry account.
# ============================================================================

locals {
  tags = {
    "azd-env-name" = var.environment_name
  }
  account_name = "${var.base_name}-foundry-${random_string.suffix.result}"
  project_name = "${var.base_name}-proj-${random_string.suffix.result}"
  name_suffix  = substr(random_string.suffix.result, 0, 6)

  # Resolve effective per-family models. If no family vars are set, route the
  # legacy model_name into its matching slot for back-compat.
  any_family_set   = var.haiku_model != "" || var.sonnet_model != "" || var.opus_model != ""
  legacy_lower     = lower(var.model_name)
  legacy_is_haiku  = strcontains(local.legacy_lower, "haiku")
  legacy_is_sonnet = strcontains(local.legacy_lower, "sonnet")
  legacy_is_opus   = strcontains(local.legacy_lower, "opus")

  effective_haiku_model     = local.any_family_set ? var.haiku_model : (local.legacy_is_haiku ? var.model_name : "")
  effective_sonnet_model    = local.any_family_set ? var.sonnet_model : (local.legacy_is_sonnet ? var.model_name : "")
  effective_opus_model      = local.any_family_set ? var.opus_model : (local.legacy_is_opus ? var.model_name : "")
  effective_haiku_capacity  = local.any_family_set ? tonumber(var.haiku_capacity) : tonumber(var.model_capacity)
  effective_sonnet_capacity = local.any_family_set ? tonumber(var.sonnet_capacity) : tonumber(var.model_capacity)
  effective_opus_capacity   = local.any_family_set ? tonumber(var.opus_capacity) : tonumber(var.model_capacity)
}

resource "random_string" "suffix" {
  length  = 8
  upper   = false
  special = false
  numeric = true
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-${var.environment_name}"
  location = var.location
  tags     = local.tags
}

# --- Microsoft Foundry account (kind = AIServices) ------------------------
resource "azapi_resource" "foundry" {
  type      = "Microsoft.CognitiveServices/accounts@2025-10-01-preview"
  name      = local.account_name
  parent_id = azurerm_resource_group.rg.id
  location  = azurerm_resource_group.rg.location
  tags      = local.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    kind = "AIServices"
    sku = {
      name = "S0"
    }
    properties = {
      customSubDomainName    = local.account_name
      allowProjectManagement = true
      publicNetworkAccess    = "Enabled"
      disableLocalAuth       = false
    }
  }

  response_export_values = ["name", "identity.principalId"]
}

# --- Foundry project ------------------------------------------------------
resource "azapi_resource" "project" {
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-10-01-preview"
  name      = local.project_name
  parent_id = azapi_resource.foundry.id
  location  = azurerm_resource_group.rg.location
  tags      = local.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {}
  }

  response_export_values = ["name"]
}

# --- Per-family Claude deployments ----------------------------------------
# Each family is conditional on its model var being non-empty. Sonnet and Opus
# chain on the prior deployment to avoid Foundry's per-account serialization
# 409s on concurrent create.
resource "azapi_resource" "claude_haiku" {
  count                     = local.effective_haiku_model == "" ? 0 : 1
  type                      = "Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview"
  name                      = "${local.effective_haiku_model}-${local.name_suffix}"
  parent_id                 = azapi_resource.foundry.id
  schema_validation_enabled = false # required to allow modelProviderData

  body = {
    sku = {
      name     = "GlobalStandard"
      capacity = local.effective_haiku_capacity
    }
    properties = {
      model = {
        format  = "Anthropic"
        name    = local.effective_haiku_model
        version = var.model_version
      }
      modelProviderData = {
        organizationName = var.claude_organization_name
        countryCode      = var.claude_country_code
        industry         = var.claude_industry
      }
      versionUpgradeOption = "OnceNewDefaultVersionAvailable"
      raiPolicyName        = "Microsoft.DefaultV2"
    }
  }

  response_export_values = ["name"]
  # Chain role assignments first: the role-assignment PUT returns fast (~5s)
  # but Foundry data-plane RBAC propagation can take 5+ min. Waiting on the
  # model-deployment LRO (30s-20min) in the meantime makes the first call
  # after `azd up` work without retries. When ASSIGN_RBAC is false, the
  # collection is empty and depends_on is satisfied immediately.
  depends_on = [
    azapi_resource.project,
    azurerm_role_assignment.cognitive_services_user,
  ]
}

resource "azapi_resource" "claude_sonnet" {
  count                     = local.effective_sonnet_model == "" ? 0 : 1
  type                      = "Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview"
  name                      = "${local.effective_sonnet_model}-${local.name_suffix}"
  parent_id                 = azapi_resource.foundry.id
  schema_validation_enabled = false

  body = {
    sku = {
      name     = "GlobalStandard"
      capacity = local.effective_sonnet_capacity
    }
    properties = {
      model = {
        format  = "Anthropic"
        name    = local.effective_sonnet_model
        version = var.model_version
      }
      modelProviderData = {
        organizationName = var.claude_organization_name
        countryCode      = var.claude_country_code
        industry         = var.claude_industry
      }
      versionUpgradeOption = "OnceNewDefaultVersionAvailable"
      raiPolicyName        = "Microsoft.DefaultV2"
    }
  }

  response_export_values = ["name"]
  depends_on = [
    azapi_resource.project,
    azapi_resource.claude_haiku,
    azurerm_role_assignment.cognitive_services_user,
  ]
}

resource "azapi_resource" "claude_opus" {
  count                     = local.effective_opus_model == "" ? 0 : 1
  type                      = "Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview"
  name                      = "${local.effective_opus_model}-${local.name_suffix}"
  parent_id                 = azapi_resource.foundry.id
  schema_validation_enabled = false

  body = {
    sku = {
      name     = "GlobalStandard"
      capacity = local.effective_opus_capacity
    }
    properties = {
      model = {
        format  = "Anthropic"
        name    = local.effective_opus_model
        version = var.model_version
      }
      modelProviderData = {
        organizationName = var.claude_organization_name
        countryCode      = var.claude_country_code
        industry         = var.claude_industry
      }
      versionUpgradeOption = "OnceNewDefaultVersionAvailable"
      raiPolicyName        = "Microsoft.DefaultV2"
    }
  }

  response_export_values = ["name"]
  depends_on = [
    azapi_resource.project,
    azapi_resource.claude_sonnet,
    azurerm_role_assignment.cognitive_services_user,
  ]
}

# --- Optional RBAC --------------------------------------------------------
# Least-privilege role for Foundry inference, per:
#   https://learn.microsoft.com/azure/foundry/foundry-models/how-to/configure-entra-id#for-making-authenticated-api-calls
# `Cognitive Services User` grants exactly the data action this template's
# runtime needs (`Microsoft.CognitiveServices/accounts/MaaS/*`) and nothing
# else. Broader roles (`Foundry User`, `Azure AI Developer`) also work and
# are documented in README.md for users who deliberately want more.
resource "azurerm_role_assignment" "cognitive_services_user" {
  count                = lower(var.assign_rbac) == "true" && var.principal_id != "" ? 1 : 0
  scope                = azapi_resource.foundry.id
  role_definition_name = "Cognitive Services User"
  principal_id         = var.principal_id
}
