"""Keep the reusable PostgreSQL CI boundary explicit and non-secret."""

from pathlib import Path
import unittest


WORKFLOW = (
    Path(__file__).resolve().parents[1]
    / ".github"
    / "workflows"
    / "postgres-integration.yml"
)


class PostgresIntegrationWorkflowContractTest(unittest.TestCase):
    def test_reusable_workflow_runs_the_explicit_artifact_migration_gate(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        normalized_workflow = " ".join(workflow.split())

        self.assertIn("workflow_call:", workflow)
        self.assertIn("runs-on: ubuntu-latest", workflow)
        self.assertIn("timeout-minutes: 10", workflow)
        self.assertIn("contents: read", workflow)
        self.assertIn("postgres:17-alpine@sha256:", workflow)
        self.assertIn("POSTGRES_DB: pulso_ci", workflow)
        self.assertIn("POSTGRES_USER: pulso_ci", workflow)
        self.assertIn("health-cmd", workflow)
        self.assertIn("PULSO_ALLOW_DESTRUCTIVE_TEST_DB: \"1\"", workflow)
        self.assertIn("PULSO_TEST_POSTGRES_URL:", workflow)
        self.assertIn(
            "cargo +1.98.1 test --locked --package improvement-engine-core "
            "--test postgres_artifact_migration -- --ignored",
            normalized_workflow,
        )

    def test_workflow_has_no_secret_or_production_configuration_boundary(self):
        workflow = WORKFLOW.read_text(encoding="utf-8").lower()

        self.assertNotIn("secrets:", workflow)
        self.assertNotIn("inputs:", workflow)
        self.assertNotIn("continue-on-error: true", workflow)
        self.assertNotIn("|| true", workflow)
        self.assertNotIn("aws_", workflow)
        self.assertNotIn("terraform", workflow)
        self.assertNotIn("production", workflow)


if __name__ == "__main__":
    unittest.main()
