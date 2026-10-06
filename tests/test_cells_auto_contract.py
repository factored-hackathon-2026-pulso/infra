"""Contract of the automatic bank cells (docs/auto-loader.md, "Cells"): the loader produces cells from landing/bank with the engine
image's bank_cells.py, gates them (k>=10), stages them under bank_cells/<run>/ and moves bank_cells/latest.json only after the pipeline.

Offline: bash with fake `aws` (a local directory is the bucket), `docker`, `chown`, `logger` and `df`. Nothing touches AWS or real data.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOADER = ROOT / "deploy" / "hackathon" / "engine" / "loader"
PRODUCER = LOADER / "run-bank-cells.sh"
TABLES = ["call_center_interactions", "complaints", "satisfaction_surveys", "digital_events", "campaign_sends", "transactions"]
REFS = ["customers.csv", "marketing_campaigns.csv"]
CELL = {"metric": "M1", "dims": {"reason_category": "Queja", "channel": "Phone"}, "half": "discovery", "period": "ALL",
        "numerator": 120, "denominator": 600}


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


def find_bash() -> str | None:
    for c in (r"C:\Program Files\Gitinash.exe", shutil.which("bash")):
        if c and Path(c).exists():
            r = subprocess.run([c, "-c", "uname -s; command -v timeout awk find sha256sum >/dev/null && echo tools"], capture_output=True, text=True)
            kind = r.stdout.split()[0] if r.stdout.split() else ""
            if r.returncode == 0 and "tools" in r.stdout and (kind.startswith(("MINGW", "MSYS")) if os.name == "nt" else True):
                return c
    return None


FAKE_AWS = r'''#!/bin/bash
loc() { case "$1" in s3://*) echo "$FAKE_S3/${1#s3://}";; *) echo "$1";; esac; }
echo "aws $*" >> "$FAKE_LOG"
svc="$1"; op="$2"; shift 2
pos=()
while [ $# -gt 0 ]; do
  case "$1" in --exclude|--include|--sse) shift 2;; --*) shift;; *) pos+=("$1"); shift;; esac
done
case "$svc $op" in
  "s3 ls") d="$(loc "${pos[0]}")"; [ -d "$d" ] || exit 1
           echo "   Total Objects: 1"; echo "   Total Size: $(find "$d" -type f -exec cat {} + | wc -c | tr -d ' ')";;
  "s3 sync") d="$(loc "${pos[0]}")"; [ -d "$d" ] || exit 1; mkdir -p "${pos[1]}"; cp -r "$d/." "${pos[1]}/";;
  "s3 cp") s="$(loc "${pos[0]}")"; t="$(loc "${pos[1]}")"; [ -f "$s" ] || exit 1; mkdir -p "$(dirname "$t")"; cp "$s" "$t";;
  *) exit 2;;
esac
'''
FAKE_DOCKER = r'''#!/bin/bash
echo "docker $*" >> "$FAKE_LOG"
[ "$1" = "run" ] || exit 0
out=""
for a in "$@"; do case "$a" in *:/out) out="${a%:/out}";; esac; done
[ -n "$out" ] && [ -n "${FAKE_CELLS:-}" ] && printf '%s' "$FAKE_CELLS" > "$out/cells.ndjson"
exit "${FAKE_DOCKER_RC:-0}"
'''


class Producer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bash = find_bash()
        cls.s = read(PRODUCER)

    def setUp(self):
        if not self.bash:
            self.skipTest("a GNU bash with timeout/awk is not available")
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        bindir = self.tmp / "bin"
        bindir.mkdir()
        for name, body in (("aws", FAKE_AWS), ("docker", FAKE_DOCKER), ("chown", "#!/bin/bash\nexit 0\n"), ("logger", "#!/bin/bash\nexit 0\n"),
                           ("df", "#!/bin/bash\nprintf 'Filesystem 1B-blocks Used Available Use%% Mounted\\nx 1 1 99999999999 1%% /\\n'\n")):
            f = bindir / name
            f.write_text(body, encoding="utf-8", newline="\n")
            f.chmod(f.stat().st_mode | stat.S_IEXEC)
        self.s3 = self.tmp / "s3"
        self.bucket = self.s3 / "bkt" / "landing" / "bank"
        for t in TABLES:
            d = self.bucket / t / "year=2024"
            d.mkdir(parents=True)
            (d / "x.csv").write_text("a,b\n1,2\n", encoding="utf-8")
        for r in REFS:
            (self.bucket / r).write_text("a,b\n1,2\n", encoding="utf-8")
        self.env_file = self.tmp / "stack.env"
        self.env_file.write_text("PULSO_IMAGE=registry/pulso@sha256:abc\nPIPELINE_IMAGE=registry/pipe@sha256:def\n", encoding="utf-8")
        self.work = self.tmp / "work" / "RUNKEY"
        self.work.mkdir(parents=True)
        self.log = self.tmp / "calls.log"
        self.log.write_text("", encoding="utf-8")

    def run_producer(self, **extra):
        env = {**os.environ, "PATH": f"{(self.tmp / 'bin').as_posix()}:{os.environ['PATH']}", "FAKE_S3": self.s3.as_posix(),
               "FAKE_LOG": self.log.as_posix(), "FAKE_CELLS": json.dumps(CELL, sort_keys=True) + "\n", "CELLS_OUT": (self.work / "cells.ndjson").as_posix(),
               "RUN_KEY": "RUNKEY", "LOADER_BUCKET": "bkt", "LOADER_DATASET_PREFIX": "landing/bank", "LOADER_K_MIN": "10",
               "LOADER_STACK_ENV": self.env_file.as_posix(), "AWS_ACCESS_KEY_ID": "test-only-not-a-secret"}
        env.update(extra)
        return subprocess.run([self.bash, PRODUCER.as_posix()], capture_output=True, text=True, env=env)

    def calls(self) -> str:
        return read(self.log)

    def test_syntax(self):
        r = subprocess.run([self.bash, "-n", PRODUCER.as_posix()], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_happy_path_syncs_only_the_eight_inputs_and_runs_the_aggregator_isolated(self):
        r = self.run_producer()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        out = self.work / "cells.ndjson"
        self.assertTrue(out.is_file() and out.stat().st_size > 0)
        calls = self.calls()
        for t in TABLES:
            self.assertIn(f"s3://bkt/landing/bank/{t}/", calls)
        for ref in REFS:
            self.assertIn(f"landing/bank/{ref}", calls)
        self.assertNotIn("call_transcripts", calls, "only what the aggregator reads is downloaded (no transcripts, no products)")
        run = next(c for c in calls.splitlines() if c.startswith("docker run"))
        for flag in ("--network none", "--read-only", "--cap-drop ALL", "--memory 1g", "--memory-swap 1g", "--user 10001:10001",
                     "/in:ro", "--entrypoint python3", "registry/pulso@sha256:abc", "/opt/pulso/aggregate/bank_cells.py", "--k 10"):
            self.assertIn(flag, run)
        self.assertNotIn("AWS_", run)
        self.assertNotIn("--env-file", run)
        self.assertFalse((self.work / "in").exists() and any((self.work / "in").iterdir()), "scratch inputs are removed")
        gate = subprocess.run(["py" if os.name == "nt" else "python3", str(LOADER / "check_cells_k.py"), str(out)], capture_output=True, text=True)
        self.assertEqual(gate.returncode, 0, gate.stderr)

    def test_same_run_key_reuses_staged_cells_without_recompute(self):
        body = json.dumps(CELL, sort_keys=True) + "\n"
        import hashlib
        stage = self.s3 / "bkt" / "lake" / "gold_analytics" / "bank_cells" / "RUNKEY"
        stage.mkdir(parents=True)
        (stage / "cells.ndjson").write_text(body, encoding="utf-8", newline="\n")
        (stage / "MANIFEST.json").write_text(json.dumps({"run": "RUNKEY", "sha256": hashlib.sha256(body.encode()).hexdigest(), "rows": 1, "k_min": 10}), encoding="utf-8")
        r = self.run_producer()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("docker run", self.calls())
        self.assertNotIn("landing/bank/transactions", self.calls())
        self.assertEqual(read(self.work / "cells.ndjson"), body)

    def test_a_staged_copy_with_a_wrong_sha_is_recomputed(self):
        stage = self.s3 / "bkt" / "lake" / "gold_analytics" / "bank_cells" / "RUNKEY"
        stage.mkdir(parents=True)
        (stage / "cells.ndjson").write_text("tampered\n", encoding="utf-8")
        (stage / "MANIFEST.json").write_text(json.dumps({"run": "RUNKEY", "sha256": "0" * 64}), encoding="utf-8")
        r = self.run_producer()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("docker run", self.calls())
        self.assertNotIn("tampered", read(self.work / "cells.ndjson"))

    def test_a_missing_table_fails_the_run_instead_of_dropping_its_metrics(self):
        shutil.rmtree(self.bucket / "digital_events")
        r = self.run_producer()
        self.assertEqual(r.returncode, 66, r.stdout + r.stderr)
        self.assertNotIn("docker run", self.calls())
        self.assertFalse((self.work / "cells.ndjson").exists())

    def test_a_missing_reference_file_fails_the_run(self):
        (self.bucket / "customers.csv").unlink()
        self.assertEqual(self.run_producer().returncode, 66)

    def test_k_below_ten_is_refused(self):
        for k in ("5", "abc"):
            self.assertEqual(self.run_producer(LOADER_K_MIN=k).returncode, 78)
        self.assertNotIn("docker run", self.calls())

    def test_aggregator_failure_fails_the_run_and_writes_nothing(self):
        r = self.run_producer(FAKE_DOCKER_RC="2", FAKE_CELLS="")
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.work / "cells.ndjson").exists())

    def test_the_producer_never_publishes(self):
        self.assertNotIn("latest.json", self.s)
        self.assertNotRegex(self.s, r"s3 (cp|sync)[^\n]*\s+s3://[^\n]*\s+s3://")
        self.assertNotRegex(self.s, r"aws s3 cp [^\n]*\"\$CELLS_OUT\" \"?s3://")
        self.assertNotRegex(self.s, r"(?m)^\s*set -x|bash -x")


class LoaderOrdering(unittest.TestCase):
    def setUp(self):
        self.s = read(LOADER / "pulso-loader.sh")

    def test_syntax(self):
        bash = find_bash()
        if not bash:
            self.skipTest("bash not available")
        r = subprocess.run([bash, "-n", (LOADER / "pulso-loader.sh").as_posix()], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_gate_stage_reassume_pipeline_pointer_done_in_that_order(self):
        s = self.s
        order = [s.index('bash -c "$LOADER_CELLS_CMD"'), s.index('python3 "$CHECK" "$CELLS"'), s.index('"$CELLS_P/$RUN_KEY/cells.ndjson"'),
                 s.index('STEP="pipeline"\nassume_loader'), s.index('run_pipeline "$IMAGE" --steps "$STEPS"'),
                 s.index('"$CELLS_P/latest.json"'), s.index('lake/loader/done/$RUN_KEY.json" --sse')]
        self.assertEqual(order, sorted(order), "cells export, gate, staging, fresh session, pipeline, pointer last, done marker")

    def test_pointer_is_written_once(self):
        self.assertEqual(self.s.count('"$CELLS_P/latest.json" --sse'), 1)

    def test_role_is_assumed_again_and_creds_still_sourced_in_one_place(self):
        self.assertEqual(len(re.findall(r"(?m)^assume_loader$", self.s)), 2)
        self.assertEqual(len(re.findall(r'\. "\$CREDS"', self.s)), 1)
        self.assertNotRegex(self.s, r"(?m)^\s*export\s+AWS_")

    def test_failure_names_the_step(self):
        self.assertGreaterEqual(self.s.count("at step $STEP"), 2)
        for step in ("cells-export", "cells-gate", "cells-stage", "pipeline", "cells-publish"):
            self.assertIn(f'STEP="{step}"', self.s)

    def test_cells_command_gets_the_run_key_and_k(self):
        self.assertIn('RUN_KEY="$RUN_KEY"', self.s)
        self.assertIn('LOADER_K_MIN="$LOADER_K_MIN"', self.s)


class Wiring(unittest.TestCase):
    def test_default_command_is_the_bundled_producer(self):
        v = read(ROOT / "terraform" / "envs" / "hackathon" / "variables.tf")
        self.assertRegex(v, r'variable "loader_cells_cmd" \{[^}]*default\s*=\s*"/usr/local/lib/pulso-loader/run-bank-cells\.sh"')

    def test_bundle_and_install(self):
        m = read(ROOT / "terraform" / "envs" / "hackathon" / "main.tf")
        self.assertIn('"loader/run-bank-cells.sh"', m)
        p = read(ROOT / "terraform" / "modules" / "hackathon_compute" / "templates" / "prepare.sh.tftpl")
        self.assertIn("install -m 755 /srv/stack/loader/run-bank-cells.sh /usr/local/lib/pulso-loader/run-bank-cells.sh", p)

    def test_producer_input_contract_matches_the_engine_aggregator(self):
        s = read(PRODUCER)
        m = re.search(r'TABLES="([^"]+)"', s)
        self.assertEqual(m.group(1).split(), TABLES)
        self.assertEqual(re.search(r'REFS="([^"]+)"', s).group(1).split(), REFS)
        self.assertIn("/opt/pulso/aggregate/bank_cells.py", s)


if __name__ == "__main__":
    unittest.main()
