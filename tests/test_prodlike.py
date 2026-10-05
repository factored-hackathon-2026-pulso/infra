"""Offline tests of the local prod-like rehearsal (scripts/prodlike, docs/prodlike-rehearsal.md).

They render the REAL deploy/hackathon bundles and check the promise of the rehearsal: same healthchecks, same depends_on,
same env file names and image variables as the hosts; only paths, ports, secrets and missing images differ. No Podman needed.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("prodlike", ROOT / "scripts" / "prodlike" / "prodlike.py")
pl = importlib.util.module_from_spec(SPEC)
sys.modules["prodlike"] = pl  # dataclasses resolves the module by name
SPEC.loader.exec_module(pl)  # type: ignore[union-attr]

CONTRACT = json.loads((ROOT / "scripts" / "prodlike" / "env_contract.json").read_text(encoding="utf-8"))
TF_TEXT = "\n".join(p.read_text(encoding="utf-8") for p in (ROOT / "terraform").rglob("*.tf"))
AVAILABLE = {"GATEWAY_IMAGE", "TOOLS_IMAGE", "PULSO_IMAGE", "PROXY_IMAGE", "POSTGRES_IMAGE"}


def declared(key: str) -> bool:
    return (key in TF_TEXT or key.split("__")[-1] in TF_TEXT
            or f'"{key.removeprefix("DB_PASSWORD_")}"' in TF_TEXT)


class EnvContract(unittest.TestCase):
    def test_every_infra_key_in_the_contract_exists_in_terraform(self):
        for fname, entries in CONTRACT["files"].items():
            for e in entries:
                with self.subTest(file=fname, name=e["name"]):
                    self.assertTrue(declared(e["infra"]), f"{e['infra']} is not declared in terraform/")

    def test_consumers_are_the_terraform_defaults(self):
        data = (ROOT / "terraform" / "modules" / "hackathon_data" / "variables.tf").read_text(encoding="utf-8")
        listed = re.search(r'variable "gateway_consumers".*?default\s*=\s*\[(.*?)\]', data, re.S).group(1)
        self.assertEqual(CONTRACT["consumers"], re.findall(r'"([A-Z_]+)"', listed))

    def test_the_engine_names_are_the_ones_pulso_run_reads(self):
        names = {e["name"] for e in CONTRACT["files"]["pulso"]}
        for needed in ("PULSO_DATABASE_URL", "PULSO_ADMIN_TOKEN", "PULSO_DEBUG_TOKEN", "PULSO_DATA_MODE", "PULSO_LLM_GATEWAY",
                       "PULSO_LLM_GATEWAY_ADDR", "PULSO_LLM_GATEWAY_KEY", "PULSO_CORE_ADDR", "PULSO_SERVICE_SEED_HEX", "PULSO_BASE_PATH"):
            self.assertIn(needed, names)


class SecretsRendering(unittest.TestCase):
    def setUp(self):
        self.env = pl.build_env_files(CONTRACT, "infb", {"OPENROUTER_API_KEY": "sk-or-test-value"})

    def test_engine_tokens_meet_the_refusal_rule_and_differ(self):
        a, d = self.env["pulso"]["PULSO_ADMIN_TOKEN"], self.env["pulso"]["PULSO_DEBUG_TOKEN"]
        self.assertGreaterEqual(len(a), 24)
        self.assertGreaterEqual(len(d), 24)
        self.assertNotEqual(a, d)

    def test_same_value_where_two_services_must_agree(self):
        self.assertEqual(self.env["pulso"]["PULSO_LLM_GATEWAY_KEY"], self.env["gateway"]["GATEWAY_TOKEN_ENGINE"])
        self.assertTrue(self.env["tools"]["TOOL_SERVICE_TOKENS"].startswith("agent-core:"))
        self.assertEqual(len(self.env["pulso"]["PULSO_SERVICE_SEED_HEX"]), 64)

    def test_gateway_config_is_the_shape_ssm_derives(self):
        consumers = json.loads(self.env["gateway"]["GATEWAY_CONSUMERS"])
        self.assertEqual(set(consumers), {"agent-core", "agent-serve", "engine", "support-platform"})
        self.assertEqual(consumers["engine"], {"token_env": "GATEWAY_TOKEN_ENGINE"})
        self.assertEqual(json.loads(self.env["gateway"]["LLM_ENDPOINTS"])["openrouter"]["api_key_env"], "OPENROUTER_API_KEY")

    def test_engine_reaches_the_gateway_by_ip_literal_like_production(self):
        addr = self.env["pulso"]["PULSO_LLM_GATEWAY_ADDR"]
        self.assertRegex(addr, r"^172\.29\.\d+\.10:8080$")
        self.assertRegex(self.env["pulso"]["PULSO_CORE_ADDR"], r"^172\.29\.\d+\.11:8001$")

    def test_external_values_are_copied_only_for_wanted_names(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "gw.env"
            f.write_text("OPENROUTER_API_KEY=abc\nUNRELATED=zzz\n", encoding="utf-8")
            got = pl.read_external(f, {"OPENROUTER_API_KEY"})
        self.assertEqual(got, {"OPENROUTER_API_KEY": "abc"})


class RenderedCompose(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.core_src = pl.load_merged(pl.CORE_FILES)
        cls.core, cls.core_dev = pl.render_compose(cls.core_src, AVAILABLE, "infb", "core")
        cls.engine_src = pl.load_merged(pl.ENGINE_FILES)
        cls.engine, cls.engine_dev = pl.render_compose(cls.engine_src, AVAILABLE, "infb", "engine")

    def test_services_without_an_image_are_dropped_and_reported_as_slots(self):
        self.assertEqual(set(self.core["services"]), {"postgres", "pulso-db-bootstrap", "llm-gateway", "tool-service"})
        text = "\n".join(self.core_dev)
        for slot in ("agent-core", "core-runtime", "core-migrate"):
            self.assertIn(f"service {slot} dropped", text)
        self.assertEqual(set(self.engine["services"]), {"pulso", "proxy"})

    def test_healthchecks_restart_and_limits_are_the_hosts(self):
        for rendered, source in ((self.core, self.core_src), (self.engine, self.engine_src)):
            for name, svc in rendered["services"].items():
                with self.subTest(service=name):
                    src = source["services"][name]
                    self.assertEqual(svc.get("healthcheck"), src.get("healthcheck"))
                    self.assertEqual(svc.get("restart"), src.get("restart"))
                    self.assertEqual(svc.get("mem_limit"), src.get("mem_limit"))
                    self.assertEqual(svc.get("user"), src.get("user"))
                    self.assertEqual(svc.get("command"), src.get("command"))
                    self.assertEqual(svc.get("image"), src.get("image"), "image variables stay variables")

    def test_remaining_depends_on_conditions_are_unchanged(self):
        self.assertEqual(self.engine["services"]["proxy"]["depends_on"], {"pulso": {"condition": "service_healthy"}})
        self.assertNotIn("depends_on", self.core["services"]["postgres"])

    def test_env_file_names_are_the_hosts_under_a_local_directory(self):
        self.assertEqual(self.engine["services"]["pulso"]["env_file"], ["./env/common.env", "./env/pulso.env"])
        self.assertEqual(self.core["services"]["llm-gateway"]["env_file"], ["./env/common.env", "./env/gateway.env"])

    def test_no_absolute_host_path_survives_and_data_is_on_named_volumes(self):
        text = yaml.safe_dump(self.core) + yaml.safe_dump(self.engine)
        self.assertNotRegex(text, r"(?m)^\s*-\s+/(srv|run)/")
        self.assertIn("srv_data_pulso:/var/lib/pulso", self.engine["services"]["pulso"]["volumes"])
        self.assertIn("srv_pgdata:/var/lib/postgresql/data", self.core["services"]["postgres"]["volumes"])

    def test_ports_are_loopback_only_and_distinct(self):
        ports = [p for r in (self.core, self.engine) for s in r["services"].values() for p in s.get("ports", [])]
        self.assertTrue(all(p.startswith("127.0.0.1:") for p in ports))
        self.assertEqual(len(ports), len(set(ports)))
        self.assertIn("127.0.0.1:18081:8080", self.core["services"]["llm-gateway"]["ports"])
        self.assertIn("127.0.0.1:18080:8080", self.engine["services"]["proxy"]["ports"])

    def test_gateway_has_a_fixed_ip_on_the_shared_network(self):
        sub = pl.subnet_for("infb")
        self.assertEqual(self.core["services"]["llm-gateway"]["networks"]["internal"]["ipv4_address"], f"{sub}.10")
        for r in (self.core, self.engine):
            self.assertEqual(r["networks"]["internal"], {"external": True, "name": "infb-net"})

    def test_strip_limits_removes_only_mem_limit_and_says_so(self):
        doc, dev = pl.render_compose(self.core_src, AVAILABLE, "infb", "core", strip_limits=True)
        for svc in doc["services"].values():
            self.assertNotIn("mem_limit", svc)
            self.assertEqual(svc["pids_limit"], 0)
        self.assertEqual(doc["services"]["llm-gateway"]["healthcheck"], self.core_src["services"]["llm-gateway"]["healthcheck"])
        self.assertTrue(any("mem_limit removed" in d for d in dev))

    def test_prefix_isolates_project_and_subnet(self):
        self.assertEqual(self.core["name"], "infb-core")
        self.assertNotEqual(pl.subnet_for("infb"), pl.subnet_for("other-lane"))

    def test_with_the_agent_image_the_serve_service_is_kept_with_its_real_dependencies(self):
        doc, _ = pl.render_compose(pl.load_merged(pl.CORE_FILES), AVAILABLE | {"AGENT_IMAGE", "CORE_IMAGE"}, "infb", "core")
        agent = doc["services"]["agent-core"]
        self.assertEqual(agent["depends_on"]["tool-service"]["condition"], "service_healthy")
        self.assertEqual(agent["depends_on"]["llm-gateway"]["condition"], "service_healthy")
        self.assertEqual(agent["healthcheck"], self.core_src["services"]["agent-core"]["healthcheck"])


class AppUserDirectories(unittest.TestCase):
    def test_volumes_that_prepare_gives_to_uid_10001_are_found(self):
        core, _ = pl.render_compose(pl.load_merged(pl.CORE_FILES), AVAILABLE, "infb", "core")
        engine, _ = pl.render_compose(pl.load_merged(pl.ENGINE_FILES), AVAILABLE, "infb", "engine")
        text = pl.PREPARE.read_text(encoding="utf-8")
        self.assertIn("srv_data_tools_state", pl.app_user_volumes(core, text))
        self.assertIn("srv_data_pulso", pl.app_user_volumes(engine, text))
        self.assertNotIn("srv_pgdata", pl.app_user_volumes(core, text), "postgres owns its own volume")
        self.assertEqual(pl.app_user_volumes(engine, "echo nothing"), [], "without the chown line nothing is prepared")


class RenderAllWritesNoSecretToStdout(unittest.TestCase):
    def test_render_all_creates_the_tree(self):
        with tempfile.TemporaryDirectory() as d:
            work = Path(d)
            (work / "images.json").write_text(json.dumps({"GATEWAY_IMAGE": "localhost/infb-gateway:local", "TOOLS_IMAGE": "localhost/infb-tools:local",
                                                          "PULSO_IMAGE": "localhost/infb-engine:local"}), encoding="utf-8")
            buf = io.StringIO()
            with redirect_stdout(buf):
                report = pl.render_all("infb", work=work)
            self.assertEqual(buf.getvalue(), "")
            self.assertTrue((work / "core" / "env" / "gateway.env").exists())
            self.assertFalse((work / "core" / "env" / "pulso.env").exists(), "each host gets only its slice")
            self.assertTrue((work / "engine" / "env" / "pulso.env").exists())
            self.assertTrue((work / "core" / "initdb" / "sql" / "00_databases_roles.sql").exists())
            self.assertTrue((work / "engine" / "Caddyfile").exists())
            dotenv = (work / "core" / ".env").read_text(encoding="utf-8")
            self.assertIn("GATEWAY_IMAGE=localhost/infb-gateway:local", dotenv)
            self.assertIn("PROXY_IMAGE=docker.io/library/caddy:2", dotenv)
            tokens = (work / "engine" / "env" / "pulso.env").read_text(encoding="utf-8")
            admin = re.search(r"PULSO_ADMIN_TOKEN=(\S+)", tokens).group(1)
            for f in ("core/compose.yaml", "engine/compose.yaml", "core/.env", "engine/.env", "state.json"):
                self.assertNotIn(admin, (work / f).read_text(encoding="utf-8"))
            self.assertTrue(any("agent-core serve" in s for s in report["slots"]))
            self.assertTrue(any("platform backend" in s for s in report["slots"]))


class HealthRule(unittest.TestCase):
    """The same verdicts as deploy-stack.sh wait_healthy."""

    def j(self, *states):
        return pl.judge_containers([dict(name=f"c{i}", exit_code=0, **s) for i, s in enumerate(states)])[0]

    def test_verdicts(self):
        self.assertEqual(self.j(dict(status="running", health="healthy"), dict(status="exited", health="none")), "ok")
        self.assertEqual(self.j(dict(status="running", health="starting")), "pending")
        self.assertEqual(self.j(dict(status="created", health="none")), "pending")
        self.assertEqual(self.j(dict(status="running", health="unhealthy")), "bad")
        self.assertEqual(self.j(dict(status="restarting", health="none")), "bad")
        self.assertEqual(pl.judge_containers([dict(name="m", status="exited", health="none", exit_code=1)])[0], "bad")
        self.assertEqual(pl.judge_containers([])[0], "pending")


class SlotsAreVisible(unittest.TestCase):
    def test_every_loop_step_of_the_plan_is_listed_and_every_slot_names_its_brief(self):
        self.assertEqual([s for s, _ in pl.LOOP_STEPS], ["detect", "propose", "prove", "announce", "approve", "publish", "release", "outcome"])
        for name, (_var, brief) in pl.SLOTS.items():
            self.assertTrue(brief, name)

    def test_build_refuses_without_ram_headroom(self):
        class Args:
            name, src, prefix, force = "engine", ".", "infb", False

        orig = pl.free_ram_mb
        pl.free_ram_mb = lambda: 100
        try:
            buf = io.StringIO()
            with contextlib.redirect_stderr(buf):
                self.assertEqual(pl.cmd_build(Args), 3)
            self.assertIn("refusing to build engine", buf.getvalue())
        finally:
            pl.free_ram_mb = orig


if __name__ == "__main__":
    unittest.main()
