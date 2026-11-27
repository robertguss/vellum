#!/usr/bin/env node
/**
 * Vellum Milestone 1 Slice 1.3 — Resumable API-First + Hybrid ZIP Notion Migration Engine.
 *
 * Supports three modes:
 *   1. API-First (`--api-token-file` / `NOTION_TOKEN`): full Notion REST API ingestion covering all 21 DB property
 *      types, dual/bidirectional & self relations, rollups, formulas, covers, icons, nested page trees, and all 22 blocks.
 *   2. ZIP-Only (`--zip`): unpacks nested Notion Markdown + CSV exports (including inner part ZIPs), deduplicates
 *      `*_all.csv` and linked-view `"Untitled"` CSVs, infers depth-N hierarchy, uploads local media, and imports.
 *   3. Hybrid (`--api-token-file` + `--zip`): uses Notion API for authoritative structure, relations, rollups, and
 *      formulas while resolving binary attachments from the local ZIP export first (avoiding expiring Notion S3 URLs).
 *
 * Non-negotiable privacy invariant:
 *   - NEVER prints tokens, raw Notion page prose, cell values, emails, or workspace titles to stdout/stderr.
 */

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const NOTION_VERSION = "2022-06-28";

const UNZIP_PY = `
import os, sys, zipfile

src_zip = os.path.abspath(sys.argv[1])
dest_dir = os.path.abspath(sys.argv[2])

def safe_extract(zpath, out_root, depth=0):
    if depth > 4:
        return
    with zipfile.ZipFile(zpath, "r") as zf:
        for info in zf.infolist():
            raw_name = info.filename
            if not (info.flag_bits & 0x800):
                try:
                    raw_name = raw_name.encode("cp437").decode("utf-8")
                except Exception:
                    pass
            norm = os.path.normpath(raw_name.replace("\\\\", "/")).lstrip("/")
            if not norm or norm == "." or norm.startswith("..") or "/../" in f"/{norm}/":
                continue
            target = os.path.abspath(os.path.join(out_root, norm))
            if os.path.commonpath([out_root, target]) != out_root:
                continue
            if info.is_dir():
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with zf.open(info, "r") as rf, open(target, "wb") as wf:
                while True:
                    chunk = rf.read(1024 * 1024)
                    if not chunk:
                        break
                    wf.write(chunk)
            if norm.lower().endswith(".zip"):
                inner_dir = target[:-4]
                os.makedirs(inner_dir, exist_ok=True)
                safe_extract(target, inner_dir, depth + 1)
                try:
                    os.remove(target)
                except OSError:
                    pass

safe_extract(src_zip, dest_dir, 0)
`;

function printHelp() {
  console.log(`Vellum Notion Migration Engine (API-First + Hybrid ZIP, Resumable 3-Pass)

Usage:
  node scripts/notion-migrate.mjs [options]

Options:
  --vellum-url <url>        Base URL of Vellum server (required unless --dry-run)
  --vellum-token <token>    Vellum Agent Bearer token (or VELLUM_TOKEN env var)
  --solo-login              Authenticate against loopback VELLUM_MODE=solo (/auth/solo/login)
  --collection-slug <slug>  Target Vellum collection slug (default: notion-import)
  --collection-name <name>  Target Vellum collection display name (default: Notion Workspace)
  --api-token-file <path>   File containing Notion integration token (or NOTION_TOKEN env var)
  --api-base-url <url>      Override Notion API base URL (default: https://api.notion.com)
  --zip <path>              Notion Export ZIP path (supports nested part ZIPs & hybrid assets)
  --state <path>            Checkpoint state JSON path (default: /tmp/vellum-notion-migrate-state.json)
  --dry-run                 Inspect, map, and validate plan without mutating Vellum
  --skip-attachments        Skip binary file uploads while migrating pages/DBs/rows
  --max-attachment-mb <n>   Skip attachments larger than N MiB (default: 500)
  --chunk-mb <n>            Local attachment chunk size in MiB, 1..16 (default: 8)
  --concurrency <n>         Concurrent Notion API reads, 1..8 (default: 4)
  -h, --help                Show help
`);
}

function parseIntOpt(raw, fallback, minVal, maxVal) {
  const n = Number.parseInt(String(raw ?? ""), 10);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(minVal, Math.min(maxVal, n));
}

function parseArgs(argv) {
  const opts = {
    vellumUrl: (process.env.VELLUM_URL ?? "").trim() || null,
    vellumToken: (process.env.VELLUM_TOKEN ?? "").trim() || null,
    soloLogin: false,
    collectionSlug: "notion-import",
    collectionName: "Notion Workspace",
    apiTokenFile: null,
    apiBaseUrl: "https://api.notion.com",
    zipPath: null,
    statePath: path.join(os.tmpdir(), "vellum-notion-migrate-state.json"),
    dryRun: false,
    skipAttachments: false,
    maxAttachmentMb: 500,
    chunkMb: 8,
    concurrency: 4,
    help: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "-h" || arg === "--help") opts.help = true;
    else if (arg === "--vellum-url") opts.vellumUrl = (argv[++i] ?? "").trim() || null;
    else if (arg === "--vellum-token") opts.vellumToken = (argv[++i] ?? "").trim() || null;
    else if (arg === "--solo-login") opts.soloLogin = true;
    else if (arg === "--collection-slug") opts.collectionSlug = (argv[++i] ?? "").trim() || "notion-import";
    else if (arg === "--collection-name") opts.collectionName = (argv[++i] ?? "").trim() || "Notion Workspace";
    else if (arg === "--api-token-file") opts.apiTokenFile = argv[++i] ?? null;
    else if (arg === "--api-base-url") opts.apiBaseUrl = (argv[++i] ?? "https://api.notion.com").replace(/\/+$/, "");
    else if (arg === "--zip") opts.zipPath = argv[++i] ?? null;
    else if (arg === "--state") opts.statePath = argv[++i] ?? opts.statePath;
    else if (arg === "--dry-run") opts.dryRun = true;
    else if (arg === "--skip-attachments") opts.skipAttachments = true;
    else if (arg === "--max-attachment-mb") opts.maxAttachmentMb = parseIntOpt(argv[++i], 500, 1, 500);
    else if (arg === "--chunk-mb") opts.chunkMb = parseIntOpt(argv[++i], 8, 1, 16);
    else if (arg === "--concurrency") opts.concurrency = parseIntOpt(argv[++i], 4, 1, 8);
    else throw new Error(`Unknown CLI flag: ${arg}`);
  }
  return opts;
}

function normId(id) {
  return String(id ?? "").replaceAll("-", "").trim().toLowerCase();
}

function extractNotionId32(raw) {
  if (!raw) return null;
  const noFrag = String(raw).split("#")[0].split("?")[0].trim().replaceAll("\\", "/");
  let decoded = noFrag;
  try {
    decoded = decodeURIComponent(noFrag);
  } catch {
    decoded = noFrag.replaceAll("%20", " ");
  }
  const base = path.posix.basename(decoded).replace(/(_all\.csv|\.csv|\.md)$/i, "").trim();
  if (/^[0-9a-f]{32}$/i.test(base)) return base.toLowerCase();
  const m = base.match(/(?:^|\s)([0-9a-f]{32})$/i);
  if (m) return m[1].toLowerCase();
  const dashUuid = base.match(/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i);
  if (dashUuid) return dashUuid[1].replaceAll("-", "").toLowerCase();
  return null;
}

function stripNotionIdSuffix(raw) {
  const noFrag = String(raw ?? "").split("#")[0].split("?")[0].trim().replaceAll("\\", "/");
  let decoded = noFrag;
  try {
    decoded = decodeURIComponent(noFrag);
  } catch {
    decoded = noFrag.replaceAll("%20", " ");
  }
  const base = path.posix.basename(decoded).replace(/(_all\.csv|\.csv|\.md)$/i, "").trim();
  if (base.length > 33 && base[base.length - 33] === " ") {
    const tail = base.slice(base.length - 32);
    if (/^[0-9a-fA-F]{32}$/.test(tail)) {
      return base.slice(0, base.length - 33).trim();
    }
  }
  return base;
}

function slugifyId(raw, fallback) {
  const cleaned = String(raw ?? "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
  return cleaned || fallback;
}

function mapOptionColor(notionColor, idx) {
  const c = String(notionColor ?? "").toLowerCase();
  if (c === "blue") return "blue";
  if (c === "green") return "green";
  if (c === "yellow" || c === "orange" || c === "brown") return "amber";
  if (c === "red" || c === "pink") return "red";
  if (c === "purple") return "purple";
  if (c === "gray" || c === "default") return "gray";
  const palette = ["gray", "blue", "green", "amber", "red", "purple"];
  return palette[idx % palette.length];
}

function isValidEmail(raw) {
  const t = String(raw ?? "").trim();
  if (!t || /\s/.test(t)) return false;
  const parts = t.split("@");
  if (parts.length !== 2) return false;
  const [local, dom] = parts;
  return Boolean(local) && dom.includes(".") && !dom.startsWith(".") && !dom.endsWith(".");
}

function isDoneStatusLabel(label) {
  const low = String(label ?? "").trim().toLowerCase();
  return [
    "done",
    "complete",
    "completed",
    "shipped",
    "closed",
    "resolved",
    "published",
    "launched",
    "approved",
    "archived",
  ].includes(low);
}

function guessContentType(filename) {
  const ext = path.extname(String(filename ?? "")).toLowerCase();
  switch (ext) {
    case ".png": return "image/png";
    case ".jpg":
    case ".jpeg": return "image/jpeg";
    case ".gif": return "image/gif";
    case ".webp": return "image/webp";
    case ".pdf": return "application/pdf";
    case ".mp4": return "video/mp4";
    case ".mov": return "video/quicktime";
    case ".webm": return "video/webm";
    case ".mp3": return "audio/mpeg";
    case ".wav": return "audio/wav";
    case ".csv": return "text/csv";
    case ".json": return "application/json";
    case ".txt": return "text/plain";
    default: return "application/octet-stream";
  }
}

function isImageFilename(filename) {
  const ext = path.extname(String(filename ?? "")).toLowerCase();
  return [".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".avif"].includes(ext);
}

function safeFilename(raw, fallback = "attachment.bin") {
  const clean = path.posix.basename(String(raw ?? "").split("?")[0].split("#")[0]).trim();
  const ascii = clean.replace(/[^A-Za-z0-9._-]+/g, "_").replace(/^_+|_+$/g, "");
  if (!ascii || ascii === "." || ascii === "..") return fallback;
  return ascii.slice(0, 120);
}

function sha256FileSync(filePath) {
  const hash = createHash("sha256");
  const fd = fs.openSync(filePath, "r");
  const buf = Buffer.allocUnsafe(1024 * 1024);
  let total = 0;
  try {
    while (true) {
      const n = fs.readSync(fd, buf, 0, buf.length, null);
      if (n <= 0) break;
      total += n;
      hash.update(buf.subarray(0, n));
    }
  } finally {
    fs.closeSync(fd);
  }
  return { sha256Hex: hash.digest("hex"), sizeBytes: total };
}

class CookieJar {
  constructor() {
    this.cookies = new Map();
  }
  storeFrom(res) {
    const rawList = typeof res.headers.getSetCookie === "function"
      ? res.headers.getSetCookie()
      : (res.headers.get("set-cookie") ? [res.headers.get("set-cookie")] : []);
    for (const raw of rawList) {
      if (!raw) continue;
      const first = raw.split(";")[0];
      const eq = first.indexOf("=");
      if (eq <= 0) continue;
      const k = first.slice(0, eq).trim();
      const v = first.slice(eq + 1).trim();
      if (!v || raw.toLowerCase().includes("max-age=0")) this.cookies.delete(k);
      else this.cookies.set(k, v);
    }
  }
  header() {
    if (this.cookies.size === 0) return "";
    return [...this.cookies.entries()].map(([k, v]) => `${k}=${v}`).join("; ");
  }
  get(name) {
    return this.cookies.get(name) ?? null;
  }
}

class VellumClient {
  constructor({ baseUrl, token, soloLogin, chunkMb }) {
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.token = token;
    this.soloLogin = Boolean(soloLogin);
    this.chunkBytes = (chunkMb ?? 8) * 1024 * 1024;
    this.jar = new CookieJar();
  }

  async init() {
    if (this.soloLogin && !this.token) {
      const res = await fetch(`${this.baseUrl}/auth/solo/login?return_to=/`, {
        method: "GET",
        redirect: "manual",
      });
      this.jar.storeFrom(res);
      if (res.status < 200 || res.status >= 400) {
        const body = await res.text().catch(() => "");
        throw new Error(`Solo login failed (${res.status}): ${body.slice(0, 180)}`);
      }
      if (!this.jar.get("vellum_session")) {
        throw new Error("Solo login did not issue vellum_session cookie (check VELLUM_MODE=solo)");
      }
    }
  }

  async reqJson(method, apiPath, bodyObj = undefined) {
    const url = `${this.baseUrl}${apiPath}`;
    const headers = { Accept: "application/json" };
    if (bodyObj !== undefined) headers["Content-Type"] = "application/json";
    if (this.token) {
      headers.Authorization = `Bearer ${this.token}`;
    } else {
      const ck = this.jar.header();
      if (ck) headers.Cookie = ck;
      if (!["GET", "HEAD", "OPTIONS"].includes(method.toUpperCase())) {
        const xsrf = this.jar.get("XSRF-TOKEN");
        if (xsrf) headers["X-XSRF-TOKEN"] = decodeURIComponent(xsrf);
      }
    }
    const res = await fetch(url, {
      method,
      headers,
      body: bodyObj !== undefined ? JSON.stringify(bodyObj) : undefined,
      redirect: "manual",
    });
    this.jar.storeFrom(res);
    const text = await res.text();
    let json = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch {
      json = null;
    }
    if (!res.ok) {
      const err = new Error(`Vellum ${method} ${apiPath} failed (${res.status}): ${text.slice(0, 240)}`);
      err.status = res.status;
      err.bodyText = text;
      throw err;
    }
    return json;
  }

  async ensureCollection(slug, name) {
    try {
      const got = await this.reqJson("GET", `/api/collections/${encodeURIComponent(slug)}`);
      if (got?.collection?.id) return got.collection.id;
    } catch (e) {
      if (e.status !== 404) throw e;
    }
    const created = await this.reqJson("POST", "/api/collections", {
      slug,
      name,
      description: "Imported from Notion",
      icon: "book-open",
      write_policy: "direct_with_audit",
      freshness_ttl_days: null,
    });
    return created.id;
  }

  async uploadFileAttachment(pageId, filePath, filename, contentType) {
    const { sha256Hex, sizeBytes } = sha256FileSync(filePath);
    if (sizeBytes <= 0 || sizeBytes > 524288000) {
      return { skipped: true, reason: `size_out_of_bounds:${sizeBytes}` };
    }
    const presign = await this.reqJson("POST", "/api/attachments/presign", {
      page_id: pageId,
      filename,
      content_type: contentType || guessContentType(filename),
      size_bytes: sizeBytes,
      sha256_hex: sha256Hex,
    });
    const attId = presign.attachment.id;
    const rawUploadUrl = presign.upload_url;

    if (rawUploadUrl.startsWith("/")) {
      const fd = fs.openSync(filePath, "r");
      try {
        let offset = 0;
        while (offset < sizeBytes) {
          const toRead = Math.min(this.chunkBytes, sizeBytes - offset);
          const chunk = Buffer.allocUnsafe(toRead);
          const bytesRead = fs.readSync(fd, chunk, 0, toRead, offset);
          if (bytesRead <= 0) break;
          const payload = bytesRead === toRead ? chunk : chunk.subarray(0, bytesRead);
          const sep = rawUploadUrl.includes("?") ? "&" : "?";
          const chunkUrl = `${this.baseUrl}${rawUploadUrl}${sep}offset=${offset}`;
          const putRes = await fetch(chunkUrl, {
            method: "PUT",
            headers: { "Content-Type": "application/octet-stream" },
            body: payload,
          });
          if (!putRes.ok) {
            const msg = await putRes.text().catch(() => "");
            throw new Error(`Local chunk upload failed (${putRes.status}): ${msg.slice(0, 180)}`);
          }
          offset += bytesRead;
        }
      } finally {
        fs.closeSync(fd);
      }
    } else {
      const putHeaders = {};
      for (const h of presign.required_headers ?? []) {
        putHeaders[h.name] = h.value;
      }
      const data = fs.readFileSync(filePath);
      const putRes = await fetch(rawUploadUrl, {
        method: presign.method || "PUT",
        headers: putHeaders,
        body: data,
      });
      if (!putRes.ok) {
        const msg = await putRes.text().catch(() => "");
        throw new Error(`S3 PUT failed (${putRes.status}): ${msg.slice(0, 180)}`);
      }
    }

    await this.reqJson("POST", `/api/attachments/${attId}/commit`, {});
    return { skipped: false, attId };
  }
}

async function notionFetch(baseUrl, token, method, endpoint, body = null) {
  const headers = {
    Authorization: `Bearer ${token}`,
    "Notion-Version": NOTION_VERSION,
  };
  if (body !== null) headers["Content-Type"] = "application/json";

  for (let attempt = 0; attempt < 7; attempt += 1) {
    const res = await fetch(`${baseUrl}${endpoint}`, {
      method,
      headers,
      body: body !== null ? JSON.stringify(body) : undefined,
    });
    if (res.status === 429 || res.status >= 500) {
      const retryAfter = Number.parseFloat(res.headers.get("retry-after") || "0");
      const ms = retryAfter > 0
        ? Math.ceil(retryAfter * 1000) + 250
        : Math.min(10000, 450 * 2 ** attempt);
      await new Promise((r) => setTimeout(r, ms));
      continue;
    }
    const text = await res.text();
    if (!res.ok) {
      const err = new Error(`Notion API ${method} ${endpoint} failed (${res.status}): ${text.slice(0, 200)}`);
      err.status = res.status;
      throw err;
    }
    return JSON.parse(text);
  }
  throw new Error(`Notion API ${method} ${endpoint} exhausted retries`);
}

function parseCsvFull(rawText) {
  const clean = String(rawText ?? "").replace(/^\uFEFF/, "").replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  if (!clean.trim()) return { headers: [], rows: [] };
  const rows = [];
  let row = [];
  let cell = "";
  let inQuotes = false;
  let atStart = true;

  for (let i = 0; i < clean.length; i += 1) {
    const ch = clean[i];
    if (inQuotes) {
      if (ch === '"') {
        if (clean[i + 1] === '"') {
          cell += '"';
          i += 1;
        } else {
          inQuotes = false;
          atStart = false;
        }
      } else {
        cell += ch;
      }
    } else if (ch === '"' && atStart) {
      inQuotes = true;
      atStart = false;
    } else if (ch === ",") {
      row.push(cell);
      cell = "";
      atStart = true;
    } else if (ch === "\n") {
      row.push(cell);
      if (!(row.length === 1 && row[0] === "")) rows.push(row);
      row = [];
      cell = "";
      atStart = true;
    } else {
      cell += ch;
      atStart = false;
    }
  }
  if (cell.length > 0 || row.length > 0) {
    row.push(cell);
    if (!(row.length === 1 && row[0] === "")) rows.push(row);
  }
  if (rows.length === 0) return { headers: [], rows: [] };
  const headers = rows[0].map((h, i) => String(h ?? "").trim() || `Column ${i + 1}`);
  const dataRows = rows.slice(1).map((r) => headers.map((_, ci) => String(r[ci] ?? "").trim()));
  return { headers, rows: dataRows };
}

function indexZipWorkspace(zipPath) {
  if (!fs.existsSync(zipPath)) {
    throw new Error(`ZIP archive not found: ${zipPath}`);
  }
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "vellum-mig-zip-"));
  execFileSync("python3", ["-c", UNZIP_PY, zipPath, tmpDir], { stdio: "pipe" });

  const mdFiles = [];
  const csvFiles = [];
  const assetsByRel = new Map();
  const assetsByParentIdAndName = new Map();
  const assetsByBase = new Map();

  function walk(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full);
        continue;
      }
      const relPosix = path.relative(tmpDir, full).split(path.sep).join("/");
      const lower = entry.name.toLowerCase();
      if (lower.endsWith(".md")) {
        const markdown = fs.readFileSync(full, "utf8");
        mdFiles.push({
          relPath: relPosix,
          absPath: full,
          notionId: extractNotionId32(relPosix),
          title: stripNotionIdSuffix(relPosix) || "Untitled Page",
          markdown,
        });
      } else if (lower.endsWith(".csv")) {
        const csvText = fs.readFileSync(full, "utf8");
        csvFiles.push({
          relPath: relPosix,
          absPath: full,
          name: entry.name,
          notionId: extractNotionId32(relPosix),
          title: stripNotionIdSuffix(relPosix) || "Untitled Database",
          isAll: /_all\.csv$/i.test(entry.name),
          csvText,
        });
      } else {
        const stat = fs.statSync(full);
        const rec = {
          relPath: relPosix,
          absPath: full,
          filename: safeFilename(entry.name),
          rawName: entry.name,
          sizeBytes: stat.size,
          contentType: guessContentType(entry.name),
        };
        assetsByRel.set(relPosix.toLowerCase(), rec);
        const parentSeg = path.posix.dirname(relPosix);
        const parentNid = extractNotionId32(parentSeg);
        const baseLow = entry.name.toLowerCase();
        if (parentNid) {
          assetsByParentIdAndName.set(`${parentNid}:${baseLow}`, rec);
        }
        if (!assetsByBase.has(baseLow)) assetsByBase.set(baseLow, []);
        assetsByBase.get(baseLow).push(rec);
      }
    }
  }
  walk(tmpDir);

  return {
    tmpDir,
    mdFiles,
    csvFiles,
    assetsByRel,
    assetsByParentIdAndName,
    assetsByBase,
    cleanup() {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    },
    resolveAsset(parentNotionId, rawName, hintRel = null) {
      if (hintRel) {
        let dec = hintRel;
        try { dec = decodeURIComponent(hintRel); } catch {}
        const byRel = assetsByRel.get(dec.replace(/^\/+/, "").toLowerCase());
        if (byRel) return byRel;
      }
      const cleanName = String(rawName ?? "").trim().toLowerCase();
      if (parentNotionId && cleanName) {
        const hit = assetsByParentIdAndName.get(`${normId(parentNotionId)}:${cleanName}`);
        if (hit) return hit;
      }
      if (cleanName && assetsByBase.has(cleanName)) {
        const list = assetsByBase.get(cleanName);
        if (list.length === 1) return list[0];
      }
      return null;
    },
  };
}

function selectCanonicalCsvEntries(csvFiles) {
  const byKey = new Map();
  const ordered = [];
  for (const f of csvFiles) {
    const key = f.notionId ? `id:${f.notionId}` : `name:${f.title.toLowerCase()}`;
    if (!byKey.has(key)) {
      byKey.set(key, ordered.length);
      ordered.push(f);
    } else if (f.isAll) {
      const slot = byKey.get(key);
      if (!ordered[slot].isAll) ordered[slot] = f;
    }
  }
  const parsedCache = ordered.map((f) => ({ f, tbl: parseCsvFull(f.csvText) }));
  const seenSigs = new Set();
  const headerSig = (tbl) =>
    tbl.headers.map((h) => h.trim().toLowerCase()).sort().join("\u0001");

  for (const { f, tbl } of parsedCache) {
    if (f.title.toLowerCase() !== "untitled" && tbl.headers.length > 0) {
      seenSigs.add(headerSig(tbl));
    }
  }
  const canonical = [];
  for (const { f, tbl } of parsedCache) {
    if (f.title.toLowerCase() !== "untitled") {
      canonical.push({ ...f, parsed: tbl });
    } else {
      const sig = headerSig(tbl);
      if (!seenSigs.has(sig)) {
        seenSigs.add(sig);
        canonical.push({ ...f, parsed: tbl });
      }
    }
  }
  return { canonical, skippedCount: csvFiles.length - canonical.length };
}

function inferSchemaFromCsvParsed(tbl) {
  const props = [];
  const rowCellsList = tbl.rows.map(() => ({}));
  const usedIds = new Set(["title"]);

  for (let ci = 0; ci < tbl.headers.length; ci += 1) {
    const h = tbl.headers[ci];
    const sortOrder = `c${ci + 10}`;
    if (ci === 0) {
      props.push({ id: "title", name: h || "Title", kind: "title", required: true, sort_order: "a" });
      for (let ri = 0; ri < tbl.rows.length; ri += 1) {
        rowCellsList[ri].title = { text_val: tbl.rows[ri][0] || `Row ${ri + 1}` };
      }
      continue;
    }
    const basePid = slugifyId(h, `col_${ci}`);
    let pid = basePid;
    let suf = 2;
    while (usedIds.has(pid)) {
      pid = `${basePid}_${suf++}`;
    }
    usedIds.add(pid);

    const vals = tbl.rows.map((r) => r[ci]).filter(Boolean);
    const lowH = h.trim().toLowerCase();
    const isStatusCol = lowH === "status" || lowH === "stage" || lowH === "state";

    let kind = "rich_text";
    const optMap = new Map();

    const boolParse = (v) => {
      const l = v.toLowerCase();
      if (l === "true" || l === "yes") return true;
      if (l === "false" || l === "no") return false;
      return null;
    };

    if (vals.length === 0) {
      kind = "rich_text";
    } else if (vals.every((v) => boolParse(v) !== null)) {
      kind = "checkbox";
      tbl.rows.forEach((r, ri) => {
        if (r[ci]) rowCellsList[ri][pid] = { bool_val: boolParse(r[ci]) };
      });
    } else if (vals.every((v) => /^\d{4}-\d{2}-\d{2}$/.test(v))) {
      kind = { date_prop: { include_time: false } };
      tbl.rows.forEach((r, ri) => {
        if (r[ci]) rowCellsList[ri][pid] = { date_val: { start: r[ci], end_date: null } };
      });
    } else if (vals.every((v) => /^-?\d+(?:\.\d+)?$/.test(v))) {
      kind = { number: { format: "plain" } };
      tbl.rows.forEach((r, ri) => {
        if (r[ci]) rowCellsList[ri][pid] = { number_val: r[ci] };
      });
    } else if (vals.every((v) => /^https?:\/\//i.test(v))) {
      kind = "url";
      tbl.rows.forEach((r, ri) => {
        if (r[ci]) rowCellsList[ri][pid] = { url_val: r[ci] };
      });
    } else if (vals.every(isValidEmail)) {
      kind = "email";
      tbl.rows.forEach((r, ri) => {
        if (r[ci]) rowCellsList[ri][pid] = { text_val: r[ci] };
      });
    } else {
      const distinct = [...new Set(vals)];
      if (distinct.length <= 12 && (vals.length >= 2 || isStatusCol) && distinct.every((d) => d.length <= 40)) {
        const opts = [];
        const usedOids = new Set();
        distinct.forEach((label, oi) => {
          const baseOid = slugifyId(label, `opt_${oi}`);
          let oid = baseOid;
          let s2 = 2;
          while (usedOids.has(oid)) oid = `${baseOid}_${s2++}`;
          usedOids.add(oid);
          optMap.set(label, oid);
          opts.push({ id: oid, label, color: mapOptionColor(null, oi) });
        });
        if (isStatusCol) {
          const doneIds = opts.filter((o) => isDoneStatusLabel(o.label)).map((o) => o.id);
          kind = { status: { options: opts, done_option_ids: doneIds } };
        } else {
          kind = { select: { options: opts } };
        }
        tbl.rows.forEach((r, ri) => {
          if (r[ci]) rowCellsList[ri][pid] = { select_val: { option_id: optMap.get(r[ci]) } };
        });
      } else {
        kind = "rich_text";
        tbl.rows.forEach((r, ri) => {
          if (r[ci]) rowCellsList[ri][pid] = { text_val: r[ci] };
        });
      }
    }

    if (kind === "rich_text") {
      tbl.rows.forEach((r, ri) => {
        if (r[ci]) rowCellsList[ri][pid] = { text_val: r[ci] };
      });
    }
    props.push({ id: pid, name: h || `Column ${ci + 1}`, kind, required: false, sort_order: sortOrder });
  }
  return { props, rowCellsList };
}

function inferZipPageParents(mdFiles) {
  const byStem = new Map();
  const byId = new Map();
  const byBase = new Map();
  const segsList = [];

  mdFiles.forEach((f, idx) => {
    let p = f.relPath.replaceAll("\\", "/");
    try { p = decodeURIComponent(p); } catch { p = p.replaceAll("%20", " "); }
    const segs = p.split("/").map((s) => s.trim()).filter(Boolean);
    segsList.push(segs);
    if (segs.length === 0) return;
    const lastNoExt = segs[segs.length - 1].replace(/\.(md|csv)$/i, "").trim();
    const stem = [...segs.slice(0, -1), lastNoExt].join("/").toLowerCase();
    if (stem && !byStem.has(stem)) byStem.set(stem, idx);
    if (!byBase.has(lastNoExt.toLowerCase())) byBase.set(lastNoExt.toLowerCase(), idx);
    if (f.notionId && !byId.has(f.notionId)) byId.set(f.notionId, idx);
  });

  const parents = new Map();
  segsList.forEach((segs, idx) => {
    for (let d = segs.length - 1; d >= 1; d -= 1) {
      const ancSegs = segs.slice(0, d);
      const ancStem = ancSegs.join("/").toLowerCase();
      const ancLast = ancSegs[ancSegs.length - 1];
      const ancNid = extractNotionId32(ancLast);
      const cand = byStem.get(ancStem) ?? (ancNid ? byId.get(ancNid) : undefined) ?? byBase.get(ancLast.toLowerCase());
      if (cand !== undefined && cand !== idx) {
        parents.set(idx, cand);
        break;
      }
    }
  });
  return parents;
}

function topologicalSortIndices(count, getParentIdx) {
  const visited = new Array(count).fill(0); // 0=unvisited,1=visiting,2=done
  const order = [];
  function visit(i) {
    if (visited[i] === 2) return;
    if (visited[i] === 1) return; // break cycle
    visited[i] = 1;
    const p = getParentIdx(i);
    if (p !== null && p !== undefined && p >= 0 && p < count && p !== i) visit(p);
    visited[i] = 2;
    order.push(i);
  }
  for (let i = 0; i < count; i += 1) visit(i);
  return order;
}

function richTextToMd(spans, ctx) {
  if (!Array.isArray(spans) || spans.length === 0) return "";
  return spans
    .map((span) => {
      let txt = span?.plain_text ?? "";
      if (span?.type === "mention" && span.mention) {
        const m = span.mention;
        if (m.type === "page" && m.page?.id) {
          const vpg = ctx.pageIdMap.get(normId(m.page.id));
          if (vpg) return `[[${vpg}|${txt || "Page"}]]`;
        } else if (m.type === "database" && m.database?.id) {
          const dbInfo = ctx.dbMap.get(normId(m.database.id));
          if (dbInfo?.hostPageId) return `[[${dbInfo.hostPageId}|${txt || "Database"}]]`;
        } else if (m.type === "date" && m.date?.start) {
          txt = m.date.end ? `${m.date.start} → ${m.date.end}` : m.date.start;
        }
      }
      if (span?.type === "equation" && span.equation?.expression) {
        return `$${span.equation.expression}$`;
      }
      const ann = span?.annotations ?? {};
      const lead = txt.match(/^\s*/)?.[0] ?? "";
      const trail = txt.match(/\s*$/)?.[0] ?? "";
      let core = txt.trim();
      if (!core) return txt;
      if (ann.code) core = `\`${core}\``;
      if (ann.bold) core = `**${core}**`;
      if (ann.italic) core = `*${core}*`;
      if (ann.strikethrough) core = `~~${core}~~`;
      if (span?.href) {
        const linkedNid = extractNotionId32(span.href);
        const vpg = linkedNid ? ctx.pageIdMap.get(linkedNid) : null;
        if (vpg) return `${lead}[[${vpg}|${txt.trim() || "Link"}]]${trail}`;
        return `${lead}[${core}](${span.href})${trail}`;
      }
      return `${lead}${core}${trail}`;
    })
    .join("");
}

function plainTextOfRichText(spans) {
  if (!Array.isArray(spans)) return "";
  return spans.map((s) => s?.plain_text ?? "").join("");
}

async function fetchBlockChildrenRecursive(baseUrl, token, rootBlockId) {
  const blocks = [];
  let cursor = undefined;
  do {
    const q = cursor ? `?page_size=100&start_cursor=${encodeURIComponent(cursor)}` : "?page_size=100";
    const data = await notionFetch(baseUrl, token, "GET", `/v1/blocks/${encodeURIComponent(rootBlockId)}/children${q}`);
    for (const blk of data.results ?? []) {
      if (blk.has_children && blk.type !== "child_page" && blk.type !== "child_database") {
        blk._children = await fetchBlockChildrenRecursive(baseUrl, token, blk.id);
      } else {
        blk._children = [];
      }
      blocks.push(blk);
    }
    cursor = data.has_more ? data.next_cursor : undefined;
  } while (cursor);
  return blocks;
}

async function resolveNotionMediaAttachment(mediaObj, pageNotionId, blockId, fallbackName, ctx) {
  if (!mediaObj) return null;
  if (mediaObj.type === "external" && mediaObj.external?.url) {
    return { externalUrl: mediaObj.external.url, filename: fallbackName || "asset" };
  }
  const fileUrl = mediaObj.file?.url ?? "";
  let urlBasename = fallbackName;
  try {
    if (fileUrl) urlBasename = decodeURIComponent(path.posix.basename(new URL(fileUrl).pathname));
  } catch {}
  const filename = safeFilename(mediaObj.name || urlBasename, fallbackName || "file.bin");
  if (ctx.skipAttachments || ctx.dryRun) {
    ctx.stats.attachments_planned += 1;
    return { pendingLabel: filename };
  }
  const cacheKey = `${normId(pageNotionId)}:${filename}:${blockId || fileUrl.split("?")[0]}`;
  if (ctx.state.attachments[cacheKey]) {
    return { attId: ctx.state.attachments[cacheKey], filename };
  }

  const vellumPageId = ctx.pageIdMap.get(normId(pageNotionId));
  if (!vellumPageId) return { pendingLabel: filename };

  // Hybrid priority: match local file from --zip before downloading signed Notion S3 URL
  const zipMatch = ctx.zipIndex?.resolveAsset(pageNotionId, urlBasename) ??
    ctx.zipIndex?.resolveAsset(pageNotionId, filename);

  let uploadPath = zipMatch?.absPath ?? null;
  let tempPath = null;
  try {
    if (!uploadPath && fileUrl) {
      tempPath = path.join(os.tmpdir(), `vlm-dl-${Date.now()}-${Math.random().toString(36).slice(2, 8)}-${filename}`);
      const dl = await fetch(fileUrl);
      if (!dl.ok) {
        ctx.warnings.push(`Attachment fetch failed (${dl.status}) for ${filename}`);
        return { externalUrl: fileUrl, filename };
      }
      const arr = Buffer.from(await dl.arrayBuffer());
      if (arr.length > ctx.maxAttachmentBytes) {
        ctx.warnings.push(`Skipped attachment exceeding ${ctx.maxAttachmentMb} MiB limit`);
        return { pendingLabel: filename };
      }
      fs.writeFileSync(tempPath, arr);
      uploadPath = tempPath;
    } else if (zipMatch && zipMatch.sizeBytes > ctx.maxAttachmentBytes) {
      ctx.warnings.push(`Skipped attachment exceeding ${ctx.maxAttachmentMb} MiB limit`);
      return { pendingLabel: filename };
    }

    if (!uploadPath) return { pendingLabel: filename };
    const up = await ctx.vellum.uploadFileAttachment(
      vellumPageId,
      uploadPath,
      filename,
      guessContentType(filename)
    );
    if (up.skipped) return { pendingLabel: filename };
    ctx.state.attachments[cacheKey] = up.attId;
    ctx.stats.attachments_uploaded += 1;
    if (zipMatch) ctx.stats.attachments_from_zip += 1;
    ctx.saveState();
    return { attId: up.attId, filename };
  } finally {
    if (tempPath && fs.existsSync(tempPath)) fs.unlinkSync(tempPath);
  }
}

async function serializeNotionBlocks(blocks, ownerNotionPageId, ctx, listState = { num: 0 }) {
  const parts = [];
  for (const blk of blocks ?? []) {
    const t = blk.type;
    const obj = blk[t] ?? {};
    if (t !== "numbered_list_item") listState.num = 0;

    if (t === "paragraph") {
      const txt = richTextToMd(obj.rich_text, ctx);
      if (txt) parts.push(txt);
      if (blk._children?.length) {
        const sub = await serializeNotionBlocks(blk._children, ownerNotionPageId, ctx);
        if (sub) parts.push(sub);
      }
    } else if (t === "heading_1" || t === "heading_2" || t === "heading_3" || t === "heading_4") {
      const lvl = Number.parseInt(t.slice(-1), 10);
      const txt = richTextToMd(obj.rich_text, ctx);
      if (obj.is_toggleable && blk._children?.length) {
        const sub = await serializeNotionBlocks(blk._children, ownerNotionPageId, ctx);
        parts.push(`:::toggle ${txt || "Section"}\n${sub}\n:::`);
      } else if (txt) {
        parts.push(`${"#".repeat(lvl)} ${txt}`);
      }
    } else if (t === "bulleted_list_item") {
      const txt = richTextToMd(obj.rich_text, ctx);
      parts.push(`- ${txt}`);
      if (blk._children?.length) {
        const sub = await serializeNotionBlocks(blk._children, ownerNotionPageId, ctx);
        if (sub) parts.push(sub);
      }
    } else if (t === "numbered_list_item") {
      listState.num += 1;
      const txt = richTextToMd(obj.rich_text, ctx);
      parts.push(`${listState.num}. ${txt}`);
      if (blk._children?.length) {
        const sub = await serializeNotionBlocks(blk._children, ownerNotionPageId, ctx);
        if (sub) parts.push(sub);
      }
    } else if (t === "to_do") {
      const txt = richTextToMd(obj.rich_text, ctx);
      parts.push(`- [${obj.checked ? "x" : " "}] ${txt}`);
      if (blk._children?.length) {
        const sub = await serializeNotionBlocks(blk._children, ownerNotionPageId, ctx);
        if (sub) parts.push(sub);
      }
    } else if (t === "quote") {
      const txt = richTextToMd(obj.rich_text, ctx) || "";
      parts.push(txt.split("\n").map((l) => `> ${l}`).join("\n"));
    } else if (t === "callout") {
      const ic = obj.icon?.type === "emoji" ? obj.icon.emoji : "info";
      const head = `> [!info|${ic}]`;
      const txt = richTextToMd(obj.rich_text, ctx);
      const childTxt = blk._children?.length
        ? await serializeNotionBlocks(blk._children, ownerNotionPageId, ctx)
        : "";
      const bodyLines = [txt, childTxt].filter(Boolean).join("\n").split("\n").map((l) => `> ${l}`);
      parts.push([head, ...bodyLines].join("\n"));
    } else if (t === "transcription") {
      const head = `> [!info|transcript]`;
      const txt = richTextToMd(obj.rich_text ?? obj.summary?.rich_text ?? [], ctx);
      const childTxt = blk._children?.length
        ? await serializeNotionBlocks(blk._children, ownerNotionPageId, ctx)
        : "";
      const bodyLines = [txt, childTxt].filter(Boolean).join("\n").split("\n").map((l) => `> ${l}`);
      parts.push(bodyLines.length > 0 ? [head, ...bodyLines].join("\n") : `${head}\n> (Transcript)`);
    } else if (t === "code") {
      const lang = String(obj.language ?? "").replace(/\s+/g, "");
      const code = plainTextOfRichText(obj.rich_text);
      parts.push(`\`\`\`${lang}\n${code}\n\`\`\``);
    } else if (t === "divider") {
      parts.push("---");
    } else if (t === "table_of_contents") {
      parts.push("<!-- toc -->");
    } else if (t === "toggle") {
      const sum = richTextToMd(obj.rich_text, ctx) || "Toggle";
      const body = blk._children?.length
        ? await serializeNotionBlocks(blk._children, ownerNotionPageId, ctx)
        : "";
      parts.push(`:::toggle ${sum.replace(/\n/g, " ")}\n${body}\n:::`);
    } else if (t === "table") {
      const rows = (blk._children ?? []).filter((c) => c.type === "table_row");
      if (rows.length > 0) {
        const formatRow = (cells) =>
          `| ${(cells ?? []).map((c) => richTextToMd(c, ctx).replace(/\|/g, "\\|").replace(/\n/g, " ")).join(" | ")} |`;
        const colCount = Math.max(1, rows[0]?.table_row?.cells?.length ?? 1);
        const sep = `| ${Array.from({ length: colCount }, () => "---").join(" | ")} |`;
        const mdRows = [formatRow(rows[0].table_row.cells), sep, ...rows.slice(1).map((r) => formatRow(r.table_row.cells))];
        parts.push(mdRows.join("\n"));
      }
    } else if (t === "child_page") {
      const vpg = ctx.pageIdMap.get(normId(blk.id));
      const title = obj.title || "Subpage";
      parts.push(vpg ? `[[${vpg}|${title}]]` : `- ${title}`);
    } else if (t === "child_database") {
      const dbInfo = ctx.dbMap.get(normId(blk.id));
      if (dbInfo?.dbId) parts.push(`<!-- db_embed:${dbInfo.dbId} -->`);
      else parts.push(`- ${obj.title || "Database"}`);
    } else if (t === "image" || t === "file" || t === "pdf" || t === "video" || t === "audio") {
      const caption = plainTextOfRichText(obj.caption).trim();
      const uploaded = await resolveNotionMediaAttachment(
        obj,
        ownerNotionPageId,
        blk.id,
        `${t}.bin`,
        ctx
      );
      if (uploaded?.attId) {
        if (t === "image") parts.push(`![${caption || uploaded.filename}](vellum://attachment/${uploaded.attId})`);
        else parts.push(`[${caption || uploaded.filename}](vellum://attachment/${uploaded.attId})`);
      } else if (uploaded?.externalUrl) {
        if (t === "image") parts.push(`![${caption || "image"}](${uploaded.externalUrl})`);
        else parts.push(`[${caption || uploaded.filename}](${uploaded.externalUrl})`);
      }
    } else if (t === "bookmark" || t === "link_preview" || t === "embed") {
      const url = obj.url ?? "";
      const caption = plainTextOfRichText(obj.caption).trim();
      if (url) parts.push(`[${caption || url}](${url})`);
    } else if (t === "equation" && obj.expression) {
      parts.push(`$$\n${obj.expression}\n$$`);
    } else if (blk._children?.length) {
      const sub = await serializeNotionBlocks(blk._children, ownerNotionPageId, ctx);
      if (sub) parts.push(sub);
    }
  }
  return parts.filter(Boolean).join("\n\n");
}

function getNotionPageTitle(pg) {
  const props = Object.values(pg?.properties ?? {});
  for (const p of props) {
    if (p?.type === "title") {
      const txt = plainTextOfRichText(p.title).trim();
      if (txt) return txt;
    }
  }
  return "Untitled Page";
}

function getNotionDbTitle(db) {
  const txt = plainTextOfRichText(db?.title ?? []).trim();
  return txt || "Untitled Database";
}

function getNotionIconText(obj) {
  if (!obj?.icon) return null;
  if (obj.icon.type === "emoji") return obj.icon.emoji || null;
  return null;
}

function mapNumberFormat(notionFmt) {
  const f = String(notionFmt ?? "").toLowerCase();
  if (f === "percent") return "percent";
  if (["dollar", "canadian_dollar", "euro", "pound", "yen", "ruble", "rupee", "won", "yuan", "franc", "peso", "real", "lira", "shekel", "ringgit"].includes(f)) {
    return "currency";
  }
  return "plain";
}

function mapRollupAgg(notionFn) {
  const f = String(notionFn ?? "").toLowerCase();
  if (f === "count") return "count_all";
  if (f === "sum") return "sum_values";
  if (f === "min" || f === "earliest_date") return "min_value";
  if (f === "max" || f === "latest_date") return "max_value";
  if (f === "percent_per_group" || f === "percent_checked" || f === "percent_not_empty") {
    return "percent_per_group";
  }
  return "count_values";
}

function buildNotionDbPlan(db, rows, validDbIds, warnings) {
  const notionPropEntries = Object.entries(db.properties ?? {});
  const propMeta = [];
  const usedVellumIds = new Set();

  // First reserve "title" for the Title column
  const titleEntry = notionPropEntries.find(([, def]) => def.type === "title");
  if (titleEntry) usedVellumIds.add("title");

  for (let idx = 0; idx < notionPropEntries.length; idx += 1) {
    const [propName, def] = notionPropEntries[idx];
    const isTitle = def.type === "title" && titleEntry && propName === titleEntry[0];
    let vellumId = isTitle ? "title" : slugifyId(propName, `prop_${idx}`);
    if (!isTitle) {
      let n = 2;
      while (usedVellumIds.has(vellumId)) vellumId = `${slugifyId(propName, "prop")}_${n++}`;
      usedVellumIds.add(vellumId);
    }

    // Collect observed select/multi_select/status options from rows too so nothing misses schema validation
    const baseOpts = (def[def.type]?.options ?? []).map((o, oi) => ({
      id: slugifyId(o.name, `opt_${oi}`),
      rawName: o.name,
      notionId: o.id,
      label: String(o.name ?? "").trim() || `Option ${oi + 1}`,
      color: mapOptionColor(o.color, oi),
    }));

    if (def.type === "select" || def.type === "multi_select" || def.type === "status") {
      const seenLabels = new Set(baseOpts.map((o) => o.label));
      for (const r of rows) {
        const cv = r.properties?.[propName];
        if (!cv) continue;
        if (def.type === "select" && cv.select?.name && !seenLabels.has(cv.select.name)) {
          seenLabels.add(cv.select.name);
          baseOpts.push({ id: slugifyId(cv.select.name, "opt"), rawName: cv.select.name, notionId: cv.select.id, label: cv.select.name, color: mapOptionColor(cv.select.color, baseOpts.length) });
        } else if (def.type === "status" && cv.status?.name && !seenLabels.has(cv.status.name)) {
          seenLabels.add(cv.status.name);
          baseOpts.push({ id: slugifyId(cv.status.name, "opt"), rawName: cv.status.name, notionId: cv.status.id, label: cv.status.name, color: mapOptionColor(cv.status.color, baseOpts.length) });
        } else if (def.type === "multi_select") {
          for (const ms of cv.multi_select ?? []) {
            if (ms?.name && !seenLabels.has(ms.name)) {
              seenLabels.add(ms.name);
              baseOpts.push({ id: slugifyId(ms.name, "opt"), rawName: ms.name, notionId: ms.id, label: ms.name, color: mapOptionColor(ms.color, baseOpts.length) });
            }
          }
        }
      }
      if (baseOpts.length === 0) {
        baseOpts.push({ id: "default", rawName: "Default", notionId: null, label: "Default", color: "gray" });
      }
    }

    // Deduplicate option IDs
    const usedOptIds = new Set();
    const labelToOptId = new Map();
    const cleanOpts = baseOpts.map((o, oi) => {
      let oid = o.id || `opt_${oi}`;
      let suf = 2;
      while (usedOptIds.has(oid)) oid = `${o.id}_${suf++}`;
      usedOptIds.add(oid);
      labelToOptId.set(o.label, oid);
      if (o.notionId) labelToOptId.set(`nid:${o.notionId}`, oid);
      return { id: oid, label: o.label, color: o.color };
    });

    propMeta.push({
      notionPropId: def.id,
      notionPropName: propName,
      notionType: def.type,
      def,
      vellumId,
      sortOrder: isTitle ? "a" : `c${idx + 10}`,
      options: cleanOpts,
      labelToOptId,
    });
  }

  // Fallback synthetic Title if database has zero title columns
  if (!titleEntry) {
    propMeta.unshift({
      notionPropId: "__synthetic_title__",
      notionPropName: "Title",
      notionType: "title",
      def: { type: "title" },
      vellumId: "title",
      sortOrder: "a",
      options: [],
      labelToOptId: new Map(),
    });
  }

  const baseProps = [];
  const deferredProps = [];

  for (const pm of propMeta) {
    const t = pm.notionType;
    const d = pm.def;
    let baseKind = null;
    if (t === "title") baseKind = "title";
    else if (t === "rich_text" || t === "phone_number" || t === "place" || t === "verification") baseKind = "rich_text";
    else if (t === "number") baseKind = { number: { format: mapNumberFormat(d.number?.format) } };
    else if (t === "date") baseKind = { date_prop: { include_time: false } };
    else if (t === "select") baseKind = { select: { options: pm.options } };
    else if (t === "multi_select") baseKind = { multi_select: { options: pm.options } };
    else if (t === "status") {
      const doneNotionIds = new Set();
      for (const g of d.status?.groups ?? []) {
        if (String(g.name ?? "").toLowerCase().includes("complete")) {
          for (const oid of g.option_ids ?? []) doneNotionIds.add(oid);
        }
      }
      const doneIds = [];
      for (const o of pm.options) {
        const matchingNid = [...pm.labelToOptId.entries()].find(([k, vid]) => k.startsWith("nid:") && vid === o.id)?.[0]?.slice(4);
        if ((matchingNid && doneNotionIds.has(matchingNid)) || isDoneStatusLabel(o.label)) {
          doneIds.push(o.id);
        }
      }
      baseKind = { status: { options: pm.options, done_option_ids: doneIds } };
    } else if (t === "checkbox") baseKind = "checkbox";
    else if (t === "people") baseKind = "person";
    else if (t === "email") baseKind = "email";
    else if (t === "files") baseKind = "file_list";
    else if (t === "url") baseKind = "url";
    else if (t === "unique_id") {
      const pfx = String(d.unique_id?.prefix ?? "ID").replace(/\s+/g, "").slice(0, 24) || "ID";
      baseKind = { unique_id: { prefix: pfx } };
    } else if (t === "created_time") baseKind = "created_time";
    else if (t === "created_by") baseKind = "created_by";
    else if (t === "last_edited_time") baseKind = "last_edited_time";
    else if (t === "last_edited_by") baseKind = "last_edited_by";
    else if (t === "relation" || t === "rollup" || t === "formula") {
      if (t === "relation") {
        const tgtNid = normId(d.relation?.database_id);
        if (!tgtNid || !validDbIds.has(tgtNid)) {
          warnings.push(`Relation property '${pm.vellumId}' targets unshared database; downgraded to rich_text`);
          baseKind = "rich_text";
        } else {
          deferredProps.push(pm);
        }
      } else {
        deferredProps.push(pm);
      }
    } else {
      baseKind = "rich_text";
    }

    if (baseKind !== null) {
      baseProps.push({
        id: pm.vellumId,
        name: pm.notionPropName,
        kind: baseKind,
        required: pm.notionType === "title",
        sort_order: pm.sortOrder,
      });
    }
  }

  return { propMeta, baseProps, deferredProps };
}

function buildFinalPropsForDb(plan, dbId, ctx) {
  const out = [...plan.baseProps];
  const byNotionId = new Map();
  const byNotionName = new Map();
  for (const pm of plan.propMeta) {
    if (pm.notionPropId) byNotionId.set(pm.notionPropId, pm);
    byNotionName.set(pm.notionPropName, pm);
  }
  const activeVellumIds = new Set(out.map((p) => p.id));

  // Pass A: Relations
  for (const pm of plan.deferredProps) {
    if (pm.notionType !== "relation") continue;
    const rel = pm.def.relation ?? {};
    const tgtNid = normId(rel.database_id);
    const tgtDb = ctx.dbStateByNotionId(tgtNid);
    if (!tgtDb) continue;
    let invVellumId = null;
    if (rel.type === "dual_property" && rel.dual_property?.synced_property_id) {
      const tgtPlan = ctx.planByNotionDbId.get(tgtNid);
      const matchInv = tgtPlan?.propMeta.find((x) => x.notionPropId === rel.dual_property.synced_property_id);
      if (matchInv) invVellumId = matchInv.vellumId;
    } else if (rel.synced_property_id) {
      const tgtPlan = ctx.planByNotionDbId.get(tgtNid);
      const matchInv = tgtPlan?.propMeta.find((x) => x.notionPropId === rel.synced_property_id);
      if (matchInv) invVellumId = matchInv.vellumId;
    }
    out.push({
      id: pm.vellumId,
      name: pm.notionPropName,
      kind: { relation: { target_db_id: tgtDb.dbId, inverse_prop_id: invVellumId } },
      required: false,
      sort_order: pm.sortOrder,
    });
    activeVellumIds.add(pm.vellumId);
  }

  // Pass B: Rollups
  for (const pm of plan.deferredProps) {
    if (pm.notionType !== "rollup") continue;
    const r = pm.def.rollup ?? {};
    const relPm = byNotionId.get(r.relation_property_id) ?? byNotionName.get(r.relation_property_name);
    if (!relPm || !activeVellumIds.has(relPm.vellumId)) {
      ctx.warnings.push(`Rollup '${pm.vellumId}' skipped (missing relation source)`);
      continue;
    }
    const relTargetNid = normId(relPm.def.relation?.database_id);
    const tgtPlan = ctx.planByNotionDbId.get(relTargetNid);
    const tgtPm =
      tgtPlan?.propMeta.find((x) => x.notionPropId === r.rollup_property_id) ??
      tgtPlan?.propMeta.find((x) => x.notionPropName === r.rollup_property_name);
    const targetPropId = tgtPm?.vellumId ?? slugifyId(r.rollup_property_name, "title");
    out.push({
      id: pm.vellumId,
      name: pm.notionPropName,
      kind: {
        rollup: {
          relation_prop_id: relPm.vellumId,
          target_prop_id: targetPropId,
          agg: mapRollupAgg(r.function),
        },
      },
      required: false,
      sort_order: pm.sortOrder,
    });
    activeVellumIds.add(pm.vellumId);
  }

  // Pass C: Formulas
  const formulas = [];
  for (const pm of plan.deferredProps) {
    if (pm.notionType !== "formula") continue;
    const expr = String(pm.def.formula?.expression ?? "").trim();
    if (!expr) continue;
    const propDef = {
      id: pm.vellumId,
      name: pm.notionPropName,
      kind: { formula: { expression: expr, format: "plain" } },
      required: false,
      sort_order: pm.sortOrder,
    };
    out.push(propDef);
    formulas.push(propDef);
  }

  return { props: out, formulas };
}

async function extractRowBaseAndRelCells(notionRow, plan, ctx, allowFilesUpload) {
  const baseCells = {};
  const relCells = {};
  const fallbackTitle = getNotionPageTitle(notionRow);

  for (const pm of plan.propMeta) {
    const pv = notionRow.properties?.[pm.notionPropName];
    if (pm.vellumId === "title") {
      const txt = pv?.type === "title" ? plainTextOfRichText(pv.title).trim() : fallbackTitle;
      baseCells.title = { text_val: txt || "Untitled" };
      continue;
    }
    if (!pv) continue;
    const t = pm.notionType;
    if (t === "unique_id" || t === "formula" || t === "rollup" || t === "created_time" || t === "created_by" || t === "last_edited_time" || t === "last_edited_by") {
      continue;
    }
    if (t === "rich_text") {
      const txt = plainTextOfRichText(pv.rich_text).trim();
      if (txt) baseCells[pm.vellumId] = { text_val: txt };
    } else if (t === "phone_number") {
      const s = String(pv.phone_number ?? "").trim();
      if (s) baseCells[pm.vellumId] = { text_val: s };
    } else if (t === "place") {
      const lbl = pv.place?.name || pv.place?.address || "";
      if (String(lbl).trim()) baseCells[pm.vellumId] = { text_val: String(lbl).trim() };
    } else if (t === "verification") {
      const st = pv.verification?.state ?? "";
      if (st) baseCells[pm.vellumId] = { text_val: st };
    } else if (t === "number") {
      if (pv.number !== null && pv.number !== undefined && Number.isFinite(Number(pv.number))) {
        baseCells[pm.vellumId] = { number_val: String(pv.number) };
      }
    } else if (t === "date") {
      if (pv.date?.start) {
        const start = String(pv.date.start).slice(0, 10);
        const endDate = pv.date.end ? String(pv.date.end).slice(0, 10) : null;
        if (/^\d{4}-\d{2}-\d{2}$/.test(start)) {
          baseCells[pm.vellumId] = {
            date_val: {
              start,
              end_date: endDate && /^\d{4}-\d{2}-\d{2}$/.test(endDate) && endDate >= start ? endDate : null,
            },
          };
        }
      }
    } else if (t === "select") {
      if (pv.select?.name) {
        const oid = pm.labelToOptId.get(pv.select.name) ?? pm.labelToOptId.get(`nid:${pv.select.id}`);
        if (oid) baseCells[pm.vellumId] = { select_val: { option_id: oid } };
      }
    } else if (t === "status") {
      if (pv.status?.name) {
        const oid = pm.labelToOptId.get(pv.status.name) ?? pm.labelToOptId.get(`nid:${pv.status.id}`);
        if (oid) baseCells[pm.vellumId] = { select_val: { option_id: oid } };
      }
    } else if (t === "multi_select") {
      const oids = (pv.multi_select ?? [])
        .map((m) => pm.labelToOptId.get(m.name) ?? pm.labelToOptId.get(`nid:${m.id}`))
        .filter(Boolean);
      if (oids.length > 0) baseCells[pm.vellumId] = { multi_select_val: { option_ids: [...new Set(oids)] } };
    } else if (t === "checkbox") {
      baseCells[pm.vellumId] = { bool_val: Boolean(pv.checkbox) };
    } else if (t === "people") {
      const pids = (pv.people ?? []).map((u) => u?.person?.email || u?.name || u?.id).filter(Boolean);
      if (pids.length > 0) baseCells[pm.vellumId] = { principal_val: pids };
    } else if (t === "email") {
      const em = String(pv.email ?? "").trim();
      if (em) {
        if (isValidEmail(em)) baseCells[pm.vellumId] = { text_val: em };
        else ctx.warnings.push(`Skipped invalid email cell in property '${pm.vellumId}'`);
      }
    } else if (t === "url") {
      let u = String(pv.url ?? "").trim();
      if (u) {
        if (!/^https?:\/\//i.test(u) && /^[a-z0-9.-]+\.[a-z]{2,}/i.test(u)) u = `https://${u}`;
        if (/^https?:\/\//i.test(u)) baseCells[pm.vellumId] = { url_val: u };
        else ctx.warnings.push(`Skipped non-http URL cell in property '${pm.vellumId}'`);
      }
    } else if (t === "files") {
      if (allowFilesUpload) {
        const aids = [];
        for (const fobj of pv.files ?? []) {
          const up = await resolveNotionMediaAttachment(
            fobj,
            notionRow.id,
            `fileprop_${pm.vellumId}`,
            safeFilename(fobj.name || "attachment.bin"),
            ctx
          );
          if (up?.attId) aids.push(up.attId);
        }
        if (aids.length > 0) baseCells[pm.vellumId] = { files_val: { attachment_ids: aids } };
      }
    } else if (t === "relation") {
      const ids = (pv.relation ?? []).map((x) => normId(x.id)).filter(Boolean);
      if (ids.length > 0) relCells[pm.vellumId] = ids;
    }
  }
  return { baseCells, relCells };
}

async function runPool(items, concurrency, fn) {
  let idx = 0;
  const workers = Array.from({ length: Math.min(concurrency, Math.max(1, items.length)) }, async () => {
    while (idx < items.length) {
      const cur = items[idx++];
      await fn(cur);
    }
  });
  await Promise.all(workers);
}

async function loadNotionApiData(baseUrl, token, concurrency) {
  const pages = [];
  const dbs = [];
  let cursor = undefined;
  do {
    const body = { page_size: 100 };
    if (cursor) body.start_cursor = cursor;
    const data = await notionFetch(baseUrl, token, "POST", "/v1/search", body);
    for (const item of data.results ?? []) {
      if (item.object === "database") dbs.push(item);
      else if (item.object === "page") pages.push(item);
    }
    cursor = data.has_more ? data.next_cursor : undefined;
  } while (cursor);

  // Deduplicate databases by normalized ID and ensure full schemas
  const dbById = new Map();
  for (const db of dbs) {
    dbById.set(normId(db.id), db);
  }

  // Query rows for each database so we don't miss rows unreturned by search
  const docPageById = new Map();
  const rowPageById = new Map();
  const rowsByDbId = new Map();

  for (const pg of pages) {
    const nid = normId(pg.id);
    if (pg.parent?.type === "database_id") {
      rowPageById.set(nid, pg);
      const dbNid = normId(pg.parent.database_id);
      if (!rowsByDbId.has(dbNid)) rowsByDbId.set(dbNid, []);
      rowsByDbId.get(dbNid).push(pg);
    } else {
      docPageById.set(nid, pg);
    }
  }

  await runPool([...dbById.keys()], concurrency, async (dbNid) => {
    const rawDbId = dbById.get(dbNid).id;
    let qCursor = undefined;
    do {
      const qBody = { page_size: 100 };
      if (qCursor) qBody.start_cursor = qCursor;
      const res = await notionFetch(baseUrl, token, "POST", `/v1/databases/${encodeURIComponent(rawDbId)}/query`, qBody);
      for (const r of res.results ?? []) {
        const rid = normId(r.id);
        rowPageById.set(rid, r);
      }
      qCursor = res.has_more ? res.next_cursor : undefined;
    } while (qCursor);
  });

  // Rebuild rowsByDbId cleanly from rowPageById so search + query results never duplicate
  rowsByDbId.clear();
  for (const r of rowPageById.values()) {
    const dbNid = normId(r.parent?.database_id);
    if (!rowsByDbId.has(dbNid)) rowsByDbId.set(dbNid, []);
    rowsByDbId.get(dbNid).push(r);
  }

  // Fetch blocks for all doc pages AND all DB row pages that might have body content
  const allReadablePages = [...docPageById.values(), ...rowPageById.values()];
  const blocksByPageId = new Map();
  let scannedCount = 0;
  await runPool(allReadablePages, concurrency, async (pg) => {
    const children = await fetchBlockChildrenRecursive(baseUrl, token, pg.id);
    blocksByPageId.set(normId(pg.id), children);
    scannedCount += 1;
    if (scannedCount % 100 === 0 || scannedCount === allReadablePages.length) {
      console.error(`[notion-migrate] scanned blocks: ${scannedCount}/${allReadablePages.length} pages`);
    }
  });

  return { dbById, docPageById, rowPageById, rowsByDbId, blocksByPageId };
}

function loadState(statePath, dryRun) {
  if (!dryRun && statePath && fs.existsSync(statePath)) {
    try {
      const parsed = JSON.parse(fs.readFileSync(statePath, "utf8"));
      return {
        collectionId: parsed.collectionId ?? null,
        pageIds: parsed.pageIds ?? {},
        pageVersions: parsed.pageVersions ?? {},
        dbIds: parsed.dbIds ?? {},
        rowIds: parsed.rowIds ?? {},
        attachments: parsed.attachments ?? {},
        coversDone: parsed.coversDone ?? {},
        markdownSynced: parsed.markdownSynced ?? {},
        continuationPages: parsed.continuationPages ?? {},
      };
    } catch {}
  }
  return {
    collectionId: null,
    pageIds: {},
    pageVersions: {},
    dbIds: {},
    rowIds: {},
    attachments: {},
    coversDone: {},
    markdownSynced: {},
    continuationPages: {},
  };
}

function writeStateAtomic(statePath, state, dryRun) {
  if (dryRun || !statePath) return;
  fs.mkdirSync(path.dirname(statePath), { recursive: true });
  const tmp = `${statePath}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(tmp, statePath);
}

async function rewriteZipMarkdownAndUploadAssets(mdItem, ownerVpgId, zipPageIdMap, zipDbIdMap, ctx) {
  const lines = mdItem.markdown.replace(/\r\n/g, "\n").replace(/\r/g, "\n").split("\n");
  const outLines = [];
  const mdDir = path.posix.dirname(mdItem.relPath);

  for (const rawLine of lines) {
    let line = rawLine;
    // Handle image links `![alt](href)`
    const imgMatch = line.trim().match(/^!\[([^\]]*)\]\(([^)]+)\)$/);
    if (imgMatch && !/^https?:\/\//i.test(imgMatch[2]) && !imgMatch[2].startsWith("vellum://")) {
      const cap = imgMatch[1].trim();
      const rawHref = imgMatch[2].split("#")[0].split("?")[0].trim();
      const resolvedRel = mdDir && mdDir !== "." ? path.posix.normalize(`${mdDir}/${rawHref}`) : rawHref;
      const asset = ctx.zipIndex.resolveAsset(mdItem.notionId, path.posix.basename(rawHref), resolvedRel) ??
        ctx.zipIndex.resolveAsset(null, path.posix.basename(decodeURIComponent(rawHref)), resolvedRel);
      if (asset && !ctx.skipAttachments && !ctx.dryRun && asset.sizeBytes <= ctx.maxAttachmentBytes) {
        const key = `zip:${normId(mdItem.notionId || mdItem.relPath)}:${asset.relPath}`;
        let attId = ctx.state.attachments[key];
        if (!attId) {
          const up = await ctx.vellum.uploadFileAttachment(ownerVpgId, asset.absPath, asset.filename, asset.contentType);
          if (!up.skipped) {
            attId = up.attId;
            ctx.state.attachments[key] = attId;
            ctx.stats.attachments_uploaded += 1;
            ctx.stats.attachments_from_zip += 1;
            ctx.saveState();
          }
        }
        if (attId) {
          outLines.push(`![${cap || asset.filename}](vellum://attachment/${attId})`);
          continue;
        }
      } else if (asset && (ctx.skipAttachments || ctx.dryRun)) {
        ctx.stats.attachments_planned += 1;
      }
    }

    // Rewrite standalone `[Label](href)` or `[[Title]]`
    const trimmed = line.trim();
    const wikiMatch = trimmed.match(/^\[\[([^|\]]+)\]\]$/);
    if (wikiMatch) {
      const inner = wikiMatch[1];
      const nid = extractNotionId32(inner);
      const targetId = (nid && zipPageIdMap.get(`id:${nid}`)) ||
        zipPageIdMap.get(`title:${stripNotionIdSuffix(inner).toLowerCase()}`);
      if (targetId) {
        outLines.push(`[[${targetId}|${stripNotionIdSuffix(inner) || "Page"}]]`);
        continue;
      }
    }

    const linkMatch = trimmed.match(/^(?!!)\[([^\]]+)\]\(([^)]+)\)$/);
    if (linkMatch) {
      const label = linkMatch[1].trim();
      const href = linkMatch[2].trim();
      const hrefClean = href.split("#")[0].split("?")[0].trim();
      const nid = extractNotionId32(hrefClean);
      if (/\.csv$/i.test(hrefClean)) {
        const did = (nid && zipDbIdMap.get(`id:${nid}`)) ||
          zipDbIdMap.get(`title:${stripNotionIdSuffix(hrefClean).toLowerCase()}`);
        if (did) {
          outLines.push(`<!-- db_embed:${did} -->`);
          continue;
        }
      } else if (!/^https?:\/\//i.test(hrefClean)) {
        const pid = (nid && zipPageIdMap.get(`id:${nid}`)) ||
          zipPageIdMap.get(`title:${stripNotionIdSuffix(hrefClean).toLowerCase()}`);
        if (pid) {
          outLines.push(`[[${pid}|${label || "Page"}]]`);
          continue;
        }
        const rawHref = hrefClean;
        const resolvedRel = mdDir && mdDir !== "." ? path.posix.normalize(`${mdDir}/${rawHref}`) : rawHref;
        const asset = ctx.zipIndex.resolveAsset(mdItem.notionId, path.posix.basename(rawHref), resolvedRel);
        if (asset && !ctx.skipAttachments && !ctx.dryRun && asset.sizeBytes <= ctx.maxAttachmentBytes) {
          const key = `zip:${normId(mdItem.notionId || mdItem.relPath)}:${asset.relPath}`;
          let attId = ctx.state.attachments[key];
          if (!attId) {
            const up = await ctx.vellum.uploadFileAttachment(ownerVpgId, asset.absPath, asset.filename, asset.contentType);
            if (!up.skipped) {
              attId = up.attId;
              ctx.state.attachments[key] = attId;
              ctx.stats.attachments_uploaded += 1;
              ctx.stats.attachments_from_zip += 1;
              ctx.saveState();
            }
          }
          if (attId) {
            outLines.push(`[${label || asset.filename}](vellum://attachment/${attId})`);
            continue;
          }
        }
      }
    }
    outLines.push(line);
  }
  return outLines.join("\n");
}

function splitMarkdownIntoChunks(markdown, maxLines = 260, maxBytes = 20000) {
  const clean = String(markdown ?? "").replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  if (!clean.trim()) return [];
  const lines = clean.split("\n");
  if (lines.length <= maxLines && Buffer.byteLength(clean, "utf8") <= maxBytes) {
    return [clean];
  }

  const chunks = [];
  let cur = [];
  let curBytes = 0;
  let inFence = false;
  let detailsDepth = 0;
  let toggleDepth = 0;

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    const t = line.trim();
    const lineBytes = Buffer.byteLength(line, "utf8") + 1;

    if (t.startsWith("```")) inFence = !inFence;
    else if (!inFence) {
      if (t.startsWith("<details")) detailsDepth += 1;
      if (t.startsWith("</details>") && detailsDepth > 0) detailsDepth -= 1;
      if (t.startsWith(":::toggle") || t.startsWith(":::ai-brief")) toggleDepth += 1;
      else if (t === ":::" && toggleDepth > 0) toggleDepth -= 1;
    }

    cur.push(line);
    curBytes += lineBytes;

    const nextTrim = (lines[i + 1] ?? "").trim();
    const safeContainer = !inFence && detailsDepth === 0 && toggleDepth === 0;
    const inTable = t.startsWith("|") || nextTrim.startsWith("|");
    const overSoft = cur.length >= maxLines || curBytes >= maxBytes;
    const overHard = cur.length >= maxLines * 2 || curBytes >= maxBytes * 2;
    const isBlankBoundary = t === "";

    if (safeContainer && !inTable && ((overSoft && isBlankBoundary) || overHard)) {
      const part = cur.join("\n").trim();
      if (part) chunks.push(part);
      cur = [];
      curBytes = 0;
    }
  }
  const tail = cur.join("\n").trim();
  if (tail) chunks.push(tail);
  return chunks;
}

async function putMarkdownWithRetry(vellum, pageId, markdown, state, reason) {
  let curVer = state.pageVersions[pageId] ?? 1;
  try {
    const synced = await vellum.reqJson("PUT", `/api/pages/${pageId}/markdown`, {
      markdown,
      expected_page_version: curVer,
      reason,
    });
    state.pageVersions[pageId] = synced.page?.version ?? curVer + 1;
  } catch (e) {
    if (e.status === 409) {
      const fresh = await vellum.reqJson("GET", `/api/pages/${pageId}`);
      curVer = fresh.page?.version ?? curVer;
      const synced = await vellum.reqJson("PUT", `/api/pages/${pageId}/markdown`, {
        markdown,
        expected_page_version: curVer,
        reason,
      });
      state.pageVersions[pageId] = synced.page?.version ?? curVer + 1;
    } else {
      throw e;
    }
  }
}

async function syncPageMarkdownChunked(
  vellum,
  collectionId,
  vpgId,
  baseTitle,
  markdown,
  state,
  stats,
  stateKey,
  statePath,
  dryRun,
  reason
) {
  if (state.markdownSynced[stateKey] === true) return;
  const chunks = splitMarkdownIntoChunks(markdown);
  if (chunks.length === 0) {
    state.markdownSynced[stateKey] = true;
    writeStateAtomic(statePath, state, dryRun);
    return;
  }
  if (chunks.length === 1) {
    await putMarkdownWithRetry(vellum, vpgId, chunks[0], state, reason);
    state.markdownSynced[stateKey] = true;
    writeStateAtomic(statePath, state, dryRun);
    return;
  }

  const displayTitle = baseTitle && String(baseTitle).trim() ? String(baseTitle).trim() : "Untitled Page";
  const backLabel = baseTitle && String(baseTitle).trim() ? String(baseTitle).trim() : "Overview";
  const contIds = state.continuationPages[stateKey] ?? [];
  state.continuationPages[stateKey] = contIds;

  for (let ci = 1; ci < chunks.length; ci += 1) {
    if (!contIds[ci - 1]) {
      const created = await vellum.reqJson("POST", "/api/pages", {
        collection_id: collectionId,
        parent_page_id: vpgId,
        title: `${displayTitle} (Part ${ci + 1}/${chunks.length})`,
        markdown: "",
        icon: null,
        freshness_ttl_days: null,
        reason,
      });
      const cid = created.page.id;
      contIds[ci - 1] = cid;
      state.pageVersions[cid] = created.page.version ?? 1;
      stats.continuation_pages_created += 1;
      writeStateAtomic(statePath, state, dryRun);
    }
  }

  const prevMark = state.markdownSynced[stateKey];
  const startPart =
    prevMark && typeof prevMark === "object" && Number.isInteger(prevMark.doneParts)
      ? prevMark.doneParts
      : 0;

  for (let ci = startPart; ci < chunks.length; ci += 1) {
    const targetId = ci === 0 ? vpgId : contIds[ci - 1];
    let partMd;
    if (ci === 0) {
      const links = contIds
        .slice(0, chunks.length - 1)
        .map((cid, idx) => `[[${cid}|Part ${idx + 2} of ${chunks.length}]]`)
        .join("\n\n");
      partMd = `${chunks[0]}\n\n---\n\n### Continued Parts\n\n${links}`;
    } else {
      partMd = `${chunks[ci]}\n\n---\n\n[[${vpgId}|Back to ${backLabel}]]`;
    }
    await putMarkdownWithRetry(vellum, targetId, partMd, state, reason);
    state.markdownSynced[stateKey] = ci + 1 < chunks.length ? { doneParts: ci + 1 } : true;
    writeStateAtomic(statePath, state, dryRun);
  }
}

async function migrateZipOnly(opts, vellum, zipIndex, state) {
  const warnings = [];
  const stats = {
    mode: "zip",
    dry_run: opts.dryRun,
    collection_id: state.collectionId,
    pages_total: zipIndex.mdFiles.length,
    pages_created: 0,
    nested_pages: 0,
    databases_total: 0,
    skipped_duplicate_csvs: 0,
    databases_created: 0,
    rows_total: 0,
    rows_created: 0,
    attachments_planned: 0,
    attachments_uploaded: 0,
    attachments_from_zip: 0,
    markdown_synced: 0,
    continuation_pages_created: 0,
    warnings,
  };

  const { canonical, skippedCount } = selectCanonicalCsvEntries(zipIndex.csvFiles);
  stats.databases_total = canonical.length;
  stats.skipped_duplicate_csvs = skippedCount;

  const inferredDbs = canonical.map((c) => ({ ...c, inferred: inferSchemaFromCsvParsed(c.parsed) }));
  stats.rows_total = inferredDbs.reduce((s, d) => s + d.inferred.rowCellsList.length, 0);

  const parentMap = inferZipPageParents(zipIndex.mdFiles);
  stats.nested_pages = parentMap.size;
  const order = topologicalSortIndices(zipIndex.mdFiles.length, (i) => parentMap.get(i) ?? null);

  if (opts.dryRun) {
    return stats;
  }

  if (!state.collectionId) {
    state.collectionId = await vellum.ensureCollection(opts.collectionSlug, opts.collectionName);
    writeStateAtomic(opts.statePath, state, opts.dryRun);
  }
  stats.collection_id = state.collectionId;

  const zipPageIdMap = new Map();
  const zipDbIdMap = new Map();

  // Pass 1a: Pages in topological order
  for (const idx of order) {
    const f = zipIndex.mdFiles[idx];
    const key = f.notionId ? `id:${f.notionId}` : `rel:${f.relPath}`;
    let vpgId = state.pageIds[key];
    if (!vpgId) {
      const parentIdx = parentMap.get(idx);
      let parentVpg = null;
      if (parentIdx !== undefined) {
        const pf = zipIndex.mdFiles[parentIdx];
        const pkey = pf.notionId ? `id:${pf.notionId}` : `rel:${pf.relPath}`;
        parentVpg = state.pageIds[pkey] ?? null;
      }
      const res = await vellum.reqJson("POST", "/api/pages", {
        collection_id: state.collectionId,
        parent_page_id: parentVpg,
        title: f.title || "Untitled Page",
        markdown: "",
        icon: null,
        freshness_ttl_days: null,
        reason: "notion zip migration pass 1",
      });
      vpgId = res.page.id;
      state.pageIds[key] = vpgId;
      state.pageVersions[vpgId] = res.page.version ?? 1;
      stats.pages_created += 1;
      writeStateAtomic(opts.statePath, state, opts.dryRun);
    }
    if (f.notionId) zipPageIdMap.set(`id:${f.notionId}`, vpgId);
    zipPageIdMap.set(`title:${f.title.toLowerCase()}`, vpgId);
  }

  // Pass 1b: Canonical CSV DBs + Pass 3a: Rows
  for (const dbItem of inferredDbs) {
    const key = dbItem.notionId ? `id:${dbItem.notionId}` : `rel:${dbItem.relPath}`;
    let dbRec = state.dbIds[key];
    if (!dbRec) {
      const created = await vellum.reqJson("POST", "/api/databases", {
        collection_id: state.collectionId,
        parent_page_id: null,
        title: dbItem.title || "Untitled Database",
        description: "Imported from Notion ZIP export",
        properties: dbItem.inferred.props,
      });
      dbRec = {
        dbId: created.database.id,
        hostPageId: created.page.id,
        version: created.database.version ?? 1,
        finalPropsDone: true,
      };
      state.dbIds[key] = dbRec;
      stats.databases_created += 1;
      writeStateAtomic(opts.statePath, state, opts.dryRun);
    }
    if (dbItem.notionId) zipDbIdMap.set(`id:${dbItem.notionId}`, dbRec.dbId);
    zipDbIdMap.set(`title:${dbItem.title.toLowerCase()}`, dbRec.dbId);

    for (let ri = 0; ri < dbItem.inferred.rowCellsList.length; ri += 1) {
      const rKey = `${key}#row:${ri}`;
      if (state.rowIds[rKey]) continue;
      const createdRow = await vellum.reqJson("POST", `/api/databases/${dbRec.dbId}/rows`, {
        cells: dbItem.inferred.rowCellsList[ri],
        markdown: null,
        reason: "notion zip migration row",
      });
      state.rowIds[rKey] = {
        dbId: dbRec.dbId,
        rowId: createdRow.row.id,
        pageId: createdRow.page.id,
        version: createdRow.row.version ?? 1,
        relDone: true,
      };
      stats.rows_created += 1;
      writeStateAtomic(opts.statePath, state, opts.dryRun);
    }
  }

  // Pass 3b: Rewrite Markdown + upload local attachments + PUT /api/pages/:id/markdown
  const ctx = {
    vellum,
    zipIndex,
    state,
    stats,
    warnings,
    dryRun: opts.dryRun,
    skipAttachments: opts.skipAttachments,
    maxAttachmentBytes: opts.maxAttachmentMb * 1024 * 1024,
    saveState: () => writeStateAtomic(opts.statePath, state, opts.dryRun),
  };

  for (const idx of order) {
    const f = zipIndex.mdFiles[idx];
    const key = f.notionId ? `id:${f.notionId}` : `rel:${f.relPath}`;
    if (state.markdownSynced[key] === true) continue;
    const vpgId = state.pageIds[key];
    const finalMd = await rewriteZipMarkdownAndUploadAssets(f, vpgId, zipPageIdMap, zipDbIdMap, ctx);
    await syncPageMarkdownChunked(
      vellum,
      state.collectionId,
      vpgId,
      f.title || "Untitled Page",
      finalMd,
      state,
      stats,
      key,
      opts.statePath,
      opts.dryRun,
      "notion zip migration pass 3"
    );
    stats.markdown_synced += 1;
    if (stats.markdown_synced % 100 === 0 || stats.markdown_synced === order.length) {
      console.error(`[notion-migrate] zip markdown synced: ${stats.markdown_synced}/${order.length}`);
    }
  }

  return stats;
}

async function migrateApiFirst(opts, notionToken, vellum, zipIndex, state) {
  const warnings = [];
  const data = await loadNotionApiData(opts.apiBaseUrl, notionToken, opts.concurrency);
  const validDbIds = new Set(data.dbById.keys());

  const stats = {
    mode: zipIndex ? "api+hybrid_zip" : "api",
    dry_run: opts.dryRun,
    collection_id: state.collectionId,
    pages_total: data.docPageById.size,
    pages_created: 0,
    nested_pages: 0,
    databases_total: data.dbById.size,
    databases_created: 0,
    rows_total: data.rowPageById.size,
    rows_created: 0,
    relations_total: 0,
    rollups_total: 0,
    formulas_total: 0,
    covers_attached: 0,
    attachments_planned: 0,
    attachments_uploaded: 0,
    attachments_from_zip: 0,
    markdown_synced: 0,
    continuation_pages_created: 0,
    warnings,
  };

  // Build plans for every DB upfront
  const planByNotionDbId = new Map();
  for (const [dbNid, db] of data.dbById.entries()) {
    const dbRows = data.rowsByDbId.get(dbNid) ?? [];
    const plan = buildNotionDbPlan(db, dbRows, validDbIds, warnings);
    planByNotionDbId.set(dbNid, plan);
    stats.relations_total += plan.deferredProps.filter((p) => p.notionType === "relation").length;
    stats.rollups_total += plan.deferredProps.filter((p) => p.notionType === "rollup").length;
    stats.formulas_total += plan.deferredProps.filter((p) => p.notionType === "formula").length;
  }

  // Topological order of non-row doc pages (handling both page_id and block_id parents)
  const blockOwnerPageMap = new Map();
  for (const [ownerPid, blks] of data.blocksByPageId.entries()) {
    const stack = [...blks];
    while (stack.length > 0) {
      const b = stack.pop();
      blockOwnerPageMap.set(normId(b.id), ownerPid);
      if (b._children?.length) stack.push(...b._children);
    }
  }
  const resolveDocParentNid = (p) => {
    if (p.parent?.type === "page_id") return normId(p.parent.page_id);
    if (p.parent?.type === "block_id") return blockOwnerPageMap.get(normId(p.parent.block_id)) ?? null;
    return null;
  };
  const docList = [...data.docPageById.values()];
  const docIdxByNid = new Map(docList.map((p, i) => [normId(p.id), i]));
  const getDocParentIdx = (i) => {
    const pnid = resolveDocParentNid(docList[i]);
    return pnid && docIdxByNid.has(pnid) ? docIdxByNid.get(pnid) : null;
  };
  for (let i = 0; i < docList.length; i += 1) {
    if (getDocParentIdx(i) !== null) stats.nested_pages += 1;
  }
  const docOrder = topologicalSortIndices(docList.length, getDocParentIdx);

  if (opts.dryRun) {
    // Still count attachment candidates in dry-run
    for (const blks of data.blocksByPageId.values()) {
      const stack = [...blks];
      while (stack.length > 0) {
        const b = stack.pop();
        if (["image", "file", "pdf", "video", "audio"].includes(b.type)) stats.attachments_planned += 1;
        if (b._children?.length) stack.push(...b._children);
      }
    }
    for (const pg of [...docList, ...data.rowPageById.values()]) {
      if (pg.cover) stats.attachments_planned += 1;
    }
    return stats;
  }

  if (!state.collectionId) {
    state.collectionId = await vellum.ensureCollection(opts.collectionSlug, opts.collectionName);
    writeStateAtomic(opts.statePath, state, opts.dryRun);
  }
  stats.collection_id = state.collectionId;

  const pageIdMap = new Map(Object.entries(state.pageIds));
  const dbMap = new Map(Object.entries(state.dbIds));
  const rowMap = new Map(Object.entries(state.rowIds));

  // Pass 1a: Create Document Page hierarchy
  for (const idx of docOrder) {
    const pg = docList[idx];
    const nid = normId(pg.id);
    if (state.pageIds[nid]) {
      pageIdMap.set(nid, state.pageIds[nid]);
      continue;
    }
    const parentNid = resolveDocParentNid(pg);
    const parentVpgId = parentNid ? pageIdMap.get(parentNid) ?? null : null;
    const created = await vellum.reqJson("POST", "/api/pages", {
      collection_id: state.collectionId,
      parent_page_id: parentVpgId,
      title: getNotionPageTitle(pg),
      markdown: "",
      icon: getNotionIconText(pg),
      freshness_ttl_days: null,
      reason: "notion api migration pass 1",
    });
    const vpgId = created.page.id;
    state.pageIds[nid] = vpgId;
    state.pageVersions[vpgId] = created.page.version ?? 1;
    pageIdMap.set(nid, vpgId);
    stats.pages_created += 1;
    writeStateAtomic(opts.statePath, state, opts.dryRun);
  }

  // Pass 1b: Create Databases with base non-Relation/Rollup/Formula schemas
  for (const [dbNid, db] of data.dbById.entries()) {
    if (state.dbIds[dbNid]) {
      dbMap.set(dbNid, state.dbIds[dbNid]);
      continue;
    }
    const plan = planByNotionDbId.get(dbNid);
    const parentVpgId = db.parent?.type === "page_id" ? pageIdMap.get(normId(db.parent.page_id)) ?? null : null;
    const created = await vellum.reqJson("POST", "/api/databases", {
      collection_id: state.collectionId,
      parent_page_id: parentVpgId,
      title: getNotionDbTitle(db),
      description: plainTextOfRichText(db.description ?? []).trim() || "Imported from Notion API",
      properties: plan.baseProps,
    });
    const rec = {
      dbId: created.database.id,
      hostPageId: created.page.id,
      version: created.database.version ?? 1,
      finalPropsDone: plan.deferredProps.length === 0,
    };
    state.dbIds[dbNid] = rec;
    dbMap.set(dbNid, rec);
    stats.databases_created += 1;
    writeStateAtomic(opts.statePath, state, opts.dryRun);
  }

  const ctx = {
    vellum,
    zipIndex,
    state,
    stats,
    warnings,
    dryRun: opts.dryRun,
    skipAttachments: opts.skipAttachments,
    maxAttachmentBytes: opts.maxAttachmentMb * 1024 * 1024,
    pageIdMap,
    dbMap,
    planByNotionDbId,
    dbStateByNotionId: (nid) => dbMap.get(nid),
    saveState: () => writeStateAtomic(opts.statePath, state, opts.dryRun),
  };

  // Pass 2: Wire Relations, Rollups, and Formulas (falling back gracefully per invalid Formula)
  for (const [dbNid] of data.dbById.entries()) {
    const rec = state.dbIds[dbNid];
    if (rec.finalPropsDone) continue;
    const plan = planByNotionDbId.get(dbNid);
    const built = buildFinalPropsForDb(plan, rec.dbId, ctx);
    let candidateProps = built.props;
    try {
      const patched = await vellum.reqJson("PATCH", `/api/databases/${rec.dbId}`, {
        properties: candidateProps,
        expected_version: rec.version,
      });
      rec.version = patched.version ?? rec.version + 1;
      rec.finalPropsDone = true;
      writeStateAtomic(opts.statePath, state, opts.dryRun);
    } catch (e) {
      if (e.status === 422 && built.formulas.length > 0) {
        // Test formulas individually or drop offending formulas so valid Relations/Rollups/Formulas still apply
        const noFormulaProps = candidateProps.filter((p) => !(p.kind && typeof p.kind === "object" && "formula" in p.kind));
        let curVer = rec.version;
        const basePatch = await vellum.reqJson("PATCH", `/api/databases/${rec.dbId}`, {
          properties: noFormulaProps,
          expected_version: curVer,
        });
        curVer = basePatch.version ?? curVer + 1;
        let activeProps = [...noFormulaProps];
        for (const fProp of built.formulas) {
          try {
            const fpRes = await vellum.reqJson("PATCH", `/api/databases/${rec.dbId}`, {
              properties: [...activeProps, fProp],
              expected_version: curVer,
            });
            activeProps.push(fProp);
            curVer = fpRes.version ?? curVer + 1;
          } catch (fe) {
            warnings.push(`Skipped unsupported formula '${fProp.id}' on database '${rec.dbId}' (${fe.status})`);
          }
        }
        rec.version = curVer;
        rec.finalPropsDone = true;
        writeStateAtomic(opts.statePath, state, opts.dryRun);
      } else {
        throw e;
      }
    }
  }

  // Pass 3a: Create Database Rows (base cells)
  for (const [dbNid, rows] of data.rowsByDbId.entries()) {
    const dbRec = state.dbIds[dbNid];
    const plan = planByNotionDbId.get(dbNid);
    for (const notionRow of rows) {
      const rnid = normId(notionRow.id);
      if (state.rowIds[rnid]) {
        rowMap.set(rnid, state.rowIds[rnid]);
        pageIdMap.set(rnid, state.rowIds[rnid].pageId);
        continue;
      }
      const { baseCells } = await extractRowBaseAndRelCells(notionRow, plan, ctx, false);
      const created = await vellum.reqJson("POST", `/api/databases/${dbRec.dbId}/rows`, {
        cells: baseCells,
        markdown: null,
        reason: "notion api migration pass 3 row",
      });
      const rRec = {
        dbId: dbRec.dbId,
        rowId: created.row.id,
        pageId: created.page.id,
        version: created.row.version ?? 1,
        relDone: false,
      };
      state.rowIds[rnid] = rRec;
      state.pageIds[rnid] = created.page.id;
      state.pageVersions[created.page.id] = created.page.version ?? 1;
      rowMap.set(rnid, rRec);
      pageIdMap.set(rnid, created.page.id);
      stats.rows_created += 1;
      writeStateAtomic(opts.statePath, state, opts.dryRun);
    }
  }

  // Pass 3b: Patch RelationVal & FilesVal on Database Rows
  for (const [dbNid, rows] of data.rowsByDbId.entries()) {
    const plan = planByNotionDbId.get(dbNid);
    const propKindById = new Map(
      buildFinalPropsForDb(plan, state.dbIds[dbNid].dbId, ctx).props.map((p) => [p.id, p.kind])
    );
    for (const notionRow of rows) {
      const rnid = normId(notionRow.id);
      const rRec = state.rowIds[rnid];
      if (!rRec || rRec.relDone) continue;
      const { baseCells, relCells } = await extractRowBaseAndRelCells(notionRow, plan, ctx, true);
      const patchCells = {};
      for (const [propId, targetNids] of Object.entries(relCells)) {
        if (!(propKindById.get(propId) && typeof propKindById.get(propId) === "object" && "relation" in propKindById.get(propId))) {
          continue;
        }
        const vellumRowIds = targetNids.map((id) => rowMap.get(id)?.rowId).filter(Boolean);
        if (vellumRowIds.length > 0) {
          patchCells[propId] = { relation_val: { row_ids: vellumRowIds } };
        }
      }
      for (const [propId, val] of Object.entries(baseCells)) {
        if (val && typeof val === "object" && "files_val" in val) {
          patchCells[propId] = val;
        }
      }
      if (Object.keys(patchCells).length > 0) {
        const patched = await vellum.reqJson(
          "PATCH",
          `/api/databases/${rRec.dbId}/rows/${rRec.rowId}`,
          {
            cells: patchCells,
            expected_version: rRec.version,
            reason: "notion api migration relations & files",
          }
        );
        rRec.version = patched.row?.version ?? rRec.version + 1;
      }
      rRec.relDone = true;
      writeStateAtomic(opts.statePath, state, opts.dryRun);
    }
  }

  // Pass 3c: Upload page/row covers + PATCH /api/pages/:id and sync Markdown bodies + inline media
  const allPagesToFinalize = [...docList, ...data.rowPageById.values()];
  for (const pg of allPagesToFinalize) {
    const nid = normId(pg.id);
    const vpgId = pageIdMap.get(nid);
    if (!vpgId) continue;

    if (pg.cover && !state.coversDone[vpgId]) {
      const up = await resolveNotionMediaAttachment(pg.cover, pg.id, "cover", "cover.png", ctx);
      if (up?.attId) {
        const curVer = state.pageVersions[vpgId] ?? 1;
        const patched = await vellum.reqJson("PATCH", `/api/pages/${vpgId}`, {
          cover_attachment_id: up.attId,
          icon: getNotionIconText(pg),
          reason: "notion api migration cover attachment",
        });
        state.pageVersions[vpgId] = patched.page?.version ?? curVer + 1;
        stats.covers_attached += 1;
      }
      state.coversDone[vpgId] = true;
      writeStateAtomic(opts.statePath, state, opts.dryRun);
    }

    if (state.markdownSynced[nid] !== true) {
      const blocks = data.blocksByPageId.get(nid) ?? [];
      if (blocks.length > 0) {
        const md = await serializeNotionBlocks(blocks, pg.id, ctx);
        if (md.trim()) {
          await syncPageMarkdownChunked(
            vellum,
            state.collectionId,
            vpgId,
            getNotionPageTitle(pg),
            md,
            state,
            stats,
            nid,
            opts.statePath,
            opts.dryRun,
            "notion api migration pass 3 markdown"
          );
          stats.markdown_synced += 1;
          if (stats.markdown_synced % 100 === 0) {
            console.error(`[notion-migrate] api markdown synced: ${stats.markdown_synced}`);
          }
        } else {
          state.markdownSynced[nid] = true;
          writeStateAtomic(opts.statePath, state, opts.dryRun);
        }
      } else {
        state.markdownSynced[nid] = true;
        writeStateAtomic(opts.statePath, state, opts.dryRun);
      }
    }
  }

  return stats;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    printHelp();
    return;
  }

  let notionToken = (process.env.NOTION_TOKEN ?? "").trim();
  if (opts.apiTokenFile) {
    notionToken = fs.readFileSync(opts.apiTokenFile, "utf8").trim();
  }

  if (!notionToken && !opts.zipPath) {
    printHelp();
    throw new Error("Provide --api-token-file (or NOTION_TOKEN) and/or --zip <path>");
  }
  if (!opts.dryRun && !opts.vellumUrl) {
    throw new Error("Provide --vellum-url <url> (or run with --dry-run)");
  }
  if (!opts.dryRun && !opts.vellumToken && !opts.soloLogin) {
    throw new Error("Provide --vellum-token <tok> (or VELLUM_TOKEN) or --solo-login");
  }

  let zipIndex = null;
  try {
    if (opts.zipPath) {
      zipIndex = indexZipWorkspace(opts.zipPath);
    }
    const state = loadState(opts.statePath, opts.dryRun);
    let vellum = null;
    if (!opts.dryRun) {
      vellum = new VellumClient({
        baseUrl: opts.vellumUrl,
        token: opts.vellumToken,
        soloLogin: opts.soloLogin,
        chunkMb: opts.chunkMb,
      });
      await vellum.init();
    }

    const summary = notionToken
      ? await migrateApiFirst(opts, notionToken, vellum, zipIndex, state)
      : await migrateZipOnly(opts, vellum, zipIndex, state);

    console.log(JSON.stringify(summary, null, 2));
  } finally {
    if (zipIndex) zipIndex.cleanup();
  }
}

main().catch((err) => {
  console.error("notion-migrate failed:", err instanceof Error ? err.message : String(err));
  process.exit(1);
});
