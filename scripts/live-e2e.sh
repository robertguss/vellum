#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

LIVE_DATA="$(mktemp -d /tmp/vellum-live.XXXXXX)"
SERVE_PID=""
MOCK_LLM_PID=""
SERVE_LOG="$LIVE_DATA/mo-serve.log"

cleanup() {
  if [[ -n "${MOCK_LLM_PID:-}" ]]; then
    kill "$MOCK_LLM_PID" 2>/dev/null || true
    wait "$MOCK_LLM_PID" 2>/dev/null || true
  fi
  if [[ -n "${SERVE_PID:-}" ]]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
  docker compose -f docker-compose.dev.yml down -v >/dev/null 2>&1 || true
  rm -rf "$LIVE_DATA"
}
trap cleanup EXIT

echo "==> Ensuring built Vite frontend assets exist"
if [[ ! -f public/manifest.json ]]; then
  (
    cd frontend
    npm run build
  )
fi
cp -r public "$LIVE_DATA/public"

echo "==> Starting Dex (OIDC) and VersityGW (S3) via docker compose"
docker compose -f docker-compose.dev.yml up -d

for i in $(seq 1 45); do
  if curl -fsS http://127.0.0.1:5556/dex/.well-known/openid-configuration >/dev/null 2>&1 &&
     curl -fsS http://127.0.0.1:9000/health >/dev/null 2>&1; then
    break
  fi
  if [[ "$i" == "45" ]]; then
    echo "Timed out waiting for Dex/S3 health checks" >&2
    docker compose -f docker-compose.dev.yml logs >&2 || true
    exit 1
  fi
  sleep 1
done

echo "==> Starting live mo serve process (4 workers) against $LIVE_DATA"
export VELLUM_SECRET_KEY="1111111111111111111111111111111122222222222222222222222222222222"
export VELLUM_INSECURE_COOKIES="1"
unset VELLUM_VITE_DEV_URL || true
export VELLUM_OIDC_PROVIDER_ID="dex"
export VELLUM_OIDC_CLIENT_ID="vellum-web"
export VELLUM_OIDC_CLIENT_SECRET="vellum-dev-oidc-secret"
export VELLUM_OIDC_REDIRECT_URI="http://127.0.0.1:8080/auth/oidc/callback"
export VELLUM_OIDC_ISSUER="http://127.0.0.1:5556/dex"
export VELLUM_OIDC_AUTH_URL="http://127.0.0.1:5556/dex/auth"
export VELLUM_OIDC_TOKEN_URL="http://127.0.0.1:5556/dex/token"
export VELLUM_OIDC_USERINFO_URL="http://127.0.0.1:5556/dex/userinfo"
export VELLUM_OIDC_ALLOWED_DOMAINS="acme.io"
export VELLUM_OIDC_REQUIRE_VERIFIED_EMAIL="1"
export VELLUM_S3_ENDPOINT="http://127.0.0.1:9000"
export VELLUM_S3_BUCKET="vellum-uploads"
export VELLUM_S3_REGION="us-east-1"
export VELLUM_S3_ACCESS_KEY_ID="vellum"
export VELLUM_S3_SECRET_ACCESS_KEY="vellum-dev-secret-key"
export VELLUM_S3_PATH_STYLE="1"

echo "==> Starting local mock OpenAI SSE server for live streaming Ask Workspace test"
node --input-type=module - "$LIVE_DATA/mock-llm.port" <<'MOCK_EOF' &
import http from "node:http";
import fs from "node:fs";

const portFile = process.argv[2];
let lastBody = null;

const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/_last") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ lastBody }));
    return;
  }
  if (req.method === "POST" && req.url === "/v1/embeddings") {
    if (req.headers.authorization !== "Bearer test-live-vellum-key") {
      res.writeHead(401, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "unauthorized" }));
      return;
    }
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      let body;
      try {
        body = JSON.parse(raw);
      } catch {
        res.writeHead(400);
        res.end("bad json");
        return;
      }
      const dims = Number.isInteger(body.dimensions) && body.dimensions > 0 ? body.dimensions : 8;
      const txt = String(body.input ?? "").toLowerCase();
      const vec = new Array(dims).fill(0);
      const isKeyTopic =
        txt.includes("runbook") ||
        txt.includes("gateway") ||
        txt.includes("quorum") ||
        txt.includes("credential") ||
        txt.includes("renewal") ||
        txt.includes("secret");
      vec[isKeyTopic ? 0 : 1] = 1.0;
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(
        JSON.stringify({
          object: "list",
          data: [{ object: "embedding", index: 0, embedding: vec }],
        })
      );
    });
    return;
  }
  if (req.method === "POST" && req.url === "/v1/chat/completions") {
    if (req.headers.authorization !== "Bearer test-live-vellum-key") {
      res.writeHead(401, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "unauthorized" }));
      return;
    }
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      try {
        lastBody = JSON.parse(raw);
      } catch {
        res.writeHead(400);
        res.end("bad json");
        return;
      }
      if (lastBody.stream !== true) {
        const allText = (lastBody.messages || [])
          .map((m) => String(m.content || ""))
          .join("\n");
        const isSteer = allText.includes(
          "revising a speculative Vellum proposal block in-place"
        );
        const isRlmSub = allText.includes("Vellum RLM Deep Research sub-agent");
        const isRlmSynth = allText.includes("Vellum RLM Deep Research synthesizer");
        const isRlmTier2Plan = allText.includes("Vellum Tier 2 RLM Planner");
        const isRlmTier2Sub = allText.includes("Vellum RLM Tier 2 sub-agent");
        const isGardener = allText.includes("Vellum Knowledge Gardener");
        const isPrBridge = allText.includes("Vellum GitHub PR Bridge");
        const isAiColumn = allText.includes("AI-compiled database column");
        const isBrief = allText.includes("Living Brief");
        let replyText =
          "Concise workspace semantic summary generated for progressive disclosure.";
        if (isRlmTier2Plan) {
          replyText = [
            "```mo",
            "let hits = ws.search(question, collection_id)",
            "var pids = map_field(hits, \"page_id\")",
            "if len(pids) == 0",
            "  pids = map_field(filter_contains(ws.summaries(collection_id), \"entity_kind\", \"page\"), \"entity_id\")",
            "end",
            "let sub_note = rlm.sub(\"Extract exact Rollback Procedure steps\", null)",
            "let blks = ws.blocks(take(pids, 4), [\"code_block\"], \"Rollback\")",
            "return llm.ask(\"Synthesize Tier 2 Micro-REPL answer with [Title §block_id] citations\", sub_note + \"\\n\" + join(map_field(blks, \"excerpt\"), \"\\n\"))",
            "```",
          ].join("\n");
        } else if (isRlmTier2Sub) {
          replyText =
            "Verified Tier 2 Mo Micro-REPL rollback procedure `kubectl rollout undo deploy/gateway` from Live RLM Runbook.";
        } else if (isRlmSub) {
          replyText =
            "Sub-agent verified Rollback Procedure block slice in Live RLM Runbook.";
        } else if (isRlmSynth) {
          replyText =
            "Verified rollback command and quorum check from RLM Tier 1 ReadProgram block slices.";
        } else if (isGardener) {
          replyText =
            "Gardener AI reconciliation: verify upstream API rate limit 25 req/s before failover.";
        } else if (isPrBridge) {
          replyText =
            "PR #708 updated gateway failover drain timeout to 45s; verify step 1 before rollout.";
        } else if (isSteer) {
          replyText =
            "Steered incident runbook paragraph revised in-place inside Modb.World branch.";
        } else if (isAiColumn) {
          if (allText.includes("ai_select") || allText.toLowerCase().includes("tier")) {
            replyText = JSON.stringify({
              value: "high",
              rationale: "Cost exceeds threshold",
            });
          } else {
            replyText = JSON.stringify({
              value: "92.50",
              rationale: "Computed live risk index",
            });
          }
        } else if (isBrief) {
          replyText =
            "- Live incident brief synthesized from permitted workspace summaries.";
        }
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(
          JSON.stringify({
            id: "chatcmpl-mock",
            object: "chat.completion",
            model: lastBody.model || "gpt-4o-mini",
            choices: [
              {
                index: 0,
                message: { role: "assistant", content: replyText },
                finish_reason: "stop",
              },
            ],
          })
        );
        return;
      }
      res.writeHead(200, {
        "Content-Type": "text/event-stream; charset=utf-8",
        "Cache-Control": "no-cache",
      });
      const tokens = ["Rotate ", "gateway ", "keys."];
      let i = 0;
      const timer = setInterval(() => {
        if (i < tokens.length) {
          const payload = JSON.stringify({ choices: [{ delta: { content: tokens[i] } }] });
          res.write(`data: ${payload}\n\n`);
          i += 1;
        } else {
          clearInterval(timer);
          res.write("data: [DONE]\n\n");
          res.end();
        }
      }, 120);
      res.on("close", () => clearInterval(timer));
    });
    return;
  }
  res.writeHead(404);
  res.end("not found");
});

server.listen(0, "127.0.0.1", () => {
  const addr = server.address();
  fs.writeFileSync(portFile, String(addr.port), "utf8");
});
MOCK_EOF
MOCK_LLM_PID=$!

for i in $(seq 1 30); do
  if [[ -f "$LIVE_DATA/mock-llm.port" ]]; then
    break
  fi
  sleep 0.1
done
if [[ ! -f "$LIVE_DATA/mock-llm.port" ]]; then
  echo "Timed out waiting for mock OpenAI SSE server" >&2
  exit 1
fi
MOCK_LLM_PORT="$(cat "$LIVE_DATA/mock-llm.port")"
export VELLUM_AI_API_KEY="test-live-vellum-key"
export VELLUM_AI_PROVIDER="openai"
export VELLUM_AI_BASE_URL="http://127.0.0.1:${MOCK_LLM_PORT}/v1/chat/completions"
export VELLUM_AI_MODEL="gpt-4o-mini"
export VELLUM_EMBED_BASE_URL="http://127.0.0.1:${MOCK_LLM_PORT}/v1/embeddings"
export VELLUM_EMBED_MODEL="text-embedding-3-small"
export VELLUM_EMBED_DIMENSIONS="8"
export VELLUM_GITHUB_WEBHOOK_SECRET="test-github-webhook-secret"

mo serve "$ROOT_DIR/main.mo" \
  --bind 127.0.0.1 \
  --port 8080 \
  --workers 4 \
  --data "$LIVE_DATA" \
  --ready-file "$LIVE_DATA/ready.json" >"$SERVE_LOG" 2>&1 &
SERVE_PID=$!

for i in $(seq 1 45); do
  if [[ -f "$LIVE_DATA/ready.json" ]]; then
    break
  fi
  if ! kill -0 "$SERVE_PID" 2>/dev/null; then
    echo "mo serve exited prematurely:" >&2
    cat "$SERVE_LOG" >&2 || true
    exit 1
  fi
  sleep 1
done
if [[ ! -f "$LIVE_DATA/ready.json" ]]; then
  echo "Timed out waiting for mo serve ready file" >&2
  cat "$SERVE_LOG" >&2 || true
  exit 1
fi

echo "==> Running live HTTP / OIDC (Dex) / S3 (VersityGW) / MCP / Proposals E2E suite"
export VELLUM_ROOT_DIR="$ROOT_DIR"
export VELLUM_LIVE_DATA="$LIVE_DATA"
node --input-type=module - <<'EOF'
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash, createHmac } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const ROOT_DIR = process.env.VELLUM_ROOT_DIR;
const LIVE_DATA = process.env.VELLUM_LIVE_DATA;

const BASE = "http://127.0.0.1:8080";

class CookieJar {
  jars = new Map();

  storeFrom(urlStr, res) {
    const u = new URL(urlStr);
    const key = u.origin;
    const jar = this.jars.get(key) ?? new Map();
    const setCookies = res.headers.getSetCookie ? res.headers.getSetCookie() : [];
    for (const sc of setCookies) {
      const pair = sc.split(";")[0];
      const eq = pair.indexOf("=");
      if (eq <= 0) continue;
      const name = pair.slice(0, eq).trim();
      const val = pair.slice(eq + 1).trim();
      if (!val || /max-age=0/i.test(sc)) {
        jar.delete(name);
      } else {
        jar.set(name, val);
      }
    }
    this.jars.set(key, jar);
  }

  headerFor(urlStr) {
    const u = new URL(urlStr);
    const jar = this.jars.get(u.origin);
    if (!jar || jar.size === 0) return undefined;
    return Array.from(jar.entries())
      .map(([k, v]) => `${k}=${v}`)
      .join("; ");
  }

  getCookie(urlStr, name) {
    const u = new URL(urlStr);
    return this.jars.get(u.origin)?.get(name);
  }
}

const jar = new CookieJar();

async function rawFetch(urlStr, opts = {}) {
  const headers = new Headers(opts.headers ?? {});
  const cookieHdr = jar.headerFor(urlStr);
  if (cookieHdr) headers.set("Cookie", cookieHdr);
  const res = await fetch(urlStr, { ...opts, headers, redirect: "manual" });
  jar.storeFrom(urlStr, res);
  return res;
}

async function apiJson(path, opts = {}) {
  const method = (opts.method ?? "GET").toUpperCase();
  const url = path.startsWith("http") ? path : `${BASE}${path}`;
  const headers = new Headers(opts.headers ?? {});
  if (!headers.has("Accept")) headers.set("Accept", "application/json");
  if (opts.body !== undefined && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }
  if (!["GET", "HEAD", "OPTIONS"].includes(method)) {
    const xsrf = jar.getCookie(BASE, "XSRF-TOKEN");
    if (xsrf) {
      headers.set("X-XSRF-TOKEN", decodeURIComponent(xsrf));
    }
  }
  const res = await rawFetch(url, { ...opts, method, headers });
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  return { res, text, json };
}

// 1. Guest shell & built Vite assets check
const guestHome = await rawFetch(`${BASE}/`);
assert.equal(guestHome.status, 303);
assert.equal(guestHome.headers.get("location"), "/login");

const loginPage = await rawFetch(`${BASE}/login`);
assert.equal(loginPage.status, 200);
const loginHtml = await loginPage.text();
const jsMatch = loginHtml.match(/src="(\/assets\/main-[^"]+\.js)"/);
const cssMatch = loginHtml.match(/href="(\/assets\/main-[^"]+\.css)"/);
assert.ok(jsMatch, "Login HTML references hashed Vite main JS");
assert.ok(cssMatch, "Login HTML references hashed Vite main CSS");
const jsAsset = await rawFetch(`${BASE}${jsMatch[1]}`);
assert.equal(jsAsset.status, 200);
const cssAsset = await rawFetch(`${BASE}${cssMatch[1]}`);
assert.equal(cssAsset.status, 200);
console.log("✓ Built Vite assets served with 200 OK:", jsMatch[1], cssMatch[1]);

// 2. Real Dex OIDC PKCE flow
let nextUrl = `${BASE}/auth/oidc/login?return_to=/`;
let hops = 0;
let res = await rawFetch(nextUrl);
while (res.status >= 300 && res.status < 400 && hops < 10) {
  const loc = res.headers.get("location");
  assert.ok(loc, "Redirect has Location");
  nextUrl = new URL(loc, nextUrl).toString();
  res = await rawFetch(nextUrl);
  hops += 1;
}
assert.equal(res.status, 200, "Dex login page loaded");
const dexFormHtml = await res.text();
const actionMatch = dexFormHtml.match(/action="([^"]+)"/);
assert.ok(actionMatch, "Dex form action found");
const formAction = new URL(actionMatch[1].replaceAll("&amp;", "&"), nextUrl).toString();

const formBody = new URLSearchParams({ login: "ada@acme.io", password: "password" });
let authRes = await rawFetch(formAction, {
  method: "POST",
  headers: { "Content-Type": "application/x-www-form-urlencoded" },
  body: formBody.toString(),
});
hops = 0;
let curUrl = formAction;
while (authRes.status >= 300 && authRes.status < 400 && hops < 10) {
  const loc = authRes.headers.get("location");
  assert.ok(loc, "OIDC callback redirect has Location");
  curUrl = new URL(loc, curUrl).toString();
  if (curUrl === `${BASE}/`) {
    break;
  }
  authRes = await rawFetch(curUrl);
  hops += 1;
}
assert.ok(jar.getCookie(BASE, "vellum_session"), "vellum_session cookie issued after Dex OIDC");
assert.ok(jar.getCookie(BASE, "XSRF-TOKEN"), "XSRF-TOKEN cookie issued after Dex OIDC");
console.log("✓ Live Dex OIDC PKCE login succeeded for ada@acme.io");

// 3. Verify Inertia v2 pages (/ , /proposals, /admin)
for (const [path, component] of [
  ["/", "Workspace/Home"],
  ["/proposals", "Workspace/Proposals"],
  ["/admin", "Workspace/Admin"],
]) {
  const r = await rawFetch(`${BASE}${path}`, { headers: { "X-Inertia": "true" } });
  assert.equal(r.status, 200, `GET ${path} status`);
  const j = await r.json();
  assert.equal(j.component, component);
}
console.log("✓ Inertia v2 XHR navigation verified across /, /proposals, /admin");

// 4. Create collection, create page, patch block, BM25 search
const colRes = await apiJson("/api/collections", {
  method: "POST",
  body: JSON.stringify({
    slug: "live-ops",
    name: "Live Ops",
    description: "Live E2E collection",
    icon: null,
    write_policy: "direct_with_audit",
    freshness_ttl_days: 30,
  }),
});
assert.equal(colRes.res.status, 201, colRes.text);
const colId = colRes.json.id;

const pgRes = await apiJson("/api/pages", {
  method: "POST",
  body: JSON.stringify({
    collection_id: colId,
    parent_page_id: null,
    title: "Live Deployment Runbook",
    markdown: "Verify gateway healthz before rotating quorum keys.",
    icon: null,
    freshness_ttl_days: null,
    reason: "live e2e seed",
  }),
});
assert.equal(pgRes.res.status, 201, pgRes.text);
const pageId = pgRes.json.page.id;
const blkId = pgRes.json.blocks[0].id;

// Seed Kubernetes target page and pin CoW Modb.Replay baseline BEFORE any World proposals run
const blTargetPg = await apiJson("/api/pages", {
  method: "POST",
  body: JSON.stringify({
    collection_id: colId,
    title: "Kubernetes Failover Standard",
    markdown: "Standard procedure for multi-zone Kubernetes cluster failover and drain.",
    reason: "seed backlink target",
  }),
});
assert.equal(blTargetPg.res.status, 201, blTargetPg.text);
const blTargetId = blTargetPg.json.page.id;
const blTargetBlkId = blTargetPg.json.blocks[0].id;

const pinBaselineRes = await apiJson("/api/admin/replay/baseline", {
  method: "POST",
  body: "{}",
});
assert.equal(pinBaselineRes.res.status, 201, pinBaselineRes.text);

const searchRes = await apiJson("/api/search?q=quorum&limit=10");
assert.equal(searchRes.res.status, 200, searchRes.text);
assert.ok(
  searchRes.json.results.some((hit) => hit.page_id === pageId),
  "Live BM25 search returned created page"
);

// Create a secret collection + page (sharing semantic topic vector [1,0,...] with Live Deployment Runbook)
// so background arvo.jobs.drain (10s schedule) indexes both into Modb.Vec during steps 5-9.
const secretColRes = await apiJson("/api/collections", {
  method: "POST",
  body: JSON.stringify({
    slug: "secret-exec",
    name: "Secret Exec",
    description: "Confidential executive keys",
    icon: null,
    write_policy: "direct_with_audit",
    freshness_ttl_days: 30,
  }),
});
assert.equal(secretColRes.res.status, 201, secretColRes.text);
const secretColId = secretColRes.json.id;

const secretPgRes = await apiJson("/api/pages", {
  method: "POST",
  body: JSON.stringify({
    collection_id: secretColId,
    parent_page_id: null,
    title: "Executive Secret Vault",
    markdown: "Master token custody zxqvault.",
    icon: null,
    freshness_ttl_days: null,
    reason: "secret semantic test page",
  }),
});
assert.equal(secretPgRes.res.status, 201, secretPgRes.text);
const secretPageId = secretPgRes.json.page.id;
console.log("✓ Collection, Page creation & live BM25 FTS verified");

// 5. Real VersityGW S3 SigV4 presigned PUT + commit + presigned GET download
const payloadBytes = Buffer.from("vellum-live-s3-payload-verified\n", "utf8");
const shaHex = createHash("sha256").update(payloadBytes).digest("hex");
const presignRes = await apiJson("/api/attachments/presign", {
  method: "POST",
  body: JSON.stringify({
    page_id: pageId,
    filename: "runbook-diagram.txt",
    content_type: "text/plain",
    size_bytes: payloadBytes.length,
    sha256_hex: shaHex,
  }),
});
assert.equal(presignRes.res.status, 201, presignRes.text);
const attId = presignRes.json.attachment.id;
const putHeaders = {};
for (const h of presignRes.json.required_headers ?? []) {
  putHeaders[h.name] = h.value;
}
const putRes = await fetch(presignRes.json.upload_url, {
  method: presignRes.json.method || "PUT",
  headers: putHeaders,
  body: payloadBytes,
});
assert.equal(putRes.status, 200, `VersityGW S3 PUT failed: ${putRes.status} ${await putRes.text()}`);

const commitRes = await apiJson(`/api/attachments/${attId}/commit`, {
  method: "POST",
  body: JSON.stringify({}),
});
assert.equal(commitRes.res.status, 200, commitRes.text);
assert.equal(commitRes.json.status, "ready");

const dlRedirect = await rawFetch(`${BASE}/api/attachments/${attId}/download`);
assert.equal(dlRedirect.status, 302);
const s3GetUrl = dlRedirect.headers.get("location");
assert.ok(s3GetUrl, "Download redirect returned presigned S3 URL");
const s3GetRes = await fetch(s3GetUrl);
assert.equal(s3GetRes.status, 200);
const downloaded = Buffer.from(await s3GetRes.arrayBuffer());
assert.deepEqual(downloaded, payloadBytes);
console.log("✓ Live VersityGW AWS SigV4 presign PUT -> commit -> 302 GET verified");

// 6. Relational database + Row + Query
const dbRes = await apiJson("/api/databases", {
  method: "POST",
  body: JSON.stringify({
    collection_id: colId,
    parent_page_id: null,
    title: "Live Incidents",
    description: null,
    properties: [
      { id: "title", name: "Title", kind: "title", required: true, sort_order: "i" },
      {
        id: "severity",
        name: "Severity",
        kind: {
          select: { options: [{ id: "sev1", label: "Sev1", color: "red" }] },
        },
        required: false,
        sort_order: "j",
      },
      { id: "cost", name: "Cost", kind: { number: { format: "currency" } }, required: false, sort_order: "k" },
    ],
  }),
});
assert.equal(dbRes.res.status, 201, dbRes.text);
const dbId = dbRes.json.database.id;
const defaultViewId = dbRes.json.default_view.id;

const rowRes = await apiJson(`/api/databases/${dbId}/rows`, {
  method: "POST",
  body: JSON.stringify({
    cells: {
      title: { text_val: "Live Smoke Incident" },
      severity: { select_val: { option_id: "sev1" } },
      cost: { number_val: "42.50" },
    },
    markdown: null,
    reason: "live e2e row",
  }),
});
assert.equal(rowRes.res.status, 201, rowRes.text);
const rowId = rowRes.json.row.id;

const qRes = await apiJson(`/api/databases/${dbId}/query`, {
  method: "POST",
  body: JSON.stringify({
    view_id: null,
    filters: [{ prop_id: "severity", op: "eq", value: "sev1" }],
    filter_match_all: true,
    sorts: [],
    from_date: null,
    to_date: null,
  }),
});
assert.equal(qRes.res.status, 200, qRes.text);
assert.equal(qRes.json.total_count, 1);

// 6b. Saved view PATCH + What-If Scenario fork -> Decimal delta -> merge to Live
const renameVwRes = await apiJson(`/api/databases/${dbId}/views/${defaultViewId}`, {
  method: "PATCH",
  body: JSON.stringify({ name: "Incidents Grid" }),
});
assert.equal(renameVwRes.res.status, 200, renameVwRes.text);
assert.equal(renameVwRes.json.name, "Incidents Grid");

const scenRes = await apiJson(`/api/databases/${dbId}/scenarios`, {
  method: "POST",
  body: JSON.stringify({
    title: "Escalation Cost Model",
    reason: "Model higher mitigation cost",
    branch_kind: "scenario",
  }),
});
assert.equal(scenRes.res.status, 201, scenRes.text);
const scenId = scenRes.json.id;

const scenMutRes = await apiJson(`/api/proposals/${scenId}/mutations`, {
  method: "POST",
  body: JSON.stringify({
    kind: "db_row_update",
    database_id: dbId,
    row_id: rowId,
    cells: { cost: { number_val: "142.75" } },
    expected_version: 1,
    reason: "Model failover hardware cost",
  }),
});
assert.equal(scenMutRes.res.status, 200, scenMutRes.text);

const scenQRes = await apiJson(`/api/databases/${dbId}/scenarios/${scenId}/query`, {
  method: "POST",
  body: JSON.stringify({
    view_id: defaultViewId,
    filters: [],
    filter_match_all: true,
    sorts: [],
    from_date: null,
    to_date: null,
  }),
});
assert.equal(scenQRes.res.status, 200, scenQRes.text);
const costDelta = (scenQRes.json.deltas ?? []).find((d) => d.prop_id === "cost");
assert.ok(costDelta, "Cost DecimalDelta present in scenario query");
assert.equal(costDelta.delta, "100.25");

const scenAcceptRes = await apiJson(`/api/proposals/${scenId}/accept`, {
  method: "POST",
  body: JSON.stringify({ reason: "Approve escalation budget" }),
});
assert.equal(scenAcceptRes.res.status, 200, scenAcceptRes.text);

const postMergeQ = await apiJson(`/api/databases/${dbId}/query`, {
  method: "POST",
  body: JSON.stringify({
    view_id: null,
    filters: [],
    filter_match_all: true,
    sorts: [],
    from_date: null,
    to_date: null,
  }),
});
assert.equal(postMergeQ.res.status, 200, postMergeQ.text);
assert.equal(postMergeQ.json.rows[0].row.cells.cost.number_val, "142.75");
console.log("✓ Relational Database + Decimal row + Query + What-If Scenario delta & merge verified");

// 6c. Statamic Blueprints + Metadata Attach + Embedded DB Markdown Sync + Live Metric Pill + Block Inspector Context
const bpRes = await apiJson("/api/blueprints", {
  method: "POST",
  body: JSON.stringify({
    slug: "incident-postmortem",
    name: "Incident Postmortem",
    description: "Structured postmortem metadata",
    icon: "shield-alert",
    fields: [
      {
        id: "tier",
        name: "Tier",
        kind: { select: { options: [{ id: "p0", label: "P0", color: "red" }, { id: "p1", label: "P1", color: "amber" }] } },
        required: true,
        sort_order: "a",
      },
      {
        id: "est_cost",
        name: "Estimated Cost",
        kind: { number: { format: "currency" } },
        required: false,
        sort_order: "b",
      },
    ],
    default_template_markdown: "## Summary",
  }),
});
assert.equal(bpRes.res.status, 201, bpRes.text);
const bpId = bpRes.json.id;

const metaRes = await apiJson(`/api/pages/${pageId}/meta`, {
  method: "PUT",
  body: JSON.stringify({
    blueprint_id: bpId,
    values: { tier: { select_val: { option_id: "p0" } }, est_cost: { number_val: "142.75" } },
    apply_template_if_empty: false,
    reason: "live e2e attach blueprint",
  }),
});
assert.equal(metaRes.res.status, 200, metaRes.text);
assert.ok(metaRes.json.yaml_frontmatter.includes("incident-postmortem"), "YAML frontmatter should contain blueprint slug");
const pageVerAfterMeta = metaRes.json.page.version;

const metricTok = `{{metric:${dbId}.cost:sum}}`;
const syncedMd = `${metaRes.json.anchored_markdown}\n\nTotal incident spend: ${metricTok}\n\n<!-- db_embed:${dbId}|${defaultViewId} -->`;
const mdSyncRes = await apiJson(`/api/pages/${pageId}/markdown`, {
  method: "PUT",
  body: JSON.stringify({
    markdown: syncedMd,
    expected_page_version: pageVerAfterMeta,
    reason: "live e2e embed db + metric pill",
  }),
});
assert.equal(mdSyncRes.res.status, 200, mdSyncRes.text);
assert.ok(mdSyncRes.json.anchored_markdown.includes(`<!-- db_embed:${dbId}|${defaultViewId} -->`));
const firstBlkId = mdSyncRes.json.blocks[0].id;

const resolveRes = await apiJson("/api/metrics/resolve", {
  method: "POST",
  body: JSON.stringify({ tokens: [metricTok], scenario_id: null }),
});
assert.equal(resolveRes.res.status, 200, resolveRes.text);
const metricEntry = resolveRes.json.metrics[metricTok];
assert.equal(metricEntry.status, "ok");
assert.equal(Number(metricEntry.value), 142.75);

const blkCtxRes = await apiJson(`/api/blocks/${firstBlkId}`);
assert.equal(blkCtxRes.res.status, 200, blkCtxRes.text);
assert.equal(blkCtxRes.json.block.id, firstBlkId);
assert.equal(blkCtxRes.json.page.id, pageId);
console.log("✓ Blueprints + Metadata + Embedded DB Markdown Sync + Live Metric Pill + Block Context verified");

// 6d. Phase 2.1: Living Summaries + Grant-Filtered /llms.txt + Context Pack CRUD & Compilation
const sumsRes = await apiJson("/api/summaries");
assert.equal(sumsRes.res.status, 200, sumsRes.text);
assert.ok(
  sumsRes.json.summaries.some((s) => s.entity_id === pageId && s.entity_kind === "page"),
  "Page LivingSummary present"
);
assert.ok(
  sumsRes.json.summaries.some((s) => s.entity_id === dbId && s.entity_kind === "database"),
  "Database LivingSummary present"
);

const cookieHdr6d = jar.headerFor(BASE);
const llmsRes = await fetch(`${BASE}/llms.txt`, {
  headers: cookieHdr6d ? { Cookie: cookieHdr6d } : {},
});
assert.equal(llmsRes.status, 200);
assert.ok((llmsRes.headers.get("content-type") || "").startsWith("text/markdown"));
const llmsText = await llmsRes.text();
assert.ok(llmsText.includes("# Vellum Workspace Index (/llms.txt)"));
assert.ok(llmsText.includes(dbId));

const createPackRes = await apiJson("/api/packs", {
  method: "POST",
  body: JSON.stringify({
    slug: "ops-brief",
    name: "Ops Brief",
    description: "Live E2E runbook and incident cost bundle",
    collection_ids: [colId],
    pinned_page_ids: [pageId],
    database_ids: [dbId],
    query_hint: null,
    fresh_only: false,
    include_full_blocks: true,
    token_budget: 2400,
  }),
});
assert.equal(createPackRes.res.status, 201, createPackRes.text);
assert.equal(createPackRes.json.slug, "ops-brief");

const compileJsonRes = await apiJson("/api/packs/ops-brief");
assert.equal(compileJsonRes.res.status, 200, compileJsonRes.text);
assert.ok(compileJsonRes.json.tokens_used <= 2400, "Respects token_budget <= 2400");
assert.ok(compileJsonRes.json.included_items.length >= 1, "Has included items");

const compileMdRes = await fetch(`${BASE}/api/packs/ops-brief/markdown`, {
  headers: cookieHdr6d ? { Cookie: cookieHdr6d } : {},
});
assert.equal(compileMdRes.status, 200);
assert.ok((compileMdRes.headers.get("content-type") || "").startsWith("text/markdown"));
const tokensHdr = Number(compileMdRes.headers.get("x-vellum-tokens-used") || "99999");
assert.ok(Number.isFinite(tokensHdr) && tokensHdr <= 2400, "X-Vellum-Tokens-Used <= 2400");
const compileMdText = await compileMdRes.text();
assert.ok(compileMdText.includes("# Context Pack:"));

const packsInertiaRes = await apiJson("/packs");
assert.equal(packsInertiaRes.res.status, 200, packsInertiaRes.text);
assert.ok(packsInertiaRes.json.packs.some((p) => p.slug === "ops-brief"));
console.log("✓ Context Studio + Living Summaries + /llms.txt + Context Pack compiler verified");

// 6e. Phase 2.2 AI-Compiled Columns (AutoApply, Modb.Feeds sync-feed staleness, StageProposal -> accept)
const dbGetRes = await apiJson(`/api/databases/${dbId}`);
assert.equal(dbGetRes.res.status, 200, dbGetRes.text);
const existingDb = dbGetRes.json.database;

const patchAiDbRes = await apiJson(`/api/databases/${dbId}`, {
  method: "PATCH",
  body: JSON.stringify({
    title: existingDb.title,
    description: existingDb.description ?? null,
    expected_version: existingDb.version,
    properties: [
      ...existingDb.properties,
      { id: "ai_notes", name: "AI Notes", kind: "rich_text", required: false, sort_order: "w" },
      {
        id: "ai_tier",
        name: "AI Triage Tier",
        kind: {
          ai_derived: {
            prompt: "Classify incident tier low or high",
            source_prop_ids: ["title", "cost", "ai_notes"],
            include_row_body: false,
            output_kind: {
              ai_select: {
                options: [
                  { id: "low", label: "Low", color: "gray" },
                  { id: "high", label: "High", color: "red" },
                ],
              },
            },
            mode: "auto_apply",
            daily_call_cap: 10,
          },
        },
        required: false,
        sort_order: "x",
      },
      {
        id: "ai_score",
        name: "AI Risk Score",
        kind: {
          ai_derived: {
            prompt: "Compute numeric risk score",
            source_prop_ids: ["title", "cost", "ai_notes"],
            include_row_body: false,
            output_kind: { ai_number: { format: "plain" } },
            mode: "stage_proposal",
            daily_call_cap: 10,
          },
        },
        required: false,
        sort_order: "y",
      },
    ],
  }),
});
assert.equal(patchAiDbRes.res.status, 200, patchAiDbRes.text);

const runTierRes = await apiJson(`/api/databases/${dbId}/ai-columns/ai_tier/run`, {
  method: "POST",
  body: JSON.stringify({
    row_ids: [rowId],
    only_stale: false,
    mode_override: null,
    deterministic_fallback: false,
  }),
});
assert.equal(runTierRes.res.status, 200, runTierRes.text);
assert.equal(runTierRes.json.updated_count, 1);
assert.equal(runTierRes.json.proposal, null);

const afterTierQ = await apiJson(`/api/databases/${dbId}/query`, {
  method: "POST",
  body: JSON.stringify({
    view_id: null,
    filters: [],
    filter_match_all: true,
    sorts: [],
    from_date: null,
    to_date: null,
  }),
});
assert.equal(afterTierQ.res.status, 200, afterTierQ.text);
const rowAfterTier = afterTierQ.json.rows.find((er) => er.row.id === rowId);
assert.ok(rowAfterTier, "rowId present after ai_tier run");
assert.equal(rowAfterTier.row.cells.ai_tier?.select_val?.option_id, "high");

const status1Res = await apiJson(`/api/databases/${dbId}/ai-columns/status`);
assert.equal(status1Res.res.status, 200, status1Res.text);
assert.ok(status1Res.json.cells?.[`${rowId}:ai_tier`]);
assert.equal(status1Res.json.cells[`${rowId}:ai_tier`].stale, false);

const mutNotesRes = await apiJson(`/api/databases/${dbId}/rows/${rowId}`, {
  method: "PATCH",
  body: JSON.stringify({
    cells: { ai_notes: { text_val: "Failover verified in us-east" } },
    expected_version: rowAfterTier.row.version,
    reason: "update source cell for feed sync",
  }),
});
assert.equal(mutNotesRes.res.status, 200, mutNotesRes.text);

const syncAiRes = await apiJson(`/api/databases/${dbId}/ai-columns/sync-feed`, {
  method: "POST",
  body: JSON.stringify({}),
});
assert.equal(syncAiRes.res.status, 200, syncAiRes.text);
assert.ok(syncAiRes.json.events_seen >= 1, syncAiRes.text);
assert.ok(syncAiRes.json.marked_stale_count >= 1, syncAiRes.text);

const status2Res = await apiJson(`/api/databases/${dbId}/ai-columns/status`);
assert.equal(status2Res.res.status, 200, status2Res.text);
assert.equal(status2Res.json.cells?.[`${rowId}:ai_tier`]?.stale, true);

const runScoreRes = await apiJson(`/api/databases/${dbId}/ai-columns/ai_score/run`, {
  method: "POST",
  body: JSON.stringify({
    row_ids: [rowId],
    only_stale: false,
    mode_override: null,
    deterministic_fallback: false,
  }),
});
assert.equal(runScoreRes.res.status, 201, runScoreRes.text);
const aiPropId = runScoreRes.json.proposal?.id;
assert.ok(aiPropId, "ai_score proposal id returned");

const beforeScoreQ = await apiJson(`/api/databases/${dbId}/query`, {
  method: "POST",
  body: JSON.stringify({
    view_id: null,
    filters: [],
    filter_match_all: true,
    sorts: [],
    from_date: null,
    to_date: null,
  }),
});
assert.equal(beforeScoreQ.res.status, 200, beforeScoreQ.text);
const rowBeforeScoreAccept = beforeScoreQ.json.rows.find((er) => er.row.id === rowId);
assert.equal(rowBeforeScoreAccept.row.cells.ai_score, undefined);

const acceptScoreRes = await apiJson(`/api/proposals/${aiPropId}/accept`, {
  method: "POST",
  body: JSON.stringify({ reason: "Approve AI risk score" }),
});
assert.equal(acceptScoreRes.res.status, 200, acceptScoreRes.text);

const afterScoreQ = await apiJson(`/api/databases/${dbId}/query`, {
  method: "POST",
  body: JSON.stringify({
    view_id: null,
    filters: [],
    filter_match_all: true,
    sorts: [],
    from_date: null,
    to_date: null,
  }),
});
assert.equal(afterScoreQ.res.status, 200, afterScoreQ.text);
const rowAfterScoreAccept = afterScoreQ.json.rows.find((er) => er.row.id === rowId);
assert.equal(Number(rowAfterScoreAccept.row.cells.ai_score?.number_val), 92.5);
assert.equal(rowAfterScoreAccept.row.cells.cost?.number_val, "142.75");

const status3Res = await apiJson(`/api/databases/${dbId}/ai-columns/status`);
assert.equal(status3Res.res.status, 200, status3Res.text);
assert.ok(status3Res.json.cells?.[`${rowId}:ai_score`]);
assert.equal(status3Res.json.cells[`${rowId}:ai_score`].stale, false);
console.log("✓ Phase 2.2 AI-Compiled Columns (AutoApply, Modb.Feeds sync-feed staleness, StageProposal -> accept) verified");

// 7. Mint Agent Token + live /mcp tool workflow + Modb.World Proposal Accept
const mintRes = await apiJson("/api/admin/agents", {
  method: "POST",
  body: JSON.stringify({
    handle: "live-agent",
    display_name: "Live Agent",
    model_id: "claude-sonnet-4-6",
    label: "live-e2e",
    allowed_actions: ["read", "propose", "comment"],
    allowed_collections: [colId],
    max_calls: 50,
    ttl_days: 7,
  }),
});
assert.equal(mintRes.res.status, 201, mintRes.text);
const rawTok = mintRes.json.raw_token;

async function mcpCall(id, method, params) {
  const r = await fetch(`${BASE}/mcp`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${rawTok}`,
    },
    body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
  });
  assert.equal(r.status, 200);
  return r.json();
}

const initR = await mcpCall(1, "initialize", {});
assert.ok(initR.result?.serverInfo?.name === "vellum-mcp");

const onboardR = await mcpCall(2, "tools/call", { name: "vellum.onboard", arguments: {} });
assert.equal(onboardR.result?.isError, false);

// MCP Progressive Disclosure resources & pack tools
const mcpResListR = await mcpCall(201, "resources/list", {});
const mcpResUris = (mcpResListR.result?.resources || []).map((r) => r.uri);
assert.ok(mcpResUris.includes("vellum://index"), "MCP advertises vellum://index");
assert.ok(mcpResUris.includes("vellum://packs/ops-brief"), "MCP advertises vellum://packs/ops-brief");

const mcpIdxReadR = await mcpCall(202, "resources/read", { uri: "vellum://index" });
assert.ok(
  (mcpIdxReadR.result?.contents?.[0]?.text || "").includes("vellum://packs/ops-brief"),
  "vellum://index includes ops-brief"
);

const mcpPackReadR = await mcpCall(203, "resources/read", { uri: "vellum://packs/ops-brief" });
assert.ok(
  (mcpPackReadR.result?.contents?.[0]?.text || "").includes("# Context Pack:"),
  "vellum://packs/ops-brief compiles to Markdown"
);

const mcpListSumsR = await mcpCall(204, "tools/call", {
  name: "vellum.list_summaries",
  arguments: {},
});
assert.equal(mcpListSumsR.result?.isError, false);

const mcpReadPackToolR = await mcpCall(205, "tools/call", {
  name: "vellum.read_pack",
  arguments: { slug: "ops-brief" },
});
assert.equal(mcpReadPackToolR.result?.isError, false);
assert.ok(mcpReadPackToolR.result?.structuredContent?.tokens_used <= 2400);

const openPropR = await mcpCall(3, "tools/call", {
  name: "vellum.proposal_open",
  arguments: {
    page_id: pageId,
    title: "Live agent runbook patch",
    reason: "Clarify zero-downtime key rotation",
  },
});
assert.equal(openPropR.result?.isError, false);
const propId = openPropR.result.structuredContent.id;
assert.ok(propId && propId.startsWith("prop_"), "Extracted MCP proposal ID");

const stagePropR = await mcpCall(4, "tools/call", {
  name: "vellum.proposal_stage_ops",
  arguments: {
    proposal_id: propId,
    reason: "Update runbook copy in isolated World",
    ops: [
      {
        replace_block: {
          block_id: blkId,
          expected_version: 1,
          kind: null,
          markdown: "Verify gateway healthz and quorum status before rotating keys.",
        },
      },
    ],
    expected_versions: { [blkId]: 1 },
  },
});
assert.equal(stagePropR.result?.isError, false);

const diffRes = await apiJson(`/api/proposals/${propId}/diff`);
assert.equal(diffRes.res.status, 200, diffRes.text);
assert.ok(JSON.stringify(diffRes.json).includes("vlm_blocks"));

const acceptRes = await apiJson(`/api/proposals/${propId}/accept`, {
  method: "POST",
  body: JSON.stringify({ reason: "Human approved live agent patch" }),
});
assert.equal(acceptRes.res.status, 200, acceptRes.text);

const finalPage = await apiJson(`/api/pages/${pageId}`);
assert.equal(finalPage.res.status, 200);
assert.ok(finalPage.json.anchored_markdown.includes("quorum status"));
console.log("✓ Live /mcp agent proposal -> Modb.World diff -> human accept verified");

// Phase 2.1 Living AI Brief block + proposals-only refresh + human accept
const briefInsertRes = await apiJson(`/api/pages/${pageId}/blocks`, {
  method: "PATCH",
  body: JSON.stringify({
    ops: [
      {
        insert_block_after: {
          after_block_id: firstBlkId,
          parent_block_id: null,
          kind: {
            ai_brief: {
              prompt: "Live incident brief",
              source_scope: colId,
              refreshed_at: null,
            },
          },
          markdown: "Initial E2E brief placeholder",
        },
      },
    ],
    expected_versions: {},
    reason: "insert live e2e ai_brief card",
  }),
});
assert.equal(briefInsertRes.res.status, 200, briefInsertRes.text);
const briefBlk = briefInsertRes.json.blocks.find(
  (b) => typeof b.kind === "object" && b.kind && "ai_brief" in b.kind
);
assert.ok(briefBlk?.id, "Created ai_brief block");

const briefRefreshRes = await apiJson("/api/ai/brief/refresh", {
  method: "POST",
  body: JSON.stringify({
    page_id: pageId,
    block_id: briefBlk.id,
    deterministic_fallback: true,
  }),
});
assert.equal(briefRefreshRes.res.status, 201, briefRefreshRes.text);
const briefPropId = briefRefreshRes.json.proposal?.id;
assert.ok(briefPropId && briefPropId.startsWith("prop_"), "Brief refresh opened proposal");

// Proposals-only invariant: live page must still have placeholder until accepted
const beforeBriefAccept = await apiJson(`/api/pages/${pageId}`);
assert.ok(beforeBriefAccept.json.anchored_markdown.includes("Initial E2E brief placeholder"));

const acceptBriefRes = await apiJson(`/api/proposals/${briefPropId}/accept`, {
  method: "POST",
  body: JSON.stringify({ reason: "Human approved AI brief refresh" }),
});
assert.equal(acceptBriefRes.res.status, 200, acceptBriefRes.text);

const afterBriefAccept = await apiJson(`/api/pages/${pageId}`);
assert.ok(afterBriefAccept.json.anchored_markdown.includes(":::ai-brief"));
assert.ok(afterBriefAccept.json.anchored_markdown.includes("Live incident brief"));
assert.ok(
  afterBriefAccept.json.anchored_markdown.includes(
    "synthesized from permitted workspace summaries"
  )
);
assert.ok(!afterBriefAccept.json.anchored_markdown.includes("Initial E2E brief placeholder"));
console.log("✓ MCP vellum://index + vellum://packs + Living AI Brief refresh-into-proposal verified");

// 7b. Phase 2.3 Full MCP DB Surface & Patchwork Per-Hunk Reject + Steer-in-Place
const dbMcpMint = await apiJson("/api/admin/agents", {
  method: "POST",
  body: JSON.stringify({
    handle: "db-mcp-agent",
    display_name: "DB MCP Agent",
    model_id: "gpt-4o-mini",
    label: "live-e2e-p23",
    allowed_actions: ["read", "write_db", "propose", "comment"],
    allowed_collections: [colId],
    max_calls: 50,
    ttl_days: 7,
  }),
});
assert.equal(dbMcpMint.res.status, 201, dbMcpMint.text);
const dbMcpTok = dbMcpMint.json.raw_token;

async function mcpDbCall(id, method, params) {
  const r = await fetch(`${BASE}/mcp`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${dbMcpTok}`,
    },
    body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
  });
  assert.equal(r.status, 200);
  return r.json();
}

const mcpDbSchemaR = await mcpDbCall(301, "tools/call", {
  name: "vellum.db_schema",
  arguments: { database_id: dbId },
});
assert.equal(mcpDbSchemaR.result?.isError, false);
assert.ok((mcpDbSchemaR.result?.structuredContent?.views || []).length >= 1);

const mcpCreateRowR = await mcpDbCall(302, "tools/call", {
  name: "vellum.db_create_row",
  arguments: {
    database_id: dbId,
    cells: {
      title: { text_val: "MCP Live Node" },
      cost: { number_val: "33.00" },
    },
    reason: "live mcp create row",
  },
});
assert.equal(mcpCreateRowR.result?.isError, false);
const mcpRowId = mcpCreateRowR.result.structuredContent.row.id;
assert.ok(mcpRowId && mcpRowId.startsWith("row_"), "MCP created DB row id");

const mcpUpdateRowR = await mcpDbCall(303, "tools/call", {
  name: "vellum.db_update_row",
  arguments: {
    database_id: dbId,
    row_id: mcpRowId,
    cells: { cost: { number_val: "55.00" } },
    expected_version: 1,
    reason: "live mcp update row",
  },
});
assert.equal(mcpUpdateRowR.result?.isError, false);
assert.equal(mcpUpdateRowR.result.structuredContent.row.version, 2);

const mcpProposeDbR = await mcpDbCall(304, "tools/call", {
  name: "vellum.db_propose_changes",
  arguments: {
    database_id: dbId,
    title: "MCP Propose Cost Revision",
    reason: "stage db_row_update via MCP",
    mutations: [
      {
        kind: "db_row_update",
        row_id: mcpRowId,
        expected_version: 2,
        cells: { cost: { number_val: "77.00" } },
      },
    ],
  },
});
assert.equal(mcpProposeDbR.result?.isError, false);
assert.equal(mcpProposeDbR.result.structuredContent.staged_count, 1);
const mcpDbPropId = mcpProposeDbR.result.structuredContent.proposal.id;

const mcpDbDiffRes = await apiJson(`/api/proposals/${mcpDbPropId}/diff`);
assert.equal(mcpDbDiffRes.res.status, 200, mcpDbDiffRes.text);
assert.equal(mcpDbDiffRes.json.db_row_diffs.length, 1);

const acceptMcpDbRes = await apiJson(`/api/proposals/${mcpDbPropId}/accept`, {
  method: "POST",
  body: JSON.stringify({ reason: "Approve MCP proposed DB edit" }),
});
assert.equal(acceptMcpDbRes.res.status, 200, acceptMcpDbRes.text);

const mcpQueryAfterR = await mcpDbCall(305, "tools/call", {
  name: "vellum.db_query",
  arguments: { database_id: dbId },
});
assert.equal(mcpQueryAfterR.result?.isError, false);
const mcpUpdatedRow = (mcpQueryAfterR.result.structuredContent.rows || []).find(
  (er) => er.row.id === mcpRowId
);
assert.equal(Number(mcpUpdatedRow?.row?.cells?.cost?.number_val), 77);

const steerPgRes = await apiJson("/api/pages", {
  method: "POST",
  body: JSON.stringify({
    collection_id: colId,
    parent_page_id: null,
    title: "Steer Patchwork Target",
    icon: null,
    markdown: "Live paragraph one.\n\nLive paragraph two.",
    freshness_ttl_days: null,
    reason: "seed patchwork steer page",
  }),
});
assert.equal(steerPgRes.res.status, 201, steerPgRes.text);
const steerPageId = steerPgRes.json.page.id;
const sBlk1 = steerPgRes.json.blocks[0].id;
const sBlk2 = steerPgRes.json.blocks[1].id;

const openSteerPropR = await mcpDbCall(306, "tools/call", {
  name: "vellum.proposal_open",
  arguments: {
    page_id: steerPageId,
    title: "Steerable Two-Block Draft",
    reason: "Update both blocks via MCP",
  },
});
assert.equal(openSteerPropR.result?.isError, false);
const steerPropId = openSteerPropR.result.structuredContent.id;

const stageSteerOpsR = await mcpDbCall(307, "tools/call", {
  name: "vellum.proposal_stage_ops",
  arguments: {
    proposal_id: steerPropId,
    reason: "Modify two blocks",
    ops: [
      {
        replace_block: {
          block_id: sBlk1,
          expected_version: 1,
          kind: null,
          markdown: "Agent draft paragraph one.",
        },
      },
      {
        replace_block: {
          block_id: sBlk2,
          expected_version: 1,
          kind: null,
          markdown: "Agent draft paragraph two to reject.",
        },
      },
    ],
    expected_versions: { [sBlk1]: 1, [sBlk2]: 1 },
  },
});
assert.equal(stageSteerOpsR.result?.isError, false);

const rejectHunkRes = await apiJson(`/api/proposals/${steerPropId}/hunks/reject`, {
  method: "POST",
  body: JSON.stringify({
    target_kind: "block",
    target_id: sBlk2,
    page_id: steerPageId,
    database_id: null,
    reason: "Keep original block two",
  }),
});
assert.equal(rejectHunkRes.res.status, 200, rejectHunkRes.text);

const steerActionRes = await apiJson(`/api/proposals/${steerPropId}/steer`, {
  method: "POST",
  body: JSON.stringify({
    target_block_id: sBlk1,
    target_page_id: steerPageId,
    instruction: "Tighten incident summary",
    deterministic_fallback: false,
  }),
});
assert.equal(steerActionRes.res.status, 200, steerActionRes.text);
assert.ok(steerActionRes.json.revised_markdown.includes("Steered incident runbook"));

const listPropCmtsRes = await apiJson(`/api/proposals/${steerPropId}/comments`);
assert.equal(listPropCmtsRes.res.status, 200, listPropCmtsRes.text);
assert.ok(listPropCmtsRes.json.comments.length >= 2);

const mcpPropCmtsR = await mcpDbCall(308, "tools/call", {
  name: "vellum.proposal_comments",
  arguments: { proposal_id: steerPropId },
});
assert.equal(mcpPropCmtsR.result?.isError, false);
assert.ok(mcpPropCmtsR.result.structuredContent.comments.length >= 2);

const acceptSteerPropRes = await apiJson(`/api/proposals/${steerPropId}/accept`, {
  method: "POST",
  body: JSON.stringify({ reason: "Merge steered block 1 only" }),
});
assert.equal(acceptSteerPropRes.res.status, 200, acceptSteerPropRes.text);

const afterSteerPg = await apiJson(`/api/pages/${steerPageId}`);
assert.equal(afterSteerPg.res.status, 200, afterSteerPg.text);
assert.ok(afterSteerPg.json.anchored_markdown.includes("Steered incident runbook"));
assert.ok(afterSteerPg.json.anchored_markdown.includes("Live paragraph two."));
console.log("✓ Phase 2.3 Full MCP DB Surface & Patchwork Steer-in-Place verified");

// 8. True Streaming SSE multi-client fanout + MCP live event + Last-Event-ID replay
async function openLiveSse(path, lastEventId = null) {
  const controller = new AbortController();
  const headers = new Headers({ Accept: "text/event-stream" });
  const cookieHdr = jar.headerFor(BASE);
  if (cookieHdr) headers.set("Cookie", cookieHdr);
  if (lastEventId) headers.set("Last-Event-ID", lastEventId);

  const sseRes = await fetch(`${BASE}${path}`, {
    headers,
    signal: controller.signal,
  });
  assert.equal(sseRes.status, 200, `SSE ${path} HTTP ${sseRes.status}`);
  assert.ok(
    (sseRes.headers.get("content-type") || "").startsWith("text/event-stream"),
    "SSE Content-Type"
  );
  assert.equal(sseRes.headers.get("x-mo-sse-subscribe"), null, "Internal subscribe header stripped");

  const reader = sseRes.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  const events = [];

  async function nextEvent(timeoutMs = 5000) {
    const deadline = Date.now() + timeoutMs;
    while (true) {
      const idx = buffer.indexOf("\n\n");
      if (idx !== -1) {
        const rawFrame = buffer.slice(0, idx);
        buffer = buffer.slice(idx + 2);
        if (!rawFrame.trim()) continue;
        let id = null;
        let event = "message";
        const dataLines = [];
        for (const line of rawFrame.split("\n")) {
          if (line.startsWith(":")) continue;
          if (line.startsWith("id:")) id = line.slice(3).trim();
          else if (line.startsWith("event:")) event = line.slice(6).trim();
          else if (line.startsWith("data:")) dataLines.push(line.slice(5).trimStart());
        }
        if (dataLines.length === 0) continue;
        const parsed = { id, event, data: dataLines.join("\n") };
        events.push(parsed);
        return parsed;
      }
      const rem = deadline - Date.now();
      if (rem <= 0) {
        throw new Error(`Timed out waiting for SSE frame; buffer=${JSON.stringify(buffer)}`);
      }
      const chunk = await Promise.race([
        reader.read(),
        new Promise((_, reject) =>
          setTimeout(() => reject(new Error("SSE read timeout")), rem)
        ),
      ]);
      if (chunk.done) {
        throw new Error("SSE stream closed unexpectedly");
      }
      buffer += decoder.decode(chunk.value, { stream: true });
    }
  }

  async function waitFor(predicate, timeoutMs = 5000) {
    const foundExisting = events.find(predicate);
    if (foundExisting) return foundExisting;
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const ev = await nextEvent(deadline - Date.now());
      if (predicate(ev)) return ev;
    }
    throw new Error("Timed out matching SSE event");
  }

  return {
    waitFor,
    close: () => {
      controller.abort();
      reader.cancel().catch(() => {});
    },
  };
}

const sseClient = await openLiveSse(`/api/events?page_id=${pageId}`);
await sseClient.waitFor((e) => e.event === "connected");
await sseClient.waitFor((e) => e.event === "claims.snapshot");

const claimRes = await apiJson("/api/claims", {
  method: "POST",
  body: JSON.stringify({
    resource: `page:${pageId}`,
    ttl_seconds: 60,
    world_id: null,
    reason: "live SSE lease check",
  }),
});
assert.equal(claimRes.res.status, 201, claimRes.text);
assert.equal(claimRes.res.headers.get("x-mo-sse-publish"), null, "Internal publish header stripped");
const claimEv = await sseClient.waitFor((e) => e.event === "claim.acquired");
assert.ok(claimEv.id && Number(claimEv.id) >= 1, "claim.acquired carries monotonic broker id");

const patchRes = await apiJson(`/api/pages/${pageId}/blocks`, {
  method: "PATCH",
  body: JSON.stringify({
    ops: [
      {
        replace_block: {
          block_id: blkId,
          expected_version: 2,
          kind: null,
          markdown: "Verify gateway healthz, quorum status, and live SSE propagation.",
        },
      },
    ],
    expected_versions: { [blkId]: 2 },
    reason: "live SSE block update",
  }),
});
assert.equal(patchRes.res.status, 200, patchRes.text);
const patchEv = await sseClient.waitFor((e) => e.event === "page.blocks_updated");
assert.ok(Number(patchEv.id) > Number(claimEv.id), "monotonic id increased across mutations");

const mcpLiveProp = await mcpCall(5, "tools/call", {
  name: "vellum.proposal_open",
  arguments: {
    page_id: pageId,
    title: "Live SSE MCP proposal",
    reason: "Verify MCP -> browser EventSource fanout",
  },
});
assert.equal(mcpLiveProp.result?.isError, false);
const propEv = await sseClient.waitFor((e) => e.event === "proposal.opened");
assert.ok(propEv.data.includes("Live SSE MCP proposal"));

const lastSeenId = propEv.id;
sseClient.close();

// Release claim while SSE tab is disconnected, then reconnect with Last-Event-ID to verify replay
const relRes = await apiJson("/api/claims/release", {
  method: "POST",
  body: JSON.stringify({ resource: `page:${pageId}` }),
});
assert.equal(relRes.res.status, 200, relRes.text);

const replayedClient = await openLiveSse(`/api/events?page_id=${pageId}`, lastSeenId);
const replayedEv = await replayedClient.waitFor((e) => e.event === "claim.released");
assert.ok(Number(replayedEv.id) > Number(lastSeenId), "replayed claim.released has newer id");
replayedClient.close();
console.log("✓ Live streaming SSE fanout (claims, blocks, MCP proposals) & Last-Event-ID replay verified");

// 9. Live HTTP-to-SSE AI token streaming via POST /api/ai/ask
const askXsrf = jar.getCookie(BASE, "XSRF-TOKEN");
const askHeaders = new Headers({
  Accept: "text/event-stream",
  "Content-Type": "application/json",
});
const askCookie = jar.headerFor(BASE);
if (askCookie) askHeaders.set("Cookie", askCookie);
if (askXsrf) askHeaders.set("X-XSRF-TOKEN", decodeURIComponent(askXsrf));

const askStartMs = Date.now();
const askRes = await fetch(`${BASE}/api/ai/ask`, {
  method: "POST",
  headers: askHeaders,
  body: JSON.stringify({
    question: "gateway",
    collection_id: null,
    max_sources: 3,
    stream: true,
  }),
});
assert.equal(askRes.status, 200, `Expected 200 on POST /api/ai/ask, got ${askRes.status}`);
assert.ok(
  (askRes.headers.get("content-type") || "").startsWith("text/event-stream"),
  "Ask SSE Content-Type"
);
assert.equal(askRes.headers.get("x-mo-sse-relay"), null, "Internal relay header stripped");

const askReader = askRes.body.getReader();
const askDecoder = new TextDecoder("utf-8");
let askBuf = "";
let firstCitationMs = null;
let doneMs = null;
let doneModel = null;
const aiCitations = [];
const aiTokens = [];

while (true) {
  const { value, done } = await askReader.read();
  if (value) {
    askBuf += askDecoder.decode(value, { stream: !done });
    const frames = askBuf.split(/\r?\n\r?\n/);
    askBuf = frames.pop() ?? "";
    for (const rawFrame of frames) {
      if (!rawFrame.trim()) continue;
      let evName = "message";
      const dataLines = [];
      for (const line of rawFrame.split(/\r?\n/)) {
        if (line.startsWith(":")) continue;
        if (line.startsWith("event:")) evName = line.slice(6).trim();
        else if (line.startsWith("data:")) dataLines.push(line.slice(5).trimStart());
      }
      if (dataLines.length === 0) continue;
      const joined = dataLines.join("\n");
      assert.ok(!joined.includes("test-live-vellum-key"), "LLM API key must never leak");
      const parsed = JSON.parse(joined);
      if (evName === "ai.citation") {
        if (firstCitationMs === null) firstCitationMs = Date.now();
        aiCitations.push(parsed);
      } else if (evName === "ai.token") {
        aiTokens.push(parsed.delta);
      } else if (evName === "ai.done") {
        doneMs = Date.now();
        doneModel = parsed.model;
      } else if (evName === "ai.error") {
        throw new Error(`Unexpected ai.error frame: ${joined}`);
      }
    }
  }
  if (done) break;
}

assert.ok(firstCitationMs !== null, "Expected ai.citation frame before tokens");
assert.ok(doneMs !== null && doneModel === "gpt-4o-mini", "Expected ai.done frame with model");
assert.ok(
  aiCitations.some((c) => c.page_id === pageId && String(c.title).includes("Live Deployment Runbook")),
  "Expected permitted Live Deployment Runbook citation"
);
assert.equal(aiTokens.join(""), "Rotate gateway keys.");
assert.ok(
  doneMs - firstCitationMs >= 200,
  `Expected incremental token streaming over >=200ms (got ${doneMs - firstCitationMs}ms since citation, total ${doneMs - askStartMs}ms)`
);
console.log("✓ Live Ask Workspace HTTP-to-SSE incremental token streaming verified");

// 10. Live Neural Embedding Outbox Indexing (`arvo.jobs.drain`) + Hybrid Semantic Search + Fail-Closed Grant Isolation
let neuralOwnerRes = null;
const pollDeadline = Date.now() + 20000;
while (Date.now() < pollDeadline) {
  const probe = await apiJson("/api/search?q=credential+renewal+protocol&mode=semantic&limit=10");
  assert.equal(probe.res.status, 200, probe.text);
  const probeIds = (probe.json?.results ?? []).map((h) => h.page_id);
  if (
    probe.json?.vector_backend === "neural" &&
    probeIds.includes(pageId) &&
    probeIds.includes(secretPageId)
  ) {
    neuralOwnerRes = probe.json;
    break;
  }
  await new Promise((r) => setTimeout(r, 500));
}
assert.ok(neuralOwnerRes, "Expected arvo.jobs.drain to populate vellum_neural_8 vector index");

// Verify BM25-only mode returns zero hits & vector_backend === "none" on zero lexical overlap query
const bm25Zero = await apiJson("/api/search?q=credential+renewal+protocol&mode=bm25&limit=10");
assert.equal(bm25Zero.res.status, 200);
assert.equal(bm25Zero.json.mode, "bm25");
assert.equal(bm25Zero.json.vector_backend, "none");
assert.equal((bm25Zero.json.results ?? []).length, 0);

// Scoped agent (allowed ONLY on colId) searches semantically via /api/search & /mcp vellum.search -> sees pageId, NEVER secretPageId
for (const mode of ["semantic", "hybrid"]) {
  const agSearch = await fetch(
    `${BASE}/api/search?q=credential+renewal+protocol&mode=${mode}&limit=10`,
    { headers: { Authorization: `Bearer ${rawTok}` } }
  );
  assert.equal(agSearch.status, 200);
  const agSearchJson = await agSearch.json();
  assert.equal(agSearchJson.vector_backend, "neural");
  const agIds = (agSearchJson.results ?? []).map((h) => h.page_id);
  assert.ok(agIds.includes(pageId), `Agent ${mode} search includes permitted page`);
  assert.ok(!agIds.includes(secretPageId), `Agent ${mode} search NEVER leaks secret page`);

  const mcpSem = await mcpCall(10 + (mode === "hybrid" ? 1 : 0), "tools/call", {
    name: "vellum.search",
    arguments: { q: "credential renewal protocol", mode },
  });
  assert.equal(mcpSem.result?.isError, false);
  assert.equal(mcpSem.result?.structuredContent?.vector_backend, "neural");
  const mcpIds = (mcpSem.result?.structuredContent?.results ?? []).map((h) => h.page_id);
  assert.ok(mcpIds.includes(pageId), `MCP ${mode} search includes permitted page`);
  assert.ok(!mcpIds.includes(secretPageId), `MCP ${mode} search NEVER leaks secret page`);
}

// Scoped agent Ask Workspace (SSE) with zero-lexical-overlap semantic question retrieves & cites ONLY permitted runbook
const semAskRes = await fetch(`${BASE}/api/ai/ask`, {
  method: "POST",
  headers: {
    Accept: "text/event-stream",
    "Content-Type": "application/json",
    Authorization: `Bearer ${rawTok}`,
  },
  body: JSON.stringify({
    question: "credential renewal protocol",
    collection_id: null,
    max_sources: 5,
    stream: true,
  }),
});
assert.equal(semAskRes.status, 200);
const semAskText = await semAskRes.text();
assert.ok(semAskText.includes(pageId), "Semantic Ask Workspace cites permitted Live Deployment Runbook");
assert.ok(!semAskText.includes(secretPageId), "Semantic Ask Workspace NEVER cites Executive Secret Vault");
assert.ok(!semAskText.includes("zxqvault"), "Semantic Ask Workspace NEVER leaks secret page text");
console.log("✓ Live Modb.Vec neural outbox indexing, Hybrid RRF /api/search + /mcp, and Semantic Ask RAG verified");

// 11. Live RLM Tier 1 Deep Research (POST /api/ai/deep-research + /mcp vellum.rlm_query)
const rlmPgRes = await apiJson("/api/pages", {
  method: "POST",
  body: JSON.stringify({
    collection_id: colId,
    parent_page_id: null,
    title: "Live RLM Rollback Playbook",
    markdown:
      "## Rollback Procedure\n\n```bash\nkubectl rollout undo deploy/gateway\n```\n\n```bash\nvellum quorum-verify --strict\n```\n\n## Observability\n\n```bash\nprometheus --version\n```",
    icon: null,
    freshness_ttl_days: null,
    reason: "seed live rlm playbook",
  }),
});
assert.equal(rlmPgRes.res.status, 201, rlmPgRes.text);
const rlmPgId = rlmPgRes.json.page.id;
const rlmBlocks = rlmPgRes.json.blocks ?? [];
assert.equal(rlmBlocks.length, 5);
const obsBlkId = rlmBlocks[4].id;

const deepRes = await apiJson("/api/ai/deep-research", {
  method: "POST",
  body: JSON.stringify({
    question: "How do we run Rollback Procedure on gateway deploy?",
    collection_id: colId,
    block_kinds: ["code_block"],
    heading_contains: "Rollback",
    include_databases: true,
    max_subcalls: 2,
  }),
});
assert.equal(deepRes.res.status, 200, deepRes.text);
assert.equal(deepRes.json.tier, "tier1_read_program");
assert.ok(deepRes.json.rows_scanned >= 5, "RLM scanned summaries + blocks + DB rows");
assert.ok(deepRes.json.trace.length >= 3, "RLM recorded ReadProgram, sub-LLM, and synthesize steps");
assert.equal(deepRes.json.taint?.untrusted_tainted, false);
assert.ok(
  (deepRes.json.citations ?? []).some((c) => c.page_id === rlmPgId),
  "RLM citations include Live RLM Rollback Playbook"
);
assert.ok(
  !(deepRes.json.citations ?? []).some((c) => c.block_id === obsBlkId),
  "RLM heading_contains filter excluded Observability section"
);

const budgetRes = await apiJson("/api/ai/deep-research", {
  method: "POST",
  body: JSON.stringify({
    question: "Rollback Procedure",
    collection_id: colId,
    max_rows_scanned: 1,
    max_subcalls: 0,
  }),
});
assert.equal(budgetRes.res.status, 422, "Tight ReadLimits enforces 422 WorkBudgetExceeded");

const mcpRlmOk = await mcpCall(12, "tools/call", {
  name: "vellum.rlm_query",
  arguments: {
    question: "Rollback Procedure gateway",
    heading_contains: "Rollback",
    block_kinds: ["code_block"],
    max_subcalls: 0,
  },
});
assert.equal(mcpRlmOk.result?.isError, false, JSON.stringify(mcpRlmOk));
const mcpRlmSc = mcpRlmOk.result?.structuredContent;
assert.equal(mcpRlmSc?.tier, "tier1_read_program");
assert.ok(!JSON.stringify(mcpRlmOk).includes("zxqvault"), "MCP RLM never leaks restricted collection");

const mcpRlmDenied = await mcpCall(13, "tools/call", {
  name: "vellum.rlm_query",
  arguments: {
    question: "Executive Secret Vault",
    collection_id: secretColId,
    max_subcalls: 0,
  },
});
assert.equal(
  mcpRlmDenied.result?.isError,
  true,
  "Scoped agent vellum.rlm_query fails closed on restricted collection"
);
console.log("✓ Live RLM Tier 1 Deep Research (/api/ai/deep-research + /mcp vellum.rlm_query) verified");

// 12. Live Conflict-Safe Two-Way `vellum sync` CLI (`mo run sync.mo`)
const mintSyncRes = await apiJson("/api/admin/agents", {
  method: "POST",
  body: JSON.stringify({
    handle: "@live_sync_bot",
    display_name: "Live Sync Bot",
    model_id: null,
    label: "live-sync",
    allowed_actions: ["read", "write_direct", "propose"],
    allowed_collections: [colId],
    max_calls: 50,
    ttl_days: 7,
  }),
});
assert.equal(mintSyncRes.res.status, 201, mintSyncRes.text);
const syncTok = mintSyncRes.json.raw_token;
assert.ok(syncTok && syncTok.startsWith("vlm_ag_"), "sync agent token minted");

function runVellumSync(args = ["sync"]) {
  return execFileSync(
    "mo",
    [
      "run",
      path.join(ROOT_DIR, "sync.mo"),
      "--",
      ...args,
      "--dir",
      "sync-docs",
      "--url",
      BASE,
      "--token",
      syncTok,
    ],
    { cwd: LIVE_DATA, encoding: "utf8" }
  );
}

const syncOut1 = runVellumSync(["sync"]);
assert.ok(syncOut1.includes("[PULL] live-ops/"), `Expected initial pull output, got: ${syncOut1}`);
assert.ok(!fs.existsSync(path.join(LIVE_DATA, "sync-docs", "secret-exec")), "Restricted collection never mirrored");

const liveOpsDir = path.join(LIVE_DATA, "sync-docs", "live-ops");
const mirrorFiles = fs.readdirSync(liveOpsDir).filter((f) => f.endsWith(`${pageId}.md`));
assert.equal(mirrorFiles.length, 1, `Expected mirror file for ${pageId}, found ${mirrorFiles}`);
const mirrorPath = path.join(liveOpsDir, mirrorFiles[0]);
const pulledDoc = fs.readFileSync(mirrorPath, "utf8");
assert.ok(pulledDoc.includes("<!-- blk:"), "Mirror preserves <!-- blk: --> anchor");

// Clean local edit -> direct push applied
const localCleanEdit = pulledDoc.replace(
  "Verify gateway healthz, quorum status, and live SSE propagation.",
  "Verify gateway healthz, quorum status, and vellum-sync round-trip."
);
fs.writeFileSync(mirrorPath, localCleanEdit, "utf8");
const syncOut2 = runVellumSync(["sync"]);
assert.ok(syncOut2.includes("[PUSH APPLIED]"), `Expected clean push, got: ${syncOut2}`);

const afterCleanPg = await apiJson(`/api/pages/${pageId}`);
assert.ok(afterCleanPg.json.anchored_markdown.includes("vellum-sync round-trip"));

// Concurrent divergence: live edit bumps remote version, then offline local edit conflicts -> Modb.World Proposal!
const liveCurBlk = afterCleanPg.json.blocks[0];
const divergeLiveRes = await apiJson(`/api/pages/${pageId}/blocks`, {
  method: "PATCH",
  body: JSON.stringify({
    ops: [
      {
        replace_block: {
          block_id: liveCurBlk.id,
          expected_version: liveCurBlk.version,
          kind: null,
          markdown: "Remote concurrent web edit winning live version.",
        },
      },
    ],
    expected_versions: { [liveCurBlk.id]: liveCurBlk.version },
    reason: "live edit to trigger sync conflict",
  }),
});
assert.equal(divergeLiveRes.res.status, 200, divergeLiveRes.text);

const afterCleanLocal = fs.readFileSync(mirrorPath, "utf8");
const divergentLocal = afterCleanLocal.replace(
  "Verify gateway healthz, quorum status, and vellum-sync round-trip.",
  "Local developer offline edit preserved without merge markers."
);
fs.writeFileSync(mirrorPath, divergentLocal, "utf8");

const syncOut3 = runVellumSync(["sync"]);
assert.ok(syncOut3.includes("[CONFLICT -> PROPOSAL "), `Expected conflict proposal output, got: ${syncOut3}`);
const preservedLocal = fs.readFileSync(mirrorPath, "utf8");
assert.equal(preservedLocal, divergentLocal, "Local mirror file must NEVER be clobbered");
assert.ok(!preservedLocal.includes("<<<<<<<"), "Local mirror must NEVER contain git conflict markers");

const propsList = await apiJson("/api/proposals");
const syncProp = (propsList.json.proposals ?? []).find(
  (p) => p.status === "open" && p.target_page_id === pageId && String(p.title).startsWith("Sync:")
);
assert.ok(syncProp, "Conflict-safe sync opened inspectable Modb.World Proposal");

const acceptSyncProp = await apiJson(`/api/proposals/${syncProp.id}/accept`, {
  method: "POST",
  body: JSON.stringify({ reason: "Accept local vellum sync conflict proposal" }),
});
assert.equal(acceptSyncProp.res.status, 200, acceptSyncProp.text);

const afterSyncAccept = await apiJson(`/api/pages/${pageId}`);
assert.ok(
  afterSyncAccept.json.anchored_markdown.includes("Local developer offline edit preserved without merge markers"),
  "Accepted sync proposal updated live page cleanly"
);
const syncOut4 = runVellumSync(["sync"]);
assert.ok(syncOut4.includes("[PULL]") || syncOut4.includes("proposals=0"), "Subsequent sync converges cleanly");
console.log("✓ Live conflict-safe two-way vellum sync CLI (pull, clean push, World conflict proposal) verified");

// 13. Live Phase 3.2 Proposals-Only Knowledge Gardeners & Signed GitHub PR Bridge
const authSpecPg = await apiJson("/api/pages", {
  method: "POST",
  body: JSON.stringify({
    collection_id: colId,
    title: "Public API Rate Limit Spec",
    markdown: "Public API rate limit is 100 req/s per tenant.",
    reason: "seed phase 3.2 citation source",
  }),
});
assert.equal(authSpecPg.res.status, 201, authSpecPg.text);
const authSpecPgId = authSpecPg.json.page.id;
const authSpecBlkId = authSpecPg.json.blocks[0].id;

const depSopPg = await apiJson("/api/pages", {
  method: "POST",
  body: JSON.stringify({
    collection_id: colId,
    title: "Gateway Retry SOP",
    markdown: "Follow upstream Public API rate limit before retrying gateway failover.",
    reason: "seed phase 3.2 dependent page",
  }),
});
assert.equal(depSopPg.res.status, 201, depSopPg.text);
const depSopPgId = depSopPg.json.page.id;
const depSopBlkId = depSopPg.json.blocks[0].id;

const citeLinkRes = await apiJson(`/api/pages/${depSopPgId}/blocks`, {
  method: "PATCH",
  body: JSON.stringify({
    ops: [
      {
        attach_citations: {
          block_id: depSopBlkId,
          citations: [
            {
              source_kind: "block",
              source_ref: authSpecBlkId,
              label: "Rate Limit §1",
              excerpt: "Public API rate limit is 100 req/s per tenant.",
            },
          ],
        },
      },
    ],
    expected_versions: {},
    reason: "attach cited block dependency",
  }),
});
assert.equal(citeLinkRes.res.status, 200, citeLinkRes.text);

const bumpSpecRes = await apiJson(`/api/pages/${authSpecPgId}/blocks`, {
  method: "PATCH",
  body: JSON.stringify({
    ops: [
      {
        replace_block: {
          block_id: authSpecBlkId,
          expected_version: 1,
          kind: null,
          markdown: "Public API rate limit is 25 req/s per tenant during failover.",
        },
      },
    ],
    expected_versions: { [authSpecBlkId]: 1 },
    reason: "update rate limit to trigger citation drift",
  }),
});
assert.equal(bumpSpecRes.res.status, 200, bumpSpecRes.text);

const dupAlpha = await apiJson("/api/pages", {
  method: "POST",
  body: JSON.stringify({
    collection_id: colId,
    title: "Deploy Rollback Checklist Alpha",
    markdown: "Always enable feature flag legacy_auth during canary deploy step 2 within 30 seconds.",
    reason: "seed phase 3.2 dup alpha",
  }),
});
assert.equal(dupAlpha.res.status, 201, dupAlpha.text);

const dupBeta = await apiJson("/api/pages", {
  method: "POST",
  body: JSON.stringify({
    collection_id: colId,
    title: "Deploy Rollback Checklist Beta",
    markdown: "Never enable feature flag legacy_auth during canary deploy step 2 within 10 seconds.",
    reason: "seed phase 3.2 dup beta",
  }),
});
assert.equal(dupBeta.res.status, 201, dupBeta.text);

const gardenRes = await apiJson("/api/admin/garden");
assert.equal(gardenRes.res.status, 200, gardenRes.text);
assert.ok(
  (gardenRes.json.citation_drifts ?? []).some(
    (d) =>
      d.dependent_page_id === depSopPgId &&
      d.cited_page_id === authSpecPgId &&
      d.cited_block_id === authSpecBlkId
  ),
  "GET /api/admin/garden reports cited-dependency drift"
);
assert.ok(
  (gardenRes.json.duplicate_pairs ?? []).some((p) => p.possible_contradiction === true),
  "GET /api/admin/garden flags semantic duplicate contradiction"
);

const depShowRes = await apiJson(`/api/pages/${depSopPgId}`);
assert.equal(depShowRes.res.status, 200, depShowRes.text);
assert.ok(
  (depShowRes.json.citation_drifts ?? []).some((d) => d.cited_block_id === authSpecBlkId),
  "GET /api/pages/:id includes X-Ray citation_drifts"
);

const gardenPropRes = await apiJson("/api/admin/garden/propose", {
  method: "POST",
  body: JSON.stringify({
    kind: "citation_drift",
    target_page_id: depSopPgId,
    target_block_id: depSopBlkId,
    related_page_id: authSpecPgId,
    related_block_id: authSpecBlkId,
    reason: "Sync Gateway Retry SOP with updated Public API rate limit",
  }),
});
assert.equal(gardenPropRes.res.status, 201, gardenPropRes.text);
const gardenPropId = gardenPropRes.json.proposal.id;
assert.equal(gardenPropRes.json.proposal.status, "open");

const depBeforeAccept = await apiJson(`/api/pages/${depSopPgId}`);
assert.ok(
  !depBeforeAccept.json.anchored_markdown.includes("Gardener AI reconciliation"),
  "Proposals-Only Gardener NEVER mutates live page before review"
);

const acceptGardenRes = await apiJson(`/api/proposals/${gardenPropId}/accept`, {
  method: "POST",
  body: JSON.stringify({ reason: "Accept Gardener citation drift proposal" }),
});
assert.equal(acceptGardenRes.res.status, 200, acceptGardenRes.text);
const depAfterAccept = await apiJson(`/api/pages/${depSopPgId}`);
assert.ok(
  depAfterAccept.json.anchored_markdown.includes("Gardener AI reconciliation"),
  "Accepted Gardener proposal updates dependent page cleanly"
);

// Signed inbound GitHub PR Bridge -> Modb.World Change Proposals
const ghBody = JSON.stringify({
  action: "opened",
  repository: { full_name: "acme/gateway" },
  changed_files: ["docs/gateway-retry-sop.md"],
  pull_request: {
    number: 708,
    title: "Gateway Retry SOP rate limit failover timeout update",
    body: "Follow upstream Public API rate limit before retrying gateway failover.",
    html_url: "https://github.com/acme/gateway/pull/708",
    merged: false,
    head: { sha: "708deadbeef" },
  },
});

const badGhRes = await rawFetch(`${BASE}/api/webhooks/github`, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "X-GitHub-Event": "pull_request",
    "X-Hub-Signature-256": "sha256=badbadbad",
  },
  body: ghBody,
});
assert.equal(badGhRes.status, 403, "Invalid GitHub webhook signature must fail closed (403)");

const ghSig = createHmac("sha256", "test-github-webhook-secret").update(ghBody).digest("hex");
const goodGhRes = await rawFetch(`${BASE}/api/webhooks/github`, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "X-GitHub-Event": "pull_request",
    "X-Hub-Signature-256": `sha256=${ghSig}`,
  },
  body: ghBody,
});
assert.equal(goodGhRes.status, 201, await goodGhRes.clone().text());
const goodGhJson = await goodGhRes.json();
assert.ok((goodGhJson.proposals ?? []).length >= 1, "Signed PR webhook staged Modb.World proposals");
const prProp = goodGhJson.proposals[0];
assert.equal(prProp.author_handle, "@github-pr-bridge");
assert.equal(prProp.status, "open");

const targetBeforePr = await apiJson(`/api/pages/${prProp.target_page_id}`);
assert.ok(
  !targetBeforePr.json.anchored_markdown.includes("PR #708 updated gateway failover"),
  "GitHub PR bridge NEVER mutates live page before review"
);

const acceptPrRes = await apiJson(`/api/proposals/${prProp.id}/accept`, {
  method: "POST",
  body: JSON.stringify({ reason: "Accept PR #708 runbook sync proposal" }),
});
assert.equal(acceptPrRes.res.status, 200, acceptPrRes.text);
const targetAfterPr = await apiJson(`/api/pages/${prProp.target_page_id}`);
assert.ok(
  targetAfterPr.json.anchored_markdown.includes("PR #708 updated gateway failover"),
  "Accepted PR bridge proposal lands cleanly on live page"
);
console.log("✓ Live Phase 3.2 Proposals-Only Knowledge Gardeners & Signed GitHub PR Bridge verified");

// 14. Live Phase 3.3 Visual Modb.Replay (Status + Time-Travel + Simulate), DB Gallery/Timeline, & Backlinks
const roadmapDbRes = await apiJson("/api/databases", {
  method: "POST",
  body: JSON.stringify({
    collection_id: colId,
    title: "Release Roadmap",
    description: "Phase 3.3 Gallery & Timeline E2E",
    properties: [
      { id: "title", name: "Item", kind: "title", required: true, sort_order: "a" },
      { id: "cover", name: "Cover", kind: "url", required: false, sort_order: "b" },
      {
        id: "start_at",
        name: "Start",
        kind: { date_prop: { include_time: false } },
        required: false,
        sort_order: "c",
      },
      {
        id: "end_at",
        name: "End",
        kind: { date_prop: { include_time: false } },
        required: false,
        sort_order: "d",
      },
    ],
  }),
});
assert.equal(roadmapDbRes.res.status, 201, roadmapDbRes.text);
const rmDbId = roadmapDbRes.json.database.id;

const rmGalleryRes = await apiJson(`/api/databases/${rmDbId}/views`, {
  method: "POST",
  body: JSON.stringify({
    name: "Visual Gallery",
    kind: { gallery_view: { cover_prop_id: "cover", card_prop_ids: ["start_at"], card_size: "md" } },
    filters: [],
    filter_match_all: true,
    sorts: [],
  }),
});
assert.equal(rmGalleryRes.res.status, 201, rmGalleryRes.text);
const rmGalleryId = rmGalleryRes.json.id;

const rmTimelineRes = await apiJson(`/api/databases/${rmDbId}/views`, {
  method: "POST",
  body: JSON.stringify({
    name: "Release Timeline",
    kind: { timeline_view: { start_date_prop_id: "start_at", end_date_prop_id: "end_at", card_prop_ids: ["cover"] } },
    filters: [],
    filter_match_all: true,
    sorts: [],
  }),
});
assert.equal(rmTimelineRes.res.status, 201, rmTimelineRes.text);
const rmTimelineId = rmTimelineRes.json.id;

const rEarlyRes = await apiJson(`/api/databases/${rmDbId}/rows`, {
  method: "POST",
  body: JSON.stringify({
    cells: {
      title: { text_val: "Early Launch" },
      cover: { url_val: "https://example.com/early.png" },
      start_at: { date_val: { start: "2026-12-01", end_date: null } },
      end_at: { date_val: { start: "2026-12-08", end_date: null } },
    },
    reason: "seed early timeline row",
  }),
});
assert.equal(rEarlyRes.res.status, 201, rEarlyRes.text);
const rLateRes = await apiJson(`/api/databases/${rmDbId}/rows`, {
  method: "POST",
  body: JSON.stringify({
    cells: {
      title: { text_val: "Late Launch" },
      start_at: { date_val: { start: "2026-12-18", end_date: null } },
      end_at: { date_val: { start: "2026-12-28", end_date: null } },
    },
    reason: "seed late timeline row",
  }),
});
assert.equal(rLateRes.res.status, 201, rLateRes.text);

const galQueryRes = await apiJson(`/api/databases/${rmDbId}/query`, {
  method: "POST",
  body: JSON.stringify({ view_id: rmGalleryId, filters: [], filter_match_all: true, sorts: [] }),
});
assert.equal(galQueryRes.res.status, 200, galQueryRes.text);
assert.equal(galQueryRes.json.rows.length, 2);

const tlQueryRes = await apiJson(`/api/databases/${rmDbId}/query`, {
  method: "POST",
  body: JSON.stringify({
    view_id: rmTimelineId,
    filters: [],
    filter_match_all: true,
    sorts: [],
    from_date: "2026-12-04",
    to_date: "2026-12-10",
  }),
});
assert.equal(tlQueryRes.res.status, 200, tlQueryRes.text);
assert.equal(tlQueryRes.json.rows.length, 1);
assert.equal(tlQueryRes.json.rows[0].row.id, rEarlyRes.json.row.id);

// Backlinks & Semantic Connections (explicit PageLink + Modb.Vec semantic)
const blSourcePg = await apiJson("/api/pages", {
  method: "POST",
  body: JSON.stringify({
    collection_id: colId,
    title: "Regional Incident Guide",
    markdown: `See [[${blTargetId}]] before failing over traffic.`,
    reason: "seed explicit backlink page",
  }),
});
assert.equal(blSourcePg.res.status, 201, blSourcePg.text);

const blSemPg = await apiJson("/api/pages", {
  method: "POST",
  body: JSON.stringify({
    collection_id: colId,
    title: "Kubernetes Cluster Failover Checklist",
    markdown: "Checklist for multi-zone Kubernetes cluster failover and node drain.",
    reason: "seed semantic backlink peer",
  }),
});
assert.equal(blSemPg.res.status, 201, blSemPg.text);

const blRes = await apiJson(`/api/pages/${blTargetId}/backlinks`);
assert.equal(blRes.res.status, 200, blRes.text);
assert.ok(
  (blRes.json.explicit_backlinks ?? []).some((b) => b.source_page_id === blSourcePg.json.page.id),
  "Explicit PageLink backlink detected"
);
assert.ok(
  (blRes.json.semantic_backlinks ?? []).some((b) => b.page_id === blSemPg.json.page.id),
  "Modb.Vec semantic backlink detected"
);

// Visual Modb.Replay: Status + History Scrubber + Read-Only Time-Travel + Simulate
const rev1Prop = await apiJson("/api/proposals", {
  method: "POST",
  body: JSON.stringify({
    page_id: blTargetId,
    title: "Replay Stop 1",
    reason: "Apply first Kubernetes revision",
  }),
});
assert.equal(rev1Prop.res.status, 201, rev1Prop.text);
const rev1Stage = await apiJson(`/api/proposals/${rev1Prop.json.id}/ops`, {
  method: "POST",
  body: JSON.stringify({
    ops: [
      {
        replace_block: {
          block_id: blTargetBlkId,
          expected_version: 1,
          kind: null,
          markdown: "Revision 1 multi-zone Kubernetes drain step.",
        },
      },
    ],
    expected_versions: { [blTargetBlkId]: 1 },
    reason: "stage rev 1",
  }),
});
assert.equal(rev1Stage.res.status, 200, rev1Stage.text);
const rev1Acc = await apiJson(`/api/proposals/${rev1Prop.json.id}/accept`, {
  method: "POST",
  body: JSON.stringify({ reason: "accept rev 1" }),
});
assert.equal(rev1Acc.res.status, 200, rev1Acc.text);

const rev2Prop = await apiJson("/api/proposals", {
  method: "POST",
  body: JSON.stringify({
    page_id: blTargetId,
    title: "Replay Stop 2",
    reason: "Apply second Kubernetes revision",
  }),
});
assert.equal(rev2Prop.res.status, 201, rev2Prop.text);
const rev2Stage = await apiJson(`/api/proposals/${rev2Prop.json.id}/ops`, {
  method: "POST",
  body: JSON.stringify({
    ops: [
      {
        replace_block: {
          block_id: blTargetBlkId,
          expected_version: 2,
          kind: null,
          markdown: "Revision 2 multi-zone Kubernetes drain step.",
        },
      },
    ],
    expected_versions: { [blTargetBlkId]: 2 },
    reason: "stage rev 2",
  }),
});
assert.equal(rev2Stage.res.status, 200, rev2Stage.text);
const rev2Acc = await apiJson(`/api/proposals/${rev2Prop.json.id}/accept`, {
  method: "POST",
  body: JSON.stringify({ reason: "accept rev 2" }),
});
assert.equal(rev2Acc.res.status, 200, rev2Acc.text);

const rplStatus = await apiJson("/api/admin/replay/status");
assert.equal(rplStatus.res.status, 200, rplStatus.text);
assert.ok(rplStatus.json.baseline, "CoW baseline present in /api/admin/replay/status");
assert.ok(rplStatus.json.call_count >= 2, "Replay call_count reflects accepted proposals");

const pgHist = await apiJson(`/api/pages/${blTargetId}/history`);
assert.equal(pgHist.res.status, 200, pgHist.text);
assert.equal(pgHist.json.can_scrub, true);
assert.ok(pgHist.json.stops.length >= 3, "Baseline + 2 revisions on scrubber");
const nonBaseline = pgHist.json.stops.filter((s) => s.seq > 0);
assert.ok(nonBaseline.length >= 2, "Found Rev 1 & Rev 2 replay stops in page history");
const rev1Stop = nonBaseline[0];

const ttRes = await apiJson(
  `/api/pages/${blTargetId}/time-travel?stop_before_seq=${rev1Stop.stop_before_seq}`
);
assert.equal(ttRes.res.status, 200, ttRes.text);
assert.equal(ttRes.json.existed_at_point, true);
assert.ok(ttRes.json.historical_markdown.includes("Revision 1 multi-zone Kubernetes drain step."));
assert.ok(!ttRes.json.historical_markdown.includes("Revision 2 multi-zone Kubernetes drain step."));
assert.ok(ttRes.json.ops_to_live_count >= 1);

const simRplRes = await apiJson("/api/admin/replay/simulate", {
  method: "POST",
  body: JSON.stringify({
    filter_kind: "stop_before_seq",
    target: null,
    seq: rev1Stop.stop_before_seq,
    description: "E2E visual simulation check",
  }),
});
assert.equal(simRplRes.res.status, 201, simRplRes.text);
assert.ok(Array.isArray(simRplRes.json.outcomes), "Simulate returns call-by-call outcomes");
const discRplRes = await apiJson(`/api/admin/replay/${simRplRes.json.proposal_id}/discard`, {
  method: "POST",
  body: "{}",
});
assert.equal(discRplRes.res.status, 200, discRplRes.text);
console.log("✓ Live Phase 3.3 Visual Modb.Replay, DB Gallery/Timeline, & Semantic Backlinks verified");

// 15. Live Phase 3.4 RLM Tier 2 (Mo Micro-REPL VM + rlm.sub + Firewall + MCP)
const tier2PlanRes = await apiJson("/api/ai/deep-research", {
  method: "POST",
  body: JSON.stringify({
    question: "How do we run Rollback Procedure on gateway deploy?",
    collection_id: colId,
    tier: "tier2",
    max_depth: 2,
    max_subcalls: 4,
    include_databases: true,
    session_id: "live-p34",
  }),
});
assert.equal(tier2PlanRes.res.status, 200, tier2PlanRes.text);
assert.equal(tier2PlanRes.json.tier, "tier2_micro_repl");
assert.ok(tier2PlanRes.json.executed_script && tier2PlanRes.json.executed_script.includes("rlm.sub"));
assert.ok(tier2PlanRes.json.depth_used >= 2, "Tier 2 reached recursion depth >= 2");
assert.ok((tier2PlanRes.json.child_sessions ?? []).length >= 1, "Tier 2 forked child taint session");
assert.ok(
  (tier2PlanRes.json.trace ?? []).some((s) => s.op === "plan_script"),
  "Tier 2 trace recorded Planner script"
);
assert.ok(
  (tier2PlanRes.json.trace ?? []).some((s) => s.op === "rlm_sub"),
  "Tier 2 trace recorded rlm.sub child fork"
);
assert.ok(
  (tier2PlanRes.json.citations ?? []).some((c) => c.page_id === rlmPgId),
  "Tier 2 citations include Live RLM Rollback Playbook"
);

const tier2FirewallRes = await apiJson("/api/ai/deep-research", {
  method: "POST",
  body: JSON.stringify({
    question: "leak local file",
    collection_id: colId,
    tier: "tier2",
    script: 'let x = Files.read("vellum.modb")\nreturn x',
  }),
});
assert.equal(tier2FirewallRes.res.status, 422, "Tier 2 static capability firewall rejects Files.read");

const mcpTier2Res = await mcpCall(15, "tools/call", {
  name: "vellum.rlm_query",
  arguments: {
    question: "Rollback Procedure",
    tier: "tier2",
    max_depth: 2,
    max_subcalls: 2,
    script: 'let h = ws.search("Rollback Procedure", null)\nlet b = ws.blocks(map_field(h, "page_id"), ["code_block"], "Rollback")\nreturn llm.ask("summarize", join(map_field(b, "excerpt"), "\\n"))',
  },
});
assert.equal(mcpTier2Res.result?.isError, false, JSON.stringify(mcpTier2Res));
assert.equal(mcpTier2Res.result?.structuredContent?.tier, "tier2_micro_repl");
assert.ok(!JSON.stringify(mcpTier2Res).includes("zxqvault"), "MCP Tier 2 RLM never leaks restricted collection");
console.log("✓ Live Phase 3.4 RLM Tier 2 Mo Micro-REPL VM (/api/ai/deep-research + /mcp vellum.rlm_query) verified");

// 16. Live Phase 4.1 Modb.Taint Lethal Trifecta Provenance, Fork Inheritance & Admin Clear
const taintColRes = await apiJson("/api/collections", {
  method: "POST",
  body: JSON.stringify({
    slug: "live-taint-lab",
    name: "Live Taint Lab",
    write_policy: "direct_with_audit",
    freshness_ttl_days: 30,
  }),
});
assert.equal(taintColRes.res.status, 201, taintColRes.text);
const taintColId = taintColRes.json.id;

const cleanPgRes = await apiJson("/api/pages", {
  method: "POST",
  body: JSON.stringify({
    collection_id: taintColId,
    title: "Live Clean Target",
    markdown: "Trusted live specification baseline.",
    reason: "seed live phase 4.1 clean page",
  }),
});
assert.equal(cleanPgRes.res.status, 201, cleanPgRes.text);
const cleanPgId = cleanPgRes.json.page.id;
const cleanBlkId = cleanPgRes.json.blocks[0].id;

const taintAgentMint = await apiJson("/api/admin/agents", {
  method: "POST",
  body: JSON.stringify({
    handle: "live-taint-agent",
    display_name: "Live Taint Agent",
    model_id: "claude-sonnet-4-6",
    label: "live-taint-e2e",
    allowed_actions: ["read", "comment", "propose", "write_direct"],
    allowed_collections: [taintColId],
    max_calls: 100,
    ttl_days: 7,
  }),
});
assert.equal(taintAgentMint.res.status, 201, taintAgentMint.text);
const taintTok = taintAgentMint.json.raw_token;

async function mcpTaintCall(id, name, argsObj) {
  const r = await fetch(`${BASE}/mcp`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${taintTok}`,
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id,
      method: "tools/call",
      params: { name, arguments: argsObj },
    }),
  });
  assert.equal(r.status, 200);
  return r.json();
}

const impTaintRes = await apiJson("/api/import/notion", {
  method: "POST",
  body: JSON.stringify({
    collection_id: taintColId,
    pages: [
      {
        path: "export/External%20Brief%209a1b2c3d4e5f67890123456789abcdef.md",
        title: null,
        markdown: "Untrusted Notion brief livezebra991 for taint tracking.",
      },
    ],
    databases: [],
  }),
});
assert.equal(impTaintRes.res.status, 201, impTaintRes.text);
assert.equal(impTaintRes.json.trust_tier, "untrusted");
const impTaintPgId = impTaintRes.json.imported_pages[0].id;

const impShowRes = await apiJson(`/api/pages/${impTaintPgId}`);
assert.equal(impShowRes.res.status, 200, impShowRes.text);
assert.equal(impShowRes.json.taint_provenance?.trust, "untrusted");
assert.ok((impShowRes.json.taint_provenance?.untrusted_block_ids ?? []).length >= 1);

const mcpTaintSearch = await mcpTaintCall(1601, "vellum.search", {
  q: "livezebra991",
  session_id: "live-p41-parent",
});
assert.equal(mcpTaintSearch.result?.isError, false, JSON.stringify(mcpTaintSearch));
assert.equal(
  mcpTaintSearch.result?.structuredContent?.taint_session?.untrusted_tainted,
  true
);

const mcpChildRead = await mcpTaintCall(1602, "vellum.read_page", {
  page_id: cleanPgId,
  session_id: "live-p41-child",
  parent_session_id: "live-p41-parent",
});
assert.equal(mcpChildRead.result?.isError, false, JSON.stringify(mcpChildRead));
assert.equal(mcpChildRead.result?.structuredContent?.taint_session?.untrusted_tainted, true);
assert.equal(
  mcpChildRead.result?.structuredContent?.taint_session?.parent_session_id,
  "live-p41-parent"
);

const mcpTaintedPatch = await mcpTaintCall(1603, "vellum.patch_blocks", {
  page_id: cleanPgId,
  reason: "should be blocked by Modb.Taint",
  session_id: "live-p41-child",
  ops: [
    {
      replace_block: {
        block_id: cleanBlkId,
        expected_version: 1,
        kind: null,
        markdown: "Live overwrite attempt",
      },
    },
  ],
  expected_versions: { [cleanBlkId]: 1 },
});
assert.equal(mcpTaintedPatch.result?.isError, true, "Tainted child blocked from vellum.patch_blocks");

const taintedWhRes = await apiJson("/api/webhooks", {
  method: "POST",
  headers: { "X-Taint-Session": "live-p41-parent" },
  body: JSON.stringify({
    collection_id: taintColId,
    url: "https://exfil.example.com/hook",
    events: ["page.updated"],
  }),
});
assert.equal(taintedWhRes.res.status, 403, taintedWhRes.text);

const mcpTaintedProp = await mcpTaintCall(1604, "vellum.proposal_open", {
  page_id: cleanPgId,
  title: "Live safe proposal while tainted",
  reason: "proposals stay permitted while direct writes are blocked",
});
assert.equal(mcpTaintedProp.result?.isError, false, JSON.stringify(mcpTaintedProp));

const taintStRes = await apiJson("/api/admin/taint/status");
assert.equal(taintStRes.res.status, 200, taintStRes.text);
assert.ok(
  (taintStRes.json.sessions ?? []).some(
    (s) => s.id === "live-p41-parent" && s.untrusted_tainted
  )
);
assert.ok(
  (taintStRes.json.sessions ?? []).some(
    (s) => s.id === "live-p41-child" && s.untrusted_tainted && s.blocked_attempts >= 1
  )
);

const clrParentRes = await apiJson("/api/admin/taint/sessions/live-p41-parent/clear", {
  method: "POST",
  body: JSON.stringify({ reason: "Live E2E admin verified" }),
});
assert.equal(clrParentRes.res.status, 200, clrParentRes.text);
assert.equal(clrParentRes.json.session?.untrusted_tainted, false);

const unblockedWhRes = await apiJson("/api/webhooks", {
  method: "POST",
  headers: { "X-Taint-Session": "live-p41-parent" },
  body: JSON.stringify({
    collection_id: taintColId,
    url: "https://safe.example.com/hook",
    events: ["page.updated"],
  }),
});
assert.equal(unblockedWhRes.res.status, 201, unblockedWhRes.text);

const clrChildRes = await apiJson("/api/admin/taint/sessions/live-p41-child/clear", {
  method: "POST",
  body: JSON.stringify({ reason: "Live E2E admin verified child" }),
});
assert.equal(clrChildRes.res.status, 200, clrChildRes.text);

const unblockedPatchRes = await mcpTaintCall(1605, "vellum.patch_blocks", {
  page_id: cleanPgId,
  reason: "allowed after admin taint clear",
  session_id: "live-p41-child",
  ops: [
    {
      replace_block: {
        block_id: cleanBlkId,
        expected_version: 1,
        kind: null,
        markdown: "Verified live post-clear update.",
      },
    },
  ],
  expected_versions: { [cleanBlkId]: 1 },
});
assert.equal(unblockedPatchRes.result?.isError, false, JSON.stringify(unblockedPatchRes));
console.log("✓ Live Phase 4.1 Modb.Taint Lethal Trifecta Provenance, Fork Inheritance & Admin Clear verified");
EOF

echo "All Live Vellum E2E checks against mo serve + Dex + VersityGW S3 passed."
