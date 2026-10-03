"""Structural contract for the engine platform and shared endpoint modules (no AWS credentials, no Terraform).

Pins what must stay true without a plan: opt-in gating (zero diff when disabled), no duplicated shared foundation,
no secret values, no load balancer or WAF, and the explicit non-goals of the engine platform.
"""

from pathlib import Path
import re
import unittest


TF = Path(__file__).resolve().parents[1] / "terraform"
MODULES = ("engine_platform", "core_vpc_endpoints")
FORBIDDEN_TYPES = (
    "aws_vpc",
    "aws_subnet",
    "aws_nat_gateway",
    "aws_internet_gateway",
    "aws_lb",
    "aws_alb",
    "aws_wafv2_web_acl",
    "aws_ecs_cluster",
    "aws_db_instance",
    "aws_s3_bucket",
    "aws_kms_key",
    "aws_secretsmanager_secret_version",
)
RESOURCE = re.compile(r'^resource "([a-z0-9_]+)" "([a-z0-9_]+)" \{\n(.*?)^\}', re.S | re.M)
GATE = re.compile(r"var\.enabled|local\.active|local\.entries")


def source(module: str) -> str:
    return (TF / "modules" / module / "main.tf").read_text(encoding="utf-8")


class EngineModuleContractTests(unittest.TestCase):
    def test_no_shared_foundation_is_duplicated(self):
        for module in MODULES:
            types = {m.group(1) for m in RESOURCE.finditer(source(module))}
            self.assertFalse(types & set(FORBIDDEN_TYPES), (module, types & set(FORBIDDEN_TYPES)))

    def test_every_resource_is_gated_by_the_enabled_switch(self):
        for module in MODULES:
            for m in RESOURCE.finditer(source(module)):
                self.assertRegex(m.group(3), GATE, f"{module}.{m.group(1)}.{m.group(2)} must be gated by enabled")

    def test_engine_platform_declares_exactly_the_agreed_workloads(self):
        text = source("engine_platform")
        for name in ("control-api", "worker", "migrate", "sandbox-lab"):
            self.assertIn(f'"{name}"', text)
        for refused in ("human-issuer", "console"):
            self.assertNotIn(f'"{refused}" = {{', text)

    def test_engine_platform_never_opens_the_internet(self):
        self.assertNotIn("0.0.0.0/0", source("engine_platform"))

    def test_roots_default_both_switches_to_off(self):
        for env in ("staging", "prod"):
            variables = (TF / "envs" / env / "variables.tf").read_text(encoding="utf-8")
            for name in ("engine_platform_enabled", "private_endpoints_enabled"):
                block = re.search(rf'variable "{name}" \{{(.*?)\n\}}', variables, re.S)
                self.assertIsNotNone(block, (env, name))
                self.assertIn("default     = false", block.group(1), (env, name))

    def test_existing_engine_service_is_not_replaced(self):
        for env in ("staging", "prod"):
            main = (TF / "envs" / env / "main.tf").read_text(encoding="utf-8")
            self.assertIn('module "compute"', main)
            self.assertIn('module "engine_platform"', main)


if __name__ == "__main__":
    unittest.main()
