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
HOST_ENV = {"core": ["common", "gateway", "tools", "db"], "engine": ["common", "pulso"]}

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
DEFAULT_REFS = {"PROXY_IMAGE": "docker.io/library/caddy:2", "POSTGRES_IMAGE": "docker.io/library/postgres:16.4"}

# Host ports of the rendered stack (127.0.0.1 only). Container port -> host port, per service where they collide.
HOST_PORTS = {("llm-gateway", 8080): 18081, ("proxy", 8080): 18080, ("postgres", 5432): 15432}

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
}

LOOP_STEPS = [  # the full loop of the plan, WS6: step, what it needs
    ("detect", "engine loop runner against the stack (steps_cli cells is not in the engine image) + bank cells"),
    ("propose", "engine reasoning roles via llm-gateway (live) + agent-core serve registry (slot)"),
    ("prove", "agent-core serve evaluate with an eval_suite (slot)"),
    ("announce", "platform backend /internal/builder/proposals/announce (slot)"),
    ("approve", "platform SPA/API approval by a supervisor + agent-core approval routes (slot)"),
    ("publish", "agent-core serve publish (slot)"),
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


def render_compose(doc: dict, available: set[str], prefix: str, host_name: str) -> tuple[dict, list[str]]:
    """Return (rendered compose document, deviations). `available` = image variables that have a local image."""
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
    for name, svc in services.items():
        deps = svc.get("depends_on")
        if isinstance(deps, dict):
            for d in [d for d in deps if d in dropped]:
                deviations.append(f"{name}: depends_on {d} removed (dropped service)")
                del deps[d]
            if not deps:
                del svc["depends_on"]
        if "env_file" in svc:
            svc["env_file"] = [re.sub(r"^/run/pulso/env/", "./env/", e) for e in svc["env_file"]]
        vols = []
        for v in svc.get("volumes", []):
            src, sep, rest = v.partition(":")
            if src.startswith("/run/pulso/files/"):
                vols.append(f"./files/{src.rsplit('/', 1)[1]}:{rest}")
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
            hp = HOST_PORTS.get((name, int(cont)), 18000 + int(host) % 1000)
            ports.append(f"127.0.0.1:{hp}:{cont}")
        if ports:
            svc["ports"] = ports
    # ONE network shared by both host projects (created by `up` with a fixed subnet), so the engine can use an IP literal for
    # the gateway exactly as in production, where it uses the core host's private IP.
    sub = subnet_for(prefix)
    doc["networks"] = {"internal": {"external": True, "name": f"{prefix}-net"}}
    fixed = {"llm-gateway": 10, "agent-core": 11, "tool-service": 12}
    for name, last in fixed.items():
        if name in services:
            services[name]["networks"] = {"internal": {"ipv4_address": f"{sub}.{last}"}}
    if named_volumes:
        doc["volumes"] = named_volumes
    doc["name"] = f"{prefix}-{host_name}"
    doc.pop("x-logging", None)
    return doc, deviations


def token(n: int = 32) -> str:
    return secrets.token_urlsafe(n)  # n bytes -> about 1.3 n characters; the engine needs at least 24


def read_external(path: Path | None, wanted: set[str]) -> dict[str, str]:
    """Copy only the wanted NAMES from a KEY=VALUE file; values stay in memory and are never printed."""
    out: dict[str, str] = {}
    if path and path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            k, sep, v = line.partition("=")
            if sep and k.strip() in wanted and v.strip():
                out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def build_env_files(contract: dict, prefix: str, external: dict[str, str] | None = None) -> dict[str, dict[str, str]]:
    external = external or {}
    sub = subnet_for(prefix)
    consumers = contract["consumers"]
    tokens = {c: token(36) for c in consumers}
    tool_tok = token(36)
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
                env[n] = secrets.token_hex(32)
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
                env[n] = external.get(n, "CHANGE_ME")
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


def render_all(prefix: str, work: Path = WORK, external_file: Path | None = None, with_forwarder: bool = False,
               bundle: Path = BUNDLE) -> dict:
    """Write the rendered stacks. Returns {'deviations': [...], 'slots': [...], 'hosts': {...}}; never secret values."""
    contract = json.loads(CONTRACT.read_text(encoding="utf-8"))
    images = images_state(prefix, work)
    available = {v for v in images} | {v for v in DEFAULT_REFS}
    wanted = {e["name"] for e in contract["files"]["gateway"] if e["local"] == "external"}
    env_files = build_env_files(contract, prefix, read_external(external_file, wanted))
    work.mkdir(parents=True, exist_ok=True)
    report = {"deviations": [], "slots": [], "hosts": {}}
    for host, files in (("core", CORE_FILES + ([OBSERVABILITY_FILE] if with_forwarder else [])), ("engine", ENGINE_FILES)):
        hdir = work / host
        hdir.mkdir(parents=True, exist_ok=True)
        doc, dev = render_compose(load_merged(files, bundle), available, prefix, host)
        report["deviations"] += [f"[{host}] {d}" for d in dev]
        (hdir / "compose.yaml").write_text(yaml.safe_dump(doc, sort_keys=False), encoding="utf-8", newline="\n")
        env_dir = hdir / "env"
        for fname in HOST_ENV[host]:  # each host gets only its own slice, like pulso-stack-prepare
            write_env_file(env_dir / f"{fname}.env", env_files[fname])
        (hdir / ".env").write_text(
            "".join(f"{v}={images[v]}\n" for v in images) +
            "".join(f"{v}={r}\n" for v, r in DEFAULT_REFS.items() if v not in images) +
            "BUCKET_NAME=local-rehearsal-no-s3\nCORE_BLOB_PREFIX=core/blobs/\nPULSO_STORAGE_PREFIX=engine/\nPRIVATE_ZONE_NAME=pulso.internal\n"
            "AGENT_SERVE_ARGS=\n", encoding="utf-8", newline="\n")
        for extra in ("Caddyfile",):
            src = bundle / host / extra
            if src.exists():
                shutil.copyfile(src, hdir / extra)
        if host == "core":
            init = hdir / "initdb"
            (init / "sql").mkdir(parents=True, exist_ok=True)
            shutil.copyfile(bundle / "core" / "initdb" / "10_init.sh", init / "10_init.sh")
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
    r = podman("ps", "-a", "--filter", f"label=com.docker.compose.project={prefix}-core",
               "--filter", f"label=com.docker.compose.project={prefix}-engine", "--format", "{{.Names}}")
    out = []
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


def cmd_render(a) -> int:
    rep = render_all(a.prefix, with_forwarder=a.forwarder, external_file=Path(a.gateway_env_file) if a.gateway_env_file else None)
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
    run(["podman", *args, str(src)])
    ident = podman("image", "inspect", "--format", "{{.Id}}", tag).stdout.strip()
    size = int(podman("image", "inspect", "--format", "{{.Size}}", tag).stdout.strip() or 0)
    state = images_state(a.prefix)
    state[var] = tag
    WORK.mkdir(parents=True, exist_ok=True)
    (WORK / "images.json").write_text(json.dumps(state, indent=1), encoding="utf-8")
    print(f"built {tag} id={ident[:19]} size={size // (1024 * 1024)} MB arch=amd64 (record in the report; no registry push)")
    return 0


def cmd_up(a) -> int:
    cmd_render(a)
    net = f"{a.prefix}-net"
    if podman("network", "exists", net, check=False).returncode:
        podman("network", "create", "--subnet", f"{subnet_for(a.prefix)}.0/24", net)
    for host in ("core", "engine"):
        if not (WORK / host / "compose.yaml").exists():
            continue
        run(compose_cmd(a.prefix, host) + ["up", "-d", "--remove-orphans"])
    wait_healthy(a.prefix, a.timeout)
    print("UP: every container healthy twice in a row (rule of deploy-stack.sh)")
    return 0


def cmd_down(a) -> int:
    for host in ("engine", "core"):
        if (WORK / host / "compose.yaml").exists():
            run(compose_cmd(a.prefix, host) + ["down"] + (["--volumes"] if a.volumes else []), check=False)
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


def smoke_steps(prefix: str, live: bool) -> list[Callable[[], Result]]:
    gw = "http://127.0.0.1:18081"
    eng = "http://127.0.0.1:18080"

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
                      f"health={h} tools={out} readyz={ready} (503 expected until a data-pipeline publication is mounted)")

    def s_engine():
        h = health_of(prefix, "pulso")
        ov = env_value("core", "common", "ORIGIN_VERIFY")
        st_ready, _ = http("GET", eng + "/pulso/readyz", {"X-Origin-Verify": ov})
        st_noh, _ = http("GET", eng + "/pulso/readyz")
        st_int, _ = http("GET", eng + "/pulso/internal/x", {"X-Origin-Verify": ov})
        st_hz, _ = http("GET", eng + "/healthz")
        ok = h == "healthy" and st_ready == 200 and st_noh == 403 and st_int == 404 and st_hz == 200
        return Result("engine ready through the proxy (prefix kept), 403 without origin header, /internal hidden", "pass" if ok else "fail",
                      f"health={h} readyz={st_ready} no_header={st_noh} internal={st_int} proxy_healthz={st_hz}")

    steps = [s_gateway_health, s_gateway_auth, s_gateway_live, s_postgres, s_tool_service, s_engine]
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
    print(f"\n{len(failed)} failed, {len(slots)} slots not exercised (images missing: agent-core serve, platform); this is NOT the full loop")
    return 1 if failed or (a.strict and slots) else 0


def cmd_chaos(a) -> int:
    """Stop a dependency and prove the observable behaviour: readiness flips, liveness stays, restart policy recovers."""
    ov = env_value("core", "common", "ORIGIN_VERIFY")

    def engine_ready() -> int:
        return http("GET", "http://127.0.0.1:18080/pulso/readyz", {"X-Origin-Verify": ov})[0]

    def wait_for(pred: Callable[[], bool], secs: int) -> float | None:
        t0 = time.time()
        while time.time() - t0 < secs:
            if pred():
                return round(time.time() - t0, 1)
            time.sleep(2)
        return None

    def cname(service: str) -> str:
        r = podman("ps", "-a", "--filter", f"label=com.docker.compose.service={service}", "--format", "{{.Names}}")
        return r.stdout.split()[0]

    if a.what == "postgres":
        podman("stop", cname("postgres"))
        down = wait_for(lambda: engine_ready() == 503, 90)
        live = http("GET", "http://127.0.0.1:18080/healthz")[0]
        podman("start", cname("postgres"))
        up = wait_for(lambda: engine_ready() == 200, 180)
        print(f"postgres stopped: engine /readyz 503 after {down}s, proxy /healthz stays {live}; postgres started: /readyz 200 after {up}s")
        return 0 if down is not None and live == 200 and up is not None else 1
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
        s.add_argument("--gateway-env-file", help="KEY=VALUE file; only OPENROUTER_API_KEY and JEV_API_KEY are copied, never printed")
        s.add_argument("--timeout", type=int, default=300)
    b = sub.add_parser("build")
    b.add_argument("name", choices=sorted(BUILDS))
    b.add_argument("--src", help="source checkout (build context); default: current directory")
    b.add_argument("--force", action="store_true", help="build even when free RAM is below the threshold")
    d = sub.add_parser("down")
    d.add_argument("--volumes", action="store_true")
    s = sub.add_parser("smoke")
    s.add_argument("--live", action="store_true")
    s.add_argument("--strict", action="store_true", help="slots count as failures")
    c = sub.add_parser("chaos")
    c.add_argument("what", choices=["postgres", "gateway"])
    a = p.parse_args(argv)
    try:
        return {"render": cmd_render, "build": cmd_build, "up": cmd_up, "down": cmd_down, "smoke": cmd_smoke, "chaos": cmd_chaos}[a.cmd](a)
    except RehearsalError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
