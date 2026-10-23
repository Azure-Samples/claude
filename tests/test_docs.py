from __future__ import annotations

from html.parser import HTMLParser
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]


class _DetailsParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.stack: list[str | None] = []
        self.parents: dict[str, tuple[str | None, ...]] = {}

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "details":
            identifier = dict(attrs).get("id")
            if identifier:
                self.parents[identifier] = tuple(self.stack)
            self.stack.append(identifier)

    def handle_endtag(self, tag: str) -> None:
        if tag == "details":
            if not self.stack:
                raise AssertionError("README has an unmatched closing details tag")
            self.stack.pop()


class DocumentationTests(unittest.TestCase):
    def test_soft_delete_help_is_nested_without_breaking_its_anchor(self) -> None:
        parser = _DetailsParser()
        parser.feed((ROOT / "README.md").read_text(encoding="utf-8"))
        self.assertEqual(parser.stack, [])
        self.assertIn(
            "advanced-check-claude-quota--capacity-programmatically",
            parser.parents["free-quota-held-by-soft-deleted-accounts"],
        )

    def test_diagram_and_readme_show_all_three_55_models(self) -> None:
        diagram = ET.parse(ROOT / "docs" / "architecture.svg")
        text = " ".join(diagram.getroot().itertext())
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        for family in ("sonnet", "haiku", "opus"):
            model = f"claude-{family}-5-5"
            with self.subTest(model=model):
                self.assertIn(model, text)
                self.assertIn(model, readme)

    def test_soft_delete_fix_is_short_and_warns_before_irreversible_purge(self) -> None:
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        section = readme.split(
            '<details id="free-quota-held-by-soft-deleted-accounts">', 1
        )[1].split("</details>", 1)[0]
        self.assertLess(len(section.splitlines()), 40)
        self.assertIn("destructive and irreversible", section)
        self.assertIn("Confirm the exact account name, region", section)

    def test_diagram_does_not_load_external_assets(self) -> None:
        root = ET.parse(ROOT / "docs" / "architecture.svg").getroot()
        for element in root.iter():
            for key, value in element.attrib.items():
                if key == "href" or key.endswith("}href"):
                    self.assertTrue(value.startswith(("#", "data:")), value)


if __name__ == "__main__":
    unittest.main()
