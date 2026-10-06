"""Bundle bind mounts must be readable by non-root containers.

prepare.sh runs with umask 077 and syncs the bundle, so every bundle file is
0600/0700 root-only. A relative bind mount (./x) read by a non-root container
therefore needs a mechanism: run as root (no user:), or a root one-shot that
makes the path world readable and that the consumer depends on.
"""

from __future__ import annotations

import unittest
from pathlib import Path

import yaml

HACKATHON = Path(__file__).resolve().parents[1] / "deploy" / "hackathon"
PERMS_SERVICE = "postgres-bundle-perms"


def _load(path):
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def _is_root(svc, image_default_root):
    user = str(svc.get("user", "")).split(":")[0]
    return user in ("0", "root") or (user == "" and image_default_root)


class BundleBindMountPerms(unittest.TestCase):
    def test_postgres_initdb_readable(self):
        doc = _load(HACKATHON / "core" / "compose.postgres.yaml")
        svcs = doc["services"]
        perms = svcs[PERMS_SERVICE]
        self.assertEqual(str(perms["user"]).split(":")[0], "0")
        self.assertEqual(perms["restart"], "no")
        self.assertIn("mem_limit", perms)
        self.assertEqual(perms["image"], svcs["postgres"]["image"])
        self.assertTrue(any(v.startswith("./initdb:") and not v.endswith(":ro") for v in perms["volumes"]))
        self.assertIn("a+rX", " ".join(map(str, perms["entrypoint"])))
        for consumer in ("postgres", "pulso-db-bootstrap"):
            dep = svcs[consumer]["depends_on"][PERMS_SERVICE]
            self.assertEqual(dep["condition"], "service_completed_successfully")

    def test_every_relative_mount_has_mechanism(self):
        for path in sorted(HACKATHON.glob("*/compose*.y*ml")):
            svcs = _load(path).get("services") or {}
            for name, svc in svcs.items():
                rel = [v for v in svc.get("volumes", []) if isinstance(v, str) and v.startswith("./")]
                if not rel:
                    continue
                # postgres and caddy images run as root unless user: is set.
                if _is_root(svc, image_default_root=True):
                    continue
                deps = svc.get("depends_on") or {}
                with self.subTest(file=path.name, service=name):
                    self.assertIn(PERMS_SERVICE, deps, f"{name} mounts {rel} as non-root without a perms step")


if __name__ == "__main__":
    unittest.main()
