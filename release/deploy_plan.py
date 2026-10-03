"""Deploy orchestrator for plan 17.3.9 (order of the nine steps), offline only.

This module holds the control logic, not AWS calls. Every step is an injected
executor ``callable(manifest) -> bool``. ``--dry-run`` uses built-in executors
that only record the step; a real run needs executors supplied by an authorised
operator and is refused otherwise (``NoExecutor``). A failing step ends the run
as ``blocked`` and no later step runs, so a failed ``core_migrate`` can never be
followed by a service update. A dry run proves orchestration order only, never a
deployment.

Usage: python release/deploy_plan.py --dry-run <manifest.json>
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import validate_manifest  # noqa: E402

# Step order = plan 17.3.9 deploy order. Each AWS-touching step requires human authorisation.
STEPS = [
    "validate",              # 0 offline manifest check (M-01..M-10)
    "apply_infra",           # 1 human terraform apply of the validated plan (only if diff)
    "snapshots",             # 2 manual RDS snapshots (Core and Pulso)
    "core_migrate",          # 3 core-migrate with the new image, schema_digest verified
    "schema_smoke",          # 4 schema smoke with the RO role
    "update_core_runtime",   # 5 update pulso-core-runtime, /readyz 200
    "engine_migrate",        # 6 engine-migrate, migrations_head verified
    "update_engine_services",  # 7 core-exporter, then engine api/worker
    "smoke",                 # 8 seed, registry-wire-contract, bounded E2E
    "receipt",               # 9 private deployment receipt
]


class NoExecutor(RuntimeError):
    """A real run was requested without operator-supplied executors."""


def _dry_executors(log):
    def make(step):
        def run(_manifest):
            log.append(step)
            return True
        return run
    return {s: make(s) for s in STEPS}


def run(manifest, executors, dry_run=True):
    """Execute STEPS in order; return {status, completed, blocked_at, reason, ...}."""
    if executors is None:
        if not dry_run:
            raise NoExecutor("a real run needs operator-supplied executors; use --dry-run to rehearse")
        executors = _dry_executors([])
    missing = [s for s in STEPS if s not in executors]
    if missing:
        raise NoExecutor(f"missing executors: {missing}")
    result = {
        "status": "completed", "dry_run": dry_run, "completed": [], "blocked_at": None,
        "reason": None, "smoke_counts_as_success": False,
    }
    check = validate_manifest.validate(manifest)
    if check["errors"]:
        result.update(status="blocked", blocked_at="validate",
                      reason=[e["code"] for e in check["errors"]])
        return result
    result["completed"].append("validate")
    for step in STEPS[1:]:
        if not executors[step](manifest):
            result.update(status="blocked", blocked_at=step, reason="step failed")
            return result
        result["completed"].append(step)
    result["smoke_counts_as_success"] = check["smoke_counts_as_success"] and not dry_run
    if dry_run:
        # A rehearsal never counts as a successful deployment smoke (M-07).
        result["smoke_counts_as_success"] = False
    return result


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("manifest")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)
    if not args.dry_run:
        print("refused: only --dry-run is implemented; real execution needs authorised executors",
              file=sys.stderr)
        return 2
    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    result = run(manifest, None, dry_run=True)
    print(json.dumps(result, indent=2))
    return 0 if result["status"] == "completed" else 1


if __name__ == "__main__":
    sys.exit(main())
