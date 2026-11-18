"""Coder workspace check for agentgateway's LLM routes (extAuthz, HTTP protocol).

agentgateway forwards each LLM request's Authorization / x-api-key header here.
The value is a Coder workspace agent token (the template writes it into the
workspace's coding-tool config). Coder decides whether it belongs to a live
agent in its workspace's latest build: GET /api/v2/workspaceagents/me/external-auth
with no parameters answers 401 for a token Coder doesn't accept, and 400
("'url' or 'id' must be provided") once the token has passed Coder's agent auth.
That endpoint has no side effects and returns no secrets.

Answers: 200 (allowed), 401 (no or unknown token), 503 (Coder unreachable:
agentgateway fails closed). Results are cached per token hash for a short while
so Coder isn't asked on every request; the token itself is never logged.
On success the response carries x-coder-agent (a short hash of the token) for
agentgateway's access log.

Env: CODER_URL (https://dev.<domain>), CACHE_OK_SECONDS (60), CACHE_DENY_SECONDS (10).
"""
import hashlib
import http.client
import http.server
import json
import os
import socketserver
import sys
import threading
import time
import urllib.parse

CODER = urllib.parse.urlsplit(os.environ["CODER_URL"])
OK_TTL = int(os.environ.get("CACHE_OK_SECONDS", "60"))
DENY_TTL = int(os.environ.get("CACHE_DENY_SECONDS", "10"))
cache = {}  # sha256 hex -> (expiry, status)
lock = threading.Lock()


def log(**kw):
    print(json.dumps({"ts": time.strftime("%FT%T"), **kw}), file=sys.stderr, flush=True)


def token_from(headers):
    auth = headers.get("Authorization", "")
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    return (headers.get("x-api-key") or "").strip()


def ask_coder(token):
    conn_cls = http.client.HTTPSConnection if CODER.scheme == "https" else http.client.HTTPConnection
    conn = conn_cls(CODER.netloc, timeout=10)
    try:
        conn.request("GET", "/api/v2/workspaceagents/me/external-auth", headers={"Coder-Session-Token": token})
        status = conn.getresponse().status
    finally:
        conn.close()
    if status == 400:
        return 200
    if status in (401, 403, 404):
        return 401
    raise RuntimeError(f"unexpected status {status} from Coder")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def answer(self, status, agent=None):
        self.send_response(status)
        if agent:
            self.send_header("x-coder-agent", agent)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def handle_any(self):
        token = token_from(self.headers)
        if not token:
            # Logged so a token-less 401 is visible: auth_header says whether
            # an Authorization header came at all (vs. "Bearer " with nothing
            # after it). No header values are logged.
            log(event="no_token", method=self.command,
                auth_header="Authorization" in self.headers,
                api_key_header="x-api-key" in self.headers)
            return self.answer(401)
        key = hashlib.sha256(token.encode()).hexdigest()
        agent = key[:12]
        now = time.time()
        with lock:
            hit = cache.get(key)
        if hit and hit[0] > now:
            return self.answer(hit[1], agent if hit[1] == 200 else None)
        try:
            status = ask_coder(token)
        except Exception as e:  # Coder down or unexpected: fail closed, don't cache
            log(event="coder_error", agent=agent, error=str(e))
            return self.answer(503)
        with lock:
            cache[key] = (now + (OK_TTL if status == 200 else DENY_TTL), status)
            if len(cache) > 10000:
                for k in [k for k, v in cache.items() if v[0] <= now]:
                    del cache[k]
        log(event="checked", agent=agent, allowed=status == 200)
        self.answer(status, agent if status == 200 else None)

    do_GET = do_POST = do_HEAD = handle_any


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    Server(("0.0.0.0", int(os.environ.get("PORT", "8080"))), Handler).serve_forever()
