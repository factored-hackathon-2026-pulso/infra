"""Contract of the improvement-loop job on the engine host (docs/engine-loop.md): `pulso loop` as a systemd one-shot.

Static checks of the compose file, the units and the Terraform wiring, plus behavioural runs of the two shell scripts against fakes
(no AWS, no docker, no systemd). Source of the env contract: improvement-engine docs/dev/ENGINE_PROD.md and ASK_infra_engine_loop_env.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "deploy" / "hackathon"
ENGINE = BUNDLE / "engine"
LOOP = ENGINE / "loop"
TF = ROOT / "terraform"


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


def find_bash() -> str | None:
    for candidate in (r"C:\Program Files\Git\bin\bash.exe", r"C:\Program Files\Git\usr\bin\bash.exe"):
        if os.path.exists(candidate):
            return candidate
    return shutil.which("bash")


def unit_values(text: str, key: str) -> list[str]:
    return re.findall(rf"(?m)^{key}=(.*)$", text)


class LoopCompose(unittest.TestCase):
    def setUp(self):
        self.doc = yaml.safe_load(read(ENGINE / "compose.loop.yaml"))
        self.svc = self.doc["services"]["pulso-loop"]
        self.env = self.svc["environment"]

    def test_runs_pulso_loop_in_the_engine_image_and_is_not_part_of_up(self):
        self.assertEqual(set(self.doc["services"]), {"pulso-loop"})
        self.assertEqual(self.svc["image"], "${PULSO_IMAGE:?set}")
        self.assertEqual(self.svc["command"], ["loop"], "the entrypoint is `pulso`; a placeholder variable is not a command")
        self.assertEqual(self.env["PULSO_LOOP_COMMAND"], "loop")
        self.assertEqual(self.svc["profiles"], ["loop"], "a profile keeps `docker compose up` from starting the one-shot")
        self.assertEqual(self.svc["restart"], "no")

    def test_env_lines_of_the_ask(self):
        want = {
            "PULSO_REGISTRY_ENV": "shared",
            "PULSO_REGISTRY_VIA": "api",
            "PULSO_REGISTRY_AUTH": "mint",
            "PULSO_LOOP_INPUTS_DIR": "/var/lib/pulso/inputs",
            "PULSO_WORK_DIR": "/var/lib/pulso/work",
            "PULSO_EVAL_BEFORE_ANNOUNCE": "on",
            "PULSO_LLM_GATEWAY": "enabled",
        }
        for k, v in want.items():
            self.assertEqual(self.env[k], v, k)
        self.assertEqual(self.env["PULSO_CELLS_SOURCE"], "${PULSO_CELLS_SOURCE:-bank}")
        self.assertEqual(self.env["PULSO_PROFILE"], "${PULSO_LOOP_PROFILE:-standard}")

    def test_credentials_are_minted_never_static(self):
        self.assertEqual(self.env["PULSO_REGISTRY_AUTH"], "mint")
        self.assertEqual(self.env["PULSO_SERVICE_CRED_TTL_S"], "300")
        # seed and kid come from pulso.env (secret PULSO__PULSO_SERVICE_SEED_HEX, SSM PULSO_SERVICE_KID), never from this file
        self.assertIn("/run/pulso/env/pulso.env", self.svc["env_file"])
        self.assertNotIn("PULSO_SERVICE_SEED_HEX", self.env)
        for path in list((TF).rglob("*.tf")) + list(BUNDLE.rglob("*")):
            if not path.is_file() or ".terraform" in path.parts or "__pycache__" in path.parts:
                continue
            for n, line in enumerate(read(path).splitlines(), 1):
                if "PULSO_REGISTRY_TOKEN" in line and not line.lstrip().startswith("#"):
                    self.fail(f"static registry token referenced outside a comment: {path.relative_to(ROOT)}:{n}")
        keys = read(TF / "modules" / "hackathon_data" / "secrets.tf") + read(TF / "modules" / "hackathon_data" / "generated.tf")
        self.assertNotIn("PULSO_REGISTRY_TOKEN", keys)

    def test_old_slot_variables_are_gone(self):
        for dead in ("PULSO_CORE_PORT", "PULSO_MODEL_PORT", "PULSO_CORE_URL", "STEPS_RUNNER_EXE", "PULSO_BRIDGE_ADDR"):
            self.assertNotIn(dead, self.env)
        self.assertNotIn("SLOT", read(ENGINE / "compose.loop.yaml"))

    def test_mounts_inputs_read_only_and_the_data_dir_read_write(self):
        vols = self.svc["volumes"]
        self.assertIn("/srv/data/pulso:/var/lib/pulso", vols)
        self.assertIn("/srv/data/inputs:/var/lib/pulso/inputs:ro", vols)

    def test_lock_ttl_is_above_the_unit_timeout(self):
        ttl = int(self.env["PULSO_LOOP_LOCK_TTL_S"])
        unit = read(LOOP / "pulso-loop.service")
        timeout = unit_values(unit, "TimeoutStartSec")[0]
        seconds = int(timeout[:-1]) * {"h": 3600, "m": 60}[timeout[-1]] if timeout[-1] in "hm" else int(timeout)
        self.assertGreater(ttl, seconds)

    def test_no_secret_value_in_the_file_and_limits_present(self):
        text = read(ENGINE / "compose.loop.yaml")
        self.assertNotRegex(text, r"(?i)(password|token|seed_hex)\s*:\s*[^\s#$]")
        self.assertRegex(self.svc["mem_limit"], r"^[0-9]+m$")
        self.assertNotIn("networks", self.svc, "the observability override sets network_mode; both would conflict")


class LoopUnits(unittest.TestCase):
    SERVICE = read(LOOP / "pulso-loop.service")

    def test_exit_status_handling(self):
        self.assertEqual(unit_values(self.SERVICE, "SuccessExitStatus"), ["75 143 SIGTERM"])
        self.assertEqual(unit_values(self.SERVICE, "Restart"), [], "the timer is the retry (tests/test_userdata_batch_contract.py)")
        self.assertEqual(unit_values(self.SERVICE, "Type"), ["oneshot"])
        self.assertIn("OnFailure=pulso-loop-failed.service", self.SERVICE)

    def test_runs_sync_then_the_one_shot_then_the_status_hook(self):
        self.assertEqual(unit_values(self.SERVICE, "ExecStartPre"), ["/usr/local/bin/pulso-inputs-sync"])
        self.assertEqual(unit_values(self.SERVICE, "ExecStopPost"), ["/usr/local/bin/pulso-loop-status"])
        start = unit_values(self.SERVICE, "ExecStart")[0]
        self.assertRegex(start, r"docker compose -p pulso --project-directory /srv/stack run --rm --no-TTY pulso-loop$")

    def test_timer_interval_is_a_dropin_written_by_prepare(self):
        timer = read(LOOP / "pulso-loop.timer")
        self.assertIn("OnUnitActiveSec=", timer)
        prepare = read(TF / "modules" / "hackathon_compute" / "templates" / "prepare.sh.tftpl")
        self.assertIn("pulso-loop.timer.d/interval.conf", prepare)
        self.assertIn("systemctl enable --now pulso-loop.timer", prepare)
        self.assertRegex(prepare, r"%\{ if install_loop ~\}")
        self.assertIn("loop_interval", prepare)

    def test_failed_unit_leaves_a_marker_and_logs_an_error(self):
        failed = read(LOOP / "pulso-loop-failed.service")
        self.assertIn("/srv/data/loop/FAILED", failed)
        self.assertIn("user.err", failed)


class Wiring(unittest.TestCase):
    MAIN = read(TF / "envs" / "hackathon" / "main.tf")
    VARS = read(TF / "envs" / "hackathon" / "variables.tf")

    def test_off_by_default_and_needs_agent_services(self):
        m = re.search(r'variable "engine_loop_enabled" \{.*?\n\}\n', self.VARS, re.S).group(0)
        self.assertIn("default     = false", m)
        self.assertIn("var.agent_services_enabled", m)

    def test_bundle_ships_the_compose_file_scripts_and_units_only_when_enabled(self):
        for name in ("compose.loop.yaml", "loop/pulso-inputs-sync.sh", "loop/pulso-loop-status.sh", "loop/pulso-loop.service",
                     "loop/pulso-loop.timer", "loop/pulso-loop-failed.service", "loader/check_cells_k.py"):
            self.assertIn(f'"{name}"', self.MAIN, name)
        self.assertRegex(self.MAIN, r"engine_loop = local\.loop \? \{")
        self.assertRegex(self.MAIN, r'compose_files\s*=\s*concat\(\["compose\.yaml"\], local\.loop \? \["compose\.loop\.yaml"\]')
        self.assertRegex(self.MAIN, r"loop_enabled\s*=\s*local\.loop")

    def test_cells_source_and_profile_are_validated(self):
        self.assertIn('contains(["bank", "e0", "synthetic"], var.engine_loop_cells_source)', self.VARS)
        self.assertIn('var.engine_loop_profile != "demo" || var.engine_loop_cells_source == "synthetic"', self.VARS)
        self.assertIn("PULSO_CELLS_SOURCE = var.engine_loop_cells_source", self.MAIN)


def run_script(script: Path, env: dict, bash: str, extra_path: Path | None = None) -> subprocess.CompletedProcess:
    full = {k: v for k, v in os.environ.items() if k in ("SYSTEMROOT", "TEMP", "TMP", "HOME", "USERPROFILE", "COMSPEC")}
    full["PATH"] = (str(extra_path) + os.pathsep if extra_path else "") + str(Path(bash).parent) + os.pathsep + r"C:\Program Files\Git\usr\bin"
    full.update(env)
    return subprocess.run([bash, str(script)], capture_output=True, text=True, env=full, timeout=60)


def posix(p: Path) -> str:
    s = str(p).replace("\\", "/")
    return "/" + s[0].lower() + s[2:] if re.match(r"^[A-Za-z]:", s) else s


@unittest.skipUnless(find_bash(), "bash not available")
class StatusHook(unittest.TestCase):
    """pulso-loop-status.sh: exit code to status, marker, alert and orphaned-lock handling."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="loopstatus"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.state, self.work, self.bin = self.tmp / "state", self.tmp / "work", self.tmp / "bin"
        for d in (self.state, self.work, self.bin):
            d.mkdir()
        (self.work / "loop.lock").write_text("x")
        self.fake_docker("")

    def fake_docker(self, ps_output: str):
        d = self.bin / "docker"
        d.write_text(f"#!/bin/bash\n[ \"$1\" = ps ] && printf '%s' '{ps_output}'\nexit 0\n", newline="\n")
        d.chmod(d.stat().st_mode | stat.S_IEXEC)

    def run_status(self, exit_status: str):
        r = run_script(LOOP / "pulso-loop-status.sh", {
            "EXIT_STATUS": exit_status, "SERVICE_RESULT": "x", "LOOP_STATE_DIR": posix(self.state),
            "LOOP_WORK_DIR": posix(self.work), "LOOP_SKIP_S3": "1"}, find_bash(), self.bin)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads((self.state / "last.json").read_text()), r.stdout

    def test_success_codes_clear_the_marker(self):
        (self.state / "FAILED").write_text("old")
        for code, state in (("0", "ok"), ("75", "locked")):
            with self.subTest(code=code):
                (self.state / "FAILED").write_text("old")
                doc, _ = self.run_status(code)
                self.assertEqual(doc["state"], state)
                self.assertEqual((self.state / "FAILED").exists(), code != "0")

    def test_exit_3_is_the_alert(self):
        doc, out = self.run_status("3")
        self.assertEqual(doc["state"], "failed_infra")
        self.assertTrue((self.state / "FAILED").exists())
        self.assertIn("infra", doc["state"])
        self.assertIn("failed_infra", out)

    def test_exit_2_and_1_fail_visibly(self):
        for code, state in (("2", "refused"), ("1", "failed")):
            with self.subTest(code=code):
                (self.state / "FAILED").unlink(missing_ok=True)
                doc, _ = self.run_status(code)
                self.assertEqual(doc["state"], state)
                self.assertTrue((self.state / "FAILED").exists())

    def test_sigterm_is_a_clean_stop_and_removes_the_orphaned_lock(self):
        for code in ("143", "TERM"):
            with self.subTest(code=code):
                (self.work / "loop.lock").write_text("x")
                doc, _ = self.run_status(code)
                self.assertEqual(doc["state"], "stopped")
                self.assertFalse((self.state / "FAILED").exists())
                self.assertFalse((self.work / "loop.lock").exists())

    def test_the_lock_stays_while_another_loop_container_runs(self):
        self.fake_docker("abc123")
        self.run_status("143")
        self.assertTrue((self.work / "loop.lock").exists())

    def test_script_prints_no_environment(self):
        self.assertNotRegex(read(LOOP / "pulso-loop-status.sh"), r"(?m)^\s*(env|printenv|set -x)\b")


FAKE_AWS = r"""#!/bin/bash
# fake aws: `s3 sync s3://B/<prefix>/ <dir>` and `s3 cp s3://B/<key> <dest>` against the directory $FAKE_S3 (a bucket)
echo "aws $*" >> "$FAKE_LOG"
[ "${FAKE_AWS_FAIL:-}" = "1" ] && exit 1
sub="$2"; src="$3"; dst="$4"
key="${src#s3://*/}"
case "$sub" in
  sync) [ -d "$FAKE_S3/$key" ] || exit 0; cp -r "$FAKE_S3/$key"/. "$dst"/ 2>/dev/null; exit 0 ;;
  cp) [ -f "$FAKE_S3/$key" ] || exit 1; cp "$FAKE_S3/$key" "$dst"; exit 0 ;;
esac
exit 1
"""

FAKE_JQ = r"""#!/bin/bash
# fake jq for the two filters of pulso-inputs-sync: jq -r '.<field> // empty' FILE
f="$(echo "$2" | sed -E 's/^\.([a-z0-9_]+) .*/\1/')"
python3 -c "import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print('' if v is None else v)" "$3" "$f"
"""

CELLS_OK = '{"segment":"a","n":12}\n'


@unittest.skipUnless(find_bash(), "bash not available")
class InputsSync(unittest.TestCase):
    """pulso-inputs-sync.sh: the mirror of engine/inputs plus the loader's bank cells, verified and swapped atomically."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="loopsync"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.s3, self.bin, self.dest = self.tmp / "s3", self.tmp / "bin", self.tmp / "inputs"
        self.log = self.tmp / "log"
        self.s3.mkdir()
        self.bin.mkdir()
        for name, body in (("aws", FAKE_AWS), ("jq", FAKE_JQ), ("python3", f'#!/bin/bash\nexec "{posix(Path(sys.executable))}" "$@"\n')):
            p = self.bin / name
            p.write_text(body, newline="\n")
            p.chmod(p.stat().st_mode | stat.S_IEXEC)
        self.check_pass = self.tmp / "check_ok.py"
        self.check_pass.write_text("import sys\nsys.exit(0)\n")
        self.check_fail = self.tmp / "check_bad.py"
        self.check_fail.write_text("import sys\nsys.exit(1)\n")

    def put(self, key: str, text: str):
        f = self.s3 / key
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text, newline="\n")

    def loader_cells(self, text: str = CELLS_OK, run: str = "r1", sha: str | None = None):
        self.put(f"lake/gold_analytics/bank_cells/{run}/cells.ndjson", text)
        digest = sha or hashlib.sha256(text.encode()).hexdigest()
        self.put("lake/gold_analytics/bank_cells/latest.json", json.dumps({"run": run, "sha256": digest, "rows": 1, "k_min": 10}))

    def run_sync(self, check: Path | None = None, **extra):
        env = {"INPUTS_BUCKET": "b", "AWS_REGION": "us-east-1", "INPUTS_DIR": posix(self.dest), "FAKE_S3": posix(self.s3),
               "FAKE_LOG": posix(self.log), "LOADER_CHECK_CELLS": posix(check or self.check_pass)}
        env.update(extra)
        return run_script(LOOP / "pulso-inputs-sync.sh", env, find_bash(), self.bin)

    def test_loader_cells_are_verified_and_become_the_loop_input(self):
        self.loader_cells()
        self.put("engine/inputs/e0/v1/sample.txt", "e0")
        r = self.run_sync()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.dest / "cells.ndjson").read_text(), CELLS_OK)
        self.assertTrue((self.dest / "e0" / "v1" / "sample.txt").exists(), "engine/inputs is mirrored too")
        self.assertFalse(list(self.tmp.glob("inputs.stage.*")), "no staging directory is left behind")

    def test_cells_in_engine_inputs_are_used_when_the_loader_published_nothing(self):
        self.put("engine/inputs/cells.ndjson", CELLS_OK)
        self.assertEqual(self.run_sync().returncode, 0)
        self.assertEqual((self.dest / "cells.ndjson").read_text(), CELLS_OK)

    def test_a_manifest_mismatch_keeps_the_previous_mirror(self):
        self.loader_cells()
        self.assertEqual(self.run_sync().returncode, 0)
        self.loader_cells(text='{"segment":"EVIL"}\n', run="r2", sha="0" * 64)
        r = self.run_sync()
        self.assertEqual(r.returncode, 0, "the previous mirror is still usable")
        self.assertEqual((self.dest / "cells.ndjson").read_text(), CELLS_OK)
        self.assertIn("manifest", r.stdout)

    def test_a_failing_k_gate_keeps_the_previous_mirror(self):
        self.loader_cells()
        self.assertEqual(self.run_sync().returncode, 0)
        self.loader_cells(text='{"segment":"small"}\n', run="r3")
        r = self.run_sync(check=self.check_fail)
        self.assertEqual(r.returncode, 0)
        self.assertEqual((self.dest / "cells.ndjson").read_text(), CELLS_OK)
        self.assertIn("k>=10", r.stdout)

    def test_no_cells_anywhere_fails_the_unit(self):
        r = self.run_sync()
        self.assertEqual(r.returncode, 1)
        self.assertFalse(self.dest.exists())

    def test_a_failed_sync_without_a_previous_mirror_fails_and_with_one_keeps_it(self):
        self.assertEqual(self.run_sync(FAKE_AWS_FAIL="1").returncode, 1)
        self.loader_cells()
        self.assertEqual(self.run_sync().returncode, 0)
        r = self.run_sync(FAKE_AWS_FAIL="1")
        self.assertEqual(r.returncode, 0)
        self.assertEqual((self.dest / "cells.ndjson").read_text(), CELLS_OK)

    def test_a_run_name_with_a_path_is_refused(self):
        self.loader_cells()
        self.assertEqual(self.run_sync().returncode, 0)
        self.put("lake/gold_analytics/bank_cells/latest.json", json.dumps({"run": "../x", "sha256": "0" * 64}))
        r = self.run_sync()
        self.assertEqual(r.returncode, 0)
        self.assertEqual((self.dest / "cells.ndjson").read_text(), CELLS_OK)

    def test_script_reads_only_the_engine_and_analytics_prefixes(self):
        text = read(LOOP / "pulso-inputs-sync.sh")
        for forbidden in ("landing/", "lake/bronze", "gold_restricted", "lake/publish"):
            self.assertNotIn(forbidden, text.replace("never creates", ""), forbidden)
        self.assertIn("engine/inputs", text)
        self.assertIn("lake/gold_analytics/bank_cells", text)


class PrepareInstallsTheLoop(unittest.TestCase):
    PREPARE = read(TF / "modules" / "hackathon_compute" / "templates" / "prepare.sh.tftpl")

    def test_inputs_and_state_directories_are_created_and_owned_by_the_app_user(self):
        self.assertIn("mkdir -p /srv/data/inputs /srv/data/loop /srv/data/pulso/work", self.PREPARE)
        self.assertIn("chown 10001:10001 /srv/data/pulso/work", self.PREPARE)

    def test_scripts_are_installed_executable_from_the_bundle(self):
        self.assertIn("install -m 755 /srv/stack/loop/pulso-inputs-sync.sh /usr/local/bin/pulso-inputs-sync", self.PREPARE)
        self.assertIn("install -m 755 /srv/stack/loop/pulso-loop-status.sh /usr/local/bin/pulso-loop-status", self.PREPARE)


if __name__ == "__main__":
    unittest.main()
