from __future__ import annotations

import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
INDUSTRIES = {
    "technology", "finance", "healthcare", "education", "retail",
    "manufacturing", "government", "media", "other",
}


class IndustryTemplateTests(unittest.TestCase):
    def test_azd_inputs_have_the_same_required_industry_mapping(self) -> None:
        bicep = json.loads(
            (ROOT / "infra-bicep" / "infra" / "main.parameters.json").read_text()
        )
        terraform = json.loads(
            (ROOT / "infra-terraform" / "infra" / "main.tfvars.json").read_text()
        )
        self.assertEqual(bicep["parameters"]["claudeIndustry"]["value"], "${INDUSTRY}")
        self.assertEqual(terraform["claude_industry"], "${INDUSTRY}")

    def test_required_industry_enums_match_in_bicep_and_terraform(self) -> None:
        for name in ("main.bicep", "foundry.bicep"):
            source = (ROOT / "infra-bicep" / "infra" / name).read_text(encoding="utf-8")
            allowed = re.search(
                r"@allowed\(\[([^\]]+)\]\)\s*param claudeIndustry string([^\n]*)",
                source,
            )
            self.assertIsNotNone(allowed, name)
            self.assertEqual(set(re.findall(r"'([^']+)'", allowed[1])), INDUSTRIES)
            self.assertNotIn("=", allowed[2], "Industry must not have a default")
        source = (ROOT / "infra-terraform" / "infra" / "variables.tf").read_text(
            encoding="utf-8"
        )
        industry = source.split('variable "claude_industry" {', 1)[1]
        self.assertNotRegex(industry, r"\bdefault\s*=")
        values = re.search(r"contains\(\[([^\]]+)\], var\.claude_industry\)", industry)
        self.assertIsNotNone(values)
        self.assertEqual(set(re.findall(r'"([^"]+)"', values[1])), INDUSTRIES)

    def test_all_deployments_retain_exact_attestation_properties(self) -> None:
        bicep = (ROOT / "infra-bicep" / "infra" / "foundry.bicep").read_text(
            encoding="utf-8"
        )
        terraform = (ROOT / "infra-terraform" / "infra" / "main.tf").read_text(
            encoding="utf-8"
        )
        self.assertEqual(len(re.findall(r"industry:\s*claudeIndustry\b", bicep)), 3)
        self.assertEqual(len(re.findall(r"industry\s*=\s*var\.claude_industry\b", terraform)), 3)
        self.assertEqual(bicep.count("modelProviderData: {"), 3)
        self.assertEqual(terraform.count("modelProviderData = {"), 3)

    def test_both_azd_variants_allow_the_preprovision_prompt(self) -> None:
        for variant in ("infra-bicep", "infra-terraform"):
            source = (ROOT / variant / "azure.yaml").read_text(encoding="utf-8")
            preprovision = source.split("  preprovision:", 1)[1].split(
                "  postprovision:", 1
            )[0]
            with self.subTest(variant=variant):
                self.assertEqual(preprovision.count("interactive: true"), 2)
                self.assertIn("../scripts/preflight-claude.ps1", preprovision)
                self.assertIn("../scripts/preflight-claude.sh", preprovision)

    def test_industry_is_collected_before_azd_resolves_required_parameters(self) -> None:
        for variant in ("infra-bicep", "infra-terraform"):
            source = (ROOT / variant / "azure.yaml").read_text(encoding="utf-8")
            preup = source.split("  preup:", 1)[1].split("  preprovision:", 1)[0]
            with self.subTest(variant=variant):
                self.assertEqual(preup.count("interactive: true"), 2)
                self.assertEqual(preup.count("-IndustryOnly"), 2)
                self.assertIn("preflight-claude.sh --industry-only", preup)


if __name__ == "__main__":
    unittest.main()
