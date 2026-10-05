"""Contract of the OTLP forwarder sidecars (docs/otlp-forwarder.md, decision B1): off by default, loopback-only sidecars in the network
namespace of their producers on each host, Langfuse keys only in the sidecar's own env file, content flags default off."""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "deploy" / "hackathon"
TF = ROOT / "terraform"


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


def load(p: Path) -> dict:
    return yaml.safe_load(read(p))["services"]


CORE = load(BUNDLE / "core" / "compose.observability.yaml")
ENGINE = load(BUNDLE / "engine" / "compose.observability.yaml")
ENGINE_LOOP = load(BUNDLE / "engine" / "compose.loop.observability.yaml")
MAIN = read(TF / "envs" / "hackathon" / "main.tf")
VARS = read(TF / "envs" / "hackathon" / "variables.tf")
LOCAL = "http://127.0.0.1:4318"


class Sidecars(unittest.TestCase):
    SIDECARS = (
        (CORE, "otlp-forwarder-gateway", "llm-gateway"),
        (CORE, "otlp-forwarder-agent", "agent-core"),
        (ENGINE, "otlp-forwarder-engine", "pulso"),
    )

    def test_one_sidecar_per_producer_on_each_host_in_its_network_namespace(self):
        self.assertEqual({n for n in CORE if n.startswith("otlp-")}, {"otlp-forwarder-gateway", "otlp-forwarder-agent"})
        self.assertEqual({n for n in ENGINE if n.startswith("otlp-")}, {"otlp-forwarder-engine"})
        for doc, name, producer in self.SIDECARS:
            with self.subTest(sidecar=name):
                s = doc[name]
                self.assertEqual(s["network_mode"], f"service:{producer}", "the forwarder binds 127.0.0.1 only")
                self.assertNotIn("ports", s, "never published")
                self.assertNotIn("networks", s)
                self.assertEqual(s["image"], "${FORWARDER_IMAGE:?set}")
                self.assertEqual(s["user"], "10001:10001")
                self.assertEqual(s["restart"], "unless-stopped")
                self.assertEqual(s["depends_on"][producer]["condition"], "service_healthy")
                self.assertIn("127.0.0.1:4318/healthz", " ".join(s["healthcheck"]["test"]))
                self.assertRegex(s["mem_limit"], r"^\d+m$")

    def test_langfuse_keys_live_only_in_the_sidecars_env_file(self):
        for doc, name, _ in self.SIDECARS:
            self.assertEqual(doc[name]["env_file"], ["/run/pulso/env/common.env", "/run/pulso/env/langfuse.env"])
        for doc in (CORE, ENGINE, ENGINE_LOOP, load(BUNDLE / "core" / "compose.agents.yaml"), load(BUNDLE / "engine" / "compose.loop.yaml"),
                    load(BUNDLE / "engine" / "compose.yaml"), load(BUNDLE / "core" / "compose.yaml")):
            for name, svc in doc.items():
                if name.startswith("otlp-"):
                    continue
                self.assertNotIn("langfuse.env", " ".join(svc.get("env_file", [])), f"{name} must never see the Langfuse keys")
                env = svc.get("environment", {})
                self.assertFalse(any(k.startswith("LANGFUSE_") or k.endswith("_HEADERS") for k in env), name)

    def test_producers_export_to_the_loopback_sidecar_without_credentials(self):
        gw = CORE["llm-gateway"]["environment"]
        self.assertEqual(gw["OTEL_EXPORTER_OTLP_ENDPOINT"], LOCAL)
        ag = CORE["agent-core"]["environment"]
        self.assertEqual(ag["OTEL_EXPORTER_OTLP_ENDPOINT"], LOCAL)
        self.assertEqual(ag["OTEL_EXPORTER_OTLP_PROTOCOL"], "http/protobuf")
        self.assertEqual(ag["OTEL_TRACES_EXPORTER"], "otlp")
        self.assertEqual(ag["AGENTCORE_TRACE_LANGFUSE"], "1")
        self.assertEqual(ENGINE["pulso"]["environment"]["PULSO_O11Y_FORWARDER_ENDPOINT"], LOCAL)
        self.assertEqual(ENGINE_LOOP["pulso-loop"]["environment"]["PULSO_O11Y_FORWARDER_ENDPOINT"], LOCAL)

    def test_the_loop_job_joins_the_producers_namespace_only_with_both_features(self):
        self.assertEqual(ENGINE_LOOP["pulso-loop"]["network_mode"], "service:pulso")
        self.assertRegex(MAIN, r'local\.loop && local\.otlp \? \["compose\.loop\.observability\.yaml"\]')
        self.assertNotIn("pulso-loop", ENGINE, "the plain observability file must not reference the loop service")


class ContentFlags(unittest.TestCase):
    def test_content_is_off_unless_the_variable_says_so(self):
        for expr in (CORE["llm-gateway"]["environment"]["LLM_GATEWAY_TRACE_CONTENT"], CORE["agent-core"]["environment"]["AGENTCORE_TRACE_CONTENT"],
                     ENGINE["pulso"]["environment"]["PULSO_O11Y_CAPTURE_CONTENT"], ENGINE_LOOP["pulso-loop"]["environment"]["PULSO_O11Y_CAPTURE_CONTENT"]):
            self.assertEqual(expr, "${OTLP_TRACE_CONTENT:-0}")
        block = re.search(r'variable "otlp_trace_content" \{.*?\n\}\n', VARS, re.S).group(0)
        self.assertIn("default     = false", block)
        self.assertRegex(MAIN, r'OTLP_TRACE_CONTENT = var\.otlp_trace_content \? "1" : "0"')

    def test_the_content_flags_are_documented(self):
        doc = read(ROOT / "docs" / "otlp-forwarder.md")
        for name in ("LLM_GATEWAY_TRACE_CONTENT", "AGENTCORE_TRACE_CONTENT", "PULSO_O11Y_CAPTURE_CONTENT", "AGENTCORE_TRACE_LANGFUSE", "otlp_trace_content"):
            self.assertIn(name, doc)


class OffByDefaultBehindOneVariable(unittest.TestCase):
    def test_variable_defaults_to_false_and_needs_the_image(self):
        block = re.search(r'variable "otlp_forwarder_enabled" \{.*?\n\}\n', VARS, re.S).group(0)
        self.assertIn("default     = false", block)
        self.assertIn("images.core.forwarder", VARS)
        self.assertRegex(VARS, r"!var\.otlp_forwarder_enabled \|\| \(contains\(keys\(var\.images\.core\), \"forwarder\"\)")

    def test_observability_files_are_only_wired_when_enabled(self):
        self.assertRegex(MAIN, r'core_otlp\s*=\s*local\.otlp \? \{ "compose\.observability\.yaml"')
        self.assertRegex(MAIN, r'engine_obs\s*=\s*local\.otlp \? \{ "compose\.observability\.yaml"')
        self.assertIn('local.otlp ? ["compose.observability.yaml"] : []', MAIN)
        self.assertIn('local.otlp ? ["langfuse"] : []', MAIN)

    def test_langfuse_keys_are_secret_names_only_and_the_base_url_is_ssm(self):
        secrets = read(TF / "modules" / "hackathon_data" / "secrets.tf")
        self.assertRegex(secrets, r'langfuse_keys\s*=\s*var\.otlp_forwarder_enabled \? \["LANGFUSE__LANGFUSE_PUBLIC_KEY", "LANGFUSE__LANGFUSE_SECRET_KEY"\] : \[\]')
        self.assertNotIn("LANGFUSE__LANGFUSE_BASE_URL", secrets)
        ssm = read(TF / "modules" / "hackathon_data" / "ssm.tf")
        self.assertIn('"core/langfuse/LANGFUSE_BASE_URL"', ssm)
        self.assertIn('"engine/langfuse/LANGFUSE_BASE_URL"', ssm)
        self.assertIn("var.otlp_forwarder_enabled", ssm)
        for p in list(BUNDLE.rglob("*")) + list((TF / "envs" / "hackathon").glob("*.tf")):
            if p.is_file():
                self.assertNotRegex(read(p), r"pk-lf-|sk-lf-|LANGFUSE_SECRET_KEY\s*[:=]\s*[\"']?[A-Za-z0-9]", p.name)

    def test_the_service_env_name_reaches_the_secret_renderer(self):
        self.assertIn("langfuse", MAIN)
        prepare = read(TF / "modules" / "hackathon_compute" / "templates" / "prepare.sh.tftpl")
        self.assertIn("svc_regex", prepare, "the renderer builds its secret filter from the host's service env names")

    def test_forwarder_image_has_a_repository_a_deployer_key_and_a_service_entry(self):
        self.assertIn('"otlp-forwarder"', read(TF / "bootstrap" / "variables.tf"))
        self.assertIn('local.otlp ? ["forwarder"] : []', MAIN)
        self.assertIn("otlp_build_services", MAIN)
        self.assertIn("'otlp-forwarder'", read(ROOT / "scripts" / "aws-prod.ps1"))
        self.assertIn("LANGFUSE", read(ROOT / "scripts" / "aws-prod.ps1"), "set-secret accepts the LANGFUSE service prefix")


if __name__ == "__main__":
    unittest.main()
