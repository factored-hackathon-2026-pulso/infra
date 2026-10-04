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


class RegionDefaultsAllowlist(unittest.TestCase):
    """Single-region prod: us-east-1 is accepted as the default of region, aws_region (bootstrap) and
    cloudfront_waf_region only (CloudFront WAF exists only there). Any other literal still fails."""

    def _rules(self, body, sub="envs/hackathon"):
        import tempfile
        with tempfile.TemporaryDirectory() as t:
            d = Path(t) / sub
            d.mkdir(parents=True)
            (d / "a.tf").write_text(body, encoding="utf-8")
            return {f.rule for f in review.scan_tf_dir(Path(t))}

    def test_us_east_1_default_accepted_for_the_three_variables(self):
        for name in ("region", "aws_region", "cloudfront_waf_region"):
            body = 'variable "%s" {\n  type    = string\n  default = "us-east-1"\n}' % name
            self.assertNotIn("hardcoded-region", self._rules(body), name)

    def test_us_east_1_rejected_for_other_variables(self):
        body = 'variable "other_region" {\n  default = "us-east-1"\n}'
        self.assertIn("hardcoded-region", self._rules(body))

    def test_other_regions_rejected_even_for_allowed_variables(self):
        for region in ("eu-west-1", "us-east-2", "us-west-2"):
            body = 'variable "region" {\n  default = "%s"\n}' % region
            self.assertIn("hardcoded-region", self._rules(body), region)

    def test_us_east_1_rejected_outside_variable_defaults(self):
        self.assertIn("hardcoded-region", self._rules('locals {\n  r = "us-east-1"\n}'))

    def test_dataset_region_us_east_2_is_the_external_dataset_location(self):
        body = 'variable "dataset_region" {\n  default = "us-east-2"\n}'
        self.assertNotIn("hardcoded-region", self._rules(body, "modules/data_pipeline"))


class CurrentTree(unittest.TestCase):
    def test_no_failures_in_current_terraform_tree(self):
        failures = [f for f in review.run_all(ROOT) if f.severity == "FAIL"]
        self.assertEqual([], [str(f) for f in failures])

    def test_known_gaps_are_reported_not_hidden(self):
        gaps = {f.rule for f in review.run_all(ROOT) if f.severity == "GAP"}
        self.assertIn("switch-missing", gaps)  # data_pipeline switch not wired in envs yet

    def test_new_account_bootstrap_and_engine_task_are_scanned(self):
        """TA0 checker must cover terraform/bootstrap, not only modules and envs."""
        import tempfile
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            boot = root / "terraform" / "bootstrap"
            boot.mkdir(parents=True)
            (boot / "a.tf").write_text('variable "r" { default = "eu-west-1" }', encoding="utf-8")
            rules = {f.rule for f in review.scan_extra_roots(root)}
            self.assertIn("hardcoded-region", rules)


if __name__ == "__main__":
    unittest.main()
