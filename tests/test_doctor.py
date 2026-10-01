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
    def test_stack_profile_reports_reachable_podman_backend(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text(json.dumps({
                "schema_version": 1, "profile": "stack",
            }), encoding="utf-8")
            if os.name == "nt":
                podman = Path(directory) / "podman.cmd"
                podman.write_text("@echo off\r\nexit /b 0\r\n", encoding="utf-8")
                path_extensions = ".COM;.EXE;.BAT;.CMD"
            else:
                podman = Path(directory) / "podman"
                podman.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                podman.chmod(0o700)
                path_extensions = os.environ.get("PATHEXT", "")
            environment = dict(os.environ, PATH=directory, PATHEXT=path_extensions)
            result = subprocess.run(
                [sys.executable, str(DOCTOR), "--config", str(config), "--json"],
                capture_output=True, text=True, timeout=10, check=False, env=environment,
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["checks"][0]["code"], "podman_backend_ready")

    def test_stack_profile_accepts_versioned_probe_deadline(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text(json.dumps({
                "schema_version": 1, "profile": "stack", "probe_timeout_seconds": 2,
            }), encoding="utf-8")
            environment = dict(os.environ, PATH=directory)
            result = subprocess.run(
                [sys.executable, str(DOCTOR), "--config", str(config), "--json"],
                capture_output=True, text=True, timeout=10, check=False, env=environment,
            )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)["checks"][0]["code"], "podman_missing")

    def test_stack_profile_times_out_without_echoing_podman_output(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text(json.dumps({
                "schema_version": 1, "profile": "stack", "probe_timeout_seconds": 1,
            }), encoding="utf-8")
            if os.name == "nt":
                podman = Path(directory) / "podman.cmd"
                podman.write_text(
                    "@echo sensitive_podman_output\r\n%SystemRoot%\\System32\\ping.exe -n 4 127.0.0.1 >nul\r\nexit /b 0\r\n",
                    encoding="utf-8",
                )
                path_extensions = ".COM;.EXE;.BAT;.CMD"
            else:
                podman = Path(directory) / "podman"
                podman.write_text("#!/bin/sh\nprintf sensitive_podman_output\nsleep 3\n", encoding="utf-8")
                podman.chmod(0o700)
                path_extensions = os.environ.get("PATHEXT", "")
            environment = dict(os.environ, PATH=directory, PATHEXT=path_extensions)
            result = subprocess.run(
                [sys.executable, str(DOCTOR), "--config", str(config), "--json"],
                capture_output=True, text=True, timeout=10, check=False, env=environment,
            )
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertEqual(report["checks"][0]["code"], "podman_backend_timeout")
        self.assertNotIn("sensitive_podman_output", result.stdout + result.stderr)

    def test_stack_profile_uses_only_the_fixed_podman_info_argv(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "config.json"
            arguments = root / "arguments.txt"
            config.write_text(json.dumps({"schema_version": 1, "profile": "stack"}), encoding="utf-8")
            if os.name == "nt":
                podman = root / "podman.cmd"
                podman.write_text(
                    f"@echo off\r\necho %* > \"{arguments}\"\r\nexit /b 0\r\n",
                    encoding="utf-8",
                )
                path_extensions = ".COM;.EXE;.BAT;.CMD"
            else:
                podman = root / "podman"
                podman.write_text(
                    f"#!/bin/sh\nprintf '%s' \"$*\" > '{arguments}'\nexit 0\n", encoding="utf-8",
                )
                podman.chmod(0o700)
                path_extensions = os.environ.get("PATHEXT", "")
            environment = dict(os.environ, PATH=directory, PATHEXT=path_extensions)
            result = subprocess.run(
                [sys.executable, str(DOCTOR), "--config", str(config), "--json"],
                capture_output=True, text=True, timeout=10, check=False, env=environment,
            )
            observed_arguments = arguments.read_text(encoding="utf-8").strip()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(observed_arguments, "info --format json")

    def test_stack_profile_fails_when_podman_is_not_available(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text(json.dumps({
                "schema_version": 1, "profile": "stack",
            }), encoding="utf-8")
            environment = dict(os.environ, PATH=directory)
            result = subprocess.run(
                [sys.executable, str(DOCTOR), "--config", str(config), "--json"],
                capture_output=True, text=True, timeout=10, check=False, env=environment,
            )
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["scope"], "stack")
        self.assertEqual(report["checks"][0]["code"], "podman_missing")

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

    def test_stack_profile_does_not_claim_ready_when_podman_is_unusable(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text('{"schema_version":1,"profile":"stack"}', encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(DOCTOR), "--config", str(config), "--json"],
                capture_output=True, text=True, timeout=10, check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        report = json.loads(result.stdout)
        self.assertEqual(report["status"], "failed")
        self.assertIn(report["checks"][0]["code"], {
            "podman_missing", "podman_backend_unavailable", "podman_backend_timeout",
        })
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
