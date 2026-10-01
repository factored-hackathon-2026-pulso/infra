"""Exercise the doctor process, not private collaborators."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

DOCTOR = Path(__file__).resolve().parents[1] / "scripts" / "doctor.py"


class DoctorContractTest(unittest.TestCase):
    def test_existing_config_does_not_claim_unimplemented_checks_passed(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text('{}', encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(DOCTOR), "--config", str(config), "--json"],
                capture_output=True, text=True, timeout=10, check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        report = json.loads(result.stdout)
        self.assertEqual(report["status"], "blocked")
        self.assertEqual(report["checks"][0]["code"], "preflight_not_implemented")
        self.assertTrue(report["checks"][0]["remediation"])

    def test_malformed_configuration_is_reported_without_echoing_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text('{"private": "sensitive_fixture",', encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(DOCTOR), "--config", str(config), "--json"],
                capture_output=True, text=True, timeout=10, check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        report = json.loads(result.stdout)
        self.assertEqual(report["checks"][0]["code"], "config_invalid")
        self.assertNotIn("sensitive_fixture", result.stdout + result.stderr)

    def test_missing_config_is_failure_not_healthy_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "missing.json"
            result = subprocess.run(
                [sys.executable, str(DOCTOR), "--config", str(missing), "--json"],
                capture_output=True, text=True, timeout=10, check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        report = json.loads(result.stdout)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["checks"][0]["code"], "config_missing")


if __name__ == "__main__":
    unittest.main()
