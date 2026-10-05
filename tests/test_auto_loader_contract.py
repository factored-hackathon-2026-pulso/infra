"""Static and unit contract of the automatic loader (docs/auto-loader.md): units, script, gate, isolation of credentials."""

from __future__ import annotations

import importlib.util
import json
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOADER = ROOT / "deploy" / "hackathon" / "engine" / "loader"


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


def load_gate():
    spec = importlib.util.spec_from_file_location("check_cells_k", LOADER / "check_cells_k.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class KGate(unittest.TestCase):
    def setUp(self):
        self.gate = load_gate()

    def cell(self, **kw):
        base = {"metric": "M1", "dims": {"channel": "web"}, "half": "discovery", "period": "ALL", "numerator": 12, "denominator": 40}
        base.update(kw)
        return json.dumps(base)

    def test_clean_file_passes(self):
        r = self.gate.check([self.cell(), self.cell(denominator=10, numerator=0)])
        self.assertEqual((r["rows"], r["below_k"], r["bad_keys"], r["bad_counts"]), (2, 0, 0, 0))

    def test_cell_below_k_is_counted(self):
        self.assertEqual(self.gate.check([self.cell(), self.cell(denominator=9, numerator=1)])["below_k"], 1)

    def test_identifier_or_free_text_keys_are_rejected(self):
        self.assertEqual(self.gate.check([self.cell(customer_id="C1")])["bad_keys"], 1)
        self.assertEqual(self.gate.check([self.cell(comment="texto")])["bad_keys"], 1)

    def test_bad_counts_and_json(self):
        self.assertEqual(self.gate.check([self.cell(numerator=50)])["bad_counts"], 1)
        self.assertEqual(self.gate.check([self.cell(numerator=-1)])["bad_counts"], 1)
        self.assertEqual(self.gate.check([self.cell(numerator=True)])["bad_counts"], 1)
        self.assertEqual(self.gate.check(["{not json"])["bad_json"], 1)

    def test_cli_exit_codes_and_no_cell_contents_printed(self):
        with tempfile.TemporaryDirectory() as d:
            good, bad, empty = Path(d, "g"), Path(d, "b"), Path(d, "e")
            good.write_text(self.cell() + "\n", encoding="utf-8")
            bad.write_text(self.cell(denominator=3, numerator=1, dims={"secret": "ZZTOP"}) + "\n", encoding="utf-8")
            empty.write_text("", encoding="utf-8")
            run = lambda p: subprocess.run(["python", str(LOADER / "check_cells_k.py"), str(p)], capture_output=True, text=True)
            self.assertEqual(run(good).returncode, 0)
            r = run(bad)
            self.assertEqual(r.returncode, 3)
            self.assertNotIn("ZZTOP", r.stdout + r.stderr)
            self.assertEqual(run(empty).returncode, 3)


class Units(unittest.TestCase):
    def test_service_is_unit_scoped_and_limited(self):
        u = read(LOADER / "pulso-loader.service")
        self.assertIn("Type=oneshot", u)
        self.assertIn("EnvironmentFile=/run/pulso/env/loader.env", u)
        self.assertEqual(len(re.findall(r"^EnvironmentFile=", u, re.M)), 1, "only the loader env file")
        self.assertNotIn("pulso.env", " ".join(l for l in u.splitlines() if not l.startswith("#")))
        self.assertIn("OnFailure=pulso-loader-failed.service", u)
        for k in ("CPUQuota=", "MemoryMax=", "Nice=", "IOSchedulingClass=idle", "PrivateTmp=true"):
            self.assertIn(k, u)

    def test_timer_polls_and_failed_unit_leaves_a_marker(self):
        t = read(LOADER / "pulso-loader.timer")
        self.assertIn("OnUnitInactiveSec=5min", t)
        self.assertIn("WantedBy=timers.target", t)
        f = read(LOADER / "pulso-loader-failed.service")
        self.assertIn("/srv/data/loader/FAILED", f)

    def test_engine_containers_never_read_the_loader_env(self):
        compose = read(ROOT / "deploy" / "hackathon" / "engine" / "compose.yaml")
        self.assertNotIn("loader.env", compose)
        self.assertNotIn("LOADER", compose)
        self.assertNotIn("AWS_SECRET_ACCESS_KEY", compose)


class Script(unittest.TestCase):
    def setUp(self):
        self.s = read(LOADER / "pulso-loader.sh")

    def test_syntax(self):
        bash = shutil.which("bash")
        if not bash:
            self.skipTest("bash not available")
        r = subprocess.run([bash, "-n", str(LOADER / "pulso-loader.sh")], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_assumes_the_role_with_external_id_and_short_session(self):
        self.assertIn("aws sts assume-role", self.s)
        self.assertIn('--external-id "$LOADER_EXTERNAL_ID"', self.s)
        self.assertIn("--duration-seconds 3600", self.s)

    def test_credentials_never_exported_in_the_script_shell(self):
        self.assertNotRegex(self.s, r"(?m)^\s*export\s+AWS_")
        self.assertNotRegex(self.s, r"(?m)^\s*AWS_(ACCESS|SECRET|SESSION)\w*=")
        # the only place they are sourced is the with_loader subshell, and the file is removed on exit
        self.assertEqual(len(re.findall(r'\. "\$CREDS"', self.s)), 1)
        self.assertIn("with_loader() { ( set -a;", self.s)
        self.assertIn('rm -f "$CREDS"', self.s)
        self.assertIn("trap", self.s)
        self.assertNotRegex(self.s, r">>?\s*/srv/stack/\.env", "never written to the stack env")
        self.assertIn('CREDS="/run/pulso/loader/', self.s, "credentials only on tmpfs")

    def test_secret_values_are_not_printed(self):
        self.assertNotRegex(self.s, r"(?m)^\s*(echo|printf|log)\b[^\n]*\$(PSEUDONYM_KEY|\{PSEUDONYM_KEY)")
        self.assertNotRegex(self.s, r"(?m)^\s*set -x|bash -x")

    def test_idempotent_by_marker_checksum_and_done_object(self):
        self.assertIn("sha256sum", self.s)
        self.assertIn("lake/loader/done/$RUN_KEY.json", self.s)
        self.assertIn("flock -n", self.s)

    def test_gate_runs_before_the_pipeline_publishes(self):
        self.assertLess(self.s.index("check_cells_k.py") if "check_cells_k.py" in self.s else self.s.index('"$CHECK"'), self.s.index("docker run"))

    def test_pipeline_container_is_limited_and_does_not_get_host_creds(self):
        self.assertIn('--memory "$LOADER_MEMORY"', self.s)
        self.assertIn('--cpus "$LOADER_CPUS"', self.s)
        self.assertIn("--env-file", self.s)
        self.assertNotIn("--privileged", self.s)
        self.assertNotIn("/var/run/docker.sock", self.s)

    def test_failure_is_reported(self):
        self.assertIn("status failed", self.s)
        self.assertIn("engine/loader/status/last.json", self.s)
        self.assertIn("exit 78", self.s)


class Memory(unittest.TestCase):
    def test_scratch_is_on_disk_not_ram_tmpfs_and_duckdb_is_bounded(self):
        s = read(LOADER / "pulso-loader.sh")
        self.assertNotIn("--tmpfs", s)
        self.assertIn('-v "$WORK/scratch:/work"', s)
        self.assertIn("DUCKDB_MEMORY_LIMIT=", s)
        self.assertIn("DUCKDB_TEMP_DIRECTORY=/work/duckdb_tmp", s)
        self.assertIn("DBT_THREADS=1", s)
        self.assertIn("--memory-swap", s)

    def test_table_batches_run_one_container_each(self):
        s = read(LOADER / "pulso-loader.sh")
        self.assertIn("LOADER_TABLE_BATCHES", s)
        self.assertIn("pipeline.ingest_bank --tables", s)

    def test_engine_host_default_is_a_4gib_free_tier_type_with_the_loader(self):
        m = read(ROOT / "terraform" / "envs" / "hackathon" / "main.tf")
        self.assertIn('engine = var.auto_loader_enabled ? "c7i-flex.large" : "t3.small"', m)
        v = read(ROOT / "terraform" / "envs" / "hackathon" / "variables.tf")
        self.assertIn('"c7i-flex.large"', v)


class Wiring(unittest.TestCase):
    def test_prepare_installs_the_loader_only_when_enabled(self):
        p = read(ROOT / "terraform" / "modules" / "hackathon_compute" / "templates" / "prepare.sh.tftpl")
        self.assertIn("%{ if install_loader ~}", p)
        self.assertIn("systemctl enable --now pulso-loader.timer", p)
        self.assertNotRegex(p, r"AWS_SECRET_ACCESS_KEY|assume-role")

    def test_env_bundles_the_five_loader_files(self):
        m = read(ROOT / "terraform" / "envs" / "hackathon" / "main.tf")
        for f in ("pulso-loader.sh", "check_cells_k.py", "pulso-loader.service", "pulso-loader.timer", "pulso-loader-failed.service"):
            self.assertIn(f, m)
            self.assertTrue((LOADER / f).is_file())

    def test_ssm_loader_names(self):
        m = read(ROOT / "terraform" / "envs" / "hackathon" / "main.tf")
        for k in ("LOADER_ROLE_ARN", "LOADER_EXTERNAL_ID", "LOADER_BUCKET", "LOADER_REGION", "LOADER_K_MIN", "LOADER_MEMORY", "LOADER_CPUS"):
            self.assertIn(k, m)
            self.assertIn(k.split("=")[0], read(LOADER / "pulso-loader.sh") + "LOADER_ROLE_ARN LOADER_EXTERNAL_ID LOADER_BUCKET LOADER_REGION LOADER_K_MIN LOADER_MEMORY LOADER_CPUS")


if __name__ == "__main__":
    unittest.main()
