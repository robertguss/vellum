## Relational Databases & Multi-View Engine HTTP handlers (Table, Kanban Board, Calendar,
## Relation/Rollup enrichment, optimistic concurrency, and fail-closed MoDB Grant + Ledger enforcement).
module Routes.Databases
expose CreateDatabaseInput(..),
UpdateDatabaseSchemaInput(..),
CreateViewInput(..),
QueryDatabaseInput(..),
CreateRowInput(..),
UpdateRowInput(..),
list_databases,
create_database,
show_database,
update_database_schema,
create_view,
query_database,
create_row,
update_row,
delete_row
use Api
use Arvo.Flash
use Arvo.Id
use Arvo.Inertia
use Date
use Db
use Domain.Blocks
use Domain.DatabaseModel{
  CellValue,
  DatabaseDef,
  DbFilterRule,
  DbRow,
  DbSortRule,
  DbViewDef,
  DbViewKind,
  PropertyDef,
  PropertyKind,
  ViewQueryResult
}
use Domain.Policy
use Domain.Types{AppError, AuthContext, AuthorKind, Page, PageKind, PrincipalKind, Provenance}
use Json
use Modb{Store, WriteTx}
use Modb.Grants
use Modb.Ledger
use Modb.Table
use Routes.Auth

## JSON payload for `POST /api/databases`.
struct CreateDatabaseInput
  collection_id: Text
  parent_page_id: Option(Text)
  title: Text
  description: Option(Text)
  properties: List(PropertyDef)
end

## JSON payload for `PATCH /api/databases/:id`.
struct UpdateDatabaseSchemaInput
  title: Option(Text)
  description: Option(Text)
  properties: Option(List(PropertyDef))
  expected_version: Int
end

## JSON payload for `POST /api/databases/:id/views`.
struct CreateViewInput
  name: Text
  kind: DbViewKind
  filters: List(DbFilterRule)
  filter_match_all: Bool
  sorts: List(DbSortRule)
end

## JSON payload for `POST /api/databases/:id/query`.
struct QueryDatabaseInput
  view_id: Option(Text)
  filters: List(DbFilterRule)
  filter_match_all: Option(Bool)
  sorts: List(DbSortRule)
  from_date: Option(Text)
  to_date: Option(Text)
end

## JSON payload for `POST /api/databases/:id/rows`.
struct CreateRowInput
  cells: Map(Text, CellValue)
  markdown: Option(Text)
  reason: Option(Text)
end

## JSON payload for `PATCH /api/databases/:id/rows/:row_id`.
struct UpdateRowInput
  cells: Map(Text, CellValue)
  expected_version: Int
  reason: Option(Text)
end

fn json_ok(status: Int, body: Json) : Api.Response
  Api.encoded_json_response(status, body).with_header(
    "Content-Type",
    "application/json; charset=utf-8"
  )
end

fn db_read_action(auth: AuthContext) : Text
  if Policy.action_permitted?(auth, "query_db")
    "query_db"
  else
    "read"
  end
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

fn find_prop(def: DatabaseDef, prop_id: Text) : Option(PropertyDef)
  for p in def.properties
    return Some(p) if p.id == prop_id
  end
  None
end

fn validate_view_def(def: DatabaseDef, v: DbViewDef) : Option(Text)
  return Some("view name must not be empty") if v.name.trim.empty?
  case v.kind
    TableView(visible_prop_ids: vpids, column_widths: _):
      for pid in vpids
        if find_prop(def, pid) == None
          return Some("TableView references unknown property '#{pid}'")
        end
      end
    BoardView(group_by_prop_id: gb_id, card_prop_ids: cpids, hide_empty_groups: _):
      gb_prop = case find_prop(def, gb_id)
        Some(p): p
        None: return Some("BoardView group_by_prop_id '#{gb_id}' not found")
      end
      case gb_prop.kind
        Select(options: _) | Checkbox: Unit
        Title | RichText | Number(format: _) | DateProp(include_time: _) | MultiSelect(options: _) | Person | Url | Relation(
          target_db_id: _,
          inverse_prop_id: _
        ) | Rollup(relation_prop_id: _, target_prop_id: _, agg: _): return Some(
          "BoardView group_by_prop_id '#{gb_id}' must be Select or Checkbox"
        )
      end
      for pid in cpids
        if find_prop(def, pid) == None
          return Some("BoardView references unknown card property '#{pid}'")
        end
      end
    CalendarView(date_prop_id: dp_id, card_prop_ids: cpids):
      dp_prop = case find_prop(def, dp_id)
        Some(p): p
        None: return Some("CalendarView date_prop_id '#{dp_id}' not found")
      end
      case dp_prop.kind
        DateProp(include_time: _): Unit
        Title | RichText | Number(format: _) | Select(options: _) | MultiSelect(options: _) | Checkbox | Person | Url | Relation(
          target_db_id: _,
          inverse_prop_id: _
        ) | Rollup(relation_prop_id: _, target_prop_id: _, agg: _): return Some(
          "CalendarView date_prop_id '#{dp_id}' must be a DateProp"
        )
      end
      for pid in cpids
        if find_prop(def, pid) == None
          return Some("CalendarView references unknown card property '#{pid}'")
        end
      end
  end
  for f in v.filters
    if find_prop(def, f.prop_id) == None
      return Some("filter references unknown property '#{f.prop_id}'")
    end
  end
  for s in v.sorts
    if find_prop(def, s.prop_id) == None
      return Some("sort references unknown property '#{s.prop_id}'")
    end
  end
  None
end

fn load_active_db_rows(store: Store, db_id: Text) : Result(List(DbRow), AppError)
  pairs = try Table.lookup(store, Db.db_rows_table(), Db.db_rows_by_database(), db_id).map_error(
    Db.map_table_error
  )
  var out = []
  for (_rid, r) in pairs
    if r.archived_at == None
      out = out.append(r)
    end
  end
  Ok(out)
end

## `GET /api/databases` — Lists all accessible relational databases (`ReadFiles`-only).
fn list_databases(auth: AuthContext, rf: ReadFiles) : Result(Api.Response, AppError)
  act = db_read_action(auth)
  if not Policy.action_permitted?(auth, act)
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit '#{act}'"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Ok(json_ok(200, Json.Object({"databases": Json.Array([])})))
  end

  dbs = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      rows = try Table.scan(Ledger.store(db), Db.databases_table(), None, None, 200).map_error(
        Db.map_table_error
      )
      var visible = []
      for (_did, def) in rows
        if Policy.collection_permitted?(auth, def.collection_id)
          visible = visible.append(def)
        end
      end
      Ok(visible)
    end
  )
  Ok(json_ok(200, Json.Object({"databases": dbs.to_json})))
end

## `POST /api/databases` — Creates a `DatabaseDef`, host `Page`, and default Table `DbViewDef`.
fn create_database(
  req: Api.Request,
  auth: AuthContext,
  input: CreateDatabaseInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  try Policy.require_collection_access(auth, "manage_schema", input.collection_id)

  now = clock.now
  db_id = "db_#{Id.ulid(rng, clock)}"
  host_page_id = "pg_#{Id.ulid(rng, clock)}"
  view_id = "vw_#{Id.ulid(rng, clock)}"

  def = DatabaseDef(
    id: db_id,
    collection_id: input.collection_id,
    page_id: host_page_id,
    title: input.title.trim,
    description: (input.description or "").trim,
    properties: input.properties,
    version: 1
  )
  case DatabaseModel.validate_database_def(def)
    Some(msg): return Error(BadInput(reason: msg))
    None: Unit
  end

  host_page = Page(
    id: host_page_id,
    collection_id: input.collection_id,
    parent_page_id: input.parent_page_id,
    title: def.title,
    icon: Some("database"),
    cover_attachment_id: None,
    kind: Document,
    sort_order: host_page_id,
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

  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "database.create",
    reason: "create database '#{def.title}'",
    at: now
  )
  audit_payload = Json.Object({
    "database_id": Json.String(def.id),
    "collection_id": Json.String(def.collection_id)
  })

  (saved_def, saved_page, saved_view) = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "created database #{def.id} (#{def.title})",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "manage_schema", now)
      case try Table.tx_get(t1, Db.collections_table(), input.collection_id).map_error(
        Db.map_table_error
      )
        Some(c) if c.archived_at == None: Unit
        Some(_) | None: return Error(Missing(entity: "collection", id: input.collection_id))
      end
      t2 = try Table.put(t1, Db.pages_table(), host_page.id, host_page).map_error(
        Db.map_table_error
      )
      t3 = try Table.put(t2, Db.databases_table(), def.id, def).map_error(Db.map_table_error)
      t4 = try Table.put(t3, Db.db_views_table(), default_view.id, default_view).map_error(
        Db.map_table_error
      )
      Ok((t4, (def, host_page, default_view)))
    end
  )

  Ok(
    json_ok(
      201,
      Json.Object({
        "database": saved_def.to_json,
        "page": saved_page.to_json,
        "default_view": saved_view.to_json
      })
    )
  )
end

## `GET /d/:id` and `GET /api/databases/:id` — Returns database schema, saved views, and enriched rows (`ReadFiles`-only).
fn show_database(req: Api.Request, id: Text, auth: Option(AuthContext), rf: ReadFiles, env: Env) : Result(
  Api.Response,
  AppError
)
  a = case auth
    Some(x): x
    None:
      if Auth.wants_json?(req)
        return Error(Unauthenticated)
      else
        return Ok(Inertia.redirect("/login"))
      end
  end
  if not rf.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "database", id: id))
  end

  read_act = db_read_action(a)
  (cols, dbs, def, views, enriched) = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      def = case try Table.get(store, Db.databases_table(), id).map_error(Db.map_table_error)
        Some(d): d
        None: return Error(Missing(entity: "database", id: id))
      end
      try Policy.require_collection_access(a, read_act, def.collection_id)
      col_rows = try Table.scan(store, Db.collections_table(), None, None, 200).map_error(
        Db.map_table_error
      )
      var cols = []
      for (_cid, c) in col_rows
        if c.archived_at == None and Policy.collection_permitted?(a, c.id)
          cols = cols.append(c)
        end
      end
      db_rows = try Table.scan(store, Db.databases_table(), None, None, 200).map_error(
        Db.map_table_error
      )
      var dbs = []
      for (_did, d) in db_rows
        if Policy.collection_permitted?(a, d.collection_id)
          dbs = dbs.append(d)
        end
      end
      v_pairs = try Table.lookup(store, Db.db_views_table(), Db.db_views_by_database(), def.id)
        .map_error(Db.map_table_error)
      active_rows = try load_active_db_rows(store, def.id)
      enr = try Db.enrich_rows_with_rollups(store, def, active_rows)
      Ok((cols, dbs, def, v_pairs.map(fn(x) x.1 end), DatabaseModel.sort_enriched_rows(enr, [])))
    end
  )

  if Auth.wants_json?(req)
    return Ok(
      json_ok(
        200,
        Json.Object({"database": def.to_json, "views": views.to_json, "rows": enriched.to_json})
      )
    )
  end

  icfg = try Auth.load_inertia_config(rf, env)
  if Inertia.check_version(req, icfg) is Some(ver_res)
    return Ok(ver_res)
  end
  key = try Auth.app_secret_key(env)
  (shared, had_flash?) = Auth.shared_props(req, Some(a), key)
  res = Inertia.render(
    req,
    icfg,
    "Workspace/Database",
    {
      "collections": cols.to_json,
      "databases": dbs.to_json,
      "database": def.to_json,
      "views": views.to_json,
      "rows": enriched.to_json
    },
    shared
  )
  Ok(Flash.clear_if_present(res, had_flash?, Auth.secure_cookies?(env)))
end

## `PATCH /api/databases/:id` — Updates database title, description, or properties with optimistic version check.
fn update_database_schema(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  input: UpdateDatabaseSchemaInput,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  now = clock.now
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "database.update_schema",
    reason: "update schema on database '#{id}'",
    at: now
  )
  audit_payload = Json.Object({"database_id": Json.String(id)})

  updated = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "updated database #{id} schema",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "manage_schema", now)
      old_def = case try Table.tx_get(t1, Db.databases_table(), id).map_error(Db.map_table_error)
        Some(d): d
        None: return Error(Missing(entity: "database", id: id))
      end
      try Policy.require_collection_access(auth, "manage_schema", old_def.collection_id)
      if old_def.version != input.expected_version
        return Error(
          Conflict(
            reason: "database '#{id}' version mismatch: expected #{input.expected_version}, found #{old_def
              .version}"
          )
        )
      end

      next_title = case input.title
        Some(t): t.trim
        None: old_def.title
      end
      next_desc = case input.description
        Some(d): d.trim
        None: old_def.description
      end
      next_props = case input.properties
        Some(ps): ps
        None: old_def.properties
      end
      next_def = DatabaseDef(
        id: old_def.id,
        collection_id: old_def.collection_id,
        page_id: old_def.page_id,
        title: next_title,
        description: next_desc,
        properties: next_props,
        version: old_def.version + 1
      )
      case DatabaseModel.validate_database_def(next_def)
        Some(msg): return Error(BadInput(reason: msg))
        None: Unit
      end
      t2 = try Table.put(t1, Db.databases_table(), next_def.id, next_def).map_error(
        Db.map_table_error
      )
      Ok((t2, next_def))
    end
  )
  Ok(json_ok(200, updated.to_json))
end

## `POST /api/databases/:id/views` — Creates a saved Table, Board, or Calendar view.
fn create_view(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  input: CreateViewInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  view_act = if Policy.action_permitted?(auth, "manage_schema")
    "manage_schema"
  else
    "write_db"
  end
  now = clock.now
  view_id = "vw_#{Id.ulid(rng, clock)}"
  v = DbViewDef(
    id: view_id,
    database_id: id,
    name: input.name.trim,
    kind: input.kind,
    filters: input.filters,
    filter_match_all: input.filter_match_all,
    sorts: input.sorts,
    sort_order: view_id
  )

  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "database.create_view",
    reason: "create view '#{v.name}' on database '#{id}'",
    at: now
  )
  audit_payload = Json.Object({"database_id": Json.String(id), "view_id": Json.String(view_id)})

  saved = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "created view #{v.name} on #{id}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, view_act, now)
      def = case try Table.tx_get(t1, Db.databases_table(), id).map_error(Db.map_table_error)
        Some(d): d
        None: return Error(Missing(entity: "database", id: id))
      end
      try Policy.require_collection_access(auth, view_act, def.collection_id)
      case validate_view_def(def, v)
        Some(msg): return Error(BadInput(reason: msg))
        None: Unit
      end
      t2 = try Table.put(t1, Db.db_views_table(), v.id, v).map_error(Db.map_table_error)
      Ok((t2, v))
    end
  )
  Ok(json_ok(201, saved.to_json))
end

## `POST /api/databases/:id/query` — Executes Table/Board/Calendar filtering, sorting, and Rollups (`ReadFiles`-only).
fn query_database(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  input: QueryDatabaseInput,
  rf: ReadFiles
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  from_d = case input.from_date
    Some(s) if not s.trim.empty?:
      case Date.parse_iso(s.trim)
        Some(d): Some(d)
        None: return Error(BadInput(reason: "invalid ISO from_date '#{s}'"))
      end
    Some(_) | None: None
  end
  to_d = case input.to_date
    Some(s) if not s.trim.empty?:
      case Date.parse_iso(s.trim)
        Some(d): Some(d)
        None: return Error(BadInput(reason: "invalid ISO to_date '#{s}'"))
      end
    Some(_) | None: None
  end

  if not rf.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "database", id: id))
  end
  read_act = db_read_action(auth)

  res = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      def = case try Table.get(store, Db.databases_table(), id).map_error(Db.map_table_error)
        Some(d): d
        None: return Error(Missing(entity: "database", id: id))
      end
      try Policy.require_collection_access(auth, read_act, def.collection_id)

      view_opt = case input.view_id
        None: None
        Some(vid):
          found = case try Table.get(store, Db.db_views_table(), vid).map_error(Db.map_table_error)
            Some(v) if v.database_id == def.id: v
            Some(_) | None: return Error(Missing(entity: "db_view", id: vid))
          end
          Some(found)
      end

      active_rows = try load_active_db_rows(store, def.id)
      enriched = try Db.enrich_rows_with_rollups(store, def, active_rows)

      filters = if not input.filters.empty?
        input.filters
      else
        case view_opt
          Some(v): v.filters
          None: []
        end
      end
      match_all? = case input.filter_match_all
        Some(b): b
        None:
          case view_opt
            Some(v): v.filter_match_all
            None: true
          end
      end
      sorts = if not input.sorts.empty?
        input.sorts
      else
        case view_opt
          Some(v): v.sorts
          None: []
        end
      end

      filtered = enriched.filter(fn(er) DatabaseModel.matches_filters?(er, filters, match_all?) end)
      sorted = DatabaseModel.sort_enriched_rows(filtered, sorts)

      (final_rows, board_groups) = case view_opt
        Some(v):
          case v.kind
            TableView(visible_prop_ids: _, column_widths: _): (sorted, None)
            BoardView(group_by_prop_id: gb_id, card_prop_ids: _, hide_empty_groups: hide_empty):
              groups = DatabaseModel.group_rows_for_board(def, sorted, gb_id, hide_empty)
              (sorted, Some(groups))
            CalendarView(date_prop_id: dp_id, card_prop_ids: _):
              ranged = DatabaseModel.filter_calendar_range(sorted, dp_id, from_d, to_d)
              (ranged, None)
          end
        None: (sorted, None)
      end

      Ok(
        ViewQueryResult(
          view: view_opt,
          rows: final_rows,
          board_groups: board_groups,
          total_count: final_rows.size
        )
      )
    end
  )
  Ok(json_ok(200, res.to_json))
end

## `POST /api/databases/:id/rows` — Atomically creates a `DbRow`, backing `Page(DatabaseRow)`, `vlm_db_cells` indexes, and `Modb.Fts`.
fn create_row(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  input: CreateRowInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  now = clock.now
  row_id = "row_#{Id.ulid(rng, clock)}"
  page_id = "pg_#{Id.ulid(rng, clock)}"
  block_prefix = "blk_#{Id.ulid(rng, clock)}"
  prov = make_provenance(auth, input.reason, now)
  blocks = case input.markdown
    Some(md) if not md.trim.empty?: Blocks.parse_markdown_blocks(page_id, md, prov, block_prefix)
    Some(_) | None: []
  end

  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "db_row.create",
    reason: input.reason or "create row in database '#{id}'",
    at: now
  )
  audit_payload = Json.Object({
    "database_id": Json.String(id),
    "row_id": Json.String(row_id),
    "page_id": Json.String(page_id)
  })

  (saved_row, saved_page) = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "created row #{row_id} in #{id}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "write_db", now)
      def = case try Table.tx_get(t1, Db.databases_table(), id).map_error(Db.map_table_error)
        Some(d): d
        None: return Error(Missing(entity: "database", id: id))
      end
      try Policy.require_collection_access(auth, "write_db", def.collection_id)

      row = DbRow(
        id: row_id,
        database_id: def.id,
        page_id: page_id,
        cells: input.cells,
        created_by: auth.principal.id,
        created_at: now,
        updated_at: now,
        archived_at: None,
        version: 1
      )
      case DatabaseModel.validate_row_cells(def, row)
        Some(msg): return Error(BadInput(reason: msg))
        None: Unit
      end

      row_title = DatabaseModel.extract_row_title(def, input.cells)
      page = Page(
        id: page_id,
        collection_id: def.collection_id,
        parent_page_id: Some(def.page_id),
        title: row_title,
        icon: None,
        cover_attachment_id: None,
        kind: DatabaseRow(database_id: def.id, row_id: row_id),
        sort_order: row_id,
        database_id: Some(def.id),
        freshness_ttl_days: None,
        verified_at: None,
        verified_by: None,
        created_by: auth.principal.id,
        created_at: now,
        updated_at: now,
        archived_at: None,
        version: 1
      )
      t2 = try Db.tx_put_db_row(t1, def, row, page, blocks)
      Ok((t2, (row, page)))
    end
  )
  Ok(json_ok(201, Json.Object({"row": saved_row.to_json, "page": saved_page.to_json})))
end

## `PATCH /api/databases/:id/rows/:row_id` — Updates row cells with optimistic version checks, syncing `vlm_db_cells`, backing `Page`, and `Modb.Fts`.
fn update_row(
  req: Api.Request,
  id: Text,
  row_id: Text,
  auth: AuthContext,
  input: UpdateRowInput,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  now = clock.now
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "db_row.update",
    reason: input.reason or "update row '#{row_id}' in database '#{id}'",
    at: now
  )
  audit_payload = Json.Object({"database_id": Json.String(id), "row_id": Json.String(row_id)})

  (next_row, next_page) = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "updated row #{row_id} in #{id}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "write_db", now)
      def = case try Table.tx_get(t1, Db.databases_table(), id).map_error(Db.map_table_error)
        Some(d): d
        None: return Error(Missing(entity: "database", id: id))
      end
      try Policy.require_collection_access(auth, "write_db", def.collection_id)

      old_row = case try Table.tx_get(t1, Db.db_rows_table(), row_id).map_error(Db.map_table_error)
        Some(r) if r.database_id == def.id and r.archived_at == None: r
        Some(_) | None: return Error(Missing(entity: "db_row", id: row_id))
      end
      if old_row.version != input.expected_version
        return Error(
          Conflict(
            reason: "db_row '#{row_id}' version mismatch: expected #{input.expected_version}, found #{old_row
              .version}"
          )
        )
      end

      var merged_cells = old_row.cells
      for (k, v) in input.cells.entries
        merged_cells = merged_cells.set(k, v)
      end
      bumped_row = DbRow(
        id: old_row.id,
        database_id: old_row.database_id,
        page_id: old_row.page_id,
        cells: merged_cells,
        created_by: old_row.created_by,
        created_at: old_row.created_at,
        updated_at: now,
        archived_at: old_row.archived_at,
        version: old_row.version + 1
      )
      case DatabaseModel.validate_row_cells(def, bumped_row)
        Some(msg): return Error(BadInput(reason: msg))
        None: Unit
      end

      old_page = case try Table.tx_get(t1, Db.pages_table(), old_row.page_id).map_error(
        Db.map_table_error
      )
        Some(p): p
        None: return Error(Missing(entity: "page", id: old_row.page_id))
      end
      block_rows = try Table.tx_lookup(t1, Db.blocks_table(), Db.blocks_by_page(), old_page.id)
        .map_error(Db.map_table_error)
      existing_blocks = Blocks.sort_blocks(block_rows.map(fn(x) x.1 end))

      bumped_page = Page(
        id: old_page.id,
        collection_id: old_page.collection_id,
        parent_page_id: old_page.parent_page_id,
        title: DatabaseModel.extract_row_title(def, merged_cells),
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
      t2 = try Db.tx_put_db_row(t1, def, bumped_row, bumped_page, existing_blocks)
      Ok((t2, (bumped_row, bumped_page)))
    end
  )
  Ok(json_ok(200, Json.Object({"row": next_row.to_json, "page": next_page.to_json})))
end

## `DELETE /api/databases/:id/rows/:row_id` — Deletes a `DbRow`, `vlm_db_cells`, backing `Page`, and FTS entry.
fn delete_row(
  req: Api.Request,
  id: Text,
  row_id: Text,
  auth: AuthContext,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  now = clock.now
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "db_row.delete",
    reason: "delete row '#{row_id}' from database '#{id}'",
    at: now
  )
  audit_payload = Json.Object({"database_id": Json.String(id), "row_id": Json.String(row_id)})

  try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "deleted row #{row_id} from #{id}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "write_db", now)
      def = case try Table.tx_get(t1, Db.databases_table(), id).map_error(Db.map_table_error)
        Some(d): d
        None: return Error(Missing(entity: "database", id: id))
      end
      try Policy.require_collection_access(auth, "write_db", def.collection_id)
      old_row = case try Table.tx_get(t1, Db.db_rows_table(), row_id).map_error(Db.map_table_error)
        Some(r) if r.database_id == def.id: r
        Some(_) | None: return Error(Missing(entity: "db_row", id: row_id))
      end
      _ignore = old_row
      t2 = try Db.tx_delete_db_row(t1, def, row_id)
      Ok((t2, Unit))
    end
  )
  Ok(json_ok(200, Json.Object({"deleted_row_id": Json.String(row_id)})))
end
