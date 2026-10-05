"""ADR 0009: Terraform-generated credentials and the engine wiring of the shared Core (agent-core serve)."""

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(*parts):
    return ROOT.joinpath(*parts).read_text(encoding="utf-8")


GENERATED = read("terraform", "modules", "hackathon_data", "generated.tf")
SCRIPT = read("scripts", "aws-prod.ps1")


class GeneratedCredentialsTest(unittest.TestCase):
    def test_engine_credentials_are_generated_by_terraform(self):
        for key in (
            '"PULSO__PULSO_LLM_GATEWAY_KEY"',
            '"PULSO__PULSO_SERVICE_SEED_HEX"',
            '"FILES__AGENT__STAFF_KEYS"',
            '"FILES__AGENT__IDENTITY_KEYS"',
            '"FILES__SUPPORT__AGENT_PRIVATE_KEYS"',
            '"AGENT__AGENTCORE_LLM_GATEWAY_TOKEN"',
        ):
            self.assertIn(key, GENERATED)
        self.assertIn('resource "tls_private_key" "agent"', GENERATED)
        self.assertIn('resource "random_password" "gateway_token"', GENERATED)

    def test_only_public_values_are_plain_outputs(self):
        outputs = read("terraform", "modules", "hackathon_data", "outputs.tf")
        self.assertIn("sensitive   = true", outputs)
        self.assertNotRegex(outputs, r"output \"[a-z_]*(seed|token|private)[a-z_]*\"")

    def test_engine_addresses_are_ip_literals_from_the_host(self):
        main = read("terraform", "envs", "hackathon", "main.tf")
        self.assertIn("module.compute_core.private_ip", main)
        self.assertNotIn("PULSO_LLM_GATEWAY_ADDR: core.", read("deploy", "hackathon", "engine", "compose.yaml"))


class ReseedTest(unittest.TestCase):
    def test_seed_secret_keys_is_merge_only(self):
        self.assertIn("function Invoke-SeedSecretKeys", SCRIPT)
        self.assertIn("'seed-secret-keys'", SCRIPT)
        self.assertIn("never overwritten", SCRIPT)

    def test_adr_is_indexed_and_states_the_trust_grant(self):
        self.assertIn("0009-shared-core-is-agentcore-serve.md", read("docs", "decisions.md"))
        adr = read("docs", "adr", "0009-shared-core-is-agentcore-serve.md")
        self.assertIn("Trust implication", adr)
        self.assertIn("every host", adr.lower().replace("all three host roles", "every host"))


if __name__ == "__main__":
    unittest.main()
