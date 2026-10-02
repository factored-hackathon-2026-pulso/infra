"""Static contracts for Pulso's modular, non-deploying AWS foundation."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
MODULES = ROOT / "terraform" / "modules"
ENVS = ROOT / "terraform" / "envs"


class AwsFoundationContractTests(unittest.TestCase):
    def test_only_staging_and_production_demo_wire_every_foundation_boundary(self):
        expected_modules = {
            "network",
            "security",
            "identity",
            "compute",
            "storage",
            "database",
            "secrets",
            "observability",
        }
        for environment in ("staging", "prod"):
            main = (ENVS / environment / "main.tf").read_text(encoding="utf-8")
            for module in expected_modules:
                self.assertIn(f'module "{module}"', main, f"{environment}: {module}")

    def test_foundation_declares_network_security_and_cost_control_interfaces(self):
        required = {
            "network": ("vpc_cidr", "public_subnet_cidrs", "private_subnet_cidrs", "nat_strategy"),
            "security": ("vpc_id", "allowed_ingress_cidrs"),
            "identity": ("workload_principal", "least_privilege_policy_boundary"),
            "compute": ("compute_engine", "private_subnet_ids"),
            "storage": ("artifact_bucket_name", "source_bucket_name"),
            "database": ("database_engine", "private_subnet_ids"),
            "secrets": ("secret_name_prefix", "kms_key_arn"),
            "observability": ("service_name", "alarm_email"),
        }
        for module, names in required.items():
            variables = (MODULES / module / "variables.tf").read_text(encoding="utf-8")
            for name in names:
                self.assertIn(f'variable "{name}"', variables, f"{module}: {name}")

    def test_legacy_local_harness_has_a_documented_removal_plan_before_deletion(self):
        inventory = " ".join(
            (ROOT / "docs" / "migration" / "i06-legacy-local-removal.md")
            .read_text(encoding="utf-8")
            .replace("**", "")
            .split()
        )
        for target in (
            "local/preflight.stack.json",
            "local/preflight.tools.json",
            "scripts/doctor.py",
            "tests/test_doctor.py",
        ):
            self.assertIn(target, inventory)
            self.assertFalse((ROOT / target).exists(), target)
        self.assertIn("not invoked by infra CI", inventory)
        self.assertIn("no confirmed engine replacement", inventory)

    def test_ci_remains_validation_only_without_automatic_cloud_actions(self):
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8").lower()
        for forbidden in (
            "terraform plan",
            "terraform apply",
            "workflow_dispatch:",
            "schedule:",
            "id-token: write",
            "${{ secrets.",
        ):
            self.assertNotIn(forbidden, workflow)


if __name__ == "__main__":
    unittest.main()
