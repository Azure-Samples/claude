<#
.SYNOPSIS
    End-to-end smoke test for a freshly provisioned Claude-on-Foundry deployment.

.DESCRIPTION
    Run this after `azd up` to verify in one shot that:

      1. The post-provision activator (`claude-code.env.ps1`) exists and
         exports the expected `CLAUDE_CODE_USE_FOUNDRY`, `ANTHROPIC_FOUNDRY_RESOURCE`,
         and `ANTHROPIC_DEFAULT_<FAMILY>_MODEL` variables.
      2. `.vscode/settings.json` is wired up with the `claudeCode.environmentVariables`
         schema the Claude Code VS Code extension reads.
      3. `az` is logged in and the current token tenant matches the tenant
         that owns the Foundry resource (a mismatch is the #1 cause of 401s).
      4. Each Claude model deployment on the Foundry account has reached a
         terminal `provisioningState`. If `azd up` returned a `GatewayTimeout`
         from `Microsoft.CognitiveServices`, that is an ARM-layer poll timeout,
         not a deployment failure &mdash; the RP often keeps going for many
         more minutes. Re-running this verifier (optionally with
         `-WaitForDeployment`) is the safe way to confirm the actual outcome
         without colliding with the in-flight long-running operation.
      5. The Claude Code CLI is on PATH. If not, the script prints the install
         hint (or runs the official installer when `-AutoInstall` is set, the
         same gate as `CLAUDE_CODE_AUTO_INSTALL` in the postprovision hook).
      6. (Default) A non-interactive `claude -p` round trip against each
         deployed family. Skips this step with `-SkipClaudeCall`.
      7. (Opt-in) A `python src/hello_claude.py` round trip exercising the
         Anthropic SDK + Entra ID code path. Enable with `-RunPythonSample`.

.PARAMETER RepoRoot
    Path to the repo root. Defaults to the parent of the scripts/ folder.

.PARAMETER AutoInstall
    Install the Claude Code CLI if it is missing. Equivalent to
    `CLAUDE_CODE_AUTO_INSTALL=true` for the postprovision hook.

.PARAMETER SkipClaudeCall
    Skip the live `claude -p` round trip (avoids burning tokens).

.PARAMETER RunPythonSample
    After the CLI check, run `python src/hello_claude.py` from the repo root.
    Requires `.env.local` populated via `azd env get-values` and a venv with
    `pip install -r requirements.txt`.

.PARAMETER WaitForDeployment
    If any Claude model deployment is still in a non-terminal state (e.g.
    `Creating`), poll the Cognitive Services RP until every deployment
    reaches `Succeeded` / `Failed` / `Canceled` or `-WaitTimeoutSeconds`
    elapses. Use this after a `GatewayTimeout` from `azd up` to confirm
    whether the deployment actually finished server-side.

.PARAMETER WaitTimeoutSeconds
    Maximum seconds to wait for non-terminal deployments when
    `-WaitForDeployment` is set. Default: 1800 (30 min). Set to 0 for a
    single status check with no polling.

.EXAMPLE
    pwsh -File scripts/verify-claude-code.ps1
    # All checks + live claude -p round trip per deployed family.

.EXAMPLE
    pwsh -File scripts/verify-claude-code.ps1 -SkipClaudeCall
    # Config checks only, no token cost.

.EXAMPLE
    pwsh -File scripts/verify-claude-code.ps1 -RunPythonSample
    # Adds a Python Entra ID round trip on top of the standard checks.

.EXAMPLE
    pwsh -File scripts/verify-claude-code.ps1 -WaitForDeployment
    # Use this after a GatewayTimeout from `azd up` to wait for the RP to
    # finish provisioning the model deployment(s).
#>
[CmdletBinding()]
param(
    [string] $RepoRoot,
    [switch] $AutoInstall,
    [switch] $SkipClaudeCall,
    [switch] $RunPythonSample,
    [switch] $WaitForDeployment,
    [int] $WaitTimeoutSeconds = 1800
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Result accumulator -> printed as a summary table at the end.
# ---------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$Name, [string]$Status, [string]$Detail = '') {
    $results.Add([pscustomobject]@{
        Check  = $Name
        Status = $Status
        Detail = $Detail
    }) | Out-Null
    $color = switch ($Status) {
        'PASS' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Gray' }
    }
    Write-Host ("  [{0,-4}] {1}{2}" -f $Status, $Name, $(if ($Detail) { " - $Detail" } else { '' })) -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# Locate the repo root.
# ---------------------------------------------------------------------------
if (-not $RepoRoot) {
    $here = Split-Path -Parent $PSCommandPath
    $RepoRoot = Resolve-Path (Join-Path $here '..') | Select-Object -ExpandProperty Path
}
Write-Host ""
Write-Host "Verifying Claude Code wiring under: $RepoRoot" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# 1. Activator file exists.
# ---------------------------------------------------------------------------
$activator = Join-Path $RepoRoot 'claude-code.env.ps1'
if (-not (Test-Path $activator)) {
    Add-Result 'Activator (claude-code.env.ps1)' 'FAIL' 'not found - run azd up or scripts/configure-claude-code.ps1 first'
    Write-Host ""
    Write-Host "Stopping: cannot verify without an activator file." -ForegroundColor Red
    exit 1
}
Add-Result 'Activator (claude-code.env.ps1)' 'PASS' $activator

# ---------------------------------------------------------------------------
# 2. Source the activator into the current scope.
# ---------------------------------------------------------------------------
. $activator | Out-Null

$expectedVars = @('CLAUDE_CODE_USE_FOUNDRY', 'ANTHROPIC_FOUNDRY_RESOURCE')
$familyVars   = @('ANTHROPIC_DEFAULT_HAIKU_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL')
$deployedFamilies = @()
foreach ($v in $expectedVars) {
    $val = [Environment]::GetEnvironmentVariable($v, 'Process')
    if ($val) {
        Add-Result "env $v" 'PASS' $val
    } else {
        Add-Result "env $v" 'FAIL' 'not set after sourcing activator'
    }
}
foreach ($v in $familyVars) {
    $val = [Environment]::GetEnvironmentVariable($v, 'Process')
    if ($val) {
        Add-Result "env $v" 'PASS' $val
        $deployedFamilies += [pscustomobject]@{ Family = ($v -replace 'ANTHROPIC_DEFAULT_(\w+)_MODEL','$1'); Deployment = $val }
    }
}
if ($deployedFamilies.Count -eq 0) {
    Add-Result 'Deployed families' 'FAIL' 'no ANTHROPIC_DEFAULT_<FAMILY>_MODEL set'
} else {
    Add-Result 'Deployed families' 'PASS' (($deployedFamilies | ForEach-Object { $_.Family }) -join ', ')
}

$foundryResource = $env:ANTHROPIC_FOUNDRY_RESOURCE

# ---------------------------------------------------------------------------
# 3. .vscode/settings.json contains the right keys.
# ---------------------------------------------------------------------------
$settingsPath = Join-Path $RepoRoot '.vscode/settings.json'
if (Test-Path $settingsPath) {
    try {
        $settings = Get-Content -Raw -Path $settingsPath | ConvertFrom-Json
        $envArr = $settings.'claudeCode.environmentVariables'
        if ($envArr) {
            $names = ($envArr | ForEach-Object { $_.name }) -join ', '
            Add-Result 'VS Code settings.json' 'PASS' $names
        } else {
            Add-Result 'VS Code settings.json' 'WARN' "no 'claudeCode.environmentVariables' key (extension may show login prompt)"
        }
    } catch {
        Add-Result 'VS Code settings.json' 'WARN' "could not parse: $($_.Exception.Message)"
    }
} else {
    Add-Result 'VS Code settings.json' 'WARN' "missing (CLI works fine; VS Code extension won't auto-configure)"
}

# ---------------------------------------------------------------------------
# 4. az login tenant matches the Foundry resource tenant.
# ---------------------------------------------------------------------------
$azCmd = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCmd) {
    Add-Result 'Azure CLI (az)' 'WARN' 'not on PATH - cannot validate tenant'
} else {
    try {
        $acct = & az account show -o json 2>$null | ConvertFrom-Json
        if (-not $acct) {
            Add-Result 'az account show' 'FAIL' 'not logged in - run az login --tenant <tenant-id>'
        } else {
            Add-Result 'az account show' 'PASS' "$($acct.user.name) on '$($acct.name)' (tenant $($acct.tenantId))"

            # Best-effort: look up the resource tenant and compare.
            if ($foundryResource) {
                $found = $null
                try {
                    $accountsJson = & az cognitiveservices account list -o json 2>$null
                    if ($accountsJson) {
                        $accounts = $accountsJson | ConvertFrom-Json
                        $script:foundryAccount = $accounts | Where-Object { $_.name -eq $foundryResource } | Select-Object -First 1
                        $found = $script:foundryAccount
                    }
                } catch { }
                if ($found) {
                    Add-Result 'Foundry resource reachable' 'PASS' "$($found.name) (rg: $($found.resourceGroup), location: $($found.location))"
                } else {
                    Add-Result 'Foundry resource reachable' 'WARN' "$foundryResource not visible to current az login - wrong tenant/subscription?"
                }
            }
        }
    } catch {
        Add-Result 'az account show' 'FAIL' $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# 4b. Model deployment provisioning state.
#
#     A `GatewayTimeout` from `Microsoft.CognitiveServices` during `azd up`
#     is an ARM-layer poll timeout, not a deployment failure -- the RP
#     often keeps provisioning for many more minutes. This check asks the
#     RP directly so we can confirm the actual outcome without re-running
#     `azd up` (which can collide with the in-flight LRO).
# ---------------------------------------------------------------------------
if ($azCmd -and $script:foundryAccount -and $deployedFamilies.Count -gt 0) {
    $rgName = $script:foundryAccount.resourceGroup
    $expectedNames = @($deployedFamilies | ForEach-Object { $_.Deployment })
    $terminalStates = @('Succeeded', 'Failed', 'Canceled')
    $deadline = (Get-Date).AddSeconds([math]::Max(0, $WaitTimeoutSeconds))
    $pollIntervalSec = 30
    $firstPass = $true

    while ($true) {
        $deployments = @()
        try {
            $depsJson = & az cognitiveservices account deployment list -g $rgName -n $foundryResource -o json 2>$null
            if ($depsJson) { $deployments = @($depsJson | ConvertFrom-Json) }
        } catch { }

        $statuses = @()
        $stillCreating = @()
        foreach ($name in $expectedNames) {
            $d = $deployments | Where-Object { $_.name -eq $name } | Select-Object -First 1
            if (-not $d) {
                $statuses += [pscustomobject]@{ Name = $name; State = '<missing>' }
                continue
            }
            $state = $d.properties.provisioningState
            $statuses += [pscustomobject]@{ Name = $name; State = $state }
            if ($state -and $terminalStates -notcontains $state) {
                $stillCreating += $name
            }
        }

        if ($firstPass -or $stillCreating.Count -eq 0 -or -not $WaitForDeployment -or (Get-Date) -ge $deadline) {
            foreach ($s in $statuses) {
                $checkName = "Deployment '$($s.Name)'"
                switch ($s.State) {
                    'Succeeded' { Add-Result $checkName 'PASS' 'provisioningState=Succeeded' }
                    'Failed'    { Add-Result $checkName 'FAIL' 'provisioningState=Failed' }
                    'Canceled'  { Add-Result $checkName 'FAIL' 'provisioningState=Canceled' }
                    '<missing>' { Add-Result $checkName 'WARN' 'not found on Foundry account - may still be creating, or activator is stale' }
                    default {
                        $hint = if ($WaitForDeployment) { "still $($s.State) after waiting $WaitTimeoutSeconds s" } else { "provisioningState=$($s.State); rerun with -WaitForDeployment to poll" }
                        Add-Result $checkName 'WARN' $hint
                    }
                }
            }
        }

        if (-not $WaitForDeployment -or $stillCreating.Count -eq 0 -or (Get-Date) -ge $deadline) {
            break
        }

        $remaining = [int]($deadline - (Get-Date)).TotalSeconds
        Write-Host ("  ... {0} deployment(s) still provisioning ({1}); polling again in {2}s (timeout in {3}s)" -f $stillCreating.Count, ($stillCreating -join ', '), $pollIntervalSec, $remaining) -ForegroundColor DarkGray
        Start-Sleep -Seconds $pollIntervalSec
        $firstPass = $false
    }
} elseif ($WaitForDeployment) {
    Add-Result 'Model deployment state' 'WARN' 'cannot poll - az not available, Foundry resource not visible, or no families set'
}

# ---------------------------------------------------------------------------
# 5. Claude Code CLI on PATH (optional auto-install).
# ---------------------------------------------------------------------------
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claudeCmd) {
    $autoInstallEnv = $env:CLAUDE_CODE_AUTO_INSTALL -and ($env:CLAUDE_CODE_AUTO_INSTALL -ne 'false' -and $env:CLAUDE_CODE_AUTO_INSTALL -ne '0')
    if ($AutoInstall -or $autoInstallEnv) {
        Write-Host ""
        Write-Host "Installing Claude Code CLI..." -ForegroundColor Cyan
        $onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ($PSVersionTable.Platform -eq 'Win32NT') -or ($env:OS -eq 'Windows_NT')
        try {
            if ($onWindows) {
                Invoke-RestMethod -Uri 'https://claude.ai/install.ps1' | Invoke-Expression
                $userBin = Join-Path $env:USERPROFILE '.local\bin'
                if (Test-Path (Join-Path $userBin 'claude.exe')) {
                    $env:PATH = "$userBin;$env:PATH"
                }
            } else {
                & bash -c "curl -fsSL https://claude.ai/install.sh | bash"
                $env:PATH = "$HOME/.local/bin:$env:PATH"
            }
            $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
        } catch {
            Add-Result 'Claude Code CLI install' 'FAIL' $_.Exception.Message
        }
    }
}

if ($claudeCmd) {
    $ver = (& claude --version 2>$null) -join ' '
    Add-Result 'Claude Code CLI' 'PASS' "$($claudeCmd.Source) ($ver)"
} else {
    Add-Result 'Claude Code CLI' 'WARN' "not on PATH - install with 'irm https://claude.ai/install.ps1 | iex' or rerun with -AutoInstall"
}

# ---------------------------------------------------------------------------
# 6. Live `claude -p` round trip per family (default on).
# ---------------------------------------------------------------------------
if ($claudeCmd -and -not $SkipClaudeCall) {
    foreach ($d in $deployedFamilies) {
        $modelArg = $d.Family.ToLower()
        Write-Host ""
        Write-Host "  -> claude --model $modelArg -p 'say hi in 5 words'" -ForegroundColor Gray
        try {
            $reply = 'say hi in 5 words' | & claude --model $modelArg -p 2>&1 | Out-String
            $reply = $reply.Trim()
            if ($LASTEXITCODE -eq 0 -and $reply) {
                $snippet = if ($reply.Length -gt 80) { $reply.Substring(0, 80) + '...' } else { $reply }
                Add-Result "claude -p ($($d.Family))" 'PASS' $snippet
            } else {
                Add-Result "claude -p ($($d.Family))" 'FAIL' "exit $LASTEXITCODE - $reply"
            }
        } catch {
            Add-Result "claude -p ($($d.Family))" 'FAIL' $_.Exception.Message
        }
    }
} elseif ($SkipClaudeCall) {
    Add-Result 'claude -p round trip' 'WARN' 'skipped (-SkipClaudeCall)'
}

# ---------------------------------------------------------------------------
# 7. Optional Python Entra ID round trip.
# ---------------------------------------------------------------------------
if ($RunPythonSample) {
    $envLocal = Join-Path $RepoRoot '.env.local'
    if (-not (Test-Path $envLocal)) {
        Add-Result 'Python sample (hello_claude.py)' 'WARN' "no .env.local at repo root - run 'azd env get-values | Out-File -Encoding utf8 ../.env.local' first"
    } else {
        $py = Get-Command python -ErrorAction SilentlyContinue
        if (-not $py) {
            Add-Result 'Python sample (hello_claude.py)' 'WARN' 'python not on PATH (activate venv?)'
        } else {
            Push-Location $RepoRoot
            try {
                Write-Host ""
                Write-Host "  -> python src/hello_claude.py" -ForegroundColor Gray
                $pyOut = & python src/hello_claude.py 2>&1 | Out-String
                if ($LASTEXITCODE -eq 0) {
                    $snippet = ($pyOut.Trim() -split "`n" | Select-Object -First 1).ToString()
                    if ($snippet.Length -gt 80) { $snippet = $snippet.Substring(0, 80) + '...' }
                    Add-Result 'Python sample (hello_claude.py)' 'PASS' $snippet
                } else {
                    Add-Result 'Python sample (hello_claude.py)' 'FAIL' "exit $LASTEXITCODE - $($pyOut.Trim())"
                }
            } finally {
                Pop-Location
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host " Verification summary" -ForegroundColor Cyan
Write-Host "=============================================================" -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String | Write-Host

$failures = @($results | Where-Object Status -eq 'FAIL')
$warnings = @($results | Where-Object Status -eq 'WARN')
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) check(s) FAILED. See above." -ForegroundColor Red
    exit 1
}
if ($warnings.Count -gt 0) {
    Write-Host "$($warnings.Count) warning(s). Deployment is usable; review above for follow-ups." -ForegroundColor Yellow
}
Write-Host "All required checks passed." -ForegroundColor Green
exit 0
