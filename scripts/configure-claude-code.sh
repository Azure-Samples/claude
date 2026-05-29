#!/usr/bin/env bash
# Configure Claude Code CLI for Microsoft Foundry after `azd up`.
#
# Designed to be invoked from the `postprovision` hook in `azure.yaml`.
# Reads the per-family deployment outputs from `azd env get-values` and
# wires up Claude Code so the user can immediately run `claude`:
#
#   1. Writes claude-code.env.ps1 / claude-code.env.sh at the repo root with
#      ANTHROPIC_DEFAULT_<FAMILY>_MODEL for each non-empty family deployment.
#   2. Writes / merges .vscode/settings.json with claudeCode.environmentVariables
#      and claudeCode.disableLoginPrompt.
#   3. Detects / optionally installs the `claude` CLI.
#
# Exit codes:
#   0  Configuration written.
#   1  Required outputs not available.
#   2  azd CLI not on PATH (standalone mode).

set -euo pipefail

fail() {
    local code="$1"; shift
    printf '\nERROR: %s\n\n' "$*" >&2
    exit "$code"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# .vscode/settings.json is opt-in. Most users of this starter call Claude from
# the Anthropic SDK, the Claude Code CLI (uses the activator at the repo root,
# no workspace settings needed), or another OpenAI-compatible client. Only
# users of the Anthropic Claude Code VS Code extension benefit from having
# claudeCode.* keys written into their workspace settings, so make them ask:
#   azd env set CLAUDE_WRITE_VSCODE_SETTINGS 1
# (or pass --write-vscode-settings when running the script standalone).
WRITE_VSCODE_SETTINGS="${CLAUDE_WRITE_VSCODE_SETTINGS:-0}"
case "$WRITE_VSCODE_SETTINGS" in
    1|true|TRUE|yes|YES|on|ON) WRITE_VSCODE_SETTINGS=1 ;;
    *) WRITE_VSCODE_SETTINGS=0 ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root)             REPO_ROOT="$2"; shift 2 ;;
        --repo-root=*)           REPO_ROOT="${1#*=}"; shift ;;
        --write-vscode-settings) WRITE_VSCODE_SETTINGS=1; shift ;;
        # Deprecated no-op: skipping is now the default. Kept so existing CI
        # / docs that still pass --skip-vscode-settings don't break.
        --skip-vscode-settings)  shift ;;
        *) fail 2 "Unknown argument: $1" ;;
    esac
done
echo "Configuring Claude Code: repo root '$REPO_ROOT'"

ACCOUNT_NAME="${FOUNDRY_ACCOUNT_NAME:-}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
HAIKU_DEPLOY="${CLAUDE_HAIKU_DEPLOYMENT_NAME:-}"
SONNET_DEPLOY="${CLAUDE_SONNET_DEPLOYMENT_NAME:-}"
OPUS_DEPLOY="${CLAUDE_OPUS_DEPLOYMENT_NAME:-}"
LEGACY_DEPLOY="${CLAUDE_DEPLOYMENT_NAME:-}"

if [ -z "$ACCOUNT_NAME" ] || { [ -z "$HAIKU_DEPLOY" ] && [ -z "$SONNET_DEPLOY" ] && [ -z "$OPUS_DEPLOY" ] && [ -z "$LEGACY_DEPLOY" ]; }; then
    if ! command -v azd >/dev/null 2>&1; then
        fail 2 "azd CLI not on PATH and required outputs not in env. Install azd or run from an azd-aware shell."
    fi
    echo "Reading outputs from 'azd env get-values'..."
    while IFS= read -r line; do
        key="$(echo "$line" | sed -n 's/^\([A-Z0-9_]*\)=.*/\1/p')"
        val="$(echo "$line" | sed -n 's/^[A-Z0-9_]*="\{0,1\}\(.*[^"]\)"\{0,1\}$/\1/p')"
        case "$key" in
            FOUNDRY_ACCOUNT_NAME)          [ -z "$ACCOUNT_NAME" ]   && ACCOUNT_NAME="$val" ;;
            AZURE_RESOURCE_GROUP)          [ -z "$RESOURCE_GROUP" ] && RESOURCE_GROUP="$val" ;;
            CLAUDE_HAIKU_DEPLOYMENT_NAME)  [ -z "$HAIKU_DEPLOY" ]   && HAIKU_DEPLOY="$val" ;;
            CLAUDE_SONNET_DEPLOYMENT_NAME) [ -z "$SONNET_DEPLOY" ]  && SONNET_DEPLOY="$val" ;;
            CLAUDE_OPUS_DEPLOYMENT_NAME)   [ -z "$OPUS_DEPLOY" ]    && OPUS_DEPLOY="$val" ;;
            CLAUDE_DEPLOYMENT_NAME)        [ -z "$LEGACY_DEPLOY" ]  && LEGACY_DEPLOY="$val" ;;
        esac
    done < <(azd env get-values 2>/dev/null || true)
fi

[ -z "$ACCOUNT_NAME" ] && fail 1 "FOUNDRY_ACCOUNT_NAME not available. Has 'azd provision' completed?"

# Build parallel arrays of (family, deployment) for deployed families.
FAMILIES=()
DEPLOYMENTS=()
[ -n "$HAIKU_DEPLOY" ]  && { FAMILIES+=("HAIKU");  DEPLOYMENTS+=("$HAIKU_DEPLOY"); }
[ -n "$SONNET_DEPLOY" ] && { FAMILIES+=("SONNET"); DEPLOYMENTS+=("$SONNET_DEPLOY"); }
[ -n "$OPUS_DEPLOY" ]   && { FAMILIES+=("OPUS");   DEPLOYMENTS+=("$OPUS_DEPLOY"); }

if [ "${#FAMILIES[@]}" -eq 0 ]; then
    # Legacy fallback: infer family from the deployment name.
    [ -z "$LEGACY_DEPLOY" ] && fail 1 "No family deployments and no legacy CLAUDE_DEPLOYMENT_NAME found. Has 'azd provision' completed?"
    LOWER="$(echo "$LEGACY_DEPLOY" | tr '[:upper:]' '[:lower:]')"
    case "$LOWER" in
        *sonnet*) FAMILIES+=("SONNET") ;;
        *haiku*)  FAMILIES+=("HAIKU")  ;;
        *opus*)   FAMILIES+=("OPUS")   ;;
        *) fail 1 "Could not infer Claude family from deployment name '$LEGACY_DEPLOY'." ;;
    esac
    DEPLOYMENTS+=("$LEGACY_DEPLOY")
fi

echo "  Foundry account : $ACCOUNT_NAME"
for i in "${!FAMILIES[@]}"; do
    printf "  %-15s : %s\n" "${FAMILIES[$i]}" "${DEPLOYMENTS[$i]}"
done

# ---------------------------------------------------------------------------
# 1. Activator scripts.
# ---------------------------------------------------------------------------
PS1_PATH="$REPO_ROOT/claude-code.env.ps1"
SH_PATH="$REPO_ROOT/claude-code.env.sh"

{
    echo "# Auto-generated by scripts/configure-claude-code.sh — safe to overwrite."
    echo "# Source me with:   . ./claude-code.env.ps1"
    echo "# Then run:         claude"
    echo ""
    echo "# Scope 'az login' (and azd) to this workspace only — never touches ~/.azure"
    echo "# and never leaks tokens into other VS Code windows or shells."
    echo "\$_claudeRoot = Split-Path -Parent \$MyInvocation.MyCommand.Path"
    echo "\$env:AZURE_CONFIG_DIR = Join-Path \$_claudeRoot '.azure-cli'"
    echo "if (-not (Test-Path \$env:AZURE_CONFIG_DIR)) { New-Item -ItemType Directory -Path \$env:AZURE_CONFIG_DIR -Force | Out-Null }"
    echo ""
    echo "\$env:CLAUDE_CODE_USE_FOUNDRY = '1'"
    echo "\$env:ANTHROPIC_FOUNDRY_RESOURCE = '$ACCOUNT_NAME'"
    for i in "${!FAMILIES[@]}"; do
        echo "\$env:ANTHROPIC_DEFAULT_${FAMILIES[$i]}_MODEL = '${DEPLOYMENTS[$i]}'"
    done
    echo ""
    echo "Write-Host \"Claude Code configured for Foundry resource '$ACCOUNT_NAME'.\" -ForegroundColor Green"
    echo "Write-Host \"Azure CLI config scoped to: \$env:AZURE_CONFIG_DIR\" -ForegroundColor Green"
    echo "Write-Host \"Authentication: Microsoft Entra ID via 'az login' (already done if 'azd up' succeeded).\" -ForegroundColor Green"
} > "$PS1_PATH"

{
    echo "# Auto-generated by scripts/configure-claude-code.sh — safe to overwrite."
    echo "# Source me with:   source ./claude-code.env.sh   (or: . ./claude-code.env.sh)"
    echo "# Then run:         claude"
    echo ""
    echo "# Scope 'az login' (and azd) to this workspace only — never touches ~/.azure"
    echo "# and never leaks tokens into other VS Code windows or shells."
    echo "_claude_root=\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]:-\$0}\")\" && pwd)\""
    echo "export AZURE_CONFIG_DIR=\"\$_claude_root/.azure-cli\""
    echo "mkdir -p \"\$AZURE_CONFIG_DIR\""
    echo "unset _claude_root"
    echo ""
    echo "export CLAUDE_CODE_USE_FOUNDRY=1"
    echo "export ANTHROPIC_FOUNDRY_RESOURCE='$ACCOUNT_NAME'"
    for i in "${!FAMILIES[@]}"; do
        echo "export ANTHROPIC_DEFAULT_${FAMILIES[$i]}_MODEL='${DEPLOYMENTS[$i]}'"
    done
    echo ""
    echo "echo \"Claude Code configured for Foundry resource '$ACCOUNT_NAME'.\""
    echo "echo \"Azure CLI config scoped to: \$AZURE_CONFIG_DIR\""
    echo "echo \"Authentication: Microsoft Entra ID via 'az login' (already done if 'azd up' succeeded).\""
} > "$SH_PATH"

echo "Wrote activator: $PS1_PATH"
echo "Wrote activator: $SH_PATH"

# ---------------------------------------------------------------------------
# 2. .vscode/settings.json — use python for safe JSON merge.
# ---------------------------------------------------------------------------
PYTHON_BIN=""
for cand in python python3; do
    if command -v "$cand" >/dev/null 2>&1; then PYTHON_BIN="$cand"; break; fi
done

if [ "${WRITE_VSCODE_SETTINGS:-}" != "1" ]; then
    echo "Skipping .vscode/settings.json (opt-in). Set 'azd env set CLAUDE_WRITE_VSCODE_SETTINGS 1' before 'azd up' to wire up the Anthropic Claude Code VS Code extension automatically. The activator above already works for sourced shells."
elif [ -n "$PYTHON_BIN" ]; then
    VSCODE_DIR="$REPO_ROOT/.vscode"
    mkdir -p "$VSCODE_DIR"
    SETTINGS_PATH="$VSCODE_DIR/settings.json"

    # Pass deployment list as a tab-separated string for python to parse.
    PAIRS=""
    for i in "${!FAMILIES[@]}"; do
        PAIRS+="${FAMILIES[$i]}=${DEPLOYMENTS[$i]}"$'\t'
    done

    ACCOUNT_NAME="$ACCOUNT_NAME" SETTINGS_PATH="$SETTINGS_PATH" PAIRS="$PAIRS" \
    "$PYTHON_BIN" - <<'PYEOF'
import json, os, sys
path = os.environ['SETTINGS_PATH']
data = {}
if os.path.exists(path):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            text = f.read().strip()
            if text:
                data = json.loads(text)
        if not isinstance(data, dict):
            print(f"WARNING: {path} root is not an object; leaving untouched.", file=sys.stderr)
            sys.exit(0)
    except Exception as e:
        print(f"WARNING: Could not parse {path} ({e}); leaving untouched.", file=sys.stderr)
        sys.exit(0)

env = [
    {'name': 'CLAUDE_CODE_USE_FOUNDRY', 'value': '1'},
    {'name': 'ANTHROPIC_FOUNDRY_RESOURCE', 'value': os.environ['ACCOUNT_NAME']},
]
for pair in os.environ['PAIRS'].split('\t'):
    if not pair:
        continue
    family, deployment = pair.split('=', 1)
    env.append({'name': f'ANTHROPIC_DEFAULT_{family}_MODEL', 'value': deployment})

data['claudeCode.environmentVariables'] = env
data['claudeCode.disableLoginPrompt'] = True

# Scope 'az login' (and azd) to a workspace-local config dir so it never
# touches ~/.azure and never leaks tokens into other VS Code windows.
# Applies to every terminal VS Code spawns in this workspace.
data['terminal.integrated.env.windows'] = {'AZURE_CONFIG_DIR': '${workspaceFolder}\\.azure-cli'}
data['terminal.integrated.env.linux']   = {'AZURE_CONFIG_DIR': '${workspaceFolder}/.azure-cli'}
data['terminal.integrated.env.osx']     = {'AZURE_CONFIG_DIR': '${workspaceFolder}/.azure-cli'}

data.pop('Claude Code: Environment Variables', None)

with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
print(f"Wrote VS Code settings: {path}")
PYEOF
elif [ "${WRITE_VSCODE_SETTINGS:-}" = "1" ]; then
    echo "WARNING: python not found on PATH; skipping .vscode/settings.json."
fi

# ---------------------------------------------------------------------------
# 2b. .claude/settings.json — pin the workspace default model to a deployed
# family. Avoids "model X is not available on your foundry deployment" when
# the user's global ~/.claude/settings.json has `model` set to a family this
# workspace didn't deploy.
# Family priority: sonnet > opus > haiku.
# ---------------------------------------------------------------------------
WORKSPACE_MODEL=""
for fam in "${FAMILIES[@]}"; do
    [ "$fam" = "SONNET" ] && WORKSPACE_MODEL="sonnet" && break
done
if [ -z "$WORKSPACE_MODEL" ]; then
    for fam in "${FAMILIES[@]}"; do
        [ "$fam" = "OPUS" ] && WORKSPACE_MODEL="opus" && break
    done
fi
if [ -z "$WORKSPACE_MODEL" ]; then
    for fam in "${FAMILIES[@]}"; do
        [ "$fam" = "HAIKU" ] && WORKSPACE_MODEL="haiku" && break
    done
fi

if [ -n "$WORKSPACE_MODEL" ] && [ -n "$PYTHON_BIN" ]; then
    CLAUDE_DIR="$REPO_ROOT/.claude"
    mkdir -p "$CLAUDE_DIR"
    CLAUDE_SETTINGS_PATH="$CLAUDE_DIR/settings.json"

    CLAUDE_SETTINGS_PATH="$CLAUDE_SETTINGS_PATH" WORKSPACE_MODEL="$WORKSPACE_MODEL" \
    "$PYTHON_BIN" - <<'PYEOF'
import json, os, sys
path = os.environ['CLAUDE_SETTINGS_PATH']
data = {}
if os.path.exists(path):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            text = f.read().strip()
            if text:
                data = json.loads(text)
        if not isinstance(data, dict):
            print(f"WARNING: {path} root is not an object; leaving untouched.", file=sys.stderr)
            sys.exit(0)
    except Exception as e:
        print(f"WARNING: Could not parse {path} ({e}); leaving untouched.", file=sys.stderr)
        sys.exit(0)

data['model'] = os.environ['WORKSPACE_MODEL']

with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
print(f"Wrote Claude Code workspace settings: {path} (model={os.environ['WORKSPACE_MODEL']})")
PYEOF
elif [ -n "$WORKSPACE_MODEL" ]; then
    echo "WARNING: python not found on PATH; skipping .claude/settings.json."
fi

# ---------------------------------------------------------------------------
# 3. Detect / optionally install Claude Code CLI.
# ---------------------------------------------------------------------------
echo ""
if command -v claude >/dev/null 2>&1; then
    echo "Claude Code CLI detected: $(command -v claude)"
else
    echo "Claude Code CLI not found on PATH."
    AUTO="${CLAUDE_CODE_AUTO_INSTALL:-}"
    if [ -n "$AUTO" ] && [ "$AUTO" != "false" ] && [ "$AUTO" != "0" ]; then
        echo "CLAUDE_CODE_AUTO_INSTALL is set — running the official installer..."
        if curl -fsSL https://claude.ai/install.sh | bash; then
            if command -v claude >/dev/null 2>&1; then
                echo "Claude Code installed: $(command -v claude)"
            else
                echo "Install ran but 'claude' is still not on PATH. Open a new shell, or add the install dir to PATH."
            fi
        else
            echo "WARNING: auto-install failed. Install manually."
        fi
    else
        echo ""
        echo "To install (one-time):"
        echo "    curl -fsSL https://claude.ai/install.sh | bash"
        echo ""
        echo "Or set CLAUDE_CODE_AUTO_INSTALL=true and re-run 'azd provision' to install automatically."
    fi
fi

# ---------------------------------------------------------------------------
# 4. Final next-step message.
# ---------------------------------------------------------------------------
echo ""
echo "============================================================="
echo " Claude Code is configured for Microsoft Foundry."
echo "============================================================="
echo ""
echo "  Foundry resource : $ACCOUNT_NAME"
for i in "${!FAMILIES[@]}"; do
    printf "  %-15s : %s\n" "${FAMILIES[$i]} deployment" "${DEPLOYMENTS[$i]}"
done
[ -n "$RESOURCE_GROUP" ] && echo "  Resource group   : $RESOURCE_GROUP"
echo ""
echo "To start Claude Code from your terminal:"
echo ""
echo "  Bash / WSL:"
echo "    source $REPO_ROOT/claude-code.env.sh"
echo "    claude"
echo ""
echo "  PowerShell:"
echo "    . $REPO_ROOT/claude-code.env.ps1"
echo "    claude"
echo ""
echo "Or in VS Code: install the 'Claude Code' extension"
echo "(https://marketplace.visualstudio.com/items?itemName=anthropic.claude-code)"
if [ "${WRITE_VSCODE_SETTINGS:-}" = "1" ]; then
    echo "- the .vscode/settings.json in this workspace already wires it up."
else
    echo "- then re-run 'azd env set CLAUDE_WRITE_VSCODE_SETTINGS 1; azd provision'"
    echo "  (or 'bash scripts/configure-claude-code.sh --write-vscode-settings')"
    echo "  to auto-wire the extension to this Foundry deployment."
fi
echo ""
exit 0
