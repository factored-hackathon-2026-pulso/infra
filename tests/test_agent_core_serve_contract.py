"""Contract of the core host's agent-core serve wiring (docs/agent-core-serve.md).

The source of truth is agent-core docs/serve-env.md (PRs 62 to 70). This file pins: every variable name of that document is accounted
for, the compose environment only uses names serve reads, health and readiness, start period, load caps, shutdown grace, migration
ordering (and that pulso-db-bootstrap is not in the chain), the legacy core-bridge services are disabled, AGENTCORE_ALLOW_DOUBLES can
never be set, and the engine key rotation (Terraform variables and the offline merge helper).
"""

from __future__ import annotations

import base64
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "deploy" / "hackathon"
CORE = BUNDLE / "core"
TF = ROOT / "terraform"
DOC = ROOT / "docs" / "agent-core-serve.md"


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


def load(p: Path) -> dict:
    return yaml.safe_load(read(p))["services"]


# Every environment variable of agent-core docs/serve-env.md (2026-10-05, agent-core main after PR 70), by section.
SERVE_ENV = {
    "core": ["AGENTCORE_REGISTRY_DSN", "AGENTCORE_KEYS_FINGERPRINT", "AGENTCORE_KEYS_TOKEN_MAP", "AGENTCORE_JEV_API_KEY",
             "AGENTCORE_SERVE_AGENTS", "AGENTCORE_GIT_SHA", "AGENTCORE_DB_POOL_MAX", "AGENTCORE_LANG_THRESHOLDS",
             "AGENTCORE_FX_RATES_FILE", "AGENTCORE_IDENTITY_KEYS_FILE", "AGENTCORE_REGISTRY_API", "AGENTCORE_STAFF_KEYS_FILE",
             "AGENTCORE_EVAL_DSN", "AGENTCORE_KEYS_RELOAD_SECONDS"],
    "pieces": ["AGENTCORE_TOOL_SERVICE_URL", "AGENTCORE_TOOL_SERVICE_TOKEN", "AGENTCORE_TOOL_SERVICE_TIMEOUT_S",
               "AGENTCORE_AUTHZ_FIELD_GRANTS_FILE", "AGENTCORE_AUTHZ_BIND_KEYS", "AGENTCORE_CALIBRATION_DIR",
               "AGENTCORE_CLASSIFIER_ARTIFACTS_DIR", "AGENTCORE_FIELD_CLASSIFICATION_FILES", "AGENTCORE_GRANTS_URL",
               "AGENTCORE_GRANTS_TOKEN", "AGENTCORE_GRANTS_TIMEOUT_S", "AGENTCORE_GRANTS_CACHE_TTL_S"],
    "external": ["AGENTCORE_LLM_GATEWAY_URL", "AGENTCORE_LLM_GATEWAY_TOKEN", "AGENTCORE_BLOB_BUCKET", "AGENTCORE_BLOB_PREFIX",
                 "AGENTCORE_BLOB_KMS_KEY_ARN", "AGENTCORE_EVENTS_TOPIC_ARN"],
    "operation": ["AGENTCORE_ALLOW_DOUBLES", "AGENTCORE_AUTO_MIGRATE", "AGENTCORE_READY_REQUIRE_LLM_GATEWAY",
                  "AGENTCORE_READY_REQUIRE_TOOL_SERVICE", "AGENTCORE_MAX_INFLIGHT", "AGENTCORE_WORKER_THREADS",
                  "AGENTCORE_SHUTDOWN_GRACE_SECONDS", "AGENTCORE_RATE_MAX_HITS", "AGENTCORE_RATE_WINDOW_SECONDS",
                  "AGENTCORE_RATE_SERVICE_MULTIPLIER", "AGENTCORE_DAILY_BUDGET_USD"],
    "observability": ["OTEL_TRACES_EXPORTER", "OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
                      "OTEL_EXPORTER_OTLP_PROTOCOL", "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL", "OTEL_EXPORTER_OTLP_HEADERS",
                      "OTEL_EXPORTER_OTLP_TRACES_HEADERS", "OTEL_SERVICE_NAME", "OTEL_RESOURCE_ATTRIBUTES", "OTEL_TRACES_SAMPLER",
                      "OTEL_TRACES_SAMPLER_ARG", "OTEL_SDK_DISABLED", "AGENTCORE_TRACE_CONTENT", "AGENTCORE_TRACE_LANGFUSE"],
}
ALL_NAMES = {n for names in SERVE_ENV.values() for n in names}
# Read by serve but owned by the infra repo, not part of serve-env.md: the one-shot's owner DSNs (infra naming) and the legacy alias.
INFRA_ONLY = {"AGENTCORE_MIGRATE_DSN", "AGENTCORE_MIGRATE_EVAL_DSN"}


class EveryNameIsAccountedFor(unittest.TestCase):
    def test_the_doc_lists_every_variable_of_serve_env(self):
        text = read(DOC)
        for name in sorted(ALL_NAMES):
            self.assertTrue(f"`{name}`" in text, f"{name} is not documented in docs/agent-core-serve.md")

    def test_the_doc_states_who_provides_what_for_the_required_ones(self):
        text = read(DOC)
        for name in ("AGENTCORE_REGISTRY_DSN", "AGENTCORE_KEYS_FINGERPRINT", "AGENTCORE_KEYS_TOKEN_MAP", "AGENTCORE_JEV_API_KEY"):
            row = next(l for l in text.splitlines() if l.startswith(f"| `{name}`"))
            self.assertIn("secret", row, name)

    def test_compose_environment_only_uses_names_serve_reads(self):
        env = load(CORE / "compose.agents.yaml")["agent-core"]["environment"]
        unknown = set(env) - ALL_NAMES - INFRA_ONLY
        self.assertEqual(set(), unknown, "serve would ignore these names (typo?)")

    def test_required_names_are_set_as_literals_or_come_from_the_secret_files(self):
        svc = load(CORE / "compose.agents.yaml")["agent-core"]
        env = svc["environment"]
        secrets_tf = read(TF / "modules" / "hackathon_data" / "secrets.tf")
        for name in ("AGENTCORE_REGISTRY_DSN", "AGENTCORE_KEYS_FINGERPRINT", "AGENTCORE_KEYS_TOKEN_MAP", "AGENTCORE_JEV_API_KEY",
                     "AGENTCORE_TOOL_SERVICE_TOKEN", "AGENTCORE_GRANTS_TOKEN", "AGENTCORE_LLM_GATEWAY_TOKEN", "AGENTCORE_EVAL_DSN"):
            self.assertNotIn(name, env, f"{name} is a secret: it must come from agent.env, never from compose")
            self.assertIn(f'"{name}"', secrets_tf, f"secret key AGENT__{name} is missing from secrets.tf")
        for name in ("AGENTCORE_REGISTRY_API", "AGENTCORE_IDENTITY_KEYS_FILE", "AGENTCORE_STAFF_KEYS_FILE", "AGENTCORE_TOOL_SERVICE_URL",
                     "AGENTCORE_GRANTS_URL", "AGENTCORE_CALIBRATION_DIR", "AGENTCORE_CLASSIFIER_ARTIFACTS_DIR",
                     "AGENTCORE_FIELD_CLASSIFICATION_FILES", "AGENTCORE_LLM_GATEWAY_URL"):
            self.assertIn(name, env, name)
        self.assertEqual(env["AGENTCORE_REGISTRY_API"], "1")
        self.assertEqual(env["AGENTCORE_IDENTITY_KEYS_FILE"], "/run/files/IDENTITY_KEYS")
        self.assertEqual(env["AGENTCORE_STAFF_KEYS_FILE"], "/run/files/STAFF_KEYS")

    def test_no_secret_value_in_the_compose_files(self):
        for name in ("compose.agents.yaml", "compose.agents.postgres.yaml", "compose.observability.yaml"):
            self.assertNotRegex(read(CORE / name), r"(?i)(password|_token|api_key|_dsn|_headers)\s*:\s*[^\s#$\"'][^\s#]*")

    def test_the_owner_dsns_never_reach_the_long_running_process(self):
        for name in ("agent-core", "agent-core-sweep"):
            env = load(CORE / "compose.agents.yaml")[name]["environment"]
            self.assertEqual(env["AGENTCORE_MIGRATE_DSN"], "")
            self.assertEqual(env["AGENTCORE_MIGRATE_EVAL_DSN"], "")


class HealthAndLoad(unittest.TestCase):
    def setUp(self):
        self.svc = load(CORE / "compose.agents.yaml")["agent-core"]
        self.env = self.svc["environment"]

    def test_container_health_is_readiness_with_a_start_period(self):
        hc = self.svc["healthcheck"]
        self.assertIn("/readyz", " ".join(hc["test"]))
        self.assertIn(":8001/", " ".join(hc["test"]), "this host serves 8001, not the image default 8000")
        self.assertGreaterEqual(int(hc["start_period"].rstrip("s")), 60)
        self.assertGreaterEqual(hc["retries"], 3)
        self.assertLess(int(hc["timeout"].rstrip("s")), int(hc["interval"].rstrip("s")))

    def test_liveness_and_readiness_are_both_documented_and_the_optional_checks_configured(self):
        self.assertEqual(self.env["AGENTCORE_READY_REQUIRE_LLM_GATEWAY"], "1")
        self.assertEqual(self.env["AGENTCORE_READY_REQUIRE_TOOL_SERVICE"], "1")
        text = read(DOC)
        self.assertIn("`GET /healthz`", text)
        self.assertIn("`GET /readyz`", text)

    def test_shutdown_grace_is_below_the_orchestrator_grace(self):
        grace = int(self.env["AGENTCORE_SHUTDOWN_GRACE_SECONDS"])
        stop = int(self.svc["stop_grace_period"].rstrip("s"))
        self.assertLess(grace, stop)
        self.assertGreaterEqual(stop - grace, 3)

    def test_load_caps_are_wired_from_the_instance_size(self):
        self.assertEqual(self.env["AGENTCORE_MAX_INFLIGHT"], "${AGENT_MAX_INFLIGHT:-16}")
        self.assertEqual(self.env["AGENTCORE_WORKER_THREADS"], "${AGENT_WORKER_THREADS:-12}")
        self.assertEqual(self.env["AGENTCORE_DB_POOL_MAX"], "${AGENT_DB_POOL_MAX:-6}")
        main = read(TF / "envs" / "hackathon" / "main.tf")
        tiers = re.findall(r"\{ inflight = (\d+), workers = (\d+), pool = (\d+) \}", main)
        self.assertEqual(len(tiers), 3, "one tier per memory class")
        values = [tuple(int(x) for x in t) for t in tiers]
        # largest instance first: more memory never gets a smaller cap
        for bigger, smaller in zip(values, values[1:]):
            for a, b in zip(bigger, smaller):
                self.assertGreaterEqual(a, b)
        for inflight, workers, pool in values:
            self.assertGreaterEqual(inflight, workers, "in-flight requests are not capped below the worker threads")
            self.assertLessEqual(pool, workers)
            self.assertLessEqual(pool, 10, "Postgres max_connections is 100 and shared with platform, tools and the engine")
        self.assertRegex(main, r"core_memory_mb >= 8192")
        self.assertRegex(main, r"AGENT_MAX_INFLIGHT\s*=\s*tostring")

    def test_pool_fits_the_postgres_connection_budget(self):
        pg = read(CORE / "compose.postgres.yaml")
        max_conn = int(re.search(r"max_connections=(\d+)", pg).group(1))
        pool = max(int(t[2]) for t in re.findall(r"\{ inflight = (\d+), workers = (\d+), pool = (\d+) \}", read(TF / "envs" / "hackathon" / "main.tf")))
        # agent-core pool + a short-lived migrate/sweep connection each + generous allowance for platform, tools, engine, exporter
        self.assertLessEqual(pool + 2 + 60, max_conn)

    def test_memory_of_the_core_host_still_leaves_headroom(self):
        total = 0
        for name in ("compose.yaml", "compose.postgres.yaml", "compose.agents.yaml"):
            services = load(CORE / name)
            for n, s in services.items():
                if "profiles" in s or n in ("core-runtime", "core-exporter", "core-migrate") and name == "compose.yaml":
                    continue  # disabled legacy services and one-shots under a profile never run together with serve
                total += int(re.fullmatch(r"(\d+)m", s.get("mem_limit", "0m")).group(1))
        self.assertLessEqual(total, 8192 * 0.7)


class LegacyBridgeIsReplaced(unittest.TestCase):
    def test_core_bridge_services_are_behind_a_profile_when_serve_is_on(self):
        svc = load(CORE / "compose.agents.yaml")
        for name in ("core-migrate", "core-runtime", "core-exporter"):
            self.assertEqual(svc[name]["profiles"], ["legacy-core-bridge"], name)
        self.assertNotIn("depends_on", svc["agent-core-migrate"], "serve's chain must not run through the legacy core-migrate")
        for s in ("agent-core", "agent-core-migrate", "tool-service"):
            self.assertNotIn("legacy", json.dumps(svc[s].get("depends_on", {})))

    def test_the_image_is_agent_cores_own_by_digest_variable(self):
        svc = load(CORE / "compose.agents.yaml")
        for name in ("agent-core", "agent-core-migrate", "agent-core-sweep"):
            self.assertEqual(svc[name]["image"], "${AGENT_IMAGE:?set}")
        self.assertNotIn(":latest", read(CORE / "compose.agents.yaml"))
        env = read(BUNDLE / ".env.example")
        self.assertRegex(env, r"(?m)^AGENT_IMAGE=.*/agent-core-serve@sha256:")
        bootstrap = read(TF / "bootstrap" / "variables.tf")
        self.assertIn('"agent-core-serve"', bootstrap)

    def test_core_image_aliases_the_agent_image_so_interpolation_succeeds(self):
        main = read(TF / "envs" / "hackathon" / "main.tf")
        self.assertRegex(main, r"images_core\s*=\s*local\.agents && !contains\(keys\(var\.images\.core\), \"core\"\) \? merge\(var\.images\.core, \{ core = var\.images\.core\.agent \}\)")
        self.assertRegex(main, r"images\s*=\s*local\.images_core")

    def test_serve_takes_no_piece_flags_by_default(self):
        cmd = load(CORE / "compose.agents.yaml")["agent-core"]["command"]
        self.assertIn("serve --host 0.0.0.0 --port 8001", cmd)
        self.assertIn("${AGENT_SERVE_ARGS:-}", cmd)
        self.assertNotIn("--tools", cmd)
        variables = read(TF / "envs" / "hackathon" / "variables.tf")
        m = re.search(r'variable "agent_serve_args" \{.*?\n\}\n', variables, re.S).group(0)
        self.assertIn('default     = ""', m)


class MigrationAndBootstrapOrdering(unittest.TestCase):
    def test_migrate_waits_for_a_healthy_postgres_in_container_mode_and_serve_waits_for_migrate(self):
        pg = load(CORE / "compose.agents.postgres.yaml")
        self.assertEqual(pg["agent-core-migrate"]["depends_on"]["postgres"]["condition"], "service_healthy")
        agents = load(CORE / "compose.agents.yaml")
        self.assertEqual(agents["agent-core"]["depends_on"]["agent-core-migrate"]["condition"], "service_completed_successfully")
        self.assertEqual(agents["agent-core-migrate"]["restart"], "no")
        entry = " ".join(agents["agent-core-migrate"]["entrypoint"])
        self.assertIn("agentcore migrate --app-role agent_app", entry)
        self.assertEqual(load(CORE / "compose.agents.yaml")["agent-core"]["environment"]["AGENTCORE_AUTO_MIGRATE"], "0")

    def test_the_postgres_override_is_merged_after_the_agents_file(self):
        main = read(TF / "envs" / "hackathon" / "main.tf")
        self.assertRegex(main, r'local\.agents \? \["compose\.agents\.yaml"\] : \[\],\s*local\.agents && local\.container_db \? \["compose\.agents\.postgres\.yaml"\]')

    def test_pulso_db_bootstrap_is_independent_of_the_agent_chain(self):
        pg = load(CORE / "compose.postgres.yaml")
        self.assertEqual(pg["pulso-db-bootstrap"]["depends_on"]["postgres"]["condition"], "service_healthy")
        for name, svc in load(CORE / "compose.agents.yaml").items():
            self.assertNotIn("pulso-db-bootstrap", svc.get("depends_on", {}), name)
        for name, svc in load(CORE / "compose.agents.postgres.yaml").items():
            self.assertNotIn("pulso-db-bootstrap", svc.get("depends_on", {}), name)
        script = read(CORE / "bootstrap" / "pulso-db-bootstrap.sh")
        self.assertIn("exit 0", script, "never blocks the host: exits 0 when the engine roles do not exist yet")

    def test_sweep_is_a_profile_one_shot_run_by_a_timer(self):
        sweep = load(CORE / "compose.agents.yaml")["agent-core-sweep"]
        self.assertEqual(sweep["command"], ["sweep", "--once"])
        self.assertEqual(sweep["profiles"], ["sweep"])
        self.assertEqual(sweep["restart"], "no")
        unit = read(CORE / "sweep" / "pulso-agent-sweep.service")
        self.assertIn("run --rm --no-TTY agent-core-sweep", unit)
        self.assertIn("OnUnitInactiveSec=5min", read(CORE / "sweep" / "pulso-agent-sweep.timer"))
        prepare = read(TF / "modules" / "hackathon_compute" / "templates" / "prepare.sh.tftpl")
        self.assertIn("systemctl enable --now pulso-agent-sweep.timer", prepare)


TOKEN = re.compile(r"AGENTCORE_ALLOW_(DOUBLES|DEMO)")
EXPLAINS = ("prohibited", "refus", "never takes", "grep -qE", "must be absent", "ABSENT", "never be set", "forbidden")


class AllowDoublesCanNeverBeSet(unittest.TestCase):
    """AGENTCORE_ALLOW_DOUBLES lets serve use testing.* doubles; prohibited in deployments (serve-env.md section 4)."""

    def test_no_bundle_or_terraform_file_sets_it(self):
        hackathon = [TF / "envs" / "hackathon"] + sorted((TF / "modules").glob("hackathon_*"))
        paths = [p for p in list(BUNDLE.rglob("*")) + [f for d in hackathon for f in d.rglob("*")] if p.is_file() and ".terraform" not in p.parts
                 and ".tftest" not in p.name and p.suffix in {".yaml", ".yml", ".tf", ".tftpl", ".sh", ".service", ".timer", ".example", ".hcl", ".sql", ".env"}]
        self.assertGreater(len(paths), 40)
        for p in paths:
            for n, line in enumerate(read(p).splitlines(), 1):
                if TOKEN.search(line):
                    stripped = line.lstrip()
                    ok = stripped.startswith("#") or any(w in line for w in EXPLAINS)
                    self.assertTrue(ok, f"{p.relative_to(ROOT)}:{n} sets or mentions AGENTCORE_ALLOW_* without saying it is prohibited")

    def test_no_compose_environment_or_env_file_has_the_name(self):
        for path in list(BUNDLE.rglob("compose*.yaml")):
            for name, svc in yaml.safe_load(read(path))["services"].items():
                env = svc.get("environment", {})
                names = set(env) if isinstance(env, dict) else {e.split("=")[0] for e in env}
                self.assertFalse(any(TOKEN.fullmatch(n) for n in names), f"{path.name}:{name}")

    def test_secret_and_ssm_key_lists_cannot_contain_it(self):
        for name in ("secrets.tf", "ssm.tf", "generated.tf"):
            for line in read(TF / "modules" / "hackathon_data" / name).splitlines():
                if TOKEN.search(line):
                    self.assertTrue(line.lstrip().startswith("#"), line)

    def test_serve_args_cannot_carry_doubles(self):
        variables = read(TF / "envs" / "hackathon" / "variables.tf")
        block = re.search(r'variable "agent_serve_args" \{.*?\n\}\n', variables, re.S).group(0)
        self.assertIn('!strcontains(var.agent_serve_args, "testing.")', block)
        self.assertRegex(block, r"allow\[-_\]\?\(doubles\|demo\)")

    def test_the_start_script_aborts_when_it_reaches_an_env_file(self):
        prepare = read(TF / "modules" / "hackathon_compute" / "templates" / "prepare.sh.tftpl")
        guard = "grep -qE '^AGENTCORE_ALLOW_(DOUBLES|DEMO)=' /run/pulso/env/*.env"
        self.assertIn(guard, prepare)
        self.assertLess(prepare.index("chmod 600 /run/pulso/env/*.env"), prepare.index(guard))
        self.assertIn("exit 1", prepare[prepare.index(guard):prepare.index(guard) + 400])
        # and it runs before any container can start: the guard sits in pulso-stack-prepare, an ExecStartPre of the stack unit
        self.assertIn("ExecStartPre=/usr/local/bin/pulso-stack-prepare", read(TF / "modules" / "hackathon_compute" / "templates" / "user_data.sh.tftpl"))

    @unittest.skipUnless(os.path.exists(r"C:\Program Files\Git\bin\bash.exe") or __import__("shutil").which("bash"), "bash not available")
    def test_the_guard_works_when_run(self):
        prepare = read(TF / "modules" / "hackathon_compute" / "templates" / "prepare.sh.tftpl")
        start = prepare.index("if grep -qE '^AGENTCORE_ALLOW_")
        end = prepare.index("fi\n", start) + 3
        snippet = prepare[start:end]
        bash = r"C:\Program Files\Git\bin\bash.exe" if os.path.exists(r"C:\Program Files\Git\bin\bash.exe") else __import__("shutil").which("bash")
        for content, expected in (("AGENTCORE_ALLOW_DOUBLES=1\n", 1), ("AGENTCORE_ALLOW_DEMO=1\n", 1), ("AGENTCORE_MAX_INFLIGHT=8\n", 0)):
            with self.subTest(content=content.strip()):
                with tempfile.TemporaryDirectory() as d:
                    envdir = Path(d) / "env"
                    envdir.mkdir()
                    (envdir / "agent.env").write_text(content)
                    script = snippet.replace("/run/pulso/env/", str(envdir).replace("\\", "/") + "/")
                    r = subprocess.run([bash, "-c", script], capture_output=True, text=True)
                    self.assertEqual(r.returncode, expected, r.stderr)
                    if expected:
                        self.assertNotIn("=1", r.stderr, "the refusal names the variable, never a value")


class KeyFilesAreRewrittenInPlace(unittest.TestCase):
    PREPARE = read(TF / "modules" / "hackathon_compute" / "templates" / "prepare.sh.tftpl")

    def test_the_files_tree_is_not_deleted_so_serve_sees_a_rotated_key(self):
        self.assertNotRegex(self.PREPARE, r"rm -rf /run/pulso/files")
        self.assertIn("rewritten IN PLACE", self.PREPARE)
        self.assertIn("xargs -r rm -f", self.PREPARE, "files that left the secret are still removed")

    def test_serve_reloads_the_files_without_a_restart(self):
        env = load(CORE / "compose.agents.yaml")["agent-core"]["environment"]
        self.assertEqual(env["AGENTCORE_KEYS_RELOAD_SECONDS"], "5")
        svc = load(CORE / "compose.agents.yaml")["agent-core"]
        self.assertIn("/run/pulso/files/agent:/run/files:ro", svc["volumes"], "a directory mount, so new inodes are not required")


class EngineKeyRotation(unittest.TestCase):
    GEN = read(TF / "modules" / "hackathon_data" / "generated.tf")
    VARS = read(TF / "modules" / "hackathon_data" / "variables.tf")

    def test_the_kid_of_the_engine_key_is_generated_by_terraform_and_published_in_both_documents(self):
        self.assertRegex(self.GEN, r'engine_active_suffix\s*=\s*coalesce\(var\.engine_active_key_suffix, var\.agent_keys_suffix\)')
        self.assertRegex(self.GEN, r'engine_kid\s*=\s*"pulso-engine-\$\{local\.engine_active_suffix\}"')
        self.assertIn("merge({ (local.principal_kid) = local.agent_keys[\"principal\"].public_b64url }, local.engine_published_public)", self.GEN)
        self.assertIn("merge({ (local.staff_kid) = local.agent_keys[\"staff\"].public_b64url }, local.engine_published_public)", self.GEN)
        self.assertIn('"engine/pulso/PULSO_SERVICE_KID" = local.engine_kid', read(TF / "modules" / "hackathon_data" / "ssm.tf"))

    def test_rotation_is_add_then_mint_then_retire_with_three_variables(self):
        for v in ("engine_extra_key_suffixes", "engine_active_key_suffix", "engine_retire_base_key"):
            self.assertIn(f'variable "{v}"', self.VARS)
            self.assertIn(f'variable "{v}"', read(TF / "envs" / "hackathon" / "variables.tf"))
        self.assertIn("terraform_data", self.GEN)
        self.assertIn("precondition", self.GEN)
        doc = read(DOC)
        steps = [doc.index(s) for s in ("1. **Add.**", "2. **Mint with the new kid.**", "3. **Retire.**")]
        self.assertEqual(steps, sorted(steps))

    def test_the_documented_helper_exists(self):
        self.assertIn("scripts/engine_key_rotation.py", read(DOC))
        self.assertTrue((ROOT / "scripts" / "engine_key_rotation.py").exists())


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


class RotationHelper(unittest.TestCase):
    SCRIPT = ROOT / "scripts" / "engine_key_rotation.py"

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="rot"))
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))
        self.k1, self.k2, self.staff = b64url(bytes(range(32))), b64url(bytes(range(32, 64))), b64url(bytes(range(64, 96)))
        self.seed = "ab" * 32

    def docs(self, kids):
        engine = {k: v for k, v in kids.items()}
        identity = {"principal_keys": {"cc-principal-hk1": self.staff, **engine}, "delegation_keys": {"cc-grant-hk1": self.staff}}
        staff = {"principal_keys": {"cc-staff-hk1": self.staff, **engine}}
        return {"FILES__AGENT__IDENTITY_KEYS": json.dumps(identity), "FILES__AGENT__STAFF_KEYS": json.dumps(staff),
                "PULSO__PULSO_SERVICE_SEED_HEX": self.seed, "OTHER__VALUE": "must-not-be-copied"}

    def write(self, name, data):
        p = self.tmp / name
        p.write_text(json.dumps(data))
        return str(p)

    def run_helper(self, *args):
        return subprocess.run([sys.executable, str(self.SCRIPT), *args], capture_output=True, text=True)

    def test_merge_copies_only_the_document_keys_and_prints_no_value(self):
        secret = self.write("secret.json", {"AGENT__AGENTCORE_JEV_API_KEY": "real-jev", "FILES__AGENT__IDENTITY_KEYS": "old", "FILES__AGENT__STAFF_KEYS": "old"})
        gen = self.write("gen.json", self.docs({"pulso-engine-hk1": self.k1, "pulso-engine-hk2": self.k2}))
        out = str(self.tmp / "merged.json")
        r = self.run_helper("merge", "--secret", secret, "--generated", gen, "--out", out)
        self.assertEqual(r.returncode, 0, r.stderr)
        merged = json.loads(Path(out).read_text())
        self.assertEqual(merged["AGENT__AGENTCORE_JEV_API_KEY"], "real-jev", "out-of-band values are kept")
        self.assertNotIn("PULSO__PULSO_SERVICE_SEED_HEX", merged, "the seed moves only with --include-seed (step 2)")
        self.assertNotIn("OTHER__VALUE", merged)
        self.assertIn("pulso-engine-hk2", json.loads(merged["FILES__AGENT__STAFF_KEYS"])["principal_keys"])
        self.assertIn("pulso-engine-hk1, pulso-engine-hk2", r.stdout)
        for secretish in (self.k1, self.k2, self.seed, "real-jev", "must-not-be-copied"):
            self.assertNotIn(secretish, r.stdout + r.stderr)
        if os.name != "nt":
            self.assertEqual(stat.S_IMODE(os.stat(out).st_mode), 0o600)

    def test_include_seed_copies_the_seed(self):
        secret = self.write("secret.json", {})
        gen = self.write("gen.json", self.docs({"pulso-engine-hk2": self.k2}))
        out = str(self.tmp / "m.json")
        r = self.run_helper("merge", "--secret", secret, "--generated", gen, "--out", out, "--include-seed")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(Path(out).read_text())["PULSO__PULSO_SERVICE_SEED_HEX"], self.seed)
        self.assertNotIn(self.seed, r.stdout)

    def test_refuses_bad_inputs_without_echoing_them(self):
        secret = self.write("secret.json", {})
        cases = {
            "short key": self.docs({"pulso-engine-hk1": b64url(b"short")}),
            "no engine kid": self.docs({}),
            "bad seed": {**self.docs({"pulso-engine-hk1": self.k1}), "PULSO__PULSO_SERVICE_SEED_HEX": "nothex"},
            "placeholder": {**self.docs({"pulso-engine-hk1": self.k1}), "FILES__AGENT__STAFF_KEYS": "CHANGE_ME"},
        }
        for label, data in cases.items():
            with self.subTest(label):
                gen = self.write("gen.json", data)
                r = self.run_helper("merge", "--secret", secret, "--generated", gen, "--out", str(self.tmp / "o.json"), "--include-seed")
                self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
                self.assertFalse((self.tmp / "o.json").exists())
                self.assertNotIn(self.seed, r.stdout + r.stderr)

    def test_identity_and_staff_must_publish_the_same_engine_kids(self):
        data = self.docs({"pulso-engine-hk1": self.k1})
        staff = json.loads(data["FILES__AGENT__STAFF_KEYS"])
        staff["principal_keys"]["pulso-engine-hk2"] = self.k2
        data["FILES__AGENT__STAFF_KEYS"] = json.dumps(staff)
        r = self.run_helper("kids", "--generated", self.write("gen.json", data))
        self.assertEqual(r.returncode, 2)

    def test_the_output_may_not_overwrite_an_input(self):
        secret = self.write("secret.json", {})
        gen = self.write("gen.json", self.docs({"pulso-engine-hk1": self.k1}))
        self.assertEqual(self.run_helper("merge", "--secret", secret, "--generated", gen, "--out", secret).returncode, 2)

    def test_accepts_the_wrapped_form_of_terraform_output(self):
        gen = self.write("gen.json", {"value": self.docs({"pulso-engine-hk1": self.k1}), "sensitive": True, "type": "object"})
        r = self.run_helper("kids", "--generated", gen)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("pulso-engine-hk1", r.stdout)


if __name__ == "__main__":
    unittest.main()
