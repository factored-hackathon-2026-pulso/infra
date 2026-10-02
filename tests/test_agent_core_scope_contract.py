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


if __name__ == "__main__":
    unittest.main()
