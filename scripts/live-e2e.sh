#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

LIVE_DATA="$(mktemp -d /tmp/vellum-live.XXXXXX)"
SERVE_PID=""
SERVE_LOG="$LIVE_DATA/mo-serve.log"

cleanup() {
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
console.log("✓ Relational Database + Decimal row + Query verified");

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
EOF

echo "All Live Vellum E2E checks against mo serve + Dex + VersityGW S3 passed."
