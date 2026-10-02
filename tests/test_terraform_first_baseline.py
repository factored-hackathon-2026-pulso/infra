"""Structural contracts for Infra's Terraform/AWS ownership boundary.

These tests intentionally do not need AWS credentials or a Terraform binary. The
CI workflow performs Terraform's own fmt/validate check on an ephemeral runner.
"""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
TERRAFORM = ROOT / "terraform"


class TerraformFirstBaselineContractTests(unittest.TestCase):
    def test_expected_environment_roots_exist_with_provider_and_backend_contracts(self):
        for environment in ("staging", "prod"):
            root = TERRAFORM / "envs" / environment
            self.assertTrue((root / "main.tf").is_file(), environment)
            self.assertTrue((root / "versions.tf").is_file(), environment)
            self.assertTrue((root / "variables.tf").is_file(), environment)
            self.assertTrue((root / "backend.hcl.example").is_file(), environment)
            self.assertTrue((root / ".terraform.lock.hcl").is_file(), environment)

            lockfile = (root / ".terraform.lock.hcl").read_text(encoding="utf-8")
            self.assertGreaterEqual(
                lockfile.count('"h1:'),
                2,
                f"{environment} lock must include Windows and Linux provider checksums",
            )

            versions = (root / "versions.tf").read_text(encoding="utf-8")
            self.assertIn('required_version = ">= 1.10.0"', versions)
            self.assertRegex(versions, r'source\s*=\s*"hashicorp/aws"')
            self.assertIn('backend "s3" {}', versions)
            self.assertNotIn("access_key", versions.lower())

            backend = (root / "backend.hcl.example").read_text(encoding="utf-8")
            self.assertIn("bucket", backend)
            self.assertIn("key", backend)
            self.assertIn("region", backend)
            self.assertIn("use_lockfile", backend)
            self.assertNotIn("secret", backend.lower())

    def test_native_s3_lockfile_contract_requires_a_compatible_terraform_ci_version(self):
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        self.assertIn("terraform_version: 1.10.5", workflow)
        for environment in ("staging", "prod"):
            backend = (TERRAFORM / "envs" / environment / "backend.hcl.example").read_text(
                encoding="utf-8"
            )
            versions = (TERRAFORM / "envs" / environment / "versions.tf").read_text(
                encoding="utf-8"
            )
            if "use_lockfile" in backend:
                self.assertIn('required_version = ">= 1.10.0"', versions)

    def test_aws_deployment_modules_have_explicit_interfaces(self):
        expected_modules = {
            "network": ("vpc_cidr", "public_subnet_cidrs", "private_subnet_cidrs", "nat_strategy"),
            "security": ("vpc_id",),
            "identity": (
                "github_oidc_provider_arn",
                "github_subjects",
                "runtime_secret_arn",
                "source_bucket_arn",
                "artifact_bucket_arn",
                "kms_key_arn",
            ),
            "compute": ("image_digest", "private_subnet_ids", "task_role_arn"),
            "storage": ("artifact_bucket_name", "source_bucket_name"),
            "database": ("postgres_engine_version", "private_subnet_ids"),
            "secrets": ("secret_name_prefix", "kms_key_arn"),
            "observability": ("alarm_email", "service_name", "cluster_name"),
        }
        for module, expected_variables in expected_modules.items():
            variables = (TERRAFORM / "modules" / module / "variables.tf").read_text(
                encoding="utf-8"
            )
            for variable in expected_variables:
                self.assertIn(f'variable "{variable}"', variables, module)

    def test_ci_validates_terraform_without_apply_or_engine_test_workflow_reuse(self):
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        self.assertIn("terraform fmt -check -recursive", workflow)
        self.assertRegex(workflow, r"init\s+-backend=false\s+-input=false\s+-lockfile=readonly")
        self.assertRegex(workflow, r"\bvalidate\b")
        self.assertIn("hashicorp/setup-terraform@b9cd54a3c349d3f38e8881555d616ced269862dd", workflow)
        self.assertNotIn("terraform apply", workflow)
        self.assertNotIn("postgres-integration.yml", workflow)

    def test_infra_has_no_executable_engine_test_workflow_or_cross_repo_caller(self):
        workflow_dir = ROOT / ".github" / "workflows"
        workflow_text = "\n".join(
            path.read_text(encoding="utf-8") for path in workflow_dir.glob("*.yml")
        ).lower()
        self.assertNotIn("workflow_call:", workflow_text)
        self.assertNotIn("improvement-engine-core", workflow_text)
        self.assertNotIn("pulso-factored/improvement-engine", workflow_text)

    def test_legacy_local_assets_are_explicitly_non_authoritative(self):
        migration = (ROOT / "docs" / "migration" / "i04-legacy-local-assets.md").read_text(
            encoding="utf-8"
        )
        self.assertIn("improvement-engine", migration)
        self.assertIn("not authoritative", migration)
        self.assertIn("Do not add", migration)
        for target in (
            "local/preflight.stack.json",
            "local/preflight.tools.json",
            "scripts/doctor.py",
            "tests/test_doctor.py",
        ):
            self.assertFalse((ROOT / target).exists(), target)


if __name__ == "__main__":
    unittest.main()
