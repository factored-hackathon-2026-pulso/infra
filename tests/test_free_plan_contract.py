"""Static contract of the free_plan profile bundle files (what terraform test cannot see).

Caddy cannot be started in CI here (no docker), so the origin check is asserted structurally: the verification must run
inside an ordered `route` block, before any proxying, with only /healthz answered before it. When a caddy binary is on
PATH the Caddyfiles are also validated by caddy itself.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "deploy" / "hackathon"
PROXIES = {"platform": BUNDLE / "platform" / "Caddyfile", "engine": BUNDLE / "engine" / "Caddyfile"}


class OriginVerifyIsEnforcedByCaddy(unittest.TestCase):
    def test_both_proxies_reject_requests_without_the_secret_header_before_proxying(self):
        for name, path in PROXIES.items():
            with self.subTest(proxy=name):
                text = path.read_text(encoding="utf-8")
                self.assertIn("route {", text, "an ordered route block keeps the check ahead of every proxy rule")
                m = re.search(r"@unverified not header X-Origin-Verify \{\$ORIGIN_VERIFY\}", text)
                self.assertIsNotNone(m, "the check must compare against the ORIGIN_VERIFY environment value")
                reject = re.search(r"respond @unverified [^\n]*\b403\b", text)
                self.assertIsNotNone(reject)
                first_proxy = text.index("reverse_proxy")
                self.assertLess(m.start(), first_proxy)
                self.assertLess(reject.start(), first_proxy)
                health = re.search(r"respond @healthz [^\n]*200", text)
                self.assertIsNotNone(health)
                self.assertLess(health.start(), m.start(), "only /healthz answers before the check (container healthcheck)")

    def test_nothing_is_proxied_outside_the_route_block(self):
        for name, path in PROXIES.items():
            with self.subTest(proxy=name):
                text = path.read_text(encoding="utf-8")
                route_start = text.index("route {")
                self.assertNotIn("reverse_proxy", text[:route_start])
                self.assertNotRegex(text, r"(?m)^\t(handle|reverse_proxy)\b", "directives live inside the route block")

    def test_proxy_service_receives_the_secret_from_common_env(self):
        for name in PROXIES:
            with self.subTest(proxy=name):
                text = (BUNDLE / name / "compose.yaml").read_text(encoding="utf-8")
                proxy = text[text.index("  proxy:") :]
                self.assertIn("/run/pulso/env/common.env", proxy.split("\n\n")[0])

    def test_start_script_refuses_to_start_a_proxy_host_without_the_secret(self):
        text = (ROOT / "terraform" / "modules" / "hackathon_compute" / "templates" / "prepare.sh.tftpl").read_text(encoding="utf-8")
        self.assertIn("ORIGIN_VERIFY", text)
        self.assertRegex(text, r'workload\s*!=\s*"core"')

    @unittest.skipUnless(shutil.which("caddy"), "caddy binary not available")
    def test_caddy_validates_the_files(self):
        for path in PROXIES.values():
            r = subprocess.run(["caddy", "validate", "--adapter", "caddyfile", "--config", str(path)], capture_output=True, text=True, env={"ORIGIN_VERIFY": "x"})
            self.assertEqual(r.returncode, 0, r.stderr)


class PostgresContainerBundle(unittest.TestCase):
    def setUp(self):
        self.compose = (BUNDLE / "core" / "compose.postgres.yaml").read_text(encoding="utf-8")

    def test_postgres_16_with_forty_connections_and_own_volume(self):
        self.assertRegex(self.compose, r"image:\s*\$\{POSTGRES_IMAGE:-postgres:16\.[0-9]+")
        self.assertIn("max_connections=40", self.compose)
        self.assertIn("/srv/pgdata:/var/lib/postgresql/data", self.compose)
        self.assertNotIn(":latest", self.compose)

    def test_password_comes_from_the_rendered_env_file_never_from_the_bundle(self):
        self.assertIn("/run/pulso/env/db.env", self.compose)
        self.assertNotRegex(self.compose, r"POSTGRES_PASSWORD\s*:")

    def test_migrations_wait_for_a_healthy_database(self):
        self.assertRegex(self.compose, r"core-migrate:\s*\n\s+depends_on:\s*\n\s+postgres:\s*\n\s+condition: service_healthy")

    def test_init_script_refuses_placeholder_passwords_and_runs_the_repo_sql(self):
        init = (BUNDLE / "core" / "initdb" / "10_init.sh").read_text(encoding="utf-8")
        self.assertIn("CHANGE_ME", init)
        for sql in ("00_databases_roles.sql", "10_core_grants.sql"):
            self.assertIn(sql, init)

    def test_memory_limits_leave_headroom_on_the_8gb_core_host(self):
        total = 0
        for text in (BUNDLE / "core" / "compose.yaml", BUNDLE / "core" / "compose.postgres.yaml"):
            total += sum(int(x) for x in re.findall(r"mem_limit:\s*(\d+)m", text.read_text(encoding="utf-8")))
        self.assertLessEqual(total, 8192 * 0.7)


if __name__ == "__main__":
    unittest.main()
