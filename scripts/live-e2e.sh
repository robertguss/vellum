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
        res.writeHead(400);
        res.end("expected stream:true");
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
node --input-type=module - <<'EOF'
import assert from "node:assert/strict";
import { createHash } from "node:crypto";

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
EOF

echo "All Live Vellum E2E checks against mo serve + Dex + VersityGW S3 passed."
