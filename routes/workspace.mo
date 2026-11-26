## Vellum workspace, collection, canonical block-tree, search, attachment, and admin handlers.
module Routes.Workspace
expose CreateCollectionInput(..),
CreatePageInput(..),
PatchBlocksInput(..),
VerifyPageInput(..),
CreateCommentInput(..),
PresignAttachmentInput(..),
MintAgentTokenInput(..),
home,
show_collection,
create_collection,
show_page,
create_page,
patch_blocks,
verify_page,
search,
create_comment,
presign_attachment,
commit_attachment,
download_attachment,
mint_agent_token,
revoke_grant,
audit_index,
proposals_page,
admin_page,
drain_jobs
use Api
use Arvo.Flash
use Arvo.Id
use Arvo.Inertia
use Arvo.Modb.Jobs
use Arvo.Modb.Sessions
use Arvo.S3
use Arvo.Webhooks
use Db
use Domain.Blocks
use Domain.Collab{WebhookJobPayload}
use Domain.DatabaseModel{DatabaseDef}
use Domain.Policy
use Domain.Types{
  AppError,
  Attachment,
  AuditFeedItem,
  AuthContext,
  AuthorKind,
  Block,
  BlockOp,
  Collection,
  CollectionWritePolicy,
  Comment,
  Page,
  PageKind,
  PrincipalKind,
  Provenance,
  WorkspaceRole
}
use Json
use Modb{Store, WriteTx}
use Modb.Grants
use Modb.Ledger
use Modb.Table
use Routes.Ai
use Routes.Auth

## JSON payload for `POST /api/collections`.
struct CreateCollectionInput
  slug: Text
  name: Text
  description: Option(Text)
  icon: Option(Text)
  write_policy: CollectionWritePolicy
  freshness_ttl_days: Option(Int)
end

## JSON payload for `POST /api/pages`.
struct CreatePageInput
  collection_id: Text
  parent_page_id: Option(Text)
  title: Text
  markdown: Text
  icon: Option(Text)
  freshness_ttl_days: Option(Int)
  reason: Option(Text)
end

## JSON payload for `PATCH /api/pages/:id/blocks`.
struct PatchBlocksInput
  ops: List(BlockOp)
  expected_versions: Map(Text, Int)
  reason: Option(Text)
end

## Optional JSON payload for `POST /api/pages/:id/verify`.
struct VerifyPageInput
  freshness_ttl_days: Option(Int)
end

## JSON payload for `POST /api/pages/:id/comments`.
struct CreateCommentInput
  block_id: Option(Text)
  parent_comment_id: Option(Text)
  body_markdown: Text
end

## JSON payload for `POST /api/attachments/presign`.
struct PresignAttachmentInput
  page_id: Text
  filename: Text
  content_type: Text
  size_bytes: Int
  sha256_hex: Option(Text)
end

## JSON payload for `POST /api/admin/agents`.
struct MintAgentTokenInput
  handle: Text
  display_name: Text
  model_id: Option(Text)
  label: Text
  allowed_actions: List(Text)
  allowed_collections: Option(List(Text))
  max_calls: Int
  ttl_days: Int
end

fn json_ok(status: Int, body: Json) : Api.Response
  Api.encoded_json_response(status, body).with_header(
    "Content-Type",
    "application/json; charset=utf-8"
  )
end

fn guest_redirect_or_401(req: Api.Request) : Result(Api.Response, AppError)
  if Auth.wants_json?(req)
    Error(Unauthenticated)
  else
    Ok(Inertia.redirect("/login"))
  end
end

fn make_provenance(auth: AuthContext, reason: Option(Text), now: Time) : Provenance
  author_kind = case auth.principal.kind
    Human: HumanAuthor
    Agent: AgentAuthor(model: auth.principal.model_id)
  end
  grant_id = if auth.principal.kind == Agent: Some(auth.grant_id) else: None
  Provenance(
    author_id: auth.principal.id,
    author_kind: author_kind,
    grant_id: grant_id,
    proposal_id: None,
    reason: reason,
    citations: [],
    updated_at: now
  )
end

fn audit_entry_to_feed(entry: Ledger.AuditEntry) : AuditFeedItem
  AuditFeedItem(
    seq: entry.seq,
    txid: entry.txid,
    actor_name: entry.principal,
    action: entry.action,
    reason: entry.reason,
    summary: entry.summary,
    at: entry.at
  )
end

fn tx_authorize_if_agent(tx: WriteTx, auth: AuthContext, action: Text, now: Time) : Result(
  WriteTx,
  AppError
)
  if auth.principal.kind == Agent
    (t1, _g) = try Grants.tx_authorize(tx, auth.grant_id, action, now).map_error(
      Db.map_grants_error
    )
    Ok(t1)
  else
    Ok(tx)
  end
end

fn map_s3_error(err: S3.S3Error) : AppError
  case err
    S3.InvalidConfig(reason: _) | S3.InvalidHeader(name: _): ServerFailed(reason: err.to_text)
    S3.InvalidKey(reason: _) | S3.InvalidExpiry(seconds: _): BadInput(reason: err.to_text)
  end
end

fn map_block_op_error(msg: Text) : AppError
  if msg.contains?("expected version") or msg.contains?("version")
    Conflict(reason: msg)
  else if msg.contains?("not found")
    Missing(entity: "block", id: msg)
  else
    BadInput(reason: msg)
  end
end

fn sanitize_filename_segment(raw: Text) : Text
  var chars = []
  for ch in raw.trim.chars
    ok = ch.ascii_letter? or ch.ascii_digit? or ch == '.' or ch == '-' or ch == '_'
    chars = chars.append(if ok: ch else: '_')
  end
  cleaned = Text.from_chars(chars)
  if cleaned.empty? or cleaned == "." or cleaned == "..": "upload.bin" else: cleaned
end

fn parse_limit(raw: Option(Text), default_val: Int, max_val: Int) : Int
  case raw
    None: default_val
    Some(s):
      case s.trim.to_int
        None: default_val
        Some(n):
          if n < 1
            1
          else if n > max_val
            max_val
          else
            n
          end
      end
  end
end

fn permitted_collections(store: Store, auth: AuthContext) : Result(List(Collection), AppError)
  rows = try Table.scan(store, Db.collections_table(), None, None, 200).map_error(
    Db.map_table_error
  )
  var out = []
  for (_id, col) in rows
    if col.archived_at == None and Policy.collection_permitted?(auth, col.id)
      out = out.append(col)
    end
  end
  Ok(out)
end

fn permitted_databases(store: Store, auth: AuthContext) : Result(List(DatabaseDef), AppError)
  rows = try Table.scan(store, Db.databases_table(), None, None, 200).map_error(Db.map_table_error)
  var out = []
  for (_id, d) in rows
    if Policy.collection_permitted?(auth, d.collection_id)
      out = out.append(d)
    end
  end
  Ok(out)
end

fn render_inertia_page(
  req: Api.Request,
  auth: AuthContext,
  rf: ReadFiles,
  env: Env,
  component: Text,
  props: Map(Text, Json)
) : Result(Api.Response, AppError)
  icfg = try Auth.load_inertia_config(rf, env)
  if Inertia.check_version(req, icfg) is Some(ver_res)
    return Ok(ver_res)
  end
  key = try Auth.app_secret_key(env)
  (shared, had_flash?) = Auth.shared_props(req, Some(auth), key)
  res = Inertia.render(req, icfg, component, props, shared)
  Ok(Flash.clear_if_present(res, had_flash?, Auth.secure_cookies?(env)))
end

## `GET /` — Renders the Vellum workspace home shell (strictly `ReadFiles`-only).
fn home(req: Api.Request, auth: Option(AuthContext), rf: ReadFiles, env: Env) : Result(
  Api.Response,
  AppError
)
  a = case auth
    Some(x): x
    None: return guest_redirect_or_401(req)
  end
  if not Policy.action_permitted?(a, "read")
    return Error(Forbidden(reason: "grant '#{a.grant_id}' does not permit 'read'"))
  end

  (cols, dbs, pages, audit_feed) = if not rf.exists?(Db.ledger_db_path)
    ([], [], [], [])
  else
    try Ledger.read_locked(
      rf,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        store = Ledger.store(db)
        c_list = try permitted_collections(store, a)
        d_list = try permitted_databases(store, a)
        p_rows = try Table.scan(store, Db.pages_table(), None, None, 100).map_error(
          Db.map_table_error
        )
        var visible_pages = []
        for (_pid, p) in p_rows
          if p.archived_at == None and Policy.collection_permitted?(a, p.collection_id)
            visible_pages = visible_pages.append(p)
          end
        end
        entries = try Ledger.audit_tail_store(store, 20).map_error(Db.map_ledger_error)
        feed = entries.map(audit_entry_to_feed)
        Ok((c_list, d_list, visible_pages, feed))
      end
    )
  end

  if Auth.wants_json?(req)
    return Ok(
      json_ok(
        200,
        Json.Object({
          "collections": cols.to_json,
          "databases": dbs.to_json,
          "pages": pages.to_json,
          "audit_feed": audit_feed.to_json
        })
      )
    )
  end

  render_inertia_page(
    req,
    a,
    rf,
    env,
    "Workspace/Home",
    {
      "collections": cols.to_json,
      "databases": dbs.to_json,
      "pages": pages.to_json,
      "audit_feed": audit_feed.to_json
    }
  )
end

## `GET /c/:slug` and `GET /api/collections/:slug` — Shows a collection and its pages (`ReadFiles`-only).
fn show_collection(req: Api.Request, slug: Text, auth: Option(AuthContext), rf: ReadFiles, env: Env) : Result(
  Api.Response,
  AppError
)
  a = case auth
    Some(x): x
    None: return guest_redirect_or_401(req)
  end
  if not rf.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "collection", id: slug))
  end

  (cols, dbs, col, pages) = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      col = case try Table.lookup_unique(
        store,
        Db.collections_table(),
        Db.collections_by_slug(),
        slug
      ).map_error(Db.map_table_error)
        Some((_cid, c)): c
        None: return Error(Missing(entity: "collection", id: slug))
      end
      try Policy.require_collection_access(a, "read", col.id)
      page_rows = try Table.lookup(store, Db.pages_table(), Db.pages_by_collection(), col.id)
        .map_error(Db.map_table_error)
      var active_pages = []
      for (_pid, p) in page_rows
        if p.archived_at == None
          active_pages = active_pages.append(p)
        end
      end
      c_list = try permitted_collections(store, a)
      d_list = try permitted_databases(store, a)
      Ok((c_list, d_list, col, active_pages))
    end
  )

  if Auth.wants_json?(req)
    return Ok(json_ok(200, Json.Object({"collection": col.to_json, "pages": pages.to_json})))
  end
  render_inertia_page(
    req,
    a,
    rf,
    env,
    "Workspace/Collection",
    {
      "collections": cols.to_json,
      "databases": dbs.to_json,
      "collection": col.to_json,
      "pages": pages.to_json
    }
  )
end

## `POST /api/collections` — Creates a new collection (requires `manage_schema`).
fn create_collection(
  req: Api.Request,
  auth: AuthContext,
  input: CreateCollectionInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if not Policy.action_permitted?(auth, "manage_schema")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'manage_schema'"))
  end
  clean_slug = input.slug.trim
  if not Policy.valid_collection_slug?(clean_slug)
    return Error(
      BadInput(
        reason: "slug '#{clean_slug}' must be 2..48 lowercase [a-z0-9-] without leading/trailing hyphen"
      )
    )
  end
  clean_name = input.name.trim
  if clean_name.empty?
    return Error(BadInput(reason: "collection name must not be empty"))
  end

  now = clock.now
  col_id = "col_#{Id.ulid(rng, clock)}"
  col = Collection(
    id: col_id,
    workspace_id: Db.default_workspace_id,
    slug: clean_slug,
    name: clean_name,
    description: (input.description or "").trim,
    icon: input.icon,
    write_policy: input.write_policy,
    freshness_ttl_days: input.freshness_ttl_days,
    sort_order: col_id,
    archived_at: None
  )

  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "collection.create",
    reason: "create collection '#{col.slug}'",
    at: now
  )
  audit_payload = Json.Object({"collection_id": Json.String(col.id), "slug": Json.String(col.slug)})
  created = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "created collection #{col.slug}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "manage_schema", now)
      t2 = try Table.put(t1, Db.collections_table(), col.id, col).map_error(Db.map_table_error)
      Ok((t2, col))
    end
  )
  Ok(json_ok(201, created.to_json))
end

## `GET /p/:id` and `GET /api/pages/:id` — Loads page, sorted blocks, anchored Markdown, comments, and attachments.
fn show_page(req: Api.Request, id: Text, auth: Option(AuthContext), rf: ReadFiles, env: Env) : Result(
  Api.Response,
  AppError
)
  a = case auth
    Some(x): x
    None: return guest_redirect_or_401(req)
  end
  if not rf.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "page", id: id))
  end

  page_bundle = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      page = case try Table.get(store, Db.pages_table(), id).map_error(Db.map_table_error)
        Some(p) if p.archived_at == None: p
        Some(_) | None: return Error(Missing(entity: "page", id: id))
      end
      try Policy.require_collection_access(a, "read", page.collection_id)
      col = case try Table.get(store, Db.collections_table(), page.collection_id).map_error(
        Db.map_table_error
      )
        Some(c): c
        None: return Error(Missing(entity: "collection", id: page.collection_id))
      end
      blks = try Db.load_page_blocks(store, page.id)
      cmt_rows = try Table.lookup(store, Db.comments_table(), Db.comments_by_page(), page.id)
        .map_error(Db.map_table_error)
      att_rows = try Table.lookup(store, Db.attachments_table(), Db.attachments_by_page(), page.id)
        .map_error(Db.map_table_error)
      c_list = try permitted_collections(store, a)
      d_list = try permitted_databases(store, a)
      Ok((c_list, d_list, col, page, blks, cmt_rows.map(fn(x) x.1 end), att_rows.map(fn(x) x.1 end)))
    end
  )

  (cols, dbs, col, page, blocks, comments, attachments) = page_bundle
  anchored_md = Blocks.to_anchored_markdown(blocks)
  if Auth.wants_json?(req)
    return Ok(
      json_ok(
        200,
        Json.Object({
          "page": page.to_json,
          "collection": col.to_json,
          "blocks": blocks.to_json,
          "anchored_markdown": Json.String(anchored_md),
          "comments": comments.to_json,
          "attachments": attachments.to_json
        })
      )
    )
  end

  render_inertia_page(
    req,
    a,
    rf,
    env,
    "Workspace/Page",
    {
      "collections": cols.to_json,
      "databases": dbs.to_json,
      "collection": col.to_json,
      "page": page.to_json,
      "blocks": blocks.to_json,
      "anchored_markdown": Json.String(anchored_md),
      "comments": comments.to_json,
      "attachments": attachments.to_json
    }
  )
end

## `POST /api/pages` — Creates a page with canonical blocks and BM25 FTS indexing.
fn create_page(
  req: Api.Request,
  auth: AuthContext,
  input: CreatePageInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  clean_title = input.title.trim
  if clean_title.empty?
    return Error(BadInput(reason: "page title must not be empty"))
  end
  try Policy.require_collection_access(auth, "write_direct", input.collection_id)

  now = clock.now
  page_id = "pg_#{Id.ulid(rng, clock)}"
  block_prefix = "blk_#{Id.ulid(rng, clock)}"
  prov = make_provenance(auth, input.reason, now)
  blocks = Blocks.parse_markdown_blocks(page_id, input.markdown, prov, block_prefix)
  job_rec = Jobs.prepare(
    rng,
    clock,
    "vellum.page.indexed",
    Json.Object({"page_id": Json.String(page_id), "collection_id": Json.String(input.collection_id)})
  )

  page = Page(
    id: page_id,
    collection_id: input.collection_id,
    parent_page_id: input.parent_page_id,
    title: clean_title,
    icon: input.icon,
    cover_attachment_id: None,
    kind: Document,
    sort_order: page_id,
    database_id: None,
    freshness_ttl_days: input.freshness_ttl_days,
    verified_at: None,
    verified_by: None,
    created_by: auth.principal.id,
    created_at: now,
    updated_at: now,
    archived_at: None,
    version: 1
  )

  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "page.create",
    reason: input.reason or "create page '#{page.title}'",
    at: now
  )
  audit_payload = Json.Object({
    "page_id": Json.String(page.id),
    "collection_id": Json.String(page.collection_id),
    "block_count": Json.int(blocks.size)
  })
  (saved_page, saved_blocks) = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "created page #{page.id} (#{page.title})",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "write_direct", now)
      col = case try Table.tx_get(t1, Db.collections_table(), input.collection_id).map_error(
        Db.map_table_error
      )
        Some(c) if c.archived_at == None: c
        Some(_) | None: return Error(Missing(entity: "collection", id: input.collection_id))
      end
      if not Policy.can_write_page_direct?(auth, col)
        return Error(
          Forbidden(
            reason: "collection '#{col.slug}' write policy prohibits direct writes by this principal"
          )
        )
      end
      case input.parent_page_id
        Some(pid):
          case try Table.tx_get(t1, Db.pages_table(), pid).map_error(Db.map_table_error)
            Some(par) if par.archived_at == None and par.collection_id == col.id: Unit
            Some(_): return Error(BadInput(reason: "parent_page_id must belong to same collection"))
            None: return Error(Missing(entity: "parent_page", id: pid))
          end
        None: Unit
      end
      t2 = try Db.tx_save_page_and_blocks(t1, page, blocks)
      (t3, _jid) = try Jobs.tx_put(t2, job_rec).map_error(Db.map_table_error)
      Ok((t3, (page, blocks)))
    end
  )

  page_ev = Json.Object({
    "page_id": Json.String(saved_page.id),
    "collection_id": Json.String(saved_page.collection_id),
    "title": Json.String(saved_page.title),
    "actor": Json.String(auth.principal.handle)
  })
  Ok(
    json_ok(
      201,
      Json.Object({
        "page": saved_page.to_json,
        "blocks": saved_blocks.to_json,
        "anchored_markdown": Json.String(Blocks.to_anchored_markdown(saved_blocks))
      })
    ).with_sse_publish_json("collection:#{saved_page.collection_id}", "page.created", page_ev)
  )
end

fn verify_expected_block_versions(existing: List(Block), expected_versions: Map(Text, Int)) : Result(
  Unit,
  AppError
)
  var by_id = {}
  for b in existing
    by_id = by_id.set(b.id, b.version)
  end
  for (bid, exp_ver) in expected_versions.entries
    case by_id.get(bid)
      None: return Error(Missing(entity: "block", id: bid))
      Some(actual_ver):
        if actual_ver != exp_ver
          return Error(
            Conflict(
              reason: "block '#{bid}' version mismatch: expected #{exp_ver}, found #{actual_ver}"
            )
          )
        end
    end
  end
  Ok(Unit)
end

## `PATCH /api/pages/:id/blocks` — Applies surgical `BlockOp`s with optimistic version checks & re-indexes FTS.
fn patch_blocks(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  input: PatchBlocksInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if input.ops.empty?
    return Error(BadInput(reason: "ops must not be empty"))
  end

  var new_ids = []
  for op in input.ops
    case op
      InsertBlockAfter(after_block_id: _, parent_block_id: _, kind: _, markdown: _): new_ids = new_ids
        .append("blk_#{Id.ulid(rng, clock)}")
      ReplaceBlock(block_id: _, expected_version: _, kind: _, markdown: _) | DeleteBlock(
        block_id: _,
        expected_version: _
      ) | MoveBlock(block_id: _, new_parent_id: _, after_block_id: _) | AttachCitations(
        block_id: _,
        citations: _
      ): Unit
    end
  end

  now = clock.now
  prov = make_provenance(auth, input.reason, now)
  idx_job = Jobs.prepare(
    rng,
    clock,
    "vellum.page.indexed",
    Json.Object({"page_id": Json.String(id)})
  )
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "page.patch_blocks",
    reason: input.reason or "surgical block patch on #{id}",
    at: now
  )
  audit_payload = Json.Object({"page_id": Json.String(id), "op_count": Json.int(input.ops.size)})

  (next_page, next_blocks) = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "patched #{input.ops.size} blocks on #{id}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "write_direct", now)
      old_page = case try Table.tx_get(t1, Db.pages_table(), id).map_error(Db.map_table_error)
        Some(p) if p.archived_at == None: p
        Some(_) | None: return Error(Missing(entity: "page", id: id))
      end
      try Policy.require_collection_access(auth, "write_direct", old_page.collection_id)
      col = case try Table.tx_get(t1, Db.collections_table(), old_page.collection_id).map_error(
        Db.map_table_error
      )
        Some(c): c
        None: return Error(Missing(entity: "collection", id: old_page.collection_id))
      end
      if not Policy.can_write_page_direct?(auth, col)
        return Error(
          Forbidden(
            reason: "collection '#{col.slug}' write policy requires change proposals for this principal"
          )
        )
      end

      existing_rows = try Table.tx_lookup(t1, Db.blocks_table(), Db.blocks_by_page(), id).map_error(
        Db.map_table_error
      )
      existing_blocks = Blocks.sort_blocks(existing_rows.map(fn(x) x.1 end))
      try verify_expected_block_versions(existing_blocks, input.expected_versions)
      updated_blocks = try Blocks.apply_block_ops(existing_blocks, input.ops, id, prov, new_ids)
        .map_error(map_block_op_error)

      bumped_page = Page(
        id: old_page.id,
        collection_id: old_page.collection_id,
        parent_page_id: old_page.parent_page_id,
        title: old_page.title,
        icon: old_page.icon,
        cover_attachment_id: old_page.cover_attachment_id,
        kind: old_page.kind,
        sort_order: old_page.sort_order,
        database_id: old_page.database_id,
        freshness_ttl_days: old_page.freshness_ttl_days,
        verified_at: old_page.verified_at,
        verified_by: old_page.verified_by,
        created_by: old_page.created_by,
        created_at: old_page.created_at,
        updated_at: now,
        archived_at: old_page.archived_at,
        version: old_page.version + 1
      )
      t2 = try Db.tx_save_page_and_blocks(t1, bumped_page, updated_blocks)
      (t3, _jid) = try Jobs.tx_put(t2, idx_job).map_error(Db.map_table_error)
      Ok((t3, (bumped_page, updated_blocks)))
    end
  )

  blocks_ev = Json.Object({
    "page_id": Json.String(next_page.id),
    "collection_id": Json.String(next_page.collection_id),
    "version": Json.int(next_page.version),
    "actor": Json.String(auth.principal.handle),
    "reason": Json.String((input.reason or "update blocks").trim)
  })
  Ok(
    json_ok(
      200,
      Json.Object({
        "page": next_page.to_json,
        "blocks": next_blocks.to_json,
        "anchored_markdown": Json.String(Blocks.to_anchored_markdown(next_blocks))
      })
    ).with_sse_publish_json("page:#{next_page.id}", "page.blocks_updated", blocks_ev)
      .with_sse_publish_json("collection:#{next_page.collection_id}", "page.blocks_updated", blocks_ev)
  )
end

## `POST /api/pages/:id/verify` — Marks a page freshly verified (`verified_at`, `verified_by`).
fn verify_page(req: Api.Request, id: Text, auth: AuthContext, files: Files, clock: Clock) : Result(
  Api.Response,
  AppError
)
  try Auth.require_session_csrf(req, auth)
  ttl_override = if req.body.empty?
    None
  else
    parsed = try Json.decode_strict[VerifyPageInput](req.body).map_error(fn(e)
      BadInput(reason: "invalid verify payload: #{e.to_text}")
    end)
    parsed.freshness_ttl_days
  end

  action_needed = if Policy.action_permitted?(auth, "publish")
    "publish"
  else
    "write_direct"
  end
  now = clock.now
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "page.verify",
    reason: "verify page '#{id}'",
    at: now
  )
  audit_payload = Json.Object({
    "page_id": Json.String(id),
    "verified_by": Json.String(auth.principal.id)
  })

  updated = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "verified page #{id}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, action_needed, now)
      old_page = case try Table.tx_get(t1, Db.pages_table(), id).map_error(Db.map_table_error)
        Some(p) if p.archived_at == None: p
        Some(_) | None: return Error(Missing(entity: "page", id: id))
      end
      try Policy.require_collection_access(auth, action_needed, old_page.collection_id)
      next_ttl = case ttl_override
        Some(v): Some(v)
        None: old_page.freshness_ttl_days
      end
      next_p = Page(
        id: old_page.id,
        collection_id: old_page.collection_id,
        parent_page_id: old_page.parent_page_id,
        title: old_page.title,
        icon: old_page.icon,
        cover_attachment_id: old_page.cover_attachment_id,
        kind: old_page.kind,
        sort_order: old_page.sort_order,
        database_id: old_page.database_id,
        freshness_ttl_days: next_ttl,
        verified_at: Some(now),
        verified_by: Some(auth.principal.id),
        created_by: old_page.created_by,
        created_at: old_page.created_at,
        updated_at: now,
        archived_at: old_page.archived_at,
        version: old_page.version + 1
      )
      t2 = try Table.put(t1, Db.pages_table(), next_p.id, next_p).map_error(Db.map_table_error)
      Ok((t2, next_p))
    end
  )
  verify_ev = Json.Object({
    "page_id": Json.String(updated.id),
    "collection_id": Json.String(updated.collection_id),
    "version": Json.int(updated.version),
    "actor": Json.String(auth.principal.handle)
  })
  Ok(
    json_ok(200, updated.to_json)
      .with_sse_publish_json("page:#{updated.id}", "page.verified", verify_ev)
      .with_sse_publish_json("collection:#{updated.collection_id}", "page.verified", verify_ev)
  )
end

## `GET /api/search` — Fail-closed grant-filtered Hybrid (BM25 + `Modb.Vec` RRF), `bm25`, or `semantic` search (`ReadFiles`-only).
fn search(
  req: Api.Request,
  auth: AuthContext,
  rf: ReadFiles,
  env: Env,
  net: Network
) : Result(Api.Response, AppError)
  if not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  q = (req.query_param("q") or "").trim
  limit = parse_limit(req.query_param("limit"), 20, 100)
  col_filter = case req.query_param("collection_id")
    Some(c) if not c.trim.empty?: Some(c.trim)
    Some(_) | None: None
  end
  out = try Ai.execute_workspace_search(
    rf,
    auth,
    q,
    limit,
    true,
    col_filter,
    req.query_param("mode"),
    env,
    net
  )
  Ok(
    json_ok(
      200,
      Json.Object({
        "results": out.results.to_json,
        "mode": Json.String(out.mode),
        "vector_backend": Json.String(out.vector_backend)
      })
    )
  )
end

## `POST /api/pages/:id/comments` — Creates a page or block comment.
fn create_comment(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  input: CreateCommentInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  body_md = input.body_markdown.trim
  if body_md.empty?
    return Error(BadInput(reason: "comment body_markdown must not be empty"))
  end

  now = clock.now
  cmt_id = "cmt_#{Id.ulid(rng, clock)}"
  cmt = Comment(
    id: cmt_id,
    page_id: id,
    block_id: input.block_id,
    parent_comment_id: input.parent_comment_id,
    author_id: auth.principal.id,
    body_markdown: body_md,
    resolved_at: None,
    created_at: now
  )
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "comment.create",
    reason: "comment on page '#{id}'",
    at: now
  )
  audit_payload = Json.Object({"comment_id": Json.String(cmt.id), "page_id": Json.String(id)})

  (created, col_id) = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "commented on page #{id}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "comment", now)
      page = case try Table.tx_get(t1, Db.pages_table(), id).map_error(Db.map_table_error)
        Some(p) if p.archived_at == None: p
        Some(_) | None: return Error(Missing(entity: "page", id: id))
      end
      try Policy.require_collection_access(auth, "comment", page.collection_id)
      t2 = try Table.put(t1, Db.comments_table(), cmt.id, cmt).map_error(Db.map_table_error)
      Ok((t2, (cmt, page.collection_id)))
    end
  )
  cmt_ev = Json.Object({
    "comment_id": Json.String(created.id),
    "page_id": Json.String(id),
    "collection_id": Json.String(col_id),
    "actor": Json.String(auth.principal.handle)
  })
  Ok(
    json_ok(201, created.to_json)
      .with_sse_publish_json("page:#{id}", "comment.created", cmt_ev)
      .with_sse_publish_json("collection:#{col_id}", "comment.created", cmt_ev)
  )
end

## `POST /api/attachments/presign` — Issues an AWS SigV4 presigned `PUT` URL and records pending metadata in MoDB.
fn presign_attachment(
  req: Api.Request,
  auth: AuthContext,
  input: PresignAttachmentInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if input.size_bytes < 1 or input.size_bytes > 52428800
    return Error(BadInput(reason: "size_bytes must be between 1 and 52428800 (50 MiB)"))
  end
  ct = input.content_type.trim
  if ct.empty?
    return Error(BadInput(reason: "content_type must not be empty"))
  end

  upload_action = if Policy.action_permitted?(auth, "upload_attachment")
    "upload_attachment"
  else
    "write_direct"
  end
  s3_cfg = try Auth.s3_config(env)
  now = clock.now
  att_id = "att_#{Id.ulid(rng, clock)}"
  clean_name = sanitize_filename_segment(input.filename)
  raw_key = "workspaces/#{Db.default_workspace_id}/pages/#{input.page_id}/#{att_id}/#{clean_name}"
  s3_key = try S3.sanitize_object_key(raw_key).map_error(map_s3_error)
  put_opts = S3.PresignPutOptions(
    expires_seconds: 900,
    content_type: Some(ct),
    content_length: Some(input.size_bytes),
    sha256_hex: input.sha256_hex
  )
  signed = try S3.presign_put(s3_cfg, s3_key, put_opts, now).map_error(map_s3_error)

  att = Attachment(
    id: att_id,
    workspace_id: Db.default_workspace_id,
    page_id: input.page_id,
    uploaded_by: auth.principal.id,
    filename: input.filename.trim,
    content_type: ct,
    size_bytes: input.size_bytes,
    sha256_hex: input.sha256_hex or "",
    s3_bucket: s3_cfg.bucket,
    s3_key: s3_key,
    status: "pending",
    created_at: now
  )
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "attachment.presign",
    reason: "presign upload '#{att.filename}' on page '#{input.page_id}'",
    at: now
  )
  audit_payload = Json.Object({
    "attachment_id": Json.String(att.id),
    "page_id": Json.String(input.page_id),
    "size_bytes": Json.int(input.size_bytes)
  })

  saved = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "presigned attachment #{att.id} (#{clean_name})",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, upload_action, now)
      page = case try Table.tx_get(t1, Db.pages_table(), input.page_id).map_error(
        Db.map_table_error
      )
        Some(p) if p.archived_at == None: p
        Some(_) | None: return Error(Missing(entity: "page", id: input.page_id))
      end
      try Policy.require_collection_access(auth, upload_action, page.collection_id)
      t2 = try Table.put(t1, Db.attachments_table(), att.id, att).map_error(Db.map_table_error)
      Ok((t2, att))
    end
  )

  hdrs_json = Json.Array(
    signed.required_headers.map(fn(h)
      Json.Object({"name": Json.String(h.0), "value": Json.String(h.1)})
    end)
  )
  Ok(
    json_ok(
      201,
      Json.Object({
        "attachment": saved.to_json,
        "upload_url": Json.String(signed.url),
        "method": Json.String(signed.method),
        "required_headers": hdrs_json,
        "expires_at": signed.expires_at.to_json
      })
    )
  )
end

## `POST /api/attachments/:id/commit` — Marks an uploaded S3 attachment `"ready"`.
fn commit_attachment(req: Api.Request, id: Text, auth: AuthContext, files: Files, clock: Clock) : Result(
  Attachment,
  AppError
)
  try Auth.require_session_csrf(req, auth)
  upload_action = if Policy.action_permitted?(auth, "upload_attachment")
    "upload_attachment"
  else
    "write_direct"
  end
  now = clock.now
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "attachment.commit",
    reason: "commit uploaded attachment '#{id}'",
    at: now
  )
  audit_payload = Json.Object({"attachment_id": Json.String(id)})

  Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "committed attachment #{id}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, upload_action, now)
      old_att = case try Table.tx_get(t1, Db.attachments_table(), id).map_error(Db.map_table_error)
        Some(a): a
        None: return Error(Missing(entity: "attachment", id: id))
      end
      page = case try Table.tx_get(t1, Db.pages_table(), old_att.page_id).map_error(
        Db.map_table_error
      )
        Some(p) if p.archived_at == None: p
        Some(_) | None: return Error(Missing(entity: "page", id: old_att.page_id))
      end
      try Policy.require_collection_access(auth, upload_action, page.collection_id)
      ready = Attachment(
        id: old_att.id,
        workspace_id: old_att.workspace_id,
        page_id: old_att.page_id,
        uploaded_by: old_att.uploaded_by,
        filename: old_att.filename,
        content_type: old_att.content_type,
        size_bytes: old_att.size_bytes,
        sha256_hex: old_att.sha256_hex,
        s3_bucket: old_att.s3_bucket,
        s3_key: old_att.s3_key,
        status: "ready",
        created_at: old_att.created_at
      )
      t2 = try Table.put(t1, Db.attachments_table(), ready.id, ready).map_error(Db.map_table_error)
      Ok((t2, ready))
    end
  )
end

## `GET /api/attachments/:id/download` — Enforces collection grant & redirects (`302`) to short-lived S3 presigned GET URL.
fn download_attachment(id: Text, auth: AuthContext, rf: ReadFiles, clock: Clock, env: Env) : Result(
  Api.Response,
  AppError
)
  if not rf.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "attachment", id: id))
  end
  att = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      a = case try Table.get(store, Db.attachments_table(), id).map_error(Db.map_table_error)
        Some(x): x
        None: return Error(Missing(entity: "attachment", id: id))
      end
      page = case try Table.get(store, Db.pages_table(), a.page_id).map_error(Db.map_table_error)
        Some(p) if p.archived_at == None: p
        Some(_) | None: return Error(Missing(entity: "page", id: a.page_id))
      end
      try Policy.require_collection_access(auth, "read", page.collection_id)
      Ok(a)
    end
  )
  if att.status != "ready"
    return Error(Conflict(reason: "attachment '#{id}' is not ready for download"))
  end

  s3_cfg = try Auth.s3_config(env)
  get_opts = S3.PresignGetOptions(
    expires_seconds: 300,
    response_content_disposition: Some("inline"),
    response_content_type: Some(att.content_type)
  )
  signed = try S3.presign_get(s3_cfg, att.s3_key, get_opts, clock.now).map_error(map_s3_error)
  Ok(Api.redirect(signed.url).with_header("Cache-Control", "private, no-store"))
end

## `POST /api/admin/agents` — Mints an `Agent` principal, scoped `Modb.Grants.Grant`, and one-time Bearer token.
fn mint_agent_token(
  req: Api.Request,
  auth: AuthContext,
  input: MintAgentTokenInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  role_ok = auth.principal.role == Owner or auth.principal.role == Admin
  if not role_ok or not Policy.action_permitted?(auth, "manage_grants")
    return Error(
      Forbidden(reason: "only workspace owners/admins with manage_grants can mint agents")
    )
  end
  if input.allowed_actions.empty?
    return Error(BadInput(reason: "allowed_actions must not be empty"))
  end
  if input.ttl_days < 1 or input.ttl_days > 365
    return Error(BadInput(reason: "ttl_days must be between 1 and 365"))
  end
  if input.max_calls <= 0
    return Error(BadInput(reason: "max_calls must be positive"))
  end
  clean_label = input.label.trim
  if clean_label.empty?
    return Error(BadInput(reason: "label must not be empty"))
  end

  now = clock.now
  agent_id = "agt_#{Id.ulid(rng, clock)}"
  grant_id = "gr_#{Id.ulid(rng, clock)}"
  token_id = "tok_#{Id.ulid(rng, clock)}"
  (raw_token, token_prefix, token_hash) = Policy.mint_agent_token_raw(rng)
  expires_at = now + input.ttl_days.days

  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "admin.mint_agent",
    reason: "mint agent '#{input.handle}' with grant '#{grant_id}'",
    at: now
  )
  audit_payload = Json.Object({
    "agent_id": Json.String(agent_id),
    "grant_id": Json.String(grant_id),
    "token_id": Json.String(token_id)
  })
  (principal, grant, tok) = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "minted agent #{input.handle} (#{grant_id})",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      (t1, p, g, t) = try Db.tx_mint_agent(
        tx,
        auth.principal.id,
        input.handle,
        input.display_name.trim,
        input.model_id,
        clean_label,
        input.allowed_actions,
        input.allowed_collections,
        input.max_calls,
        expires_at,
        agent_id,
        grant_id,
        token_id,
        token_prefix,
        token_hash,
        now
      )
      Ok((t1, (p, g, t)))
    end
  )

  Ok(
    json_ok(
      201,
      Json.Object({
        "raw_token": Json.String(raw_token),
        "principal": principal.to_json,
        "grant": grant.to_json,
        "token_id": Json.String(tok.id),
        "token_prefix": Json.String(tok.prefix)
      })
    )
  )
end

## `POST /api/admin/grants/:id/revoke` — Cascades revocation across a `Modb.Grants` subtree.
fn revoke_grant(req: Api.Request, id: Text, auth: AuthContext, files: Files, clock: Clock) : Result(
  Api.Response,
  AppError
)
  try Auth.require_session_csrf(req, auth)
  role_ok = auth.principal.role == Owner or auth.principal.role == Admin
  if not role_ok or not Policy.action_permitted?(auth, "manage_grants")
    return Error(
      Forbidden(reason: "only workspace owners/admins with manage_grants can revoke grants")
    )
  end

  now = clock.now
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "admin.revoke_grant",
    reason: "revoke grant '#{id}'",
    at: now
  )
  audit_payload = Json.Object({"grant_id": Json.String(id)})

  revoked = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "revoked grant #{id}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx) Grants.tx_revoke(tx, id).map_error(Db.map_grants_error) end
  )
  Ok(
    json_ok(
      200,
      Json.Object({"revoked_grant_id": Json.String(revoked.id), "revoked": Json.Boolean(true)})
    )
  )
end

## `GET /api/audit` — Returns the hash-chained `Modb.Ledger` audit tail (`ReadFiles`-only).
fn audit_index(req: Api.Request, auth: AuthContext, rf: ReadFiles) : Result(Api.Response, AppError)
  if not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Ok(json_ok(200, Json.Object({"audit_feed": Json.Array([])})))
  end
  limit = parse_limit(req.query_param("limit"), 50, 200)
  feed = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      entries = try Ledger.audit_tail_store(Ledger.store(db), limit).map_error(Db.map_ledger_error)
      Ok(entries.map(audit_entry_to_feed))
    end
  )
  Ok(json_ok(200, Json.Object({"audit_feed": feed.to_json})))
end

## `GET /proposals` — Renders the Change Proposals Review Inbox (`ReadFiles`-only).
fn proposals_page(req: Api.Request, auth: Option(AuthContext), rf: ReadFiles, env: Env) : Result(
  Api.Response,
  AppError
)
  a = case auth
    Some(x): x
    None: return guest_redirect_or_401(req)
  end
  if not Policy.action_permitted?(a, "read")
    return Error(Forbidden(reason: "grant '#{a.grant_id}' does not permit 'read'"))
  end

  (cols, dbs, proposals) = if not rf.exists?(Db.ledger_db_path)
    ([], [], [])
  else
    try Ledger.read_locked(
      rf,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        store = Ledger.store(db)
        c_list = try permitted_collections(store, a)
        d_list = try permitted_databases(store, a)
        p_rows = try Table.scan(store, Db.proposals_table(), None, None, 200).map_error(
          Db.map_table_error
        )
        var out = []
        for (_id, p) in p_rows
          if Policy.collection_permitted?(a, p.collection_id)
            out = out.append(p)
          end
        end
        Ok((c_list, d_list, out))
      end
    )
  end

  if Auth.wants_json?(req)
    return Ok(
      json_ok(
        200,
        Json.Object({
          "collections": cols.to_json,
          "databases": dbs.to_json,
          "proposals": proposals.to_json
        })
      )
    )
  end

  render_inertia_page(
    req,
    a,
    rf,
    env,
    "Workspace/Proposals",
    {"collections": cols.to_json, "databases": dbs.to_json, "proposals": proposals.to_json}
  )
end

## `GET /admin` — Renders the Agents/Grants, Gardening, Importer, Selective Undo & Webhooks Console (`ReadFiles`-only).
fn admin_page(req: Api.Request, auth: Option(AuthContext), rf: ReadFiles, env: Env) : Result(
  Api.Response,
  AppError
)
  a = case auth
    Some(x): x
    None: return guest_redirect_or_401(req)
  end
  if not Policy.action_permitted?(a, "read")
    return Error(Forbidden(reason: "grant '#{a.grant_id}' does not permit 'read'"))
  end

  (cols, dbs, feed, hooks) = if not rf.exists?(Db.ledger_db_path)
    ([], [], [], [])
  else
    try Ledger.read_locked(
      rf,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        store = Ledger.store(db)
        c_list = try permitted_collections(store, a)
        d_list = try permitted_databases(store, a)
        entries = try Ledger.audit_tail_store(store, 30).map_error(Db.map_ledger_error)
        audit_items = entries.map(audit_entry_to_feed)
        can_webhooks = (a.principal.role == Owner or a.principal.role == Admin) and
          Policy.action_permitted?(a, "manage_grants")
        hook_items = if can_webhooks
          w_rows = try Table.scan(store, Db.webhooks_table(), None, None, 100).map_error(
            Db.map_table_error
          )
          w_rows.map(fn(pair)
            w = pair.1
            Json.Object({
              "id": Json.String(w.id),
              "workspace_id": Json.String(w.workspace_id),
              "collection_id": w.collection_id.to_json,
              "url": Json.String(w.url),
              "events": w.events.to_json,
              "enabled": Json.Boolean(w.enabled),
              "created_at": w.created_at.to_json
            })
          end)
        else
          []
        end
        Ok((c_list, d_list, audit_items, hook_items))
      end
    )
  end

  if Auth.wants_json?(req)
    return Ok(
      json_ok(
        200,
        Json.Object({
          "collections": cols.to_json,
          "databases": dbs.to_json,
          "audit_feed": feed.to_json,
          "webhooks": Json.Array(hooks)
        })
      )
    )
  end

  render_inertia_page(
    req,
    a,
    rf,
    env,
    "Workspace/Admin",
    {
      "collections": cols.to_json,
      "databases": dbs.to_json,
      "audit_feed": feed.to_json,
      "webhooks": Json.Array(hooks)
    }
  )
end

fn extract_indexed_page_id(payload_json: Text) : Result(Text, Text)
  parsed = try Json.decode_strict[Json](payload_json.bytes).map_error(fn(e) e.to_text end)
  case parsed.text_at("page_id")
    Some(pid) if not pid.trim.empty?: Ok(pid.trim)
    Some(_) | None: Error("vellum.page.indexed payload missing non-empty 'page_id'")
  end
end

## Periodic `mo serve` job handler draining neural embedding + signed webhook jobs and pruning expired MoDB sessions.
fn drain_jobs(_payload: Json, files: Files, clock: Clock, env: Env, net: Network) : Result(
  Unit,
  AppError
)
  if files.read_only.exists?(Db.sessions_db_path)
    _pruned = try Sessions.prune_expired(files, Db.sessions_db_path, clock).map_error(
      Db.map_table_error
    )
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Ok(Unit)
  end
  _recovered = try Jobs.requeue_stale_running(files, Db.ledger_db_path, clock, 120).map_error(
    Db.map_table_error
  )
  var keep_going = true
  var processed = 0
  while keep_going and processed < 25
    claimed = try Jobs.claim_next(
      files,
      Db.ledger_db_path,
      clock,
      ["vellum.page.indexed", "vellum.webhook.deliver"]
    ).map_error(Db.map_table_error)
    case claimed
      None: keep_going = false
      Some(job):
        if job.job_name == "vellum.webhook.deliver"
          case Json.decode_strict[WebhookJobPayload](job.payload_json.bytes)
            Error(e): try Jobs.fail_or_retry(
              files,
              Db.ledger_db_path,
              clock,
              job.id,
              job.attempts,
              e.to_text
            ).map_error(Db.map_table_error)
            Ok(wp):
              res = Webhooks.deliver(
                wp.url,
                wp.secret,
                wp.delivery_id,
                wp.event,
                wp.body_json.to_text.bytes,
                clock.now,
                "X-Vellum-Signature-256",
                net
              )
              case res
                Ok(Webhooks.Delivered(status: _)) | Ok(
                  Webhooks.PermanentFailure(status: _, reason: _)
                ): try Jobs.complete(files, Db.ledger_db_path, clock, job.id, job.attempts)
                  .map_error(Db.map_table_error)
                Ok(Webhooks.RetryableFailure(status: _, reason: r)): try Jobs.fail_or_retry(
                  files,
                  Db.ledger_db_path,
                  clock,
                  job.id,
                  job.attempts,
                  r
                ).map_error(Db.map_table_error)
                Error(we): try Jobs.fail_or_retry(
                  files,
                  Db.ledger_db_path,
                  clock,
                  job.id,
                  job.attempts,
                  we.to_text
                ).map_error(Db.map_table_error)
              end
          end
        else
          case Ai.embed_config(env)
            None: try Jobs.complete(files, Db.ledger_db_path, clock, job.id, job.attempts)
              .map_error(Db.map_table_error)
            Some(ecfg):
              case extract_indexed_page_id(job.payload_json)
                Error(bad): try Jobs.fail_or_retry(
                  files,
                  Db.ledger_db_path,
                  clock,
                  job.id,
                  job.attempts,
                  bad
                ).map_error(Db.map_table_error)
                Ok(pid):
                  embed_input_res = Ledger.read_locked(
                    files.read_only,
                    Db.ledger_db_path,
                    Db.vellum_schema(),
                    Db.map_ledger_error,
                    fn(db)
                      store = Ledger.store(db)
                      case try Table.get(store, Db.pages_table(), pid).map_error(
                        Db.map_table_error
                      )
                        Some(pg) if pg.archived_at == None:
                          blks = try Db.load_page_blocks(store, pg.id)
                          extra = case pg.kind
                            Document: None
                            DatabaseRow(database_id: db_id, row_id: row_id):
                              case try Table.get(store, Db.databases_table(), db_id).map_error(
                                Db.map_table_error
                              )
                                Some(def):
                                  case try Table.get(store, Db.db_rows_table(), row_id).map_error(
                                    Db.map_table_error
                                  )
                                    Some(row): Some(DatabaseModel.row_plain_text(def, row))
                                    None: None
                                  end
                                None: None
                              end
                          end
                          txt = Db.page_embedding_text(pg, blks, extra)
                          if txt.trim.empty?
                            Ok(None)
                          else
                            Ok(Some(txt))
                          end
                        Some(_) | None: Ok(None)
                      end
                    end
                  )
                  case embed_input_res
                    Error(le): try Jobs.fail_or_retry(
                      files,
                      Db.ledger_db_path,
                      clock,
                      job.id,
                      job.attempts,
                      le.to_text
                    ).map_error(Db.map_table_error)
                    Ok(None):
                      _rm = try Ledger.transact_locked(
                        files,
                        Db.ledger_db_path,
                        Db.vellum_schema(),
                        Ledger.WriteMeta(
                          principal: "system:jobs",
                          action: "page.embed_removed",
                          reason: "clear neural vector for missing or archived page #{pid}",
                          at: clock.now
                        ),
                        "cleared neural embedding for #{pid}",
                        Json.Object({"page_id": Json.String(pid)}),
                        Db.map_ledger_error,
                        fn(tx)
                          t1 = try Db.tx_remove_page_vectors(tx, pid)
                          Ok((t1, Unit))
                        end
                      )
                      try Jobs.complete(files, Db.ledger_db_path, clock, job.id, job.attempts)
                        .map_error(Db.map_table_error)
                    Ok(Some(embed_txt)):
                      # Call OpenAI-compatible `/v1/embeddings` strictly OUTSIDE any MoDB ledger lock.
                      case Ai.fetch_embedding(ecfg, embed_txt, net)
                        Error(ee): try Jobs.fail_or_retry(
                          files,
                          Db.ledger_db_path,
                          clock,
                          job.id,
                          job.attempts,
                          ee.to_text
                        ).map_error(Db.map_table_error)
                        Ok(vec_vals):
                          _stored = try Ledger.transact_locked(
                            files,
                            Db.ledger_db_path,
                            Db.vellum_schema(),
                            Ledger.WriteMeta(
                              principal: "system:jobs",
                              action: "page.embed_indexed",
                              reason: "index neural embedding for page #{pid}",
                              at: clock.now
                            ),
                            "indexed neural vector (#{ecfg.dimensions}d) for #{pid}",
                            Json.Object({
                              "page_id": Json.String(pid),
                              "dimensions": Json.int(ecfg.dimensions),
                              "model": Json.String(ecfg.model)
                            }),
                            Db.map_ledger_error,
                            fn(tx)
                              case try Table.tx_get(tx, Db.pages_table(), pid).map_error(
                                Db.map_table_error
                              )
                                Some(live_pg) if live_pg.archived_at == None:
                                  t1 = try Db.tx_put_page_neural_vector(
                                    tx,
                                    live_pg.id,
                                    live_pg.collection_id,
                                    ecfg.dimensions,
                                    vec_vals
                                  )
                                  Ok((t1, Unit))
                                Some(_) | None:
                                  t1 = try Db.tx_remove_page_vectors(tx, pid)
                                  Ok((t1, Unit))
                              end
                            end
                          )
                          try Jobs.complete(files, Db.ledger_db_path, clock, job.id, job.attempts)
                            .map_error(Db.map_table_error)
                      end
                  end
              end
          end
        end
        processed += 1
    end
  end
  Ok(Unit)
end
