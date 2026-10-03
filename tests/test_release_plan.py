"""Plan validator and deploy orchestrator (plan 17.3.9): offline, stdlib only."""

import copy
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "release"))

import validate_manifest  # noqa: E402
import validate_plan  # noqa: E402  (first RED: module did not exist)
import deploy_plan  # noqa: E402  (first RED: module did not exist)

EXAMPLE = json.loads((ROOT / "release/fixtures/deploy-manifest.example.json").read_text(encoding="utf-8"))
INCOMPATIBLE = json.loads(
    (ROOT / "release/fixtures/deploy-manifest.incompatible.json").read_text(encoding="utf-8"))


def change(rtype, after=None, actions=("create",), address=None):
    return {"address": address or f"{rtype}.x", "type": rtype,
            "change": {"actions": list(actions), "after": after or {}}}


def plan(*changes):
    return {"format_version": "1.2", "resource_changes": list(changes)}


def taskdef(image, env=None):
    cd = [{"name": "app", "image": image, "environment": env or []}]
    return change("aws_ecs_task_definition", {"container_definitions": json.dumps(cd)})


def codes(result):
    return sorted({e["code"] for e in result["errors"]})


def approved_manifest(plan_doc):
    m = copy.deepcopy(EXAMPLE)
    m["infra"]["plan_digest"] = validate_plan.plan_digest(plan_doc)
    m["approvals"][0]["manifest_digest"] = validate_plan.manifest_digest(m)
    return m


class PlanRulesTest(unittest.TestCase):
    def test_clean_plan_passes(self):
        self.assertEqual(validate_plan.validate(plan(change("aws_s3_bucket")))["errors"], [])

    def test_open_ingress_rejected_in_all_shapes(self):
        shapes = [
            change("aws_security_group", {"ingress": [{"cidr_blocks": ["0.0.0.0/0"]}]}),
            change("aws_vpc_security_group_ingress_rule", {"cidr_ipv4": "0.0.0.0/0"}),
            change("aws_vpc_security_group_ingress_rule", {"cidr_ipv6": "::/0"}),
            change("aws_security_group_rule", {"type": "ingress", "cidr_blocks": ["0.0.0.0/0"]}),
        ]
        for c in shapes:
            self.assertIn("pulso:plan_open_ingress", codes(validate_plan.validate(plan(c))))

    def test_open_egress_is_not_ingress(self):
        c = change("aws_vpc_security_group_egress_rule", {"cidr_ipv4": "0.0.0.0/0"})
        self.assertEqual(validate_plan.validate(plan(c))["errors"], [])

    def test_demo_flag_rejected_in_env_and_secrets(self):
        env = taskdef("x@sha256:" + "a" * 64, [{"name": "AGENTCORE_ALLOW_DEMO", "value": "1"}])
        self.assertIn("pulso:plan_demo_flag", codes(validate_plan.validate(plan(env))))
        cd = [{"name": "a", "image": "x", "secrets": [{"name": "AGENTCORE_ALLOW_DEMO", "valueFrom": "arn"}]}]
        c = change("aws_ecs_task_definition", {"container_definitions": json.dumps(cd)})
        self.assertIn("pulso:plan_demo_flag", codes(validate_plan.validate(plan(c))))

    def test_stateful_delete_needs_marker(self):
        for t in ("aws_db_instance", "aws_secretsmanager_secret", "aws_kms_key"):
            p = plan(change(t, actions=("delete",), address=f"{t}.main"))
            self.assertIn("pulso:plan_destructive", codes(validate_plan.validate(p)))
            ok = validate_plan.validate(p, allow_deletes=[f"{t}.main"])
            self.assertEqual(ok["errors"], [])

    def test_replace_counts_as_delete(self):
        p = plan(change("aws_db_instance", actions=("delete", "create"), address="aws_db_instance.main"))
        self.assertIn("pulso:plan_destructive", codes(validate_plan.validate(p)))

    def test_unexpected_resource_type_rejected(self):
        p = plan(change("aws_instance"))
        self.assertIn("pulso:plan_unexpected_type", codes(validate_plan.validate(p)))

    def test_image_must_be_in_manifest(self):
        good = EXAMPLE["agent_core"]["image_digest"]
        p_ok = plan(taskdef("repo/core@" + good))
        self.assertEqual(validate_plan.validate(p_ok, manifest=EXAMPLE)["errors"], [])
        p_bad = plan(taskdef("repo/core@sha256:" + "f" * 64))
        self.assertIn("pulso:plan_image_not_in_manifest",
                      codes(validate_plan.validate(p_bad, manifest=EXAMPLE)))
        p_tag = plan(taskdef("repo/core:latest"))
        self.assertIn("pulso:plan_image_not_in_manifest",
                      codes(validate_plan.validate(p_tag, manifest=EXAMPLE)))


class PlanBypassHardeningTest(unittest.TestCase):
    """Independent review findings: each case was accepted by the first implementation."""

    def test_uninspectable_task_definition_is_rejected(self):
        unknown = change("aws_ecs_task_definition", {})  # container_definitions computed/unknown
        self.assertIn("pulso:plan_uninspectable_task_definition", codes(validate_plan.validate(plan(unknown))))
        broken = change("aws_ecs_task_definition", {"container_definitions": "{not json"})
        self.assertIn("pulso:plan_uninspectable_task_definition", codes(validate_plan.validate(plan(broken))))

    def test_demo_flag_anywhere_in_container_definition_is_rejected(self):
        cd = [{"name": "a", "image": "x@sha256:" + "a" * 64, "command": ["sh", "-c", "AGENTCORE_ALLOW_DEMO=1 run"]}]
        c = change("aws_ecs_task_definition", {"container_definitions": json.dumps(cd)})
        self.assertIn("pulso:plan_demo_flag", codes(validate_plan.validate(plan(c))))

    def test_environment_files_are_rejected(self):
        cd = [{"name": "a", "image": "x@sha256:" + "a" * 64, "environmentFiles": [{"type": "s3", "value": "arn:aws:s3:::b/e.env"}]}]
        c = change("aws_ecs_task_definition", {"container_definitions": json.dumps(cd)})
        self.assertIn("pulso:plan_environment_files", codes(validate_plan.validate(plan(c))))

    def test_open_ingress_alternate_spellings_and_halves(self):
        for cidr in ("0.0.0.0/1", "128.0.0.0/1", "0.0.0.0/0 ", "0.0.0.0/00", "::0/0", "0:0:0:0:0:0:0:0/0", "::/1"):
            key = "cidr_ipv6" if ":" in cidr else "cidr_ipv4"
            c = change("aws_vpc_security_group_ingress_rule", {key: cidr})
            self.assertIn("pulso:plan_open_ingress", codes(validate_plan.validate(plan(c))), cidr)
        ok = change("aws_vpc_security_group_ingress_rule", {"cidr_ipv4": "10.0.0.0/16"})
        self.assertEqual(validate_plan.validate(plan(ok))["errors"], [])

    def test_bucket_and_log_group_deletes_need_marker(self):
        for t in ("aws_s3_bucket", "aws_cloudwatch_log_group"):
            p = plan(change(t, actions=("delete", "create"), address=f"{t}.main"))
            self.assertIn("pulso:plan_destructive", codes(validate_plan.validate(p)))

    def test_wildcard_iam_policies_are_rejected(self):
        admin = {"policy": json.dumps({"Statement": [{"Effect": "Allow", "Action": "*", "Resource": "*"}]})}
        for rtype in ("aws_iam_role_policy", "aws_iam_policy"):
            self.assertIn("pulso:plan_iam_wildcard", codes(validate_plan.validate(plan(change(rtype, admin)))))
        svc = {"policy": json.dumps({"Statement": [{"Effect": "Allow", "Action": ["iam:*"], "Resource": "*"}]})}
        self.assertIn("pulso:plan_iam_wildcard", codes(validate_plan.validate(plan(change("aws_iam_role_policy", svc)))))
        adm = change("aws_iam_role_policy_attachment",
                     {"policy_arn": "arn:aws:iam::aws:policy/AdministratorAccess"})
        self.assertIn("pulso:plan_iam_wildcard", codes(validate_plan.validate(plan(adm))))
        deny = {"policy": json.dumps({"Statement": [{"Effect": "Deny", "Action": ["iam:*"], "Resource": "*"}]})}
        self.assertEqual(validate_plan.validate(plan(change("aws_iam_role_policy", deny)))["errors"], [])

    def test_any_principal_trust_is_rejected(self):
        trust = json.dumps({"Statement": [{"Effect": "Allow", "Action": "sts:AssumeRole", "Principal": {"AWS": "*"}}]})
        c = change("aws_iam_role", {"assume_role_policy": trust})
        self.assertIn("pulso:plan_iam_wildcard", codes(validate_plan.validate(plan(c))))

    def test_malformed_resource_change_is_an_error_not_a_crash(self):
        r = validate_plan.validate({"resource_changes": [{"type": "aws_s3_bucket"}]})
        self.assertIn("schema", codes(r))
        r = validate_plan.validate({"resource_changes": ["x"]})
        self.assertIn("schema", codes(r))

    def test_apply_refuses_errored_or_unapplyable_plan(self):
        p = plan(change("aws_s3_bucket"))
        p["errored"] = True
        m = approved_manifest(p)
        self.assertIn("pulso:apply_not_applyable", codes(validate_plan.validate(p, manifest=m, mode="apply")))
        p2 = plan(change("aws_s3_bucket"))
        p2["applyable"] = False
        m2 = approved_manifest(p2)
        self.assertIn("pulso:apply_not_applyable", codes(validate_plan.validate(p2, manifest=m2, mode="apply")))

    def test_infra_stage_must_not_roll_services_before_migrate(self):
        svc = {"resource_changes": [{"address": "module.core.aws_ecs_service.this[0]", "type": "aws_ecs_service",
               "change": {"actions": ["update"], "before": {"task_definition": "arn:td:1"},
                          "after": {"task_definition": "arn:td:2"}}}]}
        self.assertIn("pulso:plan_service_rollout_before_migrate",
                      codes(validate_plan.validate(svc, stage="infra")))
        self.assertEqual(validate_plan.validate(svc, stage="rollout")["errors"], [])
        same = {"resource_changes": [{"address": "a", "type": "aws_ecs_service",
                "change": {"actions": ["update"], "before": {"task_definition": "arn:td:1", "desired_count": 1},
                           "after": {"task_definition": "arn:td:1", "desired_count": 2}}}]}
        self.assertEqual(validate_plan.validate(same, stage="infra")["errors"], [])


class ManifestGateTest(unittest.TestCase):
    def test_incompatible_manifest_refused(self):
        self.assertNotEqual(validate_manifest.validate(INCOMPATIBLE)["errors"], [])
        r = validate_plan.validate(plan(change("aws_s3_bucket")), manifest=INCOMPATIBLE)
        self.assertIn("pulso:manifest_rejected", codes(r))

    def test_apply_without_approvals_refused(self):
        p = plan(change("aws_s3_bucket"))
        m = approved_manifest(p)
        m["approvals"] = []
        self.assertTrue(validate_plan.validate(p, manifest=m, mode="apply")["errors"])
        m2 = approved_manifest(p)
        del m2["approvals"]
        self.assertTrue(validate_plan.validate(p, manifest=m2, mode="apply")["errors"])

    def test_apply_requires_manifest(self):
        r = validate_plan.validate(plan(change("aws_s3_bucket")), mode="apply")
        self.assertIn("pulso:apply_not_approved", codes(r))

    def test_apply_requires_approval_pinned_to_manifest_digest(self):
        p = plan(change("aws_s3_bucket"))
        m = approved_manifest(p)
        self.assertEqual(validate_plan.validate(p, manifest=m, mode="apply")["errors"], [])
        m["approvals"][0]["manifest_digest"] = "sha256:" + "0" * 64
        self.assertIn("pulso:apply_not_approved",
                      codes(validate_plan.validate(p, manifest=m, mode="apply")))

    def test_apply_requires_plan_digest_match(self):
        p = plan(change("aws_s3_bucket"))
        m = approved_manifest(p)
        other = plan(change("aws_s3_bucket"), change("aws_kms_key"))
        self.assertIn("pulso:plan_digest_mismatch",
                      codes(validate_plan.validate(other, manifest=m, mode="apply")))

    def test_digest_ignores_approvals_and_signature(self):
        m = copy.deepcopy(EXAMPLE)
        d1 = validate_plan.manifest_digest(m)
        m["approvals"].append(dict(m["approvals"][0], approver="second"))
        self.assertEqual(d1, validate_plan.manifest_digest(m))


def executors(log, fail=()):
    def make(step):
        def run(manifest):
            log.append(step)
            return step not in fail
        return run
    return {s: make(s) for s in deploy_plan.STEPS}


class DeployOrchestratorTest(unittest.TestCase):
    def test_steps_follow_plan_order(self):
        self.assertEqual(deploy_plan.STEPS[:4],
                         ["validate", "apply_infra", "snapshots", "core_migrate"])
        self.assertLess(deploy_plan.STEPS.index("update_core_runtime"),
                        deploy_plan.STEPS.index("engine_migrate"))
        self.assertLess(deploy_plan.STEPS.index("engine_migrate"),
                        deploy_plan.STEPS.index("update_engine_services"))
        self.assertEqual(deploy_plan.STEPS[-1], "receipt")

    def test_all_green_completes(self):
        log = []
        r = deploy_plan.run(EXAMPLE, executors(log), dry_run=True)
        self.assertEqual(r["status"], "completed")
        self.assertEqual(log, deploy_plan.STEPS[1:])  # validate is built in

    def test_failing_core_migrate_blocks_and_no_service_update(self):
        log = []
        r = deploy_plan.run(EXAMPLE, executors(log, fail={"core_migrate"}), dry_run=True)
        self.assertEqual(r["status"], "blocked")
        self.assertEqual(r["blocked_at"], "core_migrate")
        self.assertFalse([s for s in log if s.startswith("update_")])
        self.assertNotIn("engine_migrate", log)

    def test_invalid_manifest_runs_nothing(self):
        bad = copy.deepcopy(EXAMPLE)
        bad["approvals"] = []
        log = []
        r = deploy_plan.run(bad, executors(log), dry_run=True)
        self.assertEqual(r["status"], "blocked")
        self.assertEqual(log, [])

    def test_real_run_without_executors_is_refused(self):
        with self.assertRaises(deploy_plan.NoExecutor):
            deploy_plan.run(EXAMPLE, None, dry_run=False)

    def test_unproven_smoke_is_not_success(self):
        m = copy.deepcopy(EXAMPLE)
        m["smoke"]["result"] = "not_run"
        r = deploy_plan.run(m, executors([]), dry_run=True)
        self.assertEqual(r["status"], "completed")
        self.assertFalse(r["smoke_counts_as_success"])


if __name__ == "__main__":
    unittest.main()
