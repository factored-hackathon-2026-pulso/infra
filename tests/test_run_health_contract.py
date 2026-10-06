"""Run and health contract of the host bundles (INFRA-B, docs/run-and-health.md).

What `terraform test` cannot see: whether the compose files, the start script and the release script agree with what the
images really do (ports they must publish, health probes the images ship, who owns the bind-mounted data directories,
which secrets the engine refuses to start without). Static and offline: it reads files, it starts nothing.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "deploy" / "hackathon"
TF = ROOT / "terraform"
COMPUTE = TF / "modules" / "hackathon_compute"
DATA = TF / "modules" / "hackathon_data"


def load(path: Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))["services"]


CORE = load(BUNDLE / "core" / "compose.yaml")
AGENTS = load(BUNDLE / "core" / "compose.agents.yaml")
ENGINE = load(BUNDLE / "engine" / "compose.yaml")
PLATFORM = load(BUNDLE / "platform" / "compose.yaml")
ALL_FILES = {
    "core/compose.yaml": CORE,
    "core/compose.postgres.yaml": load(BUNDLE / "core" / "compose.postgres.yaml"),
    "core/compose.agents.yaml": AGENTS,
    "engine/compose.yaml": ENGINE,
    "platform/compose.yaml": PLATFORM,
    "platform/compose.agents.yaml": load(BUNDLE / "platform" / "compose.agents.yaml"),
}


class GatewayReachability(unittest.TestCase):
    def test_gateway_is_published_for_the_engine_host(self):
        # The network module opens core:8080 from the engine security group; the engine calls <core private IP>:8080.
        self.assertIn("8080:8080", CORE["llm-gateway"].get("ports", []))
        env_main = (TF / "envs" / "hackathon" / "main.tf").read_text(encoding="utf-8")
        self.assertRegex(env_main, r'extra_ports\s*=\s*concat\(\["8080:8080"\]')

    def test_gateway_uses_the_probe_its_distroless_image_ships(self):
        hc = CORE["llm-gateway"]["healthcheck"]
        self.assertNotEqual(hc.get("disable"), True)
        self.assertEqual(hc["test"], ["CMD", "/llm-gateway", "-healthcheck"])
        for key in ("interval", "timeout", "retries", "start_period"):
            self.assertIn(key, hc)

    def test_consumers_wait_for_a_healthy_gateway_and_tool_service(self):
        self.assertEqual(CORE["core-runtime"]["depends_on"]["llm-gateway"]["condition"], "service_healthy")
        dep = AGENTS["agent-core"]["depends_on"]
        self.assertEqual(dep["llm-gateway"]["condition"], "service_healthy")
        self.assertEqual(dep["tool-service"]["condition"], "service_healthy")


class DataDirectoryOwnership(unittest.TestCase):
    def test_every_app_user_bind_mount_is_chowned_by_the_start_script(self):
        prepare = (COMPUTE / "templates" / "prepare.sh.tftpl").read_text(encoding="utf-8")
        # The engine image runs as uid 10001 and its work/store dirs live on this bind mount.
        self.assertIn("/srv/data/pulso:/var/lib/pulso", "\n".join(ENGINE["pulso"]["volumes"]))
        self.assertRegex(prepare, r"chown[^\n]*10001:10001[^\n]*/srv/data/pulso")

    def test_boot_recreates_containers_after_the_tmpfs_is_rendered(self):
        unit = (COMPUTE / "templates" / "user_data.sh.tftpl").read_text(encoding="utf-8")
        # /run/pulso is tmpfs: after a reboot the bind sources of the old containers are gone; pulso-stack-up recreates once per
        # boot (marker on tmpfs) and never on a retry (tests/test_userdata_batch_contract.py).
        self.assertRegex(unit, r"(?m)^ExecStart=/usr/local/bin/pulso-stack-up$")
        self.assertIn("--force-recreate", unit)
        self.assertRegex(unit, r"(?m)^Restart=on-failure$")


class EngineBootContract(unittest.TestCase):
    """`pulso run` on a non-loopback bind refuses to start (exit 2) without two different tokens of >= 24 characters."""

    def test_both_engine_tokens_are_generated_secrets(self):
        generated = (DATA / "generated.tf").read_text(encoding="utf-8")
        secrets = (DATA / "secrets.tf").read_text(encoding="utf-8")
        for name in ("PULSO_DEBUG_TOKEN", "PULSO_ADMIN_TOKEN"):
            self.assertIn(f'"PULSO__{name}"', generated)
            self.assertIn(name, secrets)
        self.assertRegex(generated, r'resource "random_password" "engine_debug"[^}]*length\s*=\s*48')
        self.assertRegex(generated, r'resource "random_password" "engine_admin"[^}]*length\s*=\s*48')

    def test_engine_serves_under_the_cloudfront_prefix_without_stripping_it(self):
        caddy = (BUNDLE / "engine" / "Caddyfile").read_text(encoding="utf-8")
        self.assertNotIn("strip_prefix", caddy, "PULSO_BASE_PATH makes the engine expect the prefix")
        ssm = (DATA / "ssm.tf").read_text(encoding="utf-8")
        self.assertRegex(ssm, r'"engine/pulso/PULSO_BASE_PATH"\s*=\s*"/pulso"')

    def test_engine_healthcheck_is_the_binary_probe_with_a_migration_sized_start_period(self):
        hc = ENGINE["pulso"]["healthcheck"]
        self.assertEqual(hc["test"], ["CMD", "pulso", "healthcheck"])
        self.assertGreaterEqual(int(hc["start_period"].rstrip("s")), 60)


class ComposeHygiene(unittest.TestCase):
    def test_every_long_running_service_has_a_restart_policy_and_a_memory_limit(self):
        for fname, svcs in ALL_FILES.items():
            for name, s in svcs.items():
                if "image" not in s:  # an override that only adds depends_on or ports
                    continue
                with self.subTest(file=fname, service=name):
                    self.assertIn("mem_limit", s)
                    self.assertIn("restart", s)

    def test_one_shot_jobs_never_restart(self):
        for svcs in (CORE, AGENTS):
            for name in ("core-migrate", "agent-core-migrate"):
                if name in svcs and "image" in svcs[name]:  # an override that only sets a profile has no restart of its own
                    self.assertEqual(svcs[name]["restart"], "no")

    def test_disabled_healthchecks_are_justified_in_a_comment(self):
        for rel in ("core/compose.yaml",):
            lines = (BUNDLE / rel).read_text(encoding="utf-8").splitlines()
            for i, line in enumerate(lines):
                if re.match(r"\s*disable:\s*true", line):
                    window = "\n".join(lines[max(0, i - 3):i])
                    self.assertIn("#", window, f"{rel}:{i + 1} disables a healthcheck without saying why")

    def test_env_example_lists_every_image_variable_the_bundles_use(self):
        used = set()
        for path in BUNDLE.rglob("compose*.y*ml"):
            used |= set(re.findall(r"\$\{([A-Z0-9_]+_IMAGE)[:?}-]", path.read_text(encoding="utf-8")))
        example = (BUNDLE / ".env.example").read_text(encoding="utf-8")
        for var in sorted(used - {"POSTGRES_IMAGE"}):
            self.assertRegex(example, rf"(?m)^{var}=", f"{var} is used by a compose file but missing in .env.example")


class ReleaseScript(unittest.TestCase):
    def test_podman_builds_docker_format_for_amd64(self):
        text = (ROOT / "scripts" / "release-engine.ps1").read_text(encoding="utf-8")
        # OCI format silently drops HEALTHCHECK; every EC2 type of the environment is x86_64.
        self.assertRegex(text, r"'--format',\s*'docker'")
        self.assertRegex(text, r"'--platform',\s*'linux/amd64'")


class ObservabilityForwarder(unittest.TestCase):
    """The OTLP forwarder binds loopback only, so on the core host it is a sidecar in the netns of its producer."""

    FRAGMENT = BUNDLE / "core" / "compose.observability.yaml"
    DOCKERFILE = ROOT / "docker" / "otlp-forwarder.Dockerfile"

    def test_fragment_defines_one_sidecar_per_producer_without_published_ports(self):
        svcs = load(self.FRAGMENT)
        self.assertEqual({n for n in svcs if n.startswith("otlp-")}, {"otlp-forwarder-gateway", "otlp-forwarder-agent"})
        for name, producer in (("otlp-forwarder-gateway", "llm-gateway"), ("otlp-forwarder-agent", "agent-core")):
            s = svcs[name]
            self.assertEqual(s["network_mode"], f"service:{producer}")
            self.assertNotIn("ports", s)
            self.assertEqual(s["image"], "${FORWARDER_IMAGE:?set}")
            self.assertEqual(s["user"], "10001:10001")
            self.assertEqual(s["restart"], "unless-stopped")
            self.assertEqual(s["env_file"], ["/run/pulso/env/common.env", "/run/pulso/env/langfuse.env"])
            self.assertIn("/healthz", " ".join(s["healthcheck"]["test"]))

    def test_dockerfile_is_non_root_with_healthcheck_and_no_secrets(self):
        text = self.DOCKERFILE.read_text(encoding="utf-8")
        self.assertRegex(text, r"(?m)^USER 10001")
        self.assertIn("HEALTHCHECK", text)
        self.assertNotRegex(text, r"(?i)(secret|password|token|key)\s*=")
        for needed in ("otlp_forwarder.py", "runtrace_bridge.py", "trace_id.py", "agentcore_poller.py"):
            self.assertIn(needed, text)

    def test_fragment_is_wired_into_terraform_only_behind_the_variable(self):
        env_main = (TF / "envs" / "hackathon" / "main.tf").read_text(encoding="utf-8")
        self.assertIn('local.otlp ? ["compose.observability.yaml"] : []', env_main)
        self.assertRegex(env_main, r"otlp\s*=\s*var\.otlp_forwarder_enabled")


if __name__ == "__main__":
    unittest.main()


class AutoHeal(unittest.TestCase):
    UNIT = (COMPUTE / "templates" / "user_data.sh.tftpl").read_text(encoding="utf-8")

    def test_timer_restarts_unhealthy_pulso_and_agent_core_and_never_prints_env(self):
        self.assertIn("/usr/local/bin/pulso-autoheal", self.UNIT)
        self.assertRegex(self.UNIT, r"(?m)^OnUnitActiveSec=60s?$")
        self.assertRegex(self.UNIT, r"AUTOHEAL_SERVICES:-pulso}")
        self.assertIn("health=unhealthy", self.UNIT)
        self.assertIn("docker restart", self.UNIT)
        self.assertNotIn("docker inspect \"$id\" --format '{{.Config.Env", self.UNIT)
        self.assertIn("systemctl enable --now pulso-autoheal.timer", self.UNIT)

    def test_restart_storms_are_bounded(self):
        self.assertIn("AUTOHEAL_MAX_PER_HOUR", self.UNIT)


class DbBootstrapJob(unittest.TestCase):
    PG = load(BUNDLE / "core" / "compose.postgres.yaml")
    SCRIPT = BUNDLE / "core" / "bootstrap" / "pulso-db-bootstrap.sh"

    def test_job_is_a_one_shot_as_the_master_after_a_healthy_postgres(self):
        job = self.PG["pulso-db-bootstrap"]
        self.assertEqual(job["restart"], "no")
        self.assertEqual(job["env_file"], ["/run/pulso/env/db.env"])
        self.assertEqual(job["depends_on"]["postgres"]["condition"], "service_healthy")
        self.assertEqual(job["image"], "${POSTGRES_IMAGE:-postgres:16.4}")
        self.assertIn("./initdb/sql:/sql:ro", job["volumes"])

    def test_script_is_idempotent_quiet_and_waits_for_the_engine_roles(self):
        text = self.SCRIPT.read_text(encoding="utf-8")
        self.assertIn("30_pulso_logins.sql", text)
        self.assertIn("pulso_app", text)
        self.assertNotRegex(text, r"(?m)^\s*(set -x|echo .*PASSWORD)")
        self.assertIn(">/dev/null", text)
        self.assertRegex(text, r"exit 0")

    def test_script_ships_in_the_core_bundle_and_data_mode_has_a_real_value(self):
        env_main = (TF / "envs" / "hackathon" / "main.tf").read_text(encoding="utf-8")
        self.assertIn("bootstrap/pulso-db-bootstrap.sh", env_main)
        ssm = (DATA / "ssm.tf").read_text(encoding="utf-8")
        self.assertRegex(ssm, r'"engine/pulso/PULSO_DATA_MODE"\s*=\s*var\.engine_data_mode')
        self.assertNotRegex(ssm, r'"engine/pulso/PULSO_DATA_MODE"\s*=\s*"CHANGE_ME"')


class EngineDataModeMatchesAdapter(unittest.TestCase):
    """`pulso run` refuses PULSO_DATA_MODE/PULSO_SOURCE_ADAPTER mismatches (improvement-engine config.rs, config_conflict)."""

    RULE = {
        "dataset": {"stub", "dataset-pg", "dataset-raw", "dataset-augmented"},
        "platform": {"stub", "product-sqlite", "product-postgres"},
    }
    ENV = (TF / "envs" / "hackathon" / "main.tf").read_text(encoding="utf-8")
    SSM = (DATA / "ssm.tf").read_text(encoding="utf-8")

    def test_mode_is_a_derived_variable_never_ignored(self):
        self.assertRegex(self.ENV, r'engine_data_mode\s*=\s*local\.platform_db \? "platform" : "dataset"')
        self.assertIn("var.engine_data_mode", self.SSM)
        placeholders = self.SSM.split("ssm_derived = merge(")[0]
        self.assertNotIn("PULSO_DATA_MODE", placeholders)

    def test_default_and_platform_combinations_are_valid_per_the_engine_rule(self):
        adapter = re.search(r'PULSO_SOURCE_ADAPTER\s*=\s*"([^"]+)"', self.ENV).group(1)
        self.assertEqual(adapter, "product-postgres")
        mode_on = re.search(r'engine_data_mode\s*=\s*local\.platform_db \? "(\w+)" : "(\w+)"', self.ENV)
        self.assertIn(adapter, self.RULE[mode_on.group(1)])
        # platform_database_enabled=false: no adapter parameter exists (default stub), so dataset mode is valid.
        self.assertIn("stub", self.RULE[mode_on.group(2)])
        self.assertNotIn(adapter, self.RULE[mode_on.group(2)])


class LoopJobSlot(unittest.TestCase):
    """The loop job is wired now (docs/engine-loop.md, tests/test_engine_loop_contract.py); the old slots are closed."""

    LOOP = BUNDLE / "engine" / "compose.loop.yaml"

    def test_loop_job_is_wired_behind_its_variable_and_no_slot_remains(self):
        svc = load(self.LOOP)["pulso-loop"]
        self.assertEqual(svc["image"], "${PULSO_IMAGE:?set}")
        self.assertEqual(svc["command"], ["loop"])
        text = self.LOOP.read_text(encoding="utf-8")
        self.assertNotIn("SLOT", text)
        self.assertIn("PULSO_SERVICE_SEED_HEX", text)
        self.assertIn("compose.loop.yaml", (TF / "envs" / "hackathon" / "main.tf").read_text(encoding="utf-8"))
