#!/usr/bin/env python3
"""OpenAI-compatible shim in front of Vertex AI, for Honcho.

WHY THIS EXISTS
===============
Honcho has no Vertex transport (``ModelTransport = Literal["anthropic",
"openai", "gemini"]``), so the only way to bill Honcho's reasoning to the GCP
project is to point its ``openai`` transport at an OpenAI-compatible endpoint.
Vertex publishes one — but two things block using it directly:

1. **Auth expires.** Vertex wants an OAuth bearer token that lives ~1 hour.
   Honcho takes a *static* ``api_key`` / ``api_key_env``. The alternative
   (rewrite the token and restart the containers every 45 min) means a hard
   restart loop forever. This proxy instead mints a fresh token from the
   metadata server per request, with caching — no restarts, no expiry.

2. **Vertex's OpenAI-compat /embeddings endpoint is broken.** Verified
   2026-07-28: it returns HTTP 500 "Internal error encountered" for *every*
   model name tried (gemini-embedding-001, text-embedding-004/005, with and
   without the ``google/`` prefix, in both ``global`` and ``europe-west2``).
   The *native* Vertex embeddings API works fine on the same models
   (gemini-embedding-001 -> 3072 dims, text-embedding-005 -> 768). So this
   proxy translates OpenAI ``/v1/embeddings`` into Vertex ``:predict`` and
   converts the response back.

Chat completions are a transparent pass-through (streaming included); only auth
is added. Embeddings are translated.

SECURITY
========
Binds to 0.0.0.0 so Honcho's containers can reach it over the compose bridge
gateway. Acceptable ONLY because this VM has no external IP and the firewall
admits nothing but Google's IAP range. There is no auth on this proxy — it
would hand out Vertex access to anything that can reach it. Never run it on a
host with a public IP, and never open its port in the firewall.

Python stdlib only, deliberately: no pip install, nothing to keep upgraded.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROJECT = os.environ.get("VERTEX_PROJECT", "")
LOCATION = os.environ.get("VERTEX_LOCATION", "global")
EMBED_LOCATION = os.environ.get("VERTEX_EMBED_LOCATION", "europe-west2")
EMBED_DIMS = int(os.environ.get("VERTEX_EMBED_DIMENSIONS", "1536"))
PORT = int(os.environ.get("PROXY_PORT", "8900"))
BIND = os.environ.get("PROXY_BIND", "0.0.0.0")

METADATA_TOKEN_URL = (
    "http://metadata.google.internal/computeMetadata/v1/"
    "instance/service-accounts/default/token"
)

if not PROJECT:
    sys.exit("VERTEX_PROJECT must be set")


def _host(location: str) -> str:
    """Vertex hostname for a location. ``global`` has no region prefix."""
    return (
        "aiplatform.googleapis.com"
        if location == "global"
        else f"{location}-aiplatform.googleapis.com"
    )


class TokenCache:
    """Fetch and cache the VM's service-account OAuth token.

    Refreshes 5 minutes before expiry so an in-flight request never races the
    boundary. This is the whole reason the proxy exists rather than a
    token-refresh timer plus container restarts.
    """

    def __init__(self) -> None:
        self._token = ""
        self._expires_at = 0.0
        self._lock = threading.Lock()

    def get(self) -> str:
        with self._lock:
            if self._token and time.time() < self._expires_at:
                return self._token
            req = urllib.request.Request(
                METADATA_TOKEN_URL, headers={"Metadata-Flavor": "Google"}
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.load(resp)
            self._token = data["access_token"]
            self._expires_at = time.time() + max(60, int(data.get("expires_in", 3600)) - 300)
            return self._token


TOKENS = TokenCache()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "vertex-openai-proxy/1.0"

    def log_message(self, fmt: str, *args) -> None:  # noqa: D102
        # journald already timestamps; keep one compact line per request.
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    # -- helpers ----------------------------------------------------------
    def _read_body(self) -> bytes:
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, status: int, message: str) -> None:
        # Shaped like an OpenAI error so the client surfaces something useful.
        self._send_json(status, {"error": {"message": message, "type": "proxy_error"}})

    # -- routing ----------------------------------------------------------
    def do_GET(self) -> None:  # noqa: N802
        if self.path.rstrip("/") in ("/health", "/healthz"):
            self._send_json(200, {"status": "ok", "project": PROJECT, "location": LOCATION})
        elif self.path.rstrip("/").endswith("/models"):
            # Some clients probe /v1/models on startup. Vertex has no discovery
            # route, so answer with an empty-but-valid list rather than 404.
            self._send_json(200, {"object": "list", "data": []})
        else:
            self._error(404, f"no route for GET {self.path}")

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.rstrip("/")
        try:
            if path.endswith("/chat/completions"):
                self._chat()
            elif path.endswith("/embeddings"):
                self._embeddings()
            else:
                self._error(404, f"no route for POST {self.path}")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:800]
            self._error(exc.code, f"vertex returned {exc.code}: {detail}")
        except Exception as exc:  # noqa: BLE001 — never kill the server on one request
            self._error(502, f"proxy failure: {exc}")

    # -- chat: transparent pass-through, auth injected --------------------
    def _chat(self) -> None:
        body = self._read_body()
        url = (
            f"https://{_host(LOCATION)}/v1/projects/{PROJECT}"
            f"/locations/{LOCATION}/endpoints/openapi/chat/completions"
        )
        req = urllib.request.Request(
            url,
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {TOKENS.get()}",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=600) as resp:
            ctype = resp.headers.get("Content-Type", "application/json")
            self.send_response(resp.status)
            self.send_header("Content-Type", ctype)
            # Stream rather than buffer: SSE responses must not be collected
            # first, or the client sees nothing until generation completes.
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                self.wfile.write(b"%X\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()

    # -- embeddings: OpenAI shape -> Vertex :predict ----------------------
    def _embeddings(self) -> None:
        payload = json.loads(self._read_body() or b"{}")
        raw_input = payload.get("input", "")
        inputs = [raw_input] if isinstance(raw_input, str) else list(raw_input)
        if not inputs:
            return self._error(400, "embeddings request had empty 'input'")

        # Honcho may send "google/gemini-embedding-001"; Vertex's native route
        # wants the bare publisher model id.
        model = (payload.get("model") or "gemini-embedding-001").split("/")[-1]

        # Dimensionality MUST match Honcho's pgvector column width
        # (EMBEDDING_VECTOR_DIMENSIONS, default 1536). gemini-embedding-001
        # returns 3072 unless outputDimensionality is requested, which would
        # make every insert fail on a dimension mismatch.
        dims = int(payload.get("dimensions") or EMBED_DIMS)

        url = (
            f"https://{_host(EMBED_LOCATION)}/v1/projects/{PROJECT}"
            f"/locations/{EMBED_LOCATION}/publishers/google/models/{model}:predict"
        )
        vertex_req = {
            "instances": [{"content": text} for text in inputs],
            "parameters": {"outputDimensionality": dims},
        }
        req = urllib.request.Request(
            url,
            data=json.dumps(vertex_req).encode(),
            method="POST",
            headers={
                "Authorization": f"Bearer {TOKENS.get()}",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=120) as resp:
            vertex_resp = json.load(resp)

        data = []
        for i, pred in enumerate(vertex_resp.get("predictions", [])):
            values = (pred.get("embeddings") or {}).get("values") or []
            data.append({"object": "embedding", "index": i, "embedding": values})
        if not data:
            return self._error(502, f"vertex returned no predictions: {str(vertex_resp)[:300]}")

        total = sum(
            (p.get("embeddings", {}).get("statistics", {}) or {}).get("token_count", 0) or 0
            for p in vertex_resp.get("predictions", [])
        )
        self._send_json(
            200,
            {
                "object": "list",
                "data": data,
                "model": model,
                "usage": {"prompt_tokens": total, "total_tokens": total},
            },
        )


def main() -> None:
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    server.daemon_threads = True
    sys.stderr.write(
        f"vertex-openai-proxy listening on {BIND}:{PORT} "
        f"(project={PROJECT} chat={LOCATION} embed={EMBED_LOCATION} dims={EMBED_DIMS})\n"
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
