#!/usr/bin/env node
/**
 * Zero-dependency resumable Slack Export ZIP -> Vellum Unified Chat importer.
 *
 * Usage:
 *   node scripts/slack-import.mjs \
 *     --zip ./slack-export.zip \
 *     --vellum-url http://127.0.0.1:8080 \
 *     --solo-login \
 *     --collection-slug engineering \
 *     --read-only-archive \
 *     --since-days 30
 */

import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { createHash } from "node:crypto";

function printHelp() {
  process.stdout.write(`Vellum Slack Export ZIP Importer (zero-dependency CLI)

Required:
  --zip <path>                 Path to standard Slack Workspace/Channel Export .zip

Authentication & Target:
  --vellum-url <url>           Vellum base URL (default: $VELLUM_URL or http://127.0.0.1:8080)
  --vellum-token <token>       Agent/API Bearer token (or $VELLUM_TOKEN)
  --solo-login                 Authenticate via GET /auth/solo/login session cookie
  --collection-slug <slug>     Target Collection slug (default: slack-archive)
  --collection-name <name>     Collection name if auto-created (default: Slack Archive)

Import Options:
  --read-only-archive          Mark imported Slack channels as read-only archives
  --since-days <N>             Only import messages from the last N days
  --channels <c1,c2>           Comma-separated channel names or Slack IDs to include
  --include-archived           Include archived Slack channels (skipped by default)
  --batch-size <N>             Messages per API batch request (1..200, default: 50)
  --chunk-mb <N>               Chunk size for local attachment upload (1..16, default: 8)
  --skip-attachments           Skip uploading bundled file attachments from the ZIP
  --state <path>               Checkpoint JSON path (default: .slack-import-state.json)
  --dry-run                    Validate ZIP and print structural import plan without writing
  -h, --help                   Show this help
`);
}

function parseIntOpt(raw, fallback, min, max) {
  const n = Number.parseInt(String(raw ?? ""), 10);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, n));
}

function parseArgs(argv) {
  const opts = {
    zipPath: null,
    vellumUrl: process.env.VELLUM_URL ? process.env.VELLUM_URL.trim() : "http://127.0.0.1:8080",
    vellumToken: process.env.VELLUM_TOKEN ? process.env.VELLUM_TOKEN.trim() : null,
    soloLogin: false,
    collectionSlug: "slack-archive",
    collectionName: "Slack Archive",
    readOnlyArchive: false,
    sinceDays: null,
    channels: null,
    includeArchived: false,
    batchSize: 50,
    chunkMb: 8,
    skipAttachments: false,
    statePath: ".slack-import-state.json",
    dryRun: false,
    help: false,
  };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "-h" || arg === "--help") opts.help = true;
    else if (arg === "--zip") opts.zipPath = argv[++i] ?? null;
    else if (arg === "--vellum-url") opts.vellumUrl = (argv[++i] ?? "").trim() || opts.vellumUrl;
    else if (arg === "--vellum-token") opts.vellumToken = (argv[++i] ?? "").trim() || null;
    else if (arg === "--solo-login") opts.soloLogin = true;
    else if (arg === "--collection-slug") opts.collectionSlug = (argv[++i] ?? "").trim() || "slack-archive";
    else if (arg === "--collection-name") opts.collectionName = (argv[++i] ?? "").trim() || "Slack Archive";
    else if (arg === "--read-only-archive") opts.readOnlyArchive = true;
    else if (arg === "--since-days") opts.sinceDays = parseIntOpt(argv[++i], 30, 1, 36500);
    else if (arg === "--channels") {
      const list = String(argv[++i] ?? "")
        .split(",")
        .map((s) => s.trim().replace(/^#/, "").toLowerCase())
        .filter(Boolean);
      opts.channels = list.length > 0 ? list : null;
    } else if (arg === "--include-archived") opts.includeArchived = true;
    else if (arg === "--batch-size") opts.batchSize = parseIntOpt(argv[++i], 50, 1, 200);
    else if (arg === "--chunk-mb") opts.chunkMb = parseIntOpt(argv[++i], 8, 1, 16);
    else if (arg === "--skip-attachments") opts.skipAttachments = true;
    else if (arg === "--state") opts.statePath = argv[++i] ?? opts.statePath;
    else if (arg === "--dry-run") opts.dryRun = true;
    else throw new Error(`Unknown CLI flag: ${arg}`);
  }
  return opts;
}

class ZipReader {
  constructor(buf) {
    this.buf = buf;
    this.entries = new Map();
    this.prefix = "";
    this._parse();
  }

  _findEocdOffset() {
    const minOff = Math.max(0, this.buf.length - 65557);
    for (let i = this.buf.length - 22; i >= minOff; i -= 1) {
      if (this.buf.readUInt32LE(i) === 0x06054b50) {
        return i;
      }
    }
    throw new Error("Invalid ZIP archive: End of Central Directory record not found");
  }

  _parse() {
    const eocdOff = this._findEocdOffset();
    const totalEntries = this.buf.readUInt16LE(eocdOff + 10);
    const cdSize = this.buf.readUInt32LE(eocdOff + 12);
    const cdOff = this.buf.readUInt32LE(eocdOff + 16);
    if (cdOff === 0xffffffff || cdSize === 0xffffffff || totalEntries === 0xffff) {
      throw new Error("ZIP64 archives larger than 4GiB are not supported by built-in reader");
    }

    const rawEntries = [];
    let pos = cdOff;
    for (let idx = 0; idx < totalEntries; idx += 1) {
      if (pos + 46 > this.buf.length || this.buf.readUInt32LE(pos) !== 0x02014b50) {
        throw new Error(`Corrupt ZIP central directory header at offset ${pos}`);
      }
      const method = this.buf.readUInt16LE(pos + 10);
      const compSize = this.buf.readUInt32LE(pos + 20);
      const uncompSize = this.buf.readUInt32LE(pos + 24);
      const nameLen = this.buf.readUInt16LE(pos + 28);
      const extraLen = this.buf.readUInt16LE(pos + 30);
      const commentLen = this.buf.readUInt16LE(pos + 32);
      const localHeaderOff = this.buf.readUInt32LE(pos + 42);
      const rawName = this.buf
        .subarray(pos + 46, pos + 46 + nameLen)
        .toString("utf8")
        .replaceAll("\\", "/")
        .replace(/^\.\//, "");
      pos += 46 + nameLen + extraLen + commentLen;
      if (!rawName || rawName.endsWith("/")) continue;
      rawEntries.push({ rawName, method, compSize, uncompSize, localHeaderOff });
    }

    const hasRootUsers = rawEntries.some((e) => e.rawName === "users.json" || e.rawName === "channels.json");
    if (!hasRootUsers && rawEntries.length > 0) {
      const firstSegs = new Set(rawEntries.map((e) => e.rawName.split("/")[0]).filter(Boolean));
      if (firstSegs.size === 1) {
        const candPrefix = `${[...firstSegs][0]}/`;
        const strippedHasCore = rawEntries.some(
          (e) =>
            e.rawName.slice(candPrefix.length) === "users.json" ||
            e.rawName.slice(candPrefix.length) === "channels.json"
        );
        if (strippedHasCore) this.prefix = candPrefix;
      }
    }

    for (const ent of rawEntries) {
      const cleanPath =
        this.prefix && ent.rawName.startsWith(this.prefix)
          ? ent.rawName.slice(this.prefix.length)
          : ent.rawName;
      this.entries.set(cleanPath, ent);
    }
  }

  has(relPath) {
    return this.entries.has(relPath);
  }

  listPaths() {
    return [...this.entries.keys()];
  }

  readBuffer(relPath) {
    const ent = this.entries.get(relPath);
    if (!ent) throw new Error(`Missing ZIP entry: ${relPath}`);
    const lfh = ent.localHeaderOff;
    if (lfh + 30 > this.buf.length || this.buf.readUInt32LE(lfh) !== 0x04034b50) {
      throw new Error(`Invalid local file header for ${relPath}`);
    }
    const fnameLen = this.buf.readUInt16LE(lfh + 26);
    const extraLen = this.buf.readUInt16LE(lfh + 28);
    const dataStart = lfh + 30 + fnameLen + extraLen;
    const comp = this.buf.subarray(dataStart, dataStart + ent.compSize);
    if (ent.method === 0) return Buffer.from(comp);
    if (ent.method === 8) return zlib.inflateRawSync(comp);
    throw new Error(`Unsupported ZIP compression method ${ent.method} for ${relPath}`);
  }

  readJsonOptional(relPath, fallback = null) {
    if (!this.has(relPath)) return fallback;
    const txt = this.readBuffer(relPath).toString("utf8").trim();
    if (!txt) return fallback;
    return JSON.parse(txt);
  }
}

class CookieJar {
  constructor() {
    this.cookies = new Map();
  }
  storeFrom(res) {
    const rawList =
      typeof res.headers.getSetCookie === "function"
        ? res.headers.getSetCookie()
        : res.headers.get("set-cookie")
          ? [res.headers.get("set-cookie")]
          : [];
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

function guessContentType(filename) {
  const ext = path.extname(String(filename ?? "")).toLowerCase();
  switch (ext) {
    case ".png": return "image/png";
    case ".jpg":
    case ".jpeg": return "image/jpeg";
    case ".gif": return "image/gif";
    case ".webp": return "image/webp";
    case ".pdf": return "application/pdf";
    case ".csv": return "text/csv";
    case ".json": return "application/json";
    case ".txt":
    case ".log":
    case ".md": return "text/plain";
    default: return "application/octet-stream";
  }
}

function safeFilename(raw, fallback = "attachment.bin") {
  const clean = path.posix.basename(String(raw ?? "").split("?")[0].split("#")[0]).trim();
  const ascii = clean.replace(/[^A-Za-z0-9._-]+/g, "_").replace(/^_+|_+$/g, "");
  if (!ascii || ascii === "." || ascii === "..") return fallback;
  return ascii.slice(0, 120);
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
      if (res.status < 200 || res.status >= 400 || !this.jar.get("vellum_session")) {
        throw new Error(`Solo login failed (${res.status})`);
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
      const err = new Error(`Vellum ${method} ${apiPath} failed (${res.status})`);
      err.status = res.status;
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
      description: "Imported Slack workspace archive",
      icon: "message-square",
      write_policy: "direct_with_audit",
      freshness_ttl_days: null,
    });
    return created.id;
  }

  async uploadBufferAttachment(channelId, dataBuf, filename, contentType) {
    if (!Buffer.isBuffer(dataBuf) || dataBuf.length <= 0 || dataBuf.length > 524288000) {
      return { skipped: true };
    }
    const cleanName = safeFilename(filename);
    const sha256Hex = createHash("sha256").update(dataBuf).digest("hex");
    const presign = await this.reqJson("POST", "/api/attachments/presign", {
      page_id: channelId,
      filename: cleanName,
      content_type: contentType || guessContentType(cleanName),
      size_bytes: dataBuf.length,
      sha256_hex: sha256Hex,
    });
    const attId = presign.attachment.id;
    const rawUploadUrl = presign.upload_url;

    if (rawUploadUrl.startsWith("/")) {
      let offset = 0;
      while (offset < dataBuf.length) {
        const end = Math.min(dataBuf.length, offset + this.chunkBytes);
        const chunk = dataBuf.subarray(offset, end);
        const sep = rawUploadUrl.includes("?") ? "&" : "?";
        const putRes = await fetch(`${this.baseUrl}${rawUploadUrl}${sep}offset=${offset}`, {
          method: "PUT",
          headers: { "Content-Type": "application/octet-stream" },
          body: chunk,
        });
        if (!putRes.ok) throw new Error(`Local attachment chunk upload failed (${putRes.status})`);
        offset = end;
      }
    } else {
      const putHeaders = {};
      for (const h of presign.required_headers ?? []) putHeaders[h.name] = h.value;
      const putRes = await fetch(rawUploadUrl, {
        method: presign.method || "PUT",
        headers: putHeaders,
        body: dataBuf,
      });
      if (!putRes.ok) throw new Error(`S3 attachment PUT failed (${putRes.status})`);
    }

    await this.reqJson("POST", `/api/attachments/${encodeURIComponent(attId)}/commit`, {});
    return { skipped: false, attId };
  }
}

function normalizeHandle(raw) {
  return String(raw ?? "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "")
    .slice(0, 48);
}

function mapSlackEmoji(name) {
  const clean = String(name ?? "").split("::")[0].trim().toLowerCase();
  const table = {
    "+1": "👍",
    thumbsup: "👍",
    "-1": "👎",
    eyes: "👀",
    white_check_mark: "✅",
    heavy_check_mark: "✅",
    tada: "🎉",
    rocket: "🚀",
    heart: "❤️",
    fire: "🔥",
    warning: "⚠️",
  };
  if (table[clean]) return table[clean];
  return clean ? `:${clean}:` : "";
}

function convertSlackMrkdwn(raw, usersById, channelsById) {
  let out = String(raw ?? "");
  out = out.replace(/<!(here|channel|everyone)(?:\|[^>]*)?>/gi, (_m, k) => `@${k.toLowerCase()}`);
  out = out.replace(/<!subteam\^[A-Z0-9]+\|@?([^>]+)>/gi, (_m, lbl) => `@${normalizeHandle(lbl) || lbl}`);
  out = out.replace(/<@([A-Z0-9]+)(?:\|([^>]*))?>/gi, (_m, uid, lbl) => {
    const u = usersById.get(uid);
    const h = normalizeHandle(u?.handle || lbl || uid);
    return `@${h || uid.toLowerCase()}`;
  });
  out = out.replace(/<#([A-Z0-9]+)(?:\|([^>]*))?>/gi, (_m, cid, lbl) => {
    const c = channelsById.get(cid);
    const name = c?.name || lbl || cid.toLowerCase();
    return `#${name}`;
  });
  out = out.replace(/<mailto:([^|>]+)(?:\|([^>]*))?>/gi, (_m, addr) => addr);
  out = out.replace(/<(https?:\/\/[^|>]+)\|([^>]+)>/gi, (_m, url, label) => `[${label}](${url})`);
  out = out.replace(/<(https?:\/\/[^>]+)>/gi, (_m, url) => url);
  out = out.replaceAll("&amp;", "&").replaceAll("&lt;", "<").replaceAll("&gt;", ">");
  return out.trim();
}

function slackTsToIso(tsRaw) {
  const num = Number.parseFloat(String(tsRaw ?? ""));
  if (!Number.isFinite(num) || num <= 0) return new Date().toISOString();
  return new Date(Math.round(num * 1000)).toISOString();
}

function findZipAttachmentEntry(zip, chFolder, fileObj) {
  const candidates = [];
  if (fileObj.local_path) {
    candidates.push(String(fileObj.local_path).replaceAll("\\", "/").replace(/^\.\//, ""));
  }
  const fname = fileObj.name ? safeFilename(fileObj.name) : "";
  const fid = String(fileObj.id ?? "").trim();
  if (chFolder && fname) candidates.push(`${chFolder}/files/${fname}`);
  if (fid && chFolder && fname) candidates.push(`${chFolder}/files/${fid}/${fname}`);
  if (fid && fname) candidates.push(`files/${fid}/${fname}`);
  if (fid) {
    for (const p of zip.listPaths()) {
      if (p.includes(`/${fid}/`) || p.startsWith(`files/${fid}/`) || p.includes(`/${fid}_`)) {
        candidates.push(p);
      }
    }
  }
  for (const c of candidates) {
    if (zip.has(c)) return c;
  }
  return null;
}

function loadState(statePath) {
  try {
    if (fs.existsSync(statePath)) {
      return JSON.parse(fs.readFileSync(statePath, "utf8"));
    }
  } catch {
    // ignore corrupt checkpoint
  }
  return { channels: {}, uploadedFiles: {}, importedTs: {} };
}

function saveState(statePath, state) {
  const tmp = `${statePath}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
  fs.renameSync(tmp, statePath);
}

async function run() {
  const opts = parseArgs(process.argv);
  if (opts.help) {
    printHelp();
    return;
  }
  if (!opts.zipPath) {
    throw new Error("--zip <path> is required (pass --help for usage)");
  }

  const zipBuf = fs.readFileSync(opts.zipPath);
  const zip = new ZipReader(zipBuf);

  const rawUsers = zip.readJsonOptional("users.json", []) ?? [];
  const usersById = new Map();
  for (const u of rawUsers) {
    if (!u?.id) continue;
    const prof = u.profile ?? {};
    const handle = normalizeHandle(u.name || prof.display_name_normalized || prof.display_name || u.id);
    const displayName = String(prof.real_name || prof.display_name || u.real_name || handle).trim();
    const email = typeof prof.email === "string" && prof.email.includes("@") ? prof.email.trim().toLowerCase() : null;
    usersById.set(u.id, { id: u.id, handle, displayName, email });
  }

  const pubChannels = (zip.readJsonOptional("channels.json", []) ?? []).map((c) => ({ ...c, _isPrivate: false }));
  const privChannels = (zip.readJsonOptional("groups.json", []) ?? []).map((c) => ({ ...c, _isPrivate: true }));
  const allChannels = [...pubChannels, ...privChannels];
  const channelsById = new Map();
  for (const ch of allChannels) {
    if (ch?.id) channelsById.set(ch.id, ch);
  }

  const allPaths = zip.listPaths();
  const cutoffSec = opts.sinceDays !== null ? Date.now() / 1000 - opts.sinceDays * 86400 : null;

  const selectedChannels = [];
  for (const ch of allChannels) {
    if (!ch?.name) continue;
    if (ch.is_archived && !opts.includeArchived) continue;
    if (opts.channels) {
      const nLow = String(ch.name).toLowerCase();
      const idLow = String(ch.id ?? "").toLowerCase();
      if (!opts.channels.includes(nLow) && !opts.channels.includes(idLow)) continue;
    }
    const dayFiles = allPaths
      .filter((p) => p.startsWith(`${ch.name}/`) && /^\d{4}-\d{2}-\d{2}\.json$/i.test(path.posix.basename(p)))
      .sort();
    const msgsByTs = new Map();
    for (const df of dayFiles) {
      const dayArr = zip.readJsonOptional(df, []) ?? [];
      for (const m of dayArr) {
        if (!m || m.type !== "message") continue;
        if (m.subtype && !["thread_broadcast", "file_share", "bot_message"].includes(m.subtype)) continue;
        const ts = String(m.ts ?? "").trim();
        if (!ts) continue;
        const tsNum = Number.parseFloat(ts);
        if (cutoffSec !== null && Number.isFinite(tsNum) && tsNum < cutoffSec) continue;
        if (!msgsByTs.has(ts)) msgsByTs.set(ts, m);
      }
    }
    const sortedMsgs = [...msgsByTs.values()].sort(
      (a, b) => Number.parseFloat(a.ts || "0") - Number.parseFloat(b.ts || "0")
    );
    selectedChannels.push({ meta: ch, messages: sortedMsgs });
  }

  if (opts.dryRun) {
    const plan = {
      dry_run: true,
      collection_slug: opts.collectionSlug,
      read_only_archive: opts.readOnlyArchive,
      since_days: opts.sinceDays,
      channels_count: selectedChannels.length,
      channels: selectedChannels.map((c) => ({
        slack_id: c.meta.id ?? null,
        slug: normalizeHandle(c.meta.name) || "slack-import",
        is_private: Boolean(c.meta._isPrivate),
        messages_count: c.messages.length,
        bundled_files_count: c.messages.reduce((acc, m) => acc + (Array.isArray(m.files) ? m.files.length : 0), 0),
      })),
    };
    process.stdout.write(`${JSON.stringify(plan, null, 2)}\n`);
    return;
  }

  const client = new VellumClient({
    baseUrl: opts.vellumUrl,
    token: opts.vellumToken,
    soloLogin: opts.soloLogin,
    chunkMb: opts.chunkMb,
  });
  await client.init();
  const collectionId = await client.ensureCollection(opts.collectionSlug, opts.collectionName);
  const state = loadState(opts.statePath);
  state.channels = state.channels || {};
  state.uploadedFiles = state.uploadedFiles || {};
  state.importedTs = state.importedTs || {};

  let totalCreated = 0;
  let totalSkipped = 0;
  let totalAttachments = 0;
  const channelReports = [];

  for (const chEntry of selectedChannels) {
    const ch = chEntry.meta;
    const slackChId = String(ch.id ?? "");
    const chStateKey = `${collectionId}:${slackChId || ch.name}`;
    const chMetaPayload = {
      id: state.channels[chStateKey] || undefined,
      slack_id: slackChId,
      name: ch.name,
      topic: ch.topic?.value || ch.purpose?.value || "",
      is_private: Boolean(ch._isPrivate),
      read_only: Boolean(opts.readOnlyArchive),
    };

    // Pre-create / resolve channel before uploading bundled attachments
    const preRes = await client.reqJson("POST", "/api/v1/chat/import/slack", {
      collection_id: collectionId,
      channel: chMetaPayload,
      messages: [],
    });
    const vellumChannelId = preRes.channel.id;
    state.channels[chStateKey] = vellumChannelId;
    saveState(opts.statePath, state);

    const preparedMsgs = [];
    const doneSet = new Set(state.importedTs[chStateKey] ?? []);

    for (const m of chEntry.messages) {
      const ts = String(m.ts ?? "").trim();
      if (doneSet.has(ts)) {
        totalSkipped += 1;
        continue;
      }

      const attachmentIds = [];
      if (!opts.skipAttachments && Array.isArray(m.files)) {
        for (const f of m.files) {
          const entryPath = findZipAttachmentEntry(zip, ch.name, f);
          if (!entryPath) continue;
          const upKey = `${vellumChannelId}:${entryPath}`;
          if (state.uploadedFiles[upKey]) {
            attachmentIds.push(state.uploadedFiles[upKey]);
            continue;
          }
          const buf = zip.readBuffer(entryPath);
          const up = await client.uploadBufferAttachment(
            vellumChannelId,
            buf,
            f.name || path.posix.basename(entryPath),
            f.mimetype || null
          );
          if (!up.skipped && up.attId) {
            state.uploadedFiles[upKey] = up.attId;
            attachmentIds.push(up.attId);
            totalAttachments += 1;
            saveState(opts.statePath, state);
          }
        }
      }

      const u = m.user ? usersById.get(m.user) : null;
      const bodyMd = convertSlackMrkdwn(m.text || "", usersById, channelsById);
      if (!bodyMd && attachmentIds.length === 0) continue;

      const reactions = {};
      for (const r of m.reactions ?? []) {
        const em = mapSlackEmoji(r.name);
        if (!em) continue;
        const users = (r.users ?? [])
          .map((uid) => usersById.get(uid)?.handle || String(uid))
          .filter(Boolean);
        if (users.length > 0) reactions[em] = users;
      }

      preparedMsgs.push({
        ts,
        thread_ts: m.thread_ts ? String(m.thread_ts) : null,
        author_handle: u?.handle || normalizeHandle(m.username || m.user || "slack"),
        author_name: u?.displayName || String(m.username || "Slack User"),
        author_email: u?.email || null,
        text: bodyMd,
        created_at: slackTsToIso(ts),
        attachment_ids: attachmentIds,
        reactions,
        is_decision: false,
      });
    }

    let chCreated = 0;
    let chSkipped = 0;
    for (let off = 0; off < preparedMsgs.length; off += opts.batchSize) {
      const batch = preparedMsgs.slice(off, off + opts.batchSize);
      const res = await client.reqJson("POST", "/api/v1/chat/import/slack", {
        collection_id: collectionId,
        channel: { ...chMetaPayload, id: vellumChannelId },
        messages: batch,
      });
      chCreated += res.created_count ?? 0;
      chSkipped += res.skipped_count ?? 0;
      for (const bm of batch) doneSet.add(bm.ts);
      state.importedTs[chStateKey] = [...doneSet];
      saveState(opts.statePath, state);
    }

    totalCreated += chCreated;
    totalSkipped += chSkipped;
    channelReports.push({
      channel_id: vellumChannelId,
      slug: normalizeHandle(ch.name) || "slack-import",
      created_count: chCreated,
      skipped_count: chSkipped,
    });
  }

  process.stdout.write(
    `${JSON.stringify(
      {
        dry_run: false,
        collection_slug: opts.collectionSlug,
        collection_id: collectionId,
        channels_processed: channelReports.length,
        messages_created: totalCreated,
        messages_skipped: totalSkipped,
        attachments_uploaded: totalAttachments,
        channels: channelReports,
      },
      null,
      2
    )}\n`
  );
}

run().catch((err) => {
  process.stderr.write(`slack-import error: ${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
});
