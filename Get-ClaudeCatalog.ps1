<#
.SYNOPSIS
    Lists Claude (Anthropic) model deployments you can stand up in your Azure
    subscription — region, version, capacity, context window, retirement date —
    formatted as deployment inputs for azd / bicep / terraform.

.DESCRIPTION
    Queries the Cognitive Services model catalog
    (`az cognitiveservices model list -l <region>`) in parallel across the
    Azure regions where Foundry hosts Claude (default: eastus2, swedencentral)
    and renders the result as one row per (Model, Version) with regions
    collapsed. Four views are available; the default (`Deploy`) is the
    compact, paste-into-bicep view.

    Columns in the default Deploy view:
      Model      — goes in `model.name`
      Version    — goes in `model.version`
      Regions    — every region in which this (Model, Version) is available
      Context    — max input tokens per call (e.g. 1M, 200K)
      MaxOutput  — max output tokens per call
      Capacity   — default integer for `sku.capacity`
      Retires    — inference shutdown date

    Constants for all rows (printed in a footer):
      AccountKind=AIServices  AccountSku=S0  DeploymentSku=GlobalStandard
      ModelFormat=Anthropic   Status=Preview  MaxDeploymentsPerRegion=3

    Run `az login --tenant <TENANT_ID>` and
    `az account set --subscription <SUB_ID>` before invoking.

.PARAMETER Regions
    Azure region short names to scan. Defaults to the two regions where
    Microsoft Foundry currently hosts Claude (eastus2, swedencentral).
    Pass your own list to probe additional regions.

.PARAMETER Family
    Optional filter: opus | sonnet | haiku (case-insensitive).

.PARAMETER Latest
    Per family, keep only the most-recent generation (e.g. drops opus-4-1
    through opus-4-7 and keeps just opus-4-8). Alias: -LatestOnly.

.PARAMETER View
    Deploy (default) : developer view — exactly what to paste into azd / bicep
    Detail           : flat table, one row per (region, model, version, kind)
    Matrix           : pivot — model x region availability grid
    Summary          : one row per (family, generation) with full doc facts

.PARAMETER OutputFormat
    Table (default) | Json | Object (raw pipeline)

.PARAMETER ThrottleLimit
    Max parallel az CLI calls. Default 2 (avoids Windows ephemeral-port
    exhaustion on large region sweeps). Raise if you pass many regions and
    your system can handle it.

.PARAMETER IncludeDeprecating
    Include rows whose lifecycleStatus is 'Deprecating' (default: excluded).

.EXAMPLE
    ./Get-ClaudeCatalog.ps1
    # Compact deploy-ready table for the two regions that host Claude.

.EXAMPLE
    ./Get-ClaudeCatalog.ps1 -Latest
    # Just the newest generation in each family (opus-4-8, sonnet-4-6, haiku-4-5).

.EXAMPLE
    ./Get-ClaudeCatalog.ps1 -Family sonnet -Latest -View Matrix
    # Region x version availability matrix for the latest Sonnet only.

.EXAMPLE
    ./Get-ClaudeCatalog.ps1 -View Summary
    # Per-family generation list with published RPM / TPM / Thinking / Effort.

.EXAMPLE
    ./Get-ClaudeCatalog.ps1 -OutputFormat Json | Out-File claude-catalog.json
#>
[CmdletBinding()]
param(
    [string[]]$Regions = @('eastus2','swedencentral'),
    [ValidateSet('opus','sonnet','haiku','mythos', IgnoreCase = $true)]
    [string]$Family,
    [Alias('LatestOnly')]
    [switch]$Latest,
    [ValidateSet('Deploy','Detail','Matrix','Summary')]
    [string]$View = 'Deploy',
    [ValidateSet('Table','Json','Object')]
    [string]$OutputFormat = 'Table',
    [int]$ThrottleLimit = 2,
    [switch]$IncludeDeprecating
)

$ErrorActionPreference = 'Stop'

# Normalize comma-joined string args from `pwsh -File ... -Regions a,b,c`.
$Regions = @(
    foreach ($r in $Regions) {
        if ($r -is [string] -and $r -match ',') {
            $r.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        } else { $r }
    }
)

# Verify az login context.
try {
    $ctx = az account show -o json 2>$null | ConvertFrom-Json
    if (-not $ctx) { throw 'no context' }
} catch {
    Write-Error "Not logged in. Run 'az login --tenant <TENANT_ID>' and 'az account set --subscription <SUB_ID>' first."
    exit 1
}
Write-Host "Tenant       : $($ctx.tenantId)" -ForegroundColor DarkGray
Write-Host "Subscription : $($ctx.name) ($($ctx.id))" -ForegroundColor DarkGray
Write-Host "Scanning $($Regions.Count) regions for Anthropic / Claude models..." -ForegroundColor DarkGray

# --- Fetch ----------------------------------------------------------------
# NOTE: 'Anthropic' is the on-the-wire literal in the model.format field.
# Up to 2 retries per region — the catalog endpoint occasionally returns
# an empty body under parallel load.
$raw = $Regions | ForEach-Object -Parallel {
    $r = $_
    $json = $null
    for ($i = 0; $i -lt 4 -and -not $json; $i++) {
        if ($i -gt 0) { Start-Sleep -Milliseconds (750 * $i) }
        $json = az cognitiveservices model list --location $r -o json 2>$null
    }
    if (-not $json) { return }
    try { $models = $json | ConvertFrom-Json } catch { return }
    foreach ($m in ($models | Where-Object { $_.model.format -eq 'Anthropic' })) {
        $sku        = $m.model.skus | Select-Object -First 1
        $rateReq    = ($m.model.skus.rateLimits | Where-Object key -eq 'request' | Select-Object -First 1).count
        $rateTok    = ($m.model.skus.rateLimits | Where-Object key -eq 'token'   | Select-Object -First 1).count
        $caps       = if ($m.model.capabilities) {
                        ($m.model.capabilities.PSObject.Properties |
                            Where-Object { $_.Value -eq 'true' } |
                            ForEach-Object Name) -join ','
                      } else { '' }
        [PSCustomObject]@{
            Region            = $r
            Kind              = $m.kind           # AIServices | MaaS
            Model             = $m.model.name
            Version           = "$($m.model.version)"
            Lifecycle         = $m.model.lifecycleStatus
            IsDefault         = [bool]$m.model.isDefaultVersion
            SKUs              = (($m.model.skus.name) -join ',')
            DefaultCapUnits   = $sku.capacity.default    # capacity units at deploy time (1 unit = 1K TPM baseline)
            MaxDeployments    = $m.model.maxCapacity     # max concurrent deployments per region/subscription
            MaxSkuCapUnits    = $sku.capacity.maximum    # theoretical per-deployment ceiling
            BaseRPMPerUnit    = $rateReq                 # catalog per-unit baseline (1 RPM)
            BaseTPMPerUnit    = $rateTok                 # catalog per-unit baseline (1K TPM)
            Capabilities      = $caps
            InferenceDeprec   = $m.model.deprecation.inference
            SkuDeprec         = $sku.deprecationDate
            CatalogAssetId    = $m.model.modelCatalogAssetId
        }
    }
} -ThrottleLimit $ThrottleLimit

if (-not $raw) {
    Write-Warning "No Anthropic models visible in any scanned region. Possible causes: not enrolled in the offer, wrong subscription/tenant, or region list missed the active region."
    return
}

# --- Doc-published facts overlay -----------------------------------------
# These come from the official "Deploy and use Claude models in Microsoft
# Foundry\" article (learn.microsoft.com) and are NOT in the catalog API:
#   - Context window / max output tokens
#   - thinking{} parameter values supported
#   - effort parameter values supported
#   - Actual customer-facing default RPM/TPM quotas (vs catalog per-unit baseline)
#   - One-line tagline
# Source: aka.ms/foundry-claude  (verified 2026-05).
$ClaudeFacts = @{
    'claude-mythos-preview' = @{
        ContextK = 1000; MaxOutK = 128
        Thinking = 'adaptive,enabled'
        Effort   = 'low,medium,high,max'
        RPM      = $null; TPM = $null
        Tagline  = 'Gated research preview — cybersec / autonomous coding / long-running agents'
    }
    'claude-opus-4-8' = @{
        ContextK = 1000; MaxOutK = 128
        Thinking = 'adaptive,disabled'
        Effort   = 'low,medium,high,max,xhigh'
        RPM      = 2000; TPM = 2000000
        Tagline  = 'Most intelligent Opus — best for coding & enterprise agents'
    }
    'claude-opus-4-7' = @{
        ContextK = 1000; MaxOutK = 128
        Thinking = 'adaptive,disabled'
        Effort   = 'low,medium,high,max,xhigh'
        RPM      = 2000; TPM = 2000000
        Tagline  = 'Highly capable — coding / enterprise / long-running agents'
    }
    'claude-opus-4-6' = @{
        ContextK = 1000; MaxOutK = 128
        Thinking = 'adaptive,enabled,disabled'
        Effort   = 'low,medium,high,max'
        RPM      = 2000; TPM = 2000000
        Tagline  = 'Very capable — agents, coding, enterprise workflows'
    }
    'claude-opus-4-5' = @{
        ContextK = 200; MaxOutK = 64
        Thinking = 'enabled,disabled'
        Effort   = 'low,medium,high'
        RPM      = 2000; TPM = 2000000
        Tagline  = 'Industry leader: coding, agents, computer use, enterprise'
    }
    'claude-opus-4-1' = @{
        ContextK = $null; MaxOutK = $null
        Thinking = 'enabled,disabled'
        Effort   = 'low,medium,high'
        RPM      = 2000; TPM = 2000000
        Tagline  = 'Long-running coding tasks with thousands of steps'
    }
    'claude-sonnet-4-6' = @{
        ContextK = 1000; MaxOutK = 128
        Thinking = 'adaptive,enabled,disabled'
        Effort   = 'low,medium,high,max'
        RPM      = 2000; TPM = 2000000
        Tagline  = 'Frontier intelligence at scale — coding / agents / office'
    }
    'claude-sonnet-4-5' = @{
        ContextK = 200; MaxOutK = $null  # 1M beta retiring 2026-04-30
        Thinking = 'enabled,disabled'
        Effort   = 'low,medium,high'
        RPM      = 4000; TPM = 2000000
        Tagline  = 'Balanced speed/cost — real-world agents & computer use'
    }
    'claude-haiku-4-5' = @{
        ContextK = $null; MaxOutK = $null
        Thinking = 'enabled,disabled'
        Effort   = 'low,medium,high'
        RPM      = 4000; TPM = 4000000
        Tagline  = 'Near-frontier at low cost — free products & sub-agents'
    }
}

# --- Enrich + filter ------------------------------------------------------
# Family + generation parsing, plus doc-fact overlay.
$enriched = foreach ($r in $raw) {
    $fam = if     ($r.Model -match 'opus')   { 'opus' }
           elseif ($r.Model -match 'sonnet') { 'sonnet' }
           elseif ($r.Model -match 'haiku')  { 'haiku' }
           elseif ($r.Model -match 'mythos') { 'mythos' }
           else                              { 'other' }
    $gen = ''
    if ($r.Model -match '-(\d+(?:-\d+)*)$') { $gen = $Matches[1].Replace('-','.') }
    $facts = $ClaudeFacts[$r.Model]
    $r |
      Add-Member -NotePropertyName Family     -NotePropertyValue $fam -PassThru |
      Add-Member -NotePropertyName Generation -NotePropertyValue $gen -PassThru |
      Add-Member -NotePropertyName ContextK   -NotePropertyValue ($facts.ContextK) -PassThru |
      Add-Member -NotePropertyName MaxOutK    -NotePropertyValue ($facts.MaxOutK)  -PassThru |
      Add-Member -NotePropertyName Thinking   -NotePropertyValue ($facts.Thinking) -PassThru |
      Add-Member -NotePropertyName Effort     -NotePropertyValue ($facts.Effort)   -PassThru |
      Add-Member -NotePropertyName RPM        -NotePropertyValue ($facts.RPM)      -PassThru |
      Add-Member -NotePropertyName TPM        -NotePropertyValue ($facts.TPM)      -PassThru |
      Add-Member -NotePropertyName Tagline    -NotePropertyValue ($facts.Tagline)  -PassThru
}

if ($Family) {
    $enriched = $enriched | Where-Object Family -eq $Family.ToLower()
}
if (-not $IncludeDeprecating) {
    $enriched = $enriched | Where-Object { $_.Lifecycle -ne 'Deprecating' }
}

if ($Latest) {
    # Keep only the highest Generation within each Family (e.g. for opus,
    # show 4.8 only — not 4.1, 4.5, 4.6, 4.7). Generation strings sort
    # naturally for the current Anthropic numbering (4.1, 4.5, 4.6, 4.7,
    # 4.8) but we sort by [version] to be safe across major bumps.
    $enriched = $enriched |
        Group-Object Family |
        ForEach-Object {
            $top = ($_.Group |
                Sort-Object @{ Expression = {
                    try   { [version]($_.Generation + '.0') }
                    catch { [version]'0.0' }
                } } -Descending |
                Select-Object -ExpandProperty Generation -First 1)
            $_.Group | Where-Object Generation -eq $top
        }
}

# Stable sort: family priority mythos > opus > sonnet > haiku > other, then
# newest generation first, newest version first, then region alpha, then Kind.
$famOrder = @{ mythos = 0; opus = 1; sonnet = 2; haiku = 3; other = 9 }
$sorted = $enriched | Sort-Object @(
    @{ Expression = { $famOrder[$_.Family] } }
    @{ Expression = { $_.Generation }; Descending = $true }
    @{ Expression = { $_.Version    }; Descending = $true }
    @{ Expression = { $_.Region     } }
    @{ Expression = { $_.Kind       } }
)

# --- Project per view -----------------------------------------------------
switch ($View) {
    'Deploy' {
        # Developer-focused: exactly what you paste into azd env / bicep /
        # terraform. One row per (Model, Version) — regions collapse into a
        # single comma-list, and columns that are constant across every
        # Claude deployment today are dropped (printed once as a footer).
        function _fmtTok($k) {
            if (-not $k) { return '' }
            if ($k -ge 1000) { return ('{0}M' -f ($k / 1000)) }
            return ('{0}K' -f $k)
        }
        $output = $sorted |
            Group-Object Model, Version |
            ForEach-Object {
                $f = $_.Group | Select-Object -First 1
                $regList = [string]::Join(',', @($_.Group | Select-Object -ExpandProperty Region -Unique | Sort-Object))
                [PSCustomObject]@{
                    Model      = $f.Model
                    Version    = $f.Version
                    Regions    = $regList
                    Context    = _fmtTok $f.ContextK
                    MaxOutput  = _fmtTok $f.MaxOutK
                    Capacity   = $f.DefaultCapUnits
                    Retires    = if ($f.InferenceDeprec) { ([datetime]$f.InferenceDeprec).ToString('yyyy-MM-dd') } else { '' }
                }
            } | Sort-Object @(
                @{ Expression = { $famOrder[($_.Model -replace '.*-(opus|sonnet|haiku|mythos)-.*','$1')] } }
                @{ Expression = {
                    # Sort newest version first; treat date-style (8-digit)
                    # and integer versions on the same numeric scale.
                    try { [int64]$_.Version } catch { 0 }
                } ; Descending = $true }
                @{ Expression = { $_.Model } }
            )
    }
    'Detail' {
        $output = $sorted | Select-Object `
            Family, Generation, Model, Version, Region, Kind, Lifecycle,
            SKUs, ContextK, MaxOutK, Thinking, Effort, RPM, TPM,
            DefaultCapUnits, MaxDeployments, InferenceDeprec, Tagline
    }
    'Matrix' {
        # Pivot: rows = (Family, Generation, Version, Lifecycle, ContextK, MaxOutK),
        # columns = regions, cells = 'AIS+MaaS' | 'AIS' | 'MaaS' | ''.
        $allRegions = $sorted | Select-Object -ExpandProperty Region -Unique | Sort-Object
        $output = $sorted |
            Group-Object Family, Generation, Version, Lifecycle |
            ForEach-Object {
                $first = $_.Group | Select-Object -First 1
                $row = [ordered]@{
                    Family     = $first.Family
                    Generation = $first.Generation
                    Version    = $first.Version
                    Lifecycle  = $first.Lifecycle
                    ContextK   = $first.ContextK
                    MaxOutK    = $first.MaxOutK
                }
                foreach ($region in $allRegions) {
                    $kinds = ($_.Group |
                        Where-Object Region -eq $region |
                        Select-Object -ExpandProperty Kind -Unique |
                        Sort-Object)
                    $cell = switch (($kinds | Measure-Object).Count) {
                        0 { '' }
                        1 { if ($kinds -eq 'AIServices') { 'AIS' } else { 'MaaS' } }
                        default { 'AIS+MaaS' }
                    }
                    $row[$region] = $cell
                }
                [PSCustomObject]$row
            }
    }
    'Summary' {
        # Collapse to (Family, Generation, Version) with aggregated region list.
        $output = $sorted |
            Group-Object Family, Generation, Version |
            ForEach-Object {
                $f = $_.Group | Select-Object -First 1
                $regions = ($_.Group | Select-Object -ExpandProperty Region -Unique | Sort-Object) -join ','
                $kinds   = ($_.Group | Select-Object -ExpandProperty Kind   -Unique | Sort-Object) -join ','
                [PSCustomObject]@{
                    Family         = $f.Family
                    Generation     = $f.Generation
                    Version        = $f.Version
                    Lifecycle      = $f.Lifecycle
                    Kinds          = $kinds
                    SKU            = $f.SKUs
                    ContextK       = $f.ContextK
                    MaxOutK        = $f.MaxOutK
                    Thinking       = $f.Thinking
                    Effort         = $f.Effort
                    RPM            = $f.RPM
                    TPM            = $f.TPM
                    MaxDeployments = $f.MaxDeployments
                    Regions        = $regions
                    RegionCount    = ($_.Group | Select-Object -ExpandProperty Region -Unique | Measure-Object).Count
                    Deprec         = $f.InferenceDeprec
                    Tagline        = $f.Tagline
                }
            } | Sort-Object @(
                @{ Expression = { $famOrder[$_.Family] } }
                @{ Expression = { $_.Generation }; Descending = $true }
                @{ Expression = { $_.Version    }; Descending = $true }
            )
    }
}

switch ($OutputFormat) {
    'Json'   { $output | ConvertTo-Json -Depth 6 }
    'Object' { $output }
    default  {
        if ($View -eq 'Matrix') { $output | Format-Table -AutoSize -Wrap }
        else                    { $output | Format-Table -AutoSize }
        if ($View -eq 'Deploy') {
            Write-Host ''
            Write-Host 'Constants (same for every row above):' -ForegroundColor DarkGray
            Write-Host '  AccountKind=AIServices  AccountSku=S0  DeploymentSku=GlobalStandard  ModelFormat=Anthropic' -ForegroundColor DarkGray
            Write-Host '  Status=Preview  MaxDeploymentsPerRegion=3' -ForegroundColor DarkGray
            Write-Host 'Legend: Context/MaxOutput are tokens per call (1M=1,000,000). Capacity = default sku.capacity.' -ForegroundColor DarkGray
        }
    }
}
