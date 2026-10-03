"""Structural contract: the docs agree that this repository also deploys the LLM gateway (ADR 0004).

No AWS credentials or Terraform binary are needed; this only pins what the documentation claims.
"""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class LlmGatewayScopeContractTests(unittest.TestCase):
    def test_adr_0004_is_accepted_and_states_what_is_implemented(self):
        adr = read("docs/adr/0004-llm-gateway-workload.md")
        self.assertIn("Status: **Accepted**", adr)
        self.assertIn("## Implementation status", adr)
        self.assertIn("Nothing for the LLM gateway is declared in Terraform", adr)

    def test_adr_0004_pins_the_interface_contract(self):
        adr = read("docs/adr/0004-llm-gateway-workload.md")
        for needle in (
            "GATEWAY_CONSUMERS",
            "LLM_ENDPOINTS",
            "/healthz",
            "idle timeout",
            "immutable digest",
            "stateless",
        ):
            self.assertIn(needle, adr)

    def test_scope_documents_name_the_gateway_as_a_workload(self):
        for relative in ("AGENTS.md", "CONTEXT.md", "README.md"):
            text = read(relative)
            self.assertIn("ADR 0004", text, relative)
            self.assertIn("llm-gateway", text, relative)
        agents = read("AGENTS.md")
        self.assertNotIn("or an LLM gateway.", agents)

    def test_readme_does_not_claim_the_gateway_is_deployed(self):
        self.assertIn("not declared in Terraform", read("README.md").split("## LLM gateway workload", 1)[1])

    def test_deployment_status_lists_the_gateway_as_not_declared(self):
        status = read("docs/architecture/deployment-status.md")
        self.assertIn("| LLM gateway workload |", status)
        self.assertIn("## LLM gateway workload", status)

    def test_open_gaps_track_the_gateway_prerequisites(self):
        gaps = read("docs/gaps/OPEN_GAPS.md")
        for needle in (
            "LLM gateway workload declaration",
            "LLM gateway service-to-service ingress",
            "LLM gateway secrets",
        ):
            self.assertIn(needle, gaps)

    def test_adr_0003_points_to_the_pending_change(self):
        adr = read("docs/adr/0003-agent-core-workload.md")
        self.assertIn("ADR 0004", adr)


if __name__ == "__main__":
    unittest.main()
