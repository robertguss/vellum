## Context Studio, Living Summaries (`vlm_summaries`), Context Pack compiler (`vellum://packs/<slug>`),
## and grant-filtered `/llms.txt` progressive disclosure handlers.
module Routes.Packs
expose CreatePackInput(..),
UpdatePackInput(..),
list_permitted_summaries,
list_permitted_packs,
render_llms_txt_from_store,
compile_pack_from_store,
llms_txt,
packs_page,
list_summaries,
list_packs,
create_pack,
update_pack,
delete_pack,
compile_pack_json,
compile_pack_markdown
use Api
use Arvo.Flash
use Arvo.Id
use Arvo.Inertia
use Db
use Domain.Blocks
use Domain.Blueprints{BlueprintDef, PageBlueprintMeta}
use Domain.DatabaseModel{DatabaseDef}
use Domain.Packs{CompiledPackResult, ContextPack, LivingSummary, PackDbInput, PackPageInput}
use Domain.Policy
use Domain.Types{AppError, AuthContext, Collection, PageKind, PrincipalKind}
use Json
use Modb{Store, WriteTx}
use Modb.Grants
use Modb.Ledger
use Modb.Table
use Routes.Auth
use VaultOps

## JSON payload for `POST /api/packs`.
struct CreatePackInput
  slug: Text
  name: Text
  description: Option(Text)
  collection_ids: List(Text)
  pinned_page_ids: List(Text)
  database_ids: List(Text)
  query_hint: Option(Text)
  fresh_only: Option(Bool)
  include_full_blocks: Option(Bool)
  token_budget: Option(Int)
end

## JSON payload for `PUT /api/packs/:id`.
struct UpdatePackInput
  slug: Option(Text)
  name: Option(Text)
  description: Option(Text)
  collection_ids: Option(List(Text))
  pinned_page_ids: Option(List(Text))
  database_ids: Option(List(Text))
  query_hint: Option(Text)
  fresh_only: Option(Bool)
  include_full_blocks: Option(Bool)
  token_budget: Option(Int)
  expected_version: Option(Int)
end

fn json_ok(status: Int, body: Json) : Api.Response
  Api.encoded_json_response(status, body).with_header(
    "Content-Type",
    "application/json; charset=utf-8"
  )
end

fn markdown_ok(status: Int, body: Text, extra_headers: List((Text, Text))) : Api.Response
  headers = [("Content-Type", "text/markdown; charset=utf-8")].concat(extra_headers)
  Api.response(status, headers, body.bytes)
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

fn pack_write_action(auth: AuthContext) : Text
  if Policy.action_permitted?(auth, "manage_schema")
    "manage_schema"
  else
    "write_direct"
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

fn load_page_bp_and_meta(store: Store, page_id: Text) : Result(
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

## Lists grant-filtered `LivingSummary` records across permitted pages and databases.
fn list_permitted_summaries(
  store: Store,
  auth: AuthContext,
  col_filter: Option(Text),
  kind_filter: Option(Text)
) : Result(List(LivingSummary), AppError)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  case col_filter
    Some(cid) if not cid.trim.empty?:
      if not Policy.collection_permitted?(auth, cid.trim)
        return Ok([])
      end
    Some(_) | None: Unit
  end

  sum_rows = try Table.scan(store, Db.summaries_table(), None, None, 1000).map_error(
    Db.map_table_error
  )
  var by_id = {}
  for (k, s) in sum_rows
    by_id = by_id.set(k, s)
  end

  want_pages? = case kind_filter
    Some(kf) if kf.trim == "database": false
    Some(_) | None: true
  end
  want_dbs? = case kind_filter
    Some(kf) if kf.trim == "page": false
    Some(_) | None: true
  end

  var out = []
  if want_pages?
    p_rows = try Table.scan(store, Db.pages_table(), None, None, 1000).map_error(Db.map_table_error)
    for (_pid, pg) in p_rows
      if pg.archived_at == None and pg.kind == Document and Policy.collection_permitted?(
        auth,
        pg.collection_id
      )
        match_col? = case col_filter
          Some(cid) if not cid.trim.empty?: pg.collection_id == cid.trim
          Some(_) | None: true
        end
        if match_col?
          sum_rec = case by_id.get(Db.page_summary_key(pg.id))
            Some(existing): existing
            None:
              blks = try Db.load_page_blocks(store, pg.id)
              (bp_opt, pm_opt) = try load_page_bp_and_meta(store, pg.id)
              Packs.build_page_summary(pg, blks, bp_opt, pm_opt, None, pg.updated_at)
          end
          out = out.append(sum_rec)
        end
      end
    end
  end

  if want_dbs?
    d_rows = try Table.scan(store, Db.databases_table(), None, None, 500).map_error(
      Db.map_table_error
    )
    for (_did, def) in d_rows
      if Policy.collection_permitted?(auth, def.collection_id)
        match_col? = case col_filter
          Some(cid) if not cid.trim.empty?: def.collection_id == cid.trim
          Some(_) | None: true
        end
        if match_col?
          sum_rec = case by_id.get(Db.db_summary_key(def.id))
            Some(existing): existing
            None:
              r_pairs = try Table.lookup(
                store,
                Db.db_rows_table(),
                Db.db_rows_by_database(),
                def.id
              ).map_error(Db.map_table_error)
              active = r_pairs.filter(fn(p) p.1.archived_at == None end).map(fn(p) p.1 end)
              enr = try Db.enrich_rows_with_rollups(store, def, active)
              fallback_t = Time.parse("2026-11-27T00:00:00Z") or stop "fallback_t"
              Packs.build_database_summary(def, enr, None, fallback_t)
          end
          out = out.append(sum_rec)
        end
      end
    end
  end

  Ok(out.sort_by(fn(s) "#{s.entity_kind}:#{s.title.ascii_lowercase}" end))
end

fn pack_accessible?(auth: AuthContext, pack: ContextPack) : Bool
  return false if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
  return true if pack.collection_ids.empty?
  pack.collection_ids.any?(fn(cid) Policy.collection_permitted?(auth, cid) end)
end

## Lists all `ContextPack`s visible to `auth` under fail-closed collection ACLs.
fn list_permitted_packs(store: Store, auth: AuthContext) : Result(List(ContextPack), AppError)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  rows = try Table.scan(store, Db.packs_table(), None, None, 200).map_error(Db.map_table_error)
  var out = []
  for (_id, pk) in rows
    if pack_accessible?(auth, pk)
      out = out.append(pk)
    end
  end
  Ok(out.sort_by(fn(p) p.slug end))
end

## Builds the grant-filtered `/llms.txt` Layer 1 workspace index directly from `Store`
## (excluding all `ferpa_restricted` Vault collections).
fn render_llms_txt_from_store(store: Store, auth: AuthContext) : Result(Text, AppError)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  all_policies = try VaultOps.list_vault_policies_json(store)
  var ferpa_cids = Set.empty
  for pol in all_policies
    if pol.text_at("security_tier") == Some("ferpa_restricted")
      case pol.text_at("collection_id")
        Some(cid): ferpa_cids = ferpa_cids.add(cid)
        None: Unit
      end
    end
  end
  cols = (try permitted_collections(store, auth)).filter(fn(c) not ferpa_cids.has?(c.id) end)
  packs = (try list_permitted_packs(store, auth)).filter(fn(pk)
    not pk.collection_ids.any?(fn(cid) ferpa_cids.has?(cid) end)
  end)
  sums = (try list_permitted_summaries(store, auth, None, None)).filter(fn(s)
    not ferpa_cids.has?(s.collection_id)
  end)
  Ok(Packs.render_llms_txt(cols, packs, sums))
end

fn find_pack_by_slug_or_id(store: Store, slug_or_id: Text) : Result(Option(ContextPack), AppError)
  by_slug = try Table.lookup(store, Db.packs_table(), Db.packs_by_slug(), slug_or_id).map_error(
    Db.map_table_error
  )
  case by_slug.first
    Some((_id, pk)): return Ok(Some(pk))
    None: Unit
  end
  Table.get(store, Db.packs_table(), slug_or_id).map_error(Db.map_table_error)
end

## Compiles `slug_or_id` under strict collection grant filtering and hard `token_budget` enforcement.
fn compile_pack_from_store(
  store: Store,
  auth: AuthContext,
  slug_or_id: Text,
  query_override: Option(Text),
  now: Time
) : Result(CompiledPackResult, AppError)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  pack = case try find_pack_by_slug_or_id(store, slug_or_id.trim)
    Some(p): p
    None: return Error(Missing(entity: "pack", id: slug_or_id))
  end
  if not pack_accessible?(auth, pack)
    return Error(
      Forbidden(reason: "grant '#{auth.grant_id}' does not permit access to pack '#{pack.slug}'")
    )
  end

  allowed_col_set = if pack.collection_ids.empty?
    None
  else
    Some(pack.collection_ids.filter(fn(cid) Policy.collection_permitted?(auth, cid) end).to_set)
  end

  sum_rows = try Table.scan(store, Db.summaries_table(), None, None, 1000).map_error(
    Db.map_table_error
  )
  var sum_by_id = {}
  for (k, s) in sum_rows
    sum_by_id = sum_by_id.set(k, s)
  end

  var seen_pages = {}
  var pinned_inputs = []
  for pid in pack.pinned_page_ids
    continue if seen_pages.get(pid) != None
    case try Table.get(store, Db.pages_table(), pid).map_error(Db.map_table_error)
      Some(pg) if pg.archived_at == None and pg.kind == Document and Policy.collection_permitted?(
        auth,
        pg.collection_id
      ):
        seen_pages = seen_pages.set(pg.id, true)
        blks = try Db.load_page_blocks(store, pg.id)
        (bp_opt, pm_opt) = try load_page_bp_and_meta(store, pg.id)
        sum_opt = sum_by_id.get(Db.page_summary_key(pg.id))
        pinned_inputs = pinned_inputs.append(
          PackPageInput(
            page: pg,
            blocks: blks,
            blueprint: bp_opt,
            meta: pm_opt,
            summary: sum_opt,
            pinned: true,
            stale: Packs.page_is_stale?(pg, now)
          )
        )
      Some(_) | None: Unit
    end
  end

  all_pages = try Table.scan(store, Db.pages_table(), None, None, 1000).map_error(
    Db.map_table_error
  )
  hint_raw = (query_override or (pack.query_hint or "")).trim.ascii_lowercase
  var match_inputs = []
  var other_inputs = []

  for (_pid, pg) in all_pages
    continue if seen_pages.get(pg.id) != None
    continue if pg.archived_at != None or pg.kind != Document
    continue if not Policy.collection_permitted?(auth, pg.collection_id)
    in_scope? = case allowed_col_set
      Some(cset): cset.has?(pg.collection_id)
      None: true
    end
    continue if not in_scope?

    seen_pages = seen_pages.set(pg.id, true)
    blks = try Db.load_page_blocks(store, pg.id)
    (bp_opt, pm_opt) = try load_page_bp_and_meta(store, pg.id)
    sum_opt = sum_by_id.get(Db.page_summary_key(pg.id))
    inp = PackPageInput(
      page: pg,
      blocks: blks,
      blueprint: bp_opt,
      meta: pm_opt,
      summary: sum_opt,
      pinned: false,
      stale: Packs.page_is_stale?(pg, now)
    )
    if hint_raw.empty?
      other_inputs = other_inputs.append(inp)
    else
      haystack = "#{pg.title}\n#{sum_opt.map(fn(s) s.structural_summary end) or ""}\n#{Blocks.blocks_plain_text(blks)}".ascii_lowercase
      if haystack.contains?(hint_raw)
        match_inputs = match_inputs.append(inp)
      else
        other_inputs = other_inputs.append(inp)
      end
    end
  end

  var db_inputs = []
  var seen_dbs = {}
  for did in pack.database_ids
    continue if seen_dbs.get(did) != None
    case try Table.get(store, Db.databases_table(), did).map_error(Db.map_table_error)
      Some(def) if Policy.collection_permitted?(auth, def.collection_id):
        seen_dbs = seen_dbs.set(def.id, true)
        r_pairs = try Table.lookup(store, Db.db_rows_table(), Db.db_rows_by_database(), def.id)
          .map_error(Db.map_table_error)
        active = r_pairs.filter(fn(p) p.1.archived_at == None end).map(fn(p) p.1 end)
        enr = try Db.enrich_rows_with_rollups(store, def, active)
        dsum_opt = sum_by_id.get(Db.db_summary_key(def.id))
        db_inputs = db_inputs.append(PackDbInput(def: def, rows: enr, summary: dsum_opt))
      Some(_) | None: Unit
    end
  end

  if pack.database_ids.empty?
    all_dbs = try Table.scan(store, Db.databases_table(), None, None, 200).map_error(
      Db.map_table_error
    )
    for (_did, def) in all_dbs
      continue if seen_dbs.get(def.id) != None
      continue if not Policy.collection_permitted?(auth, def.collection_id)
      in_scope? = case allowed_col_set
        Some(cset): cset.has?(def.collection_id)
        None: true
      end
      continue if not in_scope?
      seen_dbs = seen_dbs.set(def.id, true)
      r_pairs = try Table.lookup(store, Db.db_rows_table(), Db.db_rows_by_database(), def.id)
        .map_error(Db.map_table_error)
      active = r_pairs.filter(fn(p) p.1.archived_at == None end).map(fn(p) p.1 end)
      enr = try Db.enrich_rows_with_rollups(store, def, active)
      dsum_opt = sum_by_id.get(Db.db_summary_key(def.id))
      db_inputs = db_inputs.append(PackDbInput(def: def, rows: enr, summary: dsum_opt))
    end
  end

  ordered_pages = pinned_inputs.concat(match_inputs).concat(other_inputs)
  Ok(Packs.compile_pack(pack, ordered_pages, db_inputs, now))
end

fn validate_pack_targets_tx(tx: WriteTx, auth: AuthContext, pack: ContextPack) : Result(
  Unit,
  AppError
)
  for cid in pack.collection_ids
    col = case try Table.tx_get(tx, Db.collections_table(), cid).map_error(Db.map_table_error)
      Some(c) if c.archived_at == None: c
      Some(_) | None: return Error(BadInput(reason: "collection '#{cid}' not found"))
    end
    try Policy.require_collection_access(auth, "read", col.id)
  end
  for pid in pack.pinned_page_ids
    pg = case try Table.tx_get(tx, Db.pages_table(), pid).map_error(Db.map_table_error)
      Some(p) if p.archived_at == None: p
      Some(_) | None: return Error(BadInput(reason: "pinned page '#{pid}' not found"))
    end
    try Policy.require_collection_access(auth, "read", pg.collection_id)
  end
  for did in pack.database_ids
    def = case try Table.tx_get(tx, Db.databases_table(), did).map_error(Db.map_table_error)
      Some(d): d
      None: return Error(BadInput(reason: "database '#{did}' not found"))
    end
    try Policy.require_collection_access(auth, "read", def.collection_id)
  end
  Ok(Unit)
end

## `GET /llms.txt` — Returns grant-filtered Layer 1 progressive-disclosure workspace index (`text/markdown`).
fn llms_txt(_req: Api.Request, auth: AuthContext, rf: ReadFiles) : Result(Api.Response, AppError)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Ok(markdown_ok(200, "# Vellum Workspace Index (/llms.txt)\n\n_Empty workspace._", []))
  end
  body = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db) render_llms_txt_from_store(Ledger.store(db), auth) end
  )
  Ok(markdown_ok(200, body, []))
end

## `GET /packs` — Renders the Context Studio Inertia workspace (`ReadFiles`-only).
fn packs_page(req: Api.Request, auth: Option(AuthContext), rf: ReadFiles, env: Env) : Result(
  Api.Response,
  AppError
)
  a = case auth
    Some(x): x
    None: return Auth.guest_redirect_or_401(req, env)
  end
  if not Policy.action_permitted?(a, "read") or a.principal.suspended
    return Error(Forbidden(reason: "grant '#{a.grant_id}' does not permit 'read'"))
  end

  pack_data = if not rf.exists?(Db.ledger_db_path)
    Json.Object({
      "collections": Json.Array([]),
      "databases": Json.Array([]),
      "summaries": Json.Array([]),
      "packs": Json.Array([]),
      "llms_txt": Json.String("# Vellum Workspace Index (/llms.txt)\n\n_Empty workspace._")
    })
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
        s_list = try list_permitted_summaries(store, a, None, None)
        p_list = try list_permitted_packs(store, a)
        txt = try render_llms_txt_from_store(store, a)
        Ok(
          Json.Object({
            "collections": c_list.to_json,
            "databases": d_list.to_json,
            "summaries": s_list.to_json,
            "packs": p_list.to_json,
            "llms_txt": Json.String(txt)
          })
        )
      end
    )
  end

  if Auth.wants_json?(req)
    return Ok(json_ok(200, pack_data))
  end

  icfg = try Auth.load_inertia_config(rf, env)
  if Inertia.check_version(req, icfg) is Some(ver_res)
    return Ok(ver_res)
  end
  (shared, had_flash?) = try Auth.shared_props_for(req, Some(a), rf, env)
  res = Inertia.render(
    req,
    icfg,
    "Workspace/Packs",
    {
      "collections": pack_data.get("collections") or Json.Array([]),
      "databases": pack_data.get("databases") or Json.Array([]),
      "summaries": pack_data.get("summaries") or Json.Array([]),
      "packs": pack_data.get("packs") or Json.Array([]),
      "llms_txt": pack_data.get("llms_txt") or Json.String("")
    },
    shared
  )
  Ok(Flash.clear_if_present(res, had_flash?, Auth.secure_cookies?(env)))
end

## `GET /api/summaries` — Lists grant-filtered Page & Database `LivingSummary` headers (`ReadFiles`-only).
fn list_summaries(req: Api.Request, auth: AuthContext, rf: ReadFiles) : Result(
  Api.Response,
  AppError
)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Ok(json_ok(200, Json.Object({"summaries": Json.Array([])})))
  end
  col_f = req.query_param("collection_id")
  kind_f = req.query_param("kind")
  sums_json = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      sums = try list_permitted_summaries(Ledger.store(db), auth, col_f, kind_f)
      Ok(sums.to_json)
    end
  )
  Ok(json_ok(200, Json.Object({"summaries": sums_json})))
end

## `GET /api/packs` — Lists accessible `ContextPack` definitions (`ReadFiles`-only).
fn list_packs(_req: Api.Request, auth: AuthContext, rf: ReadFiles) : Result(Api.Response, AppError)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Ok(json_ok(200, Json.Object({"packs": Json.Array([])})))
  end
  packs_json = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      packs = try list_permitted_packs(Ledger.store(db), auth)
      Ok(packs.to_json)
    end
  )
  Ok(json_ok(200, Json.Object({"packs": packs_json})))
end

## `POST /api/packs` — Creates a token-budgeted `ContextPack`.
fn create_pack(
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  input = CreatePackInput(
    slug: try VaultOps.req_text(rj, "slug"),
    name: try VaultOps.req_text(rj, "name"),
    description: rj.text_at("description"),
    collection_ids: VaultOps.json_text_list_raw(rj, "collection_ids"),
    pinned_page_ids: VaultOps.json_text_list_raw(rj, "pinned_page_ids"),
    database_ids: VaultOps.json_text_list_raw(rj, "database_ids"),
    query_hint: rj.text_at("query_hint"),
    fresh_only: rj.bool_at("fresh_only"),
    include_full_blocks: rj.bool_at("include_full_blocks"),
    token_budget: rj.int_at("token_budget")
  )
  can_write? = not auth.principal.suspended and
    (Policy.action_permitted?(auth, "manage_schema") or
      Policy.action_permitted?(auth, "write_direct"))
  if not can_write?
    return Error(
      Forbidden(reason: "grant '#{auth.grant_id}' requires 'write_direct' or 'manage_schema'")
    )
  end

  now = clock.now
  act = pack_write_action(auth)
  q_hint = case input.query_hint
    Some(q) if not q.trim.empty?: Some(q.trim)
    Some(_) | None: None
  end
  pk = ContextPack(
    id: "pk_#{Id.ulid(rng, clock)}",
    slug: input.slug.trim.ascii_lowercase,
    name: input.name.trim,
    description: (input.description or "").trim,
    collection_ids: input.collection_ids,
    pinned_page_ids: input.pinned_page_ids,
    database_ids: input.database_ids,
    query_hint: q_hint,
    fresh_only: input.fresh_only or false,
    include_full_blocks: input.include_full_blocks or true,
    token_budget: input.token_budget or 4000,
    created_by: auth.principal.id,
    updated_at: now,
    version: 1
  )
  case Packs.validate_context_pack(pk)
    Some(msg): return Error(BadInput(reason: msg))
    None: Unit
  end

  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "pack.create",
    reason: "create context pack '#{pk.slug}'",
    at: now
  )
  audit_payload = Json.Object({"pack_id": Json.String(pk.id), "slug": Json.String(pk.slug)})
  created_json = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "created context pack #{pk.id} (#{pk.slug})",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, act, now)
      try validate_pack_targets_tx(t1, auth, pk)
      t2 = try Table.put(t1, Db.packs_table(), pk.id, pk).map_error(Db.map_table_error)
      Ok((t2, pk.to_json))
    end
  )
  Ok(json_ok(201, created_json))
end

## `PUT /api/packs/:id` — Updates a `ContextPack` with optimistic `expected_version` check.
fn update_pack(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  input = UpdatePackInput(
    slug: rj.text_at("slug"),
    name: rj.text_at("name"),
    description: rj.text_at("description"),
    collection_ids: VaultOps.json_text_list_opt(rj, "collection_ids"),
    pinned_page_ids: VaultOps.json_text_list_opt(rj, "pinned_page_ids"),
    database_ids: VaultOps.json_text_list_opt(rj, "database_ids"),
    query_hint: rj.text_at("query_hint"),
    fresh_only: rj.bool_at("fresh_only"),
    include_full_blocks: rj.bool_at("include_full_blocks"),
    token_budget: rj.int_at("token_budget"),
    expected_version: rj.int_at("expected_version")
  )
  can_write? = not auth.principal.suspended and
    (Policy.action_permitted?(auth, "manage_schema") or
      Policy.action_permitted?(auth, "write_direct"))
  if not can_write?
    return Error(
      Forbidden(reason: "grant '#{auth.grant_id}' requires 'write_direct' or 'manage_schema'")
    )
  end

  now = clock.now
  act = pack_write_action(auth)
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "pack.update",
    reason: "update context pack '#{id}'",
    at: now
  )
  audit_payload = Json.Object({"pack_id": Json.String(id)})

  updated_json = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "updated context pack #{id}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, act, now)
      old_pk = case try Table.tx_get(t1, Db.packs_table(), id).map_error(Db.map_table_error)
        Some(p): p
        None: return Error(Missing(entity: "pack", id: id))
      end
      if not pack_accessible?(auth, old_pk)
        return Error(
          Forbidden(
            reason: "grant '#{auth.grant_id}' cannot modify pack '#{old_pk.slug}'"
          )
        )
      end
      case input.expected_version
        Some(ev) if ev != old_pk.version: return Error(
          Conflict(reason: "expected pack version #{ev}, found #{old_pk.version}")
        )
        Some(_) | None: Unit
      end

      next_qh = case input.query_hint
        Some(q) if not q.trim.empty?: Some(q.trim)
        Some(_): None
        None: old_pk.query_hint
      end
      next_pk = ContextPack(
        id: old_pk.id,
        slug: (input.slug or old_pk.slug).trim.ascii_lowercase,
        name: (input.name or old_pk.name).trim,
        description: (input.description or old_pk.description).trim,
        collection_ids: input.collection_ids or old_pk.collection_ids,
        pinned_page_ids: input.pinned_page_ids or old_pk.pinned_page_ids,
        database_ids: input.database_ids or old_pk.database_ids,
        query_hint: next_qh,
        fresh_only: case input.fresh_only
          Some(b): b
          None: old_pk.fresh_only
        end,
        include_full_blocks: case input.include_full_blocks
          Some(b): b
          None: old_pk.include_full_blocks
        end,
        token_budget: input.token_budget or old_pk.token_budget,
        created_by: old_pk.created_by,
        updated_at: now,
        version: old_pk.version + 1
      )
      case Packs.validate_context_pack(next_pk)
        Some(msg): return Error(BadInput(reason: msg))
        None: Unit
      end
      try validate_pack_targets_tx(t1, auth, next_pk)
      t2 = try Table.put(t1, Db.packs_table(), next_pk.id, next_pk).map_error(Db.map_table_error)
      Ok((t2, next_pk.to_json))
    end
  )
  Ok(json_ok(200, updated_json))
end

## `DELETE /api/packs/:id` — Deletes a `ContextPack`.
fn delete_pack(req: Api.Request, id: Text, auth: AuthContext, files: Files, clock: Clock) : Result(
  Api.Response,
  AppError
)
  try Auth.require_session_csrf(req, auth)
  can_write? = not auth.principal.suspended and
    (Policy.action_permitted?(auth, "manage_schema") or
      Policy.action_permitted?(auth, "write_direct"))
  if not can_write?
    return Error(
      Forbidden(reason: "grant '#{auth.grant_id}' requires 'write_direct' or 'manage_schema'")
    )
  end

  now = clock.now
  act = pack_write_action(auth)
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "pack.delete",
    reason: "delete context pack '#{id}'",
    at: now
  )
  audit_payload = Json.Object({"pack_id": Json.String(id)})

  _deleted = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "deleted context pack #{id}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, act, now)
      old_pk = case try Table.tx_get(t1, Db.packs_table(), id).map_error(Db.map_table_error)
        Some(p): p
        None: return Error(Missing(entity: "pack", id: id))
      end
      if not pack_accessible?(auth, old_pk)
        return Error(
          Forbidden(reason: "grant '#{auth.grant_id}' cannot delete pack '#{old_pk.slug}'")
        )
      end
      t2 = try Table.delete(t1, Db.packs_table(), id).map_error(Db.map_table_error)
      Ok((t2, Unit))
    end
  )
  Ok(json_ok(200, Json.Object({"deleted": Json.Boolean(true), "id": Json.String(id)})))
end

## `GET /api/packs/:slug` — Compiles a `ContextPack` (JSON by default, or Markdown when requested).
fn compile_pack_json(
  req: Api.Request,
  slug: Text,
  auth: AuthContext,
  rf: ReadFiles,
  clock: Clock
) : Result(Api.Response, AppError)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "pack", id: slug))
  end
  now = clock.now
  q_over = req.query_param("q")
  compiled_wrap = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      compiled = try compile_pack_from_store(Ledger.store(db), auth, slug, q_over, now)
      Ok(
        Json.Object({
          "json": compiled.to_json,
          "markdown": Json.String(compiled.markdown),
          "tokens_used": Json.int(compiled.tokens_used),
          "token_budget": Json.int(compiled.token_budget)
        })
      )
    end
  )
  accept = (req.header("Accept") or "").ascii_lowercase
  want_md? = req.query_param("format") == Some("md") or
    (accept.contains?("text/markdown") and not accept.contains?("application/json"))
  if want_md?
    Ok(
      markdown_ok(
        200,
        compiled_wrap.text_at("markdown") or "",
        [
          ("X-Vellum-Tokens-Used", (compiled_wrap.int_at("tokens_used") or 0).to_text),
          ("X-Vellum-Token-Budget", (compiled_wrap.int_at("token_budget") or 0).to_text)
        ]
      )
    )
  else
    Ok(json_ok(200, compiled_wrap.get("json") or Json.Null))
  end
end

## `GET /api/packs/:slug/markdown` — Returns raw token-budgeted `text/markdown` for agents and CLIs.
fn compile_pack_markdown(
  req: Api.Request,
  slug: Text,
  auth: AuthContext,
  rf: ReadFiles,
  clock: Clock
) : Result(Api.Response, AppError)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "pack", id: slug))
  end
  now = clock.now
  q_over = req.query_param("q")
  compiled_wrap = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      compiled = try compile_pack_from_store(Ledger.store(db), auth, slug, q_over, now)
      Ok(
        Json.Object({
          "markdown": Json.String(compiled.markdown),
          "tokens_used": Json.int(compiled.tokens_used),
          "token_budget": Json.int(compiled.token_budget)
        })
      )
    end
  )
  Ok(
    markdown_ok(
      200,
      compiled_wrap.text_at("markdown") or "",
      [
        ("X-Vellum-Tokens-Used", (compiled_wrap.int_at("tokens_used") or 0).to_text),
        ("X-Vellum-Token-Budget", (compiled_wrap.int_at("token_budget") or 0).to_text)
      ]
    )
  )
end
