## Fail-closed authorization, collection scope checking, write policies, and agent token helpers.
module Domain.Policy
expose default_human_actions,
all_valid_actions,
action_permitted?,
collection_permitted?,
require_collection_access,
can_write_page_direct?,
can_write_db_direct?,
extract_bearer_token,
mint_agent_token_raw,
valid_collection_slug?
use Api
use Crypto
use Domain.Types{
  AppError,
  AuthContext,
  Collection,
  CollectionWritePolicy,
  Principal,
  PrincipalKind,
  WorkspaceRole
}

## Complete set of Vellum capability actions governed by `Modb.Grants`.
fn all_valid_actions() : List(Text)
  [
    "read",
    "comment",
    "claim",
    "propose",
    "write_direct",
    "publish",
    "query_db",
    "write_db",
    "manage_schema",
    "manage_grants",
    "delegate",
    "upload_attachment"
  ]
end

## Default workspace actions granted to an OIDC-authenticated human based on `WorkspaceRole`.
fn default_human_actions(role: WorkspaceRole) : List(Text)
  case role
    Owner | Admin: all_valid_actions()
    Member: [
      "read",
      "comment",
      "claim",
      "propose",
      "write_direct",
      "publish",
      "query_db",
      "write_db",
      "delegate",
      "upload_attachment"
    ]
    Guest: ["read", "comment", "query_db"]
    Bot: ["read", "comment", "claim", "propose", "query_db"]
  end
end

## Returns `true` iff `auth.principal` is not suspended and its grant permits `action`.
fn action_permitted?(auth: AuthContext, action: Text) : Bool
  return false if auth.principal.suspended
  auth.allowed_actions.contains?(action)
end

## Returns `true` iff `auth` may access `collection_id` (`None` = workspace-wide root access).
fn collection_permitted?(auth: AuthContext, collection_id: Text) : Bool
  return false if auth.principal.suspended or collection_id.empty?
  case auth.allowed_collections
    None: true
    Some(scopes): scopes.contains?("workspace:*") or scopes.contains?("collection:#{collection_id}")
  end
end

## Fails closed with `Forbidden` unless `auth` permits both `action` and `collection_id`.
fn require_collection_access(auth: AuthContext, action: Text, collection_id: Text) : Result(
  Unit,
  AppError
)
  promise "suspended principals and unpermitted actions or collections fail closed"
    (
      auth.principal.suspended or
        not auth.allowed_actions.contains?(action) or
        not collection_permitted?(auth, collection_id)
    ) implies (result is Error(Forbidden(reason: _)))
  end

  if auth.principal.suspended
    return Error(Forbidden(reason: "principal '#{auth.principal.handle}' is suspended"))
  end
  if not action_permitted?(auth, action)
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit '#{action}'"))
  end
  if not collection_permitted?(auth, collection_id)
    return Error(
      Forbidden(reason: "grant '#{auth.grant_id}' excludes collection '#{collection_id}'")
    )
  end
  Ok(Unit)
end

## Whether `auth` may edit pages directly inside `col` according to its `CollectionWritePolicy`.
fn can_write_page_direct?(auth: AuthContext, col: Collection) : Bool
  return false if not action_permitted?(auth, "write_direct")
  return false if not collection_permitted?(auth, col.id)
  case col.write_policy
    DirectWithAudit: true
    ProposalsRequiredForAgents: auth.principal.kind == Human
    ProposalsRequiredForAll: false
  end
end

## Whether `auth` may edit database rows directly inside `col` according to its `CollectionWritePolicy`.
fn can_write_db_direct?(auth: AuthContext, col: Collection) : Bool
  return false if not (action_permitted?(auth, "write_db") or action_permitted?(auth, "write_direct"))
  return false if not collection_permitted?(auth, col.id)
  case col.write_policy
    DirectWithAudit: true
    ProposalsRequiredForAgents: auth.principal.kind == Human
    ProposalsRequiredForAll: false
  end
end

## Extracts a `vlm_ag_...` Bearer token from `Authorization`, or `None` if absent/malformed.
fn extract_bearer_token(req: Api.Request) : Option(Text)
  examples
    extract_bearer_token(Api.get("/").with_header("Authorization", "Bearer vlm_ag_123")) ==
      Some("vlm_ag_123")
    extract_bearer_token(Api.get("/").with_header("Authorization", "bearer   vlm_ag_abc ")) ==
      Some("vlm_ag_abc")
    extract_bearer_token(Api.get("/").with_header("Authorization", "Basic xyz")) == None
    extract_bearer_token(Api.get("/")) == None
  end

  hdr = try req.header("Authorization")
  trimmed = hdr.trim
  return None if trimmed.byte_count < 8
  first7 = Text.from_chars(trimmed.chars.take(7))
  return None if first7.ascii_lowercase != "bearer "
  tok = (trimmed.drop_prefix(first7) or "").trim
  if tok.starts_with?("vlm_ag_") and tok.byte_count >= 10: Some(tok) else: None
end

## Generates a fresh agent token `(raw_token, display_prefix, sha256_hex)`.
fn mint_agent_token_raw(rng: SecureRandom) : (Text, Text, Text)
  raw_hex = rng.bytes(24).to_hex
  raw_token = "vlm_ag_#{raw_hex}"
  prefix = Text.from_chars(raw_token.chars.take(13))
  token_hash = Crypto.sha256(raw_token.bytes).to_hex
  (raw_token, prefix, token_hash)
end

## Validates lowercase ASCII slug (`a-z`, `0-9`, `-`, 2..48 bytes, no leading/trailing hyphen).
fn valid_collection_slug?(slug: Text) : Bool
  examples
    valid_collection_slug?("engineering-docs")
    valid_collection_slug?("ops")
    not valid_collection_slug?("a")
    not valid_collection_slug?("-ops")
    not valid_collection_slug?("Ops_Team")
  end

  n = slug.byte_count
  return false if n < 2 or n > 48
  return false if slug.starts_with?("-") or slug.ends_with?("-")
  for ch in slug.chars
    ok = ch == '-' or ch.ascii_digit? or (ch.code >= 97 and ch.code <= 122)
    return false if not ok
  end
  true
end

test "fail-closed collection policy and write_policy enforcement"
  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  human = Principal(
    id: "usr_1",
    kind: Human,
    handle: "@ada",
    display_name: "Ada",
    email: Some("ada@acme.io"),
    avatar_url: None,
    role: Member,
    model_id: None,
    root_grant_id: "gr_ada",
    suspended: false,
    created_at: t0,
    last_seen_at: None
  )
  agent = Principal(
    id: "agt_1",
    kind: Agent,
    handle: "@gardener",
    display_name: "Docs Gardener",
    email: None,
    avatar_url: None,
    role: Bot,
    model_id: Some("claude-sonnet-4-6"),
    root_grant_id: "gr_agt",
    suspended: false,
    created_at: t0,
    last_seen_at: None
  )

  h_ctx = AuthContext(
    principal: human,
    grant_id: "gr_ada",
    session: None,
    allowed_collections: None,
    allowed_actions: default_human_actions(Member)
  )
  a_ctx = AuthContext(
    principal: agent,
    grant_id: "gr_agt",
    session: None,
    allowed_collections: Some(["collection:col_eng"]),
    allowed_actions: ["read", "write_direct", "comment"]
  )

  col_eng_open = Collection(
    id: "col_eng",
    workspace_id: "ws_default",
    slug: "eng",
    name: "Engineering",
    description: "",
    icon: None,
    write_policy: DirectWithAudit,
    freshness_ttl_days: None,
    sort_order: "i",
    archived_at: None
  )
  col_eng_gated = Collection(
    id: "col_eng",
    workspace_id: "ws_default",
    slug: "eng",
    name: "Engineering",
    description: "",
    icon: None,
    write_policy: ProposalsRequiredForAgents,
    freshness_ttl_days: None,
    sort_order: "i",
    archived_at: None
  )

  assert require_collection_access(a_ctx, "read", "col_eng") == Ok(Unit)
  assert require_collection_access(a_ctx, "read", "col_secret") is Error(Forbidden(reason: _))
  assert require_collection_access(a_ctx, "manage_grants", "col_eng") is Error(Forbidden(reason: _))
  assert can_write_page_direct?(a_ctx, col_eng_open)
  assert not can_write_page_direct?(a_ctx, col_eng_gated)
  assert can_write_page_direct?(h_ctx, col_eng_gated)

  rng = SecureRandom.seeded(99)
  (raw, pref, digest) = mint_agent_token_raw(rng)
  assert raw.starts_with?("vlm_ag_")
  assert pref == Text.from_chars(raw.chars.take(13))
  assert digest.byte_count == 64
end
