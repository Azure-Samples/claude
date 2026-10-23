from __future__ import annotations

import contextlib
import io
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import check_claude_quota as quota


class QuotaTests(unittest.TestCase):
    def test_55_rpm_uses_published_ratio_and_api_thousands_once(self) -> None:
        for model in (
            "claude-opus-5-5", "claude-opus-5-5-fast",
            "claude-sonnet-5-5", "claude-haiku-5-5",
        ):
            with self.subTest(model=model):
                line = quota.QuotaLine(
                    "eastus2", "example-quota", "Example", 25, 10000, model
                )
                self.assertEqual(line.rpm_limit, 10000)
                self.assertEqual(line.rpm_used, 25)
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    quota._print_merged([line], [])
                row = next(
                    text.split() for text in output.getvalue().splitlines()
                    if text.strip().startswith(model)
                )
                self.assertEqual(row[6], "10,000,000")
                self.assertEqual(row[8], "10,000")
                self.assertEqual(row[3:5], ["-", "-"])

    def test_doc_style_rpm_has_the_same_units(self) -> None:
        model = "claude-sonnet-5-5"
        line = quota.QuotaLine(
            "eastus2", "example-quota", "Example", 25, 10000, model
        )
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            quota._print_doc_style([line])
        row = next(
            text.split() for text in output.getvalue().splitlines()
            if text.strip().startswith(model)
        )
        self.assertEqual(row[-2:], ["10,000", "10,000,000"])


if __name__ == "__main__":
    unittest.main()
