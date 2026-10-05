"""Offline contract tests of the prod-like rehearsal with agent-core `serve` in the stack (no Podman, no network, no agent-core checkout).

They pin what the rehearsal learned from the live run (docs/reports-claude/PRODLIKE_SERVE_RESULTS_2026-10-05.md): the env contract of the
agent services against Terraform, the rendered serve service, the `podman run` fallback for machines without a pids cgroup controller,
the pure-Python Ed25519 used for the staff-keys and the builder credential, and the deterministic local secrets.
"""

from __future__ import annotations

import base64
import importlib.util
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


pl = load("prodlike", ROOT / "scripts" / "prodlike" / "prodlike.py")
ed = sys.modules["ed25519"]
CONTRACT = json.loads((ROOT / "scripts" / "prodlike" / "env_contract.json").read_text(encoding="utf-8"))
TF_TEXT = "\n".join(p.read_text(encoding="utf-8") for p in (ROOT / "terraform").rglob("*.tf"))
AVAILABLE = {"GATEWAY_IMAGE", "TOOLS_IMAGE", "PULSO_IMAGE", "PROXY_IMAGE", "POSTGRES_IMAGE", "AGENT_IMAGE", "STUB_IMAGE"}


def b64u_decode(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


class Ed25519Rfc8032(unittest.TestCase):
    """RFC 8032 section 7.1 vectors: the public key listed in staff-keys is the one the engine derives from its seed."""

    VECTORS = [
        ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", "",
         "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
         "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
        ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb", "72",
         "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
         "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
    ]

    def test_public_key_and_signature_match_the_vectors(self):
        for seed, msg, pub, sig in self.VECTORS:
            with self.subTest(seed=seed[:8]):
                s = bytes.fromhex(seed)
                self.assertEqual(ed.public_key(s).hex(), pub)
                self.assertEqual(ed.sign(s, bytes.fromhex(msg)).hex(), sig)

    def test_a_seed_must_be_32_bytes(self):
        with self.assertRaises(ValueError):
            ed.public_key(b"short")


class BuilderCredential(unittest.TestCase):
    SEED = "00" * 31 + "07"

    def test_shape_is_the_one_serve_documents(self):
        head, body, sig = pl.mint_builder_credential(self.SEED, "kid-1", now=1_800_000_000).split(".")
        self.assertEqual(json.loads(b64u_decode(head)), {"alg": "EdDSA", "kid": "kid-1", "typ": "principal+jws"})
        who = json.loads(b64u_decode(body))
        self.assertEqual((who["type"], who["id"], who["roles"], who["scopes"], who["attrs"]), ("builder", "pulso-engine", ["constructor"], [], {}))
        self.assertEqual(who["auth"]["level"], "session")
        self.assertNotIn("actor", who["attrs"], "never a human")
        self.assertEqual(len(b64u_decode(sig)), 64)

    def test_signature_verifies_with_the_public_key_the_staff_file_lists(self):
        staff = pl.staff_keys_with_engine({"principal_keys": {"test-staff-1": "x"}}, self.SEED, "kid-1")
        self.assertEqual(set(staff["principal_keys"]), {"test-staff-1", "kid-1"}, "the existing staff key is kept")
        self.assertEqual(b64u_decode(staff["principal_keys"]["kid-1"]), ed.public_key(bytes.fromhex(self.SEED)))
        self.assertEqual(len(b64u_decode(staff["principal_keys"]["kid-1"])), 32)

    def test_ttl_and_roles_are_parameters_the_smoke_uses_for_the_exporter(self):
        body = json.loads(b64u_decode(pl.mint_builder_credential(self.SEED, roles=("exporter",), ttl_s=60, now=1_800_000_000).split(".")[1]))
        self.assertEqual(body["roles"], ["exporter"])


class AgentEnvContract(unittest.TestCase):
    def test_every_agent_name_is_declared_in_terraform_and_in_serve_env(self):
        names = {e["name"] for e in CONTRACT["files"]["agent"]}
        self.assertEqual(names, {"AGENTCORE_REGISTRY_DSN", "AGENTCORE_EVAL_DSN", "AGENTCORE_MIGRATE_DSN", "AGENTCORE_MIGRATE_EVAL_DSN",
                                 "AGENTCORE_LLM_GATEWAY_TOKEN", "AGENTCORE_JEV_API_KEY", "AGENTCORE_KEYS_FINGERPRINT", "AGENTCORE_KEYS_TOKEN_MAP",
                                 "AGENTCORE_TOOL_SERVICE_TOKEN", "AGENTCORE_GRANTS_TOKEN"})
        secrets_tf = (ROOT / "terraform" / "modules" / "hackathon_data" / "secrets.tf").read_text(encoding="utf-8")
        for e in CONTRACT["files"]["agent"]:
            with self.subTest(name=e["name"]):
                self.assertIn(e["name"], secrets_tf + TF_TEXT, "Terraform seeds AGENT__<name> from this list")
                self.assertTrue(e["infra"].startswith("AGENT__"))

    def test_the_five_agent_files_are_the_secret_keys_terraform_declares(self):
        secrets_tf = (ROOT / "terraform" / "modules" / "hackathon_data" / "secrets.tf").read_text(encoding="utf-8")
        self.assertIn('"FILES__AGENT__${f}"', secrets_tf)
        listed = re.search(r'for f in \[(.*?)\] : "FILES__AGENT__', secrets_tf, re.S).group(1)
        self.assertEqual(re.findall(r'"(\w+)"', listed), CONTRACT["agent_files"]["names"])

    def test_agent_serve_args_are_real_pieces_only(self):
        args = pl.terraform_default("agent_serve_args")
        self.assertNotIn("testing.", args)
        for flag in ("--tools", "--authz", "--field-classifier", "--grant-active", "--transcript", "--calibration", "--classifier"):
            self.assertIn(flag, args)


class RenderedSecrets(unittest.TestCase):
    def setUp(self):
        self.env = pl.build_env_files(CONTRACT, "prodlike", {"AGENTCORE_JEV_API_KEY": "jev-test"}, seed=b"s" * 32)

    def test_agent_env_agrees_with_the_services_it_talks_to(self):
        a = self.env["agent"]
        self.assertEqual(a["AGENTCORE_LLM_GATEWAY_TOKEN"], self.env["gateway"]["GATEWAY_TOKEN_AGENT_SERVE"])
        self.assertEqual(self.env["tools"]["TOOL_SERVICE_TOKENS"], "agent-core:" + a["AGENTCORE_TOOL_SERVICE_TOKEN"])
        self.assertEqual(a["AGENTCORE_JEV_API_KEY"], "jev-test")
        for name in ("AGENTCORE_KEYS_FINGERPRINT", "AGENTCORE_KEYS_TOKEN_MAP"):
            kid, _, b64 = a[name].partition(":")
            self.assertEqual(kid, "k1")
            self.assertGreaterEqual(len(base64.b64decode(b64)), 32, "serve needs at least 32 bytes per key")

    def test_dsns_use_the_split_roles_of_the_shared_postgres(self):
        a, db = self.env["agent"], self.env["db"]
        self.assertTrue(a["AGENTCORE_REGISTRY_DSN"].startswith(f"postgresql://agent_app:{db['DB_PASSWORD_AGENT_APP']}@postgres:5432/agent_runtime"))
        self.assertTrue(a["AGENTCORE_EVAL_DSN"].endswith("/agent_eval"))
        self.assertTrue(a["AGENTCORE_MIGRATE_DSN"].startswith(f"postgresql://agent_owner:{db['DB_PASSWORD_AGENT_OWNER']}@"))
        self.assertNotEqual(a["AGENTCORE_REGISTRY_DSN"], a["AGENTCORE_EVAL_DSN"], "serve refuses the same database for both")

    def test_secrets_are_stable_for_a_seed_and_different_without_one(self):
        again = pl.build_env_files(CONTRACT, "prodlike", {}, seed=b"s" * 32)
        self.assertEqual(self.env["db"], again["db"], "a re-render must not change the passwords of an initialised Postgres volume")
        self.assertEqual(self.env["pulso"]["PULSO_SERVICE_SEED_HEX"], again["pulso"]["PULSO_SERVICE_SEED_HEX"])
        other = pl.build_env_files(CONTRACT, "prodlike", {}, seed=b"t" * 32)
        self.assertNotEqual(self.env["db"]["POSTGRES_PASSWORD"], other["db"]["POSTGRES_PASSWORD"])
        random_a = pl.build_env_files(CONTRACT, "prodlike", {})
        random_b = pl.build_env_files(CONTRACT, "prodlike", {})
        self.assertNotEqual(random_a["db"]["POSTGRES_PASSWORD"], random_b["db"]["POSTGRES_PASSWORD"])


class RenderedServe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.src = pl.load_merged(pl.CORE_FILES)
        cls.doc, cls.dev = pl.render_compose(cls.src, AVAILABLE, "prodlike", "core")

    def test_agent_core_is_kept_with_the_host_definition_and_a_grace_period_above_serves_own(self):
        svc, host = self.doc["services"]["agent-core"], self.src["services"]["agent-core"]
        self.assertEqual(svc["command"], host["command"])
        self.assertEqual(svc["healthcheck"], host["healthcheck"])
        self.assertEqual(svc["user"], "10001:10001")
        grace = int(re.sub(r"\D", "", svc["stop_grace_period"]))
        self.assertGreater(grace, 25, "AGENTCORE_SHUTDOWN_GRACE_SECONDS defaults to 25 (docs/serve-env.md): the orchestrator must wait longer")

    def test_the_platform_is_a_reported_double_with_the_dns_name_serve_uses(self):
        stub = self.doc["services"]["platform"]
        self.assertEqual(stub["networks"]["internal"]["aliases"], ["platform.pulso.internal"])
        self.assertTrue(any("DOUBLE" in d and "platform" in d for d in self.dev))
        self.assertEqual(self.src["services"]["agent-core"]["environment"]["AGENTCORE_GRANTS_URL"], "http://platform.${PRIVATE_ZONE_NAME:?set}:8000")

    def test_local_directories_replace_the_host_paths_serve_reads(self):
        vols = self.doc["services"]["agent-core"]["volumes"]
        self.assertIn("./files/agent:/run/files:ro", vols)
        self.assertIn("./files/catalog:/catalog:ro", vols)
        self.assertIn("./files/artifacts:/artifacts:ro", vols)
        self.assertIn("./files/tools-data:/data:ro", self.doc["services"]["tool-service"]["volumes"])

    def test_the_fixed_addresses_the_engine_uses_belong_to_the_gateway_and_agent_core(self):
        sub = pl.subnet_for("prodlike")
        self.assertEqual(self.doc["services"]["agent-core"]["networks"]["internal"]["ipv4_address"], f"{sub}.11")
        self.assertEqual(self.doc["services"]["tool-service"]["networks"]["internal"]["ipv4_address"], f"{sub}.12")

    def test_ports_are_per_prefix_and_the_legacy_prefix_keeps_its_ports(self):
        self.assertEqual(pl.port_map("infb")[("llm-gateway", 8080)], 18081)
        mine, other = pl.port_map("prodlike"), pl.port_map("another-lane")
        self.assertEqual(len(set(mine.values())), 4)
        self.assertTrue(set(mine.values()).isdisjoint(other.values()) or mine != other)
        self.assertIn(f"127.0.0.1:{mine[('agent-core', 8001)]}:8001", self.doc["services"]["agent-core"]["ports"])


class PodmanRunFallback(unittest.TestCase):
    ENV = {"AGENT_IMAGE": "localhost/p-agent:local", "AGENT_SERVE_ARGS": "--tools a:b --authz c:d", "PRIVATE_ZONE_NAME": "pulso.internal"}

    def test_compose_interpolation_including_the_dollar_escape_of_the_migrate_entrypoint(self):
        self.assertEqual(pl.interpolate("${AGENT_IMAGE:?set}", self.ENV), "localhost/p-agent:local")
        self.assertEqual(pl.interpolate("${X:-fallback}", {}), "fallback")
        self.assertEqual(pl.interpolate('A="$$B" exec cmd', {}), 'A="$B" exec cmd')
        with self.assertRaises(pl.RehearsalError):
            pl.interpolate("${MISSING:?need it}", {})

    def test_serve_command_is_interpolated_before_it_is_split(self):
        doc, _ = pl.render_compose(pl.load_merged(pl.CORE_FILES), AVAILABLE, "prodlike", "core")
        args = pl.podman_run_args("prodlike", "core", "agent-core", doc["services"]["agent-core"], doc, self.ENV)
        i = args.index("localhost/p-agent:local")
        self.assertEqual(args[i + 1:i + 4], ["serve", "--host", "0.0.0.0"])
        self.assertIn("--tools", args[i:])
        self.assertIn("--pids-limit=0", args, "the whole point of the fallback")
        self.assertEqual(args[args.index("--stop-timeout") + 1], "30")
        self.assertEqual(args[args.index("--user") + 1], "10001:10001")
        self.assertIn("com.docker.compose.service=agent-core", args, "container_states and health_of find it by compose labels")

    def test_healthchecks_travel_as_json_arrays_so_arguments_with_spaces_survive(self):
        doc, _ = pl.render_compose(pl.load_merged(pl.CORE_FILES), AVAILABLE, "prodlike", "core")
        args = pl.podman_run_args("prodlike", "core", "agent-core", doc["services"]["agent-core"], doc, self.ENV)
        test = json.loads(args[args.index("--health-cmd") + 1])
        self.assertEqual(test[:3], ["CMD", "python", "-c"])
        self.assertIn("urlopen", test[3])
        pg = pl.podman_run_args("prodlike", "core", "postgres", doc["services"]["postgres"], doc, {"POSTGRES_IMAGE": "pg"}, "172.29.1.50")
        self.assertEqual(json.loads(pg[pg.index("--health-cmd") + 1])[0], "CMD-SHELL")

    def test_services_without_a_fixed_address_get_one_that_cannot_steal_the_fixed_ones(self):
        doc, _ = pl.render_compose(pl.load_merged(pl.CORE_FILES), AVAILABLE, "prodlike", "core")
        pg = pl.podman_run_args("prodlike", "core", "postgres", doc["services"]["postgres"], doc, {"POSTGRES_IMAGE": "pg"}, "172.29.1.50")
        self.assertEqual(pg[pg.index("--ip") + 1], "172.29.1.50")
        gw = pl.podman_run_args("prodlike", "core", "llm-gateway", doc["services"]["llm-gateway"], doc, {"GATEWAY_IMAGE": "gw"}, "172.29.1.51")
        self.assertEqual(gw[gw.index("--ip") + 1], f"{pl.subnet_for('prodlike')}.10", "a fixed address wins over the automatic one")


class RenderAllWithServe(unittest.TestCase):
    def test_agent_files_env_and_serve_args_are_written_without_printing_a_secret(self):
        with tempfile.TemporaryDirectory() as d:
            work = Path(d)
            (work / "images.json").write_text(json.dumps({"GATEWAY_IMAGE": "g", "TOOLS_IMAGE": "t", "PULSO_IMAGE": "e", "AGENT_IMAGE": "a"}), encoding="utf-8")
            state = work / "state"
            for sub in ("calibration", "classifier", "publication/publish/run-1"):
                (state / sub).mkdir(parents=True)
            (state / "identity-keys.json").write_text('{"principal_keys":{"k":"AAAA"}}', encoding="utf-8")
            (state / "staff-keys.json").write_text('{"principal_keys":{"test-staff-1":"AAAA"}}', encoding="utf-8")
            (state / "field-grants.json").write_text("[]", encoding="utf-8")
            (state / "field-overlay.json").write_text("{}", encoding="utf-8")
            (state / "publication" / "publish" / "latest.json").write_text('{"run_id":"run-1","path":"publish/run-1"}', encoding="utf-8")
            (state / "publication" / "publish" / "run-1" / "field_classification.json").write_text("{}", encoding="utf-8")
            report = pl.render_all("prodlike", work=work, state=state)
            core = work / "core"
            staff = json.loads((core / "files" / "agent" / "STAFF_KEYS").read_text(encoding="utf-8"))
            self.assertEqual(set(staff["principal_keys"]), {"test-staff-1", pl.ENGINE_KID}, "the engine key sits next to the staff key")
            seed = re.search(r"PULSO_SERVICE_SEED_HEX=(\S+)", (work / "engine" / "env" / "pulso.env").read_text(encoding="utf-8")).group(1)
            self.assertEqual(b64u_decode(staff["principal_keys"][pl.ENGINE_KID]), ed.public_key(bytes.fromhex(seed)))
            self.assertTrue((core / "env" / "agent.env").exists())
            self.assertTrue((core / "env" / "platform-stub.env").exists())
            self.assertTrue((core / "files" / "catalog" / "field_classification.json").exists())
            self.assertIn("agent-core", report["hosts"]["core"])
            self.assertIn("platform", report["hosts"]["core"])
            dotenv = (core / ".env").read_text(encoding="utf-8")
            self.assertIn("AGENT_SERVE_ARGS=--tools ", dotenv)
            compose_text = (core / "compose.yaml").read_text(encoding="utf-8")
            for secret in re.findall(r"=(\S{20,})", (core / "env" / "agent.env").read_text(encoding="utf-8")):
                self.assertNotIn(secret, compose_text + dotenv)

    def test_without_state_the_key_files_are_empty_so_serve_cannot_start_with_invented_keys(self):
        with tempfile.TemporaryDirectory() as d:
            work = Path(d)
            (work / "images.json").write_text(json.dumps({"GATEWAY_IMAGE": "g", "TOOLS_IMAGE": "t", "AGENT_IMAGE": "a"}), encoding="utf-8")
            report = pl.render_all("prodlike", work=work)
            self.assertEqual((work / "core" / "files" / "agent" / "IDENTITY_KEYS").read_text(encoding="utf-8"), "{}")
            self.assertTrue(any("no agent state" in x for x in report["deviations"]))
            self.assertEqual(report["hosts"]["engine"], [], "no engine image: the proxy alone is not started")


class SmokeKnowsTheEngineEdgeIsOptional(unittest.TestCase):
    def test_loop_steps_point_to_the_loop_command_or_name_the_platform_slot(self):
        steps = dict(pl.LOOP_STEPS)
        for early in ("detect", "propose", "prove"):
            self.assertIn("prodlike.py loop", steps[early])
        for human in ("approve", "publish"):
            self.assertIn("slot", steps[human])


if __name__ == "__main__":
    unittest.main()
