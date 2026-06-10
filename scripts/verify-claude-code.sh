#!/usr/bin/env bash
# End-to-end smoke test for a freshly provisioned Claude-on-Foundry deployment.
# See verify-claude-code.ps1 for the full docstring. POSIX flavor, same checks.
#
# Usage:
#   bash scripts/verify-claude-code.sh                       # all checks + claude -p per family
#   bash scripts/verify-claude-code.sh --skip-claude-call    # config checks only, no token cost
#   bash scripts/verify-claude-code.sh --auto-install        # install claude CLI if missing
#   bash scripts/verify-claude-code.sh --run-python-sample   # also run python src/hello_claude.py
#   bash scripts/verify-claude-code.sh --wait-for-deployment # poll RP while any deployment is still Creating
#                                                              (use after a GatewayTimeout from `azd up`)
#   bash scripts/verify-claude-code.sh --wait-timeout 1800   # cap on --wait-for-deployment (default 1800s)
#
# Exit codes:
#   0  all checks passed (warnings allowed)
#   1  one or more required checks failed
set -u

repo_root=""
auto_install=0
skip_claude=0
run_python=0
wait_deployment=0
wait_timeout=1800

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root)            repo_root="$2"; shift 2 ;;
        --auto-install)         auto_install=1; shift ;;
        --skip-claude-call)     skip_claude=1; shift ;;
        --run-python-sample)    run_python=1; shift ;;
        --wait-for-deployment)  wait_deployment=1; shift ;;
        --wait-timeout)         wait_timeout="$2"; shift 2 ;;
        -h|--help)              sed -n '2,15p' "$0"; exit 0 ;;
        *)                      echo "Unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$repo_root" ]]; then
    here="$(cd "$(dirname "$0")" && pwd)"
    repo_root="$(cd "$here/.." && pwd)"
fi

# ANSI colors (only when stdout is a tty).
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_YEL=$'\033[0;33m'; C_GRN=$'\033[0;32m'; C_CYA=$'\033[0;36m'; C_DIM=$'\033[0;90m'; C_RST=$'\033[0m'
else
    C_RED=''; C_YEL=''; C_GRN=''; C_CYA=''; C_DIM=''; C_RST=''
fi

results=()
fail_count=0
warn_count=0
add_result() {
    local status="$1" name="$2" detail="${3:-}"
    case "$status" in
        PASS) color="$C_GRN" ;;
        WARN) color="$C_YEL"; warn_count=$((warn_count + 1)) ;;
        FAIL) color="$C_RED"; fail_count=$((fail_count + 1)) ;;
        *)    color="" ;;
    esac
    if [[ -n "$detail" ]]; then
        printf "  ${color}[%-4s] %s${C_RST} - %s\n" "$status" "$name" "$detail"
    else
        printf "  ${color}[%-4s] %s${C_RST}\n" "$status" "$name"
    fi
    results+=("$status|$name|$detail")
}

echo
printf "${C_CYA}Verifying Claude Code wiring under: %s${C_RST}\n" "$repo_root"
echo

# 1. Activator file.
activator="$repo_root/claude-code.env.sh"
if [[ ! -f "$activator" ]]; then
    add_result FAIL "Activator (claude-code.env.sh)" "not found - run azd up or scripts/configure-claude-code.sh first"
    echo
    echo "${C_RED}Stopping: cannot verify without an activator file.${C_RST}"
    exit 1
fi
add_result PASS "Activator (claude-code.env.sh)" "$activator"

# 2. Source activator + check env vars.
# shellcheck disable=SC1090
source "$activator" >/dev/null 2>&1 || true

for v in CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_FOUNDRY_RESOURCE; do
    val="${!v:-}"
    if [[ -n "$val" ]]; then
        add_result PASS "env $v" "$val"
    else
        add_result FAIL "env $v" "not set after sourcing activator"
    fi
done

deployed_families=()
for fam in HAIKU SONNET OPUS; do
    var="ANTHROPIC_DEFAULT_${fam}_MODEL"
    val="${!var:-}"
    if [[ -n "$val" ]]; then
        add_result PASS "env $var" "$val"
        deployed_families+=("$fam|$val")
    fi
done
if [[ ${#deployed_families[@]} -eq 0 ]]; then
    add_result FAIL "Deployed families" "no ANTHROPIC_DEFAULT_<FAMILY>_MODEL set"
else
    list=$(IFS=,; echo "${deployed_families[*]%%|*}")
    add_result PASS "Deployed families" "$list"
fi

foundry_resource="${ANTHROPIC_FOUNDRY_RESOURCE:-}"

# 3. .vscode/settings.json sanity.
settings="$repo_root/.vscode/settings.json"
if [[ -f "$settings" ]]; then
    if command -v jq >/dev/null 2>&1; then
        names=$(jq -r '."claudeCode.environmentVariables" // [] | map(.name) | join(", ")' "$settings" 2>/dev/null)
        if [[ -n "$names" ]]; then
            add_result PASS "VS Code settings.json" "$names"
        else
            add_result WARN "VS Code settings.json" "no 'claudeCode.environmentVariables' key (extension may show login prompt)"
        fi
    elif grep -q 'claudeCode.environmentVariables' "$settings" 2>/dev/null; then
        add_result PASS "VS Code settings.json" "(jq not installed; grep'd claudeCode.environmentVariables key)"
    else
        add_result WARN "VS Code settings.json" "no 'claudeCode.environmentVariables' key"
    fi
else
    add_result WARN "VS Code settings.json" "missing (CLI works fine; VS Code extension won't auto-configure)"
fi

# 4. az login.
if ! command -v az >/dev/null 2>&1; then
    add_result WARN "Azure CLI (az)" "not on PATH - cannot validate tenant"
else
    acct_json=$(az account show -o json 2>/dev/null || true)
    if [[ -z "$acct_json" ]]; then
        add_result FAIL "az account show" "not logged in - run az login --tenant <tenant-id>"
    else
        user=$(echo "$acct_json" | sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' | head -1)
        tenant=$(echo "$acct_json" | sed -n 's/.*"tenantId": *"\([^"]*\)".*/\1/p' | head -1)
        sub=$(echo "$acct_json" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' | head -1)
        add_result PASS "az account show" "user=$user tenant=$tenant sub=$sub"

        if [[ -n "$foundry_resource" ]]; then
            rg=$(az cognitiveservices account list -o tsv --query "[?name=='$foundry_resource'].resourceGroup | [0]" 2>/dev/null || echo '')
            loc=$(az cognitiveservices account list -o tsv --query "[?name=='$foundry_resource'].location | [0]" 2>/dev/null || echo '')
            if [[ -n "$rg" ]]; then
                add_result PASS "Foundry resource reachable" "$foundry_resource (rg: $rg, location: $loc)"
                foundry_rg="$rg"
            else
                add_result WARN "Foundry resource reachable" "$foundry_resource not visible to current az login - wrong tenant/subscription?"
            fi
        fi
    fi
fi

# 4b. Model deployment provisioning state.
#
#     A `GatewayTimeout` from `Microsoft.CognitiveServices` during `azd up`
#     is an ARM-layer poll timeout, not a deployment failure -- the RP
#     often keeps provisioning for many more minutes. Ask the RP directly
#     so we can confirm the actual outcome without re-running `azd up`.
foundry_rg="${foundry_rg:-}"
if command -v az >/dev/null 2>&1 && [[ -n "$foundry_rg" && ${#deployed_families[@]} -gt 0 ]]; then
    poll_interval=30
    deadline=$(( $(date +%s) + (wait_timeout > 0 ? wait_timeout : 0) ))
    first_pass=1
    while :; do
        deps_json=$(az cognitiveservices account deployment list -g "$foundry_rg" -n "$foundry_resource" -o json 2>/dev/null || echo '[]')
        still_creating=()
        for entry in "${deployed_families[@]}"; do
            name="${entry##*|}"
            state=$(echo "$deps_json" | python -c "import json,sys; data=json.load(sys.stdin); m=[d for d in data if d.get('name')==sys.argv[1]]; print(m[0]['properties']['provisioningState'] if m else '<missing>')" "$name" 2>/dev/null || echo '<unknown>')
            case "$state" in
                Succeeded|Failed|Canceled|'<missing>'|'<unknown>') : ;;
                *) still_creating+=("$name") ;;
            esac
            if [[ $first_pass -eq 1 || ${#still_creating[@]} -eq 0 || $wait_deployment -eq 0 || $(date +%s) -ge $deadline ]]; then
                case "$state" in
                    Succeeded)    add_result PASS "Deployment '$name'" "provisioningState=Succeeded" ;;
                    Failed)       add_result FAIL "Deployment '$name'" "provisioningState=Failed" ;;
                    Canceled)     add_result FAIL "Deployment '$name'" "provisioningState=Canceled" ;;
                    '<missing>')  add_result WARN "Deployment '$name'" "not found on Foundry account - may still be creating, or activator is stale" ;;
                    '<unknown>')  add_result WARN "Deployment '$name'" "could not parse deployment list (jq/python missing?)" ;;
                    *)
                        if [[ $wait_deployment -eq 1 ]]; then
                            add_result WARN "Deployment '$name'" "still $state after waiting ${wait_timeout}s"
                        else
                            add_result WARN "Deployment '$name'" "provisioningState=$state; rerun with --wait-for-deployment to poll"
                        fi
                        ;;
                esac
            fi
        done

        if [[ $wait_deployment -eq 0 || ${#still_creating[@]} -eq 0 || $(date +%s) -ge $deadline ]]; then
            break
        fi
        remaining=$(( deadline - $(date +%s) ))
        printf "  ${C_DIM}... %d deployment(s) still provisioning (%s); polling again in %ds (timeout in %ds)${C_RST}\n" "${#still_creating[@]}" "$(IFS=,; echo "${still_creating[*]}")" "$poll_interval" "$remaining"
        sleep "$poll_interval"
        first_pass=0
    done
elif [[ $wait_deployment -eq 1 ]]; then
    add_result WARN "Model deployment state" "cannot poll - az not available, Foundry resource not visible, or no families set"
fi

# 5. Claude Code CLI on PATH.
auto_install_env="${CLAUDE_CODE_AUTO_INSTALL:-}"
auto_install_env_on=0
if [[ -n "$auto_install_env" && "$auto_install_env" != "false" && "$auto_install_env" != "0" ]]; then
    auto_install_env_on=1
fi

if ! command -v claude >/dev/null 2>&1; then
    if [[ $auto_install -eq 1 || $auto_install_env_on -eq 1 ]]; then
        echo
        echo "${C_CYA}Installing Claude Code CLI...${C_RST}"
        if curl -fsSL https://claude.ai/install.sh | bash; then
            export PATH="$HOME/.local/bin:$PATH"
        else
            add_result FAIL "Claude Code CLI install" "installer exited non-zero"
        fi
    fi
fi

if command -v claude >/dev/null 2>&1; then
    ver=$(claude --version 2>/dev/null | head -1)
    add_result PASS "Claude Code CLI" "$(command -v claude) ($ver)"

    # 6. claude -p per family.
    if [[ $skip_claude -eq 0 ]]; then
        for entry in "${deployed_families[@]}"; do
            fam="${entry%%|*}"
            model_arg=$(echo "$fam" | tr '[:upper:]' '[:lower:]')
            echo
            echo "  ${C_DIM}-> claude --model $model_arg -p 'say hi in 5 words'${C_RST}"
            reply=$(echo 'say hi in 5 words' | claude --model "$model_arg" -p 2>&1) || rc=$? || rc=$?
            rc=${rc:-0}
            if [[ $rc -eq 0 && -n "$reply" ]]; then
                snippet="${reply:0:80}"
                add_result PASS "claude -p ($fam)" "$snippet"
            else
                add_result FAIL "claude -p ($fam)" "exit $rc - $reply"
            fi
        done
    else
        add_result WARN "claude -p round trip" "skipped (--skip-claude-call)"
    fi
else
    add_result WARN "Claude Code CLI" "not on PATH - install with 'curl -fsSL https://claude.ai/install.sh | bash' or rerun with --auto-install"
fi

# 7. Optional Python Entra ID round trip.
if [[ $run_python -eq 1 ]]; then
    env_local="$repo_root/.env.local"
    if [[ ! -f "$env_local" ]]; then
        add_result WARN "Python sample (hello_claude.py)" "no .env.local at repo root - run 'azd env get-values > ../.env.local' first"
    elif ! command -v python >/dev/null 2>&1; then
        add_result WARN "Python sample (hello_claude.py)" "python not on PATH (activate venv?)"
    else
        echo
        echo "  ${C_DIM}-> python src/hello_claude.py${C_RST}"
        (cd "$repo_root" && python src/hello_claude.py >/tmp/hello_claude.out 2>&1) || rc=$? || rc=$?
        rc=${rc:-0}
        out=$(head -1 /tmp/hello_claude.out 2>/dev/null || echo '')
        if [[ $rc -eq 0 ]]; then
            add_result PASS "Python sample (hello_claude.py)" "${out:0:80}"
        else
            add_result FAIL "Python sample (hello_claude.py)" "exit $rc - $out"
        fi
    fi
fi

# Summary.
echo
echo "${C_CYA}=============================================================${C_RST}"
echo "${C_CYA} Verification summary${C_RST}"
echo "${C_CYA}=============================================================${C_RST}"
printf "%-4s  %-40s  %s\n" "STAT" "CHECK" "DETAIL"
printf "%-4s  %-40s  %s\n" "----" "----------------------------------------" "------"
for line in "${results[@]}"; do
    status="${line%%|*}"
    rest="${line#*|}"
    name="${rest%%|*}"
    detail="${rest#*|}"
    printf "%-4s  %-40s  %s\n" "$status" "$name" "$detail"
done
echo

if [[ $fail_count -gt 0 ]]; then
    echo "${C_RED}$fail_count check(s) FAILED. See above.${C_RST}"
    exit 1
fi
if [[ $warn_count -gt 0 ]]; then
    echo "${C_YEL}$warn_count warning(s). Deployment is usable; review above for follow-ups.${C_RST}"
fi
echo "${C_GRN}All required checks passed.${C_RST}"
exit 0
