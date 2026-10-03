"""Structural contract for the Agent Core image registry slice (ADR 0003 item 8).

Credential-free: it pins the Terraform graph and the documents, it does not prove anything exists in AWS.
"""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "terraform" / "modules" / "image_registry"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def module_source() -> str:
    return "\n".join(read(path) for path in sorted(MODULE.glob("*.tf")))


class ImageRegistryModuleTests(unittest.TestCase):
    def test_repository_is_immutable_scanned_and_lifecycle_managed(self):
        source = module_source()
        for needle in (
            'resource "aws_ecr_repository" "this"',
            'image_tag_mutability = "IMMUTABLE"',
            "scan_on_push = true",
            'resource "aws_ecr_lifecycle_policy" "this"',
        ):
            self.assertIn(needle, source)

    def test_publisher_role_is_oidc_only_pinned_and_gated(self):
        source = module_source()
        self.assertIn('resource "aws_iam_role" "publisher"', source)
        self.assertIn("sts:AssumeRoleWithWebIdentity", source)
        self.assertIn("token.actions.githubusercontent.com:sub", source)
        self.assertIn("StringEquals", source)
        self.assertNotIn("StringLike", source)
        self.assertIn('publisher_enabled = var.github_oidc_provider_arn != "" && length(var.publish_subjects) > 0', source)
        self.assertIn("count                = local.publisher_enabled ? 1 : 0", source)

    def test_publisher_cannot_pull_request_refs_or_wildcard_repositories(self):
        source = module_source()
        self.assertIn(":environment:", source)
        self.assertNotIn("refs/heads/", source)
        self.assertNotIn("pull_request", source)
        self.assertNotIn('"repo:*', source)

    def test_module_has_pinned_providers_lockfile_and_a_terraform_test(self):
        self.assertIn('required_version = ">= 1.10.0"', read(MODULE / "versions.tf"))
        self.assertIn('source  = "hashicorp/aws"', read(MODULE / "versions.tf"))
        self.assertTrue((MODULE / ".terraform.lock.hcl").is_file())
        tftest = read(MODULE / "image_registry.tftest.hcl")
        for run in (
            "repository_is_immutable_scanned_and_encrypted",
            "no_publisher_without_an_approved_oidc_provider",
            "publisher_trust_is_pinned_to_one_repository_and_branch",
            "publisher_can_only_push_to_this_repository",
        ):
            self.assertIn(f'run "{run}"', tftest)

    def test_ci_runs_the_module_tests_without_credentials(self):
        workflow = read(ROOT / ".github" / "workflows" / "ci.yml")
        self.assertIn(
            "terraform -chdir=terraform/modules/image_registry init -backend=false -input=false -lockfile=readonly",
            workflow,
        )
        self.assertIn("terraform -chdir=terraform/modules/image_registry test", workflow)


class ImageRegistryRootsTests(unittest.TestCase):
    def test_roots_gate_the_module_on_inputs_that_default_to_off(self):
        for environment in ("staging", "prod"):
            base = ROOT / "terraform" / "envs" / environment
            main = read(base / "main.tf")
            variables = read(base / "variables.tf")
            self.assertIn('module "agent_core_image_registry"', main, environment)
            self.assertRegex(main, r'count\s+= var\.agent_core_repository_name == "" \? 0 : 1')
            for name in (
                "agent_core_repository_name",
                "agent_core_publisher_oidc_provider_arn",
                "agent_core_publish_subjects",
            ):
                self.assertIn(f'variable "{name}"', variables, f"{environment}: {name}")
            self.assertIn("default", variables.split('variable "agent_core_repository_name"', 1)[1].split("}", 1)[0])


class ImageRegistryDocsTests(unittest.TestCase):
    def test_docs_state_declared_but_not_applied(self):
        adr = read(ROOT / "docs" / "adr" / "0003-agent-core-workload.md")
        self.assertIn("declared in `terraform/modules/image_registry`", adr)
        status = read(ROOT / "docs" / "architecture" / "deployment-status.md")
        self.assertIn("image_registry", status)
        self.assertIn("not applied", status)

    def test_identity_row_no_longer_claims_an_oidc_role_that_does_not_exist(self):
        status = read(ROOT / "docs" / "architecture" / "deployment-status.md")
        identity_row = [line for line in status.splitlines() if line.startswith("| Identity |")][0]
        self.assertNotIn("GitHub OIDC trust and separate", identity_row)

    def test_journal_records_the_slice(self):
        journal = read(ROOT / "docs" / "journal" / "0013-i13-agent-core-image-registry.md")
        self.assertIn("## Verification", journal)
        self.assertIn("## Not done", journal)


if __name__ == "__main__":
    unittest.main()
