"""Exercise the doctor process, not private collaborators."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

DOCTOR = Path(__file__).resolve().parents[1] / "scripts" / "doctor.py"


class DoctorContractTest(unittest.TestCase):
    def test_tools_profile_accepts_versioned_probe_deadline(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text(json.dumps({
                "schema_version": 1, "profile": "tools", "checks": ["python"],
                "probe_timeout_seconds": 2,
            }), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(DOCTOR), "--config", str(config), "--json"],
                capture_output=True, text=True, timeout=10, check=False,
            )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(json.loads(result.stdout)["checks"][0]["code"], "python_available")

    def test_tools_profile_checks_installed_git_and_python(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text(json.dumps({
                "schema_version": 1, "profile": "tools", "checks": ["git", "python"],
            }), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(DOCTOR), "--config", str(config), "--json"],
                capture_output=True, text=True, timeout=15, check=False,
            )
        self.assertEqual(result.returncode, 0, result.stdout)
        report = json.loads(result.stdout)
        self.assertEqual([item["code"] for item in report["checks"]],
                         ["git_available", "python_available"])

    def test_missing_git_is_failed_without_echoing_probe_output(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text(json.dumps({
                "schema_version": 1, "profile": "tools", "checks": ["git"],
            }), encoding="utf-8")
            environment = dict(os.environ, PATH=directory)
            result = subprocess.run(
                [sys.executable, str(DOCTOR), "--config", str(config), "--json"],
                capture_output=True, text=True, timeout=10, check=False, env=environment,
            )
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertEqual(report["checks"][0]["code"], "git_missing")
        self.assertTrue(report["checks"][0]["remediation"])

    def test_invalid_configuration_is_rejected_before_running_tools(self):
        invalid = [
            {}, {"schema_version": True, "profile": "stack"},
            {"schema_version": 2, "profile": "stack"},
            {"schema_version": 1, "profile": "tools", "checks": []},
            {"schema_version": 1, "profile": "tools", "checks": ["shell"]},
            {"schema_version": 1, "profile": "tools", "checks": ["python", "python"]},
            {"schema_version": 1, "profile": "tools", "checks": ["python"], "command": "sensitive_fixture"},
            *[{"schema_version": 1, "profile": "tools", "checks": ["python"],
               "probe_timeout_seconds": deadline} for deadline in (True, 0, -1, 31, 1.5, "5", None)],
        ]
        for value in invalid:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                config = Path(directory) / "config.json"
                config.write_text(json.dumps(value), encoding="utf-8")
                result = subprocess.run(
                    [sys.executable, str(DOCTOR), "--config", str(config), "--json"],
                    capture_output=True, text=True, timeout=10, check=False,
                )
                self.assertEqual(result.returncode, 1)
                report = json.loads(result.stdout)
                self.assertEqual(report["checks"][0]["code"], "config_invalid")
                self.assertNotIn("sensitive_fixture", result.stdout + result.stderr)

    def test_tools_profile_checks_real_python_without_claiming_stack_health(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text(json.dumps({
                "schema_version": 1, "profile": "tools", "checks": ["python"],
            }), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(DOCTOR), "--config", str(config), "--json"],
                capture_output=True, text=True, timeout=10, check=False,
            )
        self.assertEqual(result.returncode, 0)
        report = json.loads(result.stdout)
        self.assertEqual(report["scope"], "tools")
        self.assertEqual(report["checks"][0]["code"], "python_available")
        self.assertEqual(report["checks"][0]["status"], "passed")

    def test_configuration_root_must_be_an_object(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text('[]', encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(DOCTOR), "--config", str(config), "--json"],
                capture_output=True, text=True, timeout=10, check=False,
            )
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertEqual(report["checks"][0]["code"], "config_invalid")

    def test_existing_config_does_not_claim_unimplemented_checks_passed(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text('{"schema_version":1,"profile":"stack"}', encoding="utf-8")
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
