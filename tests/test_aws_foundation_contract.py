"""Static contracts for Pulso's modular, non-deploying AWS foundation."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
MODULES = ROOT / "terraform" / "modules"
ENVS = ROOT / "terraform" / "envs"


class AwsFoundationContractTests(unittest.TestCase):
    def test_only_staging_and_production_demo_wire_every_foundation_boundary(self):
        expected_modules = {
            "network", "security", "identity", "compute", "storage", "database", "secrets", "observability",
        }
        for environment in ("staging", "prod"):
            main = (ENVS / environment / "main.tf").read_text(encoding="utf-8")
            for module in expected_modules:
                self.assertIn(f'module "{module}"', main, f"{environment}: {module}")

    def test_foundation_declares_network_security_and_cost_control_interfaces(self):
        required = {
            "network": ("vpc_cidr", "public_subnet_cidrs", "private_subnet_cidrs", "nat_strategy"),
            "security": ("vpc_id",),
            "identity": ("least_privilege_policy_boundary", "runtime_secret_kms_key_arn"),
            "compute": ("image_digest", "private_subnet_ids"),
            "storage": ("artifact_bucket_name", "source_bucket_name"),
            "database": ("database_engine", "private_subnet_ids"),
            "secrets": ("secret_name_prefix", "kms_key_arn"),
            "observability": ("service_name", "alarm_actions"),
        }
        for module, names in required.items():
            variables = (MODULES / module / "variables.tf").read_text(encoding="utf-8")
            for name in names:
                self.assertIn(f'variable "{name}"', variables, f"{module}: {name}")

    def test_legacy_local_harness_has_a_documented_removal_plan_before_deletion(self):
        inventory = " ".join(
            (ROOT / "docs" / "migration" / "i06-legacy-local-removal.md")
            .read_text(encoding="utf-8").replace("**", "").split()
        )
        for target in ("local/preflight.stack.json", "local/preflight.tools.json", "scripts/doctor.py", "tests/test_doctor.py"):
            self.assertIn(target, inventory)
            self.assertFalse((ROOT / target).exists(), target)
        self.assertIn("not invoked by infra CI", inventory)
        self.assertIn("no confirmed engine replacement", inventory)

    def test_ci_remains_validation_only_without_automatic_cloud_actions(self):
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8").lower()
        for forbidden in ("terraform plan", "terraform apply", "workflow_dispatch:", "schedule:", "id-token: write", "${{ secrets."):
            self.assertNotIn(forbidden, workflow)

    def test_runtime_database_contract_exposes_only_reference_metadata(self):
        database = "\n".join(path.read_text(encoding="utf-8") for path in (MODULES / "database").glob("*.tf"))
        compute = (MODULES / "compute" / "main.tf").read_text(encoding="utf-8")
        identity = (MODULES / "identity" / "main.tf").read_text(encoding="utf-8")
        hackathon_data = MODULES / "hackathon_data"
        all_terraform = "\n".join(
            path.read_text(encoding="utf-8") for path in (ROOT / "terraform").rglob("*.tf")
            if hackathon_data not in path.parents
        )
        # Documented exception (ADR 0007 hackathon profile): the single-secret profile seeds placeholders plus a random
        # RDS master password and ignores every later change, so no real value is ever written by Terraform.
        seeded = (hackathon_data / "secrets.tf").read_text(encoding="utf-8")
        self.assertIn("ignore_changes = [secret_string]", seeded)

        self.assertIn("manage_master_user_password", database)
        self.assertIn("master_user_secret_kms_key_id", database)
        self.assertIn('output "master_user_secret_arn"', database)
        self.assertIn('"PULSO_DATABASE_ENDPOINT"', compute)
        self.assertIn('"PULSO_DATABASE_SECRET_ARN"', compute)
        self.assertNotIn("PULSO_DATABASE_PASSWORD", compute)
        self.assertIn("var.runtime_database_secret_arn", identity)
        self.assertNotIn("aws_secretsmanager_secret_version", all_terraform)
        self.assertNotIn("var.rds_master_secret_arn_guard", compute.split("container_definitions", 1)[1].split("lifecycle", 1)[0])
        self.assertNotRegex(compute, r'name\s*=\s*"PULSO_DATABASE[^"\n]*"\s*\n\s*valueFrom')

    def test_database_master_secret_cannot_be_bound_as_the_runtime_secret(self):
        compute = (MODULES / "compute" / "main.tf").read_text(encoding="utf-8")
        identity = (MODULES / "identity" / "main.tf").read_text(encoding="utf-8")
        for source, resource in ((compute, 'resource "aws_ecs_task_definition" "this"'), (identity, 'resource "aws_iam_role_policy" "task"')):
            block = source.split(resource, 1)[1]
            self.assertRegex(
                block,
                r"lifecycle\s*\{\s*precondition\s*\{\s*condition\s*=\s*var\.runtime_database_secret_arn\s*!=\s*var\.rds_master_secret_arn_guard",
            )
        self.assertNotIn("rds_master_secret_arn_guard", identity.split("task_policy", 1)[1].split("execution_secret_policy", 1)[0])
        for environment in ("staging", "prod"):
            main = (ENVS / environment / "main.tf").read_text(encoding="utf-8")
            self.assertRegex(main, r"runtime_database_secret_arn\s*=\s*var\.runtime_database_secret_arn")
            self.assertRegex(main, r"rds_master_secret_arn_guard\s*=\s*module\.database\.master_user_secret_arn")

    def test_runtime_database_secret_permission_is_least_privilege_and_task_scoped(self):
        identity = (MODULES / "identity" / "main.tf").read_text(encoding="utf-8")
        self.assertIn('Sid      = "ReadRuntimeDatabaseSecret"', identity)
        self.assertIn("Resource = [var.runtime_database_secret_arn]", identity)
        self.assertIn('Sid      = "DecryptRuntimeDatabaseSecret"', identity)
        self.assertIn("var.runtime_database_secret_kms_key_arn", identity)
        self.assertNotIn("Resource = [var.rds_master_secret_arn_guard]", identity)
        self.assertNotRegex(identity, r"Resource\s*=\s*\[\"\*\"\]")


if __name__ == "__main__":
    unittest.main()
