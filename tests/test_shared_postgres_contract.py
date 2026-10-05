"""Static contract of the shared Postgres on the core host (docs/shared-postgres.md): what terraform test cannot see.

One Postgres container, one database and role set per service. The SQL is idempotent, takes passwords from the environment only,
and the engine's exporter role is read-only and limited to an explicit table allow-list.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQL = ROOT / "terraform" / "modules" / "hackathon_data" / "sql"
CORE = ROOT / "deploy" / "hackathon" / "core"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class PlatformDatabases(unittest.TestCase):
    def setUp(self):
        self.sql = read(SQL / "25_platform_databases.sql")
        self.grants = read(SQL / "26_platform_exporter_grants.sql")

    def test_one_database_per_service_with_owner_and_app_roles(self):
        for db, owner, app in (("platform", "platform_owner", "platform_app"), ("tools", "tools_owner", "tools_app")):
            with self.subTest(db=db):
                self.assertIn(f"CREATE DATABASE {db} OWNER {owner}", self.sql)
                self.assertIn(f"GRANT CONNECT ON DATABASE {db} TO", self.sql)
                self.assertRegex(self.sql, rf"ALTER DEFAULT PRIVILEGES FOR ROLE {owner} IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {app}")
        self.assertIn("REVOKE CONNECT ON DATABASE platform, tools FROM PUBLIC", self.sql)

    def test_passwords_come_from_the_environment_never_the_file(self):
        self.assertEqual(len(re.findall(r"\\getenv \w+_pw DB_PASSWORD_[A-Z_]+", self.sql)), 5)
        self.assertNotRegex(self.sql, r"PASSWORD '[^']")
        self.assertNotRegex(self.sql, r"(?i)password\s*=")

    def test_exporter_is_read_only_and_has_no_default_privileges(self):
        self.assertIn("ALTER ROLE platform_exporter_ro SET default_transaction_read_only = on", self.sql)
        self.assertNotRegex(self.sql, r"(?i)ALTER DEFAULT PRIVILEGES[^;]*platform_exporter_ro")
        self.assertNotRegex(self.sql, r"(?i)GRANT (INSERT|UPDATE|DELETE|ALL)[^;]*platform_exporter_ro")

    def test_exporter_grants_are_an_explicit_allow_list(self):
        self.assertIn("ARRAY['event_log', 'cases']", self.grants)
        self.assertIn("REVOKE ALL ON ALL TABLES IN SCHEMA public FROM platform_exporter_ro", self.grants)
        self.assertNotRegex(self.grants, r"(?i)GRANT SELECT ON ALL TABLES")

    def test_files_are_idempotent(self):
        self.assertEqual(self.sql.count("CREATE DATABASE"), 2)
        for stmt in re.findall(r"'CREATE DATABASE [^']+'", self.sql):
            self.assertIn("WHERE NOT EXISTS", self.sql[self.sql.index(stmt):self.sql.index(stmt) + 200])


class InitScript(unittest.TestCase):
    def test_platform_databases_are_gated_on_their_passwords(self):
        init = read(CORE / "initdb" / "10_init.sh")
        self.assertIn('"$SQL/25_platform_databases.sql"', init)
        self.assertIn('[ -n "${DB_PASSWORD_PLATFORM_OWNER:-}" ]', init)
        for role in ("PLATFORM_OWNER", "PLATFORM_APP", "PLATFORM_EXPORTER_RO", "TOOLS_OWNER", "TOOLS_APP"):
            self.assertIn(f"DB_PASSWORD_{role}", init)
        self.assertIn('= "CHANGE_ME"', init)

    def test_exporter_grants_never_run_at_init(self):
        # The tables exist only after the platform's first migration.
        self.assertNotIn("26_platform_exporter_grants.sql\"", read(CORE / "initdb" / "10_init.sh"))


class PostgresSizing(unittest.TestCase):
    def test_container_fits_the_core_host(self):
        compose = read(CORE / "compose.postgres.yaml")
        self.assertIn("max_connections=100", compose)
        self.assertIn("mem_limit: 2048m", compose)
        # Containers of the core host (limits): postgres 2048 + core-runtime 768 + agent-core 768 + tool-service 1024
        # + gateway 128 + exporter 128 = 4864 MiB of the 8 GiB m7i-flex.large; one-shot migrations 256 each, one at a time.
        agents = read(CORE / "compose.agents.yaml")
        limits = [int(m) for m in re.findall(r"mem_limit: (\d+)m", read(CORE / "compose.yaml") + agents + compose)]
        self.assertLessEqual(sum(limits) - 3 * 256, 6144, "leave at least 2 GiB for the kernel, docker and page cache")


class ImdsHopLimit(unittest.TestCase):
    def test_containers_can_reach_the_instance_profile(self):
        main = read(ROOT / "terraform" / "modules" / "hackathon_compute" / "main.tf")
        self.assertRegex(main, r"http_tokens\s*=\s*\"required\"")
        self.assertRegex(main, r"http_put_response_hop_limit\s*=\s*2")


class GatewayIsReachableFromTheEngineHost(unittest.TestCase):
    def test_gateway_publishes_8080_for_the_engine(self):
        compose = read(CORE / "compose.yaml")
        block = compose[compose.index("  llm-gateway:"):]
        self.assertIn('- "8080:8080"', block, "PULSO_LLM_GATEWAY_ADDR=<core private IP>:8080 needs a published port")
        env_main = read(ROOT / "terraform" / "envs" / "hackathon" / "main.tf")
        self.assertIn('extra_ports             = concat(["8080:8080"]', env_main)


class EngineEnvContract(unittest.TestCase):
    """Names the engine reads (improvement-engine origin/main, 2026-10-05): the infra must produce exactly these."""

    def test_engine_platform_wiring_names(self):
        env_main = read(ROOT / "terraform" / "envs" / "hackathon" / "main.tf")
        for name in ("PULSO_PLATFORM_URL", "PULSO_REGISTRY_ADDR", "PULSO_ANNOUNCE_TO_PLATFORM", "PULSO_SOURCE_ADAPTER", "PULSO_SOURCE_SCHEMA"):
            self.assertIn(name, env_main)
        # The engine accepts only a private IP literal for plain HTTP: the value must come from private_ip, never a DNS name.
        self.assertIn('"http://${module.compute_platform.private_ip}:8000"', env_main)
        self.assertIn('"${module.compute_core.private_ip}:8001"', env_main)

    def test_engine_secret_names(self):
        secrets = read(ROOT / "terraform" / "modules" / "hackathon_data" / "secrets.tf")
        generated = read(ROOT / "terraform" / "modules" / "hackathon_data" / "generated.tf")
        self.assertIn("PULSO__PULSO_PG_PRODUCT_DSN", secrets)
        self.assertIn("PULSO__PULSO_PLATFORM_SERVICE_TOKEN", generated)
        self.assertIn("PULSO__PULSO_LLM_GATEWAY_KEY", generated)
        self.assertIn("PULSO__PULSO_SERVICE_SEED_HEX", generated)


if __name__ == "__main__":
    unittest.main()
