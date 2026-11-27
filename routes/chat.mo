## Unified Vellum Chat API, Inertia `/chat` surface, Calm Inbox, Reactions & FERPA Audit.
module Routes.Chat
expose chat_page,
list_channels,
create_channel,
update_channel,
list_messages,
post_message,
edit_message,
delete_message,
toggle_reaction,
mark_channel_read,
list_inbox,
ack_inbox,
search_chat
use Api
use Arvo.Flash
use Arvo.Id
use Arvo.Inertia
use ChatOps
use Db
use Domain.Policy
use Domain.Types{AppError, Attachment, AuthContext, Principal, PrincipalKind, WorkspaceRole}
use Json
use Modb{Store}
use Modb.Grants
use Modb.Ledger
use Modb.Table
use Routes.Auth
use VaultOps

fn json_ok(status: Int, body: Json) : Api.Response
  Api.encoded_json_response(status, body).with_header(
    "Content-Type",
    "application/json; charset=utf-8"
  )
end

fn parse_json_object_body(req: Api.Request) : Result(Json, AppError)
  if req.body.empty?
    return Ok(Json.Object({}))
  end
  parsed = case Json.parse(req.text or "")
    Ok(j): j
    Error(_): return Error(BadInput(reason: "invalid JSON body"))
  end
  case parsed
    Json.Object(_): Ok(parsed)
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): Error(
      BadInput(reason: "expected JSON object")
    )
  end
end

fn parse_limit(raw: Option(Text), default_val: Int, max_val: Int) : Int
  case raw
    Some(s):
      case s.trim.to_int
        Some(n): if n < 1: 1 else if n > max_val: max_val else: n
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

fn tx_authorize_if_agent(tx: Modb.WriteTx, auth: AuthContext, action: Text, now: Time) : Result(
  Modb.WriteTx,
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

fn require_channel_post_access(auth: AuthContext, ch: Json) : Result(Text, AppError)
  if ChatOps.can_access_channel?(auth, ch, "write_direct")
    Ok("write_direct")
  else if ChatOps.can_access_channel?(auth, ch, "comment")
    Ok("comment")
  else
    _ = try ChatOps.require_channel_access(auth, ch, "comment")
    Error(Forbidden(reason: "not permitted to post in channel"))
  end
end

fn principal_directory_json(p: Principal) : Json
  Json.Object({
    "id": Json.String(p.id),
    "kind": p.kind.to_json,
    "handle": Json.String(p.handle),
    "display_name": Json.String(p.display_name),
    "role": p.role.to_json
  })
end

fn list_active_principals(store: Store) : Result(List(Principal), AppError)
  rows = try Db.scan_principals(store, 500)
  var out = []
  for (_id, p) in rows
    if not p.suspended
      out = out.append(p)
    end
  end
  Ok(out.sort_by(fn(p) "#{p.display_name.ascii_lowercase}|#{p.id}" end))
end

fn principal_can_read_channel?(store: Store, p: Principal, ch: Json, now: Time) : Bool
  return false if p.suspended
  grant = case Db.verify_grant_chain_read_only(store, p.root_grant_id, now)
    Ok(g): g
    Error(_): return false
  end
  eff_views = case VaultOps.apply_vault_restrictions(store, p.id, grant.allowed_views)
    Ok(vs): vs
    Error(_): return false
  end
  p_auth = AuthContext(
    principal: p,
    grant_id: grant.id,
    session: None,
    allowed_collections: eff_views,
    allowed_actions: grant.allowed_actions
  )
  ChatOps.can_access_channel?(p_auth, ch, "read")
end

fn enrich_channel_json(store: Store, principal_id: Text, ch: Json) : Result(Json, AppError)
  ch_id = ch.text_at("id") or ""
  unread = try ChatOps.count_channel_unread(store, principal_id, ch_id)
  ferpa? = case ChatOps.channel_collection_id(ch)
    Some(cid): try VaultOps.is_ferpa_restricted(store, cid)
    None: false
  end
  sec_tier = if ferpa?: "ferpa_restricted" else: "standard"
  case ch
    Json.Object(m): Ok(
      Json.Object(
        m.set("unread_count", Json.int(unread))
          .set("ferpa_restricted", Json.Boolean(ferpa?))
          .set("security_tier", Json.String(sec_tier))
      )
    )
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): Ok(ch)
  end
end

fn attachment_summary_json(a: Attachment) : Json
  Json.Object({
    "id": Json.String(a.id),
    "filename": Json.String(a.filename),
    "content_type": Json.String(a.content_type),
    "size_bytes": Json.int(a.size_bytes),
    "download_url": Json.String("/api/attachments/#{a.id}/download")
  })
end

fn enrich_message_json(store: Store, msg: Json, reply_count: Int) : Result(Json, AppError)
  var att_objs = []
  for aid in VaultOps.json_string_list(msg, "attachment_ids")
    case try Table.get(store, Db.attachments_table(), aid).map_error(Db.map_table_error)
      Some(att): att_objs = att_objs.append(attachment_summary_json(att))
      None: Unit
    end
  end
  case msg
    Json.Object(m): Ok(
      Json.Object(
        m.set("reply_count", Json.int(reply_count)).set("attachments", Json.Array(att_objs))
      )
    )
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): Ok(msg)
  end
end

fn load_visible_channels_and_state(store: Store, auth: AuthContext) : Result(
  (List(Json), Int, List(Json)),
  AppError
)
  all_ch = try ChatOps.list_all_channels(store)
  var visible = []
  for ch in all_ch
    if ch.text_at("archived_at") == None and ChatOps.can_access_channel?(auth, ch, "read")
      visible = visible.append(try enrich_channel_json(store, auth.principal.id, ch))
    end
  end
  inbox_unread = try ChatOps.unread_inbox_count(store, auth.principal.id)
  principals = try list_active_principals(store)
  p_jsons = principals.map(fn(p) principal_directory_json(p) end)
  Ok((visible, inbox_unread, p_jsons))
end

## `GET /chat` — Renders the Unified Vellum Chat Inertia workspace (`Workspace/Chat`).
fn chat_page(req: Api.Request, auth: Option(AuthContext), rf: ReadFiles, env: Env) : Result(
  Api.Response,
  AppError
)
  a = case auth
    Some(x): x
    None: return Auth.guest_redirect_or_401(req, env)
  end
  if a.principal.suspended or not Policy.action_permitted?(a, "read")
    return Error(Forbidden(reason: "grant '#{a.grant_id}' does not permit 'read'"))
  end

  data_json = if not rf.exists?(Db.ledger_db_path)
    Json.Object({
      "collections": Json.Array([]),
      "databases": Json.Array([]),
      "channels": Json.Array([]),
      "principals": Json.Array([]),
      "inbox_unread_count": Json.int(0)
    })
  else
    try Ledger.read_locked(
      rf,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        store = Ledger.store(db)
        c_rows = try Table.scan(store, Db.collections_table(), None, None, 200).map_error(
          Db.map_table_error
        )
        var c_list = []
        for (_cid, c) in c_rows
          if c.archived_at == None and Policy.collection_permitted?(a, c.id)
            c_list = c_list.append(c)
          end
        end
        d_rows = try Table.scan(store, Db.databases_table(), None, None, 200).map_error(
          Db.map_table_error
        )
        var d_list = []
        for (_did, d) in d_rows
          if Policy.collection_permitted?(a, d.collection_id)
            d_list = d_list.append(d)
          end
        end
        (chs, ucnt, plist) = try load_visible_channels_and_state(store, a)
        Ok(
          Json.Object({
            "collections": c_list.to_json,
            "databases": d_list.to_json,
            "channels": Json.Array(chs),
            "principals": Json.Array(plist),
            "inbox_unread_count": Json.int(ucnt)
          })
        )
      end
    )
  end

  init_ch_opt = opt_trimmed(
    Json.Object({"c": (req.query_param("channel") or "").to_json}),
    "c"
  )
  init_msg_opt = opt_trimmed(Json.Object({"m": (req.query_param("msg") or "").to_json}), "m")
  page_props = {
    "collections": data_json.get("collections") or Json.Array([]),
    "databases": data_json.get("databases") or Json.Array([]),
    "channels": data_json.get("channels") or Json.Array([]),
    "principals": data_json.get("principals") or Json.Array([]),
    "inbox_unread_count": data_json.get("inbox_unread_count") or Json.int(0),
    "initial_channel_id": init_ch_opt.to_json,
    "initial_message_id": init_msg_opt.to_json
  }

  if Auth.wants_json?(req)
    return Ok(json_ok(200, Json.Object(page_props)))
  end

  icfg = try Auth.load_inertia_config(rf, env)
  if Inertia.check_version(req, icfg) is Some(ver_res)
    return Ok(ver_res)
  end
  (shared, had_flash?) = try Auth.shared_props_for(req, Some(a), rf, env)
  res = Inertia.render(req, icfg, "Workspace/Chat", page_props, shared)
  Ok(Flash.clear_if_present(res, had_flash?, Auth.secure_cookies?(env)))
end

## `GET /api/v1/chat/channels` — Lists ACL + FERPA Vault filtered channels, DMs, and unread counts.
fn list_channels(auth: AuthContext, rf: ReadFiles) : Result(Api.Response, AppError)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Ok(
      json_ok(
        200,
        Json.Object({
          "channels": Json.Array([]),
          "inbox_unread_count": Json.int(0),
          "principals": Json.Array([])
        })
      )
    )
  end
  payload = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      (chs, ucnt, plist) = try load_visible_channels_and_state(Ledger.store(db), auth)
      Ok(
        Json.Object({
          "channels": Json.Array(chs),
          "inbox_unread_count": Json.int(ucnt),
          "principals": Json.Array(plist)
        })
      )
    end
  )
  Ok(json_ok(200, payload))
end

## `POST /api/v1/chat/channels` — Creates a public/private collection channel or deduplicated 1:1 / group DM.
fn create_channel(
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
  body = try parse_json_object_body(req)
  kind = (body.text_at("kind") or "public").trim.ascii_lowercase
  if kind != "public" and kind != "private" and kind != "dm"
    return Error(BadInput(reason: "channel kind must be 'public', 'private', or 'dm'"))
  end

  raw_name = (body.text_at("name") or "").trim
  topic = (body.text_at("topic") or "").trim
  col_id_opt = opt_trimmed(body, "collection_id")
  raw_members = VaultOps.json_string_list(body, "member_principal_ids")
  now = clock.now

  if kind == "dm"
    if not Policy.action_permitted?(auth, "write_direct")
      return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit creating DMs"))
    end
    var clean_members = [auth.principal.id]
    for m in raw_members
      if not clean_members.contains?(m)
        clean_members = clean_members.append(m)
      end
    end
    if clean_members.size < 2
      return Error(BadInput(reason: "DM requires at least 1 other member_principal_ids"))
    end

    # Validate members and reuse existing active 1:1 DM if present
    dm_pre = if files.read_only.exists?(Db.ledger_db_path)
      try Ledger.read_locked(
        files.read_only,
        Db.ledger_db_path,
        Db.vellum_schema(),
        Db.map_ledger_error,
        fn(db)
          store = Ledger.store(db)
          var names = []
          for mid in clean_members
            p = case try Table.get(store, Db.principals_table(), mid).map_error(Db.map_table_error)
              Some(found) if not found.suspended: found
              Some(_) | None: return Error(Missing(entity: "principal", id: mid))
            end
            if mid != auth.principal.id
              names = names.append(p.display_name)
            end
          end
          ex = if clean_members.size == 2
            case try ChatOps.find_existing_dm(store, clean_members)
              Some(ch): Some(try enrich_channel_json(store, auth.principal.id, ch))
              None: None
            end
          else
            None
          end
          Ok(Json.Object({"existing": ex.to_json, "names": names.to_json}))
        end
      )
    else
      Json.Object({"existing": Json.Null, "names": Json.Array([])})
    end

    case dm_pre.get("existing")
      Some(Json.Object(em)):
        return Ok(
          json_ok(
            200,
            Json.Object({"channel": Json.Object(em), "existing": Json.Boolean(true)})
          )
        )
      Some(Json.Null) | Some(Json.Boolean(_)) | Some(Json.Number(_)) | Some(Json.String(_)) | Some(
        Json.Array(_)
      ) | None: Unit
    end
    validated_names = VaultOps.json_string_list(dm_pre, "names")

    dm_name = if raw_name.empty?: "DM: #{validated_names.join(", ")}" else: raw_name
    ch_id = "ch_#{Id.ulid(rng, clock)}"
    dm_slug = "dm-#{ChatOps.slugify_channel(ch_id)}"
    ch_json = Json.Object({
      "id": Json.String(ch_id),
      "kind": Json.String("dm"),
      "collection_id": Json.Null,
      "slug": Json.String(dm_slug),
      "name": Json.String(dm_name),
      "topic": Json.String(topic),
      "member_principal_ids": clean_members.to_json,
      "archived_at": Json.Null,
      "created_by": Json.String(auth.principal.id),
      "created_at": now.to_json,
      "updated_at": now.to_json,
      "last_message_at": Json.Null,
      "last_message_id": Json.Null
    })
    wmeta = Ledger.WriteMeta(
      principal: auth.principal.handle,
      action: "chat.channel_create",
      reason: "created DM channel '#{dm_name}'",
      at: now
    )
    _saved = try Ledger.transact_locked(
      files,
      Db.ledger_db_path,
      Db.vellum_schema(),
      wmeta,
      "created DM channel '#{ch_id}'",
      ch_json,
      Db.map_ledger_error,
      fn(tx)
        t1 = try tx_authorize_if_agent(tx, auth, "write_direct", now)
        t2 = try ChatOps.tx_put_channel(t1, ch_id, ch_json)
        Ok((t2, Unit))
      end
    )
    enriched = try Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db) enrich_channel_json(Ledger.store(db), auth.principal.id, ch_json) end
    )
    return Ok(json_ok(201, Json.Object({"channel": enriched, "existing": Json.Boolean(false)})))
  end

  # Public or private collection-scoped channel
  col_id = case col_id_opt
    Some(c): c
    None: return Error(BadInput(reason: "collection_id is required for #{kind} channels"))
  end
  try Policy.require_collection_access(auth, "write_direct", col_id)
  if raw_name.empty?
    return Error(BadInput(reason: "channel name must not be empty"))
  end

  slug = ChatOps.slugify_channel(raw_name)
  var clean_members = if kind == "private": [auth.principal.id] else: []
  for m in raw_members
    if kind == "private" and not clean_members.contains?(m)
      clean_members = clean_members.append(m)
    end
  end

  ch_id = "ch_#{Id.ulid(rng, clock)}"
  ch_json = Json.Object({
    "id": Json.String(ch_id),
    "kind": Json.String(kind),
    "collection_id": Json.String(col_id),
    "slug": Json.String(slug),
    "name": Json.String(raw_name),
    "topic": Json.String(topic),
    "member_principal_ids": clean_members.to_json,
    "archived_at": Json.Null,
    "created_by": Json.String(auth.principal.id),
    "created_at": now.to_json,
    "updated_at": now.to_json,
    "last_message_at": Json.Null,
    "last_message_id": Json.Null
  })

  wmeta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "chat.channel_create",
    reason: "created #{kind} chat channel ##{slug}",
    at: now
  )
  _saved = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    wmeta,
    "created chat channel ##{slug} (#{ch_id})",
    ch_json,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "write_direct", now)
      _col = case try Table.tx_get(t1, Db.collections_table(), col_id).map_error(Db.map_table_error)
        Some(c) if c.archived_at == None: c
        Some(_) | None: return Error(Missing(entity: "collection", id: col_id))
      end
      if kind == "private"
        for mid in clean_members
          _p = case try Db.tx_get_principal(t1, mid)
            Some(found) if not found.suspended: found
            Some(_) | None: return Error(Missing(entity: "principal", id: mid))
          end
        end
      end
      t2 = try ChatOps.tx_put_channel(t1, ch_id, ch_json)
      Ok((t2, Unit))
    end
  )
  enriched = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db) enrich_channel_json(Ledger.store(db), auth.principal.id, ch_json) end
  )
  Ok(json_ok(201, Json.Object({"channel": enriched, "existing": Json.Boolean(false)})))
end

## `PATCH /api/v1/chat/channels/:id` — Updates channel metadata, private/DM members, or archive status.
fn update_channel(
  id: Text,
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if auth.principal.suspended
    return Error(Forbidden(reason: "principal '#{auth.principal.handle}' is suspended"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "chat_channel", id: id))
  end
  body = try parse_json_object_body(req)
  now = clock.now
  is_admin? = auth.principal.role == Owner or auth.principal.role == Admin

  wmeta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "chat.channel_update",
    reason: "updated chat channel '#{id}'",
    at: now
  )
  updated = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    wmeta,
    "updated chat channel '#{id}'",
    Json.Object({"channel_id": Json.String(id)}),
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "write_direct", now)
      old_ch = case try ChatOps.tx_get_channel(t1, id)
        Some(c): c
        None: return Error(Missing(entity: "chat_channel", id: id))
      end
      try ChatOps.require_channel_access(auth, old_ch, "write_direct")
      creator? = old_ch.text_at("created_by") == Some(auth.principal.id)
      if not creator? and not is_admin?
        return Error(Forbidden(reason: "only channel creator or Owner/Admin may update channel"))
      end
      kind = old_ch.text_at("kind") or "public"
      old_m = case old_ch
        Json.Object(m): m
        Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
          ServerFailed(reason: "corrupt channel record")
        )
      end
      var next_m = old_m.set("updated_at", now.to_json)
      case opt_trimmed(body, "name")
        Some(nm):
          next_m = next_m.set("name", Json.String(nm))
          if kind != "dm"
            next_m = next_m.set("slug", Json.String(ChatOps.slugify_channel(nm)))
          end
        None: Unit
      end
      case body.text_at("topic")
        Some(tp): next_m = next_m.set("topic", Json.String(tp.trim))
        None: Unit
      end
      case body.list_at("member_principal_ids")
        Some(_xs):
          if kind == "private" or kind == "dm"
            var next_members = []
            for m in VaultOps.json_string_list(body, "member_principal_ids")
              if not next_members.contains?(m)
                _p = case try Db.tx_get_principal(t1, m)
                  Some(found) if not found.suspended: found
                  Some(_) | None: return Error(Missing(entity: "principal", id: m))
                end
                next_members = next_members.append(m)
              end
            end
            creator_id = old_ch.text_at("created_by") or auth.principal.id
            if not next_members.contains?(creator_id)
              next_members = [creator_id].concat(next_members)
            end
            if kind == "dm" and next_members.size < 2
              return Error(BadInput(reason: "DM requires at least 2 members"))
            end
            next_m = next_m.set("member_principal_ids", next_members.to_json)
          end
        None: Unit
      end
      case body.bool_at("archived")
        Some(true): next_m = next_m.set("archived_at", now.to_json)
        Some(false): next_m = next_m.set("archived_at", Json.Null)
        None: Unit
      end
      next_ch = Json.Object(next_m)
      t2 = try ChatOps.tx_put_channel(t1, id, next_ch)
      Ok((t2, next_ch))
    end
  )
  enriched = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db) enrich_channel_json(Ledger.store(db), auth.principal.id, updated) end
  )
  Ok(json_ok(200, Json.Object({"channel": enriched})))
end

## `GET /api/v1/chat/channels/:id/messages` — Paginates channel messages or side-thread replies (with FERPA read audit).
fn list_messages(
  id: Text,
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "chat_channel", id: id))
  end

  lim = parse_limit(req.query_param("limit"), 50, 100)
  before_opt = req.query_param("before")
  after_opt = req.query_param("after")
  parent_opt = req.query_param("parent_message_id")
  decisions_only? = req.query_param("decisions_only") == Some("1")

  list_res = try Ledger.read_locked(
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
      enr_ch = try enrich_channel_json(store, auth.principal.id, ch)
      (win, has_more?, reply_counts) = try ChatOps.scan_channel_messages_window(
        store,
        id,
        before_opt,
        after_opt,
        parent_opt,
        decisions_only?,
        lim
      )
      var enr_msgs = []
      for m in win
        mid = m.text_at("id") or ""
        rc = reply_counts.get(mid) or 0
        enr_msgs = enr_msgs.append(try enrich_message_json(store, m, rc))
      end
      next_before = case enr_msgs.first
        Some(f): f.text_at("id")
        None: None
      end
      next_after = case enr_msgs.last
        Some(l): l.text_at("id")
        None: None
      end
      fcol = case ChatOps.channel_collection_id(ch)
        Some(cid): if try VaultOps.is_ferpa_restricted(store, cid): Some(cid) else: None
        None: None
      end
      res_j = Json.Object({
        "channel": enr_ch,
        "messages": Json.Array(enr_msgs),
        "has_more": Json.Boolean(has_more?),
        "next_before_cursor": next_before.to_json,
        "next_after_cursor": next_after.to_json
      })
      Ok(Json.Object({"payload": res_j, "ferpa_col": fcol.to_json}))
    end
  )
  payload = list_res.get("payload") or Json.Object({})
  ferpa_col_opt = opt_trimmed(list_res, "ferpa_col")

  case ferpa_col_opt
    Some(fcid): try VaultOps.record_ferpa_read_audit_locked(
      files,
      rng,
      clock,
      auth,
      "chat.channel_viewed",
      fcid,
      "chat_channel",
      id,
      "Viewed FERPA Restricted chat channel '#{id}'"
    )
    None: Unit
  end
  Ok(json_ok(200, payload))
end

## `POST /api/v1/chat/channels/:id/messages` — Posts an idempotent channel message/thread reply + Calm Inbox notifications + SSE.
fn post_message(
  id: Text,
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

  body = try parse_json_object_body(req)
  raw_md = (body.text_at("body_markdown") or "").trim
  att_ids = VaultOps.json_string_list(body, "attachment_ids")
  if raw_md.empty? and att_ids.empty?
    return Error(BadInput(reason: "body_markdown or attachment_ids must not be empty"))
  end
  parent_opt = opt_trimmed(body, "parent_message_id")
  client_msg_opt = opt_trimmed(body, "client_msg_id")
  is_decision? = body.bool_at("is_decision") or false
  now = clock.now

  # Preflight read-only check: ACL, idempotent replay, parent/attachment validation, and FERPA-safe notification recipients
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
      act = try require_channel_post_access(auth, ch)

      case client_msg_opt
        Some(cmid):
          raw_key = "#{id}:#{auth.principal.id}:#{cmid}"
          case try Modb.get(store, ChatOps.idempotency_bucket, raw_key.bytes).map_error(fn(e)
            ServerFailed(reason: e.to_text)
          end)
            Some(mid_b):
              case mid_b.decode_utf8
                Some(ex_id):
                  case try ChatOps.get_message(store, id, ex_id.trim)
                    Some(ex_msg):
                      enr = try enrich_message_json(store, ex_msg, 0)
                      return Ok(
                        Json.Object({
                          "existing": enr,
                          "post_action": Json.String(act),
                          "recipients": Json.Array([]),
                          "attachments": Json.Array([])
                        })
                      )
                    None: Unit
                  end
                None: Unit
              end
            None: Unit
          end
        None: Unit
      end

      var thread_participants = []
      case parent_opt
        Some(pid):
          parent = case try ChatOps.get_message(store, id, pid)
            Some(p): p
            None: return Error(Missing(entity: "chat_message", id: pid))
          end
          if parent.text_at("deleted_at") != None
            return Error(BadInput(reason: "cannot reply to a deleted message"))
          end
          if parent.text_at("parent_message_id") != None
            return Error(BadInput(reason: "nested replies to thread replies are not supported"))
          end
          case parent.text_at("author_id")
            Some(paid) if not paid.empty?: thread_participants = thread_participants.append(paid)
            Some(_) | None: Unit
          end
          raw_msgs = try ChatOps.scan_channel_raw_messages(store, id)
          for rm in raw_msgs
            if rm.text_at("deleted_at") == None and rm.text_at("parent_message_id") == Some(pid)
              case rm.text_at("author_id")
                Some(aid) if not aid.empty? and not thread_participants.contains?(aid):
                  thread_participants = thread_participants.append(aid)
                Some(_) | None: Unit
              end
            end
          end
        None: Unit
      end

      var resolved_atts = []
      for aid in att_ids
        att = case try Table.get(store, Db.attachments_table(), aid).map_error(Db.map_table_error)
          Some(a): a
          None: return Error(Missing(entity: "attachment", id: aid))
        end
        if att.status != "ready"
          return Error(Conflict(reason: "attachment '#{aid}' must be committed before attaching"))
        end
        if att.page_id != id
          if att.page_id.starts_with?("ch_")
            src_ch = case try ChatOps.get_channel(store, att.page_id)
              Some(c) if c.text_at("archived_at") == None: c
              Some(_) | None: return Error(Missing(entity: "chat_channel", id: att.page_id))
            end
            try ChatOps.require_channel_access(auth, src_ch, "read")
          else
            pg = case try Table.get(store, Db.pages_table(), att.page_id).map_error(
              Db.map_table_error
            )
              Some(p) if p.archived_at == None: p
              Some(_) | None: return Error(Missing(entity: "page", id: att.page_id))
            end
            try Policy.require_collection_access(auth, "read", pg.collection_id)
          end
        end
        resolved_atts = resolved_atts.append(attachment_summary_json(att))
      end

      # Build Calm Inbox notification targets while strictly enforcing target FERPA & membership ACLs
      all_ps = try list_active_principals(store)
      var p_by_handle = {}
      var p_by_id = {}
      for p in all_ps
        p_by_id = p_by_id.set(p.id, p)
        norm_h = ChatOps.normalize_handle(p.handle)
        if not norm_h.empty?
          p_by_handle = p_by_handle.set(norm_h, p)
        end
      end

      var rec_map = {}
      # Thread participants first (lowest priority)
      for tpid in thread_participants
        if tpid != auth.principal.id
          case p_by_id.get(tpid)
            Some(tp) if principal_can_read_channel?(store, tp, ch, now):
              rec_map = rec_map.set(tpid, "thread_reply")
            Some(_) | None: Unit
          end
        end
      end
      # DM participants (overrides thread_reply)
      if ch.text_at("kind") == Some("dm")
        for dmid in VaultOps.json_string_list(ch, "member_principal_ids")
          if dmid != auth.principal.id
            case p_by_id.get(dmid)
              Some(dp) if not dp.suspended: rec_map = rec_map.set(dmid, "dm")
              Some(_) | None: Unit
            end
          end
        end
      end
      # Explicit @mentions (highest priority, still FERPA/ACL-gated!)
      for mh in ChatOps.extract_mentions(raw_md)
        case p_by_handle.get(mh)
          Some(mp) if mp.id != auth.principal.id and principal_can_read_channel?(store, mp, ch, now):
            rec_map = rec_map.set(mp.id, "mention")
          Some(_) | None: Unit
        end
      end

      var rec_objs = []
      for (rid, rk) in rec_map.entries
        rec_objs = rec_objs.append(Json.Object({"id": Json.String(rid), "kind": Json.String(rk)}))
      end
      Ok(
        Json.Object({
          "existing": Json.Null,
          "post_action": Json.String(act),
          "recipients": Json.Array(rec_objs),
          "attachments": Json.Array(resolved_atts)
        })
      )
    end
  )

  case preflight.get("existing")
    Some(Json.Object(em)):
      return Ok(
        json_ok(200, Json.Object({"message": Json.Object(em), "deduplicated": Json.Boolean(true)}))
      )
    Some(Json.Null) | Some(Json.Boolean(_)) | Some(Json.Number(_)) | Some(Json.String(_)) | Some(
      Json.Array(_)
    ) | None: Unit
  end
  post_action = preflight.text_at("post_action") or "comment"
  att_summaries = preflight.list_at("attachments") or []
  rec_objs = preflight.list_at("recipients") or []

  new_msg_id = "msg_#{Id.ulid(rng, clock)}"
  akind_txt = case auth.principal.kind
    Human: "human"
    Agent: "agent"
  end
  msg_json = Json.Object({
    "id": Json.String(new_msg_id),
    "channel_id": Json.String(id),
    "parent_message_id": parent_opt.to_json,
    "author_id": Json.String(auth.principal.id),
    "author_handle": Json.String(auth.principal.handle),
    "author_display_name": Json.String(auth.principal.display_name),
    "author_kind": Json.String(akind_txt),
    "body_markdown": Json.String(raw_md),
    "attachment_ids": att_ids.to_json,
    "reactions": Json.Object({}),
    "linked_row_ids": Json.Array([]),
    "linked_proposal_ids": Json.Array([]),
    "is_decision": Json.Boolean(is_decision?),
    "client_msg_id": client_msg_opt.to_json,
    "edited_at": Json.Null,
    "deleted_at": Json.Null,
    "created_at": now.to_json
  })
  preview_txt = ChatOps.msg_preview(raw_md)

  var notif_items = []
  for r in rec_objs
    rec_id = r.text_at("id") or ""
    n_kind = r.text_at("kind") or "mention"
    if not rec_id.empty?
      nid = "ntf_#{Id.ulid(rng, clock)}"
      ntf = Json.Object({
        "id": Json.String(nid),
        "recipient_principal_id": Json.String(rec_id),
        "kind": Json.String(n_kind),
        "channel_id": Json.String(id),
        "message_id": Json.String(new_msg_id),
        "parent_message_id": parent_opt.to_json,
        "actor_id": Json.String(auth.principal.id),
        "actor_handle": Json.String(auth.principal.handle),
        "preview": Json.String(preview_txt),
        "read_at": Json.Null,
        "created_at": now.to_json
      })
      notif_items = notif_items.append((rec_id, nid, ntf))
    end
  end

  wmeta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "chat.message_post",
    reason: "posted chat message in channel '#{id}'",
    at: now
  )
  tx_res = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    wmeta,
    "posted chat message '#{new_msg_id}' in '#{id}'",
    Json.Object({"channel_id": Json.String(id), "message_id": Json.String(new_msg_id)}),
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, post_action, now)
      case client_msg_opt
        Some(cmid):
          case try ChatOps.tx_lookup_idempotency(t1, id, auth.principal.id, cmid)
            Some(ex_id):
              case try ChatOps.tx_get_message(t1, id, ex_id)
                Some(ex_msg): return Ok(
                  (t1, Json.Object({"message": ex_msg, "deduplicated": Json.Boolean(true)}))
                )
                None: Unit
              end
            None: Unit
          end
        None: Unit
      end

      ch = case try ChatOps.tx_get_channel(t1, id)
        Some(c) if c.text_at("archived_at") == None: c
        Some(_) | None: return Error(Missing(entity: "chat_channel", id: id))
      end
      _act = try require_channel_post_access(auth, ch)

      var cur = try ChatOps.tx_put_message(t1, id, new_msg_id, msg_json)
      case client_msg_opt
        Some(cmid): cur = try ChatOps.tx_put_idempotency(cur, id, auth.principal.id, cmid, new_msg_id)
        None: Unit
      end

      ch_updated = case ch
        Json.Object(cm): Json.Object(
          cm.set("last_message_at", now.to_json)
            .set("last_message_id", Json.String(new_msg_id))
            .set("updated_at", now.to_json)
        )
        Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): ch
      end
      cur = try ChatOps.tx_put_channel(cur, id, ch_updated)

      for (rec_id, nid, ntf) in notif_items
        cur = try ChatOps.tx_put_inbox(cur, rec_id, nid, ntf)
      end

      # Automatically advance sender's read cursor so their own post never reads as unread
      sender_cur = Json.Object({
        "principal_id": Json.String(auth.principal.id),
        "channel_id": Json.String(id),
        "last_read_message_id": Json.String(new_msg_id),
        "last_read_at": now.to_json
      })
      cur = try ChatOps.tx_put_read_cursor(cur, auth.principal.id, id, sender_cur)
      Ok((cur, Json.Object({"message": msg_json, "deduplicated": Json.Boolean(false)})))
    end
  )

  saved_msg = tx_res.get("message") or msg_json
  dedup? = tx_res.bool_at("deduplicated") or false
  enr_msg = case saved_msg
    Json.Object(m): Json.Object(
      m.set("reply_count", Json.int(0)).set("attachments", Json.Array(att_summaries))
    )
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): saved_msg
  end
  if dedup?
    return Ok(json_ok(200, Json.Object({"message": enr_msg, "deduplicated": Json.Boolean(true)})))
  end

  var resp = json_ok(201, Json.Object({"message": enr_msg, "deduplicated": Json.Boolean(false)}))
    .with_sse_publish_json(
      "chat:channel:#{id}",
      "chat.message_created",
      Json.Object({"channel_id": Json.String(id), "message": enr_msg})
    )
  for (rec_id, _nid, ntf) in notif_items
    resp = resp.with_sse_publish_json(
      "chat:inbox:#{rec_id}",
      "chat.inbox_updated",
      Json.Object({"channel_id": Json.String(id), "notification": ntf})
    )
  end
  Ok(resp)
end

## `PATCH /api/v1/chat/channels/:id/messages/:msg_id` — Edits message body or decision flag (`is_decision`).
fn edit_message(
  id: Text,
  msg_id: Text,
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if auth.principal.suspended
    return Error(Forbidden(reason: "principal '#{auth.principal.handle}' is suspended"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "chat_message", id: msg_id))
  end
  body = try parse_json_object_body(req)
  now = clock.now
  is_admin? = auth.principal.role == Owner or auth.principal.role == Admin

  wmeta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "chat.message_edit",
    reason: "edited chat message '#{msg_id}' in '#{id}'",
    at: now
  )
  updated = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    wmeta,
    "edited chat message '#{msg_id}'",
    Json.Object({"channel_id": Json.String(id), "message_id": Json.String(msg_id)}),
    Db.map_ledger_error,
    fn(tx)
      ch = case try ChatOps.tx_get_channel(tx, id)
        Some(c) if c.text_at("archived_at") == None: c
        Some(_) | None: return Error(Missing(entity: "chat_channel", id: id))
      end
      act = try require_channel_post_access(auth, ch)
      t1 = try tx_authorize_if_agent(tx, auth, act, now)
      old_msg = case try ChatOps.tx_get_message(t1, id, msg_id)
        Some(m): m
        None: return Error(Missing(entity: "chat_message", id: msg_id))
      end
      if old_msg.text_at("deleted_at") != None
        return Error(BadInput(reason: "cannot edit a deleted message"))
      end
      is_author? = old_msg.text_at("author_id") == Some(auth.principal.id)
      if not is_author? and not is_admin?
        return Error(Forbidden(reason: "only author or Owner/Admin may edit this message"))
      end
      old_m = case old_msg
        Json.Object(m): m
        Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
          ServerFailed(reason: "corrupt message record")
        )
      end
      var next_m = old_m.set("edited_at", now.to_json)
      case body.text_at("body_markdown")
        Some(raw_md):
          clean_md = raw_md.trim
          if clean_md.empty?
            return Error(BadInput(reason: "body_markdown must not be empty"))
          end
          next_m = next_m.set("body_markdown", Json.String(clean_md))
        None: Unit
      end
      case body.bool_at("is_decision")
        Some(flag): next_m = next_m.set("is_decision", Json.Boolean(flag))
        None: Unit
      end
      next_msg = Json.Object(next_m)
      t2 = try ChatOps.tx_put_message(t1, id, msg_id, next_msg)
      Ok((t2, next_msg))
    end
  )
  enr_msg = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db) enrich_message_json(Ledger.store(db), updated, 0) end
  )
  Ok(
    json_ok(200, Json.Object({"message": enr_msg})).with_sse_publish_json(
      "chat:channel:#{id}",
      "chat.message_updated",
      Json.Object({"channel_id": Json.String(id), "message": enr_msg})
    )
  )
end

## `DELETE /api/v1/chat/channels/:id/messages/:msg_id` — Tombstones a chat message cleanly.
fn delete_message(
  id: Text,
  msg_id: Text,
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if auth.principal.suspended
    return Error(Forbidden(reason: "principal '#{auth.principal.handle}' is suspended"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "chat_message", id: msg_id))
  end
  now = clock.now
  is_admin? = auth.principal.role == Owner or auth.principal.role == Admin

  wmeta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "chat.message_delete",
    reason: "deleted chat message '#{msg_id}' in '#{id}'",
    at: now
  )
  tombstone = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    wmeta,
    "deleted chat message '#{msg_id}'",
    Json.Object({"channel_id": Json.String(id), "message_id": Json.String(msg_id)}),
    Db.map_ledger_error,
    fn(tx)
      ch = case try ChatOps.tx_get_channel(tx, id)
        Some(c) if c.text_at("archived_at") == None: c
        Some(_) | None: return Error(Missing(entity: "chat_channel", id: id))
      end
      act = try require_channel_post_access(auth, ch)
      t1 = try tx_authorize_if_agent(tx, auth, act, now)
      old_msg = case try ChatOps.tx_get_message(t1, id, msg_id)
        Some(m): m
        None: return Error(Missing(entity: "chat_message", id: msg_id))
      end
      is_author? = old_msg.text_at("author_id") == Some(auth.principal.id)
      if not is_author? and not is_admin?
        return Error(Forbidden(reason: "only author or Owner/Admin may delete this message"))
      end
      old_m = case old_msg
        Json.Object(m): m
        Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
          ServerFailed(reason: "corrupt message record")
        )
      end
      next_msg = Json.Object(
        old_m.set("body_markdown", Json.String(""))
          .set("attachment_ids", Json.Array([]))
          .set("deleted_at", now.to_json)
      )
      t2 = try ChatOps.tx_put_message(t1, id, msg_id, next_msg)
      Ok((t2, next_msg))
    end
  )
  Ok(
    json_ok(200, Json.Object({"message": tombstone, "deleted": Json.Boolean(true)}))
      .with_sse_publish_json(
        "chat:channel:#{id}",
        "chat.message_deleted",
        Json.Object({"channel_id": Json.String(id), "message_id": Json.String(msg_id)})
      )
  )
end

## `POST /api/v1/chat/channels/:id/messages/:msg_id/reactions` — Toggles caller's emoji reaction.
fn toggle_reaction(
  id: Text,
  msg_id: Text,
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if auth.principal.suspended
    return Error(Forbidden(reason: "principal '#{auth.principal.handle}' is suspended"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "chat_message", id: msg_id))
  end
  body = try parse_json_object_body(req)
  emoji = (body.text_at("emoji") or "").trim
  if emoji.empty?
    return Error(BadInput(reason: "emoji must not be empty"))
  end
  now = clock.now

  wmeta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "chat.reaction_toggle",
    reason: "toggled reaction '#{emoji}' on '#{msg_id}'",
    at: now
  )
  updated = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    wmeta,
    "toggled reaction '#{emoji}' on '#{msg_id}'",
    Json.Object({"channel_id": Json.String(id), "message_id": Json.String(msg_id)}),
    Db.map_ledger_error,
    fn(tx)
      ch = case try ChatOps.tx_get_channel(tx, id)
        Some(c) if c.text_at("archived_at") == None: c
        Some(_) | None: return Error(Missing(entity: "chat_channel", id: id))
      end
      react_act = if ChatOps.can_access_channel?(auth, ch, "comment")
        "comment"
      else if ChatOps.can_access_channel?(auth, ch, "read")
        "read"
      else
        _ = try ChatOps.require_channel_access(auth, ch, "read")
        "read"
      end
      t1 = try tx_authorize_if_agent(tx, auth, react_act, now)
      old_msg = case try ChatOps.tx_get_message(t1, id, msg_id)
        Some(m): m
        None: return Error(Missing(entity: "chat_message", id: msg_id))
      end
      if old_msg.text_at("deleted_at") != None
        return Error(BadInput(reason: "cannot react to a deleted message"))
      end
      old_m = case old_msg
        Json.Object(m): m
        Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
          ServerFailed(reason: "corrupt message record")
        )
      end
      rmap = case old_m.get("reactions")
        Some(Json.Object(rm)): rm
        Some(_) | None: {}
      end
      existing_pids = VaultOps.json_string_list(Json.Object(rmap), emoji)
      next_pids = if existing_pids.contains?(auth.principal.id)
        existing_pids.filter(fn(p) p != auth.principal.id end)
      else
        existing_pids.append(auth.principal.id)
      end
      next_rmap = if next_pids.empty?: rmap.remove(emoji) else: rmap.set(emoji, next_pids.to_json)
      next_msg = Json.Object(old_m.set("reactions", Json.Object(next_rmap)))
      t2 = try ChatOps.tx_put_message(t1, id, msg_id, next_msg)
      Ok((t2, next_msg))
    end
  )

  Ok(
    json_ok(200, Json.Object({"message": updated, "reactions": updated.get("reactions") or Json.Object({})}))
      .with_sse_publish_json(
        "chat:channel:#{id}",
        "chat.reaction_updated",
        Json.Object({
          "channel_id": Json.String(id),
          "message_id": Json.String(msg_id),
          "reactions": updated.get("reactions") or Json.Object({})
        })
      )
  )
end

## `POST /api/v1/chat/channels/:id/read` — Updates caller's channel read cursor.
fn mark_channel_read(
  id: Text,
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "chat_channel", id: id))
  end
  body = try parse_json_object_body(req)
  supplied_opt = opt_trimmed(body, "last_read_message_id")
  now = clock.now

  wmeta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "chat.channel_read",
    reason: "marked channel '#{id}' read",
    at: now
  )
  cursor = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    wmeta,
    "marked channel '#{id}' read",
    Json.Object({"channel_id": Json.String(id)}),
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "read", now)
      ch = case try ChatOps.tx_get_channel(t1, id)
        Some(c) if c.text_at("archived_at") == None: c
        Some(_) | None: return Error(Missing(entity: "chat_channel", id: id))
      end
      try ChatOps.require_channel_access(auth, ch, "read")
      last_id = case supplied_opt
        Some(s): Some(s)
        None: opt_trimmed(ch, "last_message_id")
      end
      cjson = Json.Object({
        "principal_id": Json.String(auth.principal.id),
        "channel_id": Json.String(id),
        "last_read_message_id": last_id.to_json,
        "last_read_at": now.to_json
      })
      t2 = try ChatOps.tx_put_read_cursor(t1, auth.principal.id, id, cjson)
      Ok((t2, cjson))
    end
  )
  Ok(json_ok(200, Json.Object({"cursor": cursor, "unread_count": Json.int(0)})))
end

## `GET /api/v1/chat/inbox` — Lists caller's Calm Inbox mentions, thread replies & DMs newest-first.
fn list_inbox(req: Api.Request, auth: AuthContext, rf: ReadFiles) : Result(Api.Response, AppError)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Ok(json_ok(200, Json.Object({"items": Json.Array([]), "unread_count": Json.int(0)})))
  end
  unread_only? = req.query_param("unread_only") == Some("1")
  lim = parse_limit(req.query_param("limit"), 50, 200)
  payload = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      items = try ChatOps.list_inbox(store, auth.principal.id, unread_only?, lim)
      ucnt = try ChatOps.unread_inbox_count(store, auth.principal.id)
      Ok(Json.Object({"items": Json.Array(items), "unread_count": Json.int(ucnt)}))
    end
  )
  Ok(json_ok(200, payload))
end

## `POST /api/v1/chat/inbox/ack` — Acknowledges one notification or all inbox notifications.
fn ack_inbox(
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Ok(json_ok(200, Json.Object({"acked": Json.int(0), "unread_count": Json.int(0)})))
  end
  body = try parse_json_object_body(req)
  all? = body.bool_at("all") or false
  target_id = opt_trimmed(body, "notification_id")
  if not all? and target_id == None
    return Error(BadInput(reason: "notification_id or all=true is required"))
  end
  now = clock.now

  wmeta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "chat.inbox_ack",
    reason: "acknowledged Calm Inbox notifications",
    at: now
  )
  ack_payload = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    wmeta,
    "acknowledged inbox items",
    Json.Object({"all": Json.Boolean(all?), "notification_id": target_id.to_json}),
    Db.map_ledger_error,
    fn(tx)
      var cur = try tx_authorize_if_agent(tx, auth, "read", now)
      items = try ChatOps.tx_scan_inbox(cur, auth.principal.id, 0)
      var ack_cnt = 0
      var remaining = 0
      var found_target? = false
      for item in items
        nid = item.text_at("id") or ""
        already_read? = item.text_at("read_at") != None
        matches? = all? or (target_id == Some(nid))
        if target_id == Some(nid)
          found_target? = true
        end
        if matches? and not already_read?
          updated = case item
            Json.Object(m): Json.Object(m.set("read_at", now.to_json))
            Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): item
          end
          cur = try ChatOps.tx_put_inbox(cur, auth.principal.id, nid, updated)
          ack_cnt += 1
        else if not already_read?
          remaining += 1
        end
      end
      if not all? and not found_target?
        return Error(Missing(entity: "inbox_notification", id: target_id or ""))
      end
      Ok((cur, Json.Object({"acked": Json.int(ack_cnt), "unread_count": Json.int(remaining)})))
    end
  )
  Ok(json_ok(200, ack_payload))
end

## `GET /api/v1/chat/search` — ACL + FERPA-filtered search across visible chat channels and DMs.
fn search_chat(req: Api.Request, auth: AuthContext, rf: ReadFiles) : Result(Api.Response, AppError)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  q = (req.query_param("q") or "").trim
  if not rf.exists?(Db.ledger_db_path)
    return Ok(json_ok(200, Json.Object({"results": Json.Array([]), "query": Json.String(q)})))
  end
  ch_opt = req.query_param("channel_id")
  col_opt = req.query_param("collection_id")
  decisions_only? = req.query_param("decisions_only") == Some("1")
  lim = parse_limit(req.query_param("limit"), 30, 100)

  payload = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      hits = try ChatOps.search_visible_messages(
        Ledger.store(db),
        auth,
        q,
        ch_opt,
        col_opt,
        decisions_only?,
        lim
      )
      Ok(Json.Object({"results": Json.Array(hits), "query": Json.String(q)}))
    end
  )
  Ok(json_ok(200, payload))
end
