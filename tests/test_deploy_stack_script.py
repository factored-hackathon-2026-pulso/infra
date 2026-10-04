"""deploy/hackathon/deploy-stack.sh against a fake docker and a fake prepare script (offline, no AWS, no real docker).

The script runs on the host (through the SSM Command document pulso-deploy-<workload>): it renders the env with the
new digests, pulls, brings the stack up, waits for container health and, on any failure, restores the previous
digests from a local state file and exits non-zero.
"""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "deploy" / "hackathon" / "deploy-stack.sh"

OLD = "r/core@sha256:" + "a" * 64
NEW = "r/core@sha256:" + "b" * 64

FAKE_DOCKER = r"""#!/bin/bash
echo "docker $*" >> "$FAKE_LOG"
case "$*" in
  "compose -p pulso pull"*)
    echo "pull-with: $(grep '_IMAGE=' "$STACK_DIR/.env" | tr '\n' ' ')" >> "$FAKE_LOG"
    exit "${FAKE_PULL_RC:-0}" ;;
  "compose -p pulso up"*)
    echo "up-with: $(grep '_IMAGE=' "$STACK_DIR/.env" | tr '\n' ' ')" >> "$FAKE_LOG"
    if [ -n "${FAKE_UP_FAIL_ON:-}" ] && grep -q "$FAKE_UP_FAIL_ON" "$STACK_DIR/.env"; then exit 1; fi
    exit 0 ;;
  "compose -p pulso ps -a -q"*) printf 'c1\nc2\n'; exit 0 ;;
  "compose -p pulso ps"*) echo "NAME STATUS"; exit 0 ;;
  inspect*)
    # the new digest is "bad" when FAKE_BAD_WHEN_NEW is set; the old one is always healthy
    if [ -n "${FAKE_BAD_WHEN_NEW:-}" ] && grep -q "$FAKE_BAD_WHEN_NEW" "$STACK_DIR/.env"; then
      echo "${FAKE_BAD_STATE}"
    else
      echo "${FAKE_GOOD_STATE:-running healthy 0}"
    fi
    exit 0 ;;
esac
exit 0
"""

FAKE_PREPARE = r"""#!/bin/bash
echo "prepare" >> "$FAKE_LOG"
[ "${FAKE_PREPARE_RC:-0}" = "0" ] || exit "$FAKE_PREPARE_RC"
{ grep -v '_IMAGE=' "$STACK_DIR/.env"; echo "CORE_IMAGE=$FAKE_NEW_IMAGE"; } > "$STACK_DIR/.env.new"
mv "$STACK_DIR/.env.new" "$STACK_DIR/.env"
"""


def find_bash() -> str | None:
    for candidate in (r"C:\Program Files\Git\bin\bash.exe", r"C:\Program Files\Git\usr\bin\bash.exe"):
        if os.path.exists(candidate):
            return candidate
    return shutil.which("bash")


BASH = find_bash()


@unittest.skipUnless(BASH, "bash is required")
class DeployStackScript(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.stack = self.tmp / "stack"
        self.stack.mkdir()
        (self.stack / ".env").write_text(f"BUCKET_NAME=b\nCORE_IMAGE={OLD}\n", encoding="utf-8", newline="\n")
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.log = self.tmp / "calls.log"
        self.log.write_text("", encoding="utf-8")
        for name, body in (("docker", FAKE_DOCKER), ("prepare", FAKE_PREPARE)):
            p = self.bin / name
            p.write_text(body, encoding="utf-8", newline="\n")
            p.chmod(p.stat().st_mode | stat.S_IXUSR)

    def run_script(self, **extra):
        env = dict(os.environ)
        env.update(
            STACK_DIR=self.stack.as_posix(),
            PULSO_PREPARE=(self.bin / "prepare").as_posix(),
            FAKE_LOG=self.log.as_posix(),
            FAKE_NEW_IMAGE=NEW,
            DEPLOY_HEALTH_TIMEOUT="4",
            DEPLOY_HEALTH_INTERVAL="1",
            PATH=self.bin.as_posix() + os.pathsep + env.get("PATH", ""),
        )
        env.update(extra)
        return subprocess.run([BASH, SCRIPT.as_posix()], env=env, capture_output=True, text=True, timeout=120)

    def env_images(self) -> str:
        return (self.stack / ".env").read_text(encoding="utf-8")

    def calls(self) -> str:
        return self.log.read_text(encoding="utf-8")

    def test_script_exists(self):
        self.assertTrue(SCRIPT.exists(), SCRIPT)

    def test_success_pulls_before_up_and_records_previous_digests(self):
        r = self.run_script()
        self.assertEqual(0, r.returncode, r.stdout + r.stderr)
        self.assertIn("DEPLOY_RESULT=ok", r.stdout)
        calls = self.calls()
        self.assertLess(calls.index("compose -p pulso pull"), calls.index("compose -p pulso up -d"))
        self.assertIn(NEW, self.env_images())
        previous = (self.stack / ".deploy-state" / "previous-images.env").read_text(encoding="utf-8")
        self.assertIn(OLD, previous)
        self.assertNotIn(NEW, previous)

    def test_pull_uses_the_new_digest_and_prepare_runs_first(self):
        self.run_script()
        calls = self.calls()
        self.assertLess(calls.index("prepare"), calls.index("compose -p pulso pull"))
        self.assertIn(f"pull-with: CORE_IMAGE={NEW}", calls)

    def test_unhealthy_new_digest_restores_the_previous_one_and_fails(self):
        r = self.run_script(FAKE_BAD_WHEN_NEW="b" * 64, FAKE_BAD_STATE="running unhealthy 0")
        self.assertNotEqual(0, r.returncode)
        self.assertIn("DEPLOY_RESULT=rolled_back", r.stdout)
        self.assertIn(OLD, self.env_images())
        self.assertNotIn(NEW, self.env_images())
        last_up = [l for l in self.calls().splitlines() if l.startswith("up-with:")][-1]
        self.assertIn(OLD, last_up, "the final up must run the previous digest")

    def test_crash_looping_container_counts_as_unhealthy(self):
        r = self.run_script(FAKE_BAD_WHEN_NEW="b" * 64, FAKE_BAD_STATE="restarting none 1")
        self.assertNotEqual(0, r.returncode)
        self.assertIn("DEPLOY_RESULT=rolled_back", r.stdout)

    def test_health_that_never_settles_times_out_and_rolls_back(self):
        r = self.run_script(FAKE_BAD_WHEN_NEW="b" * 64, FAKE_BAD_STATE="running starting 0")
        self.assertNotEqual(0, r.returncode)
        self.assertIn("timeout", (r.stdout + r.stderr).lower())
        self.assertIn(OLD, self.env_images())

    def test_one_shot_container_that_exited_zero_is_fine(self):
        r = self.run_script(FAKE_GOOD_STATE="exited none 0")
        self.assertEqual(0, r.returncode, r.stdout + r.stderr)

    def test_one_shot_container_that_exited_nonzero_fails(self):
        r = self.run_script(FAKE_BAD_WHEN_NEW="b" * 64, FAKE_BAD_STATE="exited none 2")
        self.assertNotEqual(0, r.returncode)
        self.assertIn(OLD, self.env_images())

    def test_container_without_healthcheck_that_runs_is_fine(self):
        r = self.run_script(FAKE_GOOD_STATE="running none 0")
        self.assertEqual(0, r.returncode, r.stdout + r.stderr)

    def test_pull_failure_never_touches_running_containers_and_restores_env(self):
        r = self.run_script(FAKE_PULL_RC="1")
        self.assertNotEqual(0, r.returncode)
        self.assertNotIn("compose -p pulso up", self.calls().replace("up-with", ""))
        self.assertIn(OLD, self.env_images())
        self.assertIn("DEPLOY_RESULT=failed", r.stdout)

    def test_prepare_failure_exits_non_zero_and_changes_nothing(self):
        r = self.run_script(FAKE_PREPARE_RC="3")
        self.assertNotEqual(0, r.returncode)
        self.assertNotIn("compose -p pulso pull", self.calls())
        self.assertIn(OLD, self.env_images())

    def test_up_failure_restores_previous_digests(self):
        r = self.run_script(FAKE_UP_FAIL_ON="b" * 64)
        self.assertNotEqual(0, r.returncode)
        self.assertIn(OLD, self.env_images())
        self.assertIn("DEPLOY_RESULT=rolled_back", r.stdout)

    def test_no_secret_values_or_aws_calls_in_the_script(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("get-secret-value", text)
        self.assertNotRegex(text, r"AKIA[0-9A-Z]{12}")


if __name__ == "__main__":
    unittest.main()
