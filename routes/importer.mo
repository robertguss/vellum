## Notion Markdown & CSV batch importer persisting interlinked `Page`s (`PageLink`),
## `Block`s, inferred `DatabaseDef`s + `DbRow`s + `vlm_db_cells` indexes, and `Modb.Fts` in one ledger tx.
module Routes.Importer
expose ImportNotionInput(..), import_notion
use Api
use Arvo.Id
use Arvo.Modb.Jobs
use Db
use Domain.Blocks
use Domain.DatabaseModel{DatabaseDef, DbRow, DbViewDef, DbViewKind}
use Domain.NotionImport{NotionCsvImport, NotionPageImport}
use Domain.Policy
use Domain.TaintBridge
use Domain.Types{AppError, AuthContext, AuthorKind, Page, PageKind, PrincipalKind, Provenance}
use Json
use Modb.Grants
use Modb.Ledger
use Routes.Auth
use VaultOps

## JSON payload for `POST /api/import/notion`.
struct ImportNotionInput
  collection_id: Text
  pages: List(NotionPageImport)
  databases: List(NotionCsvImport)
end

fn json_ok(status: Int, body: Json) : Api.Response
  Api.encoded_json_response(status, body).with_header(
    "Content-Type",
    "application/json; charset=utf-8"
  )
end

fn make_provenance(auth: AuthContext, now: Time) : Provenance
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
    reason: Some("notion export import"),
    citations: [],
    updated_at: now
  )
end

## `POST /api/import/notion` — Imports Notion Markdown documents (rewriting links + stripping UUID suffixes)
## and Notion CSV tables (inferring Vellum relational databases) atomically in one `Modb.Ledger` transaction.
fn import_notion(
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  col_id = try VaultOps.req_text(rj, "collection_id")
  var imp_pages = []
  for pj in rj.list_at("pages") or []
    imp_pages = imp_pages.append(
      NotionPageImport(
        path: try VaultOps.req_text(pj, "path"),
        title: pj.text_at("title"),
        markdown: try VaultOps.req_text(pj, "markdown")
      )
    )
  end
  var imp_dbs = []
  for dj in rj.list_at("databases") or []
    imp_dbs = imp_dbs.append(
      NotionCsvImport(
        title: try VaultOps.req_text(dj, "title"),
        csv_text: try VaultOps.req_text(dj, "csv_text")
      )
    )
  end
  input = ImportNotionInput(collection_id: col_id, pages: imp_pages, databases: imp_dbs)
  try Policy.require_collection_access(auth, "write_direct", input.collection_id)
  if not input.databases.empty?
    try Policy.require_collection_access(auth, "manage_schema", input.collection_id)
  end
  if input.pages.empty? and input.databases.empty?
    return Error(BadInput(reason: "import payload must include at least one page or database"))
  end

  now = clock.now
  prov = make_provenance(auth, now)
  (canonical_dbs, skipped_dup_dbs) = NotionImport.select_canonical_csvs(input.databases)

  var prepared_dbs = []
  var db_title_to_id = {}
  var total_rows = 0
  for db_imp in canonical_dbs
    db_title = NotionImport.strip_notion_id_suffix(db_imp.title)
    if db_title.empty?
      return Error(BadInput(reason: "imported CSV database title must not be empty"))
    end
    csv_table = try NotionImport.parse_csv(db_imp.csv_text).map_error(fn(m) BadInput(reason: m) end)
    inferred = try NotionImport.infer_database_from_csv(csv_table).map_error(fn(m)
      BadInput(reason: m)
    end)

    db_id = "db_#{Id.ulid(rng, clock)}"
    host_page_id = "pg_#{Id.ulid(rng, clock)}"
    view_id = "vw_#{Id.ulid(rng, clock)}"
    db_title_to_id = db_title_to_id.set(db_title, db_id)
    db_title_to_id = db_title_to_id.set(db_imp.title, db_id)
    case NotionImport.extract_notion_id(db_imp.title)
      Some(nid): db_title_to_id = db_title_to_id.set(nid, db_id)
      None: Unit
    end
    def = DatabaseDef(
      id: db_id,
      collection_id: input.collection_id,
      page_id: host_page_id,
      title: db_title,
      description: "Imported from Notion CSV",
      properties: inferred.properties,
      version: 1
    )
    case DatabaseModel.validate_database_def(def)
      Some(msg): return Error(BadInput(reason: msg))
      None: Unit
    end
    host_page = Page(
      id: host_page_id,
      collection_id: input.collection_id,
      parent_page_id: None,
      title: db_title,
      icon: Some("database"),
      cover_attachment_id: None,
      kind: Document,
      sort_order: host_page_id,
      database_id: Some(db_id),
      freshness_ttl_days: None,
      verified_at: Some(now),
      verified_by: Some(auth.principal.id),
      created_by: auth.principal.id,
      created_at: now,
      updated_at: now,
      archived_at: None,
      version: 1
    )
    default_view = DbViewDef(
      id: view_id,
      database_id: db_id,
      name: "Table",
      kind: TableView(visible_prop_ids: def.properties.map(fn(p) p.id end), column_widths: {}),
      filters: [],
      filter_match_all: true,
      sorts: [],
      sort_order: "a"
    )

    var rows_and_pages = []
    for cells in inferred.row_cells
      row_id = "row_#{Id.ulid(rng, clock)}"
      row_pg_id = "pg_#{Id.ulid(rng, clock)}"
      r = DbRow(
        id: row_id,
        database_id: db_id,
        page_id: row_pg_id,
        cells: cells,
        created_by: auth.principal.id,
        created_at: now,
        updated_at: now,
        archived_at: None,
        version: 1
      )
      rp = Page(
        id: row_pg_id,
        collection_id: input.collection_id,
        parent_page_id: Some(host_page_id),
        title: DatabaseModel.extract_row_title(def, cells),
        icon: None,
        cover_attachment_id: None,
        kind: DatabaseRow(database_id: db_id, row_id: row_id),
        sort_order: row_id,
        database_id: Some(db_id),
        freshness_ttl_days: None,
        verified_at: None,
        verified_by: None,
        created_by: auth.principal.id,
        created_at: now,
        updated_at: now,
        archived_at: None,
        version: 1
      )
      rows_and_pages = rows_and_pages.append((r, rp))
      total_rows += 1
    end
    prepared_dbs = prepared_dbs.append((def, host_page, default_view, rows_and_pages))
  end

  parent_idx_map = NotionImport.infer_page_parent_indices(input.pages)
  var id_by_idx = {}
  var title_to_id = {}
  var pre_pages = []
  for (idx, imp) in input.pages.enumerate
    title = NotionImport.notion_page_title(imp)
    pid = "pg_#{Id.ulid(rng, clock)}"
    bpref = "blk_#{Id.ulid(rng, clock)}"
    id_by_idx = id_by_idx.set(idx, pid)
    title_to_id = title_to_id.set(title, pid)
    title_to_id = title_to_id.set(NotionImport.strip_notion_id_suffix(imp.path), pid)
    case NotionImport.extract_notion_id(imp.path)
      Some(nid): title_to_id = title_to_id.set(nid, pid)
      None: Unit
    end
    pre_pages = pre_pages.append((idx, pid, bpref, title, imp.markdown))
  end

  var prepared_pages = []
  var nested_page_count = 0
  for (idx, pid, bpref, title, raw_md) in pre_pages
    parent_pid = case parent_idx_map.get(idx)
      Some(pidx): id_by_idx.get(pidx)
      None: None
    end
    if parent_pid != None
      nested_page_count += 1
    end
    rewritten = NotionImport.rewrite_notion_links_and_embeds(raw_md, title_to_id, db_title_to_id)
    blks = Blocks.parse_markdown_blocks(pid, rewritten, prov, bpref)
    pg = Page(
      id: pid,
      collection_id: input.collection_id,
      parent_page_id: parent_pid,
      title: title,
      icon: None,
      cover_attachment_id: None,
      kind: Document,
      sort_order: pid,
      database_id: None,
      freshness_ttl_days: None,
      verified_at: Some(now),
      verified_by: Some(auth.principal.id),
      created_by: auth.principal.id,
      created_at: now,
      updated_at: now,
      archived_at: None,
      version: 1
    )
    prepared_pages = prepared_pages.append((pg, blks))
  end

  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "import.notion",
    reason: "import #{prepared_pages.size} pages and #{prepared_dbs.size} databases from Notion",
    at: now
  )
  audit_payload = Json.Object({
    "collection_id": Json.String(input.collection_id),
    "page_count": Json.int(prepared_pages.size),
    "database_count": Json.int(prepared_dbs.size),
    "row_count": Json.int(total_rows)
  })

  var idx_jobs = []
  for (pg, _blks) in prepared_pages
    idx_jobs = idx_jobs.append(
      Jobs.prepare(rng, clock, "vellum.page.indexed", Json.Object({"page_id": Json.String(pg.id)}))
    )
  end
  for (_def, _host_pg, _view_def, rows_and_pages) in prepared_dbs
    for (_r, rp) in rows_and_pages
      idx_jobs = idx_jobs.append(
        Jobs.prepare(
          rng,
          clock,
          "vellum.page.indexed",
          Json.Object({"page_id": Json.String(rp.id)})
        )
      )
    end
  end

  _committed = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "imported Notion batch into #{input.collection_id}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      var cur = if auth.principal.kind == Agent
        (t1, _g) = try Grants.tx_authorize(tx, auth.grant_id, "write_direct", now).map_error(
          Db.map_grants_error
        )
        t1
      else
        tx
      end
      col = case try Db.tx_get_collection(cur, input.collection_id)
        Some(c) if c.archived_at == None: c
        Some(_) | None: return Error(Missing(entity: "collection", id: input.collection_id))
      end
      if not Policy.can_write_page_direct?(auth, col)
        return Error(
          Forbidden(reason: "collection '#{col.slug}' prohibits direct import by this principal")
        )
      end

      for (pg, blks) in prepared_pages
        cur = try Db.tx_save_page_and_blocks(cur, pg, blks)
        cur = try TaintBridge.tx_mark_provenance(
          cur,
          "vlm_pages",
          pg.id,
          "import:notion:#{auth.principal.handle}",
          "untrusted",
          now
        )
        for blk in blks
          cur = try TaintBridge.tx_mark_provenance(
            cur,
            "vlm_blocks",
            blk.id,
            "import:notion:#{auth.principal.handle}",
            "untrusted",
            now
          )
        end
      end
      for (def, host_pg, view_def, rows_and_pages) in prepared_dbs
        cur = try Db.tx_put_page_row(cur, host_pg)
        cur = try TaintBridge.tx_mark_provenance(
          cur,
          "vlm_pages",
          host_pg.id,
          "import:notion-csv:#{auth.principal.handle}",
          "untrusted",
          now
        )
        cur = try Db.tx_put_database(cur, def)
        cur = try Db.tx_put_db_view(cur, view_def)
        for (r, rp) in rows_and_pages
          (next_cur, assigned_cells) = try Db.tx_assign_unique_ids(cur, def, r.cells)
          r_final = DbRow(
            id: r.id,
            database_id: r.database_id,
            page_id: r.page_id,
            cells: assigned_cells,
            created_by: r.created_by,
            created_at: r.created_at,
            updated_at: r.updated_at,
            archived_at: r.archived_at,
            version: r.version
          )
          cur = try Db.tx_put_db_row(next_cur, def, r_final, rp, [])
          cur = try Db.tx_put_db_row_editor(cur, r_final.id, auth.principal.id)
          cur = try TaintBridge.tx_mark_provenance(
            cur,
            "vlm_db_rows",
            r.id,
            "import:notion-csv:#{auth.principal.handle}",
            "untrusted",
            now
          )
          cur = try TaintBridge.tx_mark_provenance(
            cur,
            "vlm_pages",
            rp.id,
            "import:notion-csv:#{auth.principal.handle}",
            "untrusted",
            now
          )
        end
      end
      for job_rec in idx_jobs
        (next_tx, _jid) = try Jobs.tx_put(cur, job_rec).map_error(Db.map_table_error)
        cur = next_tx
      end
      Ok((cur, Unit))
    end
  )

  Ok(
    json_ok(
      201,
      Json.Object({
        "imported_pages": Json.Array(prepared_pages.map(fn(x) x.0.to_json end)),
        "imported_databases": Json.Array(prepared_dbs.map(fn(x) x.0.to_json end)),
        "page_count": Json.int(prepared_pages.size),
        "nested_page_count": Json.int(nested_page_count),
        "database_count": Json.int(prepared_dbs.size),
        "skipped_duplicate_databases": Json.int(skipped_dup_dbs),
        "row_count": Json.int(total_rows),
        "trust_tier": Json.String("untrusted")
      })
    )
  )
end
