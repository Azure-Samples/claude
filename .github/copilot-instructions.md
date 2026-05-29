# Repository instructions for Copilot (and other AI assistants)

> **Anyone with Copilot Chat (or another AI assistant that reads `.github/copilot-instructions.md` and `AGENTS.md`) clones this repo and instantly gets a guided experience.** Ask the assistant in plain English — *"help me deploy"*, *"my deployment failed"*, *"clean up and free quota"* — and it follows the conventions below plus the deep playbook in [`.github/skills/claude-on-foundry/SKILL.md`](./skills/claude-on-foundry/SKILL.md).

This is the **Claude on Foundry Starter Kit** ([`Azure-Samples/claude`](https://github.com/Azure-Samples/claude) · `aka.ms/claude/start`). It provisions a Microsoft Foundry account with Claude model deployments via `azd up`, and wires the Anthropic SDK + Claude Code CLI to it using Microsoft Entra ID (no API keys).

## Repo shape — never assume, always check

- **Two IaC variants ship side-by-side. The user picks ONE.** Never edit or run both.
  - Bicep: [`infra-bicep/`](../infra-bicep) — run `cd infra-bicep && azd up`
  - Terraform: [`infra-terraform/`](../infra-terraform) — run `cd infra-terraform && azd up`
- **Two hooks fire automatically during `azd up`** (defined in each variant's `azure.yaml`):
  - `preprovision` → [`scripts/preflight-claude.ps1`](../scripts/preflight-claude.ps1) / `.sh` — marketplace catalog + quota check, hard-fails early on missing offers or insufficient TPM.
  - `postprovision` → [`scripts/configure-claude-code.ps1`](../scripts/configure-claude-code.ps1) / `.sh` — writes activator files + `.vscode/settings.json` + `.claude/settings.json` so Claude Code and the SDK target the new Foundry deployment via Entra ID.
- **One canonical catalog tool:** [`./Get-ClaudeCatalog.ps1`](../Get-ClaudeCatalog.ps1). Zero-required-params. Run with `-Latest` for the newest generation per family.
- **One verifier:** [`scripts/verify-claude-code.ps1`](../scripts/verify-claude-code.ps1) — end-to-end smoke test (`-SkipClaudeCall` for config-only, `-RunPythonSample` for full SDK round trip).

## Env-var contract (the single source of truth)

| Var | Required | Default | Purpose |
|---|---|---|---|
| `CLAUDE_ORGANIZATION_NAME` | yes | — | Anthropic attestation (legal entity) |
| `CLAUDE_COUNTRY_CODE` | attest | `US` | Anthropic attestation (ISO-2) |
| `CLAUDE_INDUSTRY` | attest | `technology` | Anthropic attestation (**lowercase only**) |
| `AZURE_LOCATION` | yes | — | `eastus2` / `swedencentral` / `westus2` (opus+sonnet only) |
| `CLAUDE_HAIKU_MODEL` | no | empty | e.g. `claude-haiku-4-5`. Empty = skip family. |
| `CLAUDE_SONNET_MODEL` | no | empty | e.g. `claude-sonnet-4-6`. Empty = skip family. |
| `CLAUDE_OPUS_MODEL` | no | empty | e.g. `claude-opus-4-8`. Empty = skip family. |
| `CLAUDE_HAIKU_CAPACITY` / `CLAUDE_SONNET_CAPACITY` / `CLAUDE_OPUS_CAPACITY` | no | `25` | TPM ÷ 1000 per family |
| `CLAUDE_MODEL_NAME` | no | `claude-sonnet-4-6` | **Legacy** single-deployment fallback (only used when all three `CLAUDE_*_MODEL` are empty) |
| `ASSIGN_RBAC` | no | `false` | `true` grants Foundry User + Foundry Project Manager to `AZURE_PRINCIPAL_ID` |
| `CLAUDE_CODE_AUTO_INSTALL` | no | `false` | `true` installs the Claude Code CLI in the postprovision hook |

Always set vars with `azd env set <VAR> <VALUE>` from inside the chosen variant folder.

## How to help the user (in priority order)

1. **Load the skill.** For any non-trivial Claude-on-Foundry task, read [`.github/skills/claude-on-foundry/SKILL.md`](./skills/claude-on-foundry/SKILL.md) first — it has the full DEPLOY / DIAGNOSE / MODIFY / VERIFY / TEARDOWN playbook.
2. **Diagnose, don't guess.** When a deployment fails, identify the exact error fingerprint (e.g. `715-123420`, `InsufficientQuota`, `AnthropicOrganizationCreationException`, `403 Forbidden`, `401 PermissionDenied`) and follow the matching entry in the skill's DIAGNOSE table.
3. **Run the existing scripts.** Do not invent ad-hoc `az` commands when [`Get-ClaudeCatalog.ps1`](../Get-ClaudeCatalog.ps1), [`preflight-claude.ps1`](../scripts/preflight-claude.ps1), [`configure-claude-code.ps1`](../scripts/configure-claude-code.ps1), [`verify-claude-code.ps1`](../scripts/verify-claude-code.ps1), or [`src/check_claude_quota.py`](../src/check_claude_quota.py) already cover the case.
4. **Confirm before destructive actions.** Always get explicit user OK before: `az cognitiveservices account purge`, `azd down`, `az role assignment delete`, deleting `.azure-cli/`, editing `~/.claude/settings.json`.

## Hard rules

- **Never write `CLAUDE_API_KEY` or any token / subscription / tenant ID into a tracked file.** All real values live in env vars, the gitignored `.env.local`, or the gitignored `.azure-cli/` token cache.
- **Never bypass the preflight** (e.g. by passing `--no-prompt` to skip hooks). It catches the two most common failure modes (offer-not-found, quota exhaustion) before they become opaque RP errors.
- **Never mix the Bicep and Terraform variants in one environment.** Each variant uses its own `azd env`. If the user wants to switch, run `azd env new <name>` in the other folder.
- **Don't suggest disabling RBAC propagation retries.** An intermittent `401 PermissionDenied` immediately after `azd up` with `ASSIGN_RBAC=true` is normal — wait 1-3 minutes.
- **Honor the user's region.** `eastus2` and `swedencentral` host all three families; `westus2` is sonnet + opus only. Don't silently change `AZURE_LOCATION`.

## Style

- Be concise. Reference doc sections by link rather than reproducing them.
- When proposing a command, explain the *one* thing it does and why, then run it.
- Surface the exact error string the user is seeing in your answer — it's the strongest signal for the troubleshooting table.
