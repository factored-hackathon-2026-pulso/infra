"""Secrets wiring contract (docs/secrets-wiring.md): only external provider keys are human; every other required name of each
service contract is sourced by the repository; no secret value in any config file, bundle file or fixture. Names only."""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = json.loads((ROOT / "scripts" / "secrets_contract.json").read_text(encoding="utf-8"))
HUMAN = {"GATEWAY__OPENROUTER_API_KEY", "GATEWAY__JEV_API_KEY", "AGENT__AGENTCORE_JEV_API_KEY",
         "LANGFUSE__LANGFUSE_PUBLIC_KEY", "LANGFUSE__LANGFUSE_SECRET_KEY"}
DATA = ROOT / "terraform" / "modules" / "hackathon_data"
CONFIG = ROOT / "deploy" / "hackathon" / "config"
PROHIBITED = ("AGENTCORE_ALLOW_DOUBLES", "AGENTCORE_ALLOW_DEMO", "PULSO_REGISTRY_TOKEN")


def read(p):
    return Path(p).read_text(encoding="utf-8")


def tf_text():
    return "\n".join(read(p) for p in sorted(DATA.glob("*.tf")))


def env_tf_text():
    return read(ROOT / "terraform" / "envs" / "hackathon" / "main.tf") + read(DATA / "ssm.tf")


class Contract(unittest.TestCase):
    def test_human_keys_are_exactly_the_provider_keys(self):
        self.assertEqual(set(CONTRACT["humanKeys"]), HUMAN)
        self.assertLessEqual({e["ref"] for e in CONTRACT["entries"] if e["source"] == "human"}, HUMAN)

    def test_every_required_name_has_a_source(self):
        tf, envtf = tf_text(), env_tf_text()
        for e in CONTRACT["entries"]:
            ref, src = e["ref"], e["source"]
            with self.subTest(service=e["service"], name=e["name"]):
                if src in ("secret", "human"):
                    var = ref.split("__", 1)[1] if "__" in ref else ref
                    self.assertTrue(f'"{ref}"' in tf or f'"{var}"' in tf or ref.startswith(("DB__DB_PASSWORD_", "GATEWAY__GATEWAY_TOKEN_")),
                                    f"{ref} not produced by the data module")
                    if src == "human":
                        self.assertIn(ref, HUMAN)
                    else:
                        self.assertNotIn(ref, HUMAN, "a wired key must not be human")
                elif src == "compose":
                    self.assertIn(e["name"].replace("file ", ""), read(ROOT / "deploy" / "hackathon" / ref))
                elif src == "ssm":
                    self.assertIn(ref.split("/")[-1], envtf)

    def test_wired_keys_are_generated_or_derived_never_placeholders(self):
        wiring, gen = read(DATA / "wiring.tf"), read(DATA / "generated.tf")
        self.assertNotIn("CHANGE_ME", wiring + gen)
        for e in CONTRACT["entries"]:
            if e["source"] != "secret" or e["ref"].startswith(("DB__DB_PASSWORD_", "GATEWAY__GATEWAY_TOKEN_")):
                continue  # passwords: wired_db_passwords over db_password_roles
            ok = f'"{e["ref"]}"' in wiring + gen or e["ref"] == "DB__POSTGRES_PASSWORD"
            self.assertTrue(ok, f'{e["ref"]} is neither generated nor derived')

    def test_db_passwords_cover_every_role(self):
        sec = read(DATA / "secrets.tf")
        roles = re.findall(r'"([A-Z_]+)"', sec[sec.index("db_password_roles"):sec.index("db_password_keys")])
        prefix = "DB__DB_PASSWORD_"
        for e in CONTRACT["entries"]:
            if e["ref"].startswith(prefix):
                self.assertIn(e["ref"][len(prefix):], roles)

    def test_only_provider_placeholders_remain(self):
        self.assertIn('k => "CHANGE_ME" if !contains(keys(local.generated_secrets), k)', read(DATA / "secrets.tf"))
        ssm = read(DATA / "ssm.tf")
        self.assertIn("ssm_placeholders = var.agent_services_enabled ? {} :", ssm)
        self.assertNotIn("CC_CORS_ORIGINS", ssm.split("ssm_derived")[0].split("ssm_placeholders")[1])

    def test_prohibited_names_never_present(self):
        for p in list(CONFIG.rglob("*")) + [DATA / "wiring.tf", ROOT / "scripts" / "secrets_contract.json"]:
            if p.is_file():
                for n in PROHIBITED:
                    self.assertNotIn(n, read(p), f"{n} in {p.name}")

    def test_config_files_are_valid_and_hold_no_secret_looking_value(self):
        grants = json.loads(read(CONFIG / "agent" / "field-grants.json"))
        self.assertTrue(all(isinstance(g, list) and len(g) == 2 for g in grants))
        fx = json.loads(read(CONFIG / "agent" / "fx-rates.json"))
        self.assertTrue(all(isinstance(v, str) for v in fx.values()))
        self.assertIsInstance(json.loads(read(CONFIG / "agent" / "field-overlay.json")), dict)
        self.assertIsInstance(json.loads(read(CONFIG / "support" / "bank-customer-links.json")), dict)
        for p in CONFIG.rglob("*.json"):
            self.assertFalse(re.search(r"[A-Za-z0-9+/_-]{32,}", read(p)), f"{p.name} looks like it holds a secret")

    def test_no_credential_in_a_url_anywhere(self):
        pat = re.compile(r"://[A-Za-z0-9_]+:([^@\s/\"'<>{}$]{8,})@")
        allowed = re.compile(r"(?i)(pw|password|secret|keep|x+)\w*")
        for d in ("tests", "scripts", "deploy", "docs", "terraform"):
            for p in (ROOT / d).rglob("*"):
                if not p.is_file() or p.suffix not in (".py", ".ps1", ".yaml", ".yml", ".sh", ".tftpl", ".md", ".json", ".hcl", ".tf") or p.name == Path(__file__).name:
                    continue
                m = pat.search(read(p))
                if m and not allowed.fullmatch(m.group(1)):
                    self.fail(f"possible credential in a URL in {p.relative_to(ROOT)}")


class Docs(unittest.TestCase):
    def test_inventory_lists_every_contract_name(self):
        doc = read(ROOT / "docs" / "secrets-wiring.md")
        for e in CONTRACT["entries"]:
            name = e["name"].replace("file ", "")
            if name.startswith("DB_PASSWORD_"):
                name = "_" + name[len("DB_PASSWORD_"):]
            self.assertTrue(name in doc or ("_" + name.split("_", 1)[1]) in doc or name.replace("<", "") in doc, e["name"])

    def test_human_checklist_lists_exactly_the_provider_keys(self):
        doc = read(ROOT / "docs" / "human-secrets-only.md")
        for k in HUMAN - {"AGENT__AGENTCORE_JEV_API_KEY"}:
            self.assertIn(k, doc)
        self.assertLessEqual(set(re.findall(r"\b([A-Z]+__[A-Z0-9_]+)\b", doc)), HUMAN)

    def test_readiness_has_no_human_row_for_a_wired_secret(self):
        doc = read(ROOT / "docs" / "deploy-readiness.md")
        sec = doc[doc.index("## Secrets checklist"):doc.index("## Apply order")]
        for row in sec.splitlines():
            if row.startswith("|") and "| human" in row:
                self.assertTrue(any(k in row for k in ("OPENROUTER", "JEV", "LANGFUSE")), row)


class Script(unittest.TestCase):
    def test_script_human_keys_and_status_prints_names_only(self):
        s = read(ROOT / "scripts" / "aws-prod.ps1")
        m = re.search(r"\$script:HumanSecretKeys = @\(([^)]*)\)", s)
        self.assertEqual(set(re.findall(r"'([A-Z_]+)'", m.group(1))), HUMAN - {"AGENT__AGENTCORE_JEV_API_KEY"})
        self.assertIn("'GATEWAY__JEV_API_KEY' = @('AGENT__AGENTCORE_JEV_API_KEY')", s)
        body = s[s.index("function Show-SecretStatus"):s.index("function Invoke-Status")]
        self.assertNotRegex(body, r"Write-Host[^\n]*\$(v|json|cur)\b")
        self.assertIn("UNSET", body)
        self.assertIn("Read-Host -Prompt $Prompt -AsSecureString", s)


if __name__ == "__main__":
    unittest.main()
