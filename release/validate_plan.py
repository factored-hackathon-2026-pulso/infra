"""Offline validator for a Terraform plan (plan 17.3.9); never calls AWS or Terraform.

Input is the JSON from ``terraform show -json <plan>`` (or a fixture). Checks:
no world-open ingress, no ``AGENTCORE_ALLOW_DEMO`` in task definitions, no delete
or replace of RDS/secrets/KMS without an explicit marker, only expected resource
types, and (with a manifest) every task-definition image is a digest the
manifest lists. ``mode="apply"`` additionally refuses anything not approved: the
manifest must validate, carry an approval pinned to its digest, and
``infra.plan_digest`` must equal the digest of this plan.

Digests: ``manifest_digest`` is sha256 of the canonical JSON of the manifest
without ``approvals`` and ``signature`` (an approval cannot contain the digest
of itself); ``plan_digest`` is sha256 of the canonical JSON of the plan.

Usage: python release/validate_plan.py <plan.json> [--manifest m.json]
       [--mode plan|apply] [--allow-delete ADDRESS ...]   (exit 0 ok, 1 rejected)
"""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import validate_manifest  # noqa: E402

DEMO_FLAG = "AGENTCORE_ALLOW_DEMO"
STATEFUL_TYPES = {
    "aws_db_instance", "aws_secretsmanager_secret", "aws_kms_key", "aws_kms_alias",
    "aws_db_subnet_group", "aws_db_parameter_group",
}
EXPECTED_TYPES = STATEFUL_TYPES | {
    "aws_cloudwatch_log_group", "aws_cloudwatch_metric_alarm", "aws_cloudwatch_event_rule",
    "aws_cloudwatch_event_target", "aws_ecs_cluster", "aws_ecs_service",
    "aws_ecs_task_definition", "aws_eip", "aws_iam_role", "aws_iam_role_policy",
    "aws_iam_role_policy_attachment", "aws_internet_gateway", "aws_nat_gateway",
    "aws_route", "aws_route_table", "aws_route_table_association", "aws_s3_bucket",
    "aws_s3_bucket_lifecycle_configuration", "aws_s3_bucket_public_access_block",
    "aws_s3_bucket_server_side_encryption_configuration", "aws_s3_bucket_versioning",
    "aws_security_group", "aws_subnet", "aws_vpc", "aws_vpc_endpoint",
    "aws_vpc_security_group_egress_rule", "aws_vpc_security_group_ingress_rule",
    "aws_sns_topic", "aws_sns_topic_policy", "aws_service_discovery_private_dns_namespace",
    "aws_service_discovery_service",
}
OPEN_V4, OPEN_V6 = "0.0.0.0/0", "::/0"


def _canonical(doc):
    return json.dumps(doc, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def plan_digest(plan):
    return "sha256:" + hashlib.sha256(_canonical(plan)).hexdigest()


def manifest_digest(manifest):
    body = {k: v for k, v in manifest.items() if k not in ("approvals", "signature")}
    return "sha256:" + hashlib.sha256(_canonical(body)).hexdigest()


def _err(code, path, message):
    return {"code": code, "path": path, "message": message}


def _is_open(after):
    after = after or {}
    return (
        after.get("cidr_ipv4") == OPEN_V4
        or after.get("cidr_ipv6") == OPEN_V6
        or OPEN_V4 in (after.get("cidr_blocks") or [])
        or OPEN_V6 in (after.get("ipv6_cidr_blocks") or [])
    )


def _open_ingress(rc):
    after = rc["change"].get("after") or {}
    kind = rc["type"]
    if kind == "aws_vpc_security_group_ingress_rule":
        return _is_open(after)
    if kind == "aws_security_group_rule":
        return after.get("type") == "ingress" and _is_open(after)
    if kind == "aws_security_group":
        return any(_is_open(rule) for rule in after.get("ingress") or [])
    return False


def _containers(rc):
    raw = (rc["change"].get("after") or {}).get("container_definitions")
    if not raw:
        return []
    try:
        data = json.loads(raw) if isinstance(raw, str) else raw
    except ValueError:
        return []
    return data if isinstance(data, list) else []


def _manifest_images(manifest):
    out = {manifest["engine"]["image_digest"], manifest["agent_core"]["image_digest"],
           manifest["exporter"]["image_digest"]}
    for slot in ("console", "sandbox"):
        if manifest[slot]["image_digest"]:
            out.add(manifest[slot]["image_digest"])
    return out


def _plan_rules(plan, errors, manifest, allow_deletes):
    images = _manifest_images(manifest) if manifest else None
    for rc in plan.get("resource_changes") or []:
        addr, rtype = rc.get("address", "?"), rc.get("type", "?")
        actions = rc["change"].get("actions") or []
        if rtype not in EXPECTED_TYPES:
            errors.append(_err("pulso:plan_unexpected_type", addr, f"{rtype} is not an expected resource type"))
        if _open_ingress(rc):
            errors.append(_err("pulso:plan_open_ingress", addr, "ingress from 0.0.0.0/0 or ::/0 is forbidden"))
        if "delete" in actions and rtype in STATEFUL_TYPES and addr not in allow_deletes:
            errors.append(_err("pulso:plan_destructive", addr,
                               "delete/replace of a stateful resource needs an explicit --allow-delete marker"))
        for container in _containers(rc):
            names = [e.get("name") for e in container.get("environment") or []]
            names += [s.get("name") for s in container.get("secrets") or []]
            if DEMO_FLAG in names:
                errors.append(_err("pulso:plan_demo_flag", addr, f"{DEMO_FLAG} is forbidden"))
            image = container.get("image", "")
            if images is not None:
                m = re.search(r"@(sha256:[0-9a-f]{64})$", image)
                if not m or m.group(1) not in images:
                    errors.append(_err("pulso:plan_image_not_in_manifest", addr,
                                       "image must be a digest listed in the manifest"))


def _apply_rules(plan, errors, manifest):
    if manifest is None:
        errors.append(_err("pulso:apply_not_approved", "manifest", "apply requires a validated manifest"))
        return
    digest = manifest_digest(manifest)
    approvals = manifest.get("approvals") or []
    if not any(a.get("manifest_digest") == digest for a in approvals):
        errors.append(_err("pulso:apply_not_approved", "approvals",
                           "no approval is pinned to this manifest's digest"))
    if manifest.get("infra", {}).get("plan_digest") != plan_digest(plan):
        errors.append(_err("pulso:plan_digest_mismatch", "infra.plan_digest",
                           "does not match the digest of the plan being applied"))


def validate(plan, manifest=None, mode="plan", allow_deletes=()):
    """Return {"errors": [...]}; empty errors means the plan may proceed to the next gate."""
    errors = []
    if mode not in ("plan", "apply"):
        raise ValueError("mode must be plan or apply")
    manifest_ok = manifest
    if manifest is not None:
        for e in validate_manifest.validate(manifest)["errors"]:
            errors.append(_err("pulso:manifest_rejected", e["path"], f"{e['code']}: {e['message']}"))
        if errors:
            manifest_ok = None
    if not isinstance(plan, dict) or "resource_changes" not in plan and plan != {}:
        errors.append(_err("schema", "", "plan must be terraform show -json output"))
        return {"errors": errors}
    _plan_rules(plan, errors, manifest_ok, set(allow_deletes))
    if mode == "apply":
        if manifest_ok is None and manifest is not None:
            pass  # manifest already rejected above; nothing is applied
        else:
            _apply_rules(plan, errors, manifest_ok)
    return {"errors": errors}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("plan")
    ap.add_argument("--manifest")
    ap.add_argument("--mode", choices=["plan", "apply"], default="plan")
    ap.add_argument("--allow-delete", action="append", default=[])
    args = ap.parse_args(argv)
    try:
        plan = json.loads(Path(args.plan).read_text(encoding="utf-8"))
        manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8")) if args.manifest else None
    except (OSError, ValueError) as exc:
        print(json.dumps({"errors": [_err("schema", "", f"cannot read input: {exc}")]}))
        return 1
    result = validate(plan, manifest, args.mode, args.allow_delete)
    print(json.dumps(result, indent=2))
    return 1 if result["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
