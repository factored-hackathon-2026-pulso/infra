#!/usr/bin/env python3
"""Local prod-like rehearsal of the EC2 host stacks with Podman (INFRA-B, docs/prodlike-rehearsal.md).

It does NOT keep a second compose file. It renders the REAL bundles in deploy/hackathon (the same compose files, the same
healthchecks, the same depends_on, the same env file names and the same image variables Terraform ships to the hosts) into
.prodlike/, changing only what a laptop cannot do: absolute host paths become named volumes, published ports go to
127.0.0.1 at a high port, secrets come from random local values, and services whose image does not exist yet are DROPPED and
reported as slots (agent-core serve, platform backend and SPA, core runtime). Nothing here talks to AWS.

    python scripts/prodlike/prodlike.py render                 # write .prodlike/ (compose, env files, .env); prints no secret
    python scripts/prodlike/prodlike.py build gateway --src D:\\path\\llm-gateway   # one image at a time, RAM-checked
    python scripts/prodlike/prodlike.py up                     # render + compose up + wait healthy (same rule as deploy-stack.sh)
    python scripts/prodlike/prodlike.py smoke [--live] [--strict]
    python scripts/prodlike/prodlike.py chaos postgres|gateway
    python scripts/prodlike/prodlike.py down [--volumes]

Environment: PULSO_STACK_PREFIX (default infb) names the compose project, volumes, networks and local images, so lanes do not
collide. PRODLIKE_COMPOSE overrides the compose command (default `podman compose`). Secret VALUES are never printed.
"""

from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import json
import os
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import yaml

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = ROOT / "deploy" / "hackathon"
SQL_DIR = ROOT / "terraform" / "modules" / "hackathon_data" / "sql"
CONTRACT = Path(__file__).with_name("env_contract.json")
WORK = ROOT / ".prodlike"

# Compose files per host, in the order Terraform merges them (COMPOSE_FILE in the rendered .env).
CORE_FILES = ["core/compose.yaml", "core/compose.postgres.yaml", "core/compose.agents.yaml"]
ENGINE_FILES = ["engine/compose.yaml"]
OBSERVABILITY_FILE = "core/compose.observability.yaml"
HOST_ENV = {"core": ["common", "gateway", "tools", "db", "agent"], "engine": ["common", "pulso"]}
AGENT_FILES = ["IDENTITY_KEYS", "STAFF_KEYS", "FIELD_GRANTS", "FIELD_OVERLAY", "FX_RATES"]
ENGINE_KID = "pulso-engine-local"  # the const of env_contract.json for PULSO_SERVICE_KID; its public key goes into staff-keys
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import ed25519  # noqa: E402  (pure Python RFC 8032: public key from the engine seed, signature for the smoke)

# Host paths that a laptop cannot have and whose content the rehearsal supplies from files of its own (name -> directory under files/).
LOCAL_DIRS = {"/srv/data/tools/current": "catalog", "/srv/data/agent/artifacts": "artifacts", "/srv/data/tools/data": "tools-data"}

# Local images: variable in the compose files -> (build recipe name, default reference when nothing is built).
IMAGE_VARS = {
    "GATEWAY_IMAGE": "gateway",
    "TOOLS_IMAGE": "tools",
    "PULSO_IMAGE": "engine",
    "PROXY_IMAGE": "proxy",
    "FORWARDER_IMAGE": "forwarder",
    "AGENT_IMAGE": "agent",
    "CORE_IMAGE": "core",
    "SUPPORT_API_IMAGE": "support_api",
    "SUPPORT_WEB_IMAGE": "support_web",
}
DEFAULT_REFS = {"PROXY_IMAGE": "docker.io/library/caddy:2", "POSTGRES_IMAGE": "docker.io/library/postgres:16.4",
                "STUB_IMAGE": "docker.io/library/python:3.12-slim"}

# Host ports of the rendered stack (127.0.0.1 only). Container port -> host port, per service where they collide.
# The default prefix `infb` keeps the original fixed ports; any other prefix gets its own block of ten derived from the prefix
# (or PULSO_STACK_PORT_BASE), so two lanes never fight for a port.
LEGACY_PORTS = {("llm-gateway", 8080): 18081, ("proxy", 8080): 18080, ("postgres", 5432): 15432, ("agent-core", 8001): 18001}


def port_map(prefix: str) -> dict[tuple[str, int], int]:
    forced = os.environ.get("PULSO_STACK_PORT_BASE")
    if prefix == "infb" and not forced:
        return dict(LEGACY_PORTS)
    base = int(forced) if forced else 20000 + int(hashlib.sha256(prefix.encode()).hexdigest(), 16) % 400 * 10
    return {("proxy", 8080): base, ("llm-gateway", 8080): base + 1, ("postgres", 5432): base + 2, ("agent-core", 8001): base + 3}


HOST_PORTS = LEGACY_PORTS  # kept for readers of the old name

# Slots: things the loop needs that cannot be rehearsed until their image exists. name -> (image variable, owner brief).
SLOTS = {
    "agent-core serve": ("AGENT_IMAGE", "ASKS/BRIEF_agent-core_serve_2026-10-05.md"),
    "platform backend": ("SUPPORT_API_IMAGE", "ASKS/BRIEF_platform_prod_ready_2026-10-05.md"),
    "platform SPA": ("SUPPORT_WEB_IMAGE", "ASKS/BRIEF_platform_prod_ready_2026-10-05.md"),
    "core runtime (core-bridge)": ("CORE_IMAGE", "engine repo core-bridge/Dockerfile; not in the improvement loop (ADR 0009)"),
}

# Build recipes: name -> (compose image variable, Dockerfile relative to the source dir or to this repo, context, min free MB).
BUILDS = {
    "gateway": ("GATEWAY_IMAGE", "Dockerfile", ".", 800, False),
    "tools": ("TOOLS_IMAGE", "Dockerfile", ".", 800, False),
    "engine": ("PULSO_IMAGE", "Dockerfile", ".", 3000, True),
    "forwarder": ("FORWARDER_IMAGE", "@docker/otlp-forwarder.Dockerfile", ".", 600, False),
    "agent": ("AGENT_IMAGE", "Dockerfile", ".", 1500, False),  # agent-core serve (python, uv): about 1 GB peak, no Rust
}

LOOP_STEPS = [  # the full loop of the plan, WS6: step, what it needs
    ("detect", "`prodlike.py loop` (engine image, planted SYNTHETIC cells): not part of `smoke`"),
    ("propose", "`prodlike.py loop` (engine reasoning roles via llm-gateway + agent-core serve registry as the minted builder)"),
    ("prove", "`prodlike.py loop` (regression proof: agent-core serve evaluate)"),
    ("announce", "platform backend /internal/builder/proposals/announce (slot: no platform image)"),
    ("approve", "platform SPA/API approval by a supervisor + agent-core approval routes (slot; the engine is never allowed to: smoke proves 403)"),
    ("publish", "agent-core serve publish by a human approver (slot: no platform)"),
    ("release", "release.published event from agent-core/platform to the engine (slot)"),
    ("outcome", "engine outcome step after a real release (slot)"),
]


class RehearsalError(Exception):
    pass


# --------------------------------------------------------------------------------------------------------------------
# Rendering (pure functions; the tests exercise them without Podman)
# --------------------------------------------------------------------------------------------------------------------

def deep_merge(a, b):
    """Compose-style merge: mappings merge recursively, lists concatenate (no duplicates), scalars are replaced."""
    if isinstance(a, dict) and isinstance(b, dict):
        out = dict(a)
        for k, v in b.items():
            out[k] = deep_merge(a[k], v) if k in a else v
        return out
    if isinstance(a, list) and isinstance(b, list):
        return a + [x for x in b if x not in a]
    return b


def load_merged(files: list[str], bundle: Path = BUNDLE) -> dict:
    merged: dict = {}
    for rel in files:
        path = bundle / rel
        if path.exists():
            merged = deep_merge(merged, yaml.safe_load(path.read_text(encoding="utf-8")))
    return merged


def image_var(image: str | None) -> tuple[str | None, bool]:
    """('GATEWAY_IMAGE', has_default) from '${GATEWAY_IMAGE:?set}' or '${POSTGRES_IMAGE:-postgres:16.4}'."""
    m = re.fullmatch(r"\$\{([A-Z0-9_]+)(:-[^}]*|:\?[^}]*)?\}", image or "")
    return (m.group(1), (m.group(2) or "").startswith(":-")) if m else (None, True)


def slug(path: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", path.strip("/").lower()).strip("_")


def subnet_for(prefix: str) -> str:
    return f"172.29.{100 + int(hashlib.sha256(prefix.encode()).hexdigest(), 16) % 100}"


def render_compose(doc: dict, available: set[str], prefix: str, host_name: str, strip_limits: bool = False,
                   ports_map: dict | None = None) -> tuple[dict, list[str]]:
    """Return (rendered compose document, deviations). `available` = image variables that have a local image."""
    ports_map = ports_map or port_map(prefix)
    doc = copy.deepcopy(doc)
    deviations: list[str] = []
    services = doc.get("services", {})
    dropped = {}
    for name, svc in list(services.items()):
        var, has_default = image_var(svc.get("image"))
        if var and not has_default and var not in available:
            dropped[name] = var
            del services[name]
    for name, var in sorted(dropped.items()):
        deviations.append(f"service {name} dropped: no local image for {var} (slot)")
    named_volumes: dict[str, dict] = {}
    if strip_limits:
        deviations.append("mem_limit removed from every service: this Podman machine delegates no memory or pids cgroup controller to containers; pids_limit set to 0 (unlimited)")
    for name, svc in services.items():
        deps = svc.get("depends_on")
        if isinstance(deps, dict):
            for d in [d for d in deps if d in dropped]:
                deviations.append(f"{name}: depends_on {d} removed (dropped service)")
                del deps[d]
            if not deps:
                del svc["depends_on"]
        if strip_limits:
            svc.pop("mem_limit", None)
            svc["pids_limit"] = 0  # these machines do not delegate the pids controller either (engine ENGINE_IMAGE.md)
        if "env_file" in svc:
            svc["env_file"] = [re.sub(r"^/run/pulso/env/", "./env/", e) for e in svc["env_file"]]
        vols = []
        for v in svc.get("volumes", []):
            src, sep, rest = v.partition(":")
            if src.startswith("/run/pulso/files/"):
                vols.append(f"./files/{src.rsplit('/', 1)[1]}:{rest}")
            elif src in LOCAL_DIRS:
                vols.append(f"./files/{LOCAL_DIRS[src]}:{rest}")
            elif src.startswith("/"):
                vname = slug(src)
                named_volumes[vname] = {}
                vols.append(f"{vname}:{rest}")
            else:
                vols.append(v)
        if vols:
            svc["volumes"] = vols
        ports = []
        for p in svc.get("ports", []):
            host, _, cont = str(p).partition(":")
            hp = ports_map.get((name, int(cont)), 18000 + int(host) % 1000)
            ports.append(f"127.0.0.1:{hp}:{cont}")
        if ports:
            svc["ports"] = ports
    if host_name == "core" and "agent-core" in services:
        # The platform backend has no image yet: serve's grant_active check calls http://platform.<zone>:8000 (real adapter). This
        # DOUBLE answers it, under that very name, so the env of serve stays the one infra renders. Reported, never hidden.
        services["platform"] = {
            "image": DEFAULT_REFS["STUB_IMAGE"], "command": ["python", "/stub/grants_stub.py"], "restart": "unless-stopped",
            "env_file": ["./env/platform-stub.env"], "volumes": ["./files/stub:/stub:ro", "./files/grants:/grants:ro"],
            "networks": {"internal": {"aliases": ["platform.pulso.internal"]}},
        }
        deviations.append("service platform ADDED: a DOUBLE of the support-platform grant endpoint (the platform image does not exist); "
                          "agent-core's real http_grant_active calls it at http://platform.pulso.internal:8000")
    # ONE network shared by both host projects (created by `up` with a fixed subnet), so the engine can use an IP literal for
    # the gateway exactly as in production, where it uses the core host's private IP.
    sub = subnet_for(prefix)
    doc["networks"] = {"internal": {"external": True, "name": f"{prefix}-net"}}
    fixed = {"llm-gateway": 10, "agent-core": 11, "tool-service": 12}
    for name, last in fixed.items():
        if name in services:
            services[name]["networks"] = {"internal": {"ipv4_address": f"{sub}.{last}"}}
    for svc in services.values():  # a service-level `networks: [internal]` list becomes the mapping form compose also accepts
        if svc.get("networks") == ["internal"]:
            svc["networks"] = {"internal": {}}
    if named_volumes:
        doc["volumes"] = named_volumes
    doc["name"] = f"{prefix}-{host_name}"
    doc.pop("x-logging", None)
    return doc, deviations


PREPARE = ROOT / "terraform" / "modules" / "hackathon_compute" / "templates" / "prepare.sh.tftpl"


def app_user_volumes(doc: dict, prepare_text: str) -> list[str]:
    """Named volumes of the rendered stack whose host directory pulso-stack-prepare gives to uid 10001 (chown / install -o)."""
    owned: set[str] = set()
    for line in prepare_text.splitlines():
        if "10001" in line and re.search(r"\b(chown|install)\b", line):
            owned |= {slug(p) for p in re.findall(r"/srv/data/[A-Za-z0-9_./-]+", line)}
    return sorted(v for v in (doc.get("volumes") or {}) if v in owned)


class Minter:
    """Local secret values, DETERMINISTIC for a persisted seed (.prodlike/secrets.seed): a re-render must give the same passwords,
    or a Postgres volume initialised by an earlier `up` would refuse the new ones. Without a seed it is plain `secrets`."""

    def __init__(self, seed: bytes | None = None):
        self.seed, self.n = seed, 0

    def bytes(self, n: int) -> bytes:
        if self.seed is None:
            return secrets.token_bytes(n)
        self.n += 1
        out = b""
        block = 0
        while len(out) < n:
            out += hashlib.sha256(self.seed + self.n.to_bytes(4, "big") + block.to_bytes(4, "big")).digest()
            block += 1
        return out[:n]

    def token(self, n: int = 32) -> str:
        return base64.urlsafe_b64encode(self.bytes(n)).rstrip(b"=").decode("ascii")  # about 1.33 n characters; the engine needs >= 24

    def hex(self, n: int = 32) -> str:
        return self.bytes(n).hex()


def token(n: int = 32) -> str:
    return Minter().token(n)


def read_external(path: Path | None, wanted: set[str]) -> dict[str, str]:
    """Copy only the wanted NAMES from a KEY=VALUE file; values stay in memory and are never printed."""
    out: dict[str, str] = {}
    if path and path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            k, sep, v = line.partition("=")
            if sep and k.strip() in wanted and v.strip():
                out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def build_env_files(contract: dict, prefix: str, external: dict[str, str] | None = None, seed: bytes | None = None) -> dict[str, dict[str, str]]:
    external = external or {}
    mint = Minter(seed)
    token = mint.token
    sub = subnet_for(prefix)
    consumers = contract["consumers"]
    tokens = {c: token(36) for c in consumers}
    tool_tok = token(36)
    internal_tok = token(36)
    db_pw = {}
    files: dict[str, dict[str, str]] = {}
    for fname, entries in contract["files"].items():
        env: dict[str, str] = {}
        for e in entries:
            n, how = e["name"], e["local"]
            if how == "token":
                env[n] = token(32)
                if n.startswith(("DB_PASSWORD_", "POSTGRES_")):
                    db_pw[n] = env[n]
            elif how == "hex64":
                env[n] = mint.hex(32)
            elif how == "gateway_consumers":
                env[n] = json.dumps({c.lower().replace("_", "-"): {"token_env": f"GATEWAY_TOKEN_{c}"} for c in consumers}, separators=(",", ":"))
            elif how == "llm_endpoints":
                env[n] = json.dumps({"openrouter": {"base_url": "https://openrouter.ai/api/v1", "api_key_env": "OPENROUTER_API_KEY"}}, separators=(",", ":"))
            elif how == "per_consumer_token":
                for c in consumers:
                    env[f"GATEWAY_TOKEN_{c}"] = tokens[c]
            elif how == "engine_gateway_token":
                env[n] = tokens["ENGINE"]
            elif how == "tool_tokens":
                env[n] = f"agent-core:{tool_tok}"
            elif how == "external":
                env[n] = external.get(n) or external.get(e.get("alias", ""), "CHANGE_ME")
            elif how.startswith("dsn:"):
                role, db, pwname = how.split(":")[1:]
                env[n] = f"postgresql://{role}:{files['db'][pwname]}@postgres:5432/{db}"
            elif how.startswith("gateway_token:"):
                env[n] = tokens[how.split(":", 1)[1]]
            elif how == "key_set":
                env[n] = "k1:" + base64.b64encode(mint.bytes(32)).decode("ascii")
            elif how == "tool_token":
                env[n] = tool_tok
            elif how == "internal_token":
                env[n] = internal_tok
            elif how == "placeholder":
                env[n] = "CHANGE_ME"
            elif how.startswith("const:"):
                env[n] = how[len("const:"):]
            elif how == "gateway_addr":
                env[n] = f"{sub}.10:8080"
            elif how == "core_addr":
                env[n] = f"{sub}.11:8001"
            elif how == "pulso_dsn":
                env[n] = "@@PULSO_DSN@@"
        files[fname] = env
    # Deviation (docs/prodlike-rehearsal.md): the engine connects as the Postgres master. In production pulso_app has no LOGIN
    # until sql/30_pulso_logins.sql runs after the engine migrations, a manual step this rehearsal does not repeat.
    master = files["db"]["POSTGRES_PASSWORD"]
    files["pulso"]["PULSO_DATABASE_URL"] = f"postgres://pulso_master:{master}@postgres:5432/pulso"
    return files


def write_env_file(path: Path, env: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{k}={v}\n" for k, v in env.items()), encoding="utf-8", newline="\n")
    try:
        path.chmod(0o600)
    except OSError:
        pass


def images_state(prefix: str, work: Path = WORK) -> dict[str, str]:
    f = work / "images.json"
    return json.loads(f.read_text(encoding="utf-8")) if f.exists() else {}


def terraform_default(name: str, tf: Path | None = None) -> str:
    """The default of a string variable in terraform/envs/hackathon/variables.tf (agent_serve_args): what Terraform writes into .env."""
    text = (tf or ROOT / "terraform" / "envs" / "hackathon" / "variables.tf").read_text(encoding="utf-8")
    m = re.search(r'variable "%s" \{.*?default\s*=\s*"([^"\n]*)"' % re.escape(name), text, re.S)
    if not m:
        raise RehearsalError(f"terraform variable {name} has no string default")
    return m.group(1)


def read_externals(paths: list[Path] | None, contract: dict) -> dict[str, str]:
    """Values of the `external` names (and their aliases) from KEY=VALUE files; later files win. Names only are ever reported."""
    wanted: set[str] = set()
    for entries in contract["files"].values():
        for e in entries:
            if e["local"] == "external":
                wanted |= {e["name"], e.get("alias", e["name"])}
    out: dict[str, str] = {}
    for p in paths or []:
        out.update(read_external(Path(p), wanted))
    return out


def staff_keys_with_engine(base: dict, seed_hex: str, kid: str = ENGINE_KID) -> dict:
    """agent-core staff-keys with the engine's PUBLIC key added under `kid` (derived from the seed, exactly as the engine does)."""
    out = copy.deepcopy(base)
    out.setdefault("principal_keys", {})[kid] = ed25519.b64url(ed25519.public_key(bytes.fromhex(seed_hex)))
    return out


def lang_arg(hdir: Path) -> str:
    """` --lang-thresholds ...` when the rehearsal supplied the file (the language never switches without it)."""
    return " --lang-thresholds /run/files/LANG_THRESHOLDS" if (hdir / "files" / "agent" / "LANG_THRESHOLDS").exists() else ""


def write_agent_files(work: Path, state: Path | None, env_files: dict[str, dict[str, str]]) -> list[str]:
    """files/agent/* (the five secret FILES__AGENT__* of the host), files/{catalog,artifacts,tools-data}, the platform-double files.

    `state` is the directory `prodlike.py state` produced (agent-core test identity keys, calibration, classifier, catalog,
    synthetic publication). Without it the key files are fail-closed empty objects, so `serve` refuses to start instead of running
    with something invented; `up` requires the state.
    """
    notes: list[str] = []
    core = work / "core"
    files = core / "files"
    agent = files / "agent"
    agent.mkdir(parents=True, exist_ok=True)
    for sub in ("catalog", "artifacts/calibrations", "artifacts/classifiers", "tools-data", "stub", "grants"):
        (files / sub).mkdir(parents=True, exist_ok=True)
    if state is not None and (state / "identity-keys.json").exists():
        shutil.copyfile(state / "identity-keys.json", agent / "IDENTITY_KEYS")
        staff = json.loads((state / "staff-keys.json").read_text(encoding="utf-8"))
        (agent / "STAFF_KEYS").write_text(json.dumps(staff_keys_with_engine(staff, env_files["pulso"]["PULSO_SERVICE_SEED_HEX"])), encoding="utf-8", newline="\n")
        shutil.copyfile(state / "field-grants.json", agent / "FIELD_GRANTS")
        shutil.copyfile(state / "field-overlay.json", agent / "FIELD_OVERLAY")
        if (state / "lang-thresholds.json").exists():
            shutil.copyfile(state / "lang-thresholds.json", agent / "LANG_THRESHOLDS")
            notes.append("serve gets --lang-thresholds /run/files/LANG_THRESHOLDS (Terraform has no FILES__AGENT__LANG_THRESHOLDS key yet): "
                         "without it a Portuguese message is answered in Spanish")
        for sub, target in (("calibration", "calibrations"), ("classifier", "classifiers")):
            shutil.copytree(state / sub, files / "artifacts" / target, dirs_exist_ok=True)
        if (state / "publication").exists():
            shutil.copytree(state / "publication", files / "tools-data", dirs_exist_ok=True)
            run = json.loads((state / "publication" / "publish" / "latest.json").read_text(encoding="utf-8"))["path"]
            shutil.copyfile(state / "publication" / run / "field_classification.json", files / "catalog" / "field_classification.json")
    else:
        for name in ("IDENTITY_KEYS", "STAFF_KEYS"):
            (agent / name).write_text("{}", encoding="utf-8")
        (agent / "FIELD_GRANTS").write_text("[]", encoding="utf-8")
        (agent / "FIELD_OVERLAY").write_text("{}", encoding="utf-8")
        notes.append("no agent state: key files are empty, serve will refuse to start (run `prodlike.py state --agent-core <checkout>`)")
    (agent / "FX_RATES").write_text(json.dumps({"USD": "1", "MXN": "0.055"}), encoding="utf-8")  # synthetic table of convertir_moneda
    shutil.copyfile(HERE / "grants_stub.py", files / "stub" / "grants_stub.py")
    write_env_file(core / "env" / "platform-stub.env", {"GRANTS_TOKEN": env_files["agent"]["AGENTCORE_GRANTS_TOKEN"]})
    return notes


def render_all(prefix: str, work: Path = WORK, external_file: Path | list | None = None, with_forwarder: bool = False,
               bundle: Path = BUNDLE, strip_limits: bool = False, state: Path | None = None) -> dict:
    """Write the rendered stacks. Returns {'deviations': [...], 'slots': [...], 'hosts': {...}}; never secret values."""
    contract = json.loads(CONTRACT.read_text(encoding="utf-8"))
    images = images_state(prefix, work)
    available = {v for v in images} | {v for v in DEFAULT_REFS}
    ext_paths = external_file if isinstance(external_file, list) else ([external_file] if external_file else [])
    work.mkdir(parents=True, exist_ok=True)
    seed_file = work / "secrets.seed"
    if not seed_file.exists():
        seed_file.write_bytes(secrets.token_bytes(32))
    env_files = build_env_files(contract, prefix, read_externals(ext_paths, contract), seed=seed_file.read_bytes())
    report = {"deviations": [], "slots": [], "hosts": {}}
    ports = port_map(prefix)
    for host, files in (("core", CORE_FILES + ([OBSERVABILITY_FILE] if with_forwarder else [])), ("engine", ENGINE_FILES)):
        hdir = work / host
        hdir.mkdir(parents=True, exist_ok=True)
        doc, dev = render_compose(load_merged(files, bundle), available, prefix, host, strip_limits, ports)
        if host == "engine" and "pulso" not in doc["services"]:
            dev.append("engine host not started: the proxy alone would front nothing (no PULSO_IMAGE); the env files are still rendered for the loop and the smoke")
            doc["services"] = {}
        report["deviations"] += [f"[{host}] {d}" for d in dev]
        (hdir / "compose.yaml").write_text(yaml.safe_dump(doc, sort_keys=False), encoding="utf-8", newline="\n")
        env_dir = hdir / "env"
        for fname in HOST_ENV[host]:  # each host gets only its own slice, like pulso-stack-prepare
            write_env_file(env_dir / f"{fname}.env", env_files[fname])
        if host == "core":
            report["deviations"] += [f"[core] {n}" for n in write_agent_files(work, state, env_files)]
        (hdir / ".env").write_text(
            "".join(f"{v}={images[v]}\n" for v in images) +
            "".join(f"{v}={r}\n" for v, r in DEFAULT_REFS.items() if v not in images) +
            "BUCKET_NAME=local-rehearsal-no-s3\nCORE_BLOB_PREFIX=core/blobs/\nPULSO_STORAGE_PREFIX=engine/\nPRIVATE_ZONE_NAME=pulso.internal\n"
            f"AGENT_SERVE_ARGS={terraform_default('agent_serve_args')}{lang_arg(hdir)}\n", encoding="utf-8", newline="\n")
        for extra in ("Caddyfile",):
            src = bundle / host / extra
            if src.exists():
                shutil.copyfile(src, hdir / extra)
        if host == "core":
            init = hdir / "initdb"
            (init / "sql").mkdir(parents=True, exist_ok=True)
            shutil.copyfile(bundle / "core" / "initdb" / "10_init.sh", init / "10_init.sh")
            shutil.copytree(bundle / "core" / "bootstrap", hdir / "bootstrap", dirs_exist_ok=True)
            for sql in sorted(SQL_DIR.glob("*.sql")):
                shutil.copyfile(sql, init / "sql" / sql.name)
        report["hosts"][host] = sorted(doc["services"])
    for slot, (var, brief) in SLOTS.items():
        if var not in images:
            report["slots"].append(f"{slot}: needs image {var} ({brief})")
    # ORIGIN_VERIFY is read by the smoke test from the rendered file; remember only where it is, never the value.
    (work / "state.json").write_text(json.dumps({"prefix": prefix, "hosts": report["hosts"]}), encoding="utf-8")
    return report


# --------------------------------------------------------------------------------------------------------------------
# Health rule (the same as deploy-stack.sh wait_healthy) and free RAM
# --------------------------------------------------------------------------------------------------------------------

def judge_containers(states: list[dict]) -> tuple[str, str]:
    """states: [{'name','status','health','exit_code'}] -> ('ok'|'pending'|'bad', reason). Mirrors deploy-stack.sh."""
    pending = False
    for s in states:
        status, health, code = s["status"], s["health"], s.get("exit_code", 0)
        if health == "unhealthy":
            return "bad", f"{s['name']} is unhealthy"
        if status == "restarting":
            return "bad", f"{s['name']} is restarting"
        if status == "dead":
            return "bad", f"{s['name']} is dead"
        if status == "exited":
            if code != 0:
                return "bad", f"{s['name']} exited with code {code}"
        elif health == "starting" or status == "created":
            pending = True
    return ("pending", "") if pending or not states else ("ok", "")


def free_ram_mb() -> int:
    if os.name == "nt":
        import ctypes

        class MemStatus(ctypes.Structure):
            _fields_ = [("l", ctypes.c_ulong), ("load", ctypes.c_ulong), ("tp", ctypes.c_ulonglong), ("ap", ctypes.c_ulonglong),
                        ("tpf", ctypes.c_ulonglong), ("apf", ctypes.c_ulonglong), ("tv", ctypes.c_ulonglong), ("av", ctypes.c_ulonglong),
                        ("ae", ctypes.c_ulonglong)]

        st = MemStatus()
        st.l = ctypes.sizeof(MemStatus)
        ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st))
        return int(st.ap // (1024 * 1024))
    for line in Path("/proc/meminfo").read_text().splitlines():
        if line.startswith("MemAvailable:"):
            return int(line.split()[1]) // 1024
    return 0


# --------------------------------------------------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------------------------------------------------

def run(cmd: list[str], check: bool = True, capture: bool = False, cwd: Path | None = None) -> subprocess.CompletedProcess:
    env = dict(os.environ, PODMAN_COMPOSE_WARNING_LOGS="false")
    r = subprocess.run(cmd, cwd=cwd, env=env, text=True, capture_output=capture)
    if check and r.returncode:
        raise RehearsalError(f"command failed ({r.returncode}): {' '.join(cmd[:4])} ...")
    return r


def compose_cmd(prefix: str, host: str) -> list[str]:
    base = shlex.split(os.environ.get("PRODLIKE_COMPOSE", "podman compose"))
    hdir = WORK / host
    return base + ["-p", f"{prefix}-{host}", "--project-directory", str(hdir), "-f", str(hdir / "compose.yaml"), "--env-file", str(hdir / ".env")]


def podman(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return run(["podman", *args], check=check, capture=True)


def container_states(prefix: str) -> list[dict]:
    out = []
    for host in ("core", "engine"):  # one query per project: podman ANDs two label filters of the same key
        r = podman("ps", "-a", "--filter", f"label=com.docker.compose.project={prefix}-{host}", "--format", "{{.Names}}")
        for name in r.stdout.split():
            i = json.loads(podman("inspect", name).stdout)[0]["State"]
            out.append({"name": name, "status": i["Status"], "health": (i.get("Health") or {}).get("Status", "none"), "exit_code": i.get("ExitCode", 0)})
    return out


def wait_healthy(prefix: str, timeout: int = 300, interval: int = 5) -> None:
    deadline, stable = time.time() + timeout, 0
    while True:
        verdict, why = judge_containers(container_states(prefix))
        if verdict == "bad":
            raise RehearsalError(why)
        stable = stable + 1 if verdict == "ok" else 0
        if stable >= 2:
            return
        if time.time() > deadline:
            raise RehearsalError(f"timeout after {timeout}s waiting for healthy containers")
        time.sleep(interval)


def env_paths(a) -> list[Path]:
    return [Path(p) for p in (getattr(a, "env_file", None) or [])]


def agent_state_dir() -> Path | None:
    return WORK / "state" if (WORK / "state" / "identity-keys.json").exists() else None


def cmd_render(a) -> int:
    rep = render_all(a.prefix, with_forwarder=a.forwarder, strip_limits=a.no_mem_limit,
                     external_file=env_paths(a), state=agent_state_dir())
    print(f"rendered {WORK} (no secret printed)")
    for h, svcs in rep["hosts"].items():
        print(f"  {h}: {', '.join(svcs)}")
    for s in rep["slots"]:
        print(f"  SLOT {s}")
    for d in rep["deviations"]:
        print(f"  deviation {d}")
    return 0


def cmd_build(a) -> int:
    var, dockerfile, ctx, need, big = BUILDS[a.name]
    free = free_ram_mb()
    if free < need and not a.force:
        print(f"refusing to build {a.name}: {free} MB free RAM < {need} MB needed (one build at a time; --force overrides)", file=sys.stderr)
        return 3
    src = Path(a.src or ".").resolve()
    df = (ROOT / dockerfile[1:]) if dockerfile.startswith("@") else (src / dockerfile)
    tag = f"localhost/{a.prefix}-{a.name}:local"
    args = ["build", "--format", "docker", "--platform", "linux/amd64", "-f", str(df), "-t", tag]
    if big:
        args += ["--build-arg", "CARGO_BUILD_JOBS=1"]
    if a.name == "agent":
        # The Dockerfile's uv cache mount can hand back a project wheel built from OLDER sources (same version): the image then carries
        # old code under the new GIT_SHA. Observed live on 2026-10-05; --no-cache rebuilds it (agent-core ask A11).
        args.insert(1, "--no-cache")
        sha = run(["git", "-C", str(src), "rev-parse", "--short", "HEAD"], check=False, capture=True).stdout.strip() or "local"
        args += ["--build-arg", f"GIT_SHA={sha}"]
    t0 = time.time()
    run(["podman", *args, str(src)])
    took = int(time.time() - t0)
    ident = podman("image", "inspect", "--format", "{{.Id}}", tag).stdout.strip()
    size = int(podman("image", "inspect", "--format", "{{.Size}}", tag).stdout.strip() or 0)
    state = images_state(a.prefix)
    state[var] = tag
    WORK.mkdir(parents=True, exist_ok=True)
    (WORK / "images.json").write_text(json.dumps(state, indent=1), encoding="utf-8")
    print(f"built {tag} id={ident[:19]} size={size // (1024 * 1024)} MB arch=amd64 time={took}s (record in the report; no registry push)")
    return 0


def tools_image(prefix: str) -> str:
    ref = images_state(prefix).get("TOOLS_IMAGE")
    if not ref:
        raise RehearsalError("build the tool-service image first: prodlike.py build tools --src <checkout>")
    return ref


SYNTHETIC_GRANTED_FIELDS = ["current_balance", "credit_limit", "amount", "amount_usd", "transaction_ts", "merchant_name", "transaction_status",
                            "product_type", "product_status", "complaint_status", "topic"]


# Fields the four fixture agents' flows put in their model views that agent-core's own overlay (scripts/e2e/field-overlay.json) does NOT classify; an
# unclassified field is `pii_direct` and reaches the model tokenized, so the router/classifier receives a token instead of the customer's words.
# Found by this rehearsal (PRODLIKE_SERVE_RESULTS D-*); remove each entry when agent-core's overlay carries it.
OVERLAY_GAPS = {
    "problema": {"field_class": "untrusted_text"}, "descripcion_cargo": {"field_class": "untrusted_text"},
    "radicado": {"field_class": "public"}, "pedido": {"field_class": "untrusted_text"},
}


def write_field_overlay(source: Path, dest: Path) -> None:
    overlay = json.loads(source.read_text(encoding="utf-8"))
    dest.write_text(json.dumps({**overlay, **OVERLAY_GAPS}), encoding="utf-8")


def write_synthetic_field_grants(path: Path) -> None:
    """FIELD_GRANTS of the rehearsal: the advisor may read the money and status fields of the SYNTHETIC customers for `advisor_view`.
    A real grant list is a data-governance decision (agent-core docs/tool-grants.md); an empty one makes every read come back masked."""
    path.write_text(json.dumps([[f, "advisor_view"] for f in SYNTHETIC_GRANTED_FIELDS]), encoding="utf-8")


def cmd_state(a) -> int:
    """Local synthetic inputs of agent-core serve: a synthetic data-pipeline publication (built inside the tool-service image),
    then agent-core's own `scripts/serve_state.py` (TEST identity keys of the agent-core repo, synthetic calibration/classifier,
    the publication's field catalog). The engine's public key is added to staff-keys by `render` from the seed it generates."""
    src = Path(a.agent_core).resolve()
    state = WORK / "state"
    pub = state / "publication"
    pub.mkdir(parents=True, exist_ok=True)
    podman("run", "--rm", "--pids-limit=0", "--user", "0", "-v", f"{pub.as_posix()}:/out", "-v", f"{(HERE / 'synthetic_publication.py').as_posix()}:/s.py:ro",
           "--entrypoint", "python", tools_image(a.prefix), "/s.py", "/out")
    run(["uv", "run", "--project", str(src), "python", "scripts/serve_state.py", "--state", str(state), "--data-pipeline", str(pub)], cwd=src)
    write_field_overlay(src / "scripts" / "e2e" / "field-overlay.json", state / "field-overlay.json")
    shutil.copyfile(src / "scripts" / "e2e" / "lang-thresholds.json", state / "lang-thresholds.json")
    write_synthetic_field_grants(state / "field-grants.json")
    print(f"state written to {state} (synthetic; contains TEST credentials of the agent-core repo: never use outside this rehearsal)")
    return 0


def host_agent_dsn(prefix: str) -> str:
    """The agent_app DSN of agent.env with the Postgres container name replaced by the published loopback port (for the host)."""
    dsn = env_value("core", "agent", "AGENTCORE_REGISTRY_DSN")
    return dsn.replace("@postgres:5432", f"@127.0.0.1:{port_map(prefix)[('postgres', 5432)]}")


def cmd_seed(a) -> int:
    """Import agent-core's fixture registry (the four agents and their eval suites) into the running Postgres, as agent-core's own
    runbook does. Runs `agentcore registry ... import` from the agent-core checkout with the DSN in the CHILD environment only."""
    src = Path(a.agent_core).resolve()
    fixtures = src / "tests" / "fixtures" / "registry-e2e"
    if a.model:
        # Project policy: the agents generate with mimo flash. The fixture profile names another model, so import a copy with ours.
        fixtures = WORK / "fixtures" / "registry-e2e"
        shutil.rmtree(fixtures.parent, ignore_errors=True)
        shutil.copytree(src / "tests" / "fixtures" / "registry-e2e", fixtures)
        for prof in (fixtures / "model_profiles").glob("*.yaml"):
            text = re.sub(r"(?m)^model: .*$", f"model: {a.model}", prof.read_text(encoding="utf-8"))
            prof.write_text(re.sub(r"(?m)^price: .*$", "price: {input_per_mtok: 0.14, output_per_mtok: 0.28, source: rehearsal, as_of: 2026-10-05}", text), encoding="utf-8", newline=chr(10))
    tokens = json.loads((WORK / "state" / "tokens.json").read_text(encoding="utf-8"))
    env = dict(os.environ, AGENTCORE_REGISTRY_DSN=host_agent_dsn(a.prefix), AGENTCORE_CREDENTIAL=tokens["admin"])
    r = subprocess.run(["uv", "run", "--project", str(src), "agentcore", "registry", "--verifier", "testing.registry_demo:demo_verifier",
                        "import", str(fixtures)], cwd=src, env=env, text=True, capture_output=True)
    out = (r.stdout or "").strip()
    try:
        rel = json.loads(out)
        print(f"registry import: {len(rel)} releases for agents {sorted({x['agent_id'] for x in rel})}")
    except (ValueError, TypeError, KeyError):
        print(chr(10).join(((r.stdout or "") + (r.stderr or "")).strip().splitlines()[-3:])[:600])
    return 0 if r.returncode == 0 or "ya tiene releases" in (r.stdout or "") + (r.stderr or "") else 1


def compose_up(a) -> subprocess.CompletedProcess:
    net = f"{a.prefix}-net"
    if podman("network", "exists", net, check=False).returncode:
        podman("network", "create", "--subnet", f"{subnet_for(a.prefix)}.0/24", net)
    last = None
    for host in ("core", "engine"):
        if not (WORK / host / "compose.yaml").exists() or not (yaml.safe_load((WORK / host / "compose.yaml").read_text(encoding="utf-8")) or {}).get("services"):
            continue
        # Like pulso-stack-prepare: create the volumes, give the app-user directories to uid 10001, then start.
        pre = run(compose_cmd(a.prefix, host) + ["up", "--no-start", "--remove-orphans"], check=False, capture=True)
        if pre.returncode:
            sys.stdout.write(pre.stdout or "")
            sys.stderr.write(pre.stderr or "")
            return pre
        doc = yaml.safe_load((WORK / host / "compose.yaml").read_text(encoding="utf-8"))
        helper = next(iter(images_state(a.prefix).values()), None)  # any local image has chown (debian or python)
        for vol in app_user_volumes(doc, PREPARE.read_text(encoding="utf-8")):
            if helper:
                extra = ["--pids-limit=0"]  # `podman run` accepts it where compose cannot; this machine has no pids cgroup controller
                podman("run", "--rm", "--user", "0", *extra, "-v", f"{a.prefix}-{host}_{vol}:/mnt", "--entrypoint", "chown", helper, "10001:10001", "/mnt")
        last = run(compose_cmd(a.prefix, host) + ["up", "-d", "--remove-orphans"], check=False, capture=True)
        sys.stdout.write(last.stdout or "")
        sys.stderr.write(last.stderr or "")
        if last.returncode:
            return last
    return last


# ---- `podman run` fallback ------------------------------------------------------------------------------------------
# Machines without a pids cgroup controller (this project's WSL ones) refuse EVERY container started through the compose API, because the
# daemon applies a default pids limit that crun cannot enforce, and docker-compose cannot send `--pids-limit=0`. `podman run
# --pids-limit=0` can. The documented fallback (INFRA_RUN_HEALTH section 6, ENGINE_IMAGE.md) is therefore to start the SAME rendered
# services with `podman run`: this runner reads the rendered compose.yaml and honours the subset the hosts' bundles use
# (image, command, entrypoint, restart, user, env_file, environment, ports, volumes, shm_size, healthcheck, networks, depends_on conditions).

def interpolate(text, env: dict[str, str]):
    """Compose-style ${VAR}, ${VAR:-default}, ${VAR:?msg} on strings (anything else is returned unchanged)."""
    if not isinstance(text, str):
        return text

    def sub(m: re.Match) -> str:
        if m.group(0) == "$$":  # compose escape for a literal dollar (the migrate entrypoint uses it for the shell)
            return "$"
        name, op, rest = m.group(1), m.group(2), m.group(3) or ""
        val = env.get(name, "")
        if op == ":-":
            return val or rest
        if op == ":?" and not val:
            raise RehearsalError(f"{name} is required: {rest}")
        return val

    return re.sub(r"\$\$|\$\{([A-Za-z0-9_]+)(?:(:-|:\?)([^}]*))?\}", sub, text)


def read_dotenv(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        k, sep, v = line.partition("=")
        if sep and not k.startswith("#"):
            out[k.strip()] = v.strip()
    return out


def secs(value: str | None, default: int) -> str:
    """'15s' -> '15s' (podman takes durations); None -> default seconds."""
    return value if value else f"{default}s"


def podman_run_args(prefix: str, host: str, name: str, svc: dict, doc: dict, env: dict[str, str], auto_ip: str | None = None) -> list[str]:
    hdir = WORK / host
    project = f"{prefix}-{host}"
    args = ["run", "-d", "--pids-limit=0", "--name", f"{project}-{name}-1", "--label", f"com.docker.compose.project={project}",
            "--label", f"com.docker.compose.service={name}", "--restart", svc.get("restart", "no")]
    if svc.get("restart") == "no" or svc.get("restart") is False:
        args[args.index("--restart") + 1] = "no"
    nets = svc.get("networks") or {}
    netname = doc["networks"]["internal"]["name"]
    net_cfg = (nets.get("internal") if isinstance(nets, dict) else None) or {}
    args += ["--network", netname]
    if net_cfg.get("ipv4_address") or auto_ip:
        # Fixed addresses (.10 gateway, .11 agent-core, .12 tool-service) must stay free, so every other service gets one from .50 up.
        args += ["--ip", net_cfg.get("ipv4_address") or auto_ip]
    for alias in net_cfg.get("aliases", []) + [name]:
        args += ["--network-alias", alias]
    if svc.get("user"):
        args += ["--user", str(svc["user"])]
    if svc.get("stop_grace_period"):
        args += ["--stop-timeout", re.sub(r"\D", "", str(svc["stop_grace_period"])) or "10"]
    if svc.get("shm_size"):
        args += ["--shm-size", str(svc["shm_size"])]
    for ef in svc.get("env_file", []):
        args += ["--env-file", str((hdir / ef).resolve())]
    for k, v in (svc.get("environment") or {}).items():
        args += ["-e", f"{k}={interpolate(str(v), env)}"]
    for port in svc.get("ports", []):
        args += ["-p", str(port)]
    for vol in svc.get("volumes", []):
        src, _, rest = vol.partition(":")
        if src.startswith("./"):
            src = (hdir / src[2:]).resolve().as_posix()
        elif "/" not in src:
            src = f"{project}_{src}"
        args += ["-v", f"{src}:{rest}"]
    hc = svc.get("healthcheck")
    if hc and not hc.get("disable"):
        test = hc["test"]
        # podman takes the JSON array form verbatim (a string would be shlex-split and lose the quoting of arguments with spaces)
        cmd = json.dumps(test) if isinstance(test, list) else test
        args += ["--health-cmd", cmd, "--health-interval", secs(hc.get("interval"), 30), "--health-timeout", secs(hc.get("timeout"), 30),
                 "--health-retries", str(hc.get("retries", 3)), "--health-start-period", secs(hc.get("start_period"), 0)]
    if svc.get("entrypoint"):
        ep = svc["entrypoint"]
        ep = [interpolate(x, env) for x in ep] if isinstance(ep, list) else interpolate(ep, env)
        args += ["--entrypoint", json.dumps(ep) if isinstance(ep, list) else ep]
    args.append(interpolate(svc["image"], env))
    command = svc.get("command")
    if command:
        args += shlex.split(interpolate(command, env)) if isinstance(command, str) else [interpolate(c, env) for c in command]
    return args


def podman_run_host(prefix: str, host: str, timeout: int = 300) -> None:
    """Start every service of the rendered host with `podman run`, honouring depends_on conditions; raises when one fails."""
    hdir = WORK / host
    doc = yaml.safe_load((hdir / "compose.yaml").read_text(encoding="utf-8"))
    env = read_dotenv(hdir / ".env")
    services = doc["services"]
    started: set[str] = set()

    def state(name: str) -> dict:
        return json.loads(podman("inspect", f"{prefix}-{host}-{name}-1").stdout)[0]["State"]

    def wait_condition(dep: str, cond: str) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            st = state(dep)
            if cond == "service_healthy" and (st.get("Health") or {}).get("Status") == "healthy":
                return
            if cond == "service_completed_successfully" and st["Status"] == "exited":
                if st["ExitCode"] == 0:
                    return
                raise RehearsalError(f"{dep} exited with code {st['ExitCode']}")
            if cond == "service_started" and st["Status"] == "running":
                return
            if st["Status"] in ("exited", "dead") and cond != "service_completed_successfully":
                raise RehearsalError(f"{dep} is {st['Status']} (code {st.get('ExitCode')})")
            time.sleep(2)
        raise RehearsalError(f"timeout waiting for {dep} ({cond})")

    def start(name: str) -> None:
        if name in started:
            return
        svc = services[name]
        for dep, cfg in (svc.get("depends_on") or {}).items():
            start(dep)
            wait_condition(dep, (cfg or {}).get("condition", "service_started"))
        podman("rm", "-f", f"{prefix}-{host}-{name}-1", check=False)
        auto = None
        if not ((svc.get("networks") or {}).get("internal") or {}).get("ipv4_address"):
            auto = f"{subnet_for(prefix)}.{50 + (host == 'engine') * 20 + list(services).index(name)}"
        r = podman(*podman_run_args(prefix, host, name, svc, doc, env, auto), check=False)
        if r.returncode:
            raise RehearsalError(f"podman run {name} failed: {(r.stderr or '').strip()[-300:]}")
        started.add(name)

    for name in services:
        start(name)


def fallback_up(a) -> None:
    """Start the rendered stacks with `podman run --pids-limit=0` (see the section above) after preparing the app-user volumes."""
    net = f"{a.prefix}-net"
    if podman("network", "exists", net, check=False).returncode:
        podman("network", "create", "--subnet", f"{subnet_for(a.prefix)}.0/24", net)
    helper = next(iter(images_state(a.prefix).values()), None)
    for host in ("core", "engine"):
        cfile = WORK / host / "compose.yaml"
        doc = yaml.safe_load(cfile.read_text(encoding="utf-8")) if cfile.exists() else {}
        if not doc or not doc.get("services"):
            continue
        for vol in app_user_volumes(doc, PREPARE.read_text(encoding="utf-8")):
            podman("volume", "create", f"{a.prefix}-{host}_{vol}", check=False)
            if helper:
                podman("run", "--rm", "--pids-limit=0", "--user", "0", "-v", f"{a.prefix}-{host}_{vol}:/mnt", "--entrypoint", "chown", helper, "10001:10001", "/mnt")
        podman_run_host(a.prefix, host, a.timeout)


def cmd_up(a) -> int:
    if "AGENT_IMAGE" in images_state(a.prefix) and agent_state_dir() is None:
        raise RehearsalError("agent-core serve needs its synthetic inputs first: prodlike.py state --agent-core <checkout>")
    cmd_render(a)
    if a.podman_run:
        a.no_mem_limit = True
        cmd_render(a)
        fallback_up(a)
    else:
        r = compose_up(a)
        if r is not None and r.returncode and any(k in (r.stderr or "") + (r.stdout or "") for k in ("memory.max", "controller `pids`", "controller `memory`")) and not a.no_mem_limit:
            # Some Podman machines (the WSL ones of this project) cannot set cgroup limits or a pids limit for containers started
            # through the compose API: re-render without mem_limit and start the same services with `podman run --pids-limit=0`.
            print("crun cannot set cgroup limits on this machine: falling back to `podman run --pids-limit=0` for the same rendered services "
                  "(mem_limit dropped; reported as a deviation)", file=sys.stderr)
            cmd_down(argparse.Namespace(prefix=a.prefix, volumes=True))
            a.no_mem_limit = True
            cmd_render(a)
            fallback_up(a)
        elif r is not None and r.returncode:
            raise RehearsalError("compose up failed")
    wait_healthy(a.prefix, a.timeout)
    print("UP: every container healthy twice in a row (rule of deploy-stack.sh)")
    if "AGENT_IMAGE" in images_state(a.prefix):
        print("next: `prodlike.py seed --agent-core <checkout>` imports the fixture registry, then `prodlike.py smoke`")
    return 0


def cmd_loop(a) -> int:
    """One run of `pulso loop` from the ENGINE image against this stack's agent-core serve, with PLANTED SYNTHETIC cells.

    Same env contract as the host (pulso.env + common.env, rendered by `render`), plus the loop's own variables
    (docs/dev/ENGINE_PROD.md section 2): synthetic cells and PULSO_PROFILE=demo, which the engine refuses for any other source. The
    cells come from the engine checkout (scripts/demo-loop/planted_cells.py: invented numbers, no customer, no row). Nothing is
    approved, published or promoted; the proposals land as drafts/candidates in agent-core. Models: mimo flash agents, mimo pro verifier."""
    image = images_state(a.prefix).get("PULSO_IMAGE")
    if not image:
        raise RehearsalError("build the engine image first: prodlike.py build engine --src <checkout>")
    src = Path(a.engine_src).resolve()
    inputs = WORK / "loop" / "inputs"
    inputs.mkdir(parents=True, exist_ok=True)
    run([sys.executable, str(src / "scripts" / "demo-loop" / "planted_cells.py"), "--out", str(inputs / "cells.ndjson")])
    work_vol = f"{a.prefix}-loop-work"
    podman("volume", "create", work_vol, check=False)
    podman("run", "--rm", "--pids-limit=0", "--user", "0", "-v", f"{work_vol}:/mnt", "--entrypoint", "chown", image, "10001:10001", "/mnt")
    env = {"PULSO_CELLS_SOURCE": "synthetic", "PULSO_PROFILE": "demo", "PULSO_LOOP_INPUTS_DIR": "/inputs", "PULSO_WORK_DIR": "/work",
           "PULSO_REGISTRY_ENV": "local", "PULSO_LLM_GATEWAY_MODEL": a.model, "PULSO_LLM_GATEWAY_VERIFIER_MODEL": a.verifier_model,
           "PULSO_LLM_GATEWAY_BUILDER_MODEL": a.model, "PULSO_LLM_GATEWAY_ALIAS": "openrouter"}
    cmd = ["run", "--rm", "--pids-limit=0", "--network", f"{a.prefix}-net", "--env-file", str(WORK / "engine" / "env" / "common.env"),
           "--env-file", str(WORK / "engine" / "env" / "pulso.env"), "-v", f"{inputs.as_posix()}:/inputs:ro", "-v", f"{work_vol}:/work"]
    for k, v in env.items():
        cmd += ["-e", f"{k}={v}"]
    cmd += [image, "loop"] + (["--check"] if a.check else [])
    r = podman(*cmd, check=False)
    sys.stdout.write(r.stdout or "")
    sys.stderr.write((r.stderr or "")[-4000:])
    print(f"pulso loop exit code {r.returncode} (0 done, 1 could not run, 2 refused config, 3 infra failure in a finding, 75 locked)")
    return r.returncode


def cmd_down(a) -> int:
    for host in ("engine", "core"):
        if (WORK / host / "compose.yaml").exists():
            run(compose_cmd(a.prefix, host) + ["down"] + (["--volumes"] if a.volumes else []), check=False)
    if a.volumes:
        podman("network", "rm", f"{a.prefix}-net", check=False)
        (WORK / "secrets.seed").unlink(missing_ok=True)  # the volumes that held the old passwords are gone: new ones next time
    return 0


# ---- smoke ---------------------------------------------------------------------------------------------------------

@dataclass
class Result:
    step: str
    status: str  # pass | fail | slot | info
    detail: str = ""


def http(method: str, url: str, headers: dict | None = None, body: bytes | None = None, timeout: int = 8) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except (urllib.error.URLError, OSError) as e:
        return 0, str(e).encode()


def env_value(host: str, fname: str, name: str) -> str:
    for line in (WORK / host / "env" / f"{fname}.env").read_text(encoding="utf-8").splitlines():
        if line.startswith(name + "="):
            return line.split("=", 1)[1]
    raise RehearsalError(f"{name} missing in {fname}.env")


def health_of(prefix: str, service: str) -> str:
    for host in ("core", "engine"):
        r = podman("ps", "-a", "--filter", f"label=com.docker.compose.project={prefix}-{host}", "--filter", f"label=com.docker.compose.service={service}", "--format", "{{.Names}}")
        for name in r.stdout.split():
            return (json.loads(podman("inspect", name).stdout)[0]["State"].get("Health") or {}).get("Status", "none")
    return "absent"


def exec_py(prefix: str, service: str, code: str) -> tuple[int, str]:
    for host in ("core", "engine"):
        r = podman("ps", "--filter", f"label=com.docker.compose.project={prefix}-{host}", "--filter", f"label=com.docker.compose.service={service}", "--format", "{{.Names}}")
        for name in r.stdout.split():
            p = podman("exec", name, "python", "-c", code, check=False)
            return p.returncode, (p.stdout or p.stderr).strip()
    return 125, "container not found"


def b64u(data: bytes) -> str:
    return ed25519.b64url(data)


def mint_builder_credential(seed_hex: str, kid: str = ENGINE_KID, roles: tuple[str, ...] = ("constructor",), ttl_s: int = 300,
                            now: float | None = None) -> str:
    """The credential the engine mints for agent-core `serve` (docs/dev/ENGINE_PROD.md section 1): compact JWS, header
    {alg: EdDSA, kid, typ: principal+jws}, payload a `builder` Principal (`constructor` only, no human attribute, session level)."""
    import datetime as dt

    at = dt.datetime.fromtimestamp(now if now is not None else time.time(), dt.timezone.utc)
    iso = lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")  # noqa: E731
    head = b64u(json.dumps({"alg": "EdDSA", "kid": kid, "typ": "principal+jws"}, separators=(",", ":")).encode())
    body = b64u(json.dumps({"type": "builder", "id": "pulso-engine", "roles": list(roles), "scopes": [], "attrs": {},
                            "auth": {"level": "session", "at": iso(at)}, "exp": iso(at + dt.timedelta(seconds=ttl_s))},
                           separators=(",", ":")).encode())
    sig = b64u(ed25519.sign(bytes.fromhex(seed_hex), f"{head}.{body}".encode("ascii")))
    return f"{head}.{body}.{sig}"


def container_name(prefix: str, service: str, running: bool = True) -> str | None:
    for host in ("core", "engine"):
        r = podman("ps", *([] if running else ["-a"]), "--filter", f"label=com.docker.compose.project={prefix}-{host}",
                   "--filter", f"label=com.docker.compose.service={service}", "--format", "{{.Names}}")
        for name in r.stdout.split():
            return name
    return None


def smoke_steps(prefix: str, live: bool) -> list[Callable[[], Result]]:
    ports = port_map(prefix)
    gw = f"http://127.0.0.1:{ports[('llm-gateway', 8080)]}"
    eng = f"http://127.0.0.1:{ports[('proxy', 8080)]}"
    agent = f"http://127.0.0.1:{ports[('agent-core', 8001)]}"

    def s_gateway_health():
        h = health_of(prefix, "llm-gateway")
        st, _ = http("GET", gw + "/healthz")
        return Result("gateway liveness (image probe + published :8080)", "pass" if h == "healthy" and st == 200 else "fail", f"health={h} http={st}")

    def s_gateway_auth():
        st, _ = http("POST", gw + "/v1/generate", {"Content-Type": "application/json"}, b"{}")
        return Result("gateway refuses a call without a bearer", "pass" if st == 401 else "fail", f"http={st}")

    def s_gateway_live():
        if not live:
            return Result("gateway authenticated call as consumer ENGINE (paid)", "info", "skipped: pass --live to spend a few cents")
        key = env_value("engine", "pulso", "PULSO_LLM_GATEWAY_KEY")
        if env_value("core", "gateway", "OPENROUTER_API_KEY") == "CHANGE_ME":
            return Result("gateway authenticated call as consumer ENGINE (paid)", "fail", "OPENROUTER_API_KEY is a placeholder: pass --gateway-env-file to render")
        body = json.dumps({"alias": "openrouter", "profile": {"model": "xiaomi/mimo-v2.6-flash", "max_tokens": 16},
                           "messages": [{"role": "user", "content": "Reply with the word ok."}]}).encode()
        st, _ = http("POST", gw + "/v1/generate", {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}, body, timeout=60)
        return Result("gateway authenticated call as consumer ENGINE (paid)", "pass" if st == 200 else "fail", f"http={st}")

    def s_postgres():
        h = health_of(prefix, "postgres")
        rc, out = 1, ""
        r = podman("ps", "--filter", f"label=com.docker.compose.project={prefix}-core", "--filter", "label=com.docker.compose.service=postgres", "--format", "{{.Names}}")
        for name in r.stdout.split():
            p = podman("exec", name, "psql", "-U", "pulso_master", "-d", "postgres", "-tAc",
                       "select count(*) from pg_database where datname in ('core_runtime','core_eval','pulso')", check=False)
            rc, out = p.returncode, p.stdout.strip()
        return Result("postgres healthy, init created the three databases", "pass" if h == "healthy" and out == "3" else "fail", f"health={h} databases={out or rc}")

    def s_tool_service():
        h = health_of(prefix, "tool-service")
        tok = env_value("core", "tools", "TOOL_SERVICE_TOKENS").split(":", 1)[1]
        rc, out = exec_py(prefix, "tool-service",
                          "import urllib.request as u,json;r=u.Request('http://127.0.0.1:8080/v1/tools',headers={'Authorization':'Bearer '+%r});"
                          "print(len(json.load(u.urlopen(r,timeout=5))['tools']))" % tok)
        rc2, ready = exec_py(prefix, "tool-service",
                             "import urllib.request as u,urllib.error as e\ntry:\n print(u.urlopen('http://127.0.0.1:8080/readyz',timeout=5).status)\nexcept e.HTTPError as x:\n print(x.code)")
        ok = h == "healthy" and rc == 0 and out.isdigit() and int(out) >= 7
        return Result("tool-service liveness and catalogue (7 tools); readyz reported", "pass" if ok else "fail",
                      f"health={h} tools={out} readyz={ready} (503 means no publication mounted; `state` mounts a synthetic one)")

    def s_engine():
        if container_name(prefix, "pulso") is None:
            return Result("engine ready through the proxy", "slot", "no engine image in this stack (build engine, then up)")
        h = health_of(prefix, "pulso")
        ov = env_value("core", "common", "ORIGIN_VERIFY")
        st_ready, _ = http("GET", eng + "/pulso/readyz", {"X-Origin-Verify": ov})
        st_noh, _ = http("GET", eng + "/pulso/readyz")
        st_int, _ = http("GET", eng + "/pulso/internal/x", {"X-Origin-Verify": ov})
        st_hz, _ = http("GET", eng + "/healthz")
        ok = h == "healthy" and st_ready == 200 and st_noh == 403 and st_int == 404 and st_hz == 200
        return Result("engine ready through the proxy (prefix kept), 403 without origin header, /internal hidden", "pass" if ok else "fail",
                      f"health={h} readyz={st_ready} no_header={st_noh} internal={st_int} proxy_healthz={st_hz}")

    def s_agent_probes():
        if container_name(prefix, "agent-core") is None:
            return Result("agent-core serve probes", "slot", "agent-core is not in the stack (no AGENT_IMAGE)")
        h = health_of(prefix, "agent-core")
        hz, _ = http("GET", agent + "/healthz")
        rz, body = http("GET", agent + "/readyz")
        try:
            deps = json.loads(body)
        except ValueError:
            deps = {}
        states = {k: (v if isinstance(v, str) else v.get("status", "?")) for k, v in (deps.get("checks") or deps.get("dependencies") or {}).items()} if isinstance(deps, dict) else {}
        vz, _ = http("GET", agent + "/version")
        ok = h == "healthy" and hz == 200 and rz == 200 and vz == 200
        return Result("agent-core serve: image probe healthy, /healthz, /readyz, /version", "pass" if ok else "fail",
                      f"health={h} healthz={hz} readyz={rz} version={vz} deps={states or 'n/a'}")

    def s_agent_mode():
        name = container_name(prefix, "agent-core")
        if name is None:
            return Result("agent-core starts in production mode, doubles not allowed", "slot", "agent-core is not in the stack")
        info = json.loads(podman("inspect", name).stdout)[0]
        env_names = {e.split("=", 1)[0] for e in info["Config"]["Env"]}
        forbidden = sorted(env_names & {"AGENTCORE_ALLOW_DOUBLES", "AGENTCORE_ALLOW_DEMO"})
        logs = podman("logs", name, check=False)
        text = (logs.stdout or "") + (logs.stderr or "")
        mode = [ln for ln in text.splitlines() if "mode=" in ln][:1]
        ok = not forbidden and any("mode=production" in ln for ln in mode)
        return Result("agent-core: AGENTCORE_ALLOW_DOUBLES unset, startup line says production", "pass" if ok else "fail",
                      f"forbidden_env={forbidden or 'none'} mode_line={'present' if mode else 'ABSENT'}")

    def s_agent_user():
        name = container_name(prefix, "agent-core")
        if name is None:
            return Result("agent-core runs as uid 10001", "slot", "agent-core is not in the stack")
        p = podman("exec", name, "python", "-c", "import os;print(os.getuid())", check=False)
        return Result("agent-core runs as uid 10001 (non-root)", "pass" if p.stdout.strip() == "10001" else "fail", f"uid={p.stdout.strip() or p.stderr.strip()}")

    def s_agent_builder():
        if container_name(prefix, "agent-core") is None:
            return Result("engine builder credential: create allowed, approve denied", "slot", "agent-core is not in the stack")
        seed = env_value("engine", "pulso", "PULSO_SERVICE_SEED_HEX")
        auth = {"Authorization": "Bearer " + mint_builder_credential(seed, env_value("engine", "pulso", "PULSO_SERVICE_KID")), "Content-Type": "application/json"}
        create = json.dumps({"agent_id": "disputas", "origin": "auto_detect", "title": "[prodlike smoke] builder contract"}).encode()
        st, body = http("POST", agent + "/v1/registry/proposals", auth, create)
        pid = json.loads(body).get("proposal_id") if st == 201 else None
        # Bodies must be valid: serve validates the body model before it checks the credential (a bad body answers 422 even when unauthenticated).
        denied = http("POST", agent + f"/v1/registry/proposals/{pid or 'none'}/approve", auth, json.dumps({"candidate_hash": "0" * 64}).encode())[0]
        forged = http("POST", agent + "/v1/registry/proposals", {**auth, "Authorization": "Bearer " + mint_builder_credential("11" * 32)}, create)[0]
        ok = st == 201 and denied == 403 and forged == 401
        return Result("engine builder credential minted from the seed: create 201, approve 403, forged key 401", "pass" if ok else "fail",
                      f"create={st} approve={denied} forged={forged} (seed/kid from pulso.env; kid listed in staff-keys)")

    steps = [s_gateway_health, s_gateway_auth, s_gateway_live, s_postgres, s_tool_service, s_agent_probes, s_agent_mode, s_agent_user,
             s_agent_builder, s_engine]
    return steps


def cmd_smoke(a) -> int:
    results: list[Result] = []
    for step in smoke_steps(a.prefix, a.live):
        try:
            results.append(step())
        except Exception as e:  # a missing container or file is a failed step, not a crash
            results.append(Result(getattr(step, "__name__", "step"), "fail", f"{type(e).__name__}: {e}"))
    for name, need in LOOP_STEPS:
        results.append(Result(f"loop: {name}", "slot", f"not exercised: {need}"))
    width = max(len(r.step) for r in results)
    for r in results:
        print(f"{r.status.upper():5} {r.step.ljust(width)}  {r.detail}")
    failed = [r for r in results if r.status == "fail"]
    slots = [r for r in results if r.status == "slot"]
    print(f"\n{len(failed)} failed, {len(slots)} slots not exercised (the platform images, and the engine if it was not built); this is NOT the full loop")
    return 1 if failed or (a.strict and slots) else 0


def one_off_serve(prefix: str, drop_env: str = "", extra_env: dict[str, str] | None = None, timeout: int = 60) -> tuple[int, str]:
    """Run the rendered agent-core service once in the foreground (own name, no ports, no fixed IP) with one variable removed
    from agent.env. Returns (exit code, stdout+stderr). The removed name is the only thing that may appear in the output."""
    hdir = WORK / "core"
    doc = yaml.safe_load((hdir / "compose.yaml").read_text(encoding="utf-8"))
    env = read_dotenv(hdir / ".env")
    svc = copy.deepcopy(doc["services"]["agent-core"])
    for k in ("ports", "healthcheck", "depends_on"):
        svc.pop(k, None)
    svc["networks"] = {"internal": {}}
    svc["restart"] = "no"
    tmp = hdir / "env" / "agent.oneoff.env"
    lines = [ln for ln in (hdir / "env" / "agent.env").read_text(encoding="utf-8").splitlines() if not ln.startswith(drop_env + "=")]
    write_env_file(tmp, dict(ln.split("=", 1) for ln in lines if "=" in ln))
    svc["env_file"] = ["./env/common.env", "./env/agent.oneoff.env"]
    svc["environment"] = {**svc.get("environment", {}), **(extra_env or {})}
    args = podman_run_args(prefix, "core", "agent-core-oneoff", svc, doc, env)
    args[args.index("-d")] = "--rm"
    args[args.index("--name") + 1] = f"{prefix}-oneoff-serve"
    for i, v in enumerate(args):
        if v == "--restart":
            args[i + 1] = "no"
    try:
        r = podman(*args, check=False)
    finally:
        tmp.unlink(missing_ok=True)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def cmd_chaos(a) -> int:
    """Stop or restart one dependency and prove the observable behaviour: readiness flips, liveness stays, recovery needs no manual step."""
    ports = port_map(a.prefix)
    agent = f"http://127.0.0.1:{ports[('agent-core', 8001)]}"
    have_agent = container_name(a.prefix, "agent-core") is not None
    ov = env_value("core", "common", "ORIGIN_VERIFY")
    proxy = f"http://127.0.0.1:{ports[('proxy', 8080)]}"

    def engine_ready() -> int:
        return http("GET", proxy + "/pulso/readyz", {"X-Origin-Verify": ov})[0]

    def agent_ready() -> int:
        return http("GET", agent + "/readyz", timeout=5)[0]

    def wait_for(pred: Callable[[], bool], secs: int) -> float | None:
        t0 = time.time()
        while time.time() - t0 < secs:
            if pred():
                return round(time.time() - t0, 1)
            time.sleep(2)
        return None

    def cname(service: str) -> str:
        name = container_name(a.prefix, service, running=False)
        if name is None:
            raise RehearsalError(f"service {service} is not in the stack")
        return name

    if a.what == "postgres":
        podman("stop", cname("postgres"))
        have_engine = container_name(a.prefix, "pulso") is not None
        down_e = wait_for(lambda: engine_ready() == 503, 90) if have_engine else 0
        down_a = wait_for(lambda: agent_ready() == 503, 90) if have_agent else 0
        live = (http("GET", agent + "/healthz")[0] if have_agent else 200, http("GET", proxy + "/healthz")[0] if have_engine else 200)
        podman("start", cname("postgres"))
        up_e = wait_for(lambda: engine_ready() == 200, 180) if have_engine else 0
        up_a = wait_for(lambda: agent_ready() == 200, 180) if have_agent else 0
        print(f"postgres stopped: engine /readyz 503 after {down_e}s, agent /readyz 503 after {down_a}s, liveness {live}; "
              f"started: engine 200 after {up_e}s, agent 200 after {up_a}s (no manual step)")
        return 0 if None not in (down_a, down_e, up_a, up_e) and live == (200, 200) else 1
    if a.what == "serve-start-db-down":
        # serve STARTS while Postgres is down: it must stay alive (liveness 200), report not-ready (503) and become ready by itself.
        podman("stop", cname("postgres"))
        podman("restart", cname("agent-core"))
        time.sleep(15)
        alive = http("GET", agent + "/healthz")[0]
        st = agent_ready()
        podman("start", cname("postgres"))
        up = wait_for(lambda: agent_ready() == 200, 180)
        print(f"serve started with Postgres down: /healthz={alive} /readyz={st}; Postgres started: /readyz 200 after {up}s with no other step")
        return 0 if alive == 200 and st == 503 and up is not None else 1
    if a.what == "serve-env-missing":
        rc, text = one_off_serve(a.prefix, drop_env=a.var)
        named = a.var in text
        print(f"serve started without {a.var}: exit code {rc}, message names the variable: {named}, value printed: no")
        return 0 if rc == 2 and named else 1
    if a.what == "gateway-down":
        podman("stop", cname("llm-gateway"))
        down = wait_for(lambda: agent_ready() == 503, 90)
        live = http("GET", agent + "/healthz")[0]
        podman("start", cname("llm-gateway"))
        up = wait_for(lambda: agent_ready() == 200, 180)
        print(f"gateway stopped: agent /readyz 503 after {down}s, /healthz stays {live}; started: /readyz 200 after {up}s")
        return 0 if down is not None and live == 200 and up is not None else 1
    if a.what == "tools-down":
        podman("stop", cname("tool-service"))
        time.sleep(8)
        st, _ = http("GET", agent + "/readyz", timeout=5)
        podman("start", cname("tool-service"))
        up = wait_for(lambda: agent_ready() == 200, 120)
        print(f"tool-service stopped: agent /readyz={st} (tool-service is optional for readiness by default and only reported); started: 200 after {up}s")
        return 0 if st in (200, 503) and up is not None else 1
    if a.what == "serve-restart":
        podman("restart", cname("agent-core"))
        up = wait_for(lambda: agent_ready() == 200, 120)
        print(f"agent-core restarted: /readyz 200 after {up}s")
        return 0 if up is not None else 1
    podman("kill", cname("llm-gateway"))
    back = wait_for(lambda: health_of(a.prefix, "llm-gateway") == "healthy", 120)
    print(f"gateway killed: restart policy brought it back healthy after {back}s")
    return 0 if back is not None else 1


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--prefix", default=os.environ.get("PULSO_STACK_PREFIX", "infb"))
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("render", "up"):
        s = sub.add_parser(name)
        s.add_argument("--forwarder", action="store_true", help="include the OTLP forwarder sidecars (needs a forwarder image)")
        s.add_argument("--env-file", "--gateway-env-file", dest="env_file", action="append",
                       help="KEY=VALUE file (repeatable); only the contract's `external` names (OPENROUTER_API_KEY, JEV_API_KEY or AGENTCORE_JEV_API_KEY) are copied, never printed")
        s.add_argument("--timeout", type=int, default=300)
        s.add_argument("--podman-run", action="store_true", help="skip compose and start the rendered services with `podman run --pids-limit=0` (machines without a pids cgroup controller)")
        s.add_argument("--no-mem-limit", action="store_true", help="drop mem_limit and lift pids_limit (`up` does it by itself when crun cannot set cgroup limits)")
    b = sub.add_parser("build")
    b.add_argument("name", choices=sorted(BUILDS))
    b.add_argument("--src", help="source checkout (build context); default: current directory")
    b.add_argument("--force", action="store_true", help="build even when free RAM is below the threshold")
    st = sub.add_parser("state", help="synthetic inputs of agent-core serve (publication, test identity keys, calibration, classifier)")
    st.add_argument("--agent-core", required=True, help="agent-core checkout (read-only use; `uv run` runs its scripts/serve_state.py)")
    sd = sub.add_parser("seed", help="import agent-core's fixture registry (four agents, eval suites) into the running Postgres")
    sd.add_argument("--agent-core", required=True)
    sd.add_argument("--model", help="replace the generation model of the fixture model profile (e.g. xiaomi/mimo-v2.6-flash)")
    lp = sub.add_parser("loop", help="one `pulso loop` run from the engine image against agent-core serve, planted SYNTHETIC cells")
    lp.add_argument("--engine-src", required=True, help="engine checkout (for scripts/demo-loop/planted_cells.py)")
    lp.add_argument("--model", default="xiaomi/mimo-v2.6-flash")
    lp.add_argument("--verifier-model", default="xiaomi/mimo-v2.6-pro")
    lp.add_argument("--check", action="store_true", help="validate the configuration only (`pulso loop --check`)")
    d = sub.add_parser("down")
    d.add_argument("--volumes", action="store_true")
    s = sub.add_parser("smoke")
    s.add_argument("--live", action="store_true")
    s.add_argument("--strict", action="store_true", help="slots count as failures")
    c = sub.add_parser("chaos")
    c.add_argument("what", choices=["postgres", "gateway", "gateway-down", "tools-down", "serve-restart", "serve-start-db-down", "serve-env-missing"])
    c.add_argument("--var", default="AGENTCORE_KEYS_TOKEN_MAP", help="serve-env-missing: the variable to remove")
    a = p.parse_args(argv)
    try:
        return {"render": cmd_render, "build": cmd_build, "up": cmd_up, "down": cmd_down, "smoke": cmd_smoke, "chaos": cmd_chaos,
                "state": cmd_state, "seed": cmd_seed, "loop": cmd_loop}[a.cmd](a)
    except RehearsalError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
