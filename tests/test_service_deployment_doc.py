"""docs/service-deployment.md (for the OTHER teams) must match the script, the modules and the bundles.

Generic checks (subcommands, flags, `var.x`, `modules/x`, links, no account ids) already run over every doc in
tests/test_docs_consistency.py; these add the things only this doc promises.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / "docs" / "service-deployment.md"
SCRIPT = (ROOT / "scripts" / "aws-prod.ps1").read_text(encoding="utf-8")
ENV = ROOT / "terraform" / "envs" / "hackathon"


def doc() -> str:
    return DOC.read_text(encoding="utf-8")


def script_services() -> list[str]:
    block = re.search(r"\$script:Services = \[ordered\]@\{(.*?)^\}", SCRIPT, re.S | re.M).group(1)
    return re.findall(r"^\s*'([a-z-]+)'\s*=", block, re.M)


class ServiceDeploymentDoc(unittest.TestCase):
    def test_doc_exists_and_is_in_the_index(self):
        self.assertTrue(DOC.exists())
        self.assertIn("service-deployment.md", (ROOT / "docs" / "README.md").read_text(encoding="utf-8"))

    def test_every_script_service_has_its_own_section(self):
        headings = "\n".join(l for l in doc().splitlines() if l.startswith("#"))
        for name in script_services():
            self.assertIn(name, headings, f"no heading for service {name}")
        self.assertGreaterEqual(len(script_services()), 6)

    def test_services_match_the_ecr_repositories_of_the_bootstrap(self):
        variables = (ROOT / "terraform" / "bootstrap" / "variables.tf").read_text(encoding="utf-8")
        default = re.search(r'variable "ecr_repositories".*?default\s*=\s*\[(.*?)\]', variables, re.S).group(1)
        repos = set(re.findall(r'"([a-z-]+)"', default))
        self.assertEqual(repos, set(script_services()))

    def test_every_images_flag_and_deploy_flag_is_explained(self):
        text = doc()
        for flag in ("-Service", "-SourceDir", "-Dockerfile", "-AgentCoreDir", "-BuildArg", "-MirrorImage", "-Digest",
                     "-FromBuild", "-Wait", "-Rollback", "-Yes", "-Stage"):
            self.assertIn(flag, text, flag)
        self.assertRegex(text, r"aws-prod\.ps1\s+images\b")
        self.assertRegex(text, r"aws-prod\.ps1\s+deploy\b")

    def test_image_keys_ssm_names_and_documents_are_documented(self):
        text = doc()
        for key in ("core", "gateway", "support_api", "support_web", "pulso", "proxy"):
            self.assertIn(f"/images/{key}", text, key)
        for w in ("core", "platform", "engine"):
            self.assertIn(f"pulso-deploy-{w}", text)
        self.assertIn("/pulso/<workload>/images/<key>", text)

    def test_deployer_policy_outputs_exist_and_are_named(self):
        outputs = (ENV / "outputs.tf").read_text(encoding="utf-8")
        for name in ("deployer_policy_json_core", "deployer_policy_json_platform", "deployer_policy_json_engine"):
            self.assertIn(f'output "{name}"', outputs)
            self.assertIn(name, doc())

    def test_introduced_variables_and_modules_are_documented(self):
        text = doc()
        variables = (ENV / "variables.tf").read_text(encoding="utf-8")
        for name in ("enable_image_builder", "image_builder_compute_type", "ecr_repository_prefix"):
            self.assertIn(f'variable "{name}"', variables)
            self.assertIn(name, text)
        for module in ("image_builder", "deployer_policies", "hackathon_compute"):
            self.assertTrue((ROOT / "terraform" / "modules" / module).is_dir())
            self.assertIn(f"modules/{module}", text)

    def test_s3_prefixes_in_the_doc_are_the_ones_the_lifecycle_expires(self):
        data = (ROOT / "terraform" / "modules" / "hackathon_data" / "main.tf").read_text(encoding="utf-8")
        for prefix in ("engine/build-src/", "engine/build-out/"):
            self.assertIn(prefix, doc())
            self.assertIn(prefix, data)

    def test_secret_keys_named_in_the_doc_are_in_secrets_keys(self):
        keys = (ROOT / "docs" / "secrets-keys.md").read_text(encoding="utf-8")
        for key in set(re.findall(r"\b(?:CORE|GATEWAY|SUPPORT|PULSO)__[A-Z0-9_]+\b", doc())):
            self.assertIn(key, keys, key)

    def test_health_endpoints_in_the_doc_exist_in_the_bundles(self):
        text = doc()
        self.assertIn("/readyz", text)
        self.assertIn("/healthz", text)
        self.assertIn("pulso healthcheck", text)
        bundles = "".join(p.read_text(encoding="utf-8") for p in (ROOT / "deploy" / "hackathon").rglob("*") if p.is_file() and "__pycache__" not in p.parts)
        for token in ("/readyz", "/healthz", "pulso\", \"healthcheck"):
            self.assertIn(token, bundles)

    def test_required_sections_exist(self):
        headings = [l.lower() for l in doc().splitlines() if l.startswith("#")]
        for needle in ("owns", "iam", "build", "deploy", "verify", "roll back", "config", "infra change", "worked example", "troubleshooting"):
            self.assertTrue(any(needle in h for h in headings), f"missing section about {needle}")

    def test_doc_names_the_single_instance_sqlite_caveat_and_vite_api_url(self):
        text = doc()
        self.assertIn("SQLite", text)
        self.assertIn("VITE_API_URL", text)

    def test_doc_holds_no_secret_value_or_real_identifier(self):
        text = doc()
        self.assertNotRegex(text, r"AKIA[0-9A-Z]{16}")
        self.assertNotRegex(text, r"\b\d{12}\b(?<!000000000000)")


if __name__ == "__main__":
    unittest.main()
