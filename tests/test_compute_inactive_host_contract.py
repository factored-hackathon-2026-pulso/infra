"""Static contract of the hackathon_compute module for hosts created with enabled=false (what terraform test cannot see).

Root cause found on the first free_plan apply (docs/troubleshooting.md "inactive host"): the instance state resource only
depended on the instance, so Terraform stopped the instance in parallel with the EBS attachments, which then failed
("instance is not running"); and a stopped instance reports no public IP, so the provider read back
associate_public_ip_address=false and the next plan wanted to REPLACE the instance (a ForceNew attribute).
The module therefore: (1) orders the state change after every attachment and (2) ignores the attributes the provider
derives from the runtime state of the instance.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

MAIN = (Path(__file__).resolve().parents[1] / "terraform" / "modules" / "hackathon_compute" / "main.tf").read_text(encoding="utf-8")


def block(kind: str, name: str) -> str:
    m = re.search(r'resource "%s" "%s" \{' % (kind, name), MAIN)
    assert m, f"{kind}.{name} not found"
    depth, i = 0, m.end() - 1
    while True:
        depth += {"{": 1, "}": -1}.get(MAIN[i], 0)
        if depth == 0:
            return MAIN[m.start() : i + 1]
        i += 1


class InactiveHostCreation(unittest.TestCase):
    def test_instance_state_waits_for_every_volume_attachment(self):
        state = block("aws_ec2_instance_state", "this")
        m = re.search(r"depends_on\s*=\s*\[([^\]]*)\]", state)
        self.assertIsNotNone(m, "the state change must be ordered after the attachments")
        self.assertIn("aws_volume_attachment.data", m.group(1))
        self.assertIn("aws_volume_attachment.db", m.group(1))

    def test_instance_ignores_the_public_ip_attributes_that_vanish_when_stopped(self):
        inst = block("aws_instance", "this")
        m = re.search(r"ignore_changes\s*=\s*\[([^\]]*)\]", inst)
        self.assertIsNotNone(m, "a stopped instance must not force replacement")
        self.assertIn("associate_public_ip_address", m.group(1))

    def test_public_ip_is_still_requested_from_the_variable(self):
        self.assertRegex(block("aws_instance", "this"), r"associate_public_ip_address\s*=\s*var\.associate_public_ip")

    def test_instance_is_never_created_stopped_by_the_instance_resource(self):
        inst = block("aws_instance", "this")
        self.assertNotRegex(inst, r"instance_initiated_shutdown|\bstate\s*=", "state is managed only by aws_ec2_instance_state")


if __name__ == "__main__":
    unittest.main()
