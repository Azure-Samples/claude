from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PWSH = shutil.which("pwsh")
BASH = (
    r"C:\Program Files\Git\bin\bash.exe"
    if os.name == "nt" and Path(r"C:\Program Files\Git\bin\bash.exe").is_file()
    else shutil.which("bash")
)


@unittest.skipUnless(PWSH, "PowerShell 7 is required for catalog and preflight tests")
class CatalogTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        fake_cli = self.work / "fake_az.py"
        fake_cli.write_text(
            """
import json
import os
import sys

args = sys.argv[1:]
if args[:3] == ["env", "set", "INDUSTRY"]:
    if os.environ.get("CLAUDE_TEST_SAVE_FAIL"):
        print("Fixture azd env save failed", file=sys.stderr)
        sys.exit(1)
    with open("industry-saves.jsonl", "a", encoding="utf-8") as saved:
        saved.write(json.dumps(args[3:]) + "\\n")
elif args[:2] == ["account", "show"]:
    print(json.dumps({"tenantId": "example-tenant", "name": "Example", "id": "example-sub"}))
elif args[:3] == ["cognitiveservices", "model", "list"]:
    names = [
        "claude-opus-4-8", "claude-opus-5", "claude-opus-5-5", "claude-opus-5-5-fast",
        "claude-sonnet-4-6", "claude-sonnet-5-5", "claude-haiku-4-5", "claude-haiku-5-5",
    ]
    models = [
        {"kind": "AIServices", "model": {
            "format": "Anthropic", "name": name, "version": "2",
            "lifecycleStatus": "GenerallyAvailable", "isDefaultVersion": True,
            "skus": [{"name": "GlobalStandard", "capacity": {"default": 25, "maximum": 100},
                      "rateLimits": [{"key": "request", "count": 1}, {"key": "token", "count": 1000}]}],
        }}
        for name in names
        if not (os.environ.get("CLAUDE_TEST_MISSING_MODEL") and name == "claude-sonnet-5-5")
    ]
    if "--query" in args:
        query = args[args.index("--query") + 1]
        wanted = query.split("model.name=='", 1)[1].split("'", 1)[0]
        if os.environ.get("CLAUDE_TEST_INVALID_COUNT"):
            print("WARNING: fixture diagnostic")
        print(sum(item["model"]["name"] == wanted for item in models))
    else:
        print(json.dumps(models))
elif args[:2] == ["rest", "--method"]:
    url = args[args.index("--url") + 1]
    if "catalogapi.azure.com/offers/anthropic.claude-" in url:
        if "--skip-authorization-header" not in args or os.environ.get("CLAUDE_TEST_MISSING_OFFER"):
            print("Not Found(The product does not exist)", file=sys.stderr)
            sys.exit(1)
        print(json.dumps({"id": "sample-public-offer"}))
    elif "-5-5" in url:
        print("Marketplace offer was not found", file=sys.stderr)
        sys.exit(1)
    else:
        print(json.dumps({"properties": {"accepted": True}}))
elif args[:3] == ["cognitiveservices", "usage", "list"]:
    query = args[args.index("--query") + 1]
    print(os.environ.get("CLAUDE_TEST_LIMIT", "25") if ".limit" in query else "0")
else:
    print("Unexpected fake az invocation", file=sys.stderr)
    sys.exit(2)
""",
            encoding="utf-8",
        )
        if os.name == "nt":
            for name in ("az", "azd"):
                (self.work / f"{name}.cmd").write_text(
                    f'@echo off\n"{sys.executable}" "{fake_cli}" %*\n', encoding="utf-8"
                )
        for name in ("az", "azd"):
            wrapper = self.work / name
            wrapper.write_text(
                f'#!/bin/sh\nexec "{Path(sys.executable).as_posix()}" "{fake_cli.as_posix()}" "$@"\n',
                encoding="utf-8",
            )
            wrapper.chmod(0o755)
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("CLAUDE_", "ANTHROPIC_", "AZURE_"))
            and key != "INDUSTRY"
        }
        self.env["INDUSTRY"] = "technology"
        self.env["PATH"] = str(self.work) + os.pathsep + self.env["PATH"]

    def _run(self, command: str) -> subprocess.CompletedProcess[str]:
        fake_http = """
function Invoke-RestMethod {
    [CmdletBinding()]
    param([string]$Uri, [int]$TimeoutSec)
    if ($Uri -notlike 'https://catalogapi.azure.com/offers/anthropic.claude-*-5-5-offer?*' -or $env:CLAUDE_TEST_MISSING_OFFER) {
        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
        throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Marketplace offer not found', $response)
    }
    [pscustomobject]@{ id = 'sample-public-offer' }
}
"""
        if "CLAUDE_TEST_INDUSTRY_CHOICE" in self.env:
            fake_http += """
function Read-Host {
    param([string]$Prompt)
    Write-Host 'INDUSTRY_PROMPT'
    return $env:CLAUDE_TEST_INDUSTRY_CHOICE
}
"""
        return subprocess.run(
            [PWSH, "-NoProfile", "-NonInteractive", "-Command", fake_http + command],
            env=self.env, cwd=self.work, capture_output=True, text=True,
            encoding="utf-8", timeout=90,
        )

    def test_latest_includes_each_55_family_and_fast_opus(self) -> None:
        script = str(ROOT / "Get-ClaudeCatalog.ps1").replace("'", "''")
        result = self._run(
            f"$rows = & '{script}' -Latest -OutputFormat Object; "
            "'CATALOG_JSON=' + (ConvertTo-Json -InputObject @($rows) -Compress)"
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        rows = json.loads(result.stdout.split("CATALOG_JSON=", 1)[1])
        self.assertEqual(
            {row["Model"] for row in rows},
            {"claude-opus-5-5", "claude-opus-5-5-fast", "claude-sonnet-5-5", "claude-haiku-5-5"},
        )
        for row in rows:
            self.assertEqual(row["Version"], "2")
            self.assertEqual(row["Lifecycle"], "GenerallyAvailable")
            self.assertEqual(row["Context"], "1M")
            self.assertEqual(row["MaxOutput"], "128K")
            self.assertEqual(row["Capacity"], 25)

    def _preflight(
        self, variant: str, limit: int, model: str = "claude-sonnet-5-5"
    ) -> subprocess.CompletedProcess[str]:
        (self.work / "azure.yaml").write_text(
            f"name: sample\ninfra:\n  provider: {variant}\n", encoding="utf-8"
        )
        self.env.update({
            "CLAUDE_ORGANIZATION_NAME": "Contoso",
            "AZURE_LOCATION": "eastus2",
            f"CLAUDE_{model.split('-')[1].upper()}_MODEL": model,
            "CLAUDE_TEST_LIMIT": str(limit),
        })
        script = str(ROOT / "scripts" / "preflight-claude.ps1").replace("'", "''")
        return self._run(f"& '{script}'; exit $LASTEXITCODE")

    def test_preflight_default_capacity_matches_25_unit_templates(self) -> None:
        result = self._preflight("terraform", 25)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("sonnet=claude-sonnet-5-5@25", result.stdout)
        self.assertIn("Marketplace offer 'claude-sonnet-5-5-offer' verified", result.stdout)

    def test_preflight_blocks_a_missing_public_55_offer(self) -> None:
        self.env["CLAUDE_TEST_MISSING_OFFER"] = "1"
        result = self._preflight("terraform", 25)
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn("Marketplace offer", result.stdout)

    def test_preflight_blocks_a_55_model_missing_from_the_region(self) -> None:
        self.env["CLAUDE_TEST_MISSING_MODEL"] = "1"
        result = self._preflight("terraform", 25)
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn("not found in the Anthropic model catalog", result.stdout)

    def test_preflight_fast_variant_uses_model_catalog_not_a_fabricated_offer(self) -> None:
        result = self._preflight("terraform", 25, "claude-opus-5-5-fast")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no standalone Marketplace offer", result.stdout)

    def test_preflight_preserves_legacy_marketplace_agreement_check(self) -> None:
        result = self._preflight("terraform", 25, "claude-sonnet-4-6")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("marketplace agreement signed", result.stdout)

    def test_preflight_still_blocks_insufficient_terraform_quota(self) -> None:
        result = self._preflight("terraform", 24)
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertIn("Insufficient quota", result.stdout)

    def test_preflight_preserves_bicep_arm_preflight_warning(self) -> None:
        result = self._preflight("bicep", 24)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Preflight WARNING", result.stdout)

    def test_industry_preconfigured_values_skip_prompt_and_save(self) -> None:
        for industry in (
            "technology", "finance", "healthcare", "education", "retail",
            "manufacturing", "government", "media", "other",
        ):
            with self.subTest(industry=industry):
                self.env.update(INDUSTRY=industry, CI="true")
                result = self._preflight("bicep", 25)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("INDUSTRY_PROMPT", result.stdout)
        self.assertFalse((self.work / "industry-saves.jsonl").exists())

    def test_industry_missing_in_ci_fails_before_deployment_checks(self) -> None:
        self.env.pop("INDUSTRY")
        self.env["CI"] = "true"
        result = self._preflight("terraform", 25)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("INDUSTRY is required", result.stdout)
        self.assertNotIn("marketplace", result.stdout.lower())

    def test_industry_noninteractive_shell_explains_how_to_preconfigure(self) -> None:
        self.env.pop("INDUSTRY")
        self.env.pop("CI", None)
        result = self._preflight("bicep", 25)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("azd env set INDUSTRY", result.stdout)

    def test_industry_menu_choice_is_saved_once_then_reused(self) -> None:
        self.env.pop("INDUSTRY")
        self.env.pop("CI", None)
        self.env["CLAUDE_TEST_INDUSTRY_CHOICE"] = "2"
        result = self._preflight("bicep", 25)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("INDUSTRY_PROMPT"), 1)
        self.assertIn("9. other", result.stdout)
        saved = self.work / "industry-saves.jsonl"
        self.assertEqual(saved.read_text(encoding="utf-8").splitlines(), ['["finance"]'])
        self.env["INDUSTRY"] = "finance"
        self.env.pop("CLAUDE_TEST_INDUSTRY_CHOICE")
        result = self._preflight("bicep", 25)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(saved.read_text(encoding="utf-8").splitlines()), 1)

    def test_industry_legacy_environment_migrates_without_prompt(self) -> None:
        self.env.pop("INDUSTRY")
        self.env.update(CLAUDE_INDUSTRY="finance", CI="true")
        result = self._preflight("terraform", 25)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            (self.work / "industry-saves.jsonl").read_text(encoding="utf-8").splitlines(),
            ['["finance"]'],
        )

    def test_industry_explicit_value_wins_over_legacy_with_warning(self) -> None:
        self.env.update(INDUSTRY="finance", CLAUDE_INDUSTRY="technology")
        result = self._preflight("bicep", 25)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("INDUSTRY overrides legacy CLAUDE_INDUSTRY", result.stdout)
        self.assertFalse((self.work / "industry-saves.jsonl").exists())

    def test_industry_invalid_or_uppercase_value_is_not_silently_replaced(self) -> None:
        for industry in ("Technology", "NONE", "not-an-industry", " finance "):
            with self.subTest(industry=industry):
                self.env.update(INDUSTRY=industry, CLAUDE_INDUSTRY="finance")
                result = self._preflight("bicep", 25)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("Invalid INDUSTRY", result.stdout)
        self.assertFalse((self.work / "industry-saves.jsonl").exists())

    def test_industry_save_failure_is_fatal(self) -> None:
        self.env.pop("INDUSTRY")
        self.env.update(CLAUDE_INDUSTRY="finance", CLAUDE_TEST_SAVE_FAIL="1")
        result = self._preflight("terraform", 25)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Could not save INDUSTRY", result.stdout)

    def test_industry_only_mode_does_not_run_deployment_checks(self) -> None:
        script = str(ROOT / "scripts" / "preflight-claude.ps1").replace("'", "''")
        self.env.pop("INDUSTRY")
        self.env.update(CLAUDE_INDUSTRY="finance", CI="true")
        result = self._run(f"& '{script}' -IndustryOnly; exit $LASTEXITCODE")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("AZURE_LOCATION", result.stdout)
        self.assertEqual(
            (self.work / "industry-saves.jsonl").read_text(encoding="utf-8").splitlines(),
            ['["finance"]'],
        )

    @unittest.skipUnless(BASH, "Bash is required")
    def test_bash_preflight_preserves_the_same_model_offer_and_quota_gates(self) -> None:
        (self.work / "azure.yaml").write_text(
            "name: sample\ninfra:\n  provider: terraform\n", encoding="utf-8"
        )
        python_alias = self.work / "python"
        python_alias.write_text("#!/bin/sh\nexit 127\n", encoding="utf-8")
        python_alias.chmod(0o755)
        for model, limit, flag, expected in (
            ("claude-sonnet-5-5", "25", None, 0),
            ("claude-sonnet-5-5", "24", None, 6),
            ("claude-sonnet-5-5", "25", "CLAUDE_TEST_MISSING_OFFER", 4),
            ("claude-sonnet-5-5", "25", "CLAUDE_TEST_MISSING_MODEL", 4),
            ("claude-sonnet-5-5", "25", "CLAUDE_TEST_INVALID_COUNT", 0),
            ("claude-opus-5-5-fast", "25", None, 0),
            ("claude-sonnet-4-6", "25", None, 0),
        ):
            with self.subTest(model=model, limit=limit, flag=flag):
                env = self.env | {
                    "CLAUDE_ORGANIZATION_NAME": "Contoso",
                    "AZURE_LOCATION": "eastus2",
                    f"CLAUDE_{model.split('-')[1].upper()}_MODEL": model,
                    "CLAUDE_TEST_LIMIT": limit,
                }
                if flag:
                    env[flag] = "1"
                result = subprocess.run(
                    [BASH, (ROOT / "scripts" / "preflight-claude.sh").as_posix()],
                    env=env, cwd=self.work, capture_output=True, text=True,
                    encoding="utf-8", timeout=60,
                )
                self.assertEqual(
                    result.returncode, expected, result.stdout + result.stderr
                )

    @unittest.skipUnless(BASH, "Bash is required")
    def test_bash_industry_required_legacy_validation_and_save_failures(self) -> None:
        script = (ROOT / "scripts" / "preflight-claude.sh").as_posix()
        for values, expected, text in (
            ({"INDUSTRY": "finance", "CI": "true"}, 0, "Skipping marketplace"),
            ({"CLAUDE_INDUSTRY": "finance", "CI": "true"}, 0, "Skipping marketplace"),
            ({"CI": "true"}, 1, "INDUSTRY is required"),
            ({"INDUSTRY": "Technology"}, 1, "Invalid INDUSTRY"),
            ({"CLAUDE_INDUSTRY": "finance", "CLAUDE_TEST_SAVE_FAIL": "1"}, 1,
             "Could not save INDUSTRY"),
        ):
            with self.subTest(values=values):
                env = {key: value for key, value in self.env.items() if key != "INDUSTRY"}
                env.update(values)
                result = subprocess.run(
                    [BASH, script], env=env, cwd=self.work, stdin=subprocess.DEVNULL,
                    capture_output=True, text=True, encoding="utf-8", timeout=60,
                )
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertIn(text, result.stdout + result.stderr)

    @unittest.skipUnless(BASH, "Bash is required")
    def test_bash_industry_only_mode_does_not_run_deployment_checks(self) -> None:
        script = (ROOT / "scripts" / "preflight-claude.sh").as_posix()
        env = self.env | {"CLAUDE_INDUSTRY": "finance", "CI": "true"}
        env.pop("INDUSTRY")
        result = subprocess.run(
            [BASH, script, "--industry-only"], env=env, cwd=self.work,
            stdin=subprocess.DEVNULL, capture_output=True, text=True,
            encoding="utf-8", timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("AZURE_LOCATION", result.stderr)
        self.assertEqual(
            (self.work / "industry-saves.jsonl").read_text(encoding="utf-8").splitlines(),
            ['["finance"]'],
        )


if __name__ == "__main__":
    unittest.main()
