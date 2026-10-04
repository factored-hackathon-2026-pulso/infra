"""Contracts for the intentionally small, manual-only deployment topology."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
TERRAFORM_ENVS = ROOT / "terraform" / "envs"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"


class EnvironmentPromotionContractTests(unittest.TestCase):
    def test_only_known_environment_roots_exist(self):  # staging, prod, the single-host hackathon env and the TEMPORARY buildbox root (remove "buildbox" here when terraform/envs/buildbox is deleted)
        environments = {path.name for path in TERRAFORM_ENVS.iterdir() if path.is_dir()}
        self.assertEqual(environments, {"staging", "prod", "hackathon", "buildbox"})

        readme = " ".join(
            (ROOT / "README.md").read_text(encoding="utf-8").lower().split()
        )
        self.assertIn("`prod` is the demo environment", readme)
        self.assertIn("staging validates before", readme)
        self.assertNotIn("{demo,staging,prod}", readme)

    def test_ci_validates_exactly_staging_then_production_without_deployment(self):
        workflow = CI_WORKFLOW.read_text(encoding="utf-8").lower()
        self.assertIn('"staging", "prod"', workflow)
        self.assertNotIn('"demo"', workflow)
        self.assertNotIn("terraform plan", workflow)
        self.assertNotIn("terraform apply", workflow)
        self.assertNotIn("workflow_dispatch:", workflow)
        self.assertNotIn("schedule:", workflow)
        self.assertNotIn("id-token: write", workflow)
        self.assertNotIn("${{ secrets.", workflow)


if __name__ == "__main__":
    unittest.main()

