"""DOUBLE of the support-platform grant endpoint, for the local rehearsal only (the platform image does not exist yet).

agent-core `serve` calls `GET {AGENTCORE_GRANTS_URL}/api/v1/internal/grants/<ref>` with `Authorization: Bearer <AGENTCORE_GRANTS_TOKEN>` and
reads `{"active": true|false}`. This stub answers active for every grant reference that is not listed in /grants/revoked (one ref per
line, optional) when the bearer is right, and 401 otherwise. `GET /` answers 200 so a reader can tell it is up. It exists only as
service `platform` of the rendered core stack, with the network alias `platform.<private zone>`, and `render` reports it as a
deviation. It must never be used where a real platform decision matters (a revocation is only seen if you list it).
"""

import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

TOKEN = os.environ["GRANTS_TOKEN"]
REVOKED = Path("/grants/revoked")
PREFIX = "/api/v1/internal/grants/"


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/", "/healthz"):
            return self._send(200, {"stub": "platform grants double"})
        if self.headers.get("Authorization") != f"Bearer {TOKEN}" or not self.path.startswith(PREFIX):
            return self._send(401, {"error": "unauthorized"})
        ref = self.path[len(PREFIX):]
        revoked = set(REVOKED.read_text(encoding="utf-8").split()) if REVOKED.exists() else set()
        self._send(200, {"active": ref not in revoked})

    def log_message(self, *args: object) -> None:  # no access log
        return


HTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
