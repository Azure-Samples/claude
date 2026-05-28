# Contributing

This project welcomes contributions and suggestions. Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit <https://cla.opensource.microsoft.com>.

When you submit a pull request, a CLA bot will automatically determine whether you need to provide
a CLA and decorate the PR appropriately (e.g., status check, comment). Simply follow the
instructions provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## Before opening a pull request

1. **Open an issue first** if your change is non-trivial (anything beyond typo fixes or doc tweaks). This avoids duplicated work and gives maintainers a chance to discuss the approach.
2. **Keep PRs focused.** One logical change per PR — easier to review, easier to revert.
3. **Update both IaC variants when relevant.** If you change a default in `infra-bicep/`, mirror it in `infra-terraform/` (and vice versa). The README's [Parity matrix](README.md) lists the variants.
4. **Test end-to-end on a fresh `azd env`** before pushing — `azd up --no-prompt` should succeed against a fresh subscription/resource group.
5. **No secrets in commits.** Subscription IDs, tenant IDs, object IDs, API keys, and JWTs must stay in gitignored files (`.env.local`, `.azure-cli/`, `claude-code.env.*`, `.vscode/settings.json`, `infra-*/.azure/`).
6. **Mention the issue number** in the PR description (`Fixes #N` or `Refs #N`).

## Local development quick reference

```pwsh
git clone https://github.com/Azure-Samples/claude.git
cd claude
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt

# Bicep variant
azd up --cwd infra-bicep

# Terraform variant
azd up --cwd infra-terraform
```

See the main [README](README.md) for the full walkthrough, prerequisites, and configuration options.

## Trademark notice

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft
trademarks or logos is subject to and must follow [Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship.
Any use of third-party trademarks or logos are subject to those third-party's policies.
