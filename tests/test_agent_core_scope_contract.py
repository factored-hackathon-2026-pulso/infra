"""Structural contract: the docs agree that this repository also deploys Agent Core (ADR 0003).

No AWS credentials or Terraform binary are needed; this only pins what the documentation claims.
"""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class AgentCoreScopeContractTests(unittest.TestCase):
    def test_adr_0003_is_accepted_and_states_what_is_implemented(self):
        adr = read("docs/adr/0003-agent-core-workload.md")
        self.assertIn("Status: **Accepted**", adr)
        self.assertNotIn("Status: **Proposed**", adr)
        self.assertIn("## Implementation status", adr)

    def test_scope_documents_no_longer_call_agent_core_external(self):
        for relative in ("AGENTS.md", "CONTEXT.md"):
            text = read(relative)
            self.assertIn("ADR 0003", text, relative)
            self.assertNotIn("Agent Core and model routing are external", text, relative)
            self.assertNotIn("not its local environment, Agent Core or an LLM gateway", text, relative)

    def test_readme_points_to_the_agent_core_workload_without_claiming_it_is_deployed(self):
        readme = read("README.md")
        self.assertIn("Agent Core", readme)
        self.assertIn("ADR 0003", readme)
        self.assertIn("not declared in Terraform", readme)

    def test_deployment_status_lists_the_agent_core_workload_as_not_declared(self):
        status = read("docs/architecture/deployment-status.md")
        self.assertIn("| Agent Core workload |", status)
        self.assertIn("## Agent Core workload", status)

    def test_open_gaps_track_the_agent_core_prerequisites(self):
        gaps = read("docs/gaps/OPEN_GAPS.md")
        for needle in ("Agent Core workload declaration", "JEV data residency", "Agent Core runtime secrets"):
            self.assertIn(needle, gaps)


def publication_paragraph(adr: str) -> str:
    return adr.split("**Publication.**", 1)[1].split("\n\n", 1)[0]


class AgentCoreDeliveryContractTests(unittest.TestCase):
    """What agent-core delivered for the infra requests (pulso-factored/agent-core#25) and what stays open."""

    def test_adr_contract_records_the_delivered_interface(self):
        adr = read("docs/adr/0003-agent-core-workload.md")
        for needle in (
            "GET /version",
            "AGENTCORE_GIT_SHA",
            "--keys-reload-seconds",
            "exporter",
            "/v1/export",
            "ADR 0022",
            "expand-only",
        ):
            self.assertIn(needle, adr)

    def test_adr_publication_path_is_ecr_plus_oidc_push_role(self):
        adr = read("docs/adr/0003-agent-core-workload.md")
        self.assertIn("**Publication.**", adr)
        paragraph = publication_paragraph(adr)
        self.assertIn("OIDC", paragraph)
        self.assertIn("ECR", paragraph)

    def test_status_documents_stop_claiming_agent_core_has_no_dockerfile(self):
        for relative in ("docs/architecture/deployment-status.md", "docs/adr/0003-agent-core-workload.md"):
            text = " ".join(read(relative).split())
            self.assertNotIn("no Dockerfile or image CI yet", text, relative)
            self.assertNotIn("a Dockerfile and an image CI that publishes a digest", text, relative)

    def test_open_gaps_track_the_new_prerequisites(self):
        gaps = read("docs/gaps/OPEN_GAPS.md")
        for needle in (
            "Agent Core image publication",
            "Agent Core export credential",
            "Agent Core schema compatibility smoke",
        ):
            self.assertIn(needle, gaps)

    def test_journal_records_the_slice(self):
        journal = read("docs/journal/0012-i12-agent-core-delivery-contract.md")
        self.assertIn("## Verification", journal)
        self.assertIn("## Not done", journal)


if __name__ == "__main__":
    unittest.main()
