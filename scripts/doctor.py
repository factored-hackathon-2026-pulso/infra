"""Read-only Pulso development preflight; implementation proceeds by TDD."""
import argparse
import json
from pathlib import Path


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
        json.loads(args.config.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        print(json.dumps({"status": "failed", "checks": [{
            "code": "config_invalid", "status": "failed",
            "remediation": "Provide readable UTF-8 JSON configuration.",
        }]}))
        return 1
    print(json.dumps({"status": "blocked", "checks": [{
        "code": "preflight_not_implemented", "status": "blocked",
        "remediation": "Tool and dependency checks are pending the next U01 slice.",
    }]}))
    return 1

if __name__ == "__main__":
    raise SystemExit(main())
