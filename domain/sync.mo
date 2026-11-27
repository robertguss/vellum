## Conflict-safe two-way local Markdown mirror helpers (`vellum sync`):
## deterministic relative mirror paths, SHA-256 content hashes, `.vellum-sync.json` manifest,
## and 3-way conflict classification routing divergent edits to `Modb.World` Change Proposals.
module Domain.Sync
expose SyncManifestEntry(..),
SyncManifest(..),
slugify_title,
page_rel_path,
derive_title_from_markdown,
sha256_text,
classify_file_sync,
empty_manifest
use Crypto

## Per-file baseline recorded in `.vellum-sync.json` after each clean pull or push.
struct SyncManifestEntry
  page_id: Text
  collection_id: Text
  collection_slug: Text
  rel_path: Text
  version: Int
  content_sha256: Text
  synced_at: Text
end

## Local `.vellum-sync.json` workspace mirror state tracked alongside mirrored Markdown files.
struct SyncManifest
  schema_version: Int
  server_url: Text
  collections: List(Text)
  files: Map(Text, SyncManifestEntry)
end

## Creates an empty v1 `SyncManifest`.
fn empty_manifest(server_url: Text, collections: List(Text)) : SyncManifest
  SyncManifest(schema_version: 1, server_url: server_url, collections: collections, files: {})
end

## Produces a URL/filesystem-safe slug from an arbitrary page title (max 48 chars, fallback `"untitled"`).
fn slugify_title(title: Text) : Text
  var chars = []
  var last_dash = true
  for ch in title.trim.ascii_lowercase.chars
    is_alnum = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9')
    if is_alnum
      chars = chars.append(ch)
      last_dash = false
    else if not last_dash
      chars = chars.append('-')
      last_dash = true
    end
    if chars.size >= 48
      break
    end
  end
  raw = Text.from_chars(chars).drop_suffix("-") or Text.from_chars(chars)
  clean = raw.trim
  if clean.empty?: "untitled" else: clean
end

## Canonical collection-scoped relative mirror path (`<col_slug>/<title-slug>--<page_id>.md`).
fn page_rel_path(col_slug: Text, title: Text, page_id: Text) : Text
  "#{col_slug}/#{slugify_title(title)}--#{page_id}.md"
end

## Derives a human page title from the first `# Heading` line or filename stem when creating a new page locally.
fn derive_title_from_markdown(rel_path: Text, body_markdown: Text) : Text
  for raw_l in body_markdown.lines
    t = raw_l.trim
    if t.starts_with?("# ")
      h = (t.drop_prefix("# ") or "").trim
      if not h.empty?
        return h
      end
    end
  end
  fname = rel_path.split("/").last or "untitled"
  stem = fname.drop_suffix(".md") or fname
  no_pid = case stem.split("--pg_")
    ps if ps.size >= 2: ps.first or stem
    _: stem
  end
  spaced = no_pid.replace("-", " ").replace("_", " ").trim
  if spaced.empty?: "Untitled Note" else: spaced
end

## Deterministic SHA-256 hex digest of UTF-8 file contents.
fn sha256_text(text: Text) : Text
  Crypto.sha256(text.bytes).to_hex
end

## 3-way conflict-safe state classifier (`"clean"`, `"pull_new"`, `"pull_update"`, `"push_create"`,
## `"push_update"`, `"conflict_proposal"`, `"remote_deleted"`).
fn classify_file_sync(
  entry_opt: Option(SyncManifestEntry),
  local_sha_opt: Option(Text),
  remote_ver_opt: Option(Int),
  remote_sha_opt: Option(Text)
) : Text
  case (entry_opt, local_sha_opt, remote_ver_opt, remote_sha_opt)
    (None, None, Some(_), Some(_)): "pull_new"
    (None, Some(_), None, None): "push_create"
    (None, Some(lsha), Some(_), Some(rsha)):
      if lsha == rsha: "clean" else: "conflict_proposal"
    (Some(e), Some(lsha), Some(rver), Some(rsha)):
      local_dirty = lsha != e.content_sha256
      remote_dirty = rver != e.version or rsha != e.content_sha256
      if lsha == rsha
        "clean"
      else if local_dirty and remote_dirty
        "conflict_proposal"
      else if local_dirty
        "push_update"
      else if remote_dirty
        "pull_update"
      else
        "clean"
      end
    (Some(_), None, Some(_), Some(_)): "pull_update"
    (Some(_), Some(_), None, None): "remote_deleted"
    (_, _, _, _): "clean"
  end
end

test "Sync deterministic paths, title derivation, SHA-256, and 3-way conflict classification"
  assert slugify_title("Gateway / Failover Runbook!!") == "gateway-failover-runbook"
  assert page_rel_path("eng-ops", "Gateway Runbook", "pg_123") == "eng-ops/gateway-runbook--pg_123.md"
  assert derive_title_from_markdown("eng-ops/new-sop.md", "Intro") == "new sop"
  assert derive_title_from_markdown("eng-ops/a.md", "# Service Failover Plan\n\nSteps") == "Service Failover Plan"

  base_sha = sha256_text("v1 content")
  local_sha = sha256_text("v1 local edit")
  remote_sha = sha256_text("v2 remote edit")
  entry = SyncManifestEntry(
    page_id: "pg_1",
    collection_id: "col_1",
    collection_slug: "eng",
    rel_path: "eng/doc--pg_1.md",
    version: 1,
    content_sha256: base_sha,
    synced_at: "2026-12-05T10:00:00Z"
  )

  assert classify_file_sync(None, None, Some(1), Some(base_sha)) == "pull_new"
  assert classify_file_sync(None, Some(local_sha), None, None) == "push_create"
  assert classify_file_sync(Some(entry), Some(base_sha), Some(1), Some(base_sha)) == "clean"
  assert classify_file_sync(Some(entry), Some(local_sha), Some(1), Some(base_sha)) == "push_update"
  assert classify_file_sync(Some(entry), Some(base_sha), Some(2), Some(remote_sha)) == "pull_update"
  assert classify_file_sync(Some(entry), Some(local_sha), Some(2), Some(remote_sha)) == "conflict_proposal"
  assert classify_file_sync(Some(entry), None, Some(1), Some(base_sha)) == "pull_update"
  assert classify_file_sync(Some(entry), Some(local_sha), None, None) == "remote_deleted"
end
