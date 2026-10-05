"""ADR 0009: the shared Core is agent-core's own `agentcore serve` image, not the composed core-bridge runtime."""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(*parts):
    return (ROOT.joinpath(*parts)).read_text(encoding="utf-8")


CORE = read("deploy", "hackathon", "core", "compose.yaml")
PLATFORM = read("deploy", "hackathon", "platform", "compose.yaml")
ENGINE = read("deploy", "hackathon", "engine", "compose.yaml")
GENERATED = read("terraform", "modules", "hackathon_data", "generated.tf")
SCRIPT = read("scripts", "aws-prod.ps1")


class CoreComposeTest(unittest.TestCase):
    def test_runs_agentcore_serve_with_registry_api_and_both_key_files(self):
        for needle in ("- serve", "--registry-api", "--identity-keys", "--staff-keys", "agent_core.adapters.tools:http_tool_executor"):
            self.assertIn(needle, CORE)

    def test_no_composed_runtime_no_exporter_no_demo(self):
        self.assertNotRegex(CORE, r'command: \["(runtime|exporter)"\]')
        self.assertNotIn("core-exporter", CORE)
        self.assertNotRegex(CORE, r"ALLOW_DEMO|testing\.")

    def test_gateway_is_published_for_the_engine_host(self):
        self.assertRegex(CORE, r'llm-gateway:\n(?:.*\n)*?    ports:\n      - "8080:8080"')

    def test_platform_and_engine_reach_the_core_and_the_gateway(self):
        self.assertIn("CC_AGENT_CORE_URL: http://core.", PLATFORM)
        self.assertIn("CC_AGENT_KEYS_FILE", PLATFORM)
        self.assertIn("PULSO_LLM_GATEWAY_ADDR: core.", ENGINE)


class GeneratedCredentialsTest(unittest.TestCase):
    def test_engine_credentials_are_generated_by_terraform(self):
        for key in (
            '"PULSO__PULSO_LLM_GATEWAY_TOKEN"',
            '"CORE__AGENTCORE_LLM_GATEWAY_TOKEN"',
            '"PULSO__PULSO_CORE_SIGNING_SEED"',
            '"CORE__STAFF_KEYS_JSON"',
            '"CORE__IDENTITY_KEYS_JSON"',
        ):
            self.assertIn(key, GENERATED)
        self.assertIn('resource "tls_private_key" "agent"', GENERATED)
        self.assertIn('resource "random_password" "gateway_token"', GENERATED)

    def test_no_secret_value_is_an_output(self):
        outputs = read("terraform", "modules", "hackathon_data", "outputs.tf")
        self.assertNotRegex(outputs, r"output \"[a-z_]*(seed|token|private)[a-z_]*\"")


class ImageBuildTest(unittest.TestCase):
    def test_core_image_comes_from_agent_cores_own_dockerfile(self):
        self.assertNotIn("core-bridge", SCRIPT.replace("core-bridge/Dockerfile reads", ""))
        self.assertRegex(SCRIPT, r"'core-runtime'\s+= @\{ Dockerfile = 'Dockerfile'; Context = '\.'")
        self.assertIn("GIT_SHA=", SCRIPT)

    def test_adr_is_indexed(self):
        self.assertIn("0009-shared-core-is-agentcore-serve.md", read("docs", "decisions.md"))
        self.assertTrue(re.search(r"Trust implication", read("docs", "adr", "0009-shared-core-is-agentcore-serve.md")))


if __name__ == "__main__":
    unittest.main()
