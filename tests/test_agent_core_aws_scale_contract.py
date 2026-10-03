"""Structural contract for the Agent Core scale-out declaration (ADR 0005).

No AWS credentials or Terraform binary are needed; this pins the guards that Terraform source must keep and that
`terraform test` also exercises with mocked providers in CI.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
MODULES = ROOT / "terraform" / "modules"
NEW_MODULES = (
    "agent_core_network",
    "ecr",
    "rds_proxy",
    "agent_core_data",
    "agent_core_ingress",
    "agent_core_workload",
    "agent_core_observability",
)


def tf(module: str, name: str = "main.tf") -> str:
    return (MODULES / module / name).read_text(encoding="utf-8")


def normalized(text: str) -> str:
    return " ".join(text.split())


class AgentCoreScaleModulesTests(unittest.TestCase):
    def test_every_new_module_has_a_provider_pin_and_variables(self):
        for module in NEW_MODULES:
            with self.subTest(module=module):
                self.assertTrue((MODULES / module / "versions.tf").exists())
                self.assertTrue((MODULES / module / "variables.tf").exists())
                self.assertIn('variable "tags"', tf(module, "variables.tf"))

    def test_modules_with_guards_have_terraform_tests(self):
        for module in ("agent_core_network", "ecr", "rds_proxy", "agent_core_data", "agent_core_workload"):
            with self.subTest(module=module):
                self.assertTrue(list((MODULES / module).glob("*.tftest.hcl")))

    def test_ingress_is_internal_https_only_and_never_the_whole_internet(self):
        ingress = tf("agent_core_ingress")
        self.assertIn("internal                   = true", ingress)
        self.assertIn('protocol          = "HTTPS"', ingress)
        self.assertNotIn('port              = 80', ingress)
        self.assertIn('path                = "/healthz"', ingress)
        self.assertIn("c != \"0.0.0.0/0\"", tf("agent_core_network", "variables.tf"))

    def test_database_is_reachable_only_through_the_proxy(self):
        network = tf("agent_core_network")
        self.assertIn("database_from_proxy", network)
        self.assertNotIn("database_from_service", network)
        self.assertIn("require_tls            = true", tf("rds_proxy"))

    def test_the_proxy_refuses_the_rds_master_secret(self):
        self.assertIn("rds_master_secret_arn_guard", tf("rds_proxy"))
        self.assertIn("never the RDS master secret", tf("rds_proxy", "variables.tf"))

    def test_images_are_immutable_and_deployed_by_digest(self):
        self.assertIn('image_tag_mutability = "IMMUTABLE"', tf("ecr"))
        self.assertIn("@sha256:", tf("agent_core_workload", "variables.tf"))

    def test_blob_bucket_denies_deletes_and_plain_http(self):
        data = tf("agent_core_data")
        self.assertIn("DenyBlobDeletion", data)
        self.assertIn("s3:DeleteObjectVersion", data)
        self.assertIn("DenyInsecureTransport", data)

    def test_every_consumer_queue_has_a_dead_letter_queue_and_an_alarm(self):
        data = tf("agent_core_data")
        self.assertIn("redrive_policy", data)
        self.assertIn("dlq_not_empty", data)

    def test_the_task_role_cannot_read_secrets_and_cannot_delete_blobs(self):
        workload = normalized(tf("agent_core_workload"))
        task_policy = workload.split('resource "aws_iam_role_policy" "task"', 1)[1].split("# --- Task definitions", 1)[0]
        self.assertNotIn("secretsmanager", task_policy)
        self.assertNotIn("s3:Delete", task_policy)
        self.assertIn("sns:Publish", task_policy)

    def test_secrets_are_scoped_per_role_and_have_no_values_in_terraform(self):
        workload = tf("agent_core_workload")
        self.assertIn("secrets_by_role", workload)
        self.assertNotIn("aws_secretsmanager_secret_version", workload)
        for role in ("migrate", "sweep", "relay"):
            self.assertRegex(workload, rf'{role}\s*=\s*\["AGENTCORE_')

    def test_demo_mode_is_gated_to_prod(self):
        workload = tf("agent_core_workload")
        self.assertIn('!var.allow_demo || local.env == "prod"', workload)
        self.assertRegex(
            normalized(tf("agent_core_workload", "variables.tf")),
            r'variable "allow_demo" \{[^}]*default\s+= false',
        )

    def test_sweep_is_scheduled_and_the_relay_is_a_service(self):
        workload = tf("agent_core_workload")
        self.assertIn('resource "aws_scheduler_schedule" "sweep"', workload)
        self.assertIn('["sweep", "--once"]', workload)
        self.assertIn('resource "aws_ecs_service" "relay"', workload)

    def test_api_service_leaves_desired_count_to_autoscaling(self):
        workload = tf("agent_core_workload")
        self.assertIn("ignore_changes = [desired_count]", workload)
        self.assertIn("ECSServiceAverageCPUUtilization", workload)
        self.assertIn("ALBRequestCountPerTarget", workload)


class AgentCoreEnvironmentWiringTests(unittest.TestCase):
    def test_both_environments_wire_every_new_module(self):
        for environment in ("staging", "prod"):
            main = (ROOT / "terraform" / "envs" / environment / "main.tf").read_text(encoding="utf-8")
            for module in (
                "agent_core_network",
                "agent_core_ecr",
                "agent_core_database",
                "agent_core_proxy",
                "agent_core_data",
                "agent_core_ingress",
                "agent_core_workload",
                "agent_core_observability",
            ):
                with self.subTest(environment=environment, module=module):
                    self.assertIn(f'module "{module}"', main)

    def test_environments_do_not_default_to_running_tasks_or_demo_mode(self):
        for environment in ("staging", "prod"):
            variables = normalized(
                (ROOT / "terraform" / "envs" / environment / "variables.tf").read_text(encoding="utf-8")
            )
            self.assertRegex(variables, r'variable "agent_core_desired_count" \{ type = number default = 0 \}')
            self.assertRegex(variables, r'variable "agent_core_allow_demo" \{[^}]*default\s+= false')

    def test_agent_core_database_secret_is_not_the_master_secret(self):
        for environment in ("staging", "prod"):
            main = (ROOT / "terraform" / "envs" / environment / "main.tf").read_text(encoding="utf-8")
            self.assertRegex(
                main,
                r"rds_master_secret_arn_guard\s+=\s+module\.agent_core_database\.master_user_secret_arn",
            )

    def test_the_ci_runs_the_new_module_tests(self):
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        flat = normalized(workflow)
        self.assertIn("terraform -chdir=terraform/modules/$module test", flat)
        for module in ("agent_core_network", "ecr", "rds_proxy", "agent_core_data", "agent_core_workload"):
            self.assertIn(f'"{module}"', flat, module)


class AgentCoreScaleDocumentationTests(unittest.TestCase):
    def test_adr_0005_is_accepted_and_admits_nothing_is_applied(self):
        adr = (ROOT / "docs" / "adr" / "0005-agent-core-escalado-fase-0-1.md").read_text(encoding="utf-8")
        self.assertIn("Status: **Accepted**", adr)
        self.assertIn("creates no resources", adr)
        self.assertRegex(adr, re.compile(r"no apply", re.IGNORECASE))
        self.assertIn("Not covered", adr)


if __name__ == "__main__":
    unittest.main()
