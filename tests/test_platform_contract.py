"""Contract between the infra platform bundle and support-platform's deploy-env contract (names only, no values).

Source of truth: support-platform main docs/platform/deploy-env.md and deploy/database.md (checked 2026-10-06)."""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAT = ROOT / "deploy" / "hackathon" / "platform"
DATA = ROOT / "terraform" / "modules" / "hackathon_data"


def read(p):
    return Path(p).read_text(encoding="utf-8")


class Dsn(unittest.TestCase):
    def test_platform_dsns_use_the_psycopg_default_scheme(self):
        wiring = read(DATA / "wiring.tf")
        self.assertNotIn("asyncpg", wiring)  # the platform ships psycopg 3, not asyncpg
        self.assertNotIn("ssl=require", wiring.replace("sslmode=require", ""))

    def test_owner_dsn_is_not_in_the_api_env(self):
        self.assertNotIn("SUPPORT__CC_MIGRATE_DATABASE_URL", read(DATA / "wiring.tf") + read(DATA / "secrets.tf"))
        self.assertIn('"MIGRATE__CC_DATABASE_URL"', read(DATA / "wiring.tf"))


class Compose(unittest.TestCase):
    def setUp(self):
        self.c = read(PLAT / "compose.yaml")

    def test_runtime_contract_variables(self):
        for name in ("CC_ENV: staging", "CC_MIGRATE_ON_START", "CC_TRUSTED_PROXIES", "CC_SEED_DEMO_DATA", "CC_SEED_DEMO_BANK_LINKS", "CC_DEV_MAILBOX"):
            self.assertIn(name, self.c)
        self.assertNotRegex(self.c, r"CC_ENV: prod")

    def test_trusted_proxy_is_the_pinned_network(self):
        subnet = re.search(r"subnet: (\S+)", self.c).group(1)
        line = next(l for l in self.c.splitlines() if "CC_TRUSTED_PROXIES:" in l)
        self.assertIn(subnet, line)

    def test_health_is_readyz_and_grace_covers_shutdown(self):
        self.assertIn("/readyz", self.c)
        self.assertNotIn("8000/'", self.c)
        self.assertIn("stop_grace_period: 30s", self.c)

    def test_non_root_and_migrate_before_api(self):
        self.assertGreaterEqual(self.c.count('user: "10001:10001"'), 3)
        self.assertIn("command: [\"cc-migrate\"]", self.c)
        self.assertIn("service_completed_successfully", self.c)
        self.assertIn("migrate.env", self.c)

    def test_seed_unit_is_on_demand_and_idempotent_profile(self):
        self.assertIn('profiles: ["seed"]', self.c)
        self.assertIn('"cc-seed", "--profile", "volume"', self.c)

    def test_agent_core_timeout_is_below_the_edge_timeout(self):
        a = read(PLAT / "compose.agents.yaml")
        self.assertIn('CC_AGENT_CORE_TIMEOUT_SECONDS: "55"', a)
        self.assertIn("origin_read_timeout", read(ROOT / "terraform" / "modules" / "hackathon_edge" / "main.tf"))

    def test_agent_variable_names_match_the_platform(self):
        a = read(PLAT / "compose.agents.yaml")
        for name in ("CC_AGENT_CORE_URL", "CC_AGENT_KEYS_FILE", "CC_BANK_CUSTOMER_LINKS_FILE"):
            self.assertIn(name, a)


class Caddy(unittest.TestCase):
    def test_forwarded_headers(self):
        c = read(PLAT / "Caddyfile")
        self.assertIn("header_up X-Forwarded-Proto https", c)
        self.assertIn("trusted_proxies static private_ranges", c)
        self.assertLess(c.index("X-Origin-Verify"), c.index("reverse_proxy"))


class Grants(unittest.TestCase):
    def test_exporter_columns_include_case_type_and_no_free_text(self):
        g = read(DATA / "sql" / "26_platform_exporter_grants.sql")
        self.assertIn("case_type", g)
        for col in ("status", "close_reason", "closed_at"):
            self.assertNotRegex(g, rf"\b{col}\b.*opened_at|opened_at.*\b{col}\b")


if __name__ == "__main__":
    unittest.main()
