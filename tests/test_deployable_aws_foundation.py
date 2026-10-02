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
        identity = (MODULES / "identity" / "main.tf").read_text(encoding="utf-8")
        self.assertIn('resource "aws_vpc_security_group_egress_rule" "runtime_to_database"', security)
        self.assertIn('resource "aws_vpc_security_group_egress_rule" "runtime_https"', security)
        self.assertIn('resource "aws_vpc_security_group_ingress_rule" "database_from_runtime"', security)
        self.assertRegex(security, r"referenced_security_group_id\s*=\s*aws_security_group\.database\.id")
        self.assertRegex(security, r"referenced_security_group_id\s*=\s*aws_security_group\.runtime\.id")
        self.assertEqual(security.count("from_port                    = 5432"), 2)
        self.assertNotIn("  egress {", security)
        self.assertNotIn("  egress =", security)
        self.assertIn('runtime_secret_arn', compute)
        self.assertIn('resource "aws_iam_role_policy" "execution_secret"', identity)
        self.assertIn('role   = aws_iam_role.execution.id', identity)
        self.assertIn('"secretsmanager:GetSecretValue"', identity)
        self.assertIn('"kms:Decrypt"', identity)
        self.assertIn('var.runtime_secret_kms_key_arn == "" ? []', identity)
        self.assertIn('"kms:ViaService"', identity)
        self.assertIn('"secretsmanager.${var.aws_region}.amazonaws.com"', identity)
        self.assertIn('"kms:EncryptionContext:SecretARN"', identity)
        self.assertIn('Resource = [var.runtime_secret_arn]', identity)
        self.assertNotIn('secretsmanager:GetSecretValue', identity.split('resource "aws_iam_role_policy" "task"')[1].split('# ECS resolves')[0])
        self.assertFalse(list((MODULES / "api").glob("*.tf")))

    def test_ci_exercises_both_execution_secret_policy_branches(self):
        terraform_test = (MODULES / "identity" / "identity.tftest.hcl").read_text(encoding="utf-8")
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        versions = (MODULES / "identity" / "versions.tf").read_text(encoding="utf-8")
        lockfile = MODULES / "identity" / ".terraform.lock.hcl"
        self.assertIn('run "aws_managed_secret_key_never_grants_kms_decrypt"', terraform_test)
        self.assertIn('run "customer_managed_key_is_bound_to_exact_secret_manager_context"', terraform_test)
        self.assertIn('required_version = ">= 1.10.0"', versions)
        self.assertTrue(lockfile.is_file())
        self.assertIn('terraform -chdir=terraform/modules/identity init -backend=false -input=false -lockfile=readonly', workflow)
        self.assertIn('terraform -chdir=terraform/modules/identity test', workflow)

    def test_roots_do_not_expose_inputs_that_have_no_resource_behavior(self):
        removed_inputs = ("vpc_id", "allowed_ingress_cidrs", "workload_principal", "compute_engine", "private_subnet_ids", "security_group_ids", "alarm_email", "metric_namespace", "trace_mode")
        for environment in ("staging", "prod"):
            variables = (ROOT / "terraform" / "envs" / environment / "variables.tf").read_text(encoding="utf-8")
            for name in removed_inputs:
                self.assertNotIn(f'variable "{name}"', variables, f"{environment}: {name}")

    def test_terraform_native_syntax_does_not_use_semicolon_statement_delimiters(self):
        def outside_string_semicolons(source: str) -> list[int]:
            hits = []
            quoted = False
            escaped = False
            comment = False
            for index, character in enumerate(source):
                if comment:
                    if character == "\n":
                        comment = False
                    continue
                if quoted:
                    if escaped:
                        escaped = False
                    elif character == "\\":
                        escaped = True
                    elif character == '"':
                        quoted = False
                    continue
                if character == "#":
                    comment = True
                elif character == '"':
                    quoted = True
                elif character == ";":
                    hits.append(index)
            return hits

        for path in ROOT.glob("terraform/**/*.tf"):
            self.assertEqual(outside_string_semicolons(path.read_text(encoding="utf-8")), [], path)
        for path in ROOT.glob("terraform/**/*.tftest.hcl"):
            self.assertEqual(outside_string_semicolons(path.read_text(encoding="utf-8")), [], path)

    def test_source_and_artifact_buckets_both_scope_lifecycle_to_all_objects(self):
        storage = (MODULES / "storage" / "main.tf").read_text(encoding="utf-8")
        self.assertIn('resource "aws_s3_bucket_lifecycle_configuration" "artifacts"', storage)
        self.assertIn('resource "aws_s3_bucket_lifecycle_configuration" "source"', storage)
        self.assertEqual(storage.count('filter {\n      prefix = ""\n    }'), 2)


if __name__ == "__main__":
    unittest.main()
