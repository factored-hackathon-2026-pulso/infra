"""Exercise a running agent-core `serve` of the prod-like rehearsal: turns, the engine registry flow, run export, concurrency.

Run it with agent-core's own Python environment (it uses agent-core's TEST identity issuer, the same keys `prodlike.py state` put into the
serve identity-keys file) and against the synthetic data of the rehearsal:

    uv run --project <agent-core checkout> python scripts/prodlike/exercise_serve.py --prefix prodlike [--only turns,registry,export,load]

Everything is synthetic (two invented customers of the synthetic publication). It prints counts, outcomes and latencies, never a credential
and never the text of a conversation. The LLM calls go through the llm-gateway of the stack (OpenRouter, mimo flash), so they cost cents.

What it does NOT do, on purpose: approve, reject, publish or promote anything. Those are human steps of the platform; the engine principal is
only asked to create, write, validate, freeze and evaluate, and the script proves that approve and publish are refused with 403.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import statistics
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("prodlike", HERE / "prodlike.py")
pl = importlib.util.module_from_spec(spec)
sys.modules["prodlike"] = pl
spec.loader.exec_module(pl)  # type: ignore[union-attr]

from agent_core.adapters.system_clock import SystemClock  # noqa: E402
from agent_core.adapters.system_ids import SystemIds  # noqa: E402
from agent_core.ports import IdKind  # noqa: E402
from testing.chat import ChatSession  # noqa: E402
from testing.fakes.identity import TestIdentityIssuer  # noqa: E402

CUSTOMER = "CLI-0000000001"  # a customer of the synthetic publication (tool-service data)
Json = dict[str, Any]
RESULTS: list[dict] = []


def record(name: str, status: str, detail: str = "", **extra: Any) -> None:
    RESULTS.append({"check": name, "status": status, "detail": detail, **extra})
    print(f"{status.upper():5} {name}  {detail}", flush=True)


class Client:
    def __init__(self, base: str):
        self.base, self.issuer, self.ids = base.rstrip("/"), TestIdentityIssuer(SystemClock()), SystemIds()

    def call(self, method: str, path: str, token: str | None = None, body: Any = None, headers: dict | None = None) -> tuple[int, Json]:
        hdrs = {"Content-Type": "application/json", **(headers or {})}
        if token:
            hdrs["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(self.base + path, data=None if body is None else json.dumps(body).encode(), method=method, headers=hdrs)
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                raw = r.read()
                return r.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                return e.code, (json.loads(raw) if raw else {})
            except ValueError:
                return e.code, {}


def converse(c: Client, agent: str, lines: list[str], *, advisor: bool = False, follow_ups: int = 2, subject: str = CUSTOMER, who: str = "adv-7") -> dict:
    said: list[str] = []
    extra: dict[str, str] = {}
    if advisor:
        principal, delegation = c.issuer.advisor(who, subject)
        token = lambda: principal  # noqa: E731
        extra, step_up = {"X-On-Behalf-Of": delegation}, None
    else:
        token = lambda: c.issuer.customer(subject)  # noqa: E731
        step_up = lambda: c.issuer.stepped_up(subject)  # noqa: E731
    transport = lambda m, p, h, b: c.call(m, p, body=b, headers=dict(h))  # noqa: E731
    t0 = time.time()
    chat = ChatSession(transport=transport, ids=c.ids, token=token, step_up_token=step_up, agent=agent, out=said.append, ask=lambda _: "s",
                       extra_headers=extra)
    chat.start()
    if chat.run_id is None:
        return {"ok": False, "why": "no run", "seconds": round(time.time() - t0, 1), "text": ""}
    for line in lines:
        if chat.closed:
            break
        chat.say(line)
    for _ in range(follow_ups):
        if chat.closed:
            break
        chat.say("sí" if "pt" not in agent else "sim")
    status, summary = c.call("GET", f"/v1/runs/{chat.run_id}", chat._current_token(), headers=extra)
    return {"ok": status == 200, "run_id": chat.run_id, "status": summary.get("status"), "outcome": summary.get("outcome"),
            "seconds": round(time.time() - t0, 1), "text": " ".join(said), "messages": len(said)}


TURN_CASES = [
    # name, agent, lines, advisor, expectation (outcome set or text fragment)
    ("recepcion es: disputa 120 USD (transfer to disputas)", "recepcion", ["no reconozco un cargo en la Tienda Aurora", "el de 120 dólares"], False, {"resolved", "escalated"}),
    ("recepcion es: fraud interrupt", "recepcion", ["me robaron la tarjeta"], False, {"escalated"}),
    ("recepcion pt: dispute 120 USD", "recepcion", ["Olá, eu não reconheço uma compra no meu cartão de crédito feita ontem na loja Aurora, preciso de ajuda", "a de 120 dólares"], False, {"resolved", "escalated"}),
    ("disputas es: direct", "disputas", ["no reconozco un cargo de 120 dólares en la Tienda Aurora"], False, {"resolved", "escalated", None}),
    ("consultas es: case status", "consultas", ["quiero saber el estado de mi reclamo", "CASE-1"], False, {"resolved", "escalated", "abstained", None}),
    ("consultas pt: case status", "consultas", ["Olá, eu gostaria de saber o estado da minha reclamação, por favor", "CASE-1"], False, {"resolved", "escalated", "abstained", None}),
    ("copiloto-asesor es: card balance", "copiloto-asesor", ["¿cuánto debe en la tarjeta?"], True, "1342.8"),
    ("copiloto-asesor pt: card balance", "copiloto-asesor", ["Quanto o cliente deve no cartão de crédito e qual é o limite disponível agora?"], True, "1342.8"),
]


def run_turns(c: Client, match: str = "") -> None:
    for name, agent, lines, advisor, expect in TURN_CASES:
        if match and match not in name:
            continue
        try:
            r = converse(c, agent, lines, advisor=advisor)
        except Exception as e:  # a crash is a result, not an abort
            record(f"turn: {name}", "fail", f"{type(e).__name__}")
            continue
        if isinstance(expect, str):
            found = re.search(r"1342[.,]8", r["text"]) is not None
            ok = r["ok"] and found
            detail = f"status={r.get('status')} outcome={r.get('outcome')} card_balance_in_answer={found} {r['seconds']}s run={r.get('run_id')}"
        else:
            ok = r["ok"] and r.get("outcome") in expect
            detail = f"status={r.get('status')} outcome={r.get('outcome')} messages={r.get('messages')} {r['seconds']}s run={r.get('run_id')}"
        if " pt" in name:  # the reply must come back in Portuguese (needs --lang-thresholds; see the results report)
            pt = re.search(r"(n[ãa]o|voc[êe]|cart[ãa]o|obrigad[oa]|pode)", r["text"].lower()) is not None
            detail += f" reply_in_portuguese={pt}"
            ok = ok and pt
        record(f"turn: {name}", "pass" if ok else "fail", detail, run_id=r.get("run_id"), outcome=r.get("outcome"), seconds=r["seconds"])


def engine_headers(auth: str) -> dict:
    return {"Authorization": f"Bearer {auth}"}


def run_registry(c: Client, prefix: str) -> None:
    """create -> draft -> validate -> freeze -> evaluate (disputas-suite) as the engine principal, minted from its seed; approve and
    publish must be 403. A second credential with the exporter role reads the run export."""
    seed = pl.env_value("engine", "pulso", "PULSO_SERVICE_SEED_HEX")
    kid = pl.env_value("engine", "pulso", "PULSO_SERVICE_KID")
    tok = pl.mint_builder_credential(seed, kid)
    st, p = c.call("POST", "/v1/registry/proposals", tok, {"agent_id": "disputas", "origin": "auto_detect", "title": "[prodlike] engine flow"})
    record("registry: create proposal as pulso-engine (minted)", "pass" if st == 201 and p.get("created_by") == "pulso-engine" else "fail",
           f"http={st} created_by={p.get('created_by')}")
    if st != 201:
        return
    pid = p["proposal_id"]
    draft = {"expected_rev": p.get("rev", 0), "changes": [{
        "kind": "prompt", "content": {
            "id": "p/resumen_radicado", "version": f"1.{int(time.time()) % 100000 + 1}.0",
            "locales": {"es": "Confirma en una frase que la disputa quedó radicada y di qué pasa después.",
                        "pt": "Confirme em uma frase que a contestação foi registrada e diga o que acontece depois."},
            "model_profile": "perfil-generacion@1.0.0"},
        "docs": {"description": "prodlike rehearsal draft", "rationale": "exercise the engine flow", "changelog": "wording"}}]}
    st, body = c.call("PUT", f"/v1/registry/proposals/{pid}/draft", tok, draft)
    record("registry: write draft", "pass" if st == 200 else "fail", f"http={st} {body.get('code', '')}")
    st, body = c.call("POST", f"/v1/registry/proposals/{pid}/validate", tok)
    record("registry: validate", "pass" if st == 200 else "fail", f"http={st} ok={body.get('ok')}")
    st, cand = c.call("POST", f"/v1/registry/proposals/{pid}/freeze", tok, headers={"Idempotency-Key": "prodlike-freeze-" + pid})
    record("registry: freeze", "pass" if st == 200 else "fail", f"http={st} {cand.get('code', '')}")
    t0 = time.time()
    st, ev = c.call("POST", f"/v1/registry/proposals/{pid}/evaluate", tok, {"suite_id": "disputas-suite"}, {"Idempotency-Key": "prodlike-eval-" + pid})
    record("registry: evaluate with eval_suite disputas-suite", "pass" if st == 200 else "fail",
           f"http={st} verdict={ev.get('verdict') or ev.get('status')} {round(time.time() - t0, 1)}s {ev.get('code', '')}", eval_keys=sorted(ev)[:12])
    chash = cand.get("candidate_hash") or (cand.get("candidate") or {}).get("hash") or "0" * 64
    st, body = c.call("POST", f"/v1/registry/proposals/{pid}/approve", tok, {"candidate_hash": chash})
    record("registry: engine approve is refused (403)", "pass" if st == 403 else "fail", f"http={st} {body.get('code', '')}")
    st, body = c.call("POST", f"/v1/registry/proposals/{pid}/publish", tok, headers={"Idempotency-Key": "prodlike-publish-" + pid})
    record("registry: engine publish is refused (403)", "pass" if st == 403 else "fail", f"http={st} {body.get('code', '')}")
    st, body = c.call("GET", f"/v1/registry/proposals/{pid}", tok)
    record("registry: proposal readable by its creator", "pass" if st == 200 else "fail", f"http={st} state={body.get('state') or (body.get('proposal') or {}).get('state')}")


def run_export(c: Client) -> None:
    seed = pl.env_value("engine", "pulso", "PULSO_SERVICE_SEED_HEX")
    kid = pl.env_value("engine", "pulso", "PULSO_SERVICE_KID")
    exporter = pl.mint_builder_credential(seed, kid, roles=("exporter",))
    st, page = c.call("GET", "/v1/export/runs?limit=50", exporter)
    items = page.get("items", []) if isinstance(page, dict) else []
    record("export: list runs as exporter", "pass" if st == 200 and items else "fail", f"http={st} runs={len(items)}")
    if items:
        rid = items[-1].get("run_id") or items[-1].get("id")
        st, ev = c.call("GET", f"/v1/export/runs/{rid}/events?limit=100", exporter)
        record("export: events of a run", "pass" if st == 200 and ev.get("items") else "fail", f"http={st} events={len(ev.get('items', []))}")
        constructor = pl.mint_builder_credential(seed, kid)
        st, lin = c.call("GET", f"/v1/registry/runs/{rid}/lineage", constructor)
        record("lineage of a run (constructor)", "pass" if st == 200 else "fail", f"http={st} keys={sorted(lin)[:6] if isinstance(lin, dict) else ''} {lin.get('code', '') if isinstance(lin, dict) else ''}")
    st, _ = c.call("GET", "/v1/export/runs", pl.mint_builder_credential(seed, kid))
    record("export: constructor-only credential cannot export", "pass" if st == 403 else "fail", f"http={st}")


def run_load(c: Client, n: int = 20, kind: str = "fraud") -> None:
    """n simultaneous conversations. `fraud`: recepcion, fraud interrupt (JEV + rules, no generation). `copilot`: copiloto-asesor asks the card
    balance (JEV + tool-service + two or more mimo-flash generations)."""
    def one(i: int) -> dict:
        try:
            if kind == "copilot":
                r = converse(c, "copiloto-asesor", ["¿cuánto debe en la tarjeta?"], advisor=True, follow_ups=0, who=f"adv-load-{i}")
                good = r["ok"] and re.search(r"1342[.,]8", r["text"]) is not None
            else:
                r = converse(c, "recepcion", ["me robaron la tarjeta"], follow_ups=0, subject=f"CLI-load-{i:04d}")  # one principal each: the rate limit is per principal
                good = r["ok"] and r.get("outcome") == "escalated"
            return {"i": i, "ok": good, "s": r["seconds"], "outcome": r.get("outcome"), "status": r.get("status")}
        except Exception as e:
            return {"i": i, "ok": False, "s": 0.0, "err": type(e).__name__}

    t0 = time.time()
    with ThreadPoolExecutor(max_workers=n) as ex:
        out = list(ex.map(one, range(n)))
    wall = round(time.time() - t0, 1)
    lat = sorted(r["s"] for r in out if r["ok"])
    errs = [r for r in out if not r["ok"]]
    p50 = statistics.median(lat) if lat else None
    p95 = lat[min(len(lat) - 1, int(round(0.95 * len(lat))) - 1)] if lat else None
    record(f"load[{kind}]: {n} concurrent conversations", "pass" if not errs else "fail",
           f"ok={len(lat)} errors={len(errs)} p50={p50}s p95={p95}s max={lat[-1] if lat else None}s wall={wall}s", p50=p50, p95=p95,
           errors=len(errs), n=n, error_kinds=sorted({str(e.get('err') or e.get('status')) for e in errs}))


def run_midrun(c: Client, prefix: str) -> None:
    """Restart `serve` while a long turn (copiloto-asesor, several mimo-flash calls) is in flight: once with SIGTERM and the shutdown grace
    (`podman restart`, the in-flight turn should finish), once with SIGKILL (`podman kill`, the turn dies). Then the SAME run must be readable
    and accept another turn: a run is resumed or closed with a defined outcome, never left corrupted."""
    import subprocess
    import threading

    name = pl.container_name(prefix, "agent-core")
    for mode in ("sigterm", "sigkill"):
        said: list[str] = []
        principal, delegation = c.issuer.advisor(f"adv-mid-{mode}", CUSTOMER)
        extra = {"X-On-Behalf-Of": delegation}
        transport = lambda m, p, h, b: c.call(m, p, body=b, headers=dict(h))  # noqa: E731
        chat = ChatSession(transport=transport, ids=c.ids, token=lambda: principal, step_up_token=None, agent="copiloto-asesor", out=said.append,
                           ask=lambda _: "s", extra_headers=extra)
        chat.start()
        if chat.run_id is None:
            record(f"restart mid-run ({mode})", "fail", "no run")
            continue
        n0 = len(said)
        t0 = time.time()
        th = threading.Thread(target=lambda: chat.say("¿cuánto debe en la tarjeta?"))
        th.start()
        time.sleep(5)
        cmd = ["podman", "restart", "--time", "40", name] if mode == "sigterm" else ["podman", "kill", name]
        subprocess.run(cmd, capture_output=True)
        if mode == "sigkill":
            subprocess.run(["podman", "start", name], capture_output=True)
        th.join(timeout=120)
        inflight = " ".join(said[n0:])
        finished = re.search(r"1342[.,]8", inflight) is not None
        up = None
        t1 = time.time()
        while time.time() - t1 < 120:
            if c.call("GET", "/readyz")[0] == 200:
                up = round(time.time() - t1, 1)
                break
            time.sleep(2)
        st, summary = c.call("GET", f"/v1/runs/{chat.run_id}", principal, headers=extra)
        blocked, accepted_after = 0, None
        t2 = time.time()
        while time.time() - t2 < 150:
            code, body = c.call("POST", f"/v1/sessions/{chat.session_id}/turns", principal,
                                {"text": "¿y el cupo de la tarjeta?", "channel": "web", "client_turn_id": c.ids.new_id(IdKind.turn)}, extra)
            if code == 200:
                accepted_after = round(time.time() - t2, 1)
                break
            blocked += code == 409
            time.sleep(5)
        record(f"restart mid-run ({mode}): same run readable and accepts another turn", "pass" if st == 200 and accepted_after is not None else "fail",
               f"inflight_turn_finished={finished} readyz_after={up}s run_http={st} run_status={summary.get('status')} next_turn_accepted_after={accepted_after}s "
               f"(409 turn_in_progress x{blocked} until the dead turn's lease expires)", inflight_finished=finished, run_status=summary.get("status"),
               next_turn_after_s=accepted_after, blocked_409=blocked)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--prefix", default="prodlike")
    ap.add_argument("--only", default="turns,registry,export,load")
    ap.add_argument("--n", type=int, default=20)
    ap.add_argument("--match", default="", help="turns: only the cases whose name contains this text")
    ap.add_argument("--out", help="write the results as JSON here")
    a = ap.parse_args()
    ports = pl.port_map(a.prefix)
    c = Client(f"http://127.0.0.1:{ports[('agent-core', 8001)]}")
    todo = set(a.only.split(","))
    if "turns" in todo:
        run_turns(c, a.match)
    if "registry" in todo:
        run_registry(c, a.prefix)
    if "export" in todo:
        run_export(c)
    if "load" in todo:
        run_load(c, a.n, "fraud")
    if "midrun" in todo:
        run_midrun(c, a.prefix)
    if "loadllm" in todo:
        run_load(c, a.n, "copilot")
    if a.out:
        Path(a.out).write_text(json.dumps(RESULTS, indent=1), encoding="utf-8")
    failed = [r for r in RESULTS if r["status"] == "fail"]
    print(f"\n{len(RESULTS) - len(failed)} pass, {len(failed)} fail")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
