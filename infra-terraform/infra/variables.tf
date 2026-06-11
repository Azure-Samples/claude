# ---------------------------------------------------------------------------
# azd-injected variables (populated from `azd env` values via main.tfvars.json)
# ---------------------------------------------------------------------------
variable "environment_name" {
  description = "azd environment name. Used for resource group + tagging."
  type        = string
}

variable "location" {
  description = "Azure region. All three families coexist in eastus2 or swedencentral."
  type        = string
  validation {
    condition     = contains(["eastus2", "swedencentral", "westus2"], var.location)
    error_message = "location must be eastus2, swedencentral, or westus2."
  }
}

variable "subscription_id" {
  description = "Target Azure subscription id."
  type        = string
}

variable "principal_id" {
  description = "Object id of the deploying user/SP. Empty disables RBAC."
  type        = string
  default     = ""
}

variable "assign_rbac" {
  description = "Whether to assign Cognitive Services User (least-privilege inference role) to principal_id on the Foundry account. Set to \"true\" to enable. Requires Microsoft.Authorization/roleAssignments/write on the deployer."
  type        = string
  default     = "false"
}

# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------
variable "base_name" {
  description = "Short prefix for resource names."
  type        = string
  default     = "claude"
}

# ---------------------------------------------------------------------------
# Per-family Claude deployments (preferred). Empty string = skip that family.
# ---------------------------------------------------------------------------
variable "haiku_model" {
  description = "Haiku family model id. Empty = do not deploy haiku."
  type        = string
  default     = ""
}

variable "sonnet_model" {
  description = "Sonnet family model id. Empty = do not deploy sonnet."
  type        = string
  default     = ""
}

variable "opus_model" {
  description = "Opus family model id. Empty = do not deploy opus."
  type        = string
  default     = ""
}

variable "haiku_capacity" {
  description = "Haiku deployment capacity (TPM / 1000). Default 25 fits most subs out of the box; raise via `azd env set CLAUDE_HAIKU_CAPACITY <n>`."
  type        = string
  default     = "25"
}

variable "sonnet_capacity" {
  description = "Sonnet deployment capacity (TPM / 1000). Default 25 fits most subs out of the box; raise via `azd env set CLAUDE_SONNET_CAPACITY <n>`."
  type        = string
  default     = "25"
}

variable "opus_capacity" {
  description = "Opus deployment capacity (TPM / 1000). Default 25 fits most subs out of the box; raise via `azd env set CLAUDE_OPUS_CAPACITY <n>`."
  type        = string
  default     = "25"
}

variable "model_version" {
  description = "Model version string. Use \"1\" for newest preview models."
  type        = string
  default     = "1"
}

# ---------------------------------------------------------------------------
# Legacy single-model fallback. Only used when all three per-family vars
# are empty.
# ---------------------------------------------------------------------------
variable "model_name" {
  description = "Legacy single-model name. Ignored when any of haiku_model/sonnet_model/opus_model is set."
  type        = string
  default     = "claude-sonnet-4-6"
}

variable "model_capacity" {
  description = "Legacy single-model capacity. Ignored when any per-family var is set."
  type        = string
  default     = "25"
}

# ---------------------------------------------------------------------------
# modelProviderData (REQUIRED by Foundry for Claude deployments)
# ---------------------------------------------------------------------------
variable "claude_organization_name" {
  description = "Organization name surfaced via modelProviderData."
  type        = string
}

variable "claude_country_code" {
  description = "Two-letter ISO country code (e.g. US, GB, DE)."
  type        = string
  default     = "US"
  validation {
    condition     = length(var.claude_country_code) == 2
    error_message = "Must be a 2-letter country code."
  }
}

variable "claude_industry" {
  description = "Industry — MUST be lowercase to match Foundry portal dropdown."
  type        = string
  default     = "technology"
  validation {
    condition = contains([
      "technology", "finance", "healthcare", "education",
      "retail", "manufacturing", "government", "media", "other",
    ], var.claude_industry)
    error_message = "industry must be a lowercase value supported by the Foundry portal."
  }
}
