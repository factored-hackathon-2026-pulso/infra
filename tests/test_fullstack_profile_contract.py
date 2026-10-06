"""Contract of the COMPLETE profile (terraform/envs/hackathon/prod.tfvars.complete.example) and of what must come with it.

Offline and read-only: no Terraform binary, no AWS, no PowerShell. The profile must switch on every service of the system with no
flag left off, must never carry the doubles switch or a static registry token, and must keep the platform host on the staging
runtime (seeded demo accounts, dev MFA code). The image build path (scripts/aws-prod.ps1) and the acceptance script
(scripts/aws-acceptance.ps1) are checked statically against the same profile, so a new image or flag cannot be added in one place only.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENV = ROOT / "terraform" / "envs" / "hackathon"
PROFILE = ENV / "prod.tfvars.complete.example"
BUNDLE = ROOT / "deploy" / "hackathon"
FORBIDDEN = ("AGENTCORE_ALLOW_DOUBLES", "AGENTCORE_ALLOW_DEMO", "PULSO_REGISTRY_TOKEN")


def code_lines(text: str) -> list[str]:
    """Lines without full-line comments and without trailing ` # ...` comments (values here never contain a hash)."""
    out = []
    for line in text.splitlines():
        stripped = re.sub(r"\s+#.*$", "", line).rstrip()
        if stripped.strip() and not stripped.strip().startswith("#"):
            out.append(stripped)
    return out


def profile_text() -> str:
    return "\n".join(code_lines(PROFILE.read_text(encoding="utf-8")))


def scalar(name: str) -> str | None:
    m = re.search(rf"(?m)^{re.escape(name)}\s*=\s*(.+?)\s*$", profile_text())
    return m.group(1) if m else None


def map_value(name: str) -> dict[str, str]:
    m = re.search(rf"(?m)^{re.escape(name)}\s*=\s*\{{(.*?)\}}\s*$", profile_text())
    assert m, f"{name} is not set (single-line map) in the profile"
    return {k: v for k, v in re.findall(r"(\w+)\s*=\s*\"?([\w.-]+)\"?", m.group(1))}


def images_block() -> dict[str, dict[str, str]]:
    text = profile_text()
    m = re.search(r"(?ms)^images\s*=\s*\{(.*?)^\}", text)
    assert m, "images block missing"
    groups = {}
    for name, body in re.findall(r"(?ms)^  (\w+) = \{(.*?)^  \}", m.group(1)):
        groups[name] = dict(re.findall(r"(\w+)\s*=\s*\"([^\"]+)\"", body))
    return groups


def variables(path: Path) -> dict[str, str]:
    """variable name -> its block body, for the hackathon root."""
    text = (path / "variables.tf").read_text(encoding="utf-8")
    return {m.group(1): m.group(2) for m in re.finditer(r'(?ms)^variable\s+"([^"]+)"\s*\{(.*?)^\}', text)}


class EveryServiceIsOn(unittest.TestCase):
    """(a) the profile enables every service of the system with no flag left off."""

    def test_every_bool_service_flag_defaulting_to_false_is_true_in_the_profile(self):
        flags = []
        for name, body in variables(ENV).items():
            if name.endswith("_enabled") and re.search(r"type\s*=\s*bool", body) and re.search(r"default\s*=\s*false", body):
                flags.append(name)
        self.assertTrue(flags, "no *_enabled flag found: the rule would pass by accident")
        off = [f for f in flags if scalar(f) != "true"]
        self.assertEqual([], off, "service flags left off in the complete profile (set them to true or justify them in this test)")

    def test_the_five_service_flags_are_named_explicitly(self):
        for flag in ("agent_services_enabled", "platform_database_enabled", "auto_loader_enabled", "engine_loop_enabled", "otlp_forwarder_enabled"):
            self.assertEqual("true", scalar(flag), flag)

    def test_every_host_is_enabled_and_the_edge_is_on(self):
        self.assertEqual({"core": "true", "platform": "true", "engine": "true"}, map_value("enabled"))
        self.assertEqual("true", scalar("edge_enabled"))

    def test_instance_types_are_the_largest_free_plan_type_for_core_and_engine(self):
        types = map_value("instance_types")
        self.assertEqual("m7i-flex.large", types["core"])
        self.assertEqual("m7i-flex.large", types["engine"])
        allowed = re.search(r'contains\(\[([^\]]+)\]', variables(ENV)["instance_types"]).group(1)
        for host, t in types.items():
            self.assertIn(f'"{t}"', allowed, f"{host}: {t} is not a Free Plan type accepted by var.instance_types")

    def test_the_loop_reads_the_bank_cells_and_the_loader_role_is_the_only_loader(self):
        self.assertEqual('"bank"', scalar("engine_loop_cells_source"))
        self.assertEqual('"standard"', scalar("engine_loop_profile"))
        self.assertEqual("false", scalar("engine_host_can_load"))

    def test_every_name_in_the_profile_is_a_variable_of_the_root(self):
        known = set(variables(ENV))
        names = set(re.findall(r"(?m)^([a-z_]+)\s*=", profile_text()))
        self.assertEqual(set(), names - known)

    def test_the_profile_stays_on_the_free_plan_with_the_waf_off_and_no_custom_domain(self):
        self.assertEqual('"free_plan"', scalar("profile"))
        self.assertEqual("false", scalar("enable_waf"))
        text = profile_text()
        for forbidden in ("domain_name", "certificate", "acm", "allowlist", "origin_secret", "viewer_cidr"):
            self.assertNotIn(forbidden, text, "the public URL is intentionally unrestricted and has no custom domain")


class EveryImageIsPinned(unittest.TestCase):
    """Every image of the system has a digest-pinned slot in the profile, a repository, a build path."""

    REQUIRED = {
        "core": {"gateway", "agent", "tools", "forwarder"},
        "platform": {"support_api", "support_web", "proxy"},
        "engine": {"pulso", "proxy", "pipeline", "forwarder"},
    }

    def test_slots_per_host(self):
        blocks = images_block()
        for host, keys in self.REQUIRED.items():
            self.assertEqual(keys, set(blocks[host]), host)

    def test_references_are_digest_pinned_in_the_prefix_and_in_a_bootstrap_repository(self):
        bootstrap = (ROOT / "terraform" / "bootstrap" / "variables.tf").read_text(encoding="utf-8")
        repos = set(re.findall(r'"([a-z0-9-]+)"', re.search(r'variable "ecr_repositories".*?default\s*=\s*\[(.*?)\]', bootstrap, re.S).group(1)))
        for host, slots in images_block().items():
            for key, ref in slots.items():
                m = re.fullmatch(r"<registry>/pulso-prod/([a-z0-9-]+)@sha256:REPLACE_WITH_64_HEX_DIGEST", ref)
                self.assertIsNotNone(m, f"{host}.{key}: {ref}")
                self.assertIn(m.group(1), repos, f"{host}.{key}: repository {m.group(1)} is not created by terraform/bootstrap")
                self.assertNotIn(":latest", ref)

    def test_the_forwarder_is_one_image_in_two_slots(self):
        blocks = images_block()
        self.assertEqual(blocks["core"]["forwarder"], blocks["engine"]["forwarder"])
        self.assertEqual(blocks["platform"]["proxy"], blocks["engine"]["proxy"])

    def test_the_legacy_core_bridge_image_is_not_needed(self):
        self.assertNotIn("core", images_block()["core"], "agent-core serve replaces the core-bridge image (ADR 0009)")

    def test_every_service_of_the_image_script_has_its_slot_except_the_legacy_core_runtime(self):
        script = (ROOT / "scripts" / "aws-prod.ps1").read_text(encoding="utf-8")
        table = script[script.index("$script:Services = [ordered]@{") : script.index("function Resolve-Service")]
        keys = set(re.findall(r"Key = '([a-z_]+)'", table))
        self.assertEqual(
            {"core", "gateway", "support_api", "support_web", "pulso", "proxy", "agent", "tools", "pipeline", "forwarder"}, keys,
            "ten images are built by aws-prod.ps1 images -Service: a new one needs a slot, a recipe and a line in this test",
        )
        slots = set().union(*(set(v) for v in images_block().values()))
        self.assertEqual({"core"}, keys - slots, "only the legacy core-runtime key may lack a slot in the complete profile")

    def test_every_buildable_service_has_a_host_build_recipe_and_a_codebuild_project(self):
        script = (ROOT / "scripts" / "aws-prod.ps1").read_text(encoding="utf-8")
        services = set(re.findall(r"^    '([a-z-]+)'\s+= @\{ Key = ", script, re.M))
        host = set(re.findall(r"^    '([a-z-]+)'\s+= @\{ Dockerfile = ", script, re.M))
        self.assertEqual({"caddy"}, services - host, "-Builder host must be able to build every service (caddy is a mirror, not a build)")
        main = (ENV / "main.tf").read_text(encoding="utf-8")
        for name in services:
            self.assertIn(f'"{name}"', main, f"{name}: no CodeBuild project in terraform/envs/hackathon/main.tf")

    def test_the_builder_stage_carries_every_slot_so_the_images_can_be_built_before_the_hosts_exist(self):
        script = (ROOT / "scripts" / "aws-prod.ps1").read_text(encoding="utf-8")
        stage = script[script.index("function Invoke-PlanBuilderStage") :]
        stage = stage[: stage.index("Set-Content -Encoding utf8 $stageFile")]
        for slot in ("agent", "tools", "forwarder", "pipeline", "support_api", "support_web", "gateway", "pulso", "proxy"):
            self.assertRegex(stage, rf"(?m)^\s+{slot}\s+= ", f"builder stage lacks {slot}: the complete profile would fail the images validation")

    def test_the_web_image_can_be_built_same_origin(self):
        script = (ROOT / "scripts" / "aws-prod.ps1").read_text(encoding="utf-8")
        self.assertIn("$p.ViteApiUrl -ne '/'", script, "-ViteApiUrl / is the same-origin build behind CloudFront")

    def test_the_forwarder_build_ships_this_repositorys_dockerfile(self):
        script = (ROOT / "scripts" / "aws-prod.ps1").read_text(encoding="utf-8")
        self.assertIn("docker/otlp-forwarder.Dockerfile", script)
        self.assertRegex(script, r"otlp-forwarder'.*Test-Path.*docker/otlp-forwarder\.Dockerfile.*Prefix = 'docker'")
        self.assertTrue((ROOT / "docker" / "otlp-forwarder.Dockerfile").exists())


class NeverTheDoublesNorAStaticToken(unittest.TestCase):
    """(b) AGENTCORE_ALLOW_DOUBLES and PULSO_REGISTRY_TOKEN are set nowhere: not in the profile, the bundle or the secret contract."""

    def test_the_profile_and_its_serve_arguments(self):
        text = profile_text()
        for name in FORBIDDEN:
            self.assertNotIn(name, text, name)
        self.assertNotIn("agent_serve_args", text, "the seven real pieces are serve's defaults; the profile passes no override")
        self.assertNotRegex(text, r"testing\.|--allow|doubles", "no testing double, no allow switch")

    def test_the_deploy_bundle_sets_neither(self):
        offenders = []
        for f in BUNDLE.rglob("*"):
            if not f.is_file() or "config" in f.relative_to(BUNDLE).parts[:1]:
                continue
            for line in code_lines(f.read_text(encoding="utf-8", errors="replace")):
                if any(name in line for name in FORBIDDEN):
                    offenders.append(f"{f.relative_to(ROOT)}: {line.strip()[:100]}")
        self.assertEqual([], offenders)

    def test_the_secret_contract_has_no_such_key(self):
        text = (ROOT / "scripts" / "secrets_contract.json").read_text(encoding="utf-8")
        for name in FORBIDDEN:
            self.assertNotIn(name, text)
        for fragment in ("ALLOW_DOUBLES", "REGISTRY_TOKEN"):
            self.assertNotIn(fragment, text)

    def test_the_hackathon_root_and_its_modules_do_not_define_them(self):
        offenders = []
        for base in (ENV, *(ROOT / "terraform" / "modules").glob("hackathon_*")):
            for f in base.rglob("*"):
                if not f.is_file() or f.suffix not in {".tf", ".tftpl", ".sh"}:
                    continue
                for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
                    s = line.strip()
                    if s.startswith("#") or s.startswith("//"):
                        continue
                    # The start script's refusal and the tests' negative assertions mention the names on purpose.
                    if any(name in s for name in FORBIDDEN) and not re.search(r"echo|refus|error_message|prohibit", s):
                        offenders.append(f"{f.relative_to(ROOT)}:{n}")
        self.assertEqual([], offenders)


class PlatformHostStaysOnStaging(unittest.TestCase):
    """(c) the platform host is enabled and runs CC_ENV=staging demo settings, never prod (which rejects the demo accounts)."""

    PLATFORM = BUNDLE / "platform"

    def platform_code(self) -> str:
        return "\n".join(code_lines("\n".join(f.read_text(encoding="utf-8") for f in self.PLATFORM.glob("compose*.yaml"))))

    def test_the_platform_host_is_enabled_in_the_profile(self):
        self.assertEqual("true", map_value("enabled")["platform"])

    def test_the_profile_does_not_set_the_platform_environment(self):
        text = profile_text()
        self.assertNotRegex(text, r"CC_ENV|cc_env|CC_SEED|CC_DEV")

    def test_no_platform_file_runs_prod_or_production(self):
        self.assertNotRegex(self.platform_code(), r"CC_ENV\s*[:=]\s*\"?(prod|production)\b")

    def test_cc_env_is_staging_with_the_demo_settings_once_the_bundle_declares_it(self):
        code = self.platform_code()
        if "CC_ENV" not in code:
            self.skipTest("the platform bundle does not declare CC_ENV yet (it lands with the platform deploy-contract PR); until then the profile cannot enforce it")
        self.assertRegex(code, r"CC_ENV:\s*\"?staging\"?")
        for setting in ("CC_SEED_DEMO_DATA", "CC_DEV_MAILBOX"):
            self.assertRegex(code, rf"{setting}:\s*\"?true\"?", setting)

    def test_the_platform_secret_and_demo_keys_are_not_defined_as_production_only(self):
        # the dev MFA code is a staging behaviour of the platform itself: no key of the secret contract may set it, so it cannot drift
        contract = (ROOT / "scripts" / "secrets_contract.json").read_text(encoding="utf-8")
        self.assertNotIn("CC_DEV_MFA_CODE", contract)


class AcceptanceCoversTheWholeProfile(unittest.TestCase):
    """The acceptance script has a check for every service the profile turns on, in the documented order."""

    SCRIPT = (ROOT / "scripts" / "aws-acceptance.ps1").read_text(encoding="utf-8")

    def test_the_checks_exist_in_order(self):
        order = [
            "edge-spa", "platform-health", "demo-login", "customer-chat", "agent-core-ready", "gateway-ready", "tool-service-ready",
            "loader-marker", "lake-zones", "engine-edge", "engine-loop-check", "engine-loop-unit", "engine-announce", "forwarder",
        ]
        calls = self.SCRIPT[self.SCRIPT.index("function Invoke-Acceptance") :]
        positions = [calls.rfind(f"'{name}'") for name in order]
        self.assertNotIn(-1, positions, dict(zip(order, positions)))
        self.assertEqual(sorted(positions), positions, "the checks run in the order of the runbook")

    def test_it_is_read_only_and_never_takes_a_secret(self):
        text = self.SCRIPT
        for verb in ("put-secret-value", "put-object", "delete-", "update-", "terminate-", "create-", "run-instances", "apply", "put-parameter"):
            self.assertNotIn(verb, text, verb)
        self.assertNotIn("get-secret-value", text, "the script must not read secrets")
        params = re.search(r"(?ms)^param\((.*?)^\)", text).group(1)
        self.assertNotRegex(params, r"(?i)\$(token|secret|apikey|accesskey)", "no script parameter takes a secret")
        self.assertIn("-K -", text, "tokens reach curl on its standard input, never in a command line")
        self.assertRegex(text, r"if \(\$fail -gt 0\) \{ return 1 \}")

    def test_the_runbook_names_the_script_and_the_profile(self):
        doc = (ROOT / "docs" / "infra-day-one.md").read_text(encoding="utf-8")
        self.assertIn("aws-acceptance.ps1", doc)
        self.assertIn("prod.tfvars.complete.example", doc)


if __name__ == "__main__":
    unittest.main()
