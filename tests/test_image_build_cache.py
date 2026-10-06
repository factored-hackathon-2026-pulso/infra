"""The host image build must not reuse a stale uv wheel cache (agent-core ask A11, prod-like rehearsal 2026-10-05)."""

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class HostBuildIsNotCached(unittest.TestCase):
    def test_buildx_on_the_core_host_passes_no_cache(self):
        text = (ROOT / "scripts" / "aws-prod.ps1").read_text(encoding="utf-8")
        self.assertIn("docker buildx build --pull --no-cache --load", text)

    def test_the_rehearsal_builds_the_agent_without_cache(self):
        self.assertIn('args.insert(1, "--no-cache")', (ROOT / "scripts" / "prodlike" / "prodlike.py").read_text(encoding="utf-8"))

    def test_serve_pool_is_set_from_the_instance_table_not_left_to_the_default(self):
        compose = (ROOT / "deploy" / "hackathon" / "core" / "compose.agents.yaml").read_text(encoding="utf-8")
        self.assertIn("AGENTCORE_DB_POOL_MAX: ${AGENT_DB_POOL_MAX:-24}", compose)


if __name__ == "__main__":
    unittest.main()
