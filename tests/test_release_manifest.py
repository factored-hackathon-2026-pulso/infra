"""Rules M-01..M-10 for the joint deploy manifest (plan 17.3.9, SR-07)."""

import copy
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "release"))

import validate_manifest  # noqa: E402  (first RED: module did not exist)


def d(ch):
    return "sha256:" + ch * 64


def good():
    return {
        "schema_version": "1",
        "environment": "staging",
        "engine": {
            "image_digest": d("a"),
            "git_sha": "1234567" + "0" * 33,
            "migrations_head": "0042_expand_runs",
            "migration_class": "expand",
            "expected_contracts_version": "1.3.0",
            "expected_pin_manifest_digest": d("c"),
        },
        "agent_core": {
            "image_digest": d("b"),
            "image_tag": "894fa65-1234567",
            "git_sha": "894fa65575d83420523f33ec1c6919b8965f7ebe",
            "contracts_version": "1.3.0",
            "schema_digest": {"runtime": d("1"), "eval": d("2")},
            "pulso_package_sha": "1234567" + "0" * 33,
        },
        "contracts": {"pin_manifest_digest": d("c")},
        "compat": {
            "kind": "unchanged",
            "n_minus_1_image_tested": False,
            "strategy": None,
        },
        "assets": {
            "manifest_digest": d("3"),
            "expected_state_digest": d("4"),
            "release_ids": ["rel-1"],
        },
        "exporter": {"image_digest": d("b")},
        "console": {"image_digest": None, "reason": "dependency_blocked:edge"},
        "sandbox": {"image_digest": None, "reason": "dependency_blocked:CLQ-43"},
        "runtime_config": {"ref": "runtime-config/staging", "digest": d("5")},
        "infra": {
            "git_sha": "abcdef0" + "0" * 33,
            "tfvars_digest": d("6"),
            "plan_digest": d("7"),
        },
        "approvals": [
            {
                "approver": "release-owner",
                "role": "human",
                "approved_at": "2026-10-02T12:00:00Z",
                "manifest_digest": d("8"),
            }
        ],
        "smoke": {
            "suite": "registry-wire-contract",
            "target": "real_aws",
            "doubles": [],
            "result": "ok",
        },
        "rollback": {
            "previous_manifest_digest": d("9"),
            "previous_schema_digest": {"runtime": d("1"), "eval": d("2")},
        },
        "signature": {"status": "dependency_blocked"},
    }


def codes(manifest):
    return [e["code"] for e in validate_manifest.validate(manifest)["errors"]]


class ManifestTest(unittest.TestCase):
    def mutate(self, fn):
        m = copy.deepcopy(good())
        fn(m)
        return m

    def test_good_manifest_is_accepted_and_smoke_counts(self):
        r = validate_manifest.validate(good())
        self.assertEqual(r["errors"], [])
        self.assertTrue(r["smoke_counts_as_success"])

    def test_m01_incompatible_contracts_rejected(self):
        m = self.mutate(lambda m: m["agent_core"].update(contracts_version="1.4.0"))
        self.assertIn("pulso:manifest_incompatible", codes(m))
        m = self.mutate(lambda m: m["contracts"].update(pin_manifest_digest=d("d")))
        self.assertIn("pulso:manifest_incompatible", codes(m))

    def test_m02_image_tag_sha_mismatch(self):
        m = self.mutate(lambda m: m["agent_core"].update(image_tag="deadbee-1234567"))
        self.assertIn("pulso:image_sha_mismatch", codes(m))

    def test_m03_exporter_digest_must_equal_core(self):
        m = self.mutate(lambda m: m["exporter"].update(image_digest=d("e")))
        self.assertIn("pulso:exporter_digest_mismatch", codes(m))

    def test_m04_mutable_tag_or_bad_digest_rejected(self):
        m = self.mutate(lambda m: m["engine"].update(image_digest="latest"))
        self.assertTrue(codes(m))
        m = self.mutate(lambda m: m["agent_core"].update(image_digest="sha1:" + "a" * 40))
        self.assertTrue(codes(m))

    def test_m05_missing_expected_state_digest(self):
        m = self.mutate(lambda m: m["assets"].pop("expected_state_digest"))
        self.assertIn("pulso:assets_drift", codes(m))

    def test_m06_schema_change_needs_declared_compat(self):
        def f(m):
            m["agent_core"]["schema_digest"]["runtime"] = d("f")

        self.assertIn("pulso:schema_change_undeclared", codes(self.mutate(f)))

        def g(m):
            f(m)
            m["compat"] = {"kind": "expand", "n_minus_1_image_tested": True, "strategy": None}

        self.assertEqual(codes(self.mutate(g)), [])

    def test_m06_expand_requires_n_minus_1_evidence(self):
        def f(m):
            m["agent_core"]["schema_digest"]["eval"] = d("f")
            m["compat"] = {"kind": "expand", "n_minus_1_image_tested": False, "strategy": None}

        self.assertIn("pulso:compat_untested", codes(self.mutate(f)))

    def test_m07_doubles_or_non_aws_target_is_not_success(self):
        m = self.mutate(lambda m: m["smoke"].update(doubles=["llm"]))
        r = validate_manifest.validate(m)
        self.assertEqual(r["errors"], [])
        self.assertFalse(r["smoke_counts_as_success"])
        m = self.mutate(lambda m: m["smoke"].update(target="local"))
        self.assertFalse(validate_manifest.validate(m)["smoke_counts_as_success"])
        m = self.mutate(lambda m: m["smoke"].update(result="not_run"))
        self.assertFalse(validate_manifest.validate(m)["smoke_counts_as_success"])

    def test_m08_contract_migration_without_strategy_blocks(self):
        def f(m):
            m["engine"]["migration_class"] = "contract"

        self.assertIn("pulso:destructive_migration_blocked", codes(self.mutate(f)))

        def g(m):
            m["agent_core"]["schema_digest"]["runtime"] = d("f")
            m["compat"] = {"kind": "contract", "n_minus_1_image_tested": True, "strategy": None}

        self.assertIn("pulso:destructive_migration_blocked", codes(self.mutate(g)))

        def h(m):
            g(m)
            m["compat"]["strategy"] = "freeze at N and fix forward; ticket PULSO-1"

        self.assertEqual(codes(self.mutate(h)), [])

    def test_m09_empty_approvals_rejected(self):
        m = self.mutate(lambda m: m.update(approvals=[]))
        self.assertTrue(codes(m))

    def test_trailing_newline_does_not_bypass_patterns(self):
        m = self.mutate(lambda m: m["engine"].update(git_sha=m["engine"]["git_sha"] + "\n"))
        self.assertTrue(codes(m))
        m = self.mutate(lambda m: m["engine"].update(image_digest=d("a") + "\n"))
        self.assertTrue(codes(m))

    def test_m05_reported_once_and_for_empty_or_null(self):
        m = self.mutate(lambda m: m["assets"].pop("expected_state_digest"))
        self.assertEqual(codes(m), ["pulso:assets_drift"])
        for bad in ("", None, "not-a-digest"):
            m = self.mutate(lambda m, b=bad: m["assets"].update(expected_state_digest=b))
            self.assertEqual(codes(m), ["pulso:assets_drift"])

    def test_log_group_has_single_declaring_resource(self):
        tf = ROOT / "terraform" / "modules"
        owners = [
            p.parent.name for p in tf.glob("*/*.tf")
            if 'resource "aws_cloudwatch_log_group"' in p.read_text("utf-8")
        ]
        # engine_platform owns only the four /pulso/<env>/pulso-engine-* names, bridge_services the three
        # /pulso/<env>/pulso-{core-runtime,core-exporter,platform-exporter} names; observability owns the legacy one.
        self.assertEqual(sorted(owners), ["bridge_services", "engine_platform", "observability"])
        engine = (tf / "engine_platform" / "main.tf").read_text("utf-8")
        self.assertIn('name              = "/pulso/${local.env}/${local.prefix}-${each.key}"', engine)

    def test_m10_console_digest_blocked_while_edge_blocked(self):
        m = self.mutate(lambda m: m["console"].update(image_digest=d("e")))
        self.assertIn("pulso:console_blocked", codes(m))

    def test_signature_stays_dependency_blocked(self):
        m = self.mutate(lambda m: m.update(signature={"status": "signed"}))
        self.assertTrue(codes(m))

    def test_unknown_field_and_missing_section_rejected(self):
        m = self.mutate(lambda m: m.update(extra=1))
        self.assertTrue(codes(m))
        m = self.mutate(lambda m: m.pop("rollback"))
        self.assertTrue(codes(m))

    def test_non_object_manifest_rejected(self):
        self.assertTrue(validate_manifest.validate([])["errors"])

    def test_cli_exit_codes_and_fixtures(self):
        fixtures = ROOT / "release" / "fixtures"
        self.assertEqual(
            validate_manifest.main([str(fixtures / "deploy-manifest.example.json")]), 0
        )
        self.assertEqual(
            validate_manifest.main([str(fixtures / "deploy-manifest.incompatible.json")]), 1
        )

    def test_fixtures_match_the_test_manifest(self):
        fixtures = ROOT / "release" / "fixtures"
        example = json.loads((fixtures / "deploy-manifest.example.json").read_text("utf-8"))
        self.assertEqual(example, good())

    def test_schema_is_valid_json_with_required_sections(self):
        schema = json.loads(
            (ROOT / "release" / "deploy-manifest.schema.json").read_text("utf-8")
        )
        for key in (
            "schema_version", "compat", "exporter", "console", "sandbox", "assets",
            "approvals", "rollback", "signature",
        ):
            self.assertIn(key, schema["required"])
        self.assertIn("schema_digest", schema["properties"]["agent_core"]["properties"])


if __name__ == "__main__":
    unittest.main()
