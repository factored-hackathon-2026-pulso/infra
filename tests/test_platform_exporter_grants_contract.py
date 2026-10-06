"""The platform exporter grants (26_platform_exporter_grants.sql) are applied by an automatic job, not by hand."""
import pathlib
import re
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORE = ROOT / "deploy" / "hackathon" / "core"
SCRIPT = CORE / "bootstrap" / "platform-exporter-grants.sh"
MAIN_TF = ROOT / "terraform" / "envs" / "hackathon" / "main.tf"


class PlatformExporterGrantsJob(unittest.TestCase):
    JOB = yaml.safe_load((CORE / "compose.agents.postgres.yaml").read_text(encoding="utf-8"))["services"]["platform-exporter-grants"]
    TEXT = SCRIPT.read_text(encoding="utf-8")

    def test_job_is_a_restarting_loop_as_the_master_after_a_healthy_postgres(self):
        self.assertEqual(self.JOB["restart"], "unless-stopped")
        self.assertNotIn("healthcheck", self.JOB)  # a running container without one never blocks wait_healthy
        self.assertEqual(self.JOB["env_file"], ["/run/pulso/env/db.env"])
        self.assertEqual(self.JOB["depends_on"]["postgres"]["condition"], "service_healthy")
        self.assertEqual(self.JOB["depends_on"]["postgres-bundle-perms"]["condition"], "service_completed_successfully")
        self.assertIn("./initdb/sql:/sql:ro", self.JOB["volumes"])
        self.assertIn("./bootstrap:/bootstrap:ro", self.JOB["volumes"])

    def test_nothing_else_waits_for_the_job(self):
        for f in CORE.glob("compose*.y*ml"):
            for name, svc in (yaml.safe_load(f.read_text(encoding="utf-8")).get("services") or {}).items():
                self.assertNotIn("platform-exporter-grants", svc.get("depends_on", {}), name)

    def test_script_applies_the_grants_file_idempotently_when_the_schema_exists(self):
        self.assertIn("26_platform_exporter_grants.sql", self.TEXT)
        self.assertIn("-d platform", self.TEXT)
        self.assertIn("ON_ERROR_STOP=1", self.TEXT)
        self.assertIn("alembic_version", self.TEXT)
        self.assertIn("event_log", self.TEXT)
        self.assertIn("exporter grants applied", self.TEXT)
        self.assertRegex(self.TEXT, r"(?m)^while :")  # waits for the other host's migrations instead of exiting

    def test_script_waits_quietly_and_never_prints_credentials(self):
        self.assertIn("waiting for the platform migrations", self.TEXT)
        self.assertIn(">/dev/null", self.TEXT)
        self.assertNotRegex(self.TEXT, r"(?m)^\s*set -\w*[ex]")
        for line in self.TEXT.splitlines():
            if re.match(r"\s*(echo|say|printf)\b", line):
                self.assertNotRegex(line, r"(?i)PASSWORD|PGPASSWORD|\$POSTGRES")

    def test_script_ships_with_the_grants_sql_in_the_bundle(self):
        tf = MAIN_TF.read_text(encoding="utf-8")
        self.assertIn("bootstrap/platform-exporter-grants.sh", tf)
        self.assertIn("26_platform_exporter_grants.sql", tf)

    def test_docs_describe_automatic_apply_with_manual_fallback(self):
        for doc in ("shared-postgres.md", "infra-day-one.md"):
            text = (ROOT / "docs" / doc).read_text(encoding="utf-8")
            self.assertIn("platform-exporter-grants", text, doc)
            self.assertIn("26_platform_exporter_grants.sql", text, doc)


if __name__ == "__main__":
    unittest.main()
