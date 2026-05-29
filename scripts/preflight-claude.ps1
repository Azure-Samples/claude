<#
.SYNOPSIS
    Preflight check for Claude-on-Microsoft-Foundry deployments.

.DESCRIPTION
    Gates `azd up` on:
      1. Required env vars being set.
      2. (Informational) Marketplace catalog: the Anthropic offer resolves
         via the Microsoft.MarketplaceOrdering REST API. A missing offer
         is a hard fail (typo / unreleased SKU). The Cognitive Services
         RP auto-signs the agreement during deployment on eligible subs,
         so an unsigned status is informational only.
      3. **Per-region Cognitive Services quota headroom** per model.
         A hard fail (exit 6) when `currentValue + requestedCapacity >
         limit`. This is the most common cause of `azd up` failures and
         the cause of the opaque `400 715-123420` error that Terraform's
         `azapi_resource` returns. (Bicep / `az deployment group create`
         surface the real `InsufficientQuota` message because they go
         through ARM preflight; `azapi` bypasses it.)

    Per-family mode: set any of CLAUDE_HAIKU_MODEL / CLAUDE_SONNET_MODEL /
    CLAUDE_OPUS_MODEL. Empty = skip that family. If all three are empty,
    falls back to CLAUDE_MODEL_NAME (legacy single-model behavior).

    Env vars consumed:
      CLAUDE_ORGANIZATION_NAME, AZURE_LOCATION, CLAUDE_HAIKU_MODEL,
      CLAUDE_SONNET_MODEL, CLAUDE_OPUS_MODEL (+ matching *_CAPACITY),
      CLAUDE_MODEL_NAME, CLAUDE_MODEL_CAPACITY (legacy fallback).

.NOTES
    Exit codes:
      0  Preflight passed (or skipped — see warnings).
      4  Marketplace offer not found (typo in a model name, or model not
         in the Anthropic-on-Foundry catalog yet).
      6  Insufficient quota (used + requested > limit).

    The preflight is best-effort. If `CLAUDE_ORGANIZATION_NAME` /
    `AZURE_LOCATION` aren't set, or `az` isn't installed / logged in, it
    warns and exits 0 so `azd up` can continue (azd / Bicep will prompt
    for any missing parameter; the RP surfaces catalog / quota errors at
    deploy time, just less ergonomically). The marketplace-offer and
    quota checks remain hard fails when they CAN run, because they
    catch the most common cause of opaque deploy failures.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Fail([int]$code, [string]$message) {
    Write-Host ""
    Write-Host "ERROR: $message" -ForegroundColor Red
    Write-Host ""
    exit $code
}

function Warn([string]$message) {
    Write-Host "Preflight: $message" -ForegroundColor Yellow
}

# --- 1. Required env vars ---------------------------------------------------
if (-not $env:CLAUDE_ORGANIZATION_NAME) {
    Warn "CLAUDE_ORGANIZATION_NAME is not set. azd will prompt for the 'claudeOrganizationName' Bicep parameter at provision time. To skip the prompt: azd env set CLAUDE_ORGANIZATION_NAME 'Your Org'"
}
if (-not $env:AZURE_LOCATION) {
    Warn "AZURE_LOCATION is not set. azd will prompt at provision time. Skipping marketplace + quota validation (they need a region). To skip the prompt: azd env set AZURE_LOCATION swedencentral"
    exit 0
}

$location = $env:AZURE_LOCATION

# Build the list of (family, model, capacity) tuples to validate. Empty
# family vars are skipped. If none are set, fall back to legacy single-model.
$requested = @()
if ($env:CLAUDE_HAIKU_MODEL)  { $requested += [pscustomobject]@{ Family='haiku';  Model=$env:CLAUDE_HAIKU_MODEL;  Capacity=[int]($env:CLAUDE_HAIKU_CAPACITY  | ForEach-Object { if ($_) { $_ } else { 50 } }) } }
if ($env:CLAUDE_SONNET_MODEL) { $requested += [pscustomobject]@{ Family='sonnet'; Model=$env:CLAUDE_SONNET_MODEL; Capacity=[int]($env:CLAUDE_SONNET_CAPACITY | ForEach-Object { if ($_) { $_ } else { 50 } }) } }
if ($env:CLAUDE_OPUS_MODEL)   { $requested += [pscustomobject]@{ Family='opus';   Model=$env:CLAUDE_OPUS_MODEL;   Capacity=[int]($env:CLAUDE_OPUS_CAPACITY   | ForEach-Object { if ($_) { $_ } else { 50 } }) } }

if ($requested.Count -eq 0) {
    $legacyModel    = if ($env:CLAUDE_MODEL_NAME) { $env:CLAUDE_MODEL_NAME } else { "claude-sonnet-4-6" }
    $legacyCapacity = if ($env:CLAUDE_MODEL_CAPACITY) { [int]$env:CLAUDE_MODEL_CAPACITY } else { 50 }
    $requested = ,([pscustomobject]@{ Family='legacy'; Model=$legacyModel; Capacity=$legacyCapacity })
}

# --- 2. Azure CLI / active subscription ------------------------------------
# These checks are best-effort: if `az` is missing or the user hasn't run
# `az login`, we skip the marketplace + quota checks and let `azd up`
# continue. The RP will surface any errors at deploy time.
$az = Get-Command az -ErrorAction SilentlyContinue
if (-not $az) {
    Warn "Azure CLI (az) not found on PATH. Skipping marketplace + quota validation. Install az and run 'az login' for proactive checks: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 0
}

$subId = (az account show --query id -o tsv 2>$null)
if (-not $subId) {
    Warn "Not signed in to Azure CLI. Skipping marketplace + quota validation. Run 'az login' (and 'az account set --subscription <id>' if needed) for proactive checks."
    exit 0
}

$summary = ($requested | ForEach-Object { "$($_.Family)=$($_.Model)@$($_.Capacity)" }) -join ', '
Write-Host "Preflight: subscription $subId, location $location, deployments: $summary"

$publisher = "anthropic"

foreach ($r in $requested) {
    $modelName = $r.Model
    $capacity  = $r.Capacity
    $family    = $r.Family

    # --- Marketplace catalog check (offer exists; agreement status informational) ---
    # Anthropic publishes Claude as a fetch-style plan named '<offer>-plan-new'
    # ('-test-plan' is a non-purchasable stub used by some legacy tooling).
    $offer = "anthropic-$modelName-offer"
    $plan  = "anthropic-$modelName-plan-new"
    $mpUrl = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.MarketplaceOrdering/offerTypes/virtualmachine/publishers/$publisher/offers/$offer/plans/$plan/agreements/current?api-version=2021-01-01"

    $mpRaw  = az rest --method get --url $mpUrl 2>&1
    $mpExit = $LASTEXITCODE

    if ($mpExit -ne 0) {
        $msg = ($mpRaw | Out-String).Trim()
        if ($msg -match "was not found" -or $msg -match "BadRequest") {
            Fail 4 @"
Marketplace offer 'anthropic/$offer/$plan' not found (family=$family).

Likely causes:
  - The model id '$modelName' is misspelled.
  - The model isn't (yet) published in the Anthropic-on-Foundry catalog.
  - Anthropic changed the plan naming convention.

Available Anthropic agreements on this subscription:
  az rest --method get --url 'https://management.azure.com/subscriptions/$subId/providers/Microsoft.MarketplaceOrdering/agreements?api-version=2021-01-01' --query "value[?properties.publisher=='anthropic']"

Underlying error:
$msg
"@
        }
        Write-Host "Preflight: Marketplace catalog query for '$modelName' returned an unexpected error (continuing — RP will validate at deploy time):" -ForegroundColor Yellow
        Write-Host "  $msg" -ForegroundColor Yellow
    } else {
        $mp = $mpRaw | ConvertFrom-Json
        if (-not $mp.properties.accepted) {
            Write-Host "Preflight: '$modelName' marketplace agreement is currently unsigned. The Cognitive Services RP will auto-sign during deployment on eligible subs." -ForegroundColor Yellow
            Write-Host "         If your subscription blocks RP-initiated subscribes, pre-accept manually:" -ForegroundColor Yellow
            Write-Host "           az term accept --publisher $publisher --product $offer --plan $plan" -ForegroundColor Yellow
        } else {
            Write-Host "Preflight: '$modelName' marketplace agreement signed." -ForegroundColor Green
        }
    }

    # --- Quota headroom (HARD FAIL on insufficient) ------------------------
    # The Cognitive Services RP returns an opaque `400 715-123420` for
    # quota-rejected requests when called via azapi/Terraform. Catch it
    # early with a clear message.
    $sku = "AIServices.GlobalStandard.$modelName"
    $limitRaw   = az cognitiveservices usage list --location $location --query "[?name.value=='$sku'].limit | [0]" -o tsv 2>$null
    $currentRaw = az cognitiveservices usage list --location $location --query "[?name.value=='$sku'].currentValue | [0]" -o tsv 2>$null

    if (-not [string]::IsNullOrWhiteSpace($limitRaw)) {
        $limit     = [int]([double]$limitRaw)
        $current   = if ([string]::IsNullOrWhiteSpace($currentRaw)) { 0 } else { [int]([double]$currentRaw) }
        $available = $limit - $current
        if ($available -lt $capacity) {
            $upperFamily = $family.ToUpper()
            Fail 6 @"
Insufficient quota for '$modelName' (family=$family) in '$location'.

Requested capacity: $capacity TPM (thousands)
Available:         $available TPM (limit $limit, currently used $current)

Fix one of:
  - Lower the requested capacity:
      azd env set CLAUDE_$($upperFamily)_CAPACITY $available
    (or CLAUDE_MODEL_CAPACITY for legacy single-model mode)
  - Free up quota by deleting unused deployments:
      az cognitiveservices account deployment list --name <foundry> --resource-group <rg> -o table
      az cognitiveservices account deployment delete --name <foundry> --resource-group <rg> --deployment-name <name>
  - Request a quota increase in the Azure Foundry portal:
      Foundry portal -> Management center -> Quota -> select '$sku' -> Request increase

Note: without this preflight, Terraform (azapi_resource) would fail with an
opaque '400 715-123420' error because azapi bypasses ARM preflight
validation. Bicep and 'az deployment group create' show the real
'InsufficientQuota' message because they go through ARM preflight.
"@
        }
        Write-Host "Preflight: '$modelName' quota OK ($capacity requested, $available available of $limit in $location)." -ForegroundColor Green
    } else {
        Write-Host "Preflight: no quota row visible for '$sku' in '$location' yet — first deploy may surface a quota error from the RP." -ForegroundColor Yellow
    }
}

Write-Host "Preflight OK." -ForegroundColor Green
exit 0
