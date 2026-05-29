# AGENTS.md — Claude on Foundry Starter Kit

Guidance for AI coding agents (Claude Code, OpenAI Codex, Cursor, Gemini CLI, Amp, Goose, and others) working in this repository. GitHub Copilot reads [`.github/copilot-instructions.md`](./.github/copilot-instructions.md) natively; this file is the universal pointer for everyone else.

This repo deploys one or more **Claude** models (haiku, sonnet, opus) into a **Microsoft Foundry** account with a single command (azd up), then wires the Anthropic SDK and the Claude Code CLI to it over **Microsoft Entra ID** (no API keys). Bicep and Terraform variants ship side by side.

Short link: <https://aka.ms/claude/start>

## Start here

For any deploy, verify, modify, debug, or teardown request, follow the full playbook in **[`skills/claude-on-foundry/SKILL.md`](skills/claude-on-foundry/SKILL.md)**. It contains the decision tree, env-var contract, region matrix, error catalog, and destructive-action policy.

The always-on rules below are the same ones in [`.github/copilot-instructions.md`](.github/copilot-instructions.md), restated here so non-Copilot agents have them inline.

## Non-negotiable rules

- **Two IaC variants ship side by side. The user picks ONE.** Never edit or run both in the same `azd env`.
  - Bicep: [`infra-bicep/`](./infra-bicep/) — run `cd infra-bicep && azd up`
  - Terraform: [`infra-terraform/`](./infra-terraform/) — run `cd infra-terraform && azd up`
- **Single entrypoint:** `azd up` from inside the chosen variant folder. Two hooks fire automatically:
  - `preprovision` runs [`scripts/preflight-claude.ps1`](./scripts/preflight-claude.ps1) (catalog + quota gate). Never bypass it.
  - `postprovision` runs [`scripts/configure-claude-code.ps1`](./scripts/configure-claude-code.ps1) to wire Claude Code + the SDK to the new deployment.
- **Configure via `azd env set <KEY> <VALUE>`** from inside the chosen variant folder. There is no `.env` file. See the env-var contract in [`.github/copilot-instructions.md`](.github/copilot-instructions.md).
- **`CLAUDE_INDUSTRY` must be lowercase**: `technology`, `finance`, `healthcare`, `education`, `retail`, `manufacturing`, `government`, `media`, `other`. Uppercase fails with `AnthropicOrganizationCreationException`.
- **Honor the user's region.** `eastus2` and `swedencentral` host all three families; `westus2` is sonnet + opus only. Don't silently change `AZURE_LOCATION`.
- **Passwordless only.** Microsoft Entra ID via `DefaultAzureCredential` / `az login`. Never write `CLAUDE_API_KEY`, subscription IDs, tenant IDs, or tokens into any tracked file. Real values live in env vars, the gitignored `.env.local`, or the gitignored `.azure-cli/` token cache.
- **Confirm before destructive actions.** Always get explicit user OK before: `azd down`, `az cognitiveservices account purge`, `az role assignment delete`, deleting `.azure-cli/`, editing `~/.claude/settings.json`. Never pass `--no-prompt` to skip hooks.
- **Diagnose, don't guess.** When a deployment fails, identify the exact error fingerprint (`715-123420`, `InsufficientQuota`, `AnthropicOrganizationCreationException`, `403 Forbidden`, `401 PermissionDenied`) and follow the matching row in the skill's DIAGNOSE table.
- **Run the existing scripts.** Don't invent ad-hoc `az` commands when [`Get-ClaudeCatalog.ps1`](./Get-ClaudeCatalog.ps1), [`scripts/preflight-claude.ps1`](./scripts/preflight-claude.ps1), [`scripts/configure-claude-code.ps1`](./scripts/configure-claude-code.ps1), [`scripts/verify-claude-code.ps1`](./scripts/verify-claude-code.ps1), or [`src/check_claude_quota.py`](./src/check_claude_quota.py) already cover the case.

## Verify

After a deploy, run [`scripts/verify-claude-code.ps1`](./scripts/verify-claude-code.ps1) (or `scripts/verify-claude-code.sh`). It checks the activator, env vars, `.vscode/settings.json`, `az` login + tenant, `claude` on PATH, then does a `claude -p` round trip per deployed family. Exits non-zero on hard failures.

## Reference

- Full README: [README.md](./README.md)
- Skill body: [`skills/claude-on-foundry/SKILL.md`](skills/claude-on-foundry/SKILL.md)
- Agent Skills manifest: [`.github/agents/claude-on-foundry.agent.md`](.github/agents/claude-on-foundry.agent.md)
- Copilot always-on rules: [`.github/copilot-instructions.md`](.github/copilot-instructions.md)
