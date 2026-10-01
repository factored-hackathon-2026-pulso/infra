"""Read-only Pulso development preflight; implementation proceeds by TDD."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import shutil

TOOLS = {"python": None, "git": "git"}


def probe(tool, timeout_seconds=5):
    executable = sys.executable if tool == "python" else shutil.which(TOOLS[tool])
    if not executable:
        return {"code": f"{tool}_missing", "status": "failed",
                "remediation": f"Install {tool} or expose it in this session's PATH."}
    try:
        result = subprocess.run([executable, "--version"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                timeout=timeout_seconds, check=False)
        passed = result.returncode == 0
        code = f"{tool}_available" if passed else f"{tool}_probe_failed"
    except subprocess.TimeoutExpired:
        passed, code = False, f"{tool}_probe_timeout"
    except OSError:
        passed, code = False, f"{tool}_probe_failed"
    return {"code": code, "status": "passed" if passed else "failed",
            "remediation": "" if passed else f"Check the local {tool} installation."}


def probe_podman(timeout_seconds=5):
    executable = shutil.which("podman")
    if not executable:
        return {"code": "podman_missing", "status": "failed",
                "remediation": "Install Podman or expose it in this session's PATH."}
    try:
        result = subprocess.run([executable, "info", "--format", "json"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                timeout=timeout_seconds, check=False)
    except subprocess.TimeoutExpired:
        code = "podman_backend_timeout"
    except OSError:
        code = "podman_backend_unavailable"
    else:
        code = "podman_backend_ready" if result.returncode == 0 else "podman_backend_unavailable"
    passed = code == "podman_backend_ready"
    return {"code": code, "status": "passed" if passed else "failed",
            "remediation": "" if passed else "Start or repair the Podman backend; do not create a machine automatically."}


def valid_config(config):
    if not isinstance(config, dict) or type(config.get("schema_version")) is not int:
        return False
    if config["schema_version"] != 1:
        return False
    if config.get("profile") == "stack":
        if not set(config) <= {"schema_version", "profile", "probe_timeout_seconds"}:
            return False
        deadline = config.get("probe_timeout_seconds", 5)
        return type(deadline) is int and 1 <= deadline <= 30
    if config.get("profile") != "tools" or not {"schema_version", "profile", "checks"} <= set(config) or not set(config) <= {"schema_version", "profile", "checks", "probe_timeout_seconds"}:
        return False
    deadline = config.get("probe_timeout_seconds", 5)
    if type(deadline) is not int or not 1 <= deadline <= 30:
        return False
    checks = config["checks"]
    return (isinstance(checks, list) and bool(checks)
            and all(isinstance(check, str) and check in TOOLS for check in checks)
            and len(set(checks)) == len(checks))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if not args.config.is_file():
        report = {"status": "failed", "checks": [{
            "code": "config_missing", "status": "failed",
            "remediation": "Provide a versioned preflight configuration file.",
        }]}
        print(json.dumps(report))
        return 1
    try:
        config = json.loads(args.config.read_text(encoding="utf-8"))
        if not valid_config(config):
            raise ValueError("Unsupported preflight configuration")
    except (OSError, UnicodeError, ValueError):
        print(json.dumps({"status": "failed", "checks": [{
            "code": "config_invalid", "status": "failed",
            "remediation": "Provide readable UTF-8 JSON matching schema version 1 and allowed checks/settings.",
        }]}))
        return 1
    if config["profile"] == "tools":
        checks = [probe(tool, config.get("probe_timeout_seconds", 5)) for tool in config["checks"]]
        passed = all(check["status"] == "passed" for check in checks)
        print(json.dumps({"status": "passed" if passed else "failed", "scope": "tools", "checks": checks}))
        return 0 if passed else 1
    check = probe_podman(config.get("probe_timeout_seconds", 5))
    passed = check["status"] == "passed"
    print(json.dumps({"status": "passed" if passed else "failed", "scope": "stack", "checks": [check]}))
    return 0 if passed else 1

if __name__ == "__main__":
    raise SystemExit(main())
