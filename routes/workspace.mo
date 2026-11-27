## Vellum workspace, collection, canonical block-tree, search, attachment, and admin handlers.
module Routes.Workspace
expose CreateCollectionInput(..),
CreatePageInput(..),
UpdatePageInput(..),
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
page_backlinks,
create_page,
update_page,
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
validate_meta_relations_tx,
drain_jobs,
erasure_status,
purge_secret,
download_erasure_receipt,
grants_tree,
kill_all_agent_grants
use Api
use Arvo.Flash
use Arvo.Id
use Arvo.Inertia
use Arvo.Modb.Jobs
use Arvo.Modb.Sessions
use Arvo.S3
use Arvo.Webhooks
use ChatOps
use Crypto
use Db
use ErasureOps
use Domain.Blocks
use Domain.Blueprints{BlueprintDef, PageBlueprintMeta}
use Domain.Collab{WebhookJobPayload}
use Domain.DatabaseModel{
  AiOutputKind,
  CellValue,
  DatabaseDef,
  EnrichedRow,
  PropertyDef,
  PropertyKind,
  RollupAgg,
  decode_cell_map_json,
  decode_property_defs_json
}
use Domain.Packs{LivingSummary}
use Domain.Policy
use Domain.TaintBridge
use Domain.Types{
  AgentToken,
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
use VaultOps

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

## JSON payload for `PATCH /api/pages/:id`.
struct UpdatePageInput
  title: Option(Text)
  parent_page_id: Option(Text)
  clear_parent: Option(Bool)
  icon: Option(Text)
  cover_attachment_id: Option(Text)
  clear_cover: Option(Bool)
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
    ) | Status(options: _, done_option_ids: _) | Checkbox | Person | Email | FileList | Url | UniqueId(
      prefix: _
    ) | Formula(expression: _, format: _) | CreatedTime | CreatedBy | LastEditedTime | LastEditedBy | Rollup(
      relation_prop_id: _,
      target_prop_id: _,
      agg: _
    ) | AiDerived(
      prompt: _,
      source_prop_ids: _,
      include_row_body: _,
      output_kind: _,
      mode: _,
      daily_call_cap: _
    ): None
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
  if existing_blocks.empty?
    var out = []
    for (idx, p) in parsed.enumerate
      seq = idx + 1
      out = out.append(
        Block(
          id: "blk_#{id_prefix}_#{zero_pad4_int(seq)}",
          page_id: page_id,
          parent_block_id: None,
          rank: "i#{zero_pad4_int(seq)}",
          kind: p.kind,
          markdown: p.markdown,
          provenance: prov,
          version: 1
        )
      )
    end
    return out
  end

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
        ) | FilesVal(attachment_ids: _) | UrlVal(_) | RelationVal(row_ids: _): Ok((None, None))
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
          ) | BoolVal(_) | PrincipalVal(_) | FilesVal(attachment_ids: _) | UrlVal(_) | RelationVal(
            row_ids: _
          ): Unit
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
    Formula(expression: _, format: f): if f.empty?: "plain" else: f
    Rollup(relation_prop_id: _, target_prop_id: _, agg: agg):
      case agg
        PercentPerGroup: "percent_fraction"
        CountAll | CountValues | SumValues | MinValue | MaxValue: "plain"
      end
    AiDerived(
      prompt: _,
      source_prop_ids: _,
      include_row_body: _,
      output_kind: AiNumber(format: f),
      mode: _,
      daily_call_cap: _
    ): f
    Title | RichText | DateProp(include_time: _) | Select(options: _) | MultiSelect(options: _) | Status(
      options: _,
      done_option_ids: _
    ) | Checkbox | Person | Email | FileList | Url | UniqueId(prefix: _) | CreatedTime | CreatedBy | LastEditedTime | LastEditedBy | Relation(
      target_db_id: _,
      inverse_prop_id: _
    ) | AiDerived(
      prompt: _,
      source_prop_ids: _,
      include_row_body: _,
      output_kind: _,
      mode: _,
      daily_call_cap: _
    ): "plain"
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

  home_json = if not rf.exists?(Db.ledger_db_path)
    Json.Object({
      "collections": Json.Array([]),
      "databases": Json.Array([]),
      "pages": Json.Array([]),
      "audit_feed": Json.Array([])
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
        Ok(
          Json.Object({
            "collections": c_list.to_json,
            "databases": d_list.to_json,
            "pages": visible_pages.to_json,
            "audit_feed": feed.to_json
          })
        )
      end
    )
  end
  cols_json = home_json.get("collections") or Json.Array([])
  dbs_json = home_json.get("databases") or Json.Array([])
  pages_json = home_json.get("pages") or Json.Array([])
  feed_json = home_json.get("audit_feed") or Json.Array([])

  if Auth.wants_json?(req)
    return Ok(
      json_ok(
        200,
        Json.Object({
          "collections": cols_json,
          "databases": dbs_json,
          "pages": pages_json,
          "audit_feed": feed_json
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
      "collections": cols_json,
      "databases": dbs_json,
      "pages": pages_json,
      "audit_feed": feed_json
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

  col_payload = try Ledger.read_locked(
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
      Ok(
        Json.Object({
          "collections": c_list.to_json,
          "databases": d_list.to_json,
          "collection": col.to_json,
          "pages": active_pages.to_json
        })
      )
    end
  )

  if Auth.wants_json?(req)
    return Ok(
      json_ok(
        200,
        Json.Object({
          "collection": col_payload.get("collection") or Json.Null,
          "pages": col_payload.get("pages") or Json.Null
        })
      )
    )
  end
  render_inertia_page(
    req,
    a,
    rf,
    env,
    "Workspace/Collection",
    {
      "collections": col_payload.get("collections") or Json.Null,
      "databases": col_payload.get("databases") or Json.Null,
      "collection": col_payload.get("collection") or Json.Null,
      "pages": col_payload.get("pages") or Json.Null
    }
  )
end

## `POST /api/collections` — Creates a new collection (requires `manage_schema`).
fn create_collection(
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  wp_raw = try VaultOps.req_text(rj, "write_policy")
  wp = if wp_raw == "direct_with_audit"
    DirectWithAudit
  else if wp_raw == "proposals_required_for_agents"
    ProposalsRequiredForAgents
  else if wp_raw == "proposals_required_for_all"
    ProposalsRequiredForAll
  else
    return Error(BadInput(reason: "invalid write_policy '#{wp_raw}'"))
  end
  input = CreateCollectionInput(
    slug: try VaultOps.req_text(rj, "slug"),
    name: try VaultOps.req_text(rj, "name"),
    description: rj.text_at("description"),
    icon: rj.text_at("icon"),
    write_policy: wp,
    freshness_ttl_days: rj.int_at("freshness_ttl_days")
  )
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
  try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "created collection #{col.slug}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "manage_schema", now)
      t2 = try Db.tx_put_collection(t1, col)
      Ok((t2, Unit))
    end
  )
  Ok(json_ok(201, col.to_json))
end

## `GET /p/:id` and `GET /api/pages/:id` — Loads page, sorted blocks, anchored Markdown, comments, and attachments.
fn show_page(
  req: Api.Request,
  id: Text,
  auth: Option(AuthContext),
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env
) : Result(
  Api.Response,
  AppError
)
  a = case auth
    Some(x): x
    None: return Auth.guest_redirect_or_401(req, env)
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "page", id: id))
  end

  page_bundle = try Ledger.read_locked(
    files.read_only,
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
      citation_drifts = try Db.detect_page_citation_drifts(store, Some(a), page, blks)
      (explicit_backlinks, semantic_backlinks) = try Db.compute_page_backlinks(
        store,
        a,
        page,
        blks,
        6
      )
      page_prov_opt = try TaintBridge.get_provenance_info(store, "vlm_pages", page.id)
      var block_taints = {}
      var untrusted_block_ids = []
      for blk in blks
        case try TaintBridge.get_provenance_info(store, "vlm_blocks", blk.id)
          Some((tr, w, at)):
            block_taints = block_taints.set(
              blk.id,
              Json.Object({
                "trust": Json.String(tr),
                "writer": Json.String(w),
                "updated_at": at.to_json
              })
            )
            if tr == "untrusted"
              untrusted_block_ids = untrusted_block_ids.append(blk.id)
            end
          None: Unit
        end
      end
      page_trust = case page_prov_opt
        Some((tr, _w, _at)): tr
        None: if untrusted_block_ids.empty?: "trusted" else: "untrusted"
      end
      taint_provenance_json = Json.Object({
        "trust": Json.String(page_trust),
        "page": case page_prov_opt
          Some((tr, w, at)): Json.Object({
            "trust": Json.String(tr),
            "writer": Json.String(w),
            "updated_at": at.to_json
          })
          None: Json.Null
        end,
        "blocks": Json.Object(block_taints),
        "untrusted_block_ids": untrusted_block_ids.to_json
      })
      cmt_list = cmt_rows.map(fn(x) x.1 end)
      att_list = att_rows.map(fn(x) x.1 end)
      secret_hints = ErasureOps.scan_page_secret_hints(store, page, blks, cmt_list)
      anchored_md = Blocks.to_anchored_markdown(blks)
      yaml_fm = Blueprints.to_yaml_frontmatter(page, page_bp_opt, page_meta_opt, anchored_md)
      vault_pol = (try VaultOps.get_vault_policy_json(store, page.collection_id)) or VaultOps
        .default_vault_policy_json(page.collection_id)

      Ok(
        Json.Object({
          "collections": c_list.to_json,
          "databases": d_list.to_json,
          "collection": col.to_json,
          "collection_security": vault_pol,
          "page": page.to_json,
          "blocks": blks.to_json,
          "anchored_markdown": Json.String(anchored_md),
          "yaml_frontmatter": Json.String(yaml_fm),
          "comments": cmt_list.to_json,
          "attachments": att_list.to_json,
          "blueprints": bps.to_json,
          "page_blueprint": page_bp_opt.to_json,
          "page_meta": page_meta_opt.to_json,
          "page_proposals": page_props.to_json,
          "principals": principals_json,
          "relation_targets": rel_targets_json,
          "resolved_metrics": metrics_json,
          "open_scenarios": scenarios.to_json,
          "page_audit": page_audit.to_json,
          "citation_drifts": citation_drifts.to_json,
          "explicit_backlinks": explicit_backlinks.to_json,
          "semantic_backlinks": semantic_backlinks.to_json,
          "taint_provenance": taint_provenance_json,
          "secret_hints": Json.Array(secret_hints)
        })
      )
    end
  )

  if (page_bundle.get("collection_security") or Json.Null).text_at("security_tier") == Some(
    "ferpa_restricted"
  )
    ferpa_cid = (page_bundle.get("collection") or Json.Null).text_at("id") or ""
    try VaultOps.record_ferpa_read_audit_locked(
      files,
      rng,
      clock,
      a,
      "ferpa.page.viewed",
      ferpa_cid,
      "page",
      id,
      "FERPA vault page view"
    )
  end

  if Auth.wants_json?(req)
    return Ok(
      json_ok(
        200,
        Json.Object({
          "page": page_bundle.get("page") or Json.Null,
          "collection": page_bundle.get("collection") or Json.Null,
          "collection_security": page_bundle.get("collection_security") or Json.Null,
          "blocks": page_bundle.get("blocks") or Json.Null,
          "anchored_markdown": page_bundle.get("anchored_markdown") or Json.Null,
          "yaml_frontmatter": page_bundle.get("yaml_frontmatter") or Json.Null,
          "comments": page_bundle.get("comments") or Json.Null,
          "attachments": page_bundle.get("attachments") or Json.Null,
          "blueprints": page_bundle.get("blueprints") or Json.Null,
          "page_blueprint": page_bundle.get("page_blueprint") or Json.Null,
          "page_meta": page_bundle.get("page_meta") or Json.Null,
          "page_proposals": page_bundle.get("page_proposals") or Json.Null,
          "principals": page_bundle.get("principals") or Json.Null,
          "relation_targets": page_bundle.get("relation_targets") or Json.Null,
          "resolved_metrics": page_bundle.get("resolved_metrics") or Json.Null,
          "open_scenarios": page_bundle.get("open_scenarios") or Json.Null,
          "page_audit": page_bundle.get("page_audit") or Json.Null,
          "citation_drifts": page_bundle.get("citation_drifts") or Json.Null,
          "explicit_backlinks": page_bundle.get("explicit_backlinks") or Json.Null,
          "semantic_backlinks": page_bundle.get("semantic_backlinks") or Json.Null,
          "taint_provenance": page_bundle.get("taint_provenance") or Json.Null,
          "secret_hints": page_bundle.get("secret_hints") or Json.Null
        })
      )
    )
  end

  render_inertia_page(
    req,
    a,
    files.read_only,
    env,
    "Workspace/Page",
    {
      "collections": page_bundle.get("collections") or Json.Null,
      "databases": page_bundle.get("databases") or Json.Null,
      "collection": page_bundle.get("collection") or Json.Null,
      "collection_security": page_bundle.get("collection_security") or Json.Null,
      "page": page_bundle.get("page") or Json.Null,
      "blocks": page_bundle.get("blocks") or Json.Null,
      "anchored_markdown": page_bundle.get("anchored_markdown") or Json.Null,
      "yaml_frontmatter": page_bundle.get("yaml_frontmatter") or Json.Null,
      "comments": page_bundle.get("comments") or Json.Null,
      "attachments": page_bundle.get("attachments") or Json.Null,
      "blueprints": page_bundle.get("blueprints") or Json.Null,
      "page_blueprint": page_bundle.get("page_blueprint") or Json.Null,
      "page_meta": page_bundle.get("page_meta") or Json.Null,
      "page_proposals": page_bundle.get("page_proposals") or Json.Null,
      "principals": page_bundle.get("principals") or Json.Null,
      "relation_targets": page_bundle.get("relation_targets") or Json.Null,
      "resolved_metrics": page_bundle.get("resolved_metrics") or Json.Null,
      "open_scenarios": page_bundle.get("open_scenarios") or Json.Null,
      "page_audit": page_bundle.get("page_audit") or Json.Null,
      "citation_drifts": page_bundle.get("citation_drifts") or Json.Null,
      "explicit_backlinks": page_bundle.get("explicit_backlinks") or Json.Null,
      "semantic_backlinks": page_bundle.get("semantic_backlinks") or Json.Null,
      "taint_provenance": page_bundle.get("taint_provenance") or Json.Null,
      "secret_hints": page_bundle.get("secret_hints") or Json.Null
    }
  )
end

## `GET /api/pages/:id/backlinks` — Returns grant-filtered explicit (`PageLink`/`Citation`) and
## semantic (`Modb.Vec`) backlinks pointing to page `id`.
fn page_backlinks(req: Api.Request, id: Text, auth: AuthContext, rf: ReadFiles) : Result(
  Api.Response,
  AppError
)
  if not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "page", id: id))
  end
  lim = case req.query_param("limit")
    Some(s): s.trim.to_int or 8
    None: 8
  end
  payload = try Ledger.read_locked(
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
      try Policy.require_collection_access(auth, "read", page.collection_id)
      blks = try Db.load_page_blocks(store, page.id)
      (exp, sem) = try Db.compute_page_backlinks(store, auth, page, blks, lim)
      Ok(
        Json.Object({
          "page_id": Json.String(page.id),
          "explicit_backlinks": exp.to_json,
          "semantic_backlinks": sem.to_json
        })
      )
    end
  )
  Ok(json_ok(200, payload))
end

## `POST /api/pages` — Creates a page with canonical blocks and BM25 FTS indexing.
fn create_page(
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  input = CreatePageInput(
    collection_id: try VaultOps.req_text(rj, "collection_id"),
    parent_page_id: rj.text_at("parent_page_id"),
    title: try VaultOps.req_text(rj, "title"),
    markdown: try VaultOps.req_text(rj, "markdown"),
    icon: rj.text_at("icon"),
    freshness_ttl_days: rj.int_at("freshness_ttl_days"),
    reason: rj.text_at("reason")
  )
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
  try Ledger.transact_locked(
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
      Ok((t3, Unit))
    end
  )

  page_ev = Json.Object({
    "page_id": Json.String(page.id),
    "collection_id": Json.String(page.collection_id),
    "title": Json.String(page.title),
    "actor": Json.String(auth.principal.handle)
  })
  Ok(
    json_ok(
      201,
      Json.Object({
        "page": page.to_json,
        "blocks": blocks.to_json,
        "anchored_markdown": Json.String(Blocks.to_anchored_markdown(blocks))
      })
    ).with_sse_publish_json("collection:#{page.collection_id}", "page.created", page_ev)
  )
end

fn validate_page_parent_tx(tx: WriteTx, page_id: Text, col_id: Text, parent_id: Text) : Result(
  Unit,
  AppError
)
  clean_pid = parent_id.trim
  if clean_pid.empty?
    return Error(BadInput(reason: "parent_page_id must not be empty"))
  end
  if clean_pid == page_id
    return Error(BadInput(reason: "page '#{page_id}' cannot be its own parent"))
  end
  var cur_opt = Some(clean_pid)
  var hops = 0
  while hops < 64
    cid = case cur_opt
      Some(x): x
      None: return Ok(Unit)
    end
    if cid == page_id
      return Error(BadInput(reason: "parent_page_id '#{clean_pid}' would create a cycle"))
    end
    par = case try Table.tx_get(tx, Db.pages_table(), cid).map_error(Db.map_table_error)
      Some(p) if p.archived_at == None: p
      Some(_) | None:
        if hops == 0
          return Error(Missing(entity: "parent_page", id: clean_pid))
        else
          return Ok(Unit)
        end
    end
    if hops == 0 and par.collection_id != col_id
      return Error(BadInput(reason: "parent_page_id must belong to same collection"))
    end
    cur_opt = par.parent_page_id
    hops += 1
  end
  Error(BadInput(reason: "page nesting exceeds maximum depth (64)"))
end

## `PATCH /api/pages/:id` — Updates page title, icon, parent hierarchy (acyclic), or cover attachment.
fn update_page(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  input = UpdatePageInput(
    title: rj.text_at("title"),
    parent_page_id: rj.text_at("parent_page_id"),
    clear_parent: rj.bool_at("clear_parent"),
    icon: rj.text_at("icon"),
    cover_attachment_id: rj.text_at("cover_attachment_id"),
    clear_cover: rj.bool_at("clear_cover"),
    reason: rj.text_at("reason")
  )
  case input.title
    Some(t) if t.trim.empty?: return Error(BadInput(reason: "page title must not be empty"))
    Some(_) | None: Unit
  end

  now = clock.now
  idx_job = Jobs.prepare(rng, clock, "vellum.page.indexed", Json.Object({"page_id": Json.String(id)}))
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "page.update",
    reason: input.reason or "update page '#{id}'",
    at: now
  )
  audit_payload = Json.Object({"page_id": Json.String(id)})

  upd_json = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "updated page #{id}",
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
            reason: "collection '#{col.slug}' write policy prohibits direct writes by this principal"
          )
        )
      end

      next_parent = if input.clear_parent == Some(true)
        None
      else
        case input.parent_page_id
          Some(pid):
            try validate_page_parent_tx(t1, old_page.id, old_page.collection_id, pid)
            Some(pid.trim)
          None: old_page.parent_page_id
        end
      end

      next_cover = if input.clear_cover == Some(true)
        None
      else
        case input.cover_attachment_id
          Some(raw_aid):
            aid = raw_aid.trim
            if aid.empty?
              None
            else
              att = case try Table.tx_get(t1, Db.attachments_table(), aid).map_error(
                Db.map_table_error
              )
                Some(a): a
                None: return Error(Missing(entity: "attachment", id: aid))
              end
              att_pg = case try Table.tx_get(t1, Db.pages_table(), att.page_id).map_error(
                Db.map_table_error
              )
                Some(p) if p.archived_at == None: p
                Some(_) | None: return Error(Missing(entity: "page", id: att.page_id))
              end
              if att_pg.collection_id != old_page.collection_id
                return Error(
                  BadInput(reason: "cover_attachment_id must belong to the same collection")
                )
              end
              if att.status != "ready"
                return Error(BadInput(reason: "cover_attachment_id must be committed ('ready')"))
              end
              Some(aid)
            end
          None: old_page.cover_attachment_id
        end
      end

      next_title = case input.title
        Some(t): t.trim
        None: old_page.title
      end
      next_icon = case input.icon
        Some(ic):
          trimmed = ic.trim
          if trimmed.empty?: None else: Some(trimmed)
        None: old_page.icon
      end

      updated_page = Page(
        id: old_page.id,
        collection_id: old_page.collection_id,
        parent_page_id: next_parent,
        title: next_title,
        icon: next_icon,
        cover_attachment_id: next_cover,
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
      existing_rows = try Table.tx_lookup(t1, Db.blocks_table(), Db.blocks_by_page(), old_page.id)
        .map_error(Db.map_table_error)
      existing_blocks = Blocks.sort_blocks(existing_rows.map(fn(x) x.1 end))
      t2 = try Db.tx_save_page_and_blocks(t1, updated_page, existing_blocks)
      (t3, _jid) = try Jobs.tx_put(t2, idx_job).map_error(Db.map_table_error)
      Ok((
        t3,
        Json.Object({
          "page": updated_page.to_json,
          "collection_id": Json.String(updated_page.collection_id),
          "version": Json.int(updated_page.version),
          "title": Json.String(updated_page.title)
        })
      ))
    end
  )

  p_col_id = upd_json.text_at("collection_id") or ""
  p_ver = upd_json.int_at("version") or 1
  p_title = upd_json.text_at("title") or ""
  upd_ev = Json.Object({
    "page_id": Json.String(id),
    "collection_id": Json.String(p_col_id),
    "version": Json.int(p_ver),
    "title": Json.String(p_title),
    "actor": Json.String(auth.principal.handle)
  })
  Ok(
    json_ok(200, Json.Object({"page": upd_json.get("page") or Json.Null}))
      .with_sse_publish_json("page:#{id}", "page.updated", upd_ev)
      .with_sse_publish_json("collection:#{p_col_id}", "page.updated", upd_ev)
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
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  ops_in = case rj.get("ops")
    None: return Error(BadInput(reason: "missing 'ops' array"))
    Some(oj): try Blocks.decode_block_ops_json(oj.to_text.bytes).map_error(fn(e)
      BadInput(reason: "invalid 'ops': #{e}")
    end)
  end
  exp_in = case rj.get("expected_versions")
    None | Some(Json.Null): {}
    Some(ej): try Blocks.decode_version_map_json(ej.to_text.bytes).map_error(fn(e)
      BadInput(reason: "invalid 'expected_versions': #{e}")
    end)
  end
  input = PatchBlocksInput(
    ops: ops_in,
    expected_versions: exp_in,
    reason: rj.text_at("reason")
  )
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
  patch_sid = case req.header("X-Taint-Session")
    Some(s) if not s.trim.empty?: Some(s.trim)
    Some(_) | None: if auth.principal.kind == Agent: Some("agent:#{auth.grant_id}") else: None
  end
  case patch_sid
    Some(sid):
      if files.read_only.exists?(Db.ledger_db_path)
        sess_opt = try Ledger.read_locked(
          files.read_only,
          Db.ledger_db_path,
          Db.vellum_schema(),
          Db.map_ledger_error,
          fn(db) TaintBridge.get_taint_session(Ledger.store(db), sid) end
        )
        case sess_opt
          Some(_):
            _auth_sess = try TaintBridge.authorize_action_locked(
              files,
              Db.ledger_db_path,
              Db.vellum_schema(),
              sid,
              "page.write_direct",
              now
            )
          None: Unit
        end
      end
    None: Unit
  end
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

  patch_json = try Ledger.transact_locked(
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
      Ok((
        t3,
        Json.Object({
          "page": bumped_page.to_json,
          "blocks": updated_blocks.to_json,
          "anchored_markdown": Json.String(Blocks.to_anchored_markdown(updated_blocks)),
          "collection_id": Json.String(bumped_page.collection_id),
          "version": Json.int(bumped_page.version)
        })
      ))
    end
  )

  p_col_id = patch_json.text_at("collection_id") or ""
  p_ver = patch_json.int_at("version") or 1
  blocks_ev = Json.Object({
    "page_id": Json.String(id),
    "collection_id": Json.String(p_col_id),
    "version": Json.int(p_ver),
    "actor": Json.String(auth.principal.handle),
    "reason": Json.String((input.reason or "update blocks").trim)
  })
  Ok(
    json_ok(
      200,
      Json.Object({
        "page": patch_json.get("page") or Json.Null,
        "blocks": patch_json.get("blocks") or Json.Null,
        "anchored_markdown": patch_json.get("anchored_markdown") or Json.Null
      })
    ).with_sse_publish_json("page:#{id}", "page.blocks_updated", blocks_ev)
      .with_sse_publish_json("collection:#{p_col_id}", "page.blocks_updated", blocks_ev)
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
    rj = try VaultOps.parse_req_json_obj(req.text)
    rj.int_at("freshness_ttl_days")
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

  upd_json = try Ledger.transact_locked(
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
      t2 = try Db.tx_put_page_row(t1, next_p)
      Ok((
        t2,
        Json.Object({
          "page": next_p.to_json,
          "collection_id": Json.String(next_p.collection_id),
          "version": Json.int(next_p.version)
        })
      ))
    end
  )
  v_col_id = upd_json.text_at("collection_id") or ""
  v_ver = upd_json.int_at("version") or 1
  verify_ev = Json.Object({
    "page_id": Json.String(id),
    "collection_id": Json.String(v_col_id),
    "version": Json.int(v_ver),
    "actor": Json.String(auth.principal.handle)
  })
  Ok(
    json_ok(200, upd_json.get("page") or Json.Null)
      .with_sse_publish_json("page:#{id}", "page.verified", verify_ev)
      .with_sse_publish_json("collection:#{v_col_id}", "page.verified", verify_ev)
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
  chat_hits_opt = if req.query_param("include_chat") == Some("1") and
    rf.exists?(Db.ledger_db_path)
    hits_j = try Ledger.read_locked(
      rf,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        hits = try ChatOps.search_visible_messages(
          Ledger.store(db),
          auth,
          q,
          None,
          col_filter,
          false,
          limit
        )
        Ok(Json.Array(hits))
      end
    )
    Some(hits_j)
  else
    None
  end
  base_map = {
    "results": out.results.to_json,
    "mode": Json.String(out.mode),
    "vector_backend": Json.String(out.vector_backend)
  }
  final_map = case chat_hits_opt
    Some(hits_j): base_map.set("chat_results", hits_j)
    None: base_map
  end
  Ok(json_ok(200, Json.Object(final_map)))
end

## `POST /api/pages/:id/comments` — Creates a page or block comment.
fn create_comment(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  input = CreateCommentInput(
    block_id: rj.text_at("block_id"),
    parent_comment_id: rj.text_at("parent_comment_id"),
    body_markdown: try VaultOps.req_text(rj, "body_markdown")
  )
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

  col_json = try Ledger.transact_locked(
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
      t2 = try Db.tx_put_comment(t1, cmt)
      Ok((t2, Json.Object({"collection_id": Json.String(page.collection_id)})))
    end
  )
  col_id = col_json.text_at("collection_id") or ""
  cmt_ev = Json.Object({
    "comment_id": Json.String(cmt.id),
    "page_id": Json.String(id),
    "collection_id": Json.String(col_id),
    "actor": Json.String(auth.principal.handle)
  })
  Ok(
    json_ok(201, cmt.to_json)
      .with_sse_publish_json("page:#{id}", "comment.created", cmt_ev)
      .with_sse_publish_json("collection:#{col_id}", "comment.created", cmt_ev)
  )
end

## `POST /api/attachments/presign` — Issues an AWS SigV4 presigned `PUT` URL (or signed local-disk upload URL in Solo/Personal modes) and records pending metadata in MoDB.
fn presign_attachment(
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  input = PresignAttachmentInput(
    page_id: try VaultOps.req_text(rj, "page_id"),
    filename: try VaultOps.req_text(rj, "filename"),
    content_type: try VaultOps.req_text(rj, "content_type"),
    size_bytes: try VaultOps.req_int(rj, "size_bytes"),
    sha256_hex: rj.text_at("sha256_hex")
  )
  if input.size_bytes < 1 or input.size_bytes > 524288000
    return Error(BadInput(reason: "size_bytes must be between 1 and 524288000 (500 MiB)"))
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
    raw_key = if input.page_id.starts_with?("ch_")
      "workspaces/#{Db.default_workspace_id}/chat/#{input.page_id}/#{att_id}/#{clean_name}"
    else
      "workspaces/#{Db.default_workspace_id}/pages/#{input.page_id}/#{att_id}/#{clean_name}"
    end
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

  try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "presigned attachment #{att.id} (#{clean_name})",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, upload_action, now)
      if input.page_id.starts_with?("ch_")
        ch = case try ChatOps.tx_get_channel(t1, input.page_id)
          Some(c) if c.text_at("archived_at") == None: c
          Some(_) | None: return Error(Missing(entity: "chat_channel", id: input.page_id))
        end
        try ChatOps.require_channel_access(auth, ch, upload_action)
      else
        page = case try Table.tx_get(t1, Db.pages_table(), input.page_id).map_error(
          Db.map_table_error
        )
          Some(p) if p.archived_at == None: p
          Some(_) | None: return Error(Missing(entity: "page", id: input.page_id))
        end
        try Policy.require_collection_access(auth, upload_action, page.collection_id)
      end
      t2 = try Table.put(t1, Db.attachments_table(), att.id, att).map_error(Db.map_table_error)
      Ok((t2, Unit))
    end
  )

  Ok(
    json_ok(
      201,
      Json.Object({
        "attachment": att.to_json,
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

  att_json = try Ledger.read_locked(
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
      Ok(a.to_json)
    end
  )
  att_id = att_json.text_at("id") or ""
  att_s3_bucket = att_json.text_at("s3_bucket") or ""
  att_status = att_json.text_at("status") or ""
  att_size_bytes = att_json.int_at("size_bytes") or 0
  att_sha256_hex = att_json.text_at("sha256_hex") or ""
  att_s3_key = att_json.text_at("s3_key") or ""
  if att_s3_bucket != "local"
    return Error(BadInput(reason: "attachment '#{id}' uses S3 object storage, not local upload"))
  end
  if att_status != "pending"
    return Error(Conflict(reason: "attachment '#{id}' is '#{att_status}', not 'pending'"))
  end
  if not Auth.verify_local_attachment_sig(key, att_id, exp_sec, att_size_bytes, att_sha256_hex, sig)
    return Error(Forbidden(reason: "invalid local attachment upload signature"))
  end

  try files.make_folder("attachments/#{att_id}").map_error(map_file_error)
  case req.query_param("offset")
    Some(raw_off):
      off = case raw_off.trim.to_int
        Some(n) if n >= 0: n
        Some(_) | None: return Error(BadInput(reason: "offset must be a non-negative integer"))
      end
      if req.body.size <= 0 or req.body.size > 16777216
        return Error(BadInput(reason: "chunk size must be between 1 and 16777216 (16 MiB)"))
      end
      if off + req.body.size > att_size_bytes
        return Error(
          BadInput(reason: "chunk offset + size (#{off + req.body.size}) exceeds #{att_size_bytes}")
        )
      end
      fh = try files.open(att_s3_key).map_error(map_file_error)
      try fh.write_at(off, req.body).map_error(map_file_error)
      try fh.sync.map_error(map_file_error)
      cur_sz = try fh.size.map_error(map_file_error)
      return Ok(
        json_ok(
          200,
          Json.Object({
            "ok": Json.Boolean(true),
            "attachment_id": Json.String(att_id),
            "offset": Json.int(off),
            "chunk_bytes": Json.int(req.body.size),
            "file_size": Json.int(cur_sz)
          })
        )
      )
    None:
      if req.body.size != att_size_bytes or req.body.size > 524288000
        return Error(
          BadInput(reason: "expected #{att_size_bytes} bytes, received #{req.body.size} bytes")
        )
      end
      if not att_sha256_hex.empty?
        actual_sha = Crypto.sha256(req.body).to_hex.bytes
        if not Crypto.constant_time_eq?(actual_sha, att_sha256_hex.ascii_lowercase.bytes)
          return Error(BadInput(reason: "uploaded attachment SHA-256 digest mismatch"))
        end
      end
      try files.write_bytes(att_s3_key, req.body).map_error(map_file_error)
      return Ok(
        json_ok(
          200,
          Json.Object({
            "ok": Json.Boolean(true),
            "attachment_id": Json.String(att_id),
            "size_bytes": Json.int(req.body.size)
          })
        )
      )
  end
end

fn parse_http_range(range_hdr: Text, total_len: Int) : Result((Int, Int), AppError)
  if total_len <= 0
    return Error(BadInput(reason: "cannot serve byte range for empty file"))
  end
  raw = range_hdr.trim.ascii_lowercase
  spec = case raw.drop_prefix("bytes=")
    Some(s): s.trim
    None: return Error(BadInput(reason: "unsupported Range unit (expected bytes=...)"))
  end
  if spec.empty? or spec.contains?(",")
    return Error(BadInput(reason: "single contiguous bytes=start-end range required"))
  end
  parts = spec.split("-")
  if parts.size != 2
    return Error(BadInput(reason: "invalid Range header syntax"))
  end
  start_str = (parts.first or "").trim
  end_str = (parts.get(1) or "").trim
  (start_off, req_end) = if start_str.empty?
    suffix_len = case end_str.to_int
      Some(n) if n > 0: n
      Some(_) | None: return Error(BadInput(reason: "invalid suffix Range length"))
    end
    st = if total_len > suffix_len: total_len - suffix_len else: 0
    (st, total_len - 1)
  else
    st = case start_str.to_int
      Some(n) if n >= 0 and n < total_len: n
      Some(_) | None: return Error(BadInput(reason: "Range start out of bounds"))
    end
    en = if end_str.empty?
      total_len - 1
    else
      case end_str.to_int
        Some(n) if n >= st:
          if n >= total_len: total_len - 1 else: n
        Some(_) | None: return Error(BadInput(reason: "invalid Range end offset"))
      end
    end
    (st, en)
  end
  max_end = start_off + 8388607
  clamped_end = if req_end > max_end: max_end else: req_end
  Ok((start_off, clamped_end))
end

## `POST /api/attachments/:id/commit` — Marks an uploaded S3 or local-disk attachment `"ready"`.
fn commit_attachment(req: Api.Request, id: Text, auth: AuthContext, files: Files, clock: Clock) : Result(
  Api.Response,
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
        Some(a): Ok(a.to_json)
        None: Error(Missing(entity: "attachment", id: id))
      end
    end
  )
  pre_s3_bucket = pre_att.text_at("s3_bucket") or ""
  pre_s3_key = pre_att.text_at("s3_key") or ""
  pre_size_bytes = pre_att.int_at("size_bytes") or 0
  pre_sha256_hex = pre_att.text_at("sha256_hex") or ""
  if pre_s3_bucket == "local"
    if not files.read_only.exists?(pre_s3_key)
      return Error(BadInput(reason: "local attachment payload has not been uploaded yet"))
    end
    lf = try files.read_only.open(pre_s3_key).map_error(map_file_error)
    actual_sz = try lf.size.map_error(map_file_error)
    if actual_sz != pre_size_bytes
      return Error(
        BadInput(
          reason: "local attachment incomplete: expected #{pre_size_bytes} bytes, got #{actual_sz} bytes"
        )
      )
    end
    if not pre_sha256_hex.empty? and pre_size_bytes <= 67108864
      full_bytes = try files.read_only.read_bytes(pre_s3_key).map_error(map_file_error)
      actual_sha = Crypto.sha256(full_bytes).to_hex.bytes
      if not Crypto.constant_time_eq?(actual_sha, pre_sha256_hex.ascii_lowercase.bytes)
        return Error(BadInput(reason: "uploaded attachment SHA-256 digest mismatch"))
      end
    end
  end

  now = clock.now
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "attachment.commit",
    reason: "commit uploaded attachment '#{id}'",
    at: now
  )
  audit_payload = Json.Object({"attachment_id": Json.String(id)})

  ready_json = try Ledger.transact_locked(
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
      if old_att.page_id.starts_with?("ch_")
        ch = case try ChatOps.tx_get_channel(t1, old_att.page_id)
          Some(c) if c.text_at("archived_at") == None: c
          Some(_) | None: return Error(Missing(entity: "chat_channel", id: old_att.page_id))
        end
        try ChatOps.require_channel_access(auth, ch, upload_action)
      else
        page = case try Table.tx_get(t1, Db.pages_table(), old_att.page_id).map_error(
          Db.map_table_error
        )
          Some(p) if p.archived_at == None: p
          Some(_) | None: return Error(Missing(entity: "page", id: old_att.page_id))
        end
        try Policy.require_collection_access(auth, upload_action, page.collection_id)
      end
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
      Ok((t2, ready.to_json))
    end
  )
  Ok(json_ok(200, ready_json))
end

## `GET /api/attachments/:id/download` — Enforces collection grant & redirects (`302`) to S3 or serves local file (plus FERPA read audit when restricted).
fn download_attachment(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env
) : Result(Api.Response, AppError)
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "attachment", id: id))
  end
  att_info = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      a = case try Table.get(store, Db.attachments_table(), id).map_error(Db.map_table_error)
        Some(x): x
        None: return Error(Missing(entity: "attachment", id: id))
      end
      ferpa_col = if a.page_id.starts_with?("ch_")
        ch = case try ChatOps.get_channel(store, a.page_id)
          Some(c) if c.text_at("archived_at") == None: c
          Some(_) | None: return Error(Missing(entity: "chat_channel", id: a.page_id))
        end
        try ChatOps.require_channel_access(auth, ch, "read")
        case ChatOps.channel_collection_id(ch)
          Some(cid): if try VaultOps.is_ferpa_restricted(store, cid): Json.String(cid) else: Json.Null
          None: Json.Null
        end
      else
        page = case try Table.get(store, Db.pages_table(), a.page_id).map_error(Db.map_table_error)
          Some(p) if p.archived_at == None: p
          Some(_) | None: return Error(Missing(entity: "page", id: a.page_id))
        end
        try Policy.require_collection_access(auth, "read", page.collection_id)
        is_ferpa? = try VaultOps.is_ferpa_restricted(store, page.collection_id)
        if is_ferpa?: Json.String(page.collection_id) else: Json.Null
      end
      Ok(
        Json.Object({
          "id": Json.String(a.id),
          "status": Json.String(a.status),
          "s3_bucket": Json.String(a.s3_bucket),
          "s3_key": Json.String(a.s3_key),
          "content_type": Json.String(a.content_type),
          "filename": Json.String(a.filename),
          "ferpa_col": ferpa_col
        })
      )
    end
  )
  att_id = att_info.text_at("id") or id
  att_status = att_info.text_at("status") or ""
  att_s3_bucket = att_info.text_at("s3_bucket") or ""
  att_s3_key = att_info.text_at("s3_key") or ""
  att_content_type = att_info.text_at("content_type") or ""
  att_filename = att_info.text_at("filename") or ""
  if att_status != "ready"
    return Error(Conflict(reason: "attachment '#{id}' is not ready for download"))
  end
  case att_info.text_at("ferpa_col")
    Some(fcid):
      try VaultOps.record_ferpa_read_audit_locked(
        files,
        rng,
        clock,
        auth,
        "ferpa.attachment.downloaded",
        fcid,
        "attachment",
        att_id,
        "FERPA vault attachment download"
      )
    None: Unit
  end

  if att_s3_bucket == "local"
    disp = if dangerous_inline_mime?(att_content_type): "attachment" else: "inline"
    safe_name = sanitize_filename_segment(att_filename)
    case req.header("Range")
      Some(range_hdr) if not range_hdr.trim.empty?:
        fh = try files.read_only.open(att_s3_key).map_error(map_file_error)
        total_sz = try fh.size.map_error(map_file_error)
        (start_off, end_off) = try parse_http_range(range_hdr, total_sz)
        want_len = end_off - start_off + 1
        slice_bytes = try fh.read_at(start_off, want_len).map_error(map_file_error)
        actual_end = if slice_bytes.empty?
          start_off
        else
          start_off + slice_bytes.size - 1
        end
        return Ok(
          Api.response(
            206,
            [
              ("Content-Type", att_content_type),
              ("Content-Range", "bytes #{start_off}-#{actual_end}/#{total_sz}"),
              ("Content-Length", "#{slice_bytes.size}"),
              ("Accept-Ranges", "bytes"),
              ("Content-Disposition", "#{disp}; filename=\"#{safe_name}\""),
              ("Cache-Control", "private, no-store"),
              ("X-Content-Type-Options", "nosniff")
            ],
            slice_bytes
          )
        )
      Some(_) | None: Unit
    end
    payload = try files.read_only.read_bytes(att_s3_key).map_error(map_file_error)
    return Ok(
      Api.response(
        200,
        [
          ("Content-Type", att_content_type),
          ("Accept-Ranges", "bytes"),
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
    response_content_type: Some(att_content_type)
  )
  signed = try S3.presign_get(s3_cfg, att_s3_key, get_opts, clock.now).map_error(map_s3_error)
  Ok(Api.redirect(signed.url).with_header("Cache-Control", "private, no-store"))
end

## `POST /api/admin/agents` — Mints an `Agent` principal, scoped `Modb.Grants.Grant`, and one-time Bearer token.
fn mint_agent_token(
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  input = MintAgentTokenInput(
    handle: try VaultOps.req_text(rj, "handle"),
    display_name: try VaultOps.req_text(rj, "display_name"),
    model_id: rj.text_at("model_id"),
    label: try VaultOps.req_text(rj, "label"),
    allowed_actions: VaultOps.json_text_list_raw(rj, "allowed_actions"),
    allowed_collections: VaultOps.json_text_list_opt(rj, "allowed_collections"),
    max_calls: try VaultOps.req_int(rj, "max_calls"),
    ttl_days: try VaultOps.req_int(rj, "ttl_days")
  )
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
  mint_json = try Ledger.transact_locked(
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
      Ok((
        t1,
        Json.Object({
          "grant_id": Json.String(g.id),
          "parent_grant_id": g.parent_id.to_json,
          "principal_handle": Json.String(p.handle),
          "max_calls": Json.int(g.max_calls),
          "principal": p.to_json,
          "grant": g.to_json,
          "token_id": Json.String(t.id),
          "token_prefix": Json.String(t.prefix)
        })
      ))
    end
  )

  mint_ev = Json.Object({
    "grant_id": mint_json.get("grant_id") or Json.Null,
    "parent_grant_id": mint_json.get("parent_grant_id") or Json.Null,
    "principal_handle": mint_json.get("principal_handle") or Json.Null,
    "max_calls": mint_json.get("max_calls") or Json.Null,
    "actor": Json.String(auth.principal.handle)
  })
  Ok(
    json_ok(
      201,
      Json.Object({
        "raw_token": Json.String(raw_token),
        "principal": mint_json.get("principal") or Json.Null,
        "grant": mint_json.get("grant") or Json.Null,
        "token_id": mint_json.get("token_id") or Json.Null,
        "token_prefix": mint_json.get("token_prefix") or Json.Null
      })
    ).with_sse_publish_json("grants", "grant.minted", mint_ev)
  )
end

## `POST /api/admin/grants/:id/revoke` — Cascades revocation across a `Modb.Grants` subtree and revokes bound agent tokens.
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

  rev_json = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "revoked grant #{id}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      all_g_rows = try Table.tx_scan(tx, Grants.grants_table(), None, None, 500).map_error(
        Db.map_table_error
      )
      var sub_ids = [id]
      var q_idx = 0
      while q_idx < sub_ids.size
        cur_gid = sub_ids.get(q_idx) or stop "subtree bfs idx"
        q_idx += 1
        for (_gid, g) in all_g_rows
          if g.parent_id == Some(cur_gid) and not sub_ids.contains?(g.id)
            sub_ids = sub_ids.append(g.id)
          end
        end
      end
      (t1, rev_g) = try Grants.tx_revoke(tx, id).map_error(Db.map_grants_error)
      var cur = t1
      tok_rows = try Table.tx_scan(cur, Db.agent_tokens_table(), None, None, 500).map_error(
        Db.map_table_error
      )
      for (_tid, tok) in tok_rows
        if sub_ids.contains?(tok.grant_id) and tok.revoked_at == None
          upd_tok = AgentToken(
            id: tok.id,
            principal_id: tok.principal_id,
            grant_id: tok.grant_id,
            label: tok.label,
            prefix: tok.prefix,
            token_hash: tok.token_hash,
            created_by: tok.created_by,
            expires_at: tok.expires_at,
            revoked_at: Some(now),
            last_used_at: tok.last_used_at
          )
          cur = try Db.tx_put_agent_token(cur, upd_tok)
        end
      end
      Ok((
        cur,
        Json.Object({
          "grant_id": Json.String(rev_g.id),
          "affected_grant_ids": sub_ids.to_json,
          "cascaded_count": Json.int(sub_ids.size)
        })
      ))
    end
  )
  rev_gid = rev_json.text_at("grant_id") or id
  rev_aff = rev_json.get("affected_grant_ids") or Json.Array([])
  rev_cnt = rev_json.get("cascaded_count") or Json.int(1)
  rev_ev = Json.Object({
    "grant_id": Json.String(rev_gid),
    "affected_grant_ids": rev_aff,
    "cascaded_count": rev_cnt,
    "actor": Json.String(auth.principal.handle)
  })
  Ok(
    json_ok(
      200,
      Json.Object({
        "revoked_grant_id": Json.String(rev_gid),
        "revoked": Json.Boolean(true),
        "affected_grant_ids": rev_aff,
        "cascaded_count": rev_cnt
      })
    ).with_sse_publish_json("grants", "grant.revoked", rev_ev)
  )
end

fn grant_ancestor_path(grants_by_id: Map(Text, Grants.Grant), g: Grants.Grant) : List(Text)
  var path = [g.id]
  var cur_opt = g.parent_id
  while true
    case cur_opt
      None: break
      Some(pid):
        break if path.contains?(pid)
        path = [pid].concat(path)
        cur_opt = case grants_by_id.get(pid)
          Some(pg): pg.parent_id
          None: None
        end
    end
  end
  path
end

## `GET /api/admin/grants/tree` — Returns the full `Modb.Grants` sub-delegation hierarchy,
## cascading revocation/expiry status, call-budget utilization gauges, and token metadata.
fn grants_tree(auth: AuthContext, rf: ReadFiles, clock: Clock) : Result(Api.Response, AppError)
  role_ok = auth.principal.role == Owner or auth.principal.role == Admin
  if not role_ok
    return Error(Forbidden(reason: "only Owner/Admin may inspect the Modb.Grants hierarchy"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Ok(
      json_ok(
        200,
        Json.Object({
          "summary": Json.Object({
            "total_grants": Json.int(0),
            "active_grants": Json.int(0),
            "active_agent_grants": Json.int(0),
            "delegated_grants": Json.int(0),
            "revoked_grants": Json.int(0),
            "expired_grants": Json.int(0),
            "exhausted_grants": Json.int(0),
            "total_calls_used": Json.int(0),
            "total_call_budget": Json.int(0)
          }),
          "grants": Json.Array([])
        })
      )
    )
  end

  now = clock.now
  payload = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      all_grants = try Grants.list_all(store).map_error(Db.map_grants_error)
      p_rows = try Table.scan(store, Db.principals_table(), None, None, 500).map_error(
        Db.map_table_error
      )
      t_rows = try Table.scan(store, Db.agent_tokens_table(), None, None, 500).map_error(
        Db.map_table_error
      )

      var grants_by_id = {}
      for g in all_grants
        grants_by_id = grants_by_id.set(g.id, g)
      end
      var principals_by_id = {}
      for (pid, p) in p_rows
        principals_by_id = principals_by_id.set(pid, p)
      end
      var tokens_by_grant = {}
      for (_tid, tok) in t_rows
        tokens_by_grant = tokens_by_grant.set(tok.grant_id, tok)
      end

      sorted_grants = all_grants.sort_by(fn(g) grant_ancestor_path(grants_by_id, g).join("/") end)
      var total_active = 0
      var total_active_agent = 0
      var total_delegated = 0
      var total_revoked = 0
      var total_expired = 0
      var total_exhausted = 0
      var total_used = 0
      var total_budget = 0
      var nodes_json = []

      for g in sorted_grants
        anc_path = grant_ancestor_path(grants_by_id, g)
        var rev_via = None
        var expired? = now > g.expires_at
        for anc_id in anc_path
          case grants_by_id.get(anc_id)
            Some(anc):
              if anc.revoked and rev_via == None
                rev_via = Some(anc.id)
              end
              if now > anc.expires_at
                expired? = true
              end
            None: Unit
          end
        end
        eff_revoked? = rev_via != None
        exhausted? = g.max_calls > 0 and g.used_calls >= g.max_calls
        status = if eff_revoked?
          "revoked"
        else if expired?
          "expired"
        else if exhausted?
          "exhausted"
        else
          "active"
        end
        depth = if anc_path.size > 0: anc_path.size - 1 else: 0
        sub_set = try Grants.grant_subtree_ids(store, g.id).map_error(Db.map_grants_error)
        desc_cnt = if sub_set.size > 0: sub_set.size - 1 else: 0
        util_pct = if g.max_calls > 0
          raw_pct = (g.used_calls * 100) / g.max_calls
          if raw_pct > 100: 100 else: raw_pct
        else
          0
        end

        p_opt = principals_by_id.get(g.principal)
        t_opt = tokens_by_grant.get(g.id)
        is_agent? = case p_opt
          Some(p): p.kind == Agent
          None: false
        end

        if g.parent_id != None
          total_delegated += 1
        end
        if status == "active"
          total_active += 1
          if is_agent?
            total_active_agent += 1
          end
        else if status == "revoked"
          total_revoked += 1
        else if status == "expired"
          total_expired += 1
        else
          total_exhausted += 1
        end
        if is_agent?
          total_used += g.used_calls
          total_budget += g.max_calls
        end

        nodes_json = nodes_json.append(
          Json.Object({
            "id": Json.String(g.id),
            "parent_id": g.parent_id.to_json,
            "principal_id": Json.String(g.principal),
            "principal_handle": p_opt.map(fn(p) p.handle end).to_json,
            "principal_name": p_opt.map(fn(p) p.display_name end).to_json,
            "principal_kind": p_opt.map(fn(p) p.kind end).to_json,
            "model_id": case p_opt
              Some(p): p.model_id.to_json
              None: Json.Null
            end,
            "role": p_opt.map(fn(p) p.role end).to_json,
            "allowed_actions": g.allowed_actions.to_json,
            "allowed_collections": g.allowed_views.to_json,
            "max_calls": Json.int(g.max_calls),
            "used_calls": Json.int(g.used_calls),
            "utilization_pct": Json.int(util_pct),
            "expires_at": g.expires_at.to_json,
            "revoked": Json.Boolean(eff_revoked?),
            "revoked_directly": Json.Boolean(g.revoked),
            "revoked_via": rev_via.to_json,
            "status": Json.String(status),
            "depth": Json.int(depth),
            "descendant_count": Json.int(desc_cnt),
            "chain": g.chain.to_json,
            "token_prefix": t_opt.map(fn(t) t.prefix end).to_json,
            "token_label": t_opt.map(fn(t) t.label end).to_json,
            "last_used_at": case t_opt
              Some(t): t.last_used_at.to_json
              None: Json.Null
            end
          })
        )
      end

      Ok(
        Json.Object({
          "summary": Json.Object({
            "total_grants": Json.int(sorted_grants.size),
            "active_grants": Json.int(total_active),
            "active_agent_grants": Json.int(total_active_agent),
            "delegated_grants": Json.int(total_delegated),
            "revoked_grants": Json.int(total_revoked),
            "expired_grants": Json.int(total_expired),
            "exhausted_grants": Json.int(total_exhausted),
            "total_calls_used": Json.int(total_used),
            "total_call_budget": Json.int(total_budget)
          }),
          "grants": Json.Array(nodes_json)
        })
      )
    end
  )
  Ok(json_ok(200, payload))
end

## `POST /api/admin/grants/kill-all` — Emergency kill switch revoking every active Agent `Modb.Grants`
## and Bearer token atomically while preserving Human Owner/Admin sessions.
fn kill_all_agent_grants(
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  role_ok = auth.principal.role == Owner or auth.principal.role == Admin
  if not role_ok or not Policy.action_permitted?(auth, "manage_grants")
    return Error(
      Forbidden(reason: "only Owner/Admin with manage_grants may trigger the agent kill switch")
    )
  end
  raw_reason = if req.body.empty?
    ""
  else
    case Json.parse(req.text or "")
      Ok(j): (j.text_at("reason") or "").trim
      Error(_): ""
    end
  end
  clean_reason = if raw_reason.empty?
    "Emergency kill switch: revoke all active agent grants"
  else
    raw_reason
  end

  if not files.read_only.exists?(Db.ledger_db_path)
    return Ok(
      json_ok(
        200,
        Json.Object({
          "revoked_count": Json.int(0),
          "revoked_grant_ids": Json.Array([]),
          "reason": Json.String(clean_reason)
        })
      )
    )
  end

  now = clock.now
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "admin.kill_all_agents",
    reason: clean_reason,
    at: now
  )
  rev_json = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "emergency kill-all agent grants",
    Json.Object({"reason": Json.String(clean_reason)}),
    Db.map_ledger_error,
    fn(tx)
      p_rows = try Table.tx_scan(tx, Db.principals_table(), None, None, 500).map_error(
        Db.map_table_error
      )
      var agent_pids = Set.empty
      for (pid, p) in p_rows
        if p.kind == Agent
          agent_pids = agent_pids.add(pid)
        end
      end

      var cur = tx
      var revoked_ids = []
      g_rows = try Table.tx_scan(cur, Grants.grants_table(), None, None, 500).map_error(
        Db.map_table_error
      )
      for (_gid, g) in g_rows
        if not g.revoked and agent_pids.has?(g.principal)
          (next_tx, rev_g) = try Grants.tx_revoke(cur, g.id).map_error(Db.map_grants_error)
          cur = next_tx
          revoked_ids = revoked_ids.append(rev_g.id)
        end
      end

      tok_rows = try Table.tx_scan(cur, Db.agent_tokens_table(), None, None, 500).map_error(
        Db.map_table_error
      )
      for (_tid, tok) in tok_rows
        if tok.revoked_at == None and
          (revoked_ids.contains?(tok.grant_id) or agent_pids.has?(tok.principal_id))
          upd_tok = AgentToken(
            id: tok.id,
            principal_id: tok.principal_id,
            grant_id: tok.grant_id,
            label: tok.label,
            prefix: tok.prefix,
            token_hash: tok.token_hash,
            created_by: tok.created_by,
            expires_at: tok.expires_at,
            revoked_at: Some(now),
            last_used_at: tok.last_used_at
          )
          cur = try Db.tx_put_agent_token(cur, upd_tok)
        end
      end
      Ok((cur, Json.Object({"ids": revoked_ids.to_json})))
    end
  )
  revoked_ids = VaultOps.json_text_list_raw(rev_json, "ids")

  kill_ev = Json.Object({
    "revoked_grant_ids": revoked_ids.to_json,
    "revoked_count": Json.int(revoked_ids.size),
    "actor": Json.String(auth.principal.handle),
    "reason": Json.String(clean_reason)
  })
  Ok(
    json_ok(
      200,
      Json.Object({
        "revoked_count": Json.int(revoked_ids.size),
        "revoked_grant_ids": revoked_ids.to_json,
        "reason": Json.String(clean_reason)
      })
    ).with_sse_publish_json("grants", "grants.kill_all", kill_ev)
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
  feed_json = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      entries = try Ledger.audit_tail_store(Ledger.store(db), limit).map_error(Db.map_ledger_error)
      Ok(entries.map(audit_entry_to_feed).to_json)
    end
  )
  Ok(json_ok(200, Json.Object({"audit_feed": feed_json})))
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

  prop_json = if not rf.exists?(Db.ledger_db_path)
    Json.Object({"collections": Json.Array([]), "databases": Json.Array([]), "proposals": Json.Array([])})
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
        Ok(
          Json.Object({
            "collections": c_list.to_json,
            "databases": d_list.to_json,
            "proposals": out.to_json
          })
        )
      end
    )
  end
  cols_json = prop_json.get("collections") or Json.Array([])
  dbs_json = prop_json.get("databases") or Json.Array([])
  props_json = prop_json.get("proposals") or Json.Array([])

  if Auth.wants_json?(req)
    return Ok(
      json_ok(
        200,
        Json.Object({
          "collections": cols_json,
          "databases": dbs_json,
          "proposals": props_json
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
    {"collections": cols_json, "databases": dbs_json, "proposals": props_json}
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

  admin_json = if not rf.exists?(Db.ledger_db_path)
    Json.Object({
      "collections": Json.Array([]),
      "databases": Json.Array([]),
      "audit_feed": Json.Array([]),
      "webhooks": Json.Array([])
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
        Ok(
          Json.Object({
            "collections": c_list.to_json,
            "databases": d_list.to_json,
            "audit_feed": audit_items.to_json,
            "webhooks": Json.Array(hook_items)
          })
        )
      end
    )
  end
  cols_json = admin_json.get("collections") or Json.Array([])
  dbs_json = admin_json.get("databases") or Json.Array([])
  feed_json = admin_json.get("audit_feed") or Json.Array([])
  hooks_json = admin_json.get("webhooks") or Json.Array([])

  if Auth.wants_json?(req)
    return Ok(
      json_ok(
        200,
        Json.Object({
          "collections": cols_json,
          "databases": dbs_json,
          "audit_feed": feed_json,
          "webhooks": hooks_json
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
      "collections": cols_json,
      "databases": dbs_json,
      "audit_feed": feed_json,
      "webhooks": hooks_json
    }
  )
end

fn extract_indexed_page_id(payload_json: Text) : Result(Text, Text)
  parsed = try Json.parse(payload_json).map_error(fn(e) e.to_text end)
  case parsed.text_at("page_id")
    Some(pid) if not pid.trim.empty?: Ok(pid.trim)
    Some(_) | None: Error("vellum.page.indexed payload missing non-empty 'page_id'")
  end
end

fn parse_webhook_job_payload(raw: Text) : Result(WebhookJobPayload, Text)
  j = try Json.parse(raw).map_error(fn(e) e.to_text end)
  wid = try j.text_at("webhook_id").or_fail("missing webhook_id")
  did = try j.text_at("delivery_id").or_fail("missing delivery_id")
  url = try j.text_at("url").or_fail("missing url")
  sec = try j.text_at("secret").or_fail("missing secret")
  evt = try j.text_at("event").or_fail("missing event")
  bj = j.get("body_json") or Json.Null
  Ok(
    WebhookJobPayload(
      webhook_id: wid,
      delivery_id: did,
      url: url,
      secret: sec,
      event: evt,
      body_json: bj,
      taint_session_id: j.text_at("taint_session_id")
    )
  )
end

fn refresh_semantic_summary_if_stale(
  pid: Text,
  cfg: Ai.AiConfig,
  files: Files,
  clock: Clock,
  env: Env,
  net: Network
) : Unit
  local_only_ai? = VaultOps.env_ai_local_only?(env)
  prep_res = Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      pg = case try Table.get(store, Db.pages_table(), pid).map_error(Db.map_table_error)
        Some(p) if p.archived_at == None and p.kind == Document: p
        Some(_) | None: return Ok(Json.Object({"ready": Json.Boolean(false)}))
      end
      if not try VaultOps.ai_allowed_for_collection(
        store,
        pg.collection_id,
        cfg.base_url,
        local_only_ai?
      )
        return Ok(Json.Object({"ready": Json.Boolean(false)}))
      end
      s_opt = try Table.get(store, Db.summaries_table(), Db.page_summary_key(pg.id)).map_error(
        Db.map_table_error
      )
      needs_refresh? = case s_opt
        Some(sm): sm.semantic_source_version < pg.version or sm.semantic_summary == None
        None: false
      end
      return Ok(Json.Object({"ready": Json.Boolean(false)})) if not needs_refresh?
      blks = try Db.load_page_blocks(store, pg.id)
      plain = Blocks.blocks_plain_text(blks)
      Ok(
        Json.Object({
          "ready": Json.Boolean(true),
          "title": Json.String(pg.title),
          "version": Json.int(pg.version),
          "plain": Json.String(plain)
        })
      )
    end
  )
  (title, pg_ver, plain) = case prep_res
    Ok(j) if j.bool_at("ready") == Some(true):
      (j.text_at("title") or "", j.int_at("version") or 0, j.text_at("plain") or "")
    Ok(_) | Error(_): return Unit
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
          t1 = try Db.tx_put_summary(tx, nxt)
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
  local_only_ai? = VaultOps.env_ai_local_only?(env)
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
          case parse_webhook_job_payload(job.payload_json)
            Error(e): try Jobs.fail_or_retry(
              files,
              Db.ledger_db_path,
              clock,
              job.id,
              job.attempts,
              e
            ).map_error(Db.map_table_error)
            Ok(wp):
              taint_check = case wp.taint_session_id
                Some(sid):
                  sess_opt = try Ledger.read_locked(
                    files.read_only,
                    Db.ledger_db_path,
                    Db.vellum_schema(),
                    Db.map_ledger_error,
                    fn(db) TaintBridge.get_taint_session(Ledger.store(db), sid) end
                  )
                  case sess_opt
                    Some(_):
                      case TaintBridge.authorize_action_locked(
                        files,
                        Db.ledger_db_path,
                        Db.vellum_schema(),
                        sid,
                        "webhook.deliver",
                        clock.now
                      )
                        Ok(_): Ok(Unit)
                        Error(te): Error(te)
                      end
                    None: Ok(Unit)
                  end
                None: Ok(Unit)
              end
              case taint_check
                Error(te): try Jobs.fail_or_retry(
                  files,
                  Db.ledger_db_path,
                  clock,
                  job.id,
                  999,
                  "blocked by Modb.Taint Lethal Trifecta policy: #{te.to_text}"
                ).map_error(Db.map_table_error)
                Ok(_):
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
                          if not try VaultOps.ai_allowed_for_collection(
                            store,
                            pg.collection_id,
                            ecfg.base_url,
                            local_only_ai?
                          )
                            return Ok(Json.Object({"ready": Json.Boolean(false)}))
                          end
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
                            Ok(Json.Object({"ready": Json.Boolean(false)}))
                          else
                            Ok(Json.Object({"ready": Json.Boolean(true), "text": Json.String(txt)}))
                          end
                        Some(_) | None: Ok(Json.Object({"ready": Json.Boolean(false)}))
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
                    Ok(ej) if ej.bool_at("ready") != Some(true):
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
                    Ok(ej):
                      embed_txt = ej.text_at("text") or ""
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
                Ok(ai_cfg): refresh_semantic_summary_if_stale(pid, ai_cfg, files, clock, env, net)
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
  bps_json = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      rows = try Table.scan(Ledger.store(db), Db.blueprints_table(), None, None, 200).map_error(
        Db.map_table_error
      )
      Ok(rows.map(fn(x) x.1 end).to_json)
    end
  )
  Ok(json_ok(200, Json.Object({"blueprints": bps_json})))
end

## `POST /api/blueprints` — Creates a new Statamic-style `BlueprintDef` (`manage_schema`).
fn create_blueprint(
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  fields_in = case rj.get("fields")
    None: return Error(BadInput(reason: "missing 'fields' array"))
    Some(fj): try decode_property_defs_json(fj.to_text.bytes).map_error(fn(e)
      BadInput(reason: "invalid 'fields': #{e}")
    end)
  end
  input = CreateBlueprintInput(
    slug: try VaultOps.req_text(rj, "slug"),
    name: try VaultOps.req_text(rj, "name"),
    description: rj.text_at("description"),
    icon: rj.text_at("icon"),
    fields: fields_in,
    default_template_markdown: rj.text_at("default_template_markdown")
  )
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
  created_json = try Ledger.transact_locked(
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
      Ok((t2, bp.to_json))
    end
  )
  Ok(json_ok(201, created_json))
end

## `PUT /api/blueprints/:id` — Updates an existing `BlueprintDef` (`manage_schema`).
fn update_blueprint(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  fields_opt = case rj.get("fields")
    None | Some(Json.Null): None
    Some(fj): Some(
      try decode_property_defs_json(fj.to_text.bytes).map_error(fn(e)
        BadInput(reason: "invalid 'fields': #{e}")
      end)
    )
  end
  input = UpdateBlueprintInput(
    slug: rj.text_at("slug"),
    name: rj.text_at("name"),
    description: rj.text_at("description"),
    icon: rj.text_at("icon"),
    fields: fields_opt,
    default_template_markdown: rj.text_at("default_template_markdown"),
    expected_version: rj.int_at("expected_version")
  )
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

  updated_json = try Ledger.transact_locked(
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
      Ok((t2, next_bp.to_json))
    end
  )
  Ok(json_ok(200, updated_json))
end

## `PUT /api/pages/:id/meta` — Attaches, updates, or detaches a `BlueprintDef` + typed metadata on a page.
fn set_page_blueprint_meta(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  vals_opt = case rj.get("values")
    None | Some(Json.Null): None
    Some(vj): Some(
      try decode_cell_map_json(vj.to_text.bytes).map_error(fn(e)
        BadInput(reason: "invalid 'values': #{e}")
      end)
    )
  end
  input = SetPageMetaInput(
    blueprint_id: rj.text_at("blueprint_id"),
    values: vals_opt,
    apply_template_if_empty: rj.bool_at("apply_template_if_empty"),
    reason: rj.text_at("reason")
  )
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

  meta_json = try Ledger.transact_locked(
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
            Some(_): try Db.tx_delete_page_meta(t1, id)
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
          t_pm = try Db.tx_put_page_meta(t1, pm)
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
      anchored_md = Blocks.to_anchored_markdown(out_blocks)
      yaml_fm = Blueprints.to_yaml_frontmatter(bumped_page, bp_opt, pm_opt, anchored_md)
      Ok((
        t4,
        Json.Object({
          "collection_id": Json.String(bumped_page.collection_id),
          "version": Json.int(bumped_page.version),
          "body": Json.Object({
            "page": bumped_page.to_json,
            "blocks": out_blocks.to_json,
            "page_blueprint": bp_opt.to_json,
            "page_meta": pm_opt.to_json,
            "anchored_markdown": Json.String(anchored_md),
            "yaml_frontmatter": Json.String(yaml_fm)
          })
        })
      ))
    end
  )

  m_col_id = meta_json.text_at("collection_id") or ""
  m_ver = meta_json.int_at("version") or 1
  meta_ev = Json.Object({
    "page_id": Json.String(id),
    "collection_id": Json.String(m_col_id),
    "version": Json.int(m_ver),
    "actor": Json.String(auth.principal.handle)
  })
  Ok(
    json_ok(200, meta_json.get("body") or Json.Null)
      .with_sse_publish_json("page:#{id}", "page.meta_updated", meta_ev)
      .with_sse_publish_json("collection:#{m_col_id}", "page.meta_updated", meta_ev)
  )
end

## `PUT /api/pages/:id/markdown` — Reconciles anchored Markdown back into canonical blocks while preserving unchanged IDs/provenance.
fn sync_page_markdown(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  input = SyncPageMarkdownInput(
    markdown: try VaultOps.req_text(rj, "markdown"),
    expected_page_version: try VaultOps.req_int(rj, "expected_page_version"),
    reason: rj.text_at("reason")
  )
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

  sync_json = try Ledger.transact_locked(
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
      anchored_md = Blocks.to_anchored_markdown(reconciled)
      yaml_fm = Blueprints.to_yaml_frontmatter(bumped_page, bp_opt, pm_opt, anchored_md)
      Ok((
        t3,
        Json.Object({
          "collection_id": Json.String(bumped_page.collection_id),
          "version": Json.int(bumped_page.version),
          "body": Json.Object({
            "page": bumped_page.to_json,
            "blocks": reconciled.to_json,
            "anchored_markdown": Json.String(anchored_md),
            "yaml_frontmatter": Json.String(yaml_fm)
          })
        })
      ))
    end
  )

  s_col_id = sync_json.text_at("collection_id") or ""
  s_ver = sync_json.int_at("version") or 1
  blocks_ev = Json.Object({
    "page_id": Json.String(id),
    "collection_id": Json.String(s_col_id),
    "version": Json.int(s_ver),
    "actor": Json.String(auth.principal.handle),
    "reason": Json.String(reason_opt or "sync markdown")
  })
  Ok(
    json_ok(200, sync_json.get("body") or Json.Null)
      .with_sse_publish_json("page:#{id}", "page.blocks_updated", blocks_ev)
      .with_sse_publish_json("collection:#{s_col_id}", "page.blocks_updated", blocks_ev)
  )
end

## `POST /api/metrics/resolve` — Evaluates `{{metric:<db>.<prop>:<agg>}}` tokens (fail-closed per DB ACL, with optional What-If Scenario diff).
fn resolve_metrics(
  req: Api.Request,
  auth: AuthContext,
  rf: ReadFiles
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  input = ResolveMetricsInput(
    tokens: VaultOps.json_text_list_raw(rj, "tokens"),
    scenario_id: rj.text_at("scenario_id")
  )
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

## `GET /api/admin/erasure/status` — Lists scanned secret exposure hints and verifiable `Modb.Erasure` receipts.
fn erasure_status(auth: AuthContext, rf: ReadFiles) : Result(Api.Response, AppError)
  role_ok = auth.principal.role == Owner or auth.principal.role == Admin
  if not role_ok
    return Error(Forbidden(reason: "only Owner/Admin may inspect Modb.Erasure status"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Ok(json_ok(200, Json.Object({"findings": Json.Array([]), "receipts": Json.Array([])})))
  end
  payload = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      findings = try ErasureOps.scan_workspace_secrets(store)
      receipts = try ErasureOps.list_erasure_receipts_json(store)
      Ok(Json.Object({"findings": Json.Array(findings), "receipts": Json.Array(receipts)}))
    end
  )
  Ok(json_ok(200, payload))
end

fn opt_trimmed_text(j: Json, key: Text) : Option(Text)
  case j.text_at(key)
    Some(s) if not s.trim.empty?: Some(s.trim)
    Some(_) | None: None
  end
end

## `POST /api/admin/erasure/purge` — One-click Owner/Admin `Modb.Erasure` crypto-shredding,
## live sanitization/deletion, audit/replay scrubbing, FTS/Vec purge, and optional compaction.
fn purge_secret(
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  role_ok = auth.principal.role == Owner or auth.principal.role == Admin
  if not role_ok or not Policy.action_permitted?(auth, "manage_grants")
    return Error(Forbidden(reason: "only Owner/Admin may execute Modb.Erasure secret purges"))
  end

  raw_json = if req.body.empty?
    Json.Object({})
  else
    case Json.parse(req.text or "")
      Ok(j): j
      Error(_): return Error(BadInput(reason: "invalid JSON body"))
    end
  end
  case raw_json
    Json.Object(_): Unit
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
      BadInput(reason: "expected JSON object")
    )
  end

  target_page_id = opt_trimmed_text(raw_json, "page_id")
  target_block_id = opt_trimmed_text(raw_json, "block_id")
  target_comment_id = opt_trimmed_text(raw_json, "comment_id")
  mode = raw_json.text_at("mode") or "redact"
  compact? = raw_json.bool_at("compact") or true
  reason = raw_json.text_at("reason") or ""

  var extra_tokens = []
  case raw_json.list_at("match_tokens")
    Some(xs):
      for item in xs
        case item
          Json.String(s) if not s.trim.empty?: extra_tokens = extra_tokens.append(s.trim)
          Json.String(_) | Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json
            .Object(_): Unit
        end
      end
    None: Unit
  end

  now = clock.now
  receipt_id = "ers_#{Id.ulid(rng, clock)}"
  subject_id = case opt_trimmed_text(raw_json, "subject_id")
    Some(s): s
    None:
      case target_page_id
        Some(pid): "secret:#{pid}:#{receipt_id}"
        None: "secret:#{receipt_id}"
      end
  end

  (receipt, blocks_redacted, comments_redacted, affected_page_ids) = try ErasureOps.execute_secret_purge_locked(
    files,
    rng,
    receipt_id,
    subject_id,
    target_page_id,
    target_block_id,
    target_comment_id,
    mode,
    extra_tokens,
    compact?,
    auth.principal.handle,
    true,
    reason,
    now
  )

  var resp = json_ok(
    200,
    Json.Object({
      "receipt": ErasureOps.erasure_receipt_to_json(receipt),
      "blocks_redacted": Json.int(blocks_redacted),
      "comments_redacted": Json.int(comments_redacted),
      "affected_page_ids": affected_page_ids.to_json
    })
  )
  if mode.trim.ascii_lowercase == "redact"
    for pid in affected_page_ids
      ev = Json.Object({
        "page_id": Json.String(pid),
        "actor": Json.String(auth.principal.handle),
        "reason": Json.String("redacted via Modb.Erasure #{receipt.id}")
      })
      resp = resp.with_sse_publish_json("page:#{pid}", "page.blocks_updated", ev)
    end
  end
  Ok(resp)
end

## `GET /api/admin/erasure/receipts/:id/download` — Downloads a verifiable `Modb.Erasure.ErasureReceipt` JSON file.
fn download_erasure_receipt(id: Text, auth: AuthContext, rf: ReadFiles) : Result(
  Api.Response,
  AppError
)
  role_ok = auth.principal.role == Owner or auth.principal.role == Admin
  if not role_ok
    return Error(Forbidden(reason: "only Owner/Admin may download Modb.Erasure receipts"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "erasure_receipt", id: id))
  end
  rcpt_json = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      case try ErasureOps.get_erasure_receipt_json(Ledger.store(db), id)
        Some(rj): Ok(rj)
        None: Error(Missing(entity: "erasure_receipt", id: id))
      end
    end
  )
  safe_id = sanitize_filename_segment(id)
  body = Json.Object({
    "receipt": rcpt_json,
    "verification_note": Json.String(
      "Generated by Modb.Erasure dual-layer verification; raw secrets and PII are omitted (SHA-256 subject binding only)."
    )
  })
  Ok(
    Api.response(
      200,
      [
        ("Content-Type", "application/json; charset=utf-8"),
        ("Content-Disposition", "attachment; filename=\"vellum-erasure-receipt-#{safe_id}.json\""),
        ("Cache-Control", "no-store"),
        ("X-Content-Type-Options", "nosniff")
      ],
      body.to_text.bytes
    )
  )
end
