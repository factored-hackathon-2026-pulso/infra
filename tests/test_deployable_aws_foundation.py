"""Acceptance contract for the deployable shared AWS foundation.

This stays credential-free: it asserts the Terraform graph rather than
pretending an AWS plan/apply was executed.
"""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
MODULES = ROOT / "terraform" / "modules"


class DeployableAwsFoundationTests(unittest.TestCase):
    def test_shared_foundation_declares_real_aws_resources_for_every_required_plane(self):
        expected = {
            "network": ("aws_vpc", "aws_subnet", "aws_nat_gateway"),
            "security": ("aws_security_group",),
            "identity": ("aws_iam_role", "aws_iam_role_policy"),
            "compute": ("aws_ecs_cluster", "aws_ecs_service"),
            "storage": ("aws_s3_bucket",),
            "database": ("aws_db_instance", "aws_db_subnet_group"),
            "secrets": ("aws_secretsmanager_secret",),
            "observability": ("aws_cloudwatch_log_group", "aws_cloudwatch_metric_alarm"),
        }
        for module, resources in expected.items():
            contents = "\n".join(
                path.read_text(encoding="utf-8")
                for path in (MODULES / module).glob("*.tf")
            )
            for resource in resources:
                self.assertIn(f'resource "{resource}"', contents, f"{module}: {resource}")

    def test_environment_roots_wire_outputs_not_caller_supplied_resource_ids(self):
        for environment in ("staging", "prod"):
            main = (ROOT / "terraform" / "envs" / environment / "main.tf").read_text(
                encoding="utf-8"
            )
            self.assertIn("module.network.vpc_id", main)
            self.assertIn("module.network.private_subnet_ids", main)
            self.assertIn("module.security.runtime_security_group_id", main)
            self.assertNotIn("variable \"vpc_id\"", main)

    def test_infra_keeps_local_runtime_out_of_the_repository(self):
        for target in ("local", "scripts/doctor.py", "tests/test_doctor.py"):
            self.assertFalse((ROOT / target).exists(), target)

    def test_runtime_is_private_and_api_is_deferred_until_authenticated_integration_exists(self):
        security = (MODULES / "security" / "main.tf").read_text(encoding="utf-8")
        compute = (MODULES / "compute" / "main.tf").read_text(encoding="utf-8")
        self.assertIn('from_port = 5432', security)
        self.assertIn('security_groups = [aws_security_group.database.id]', security)
        self.assertIn('runtime_secret_arn', compute)
        self.assertFalse(list((MODULES / "api").glob("*.tf")))


if __name__ == "__main__":
    unittest.main()
