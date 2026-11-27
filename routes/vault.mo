## Admin control-plane routes for Department Groups, Collection FERPA Vault Security Tiers,
## and `Modb.Ledger` FERPA read/export audit inspection.
module Routes.Vault
expose CreateGroupInput(..),
UpdateGroupInput(..),
UpdateCollectionSecurityInput(..),
vault_status,
list_groups,
create_group,
update_group,
delete_group,
update_collection_security,
ferpa_audit_index
use Api
use Arvo.Id
use Db
use Domain.Policy
use Domain.Types{AppError, AuthContext, PrincipalKind, WorkspaceRole}
use Json
use Modb
use Modb.Ledger
use Routes.Auth
use VaultOps

## JSON payload for `POST /api/admin/groups`.
struct CreateGroupInput
  name: Text
  slug: Option(Text)
  description: Option(Text)
  member_principal_ids: List(Text)
end

## JSON payload for `PATCH /api/admin/groups/:id`.
struct UpdateGroupInput
  name: Option(Text)
  description: Option(Text)
  member_principal_ids: Option(List(Text))
end

## JSON payload for `PATCH /api/collections/:id/security`.
struct UpdateCollectionSecurityInput
  security_tier: Text
  allowed_group_ids: List(Text)
  allowed_principal_ids: List(Text)
  allow_local_ai: Option(Bool)
  reason: Option(Text)
end

fn json_ok(status: Int, body: Json) : Api.Response
  Api.encoded_json_response(status, body).with_header(
    "Content-Type",
    "application/json; charset=utf-8"
  )
end

fn require_vault_admin(auth: AuthContext) : Result(Unit, AppError)
  if auth.principal.suspended
    return Error(Forbidden(reason: "principal '#{auth.principal.handle}' is suspended"))
  end
  role_ok? = auth.principal.role == Owner or auth.principal.role == Admin
  if not role_ok?
    return Error(
      Forbidden(reason: "only Owner/Admin may manage Department Groups and FERPA Vault policies")
    )
  end
  if auth.principal.kind == Agent and not Policy.action_permitted?(auth, "manage_grants")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'manage_grants'"))
  end
  Ok(Unit)
end

fn slugify_group_name(raw: Text) : Text
  var chars = []
  var prev_dash = true
  for ch in raw.trim.ascii_lowercase.chars
    if ch.ascii_letter? or ch.ascii_digit?
      chars = chars.append(ch)
      prev_dash = false
    else if not prev_dash
      chars = chars.append('-')
      prev_dash = true
    end
  end
  while not chars.empty? and chars.last == Some('-')
    chars = chars.take(chars.size - 1)
  end
  if chars.empty?: "group" else: Text.from_chars(chars)
end

fn dedup_non_empty(xs: List(Text)) : List(Text)
  var out = []
  for x in xs
    t = x.trim
    if not t.empty? and not out.contains?(t)
      out = out.append(t)
    end
  end
  out
end

fn validate_member_principals_tx(tx: Modb.WriteTx, pids: List(Text)) : Result(Unit, AppError)
  for pid in pids
    case try Db.tx_get_principal(tx, pid)
      Some(p) if not p.suspended: Unit
      Some(_) | None: return Error(
        BadInput(reason: "unknown or suspended principal '#{pid}'")
      )
    end
  end
  Ok(Unit)
end

## `GET /api/admin/vault/status` — Returns Department Groups, Vault policies, collections, principals, and recent FERPA audit logs.
fn vault_status(_req: Api.Request, auth: AuthContext, rf: ReadFiles) : Result(
  Api.Response,
  AppError
)
  try require_vault_admin(auth)
  if not rf.exists?(Db.ledger_db_path)
    return Ok(
      json_ok(
        200,
        Json.Object({
          "groups": Json.Array([]),
          "policies": Json.Array([]),
          "collections": Json.Array([]),
          "principals": Json.Array([]),
          "recent_audit": Json.Array([])
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
      store = Ledger.store(db)
      groups = try VaultOps.list_groups_json(store)
      policies = try VaultOps.list_vault_policies_json(store)
      c_rows = try Db.scan_collections(store, 200)
      var cols = []
      for (_cid, c) in c_rows
        if c.archived_at == None
          cols = cols.append(
            Json.Object({
              "id": Json.String(c.id),
              "slug": Json.String(c.slug),
              "name": Json.String(c.name)
            })
          )
        end
      end
      p_rows = try Db.scan_principals(store, 200)
      var prs = []
      for (_pid, p) in p_rows
        if not p.suspended
          prs = prs.append(
            Json.Object({
              "id": Json.String(p.id),
              "handle": Json.String(p.handle),
              "display_name": Json.String(p.display_name),
              "email": p.email.to_json,
              "role": p.role.to_json,
              "kind": p.kind.to_json
            })
          )
        end
      end
      recent_audit = try VaultOps.list_ferpa_audit_json(store, None, None, None, 50)
      Ok(
        Json.Object({
          "groups": Json.Array(groups),
          "policies": Json.Array(policies),
          "collections": Json.Array(cols),
          "principals": Json.Array(prs),
          "recent_audit": Json.Array(recent_audit)
        })
      )
    end
  )
  Ok(json_ok(200, payload))
end

## `GET /api/admin/groups` — Lists all Department Groups (`Owner`/`Admin`).
fn list_groups(_req: Api.Request, auth: AuthContext, rf: ReadFiles) : Result(Api.Response, AppError)
  try require_vault_admin(auth)
  if not rf.exists?(Db.ledger_db_path)
    return Ok(json_ok(200, Json.Object({"groups": Json.Array([])})))
  end
  payload = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      groups = try VaultOps.list_groups_json(Ledger.store(db))
      Ok(Json.Object({"groups": Json.Array(groups)}))
    end
  )
  Ok(json_ok(200, payload))
end

## `POST /api/admin/groups` — Creates a Department Group for Collection FERPA Vault allowlists.
fn create_group(
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  input = CreateGroupInput(
    name: try VaultOps.req_text(rj, "name"),
    slug: rj.text_at("slug"),
    description: rj.text_at("description"),
    member_principal_ids: VaultOps.json_text_list_raw(rj, "member_principal_ids")
  )
  try require_vault_admin(auth)
  name = input.name.trim
  if name.empty?
    return Error(BadInput(reason: "group name must not be empty"))
  end
  slug = case input.slug
    Some(s) if not s.trim.empty?: slugify_group_name(s)
    Some(_) | None: slugify_group_name(name)
  end
  members = dedup_non_empty(input.member_principal_ids)
  desc = case input.description
    Some(d) if not d.trim.empty?: Some(d.trim)
    Some(_) | None: None
  end
  gid = "grp_#{Id.ulid(rng, clock)}"
  now = clock.now
  grp_json = Json.Object({
    "id": Json.String(gid),
    "slug": Json.String(slug),
    "name": Json.String(name),
    "description": desc.to_json,
    "member_principal_ids": members.to_json,
    "created_by": Json.String(auth.principal.id),
    "created_at": now.to_json,
    "updated_at": now.to_json
  })
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "group.created",
    reason: "create department group '#{slug}'",
    at: now
  )
  saved = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "created department group '#{name}'",
    Json.Object({"group_id": Json.String(gid), "slug": Json.String(slug)}),
    Db.map_ledger_error,
    fn(tx)
      existing = try VaultOps.tx_scan_json(tx, VaultOps.dept_groups_bucket, 200)
      for g in existing
        if g.text_at("slug") == Some(slug)
          return Error(Conflict(reason: "department group slug '#{slug}' already exists"))
        end
      end
      try validate_member_principals_tx(tx, members)
      t1 = try VaultOps.tx_put_json(tx, VaultOps.dept_groups_bucket, gid, grp_json)
      Ok((t1, grp_json))
    end
  )
  Ok(json_ok(201, Json.Object({"group": saved})))
end

## `PATCH /api/admin/groups/:id` — Updates a Department Group's name, description, or members.
fn update_group(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  input = UpdateGroupInput(
    name: rj.text_at("name"),
    description: rj.text_at("description"),
    member_principal_ids: VaultOps.json_text_list_opt(rj, "member_principal_ids")
  )
  try require_vault_admin(auth)
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "group", id: id))
  end
  now = clock.now
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "group.updated",
    reason: "update department group '#{id}'",
    at: now
  )
  saved = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "updated department group '#{id}'",
    Json.Object({"group_id": Json.String(id)}),
    Db.map_ledger_error,
    fn(tx)
      old_grp = case try VaultOps.tx_get_json(tx, VaultOps.dept_groups_bucket, id)
        Some(g): g
        None: return Error(Missing(entity: "group", id: id))
      end
      next_name = case input.name
        Some(n):
          t = n.trim
          return Error(BadInput(reason: "group name must not be empty")) if t.empty?
          t
        None: old_grp.text_at("name") or id
      end
      next_desc = case input.description
        Some(d): if d.trim.empty?: None else: Some(d.trim)
        None: old_grp.text_at("description")
      end
      next_members = case input.member_principal_ids
        Some(ms):
          clean = dedup_non_empty(ms)
          try validate_member_principals_tx(tx, clean)
          clean
        None: VaultOps.json_string_list(old_grp, "member_principal_ids")
      end
      nxt = Json.Object({
        "id": Json.String(id),
        "slug": Json.String(old_grp.text_at("slug") or id),
        "name": Json.String(next_name),
        "description": next_desc.to_json,
        "member_principal_ids": next_members.to_json,
        "created_by": Json.String(old_grp.text_at("created_by") or auth.principal.id),
        "created_at": old_grp.get("created_at") or now.to_json,
        "updated_at": now.to_json
      })
      t1 = try VaultOps.tx_put_json(tx, VaultOps.dept_groups_bucket, id, nxt)
      Ok((t1, nxt))
    end
  )
  Ok(json_ok(200, Json.Object({"group": saved})))
end

## `DELETE /api/admin/groups/:id` — Deletes a Department Group if no `ferpa_restricted` collection depends solely on it.
fn delete_group(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  try require_vault_admin(auth)
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "group", id: id))
  end
  now = clock.now
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "group.deleted",
    reason: "delete department group '#{id}'",
    at: now
  )
  out_json = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "deleted department group '#{id}'",
    Json.Object({"group_id": Json.String(id)}),
    Db.map_ledger_error,
    fn(tx)
      _old = case try VaultOps.tx_get_json(tx, VaultOps.dept_groups_bucket, id)
        Some(g): g
        None: return Error(Missing(entity: "group", id: id))
      end
      policies = try VaultOps.tx_scan_json(tx, VaultOps.vault_policies_bucket, 200)
      var cur = tx
      for pol in policies
        cid = pol.text_at("collection_id") or ""
        gids = VaultOps.json_string_list(pol, "allowed_group_ids")
        if gids.contains?(id)
          rem_gids = gids.filter(fn(g) g != id end)
          pids = VaultOps.json_string_list(pol, "allowed_principal_ids")
          if pol.text_at("security_tier") == Some("ferpa_restricted") and rem_gids.empty? and
            pids.empty?
            return Error(
              Conflict(
                reason: "cannot delete group '#{id}': sole allowlist entry for FERPA Restricted collection '#{cid}'"
              )
            )
          end
          upd_pol = Json.Object({
            "collection_id": Json.String(cid),
            "security_tier": Json.String(pol.text_at("security_tier") or "standard"),
            "allowed_group_ids": rem_gids.to_json,
            "allowed_principal_ids": pids.to_json,
            "allow_local_ai": Json.Boolean(pol.bool_at("allow_local_ai") or false),
            "updated_by": Json.String(auth.principal.id),
            "updated_at": now.to_json
          })
          cur = try VaultOps.tx_put_json(cur, VaultOps.vault_policies_bucket, cid, upd_pol)
        end
      end
      t_del = try VaultOps.tx_delete_key(cur, VaultOps.dept_groups_bucket, id)
      Ok((t_del, Json.Object({"deleted": Json.Boolean(true), "id": Json.String(id)})))
    end
  )
  Ok(json_ok(200, out_json))
end

## `PATCH /api/collections/:id/security` — Configures `standard` vs `ferpa_restricted` Vault tier & allowlist.
fn update_collection_security(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  input = UpdateCollectionSecurityInput(
    security_tier: try VaultOps.req_text(rj, "security_tier"),
    allowed_group_ids: VaultOps.json_text_list_raw(rj, "allowed_group_ids"),
    allowed_principal_ids: VaultOps.json_text_list_raw(rj, "allowed_principal_ids"),
    allow_local_ai: rj.bool_at("allow_local_ai"),
    reason: rj.text_at("reason")
  )
  try require_vault_admin(auth)
  tier = input.security_tier.trim.ascii_lowercase
  if tier != "standard" and tier != "ferpa_restricted"
    return Error(BadInput(reason: "security_tier must be 'standard' or 'ferpa_restricted'"))
  end
  gids = dedup_non_empty(input.allowed_group_ids)
  pids = dedup_non_empty(input.allowed_principal_ids)
  if tier == "ferpa_restricted" and gids.empty? and pids.empty?
    return Error(
      BadInput(reason: "ferpa_restricted collections require at least one allowed group or principal")
    )
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "collection", id: id))
  end

  now = clock.now
  local_ai? = input.allow_local_ai or false
  reason = case input.reason
    Some(r) if not r.trim.empty?: r.trim
    Some(_) | None: "set collection '#{id}' security tier to #{tier}"
  end
  pol_json = Json.Object({
    "collection_id": Json.String(id),
    "security_tier": Json.String(tier),
    "allowed_group_ids": gids.to_json,
    "allowed_principal_ids": pids.to_json,
    "allow_local_ai": Json.Boolean(local_ai?),
    "updated_by": Json.String(auth.principal.id),
    "updated_at": now.to_json
  })
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "collection.security_updated",
    reason: reason,
    at: now
  )
  saved = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    reason,
    Json.Object({
      "collection_id": Json.String(id),
      "security_tier": Json.String(tier),
      "allow_local_ai": Json.Boolean(local_ai?)
    }),
    Db.map_ledger_error,
    fn(tx)
      _col = case try Db.tx_get_collection(tx, id)
        Some(c) if c.archived_at == None: c
        Some(_) | None: return Error(Missing(entity: "collection", id: id))
      end
      for gid in gids
        if (try VaultOps.tx_get_json(tx, VaultOps.dept_groups_bucket, gid)) is None
          return Error(BadInput(reason: "unknown department group '#{gid}'"))
        end
      end
      try validate_member_principals_tx(tx, pids)
      t1 = try VaultOps.tx_put_json(tx, VaultOps.vault_policies_bucket, id, pol_json)
      Ok((t1, pol_json))
    end
  )
  Ok(json_ok(200, Json.Object({"policy": saved})))
end

## `GET /api/admin/ferpa/audit` — Returns filtered `Modb.Ledger` FERPA read/export audit logs.
fn ferpa_audit_index(req: Api.Request, auth: AuthContext, rf: ReadFiles) : Result(
  Api.Response,
  AppError
)
  try require_vault_admin(auth)
  if not rf.exists?(Db.ledger_db_path)
    return Ok(json_ok(200, Json.Object({"entries": Json.Array([])})))
  end
  lim = case req.query_param("limit")
    Some(s): s.trim.to_int or 50
    None: 50
  end
  payload = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      entries = try VaultOps.list_ferpa_audit_json(
        Ledger.store(db),
        req.query_param("collection_id"),
        req.query_param("principal"),
        req.query_param("action"),
        lim
      )
      Ok(Json.Object({"entries": Json.Array(entries)}))
    end
  )
  Ok(json_ok(200, payload))
end
