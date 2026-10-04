"""Offline plan-review checks (docs/aws-plan-review-checklist.md). No AWS credentials, no network."""

from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import aws_plan_review as review  # noqa: E402

FIXTURE = ROOT / "tests" / "fixtures" / "account_assuming"


class FixtureFailsRed(unittest.TestCase):
    def test_account_assuming_fixture_is_flagged_for_every_rule(self):
        rules = {f.rule for f in review.scan_tf_dir(FIXTURE)}
        for expected in ("hardcoded-account-id", "hardcoded-region", "admin-policy",
                         "public-db", "open-ingress", "switch-default-on"):
            self.assertIn(expected, rules)


class FalseNegatives(unittest.TestCase):
    def _rules(self, body, sub="envs/x"):
        import tempfile
        with tempfile.TemporaryDirectory() as t:
            d = Path(t) / sub
            d.mkdir(parents=True)
            (d / "a.tf").write_text(body, encoding="utf-8")
            return {f.rule for f in review.scan_tf_dir(Path(t))}

    def test_other_syntaxes_are_flagged(self):
        cases = {
            "bare-account-id": 'locals { a = "123456789012" }',
            "wildcard-account-arn": 'x = "arn:aws:iam::*:role/r"',
            "open-ingress": '''resource "aws_security_group" "s" {
  ingress {
    cidr_blocks = ["0.0.0.0/0"]
  }
}''',
            "public-db": 'publicly_accessible = "true"',
            "admin-policy": 'actions = ["*"]',
            "wildcard-principal": 'Principal = "*"',
            "secret-committed": 'k = "AKIAABCDEFGHIJKLMNOP"',
            "switch-default-on": '''variable "q_enabled" {
  default = "true"
}''',
        }
        for rule, body in cases.items():
            self.assertIn(rule, self._rules(body), rule)

    def test_locals_switch_on_is_flagged(self):
        self.assertIn("switch-default-on", self._rules('locals {\n  bridge_services_enabled = true\n}'))

    def test_wildcard_principal_allowed_only_in_deny(self):
        deny = 'statement {\n  effect = "Deny"\n  principals { identifiers = ["*"] }\n}'
        allow = 'statement {\n  effect = "Allow"\n  principals { identifiers = ["*"] }\n}'
        self.assertNotIn("wildcard-principal", self._rules(deny))
        self.assertIn("wildcard-principal", self._rules(allow))

    def test_legit_use_not_flagged(self):
        ok = '''egress { cidr_blocks = ["0.0.0.0/0"] }
variable "a" { default = "000000000000" }
actions = ["s3:GetObject"]'''
        self.assertEqual(set(), self._rules(ok))


class CurrentTree(unittest.TestCase):
    def test_no_failures_in_current_terraform_tree(self):
        failures = [f for f in review.run_all(ROOT) if f.severity == "FAIL"]
        self.assertEqual([], [str(f) for f in failures])

    def test_known_gaps_are_reported_not_hidden(self):
        gaps = {f.rule for f in review.run_all(ROOT) if f.severity == "GAP"}
        self.assertIn("switch-missing", gaps)  # data_pipeline switch not wired in envs yet


if __name__ == "__main__":
    unittest.main()
