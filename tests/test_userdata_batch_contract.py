"""Contract of the fixes that live in aws_instance.user_data (prepare.sh.tftpl, user_data.sh.tftpl), applied together in one
controlled host replacement window (docs/infra-day-one.md, "Controlled replacement window").

Static checks plus behavioural runs of the rendered shell fragments against fakes (no AWS, no docker, no systemd).
"""

from __future__ import annotations

import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMPUTE = ROOT / "terraform" / "modules" / "hackathon_compute"
PREPARE = (COMPUTE / "templates" / "prepare.sh.tftpl").read_text(encoding="utf-8")
USER_DATA = (COMPUTE / "templates" / "user_data.sh.tftpl").read_text(encoding="utf-8")
LOOP = ROOT / "deploy" / "hackathon" / "engine" / "loop"
DOCS = ROOT / "docs"


def find_bash() -> str | None:
    for candidate in (r"C:\Program Files\Git\bin\bash.exe", r"C:\Program Files\Git\usr\bin\bash.exe"):
        if os.path.exists(candidate):
            return candidate
    return shutil.which("bash")


BASH = find_bash()


def heredoc(text: str, marker: str) -> str:
    m = re.search(rf"<<'{marker}'\n(.*?)\n{marker}\n", text, re.S)
    assert m, marker
    return m.group(1)


def block(text: str, name: str) -> str:
    m = re.search(rf"# BEGIN {name}\n(.*?)# END {name}\n", text, re.S)
    assert m, name
    return m.group(1)


def untemplate(s: str) -> str:
    return s.replace("$${", "${")


class LoopTimerAlwaysHasANextElapse(unittest.TestCase):
    def test_timer_is_relative_to_the_last_start_not_to_the_end(self):
        timer = (LOOP / "pulso-loop.timer").read_text(encoding="utf-8")
        self.assertIn("OnBootSec=10min", timer)
        self.assertIn("OnUnitActiveSec=6h", timer)
        self.assertNotIn("OnUnitInactiveSec", timer)

    def test_dropin_resets_and_sets_unit_active_sec(self):
        self.assertIn(r"OnUnitActiveSec=\nOnUnitActiveSec=%s\n", PREPARE)
        self.assertNotIn("OnUnitInactiveSec", PREPARE)

    def test_service_has_no_restart_loop_and_no_start_limit(self):
        unit = (LOOP / "pulso-loop.service").read_text(encoding="utf-8")
        self.assertNotRegex(unit, r"(?m)^Restart=")
        self.assertNotRegex(unit, r"(?m)^RestartSec=")
        self.assertIn("StartLimitIntervalSec=0", unit)
        self.assertNotIn("StartLimitBurst", unit)


class StackUnitDoesNotRecreateOnRetry(unittest.TestCase):
    UP = heredoc(USER_DATA, "UP")

    def test_unit_starts_through_the_up_script_and_documents_tmpfs(self):
        self.assertIn("ExecStart=/usr/local/bin/pulso-stack-up", USER_DATA)
        self.assertNotRegex(USER_DATA, r"(?m)^ExecStart=.*--force-recreate")
        self.assertIn("tmpfs", USER_DATA)
        self.assertRegex(USER_DATA, r"(?m)^ExecStopPost=.*pulso/\.stack-created")
        self.assertRegex(USER_DATA, r"(?m)^RestartSec=(60|[1-9][0-9]{2,})$")

    def run_up(self, tmp: Path, fail_start: bool) -> list[str]:
        fake = tmp / "bin"
        fake.mkdir(exist_ok=True)
        log = tmp / "calls.log"
        docker = fake / "docker"
        docker.write_text(
            '#!/bin/bash\necho "$*" >> "%s"\n'
            'if [ "%s" = 1 ]; then case "$*" in *--no-start*) exit 0;; *) exit 1;; esac; fi\nexit 0\n'
            % (log.as_posix(), "1" if fail_start else "0"),
            encoding="utf-8",
        )
        docker.chmod(docker.stat().st_mode | stat.S_IEXEC)
        script = tmp / "up.sh"
        script.write_text(untemplate(self.UP).replace("/usr/bin/docker", "docker"), encoding="utf-8", newline="\n")
        env = dict(os.environ, PATH=f"{fake.as_posix()}:{os.environ['PATH']}", STACK_MARK=(tmp / "mark").as_posix())
        subprocess.run([BASH, script.as_posix()], env=env, capture_output=True, text=True)
        return log.read_text(encoding="utf-8").splitlines() if log.exists() else []

    @unittest.skipUnless(BASH, "bash required")
    def test_first_start_recreates_once_then_retries_do_not(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            first = self.run_up(tmp, fail_start=True)  # a dependency is unhealthy: the start fails
            self.assertTrue(any("--force-recreate" in c and "--no-start" in c for c in first), first)
            self.assertTrue((tmp / "mark").exists(), "marker is set once the containers were created")
            (tmp / "calls.log").unlink()
            retry = self.run_up(tmp, fail_start=False)
            self.assertEqual(len(retry), 1, retry)
            self.assertNotIn("--force-recreate", retry[0])
            self.assertIn("up -d --remove-orphans", retry[0])


@unittest.skipUnless(BASH, "bash required")
class PlaceholderAndEnvFileChecks(unittest.TestCase):
    GOOD = {
        "gateway.env": "OPENROUTER_API_KEY=sk-x\nJEV_API_KEY=k\n",
        "agent.env": "AGENTCORE_JEV_API_KEY=k\n",
        "langfuse.env": "LANGFUSE_PUBLIC_KEY=pk\nLANGFUSE_SECRET_KEY=sk\n",
    }
    COMPOSE = {"compose.yaml": "services:\n  a:\n    env_file: [/run/pulso/env/gateway.env]\n"}

    def run_checks(self, files: dict[str, str], compose: dict[str, str], dotenv: str = "") -> subprocess.CompletedProcess:
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        env, stack = tmp / "env", tmp / "stack"
        env.mkdir()
        stack.mkdir()
        for n, c in files.items():
            (env / n).write_text(c, encoding="utf-8", newline="\n")
        for n, c in compose.items():
            (stack / n).write_text(c.replace("/run/pulso/env", env.as_posix()), encoding="utf-8", newline="\n")
        (stack / ".env").write_text(dotenv, encoding="utf-8", newline="\n")
        code = "set -euo pipefail\n" + untemplate(block(PREPARE, "required-values-check")) + untemplate(block(PREPARE, "env-files-check"))
        code = code.replace("/run/pulso/env", env.as_posix()).replace("/srv/stack", stack.as_posix())
        return subprocess.run([BASH, "-c", code], capture_output=True, text=True)

    def test_passes_with_real_values(self):
        r = self.run_checks(self.GOOD, self.COMPOSE)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_fails_closed_on_each_human_only_key_and_names_only_the_key(self):
        for fname, var in (("gateway.env", "OPENROUTER_API_KEY"), ("gateway.env", "JEV_API_KEY"), ("agent.env", "AGENTCORE_JEV_API_KEY")):
            files = dict(self.GOOD)
            files[fname] = re.sub(rf"{var}=.*", f"{var}=CHANGE_ME", files[fname])
            r = self.run_checks(files, self.COMPOSE)
            self.assertNotEqual(r.returncode, 0, var)
            self.assertIn(var, r.stderr)
            self.assertIn("CHANGE_ME", r.stderr)

    def test_langfuse_placeholders_only_warn(self):
        files = dict(self.GOOD, **{"langfuse.env": "LANGFUSE_PUBLIC_KEY=CHANGE_ME\nLANGFUSE_SECRET_KEY=CHANGE_ME\n"})
        r = self.run_checks(files, self.COMPOSE)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("WARNING", r.stderr)
        self.assertIn("LANGFUSE_PUBLIC_KEY", r.stderr)

    def test_missing_env_file_referenced_by_a_compose_file_fails(self):
        compose = {"compose.yaml": "services:\n  a:\n    env_file: [/run/pulso/env/gateway.env, /run/pulso/env/tools.env]\n"}
        r = self.run_checks(self.GOOD, compose)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("tools.env", r.stderr)

    def test_follows_the_compose_file_list_of_dotenv(self):
        compose = dict(self.COMPOSE, **{"extra.yaml": "services:\n  b:\n    env_file: [/run/pulso/env/nope.env]\n"})
        r = self.run_checks(self.GOOD, compose, dotenv="COMPOSE_FILE=compose.yaml:extra.yaml\n")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("nope.env", r.stderr)

    def test_checks_run_after_the_env_files_are_rendered(self):
        self.assertGreater(PREPARE.index("# BEGIN required-values-check"), PREPARE.index("chmod 600 /run/pulso/env/*.env"))
        self.assertGreater(PREPARE.index("# BEGIN env-files-check"), PREPARE.index("# BEGIN required-values-check"))


class EmptyCatalogSeed(unittest.TestCase):
    def test_seeds_empty_object_only_when_no_publication_and_never_overwrites(self):
        else_branch = PREPARE.split('echo "WARNING: no publication at', 1)[1].split("%{ endif", 1)[0]
        self.assertIn("/srv/data/tools/current/field_classification.json", else_branch)
        self.assertIn("'{}'", else_branch)
        self.assertRegex(else_branch, r"\[ -s /srv/data/tools/current/field_classification\.json \] \|\|")


class Docs(unittest.TestCase):
    def test_docs_describe_the_batch(self):
        day = (DOCS / "infra-day-one.md").read_text(encoding="utf-8")
        run = (DOCS / "run-and-health.md").read_text(encoding="utf-8")
        self.assertIn("Controlled replacement window", day)
        for needle in ("CHANGE_ME", "OnUnitActiveSec", "pulso-stack-up"):
            self.assertIn(needle, day + run + (DOCS / "engine-loop.md").read_text(encoding="utf-8"), needle)
        self.assertNotIn("up -d --remove-orphans --force-recreate", run)
        self.assertNotIn("OnUnitInactiveSec", (DOCS / "engine-loop.md").read_text(encoding="utf-8").split("## Exit status")[0])


if __name__ == "__main__":
    unittest.main()
