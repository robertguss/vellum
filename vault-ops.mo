## Vellum v3 FERPA / Restricted Vault storage helpers: Department Groups, Collection Security Tiers,
## Zero-Exfiltration AI/Webhook guards, and tamper-evident `Modb.Ledger` read/export audits.
module VaultOps
expose dept_groups_bucket,
vault_policies_bucket,
ferpa_audit_bucket,
json_string_list,
json_text_list_raw,
json_text_list_opt,
parse_req_json_obj,
req_text,
req_int,
default_vault_policy_json,
get_vault_policy_json,
tx_get_json,
tx_put_json,
tx_delete_key,
tx_scan_json,
is_ferpa_restricted,
env_ai_local_only?,
is_local_ai_url?,
is_local_ai_url_flag?,
ai_allowed_for_collection,
require_ai_allowed_for_collection,
list_groups_json,
list_vault_policies_json,
list_ferpa_audit_json,
apply_vault_restrictions,
record_ferpa_read_audit_locked
use Arvo.Id
use Db
use Domain.Types{AppError, AuthContext}
use Json
use Modb{Store, WriteTx}
use Modb.Ledger

dept_groups_bucket = "vlm_dept_groups"
vault_policies_bucket = "vlm_vault_policies"
ferpa_audit_bucket = "vlm_ferpa_audit"

fn parse_bytes_json(raw: Bytes) : Option(Json)
  case raw.decode_utf8
    Some(txt):
      case Json.parse(txt)
        Ok(j): Some(j)
        Error(_): None
      end
    None: None
  end
end

## Extracts non-empty trimmed string entries from a JSON array property.
fn json_string_list(j: Json, field: Text) : List(Text)
  var out = []
  for item in j.list_at(field) or []
    case item
      Json.String(s) if not s.trim.empty?:
        clean = s.trim
        if not out.contains?(clean)
          out = out.append(clean)
        end
      Json.String(_) | Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json
        .Object(_): Unit
    end
  end
  out
end

## Extracts string entries from a JSON array property verbatim.
fn json_text_list_raw(j: Json, field: Text) : List(Text)
  var out = []
  for item in j.list_at(field) or []
    case item
      Json.String(s): out = out.append(s)
      Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json.Object(_): Unit
    end
  end
  out
end

## Returns `Some(strings)` when `field` is a JSON array, otherwise `None`.
fn json_text_list_opt(j: Json, field: Text) : Option(List(Text))
  case j.list_at(field)
    Some(items):
      var out = []
      for item in items
        case item
          Json.String(s): out = out.append(s)
          Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json.Object(_): Unit
        end
      end
      Some(out)
    None: None
  end
end

## Parses a request body string into a JSON object without generic `Json.decode_strict` lowering overhead.
fn parse_req_json_obj(raw_text: Option(Text)) : Result(Json, AppError)
  j = case Json.parse(raw_text or "")
    Ok(parsed): parsed
    Error(e): return Error(BadInput(reason: "invalid request body JSON: #{e}"))
  end
  case j
    Json.Object(_): Ok(j)
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): Error(
      BadInput(reason: "request body must be a JSON object")
    )
  end
end

## Extracts a required text field from a JSON object or fails with `BadInput`.
fn req_text(j: Json, field: Text) : Result(Text, AppError)
  case j.text_at(field)
    Some(s): Ok(s)
    None: Error(BadInput(reason: "missing string field '#{field}'"))
  end
end

## Extracts a required integer field from a JSON object or fails with `BadInput`.
fn req_int(j: Json, field: Text) : Result(Int, AppError)
  case j.int_at(field)
    Some(n): Ok(n)
    None: Error(BadInput(reason: "missing integer field '#{field}'"))
  end
end

## Default `Standard` collection security policy payload returned when no override is persisted.
fn default_vault_policy_json(collection_id: Text) : Json
  Json.Object({
    "collection_id": Json.String(collection_id),
    "security_tier": Json.String("standard"),
    "allowed_group_ids": Json.Array([]),
    "allowed_principal_ids": Json.Array([]),
    "allow_local_ai": Json.Boolean(false),
    "updated_by": Json.Null,
    "updated_at": Json.Null
  })
end

fn scan_bucket_jsons(store: Store, bucket: Text, limit: Int) : Result(List(Json), AppError)
  rows = try Modb.scan(store, bucket, None, None, limit).map_error(fn(e)
    ServerFailed(reason: e.to_text)
  end)
  var out = []
  for (_k, v) in rows
    case parse_bytes_json(v)
      Some(j): out = out.append(j)
      None: Unit
    end
  end
  Ok(out)
end

## Scans all JSON values inside `bucket` inside a `WriteTx`.
fn tx_scan_json(tx: WriteTx, bucket: Text, limit: Int) : Result(List(Json), AppError)
  rows = try Modb.tx_scan(tx, bucket, None, None, limit).map_error(fn(e)
    ServerFailed(reason: e.to_text)
  end)
  var out = []
  for (_k, v) in rows
    case parse_bytes_json(v)
      Some(j): out = out.append(j)
      None: Unit
    end
  end
  Ok(out)
end

## Fetches a single stored JSON policy for `collection_id`, if present.
fn get_vault_policy_json(store: Store, collection_id: Text) : Result(Option(Json), AppError)
  val_opt = try Modb.get(store, vault_policies_bucket, collection_id.bytes).map_error(fn(e)
    ServerFailed(reason: e.to_text)
  end)
  case val_opt
    Some(b): Ok(parse_bytes_json(b))
    None: Ok(None)
  end
end

## Fetches a stored JSON record by text key inside a `WriteTx`.
fn tx_get_json(tx: WriteTx, bucket: Text, key: Text) : Result(Option(Json), AppError)
  val_opt = try Modb.tx_get(tx, bucket, key.bytes).map_error(fn(e)
    ServerFailed(reason: e.to_text)
  end)
  case val_opt
    Some(b): Ok(parse_bytes_json(b))
    None: Ok(None)
  end
end

## Persists a JSON record by text key inside `WriteTx`.
fn tx_put_json(tx: WriteTx, bucket: Text, key: Text, val: Json) : Result(WriteTx, AppError)
  Modb.tx_put(tx, bucket, key.bytes, val.to_text.bytes).map_error(fn(e)
    ServerFailed(reason: e.to_text)
  end)
end

## Deletes a record by text key inside `WriteTx`.
fn tx_delete_key(tx: WriteTx, bucket: Text, key: Text) : Result(WriteTx, AppError)
  Modb.tx_delete(tx, bucket, key.bytes).map_error(fn(e)
    ServerFailed(reason: e.to_text)
  end)
end

## Returns `true` iff `collection_id` is configured as `ferpa_restricted`.
fn is_ferpa_restricted(store: Store, collection_id: Text) : Result(Bool, AppError)
  case try get_vault_policy_json(store, collection_id)
    Some(p): Ok(p.text_at("security_tier") == Some("ferpa_restricted"))
    None: Ok(false)
  end
end

## Returns `true` when `VELLUM_AI_LOCAL_ONLY=1` is configured in the process environment.
fn env_ai_local_only?(env: Env) : Bool
  (env.get("VELLUM_AI_LOCAL_ONLY") or "").trim == "1"
end

## Pure helper checking approved campus/loopback AI endpoints given pre-read `local_only_env?`.
fn is_local_ai_url_flag?(base_url: Text, local_only_env?: Bool) : Bool
  return true if local_only_env?
  low = base_url.trim.ascii_lowercase
  low.starts_with?("http://127.0.0.1") or low.starts_with?("https://127.0.0.1") or
    low.starts_with?("http://localhost") or
    low.starts_with?("https://localhost") or
    low.starts_with?("http://[::1]") or
    low.starts_with?("https://[::1]")
end

## Returns `true` when AI requests target an approved campus/loopback endpoint or local-only mode.
fn is_local_ai_url?(base_url: Text, env: Env) : Bool
  is_local_ai_url_flag?(base_url, env_ai_local_only?(env))
end

## Returns `true` iff AI inference using `base_url` is permitted for `collection_id`.
## Takes `local_only_env?` as a plain `Bool` so `Ledger.read_locked` closures need not capture `Env`.
fn ai_allowed_for_collection(
  store: Store,
  collection_id: Text,
  base_url: Text,
  local_only_env?: Bool
) : Result(Bool, AppError)
  case try get_vault_policy_json(store, collection_id)
    Some(pol) if pol.text_at("security_tier") == Some("ferpa_restricted"):
      local_ok? = pol.bool_at("allow_local_ai") or false
      Ok(local_ok? and is_local_ai_url_flag?(base_url, local_only_env?))
    Some(_) | None: Ok(true)
  end
end

## Fails closed with `403 Forbidden` when a `ferpa_restricted` collection disallows external AI.
fn require_ai_allowed_for_collection(
  store: Store,
  collection_id: Text,
  base_url: Text,
  local_only_env?: Bool
) : Result(Unit, AppError)
  allowed? = try ai_allowed_for_collection(store, collection_id, base_url, local_only_env?)
  if allowed?
    Ok(Unit)
  else
    Error(
      Forbidden(
        reason: "FERPA / Restricted Vault blocks external AI on collection '#{collection_id}'"
      )
    )
  end
end

## Lists all persisted Department Groups sorted deterministically by name then id.
fn list_groups_json(store: Store) : Result(List(Json), AppError)
  items = try scan_bucket_jsons(store, dept_groups_bucket, 200)
  Ok(
    items.sort_by(fn(g)
      "#{g.text_at("name") or ""}|#{g.text_at("id") or ""}"
    end)
  )
end

## Lists all persisted Collection Security Vault policies.
fn list_vault_policies_json(store: Store) : Result(List(Json), AppError)
  items = try scan_bucket_jsons(store, vault_policies_bucket, 200)
  Ok(items.sort_by(fn(p) p.text_at("collection_id") or "" end))
end

## Lists filtered `Modb.Ledger` FERPA read/export audit entries newest-first (capped 1..200).
fn list_ferpa_audit_json(
  store: Store,
  col_filter: Option(Text),
  principal_filter: Option(Text),
  action_filter: Option(Text),
  limit: Int
) : Result(List(Json), AppError)
  lim = if limit < 1: 1 else if limit > 200: 200 else: limit
  items = try scan_bucket_jsons(store, ferpa_audit_bucket, 500)
  var filtered = []
  for j in items.reverse
    col_ok = case col_filter
      Some(c) if not c.trim.empty?: j.text_at("collection_id") == Some(c.trim)
      Some(_) | None: true
    end
    continue if not col_ok
    pr_ok = case principal_filter
      Some(pr) if not pr.trim.empty?:
        p_clean = pr.trim
        j.text_at("principal_id") == Some(p_clean) or j.text_at("principal_handle") == Some(p_clean)
      Some(_) | None: true
    end
    continue if not pr_ok
    act_ok = case action_filter
      Some(act) if not act.trim.empty?: j.text_at("action") == Some(act.trim)
      Some(_) | None: true
    end
    continue if not act_ok
    filtered = filtered.append(j)
    break if filtered.size >= lim
  end
  Ok(filtered)
end

## Augments `base_views` with explicit `"deny:collection:<id>"` exclusions for any
## `ferpa_restricted` collection that does not admit `principal_id` directly or via a Department Group.
fn apply_vault_restrictions(
  store: Store,
  principal_id: Text,
  base_views: Option(List(Text))
) : Result(Option(List(Text)), AppError)
  policies = try scan_bucket_jsons(store, vault_policies_bucket, 200)
  var restricted = []
  for pol in policies
    if pol.text_at("security_tier") == Some("ferpa_restricted")
      restricted = restricted.append(pol)
    end
  end
  if restricted.empty?
    return Ok(base_views)
  end

  groups = try scan_bucket_jsons(store, dept_groups_bucket, 200)
  var member_gids = []
  for g in groups
    if json_string_list(g, "member_principal_ids").contains?(principal_id)
      case g.text_at("id")
        Some(gid): member_gids = member_gids.append(gid)
        None: Unit
      end
    end
  end

  var denies = []
  for pol in restricted
    cid = pol.text_at("collection_id") or ""
    continue if cid.empty?
    direct_ok? = json_string_list(pol, "allowed_principal_ids").contains?(principal_id)
    group_ok? = json_string_list(pol, "allowed_group_ids").any?(fn(gid)
      member_gids.contains?(gid)
    end)
    if not direct_ok? and not group_ok?
      denies = denies.append("deny:collection:#{cid}")
    end
  end
  if denies.empty?
    return Ok(base_views)
  end

  case base_views
    None: Ok(Some(["workspace:*"].concat(denies)))
    Some(vs): Ok(Some(vs.concat(denies)))
  end
end

## Appends a hash-chained `Modb.Ledger` read/export audit record for accessing a `ferpa_restricted` collection.
fn record_ferpa_read_audit_locked(
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  auth: AuthContext,
  action: Text,
  collection_id: Text,
  resource_kind: Text,
  resource_id: Text,
  reason: Text
) : Result(Unit, AppError)
  aid = "faud_#{Id.ulid(rng, clock)}"
  now = clock.now
  sess_id = auth.session.map(fn(s) s.id end)
  entry = Json.Object({
    "id": Json.String(aid),
    "action": Json.String(action),
    "collection_id": Json.String(collection_id),
    "resource_kind": Json.String(resource_kind),
    "resource_id": Json.String(resource_id),
    "principal_id": Json.String(auth.principal.id),
    "principal_handle": Json.String(auth.principal.handle),
    "grant_id": Json.String(auth.grant_id),
    "session_id": sess_id.to_json,
    "reason": Json.String(reason),
    "at": now.to_json
  })
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: action,
    reason: reason,
    at: now
  )
  Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    reason,
    entry,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_put_json(tx, ferpa_audit_bucket, aid, entry)
      Ok((t1, Unit))
    end
  )
end
