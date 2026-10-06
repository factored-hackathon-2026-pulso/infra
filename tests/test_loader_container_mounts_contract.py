"""Every host directory the loader bind-mounts into a non-root container must be readable by that uid despite `umask 077`."""

from __future__ import annotations

import re
import unittest
from pathlib import Path

LOADER = Path(__file__).resolve().parents[1] / "deploy" / "hackathon" / "engine" / "loader"
UID = "10001"


def read(name: str) -> str:
    return (LOADER / name).read_text(encoding="utf-8")


class LoaderContainerMounts(unittest.TestCase):
    def test_scripts_run_with_umask_077(self):
        for name in ("pulso-loader.sh", "run-bank-cells.sh"):
            self.assertIn("umask 077", read(name))

    def test_pipeline_mounts_are_chowned_before_use(self):
        text = read("pulso-loader.sh")
        for var in re.findall(r'-v "\$(?:\{)?(\w+)(?:\})?/(\w+):', text):
            path = f"$WORK/{var[1]}"
            chowned = re.search(rf'chown -R {UID}:{UID} "{re.escape(path)}"', text)
            self.assertTrue(chowned, f"{path} is mounted into the pipeline container but never chowned to {UID}")
            self.assertLess(chowned.start(), text.index("run_pipeline()"))
        self.assertIn('-v "$WORK/e0:/e0:ro"', text)

    def test_e0_chown_follows_the_sync(self):
        text = read("pulso-loader.sh")
        sync = text.index('aws s3 sync "s3://$LOADER_BUCKET/$E0_PREFIX" "$WORK/e0"')
        chown = text.index('chown -R 10001:10001 "$WORK/e0"', sync)
        self.assertLess(chown, text.index("STEPS=\"ingest_e0,$STEPS\""))

    def test_bank_cells_mounts_are_prepared_for_the_container_uid(self):
        text = read("run-bank-cells.sh")
        self.assertIn(f"--user {UID}:{UID}", text)
        self.assertRegex(text, r'chmod -R a\+rX "\$IN"')
        self.assertIn(f'chown {UID}:{UID} "$OUT"', text)
        self.assertLess(text.index('chown 10001:10001 "$OUT"'), text.index("docker run"))
        self.assertLess(text.index('chmod -R a+rX "$IN"'), text.index("docker run"))


if __name__ == "__main__":
    unittest.main()
