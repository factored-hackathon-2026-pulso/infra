"""Structural contract for the Agent Core scale-out pieces (ADR 0005).

No AWS credentials or Terraform binary are needed; this pins the guards the Terraform source must keep and that
`terraform test` also exercises with mocked providers in CI.
"""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
MODULES = ROOT / "terraform" / "modules"
NEW_MODULES = ("ecr", "rds_proxy", "core_data", "scheduled_task", "core_alarms")


def tf(module: str, name: str = "main.tf") -> str:
    return (MODULES / module / name).read_text(encoding="utf-8")


def normalized(text: str) -> str:
    return " ".join(text.split())


class ScaleModulesTests(unittest.TestCase):
    def test_every_new_module_has_versions_variables_and_a_terraform_test(self):
        for module in NEW_MODULES:
            with self.subTest(module=module):
                self.assertTrue((MODULES / module / "versions.tf").exists())
                self.assertIn('variable "tags"', tf(module, "variables.tf"))
                self.assertTrue(list((MODULES / module).glob("*.tftest.hcl")))

    def test_this_slice_adds_no_ingress_or_parallel_workload_modules(self):
        # ADR 0003: private service, no load balancer or WAF; tasks come from the `workload` module.
        for module in NEW_MODULES:
            source = normalized(" ".join(p.read_text(encoding="utf-8") for p in (MODULES / module).glob("*.tf")))
            self.assertNotIn('resource "aws_lb"', source, module)
            self.assertNotIn('resource "aws_wafv2_web_acl"', source, module)
            self.assertNotIn('resource "aws_ecs_task_definition"', source, module)
            self.assertNotIn('resource "aws_ecs_service"', source, module)

    def test_images_are_immutable(self):
        self.assertIn('image_tag_mutability = "IMMUTABLE"', tf("ecr"))

    def test_the_proxy_refuses_the_rds_master_secret_and_requires_tls(self):
        proxy = tf("rds_proxy")
        self.assertIn("rds_master_secret_arn_guard", proxy)
        self.assertIn("require_tls            = true", proxy)

    def test_blob_bucket_denies_deletes_and_plain_http(self):
        data = tf("core_data")
        self.assertIn("DenyBlobDeletion", data)
        self.assertIn("s3:DeleteObjectVersion", data)
        self.assertIn("DenyInsecureTransport", data)

    def test_every_consumer_queue_has_a_dead_letter_queue_and_an_alarm(self):
        data = tf("core_data")
        self.assertIn("redrive_policy", data)
        self.assertIn("dlq_not_empty", data)

    def test_task_statements_carry_no_kms_secrets_or_delete_actions(self):
        outputs = normalized(tf("core_data", "outputs.tf"))
        statements = outputs.split('output "task_statements"', 1)[1]
        for forbidden in ("kms:", "secretsmanager:", "s3:Delete", "iam:", "sts:"):
            self.assertNotIn(forbidden, statements)
        self.assertIn("sns:Publish", statements)

    def test_scheduler_passes_only_listed_roles_to_ecs(self):
        scheduled = tf("scheduled_task")
        self.assertIn("iam:PassedToService", scheduled)
        self.assertIn("assign_public_ip = false", scheduled)

    def test_alarms_do_not_create_a_log_group(self):
        self.assertNotIn("aws_cloudwatch_log_group", tf("core_alarms"))


class EnvironmentWiringTests(unittest.TestCase):
    def test_both_environments_wire_the_repository_and_the_data_plane(self):
        for environment in ("staging", "prod"):
            main = (ROOT / "terraform" / "envs" / environment / "main.tf").read_text(encoding="utf-8")
            for module in ("core_ecr", "core_data"):
                with self.subTest(environment=environment, module=module):
                    self.assertIn(f'module "{module}"', main)

    def test_the_ci_runs_the_new_module_tests(self):
        flat = normalized((ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8"))
        # PR #25 quotes the argument so PowerShell expands $module; the unquoted form is the bug it fixed.
        self.assertIn('terraform "-chdir=terraform/modules/$module" test', flat)
        self.assertNotIn("terraform -chdir=terraform/modules/$module test", flat)
        for module in NEW_MODULES:
            self.assertIn(f'"{module}"', flat, module)


class DocumentationTests(unittest.TestCase):
    def test_adr_0005_is_accepted_defers_to_adr_0003_and_admits_nothing_is_applied(self):
        adr = (ROOT / "docs" / "adr" / "0005-agent-core-escalado-fase-0-1.md").read_text(encoding="utf-8")
        self.assertIn("Status: **Accepted**", adr)
        self.assertIn("changes none of its", normalized(adr))
        self.assertIn("nothing is applied", adr)
        self.assertIn("Not covered", adr)


if __name__ == "__main__":
    unittest.main()
