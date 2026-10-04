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


class CurrentTree(unittest.TestCase):
    def test_no_failures_in_current_terraform_tree(self):
        failures = [f for f in review.run_all(ROOT) if f.severity == "FAIL"]
        self.assertEqual([], [str(f) for f in failures])

    def test_known_gaps_are_reported_not_hidden(self):
        gaps = {f.rule for f in review.run_all(ROOT) if f.severity == "GAP"}
        self.assertIn("switch-missing", gaps)  # data_pipeline switch not wired in envs yet


if __name__ == "__main__":
    unittest.main()
