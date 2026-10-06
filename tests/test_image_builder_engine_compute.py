"""The engine image compiles Rust inside docker build: its CodeBuild project must not run on the 3 GB / 60 minute defaults."""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAIN = (ROOT / "terraform" / "envs" / "hackathon" / "main.tf").read_text(encoding="utf-8")
MODULE = (ROOT / "terraform" / "modules" / "image_builder" / "main.tf").read_text(encoding="utf-8")
MODULE_VARS = (ROOT / "terraform" / "modules" / "image_builder" / "variables.tf").read_text(encoding="utf-8")


class EngineBuildCompute(unittest.TestCase):
    def test_engine_service_sets_its_own_compute_and_timeout(self):
        line = next(l for l in MAIN.splitlines() if l.strip().startswith('"pulso-engine"'))
        self.assertIn('compute_type = coalesce(var.image_builder_engine_compute_type, "BUILD_GENERAL1_MEDIUM")', line)
        self.assertRegex(line, r"timeout_mins\s*=\s*(1[2-9]\d|[2-9]\d\d)")

    def test_module_honours_per_service_overrides(self):
        self.assertIn("coalesce(each.value.compute_type, var.compute_type)", MODULE)
        self.assertIn("coalesce(each.value.timeout_mins, var.timeout_mins)", MODULE)
        self.assertRegex(MODULE_VARS, r"compute_type\s*=\s*optional\(string\)")
        self.assertRegex(MODULE_VARS, r"timeout_mins\s*=\s*optional\(number\)")

    def test_poll_loop_outlasts_the_longest_build_timeout(self):
        text = (ROOT / "scripts" / "aws-prod.ps1").read_text(encoding="utf-8")
        n = int(re.search(r"for \(\$i = 0; \$i -lt (\d+); \$i\+\+\)\s*\{\s*\$now = ", text).group(1))
        self.assertGreaterEqual(n * 15 / 60, 120)


if __name__ == "__main__":
    unittest.main()
