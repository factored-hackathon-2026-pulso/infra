"""Offline validator for the joint deploy manifest (plan 17.3.9, rules M-01..M-10).

Stdlib only; never calls AWS. The structural contract is read from
``deploy-manifest.schema.json`` (a JSON Schema subset interpreted here); the
cross-field rules are implemented in ``_rules``. A manifest that passes does
not prove a deployment: ``smoke_counts_as_success`` says whether the smoke
block may be presented as success (M-07).

Usage: python release/validate_manifest.py <manifest.json>   (exit 0 ok, 1 rejected)
"""

import json
import re
import sys
from pathlib import Path

SCHEMA_PATH = Path(__file__).with_name("deploy-manifest.schema.json")

_TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "boolean": bool,
    "null": type(None),
}


def _is_type(value, name):
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    return isinstance(value, _TYPES[name])


def _check(value, schema, root, path, errors):
    """Validate ``value`` against the supported JSON Schema subset."""
    if "$ref" in schema:
        node = root
        for part in schema["$ref"].lstrip("#/").split("/"):
            node = node[part]
        return _check(value, node, root, path, errors)
    if "oneOf" in schema:
        trials = []
        for sub in schema["oneOf"]:
            sub_errors = []
            _check(value, sub, root, path, sub_errors)
            trials.append(sub_errors)
        if sum(1 for t in trials if not t) != 1:
            errors.append(_err("schema", path, "does not match exactly one allowed form"))
        return None
    if "const" in schema and value != schema["const"]:
        errors.append(_err("schema", path, f"must equal {schema['const']!r}"))
        return None
    if "enum" in schema and value not in schema["enum"]:
        errors.append(_err("schema", path, f"must be one of {schema['enum']!r}"))
        return None
    if "type" in schema:
        names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_is_type(value, n) for n in names):
            errors.append(_err("schema", path, f"must be of type {'|'.join(names)}"))
            return None
    if isinstance(value, str):
        if "pattern" in schema and not re.search(schema["pattern"], value):
            errors.append(_err("schema", path, f"must match {schema['pattern']}"))
        if len(value) < schema.get("minLength", 0):
            errors.append(_err("schema", path, "must not be empty"))
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            errors.append(_err("schema", path, f"needs at least {schema['minItems']} item(s)"))
        for i, item in enumerate(value):
            if "items" in schema:
                _check(item, schema["items"], root, f"{path}[{i}]", errors)
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append(_err("schema", f"{path}.{key}".lstrip("."), "is required"))
        props = schema.get("properties", {})
        for key, sub in value.items():
            if key in props:
                _check(sub, props[key], root, f"{path}.{key}".lstrip("."), errors)
            elif schema.get("additionalProperties") is False:
                errors.append(_err("schema", f"{path}.{key}".lstrip("."), "unknown field"))
    return None


def _err(code, path, message):
    return {"code": code, "path": path, "message": message}


def _rules(m, errors):
    engine, core = m["engine"], m["agent_core"]
    compat = m["compat"]

    # M-01: Core contract version and pin manifest must match what the engine image expects.
    if core["contracts_version"] != engine["expected_contracts_version"]:
        errors.append(_err(
            "pulso:manifest_incompatible", "agent_core.contracts_version",
            "differs from the contracts version the engine image expects"))
    if m["contracts"]["pin_manifest_digest"] != engine["expected_pin_manifest_digest"]:
        errors.append(_err(
            "pulso:manifest_incompatible", "contracts.pin_manifest_digest",
            "differs from the pin manifest digest the engine image expects"))

    # M-02: image tag is <sha_core7>-<sha_pulso7> and must agree with the recorded SHAs.
    core7, _, pulso7 = core["image_tag"].partition("-")
    if core7 != core["git_sha"][:7] or pulso7 != core["pulso_package_sha"][:7]:
        errors.append(_err(
            "pulso:image_sha_mismatch", "agent_core.image_tag",
            "tag must be <agent_core.git_sha[:7]>-<pulso_package_sha[:7]>"))

    # M-03: one Core image serves runtime, exporter, migrate, sweep and seed.
    if m["exporter"]["image_digest"] != core["image_digest"]:
        errors.append(_err(
            "pulso:exporter_digest_mismatch", "exporter.image_digest",
            "must equal agent_core.image_digest"))

    # M-05: without the expected-state digest asset drift cannot be detected.
    if not m["assets"].get("expected_state_digest"):
        errors.append(_err(
            "pulso:assets_drift", "assets.expected_state_digest", "is required"))

    # M-06: a Core schema change must be declared (Core has no versioned migrations).
    previous = m["rollback"]["previous_schema_digest"]
    changed = core["schema_digest"] != previous
    if changed and compat["kind"] == "unchanged":
        errors.append(_err(
            "pulso:schema_change_undeclared", "compat.kind",
            "schema_digest differs from rollback.previous_schema_digest but compat is unchanged"))
    if not changed and compat["kind"] != "unchanged":
        errors.append(_err(
            "pulso:schema_change_undeclared", "compat.kind",
            "compat declares a change but schema_digest equals the previous one"))
    if compat["kind"] == "expand" and not compat["n_minus_1_image_tested"]:
        errors.append(_err(
            "pulso:compat_untested", "compat.n_minus_1_image_tested",
            "expand needs evidence that image N-1 runs against schema N"))

    # M-08: destructive migrations need an explicit strategy (Core compat or engine class).
    destructive = compat["kind"] == "contract" or engine["migration_class"] == "contract"
    if destructive and not (compat["strategy"] or "").strip():
        errors.append(_err(
            "pulso:destructive_migration_blocked", "compat.strategy",
            "contract migration without an explicit strategy blocks the deployment"))

    # M-10: no console image while the edge is dependency_blocked.
    if m["console"]["image_digest"] is not None:
        errors.append(_err(
            "pulso:console_blocked", "console.image_digest",
            "must be null with reason dependency_blocked:edge until edge exists"))
    elif m["console"]["reason"] != "dependency_blocked:edge":
        errors.append(_err(
            "pulso:console_blocked", "console.reason", "must be dependency_blocked:edge"))

    # Sandbox slot is blocked until CLQ-43: a null digest needs an explicit reason.
    if m["sandbox"]["image_digest"] is None and not m["sandbox"]["reason"]:
        errors.append(_err("schema", "sandbox.reason", "is required when image_digest is null"))


def smoke_counts_as_success(m):
    """M-07: only a real-AWS smoke with no doubles and result ok counts."""
    smoke = m.get("smoke", {})
    return (
        smoke.get("target") == "real_aws"
        and smoke.get("doubles") == []
        and smoke.get("result") == "ok"
    )


def validate(manifest, schema=None):
    """Return {"errors": [...], "smoke_counts_as_success": bool}."""
    schema = schema or json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    errors = []
    if not isinstance(manifest, dict):
        return {
            "errors": [_err("schema", "", "manifest must be a JSON object")],
            "smoke_counts_as_success": False,
        }
    _check(manifest, schema, schema, "", errors)
    # M-05 is reported with its own code even when the schema also flags the absence.
    if not errors or all(e["code"] == "schema" for e in errors):
        if "expected_state_digest" not in manifest.get("assets", {}):
            errors = [e for e in errors if e["path"] != "assets.expected_state_digest"]
            errors.append(_err("pulso:assets_drift", "assets.expected_state_digest", "is required"))
    if not any(e["code"] == "schema" for e in errors):
        _rules(manifest, errors)
    return {"errors": errors, "smoke_counts_as_success": not errors and smoke_counts_as_success(manifest)}


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        print("usage: validate_manifest.py <manifest.json>", file=sys.stderr)
        return 2
    try:
        manifest = json.loads(Path(argv[0]).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(json.dumps({"errors": [_err("schema", "", f"cannot read manifest: {exc}")]}))
        return 1
    result = validate(manifest)
    print(json.dumps(result, indent=2))
    return 1 if result["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
