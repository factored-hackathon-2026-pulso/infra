"""Static contract of the digest-deploy mechanism (things terraform test cannot see)."""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMPUTE = ROOT / "terraform" / "modules" / "hackathon_compute"


def resource_block(text: str, header: str) -> str:
    start = text.index(header)
    depth = 0
    for i in range(text.index("{", start), len(text)):
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        if depth == 0:
            return text[start : i + 1]
    raise AssertionError(header)


class ImageParameters(unittest.TestCase):
    def setUp(self):
        self.main = (COMPUTE / "main.tf").read_text(encoding="utf-8")

    def test_image_parameters_ignore_value_changes_so_terraform_does_not_fight_deployments(self):
        block = resource_block(self.main, 'resource "aws_ssm_parameter" "image"')
        self.assertRegex(block, r"ignore_changes\s*=\s*\[\s*value\s*\]")

    def test_instance_user_data_does_not_reference_images(self):
        block = resource_block(self.main, 'resource "aws_instance" "this"')
        self.assertNotIn("var.images", block)
        user_data = resource_block(self.main, "user_data = templatefile")
        self.assertNotIn("images", user_data)
        prepare = resource_block(self.main, "prepare_script = templatefile")
        self.assertNotIn("var.images", prepare)

    def test_host_start_script_reads_digests_from_ssm_not_from_the_bundle(self):
        text = (COMPUTE / "templates" / "prepare.sh.tftpl").read_text(encoding="utf-8")
        self.assertRegex(text, r"\$SSM_PREFIX/images")


if __name__ == "__main__":
    unittest.main()
