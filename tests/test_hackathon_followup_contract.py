"""Hackathon deploy follow-up: build contexts, provider key names, set-secret and the state key stay consistent."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "scripts" / "aws-prod.ps1").read_text(encoding="utf-8")
ENV_MAIN = (ROOT / "terraform" / "envs" / "hackathon" / "main.tf").read_text(encoding="utf-8")
DATA_VARS = (ROOT / "terraform" / "modules" / "hackathon_data" / "variables.tf").read_text(encoding="utf-8")


def read(*parts):
    return (ROOT.joinpath(*parts)).read_text(encoding="utf-8")


class StateKeyTest(unittest.TestCase):
    def test_hackathon_state_key_is_the_same_everywhere(self):
        key = "pulso/prod/hackathon/terraform.tfstate"
        self.assertIn(key, SCRIPT)
        self.assertIn(key, read("terraform", "envs", "hackathon", "backend.hcl.example"))
        self.assertIn(key, read("docs", "modification-guide.md"))
        self.assertNotRegex(SCRIPT, r"pulso/prod/terraform\.tfstate")


class BuildContextTest(unittest.TestCase):
    def test_codebuild_projects_use_the_staged_contexts(self):
        for line in (
            'dockerfile = "core-bridge/Dockerfile", context_dir = "core-bridge", core_context_dir = "agent-core"',
            'dockerfile = "backend/Dockerfile", context_dir = "backend"',
            'dockerfile = "frontend/Dockerfile", context_dir = "frontend"',
        ):
            self.assertIn(line, ENV_MAIN)

    def test_docs_describe_backend_frontend_and_core_bridge(self):
        text = read("docs", "service-deployment.md")
        self.assertIn("backend/Dockerfile", text)
        self.assertIn("frontend/Dockerfile", text)
        self.assertIn("-ViteApiUrl", text)
        self.assertIn("context `core-bridge/`", text)
        self.assertIn("contracts", text)


class SecretsTest(unittest.TestCase):
    def test_openrouter_is_a_gateway_provider_key(self):
        self.assertIn('"OPENROUTER_API_KEY"', DATA_VARS)
        self.assertIn("GATEWAY__OPENROUTER_API_KEY", read("docs", "secrets-keys.md"))

    def test_model_is_not_configured_in_the_gateway(self):
        text = read("docs", "secrets-keys.md") + read("docs", "service-deployment.md")
        self.assertIn("deepseek/deepseek-v4.1-flash", text)
        self.assertRegex(text, r"caller profile")

    def test_set_secret_documented_and_has_no_value_parameter(self):
        text = read("docs", "secrets-keys.md")
        self.assertIn("aws-prod.ps1 set-secret", text)
        params = re.search(r"param\((.*?)\n\)\n", SCRIPT, re.S).group(1)
        for bad in ("Value", "SecretValue", "Password", "FromFile"):
            self.assertNotRegex(params, r"\$%s\b" % bad)
        self.assertNotIn("Write-Host $value", SCRIPT)


if __name__ == "__main__":
    unittest.main()
