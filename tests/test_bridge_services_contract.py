"""Structural contract for the bridge_services module (the Core bridge runtime, Core exporter and platform exporter).

Pins what must stay true without a plan or credentials: opt-in gating, no duplicated shared foundation, names-only
secrets, no demo flag or provider/JEV material, no internet egress, and that the three services are wired from the
environment roots in their own files (never in main.tf / variables.tf).
"""

from pathlib import Path
import re
import unittest


TF = Path(__file__).resolve().parents[1] / "terraform"
RESOURCE = re.compile(r'^resource "([a-z0-9_]+)" "([a-z0-9_]+)" \{\n(.*?)^\}', re.S | re.M)
GATE = re.compile(r"var\.enabled|local\.active|local\.entries|local\.db_rules|local\.engine_callers|local\.on\[")
FORBIDDEN_TYPES = (
    "aws_vpc", "aws_subnet", "aws_nat_gateway", "aws_internet_gateway", "aws_lb", "aws_alb", "aws_wafv2_web_acl",
    "aws_ecs_cluster", "aws_db_instance", "aws_s3_bucket", "aws_kms_key", "aws_secretsmanager_secret_version",
    "aws_ecr_repository", "aws_service_discovery_private_dns_namespace", "aws_ecs_task_definition",
)
FORBIDDEN_NAMES = ("AGENTCORE_JEV_API_KEY", "LLM_ENDPOINTS", "PULSO_SERVICE_TOKEN")


def module_source() -> str:
    return (TF / "modules" / "bridge_services" / "main.tf").read_text(encoding="utf-8")


class BridgeServicesModuleContractTests(unittest.TestCase):
    def test_no_shared_foundation_is_duplicated(self):
        types = {m.group(1) for m in RESOURCE.finditer(module_source())}
        self.assertFalse(types & set(FORBIDDEN_TYPES), types & set(FORBIDDEN_TYPES))

    def test_every_resource_is_gated_by_the_enabled_switch(self):
        for m in RESOURCE.finditer(module_source()):
            self.assertRegex(m.group(3), GATE, f"{m.group(1)}.{m.group(2)} must be gated by enabled")

    def test_enabled_defaults_to_false(self):
        block = re.search(r'variable "enabled" \{(.*?)\n\}', module_source(), re.S)
        self.assertIsNotNone(block)
        self.assertIn("default = false", block.group(1))

    def test_no_internet_egress_and_no_forbidden_variables(self):
        text = module_source()
        self.assertNotIn("0.0.0.0/0", text)
        self.assertNotIn("AGENTCORE_ALLOW_DEMO", text)
        for name in FORBIDDEN_NAMES:
            self.assertNotIn(name, text, name)

    def test_the_three_services_reuse_the_shared_workload_modules(self):
        text = module_source()
        self.assertIn('source   = "../workload"', text)
        self.assertIn('source   = "../workload_iam"', text)
        for name in ("core-runtime", "core-exporter", "platform-exporter"):
            self.assertIn(f'"{name}"', text)
        self.assertRegex(text, r"task_statements\s*=\s*\[\]")

    def test_secrets_are_names_only_and_the_core_layout_is_consumed_not_created(self):
        text = module_source()
        self.assertNotIn("secret_string", text)
        for owned in ("core/bridge-signers", "core/exporter-keys", "platform-exporter/db-readonly", "platform-exporter/keys"):
            self.assertIn(owned, text)
        for consumed in ("core/db-app", "core/db-exporter", "core/identity-keys", "core/llm-gateway-token"):
            self.assertNotIn(f'/{consumed}', text)

    def test_roots_wire_it_in_own_files_with_every_switch_off(self):
        for env in ("staging", "prod"):
            wiring = (TF / "envs" / env / "bridge_services.tf").read_text(encoding="utf-8")
            variables = (TF / "envs" / env / "bridge_services_variables.tf").read_text(encoding="utf-8")
            self.assertIn('module "bridge_services"', wiring)
            self.assertIn('source   = "../../modules/ecr"', wiring)
            self.assertNotIn("aws_ecr_repository", wiring)
            for name in ("bridge_services_enabled", "bridge_ecr_enabled"):
                block = re.search(rf'variable "{name}" \{{(.*?)\n\}}', variables, re.S)
                self.assertIsNotNone(block, (env, name))
                self.assertIn("default     = false", block.group(1), (env, name))
            for name in ("main.tf", "variables.tf", "engine_platform.tf", "engine_platform_variables.tf"):
                text = (TF / "envs" / env / name).read_text(encoding="utf-8")
                self.assertNotRegex(text, r"bridge_services|bridge_ecr", (env, name))

    def test_roots_refuse_overlapping_engine_wiring(self):
        for env in ("staging", "prod"):
            wiring = (TF / "envs" / env / "bridge_services.tf").read_text(encoding="utf-8")
            self.assertIn("engine_platform_core_runtime_security_group_ids", wiring)
            self.assertIn("engine_platform_core_callback_security_group_ids", wiring)
            self.assertIn('check "bridge_services_owns_the_engine_flows"', wiring)

    def test_workload_volumes_are_additive_and_task_scoped(self):
        text = (TF / "modules" / "workload" / "main.tf").read_text(encoding="utf-8")
        self.assertIn("readonlyRootFilesystem", text)
        self.assertNotIn("host_path", text)
        self.assertNotIn("efs_volume_configuration", text)


if __name__ == "__main__":
    unittest.main()
