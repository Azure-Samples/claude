#!/usr/bin/env bash
# Preflight check for Claude-on-Microsoft-Foundry deployments.
#
# Per-family mode: set any of CLAUDE_HAIKU_MODEL / CLAUDE_SONNET_MODEL /
# CLAUDE_OPUS_MODEL to validate that family. Empty = skip. If all three are
# empty, falls back to CLAUDE_MODEL_NAME (legacy single-model behavior).
#
# Gates `azd up` on:
#   1. Required env vars being set.
#   2. (Informational) Marketplace catalog: each requested model exists in
#      the Anthropic-on-Foundry catalog (offer must resolve via
#      Microsoft.MarketplaceOrdering). A typo is a hard fail. Agreement
#      signed/unsigned is informational (RP auto-signs at deploy time on
#      eligible subs).
#   3. **Per-region Cognitive Services quota headroom** per model.
#      Hard fail (exit 6) when used + requested > limit. This catches the
#      opaque `400 715-123420` error that Terraform's azapi_resource returns
#      for quota-rejected requests (azapi bypasses ARM preflight; Bicep /
#      `az deployment group create` show the real `InsufficientQuota`).
#
# Exit codes:
#   0  Preflight passed (or skipped — see warnings).
#   4  Marketplace offer not found.
#   6  Insufficient quota (Terraform variant only; on Bicep this is a
#      warning because azd's own ARM preflight already surfaces it).
#
# The preflight is best-effort. If CLAUDE_ORGANIZATION_NAME / AZURE_LOCATION
# aren't set, or `az` isn't installed / logged in, it warns and exits 0 so
# `azd up` can continue (azd / Bicep will prompt for any missing parameter;
# the RP surfaces catalog / quota errors at deploy time, just less
# ergonomically). The marketplace-offer check remains a hard fail in both
# variants when it can run. The quota check is a hard fail only on the
# Terraform variant because azapi_resource swallows quota into the opaque
# 715-123420; on Bicep it's a warning because azd's own
# provisionParametersResolver prints InsufficientQuota next and prompts to
# continue.

set -euo pipefail

fail() {
    local code="$1"; shift
    printf '\nERROR: %s\n\n' "$*" >&2
    exit "$code"
}

warn() {
    printf 'Preflight: %s\n' "$*" >&2
}

# Detect which IaC variant the preprovision hook is running under. The hook
# always fires from inside the variant folder (infra-bicep/ or
# infra-terraform/), so the local azure.yaml tells us which provider azd is
# about to drive. This decides whether the quota check is a hard fail
# (Terraform: azapi_resource bypasses ARM preflight and the RP returns the
# opaque 400 715-123420, so we MUST catch it here) or a warning (Bicep:
# azd's own provisionParametersResolver already runs ARM preflight and prints
# a clean InsufficientQuota message + prompts to continue, so a hard fail
# here just blocks that better UX).
VARIANT="unknown"
if [ -f "./azure.yaml" ]; then
    if grep -qE '^[[:space:]]*provider:[[:space:]]*bicep' ./azure.yaml; then
        VARIANT="bicep"
    elif grep -qE '^[[:space:]]*provider:[[:space:]]*terraform' ./azure.yaml; then
        VARIANT="terraform"
    fi
fi

# --- 1. Required env vars ---------------------------------------------------
if [ -z "${CLAUDE_ORGANIZATION_NAME:-}" ]; then
    warn "CLAUDE_ORGANIZATION_NAME is not set. azd will prompt for the 'claudeOrganizationName' Bicep parameter at provision time. To skip the prompt: azd env set CLAUDE_ORGANIZATION_NAME 'Your Org'"
fi
if [ -z "${AZURE_LOCATION:-}" ]; then
    warn "AZURE_LOCATION is not set. azd will prompt at provision time. Skipping marketplace + quota validation (they need a region). To skip the prompt: azd env set AZURE_LOCATION swedencentral"
    exit 0
fi

LOCATION="$AZURE_LOCATION"

# Build the list of (family, model, capacity) tuples.
FAMILIES=()
MODELS=()
CAPACITIES=()

if [ -n "${CLAUDE_HAIKU_MODEL:-}" ]; then
    FAMILIES+=("haiku");  MODELS+=("$CLAUDE_HAIKU_MODEL");  CAPACITIES+=("${CLAUDE_HAIKU_CAPACITY:-50}")
fi
if [ -n "${CLAUDE_SONNET_MODEL:-}" ]; then
    FAMILIES+=("sonnet"); MODELS+=("$CLAUDE_SONNET_MODEL"); CAPACITIES+=("${CLAUDE_SONNET_CAPACITY:-50}")
fi
if [ -n "${CLAUDE_OPUS_MODEL:-}" ]; then
    FAMILIES+=("opus");   MODELS+=("$CLAUDE_OPUS_MODEL");   CAPACITIES+=("${CLAUDE_OPUS_CAPACITY:-50}")
fi

if [ "${#FAMILIES[@]}" -eq 0 ]; then
    FAMILIES+=("legacy")
    MODELS+=("${CLAUDE_MODEL_NAME:-claude-sonnet-4-6}")
    CAPACITIES+=("${CLAUDE_MODEL_CAPACITY:-50}")
fi

# --- 2. Azure CLI / active subscription ------------------------------------
# These checks are best-effort: if `az` is missing or the user hasn't run
# `az login`, we skip the marketplace + quota checks and let `azd up`
# continue. The RP will surface any errors at deploy time.
if ! command -v az >/dev/null 2>&1; then
    warn "Azure CLI (az) not found on PATH. Skipping marketplace + quota validation. Install az and run 'az login' for proactive checks: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 0
fi

SUB_ID="$(az account show --query id -o tsv 2>/dev/null || true)"
if [ -z "$SUB_ID" ]; then
    warn "Not signed in to Azure CLI. Skipping marketplace + quota validation. Run 'az login' (and 'az account set --subscription <id>' if needed) for proactive checks."
    exit 0
fi

SUMMARY=""
for i in "${!FAMILIES[@]}"; do
    SUMMARY="${SUMMARY}${SUMMARY:+, }${FAMILIES[$i]}=${MODELS[$i]}@${CAPACITIES[$i]}"
done
echo "Preflight: subscription $SUB_ID, location $LOCATION, deployments: $SUMMARY"

PUBLISHER="anthropic"

for i in "${!FAMILIES[@]}"; do
    FAMILY="${FAMILIES[$i]}"
    MODEL_NAME="${MODELS[$i]}"
    CAPACITY="${CAPACITIES[$i]}"

    # Anthropic publishes Claude as a fetch-style plan named '<offer>-plan-new'.
    OFFER="anthropic-$MODEL_NAME-offer"
    PLAN="anthropic-$MODEL_NAME-plan-new"
    MP_URL="https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.MarketplaceOrdering/offerTypes/virtualmachine/publishers/$PUBLISHER/offers/$OFFER/plans/$PLAN/agreements/current?api-version=2021-01-01"

    set +e
    MP_RAW="$(az rest --method get --url "$MP_URL" 2>&1)"
    MP_EXIT=$?
    set -e

    if [ "$MP_EXIT" -ne 0 ]; then
        if echo "$MP_RAW" | grep -qE "was not found|BadRequest"; then
            fail 4 "Marketplace offer 'anthropic/$OFFER/$PLAN' not found (family=$FAMILY).

Likely causes:
  - The model id '$MODEL_NAME' is misspelled.
  - The model isn't (yet) published in the Anthropic-on-Foundry catalog.
  - Anthropic changed the plan naming convention.

Available Anthropic agreements on this subscription:
  az rest --method get --url 'https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.MarketplaceOrdering/agreements?api-version=2021-01-01' --query \"value[?properties.publisher=='anthropic']\"

Underlying error:
$MP_RAW"
        fi
        echo "Preflight: Marketplace catalog query for '$MODEL_NAME' returned an unexpected error (continuing — RP will validate at deploy time):" >&2
        echo "  $MP_RAW" >&2
    else
        ACCEPTED="$(echo "$MP_RAW" | python -c 'import json, sys; print(json.load(sys.stdin)["properties"]["accepted"])' 2>/dev/null || true)"
        if [ "$ACCEPTED" != "True" ] && [ "$ACCEPTED" != "true" ]; then
            echo "Preflight: '$MODEL_NAME' marketplace agreement is currently unsigned. The Cognitive Services RP will auto-sign during deployment on eligible subs."
            echo "         If your subscription blocks RP-initiated subscribes, pre-accept manually:"
            echo "           az term accept --publisher $PUBLISHER --product $OFFER --plan $PLAN"
        else
            echo "Preflight: '$MODEL_NAME' marketplace agreement signed."
        fi
    fi

    # --- Quota headroom (HARD FAIL on insufficient) ------------------------
    SKU="AIServices.GlobalStandard.$MODEL_NAME"
    LIMIT="$(az cognitiveservices usage list --location "$LOCATION" --query "[?name.value=='$SKU'].limit | [0]" -o tsv 2>/dev/null || true)"
    CURRENT="$(az cognitiveservices usage list --location "$LOCATION" --query "[?name.value=='$SKU'].currentValue | [0]" -o tsv 2>/dev/null || true)"

    if [ -n "$LIMIT" ]; then
        LIMIT_INT="${LIMIT%%.*}"
        CURRENT_INT="${CURRENT%%.*}"
        CURRENT_INT="${CURRENT_INT:-0}"
        AVAILABLE=$(( LIMIT_INT - CURRENT_INT ))
        if [ "$AVAILABLE" -lt "$CAPACITY" ]; then
            FAMILY_UPPER="$(echo "$FAMILY" | tr '[:lower:]' '[:upper:]')"
            QUOTA_MSG="Insufficient quota for '$MODEL_NAME' (family=$FAMILY) in '$LOCATION'.

Requested capacity: $CAPACITY TPM (thousands)
Available:         $AVAILABLE TPM (limit $LIMIT_INT, currently used $CURRENT_INT)

Fix one of:
  - Lower the requested capacity:
      azd env set CLAUDE_${FAMILY_UPPER}_CAPACITY $AVAILABLE
    (or CLAUDE_MODEL_CAPACITY for legacy single-model mode)
  - Free up quota by deleting unused deployments:
      az cognitiveservices account deployment list --name <foundry> --resource-group <rg> -o table
      az cognitiveservices account deployment delete --name <foundry> --resource-group <rg> --deployment-name <name>
  - Request a quota increase in the Azure Foundry portal:
      Foundry portal -> Management center -> Quota -> select '$SKU' -> Request increase

Note: without this preflight, Terraform (azapi_resource) would fail with an
opaque '400 715-123420' error because azapi bypasses ARM preflight
validation. Bicep / 'az deployment group create' show the real
'InsufficientQuota' message because they go through ARM preflight."
            if [ "$VARIANT" = "bicep" ]; then
                # Bicep variant: azd's own ARM preflight will print the same
                # InsufficientQuota next and prompt to continue. Warn so the
                # diagnostic is up front, then let azd take over.
                printf '\nPreflight WARNING: %s\n(Continuing — azd'"'"'s Bicep ARM preflight will repeat this and prompt to continue.)\n\n' "$QUOTA_MSG" >&2
                continue
            fi
            fail 6 "$QUOTA_MSG"
        fi
        echo "Preflight: '$MODEL_NAME' quota OK ($CAPACITY requested, $AVAILABLE available of $LIMIT_INT in $LOCATION)."
    else
        echo "Preflight: no quota row visible for '$SKU' in '$LOCATION' yet — first deploy may surface a quota error from the RP." >&2
    fi
done

echo "Preflight OK."
