#!/usr/bin/env node
/**
 * Vellum Milestone 0 — Notion Workspace Audit Spike (Read-Only, Privacy-Preserving)
 *
 * Inspects a Notion Export ZIP (Markdown & CSV) and/or read-only Notion REST API token
 * to catalog exact features in real use (block types, DB properties, formulas, relations,
 * rollups, embeds, attachments, nesting depth, public links) and map them against Vellum v2.
 *
 * Privacy invariants:
 *  - NEVER logs or writes API tokens.
 *  - NEVER writes raw page prose or cell values to stdout or the JSON report.
 *  - Only emits structural types, schemas, formula expressions, embed hostnames, file extensions, and counts.
 */

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

function printHelp() {
  console.log(`Vellum Milestone 0 — Notion Workspace Audit Spike

Usage:
  node scripts/notion-audit.mjs [options]

Options:
  --zip <path>              Path to Notion Export ZIP (Markdown & CSV) outside the repo
  --api-token-file <path>   Path to file containing read-only Notion API token (or set NOTION_TOKEN env)
  --max-pages <n>           Max sample pages to deeply traverse via Notion API block children (default: 60)
  --max-depth <n>           Max nested block depth to traverse via Notion API (default: 2)
  --max-requests <n>        Hard cap on Notion block-children API requests (default: 250)
  --concurrency <n>         Concurrent Notion API workers for block scanning (default: 3)
  --out <path>              Output JSON report path (default: /tmp/vellum-notion-audit.json)
  -h, --help                Show this help text

Examples:
  node scripts/notion-audit.mjs --zip /tmp/notion-export.zip
  node scripts/notion-audit.mjs --api-token-file /tmp/notion.tok --out /tmp/audit.json
  node scripts/notion-audit.mjs --zip /tmp/notion-export.zip --api-token-file /tmp/notion.tok
`);
}

function parsePositiveInt(raw, fallback) {
  const parsed = Number.parseInt(raw ?? "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function parseArgs(argv) {
  const opts = {
    zipPath: null,
    tokenFile: null,
    maxPages: 60,
    maxDepth: 2,
    maxRequests: 250,
    concurrency: 3,
    outPath: path.join(os.tmpdir(), "vellum-notion-audit.json"),
    help: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "-h" || arg === "--help") {
      opts.help = true;
    } else if (arg === "--zip") {
      opts.zipPath = argv[++i] ?? null;
    } else if (arg === "--api-token-file") {
      opts.tokenFile = argv[++i] ?? null;
    } else if (arg === "--max-pages") {
      opts.maxPages = parsePositiveInt(argv[++i], 60);
    } else if (arg === "--max-depth") {
      opts.maxDepth = parsePositiveInt(argv[++i], 2);
    } else if (arg === "--max-requests") {
      opts.maxRequests = parsePositiveInt(argv[++i], 250);
    } else if (arg === "--concurrency") {
      opts.concurrency = Math.min(8, parsePositiveInt(argv[++i], 3));
    } else if (arg === "--out") {
      opts.outPath = argv[++i] ?? opts.outPath;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return opts;
}

function inc(map, key, by = 1) {
  if (!key) return;
  map[key] = (map[key] ?? 0) + by;
}

function safeHostname(rawUrl) {
  try {
    const u = new URL(rawUrl);
    return u.hostname.toLowerCase();
  } catch {
    return null;
  }
}

function stripNotionIdSuffix(rawName) {
  const base = path.basename(rawName).replace(/\.(md|csv)$/i, "").replace(/%20/g, " ").trim();
  if (base.length > 33 && base[base.length - 33] === " ") {
    const tail = base.slice(base.length - 32);
    if (/^[0-9a-fA-F]{32}$/.test(tail)) {
      return base.slice(0, base.length - 33).trim();
    }
  }
  return base;
}

function parseCsvHeader(csvText) {
  const clean = csvText.replace(/^\uFEFF/, "");
  const headers = [];
  let cur = "";
  let inQuotes = false;
  for (let i = 0; i < clean.length; i += 1) {
    const ch = clean[i];
    if (inQuotes) {
      if (ch === '"') {
        if (clean[i + 1] === '"') {
          cur += '"';
          i += 1;
        } else {
          inQuotes = false;
        }
      } else {
        cur += ch;
      }
    } else if (ch === '"') {
      inQuotes = true;
    } else if (ch === ",") {
      headers.push(cur.trim());
      cur = "";
    } else if (ch === "\r" || ch === "\n") {
      break;
    } else {
      cur += ch;
    }
  }
  if (cur.length > 0 || headers.length > 0) headers.push(cur.trim());
  return headers.filter(Boolean);
}

function countCsvRows(csvText) {
  let rows = 0;
  let inQuotes = false;
  let nonEmpty = false;
  for (let i = 0; i < csvText.length; i += 1) {
    const ch = csvText[i];
    if (ch === '"') {
      if (inQuotes && csvText[i + 1] === '"') i += 1;
      else inQuotes = !inQuotes;
      nonEmpty = true;
    } else if (ch === "\n" && !inQuotes) {
      if (nonEmpty) rows += 1;
      nonEmpty = false;
    } else if (ch !== "\r") {
      nonEmpty = true;
    }
  }
  if (nonEmpty) rows += 1;
  return Math.max(0, rows - 1);
}

function inspectZipExport(zipPath) {
  if (!fs.existsSync(zipPath)) {
    throw new Error(`ZIP file not found: ${zipPath}`);
  }
  const stat = fs.statSync(zipPath);
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "vellum-notion-zip-"));
  const result = {
    zip_size_bytes: stat.size,
    markdown_pages: 0,
    csv_databases: 0,
    csv_all_suffix_files: 0,
    max_folder_depth: 0,
    attachments_by_ext: {},
    attachment_total_bytes: 0,
    databases: [],
    syntax_cues: {
      headings: 0,
      tables: 0,
      code_fences: 0,
      checklists: 0,
      callouts_or_quotes: 0,
      html_details_toggles: 0,
      markdown_links: 0,
      wiki_links: 0,
      embedded_images: 0,
      notion_csv_embeds: 0,
      external_urls: 0,
    },
    external_embed_hosts: {},
  };

  try {
    execFileSync("unzip", ["-q", "-o", zipPath, "-d", tmpDir], { stdio: "pipe" });

    // Flatten nested Notion export-part ZIPs if Notion bundled a workspace export as inner zips.
    const topEntries = fs.readdirSync(tmpDir);
    for (const entry of topEntries) {
      if (entry.toLowerCase().endsWith(".zip")) {
        const innerZip = path.join(tmpDir, entry);
        const innerDest = path.join(tmpDir, entry.slice(0, -4));
        fs.mkdirSync(innerDest, { recursive: true });
        execFileSync("unzip", ["-q", "-o", innerZip, "-d", innerDest], { stdio: "pipe" });
        fs.unlinkSync(innerZip);
      }
    }

    function walk(dir, depth) {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) {
          if (depth + 1 > result.max_folder_depth) result.max_folder_depth = depth + 1;
          walk(full, depth + 1);
          continue;
        }
        const fstat = fs.statSync(full);
        const lower = entry.name.toLowerCase();
        if (lower.endsWith(".md")) {
          result.markdown_pages += 1;
          const md = fs.readFileSync(full, "utf8");
          const lines = md.split(/\r?\n/);
          let inFence = false;
          for (const line of lines) {
            const t = line.trim();
            if (t.startsWith("```")) {
              if (!inFence) result.syntax_cues.code_fences += 1;
              inFence = !inFence;
              continue;
            }
            if (inFence) continue;
            if (/^#{1,6}\s/.test(t)) result.syntax_cues.headings += 1;
            if (/^- \[[ xX]\]\s/.test(t)) result.syntax_cues.checklists += 1;
            if (t.startsWith(">")) result.syntax_cues.callouts_or_quotes += 1;
            if (/^\|.+\|$/.test(t)) result.syntax_cues.tables += 1;
            if (t.includes("<details>") || t.includes("<summary>")) {
              result.syntax_cues.html_details_toggles += 1;
            }
          }
          const imgMatches = md.match(/!\[[^\]]*\]\([^)]+\)/g) ?? [];
          result.syntax_cues.embedded_images += imgMatches.length;

          const wikiMatches = md.match(/\[\[[^\]]+\]\]/g) ?? [];
          result.syntax_cues.wiki_links += wikiMatches.length;

          const linkRe = /(?<!!)\[[^\]]+\]\(([^)]+)\)/g;
          let m;
          while ((m = linkRe.exec(md)) !== null) {
            const href = m[1].trim();
            if (/^https?:\/\//i.test(href)) {
              result.syntax_cues.external_urls += 1;
              const host = safeHostname(href);
              if (host) inc(result.external_embed_hosts, host);
            } else {
              result.syntax_cues.markdown_links += 1;
              if (href.toLowerCase().includes(".csv")) {
                result.syntax_cues.notion_csv_embeds += 1;
              }
            }
          }
        } else if (lower.endsWith(".csv")) {
          if (lower.endsWith("_all.csv") || lower.includes("_all ")) {
            result.csv_all_suffix_files += 1;
            continue;
          }
          result.csv_databases += 1;
          const csvText = fs.readFileSync(full, "utf8");
          const headers = parseCsvHeader(csvText);
          const rows = countCsvRows(csvText);
          result.databases.push({
            title: stripNotionIdSuffix(entry.name),
            rows,
            column_count: headers.length,
            columns: headers,
          });
        } else {
          const ext = path.extname(lower).replace(/^\./, "") || "(no_ext)";
          inc(result.attachments_by_ext, ext);
          result.attachment_total_bytes += fstat.size;
        }
      }
    }

    walk(tmpDir, 0);
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
  return result;
}

const NOTION_VERSION = "2022-06-28";

async function notionFetch(token, method, endpoint, body = null) {
  const headers = {
    Authorization: `Bearer ${token}`,
    "Notion-Version": NOTION_VERSION,
  };
  if (body !== null) headers["Content-Type"] = "application/json";

  for (let attempt = 0; attempt < 6; attempt += 1) {
    const res = await fetch(`https://api.notion.com${endpoint}`, {
      method,
      headers,
      body: body !== null ? JSON.stringify(body) : undefined,
    });
    if (res.status === 429 || res.status >= 500) {
      const retryAfterSec = Number.parseFloat(res.headers.get("retry-after") || "0");
      const backoffMs =
        retryAfterSec > 0
          ? Math.ceil(retryAfterSec * 1000) + 200
          : Math.min(8000, 400 * 2 ** attempt);
      await new Promise((r) => setTimeout(r, backoffMs));
      continue;
    }
    const text = await res.text();
    if (!res.ok) {
      throw new Error(`Notion API ${method} ${endpoint} failed (${res.status}): ${text.slice(0, 240)}`);
    }
    return JSON.parse(text);
  }
  throw new Error(`Notion API ${method} ${endpoint} exceeded rate-limit/server retries`);
}

function summarizeRichTextUrl(blockObj) {
  const btype = blockObj?.type;
  const inner = btype ? blockObj[btype] : null;
  if (!inner || typeof inner !== "object") return [];
  const hosts = [];
  if (typeof inner.url === "string") {
    const h = safeHostname(inner.url);
    if (h) hosts.push(h);
  }
  if (inner.external && typeof inner.external.url === "string") {
    const h = safeHostname(inner.external.url);
    if (h) hosts.push(h);
  }
  if (Array.isArray(inner.rich_text)) {
    for (const span of inner.rich_text) {
      if (span?.href) {
        const h = safeHostname(span.href);
        if (h) hosts.push(h);
      }
    }
  }
  return hosts;
}

function buildRepresentativeSample(pages, maxPages) {
  const seen = new Set();
  const sample = [];
  const addPage = (pg) => {
    if (!pg || seen.has(pg.id) || sample.length >= maxPages) return false;
    seen.add(pg.id);
    sample.push(pg);
    return true;
  };

  // 1. Prioritize non-database wiki/doc pages (root, page, block, workspace parents).
  const docPages = pages.filter((p) => p.parent?.type !== "database_id");
  for (const pg of docPages) {
    if (sample.length >= maxPages) break;
    addPage(pg);
  }

  // 2. Include up to 2 sample row pages per distinct database so DB templates/body structures appear.
  const rowsByDb = new Map();
  for (const pg of pages) {
    if (pg.parent?.type !== "database_id") continue;
    const dbId = pg.parent.database_id ?? "unknown";
    if (!rowsByDb.has(dbId)) rowsByDb.set(dbId, []);
    rowsByDb.get(dbId).push(pg);
  }
  for (const dbRows of rowsByDb.values()) {
    for (const pg of dbRows.slice(0, 2)) {
      if (sample.length >= maxPages) break;
      addPage(pg);
    }
  }

  // 3. Top up with any remaining pages up to maxPages.
  for (const pg of pages) {
    if (sample.length >= maxPages) break;
    addPage(pg);
  }
  return sample;
}

async function inspectNotionApi(token, maxPages, maxDepth, maxRequests, concurrency) {
  const MAX_SEARCH_CALLS = 50;
  const summary = {
    total_pages_seen: 0,
    pages_block_scanned: 0,
    search_requests_used: 0,
    search_truncated: false,
    block_requests_used: 0,
    block_requests_limit: maxRequests,
    scan_truncated: false,
    total_databases_seen: 0,
    total_blocks_scanned: 0,
    public_pages_count: 0,
    public_databases_count: 0,
    pages_with_covers: 0,
    pages_with_icons: 0,
    parent_kinds: {},
    block_types: {},
    db_property_types: {},
    external_hosts: {},
    file_block_kinds: {},
    synced_blocks_original: 0,
    synced_blocks_reference: 0,
    databases: [],
  };

  let cursor = undefined;
  const pages = [];
  const databases = [];

  do {
    if (summary.search_requests_used >= MAX_SEARCH_CALLS) {
      summary.search_truncated = true;
      break;
    }
    const payload = { page_size: 100 };
    if (cursor) payload.start_cursor = cursor;
    summary.search_requests_used += 1;
    const data = await notionFetch(token, "POST", "/v1/search", payload);
    for (const item of data.results ?? []) {
      if (item.object === "database") databases.push(item);
      else if (item.object === "page") pages.push(item);
    }
    if (summary.search_requests_used % 5 === 0 || !data.has_more) {
      console.error(
        `[notion-audit] search(${summary.search_requests_used}/${MAX_SEARCH_CALLS}): ${pages.length} pages, ${databases.length} databases`
      );
    }
    cursor = data.has_more ? data.next_cursor : undefined;
  } while (cursor);

  summary.total_pages_seen = pages.length;
  summary.total_databases_seen = databases.length;

  for (const db of databases) {
    if (db.public_url) summary.public_databases_count += 1;
    const dbTitle = (db.title ?? []).map((t) => t.plain_text ?? "").join("").trim() || "(untitled database)";
    const propEntries = Object.entries(db.properties ?? {});
    const schemaSummary = [];
    for (const [propName, propDef] of propEntries) {
      inc(summary.db_property_types, propDef.type);
      const entry = { name: propName, type: propDef.type };
      if (propDef.type === "formula") {
        entry.formula_expression = propDef.formula?.expression ?? "";
      } else if (propDef.type === "relation") {
        entry.relation_database_id = propDef.relation?.database_id ?? null;
        entry.relation_kind = propDef.relation?.type ?? "dual_or_single";
      } else if (propDef.type === "rollup") {
        entry.rollup_function = propDef.rollup?.function ?? "";
        entry.rollup_relation_prop = propDef.rollup?.relation_property_name ?? "";
        entry.rollup_target_prop = propDef.rollup?.rollup_property_name ?? "";
      } else if (propDef.type === "select" || propDef.type === "multi_select" || propDef.type === "status") {
        entry.option_count = (propDef[propDef.type]?.options ?? []).length;
      }
      schemaSummary.push(entry);
    }
    summary.databases.push({
      id: db.id,
      title: dbTitle,
      is_inline: Boolean(db.is_inline),
      parent_type: db.parent?.type ?? "unknown",
      has_public_url: Boolean(db.public_url),
      property_count: schemaSummary.length,
      properties: schemaSummary,
    });
  }

  for (const pg of pages) {
    inc(summary.parent_kinds, pg.parent?.type ?? "unknown");
    if (pg.public_url) summary.public_pages_count += 1;
    if (pg.cover) summary.pages_with_covers += 1;
    if (pg.icon) summary.pages_with_icons += 1;
  }

  const samplePages = buildRepresentativeSample(pages, maxPages);
  if (pages.length > samplePages.length) {
    summary.scan_truncated = true;
  }

  async function scanBlocks(blockId, depth) {
    let blkCursor = undefined;
    do {
      if (summary.block_requests_used >= maxRequests) {
        summary.scan_truncated = true;
        return;
      }
      summary.block_requests_used += 1;
      const q = blkCursor
        ? `?page_size=100&start_cursor=${encodeURIComponent(blkCursor)}`
        : "?page_size=100";
      const data = await notionFetch(token, "GET", `/v1/blocks/${encodeURIComponent(blockId)}/children${q}`);
      const nestedChildren = [];
      for (const blk of data.results ?? []) {
        summary.total_blocks_scanned += 1;
        inc(summary.block_types, blk.type);
        for (const h of summarizeRichTextUrl(blk)) {
          inc(summary.external_hosts, h);
        }
        if (blk.type === "file" || blk.type === "image" || blk.type === "pdf" || blk.type === "video") {
          const storageKind = blk[blk.type]?.type ?? "unknown";
          inc(summary.file_block_kinds, `${blk.type}:${storageKind}`);
        }
        if (blk.type === "synced_block") {
          if (blk.synced_block?.synced_from) summary.synced_blocks_reference += 1;
          else summary.synced_blocks_original += 1;
        }
        if (blk.has_children && depth < maxDepth && blk.type !== "child_page" && blk.type !== "child_database") {
          nestedChildren.push(blk.id);
        }
      }
      for (const childId of nestedChildren) {
        if (summary.block_requests_used >= maxRequests) {
          summary.scan_truncated = true;
          return;
        }
        await scanBlocks(childId, depth + 1);
      }
      blkCursor = data.has_more ? data.next_cursor : undefined;
    } while (blkCursor);
  }

  let nextIdx = 0;
  let completedPages = 0;
  async function worker() {
    while (true) {
      if (summary.block_requests_used >= maxRequests) {
        summary.scan_truncated = true;
        return;
      }
      const idx = nextIdx;
      nextIdx += 1;
      if (idx >= samplePages.length) return;
      const pg = samplePages[idx];
      summary.pages_block_scanned += 1;
      await scanBlocks(pg.id, 1);
      completedPages += 1;
      if (completedPages % 10 === 0 || completedPages === samplePages.length) {
        console.error(
          `[notion-audit] blocks: ${completedPages}/${samplePages.length} pages, ${summary.total_blocks_scanned} blocks, ${summary.block_requests_used}/${maxRequests} reqs`
        );
      }
    }
  }

  const workerCount = Math.min(concurrency, Math.max(1, samplePages.length));
  await Promise.all(Array.from({ length: workerCount }, () => worker()));

  return summary;
}

const VELLUM_BLOCK_SUPPORT = {
  paragraph: "supported (BlockKind.Paragraph)",
  heading_1: "supported (BlockKind.Heading(1))",
  heading_2: "supported (BlockKind.Heading(2))",
  heading_3: "supported (BlockKind.Heading(3))",
  heading_4: "GAP — preserve H4 heading level in BlockKind / Studio Editor",
  transcription: "GAP — map Notion AI transcription block to structured Callout/Note",
  bulleted_list_item: "supported (BlockKind.BulletListItem)",
  numbered_list_item: "supported (BlockKind.OrderedListItem)",
  to_do: "supported (BlockKind.TaskItem)",
  quote: "supported (BlockKind.Quote)",
  callout: "supported (BlockKind.Callout)",
  code: "supported (BlockKind.CodeBlock)",
  divider: "supported (BlockKind.Divider)",
  image: "partial (Image block supported; batch ZIP/API upload needed)",
  file: "partial (FileEmbed supported; batch ZIP/API upload needed)",
  pdf: "partial (FileEmbed supported; inline PDF viewer optional)",
  child_page: "partial (Notion API parent_page_id needed; flat today in importer)",
  child_database: "partial (DatabaseViewEmbed supported; auto-linking needed)",
  toggle: "GAP — needs Toggle BlockKind + TipTap Studio node",
  table: "GAP — needs Native Table BlockKind (Markdown GFM table + Editor)",
  table_row: "GAP — part of Native Table BlockKind",
  column_list: "GAP — multi-column layout block (or responsive grid stack)",
  column: "GAP — part of ColumnList layout",
  synced_block: "GAP — reusable transclusion / shared block reference",
  bookmark: "GAP — rich link preview / Bookmark block",
  embed: "GAP — safe allowlisted Embed card (Loom, YouTube, Drive, Figma)",
  link_preview: "GAP — rich link preview card",
  video: "GAP — Video/Embed block",
  equation: "GAP — KaTeX / LaTeX math block",
  table_of_contents: "GAP — auto-generated heading TOC widget",
};

const VELLUM_PROP_SUPPORT = {
  title: "supported (PropertyKind.Title)",
  rich_text: "supported (PropertyKind.RichText)",
  number: "supported (PropertyKind.Number, exact Decimal)",
  date: "supported (PropertyKind.DateProp)",
  select: "supported (PropertyKind.Select)",
  multi_select: "supported (PropertyKind.MultiSelect)",
  checkbox: "supported (PropertyKind.Checkbox)",
  people: "supported (PropertyKind.Person)",
  url: "supported (PropertyKind.Url)",
  relation: "supported in engine (PropertyKind.Relation; API/ZIP auto-wiring needed)",
  rollup: "supported in engine (PropertyKind.Rollup; API/ZIP auto-wiring needed)",
  status: "partial (maps to Select option groups or dedicated Status column)",
  formula: "GAP — needs deterministic Formula engine in Domain.DatabaseModel",
  files: "GAP — needs Attachment list CellValue / File property",
  email: "GAP — can map to RichText/Url or dedicated Email validation",
  phone_number: "GAP — can map to RichText or Phone formatting",
  created_time: "partial (DbRow already tracks created_at; expose as computed column)",
  created_by: "partial (DbRow/Page tracks created_by; expose as computed column)",
  last_edited_time: "partial (DbRow tracks updated_at; expose as computed column)",
  last_edited_by: "partial (expose last editor as computed column)",
  unique_id: "GAP — auto-increment prefixed ID column (e.g. TASK-42)",
  verification: "partial (Pages track verified_at/verified_by; extend if DB uses it)",
  place: "partial (map Notion location metadata to RichText label)",
  button: "GAP — workflow trigger button",
};

function computeParityGaps(report) {
  const gaps = [];
  if (report.zip) {
    if (report.zip.max_folder_depth > 1) {
      gaps.push({
        area: "Hierarchy",
        observed: `max folder depth ${report.zip.max_folder_depth} across ${report.zip.markdown_pages} pages`,
        status: "GAP — importer currently creates flat parent_page_id: None",
      });
    }
    if (Object.keys(report.zip.attachments_by_ext).length > 0) {
      gaps.push({
        area: "Attachments",
        observed: `${Object.values(report.zip.attachments_by_ext).reduce((a, b) => a + b, 0)} files (${(report.zip.attachment_total_bytes / (1024 * 1024)).toFixed(2)} MiB)`,
        status: "GAP — importer does not yet upload local ZIP assets to S3/disk",
      });
    }
    if (report.zip.syntax_cues.html_details_toggles > 0) {
      gaps.push({
        area: "Toggles (<details>)",
        observed: `${report.zip.syntax_cues.html_details_toggles} occurrences`,
        status: VELLUM_BLOCK_SUPPORT.toggle,
      });
    }
    if (report.zip.syntax_cues.tables > 0) {
      gaps.push({
        area: "Markdown Tables",
        observed: `${report.zip.syntax_cues.tables} table lines`,
        status: VELLUM_BLOCK_SUPPORT.table,
      });
    }
  }
  if (report.api) {
    for (const [btype, count] of Object.entries(report.api.block_types)) {
      const status = VELLUM_BLOCK_SUPPORT[btype] ?? "UNMAPPED — inspect Notion block type";
      if (!status.startsWith("supported")) {
        gaps.push({ area: `Block: ${btype}`, observed: `${count} blocks`, status });
      }
    }
    for (const [ptype, count] of Object.entries(report.api.db_property_types)) {
      const status = VELLUM_PROP_SUPPORT[ptype] ?? "UNMAPPED — inspect Notion property type";
      if (!status.startsWith("supported (")) {
        gaps.push({ area: `DB Prop: ${ptype}`, observed: `${count} columns`, status });
      }
    }
    if (report.api.public_pages_count > 0 || report.api.public_databases_count > 0) {
      gaps.push({
        area: "Public Web Sharing",
        observed: `${report.api.public_pages_count} public pages, ${report.api.public_databases_count} public DBs`,
        status: "GAP — needs read-only public share links (Standard collections only)",
      });
    }
  }
  return gaps;
}

function printMarkdownSummary(report, outPath) {
  console.log("# Vellum Milestone 0 — Notion Workspace Audit Report\n");
  if (report.zip) {
    const z = report.zip;
    console.log("## Export ZIP Summary");
    console.log(`- Markdown pages: **${z.markdown_pages}** (max folder nesting: **${z.max_folder_depth}**)`);
    console.log(`- CSV databases: **${z.csv_databases}** (skipped \`_all.csv\`: ${z.csv_all_suffix_files})`);
    console.log(
      `- Attachments: **${(z.attachment_total_bytes / (1024 * 1024)).toFixed(2)} MiB** across ${JSON.stringify(z.attachments_by_ext)}`
    );
    console.log(`- Syntax cues: ${JSON.stringify(z.syntax_cues)}`);
    if (Object.keys(z.external_embed_hosts).length > 0) {
      console.log(`- External URL hosts: ${JSON.stringify(z.external_embed_hosts)}`);
    }
    console.log("");
  }

  if (report.api) {
    const a = report.api;
    console.log("## Notion API Structural Summary");
    console.log(
      `- Pages seen: **${a.total_pages_seen}**${a.search_truncated ? " (search capped at 50 pages)" : ""} (block-sampled: **${a.pages_block_scanned}**, reqs: ${a.block_requests_used}/${a.block_requests_limit}${a.scan_truncated ? ", truncated" : ""})`
    );
    console.log(`- Databases seen: **${a.total_databases_seen}**`);
    console.log(`- Blocks scanned: **${a.total_blocks_scanned}**`);
    console.log(`- Public links: **${a.public_pages_count}** pages, **${a.public_databases_count}** DBs`);
    console.log(`- Parent kinds: ${JSON.stringify(a.parent_kinds)}`);
    console.log(`- Block histogram: ${JSON.stringify(a.block_types)}`);
    console.log(`- DB property histogram: ${JSON.stringify(a.db_property_types)}`);
    if (Object.keys(a.external_hosts).length > 0) {
      console.log(`- External link/embed hosts: ${JSON.stringify(a.external_hosts)}`);
    }
    const formulas = a.databases.flatMap((d) =>
      d.properties.filter((p) => p.type === "formula").map((p) => `${d.title}.${p.name}: ${p.formula_expression}`)
    );
    if (formulas.length > 0) {
      console.log("\n### Notion Formulas Discovered");
      for (const f of formulas) console.log(`- \`${f}\``);
    }
    console.log("");
  }

  console.log("## Vellum Parity Gap Checklist");
  if (report.parity_gaps.length === 0) {
    console.log("- No unmapped Notion primitives detected in scanned scope!");
  } else {
    console.log("| Area | Observed in Notion | Vellum Status |");
    console.log("| --- | --- | --- |");
    for (const g of report.parity_gaps) {
      console.log(`| ${g.area} | ${g.observed} | ${g.status} |`);
    }
  }
  console.log(`\nSanitized structural report written to: ${outPath}`);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    printHelp();
    return;
  }
  let token = (process.env.NOTION_TOKEN ?? "").trim();
  if (opts.tokenFile) {
    token = fs.readFileSync(opts.tokenFile, "utf8").trim();
  }
  if (!opts.zipPath && !token) {
    printHelp();
    console.error("\nError: provide --zip <path> and/or --api-token-file <path> (or NOTION_TOKEN).");
    process.exit(1);
  }

  const report = {
    generated_at: new Date().toISOString(),
    zip: opts.zipPath ? inspectZipExport(opts.zipPath) : null,
    api: token
      ? await inspectNotionApi(token, opts.maxPages, opts.maxDepth, opts.maxRequests, opts.concurrency)
      : null,
    parity_gaps: [],
  };
  report.parity_gaps = computeParityGaps(report);

  fs.mkdirSync(path.dirname(opts.outPath), { recursive: true });
  fs.writeFileSync(opts.outPath, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
  printMarkdownSummary(report, opts.outPath);
}

main().catch((err) => {
  console.error("notion-audit failed:", err instanceof Error ? err.message : String(err));
  process.exit(1);
});
