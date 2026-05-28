# Support

## How to file issues and get help

This project uses [GitHub Issues](https://github.com/Azure-Samples/claude/issues) to track bugs and feature requests. Please search the existing issues before filing new ones to avoid duplicates. For new issues, file your bug or feature request as a new issue.

When filing an issue, please include:

- Which IaC variant you're using (`infra-bicep/` or `infra-terraform/`)
- Output of `azd version`, `az version`, and (for the Terraform variant) `terraform version`
- The relevant slice of `azd up` / `azd provision` output, with any subscription IDs or tenant IDs redacted
- For runtime issues: which sample script (`hello_claude.py`, `chat_stream.py`, etc.) and the full traceback

For help and questions about using this project, please **open a GitHub Issue** with the `question` label.

## Microsoft Support Policy

Support for this **sample** is limited to the resources listed above. This project is provided "as-is" under the [MIT License](LICENSE) and is **not** covered by a Microsoft Azure support contract or Service Level Agreement.

For issues with the underlying Azure services this sample uses (Azure AI Foundry, Cognitive Services, Marketplace) please follow the standard Azure support channels:

- [Azure support plans](https://azure.microsoft.com/support/plans/)
- [Azure AI Foundry documentation](https://learn.microsoft.com/azure/ai-foundry/)
- [Anthropic models on Foundry documentation](https://learn.microsoft.com/azure/ai-foundry/foundry-models/how-to/use-foundry-models-claude)
