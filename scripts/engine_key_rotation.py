"""Merge the engine key-rotation values Terraform generated into a copy of the Secrets Manager secret (offline helper).

Why: the secret version ignores later Terraform changes (an apply never overwrites out-of-band values), so a new engine key
reaches the hosts only through an explicit merge of three keys. Procedure and the Terraform variables: docs/agent-core-serve.md
section 7. This script touches no AWS API and prints key NAMES and kids only, never a value.

    python scripts/engine_key_rotation.py merge --secret current.json --generated generated.json --out merged.json [--include-seed]
    python scripts/engine_key_rotation.py kids --generated generated.json

`current.json` is the secret as JSON (`aws secretsmanager get-secret-value ... --query SecretString --output text` written to a private
file); `generated.json` is `terraform output -json generated_secrets`. `merged.json` is written with mode 0600; the human then runs
`aws secretsmanager put-secret-value --secret-id <arn> --secret-string file://merged.json` and deletes the three files.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import re
import sys
from pathlib import Path

DOC_KEYS = ("FILES__AGENT__IDENTITY_KEYS", "FILES__AGENT__STAFF_KEYS")
SEED_KEY = "PULSO__PULSO_SERVICE_SEED_HEX"
ENGINE_KID = re.compile(r"^pulso-engine-[a-z0-9][a-z0-9-]{0,23}$")


class RotationError(Exception):
    pass


def load_json(path: str, what: str):
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise RotationError(f"cannot read {what}: {type(exc).__name__}") from None
    if isinstance(data, dict) and set(data) >= {"value", "sensitive"} and isinstance(data["value"], dict):
        data = data["value"]  # `terraform output -json` of ALL outputs wraps each one
    if not isinstance(data, dict) or not all(isinstance(k, str) for k in data):
        raise RotationError(f"{what} is not a JSON object")
    return data


def b64url_32(value: str) -> bool:
    try:
        return len(base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))) == 32
    except (binascii.Error, ValueError):
        return False


def engine_kids(doc_text: str, name: str) -> dict[str, str]:
    """kid -> public key of the engine entries of one key document; validates every key it reads."""
    try:
        doc = json.loads(doc_text)
    except ValueError:
        raise RotationError(f"{name} is not JSON") from None
    keys = doc.get("principal_keys") if isinstance(doc, dict) else None
    if not isinstance(keys, dict) or not keys:
        raise RotationError(f"{name} has no principal_keys")
    for kid, pub in keys.items():
        if not isinstance(pub, str) or not b64url_32(pub):
            raise RotationError(f"{name}: key {kid} is not 32 bytes of base64url")
    return {k: v for k, v in keys.items() if ENGINE_KID.match(k)}


def check_generated(generated: dict, include_seed: bool) -> list[str]:
    names = list(DOC_KEYS) + ([SEED_KEY] if include_seed else [])
    for n in names:
        v = generated.get(n)
        if not isinstance(v, str) or not v or v == "CHANGE_ME":
            raise RotationError(f"generated_secrets has no usable {n}")
    if include_seed and not re.fullmatch(r"[0-9a-f]{64}", generated[SEED_KEY]):
        raise RotationError(f"{SEED_KEY} is not 64 hex characters")
    identity = engine_kids(generated[DOC_KEYS[0]], DOC_KEYS[0])
    staff = engine_kids(generated[DOC_KEYS[1]], DOC_KEYS[1])
    if not staff:
        raise RotationError("staff-keys publishes no engine kid: serve would reject every engine credential")
    if set(identity) != set(staff):
        raise RotationError("identity-keys and staff-keys publish different engine kids")
    return sorted(staff)


def merge(secret: dict, generated: dict, include_seed: bool) -> tuple[dict, list[str], list[str]]:
    kids = check_generated(generated, include_seed)
    names = list(DOC_KEYS) + ([SEED_KEY] if include_seed else [])
    merged = dict(secret)
    for n in names:
        merged[n] = generated[n]
    return merged, names, kids


def write_private(path: str, data: dict) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(data, fh)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("merge")
    m.add_argument("--secret", required=True)
    m.add_argument("--generated", required=True)
    m.add_argument("--out", required=True)
    m.add_argument("--include-seed", action="store_true", help="also copy PULSO__PULSO_SERVICE_SEED_HEX (step 2: mint with the new kid)")
    k = sub.add_parser("kids")
    k.add_argument("--generated", required=True)
    a = ap.parse_args(argv)
    try:
        generated = load_json(a.generated, "generated_secrets")
        if a.cmd == "kids":
            print("published engine kids: " + ", ".join(check_generated(generated, include_seed=False)))
            return 0
        secret = load_json(a.secret, "secret")
        if Path(a.out).resolve() in (Path(a.secret).resolve(), Path(a.generated).resolve()):
            raise RotationError("--out must be a new file, not an input")
        merged, names, kids = merge(secret, generated, a.include_seed)
        write_private(a.out, merged)
    except RotationError as exc:
        print(f"refused: {exc}", file=sys.stderr)
        return 2
    print("merged keys: " + ", ".join(names))
    print("published engine kids: " + ", ".join(kids))
    print(f"wrote {a.out} (mode 0600). Next: aws secretsmanager put-secret-value, then delete the three files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
