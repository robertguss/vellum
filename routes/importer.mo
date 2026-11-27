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
use Modb.Table
use Routes.Auth

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
  input: ImportNotionInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  try Policy.require_collection_access(auth, "write_direct", input.collection_id)
  if not input.databases.empty?
    try Policy.require_collection_access(auth, "manage_schema", input.collection_id)
  end
  if input.pages.empty? and input.databases.empty?
    return Error(BadInput(reason: "import payload must include at least one page or database"))
  end

  now = clock.now
  prov = make_provenance(auth, now)

  var title_to_id = {}
  var pre_pages = []
  for imp in input.pages
    title = NotionImport.notion_page_title(imp)
    pid = "pg_#{Id.ulid(rng, clock)}"
    bpref = "blk_#{Id.ulid(rng, clock)}"
    title_to_id = title_to_id.set(title, pid)
    title_to_id = title_to_id.set(NotionImport.strip_notion_id_suffix(imp.path), pid)
    pre_pages = pre_pages.append((pid, bpref, title, imp.markdown))
  end

  var prepared_pages = []
  for (pid, bpref, title, raw_md) in pre_pages
    rewritten = NotionImport.rewrite_notion_links(raw_md, title_to_id)
    blks = Blocks.parse_markdown_blocks(pid, rewritten, prov, bpref)
    pg = Page(
      id: pid,
      collection_id: input.collection_id,
      parent_page_id: None,
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

  var prepared_dbs = []
  var total_rows = 0
  for db_imp in input.databases
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
      col = case try Table.tx_get(cur, Db.collections_table(), input.collection_id).map_error(
        Db.map_table_error
      )
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
        cur = try Table.put(cur, Db.pages_table(), host_pg.id, host_pg).map_error(
          Db.map_table_error
        )
        cur = try TaintBridge.tx_mark_provenance(
          cur,
          "vlm_pages",
          host_pg.id,
          "import:notion-csv:#{auth.principal.handle}",
          "untrusted",
          now
        )
        cur = try Table.put(cur, Db.databases_table(), def.id, def).map_error(Db.map_table_error)
        cur = try Table.put(cur, Db.db_views_table(), view_def.id, view_def).map_error(
          Db.map_table_error
        )
        for (r, rp) in rows_and_pages
          cur = try Db.tx_put_db_row(cur, def, r, rp, [])
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
        "database_count": Json.int(prepared_dbs.size),
        "row_count": Json.int(total_rows),
        "trust_tier": Json.String("untrusted")
      })
    )
  )
end
