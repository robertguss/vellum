## Vellum v3 Milestone 3 Slice 3.2 — Chat Moat & Slack Export Importer:
## 1-Click Thread->Task, Live Bidirectional Reference Pills, ACL-Safe Inline Citations,
## Decision->Doc Change Proposal (`Modb.World`), Entity Autocomplete, and Slack Batch Import.
module Routes.ChatMoat
expose resolve_message_moat_enrichment,
strip_msg_for_sse,
list_origin_chat_threads_for_target,
row_links_for_rows_json,
page_origin_threads_json,
create_task_from_message,
draft_proposal_from_message,
list_linkable_entities,
import_slack_batch
use Api
use Arvo.Id
use ChatOps
use Db
use Domain.Blocks
use Domain.Collab{ProposalMeta, WorldPatchArgs}
use Domain.DatabaseModel{
  CellValue,
  DatabaseDef,
  DbRow,
  PropertyDef,
  PropertyKind,
  SelectOption,
  SelectOptionColor
}
use Domain.Policy
use Domain.Types{
  AppError,
  AuthContext,
  AuthorKind,
  BlockKind,
  BlockOp,
  Citation,
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
use Modb.World
use Routes.Auth
use VaultOps

fn json_ok(status: Int, body: Json) : Api.Response
  Api.encoded_json_response(status, body).with_header(
    "Content-Type",
    "application/json; charset=utf-8"
  )
end

fn parse_limit(raw: Option(Text), default_val: Int, max_val: Int) : Int
  case raw
    Some(s):
      case s.trim.to_int
        Some(n):
          if n < 1
            1
          else if n > max_val
            max_val
          else
            n
          end
        None: default_val
      end
    None: default_val
  end
end

fn opt_trimmed(j: Json, key: Text) : Option(Text)
  case j.text_at(key)
    Some(s) if not s.trim.empty?: Some(s.trim)
    Some(_) | None: None
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

fn option_color_text(c: SelectOptionColor) : Text
  case c
    Gray: "gray"
    Blue: "blue"
    Green: "green"
    Amber: "amber"
    Red: "red"
    Purple: "purple"
  end
end

fn status_options_of_kind(kind: PropertyKind) : Option(List(SelectOption))
  case kind
    Status(options: opts, done_option_ids: _) | Select(options: opts): Some(opts)
    Title | RichText | Number(format: _) | DateProp(include_time: _) | MultiSelect(options: _) |
      Checkbox | Person | Email | FileList | Url | UniqueId(prefix: _) | Formula(
        expression: _,
        format: _
      ) | CreatedTime | CreatedBy | LastEditedTime | LastEditedBy | Relation(
        target_db_id: _,
        inverse_prop_id: _
      ) | Rollup(relation_prop_id: _, target_prop_id: _, agg: _) | AiDerived(
        prompt: _,
        source_prop_ids: _,
        include_row_body: _,
        output_kind: _,
        mode: _,
        daily_call_cap: _
      ): None
  end
end

fn find_title_prop_id(props: List(PropertyDef)) : Text
  for p in props
    case p.kind
      Title: return p.id
      RichText | Number(format: _) | DateProp(include_time: _) | Select(options: _) | MultiSelect(
        options: _
      ) | Status(options: _, done_option_ids: _) | Checkbox | Person | Email | FileList | Url |
        UniqueId(prefix: _) | Formula(expression: _, format: _) | CreatedTime | CreatedBy |
        LastEditedTime | LastEditedBy | Relation(target_db_id: _, inverse_prop_id: _) | Rollup(
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
        ): Unit
    end
  end
  "title"
end

fn extract_row_status_badge(props: List(PropertyDef), cells: Map(Text, CellValue)) : (
  Option(Text),
  Option(Text)
)
  for p in props
    case status_options_of_kind(p.kind)
      Some(opts):
        oid_opt = case cells.get(p.id)
          Some(SelectVal(option_id: oid)): Some(oid)
          Some(Empty) | Some(TextVal(_)) | Some(NumberVal(_)) | Some(
            DateVal(start: _, end_date: _)
          ) | Some(MultiSelectVal(option_ids: _)) | Some(BoolVal(_)) | Some(PrincipalVal(_)) |
            Some(FilesVal(attachment_ids: _)) | Some(UrlVal(_)) | Some(RelationVal(row_ids: _)) |
            None: None
        end
        case oid_opt
          Some(oid):
            case opts.find(fn(o) o.id == oid end)
              Some(opt): return (Some(opt.label), Some(option_color_text(opt.color)))
              None: return (Some(oid), Some("gray"))
            end
          None: Unit
        end
      None: Unit
    end
  end
  (None, None)
end

fn linked_row_summary_json(def: DatabaseDef, row: DbRow) : Json
  title = DatabaseModel.extract_row_title(def, row.cells)
  (st_label, st_color) = extract_row_status_badge(def.properties, row.cells)
  Json.Object({
    "row_id": Json.String(row.id),
    "page_id": Json.String(row.page_id),
    "database_id": Json.String(def.id),
    "database_title": Json.String(def.title),
    "collection_id": Json.String(def.collection_id),
    "title": Json.String(title),
    "status_label": st_label.to_json,
    "status_color": st_color.to_json,
    "updated_at": row.updated_at.to_json
  })
end

fn redacted_ref_json(kind: Text, id: Text, raw: Text, subtitle: Text, label: Text) : Json
  Json.Object({
    "kind": Json.String(kind),
    "id": Json.String(id),
    "raw": Json.String(raw),
    "accessible": Json.Boolean(false),
    "redacted": Json.Boolean(true),
    "title": Json.String(label),
    "subtitle": Json.String(subtitle),
    "url": Json.Null
  })
end

fn missing_ref_json(kind: Text, id: Text, raw: Text, label: Text) : Json
  Json.Object({
    "kind": Json.String(kind),
    "id": Json.String(id),
    "raw": Json.String(raw),
    "accessible": Json.Boolean(false),
    "redacted": Json.Boolean(false),
    "title": Json.String(label),
    "subtitle": Json.String("Not found"),
    "url": Json.Null
  })
end

fn resolve_inline_ref_json(store: Store, auth: AuthContext, ref_j: Json) : Result(Json, AppError)
  kind = ref_j.text_at("kind") or ""
  id = ref_j.text_at("id") or ""
  raw = ref_j.text_at("raw") or ""
  if kind == "page"
    case try Db.get_page(store, id)
      Some(pg) if pg.archived_at == None:
        if Policy.collection_permitted?(auth, pg.collection_id)
          Ok(
            Json.Object({
              "kind": Json.String("page"),
              "id": Json.String(pg.id),
              "raw": Json.String(raw),
              "accessible": Json.Boolean(true),
              "redacted": Json.Boolean(false),
              "title": Json.String(pg.title),
              "subtitle": Json.String("Page"),
              "url": Json.String("/p/#{pg.id}"),
              "collection_id": Json.String(pg.collection_id)
            })
          )
        else
          Ok(redacted_ref_json("page", id, raw, "Access restricted", "[Restricted Citation]"))
        end
      Some(_) | None: Ok(missing_ref_json("page", id, raw, "[Missing Page]"))
    end
  else if kind == "row"
    case try Db.get_db_row(store, id)
      Some(r) if r.archived_at == None:
        case try Db.get_database(store, r.database_id)
          Some(d):
            if Policy.collection_permitted?(auth, d.collection_id)
              title = DatabaseModel.extract_row_title(d, r.cells)
              (st_label, st_color) = extract_row_status_badge(d.properties, r.cells)
              Ok(
                Json.Object({
                  "kind": Json.String("row"),
                  "id": Json.String(r.id),
                  "raw": Json.String(raw),
                  "accessible": Json.Boolean(true),
                  "redacted": Json.Boolean(false),
                  "title": Json.String(title),
                  "subtitle": Json.String(d.title),
                  "url": Json.String("/p/#{r.page_id}"),
                  "database_id": Json.String(d.id),
                  "page_id": Json.String(r.page_id),
                  "collection_id": Json.String(d.collection_id),
                  "status_label": st_label.to_json,
                  "status_color": st_color.to_json
                })
              )
            else
              Ok(redacted_ref_json("row", id, raw, "Access restricted", "[Restricted Citation]"))
            end
          None: Ok(missing_ref_json("row", id, raw, "[Missing Task]"))
        end
      Some(_) | None: Ok(missing_ref_json("row", id, raw, "[Missing Task]"))
    end
  else if kind == "proposal"
    case try Db.get_proposal(store, id)
      Some(pm):
        if Policy.collection_permitted?(auth, pm.collection_id)
          Ok(
            Json.Object({
              "kind": Json.String("proposal"),
              "id": Json.String(pm.id),
              "raw": Json.String(raw),
              "accessible": Json.Boolean(true),
              "redacted": Json.Boolean(false),
              "title": Json.String(pm.title),
              "subtitle": Json.String("Change Proposal"),
              "url": Json.String("/p/#{pm.target_page_id}"),
              "target_page_id": Json.String(pm.target_page_id),
              "collection_id": Json.String(pm.collection_id),
              "status": Json.String(pm.status)
            })
          )
        else
          Ok(
            redacted_ref_json("proposal", id, raw, "Access restricted", "[Restricted Citation]")
          )
        end
      None: Ok(missing_ref_json("proposal", id, raw, "[Missing Proposal]"))
    end
  else if kind == "thread"
    parts = id.split(":")
    cid = parts.get(0) or ""
    mid = parts.get(1) or ""
    if cid.empty? or mid.empty?
      return Ok(missing_ref_json("thread", id, raw, "[Missing Thread]"))
    end
    case try ChatOps.get_channel(store, cid)
      Some(ch) if ch.text_at("archived_at") == None:
        if not ChatOps.can_access_channel?(auth, ch, "read")
          return Ok(
            redacted_ref_json("thread", id, raw, "Access restricted", "[Restricted Thread]")
          )
        end
        case try ChatOps.get_message(store, cid, mid)
          Some(tm) if tm.text_at("deleted_at") == None:
            ch_name = ch.text_at("name") or cid
            sub = if ch.text_at("kind") == Some("dm")
              ch_name
            else
              "##{ch_name}"
            end
            Ok(
              Json.Object({
                "kind": Json.String("thread"),
                "id": Json.String(id),
                "raw": Json.String(raw),
                "accessible": Json.Boolean(true),
                "redacted": Json.Boolean(false),
                "title": Json.String(ChatOps.msg_preview(tm.text_at("body_markdown") or "")),
                "subtitle": Json.String(sub),
                "url": Json.String("/chat?channel=#{cid}&message=#{mid}"),
                "channel_id": Json.String(cid),
                "message_id": Json.String(mid),
                "channel_name": Json.String(ch_name)
              })
            )
          Some(_) | None: Ok(missing_ref_json("thread", id, raw, "[Missing Thread]"))
        end
      Some(_) | None: Ok(missing_ref_json("thread", id, raw, "[Missing Thread]"))
    end
  else
    Ok(missing_ref_json(kind, id, raw, "[Unknown Ref]"))
  end
end

## Resolves live status pills (`linked_rows`), proposal pills (`linked_proposals`),
## and ACL-redacted `inline_refs` cards for a single chat message `msg`.
fn resolve_message_moat_enrichment(store: Store, auth: AuthContext, msg: Json) : Result(
  Json,
  AppError
)
  var linked_rows = []
  for rid in VaultOps.json_string_list(msg, "linked_row_ids")
    case try Db.get_db_row(store, rid)
      Some(r) if r.archived_at == None:
        case try Db.get_database(store, r.database_id)
          Some(d) if Policy.collection_permitted?(auth, d.collection_id):
            linked_rows = linked_rows.append(linked_row_summary_json(d, r))
          Some(_) | None: Unit
        end
      Some(_) | None: Unit
    end
  end

  var linked_proposals = []
  for prid in VaultOps.json_string_list(msg, "linked_proposal_ids")
    case try Db.get_proposal(store, prid)
      Some(pm) if Policy.collection_permitted?(auth, pm.collection_id):
        linked_proposals = linked_proposals.append(
          Json.Object({
            "proposal_id": Json.String(pm.id),
            "target_page_id": Json.String(pm.target_page_id),
            "collection_id": Json.String(pm.collection_id),
            "title": Json.String(pm.title),
            "status": Json.String(pm.status),
            "updated_at": pm.updated_at.to_json
          })
        )
      Some(_) | None: Unit
    end
  end

  var inline_refs = []
  raw_body = msg.text_at("body_markdown") or ""
  for rj in ChatOps.extract_entity_refs(raw_body)
    inline_refs = inline_refs.append(try resolve_inline_ref_json(store, auth, rj))
  end

  Ok(
    Json.Object({
      "linked_rows": Json.Array(linked_rows),
      "linked_proposals": Json.Array(linked_proposals),
      "inline_refs": Json.Array(inline_refs)
    })
  )
end

## Strips caller-resolved link/citation details before broadcasting on shared channel SSE topics,
## marking `needs_enrichment: true` when references exist so subscribers fetch their own ACL view.
fn strip_msg_for_sse(msg: Json) : Json
  body = msg.text_at("body_markdown") or ""
  has_refs? = not ChatOps.extract_entity_refs(body).empty?
  has_links? = not VaultOps.json_string_list(msg, "linked_row_ids").empty? or
    not VaultOps.json_string_list(msg, "linked_proposal_ids").empty?
  needs? = has_refs? or has_links?
  case msg
    Json.Object(m): Json.Object(
      m.set("linked_rows", Json.Array([])).set("linked_proposals", Json.Array([])).set(
        "inline_refs",
        Json.Array([])
      ).set("needs_enrichment", Json.Boolean(needs?))
    )
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): msg
  end
end

## Returns ACL-filtered originating chat thread links pointing to `(target_kind, target_id)`.
fn list_origin_chat_threads_for_target(
  store: Store,
  auth: AuthContext,
  target_kind: Text,
  target_id: Text
) : Result(List(Json), AppError)
  raw_links = try ChatOps.scan_chat_links_for_target(store, target_kind, target_id, 50)
  var out = []
  var seen = []
  for lj in raw_links
    cid = lj.text_at("channel_id") or ""
    mid = lj.text_at("message_id") or ""
    dedup = "#{cid}:#{mid}"
    continue if cid.empty? or mid.empty? or seen.contains?(dedup)
    case try ChatOps.get_channel(store, cid)
      Some(ch) if ch.text_at("archived_at") == None and ChatOps.can_access_channel?(
        auth,
        ch,
        "read"
      ):
        case try ChatOps.get_message(store, cid, mid)
          Some(tm) if tm.text_at("deleted_at") == None:
            seen = seen.append(dedup)
            ch_name = ch.text_at("name") or cid
            out = out.append(
              Json.Object({
                "link_kind": Json.String(lj.text_at("link_kind") or "task"),
                "channel_id": Json.String(cid),
                "channel_name": Json.String(ch_name),
                "channel_kind": Json.String(ch.text_at("kind") or "public"),
                "message_id": Json.String(mid),
                "root_message_id": Json.String(tm.text_at("parent_message_id") or mid),
                "author_handle": Json.String(tm.text_at("author_handle") or ""),
                "preview": Json.String(ChatOps.msg_preview(tm.text_at("body_markdown") or "")),
                "created_at": Json.String(
                  lj.text_at("created_at") or (tm.text_at("created_at") or "")
                ),
                "url": Json.String("/chat?channel=#{cid}&message=#{mid}")
              })
            )
          Some(_) | None: Unit
        end
      Some(_) | None: Unit
    end
  end
  Ok(out)
end

## Batch-resolves `{ row_id: [OriginChatThreadLink, ...] }` for `show_database` payloads.
fn row_links_for_rows_json(rf: ReadFiles, auth: AuthContext, rows_json: Json) : Result(
  Json,
  AppError
)
  if not rf.exists?(Db.ledger_db_path)
    return Ok(Json.Object({}))
  end
  var rids = []
  case rows_json
    Json.Array(items):
      for er in items
        row_obj = er.get("row") or Json.Null
        rid = row_obj.text_at("id") or ""
        if not rid.empty? and not rids.contains?(rid)
          rids = rids.append(rid)
        end
      end
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Object(_): Unit
  end
  if rids.empty?
    return Ok(Json.Object({}))
  end
  Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      var out = {}
      for rid in rids
        links = try list_origin_chat_threads_for_target(store, auth, "row", rid)
        if not links.empty?
          out = out.set(rid, Json.Array(links))
        end
      end
      Ok(Json.Object(out))
    end
  )
end

## Resolves ACL-filtered `[OriginChatThreadLink, ...]` for `show_page` (including DB row backing pages).
fn page_origin_threads_json(rf: ReadFiles, auth: AuthContext, page_id: Text) : Result(
  Json,
  AppError
)
  if not rf.exists?(Db.ledger_db_path)
    return Ok(Json.Array([]))
  end
  Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      var links = try list_origin_chat_threads_for_target(store, auth, "page", page_id)
      case try Db.get_page(store, page_id)
        Some(pg):
          case pg.kind
            DatabaseRow(database_id: _, row_id: rid):
              var seen = []
              for l in links
                seen = seen.append("#{l.text_at("channel_id") or ""}:#{l.text_at("message_id") or ""}")
              end
              for rl in try list_origin_chat_threads_for_target(store, auth, "row", rid)
                k = "#{rl.text_at("channel_id") or ""}:#{rl.text_at("message_id") or ""}"
                if not seen.contains?(k)
                  seen = seen.append(k)
                  links = links.append(rl)
                end
              end
            Document: Unit
          end
        None: Unit
      end
      Ok(Json.Array(links))
    end
  )
end

fn append_unique_str(items: List(Text), item: Text) : List(Text)
  if items.contains?(item)
    items
  else
    items.append(item)
  end
end

fn set_msg_str_array(msg: Json, field: Text, item: Text) : Json
  cur = VaultOps.json_string_list(msg, field)
  next = append_unique_str(cur, item)
  case msg
    Json.Object(m): Json.Object(m.set(field, next.to_json))
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): msg
  end
end

fn check_ferpa_boundary_lock(
  store: Store,
  ch: Json,
  target_col_id: Text,
  err_msg: Text
) : Result(Unit, AppError)
  case ChatOps.channel_collection_id(ch)
    Some(ch_col_id):
      ch_ferpa? = try VaultOps.is_ferpa_restricted(store, ch_col_id)
      tgt_ferpa? = try VaultOps.is_ferpa_restricted(store, target_col_id)
      if ch_ferpa? and not tgt_ferpa?
        return Error(Forbidden(reason: err_msg))
      end
    None: Unit
  end
  Ok(Unit)
end

## `POST /api/v1/chat/channels/:id/messages/:msg_id/create-task`
## Creates a live Database Row + backing Page linked bidirectionally with the originating Chat message.
fn create_task_from_message(
  id: Text,
  msg_id: Text,
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if auth.principal.suspended
    return Error(Forbidden(reason: "principal '#{auth.principal.handle}' is suspended"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "chat_channel", id: id))
  end

  body = try VaultOps.parse_req_json_obj(req.text)
  database_id = try VaultOps.req_text(body, "database_id")
  title_opt = opt_trimmed(body, "title")
  reason_opt = opt_trimmed(body, "reason")
  raw_cells = case body.get("cells")
    Some(Json.Object(cm)): try DatabaseModel.decode_cell_map_json(Json.Object(cm).to_text.bytes)
      .map_error(fn(e) BadInput(reason: e) end)
    Some(_): return Error(BadInput(reason: "'cells' must be a JSON object"))
    None: {}
  end

  preflight = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      ch = case try ChatOps.get_channel(store, id)
        Some(c) if c.text_at("archived_at") == None: c
        Some(_) | None: return Error(Missing(entity: "chat_channel", id: id))
      end
      try ChatOps.require_channel_access(auth, ch, "read")
      msg = case try ChatOps.get_message(store, id, msg_id)
        Some(m) if m.text_at("deleted_at") == None: m
        Some(_) | None: return Error(Missing(entity: "chat_message", id: msg_id))
      end
      def = case try Db.get_database(store, database_id)
        Some(d): d
        None: return Error(Missing(entity: "database", id: database_id))
      end
      db_col = case try Db.get_collection(store, def.collection_id)
        Some(col) if col.archived_at == None: col
        Some(_) | None: return Error(Missing(entity: "collection", id: def.collection_id))
      end
      if not Policy.can_write_db_direct?(auth, db_col)
        return Error(
          Forbidden(reason: "grant '#{auth.grant_id}' cannot write rows in '#{def.collection_id}'")
        )
      end
      try check_ferpa_boundary_lock(
        store,
        ch,
        def.collection_id,
        "FERPA Vault prohibits creating a task from restricted chat into a non-FERPA database"
      )
      Ok(Json.Object({"ch": ch, "msg": msg, "db_title": Json.String(def.title)}))
    end
  )

  now = clock.now
  row_id = "row_#{Id.ulid(rng, clock)}"
  row_page_id = "pg_#{Id.ulid(rng, clock)}"
  bpref = "blk_#{Id.ulid(rng, clock)}"
  ch_j = preflight.get("ch") or Json.Null
  msg_j = preflight.get("msg") or Json.Null
  ch_name = ch_j.text_at("name") or id
  ch_kind = ch_j.text_at("kind") or "public"
  ch_label = if ch_kind == "dm"
    ch_name
  else
    "##{ch_name}"
  end
  msg_body = (msg_j.text_at("body_markdown") or "").trim
  msg_author = msg_j.text_at("author_handle") or "unknown"
  preview_txt = ChatOps.msg_preview(msg_body)
  fallback_title = if preview_txt.empty?
    "Task from #{ch_label}"
  else
    preview_txt
  end
  task_md = "Created from **#{ch_label}** by `@#{msg_author}`:\n\n> #{msg_body}\n\n[[thread:#{id}:#{msg_id}]]"
  author_kind = case auth.principal.kind
    Human: HumanAuthor
    Agent: AgentAuthor(model: auth.principal.model_id)
  end
  cit = Citation(
    source_kind: "chat_message",
    source_ref: "#{id}:#{msg_id}",
    label: "Chat #{ch_label}",
    excerpt: Some(preview_txt)
  )
  prov = Provenance(
    author_id: auth.principal.id,
    author_kind: author_kind,
    grant_id: Some(auth.grant_id),
    proposal_id: None,
    reason: Some(reason_opt or "created database task from chat thread"),
    citations: [cit],
    updated_at: now
  )
  link_entry = Json.Object({
    "link_kind": Json.String("task"),
    "channel_id": Json.String(id),
    "message_id": Json.String(msg_id),
    "row_id": Json.String(row_id),
    "page_id": Json.String(row_page_id),
    "database_id": Json.String(database_id),
    "created_by": Json.String(auth.principal.id),
    "created_at": now.to_json
  })

  wmeta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "chat.create_task",
    reason: reason_opt or "created task #{row_id} in #{database_id} from #{id}:#{msg_id}",
    at: now
  )
  tx_res = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    wmeta,
    "created task '#{row_id}' from chat message '#{msg_id}'",
    Json.Object({
      "channel_id": Json.String(id),
      "message_id": Json.String(msg_id),
      "database_id": Json.String(database_id),
      "row_id": Json.String(row_id)
    }),
    Db.map_ledger_error,
    fn(tx)
      t0 = try tx_authorize_if_agent(tx, auth, "write_db", now)
      def = case try Db.tx_get_database(t0, database_id)
        Some(d): d
        None: return Error(Missing(entity: "database", id: database_id))
      end
      msg_cur = case try ChatOps.tx_get_message(t0, id, msg_id)
        Some(m) if m.text_at("deleted_at") == None: m
        Some(_) | None: return Error(Missing(entity: "chat_message", id: msg_id))
      end
      tprop_id = find_title_prop_id(def.properties)
      var merged_cells = raw_cells
      has_title? = case merged_cells.get(tprop_id)
        Some(TextVal(s)) if not s.trim.empty?: true
        Some(_) | None: false
      end
      case title_opt
        Some(t): merged_cells = merged_cells.set(tprop_id, TextVal(t))
        None:
          if not has_title?
            merged_cells = merged_cells.set(tprop_id, TextVal(fallback_title))
          end
      end
      (t1, assigned_cells) = try Db.tx_assign_unique_ids(t0, def, merged_cells)
      row = DbRow(
        id: row_id,
        database_id: def.id,
        page_id: row_page_id,
        cells: assigned_cells,
        created_by: auth.principal.id,
        created_at: now,
        updated_at: now,
        archived_at: None,
        version: 1
      )
      case DatabaseModel.validate_row_cells(def, row)
        Some(err): return Error(BadInput(reason: err))
        None: Unit
      end
      row_title = DatabaseModel.extract_row_title(def, assigned_cells)
      row_page = Page(
        id: row_page_id,
        collection_id: def.collection_id,
        parent_page_id: None,
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
      blks = Blocks.parse_markdown_blocks(row_page_id, task_md, prov, bpref)
      t2 = try Db.tx_put_db_row(t1, def, row, row_page, blks)
      t3 = try Db.tx_put_db_row_editor(t2, row_id, auth.principal.id)
      next_msg = set_msg_str_array(msg_cur, "linked_row_ids", row_id)
      t4 = try ChatOps.tx_put_message(t3, id, msg_id, next_msg)
      t5 = try ChatOps.tx_put_chat_link(t4, "row", row_id, id, msg_id, link_entry)
      t6 = try ChatOps.tx_put_chat_link(t5, "page", row_page_id, id, msg_id, link_entry)
      Ok((
        t6,
        Json.Object({
          "row": row.to_json,
          "page": row_page.to_json,
          "database": def.to_json,
          "message": next_msg
        })
      ))
    end
  )

  raw_updated_msg = tx_res.get("message") or msg_j
  enriched_msg = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      moat = try resolve_message_moat_enrichment(Ledger.store(db), auth, raw_updated_msg)
      case raw_updated_msg
        Json.Object(m): Ok(
          Json.Object(
            m.set("linked_rows", moat.get("linked_rows") or Json.Array([])).set(
              "linked_proposals",
              moat.get("linked_proposals") or Json.Array([])
            ).set("inline_refs", moat.get("inline_refs") or Json.Array([]))
          )
        )
        Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): Ok(
          raw_updated_msg
        )
      end
    end
  )

  sse_msg = strip_msg_for_sse(enriched_msg)
  Ok(
    json_ok(
      201,
      Json.Object({
        "row": tx_res.get("row") or Json.Null,
        "page": tx_res.get("page") or Json.Null,
        "database": tx_res.get("database") or Json.Null,
        "message": enriched_msg
      })
    ).with_sse_publish_json(
      "chat:channel:#{id}",
      "chat.message_updated",
      Json.Object({"channel_id": Json.String(id), "message": sse_msg})
    )
  )
end

## `POST /api/v1/chat/channels/:id/messages/:msg_id/draft-proposal`
## Stages a `Modb.World` Change Proposal appending a cited Callout block onto a Living Doc Page.
fn draft_proposal_from_message(
  id: Text,
  msg_id: Text,
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if auth.principal.suspended
    return Error(Forbidden(reason: "principal '#{auth.principal.handle}' is suspended"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "chat_channel", id: id))
  end

  body = try VaultOps.parse_req_json_obj(req.text)
  target_page_id = try VaultOps.req_text(body, "target_page_id")
  title_opt = opt_trimmed(body, "title")
  reason_opt = opt_trimmed(body, "reason")
  tone = opt_trimmed(body, "tone") or "info"

  preflight = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      ch = case try ChatOps.get_channel(store, id)
        Some(c) if c.text_at("archived_at") == None: c
        Some(_) | None: return Error(Missing(entity: "chat_channel", id: id))
      end
      try ChatOps.require_channel_access(auth, ch, "read")
      msg = case try ChatOps.get_message(store, id, msg_id)
        Some(m) if m.text_at("deleted_at") == None: m
        Some(_) | None: return Error(Missing(entity: "chat_message", id: msg_id))
      end
      pg = case try Db.get_page(store, target_page_id)
        Some(p) if p.archived_at == None: p
        Some(_) | None: return Error(Missing(entity: "page", id: target_page_id))
      end
      try Policy.require_collection_access(auth, "propose", pg.collection_id)
      try check_ferpa_boundary_lock(
        store,
        ch,
        pg.collection_id,
        "FERPA Vault prohibits drafting a proposal from restricted chat onto a non-FERPA page"
      )
      blks = try Db.load_page_blocks(store, pg.id)
      after_bid = case blks.last
        Some(lb): Some(lb.id)
        None: None
      end
      Ok(
        Json.Object({
          "ch": ch,
          "msg": msg,
          "page_col_id": Json.String(pg.collection_id),
          "page_title": Json.String(pg.title),
          "after_block_id": after_bid.to_json
        })
      )
    end
  )

  now = clock.now
  prop_id = "prop_#{Id.ulid(rng, clock)}"
  world_id = "w_#{Id.ulid(rng, clock)}"
  new_bid = "blk_#{Id.ulid(rng, clock)}"
  ch_j = preflight.get("ch") or Json.Null
  msg_j = preflight.get("msg") or Json.Null
  page_col_id = preflight.text_at("page_col_id") or ""
  page_title = preflight.text_at("page_title") or target_page_id
  after_bid_opt = preflight.text_at("after_block_id")

  ch_name = ch_j.text_at("name") or id
  ch_kind = ch_j.text_at("kind") or "public"
  ch_label = if ch_kind == "dm"
    ch_name
  else
    "##{ch_name}"
  end
  msg_body = (msg_j.text_at("body_markdown") or "").trim
  msg_author = msg_j.text_at("author_handle") or "unknown"
  preview_txt = ChatOps.msg_preview(msg_body)
  prop_title = title_opt or "Decision from #{ch_label}: #{preview_txt}"
  clean_reason = reason_opt or "Proposed update to #{page_title} from #{ch_label}"
  note_md = "**Decision from #{ch_label}** (@#{msg_author}): #{msg_body}\n\n_Source:_ [[thread:#{id}:#{msg_id}]]"

  _wrec = try World.open_world_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    world_id,
    auth.grant_id,
    now,
    now + 7.days
  ).map_error(Db.map_world_error)

  author_kind = case auth.principal.kind
    Human: HumanAuthor
    Agent: AgentAuthor(model: auth.principal.model_id)
  end
  cit = Citation(
    source_kind: "chat_message",
    source_ref: "#{id}:#{msg_id}",
    label: "Chat #{ch_label}",
    excerpt: Some(preview_txt)
  )
  prov = Provenance(
    author_id: auth.principal.id,
    author_kind: author_kind,
    grant_id: Some(auth.grant_id),
    proposal_id: Some(prop_id),
    reason: Some(clean_reason),
    citations: [cit],
    updated_at: now
  )
  wargs = WorldPatchArgs(
    page_id: target_page_id,
    ops: [
      InsertBlockAfter(
        after_block_id: after_bid_opt,
        parent_block_id: None,
        kind: Callout(tone: tone, icon: Some("award")),
        markdown: note_md
      )
    ],
    new_ids: [new_bid],
    provenance: prov,
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
    clean_reason,
    now
  ).map_error(Db.map_world_error)

  proposal = ProposalMeta(
    id: prop_id,
    world_id: world_id,
    collection_id: page_col_id,
    target_page_id: target_page_id,
    target_database_id: None,
    branch_kind: "proposal",
    title: prop_title,
    reason: clean_reason,
    author_id: auth.principal.id,
    author_handle: auth.principal.handle,
    grant_id: auth.grant_id,
    status: "open",
    created_at: now,
    updated_at: now,
    decided_by: None,
    decided_at: None
  )
  link_entry = Json.Object({
    "link_kind": Json.String("proposal"),
    "channel_id": Json.String(id),
    "message_id": Json.String(msg_id),
    "proposal_id": Json.String(prop_id),
    "page_id": Json.String(target_page_id),
    "created_by": Json.String(auth.principal.id),
    "created_at": now.to_json
  })

  wmeta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "chat.draft_proposal",
    reason: clean_reason,
    at: now
  )
  tx_res = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    wmeta,
    "drafted proposal '#{prop_id}' from chat message '#{msg_id}'",
    Json.Object({
      "channel_id": Json.String(id),
      "message_id": Json.String(msg_id),
      "proposal_id": Json.String(prop_id),
      "target_page_id": Json.String(target_page_id)
    }),
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "propose", now)
      t2 = try Db.tx_put_proposal(t1, proposal)
      msg_cur = case try ChatOps.tx_get_message(t2, id, msg_id)
        Some(m) if m.text_at("deleted_at") == None: m
        Some(_) | None: return Error(Missing(entity: "chat_message", id: msg_id))
      end
      next_msg = set_msg_str_array(msg_cur, "linked_proposal_ids", prop_id)
      t3 = try ChatOps.tx_put_message(t2, id, msg_id, next_msg)
      t4 = try ChatOps.tx_put_chat_link(t3, "proposal", prop_id, id, msg_id, link_entry)
      t5 = try ChatOps.tx_put_chat_link(t4, "page", target_page_id, id, msg_id, link_entry)
      Ok((t5, Json.Object({"proposal": proposal.to_json, "message": next_msg})))
    end
  )

  raw_updated_msg = tx_res.get("message") or msg_j
  enriched_msg = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      moat = try resolve_message_moat_enrichment(Ledger.store(db), auth, raw_updated_msg)
      case raw_updated_msg
        Json.Object(m): Ok(
          Json.Object(
            m.set("linked_rows", moat.get("linked_rows") or Json.Array([])).set(
              "linked_proposals",
              moat.get("linked_proposals") or Json.Array([])
            ).set("inline_refs", moat.get("inline_refs") or Json.Array([]))
          )
        )
        Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): Ok(
          raw_updated_msg
        )
      end
    end
  )

  sse_msg = strip_msg_for_sse(enriched_msg)
  Ok(
    json_ok(
      201,
      Json.Object({
        "proposal": tx_res.get("proposal") or Json.Null,
        "message": enriched_msg,
        "block_preview": Json.String(note_md)
      })
    ).with_sse_publish_json(
      "chat:channel:#{id}",
      "chat.message_updated",
      Json.Object({"channel_id": Json.String(id), "message": sse_msg})
    )
  )
end

## `GET /api/v1/chat/entities` — ACL-filtered autocomplete list of pages, tasks, and proposals.
fn list_linkable_entities(req: Api.Request, auth: AuthContext, files: Files) : Result(
  Api.Response,
  AppError
)
  if not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  q_low = (req.query_param("q") or "").trim.ascii_lowercase
  kind_filter = (req.query_param("kind") or "").trim.ascii_lowercase
  lim = parse_limit(req.query_param("limit"), 25, 50)
  if not files.read_only.exists?(Db.ledger_db_path)
    return Ok(json_ok(200, Json.Object({"entities": Json.Array([])})))
  end

  payload = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      var items = []
      want_pages? = kind_filter.empty? or kind_filter == "page"
      want_rows? = kind_filter.empty? or kind_filter == "row" or kind_filter == "task"
      want_props? = kind_filter.empty? or kind_filter == "proposal"

      var db_by_id = {}
      all_dbs = try Db.scan_databases(store, 200)
      for (did, def) in all_dbs
        db_by_id = db_by_id.set(did, def)
      end

      if want_pages?
        pg_pairs = try Db.scan_pages(store, 300)
        for (_pid, pg) in pg_pairs
          break if items.size >= lim
          continue if pg.archived_at != None
          continue if not Policy.collection_permitted?(auth, pg.collection_id)
          case pg.kind
            Document:
              hay = "#{pg.title} #{pg.id}".ascii_lowercase
              if q_low.empty? or hay.contains?(q_low)
                items = items.append(
                  Json.Object({
                    "kind": Json.String("page"),
                    "id": Json.String(pg.id),
                    "title": Json.String(pg.title),
                    "subtitle": Json.String("Page"),
                    "collection_id": Json.String(pg.collection_id),
                    "insert_token": Json.String("[[page:#{pg.id}]]"),
                    "url": Json.String("/p/#{pg.id}")
                  })
                )
              end
            DatabaseRow(database_id: _, row_id: _): Unit
          end
        end
      end

      if want_rows?
        row_pairs = try Db.scan_db_rows(store, 300)
        for (_rid, r) in row_pairs
          break if items.size >= lim
          continue if r.archived_at != None
          case db_by_id.get(r.database_id)
            Some(d) if Policy.collection_permitted?(auth, d.collection_id):
              rtitle = DatabaseModel.extract_row_title(d, r.cells)
              hay = "#{rtitle} #{d.title} #{r.id}".ascii_lowercase
              if q_low.empty? or hay.contains?(q_low)
                items = items.append(
                  Json.Object({
                    "kind": Json.String("row"),
                    "id": Json.String(r.id),
                    "title": Json.String(rtitle),
                    "subtitle": Json.String(d.title),
                    "collection_id": Json.String(d.collection_id),
                    "page_id": Json.String(r.page_id),
                    "insert_token": Json.String("[[row:#{r.id}]]"),
                    "url": Json.String("/p/#{r.page_id}")
                  })
                )
              end
            Some(_) | None: Unit
          end
        end
      end

      if want_props?
        prop_pairs = try Db.scan_proposals(store, 200)
        for (_prid, pm) in prop_pairs
          break if items.size >= lim
          continue if not Policy.collection_permitted?(auth, pm.collection_id)
          hay = "#{pm.title} #{pm.id}".ascii_lowercase
          if q_low.empty? or hay.contains?(q_low)
            items = items.append(
              Json.Object({
                "kind": Json.String("proposal"),
                "id": Json.String(pm.id),
                "title": Json.String(pm.title),
                "subtitle": Json.String("Proposal (#{pm.status})"),
                "collection_id": Json.String(pm.collection_id),
                "insert_token": Json.String("[[proposal:#{pm.id}]]"),
                "url": Json.String("/p/#{pm.target_page_id}")
              })
            )
          end
        end
      end

      Ok(Json.Object({"entities": Json.Array(items)}))
    end
  )
  Ok(json_ok(200, payload))
end

fn resolve_import_author(
  by_email: Json,
  by_handle: Json,
  handle_hint: Text,
  email_hint: Option(Text),
  display_hint: Text
) : (Text, Text, Text)
  clean_email = (email_hint or "").trim.ascii_lowercase
  if not clean_email.empty?
    case by_email.get(clean_email)
      Some(pj): return (
        pj.text_at("id") or "slack_user",
        pj.text_at("handle") or "slack_user",
        pj.text_at("display_name") or "Slack User"
      )
      None: Unit
    end
  end
  norm_h = ChatOps.normalize_handle(handle_hint)
  if not norm_h.empty?
    case by_handle.get(norm_h)
      Some(pj): return (
        pj.text_at("id") or "slack_user",
        pj.text_at("handle") or "slack_user",
        pj.text_at("display_name") or "Slack User"
      )
      None: Unit
    end
  end
  disp = if display_hint.trim.empty?
    if norm_h.empty?
      "Slack User"
    else
      norm_h
    end
  else
    display_hint.trim
  end
  final_h = if norm_h.empty?
    "slack_user"
  else
    norm_h
  end
  ("slack:#{final_h}", final_h, disp)
end

fn parse_slack_msg_time(created_at_opt: Option(Text), fallback: Time) : Time
  case created_at_opt
    Some(raw) if not raw.trim.empty?:
      case Time.parse(raw.trim)
        Some(t): t
        None: fallback
      end
    Some(_) | None: fallback
  end
end

fn digits_only(s: Text) : Text
  Text.from_chars(s.chars.filter(fn(c) c.ascii_digit? end))
end

fn pad_zeros_left(s: Text, width: Int) : Text
  var out = s
  while out.chars.size < width
    out = "0#{out}"
  end
  out
end

fn pad_zeros_right(s: Text, width: Int) : Text
  var out = s
  while out.chars.size < width
    out = "#{out}0"
  end
  Text.from_chars(out.chars.take(width))
end

fn format_slack_msg_id(slack_ts: Text, rng: SecureRandom, clock: Clock) : Text
  parts = slack_ts.trim.split(".")
  sec_raw = digits_only(parts.get(0) or "")
  sec_clean = if sec_raw.empty?
    "0"
  else
    sec_raw
  end
  usec_raw = digits_only(parts.get(1) or "")
  sec_padded = pad_zeros_left(sec_clean, 12)
  usec_padded = pad_zeros_right(usec_raw, 6)
  "msg_00#{sec_padded}_#{usec_padded}_#{Id.ulid(rng, clock)}"
end

fn build_ts_msg_map(msgs: List(Json)) : Map(Text, Text)
  var out = {}
  for m in msgs
    ts_opt = m.text_at("slack_ts")
    mid_opt = m.text_at("id")
    case (ts_opt, mid_opt)
      (Some(ts), Some(mid)) if not ts.empty? and not mid.empty?: out = out.set(ts, mid)
      (Some(_), Some(_)) | (Some(_), None) | (None, Some(_)) | (None, None): Unit
    end
  end
  out
end

fn validate_slack_reactions(j: Json) : Json
  case j.get("reactions")
    Some(Json.Object(rm)):
      var clean = {}
      for (em, users_v) in rm.entries
        var ulist = []
        case users_v
          Json.Array(arr):
            for u in arr
              case u
                Json.String(s) if not s.trim.empty?: ulist = ulist.append(s.trim)
                Json.String(_) | Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) |
                  Json.Object(_): Unit
              end
            end
          Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Object(_): Unit
        end
        if not ulist.empty?
          clean = clean.set(em, ulist.to_json)
        end
      end
      Json.Object(clean)
    Some(_) | None: Json.Object({})
  end
end

fn tx_scan_channel_msgs_json(tx: WriteTx, ch_id: Text) : Result(List(Json), AppError)
  prefix = "#{ch_id}:"
  hi = "#{ch_id};"
  rows = try Modb.tx_scan(tx, ChatOps.messages_bucket, Some(prefix.bytes), Some(hi.bytes), 0)
    .map_error(fn(e) ServerFailed(reason: e.to_text) end)
  var out = []
  for (k_bytes, v_bytes) in rows
    k_txt = k_bytes.decode_utf8 or ""
    if k_txt.starts_with?(prefix)
      case v_bytes.decode_utf8
        Some(txt):
          case Json.parse(txt)
            Ok(j): out = out.append(j)
            Error(_): Unit
          end
        None: Unit
      end
    end
  end
  Ok(out)
end

fn find_matching_slack_channel(
  all_chs: List(Json),
  ch_id_override: Option(Text),
  collection_id: Text,
  slack_ch_id: Text,
  ch_slug: Text
) : Option(Json)
  for c in all_chs
    if c.text_at("archived_at") == None
      cid_match? = case ch_id_override
        Some(ov): c.text_at("id") == Some(ov)
        None: false
      end
      same_col? = c.text_at("collection_id") == Some(collection_id)
      slack_match? = same_col? and not slack_ch_id.empty? and
        c.text_at("slack_channel_id") == Some(slack_ch_id)
      slug_match? = same_col? and slack_ch_id.empty? and c.text_at("slug") == Some(ch_slug)
      if cid_match? or slack_match? or slug_match?
        return Some(c)
      end
    end
  end
  None
end

fn update_or_build_slack_channel(
  matched_opt: Option(Json),
  candidate_ch_id: Text,
  workspace_id: Text,
  ch_kind: Text,
  collection_id: Text,
  ch_slug: Text,
  raw_ch_name: Text,
  ch_topic: Text,
  read_only?: Bool,
  slack_ch_id: Text,
  is_private?: Bool,
  creator_id: Text,
  now: Time
) : Json
  slack_id_json = if slack_ch_id.empty?
    Json.Null
  else
    Json.String(slack_ch_id)
  end
  members = if is_private?
    [creator_id]
  else
    []
  end
  case matched_opt
    Some(existing_c):
      case existing_c
        Json.Object(m):
          var m2 = m
          if read_only?
            m2 = m2.set("read_only", Json.Boolean(true))
          end
          if not ch_topic.empty? and (existing_c.text_at("topic") or "").empty?
            m2 = m2.set("topic", Json.String(ch_topic))
          end
          if not slack_ch_id.empty? and (existing_c.text_at("slack_channel_id") or "").empty?
            m2 = m2.set("slack_channel_id", Json.String(slack_ch_id))
          end
          Json.Object(m2)
        Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): existing_c
      end
    None:
      Json.Object({
        "id": Json.String(candidate_ch_id),
        "workspace_id": Json.String(workspace_id),
        "kind": Json.String(ch_kind),
        "collection_id": Json.String(collection_id),
        "slug": Json.String(ch_slug),
        "name": Json.String(raw_ch_name),
        "topic": Json.String(ch_topic),
        "read_only": Json.Boolean(read_only?),
        "source_type": Json.String("slack"),
        "slack_channel_id": slack_id_json,
        "member_principal_ids": members.to_json,
        "archived_at": Json.Null,
        "created_by": Json.String(creator_id),
        "created_at": now.to_json,
        "updated_at": now.to_json,
        "last_message_at": Json.Null,
        "last_message_id": Json.Null
      })
  end
end

fn tx_import_one_slack_message(
  tx: WriteTx,
  ch_id: Text,
  mj: Json,
  idx: Int,
  ts_map: Map(Text, Text),
  by_email: Json,
  by_handle: Json,
  candidate_mid: Text,
  now: Time
) : Result((WriteTx, Map(Text, Text), Bool, Option(Text), Option(Text)), AppError)
  slack_ts = try VaultOps.req_text(mj, "ts")
  case try ChatOps.tx_lookup_idempotency(tx, ch_id, "slack_import", slack_ts)
    Some(existing_mid):
      return Ok((tx, ts_map.set(slack_ts, existing_mid), false, None, None))
    None: Unit
  end
  raw_txt = (mj.text_at("text") or "").trim
  att_ids = VaultOps.json_string_list(mj, "attachment_ids")
  if raw_txt.empty? and att_ids.empty?
    return Ok((tx, ts_map, false, None, None))
  end
  for aid in att_ids
    att = case try Db.tx_get_attachment(tx, aid)
      Some(a): a
      None: return Error(BadInput(reason: "attachment '#{aid}' does not exist"))
    end
    if att.page_id != ch_id
      return Error(
        Forbidden(reason: "attachment '#{aid}' is not scoped to Slack target channel '#{ch_id}'")
      )
    end
  end
  t_parsed = parse_slack_msg_time(opt_trimmed(mj, "created_at"), now)
  t_msg = t_parsed + idx.milliseconds
  new_mid = candidate_mid
  thread_ts_opt = opt_trimmed(mj, "thread_ts")
  parent_mid_opt = case thread_ts_opt
    Some(tts) if tts != slack_ts: ts_map.get(tts)
    Some(_) | None: None
  end
  (a_id, a_handle, a_display) = resolve_import_author(
    by_email,
    by_handle,
    mj.text_at("author_handle") or "",
    opt_trimmed(mj, "author_email"),
    mj.text_at("author_name") or ""
  )
  mentions = ChatOps.extract_mentions(raw_txt)
  reactions_j = validate_slack_reactions(mj)
  is_dec? = mj.bool_at("is_decision") or false
  m_json = Json.Object({
    "id": Json.String(new_mid),
    "channel_id": Json.String(ch_id),
    "parent_message_id": parent_mid_opt.to_json,
    "author_id": Json.String(a_id),
    "author_handle": Json.String(a_handle),
    "author_display_name": Json.String(a_display),
    "author_kind": Json.String("human"),
    "body_markdown": Json.String(raw_txt),
    "mentions": mentions.to_json,
    "attachment_ids": att_ids.to_json,
    "reactions": reactions_j,
    "linked_row_ids": Json.Array([]),
    "linked_proposal_ids": Json.Array([]),
    "is_decision": Json.Boolean(is_dec?),
    "source_type": Json.String("slack"),
    "slack_ts": Json.String(slack_ts),
    "slack_thread_ts": thread_ts_opt.to_json,
    "client_msg_id": Json.String("slack:#{slack_ts}"),
    "edited_at": Json.Null,
    "deleted_at": Json.Null,
    "created_at": t_msg.to_json
  })
  t1 = try ChatOps.tx_put_message(tx, ch_id, new_mid, m_json)
  t2 = try ChatOps.tx_put_idempotency(t1, ch_id, "slack_import", slack_ts, new_mid)
  Ok((t2, ts_map.set(slack_ts, new_mid), true, Some(new_mid), m_json.text_at("created_at")))
end

## `POST /api/v1/chat/import/slack`
## Idempotently creates/resolves a target Slack channel and imports chronological message batches
## preserving `thread_ts` -> `parent_message_id`, attachments, reactions, and read-only archive status.
fn import_slack_batch(
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if auth.principal.suspended
    return Error(Forbidden(reason: "principal '#{auth.principal.handle}' is suspended"))
  end
  if auth.principal.kind == Human
    is_admin? = auth.principal.role == Owner or auth.principal.role == Admin
    if not is_admin?
      return Error(Forbidden(reason: "Slack archive import requires an Owner or Admin principal"))
    end
  else
    if not Policy.action_permitted?(auth, "write_direct") or
      not Policy.action_permitted?(auth, "manage_schema")
      return Error(
        Forbidden(
          reason: "Slack archive import agent token requires 'write_direct' and 'manage_schema'"
        )
      )
    end
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "workspace", id: Db.default_workspace_id))
  end

  body = try VaultOps.parse_req_json_obj(req.text)
  collection_id = try VaultOps.req_text(body, "collection_id")
  try Policy.require_collection_access(auth, "write_direct", collection_id)
  if auth.principal.kind == Agent
    try Policy.require_collection_access(auth, "manage_schema", collection_id)
  end

  ch_req = case body.get("channel")
    Some(Json.Object(cm)): Json.Object(cm)
    Some(_) | None: return Error(BadInput(reason: "missing object field 'channel'"))
  end
  ch_id_override = opt_trimmed(ch_req, "id")
  slack_ch_id = opt_trimmed(ch_req, "slack_id") or ""
  raw_ch_name = opt_trimmed(ch_req, "name") or "slack-import"
  ch_slug = ChatOps.slugify_channel(raw_ch_name)
  ch_topic = (ch_req.text_at("topic") or "").trim
  is_private? = ch_req.bool_at("is_private") or false
  read_only? = ch_req.bool_at("read_only") or false
  ch_kind = if is_private?
    "private"
  else
    "public"
  end

  raw_msgs = case body.get("messages")
    Some(Json.Array(ms)):
      if ms.size > 200
        return Error(BadInput(reason: "messages batch exceeds maximum 200 items"))
      end
      ms
    Some(_): return Error(BadInput(reason: "'messages' must be a JSON array"))
    None: []
  end

  now = clock.now
  candidate_ch_id = ch_id_override or "ch_#{Id.ulid(rng, clock)}"
  var pre_msg_ids = []
  for (idx, item) in raw_msgs.enumerate
    slack_ts_pre = case item
      Json.Object(_): item.text_at("ts") or "#{idx}"
      Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): "#{idx}"
    end
    pre_msg_ids = pre_msg_ids.append(format_slack_msg_id(slack_ts_pre, rng, clock))
  end

  principals_idx = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      pairs = try Db.scan_principals(Ledger.store(db), 500)
      var by_email = {}
      var by_handle = {}
      for (_pid, p) in pairs
        continue if p.suspended
        pj = Json.Object({
          "id": Json.String(p.id),
          "handle": Json.String(p.handle),
          "display_name": Json.String(p.display_name)
        })
        norm_h = ChatOps.normalize_handle(p.handle)
        if not norm_h.empty?
          by_handle = by_handle.set(norm_h, pj)
        end
        case p.email
          Some(em) if not em.trim.empty?:
            by_email = by_email.set(em.trim.ascii_lowercase, pj)
          Some(_) | None: Unit
        end
      end
      Ok(Json.Object({"by_email": Json.Object(by_email), "by_handle": Json.Object(by_handle)}))
    end
  )
  by_email_j = principals_idx.get("by_email") or Json.Object({})
  by_handle_j = principals_idx.get("by_handle") or Json.Object({})

  wmeta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "chat.import_slack",
    reason: "imported #{raw_msgs.size} Slack messages into ##{ch_slug}",
    at: now
  )
  tx_res = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    wmeta,
    "imported Slack batch into ##{ch_slug}",
    Json.Object({
      "collection_id": Json.String(collection_id),
      "slack_channel_id": Json.String(slack_ch_id),
      "channel_slug": Json.String(ch_slug),
      "batch_size": Json.int(raw_msgs.size)
    }),
    Db.map_ledger_error,
    fn(tx)
      t0 = try tx_authorize_if_agent(tx, auth, "write_direct", now)
      col = case try Db.tx_get_collection(t0, collection_id)
        Some(c) if c.archived_at == None: c
        Some(_) | None: return Error(Missing(entity: "collection", id: collection_id))
      end
      if not Policy.can_write_page_direct?(auth, col)
        return Error(
          Forbidden(
            reason: "collection '#{col.id}' write policy prohibits direct Slack import writes"
          )
        )
      end

      all_chs = try VaultOps.tx_scan_json(t0, ChatOps.channels_bucket, 500)
      matched_opt = find_matching_slack_channel(
        all_chs,
        ch_id_override,
        collection_id,
        slack_ch_id,
        ch_slug
      )
      ch_json = update_or_build_slack_channel(
        matched_opt,
        candidate_ch_id,
        col.workspace_id,
        ch_kind,
        collection_id,
        ch_slug,
        raw_ch_name,
        ch_topic,
        read_only?,
        slack_ch_id,
        is_private?,
        auth.principal.id,
        now
      )
      ch_id = ch_json.text_at("id") or candidate_ch_id
      var cur_tx = try ChatOps.tx_put_channel(t0, ch_id, ch_json)

      existing_msgs = try tx_scan_channel_msgs_json(cur_tx, ch_id)
      var ts_map = build_ts_msg_map(existing_msgs)
      var created_count = 0
      var skipped_count = 0
      var last_msg_id = ch_json.text_at("last_message_id")
      var last_msg_at = ch_json.text_at("last_message_at")

      for (idx, item) in raw_msgs.enumerate
        mj = case item
          Json.Object(_): item
          Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_):
            return Error(BadInput(reason: "each Slack message item must be a JSON object"))
        end
        cand_mid = pre_msg_ids.get(idx) or "msg_00#{idx}"
        (next_tx, next_ts_map, created?, new_mid_opt, new_mat_opt) = try tx_import_one_slack_message(
          cur_tx,
          ch_id,
          mj,
          idx,
          ts_map,
          by_email_j,
          by_handle_j,
          cand_mid,
          now
        )
        cur_tx = next_tx
        ts_map = next_ts_map
        if created?
          created_count += 1
          last_msg_id = new_mid_opt
          last_msg_at = new_mat_opt
        else
          skipped_count += 1
        end
      end

      final_ch = case ch_json
        Json.Object(cm): Json.Object(
          cm.set("last_message_id", last_msg_id.to_json).set(
            "last_message_at",
            last_msg_at.to_json
          ).set("updated_at", now.to_json)
        )
        Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): ch_json
      end
      cur_tx = try ChatOps.tx_put_channel(cur_tx, ch_id, final_ch)
      Ok((
        cur_tx,
        Json.Object({
          "channel": final_ch,
          "created_count": Json.int(created_count),
          "skipped_count": Json.int(skipped_count)
        })
      ))
    end
  )
  Ok(json_ok(200, tx_res))
end
