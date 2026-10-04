"""Offline, grep-based evaluation of the machine-checkable items in docs/aws-plan-review-checklist.md.

No AWS credentials, no network, no terraform plan. `--validate` additionally runs
`terraform init -backend=false` + `terraform validate` per env root (needs the provider plugin cached).
Exit code 1 when any FAIL exists; GAP entries are reported but do not fail.
"""

from __future__ import annotations

import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ACCOUNT_ARN = re.compile(r"arn:aws[a-z-]*:[a-z0-9-]*:[a-z0-9-]*:(\d{12}):")
REGION = re.compile(r"\b(?:us|eu|ap|sa|ca|me|af)-(?:east|west|north|south|central|northeast|southeast)-\d\b")
PLACEHOLDER_ACCOUNT = "000000000000"
SWITCHES_OFF = ("bridge_services_enabled", "bridge_ecr_enabled", "engine_platform_enabled",
                "private_endpoints_enabled", "engine_ecr_enabled")
SWITCHES_EXPECTED_BUT_ABSENT = ("data_pipeline_enabled",)
ENVS = ("staging", "prod")


@dataclass(frozen=True)
class Finding:
    severity: str  # FAIL | GAP
    rule: str
    where: str
    detail: str = ""

    def __str__(self) -> str:
        return f"{self.severity} {self.rule} {self.where} {self.detail}".strip()


def _code_lines(path: Path):
    for no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        code = line.split("#", 1)[0] if not line.lstrip().startswith("#") else ""
        if code.strip():
            yield no, code


def scan_tf_dir(directory: Path, skip_tests: bool = True) -> list[Finding]:
    out: list[Finding] = []
    for path in sorted(directory.rglob("*.tf")):
        text = path.read_text(encoding="utf-8")
        where = lambda n: f"{path.relative_to(directory.parent) if directory.parent in path.parents else path.name}:{n}"
        for no, line in _code_lines(path):
            validation = "regex(" in line
            m = ACCOUNT_ARN.search(line)
            if m and not validation and m.group(1) != PLACEHOLDER_ACCOUNT:
                out.append(Finding("FAIL", "hardcoded-account-id", where(no), line.strip()))
            if REGION.search(line) and not validation:
                out.append(Finding("FAIL", "hardcoded-region", where(no), line.strip()))
            if "AdministratorAccess" in line or re.search(r'Action\s*=\s*(\[\s*)?"\*"', line):
                out.append(Finding("FAIL", "admin-policy", where(no), line.strip()))
            if re.search(r"(publicly_accessible|assign_public_ip|map_public_ip_on_launch)\s*=\s*true", line):
                out.append(Finding("FAIL", "public-db", where(no), line.strip()))
        for block in re.finditer(r'resource "aws_vpc_security_group_ingress_rule"[^{]*\{(.*?)\n\}', text, re.S):
            if re.search(r'"(0\.0\.0\.0/0|::/0)"', block.group(1)):
                out.append(Finding("FAIL", "open-ingress", path.name))
        if "envs" not in path.parts and directory.name != "account_assuming":
            continue  # module-internal toggles (e.g. core_runtime_enabled) are gated by the env root switches
        for block in re.finditer(r'variable "(\w+_enabled)"\s*\{(.*?)\n\}', text, re.S):
            if re.search(r"default\s*=\s*true", block.group(2)):
                out.append(Finding("FAIL", "switch-default-on", f"{path.name}:{block.group(1)}"))
    return out


def check_env(root: Path, env: str) -> list[Finding]:
    d = root / "terraform" / "envs" / env
    out: list[Finding] = []
    variables = "\n".join(p.read_text(encoding="utf-8") for p in d.glob("*variables.tf"))
    for name in ("aws_region", "kms_key_arn", "artifact_bucket_name", "source_bucket_name"):
        m = re.search(rf'variable "{name}"\s*\{{(.*?)\}}', variables, re.S)
        if m and "default" in m.group(1):
            out.append(Finding("FAIL", "account-default", f"{env}:{name}"))
    for name in SWITCHES_OFF:
        m = re.search(rf'variable "{name}"\s*\{{(.*?)\n\}}', variables, re.S)
        if not m:
            out.append(Finding("FAIL", "switch-missing", f"{env}:{name}"))
        elif not re.search(r"default\s*=\s*false", m.group(1)):
            out.append(Finding("FAIL", "switch-not-off", f"{env}:{name}"))
    for name in SWITCHES_EXPECTED_BUT_ABSENT:
        if f'variable "{name}"' not in variables:
            out.append(Finding("GAP", "switch-missing", f"{env}:{name}",
                               "data_lake module exists but no env switch wires it (ADR 0006)"))
    versions = (d / "versions.tf").read_text(encoding="utf-8")
    if not re.search(r'backend "s3"\s*\{\s*\}', versions):
        out.append(Finding("FAIL", "backend-not-placeholder", env))
    example = d / "backend.hcl.example"
    if not example.exists() or "replace-with" not in example.read_text(encoding="utf-8"):
        out.append(Finding("FAIL", "backend-example-missing-placeholder", env))
    elif REGION.search(example.read_text(encoding="utf-8")):
        out.append(Finding("GAP", "backend-example-region", env, "example pins a region; harmless but an implicit assumption"))
    main = (d / "main.tf").read_text(encoding="utf-8")
    for tag in ("ManagedBy", "Environment", "Service"):
        if tag not in main:
            out.append(Finding("FAIL", "tag-missing", f"{env}:{tag}"))
    return out


def check_modules(root: Path) -> list[Finding]:
    out: list[Finding] = []
    for m in sorted((root / "terraform" / "modules").iterdir()):
        if m.is_dir() and 'variable "tags"' not in "\n".join(p.read_text(encoding="utf-8") for p in m.glob("variables.tf")):
            if (m / "main.tf").exists() and "tags" not in (m / "main.tf").read_text(encoding="utf-8"):
                out.append(Finding("GAP", "module-no-tags", m.name))
    return out


def run_all(root: Path) -> list[Finding]:
    out = scan_tf_dir(root / "terraform" / "modules") + scan_tf_dir(root / "terraform" / "envs")
    for env in ENVS:
        out += check_env(root, env)
    return out + check_modules(root)


def validate(root: Path) -> list[Finding]:
    out: list[Finding] = []
    for env in ENVS:
        d = root / "terraform" / "envs" / env
        for cmd in (["init", "-backend=false", "-input=false", "-lockfile=readonly"], ["validate"]):
            r = subprocess.run(["terraform", f"-chdir={d}", *cmd], capture_output=True, text=True)
            if r.returncode:
                out.append(Finding("FAIL", f"terraform-{cmd[0]}", env, (r.stderr or r.stdout).strip()[:300]))
                break
    return out


if __name__ == "__main__":
    base = Path(__file__).resolve().parents[1]
    found = run_all(base) + (validate(base) if "--validate" in sys.argv else [])
    for f in found:
        print(f)
    print(f"{sum(f.severity == 'FAIL' for f in found)} FAIL, {sum(f.severity == 'GAP' for f in found)} GAP")
    sys.exit(1 if any(f.severity == "FAIL" for f in found) else 0)
