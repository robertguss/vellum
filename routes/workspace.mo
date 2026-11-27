## Vellum workspace, collection, canonical block-tree, search, attachment, and admin handlers.
module Routes.Workspace
expose CreateCollectionInput(..),
CreatePageInput(..),
PatchBlocksInput(..),
VerifyPageInput(..),
CreateCommentInput(..),
PresignAttachmentInput(..),
MintAgentTokenInput(..),
CreateBlueprintInput(..),
UpdateBlueprintInput(..),
SetPageMetaInput(..),
SyncPageMarkdownInput(..),
ResolveMetricsInput(..),
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
upload_local_attachment,
mint_agent_token,
revoke_grant,
audit_index,
proposals_page,
admin_page,
list_blueprints,
create_blueprint,
update_blueprint,
set_page_blueprint_meta,
sync_page_markdown,
resolve_metrics,
show_block_context,
drain_jobs
use Api
use Arvo.Flash
use Arvo.Id
use Arvo.Inertia
use Arvo.Modb.Jobs
use Arvo.Modb.Sessions
use Arvo.S3
use Arvo.Webhooks
use Crypto
use Db
use Domain.Blocks
use Domain.Blueprints{BlueprintDef, PageBlueprintMeta}
use Domain.Collab{WebhookJobPayload}
use Domain.DatabaseModel{CellValue, DatabaseDef, EnrichedRow, PropertyDef, PropertyKind, RollupAgg}
use Domain.Packs{LivingSummary}
use Domain.Policy
use Domain.Types{
  AppError,
  Attachment,
  AuditFeedItem,
  AuthContext,
  AuthorKind,
  Block,
  BlockKind,
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
use Modb.World
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

## JSON payload for `POST /api/blueprints`.
struct CreateBlueprintInput
  slug: Text
  name: Text
  description: Option(Text)
  icon: Option(Text)
  fields: List(PropertyDef)
  default_template_markdown: Option(Text)
end

## JSON payload for `PUT /api/blueprints/:id`.
struct UpdateBlueprintInput
  slug: Option(Text)
  name: Option(Text)
  description: Option(Text)
  icon: Option(Text)
  fields: Option(List(PropertyDef))
  default_template_markdown: Option(Text)
  expected_version: Option(Int)
end

## JSON payload for `PUT /api/pages/:id/meta`.
struct SetPageMetaInput
  blueprint_id: Option(Text)
  values: Option(Map(Text, CellValue))
  apply_template_if_empty: Option(Bool)
  reason: Option(Text)
end

## JSON payload for `PUT /api/pages/:id/markdown`.
struct SyncPageMarkdownInput
  markdown: Text
  expected_page_version: Int
  reason: Option(Text)
end

## JSON payload for `POST /api/metrics/resolve`.
struct ResolveMetricsInput
  tokens: List(Text)
  scenario_id: Option(Text)
end

struct CachedDbMetricsData
  def: DatabaseDef
  rows: List(EnrichedRow)
end

fn zero_pad4_int(n: Int) : Text
  s = n.to_text
  if s.byte_count >= 4: s else: "#{"0".repeat(4 - s.byte_count)}#{s}"
end

fn prop_is_relation_target(kind: PropertyKind) : Option(Text)
  case kind
    Relation(target_db_id: tdb_id, inverse_prop_id: _): Some(tdb_id)
    Title | RichText | Number(format: _) | DateProp(include_time: _) | Select(options: _) | MultiSelect(
      options: _
    ) | Checkbox | Person | Url | Rollup(relation_prop_id: _, target_prop_id: _, agg: _): None
  end
end

fn validate_blueprint_relations_tx(tx: WriteTx, auth: AuthContext, bp: BlueprintDef) : Result(
  Unit,
  AppError
)
  for f in bp.fields
    case prop_is_relation_target(f.kind)
      Some(tdb_id):
        tdb = case try Table.tx_get(tx, Db.databases_table(), tdb_id).map_error(Db.map_table_error)
          Some(d): d
          None: return Error(
            BadInput(reason: "relation field '#{f.id}' references missing database '#{tdb_id}'")
          )
        end
        try Policy.require_collection_access(auth, "read", tdb.collection_id)
      None: Unit
    end
  end
  Ok(Unit)
end

fn validate_meta_relations_tx(
  tx: WriteTx,
  auth: AuthContext,
  bp: BlueprintDef,
  values: Map(Text, CellValue)
) : Result(Unit, AppError)
  for f in bp.fields
    case prop_is_relation_target(f.kind)
      Some(tdb_id):
        case values.get(f.id)
          Some(RelationVal(row_ids: rids)) if not rids.empty?:
            tdb = case try Table.tx_get(tx, Db.databases_table(), tdb_id).map_error(
              Db.map_table_error
            )
              Some(d): d
              None: return Error(
                BadInput(reason: "relation field '#{f.id}' references missing database '#{tdb_id}'")
              )
            end
            try Policy.require_collection_access(auth, "read", tdb.collection_id)
            for rid in rids
              case try Table.tx_get(tx, Db.db_rows_table(), rid).map_error(Db.map_table_error)
                Some(tr) if tr.database_id == tdb_id and tr.archived_at == None: Unit
                Some(_) | None: return Error(
                  BadInput(
                    reason: "relation field '#{f.id}' references missing row '#{rid}' in '#{tdb_id}'"
                  )
                )
              end
            end
          Some(_) | None: Unit
        end
      None: Unit
    end
  end
  Ok(Unit)
end

fn strip_optional_frontmatter(raw: Text) : Text
  lines = raw.lines
  return raw if lines.size < 3
  first = (lines.first or "").trim
  return raw if first != "---"
  var i = 1
  var valid_keys = false
  while i < lines.size
    line = lines.get(i) or ""
    t = line.trim
    if t == "---"
      if valid_keys
        return lines.drop(i + 1).join("\n")
      else
        return raw
      end
    end
    if not t.empty? and not t.starts_with?("#")
      if line.starts_with?(" ") or line.starts_with?("\t") or t.contains?(":")
        valid_keys = true
      else
        return raw
      end
    end
    i += 1
  end
  raw
end

fn reconcile_markdown_blocks(
  page_id: Text,
  existing_blocks: List(Block),
  raw_markdown: Text,
  prov: Provenance,
  id_prefix: Text
) : List(Block)
  body = strip_optional_frontmatter(raw_markdown)
  parsed = Blocks.parse_markdown_blocks(page_id, body, prov, "tmp_#{id_prefix}")
  return [] if parsed.empty?

  sorted_old = Blocks.sort_blocks(existing_blocks)
  var old_by_id = {}
  var old_idx_by_id = {}
  var oi = 0
  for ob in sorted_old
    old_by_id = old_by_id.set(ob.id, ob)
    old_idx_by_id = old_idx_by_id.set(ob.id, oi)
    oi += 1
  end

  # Deduplicate anchor IDs and mint fresh IDs for any block not already owned by `page_id`.
  var seen_ids = {}
  var new_seq = 0
  var staged = []
  var in_order? = true
  var last_old_idx = -1
  var last_old_rank = None

  for p in parsed
    matched_opt = if seen_ids.get(p.id) == None
      case old_by_id.get(p.id)
        Some(ob):
          seen_ids = seen_ids.set(ob.id, true)
          idx = old_idx_by_id.get(ob.id) or 0
          rank_ok = case last_old_rank
            Some(pr): ob.rank > pr
            None: true
          end
          if idx <= last_old_idx or not rank_ok
            in_order? = false
          else
            last_old_idx = idx
            last_old_rank = Some(ob.rank)
          end
          Some(ob)
        None: None
      end
    else
      None
    end

    case matched_opt
      Some(ob): staged = staged.append((Some(ob), p.kind, p.markdown))
      None:
        new_seq += 1
        fresh_id = "blk_#{id_prefix}_#{zero_pad4_int(new_seq)}"
        nb = Block(
          id: fresh_id,
          page_id: page_id,
          parent_block_id: None,
          rank: p.rank,
          kind: p.kind,
          markdown: p.markdown,
          provenance: prov,
          version: 1
        )
        staged = staged.append((None, nb.kind, nb.markdown))
    end
  end

  if in_order?
    # Assign preserved ranks directly and interpolate ranks for newly inserted spans via rank_between.
    var out = []
    var prev_rank = None
    var fresh_idx = 0
    var i = 0
    n = staged.size
    while i < n
      entry = staged.get(i) or (None, Paragraph, "")
      case entry.0
        Some(ob):
          updated = if ob.kind == entry.1 and ob.markdown == entry.2
            ob
          else
            Block(
              id: ob.id,
              page_id: page_id,
              parent_block_id: ob.parent_block_id,
              rank: ob.rank,
              kind: entry.1,
              markdown: entry.2,
              provenance: prov,
              version: ob.version + 1
            )
          end
          prev_rank = Some(ob.rank)
          out = out.append(updated)
          i += 1
        None:
          # Find the next preserved block rank after this run of new blocks.
          var j = i + 1
          var next_rank = None
          while j < n
            nxt = staged.get(j) or (None, Paragraph, "")
            case nxt.0
              Some(ob2):
                next_rank = Some(ob2.rank)
                break
              None: j += 1
            end
          end
          var k = i
          var cur_left = prev_rank
          while k < j
            new_e = staged.get(k) or (None, Paragraph, "")
            fresh_idx += 1
            fid = "blk_#{id_prefix}_#{zero_pad4_int(fresh_idx)}"
            r = Blocks.rank_between(cur_left, next_rank)
            cur_left = Some(r)
            out = out.append(
              Block(
                id: fid,
                page_id: page_id,
                parent_block_id: None,
                rank: r,
                kind: new_e.1,
                markdown: new_e.2,
                provenance: prov,
                version: 1
              )
            )
            k += 1
          end
          prev_rank = cur_left
          i = j
      end
    end
    out
  else
    # Reordered case: assign clean monotonic ranks; preserve version/provenance only if unchanged at same rank.
    var out = []
    var fresh_idx = 0
    var pos = 0
    for entry in staged
      pos += 1
      new_rank = "i#{zero_pad4_int(pos)}"
      case entry.0
        Some(ob):
          if ob.kind == entry.1 and ob.markdown == entry.2 and ob.rank == new_rank
            out = out.append(ob)
          else
            out = out.append(
              Block(
                id: ob.id,
                page_id: page_id,
                parent_block_id: ob.parent_block_id,
                rank: new_rank,
                kind: entry.1,
                markdown: entry.2,
                provenance: prov,
                version: ob.version + 1
              )
            )
          end
        None:
          fresh_idx += 1
          fid = "blk_#{id_prefix}_#{zero_pad4_int(fresh_idx)}"
          out = out.append(
            Block(
              id: fid,
              page_id: page_id,
              parent_block_id: None,
              rank: new_rank,
              kind: entry.1,
              markdown: entry.2,
              provenance: prov,
              version: 1
            )
          )
      end
    end
    out
  end
end

fn load_live_db_cached(
  store: Store,
  auth: AuthContext,
  cache: Map(Text, Option(CachedDbMetricsData)),
  db_id: Text
) : Result((Map(Text, Option(CachedDbMetricsData)), Option(CachedDbMetricsData)), AppError)
  case cache.get(db_id)
    Some(hit): return Ok((cache, hit))
    None: Unit
  end
  res = case try Table.get(store, Db.databases_table(), db_id).map_error(Db.map_table_error)
    None: None
    Some(def):
      if not Policy.collection_permitted?(auth, def.collection_id)
        None
      else
        pairs = try Table.lookup(store, Db.db_rows_table(), Db.db_rows_by_database(), def.id)
          .map_error(Db.map_table_error)
        var active = []
        for (_rid, r) in pairs
          if r.archived_at == None
            active = active.append(r)
          end
        end
        enr = try Db.enrich_rows_with_rollups(store, def, active)
        Some(CachedDbMetricsData(def: def, rows: enr))
      end
  end
  Ok((cache.set(db_id, res), res))
end

fn load_scen_db_cached(
  spec_tx: WriteTx,
  auth: AuthContext,
  cache: Map(Text, Option(CachedDbMetricsData)),
  db_id: Text
) : Result((Map(Text, Option(CachedDbMetricsData)), Option(CachedDbMetricsData)), AppError)
  case cache.get(db_id)
    Some(hit): return Ok((cache, hit))
    None: Unit
  end
  res = case try Table.tx_get(spec_tx, Db.databases_table(), db_id).map_error(Db.map_table_error)
    None: None
    Some(def):
      if not Policy.collection_permitted?(auth, def.collection_id)
        None
      else
        pairs = try Table.tx_lookup(
          spec_tx,
          Db.db_rows_table(),
          Db.db_rows_by_database(),
          def.id
        ).map_error(Db.map_table_error)
        var active = []
        for (_rid, r) in pairs
          if r.archived_at == None
            active = active.append(r)
          end
        end
        enr = try Db.tx_enrich_rows_with_rollups(spec_tx, def, active)
        Some(CachedDbMetricsData(def: def, rows: enr))
      end
  end
  Ok((cache.set(db_id, res), res))
end

fn eval_metric_agg(agg: Text, cells: List(CellValue)) : Result((Option(Text), Option(Decimal)), Text)
  low = agg.trim.ascii_lowercase
  case low
    "sum" | "count" | "count_values" | "min" | "max":
      op = case low
        "sum": SumValues
        "count": CountAll
        "count_values": CountValues
        "min": MinValue
        _: MaxValue
      end
      case DatabaseModel.compute_rollup(op, cells)
        NumberVal(d): Ok((Some(d.to_text), Some(d)))
        DateVal(start: dt, end_date: _): Ok((Some(dt.to_iso), None))
        Empty | TextVal(_) | SelectVal(option_id: _) | MultiSelectVal(option_ids: _) | BoolVal(_) | PrincipalVal(
          _
        ) | UrlVal(_) | RelationVal(row_ids: _): Ok((None, None))
      end
    "avg":
      var sum_d = 0.0
      var count_n = 0
      for c in cells
        case c
          NumberVal(d):
            sum_d += d
            count_n += 1
          Empty | TextVal(_) | DateVal(start: _, end_date: _) | SelectVal(option_id: _) | MultiSelectVal(
            option_ids: _
          ) | BoolVal(_) | PrincipalVal(_) | UrlVal(_) | RelationVal(row_ids: _): Unit
        end
      end
      if count_n == 0
        Ok((None, None))
      else
        avg_d = (sum_d / count_n.to_decimal).round(4)
        Ok((Some(avg_d.to_text), Some(avg_d)))
      end
    _: Error("unsupported metric aggregation '#{agg}'")
  end
end

fn metric_format_of_prop(kind: PropertyKind) : Text
  case kind
    Number(format: f): f
    Title | RichText | DateProp(include_time: _) | Select(options: _) | MultiSelect(options: _) | Checkbox | Person | Url | Relation(
      target_db_id: _,
      inverse_prop_id: _
    ) | Rollup(relation_prop_id: _, target_prop_id: _, agg: _): "plain"
  end
end

fn find_prop_in_def(def: DatabaseDef, prop_id: Text) : Option(PropertyDef)
  for p in def.properties
    if p.id == prop_id
      return Some(p)
    end
  end
  None
end

fn forbidden_metric_json(
  tok: Text,
  db_id: Text,
  prop_id: Text,
  agg: Text,
  status_str: Text
) : Json
  Json.Object({
    "token": Json.String(tok),
    "database_id": Json.String(db_id),
    "property_id": Json.String(prop_id),
    "agg": Json.String(agg),
    "status": Json.String(status_str),
    "value": Json.Null,
    "live_value": Json.Null,
    "scenario_value": Json.Null,
    "delta": Json.Null,
    "format": Json.String("plain"),
    "database_title": Json.Null,
    "property_name": Json.Null,
    "row_count": Json.int(0)
  })
end

fn resolve_metrics_in_store(
  store: Store,
  auth: AuthContext,
  tokens: List(Text),
  scenario_id: Option(Text)
) : Result(Json, AppError)
  if auth.principal.suspended
    return Error(Forbidden(reason: "principal '#{auth.principal.handle}' is suspended"))
  end
  metric_ok = Policy.action_permitted?(auth, "query_db") or Policy.action_permitted?(auth, "read")
  if not metric_ok
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' requires 'read' or 'query_db'"))
  end

  spec_tx_opt = case scenario_id
    Some(sid_raw) if not sid_raw.trim.empty?:
      sid = sid_raw.trim
      pm = case try Table.get(store, Db.proposals_table(), sid).map_error(Db.map_table_error)
        Some(p): p
        None: return Error(Missing(entity: "proposal", id: sid))
      end
      try Policy.require_collection_access(auth, "read", pm.collection_id)
      if pm.status != "open"
        return Error(Conflict(reason: "scenario '#{sid}' is '#{pm.status}', not 'open'"))
      end
      world = case try World.get_world(store, pm.world_id).map_error(Db.map_world_error)
        Some(w): w
        None: return Error(Missing(entity: "world", id: pm.world_id))
      end
      (_base_tx, spec_tx) = try Db.materialize_world_tx(store, world)
      Some(spec_tx)
    Some(_) | None: None
  end

  var live_cache = {}
  var scen_cache = {}
  var out_map = {}
  var seen_tokens = {}

  for raw_tok in tokens
    continue if seen_tokens.get(raw_tok) != None
    seen_tokens = seen_tokens.set(raw_tok, true)
    parsed_refs = Blocks.extract_metric_refs(raw_tok)
    valid_ref_opt = case parsed_refs.first
      Some(mr) if parsed_refs.size == 1 and mr.raw_token == raw_tok.trim: Some(mr)
      Some(_) | None: None
    end
    m = case valid_ref_opt
      Some(x): x
      None:
        out_map = out_map.set(raw_tok, forbidden_metric_json(raw_tok, "", "", "", "invalid_token"))
        continue
    end

    (next_lc, live_opt) = try load_live_db_cached(store, auth, live_cache, m.database_id)
    live_cache = next_lc
    live_data = case live_opt
      Some(ld): ld
      None:
        out_map = out_map.set(
          raw_tok,
          forbidden_metric_json(raw_tok, m.database_id, m.property_id, m.agg, "forbidden")
        )
        continue
    end

    prop = case find_prop_in_def(live_data.def, m.property_id)
      Some(p): p
      None:
        out_map = out_map.set(
          raw_tok,
          Json.Object({
            "token": Json.String(raw_tok),
            "database_id": Json.String(m.database_id),
            "property_id": Json.String(m.property_id),
            "agg": Json.String(m.agg),
            "status": Json.String("missing_property"),
            "value": Json.Null,
            "live_value": Json.Null,
            "scenario_value": Json.Null,
            "delta": Json.Null,
            "format": Json.String("plain"),
            "database_title": Json.String(live_data.def.title),
            "property_name": Json.Null,
            "row_count": Json.int(live_data.rows.size)
          })
        )
        continue
    end

    fmt = metric_format_of_prop(prop.kind)
    live_cells = live_data.rows.map(fn(er) DatabaseModel.effective_cell(er, prop.id) end)
    (live_str_opt, live_dec_opt) = case eval_metric_agg(m.agg, live_cells)
      Ok(pair): pair
      Error(_msg):
        out_map = out_map.set(
          raw_tok,
          Json.Object({
            "token": Json.String(raw_tok),
            "database_id": Json.String(m.database_id),
            "property_id": Json.String(m.property_id),
            "agg": Json.String(m.agg),
            "status": Json.String("invalid_agg"),
            "value": Json.Null,
            "live_value": Json.Null,
            "scenario_value": Json.Null,
            "delta": Json.Null,
            "format": Json.String(fmt),
            "database_title": Json.String(live_data.def.title),
            "property_name": Json.String(prop.name),
            "row_count": Json.int(live_data.rows.size)
          })
        )
        continue
    end

    live_json = case live_str_opt
      Some(s): Json.String(s)
      None: Json.Null
    end

    (val_json, scen_json, delta_json, row_cnt) = case spec_tx_opt
      None: (live_json, Json.Null, Json.Null, live_data.rows.size)
      Some(spec_tx):
        (next_sc, scen_opt) = try load_scen_db_cached(spec_tx, auth, scen_cache, m.database_id)
        scen_cache = next_sc
        case scen_opt
          None: (live_json, Json.Null, Json.Null, live_data.rows.size)
          Some(sdata):
            scen_cells = sdata.rows.map(fn(er) DatabaseModel.effective_cell(er, prop.id) end)
            case eval_metric_agg(m.agg, scen_cells)
              Ok((s_str_opt, s_dec_opt)):
                sj = case s_str_opt
                  Some(s): Json.String(s)
                  None: Json.Null
                end
                dj = case (live_dec_opt, s_dec_opt)
                  (Some(ld), Some(sd)): Json.String((sd - ld).to_text)
                  _: Json.Null
                end
                (sj, sj, dj, sdata.rows.size)
              Error(_): (live_json, Json.Null, Json.Null, sdata.rows.size)
            end
        end
    end

    out_map = out_map.set(
      raw_tok,
      Json.Object({
        "token": Json.String(raw_tok),
        "database_id": Json.String(m.database_id),
        "property_id": Json.String(m.property_id),
        "agg": Json.String(m.agg),
        "status": Json.String("ok"),
        "value": val_json,
        "live_value": live_json,
        "scenario_value": scen_json,
        "delta": delta_json,
        "format": Json.String(fmt),
        "database_title": Json.String(live_data.def.title),
        "property_name": Json.String(prop.name),
        "row_count": Json.int(row_cnt)
      })
    )
  end

  Ok(Json.Object(out_map))
end

fn load_active_principals_json(store: Store) : Result(Json, AppError)
  pr_rows = try Table.scan(store, Db.principals_table(), None, None, 200).map_error(
    Db.map_table_error
  )
  var list_out = []
  for (_pid, pr) in pr_rows
    if not pr.suspended
      list_out = list_out.append(
        Json.Object({
          "id": Json.String(pr.id),
          "handle": Json.String(pr.handle),
          "display_name": Json.String(pr.display_name),
          "kind": pr.kind.to_json,
          "role": pr.role.to_json
        })
      )
    end
  end
  Ok(Json.Array(list_out))
end

fn load_blueprint_relation_targets(
  store: Store,
  auth: AuthContext,
  blueprints: List(BlueprintDef),
  dbs: List(DatabaseDef)
) : Result(Json, AppError)
  var db_by_id = {}
  for d in dbs
    db_by_id = db_by_id.set(d.id, d)
  end
  var rel_map = {}
  var seen_targets = {}
  for bp in blueprints
    for f in bp.fields
      case prop_is_relation_target(f.kind)
        Some(tdb_id):
          if seen_targets.get(tdb_id) == None
            seen_targets = seen_targets.set(tdb_id, true)
            case db_by_id.get(tdb_id)
              Some(tdb) if Policy.collection_permitted?(auth, tdb.collection_id):
                r_pairs = try Table.lookup(
                  store,
                  Db.db_rows_table(),
                  Db.db_rows_by_database(),
                  tdb.id
                ).map_error(Db.map_table_error)
                var opts = []
                for (_rid, tr) in r_pairs
                  if tr.archived_at == None
                    opts = opts.append(
                      Json.Object({
                        "row_id": Json.String(tr.id),
                        "page_id": Json.String(tr.page_id),
                        "title": Json.String(DatabaseModel.extract_row_title(tdb, tr.cells))
                      })
                    )
                  end
                end
                rel_map = rel_map.set(tdb_id, Json.Array(opts))
              Some(_) | None: Unit
            end
          end
        None: Unit
      end
    end
  end
  Ok(Json.Object(rel_map))
end

fn filter_audit_for_page(entries: List(Ledger.AuditEntry), page_id: Text, max_items: Int) : List(
  AuditFeedItem
)
  var matched = []
  for e in entries
    if e.summary.contains?(page_id) or e.reason.contains?(page_id)
      matched = matched.append(audit_entry_to_feed(e))
    end
  end
  n = matched.size
  if n <= max_items
    matched
  else
    matched.drop(n - max_items)
  end
end

fn json_ok(status: Int, body: Json) : Api.Response
  Api.encoded_json_response(status, body).with_header(
    "Content-Type",
    "application/json; charset=utf-8"
  )
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

fn map_file_error(err: FileError) : AppError
  case err
    NotFound(path: p): Missing(entity: "attachment_file", id: p)
    NotAllowed(path: _): Forbidden(reason: err.to_text)
    NotText(path: _) | Failed(path: _, reason: _): ServerFailed(reason: err.to_text)
  end
end

fn dangerous_inline_mime?(ct: Text) : Bool
  lower = ct.trim.ascii_lowercase
  lower.contains?("html") or
    lower.contains?("svg") or
    lower.contains?("xml") or
    lower.contains?("javascript") or
    lower.contains?("ecmascript")
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
  (shared, had_flash?) = try Auth.shared_props_for(req, Some(auth), rf, env)
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
    None: return Auth.guest_redirect_or_401(req, env)
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
    None: return Auth.guest_redirect_or_401(req, env)
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
    None: return Auth.guest_redirect_or_401(req, env)
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

      bp_rows = try Table.scan(store, Db.blueprints_table(), None, None, 200).map_error(
        Db.map_table_error
      )
      bps = bp_rows.map(fn(x) x.1 end)
      page_meta_opt = try Table.get(store, Db.page_meta_table(), page.id).map_error(
        Db.map_table_error
      )
      page_bp_opt = case page_meta_opt
        Some(pm): try Table.get(store, Db.blueprints_table(), pm.blueprint_id).map_error(
          Db.map_table_error
        )
        None: None
      end

      prop_rows = try Table.lookup(store, Db.proposals_table(), Db.proposals_by_page(), page.id)
        .map_error(Db.map_table_error)
      var page_props = []
      for (_pid, pr) in prop_rows
        if Policy.collection_permitted?(a, pr.collection_id)
          page_props = page_props.append(pr)
        end
      end

      all_prop_rows = try Table.scan(store, Db.proposals_table(), None, None, 200).map_error(
        Db.map_table_error
      )
      var scenarios = []
      for (_spid, spr) in all_prop_rows
        if spr.status == "open" and spr.branch_kind == "scenario" and Policy.collection_permitted?(
          a,
          spr.collection_id
        )
          scenarios = scenarios.append(spr)
        end
      end

      principals_json = try load_active_principals_json(store)
      rel_targets_json = try load_blueprint_relation_targets(store, a, bps, d_list)
      metric_tokens = Blocks.blocks_metric_refs(blks).map(fn(m) m.raw_token end)
      metrics_json = try resolve_metrics_in_store(store, a, metric_tokens, None)
      audit_entries = try Ledger.audit_tail_store(store, 200).map_error(Db.map_ledger_error)
      page_audit = filter_audit_for_page(audit_entries, page.id, 25)

      Ok((
        (c_list, d_list, col, page, blks, cmt_rows.map(fn(x) x.1 end), att_rows.map(fn(x) x.1 end)),
        (bps, page_bp_opt, page_meta_opt, page_props, scenarios, page_audit),
        (principals_json, rel_targets_json, metrics_json)
      ))
    end
  )

  (
    (cols, dbs, col, page, blocks, comments, attachments),
    (blueprints, page_bp_opt, page_meta_opt, page_proposals, open_scenarios, page_audit),
    (principals_json, rel_targets_json, resolved_metrics_json)
  ) = page_bundle
  anchored_md = Blocks.to_anchored_markdown(blocks)
  yaml_fm = Blueprints.to_yaml_frontmatter(page, page_bp_opt, page_meta_opt, anchored_md)
  if Auth.wants_json?(req)
    return Ok(
      json_ok(
        200,
        Json.Object({
          "page": page.to_json,
          "collection": col.to_json,
          "blocks": blocks.to_json,
          "anchored_markdown": Json.String(anchored_md),
          "yaml_frontmatter": Json.String(yaml_fm),
          "comments": comments.to_json,
          "attachments": attachments.to_json,
          "blueprints": blueprints.to_json,
          "page_blueprint": page_bp_opt.to_json,
          "page_meta": page_meta_opt.to_json,
          "page_proposals": page_proposals.to_json,
          "principals": principals_json,
          "relation_targets": rel_targets_json,
          "resolved_metrics": resolved_metrics_json,
          "open_scenarios": open_scenarios.to_json,
          "page_audit": page_audit.to_json
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
      "yaml_frontmatter": Json.String(yaml_fm),
      "comments": comments.to_json,
      "attachments": attachments.to_json,
      "blueprints": blueprints.to_json,
      "page_blueprint": page_bp_opt.to_json,
      "page_meta": page_meta_opt.to_json,
      "page_proposals": page_proposals.to_json,
      "principals": principals_json,
      "relation_targets": rel_targets_json,
      "resolved_metrics": resolved_metrics_json,
      "open_scenarios": open_scenarios.to_json,
      "page_audit": page_audit.to_json
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

## `POST /api/attachments/presign` — Issues an AWS SigV4 presigned `PUT` URL (or signed local-disk upload URL in Solo/Personal modes) and records pending metadata in MoDB.
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
  use_local? = try Auth.use_local_attachments(env)
  now = clock.now
  att_id = "att_#{Id.ulid(rng, clock)}"
  clean_name = sanitize_filename_segment(input.filename)
  sha_norm = case input.sha256_hex
    Some(s) if not s.trim.empty?: s.trim.ascii_lowercase
    Some(_) | None: ""
  end
  sha_opt = if sha_norm.empty?: None else: Some(sha_norm)

  (bucket_name, object_key, upload_url, method_str, hdrs_json, expires_at) = if use_local?
    key = try Auth.ensure_app_secret_key(files, rng, env)
    exp_sec = Webhooks.unix_seconds(now) + 900
    local_key = "attachments/#{att_id}/#{clean_name}"
    sig = Auth.local_attachment_sig(key, att_id, exp_sec, input.size_bytes, sha_norm)
    (
      "local",
      local_key,
      "/api/attachments/#{att_id}/upload?exp=#{exp_sec}&sig=#{sig}",
      "PUT",
      Json.Array([Json.Object({"name": Json.String("Content-Type"), "value": Json.String(ct)})]),
      now + 15.minutes
    )
  else
    s3_cfg = try Auth.s3_config(env)
    raw_key = "workspaces/#{Db.default_workspace_id}/pages/#{input.page_id}/#{att_id}/#{clean_name}"
    s3_key = try S3.sanitize_object_key(raw_key).map_error(map_s3_error)
    put_opts = S3.PresignPutOptions(
      expires_seconds: 900,
      content_type: Some(ct),
      content_length: Some(input.size_bytes),
      sha256_hex: sha_opt
    )
    signed = try S3.presign_put(s3_cfg, s3_key, put_opts, now).map_error(map_s3_error)
    hdrs = Json.Array(
      signed.required_headers.map(fn(h)
        Json.Object({"name": Json.String(h.0), "value": Json.String(h.1)})
      end)
    )
    (s3_cfg.bucket, s3_key, signed.url, signed.method, hdrs, signed.expires_at)
  end

  att = Attachment(
    id: att_id,
    workspace_id: Db.default_workspace_id,
    page_id: input.page_id,
    uploaded_by: auth.principal.id,
    filename: input.filename.trim,
    content_type: ct,
    size_bytes: input.size_bytes,
    sha256_hex: sha_norm,
    s3_bucket: bucket_name,
    s3_key: object_key,
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

  Ok(
    json_ok(
      201,
      Json.Object({
        "attachment": saved.to_json,
        "upload_url": Json.String(upload_url),
        "method": Json.String(method_str),
        "required_headers": hdrs_json,
        "expires_at": expires_at.to_json
      })
    )
  )
end

## `PUT /api/attachments/:id/upload` — Accepts HMAC-signed local attachment uploads when S3 is unconfigured (Solo/Personal modes).
fn upload_local_attachment(
  req: Api.Request,
  id: Text,
  files: Files,
  clock: Clock,
  env: Env
) : Result(Api.Response, AppError)
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "attachment", id: id))
  end
  exp_raw = case req.query_param("exp")
    Some(s): s
    None: return Error(Forbidden(reason: "missing exp query parameter"))
  end
  exp_sec = case exp_raw.trim.to_int
    Some(n): n
    None: return Error(Forbidden(reason: "invalid exp query parameter"))
  end
  sig = case req.query_param("sig")
    Some(s) if not s.trim.empty?: s.trim
    Some(_) | None: return Error(Forbidden(reason: "missing sig query parameter"))
  end
  if Webhooks.unix_seconds(clock.now) > exp_sec
    return Error(Forbidden(reason: "signed local upload URL has expired"))
  end
  key = case try Auth.resolve_app_secret_key(files.read_only, env)
    Some(k): k
    None: return Error(Forbidden(reason: "application secret key is uninitialized"))
  end

  att = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      a = case try Table.get(Ledger.store(db), Db.attachments_table(), id).map_error(
        Db.map_table_error
      )
        Some(x): x
        None: return Error(Missing(entity: "attachment", id: id))
      end
      Ok(a)
    end
  )
  if att.s3_bucket != "local"
    return Error(BadInput(reason: "attachment '#{id}' uses S3 object storage, not local upload"))
  end
  if att.status != "pending"
    return Error(Conflict(reason: "attachment '#{id}' is '#{att.status}', not 'pending'"))
  end
  if not Auth.verify_local_attachment_sig(key, att.id, exp_sec, att.size_bytes, att.sha256_hex, sig)
    return Error(Forbidden(reason: "invalid local attachment upload signature"))
  end
  if req.body.size != att.size_bytes or req.body.size > 52428800
    return Error(
      BadInput(reason: "expected #{att.size_bytes} bytes, received #{req.body.size} bytes")
    )
  end
  if not att.sha256_hex.empty?
    actual_sha = Crypto.sha256(req.body).to_hex.bytes
    if not Crypto.constant_time_eq?(actual_sha, att.sha256_hex.ascii_lowercase.bytes)
      return Error(BadInput(reason: "uploaded attachment SHA-256 digest mismatch"))
    end
  end

  try files.make_folder("attachments/#{att.id}").map_error(map_file_error)
  try files.write_bytes(att.s3_key, req.body).map_error(map_file_error)
  Ok(
    json_ok(
      200,
      Json.Object({
        "ok": Json.Boolean(true),
        "attachment_id": Json.String(att.id),
        "size_bytes": Json.int(req.body.size)
      })
    )
  )
end

## `POST /api/attachments/:id/commit` — Marks an uploaded S3 or local-disk attachment `"ready"`.
fn commit_attachment(req: Api.Request, id: Text, auth: AuthContext, files: Files, clock: Clock) : Result(
  Attachment,
  AppError
)
  try Auth.require_session_csrf(req, auth)
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "attachment", id: id))
  end
  upload_action = if Policy.action_permitted?(auth, "upload_attachment")
    "upload_attachment"
  else
    "write_direct"
  end
  pre_att = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      case try Table.get(Ledger.store(db), Db.attachments_table(), id).map_error(Db.map_table_error)
        Some(a): Ok(a)
        None: Error(Missing(entity: "attachment", id: id))
      end
    end
  )
  if pre_att.s3_bucket == "local" and not files.read_only.exists?(pre_att.s3_key)
    return Error(BadInput(reason: "local attachment payload has not been uploaded yet"))
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

## `GET /api/attachments/:id/download` — Enforces collection grant & redirects (`302`) to S3 or serves local file safely.
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

  if att.s3_bucket == "local"
    payload = try rf.read_bytes(att.s3_key).map_error(map_file_error)
    disp = if dangerous_inline_mime?(att.content_type): "attachment" else: "inline"
    safe_name = sanitize_filename_segment(att.filename)
    return Ok(
      Api.response(
        200,
        [
          ("Content-Type", att.content_type),
          ("Content-Disposition", "#{disp}; filename=\"#{safe_name}\""),
          ("Cache-Control", "private, no-store"),
          ("X-Content-Type-Options", "nosniff")
        ],
        payload
      )
    )
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
    None: return Auth.guest_redirect_or_401(req, env)
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
    None: return Auth.guest_redirect_or_401(req, env)
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

fn refresh_semantic_summary_if_stale(
  pid: Text,
  cfg: Ai.AiConfig,
  files: Files,
  clock: Clock,
  net: Network
) : Unit
  prep_res = Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      pg = case try Table.get(store, Db.pages_table(), pid).map_error(Db.map_table_error)
        Some(p) if p.archived_at == None and p.kind == Document: p
        Some(_) | None: return Ok(None)
      end
      s_opt = try Table.get(store, Db.summaries_table(), Db.page_summary_key(pg.id)).map_error(
        Db.map_table_error
      )
      needs_refresh? = case s_opt
        Some(sm): sm.semantic_source_version < pg.version or sm.semantic_summary == None
        None: false
      end
      return Ok(None) if not needs_refresh?
      blks = try Db.load_page_blocks(store, pg.id)
      plain = Blocks.blocks_plain_text(blks)
      Ok(Some((pg.title, pg.version, plain)))
    end
  )
  (title, pg_ver, plain) = case prep_res
    Ok(Some(t)): t
    Ok(None) | Error(_): return Unit
  end
  sem_txt = case Ai.generate_semantic_summary(cfg, title, plain, net)
    Ok(s) if not s.trim.empty?: s.trim
    Ok(_) | Error(_): return Unit
  end
  now = clock.now
  _saved = Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Ledger.WriteMeta(
      principal: "system:jobs",
      action: "page.semantic_summarized",
      reason: "refresh debounced semantic summary for #{pid}",
      at: now
    ),
    "updated semantic summary for #{pid}",
    Json.Object({"page_id": Json.String(pid), "version": Json.int(pg_ver)}),
    Db.map_ledger_error,
    fn(tx)
      skey = Db.page_summary_key(pid)
      case try Table.tx_get(tx, Db.summaries_table(), skey).map_error(Db.map_table_error)
        Some(cur) if cur.semantic_source_version < pg_ver:
          nxt = LivingSummary(
            id: cur.id,
            entity_kind: cur.entity_kind,
            entity_id: cur.entity_id,
            collection_id: cur.collection_id,
            title: cur.title,
            structural_summary: cur.structural_summary,
            semantic_summary: Some(sem_txt),
            headings: cur.headings,
            word_count: cur.word_count,
            open_tasks: cur.open_tasks,
            done_tasks: cur.done_tasks,
            row_count: cur.row_count,
            blueprint_slug: cur.blueprint_slug,
            estimated_tokens: cur.estimated_tokens,
            source_version: cur.source_version,
            semantic_source_version: pg_ver,
            updated_at: now
          )
          t1 = try Table.put(tx, Db.summaries_table(), nxt.id, nxt).map_error(Db.map_table_error)
          Ok((t1, Unit))
        Some(_) | None: Ok((tx, Unit))
      end
    end
  )
  Unit
end

## Periodic `mo serve` job handler draining neural embedding, semantic summaries, + signed webhook jobs and pruning expired MoDB sessions.
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
              case Ai.embed_config(env)
                None: try Jobs.complete(files, Db.ledger_db_path, clock, job.id, job.attempts)
                  .map_error(Db.map_table_error)
                Some(ecfg):
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
                            Document:
                              case try Table.get(store, Db.page_meta_table(), pg.id).map_error(
                                Db.map_table_error
                              )
                                Some(pm):
                                  case try Table.get(
                                    store,
                                    Db.blueprints_table(),
                                    pm.blueprint_id
                                  ).map_error(Db.map_table_error)
                                    Some(bp): Some(Blueprints.page_meta_plain_text(bp, pm))
                                    None: None
                                  end
                                None: None
                              end
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
              case Ai.ai_config(env)
                Ok(ai_cfg): refresh_semantic_summary_if_stale(pid, ai_cfg, files, clock, net)
                Error(_): Unit
              end
          end
        end
        processed += 1
    end
  end
  Ok(Unit)
end

## `GET /api/blueprints` — Lists all Statamic-style Blueprint definitions (`ReadFiles`-only).
fn list_blueprints(_req: Api.Request, auth: AuthContext, rf: ReadFiles) : Result(
  Api.Response,
  AppError
)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Ok(json_ok(200, Json.Object({"blueprints": Json.Array([])})))
  end
  bps = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      rows = try Table.scan(Ledger.store(db), Db.blueprints_table(), None, None, 200).map_error(
        Db.map_table_error
      )
      Ok(rows.map(fn(x) x.1 end))
    end
  )
  Ok(json_ok(200, Json.Object({"blueprints": bps.to_json})))
end

## `POST /api/blueprints` — Creates a new Statamic-style `BlueprintDef` (`manage_schema`).
fn create_blueprint(
  req: Api.Request,
  auth: AuthContext,
  input: CreateBlueprintInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "manage_schema")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'manage_schema'"))
  end

  now = clock.now
  bp = BlueprintDef(
    id: "bp_#{Id.ulid(rng, clock)}",
    slug: input.slug.trim.ascii_lowercase,
    name: input.name.trim,
    description: (input.description or "").trim,
    icon: input.icon,
    fields: input.fields,
    default_template_markdown: input.default_template_markdown or "",
    version: 1
  )
  case Blueprints.validate_blueprint_def(bp)
    Some(msg): return Error(BadInput(reason: msg))
    None: Unit
  end

  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "blueprint.create",
    reason: "create blueprint '#{bp.slug}'",
    at: now
  )
  audit_payload = Json.Object({"blueprint_id": Json.String(bp.id), "slug": Json.String(bp.slug)})
  created = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "created blueprint #{bp.id} (#{bp.slug})",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "manage_schema", now)
      try validate_blueprint_relations_tx(t1, auth, bp)
      t2 = try Table.put(t1, Db.blueprints_table(), bp.id, bp).map_error(Db.map_table_error)
      Ok((t2, bp))
    end
  )
  Ok(json_ok(201, created.to_json))
end

## `PUT /api/blueprints/:id` — Updates an existing `BlueprintDef` (`manage_schema`).
fn update_blueprint(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  input: UpdateBlueprintInput,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "manage_schema")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'manage_schema'"))
  end

  now = clock.now
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "blueprint.update",
    reason: "update blueprint '#{id}'",
    at: now
  )
  audit_payload = Json.Object({"blueprint_id": Json.String(id)})

  updated = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "updated blueprint #{id}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "manage_schema", now)
      old_bp = case try Table.tx_get(t1, Db.blueprints_table(), id).map_error(Db.map_table_error)
        Some(b): b
        None: return Error(Missing(entity: "blueprint", id: id))
      end
      case input.expected_version
        Some(ev) if ev != old_bp.version: return Error(
          Conflict(reason: "expected blueprint version #{ev}, found #{old_bp.version}")
        )
        Some(_) | None: Unit
      end

      next_bp = BlueprintDef(
        id: old_bp.id,
        slug: (input.slug or old_bp.slug).trim.ascii_lowercase,
        name: (input.name or old_bp.name).trim,
        description: (input.description or old_bp.description).trim,
        icon: case input.icon
          Some(ic): Some(ic)
          None: old_bp.icon
        end,
        fields: input.fields or old_bp.fields,
        default_template_markdown: input.default_template_markdown or
          old_bp.default_template_markdown,
        version: old_bp.version + 1
      )
      case Blueprints.validate_blueprint_def(next_bp)
        Some(msg): return Error(BadInput(reason: msg))
        None: Unit
      end
      try validate_blueprint_relations_tx(t1, auth, next_bp)

      existing_metas = try Table.tx_lookup(
        t1,
        Db.page_meta_table(),
        Db.page_meta_by_blueprint(),
        next_bp.id
      ).map_error(Db.map_table_error)
      for (_pid, pm) in existing_metas
        case Blueprints.validate_page_meta(next_bp, pm.values)
          Some(msg): return Error(
            BadInput(reason: "existing page '#{pm.page_id}' invalid under updated blueprint: #{msg}")
          )
          None: Unit
        end
      end

      t2 = try Table.put(t1, Db.blueprints_table(), next_bp.id, next_bp).map_error(
        Db.map_table_error
      )
      Ok((t2, next_bp))
    end
  )
  Ok(json_ok(200, updated.to_json))
end

## `PUT /api/pages/:id/meta` — Attaches, updates, or detaches a `BlueprintDef` + typed metadata on a page.
fn set_page_blueprint_meta(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  input: SetPageMetaInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  now = clock.now
  bp_prefix = Id.ulid(rng, clock)
  reason_opt = case input.reason
    Some(r) if not r.trim.empty?: Some(r.trim)
    Some(_) | None: Some("update page blueprint metadata")
  end
  prov = make_provenance(auth, reason_opt, now)
  idx_job = Jobs.prepare(rng, clock, "vellum.page.indexed", Json.Object({"page_id": Json.String(id)}))
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "page.meta_update",
    reason: reason_opt or "update blueprint metadata on '#{id}'",
    at: now
  )
  audit_payload = Json.Object({
    "page_id": Json.String(id),
    "blueprint_id": input.blueprint_id.to_json
  })

  (next_page, next_blocks, next_bp_opt, next_meta_opt) = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "updated blueprint metadata on #{id}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "write_direct", now)
      old_page = case try Table.tx_get(t1, Db.pages_table(), id).map_error(Db.map_table_error)
        Some(p) if p.archived_at == None: p
        Some(_) | None: return Error(Missing(entity: "page", id: id))
      end
      if old_page.kind != Document
        return Error(BadInput(reason: "blueprints are only supported on Document pages"))
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

      (t2, out_blocks, bp_opt, pm_opt) = case input.blueprint_id
        None:
          cleaned = case try Table.tx_get(t1, Db.page_meta_table(), id).map_error(
            Db.map_table_error
          )
            Some(_): try Table.delete(t1, Db.page_meta_table(), id).map_error(Db.map_table_error)
            None: t1
          end
          (cleaned, existing_blocks, None, None)
        Some(raw_bid):
          bid = raw_bid.trim
          bp = case try Table.tx_get(t1, Db.blueprints_table(), bid).map_error(Db.map_table_error)
            Some(b): b
            None: return Error(Missing(entity: "blueprint", id: bid))
          end
          vals = input.values or {}
          case Blueprints.validate_page_meta(bp, vals)
            Some(msg): return Error(BadInput(reason: msg))
            None: Unit
          end
          try validate_meta_relations_tx(t1, auth, bp, vals)
          pm = PageBlueprintMeta(page_id: id, blueprint_id: bp.id, values: vals, updated_at: now)
          t_pm = try Table.put(t1, Db.page_meta_table(), id, pm).map_error(Db.map_table_error)
          apply_tpl? = input.apply_template_if_empty or false
          tpl_blocks = if apply_tpl? and existing_blocks.empty? and not bp.default_template_markdown
            .trim
            .empty?
            reconcile_markdown_blocks(id, [], bp.default_template_markdown, prov, bp_prefix)
          else
            existing_blocks
          end
          (t_pm, tpl_blocks, Some(bp), Some(pm))
      end

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
      t3 = try Db.tx_save_page_and_blocks(t2, bumped_page, out_blocks)
      (t4, _jid) = try Jobs.tx_put(t3, idx_job).map_error(Db.map_table_error)
      Ok((t4, (bumped_page, out_blocks, bp_opt, pm_opt)))
    end
  )

  anchored_md = Blocks.to_anchored_markdown(next_blocks)
  yaml_fm = Blueprints.to_yaml_frontmatter(next_page, next_bp_opt, next_meta_opt, anchored_md)
  meta_ev = Json.Object({
    "page_id": Json.String(next_page.id),
    "collection_id": Json.String(next_page.collection_id),
    "version": Json.int(next_page.version),
    "actor": Json.String(auth.principal.handle)
  })
  Ok(
    json_ok(
      200,
      Json.Object({
        "page": next_page.to_json,
        "blocks": next_blocks.to_json,
        "page_blueprint": next_bp_opt.to_json,
        "page_meta": next_meta_opt.to_json,
        "anchored_markdown": Json.String(anchored_md),
        "yaml_frontmatter": Json.String(yaml_fm)
      })
    ).with_sse_publish_json("page:#{next_page.id}", "page.meta_updated", meta_ev)
      .with_sse_publish_json("collection:#{next_page.collection_id}", "page.meta_updated", meta_ev)
  )
end

## `PUT /api/pages/:id/markdown` — Reconciles anchored Markdown back into canonical blocks while preserving unchanged IDs/provenance.
fn sync_page_markdown(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  input: SyncPageMarkdownInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  now = clock.now
  id_prefix = Id.ulid(rng, clock)
  reason_opt = case input.reason
    Some(r) if not r.trim.empty?: Some(r.trim)
    Some(_) | None: Some("markdown sync on #{id}")
  end
  prov = make_provenance(auth, reason_opt, now)
  idx_job = Jobs.prepare(rng, clock, "vellum.page.indexed", Json.Object({"page_id": Json.String(id)}))
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "page.sync_markdown",
    reason: reason_opt or "sync markdown on '#{id}'",
    at: now
  )
  audit_payload = Json.Object({
    "page_id": Json.String(id),
    "expected_page_version": Json.int(input.expected_page_version)
  })

  (next_page, next_blocks, page_bp_opt, page_meta_opt) = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "synced markdown on #{id}",
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
      if old_page.version != input.expected_page_version
        return Error(
          Conflict(
            reason: "expected page version #{input.expected_page_version}, found #{old_page.version}"
          )
        )
      end

      existing_rows = try Table.tx_lookup(t1, Db.blocks_table(), Db.blocks_by_page(), id).map_error(
        Db.map_table_error
      )
      existing_blocks = Blocks.sort_blocks(existing_rows.map(fn(x) x.1 end))
      reconciled = reconcile_markdown_blocks(id, existing_blocks, input.markdown, prov, id_prefix)

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
      t2 = try Db.tx_save_page_and_blocks(t1, bumped_page, reconciled)
      (t3, _jid) = try Jobs.tx_put(t2, idx_job).map_error(Db.map_table_error)
      pm_opt = try Table.tx_get(t3, Db.page_meta_table(), id).map_error(Db.map_table_error)
      bp_opt = case pm_opt
        Some(pm): try Table.tx_get(t3, Db.blueprints_table(), pm.blueprint_id).map_error(
          Db.map_table_error
        )
        None: None
      end
      Ok((t3, (bumped_page, reconciled, bp_opt, pm_opt)))
    end
  )

  anchored_md = Blocks.to_anchored_markdown(next_blocks)
  yaml_fm = Blueprints.to_yaml_frontmatter(next_page, page_bp_opt, page_meta_opt, anchored_md)
  blocks_ev = Json.Object({
    "page_id": Json.String(next_page.id),
    "collection_id": Json.String(next_page.collection_id),
    "version": Json.int(next_page.version),
    "actor": Json.String(auth.principal.handle),
    "reason": Json.String(reason_opt or "sync markdown")
  })
  Ok(
    json_ok(
      200,
      Json.Object({
        "page": next_page.to_json,
        "blocks": next_blocks.to_json,
        "anchored_markdown": Json.String(anchored_md),
        "yaml_frontmatter": Json.String(yaml_fm)
      })
    ).with_sse_publish_json("page:#{next_page.id}", "page.blocks_updated", blocks_ev)
      .with_sse_publish_json("collection:#{next_page.collection_id}", "page.blocks_updated", blocks_ev)
  )
end

## `POST /api/metrics/resolve` — Evaluates `{{metric:<db>.<prop>:<agg>}}` tokens (fail-closed per DB ACL, with optional What-If Scenario diff).
fn resolve_metrics(
  req: Api.Request,
  auth: AuthContext,
  input: ResolveMetricsInput,
  rf: ReadFiles
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if auth.principal.suspended
    return Error(Forbidden(reason: "principal '#{auth.principal.handle}' is suspended"))
  end
  metric_ok = Policy.action_permitted?(auth, "query_db") or Policy.action_permitted?(auth, "read")
  if not metric_ok
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' requires 'read' or 'query_db'"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Ok(
      json_ok(
        200,
        Json.Object({"metrics": Json.Object({}), "scenario_id": input.scenario_id.to_json})
      )
    )
  end
  metrics_json = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db) resolve_metrics_in_store(Ledger.store(db), auth, input.tokens, input.scenario_id) end
  )
  Ok(
    json_ok(
      200,
      Json.Object({"metrics": metrics_json, "scenario_id": input.scenario_id.to_json})
    )
  )
end

## `GET /api/blocks/:block_id` — Returns a block with parent page context, neighbors, blueprint metadata, and block comments (`ReadFiles`-only, collection-gated).
fn show_block_context(_req: Api.Request, block_id: Text, auth: AuthContext, rf: ReadFiles) : Result(
  Api.Response,
  AppError
)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "block", id: block_id))
  end

  payload = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      blk = case try Table.get(store, Db.blocks_table(), block_id).map_error(Db.map_table_error)
        Some(b): b
        None: return Error(Missing(entity: "block", id: block_id))
      end
      page = case try Table.get(store, Db.pages_table(), blk.page_id).map_error(Db.map_table_error)
        Some(p) if p.archived_at == None: p
        Some(_) | None: return Error(Missing(entity: "block", id: block_id))
      end
      try Policy.require_collection_access(auth, "read", page.collection_id)
      col = case try Table.get(store, Db.collections_table(), page.collection_id).map_error(
        Db.map_table_error
      )
        Some(c): c
        None: return Error(Missing(entity: "collection", id: page.collection_id))
      end
      blks = try Db.load_page_blocks(store, page.id)
      var prev_blk = None
      var next_blk = None
      var found_idx = -1
      var i = 0
      while i < blks.size
        case blks.get(i)
          Some(sb) if sb.id == blk.id:
            found_idx = i
            break
          Some(_) | None: i += 1
        end
      end
      if found_idx > 0
        prev_blk = blks.get(found_idx - 1)
      end
      if found_idx >= 0 and found_idx + 1 < blks.size
        next_blk = blks.get(found_idx + 1)
      end

      pm_opt = try Table.get(store, Db.page_meta_table(), page.id).map_error(Db.map_table_error)
      bp_opt = case pm_opt
        Some(pm): try Table.get(store, Db.blueprints_table(), pm.blueprint_id).map_error(
          Db.map_table_error
        )
        None: None
      end
      cmt_rows = try Table.lookup(store, Db.comments_table(), Db.comments_by_page(), page.id)
        .map_error(Db.map_table_error)
      var blk_cmts = []
      for (_cid, c) in cmt_rows
        if c.block_id == Some(blk.id)
          blk_cmts = blk_cmts.append(c)
        end
      end

      Ok(
        Json.Object({
          "block": blk.to_json,
          "page": page.to_json,
          "collection": col.to_json,
          "prev_block": prev_blk.to_json,
          "next_block": next_blk.to_json,
          "page_blueprint": bp_opt.to_json,
          "page_meta": pm_opt.to_json,
          "comments": blk_cmts.to_json
        })
      )
    end
  )
  Ok(json_ok(200, payload))
end
