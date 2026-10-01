"""Protect the infra repository's own portable CI gate."""

from pathlib import Path
import unittest


WORKFLOW = (
    Path(__file__).resolve().parents[1] / ".github" / "workflows" / "ci.yml"
)


class InfrastructureCiWorkflowContractTest(unittest.TestCase):
    def test_ci_runs_portable_contract_tests_on_prs_and_main_pushes(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        normalized_workflow = " ".join(workflow.split())

        self.assertIn("name: infrastructure-ci", workflow)
        self.assertIn("pull_request:", workflow)
        self.assertIn("push:", workflow)
        self.assertIn("branches: [main]", workflow)
        self.assertIn("os: [windows-latest, ubuntu-latest]", workflow)
        self.assertIn("python -m unittest discover -s tests -v", normalized_workflow)

    def test_ci_is_pinned_least_privilege_and_non_secret(self):
        workflow = WORKFLOW.read_text(encoding="utf-8").lower()

        self.assertIn("contents: read", workflow)
        self.assertIn("concurrency:", workflow)
        self.assertIn("cancel-in-progress: true", workflow)
        self.assertIn("actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertNotIn("secrets:", workflow)
        self.assertNotIn("${{ secrets.", workflow)
        self.assertNotIn("write-all", workflow)


if __name__ == "__main__":
    unittest.main()
