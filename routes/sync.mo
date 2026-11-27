## Conflict-safe two-way local sync endpoints (`GET /api/sync/snapshot`, `POST /api/sync/push`):
## renders/parses YAML frontmatter + `<!-- blk:... -->` anchored Markdown, detects `expected_version`
## conflicts, and routes divergent edits cleanly into `Modb.World` Change Proposals.
module Routes.Sync
expose SyncPushInput(..),
sync_snapshot,
sync_push
use Api
use Arvo.Id
use Arvo.Modb.Jobs
use Db
use Domain.Blocks
use Domain.Blueprints{BlueprintDef, PageBlueprintMeta}
use Domain.Collab{ProposalMeta, WorldPatchArgs}
use Domain.Policy
use Domain.Sync
use Domain.Types{
  AppError,
  AuthContext,
  AuthorKind,
  Block,
  Collection,
  Page,
  PageKind,
  PrincipalKind,
  Provenance
}
use Json
use Modb{Store, WriteTx}
use Modb.Grants
use Modb.Ledger
use Modb.Table
use Modb.World
use Routes.Auth
use Routes.Workspace{validate_meta_relations_tx}

## JSON payload for `POST /api/sync/push`.
struct SyncPushInput
  page_id: Option(Text)
  collection_id: Option(Text)
  rel_path: Text
  markdown_document: Text
  expected_version: Option(Int)
  reason: Option(Text)
end

fn json_ok(status: Int, body: Json) : Api.Response
  Api.encoded_json_response(status, body).with_header(
    "Content-Type",
    "application/json; charset=utf-8"
  )
end

fn non_empty_opt(raw: Option(Text)) : Option(Text)
  case raw
    Some(s) if not s.trim.empty?: Some(s.trim)
    Some(_) | None: None
  end
end

fn make_provenance(auth: AuthContext, reason: Text, now: Time) : Provenance
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
    reason: Some(reason),
    citations: [],
    updated_at: now
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

fn tx_resolve_frontmatter_meta(
  tx: WriteTx,
  auth: AuthContext,
  fm: Blueprints.ParsedFrontmatter,
  page_id: Text,
  now: Time
) : Result((Option(BlueprintDef), Option(PageBlueprintMeta)), AppError)
  case fm.blueprint_slug
    None: Ok((None, None))
    Some(slug):
      hits = try Table.tx_lookup(tx, Db.blueprints_table(), Db.blueprints_by_slug(), slug).map_error(
        Db.map_table_error
      )
      bp = case hits.first
        Some(pair): pair.1
        None: return Error(Missing(entity: "blueprint", id: slug))
      end
      vals = try Blueprints.parse_yaml_meta_values(bp, fm.meta_raw).map_error(fn(e)
        BadInput(reason: e)
      end)
      try validate_meta_relations_tx(tx, auth, bp, vals)
      Ok((Some(bp), Some(PageBlueprintMeta(page_id: page_id, blueprint_id: bp.id, values: vals, updated_at: now))))
  end
end

fn load_page_bp_meta(store: Store, page_id: Text) : Result(
  (Option(BlueprintDef), Option(PageBlueprintMeta)),
  AppError
)
  pm_opt = try Table.get(store, Db.page_meta_table(), page_id).map_error(Db.map_table_error)
  bp_opt = case pm_opt
    Some(pm): try Table.get(store, Db.blueprints_table(), pm.blueprint_id).map_error(
      Db.map_table_error
    )
    None: None
  end
  Ok((bp_opt, pm_opt))
end

fn resolve_snapshot_collections(
  store: Store,
  auth: AuthContext,
  filter_param: Option(Text)
) : Result(List(Collection), AppError)
  rows = try Table.scan(store, Db.collections_table(), None, None, 200).map_error(Db.map_table_error)
  active = rows.filter(fn(p) p.1.archived_at == None end).map(fn(p) p.1 end).sort_by(fn(c)
    c.slug
  end)
  tokens = case filter_param
    Some(raw) if not raw.trim.empty?:
      raw.split(",").map(fn(s) s.trim end).filter(fn(s) not s.empty? end)
    Some(_) | None: []
  end
  if tokens.empty?
    return Ok(active.filter(fn(c) Policy.collection_permitted?(auth, c.id) end))
  end

  var seen = Set.empty
  var out = []
  for tok in tokens
    found = case active.find(fn(c) c.id == tok or c.slug == tok end)
      Some(c): c
      None: return Error(Missing(entity: "collection", id: tok))
    end
    try Policy.require_collection_access(auth, "read", found.id)
    if not seen.has?(found.id)
      seen = seen.add(found.id)
      out = out.append(found)
    end
  end
  Ok(out)
end

## `GET /api/sync/snapshot` — Grant-filtered read-only snapshot of mirrored YAML + anchored Markdown docs.
fn sync_snapshot(req: Api.Request, auth: AuthContext, rf: ReadFiles) : Result(
  Api.Response,
  AppError
)
  if auth.principal.suspended
    return Error(Forbidden(reason: "principal '#{auth.principal.handle}' is suspended"))
  end
  if not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  col_filter = req.query_param("collections")
  if not rf.exists?(Db.ledger_db_path)
    return Ok(
      json_ok(
        200,
        Json.Object({"txid": Json.int(0), "collections": Json.Array([]), "pages": Json.Array([])})
      )
    )
  end

  (txid_val, cols, page_entries) = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      selected = try resolve_snapshot_collections(store, auth, col_filter)
      var items = []
      for col in selected
        p_rows = try Table.lookup(store, Db.pages_table(), Db.pages_by_collection(), col.id).map_error(
          Db.map_table_error
        )
        doc_pages = p_rows.filter(fn(p)
          p.1.archived_at == None and p.1.kind == Document
        end).map(fn(p) p.1 end).sort_by(fn(p) p.id end)
        for pg in doc_pages
          blks = try Db.load_page_blocks(store, pg.id)
          (bp_opt, pm_opt) = try load_page_bp_meta(store, pg.id)
          anchored_md = Blocks.to_anchored_markdown(blks)
          doc = Blueprints.to_yaml_frontmatter(pg, bp_opt, pm_opt, anchored_md)
          rel_path = Sync.page_rel_path(col.slug, pg.title, pg.id)
          sha = Sync.sha256_text(doc)
          items = items.append(
            Json.Object({
              "page_id": Json.String(pg.id),
              "collection_id": Json.String(col.id),
              "collection_slug": Json.String(col.slug),
              "title": Json.String(pg.title),
              "version": Json.int(pg.version),
              "rel_path": Json.String(rel_path),
              "content_sha256": Json.String(sha),
              "markdown_document": Json.String(doc),
              "updated_at": pg.updated_at.to_json
            })
          )
        end
      end
      Ok((Modb.txid(store), selected, items))
    end
  )

  Ok(
    json_ok(
      200,
      Json.Object({
        "txid": Json.int(txid_val),
        "collections": cols.to_json,
        "pages": Json.Array(page_entries)
      })
    )
  )
end

fn infer_collection_token(
  input: SyncPushInput,
  fm: Blueprints.ParsedFrontmatter
) : Option(Text)
  case non_empty_opt(input.collection_id)
    Some(c): return Some(c)
    None: Unit
  end
  case fm.collection_id
    Some(c): return Some(c)
    None: Unit
  end
  parts = input.rel_path.trim.split("/").filter(fn(s) not s.empty? end)
  if parts.size >= 2
    parts.first
  else
    None
  end
end

fn sync_push_create(
  auth: AuthContext,
  input: SyncPushInput,
  fm: Blueprints.ParsedFrontmatter,
  reason_str: Text,
  prov: Provenance,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  now: Time
) : Result(Api.Response, AppError)
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "collection", id: "unknown"))
  end
  col_tok = try infer_collection_token(input, fm).or_fail(
    BadInput(reason: "new page push requires collection_id or <collection_slug>/<file>.md path")
  )
  col = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      rows = try Table.scan(Ledger.store(db), Db.collections_table(), None, None, 200).map_error(
        Db.map_table_error
      )
      found = rows.filter(fn(p) p.1.archived_at == None end).map(fn(p) p.1 end).find(fn(c)
        c.id == col_tok or c.slug == col_tok
      end)
      case found
        Some(c): Ok(c)
        None: Error(Missing(entity: "collection", id: col_tok))
      end
    end
  )
  try Policy.require_collection_access(auth, "write_direct", col.id)
  if not Policy.can_write_page_direct?(auth, col)
    return Error(
      Forbidden(
        reason: "collection '#{col.slug}' write policy requires change proposals for this principal"
      )
    )
  end

  new_pid = "pg_#{Id.ulid(rng, clock)}"
  id_prefix = Id.ulid(rng, clock)
  title = fm.title or Sync.derive_title_from_markdown(input.rel_path, fm.body_markdown)
  blocks = Blocks.reconcile_blocks_from_markdown(new_pid, [], fm.body_markdown, prov, id_prefix)
  page = Page(
    id: new_pid,
    collection_id: col.id,
    parent_page_id: None,
    title: title,
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "z",
    database_id: None,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: auth.principal.id,
    created_at: now,
    updated_at: now,
    archived_at: None,
    version: 1
  )
  idx_job = Jobs.prepare(
    rng,
    clock,
    "vellum.page.indexed",
    Json.Object({"page_id": Json.String(page.id)})
  )
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "sync.push_create",
    reason: reason_str,
    at: now
  )
  (saved_page, bp_opt, pm_opt) = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "vellum sync created page '#{page.title}'",
    Json.Object({"page_id": Json.String(page.id), "rel_path": Json.String(input.rel_path)}),
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "write_direct", now)
      (b_opt, m_opt) = try tx_resolve_frontmatter_meta(t1, auth, fm, page.id, now)
      t2 = case m_opt
        Some(pm): try Table.put(t1, Db.page_meta_table(), page.id, pm).map_error(Db.map_table_error)
        None: t1
      end
      t3 = try Db.tx_save_page_and_blocks(t2, page, blocks)
      (t4, _jid) = try Jobs.tx_put(t3, idx_job).map_error(Db.map_table_error)
      Ok((t4, (page, b_opt, m_opt)))
    end
  )

  doc = Blueprints.to_yaml_frontmatter(
    saved_page,
    bp_opt,
    pm_opt,
    Blocks.to_anchored_markdown(blocks)
  )
  rel = Sync.page_rel_path(col.slug, saved_page.title, saved_page.id)
  ev = Json.Object({
    "page_id": Json.String(saved_page.id),
    "collection_id": Json.String(col.id),
    "version": Json.int(saved_page.version),
    "actor": Json.String(auth.principal.handle)
  })
  Ok(
    json_ok(
      201,
      Json.Object({
        "outcome": Json.String("created"),
        "page": saved_page.to_json,
        "rel_path": Json.String(rel),
        "markdown_document": Json.String(doc),
        "content_sha256": Json.String(Sync.sha256_text(doc)),
        "proposal": Json.Null
      })
    ).with_sse_publish_json("collection:#{col.id}", "page.created", ev)
  )
end

fn sync_push_stage_proposal(
  auth: AuthContext,
  old_page: Page,
  col: Collection,
  old_blocks: List(Block),
  bp_opt: Option(BlueprintDef),
  pm_opt: Option(PageBlueprintMeta),
  fm: Blueprints.ParsedFrontmatter,
  expected_ver: Int,
  conflict_reason: Text,
  reason_str: Text,
  prov: Provenance,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  now: Time
) : Result(Api.Response, AppError)
  try Policy.require_collection_access(auth, "propose", col.id)
  id_prefix = Id.ulid(rng, clock)
  incoming = Blocks.reconcile_blocks_from_markdown(
    old_page.id,
    old_blocks,
    fm.body_markdown,
    prov,
    id_prefix
  )
  (ops, new_ids) = Blocks.diff_blocks_to_ops(old_blocks, incoming)

  live_doc = Blueprints.to_yaml_frontmatter(
    old_page,
    bp_opt,
    pm_opt,
    Blocks.to_anchored_markdown(old_blocks)
  )
  live_sha = Sync.sha256_text(live_doc)
  live_rel = Sync.page_rel_path(col.slug, old_page.title, old_page.id)

  if ops.empty?
    return Ok(
      json_ok(
        200,
        Json.Object({
          "outcome": Json.String("unchanged"),
          "page": old_page.to_json,
          "rel_path": Json.String(live_rel),
          "markdown_document": Json.String(live_doc),
          "content_sha256": Json.String(live_sha),
          "proposal": Json.Null
        })
      )
    )
  end

  prop_id = "prop_#{Id.ulid(rng, clock)}"
  world_id = "w_#{Id.ulid(rng, clock)}"
  _wrec = try World.open_world_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    world_id,
    auth.grant_id,
    now,
    now + 7.days
  ).map_error(Db.map_world_error)

  prop_reason = "#{reason_str} (#{conflict_reason}: expected v#{expected_ver}, live v#{old_page.version})"
  prop_prov = Provenance(
    author_id: auth.principal.id,
    author_kind: prov.author_kind,
    grant_id: prov.grant_id,
    proposal_id: Some(prop_id),
    reason: Some(prop_reason),
    citations: [],
    updated_at: now
  )
  wargs = WorldPatchArgs(
    page_id: old_page.id,
    ops: ops,
    new_ids: new_ids,
    provenance: prop_prov,
    expected_versions: {},
    updated_at: now
  )
  _step = try World.world_call_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.world_catalog(),
    world_id,
    "propose",
    wargs.to_json,
    prop_reason,
    now
  ).map_error(Db.map_world_error)

  pm = ProposalMeta(
    id: prop_id,
    world_id: world_id,
    collection_id: col.id,
    target_page_id: old_page.id,
    target_database_id: None,
    branch_kind: "proposal",
    title: "Sync: #{old_page.title}",
    reason: prop_reason,
    author_id: auth.principal.id,
    author_handle: auth.principal.handle,
    grant_id: auth.grant_id,
    status: "open",
    created_at: now,
    updated_at: now,
    decided_by: None,
    decided_at: None
  )
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "sync.conflict_proposal",
    reason: prop_reason,
    at: now
  )
  saved_pm = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "staged sync proposal #{pm.id} on #{old_page.id}",
    Json.Object({
      "proposal_id": Json.String(pm.id),
      "page_id": Json.String(old_page.id),
      "conflict_reason": Json.String(conflict_reason)
    }),
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "propose", now)
      t2 = try Table.put(t1, Db.proposals_table(), pm.id, pm).map_error(Db.map_table_error)
      Ok((t2, pm))
    end
  )

  prop_ev = Json.Object({
    "proposal_id": Json.String(saved_pm.id),
    "page_id": Json.String(old_page.id),
    "collection_id": Json.String(col.id),
    "title": Json.String(saved_pm.title),
    "actor": Json.String(auth.principal.handle)
  })
  Ok(
    json_ok(
      202,
      Json.Object({
        "outcome": Json.String("proposal_opened"),
        "conflict_reason": Json.String(conflict_reason),
        "expected_version": Json.int(expected_ver),
        "live_version": Json.int(old_page.version),
        "ops_staged": Json.int(ops.size),
        "page": old_page.to_json,
        "proposal": saved_pm.to_json,
        "review_url": Json.String("/proposals"),
        "live_markdown_document": Json.String(live_doc),
        "live_content_sha256": Json.String(live_sha)
      })
    ).with_sse_publish_json("page:#{old_page.id}", "proposal.opened", prop_ev)
      .with_sse_publish_json("collection:#{col.id}", "proposal.opened", prop_ev)
  )
end

fn sync_push_direct_update(
  auth: AuthContext,
  old_page: Page,
  col: Collection,
  old_blocks: List(Block),
  cur_bp_opt: Option(BlueprintDef),
  cur_pm_opt: Option(PageBlueprintMeta),
  fm: Blueprints.ParsedFrontmatter,
  expected_ver: Int,
  reason_str: Text,
  prov: Provenance,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  now: Time
) : Result(Api.Response, AppError)
  id_prefix = Id.ulid(rng, clock)
  idx_job = Jobs.prepare(
    rng,
    clock,
    "vellum.page.indexed",
    Json.Object({"page_id": Json.String(old_page.id)})
  )
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "sync.push_update",
    reason: reason_str,
    at: now
  )
  tx_res = Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "vellum sync updated #{old_page.id}",
    Json.Object({
      "page_id": Json.String(old_page.id),
      "expected_version": Json.int(expected_ver)
    }),
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "write_direct", now)
      live = case try Table.tx_get(t1, Db.pages_table(), old_page.id).map_error(Db.map_table_error)
        Some(p) if p.archived_at == None: p
        Some(_) | None: return Error(Missing(entity: "page", id: old_page.id))
      end
      if live.version != expected_ver
        return Error(Conflict(reason: "version_mismatch"))
      end

      (next_bp_opt, next_pm_opt) = case fm.blueprint_slug
        Some(_): try tx_resolve_frontmatter_meta(t1, auth, fm, live.id, now)
        None: (cur_bp_opt, cur_pm_opt)
      end
      t2 = case next_pm_opt
        Some(pm) if fm.blueprint_slug != None: try Table.put(t1, Db.page_meta_table(), live.id, pm)
          .map_error(Db.map_table_error)
        Some(_) | None: t1
      end

      live_rows = try Table.tx_lookup(t2, Db.blocks_table(), Db.blocks_by_page(), live.id).map_error(
        Db.map_table_error
      )
      live_blocks = Blocks.sort_blocks(live_rows.map(fn(p) p.1 end))
      reconciled = Blocks.reconcile_blocks_from_markdown(
        live.id,
        live_blocks,
        fm.body_markdown,
        prov,
        id_prefix
      )
      next_title = fm.title or live.title
      bumped_page = Page(
        id: live.id,
        collection_id: live.collection_id,
        parent_page_id: live.parent_page_id,
        title: next_title,
        icon: live.icon,
        cover_attachment_id: live.cover_attachment_id,
        kind: live.kind,
        sort_order: live.sort_order,
        database_id: live.database_id,
        freshness_ttl_days: live.freshness_ttl_days,
        verified_at: live.verified_at,
        verified_by: live.verified_by,
        created_by: live.created_by,
        created_at: live.created_at,
        updated_at: now,
        archived_at: live.archived_at,
        version: live.version + 1
      )
      t3 = try Db.tx_save_page_and_blocks(t2, bumped_page, reconciled)
      (t4, _jid) = try Jobs.tx_put(t3, idx_job).map_error(Db.map_table_error)
      Ok((t4, (bumped_page, reconciled, next_bp_opt, next_pm_opt)))
    end
  )

  case tx_res
    Error(Conflict(reason: _)):
      # Concurrent edit landed before lock acquisition: route safely to Change Proposal!
      sync_push_stage_proposal(
        auth,
        old_page,
        col,
        old_blocks,
        cur_bp_opt,
        cur_pm_opt,
        fm,
        expected_ver,
        "version_mismatch",
        reason_str,
        prov,
        files,
        rng,
        clock,
        now
      )
    Error(e): Error(e)
    Ok((saved_page, saved_blocks, bp_opt, pm_opt)):
      doc = Blueprints.to_yaml_frontmatter(
        saved_page,
        bp_opt,
        pm_opt,
        Blocks.to_anchored_markdown(saved_blocks)
      )
      rel = Sync.page_rel_path(col.slug, saved_page.title, saved_page.id)
      ev = Json.Object({
        "page_id": Json.String(saved_page.id),
        "collection_id": Json.String(col.id),
        "version": Json.int(saved_page.version),
        "actor": Json.String(auth.principal.handle),
        "reason": Json.String(reason_str)
      })
      Ok(
        json_ok(
          200,
          Json.Object({
            "outcome": Json.String("applied"),
            "page": saved_page.to_json,
            "rel_path": Json.String(rel),
            "markdown_document": Json.String(doc),
            "content_sha256": Json.String(Sync.sha256_text(doc)),
            "proposal": Json.Null
          })
        ).with_sse_publish_json("page:#{saved_page.id}", "page.blocks_updated", ev)
          .with_sse_publish_json("collection:#{col.id}", "page.blocks_updated", ev)
      )
  end
end

## `POST /api/sync/push` — Conflict-safe local Markdown mirror push: applies clean updates,
## creates new pages, or stages `version_mismatch` / policy-gated edits into a `Modb.World` Change Proposal.
fn sync_push(
  req: Api.Request,
  auth: AuthContext,
  input: SyncPushInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if auth.principal.suspended
    return Error(Forbidden(reason: "principal '#{auth.principal.handle}' is suspended"))
  end
  fm = try Blueprints.parse_yaml_frontmatter(input.markdown_document).map_error(fn(e)
    BadInput(reason: e)
  end)
  now = clock.now
  reason_str = (non_empty_opt(input.reason) or "vellum sync").trim
  prov = make_provenance(auth, reason_str, now)

  target_pid_opt = case non_empty_opt(input.page_id)
    Some(p): Some(p)
    None: fm.page_id
  end
  pid = case target_pid_opt
    None: return sync_push_create(auth, input, fm, reason_str, prov, files, rng, clock, now)
    Some(p): p
  end

  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "page", id: pid))
  end

  (old_page, col, old_blocks, bp_opt, pm_opt) = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      pg = case try Table.get(store, Db.pages_table(), pid).map_error(Db.map_table_error)
        Some(p) if p.archived_at == None: p
        Some(_) | None: return Error(Missing(entity: "page", id: pid))
      end
      try Policy.require_collection_access(auth, "read", pg.collection_id)
      if pg.kind != Document
        return Error(BadInput(reason: "vellum sync only supports Document pages"))
      end
      c = case try Table.get(store, Db.collections_table(), pg.collection_id).map_error(
        Db.map_table_error
      )
        Some(col_rec): col_rec
        None: return Error(Missing(entity: "collection", id: pg.collection_id))
      end
      blks = try Db.load_page_blocks(store, pg.id)
      (bp_o, pm_o) = try load_page_bp_meta(store, pg.id)
      Ok((pg, c, blks, bp_o, pm_o))
    end
  )

  expected_ver = case input.expected_version
    Some(v): v
    None: fm.version or 0
  end
  version_conflict? = old_page.version != expected_ver
  can_direct? = Policy.can_write_page_direct?(auth, col) and
    Policy.action_permitted?(auth, "write_direct")

  if (not version_conflict?) and can_direct?
    sync_push_direct_update(
      auth,
      old_page,
      col,
      old_blocks,
      bp_opt,
      pm_opt,
      fm,
      expected_ver,
      reason_str,
      prov,
      files,
      rng,
      clock,
      now
    )
  else
    conflict_reason = if version_conflict?
      "version_mismatch"
    else
      "policy_requires_proposal"
    end
    sync_push_stage_proposal(
      auth,
      old_page,
      col,
      old_blocks,
      bp_opt,
      pm_opt,
      fm,
      expected_ver,
      conflict_reason,
      reason_str,
      prov,
      files,
      rng,
      clock,
      now
    )
  end
end
