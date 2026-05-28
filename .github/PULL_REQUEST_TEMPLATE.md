<!-- Thanks for opening a PR! Please fill out the sections below. -->

## What

<!-- One-line summary of the change. -->

## Why

<!-- Link an issue (e.g., `Fixes #123`) or explain the motivation. -->

## How

<!-- Brief description of the approach. Skip if obvious from the diff. -->

## Verification

<!-- How was this tested? At minimum, mention which IaC variant(s) and sub. -->

- [ ] `azd up` succeeded end-to-end on a fresh env (Bicep)
- [ ] `azd up` succeeded end-to-end on a fresh env (Terraform)
- [ ] `python src/hello_claude.py` returned a live model response
- [ ] N/A — docs-only / CI-only change

## Checklist

- [ ] Mirrored the change across **both** `infra-bicep/` and `infra-terraform/` (if applicable)
- [ ] No secrets / subscription IDs / tenant IDs / object IDs in commits, comments, or PR body
- [ ] README updated if user-facing behavior changed
- [ ] Conventional one logical change per PR
