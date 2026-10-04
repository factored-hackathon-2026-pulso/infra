"""Documentation must match the code: documented script subcommands, flags, variables and modules must exist.

Offline and read-only. Conventions the docs follow so this can be checked mechanically:
  - `aws-prod.ps1 <subcommand> ... -Flag` in prose or code blocks names real subcommands and parameters;
  - `var.<name>` names a Terraform variable defined in some variables.tf;
  - `module.<name>` names a module call in terraform/envs/hackathon/main.tf;
  - `terraform/modules/<name>` and `modules/<name>` name a directory;
  - relative Markdown links resolve to files.
And in the other direction: every subcommand and every variable of the two prod roots is documented somewhere.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
SCRIPT = ROOT / "scripts" / "aws-prod.ps1"
REQUIRED_DOCS = (
    "README.md", "aws-prod-quickstart.md", "architecture.md", "operations.md", "modification-guide.md",
    "troubleshooting.md", "security-model.md", "costs.md", "decisions.md",
)


def doc_files():
    files = [ROOT / "README.md"] + sorted(DOCS.glob("*.md"))
    return [f for f in files if f.exists()]


def all_doc_text() -> str:
    return "\n".join(f.read_text(encoding="utf-8") for f in doc_files())


def script_subcommands() -> set[str]:
    text = SCRIPT.read_text(encoding="utf-8")
    block = re.search(r"ValidateSet\(([^)]*)\)\]\s*\[string\]\$Command", text, re.S).group(1)
    return set(re.findall(r"'([a-z-]+)'", block))


def script_parameters() -> set[str]:
    text = SCRIPT.read_text(encoding="utf-8")
    param = re.search(r"^param\((.*?)^\)", text, re.S | re.M).group(1)
    return {m.lower() for m in re.findall(r"\$([A-Za-z]+)\s*(?:=|,|\n|$)", param)}


def terraform_variables(directory: Path) -> set[str]:
    names: set[str] = set()
    for f in directory.glob("variables.tf"):
        names |= set(re.findall(r'^variable\s+"([^"]+)"', f.read_text(encoding="utf-8"), re.M))
    return names


def all_variables() -> set[str]:
    names: set[str] = set()
    for f in (ROOT / "terraform").rglob("variables.tf"):
        if ".terraform" in f.parts:
            continue
        names |= set(re.findall(r'^variable\s+"([^"]+)"', f.read_text(encoding="utf-8"), re.M))
    return names


class DocsExist(unittest.TestCase):
    def test_required_docs_exist(self):
        missing = [d for d in REQUIRED_DOCS if not (DOCS / d).exists()]
        self.assertEqual([], missing)

    def test_repo_readme_points_to_the_docs_index(self):
        self.assertIn("docs/README.md", (ROOT / "README.md").read_text(encoding="utf-8"))

    def test_docs_index_links_every_required_doc(self):
        index = (DOCS / "README.md").read_text(encoding="utf-8")
        for d in REQUIRED_DOCS[1:]:
            self.assertIn(d, index, d)

    def test_decisions_index_lists_every_adr(self):
        text = (DOCS / "decisions.md").read_text(encoding="utf-8")
        for adr in sorted((DOCS / "adr").glob("*.md")):
            self.assertIn(adr.name, text, adr.name)


class DocsMatchCode(unittest.TestCase):
    def test_documented_subcommands_exist(self):
        known = script_subcommands()
        self.assertIn("check", known)
        found = set(re.findall(r"aws-prod\.ps1\s+([a-z][a-z-]+)", all_doc_text()))
        self.assertEqual(set(), found - known, "documented subcommand missing from scripts/aws-prod.ps1")

    def test_every_subcommand_is_documented(self):
        text = (DOCS / "aws-prod-quickstart.md").read_text(encoding="utf-8") + (DOCS / "operations.md").read_text(encoding="utf-8")
        for sub in script_subcommands():
            self.assertRegex(text, r"aws-prod\.ps1\s+%s\b" % re.escape(sub), sub)

    def test_documented_script_flags_exist(self):
        known = script_parameters() | {"verbose", "debug"}
        flags = set()
        for line in all_doc_text().splitlines():
            if "aws-prod.ps1" in line:
                flags |= {f.lower() for f in re.findall(r"\s-([A-Z][A-Za-z]+)\b", line)}
        self.assertEqual(set(), flags - known, "documented flag missing from scripts/aws-prod.ps1")

    def test_documented_variables_exist(self):
        known = all_variables()
        found = set(re.findall(r"`var\.([a-z][a-z0-9_]*)`", all_doc_text()))
        self.assertEqual(set(), found - known)

    def test_prod_root_variables_are_all_documented(self):
        text = all_doc_text()
        for d in ("terraform/envs/hackathon", "terraform/bootstrap"):
            for name in terraform_variables(ROOT / d):
                self.assertRegex(text, r"\b%s\b" % re.escape(name), f"{d}: {name} is not documented")

    def test_documented_modules_exist(self):
        text = all_doc_text()
        modules = {p.name for p in (ROOT / "terraform" / "modules").iterdir() if p.is_dir()}
        for name in set(re.findall(r"modules/([a-z][a-z0-9_]*[a-z0-9])\b", text)):
            self.assertIn(name, modules, f"modules/{name}")
        main = (ROOT / "terraform/envs/hackathon/main.tf").read_text(encoding="utf-8")
        called = set(re.findall(r'^module\s+"([^"]+)"', main, re.M))
        for name in set(re.findall(r"`module\.([a-z][a-z0-9_]+)`", text)):
            self.assertIn(name, called, f"module.{name}")

    def test_relative_links_resolve(self):
        broken = []
        for f in doc_files():
            for target in re.findall(r"\]\(([^)\s]+)\)", f.read_text(encoding="utf-8")):
                if re.match(r"^(https?:|mailto:|#)", target):
                    continue
                path = target.split("#", 1)[0]
                if path and not (f.parent / path).resolve().exists():
                    broken.append(f"{f.relative_to(ROOT)} -> {target}")
        self.assertEqual([], broken)

    def test_docs_hold_no_account_id_key_or_email(self):
        text = all_doc_text()
        self.assertNotRegex(text, r"\b\d{12}\b(?<!000000000000)", "a 12-digit account id")
        self.assertNotRegex(text, r"AKIA[0-9A-Z]{16}")
        self.assertNotRegex(text, r"[\w.+-]+@[\w-]+\.[\w.]+")


if __name__ == "__main__":
    unittest.main()
