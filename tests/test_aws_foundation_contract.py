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
            "security": ("vpc_id",),
            "identity": (
                "github_oidc_provider_arn",
                "github_subjects",
                "runtime_secret_arn",
                "source_bucket_arn",
                "artifact_bucket_arn",
            ),
            "compute": ("image_digest", "private_subnet_ids"),
            "storage": ("artifact_bucket_name", "source_bucket_name"),
            "database": ("postgres_engine_version", "private_subnet_ids"),
            "secrets": ("secret_name_prefix", "kms_key_arn"),
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
            "schedule:",
            "id-token: write",
            "${{ secrets.",
        ):
            self.assertNotIn(forbidden, workflow)
        self.assertIn("workflow_dispatch:", workflow)

    def test_foundation_modules_create_concrete_aws_boundaries_not_only_variable_interfaces(self):
        required_resources = {
            "network": ("aws_vpc", "aws_subnet", "aws_nat_gateway"),
            "security": ("aws_security_group",),
            "identity": ("aws_iam_role",),
            "compute": ("aws_ecs_cluster", "aws_ecs_service"),
            "storage": ("aws_s3_bucket", "aws_s3_bucket_public_access_block"),
            "database": ("aws_db_subnet_group", "aws_db_instance"),
            "secrets": ("aws_secretsmanager_secret",),
            "observability": ("aws_cloudwatch_metric_alarm",),
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

    def test_storage_enforces_kms_sse_for_each_bucket(self):
        storage = (MODULES / "storage" / "main.tf").read_text(encoding="utf-8")
        self.assertEqual(storage.count('resource "aws_s3_bucket_server_side_encryption_configuration"'), 2)
        self.assertIn('sse_algorithm     = "aws:kms"', storage)
        self.assertIn("kms_master_key_id = var.kms_key_arn", storage)
        self.assertIn("bucket_key_enabled = true", storage)

    def test_storage_denies_missing_wrong_or_non_kms_put_object_headers_for_both_buckets(self):
        storage = (MODULES / "storage" / "main.tf").read_text(encoding="utf-8")

        self.assertIn("for_each = local.buckets", storage)
        self.assertIn('resource "aws_s3_bucket_policy" "require_kms"', storage)
        self.assertIn('actions   = ["s3:PutObject"]', storage)
        self.assertEqual(3, storage.count('effect    = "Deny"'))
        self.assertRegex(storage, r'sid\s*=\s*"DenyMissingSseKmsKey"')
        self.assertRegex(storage, r'test\s*=\s*"Null"')
        self.assertRegex(
            storage, r'variable\s*=\s*"s3:x-amz-server-side-encryption-aws-kms-key-id"'
        )
        self.assertRegex(storage, r'values\s*=\s*\["true"\]')
        self.assertRegex(storage, r'sid\s*=\s*"DenyNonKmsObjectEncryption"')
        self.assertRegex(storage, r'test\s*=\s*"StringNotEquals"')
        self.assertRegex(storage, r'variable\s*=\s*"s3:x-amz-server-side-encryption"')
        self.assertRegex(storage, r'values\s*=\s*\["aws:kms"\]')
        self.assertRegex(storage, r'sid\s*=\s*"DenyWrongSseKmsKey"')
        self.assertRegex(storage, r'test\s*=\s*"ArnNotEqualsIfExists"')
        self.assertRegex(storage, r'values\s*=\s*\[var\.kms_key_arn\]')

    def test_workload_rds_path_is_explicit_sg_to_sg_without_open_database_egress(self):
        security = (MODULES / "security" / "main.tf").read_text(encoding="utf-8")
        self.assertIn('resource "aws_vpc_security_group_egress_rule" "workload_to_database"', security)
        self.assertIn("referenced_security_group_id = aws_security_group.database.id", security)
        self.assertIn("from_port                     = 5432", security)
        self.assertIn('resource "aws_vpc_security_group_ingress_rule" "database_from_workload"', security)

    def test_identity_has_shared_oidc_and_separate_hardcoded_ecs_roles(self):
        identity = "\n".join(
            path.read_text(encoding="utf-8") for path in (MODULES / "identity").glob("*.tf")
        )
        self.assertNotIn('resource "aws_iam_openid_connect_provider"', identity)
        self.assertIn("var.github_oidc_provider_arn", identity)
        self.assertIn('identifiers = ["ecs-tasks.amazonaws.com"]', identity)
        self.assertIn('resource "aws_iam_role" "execution"', identity)
        self.assertIn('resource "aws_iam_role" "runtime"', identity)
        self.assertIn('AmazonECSTaskExecutionRolePolicy', identity)
        self.assertNotIn("workload_assume_role_policy_json", identity)
        self.assertNotIn("workload_policy_json", identity)

    def test_runtime_kms_permissions_are_minimum_and_scoped_to_the_configured_cmk(self):
        identity = (MODULES / "identity" / "main.tf").read_text(encoding="utf-8")
        variables = (MODULES / "identity" / "variables.tf").read_text(encoding="utf-8")

        self.assertIn('sid = "UseConfiguredS3DataKey"', identity)
        self.assertIn('sid       = "UseConfiguredSecretKey"', identity)
        for action in (
            "kms:Decrypt",
            "kms:GenerateDataKey",
        ):
            self.assertIn(f'"{action}"', identity)
        self.assertEqual(2, identity.count("resources = [var.kms_key_arn]"))
        self.assertEqual(2, identity.count('variable = "kms:ViaService"'))
        self.assertRegex(
            identity, r'values\s*=\s*\["s3\.\$\{var\.aws_region\}\.amazonaws\.com"\]'
        )
        self.assertRegex(
            identity,
            r'values\s*=\s*\["secretsmanager\.\$\{var\.aws_region\}\.amazonaws\.com"\]',
        )
        self.assertIn('variable = "kms:EncryptionContext:SecretARN"', identity)
        self.assertRegex(identity, r"values\s*=\s*\[var\.runtime_secret_arn\]")
        self.assertIn('variable = "kms:EncryptionContext:aws:s3:arn"', identity)
        self.assertRegex(
            identity,
            r"values\s*=\s*\[var\.source_bucket_arn, var\.artifact_bucket_arn\]",
        )
        s3_key_statement = identity.split('sid = "UseConfiguredS3DataKey"', 1)[1].split(
            "# Secrets Manager", 1
        )[0]
        self.assertNotIn('"${var.source_bucket_arn}/*"', s3_key_statement)
        self.assertNotIn('"${var.artifact_bucket_arn}/*"', s3_key_statement)
        self.assertIn('variable "kms_key_arn"', variables)
        self.assertIn('variable "aws_region"', variables)
        self.assertEqual(
            {
                "kms:Decrypt",
                "kms:GenerateDataKey",
                "kms:ViaService",
                "kms:EncryptionContext:SecretARN",
                "kms:EncryptionContext:aws:s3:arn",
            },
            set(re.findall(r'"(kms:[^"]+)"', identity)),
        )
        self.assertNotIn('resources = ["*"]', identity)

        for environment in ("staging", "prod"):
            main = (ENVS / environment / "main.tf").read_text(encoding="utf-8")
            identity_module = re.search(
                r'module "identity" \{(?P<body>.*?)\n\}', main, flags=re.DOTALL
            )
            self.assertIsNotNone(identity_module)
            self.assertRegex(
                identity_module.group("body"), r"kms_key_arn\s*=\s*var\.kms_key_arn"
            )
            self.assertRegex(
                identity_module.group("body"), r"aws_region\s*=\s*var\.aws_region"
            )

    def test_public_http_api_is_deferred_until_an_authenticated_or_private_integration_is_approved(self):
        terraform = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (ROOT / "terraform").rglob("*.tf")
        )
        for public_resource in ("aws_apigatewayv2_api", "aws_apigatewayv2_stage"):
            self.assertNotIn(f'resource "{public_resource}"', terraform)
        for environment in ("staging", "prod"):
            main = (ENVS / environment / "main.tf").read_text(encoding="utf-8")
            self.assertNotIn('module "api"', main)

        observability = "\n".join(
            path.read_text(encoding="utf-8") for path in (MODULES / "observability").glob("*.tf")
        )
        self.assertNotIn('resource "aws_cloudwatch_log_group" "api"', observability)
        self.assertNotIn("api_log_group_arn", observability)

        security = "\n".join(
            path.read_text(encoding="utf-8") for path in (MODULES / "security").glob("*.tf")
        )
        for dead_edge_boundary in (
            'resource "aws_security_group" "edge"',
            '"edge_https"',
            '"workload_from_edge"',
            "edge_security_group_id",
            "allowed_ingress_cidrs",
            "container_port",
        ):
            self.assertNotIn(dead_edge_boundary, security)

        for environment in ("staging", "prod"):
            main = (ENVS / environment / "main.tf").read_text(encoding="utf-8")
            security_module = re.search(
                r'module "security" \{(?P<body>.*?)\n\}', main, flags=re.DOTALL
            )
            self.assertIsNotNone(security_module)
            self.assertNotIn("container_port", security_module.group("body"))

        gap = (ROOT / "docs" / "gaps" / "OPEN_GAPS.md").read_text(encoding="utf-8")
        self.assertIn("public HTTP API", gap)
        self.assertIn("authenticated or private", gap.lower())

    def test_alarm_email_creates_a_configured_subscription_instead_of_dead_input(self):
        observability = "\n".join(
            path.read_text(encoding="utf-8") for path in (MODULES / "observability").glob("*.tf")
        )
        self.assertIn('resource "aws_sns_topic_subscription" "alarm_email"', observability)
        self.assertIn('protocol  = "email"', observability)
        self.assertIn("endpoint  = var.alarm_email", observability)
        self.assertIn("var.alarm_email == null ? 0 : 1", observability)

    def test_ecs_task_has_awslogs_and_the_service_port_mapping(self):
        compute = (MODULES / "compute" / "main.tf").read_text(encoding="utf-8")
        self.assertIn('logDriver = "awslogs"', compute)
        self.assertIn('"awslogs-group"         = aws_cloudwatch_log_group.task.name', compute)
        self.assertIn('"awslogs-region"        = var.aws_region', compute)
        self.assertIn("portMappings = [{", compute)
        self.assertIn("containerPort = var.container_port", compute)


if __name__ == "__main__":
    unittest.main()
