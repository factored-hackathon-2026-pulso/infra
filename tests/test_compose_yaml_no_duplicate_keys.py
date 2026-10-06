"""Every YAML under deploy/ must be free of duplicate mapping keys.

PyYAML silently keeps the last duplicate, but docker compose (Go yaml) aborts
with "mapping key ... already defined", so a merge artifact can take down a host.
"""

from __future__ import annotations

import unittest
from pathlib import Path

import yaml

DEPLOY = Path(__file__).resolve().parents[1] / "deploy"


class DuplicateKeyError(yaml.YAMLError):
    pass


class StrictLoader(yaml.SafeLoader):
    def construct_mapping(self, node, deep=False):
        if isinstance(node, yaml.MappingNode):
            self.flatten_mapping(node)
            seen = {}
            for key_node, _ in node.value:
                key = self.construct_object(key_node, deep=True)
                if key in seen:
                    raise DuplicateKeyError(
                        f"line {key_node.start_mark.line + 1}: mapping key {key!r} "
                        f"already defined at line {seen[key] + 1}"
                    )
                seen[key] = key_node.start_mark.line
        return super().construct_mapping(node, deep)


def yaml_files():
    return sorted(p for ext in ("*.yaml", "*.yml") for p in DEPLOY.rglob(ext))


class NoDuplicateKeys(unittest.TestCase):
    def test_deploy_yaml_files_are_found(self):
        self.assertTrue(yaml_files())

    def test_no_yaml_under_deploy_has_duplicate_keys(self):
        failures = []
        for path in yaml_files():
            try:
                yaml.load(path.read_text(encoding="utf-8"), Loader=StrictLoader)
            except DuplicateKeyError as exc:
                failures.append(f"{path.relative_to(DEPLOY.parent)}: {exc}")
        self.assertEqual([], failures)


if __name__ == "__main__":
    unittest.main()
