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
            "api",
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
            "identity": ("github_subjects", "workload_assume_role_policy_json"),
            "compute": ("image_digest", "private_subnet_ids"),
            "storage": ("artifact_bucket_name", "source_bucket_name"),
            "database": ("postgres_engine_version", "private_subnet_ids"),
            "secrets": ("secret_name_prefix", "kms_key_arn"),
            "api": ("access_log_group_arn",),
            "observability": ("service_name", "alarm_email", "cluster_name"),
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

    def test_foundation_modules_create_concrete_aws_boundaries_not_only_variable_interfaces(self):
        required_resources = {
            "network": ("aws_vpc", "aws_subnet", "aws_nat_gateway"),
            "security": ("aws_security_group",),
            "identity": ("aws_iam_role", "aws_iam_openid_connect_provider"),
            "compute": ("aws_ecs_cluster", "aws_ecs_service"),
            "storage": ("aws_s3_bucket", "aws_s3_bucket_public_access_block"),
            "database": ("aws_db_subnet_group", "aws_db_instance"),
            "secrets": ("aws_secretsmanager_secret",),
            "api": ("aws_apigatewayv2_api", "aws_apigatewayv2_stage"),
            "observability": ("aws_cloudwatch_log_group", "aws_cloudwatch_metric_alarm"),
        }
        for module, resource_names in required_resources.items():
            source = "\n".join(
                path.read_text(encoding="utf-8")
                for path in (MODULES / module).glob("*.tf")
            )
            for resource_name in resource_names:
                self.assertIn(f'resource "{resource_name}"', source, module)

    def test_environment_wires_outputs_instead_of_requiring_caller_supplied_resource_ids(self):
        for environment in ("staging", "prod"):
            main = (ENVS / environment / "main.tf").read_text(encoding="utf-8")
            self.assertIn("module.network.vpc_id", main)
            self.assertIn("module.network.private_subnet_ids", main)
            self.assertIn("module.security.workload_security_group_id", main)
            self.assertNotIn('variable "vpc_id"', (ENVS / environment / "variables.tf").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
