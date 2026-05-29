<#
.SYNOPSIS
    Configure Claude Code CLI for Microsoft Foundry after `azd up`.

.DESCRIPTION
    Designed to be invoked from the `postprovision` hook in `azure.yaml`.
    Reads the per-family deployment outputs from `azd env get-values` and
    wires up Claude Code so the user can immediately run `claude`:

      1. Writes a project-scoped activator at the repo root:
             claude-code.env.ps1   (PowerShell)
             claude-code.env.sh    (Bash / WSL)
         containing ANTHROPIC_DEFAULT_<FAMILY>_MODEL for each non-empty
         family deployment (haiku / sonnet / opus). Documented at:
         https://learn.microsoft.com/azure/foundry/foundry-models/how-to/configure-claude-code

      2. Writes (or merges into) `.vscode/settings.json` with
         `claudeCode.environmentVariables` and `claudeCode.disableLoginPrompt`.

      3. Detects whether the `claude` CLI is on PATH. If not, prints the
         platform-appropriate install command. Set CLAUDE_CODE_AUTO_INSTALL=true
         to run the official installer automatically.

    Works on PowerShell 7+ on Windows, Linux, and macOS. Safe to re-run.

.NOTES
    Exit codes:
      0  Configuration written.
      1  No deployment outputs found (provision didn't deploy any family).
      2  azd CLI not on PATH (when running standalone).
#>

[CmdletBinding()]
param(
    [string] $RepoRoot,
    [switch] $SkipVsCodeSettings
)

$ErrorActionPreference = 'Stop'

# Env-var opt-out so the postprovision hook can honor it without having to
# pass -SkipVsCodeSettings on the command line:
#   azd env set CLAUDE_SKIP_VSCODE_SETTINGS 1
if (-not $SkipVsCodeSettings) {
    $skipEnv = $env:CLAUDE_SKIP_VSCODE_SETTINGS
    if ($skipEnv -and $skipEnv -match '^(1|true|yes|on)$') {
        $SkipVsCodeSettings = $true
    }
}

function Fail([int]$code, [string]$message) {
    Write-Host ""
    Write-Host "ERROR: $message" -ForegroundColor Red
    Write-Host ""
    exit $code
}

# ---------------------------------------------------------------------------
# Locate the repo root.
# ---------------------------------------------------------------------------
if (-not $RepoRoot) {
    $here = Split-Path -Parent $PSCommandPath
    $RepoRoot = Resolve-Path (Join-Path $here '..') | Select-Object -ExpandProperty Path
}
Write-Host "Configuring Claude Code: repo root '$RepoRoot'"

# ---------------------------------------------------------------------------
# Resolve azd outputs.
# ---------------------------------------------------------------------------
$accountName    = $env:FOUNDRY_ACCOUNT_NAME
$resourceGroup  = $env:AZURE_RESOURCE_GROUP
$haikuDeploy    = $env:CLAUDE_HAIKU_DEPLOYMENT_NAME
$sonnetDeploy   = $env:CLAUDE_SONNET_DEPLOYMENT_NAME
$opusDeploy     = $env:CLAUDE_OPUS_DEPLOYMENT_NAME
$legacyDeploy   = $env:CLAUDE_DEPLOYMENT_NAME

# When the trio outputs aren't in env (running standalone), parse azd env.
$needsAzd = -not $accountName -or
            (-not $haikuDeploy -and -not $sonnetDeploy -and -not $opusDeploy -and -not $legacyDeploy)
if ($needsAzd) {
    $azd = Get-Command azd -ErrorAction SilentlyContinue
    if (-not $azd) {
        Fail 2 "azd CLI not on PATH and required outputs not in env. Install azd or run from an azd-aware shell."
    }
    Write-Host "Reading outputs from 'azd env get-values'..."
    $vals = & azd env get-values 2>$null
    foreach ($line in $vals) {
        if ($line -match '^(?<k>[A-Z0-9_]+)="?(?<v>.*?)"?$') {
            switch ($Matches['k']) {
                'FOUNDRY_ACCOUNT_NAME'           { if (-not $accountName)  { $accountName  = $Matches['v'] } }
                'AZURE_RESOURCE_GROUP'           { if (-not $resourceGroup){ $resourceGroup= $Matches['v'] } }
                'CLAUDE_HAIKU_DEPLOYMENT_NAME'   { if (-not $haikuDeploy)  { $haikuDeploy  = $Matches['v'] } }
                'CLAUDE_SONNET_DEPLOYMENT_NAME'  { if (-not $sonnetDeploy) { $sonnetDeploy = $Matches['v'] } }
                'CLAUDE_OPUS_DEPLOYMENT_NAME'    { if (-not $opusDeploy)   { $opusDeploy   = $Matches['v'] } }
                'CLAUDE_DEPLOYMENT_NAME'         { if (-not $legacyDeploy) { $legacyDeploy = $Matches['v'] } }
            }
        }
    }
}

if (-not $accountName) {
    Fail 1 "FOUNDRY_ACCOUNT_NAME not available. Has 'azd provision' completed?"
}

# Build the list of (family, deployment) pairs that were actually deployed.
$deployments = @()
if ($haikuDeploy)  { $deployments += [pscustomobject]@{ Family='HAIKU';  Deployment=$haikuDeploy  } }
if ($sonnetDeploy) { $deployments += [pscustomobject]@{ Family='SONNET'; Deployment=$sonnetDeploy } }
if ($opusDeploy)   { $deployments += [pscustomobject]@{ Family='OPUS';   Deployment=$opusDeploy   } }

if ($deployments.Count -eq 0) {
    # Legacy single-deployment fallback: infer family from the model name baked
    # into the deployment name (e.g. "claude-opus-4-6-abc123" → OPUS).
    if (-not $legacyDeploy) {
        Fail 1 "No family deployments and no legacy CLAUDE_DEPLOYMENT_NAME found. Has 'azd provision' completed?"
    }
    $lower = $legacyDeploy.ToLower()
    $family =
        if     ($lower -like '*sonnet*') { 'SONNET' }
        elseif ($lower -like '*haiku*')  { 'HAIKU'  }
        elseif ($lower -like '*opus*')   { 'OPUS'   }
        else { Fail 1 "Could not infer Claude family from deployment name '$legacyDeploy'." }
    $deployments += [pscustomobject]@{ Family=$family; Deployment=$legacyDeploy }
}

Write-Host "  Foundry account     : $accountName"
foreach ($d in $deployments) {
    Write-Host ("  {0,-18} : {1}" -f $d.Family, $d.Deployment)
}

# ---------------------------------------------------------------------------
# 1. Write the PowerShell + Bash activator scripts at the repo root.
# ---------------------------------------------------------------------------
$ps1Path = Join-Path $RepoRoot 'claude-code.env.ps1'
$shPath  = Join-Path $RepoRoot 'claude-code.env.sh'

$ps1Lines = @(
    "# Auto-generated by scripts/configure-claude-code.ps1 — safe to overwrite.",
    "# Source me with:   . ./claude-code.env.ps1",
    "# Then run:         claude",
    "",
    "# Scope 'az login' (and azd) to this workspace only — never touches ~/.azure",
    "# and never leaks tokens into other VS Code windows or shells.",
    "`$_claudeRoot = Split-Path -Parent `$MyInvocation.MyCommand.Path",
    "`$env:AZURE_CONFIG_DIR = Join-Path `$_claudeRoot '.azure-cli'",
    "if (-not (Test-Path `$env:AZURE_CONFIG_DIR)) { New-Item -ItemType Directory -Path `$env:AZURE_CONFIG_DIR -Force | Out-Null }",
    "",
    "`$env:CLAUDE_CODE_USE_FOUNDRY = '1'",
    "`$env:ANTHROPIC_FOUNDRY_RESOURCE = '$accountName'"
)
foreach ($d in $deployments) {
    $ps1Lines += "`$env:ANTHROPIC_DEFAULT_$($d.Family)_MODEL = '$($d.Deployment)'"
}
$ps1Lines += ""
$ps1Lines += "Write-Host `"Claude Code configured for Foundry resource '$accountName'.`" -ForegroundColor Green"
$ps1Lines += "Write-Host `"Azure CLI config scoped to: `$env:AZURE_CONFIG_DIR`" -ForegroundColor Green"
$ps1Lines += "Write-Host `"Authentication: Microsoft Entra ID via 'az login' (already done if 'azd up' succeeded).`" -ForegroundColor Green"

$shLines = @(
    "# Auto-generated by scripts/configure-claude-code.ps1 — safe to overwrite.",
    "# Source me with:   source ./claude-code.env.sh   (or: . ./claude-code.env.sh)",
    "# Then run:         claude",
    "",
    "# Scope 'az login' (and azd) to this workspace only — never touches ~/.azure",
    "# and never leaks tokens into other VS Code windows or shells.",
    "_claude_root=`"`$(cd `"`$(dirname `"`${BASH_SOURCE[0]:-`$0}`")`" && pwd)`"",
    "export AZURE_CONFIG_DIR=`"`$_claude_root/.azure-cli`"",
    "mkdir -p `"`$AZURE_CONFIG_DIR`"",
    "unset _claude_root",
    "",
    "export CLAUDE_CODE_USE_FOUNDRY=1",
    "export ANTHROPIC_FOUNDRY_RESOURCE='$accountName'"
)
foreach ($d in $deployments) {
    $shLines += "export ANTHROPIC_DEFAULT_$($d.Family)_MODEL='$($d.Deployment)'"
}
$shLines += ""
$shLines += "echo `"Claude Code configured for Foundry resource '$accountName'.`""
$shLines += "echo `"Azure CLI config scoped to: `$AZURE_CONFIG_DIR`""
$shLines += "echo `"Authentication: Microsoft Entra ID via 'az login' (already done if 'azd up' succeeded).`""

Set-Content -Path $ps1Path -Value ($ps1Lines -join [Environment]::NewLine) -Encoding utf8
Set-Content -Path $shPath  -Value ($shLines  -join "`n") -Encoding utf8 -NoNewline:$false
Write-Host "Wrote activator: $ps1Path"
Write-Host "Wrote activator: $shPath"

# ---------------------------------------------------------------------------
# 2. Write / merge `.vscode/settings.json` for the Claude Code VS Code extension.
# ---------------------------------------------------------------------------
if ($SkipVsCodeSettings) {
    Write-Host "Skipping .vscode/settings.json (CLAUDE_SKIP_VSCODE_SETTINGS / -SkipVsCodeSettings set). The activator above still wires up sourced shells."
} else {
    $vscodeDir = Join-Path $RepoRoot '.vscode'
    $settingsPath = Join-Path $vscodeDir 'settings.json'
    if (-not (Test-Path $vscodeDir)) {
        New-Item -ItemType Directory -Path $vscodeDir -Force | Out-Null
    }

    $existing = [ordered]@{}
    if (Test-Path $settingsPath) {
        try {
            $raw = Get-Content -Raw -Path $settingsPath
            if ($raw -and $raw.Trim()) {
                $obj = $raw | ConvertFrom-Json -ErrorAction Stop
                foreach ($p in $obj.PSObject.Properties) {
                    $existing[$p.Name] = $p.Value
                }
            }
        } catch {
            Write-Host "WARNING: Could not parse existing $settingsPath ($($_.Exception.Message)). Leaving it untouched." -ForegroundColor Yellow
            $SkipVsCodeSettings = $true
        }
    }

    if (-not $SkipVsCodeSettings) {
        # Use [ordered] hashtables per entry so name appears before value in
        # the rendered JSON (PSCustomObject hashtable iteration is unordered).
        $claudeEnv = @(
            [ordered]@{ name = 'CLAUDE_CODE_USE_FOUNDRY';    value = '1' }
            [ordered]@{ name = 'ANTHROPIC_FOUNDRY_RESOURCE'; value = $accountName }
        )
        foreach ($d in $deployments) {
            $claudeEnv += [ordered]@{ name = "ANTHROPIC_DEFAULT_$($d.Family)_MODEL"; value = $d.Deployment }
        }
        $existing['claudeCode.environmentVariables'] = $claudeEnv
        $existing['claudeCode.disableLoginPrompt']   = $true

        # Scope 'az login' (and azd) to a workspace-local config dir so it
        # never touches ~/.azure and never leaks tokens into other VS Code
        # windows. Applies to every terminal VS Code spawns in this workspace.
        $azCfgWin   = [ordered]@{ AZURE_CONFIG_DIR = '${workspaceFolder}\.azure-cli' }
        $azCfgPosix = [ordered]@{ AZURE_CONFIG_DIR = '${workspaceFolder}/.azure-cli' }
        $existing['terminal.integrated.env.windows'] = $azCfgWin
        $existing['terminal.integrated.env.linux']   = $azCfgPosix
        $existing['terminal.integrated.env.osx']     = $azCfgPosix

        # Strip any stale display-title key from prior versions of this script.
        if ($existing.Contains('Claude Code: Environment Variables')) {
            $existing.Remove('Claude Code: Environment Variables')
        }
        ($existing | ConvertTo-Json -Depth 8) | Set-Content -Path $settingsPath -Encoding utf8
        Write-Host "Wrote VS Code settings: $settingsPath"
    }
}

# ---------------------------------------------------------------------------
# 2b. Write / merge `.claude/settings.json` to pin the workspace default model
# to a deployed family. Avoids "model X is not available on your foundry
# deployment" when the user's global ~/.claude/settings.json has `model` set
# to a family this workspace didn't deploy.
# ---------------------------------------------------------------------------
# Family priority: sonnet > opus > haiku (matches outputs.tf legacy
# CLAUDE_DEPLOYMENT_NAME picker and the README's "recommended general default").
$workspaceModelFamily = $null
foreach ($d in $deployments) {
    if ($d.Family -eq 'SONNET') { $workspaceModelFamily = 'sonnet'; break }
}
if (-not $workspaceModelFamily) {
    foreach ($d in $deployments) {
        if ($d.Family -eq 'OPUS') { $workspaceModelFamily = 'opus'; break }
    }
}
if (-not $workspaceModelFamily) {
    foreach ($d in $deployments) {
        if ($d.Family -eq 'HAIKU') { $workspaceModelFamily = 'haiku'; break }
    }
}

if ($workspaceModelFamily) {
    $claudeDir = Join-Path $RepoRoot '.claude'
    $claudeSettingsPath = Join-Path $claudeDir 'settings.json'
    if (-not (Test-Path $claudeDir)) {
        New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
    }

    $claudeExisting = [ordered]@{}
    $skipClaudeMerge = $false
    if (Test-Path $claudeSettingsPath) {
        try {
            $raw = Get-Content -Raw -Path $claudeSettingsPath
            if ($raw -and $raw.Trim()) {
                $obj = $raw | ConvertFrom-Json -ErrorAction Stop
                foreach ($p in $obj.PSObject.Properties) {
                    $claudeExisting[$p.Name] = $p.Value
                }
            }
        } catch {
            Write-Host "WARNING: Could not parse existing $claudeSettingsPath ($($_.Exception.Message)). Leaving it untouched." -ForegroundColor Yellow
            $skipClaudeMerge = $true
        }
    }

    if (-not $skipClaudeMerge) {
        $claudeExisting['model'] = $workspaceModelFamily
        ($claudeExisting | ConvertTo-Json -Depth 8) | Set-Content -Path $claudeSettingsPath -Encoding utf8
        Write-Host "Wrote Claude Code workspace settings: $claudeSettingsPath (model=$workspaceModelFamily)"
    }
}

# ---------------------------------------------------------------------------
# 3. Detect / optionally install the Claude Code CLI.
# ---------------------------------------------------------------------------
$claude = Get-Command claude -ErrorAction SilentlyContinue
$autoInstall = $env:CLAUDE_CODE_AUTO_INSTALL -and ($env:CLAUDE_CODE_AUTO_INSTALL -ne 'false' -and $env:CLAUDE_CODE_AUTO_INSTALL -ne '0')

if ($claude) {
    Write-Host ""
    Write-Host "Claude Code CLI detected: $($claude.Source)" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Claude Code CLI not found on PATH." -ForegroundColor Yellow

    $onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or `
                 ($PSVersionTable.Platform -eq 'Win32NT') -or `
                 ($env:OS -eq 'Windows_NT')

    if ($autoInstall) {
        Write-Host "CLAUDE_CODE_AUTO_INSTALL is set — running the official installer..."
        try {
            if ($onWindows) {
                Invoke-RestMethod -Uri 'https://claude.ai/install.ps1' | Invoke-Expression
            } else {
                & bash -c "curl -fsSL https://claude.ai/install.sh | bash"
            }
            $claude = Get-Command claude -ErrorAction SilentlyContinue
            if ($claude) {
                Write-Host "Claude Code installed: $($claude.Source)" -ForegroundColor Green
            } else {
                Write-Host "Install ran but 'claude' is still not on PATH. Open a new shell, or add the install dir to PATH." -ForegroundColor Yellow
            }
        } catch {
            Write-Host "WARNING: auto-install failed ($($_.Exception.Message)). Install manually." -ForegroundColor Yellow
        }
    } else {
        Write-Host ""
        Write-Host "To install (one-time):" -ForegroundColor Cyan
        if ($onWindows) {
            Write-Host "    irm https://claude.ai/install.ps1 | iex"
            Write-Host "  or in Git Bash / WSL:"
            Write-Host "    curl -fsSL https://claude.ai/install.sh | bash"
        } else {
            Write-Host "    curl -fsSL https://claude.ai/install.sh | bash"
        }
        Write-Host ""
        Write-Host "Or set CLAUDE_CODE_AUTO_INSTALL=true and re-run 'azd provision' to install automatically."
    }
}

# ---------------------------------------------------------------------------
# 4. Final next-step message.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host " Claude Code is configured for Microsoft Foundry." -ForegroundColor Cyan
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Foundry resource : $accountName"
foreach ($d in $deployments) {
    Write-Host ("  {0,-16} : {1}" -f "$($d.Family) deployment", $d.Deployment)
}
if ($resourceGroup) { Write-Host "  Resource group   : $resourceGroup" }
Write-Host ""
Write-Host "To start Claude Code from your terminal:"
Write-Host ""
Write-Host "  PowerShell:" -ForegroundColor Cyan
Write-Host "    . $RepoRoot\claude-code.env.ps1"
Write-Host "    claude"
Write-Host ""
Write-Host "  Bash / WSL:" -ForegroundColor Cyan
Write-Host "    source $RepoRoot/claude-code.env.sh"
Write-Host "    claude"
Write-Host ""
Write-Host "Or in VS Code: install the 'Claude Code' extension"
Write-Host "(https://marketplace.visualstudio.com/items?itemName=anthropic.claude-code)"
Write-Host "— the .vscode/settings.json in this workspace already wires it up."
Write-Host ""
exit 0
