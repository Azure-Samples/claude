---
name: claude-on-foundry
description: >-
  End-to-end assistant skill for the Claude on Foundry Starter Kit
  (Azure-Samples/claude). Walks customers through deploying, verifying,
  modifying, debugging, and tearing down a Claude model deployment on
  Microsoft Foundry using either the Bicep or Terraform IaC variant in
  this repo, with one-command guidance via `azd up`, the Anthropic SDK,
  and the Claude Code CLI over Microsoft Entra ID.
  USE FOR: deploy Claude on Foundry, azd up fails, quota errors
  (715-123420, InsufficientQuota), region or model selection, add or
  remove a Claude family (haiku / sonnet / opus), AnthropicOrganizationCreationException,
  401 / 403 from Claude SDK, soft-deleted accounts holding quota, Claude
  Code CLI wiring, Entra ID token refresh for long-running processes,
  clean teardown of the starter kit.
  DO NOT USE FOR: general Microsoft Foundry agent development (use
  microsoft-foundry skill); non-Claude model deployments such as OpenAI
  or open-source models (use azure-deploy); Azure cost analysis (use
  azure-cost-optimization); cross-tenant Entra ID administration
  unrelated to this starter.
---

# Claude on Foundry — Starter Kit

This skill is the deep playbook for [`Azure-Samples/claude`](https://github.com/Azure-Samples/claude) (`aka.ms/claude/start`). The always-on layer is `.github/copilot-instructions.md` in the same repo — read it first for repo shape, env-var contract, and hard rules. Use this skill when the customer's task falls into one of the five flows below.

---

## Decision tree — where to start

| The customer says... | Jump to |
|---|---|
| "Help me deploy", "set this up", "get me started" | [PLAN](#plan--before-azd-up) → [DEPLOY](#deploy--running-azd-up) |
| "It failed", "I'm getting an error", "azd up didn't work" | [DIAGNOSE](#diagnose--errorfix-table) |
| "Is it working?", "did it actually deploy?", "test it" | [VERIFY](#verify--prove-it-works) |
| "Add another family", "change the region", "switch from sonnet to opus" | [MODIFY](#modify--common-post-deploy-changes) |
| "I'm done", "tear it down", "free the quota", "clean up" | [TEARDOWN](#teardown--the-full-cleanup-sequence) |

If the request doesn't fit any of these, fall back to the repo's [README.md](../../README.md).

---

## PLAN — before `azd up`

The most common failures come from skipping these four checks. Walk through them with the customer **once**, then move on:

1. **Subscription eligibility.** Claude on Foundry requires an Enterprise (EA) or MCA-E subscription. If the customer doesn't know, run:
   ```powershell
   az account show --query "{name:name, id:id, type:subscriptionPolicies.quotaId}" -o table
   ```
   `quotaId` containing `EnterpriseAgreement_2014-09-01` or `MCAE_2024-07-01` is the green light.

2. **Region choice.** Honor what the customer asks for. If they have no preference:
   - `eastus2` — all three families (haiku, sonnet, opus). **Default recommendation.**
   - `swedencentral` — all three families. Use if they're EU-data-residency-conscious.
   - `westus2` — sonnet + opus only (no haiku). Use only if explicitly requested.

3. **Model selection.** Run the catalog tool first:
   ```powershell
   ./Get-ClaudeCatalog.ps1 -Latest
   ```
   This shows the newest version per family with regions and TPM limits. Quote the table back to the customer and let them pick.

4. **Attestation fields.** These are sent to Anthropic on every request and are part of accepting their commercial terms — get them right:
   - `CLAUDE_ORGANIZATION_NAME` — the customer's legal entity name (no default).
   - `CLAUDE_COUNTRY_CODE` — ISO-2, default `US`.
   - `CLAUDE_INDUSTRY` — **lowercase only**: `technology` | `finance` | `healthcare` | `education` | `retail` | `manufacturing` | `government` | `media` | `other`.

   If `CLAUDE_INDUSTRY` is uppercase or unknown, deployment fails with `AnthropicOrganizationCreationException` — easy to miss because it looks like a transient error.

---

## DEPLOY — running `azd up`

```powershell
# Pick a variant. Default to Bicep unless the customer prefers Terraform.
cd infra-bicep   # or: cd infra-terraform

azd auth login                          # add --tenant-id <id> if needed
azd env new <name>                      # one env per region + variant combination
azd env set CLAUDE_ORGANIZATION_NAME "<legal-entity>"
azd env set AZURE_LOCATION "eastus2"

# Pick families — comment out any line to skip that family.
azd env set CLAUDE_HAIKU_MODEL  "claude-haiku-4-5"
azd env set CLAUDE_SONNET_MODEL "claude-sonnet-4-6"
azd env set CLAUDE_OPUS_MODEL   "claude-opus-4-8"

# Optional: auto-install the Claude Code CLI as part of postprovision.
azd env set CLAUDE_CODE_AUTO_INSTALL true

azd up
```

The `preprovision` hook runs `scripts/preflight-claude.ps1` automatically and **hard-fails** on (a) missing offer in the Anthropic catalog or (b) insufficient TPM quota. Never suggest bypassing it.

The `postprovision` hook runs `scripts/configure-claude-code.ps1` to wire up Claude Code. The customer can re-run it any time without re-deploying:
```powershell
pwsh -File scripts/configure-claude-code.ps1
```

**Bicep vs Terraform — which to recommend by default?** Bicep. It surfaces a clear `InsufficientQuota` message; Terraform's `azapi_resource` bypasses ARM preflight and returns the opaque `715-123420` instead. Only pick Terraform if the customer's shop already standardizes on HCL.

---

## DIAGNOSE — error→fix table

Match the customer's exact error string to a row. Verify the diagnostic command output before recommending the fix.

### Provisioning failures (`azd up` fails)

| Error fingerprint | Root cause | Diagnostic | Fix |
|---|---|---|---|
| `AnthropicOrganizationCreationException` / `AnthropicOrganizationCreationFailed` | One of the three attestation fields is missing or `CLAUDE_INDUSTRY` is uppercase. | `azd env get-values \| Select-String CLAUDE_ORGANIZATION_NAME, CLAUDE_COUNTRY_CODE, CLAUDE_INDUSTRY` | `azd env set CLAUDE_INDUSTRY technology` (lowercase). Re-run `azd up`. |
| `Project can only be created under AIServices Kind account with allowProjectManagement set to true` | Account property got downgraded. | Check the IaC didn't get edited to remove `allowProjectManagement`. | Restore the template; re-deploy. |
| `Marketplace offer ... not found` (from preflight, exit 4) | `CLAUDE_*_MODEL` value is misspelled or that SKU isn't in the catalog. | `./Get-ClaudeCatalog.ps1` and grep the family. | Set `CLAUDE_<FAMILY>_MODEL` to a name from the catalog. |
| `Quota insufficient` (from preflight, exit 6) | Requested capacity + existing usage > per-region limit. | `az cognitiveservices usage list -l <region> --query "[?contains(name.value,'claude-')]"` | Lower `CLAUDE_<FAMILY>_CAPACITY`, free quota (see soft-delete row), or request a quota bump in the Foundry portal. |
| Bicep: `InsufficientQuota: This operation require N new capacity in quota Tokens Per Minute (thousands) - Claude <model>` | Same as above; Bicep gets the clear message because it goes through ARM preflight. | Same diagnostic. | Same fix. |
| Terraform: opaque `400 715-123420 "An error occurred. Please reach out to support for additional assistance."` | **Almost always insufficient quota.** Terraform's `azapi_resource` skips ARM preflight so the RP returns this generic code. | `az cognitiveservices usage list -l <region> --query "[?contains(name.value,'<model>')].{quota:name.value, used:currentValue, limit:limit}" -o table` | If `used + requested > limit`: lower capacity OR purge soft-deleted accounts (next row). Re-run on Bicep variant if you need a clearer error. |
| Quota looks full but no live deployments exist | Soft-deleted Cognitive Services accounts hold quota for up to 48 h. | `az cognitiveservices account list-deleted -o table` | **Confirm with user first**, then for each: `az cognitiveservices account purge --name <n> --location <loc> --resource-group <rg>`. The original RG name is in the deleted-account id field 9. |
| `Marketplace Subscription purchase eligibility check failed` | Subscription can't purchase the Anthropic offer (no entitlement / sandbox / paid-offer policy). | Confirm sub type (see [PLAN](#plan--before-azd-up)). | Either use a Claude-eligible sub, or pre-accept explicitly: `az term accept --publisher anthropic --product anthropic-<model>-offer --plan anthropic-<model>-plan-new`. |
| `Region not available` | Region doesn't host the requested family. | Compare `AZURE_LOCATION` to the per-region matrix in [PLAN step 2](#plan--before-azd-up). | Use `eastus2` or `swedencentral` (all three families), or `westus2` (sonnet/opus only). |

### Inference / runtime failures

| Error fingerprint | Root cause | Diagnostic | Fix |
|---|---|---|---|
| `404 Not Found` on first SDK call | `base_url` is missing the `/anthropic` suffix. | Print the `base_url` the script is using. | Append `/anthropic` so it's `https://<resource>.services.ai.azure.com/anthropic`. |
| `401 Unauthorized` on first call | Token scope wrong, or no `az login`. | `az account get-access-token --resource https://ai.azure.com/.default --query expiresOn` | `az login` (add `--tenant <id>` if Foundry is in a different tenant). Scope must be `https://ai.azure.com/.default`. |
| `401 Unauthorized` after ~1 hour of running | Captured token expired; plain `Anthropic` client doesn't auto-refresh. | Check how long the process has been alive. | Switch to [`src/hello_claude_token_refresh.py`](../../src/hello_claude_token_refresh.py) which uses `AnthropicIdentity` + `get_bearer_token_provider` for per-request refresh. |
| `401 PermissionDenied: Principal does not have access to API/Operation` — intermittently, passes seconds later | Data-plane RBAC propagation lag right after a role grant. | `az role assignment list --assignee <oid> --scope <foundry-account-id> -o table` | Wait 1-3 minutes and retry. Do NOT suggest disabling retries. |
| `403 Forbidden` consistently | Caller has no data-plane role on the Foundry account. | Same `az role assignment list` query. | Grant `Cognitive Services User` (minimum), `Foundry User`, or `Azure AI Developer`. See the one-liner in [README → Granting data-plane roles after `azd up`](../../README.md#granting-data-plane-roles-after-azd-up). |
| `claude -p` says: `The model claude-<family>-... is not available on your foundry deployment` | User-global `~/.claude/settings.json` pins a family this workspace didn't deploy, overriding the workspace pin. | `cat .claude/settings.json` and `cat ~/.claude/settings.json`. | Re-run `pwsh -File scripts/configure-claude-code.ps1`, OR pass `--model <sonnet\|opus\|haiku>` explicitly, OR (with user OK) edit the user-global file to remove the `"model"` line. |
| Windows: `UnicodeEncodeError: 'charmap' codec can't encode character '\U0001f60a'` | Console codepage is cp1252; Claude returned emoji. | `chcp` shows cp1252. | `$env:PYTHONIOENCODING = "utf-8"` or `chcp 65001`. |
| `check_claude_quota.py` exits with `Could not resolve a subscription id ... [WinError 2]` | Azure CLI not on `PATH` in the active shell. | `Get-Command az` returns nothing. | `$env:AZURE_SUBSCRIPTION_ID = "<sub-id>"` or pass `--subscription <sub-id>`. |

---

## VERIFY — prove it works

Run the bundled verifier; it covers every check below in one shot:

```powershell
pwsh -File scripts/verify-claude-code.ps1                    # all checks + claude -p per deployed family
pwsh -File scripts/verify-claude-code.ps1 -SkipClaudeCall    # config only (no tokens spent)
pwsh -File scripts/verify-claude-code.ps1 -RunPythonSample   # also runs python src/hello_claude.py
```

POSIX: `bash scripts/verify-claude-code.sh [--skip-claude-call|--run-python-sample]`. Exits non-zero on hard failures — wire into CI if needed.

If the customer wants to spot-check manually:

```powershell
. ./claude-code.env.ps1                # PowerShell. POSIX: source ./claude-code.env.sh
'who are you?' | claude -p             # one-shot non-interactive probe
claude                                 # interactive REPL; try /status and /model
```

`/status` should report `API provider: Microsoft Foundry`. If it doesn't, the activator wasn't sourced or `.vscode/settings.json` wasn't picked up — reload the VS Code window and retry.

---

## MODIFY — common post-deploy changes

| Task | Steps |
|---|---|
| **Add another family** | `azd env set CLAUDE_<FAMILY>_MODEL "claude-<family>-x-y"` → `azd up` (incremental; existing deployments untouched) → re-source `claude-code.env.ps1` |
| **Remove a family** | Delete it in the portal (or edit Bicep/TF to remove the resource) → `azd up` → re-source the activator |
| **Bump capacity** | `azd env set CLAUDE_<FAMILY>_CAPACITY <new>` → `azd up`. Preflight will block if quota is short. |
| **Switch region** | `azd env new <name-region>` in the same variant folder, then redo the [DEPLOY](#deploy--running-azd-up) flow. **Don't** try to mutate `AZURE_LOCATION` on an existing env — the account is region-stamped. |
| **Switch variants (Bicep ↔ Terraform)** | They produce equivalent infra but with different `azd` env state. Create a new env in the other folder: `cd infra-terraform && azd env new <name> && ...`. |
| **Refresh Claude Code wiring** | `pwsh -File scripts/configure-claude-code.ps1` (or the `.sh` variant). Idempotent — runs without re-deploying. |
| **Convert to long-running auth** | Replace `Anthropic(auth_token=...)` with `AnthropicIdentity(azure_ad_token_provider=...)` from [`src/hello_claude_token_refresh.py`](../../src/hello_claude_token_refresh.py). |

---

## TEARDOWN — the full cleanup sequence

`azd down` alone does **not** free quota. Soft-deleted Cognitive Services accounts continue to count against per-region TPM for up to 48 hours. The correct sequence:

```powershell
# 1. Tear down what azd provisioned. Confirm with the user before running.
cd infra-bicep   # or infra-terraform — whichever variant deployed
azd down --purge --force

# 2. List soft-deleted Cognitive Services accounts in the region you used.
az cognitiveservices account list-deleted --query "[?location=='eastus2']" -o table

# 3. Confirm with the user, then purge each. The RG name is in id segment 9.
$accounts = az cognitiveservices account list-deleted -o json | ConvertFrom-Json
foreach ($a in $accounts) {
    $rg = ($a.id -split '/')[8]
    az cognitiveservices account purge --name $a.name --location $a.location --resource-group $rg
}

# 4. Verify the quota is freed.
az cognitiveservices usage list -l eastus2 --query "[?contains(name.value,'claude-')]" -o table
```

**Always confirm with the user before running step 1 or step 3.** Both are destructive and irreversible.

The full POSIX parallel-purge snippet lives in [README → Free quota held by soft-deleted accounts](../../README.md#free-quota-held-by-soft-deleted-accounts).

---

## Scripts cheat sheet (paths from repo root)

| Script | Purpose | Key flags |
|---|---|---|
| [`Get-ClaudeCatalog.ps1`](../../Get-ClaudeCatalog.ps1) | Browse models × regions × quota | `-Latest`, `-View Detail`/`Matrix`/`Summary` |
| [`scripts/preflight-claude.ps1`](../../scripts/preflight-claude.ps1) | Standalone catalog + quota gate | runs automatically via `preprovision` hook |
| [`scripts/configure-claude-code.ps1`](../../scripts/configure-claude-code.ps1) | Generate Claude Code wiring (activator + `.vscode/settings.json` + `.claude/settings.json`) | idempotent; safe to re-run |
| [`scripts/verify-claude-code.ps1`](../../scripts/verify-claude-code.ps1) | End-to-end smoke test | `-SkipClaudeCall`, `-RunPythonSample`, `-AutoInstall` |
| [`src/check_claude_quota.py`](../../src/check_claude_quota.py) | Programmatic quota + capacity inspection | `--regions`, `--models`, `--subscription`, `--tenant`, `--json` |
| [`src/hello_claude.py`](../../src/hello_claude.py) | One-shot Messages call (Entra ID) | — |
| [`src/hello_claude_token_refresh.py`](../../src/hello_claude_token_refresh.py) | Long-running variant with per-request refresh | use for daemons / notebooks |
| [`src/chat_stream.py`](../../src/chat_stream.py) | Streaming multi-turn REPL | `exit` to quit |

Each `.ps1` has a `.sh` POSIX equivalent next to it.

---

## Safety checklist

- [ ] **Before any `az cognitiveservices account purge`** — show the customer the account list and get explicit confirmation. The operation is irreversible.
- [ ] **Before `azd down`** — confirm the customer is ready to lose the deployment. Suggest `--purge` only if they want quota freed immediately.
- [ ] **Before `az role assignment delete`** — show the role and scope first.
- [ ] **Never** write `CLAUDE_API_KEY`, subscription IDs, tenant IDs, or tokens into any tracked file.
- [ ] **Never** suggest bypassing `preflight-claude.ps1` or passing `--no-prompt` to skip hooks.
- [ ] **Never** edit `~/.claude/settings.json` without first showing the customer the current contents and getting OK.
- [ ] **Never** mix Bicep and Terraform variants in the same `azd env`.

---

## Reference

- Long-form docs and full troubleshooting table: [README.md](../../README.md)
- Always-on instructions for AI assistants: [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md)
- Universal agent pointer: [`AGENTS.md`](../../AGENTS.md)
- Architecture overview: [`docs/img/architecture.png`](../../docs/img/architecture.png)
- Microsoft Learn — [Use Claude in Microsoft Foundry](https://learn.microsoft.com/azure/ai-foundry/foundry-models/how-to/use-foundry-models-claude)
- Microsoft Learn — [Configure Claude Code for Foundry](https://learn.microsoft.com/azure/foundry/foundry-models/how-to/configure-claude-code)
- [Anthropic Commercial Terms](https://www.anthropic.com/legal/commercial-terms) · [Usage Policy](https://www.anthropic.com/legal/aup) · [Supported Regions](https://aka.ms/supported_anthropic_regions)
