"""Static contract of the agent services bundle (agent-core serve and tool-service on the core host; the platform side).

What terraform test cannot see: the compose overrides, the Caddyfile and the init script. Docs: docs/agent-services.md.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "deploy" / "hackathon"
CORE_AGENTS = BUNDLE / "core" / "compose.agents.yaml"
PLATFORM_AGENTS = BUNDLE / "platform" / "compose.agents.yaml"


def services(path: Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))["services"]


class CoreAgentServices(unittest.TestCase):
    def setUp(self):
        self.text = CORE_AGENTS.read_text(encoding="utf-8")
        self.svc = services(CORE_AGENTS)

    def test_three_services_digest_pinned_by_variable(self):
        # the three core-bridge services only get a profile here (docs/agent-core-serve.md); the sweep is a profile one-shot
        self.assertEqual(set(self.svc), {"agent-core-migrate", "agent-core", "agent-core-sweep", "tool-service", "core-migrate", "core-runtime", "core-exporter"})
        self.assertNotIn(":latest", self.text)
        self.assertEqual(self.svc["agent-core"]["image"], "${AGENT_IMAGE:?set}")
        self.assertEqual(self.svc["agent-core-migrate"]["image"], "${AGENT_IMAGE:?set}")
        self.assertEqual(self.svc["tool-service"]["image"], "${TOOLS_IMAGE:?set}")

    def test_only_agent_core_is_published_and_on_8001(self):
        published = {n: s["ports"] for n, s in self.svc.items() if "ports" in s}
        self.assertEqual(published, {"agent-core": ["8001:8001"]}, "tool-service stays internal")
        self.assertIn("--port 8001", self.svc["agent-core"]["command"])

    def test_every_service_runs_as_the_app_user_with_limits_and_restart(self):
        for name, s in self.svc.items():
            if "image" not in s:  # the legacy services only carry a profile here
                continue
            with self.subTest(service=name):
                self.assertEqual(s["user"], "10001:10001")
                self.assertRegex(s["mem_limit"], r"^[0-9]+m$")
                self.assertIn("restart", s)

    def test_secrets_come_only_from_the_rendered_env_and_files(self):
        self.assertNotRegex(self.text, r"(?i)(password|token|api_key|dsn)\s*:\s*(?!\"\")\S")
        self.assertEqual(self.svc["agent-core"]["env_file"], ["/run/pulso/env/common.env", "/run/pulso/env/agent.env"])
        self.assertEqual(self.svc["tool-service"]["env_file"], ["/run/pulso/env/common.env", "/run/pulso/env/tools.env"])
        self.assertIn("/run/pulso/files/agent:/run/files:ro", self.svc["agent-core"]["volumes"])

    def test_serve_runs_with_real_pieces_never_demo_doubles(self):
        cmd = self.svc["agent-core"]["command"]
        env = self.svc["agent-core"]["environment"]
        self.assertIn("${AGENT_SERVE_ARGS:-}", cmd, "extra arguments are deployment input (.env); the seven real pieces are serve's defaults")
        self.assertEqual(env["AGENTCORE_IDENTITY_KEYS_FILE"], "/run/files/IDENTITY_KEYS")
        self.assertEqual(env["AGENTCORE_STAFF_KEYS_FILE"], "/run/files/STAFF_KEYS")
        self.assertEqual(env["AGENTCORE_REGISTRY_API"], "1")
        self.assertNotIn("--tools", cmd)
        self.assertNotIn("testing.", self.text)
        self.assertNotIn("AGENTCORE_ALLOW_DEMO", self.text.replace("AGENTCORE_ALLOW_DOUBLES is NEVER set", ""))

    def test_agent_core_reaches_its_siblings_by_compose_and_private_dns(self):
        env = self.svc["agent-core"]["environment"]
        self.assertEqual(env["AGENTCORE_LLM_GATEWAY_URL"], "http://llm-gateway:8080")
        self.assertEqual(env["AGENTCORE_TOOL_SERVICE_URL"], "http://tool-service:8080")
        self.assertEqual(env["AGENTCORE_GRANTS_URL"], "http://platform.${PRIVATE_ZONE_NAME:?set}:8000")
        self.assertEqual(env["AGENTCORE_AUTHZ_BIND_KEYS"], "subject_ref,customer_id")

    def test_calibration_and_classifier_artifacts_are_mounted_read_only(self):
        env = self.svc["agent-core"]["environment"]
        self.assertEqual(env["AGENTCORE_CALIBRATION_DIR"], "/artifacts/calibrations")
        self.assertEqual(env["AGENTCORE_CLASSIFIER_ARTIFACTS_DIR"], "/artifacts/classifiers")
        self.assertIn("/srv/data/agent/artifacts:/artifacts:ro", self.svc["agent-core"]["volumes"])

    def test_fx_table_and_staff_keys_come_from_the_secret_files(self):
        env = self.svc["agent-core"]["environment"]
        self.assertEqual(env["AGENTCORE_FX_RATES_FILE"], "/run/files/FX_RATES")
        self.assertEqual(env["AGENTCORE_STAFF_KEYS_FILE"], "/run/files/STAFF_KEYS")

    def test_migrate_uses_the_owner_dsn_and_runs_before_serve(self):
        migrate = self.svc["agent-core-migrate"]
        self.assertEqual(migrate["restart"], "no")
        joined = " ".join(migrate["entrypoint"])
        self.assertIn("AGENTCORE_MIGRATE_DSN", joined)
        self.assertIn("agentcore migrate --app-role agent_app", joined)
        self.assertEqual(self.svc["agent-core"]["depends_on"]["agent-core-migrate"]["condition"], "service_completed_successfully")
        pg = services(CORE_AGENTS.with_name("compose.agents.postgres.yaml"))
        self.assertEqual(pg["agent-core-migrate"]["depends_on"]["postgres"]["condition"], "service_healthy",
                         "container mode: the migration waits for a healthy Postgres (the legacy core-migrate is out of the chain)")

    def test_tool_service_reads_the_synced_publication_read_only_and_keeps_filings(self):
        ts = self.svc["tool-service"]
        self.assertIn("/srv/data/tools/data:/data:ro", ts["volumes"])
        self.assertIn("/srv/data/tools/state:/state", ts["volumes"])
        self.assertEqual(ts["environment"]["TOOL_DATA_DIR"], "/data")
        self.assertEqual(ts["environment"]["TOOL_FILED_DB"], "/state/filed_pqrs.db")
        self.assertIn("/srv/data/tools/current:/catalog:ro", self.svc["agent-core"]["volumes"])

    def test_memory_limits_leave_headroom_on_the_8gb_core_host_with_postgres(self):
        # With serve on the legacy core-bridge services and the sweep one-shot (profiles) are not running next to the rest.
        profiled = {n for n, s in self.svc.items() if "profiles" in s}
        total = 0
        for name in ("compose.yaml", "compose.postgres.yaml", "compose.agents.yaml"):
            for n, s in services(BUNDLE / "core" / name).items():
                if n not in profiled:
                    total += int(re.fullmatch(r"(\d+)m", s.get("mem_limit", "0m")).group(1))
        self.assertLessEqual(total, 8192 * 0.7)


class AgentDatabases(unittest.TestCase):
    def test_init_runs_the_agent_sql_only_when_its_passwords_exist(self):
        init = (BUNDLE / "core" / "initdb" / "10_init.sh").read_text(encoding="utf-8")
        self.assertIn("20_agent_databases.sql", init)
        self.assertIn("DB_PASSWORD_AGENT_OWNER", init)

    def test_agent_sql_creates_separate_databases_owned_by_agent_owner(self):
        sql = (ROOT / "terraform" / "modules" / "hackathon_data" / "sql" / "20_agent_databases.sql").read_text(encoding="utf-8")
        self.assertIn("\\getenv agent_owner_pw DB_PASSWORD_AGENT_OWNER", sql)
        self.assertIn("CREATE DATABASE agent_runtime OWNER agent_owner", sql)
        self.assertIn("CREATE DATABASE agent_eval OWNER agent_owner", sql)
        self.assertIn("ALTER DEFAULT PRIVILEGES FOR ROLE agent_owner", sql)
        self.assertNotIn("core_runtime", sql.split("--", 1)[0])


class PlatformSide(unittest.TestCase):
    def setUp(self):
        self.svc = services(PLATFORM_AGENTS)

    def test_platform_api_is_published_for_grant_active_and_points_to_agent_core(self):
        api = self.svc["support-platform-api"]
        self.assertEqual(api["ports"], ["8000:8000"])
        self.assertEqual(api["environment"]["CC_AGENT_CORE_URL"], "http://core.${PRIVATE_ZONE_NAME:?set}:8001")
        self.assertEqual(api["environment"]["CC_AGENT_KEYS_FILE"], "/run/files/AGENT_PRIVATE_KEYS")
        self.assertEqual(api["environment"]["CC_BANK_CUSTOMER_LINKS_FILE"], "/run/files/BANK_CUSTOMER_LINKS")
        self.assertIn("/run/pulso/files/support:/run/files:ro", api["volumes"])

    def test_caddy_never_proxies_the_internal_api_routes(self):
        caddy = (BUNDLE / "platform" / "Caddyfile").read_text(encoding="utf-8")
        m = re.search(r"@internal path ([^\n]+)", caddy)
        self.assertIsNotNone(m)
        self.assertIn("/api/v1/internal/*", m.group(1).split(), "grant_active is for agent-core over the VPC, not for CloudFront")
        self.assertLess(caddy.index("respond @internal"), caddy.index("reverse_proxy /api/*"))


if __name__ == "__main__":
    unittest.main()
