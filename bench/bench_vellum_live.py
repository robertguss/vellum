#!/usr/bin/env python3
"""Live 8-worker `mo serve` concurrency, SSE fanout, request-budget, and integrity benchmark for Vellum."""
import base64
from concurrent.futures import ThreadPoolExecutor
from http.cookiejar import CookieJar
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


def pick_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def make_unsigned_jwt(claims: dict) -> str:
    hdr = b64url(json.dumps({"alg": "none", "typ": "JWT"}, separators=(",", ":")).encode("utf-8"))
    pay = b64url(json.dumps(claims, separators=(",", ":")).encode("utf-8"))
    return f"{hdr}.{pay}.test_sig"


class MockAuthAndEmbedServer:
    """In-process HTTP mock for Dex/OIDC PKCE + OpenAI `/v1/embeddings`."""

    def __init__(self, port: int):
        self.port = port
        self.lock = threading.Lock()
        self.nonces: dict[str, str] = {}
        self.embed_calls = 0
        self.httpd: ThreadingHTTPServer | None = None
        self.thread: threading.Thread | None = None

    def start(self):
        parent = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, format, *args):
                return

            def do_GET(self):
                parsed = urllib.parse.urlparse(self.path)
                if parsed.path == "/oidc/authorize":
                    qs = urllib.parse.parse_qs(parsed.query)
                    state = qs.get("state", [""])[0]
                    nonce = qs.get("nonce", [""])[0]
                    redir = qs.get("redirect_uri", [""])[0]
                    with parent.lock:
                        parent.nonces["last"] = nonce
                        if state:
                            parent.nonces[state] = nonce
                    sep = "&" if "?" in redir else "?"
                    loc = f"{redir}{sep}code=bench-code-1&state={urllib.parse.quote(state)}"
                    self.send_response(302)
                    self.send_header("Location", loc)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if parsed.path == "/oidc/userinfo":
                    body = json.dumps(
                        {
                            "sub": "sub_bench_ada",
                            "email": "ada@acme.io",
                            "email_verified": True,
                            "name": "Ada Bench",
                        }
                    ).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length) if length > 0 else b""
                parsed = urllib.parse.urlparse(self.path)
                if parsed.path == "/oidc/token":
                    with parent.lock:
                        nonce = parent.nonces.get("last", "")
                    jwt_tok = make_unsigned_jwt(
                        {
                            "iss": f"http://127.0.0.1:{parent.port}/oidc",
                            "aud": "vellum-bench",
                            "sub": "sub_bench_ada",
                            "nonce": nonce,
                            "exp": int(time.time()) + 7200,
                            "email": "ada@acme.io",
                            "email_verified": True,
                        }
                    )
                    body = json.dumps(
                        {
                            "access_token": "at-bench-1",
                            "token_type": "Bearer",
                            "id_token": jwt_tok,
                        }
                    ).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return

                if parsed.path == "/v1/embeddings":
                    req_json = json.loads(raw.decode("utf-8"))
                    dims = int(req_json.get("dimensions", 256))
                    txt = str(req_json.get("input", "")).lower()
                    vec = [0.0] * dims
                    if any(w in txt for w in ("gateway", "quorum", "runbook", "credential", "renewal", "rotation")):
                        vec[0] = 1.0
                    elif any(w in txt for w in ("database", "rollup", "task", "kanban")):
                        vec[1] = 1.0
                    else:
                        vec[2] = 1.0
                    with parent.lock:
                        parent.embed_calls += 1
                    body = json.dumps(
                        {"object": "list", "data": [{"object": "embedding", "index": 0, "embedding": vec}]}
                    ).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return

                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()

        self.httpd = ThreadingHTTPServer(("127.0.0.1", self.port), Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def stop(self):
        if self.httpd is not None:
            self.httpd.shutdown()
            self.httpd.server_close()


class HttpClient:
    def __init__(self, base: str, bearer: str | None = None):
        self.base = base
        self.bearer = bearer
        self.jar = CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))

    def _xsrf(self) -> str | None:
        for c in self.jar:
            if c.name == "XSRF-TOKEN":
                return urllib.parse.unquote(c.value)
        return None

    def req(self, method: str, path: str, body=None, headers=None, timeout: float = 30.0):
        hdrs = {"Accept": "application/json"}
        if self.bearer:
            hdrs["Authorization"] = f"Bearer {self.bearer}"
        elif method.upper() not in ("GET", "HEAD", "OPTIONS"):
            xsrf = self._xsrf()
            if xsrf:
                hdrs["X-XSRF-TOKEN"] = xsrf
        if headers:
            hdrs.update(headers)
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            hdrs["Content-Type"] = "application/json"
        r = urllib.request.Request(f"{self.base}{path}", data=data, headers=hdrs, method=method)
        t0 = time.perf_counter()
        try:
            with self.opener.open(r, timeout=timeout) as resp:
                raw = resp.read().decode("utf-8")
                dt_ms = (time.perf_counter() - t0) * 1000.0
                return resp.status, (json.loads(raw) if raw else None), dt_ms
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", errors="replace")
            dt_ms = (time.perf_counter() - t0) * 1000.0
            try:
                parsed = json.loads(raw) if raw else None
            except json.JSONDecodeError:
                parsed = raw
            return e.code, parsed, dt_ms

    def oidc_login(self):
        # Follow full /auth/oidc/login -> mock /oidc/authorize -> /auth/oidc/callback -> /
        r = urllib.request.Request(f"{self.base}/auth/oidc/login?return_to=/", method="GET")
        with self.opener.open(r, timeout=15.0) as resp:
            _ = resp.read()
            assert resp.status == 200, resp.status


def pct(samples: list[float], p: float) -> float:
    if not samples:
        return 0.0
    s = sorted(samples)
    idx = min(len(s) - 1, int(len(s) * p))
    return s[idx]


def make_large_md(target_kb: int) -> str:
    unit = (
        "## Operational Section\n\n"
        "Verify gateway healthz, quorum consensus, and MoDB page compaction before key rotation.\n\n"
        "- Confirm S3 upload integrity\n"
        "- Check change proposal diff buckets\n\n"
        "> [!info]\n> Agent proposals stage isolated copy-on-write buckets.\n\n"
    )
    reps = max(1, (target_kb * 1024) // len(unit.encode("utf-8")) + 1)
    chunks = [f"# Batch {i}\n\n{unit}" for i in range(reps)]
    return "".join(chunks)


def main() -> int:
    mo_bin = sys.argv[1] if len(sys.argv) > 1 else shutil.which("mo") or "mo"
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    main_mo = os.path.join(repo_root, "main.mo")
    bench_hot_mo = os.path.join(repo_root, "bench", "bench-vellum-hotpaths.mo")

    mock_port = pick_free_port()
    srv_port = pick_free_port()
    base = f"http://127.0.0.1:{srv_port}"
    mock = MockAuthAndEmbedServer(mock_port)
    mock.start()

    with tempfile.TemporaryDirectory(prefix="vellum-live-bench-") as tmp:
        src_pub = os.path.join(repo_root, "public")
        dst_pub = os.path.join(tmp, "public")
        if os.path.isfile(os.path.join(src_pub, "manifest.json")):
            shutil.copytree(src_pub, dst_pub)
        else:
            os.makedirs(os.path.join(dst_pub, "assets"), exist_ok=True)
            with open(os.path.join(dst_pub, "manifest.json"), "w", encoding="utf-8") as fh:
                json.dump(
                    {
                        "src/main.tsx": {
                            "file": "assets/main-bench.js",
                            "css": ["assets/main-bench.css"],
                            "isEntry": True,
                        }
                    },
                    fh,
                )
            open(os.path.join(dst_pub, "assets", "main-bench.js"), "w").write("console.log('bench');")
            open(os.path.join(dst_pub, "assets", "main-bench.css"), "w").write("body{margin:0}")

        env = os.environ.copy()
        env["VELLUM_SECRET_KEY"] = "1111111111111111111111111111111122222222222222222222222222222222"
        env["VELLUM_INSECURE_COOKIES"] = "1"
        env.pop("VELLUM_VITE_DEV_URL", None)
        env["VELLUM_OIDC_PROVIDER_ID"] = "bench-oidc"
        env["VELLUM_OIDC_CLIENT_ID"] = "vellum-bench"
        env["VELLUM_OIDC_CLIENT_SECRET"] = "bench-oidc-secret"
        env["VELLUM_OIDC_REDIRECT_URI"] = f"{base}/auth/oidc/callback"
        env["VELLUM_OIDC_ISSUER"] = f"http://127.0.0.1:{mock_port}/oidc"
        env["VELLUM_OIDC_AUTH_URL"] = f"http://127.0.0.1:{mock_port}/oidc/authorize"
        env["VELLUM_OIDC_TOKEN_URL"] = f"http://127.0.0.1:{mock_port}/oidc/token"
        env["VELLUM_OIDC_USERINFO_URL"] = f"http://127.0.0.1:{mock_port}/oidc/userinfo"
        env["VELLUM_OIDC_ALLOWED_DOMAINS"] = "acme.io"
        env["VELLUM_OIDC_REQUIRE_VERIFIED_EMAIL"] = "1"
        env["VELLUM_AI_API_KEY"] = "bench-embed-key"
        env["VELLUM_EMBED_API_KEY"] = "bench-embed-key"
        env["VELLUM_EMBED_BASE_URL"] = f"http://127.0.0.1:{mock_port}/v1/embeddings"
        env["VELLUM_EMBED_MODEL"] = "text-embedding-3-small"
        env["VELLUM_EMBED_DIMENSIONS"] = "256"

        ready_file = os.path.join(tmp, "ready.json")
        log_path = os.path.join(tmp, "mo-serve.log")
        log_fh = open(log_path, "w", encoding="utf-8")
        proc = subprocess.Popen(
            [
                mo_bin,
                "serve",
                main_mo,
                "--bind",
                "127.0.0.1",
                "--port",
                str(srv_port),
                "--workers",
                "8",
                "--data",
                tmp,
                "--ready-file",
                ready_file,
            ],
            stdout=log_fh,
            stderr=log_fh,
            text=True,
            env=env,
        )

        try:
            deadline = time.monotonic() + 30.0
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    raise RuntimeError(f"mo serve exited early ({proc.returncode}):\n{open(log_path).read()}")
                if os.path.isfile(ready_file):
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError("Timed out waiting for mo serve --ready-file")

            print("=== Vellum 8-Worker Live Concurrency & Scale Benchmark ===")
            owner = HttpClient(base)
            owner.oidc_login()

            # 1. Seed 5 collections + 24 pages + 50 database rows
            col_ids: list[str] = []
            for ci in range(5):
                st, body, _ = owner.req(
                    "POST",
                    "/api/collections",
                    {
                        "slug": f"bench-ops-{ci}",
                        "name": f"Bench Ops {ci}",
                        "description": None,
                        "icon": None,
                        "write_policy": "direct_with_audit",
                        "freshness_ttl_days": 90,
                    },
                )
                assert st == 201, (st, body)
                col_ids.append(body["id"])

            page_ids: list[str] = []
            block_ids: dict[str, str] = {}
            seed_t0 = time.perf_counter()
            for pi in range(24):
                cid = col_ids[pi % len(col_ids)]
                topic = "Gateway Runbook" if pi % 2 == 0 else "Cluster Telemetry"
                md = (
                    f"## {topic} #{pi}\n\n"
                    "Verify gateway healthz, quorum consensus, and key rotation safeguards."
                )
                st, body, _ = owner.req(
                    "POST",
                    "/api/pages",
                    {
                        "collection_id": cid,
                        "parent_page_id": None,
                        "title": f"{topic} #{pi}",
                        "markdown": md,
                        "icon": None,
                        "freshness_ttl_days": None,
                        "reason": "bench seed",
                    },
                )
                assert st == 201, (st, body)
                pid = body["page"]["id"]
                page_ids.append(pid)
                block_ids[pid] = body["blocks"][0]["id"]
            seed_ms = (time.perf_counter() - seed_t0) * 1000.0

            # Poll until arvo.jobs.drain completes neural indexing for initial 24 pages
            neural_ready = False
            poll_end = time.monotonic() + 20.0
            while time.monotonic() < poll_end:
                st, body, _ = owner.req("GET", "/api/search?q=credential+renewal&mode=semantic&limit=10")
                if st == 200 and body and body.get("vector_backend") == "neural" and len(body.get("results", [])) > 0:
                    neural_ready = True
                    break
                time.sleep(0.4)
            assert neural_ready, "Timed out waiting for arvo.jobs.drain to populate 256-d neural index"

            # Create a relational DB with 50 rows in col_ids[0]
            st, db_body, _ = owner.req(
                "POST",
                "/api/databases",
                {
                    "collection_id": col_ids[0],
                    "parent_page_id": None,
                    "title": "Bench Incidents",
                    "description": None,
                    "properties": [
                        {"id": "title", "name": "Title", "kind": "title", "required": True, "sort_order": "a"},
                        {
                            "id": "severity",
                            "name": "Severity",
                            "kind": {
                                "select": {
                                    "options": [
                                        {"id": "sev1", "label": "Sev1", "color": "red"},
                                        {"id": "sev2", "label": "Sev2", "color": "amber"},
                                    ]
                                }
                            },
                            "required": False,
                            "sort_order": "b",
                        },
                        {"id": "cost", "name": "Cost", "kind": {"number": {"format": "currency"}}, "required": False, "sort_order": "c"},
                    ],
                },
            )
            assert st == 201, (st, db_body)
            db_id = db_body["database"]["id"]

            db_seed_t0 = time.perf_counter()
            for ri in range(50):
                st, rbody, _ = owner.req(
                    "POST",
                    f"/api/databases/{db_id}/rows",
                    {
                        "cells": {
                            "title": {"text_val": f"Bench Incident #{ri}"},
                            "severity": {"select_val": {"option_id": "sev1" if ri % 2 == 0 else "sev2"}},
                            "cost": {"number_val": f"{(ri + 1) * 1.25:.2f}"},
                        },
                        "markdown": None,
                        "reason": "bench db seed",
                    },
                )
                assert st == 201, (st, rbody)
            db_seed_ms = (time.perf_counter() - db_seed_t0) * 1000.0

            # Mint 6 scoped agents (4 readers across all 5 collections, 2 writers)
            agent_tokens: list[str] = []
            for ai in range(6):
                st, abody, _ = owner.req(
                    "POST",
                    "/api/admin/agents",
                    {
                        "handle": f"bench-ag-{ai}",
                        "display_name": f"Bench Agent {ai}",
                        "model_id": "gpt-4o-mini",
                        "label": f"bench-{ai}",
                        "allowed_actions": ["read", "write_direct", "propose", "publish", "write_db", "claim"],
                        "allowed_collections": col_ids,
                        "max_calls": 5000,
                        "ttl_days": 7,
                    },
                )
                assert st == 201, (st, abody)
                agent_tokens.append(abody["raw_token"])

            print(
                f"Seeded 5 collections, 24 pages ({seed_ms:.0f} ms, {seed_ms/24:.1f} ms/page), "
                f"50 DB rows ({db_seed_ms:.0f} ms, {db_seed_ms/50:.1f} ms/row), neural_backend=ready"
            )

            # Phase A: Pure 8-Thread Read Burst (400 requests across 8 workers)
            lock = threading.Lock()
            by_kind: dict[str, list[float]] = {
                "page_get": [],
                "search_bm25": [],
                "search_hybrid": [],
                "search_semantic": [],
                "db_query": [],
            }
            all_read_lats: list[float] = []
            read_errs: list[tuple[str, int, object]] = []

            def phase_a_worker(wid: int):
                cl = HttpClient(base, bearer=agent_tokens[wid % len(agent_tokens)])
                local_all = []
                local_by: dict[str, list[float]] = {k: [] for k in by_kind}
                local_errs = []
                for j in range(50):
                    slot = (wid + j) % 5
                    if slot == 0:
                        k = "page_get"
                        pid = page_ids[(wid * 7 + j) % len(page_ids)]
                        st, _, dt = cl.req("GET", f"/api/pages/{pid}")
                    elif slot == 1:
                        k = "search_bm25"
                        st, _, dt = cl.req("GET", "/api/search?q=quorum+rotation&mode=bm25&limit=10")
                    elif slot == 2:
                        k = "search_hybrid"
                        st, _, dt = cl.req("GET", "/api/search?q=credential+renewal&mode=hybrid&limit=10")
                    elif slot == 3:
                        k = "search_semantic"
                        st, _, dt = cl.req("GET", "/api/search?q=credential+renewal&mode=semantic&limit=10")
                    else:
                        k = "db_query"
                        st, _, dt = cl.req(
                            "POST",
                            f"/api/databases/{db_id}/query",
                            {
                                "view_id": None,
                                "filters": [{"prop_id": "severity", "op": "eq", "value": "sev1"}],
                                "filter_match_all": True,
                                "sorts": [],
                                "from_date": None,
                                "to_date": None,
                            },
                        )
                    if st == 200:
                        local_all.append(dt)
                        local_by[k].append(dt)
                    else:
                        local_errs.append((k, st, dt))
                with lock:
                    all_read_lats.extend(local_all)
                    for k, vals in local_by.items():
                        by_kind[k].extend(vals)
                    read_errs.extend(local_errs)

            ta0 = time.perf_counter()
            with ThreadPoolExecutor(max_workers=8) as pool:
                for f in [pool.submit(phase_a_worker, w) for w in range(8)]:
                    f.result()
            ta_s = time.perf_counter() - ta0
            assert not read_errs, f"Phase A errors: {read_errs[:5]}"
            print(
                f"Phase A (8-thread read burst, {len(all_read_lats)} reqs in {ta_s:.2f}s): "
                f"{len(all_read_lats)/ta_s:.1f} req/s | "
                f"p50={pct(all_read_lats, 0.5):.1f}ms p95={pct(all_read_lats, 0.95):.1f}ms p99={pct(all_read_lats, 0.99):.1f}ms max={max(all_read_lats):.1f}ms"
            )
            for k, vals in by_kind.items():
                print(
                    f"  {k:15s}: n={len(vals):3d} p50={pct(vals, 0.5):5.1f}ms p95={pct(vals, 0.95):5.1f}ms max={max(vals):5.1f}ms"
                )

            # Phase B: Mixed Multi-Actor Concurrency + 2 Live SSE Clients + /mcp + Claims + Proposals
            sse_stop = threading.Event()
            sse_events: dict[int, list[str]] = {0: [], 1: []}
            sse_ready = threading.Event()

            def sse_reader(cid_idx: int, col_id: str, tok: str):
                req = urllib.request.Request(
                    f"{base}/api/events?collection_id={col_id}",
                    headers={"Accept": "text/event-stream", "Authorization": f"Bearer {tok}"},
                )
                try:
                    with urllib.request.urlopen(req, timeout=30.0) as resp:
                        buf = ""
                        while not sse_stop.is_set():
                            line_b = resp.readline()
                            if not line_b:
                                break
                            line = line_b.decode("utf-8", errors="replace").rstrip("\r\n")
                            if line.startswith("event:"):
                                ev = line[6:].strip()
                                buf = ev
                                if ev == "connected":
                                    sse_ready.set()
                                elif ev != "":
                                    with lock:
                                        sse_events[cid_idx].append(ev)
                            elif line == "" and buf:
                                buf = ""
                except Exception:
                    pass

            t_sse0 = threading.Thread(target=sse_reader, args=(0, col_ids[0], agent_tokens[0]), daemon=True)
            t_sse1 = threading.Thread(target=sse_reader, args=(1, col_ids[1], agent_tokens[1]), daemon=True)
            t_sse0.start()
            t_sse1.start()
            assert sse_ready.wait(timeout=10.0), "SSE client did not connect"

            mix_r_lats: list[float] = []
            mix_mcp_lats: list[float] = []
            mix_patch_lats: list[float] = []
            mix_claim_lats: list[float] = []
            mix_prop_lats: list[float] = []
            mix_errs: list[tuple[str, int, object]] = []
            mix_stop = threading.Event()

            def mix_writer(w_idx: int):
                # Use col_ids[w_idx] disjoint pages so writers never collide on versions while hitting both subscribed SSE topics
                cl = HttpClient(base, bearer=agent_tokens[4 + w_idx])
                target_pages = [pid for pid in page_ids if page_ids.index(pid) % 5 == w_idx]
                local_errs = []

                # Track each page's block version safely
                blk_ver: dict[str, int] = {}
                for pid in target_pages:
                    st, pb, _ = cl.req("GET", f"/api/pages/{pid}")
                    assert st == 200
                    blk_ver[pid] = pb["blocks"][0]["version"]

                for step in range(10):
                    pid = target_pages[step % len(target_pages)]
                    bid = block_ids[pid]
                    ver = blk_ver[pid]
                    # 1) Claim acquire -> heartbeat -> release
                    res_key = f"page:{pid}"
                    st1, b1, dt1 = cl.req(
                        "POST",
                        "/api/claims",
                        {"resource": res_key, "ttl_seconds": 30, "world_id": None, "reason": "bench edit"},
                    )
                    if st1 == 201:
                        with lock:
                            mix_claim_lats.append(dt1)
                    else:
                        local_errs.append(("claim_acq", st1, b1))

                    st2, b2, dt2 = cl.req(
                        "POST", "/api/claims/heartbeat", {"resource": res_key, "ttl_seconds": 30}
                    )
                    if st2 == 200:
                        with lock:
                            mix_claim_lats.append(dt2)
                    else:
                        local_errs.append(("claim_hb", st2, b2))

                    # 2) Surgical PatchBlocks
                    st3, b3, dt3 = cl.req(
                        "PATCH",
                        f"/api/pages/{pid}/blocks",
                        {
                            "ops": [
                                {
                                    "replace_block": {
                                        "block_id": bid,
                                        "expected_version": ver,
                                        "kind": None,
                                        "markdown": f"Verify gateway healthz, quorum, step={step} writer={w_idx}.",
                                    }
                                }
                            ],
                            "expected_versions": {bid: ver},
                            "reason": "bench patch",
                        },
                    )
                    if st3 == 200:
                        blk_ver[pid] = b3["blocks"][0]["version"]
                        with lock:
                            mix_patch_lats.append(dt3)
                    else:
                        local_errs.append(("patch_blocks", st3, b3))

                    st4, b4, dt4 = cl.req("POST", "/api/claims/release", {"resource": res_key})
                    if st4 == 200:
                        with lock:
                            mix_claim_lats.append(dt4)
                    else:
                        local_errs.append(("claim_rel", st4, b4))

                    # 3) Every other iteration run full Modb.World Proposal open -> stage -> diff -> accept
                    if step % 2 == 0:
                        cur_v = blk_ver[pid]
                        to_ms = 0.0
                        stp, bp, dtp = cl.req(
                            "POST",
                            "/api/proposals",
                            {"page_id": pid, "title": f"Bench Prop {w_idx}.{step}", "reason": "world bench"},
                        )
                        if stp != 201:
                            local_errs.append(("prop_open", stp, bp))
                            continue
                        to_ms += dtp
                        prop_id = bp["id"]
                        sts, bs, dts = cl.req(
                            "POST",
                            f"/api/proposals/{prop_id}/ops",
                            {
                                "ops": [
                                    {
                                        "replace_block": {
                                            "block_id": bid,
                                            "expected_version": cur_v,
                                            "kind": None,
                                            "markdown": f"Verify gateway healthz, quorum, world={prop_id}.",
                                        }
                                    }
                                ],
                                "expected_versions": {bid: cur_v},
                                "reason": "stage world edit",
                            },
                        )
                        if sts != 200:
                            local_errs.append(("prop_stage", sts, bs))
                            continue
                        to_ms += dts
                        std, bd, dtd = cl.req("GET", f"/api/proposals/{prop_id}/diff")
                        if std != 200:
                            local_errs.append(("prop_diff", std, bd))
                            continue
                        to_ms += dtd
                        sta, ba, dta = cl.req(
                            "POST", f"/api/proposals/{prop_id}/accept", {"reason": "bench accept"}
                        )
                        if sta == 200:
                            to_ms += dta
                            blk_ver[pid] = cur_v + 1
                            with lock:
                                mix_prop_lats.append(to_ms)
                        else:
                            local_errs.append(("prop_accept", sta, ba))

                if local_errs:
                    with lock:
                        mix_errs.extend(local_errs)

            def mix_reader(r_idx: int):
                cl = HttpClient(base, bearer=agent_tokens[r_idx % 4])
                step = 0
                local_r = []
                local_m = []
                local_errs = []
                while not mix_stop.is_set():
                    if step % 3 == 0:
                        st, _, dt = cl.req(
                            "POST",
                            "/mcp",
                            {
                                "jsonrpc": "2.0",
                                "id": step + 1,
                                "method": "tools/call",
                                "params": {
                                    "name": "vellum.search",
                                    "arguments": {"q": "credential renewal", "mode": "hybrid"},
                                },
                            },
                        )
                        if st == 200:
                            local_m.append(dt)
                        else:
                            local_errs.append(("mcp_search", st, dt))
                    elif step % 3 == 1:
                        st, _, dt = cl.req("GET", "/api/search?q=gateway+quorum&mode=hybrid&limit=10")
                        if st == 200:
                            local_r.append(dt)
                        else:
                            local_errs.append(("hyb_search", st, dt))
                    else:
                        pid = page_ids[(r_idx * 5 + step) % len(page_ids)]
                        st, _, dt = cl.req("GET", f"/api/pages/{pid}")
                        if st == 200:
                            local_r.append(dt)
                        else:
                            local_errs.append(("mix_page", st, dt))
                    step += 1
                with lock:
                    mix_r_lats.extend(local_r)
                    mix_mcp_lats.extend(local_m)
                    mix_errs.extend(local_errs)

            tb0 = time.perf_counter()
            with ThreadPoolExecutor(max_workers=6) as pool:
                rfuts = [pool.submit(mix_reader, r) for r in range(4)]
                wfuts = [pool.submit(mix_writer, w) for w in range(2)]
                for f in wfuts:
                    f.result()
                mix_stop.set()
                for f in rfuts:
                    f.result()
            tb_s = time.perf_counter() - tb0
            time.sleep(0.3)
            sse_stop.set()

            assert not mix_errs, f"Phase B errors: {mix_errs[:5]}"
            total_b_reqs = len(mix_r_lats) + len(mix_mcp_lats) + len(mix_patch_lats) + len(mix_claim_lats) + len(mix_prop_lats) * 4
            print(
                f"Phase B (Mixed 4R+2W + 2 live SSE under 8 workers, {total_b_reqs} ops in {tb_s:.2f}s): "
                f"{total_b_reqs/tb_s:.1f} req/s | 0 errors"
            )
            print(
                f"  http_reads (n={len(mix_r_lats)}): p50={pct(mix_r_lats, 0.5):.1f}ms p95={pct(mix_r_lats, 0.95):.1f}ms | "
                f"mcp_search (n={len(mix_mcp_lats)}): p50={pct(mix_mcp_lats, 0.5):.1f}ms p95={pct(mix_mcp_lats, 0.95):.1f}ms"
            )
            print(
                f"  patch_blocks (n={len(mix_patch_lats)}): p50={pct(mix_patch_lats, 0.5):.1f}ms p95={pct(mix_patch_lats, 0.95):.1f}ms | "
                f"claims_ops (n={len(mix_claim_lats)}): p50={pct(mix_claim_lats, 0.5):.1f}ms p95={pct(mix_claim_lats, 0.95):.1f}ms | "
                f"proposal_e2e (n={len(mix_prop_lats)}): p50={pct(mix_prop_lats, 0.5):.1f}ms p95={pct(mix_prop_lats, 0.95):.1f}ms"
            )
            print(
                f"  SSE fanout delivered: col_0={len(sse_events[0])} events, col_1={len(sse_events[1])} events"
            )

            # Phase C: Large-Document HTTP Request Budget Probe (5 / 25 / 50 / 100 / 200 KiB)
            print("Phase C (Large-Doc HTTP Request Budget Probe):")
            for kb in [5, 25, 50, 100, 200]:
                md = make_large_md(kb)
                st_c, b_c, dt_c = owner.req(
                    "POST",
                    "/api/pages",
                    {
                        "collection_id": col_ids[0],
                        "parent_page_id": None,
                        "title": f"Large Doc {kb}KiB",
                        "markdown": md,
                        "icon": None,
                        "freshness_ttl_days": None,
                        "reason": f"budget probe {kb}k",
                    },
                    timeout=60.0,
                )
                if st_c == 201 and isinstance(b_c, dict):
                    lpid = b_c["page"]["id"]
                    lblk = b_c["blocks"][0]["id"]
                    lver = b_c["blocks"][0]["version"]
                    st_g, _, dt_g = owner.req("GET", f"/api/pages/{lpid}", timeout=60.0)
                    st_p, _, dt_p = owner.req(
                        "PATCH",
                        f"/api/pages/{lpid}/blocks",
                        {
                            "ops": [
                                {
                                    "replace_block": {
                                        "block_id": lblk,
                                        "expected_version": lver,
                                        "kind": None,
                                        "markdown": "## Updated Heading Large Doc",
                                    }
                                }
                            ],
                            "expected_versions": {lblk: lver},
                            "reason": "patch large doc",
                        },
                        timeout=60.0,
                    )
                    print(
                        f"  {kb:3d} KiB ({len(md.encode('utf-8')):6d} B, {len(b_c['blocks']):4d} blks): "
                        f"POST={st_c} ({dt_c:.1f}ms) | GET={st_g} ({dt_g:.1f}ms) | PATCH={st_p} ({dt_p:.1f}ms)"
                    )
                else:
                    msg = b_c if isinstance(b_c, str) else json.dumps(b_c)[:160]
                    print(f"  {kb:3d} KiB ({len(md.encode('utf-8')):6d} B): POST={st_c} ({dt_c:.1f}ms) err={msg}")

            # Phase D: Audit endpoint check + Graceful shutdown + Ledger.verify_all post-load verification
            st_au, _, dt_au = owner.req("GET", "/api/audit?limit=25")
            assert st_au == 200, st_au
            print(f"Phase D: /api/audit status=200 ({dt_au:.1f}ms), shutting down mo serve for Ledger.verify_all...")
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            log_fh.close()
            mock.stop()

        ver = subprocess.run(
            [mo_bin, "run", "--root", tmp, bench_hot_mo, "--verify-only"],
            capture_output=True,
            text=True,
            check=False,
        )
        assert ver.returncode == 0, f"Post-load Ledger.verify_all failed:\n{ver.stdout}\n{ver.stderr}"
        print(f"Phase D: {ver.stdout.strip()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
